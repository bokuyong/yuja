import Foundation
import ZIPFoundation

/// IR → DOCX (OOXML 직접 생성, 외부 라이브러리 없이 ZIP만 사용).
///
/// - 제목은 Heading1~6 스타일, 목록은 numbering.xml (번호 목록마다 번호 다시 시작)
/// - 표는 TableGrid 스타일, 병합은 gridSpan / vMerge로 재현. 1×1 제목 상자도 표로 유지
/// - 이미지는 word/media에 넣는다. 원본 표시 크기를 쓰고, 본문 폭을 넘으면 줄인다
public struct DocxExporter {
    public init() {}

    /// ZIP 엔트리 날짜를 고정해서 같은 입력이면 같은 파일이 나오게 한다.
    static let fixedDate = Date(timeIntervalSince1970: 315_532_800)  // 1980-01-01

    public func write(_ document: Document, resources: ResourceProvider?, to url: URL) throws {
        let parts = try self.parts(document, resources: resources)

        // 같은 폴더에 임시 파일로 쓰고 바꿔치기 (중간에 실패해도 기존 파일이 깨지지 않게)
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            let archive = try Archive(url: tmp, accessMode: .create)
            for part in parts {
                let data = part.data
                try archive.addEntry(
                    with: part.path, type: .file, uncompressedSize: Int64(data.count),
                    modificationDate: Self.fixedDate, compressionMethod: .deflate,
                    provider: { position, size in data.subdata(in: Int(position)..<Int(position) + size) }
                )
            }
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw YujaError.writeFailed(url.path)
        }
    }

    /// 패키지 부품 (경로, 내용). 순서대로 ZIP에 들어간다.
    func parts(_ document: Document, resources: ResourceProvider?) throws -> [(path: String, data: Data)] {
        var builder = DocxBodyBuilder(resources: resources)
        for section in document.sections {
            builder.blocks(section.blocks, maxWidth: DocxTemplates.contentWidth)
        }
        let body = builder.finish()

        var parts: [(String, Data)] = [
            ("[Content_Types].xml", Data(DocxTemplates.contentTypes(imageExtensions: Set(builder.media.map(\.ext))).utf8)),
            ("_rels/.rels", Data(DocxTemplates.packageRels.utf8)),
            ("docProps/core.xml", Data(DocxTemplates.core(title: document.meta.title, creator: document.meta.author).utf8)),
            ("word/document.xml", Data(body.utf8)),
            ("word/styles.xml", Data(DocxTemplates.styles.utf8)),
            ("word/numbering.xml", Data(DocxTemplates.numbering(orderedLists: builder.orderedLists).utf8)),
            ("word/_rels/document.xml.rels",
             Data(DocxTemplates.documentRels(images: builder.media.map { ($0.relID, "media/" + $0.name) }).utf8)),
        ]
        parts += builder.media.map { ("word/media/" + $0.name, $0.data) }
        return parts
    }
}

// MARK: - 본문

struct DocxBodyBuilder {
    struct Media {
        var relID: String
        var name: String
        var ext: String
        var data: Data
        var pixelSize: (width: Int, height: Int)?
    }

    let resources: ResourceProvider?
    private(set) var media: [Media] = []
    private(set) var orderedLists: [(numId: Int, level: Int)] = []

    private var xml = ""
    private var mediaBySource: [String: Int] = [:]
    private var drawingCount = 0

    static let bulletNumID = 1
    /// 1 twip = 635 EMU, 1pt = 12700 EMU, 96dpi 1px = 9525 EMU
    static let emuPerTwip = 635

    init(resources: ResourceProvider?) {
        self.resources = resources
    }

    mutating func finish() -> String {
        let w = DocxTemplates.self
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="\(w.wordNS)" xmlns:r="\(w.relNS)" \
        xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
        <w:body>
        \(xml)<w:sectPr><w:pgSz w:w="\(w.pageWidth)" w:h="\(w.pageHeight)"/>\
        <w:pgMar w:top="\(w.margin)" w:right="\(w.margin)" w:bottom="\(w.margin)" w:left="\(w.margin)" \
        w:header="720" w:footer="720" w:gutter="0"/></w:sectPr>
        </w:body>
        </w:document>

        """
    }

    // MARK: 블록

    /// maxWidth: 이미지가 넘지 말아야 할 폭 (twip). 표 셀 안에서는 칸 폭.
    mutating func blocks(_ blocks: [Block], maxWidth: Int) {
        for block in blocks { self.block(block, maxWidth: maxWidth) }
    }

    private mutating func block(_ block: Block, maxWidth: Int) {
        switch block {
        case .heading(let level, let runs):
            guard runs.hasVisibleText else { return }
            paragraph(runs, style: "Heading\(max(1, min(level, 6)))")

        case .paragraph(let runs, let align):
            guard runs.hasVisibleText else { return }
            paragraph(runs, align: align)

        case .list(let items, let ordered):
            list(items, ordered: ordered, level: 0, maxWidth: maxWidth)

        case .table(let table):
            self.table(table, width: maxWidth)

        case .image(let ref):
            image(ref, maxWidth: maxWidth)

        case .pageBreak:
            xml += "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>\n"

        case .raw(let text):
            guard text.contains(where: { !$0.isWhitespace }) else { return }
            paragraph([Run(text)])
        }
    }

    private mutating func paragraph(_ runs: [Run], style: String? = nil, align: Align? = nil,
                                    numbering: (numId: Int, level: Int)? = nil, indentLevel: Int? = nil) {
        var pPr = ""
        if let style { pPr += "<w:pStyle w:val=\"\(style)\"/>" }
        if let numbering {
            pPr += "<w:numPr><w:ilvl w:val=\"\(numbering.level)\"/><w:numId w:val=\"\(numbering.numId)\"/></w:numPr>"
        }
        if let indentLevel { pPr += "<w:ind w:left=\"\(400 * (indentLevel + 1))\"/>" }
        if let jc = Self.justification(align) { pPr += "<w:jc w:val=\"\(jc)\"/>" }

        xml += "<w:p>" + (pPr.isEmpty ? "" : "<w:pPr>\(pPr)</w:pPr>") + runs.map(Self.run).joined() + "</w:p>\n"
    }

    private static func justification(_ align: Align?) -> String? {
        switch align {
        case .center: return "center"
        case .right: return "right"
        case .justify: return "both"
        case .left, nil: return nil
        }
    }

    private static func run(_ run: Run) -> String {
        guard !run.text.isEmpty else { return "" }
        // 순서는 스키마(CT_RPr) 순서를 따라야 Word가 받아들인다: b, i, strike, …, u
        var rPr = ""
        if run.bold { rPr += "<w:b/><w:bCs/>" }
        if run.italic { rPr += "<w:i/><w:iCs/>" }
        if run.strike { rPr += "<w:strike/>" }
        if run.underline { rPr += "<w:u w:val=\"single\"/>" }

        var content = ""
        var pending = ""
        func flush() {
            guard !pending.isEmpty else { return }
            content += "<w:t xml:space=\"preserve\">\(DocxXML.escape(pending))</w:t>"
            pending = ""
        }
        for ch in run.text {
            switch ch {
            case "\n", "\r\n": flush(); content += "<w:br/>"
            case "\t": flush(); content += "<w:tab/>"
            default: pending.append(ch)
            }
        }
        flush()
        return "<w:r>" + (rPr.isEmpty ? "" : "<w:rPr>\(rPr)</w:rPr>") + content + "</w:r>"
    }

    // MARK: 목록

    private mutating func list(_ items: [[Block]], ordered: Bool, level: Int, maxWidth: Int) {
        let level = min(level, 8)
        let numId: Int
        if ordered {
            numId = Self.bulletNumID + 1 + orderedLists.count
            orderedLists.append((numId, level))
        } else {
            numId = Self.bulletNumID
        }

        for item in items {
            var numbered = false
            for child in item {
                switch child {
                case .paragraph(let runs, _), .heading(_, let runs):
                    guard runs.hasVisibleText else { continue }
                    if numbered {
                        paragraph(runs, style: "ListParagraph", indentLevel: level)
                    } else {
                        paragraph(runs, style: "ListParagraph", numbering: (numId, level))
                        numbered = true
                    }
                case .list(let nested, let nestedOrdered):
                    list(nested, ordered: nestedOrdered, level: level + 1, maxWidth: maxWidth)
                default:
                    block(child, maxWidth: maxWidth)
                }
            }
        }
    }

    // MARK: 표

    private mutating func table(_ table: Table, width: Int) {
        let grid = TableGrid(table)
        let columns = grid.columnCount
        guard columns > 0, !grid.slots.isEmpty else { return }
        let colWidths = Self.columnWidths(grid, maxWidth: width)
        func spanWidth(_ c: Int, _ span: Int) -> Int { colWidths[c..<(c + span)].reduce(0, +) }

        // 테두리·폭은 스타일에만 두면 Pages·Quick Look 등이 무시하므로 표마다 직접 적는다.
        let border = "w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\""
        xml += "<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:tblW w:w=\"\(colWidths.reduce(0, +))\" w:type=\"dxa\"/>"
        xml += "<w:tblBorders><w:top \(border)/><w:left \(border)/><w:bottom \(border)/><w:right \(border)/>"
        xml += "<w:insideH \(border)/><w:insideV \(border)/></w:tblBorders>"
        xml += "<w:tblLayout w:type=\"fixed\"/>"
        xml += "<w:tblLook w:val=\"04A0\" w:firstRow=\"0\" w:lastRow=\"0\" w:firstColumn=\"0\" w:lastColumn=\"0\" w:noHBand=\"0\" w:noVBand=\"1\"/></w:tblPr>"
        xml += "<w:tblGrid>" + colWidths.map { "<w:gridCol w:w=\"\($0)\"/>" }.joined() + "</w:tblGrid>\n"

        for (r, row) in grid.slots.enumerated() {
            xml += "<w:tr>"
            var c = 0
            while c < columns {
                switch row[c] {
                case .cell(let cell):
                    let span = min(cell.colSpan, columns - c)
                    cellXML(cell.blocks, span: span, vMerge: cell.rowSpan > 1 ? "restart" : nil, width: spanWidth(c, span))
                    c += span

                case .covered(let originRow, let originCol):
                    // 위쪽 셀의 세로 병합 → 같은 폭의 vMerge 이어짐 칸.
                    // (같은 행의 가로 병합 칸은 앞 셀의 gridSpan으로 이미 건너뛰었다.)
                    if originRow < r, originCol == c, case .cell(let origin) = grid.slots[originRow][originCol] {
                        let span = min(origin.colSpan, columns - c)
                        cellXML([], span: span, vMerge: "continue", width: spanWidth(c, span))
                        c += span
                    } else {
                        c += 1
                    }

                case .empty:
                    cellXML([], span: 1, vMerge: nil, width: colWidths[c])
                    c += 1
                }
            }
            xml += "</w:tr>\n"
        }
        xml += "</w:tbl>\n"
    }

    /// 열 폭(twip). 원본 셀 폭이 있으면 그 비율대로, 본문 폭을 넘으면 줄인다. 없으면 균등.
    static func columnWidths(_ grid: TableGrid, maxWidth: Int) -> [Int] {
        let columns = grid.columnCount
        guard let points = grid.columnWidths() else {
            return Array(repeating: max(maxWidth / columns, 1), count: columns)
        }
        let twips = points.map { $0 * 20 }
        let total = twips.reduce(0, +)
        let scale = total > Double(maxWidth) ? Double(maxWidth) / total : 1
        return twips.map { max(Int(($0 * scale).rounded(.down)), 1) }
    }

    private mutating func cellXML(_ blocks: [Block], span: Int, vMerge: String?, width: Int) {
        var tcPr = "<w:tcW w:w=\"\(width)\" w:type=\"dxa\"/>"
        if span > 1 { tcPr += "<w:gridSpan w:val=\"\(span)\"/>" }
        if let vMerge { tcPr += vMerge == "continue" ? "<w:vMerge/>" : "<w:vMerge w:val=\"restart\"/>" }
        xml += "<w:tc><w:tcPr>\(tcPr)</w:tcPr>"

        let before = xml.utf8.count
        // 셀 여백(좌우 108 twip씩)을 뺀 폭 안에 이미지를 맞춘다
        self.blocks(blocks, maxWidth: max(width - 216, 1))
        // 셀은 반드시 문단으로 끝나야 한다 (비었거나 표로 끝나면 빈 문단 추가)
        if xml.utf8.count == before || xml.hasSuffix("</w:tbl>\n") { xml += "<w:p/>" }
        xml += "</w:tc>"
    }

    // MARK: 이미지

    private mutating func image(_ ref: ImageRef, maxWidth: Int) {
        guard let index = mediaIndex(for: ref.sourceID) else {
            paragraph([Run("[이미지: \(ref.sourceID)]")])
            return
        }
        let item = media[index]

        // EMU 크기: 원본 표시 크기(pt) → 없으면 픽셀(96dpi) → 없으면 1인치
        var cx: Double, cy: Double
        if let size = ref.size {
            (cx, cy) = (size.width * 12700, size.height * 12700)
        } else if let px = item.pixelSize {
            (cx, cy) = (Double(px.width) * 9525, Double(px.height) * 9525)
        } else {
            (cx, cy) = (914_400, 914_400)
        }
        let limit = Double(maxWidth * Self.emuPerTwip)
        if cx > limit { (cx, cy) = (limit, cy * limit / cx) }
        let (w, h) = (Int(cx.rounded()), max(Int(cy.rounded()), 1))

        drawingCount += 1
        let id = drawingCount
        xml += """
        <w:p><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">\
        <wp:extent cx="\(w)" cy="\(h)"/><wp:docPr id="\(id)" name="그림 \(id)"/>\
        <wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>\
        <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">\
        <pic:pic><pic:nvPicPr><pic:cNvPr id="\(id)" name="\(item.name)"/><pic:cNvPicPr/></pic:nvPicPr>\
        <pic:blipFill><a:blip r:embed="\(item.relID)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
        <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(w)" cy="\(h)"/></a:xfrm>\
        <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>\
        </a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>

        """
    }

    /// 같은 원본 이미지는 한 번만 넣는다. 읽을 수 없으면 nil (자리표시 문단으로 대체).
    private mutating func mediaIndex(for sourceID: String) -> Int? {
        if let index = mediaBySource[sourceID] { return index }
        guard let raw = try? resources?.data(for: sourceID) else { return nil }

        let image = ImageData.normalized(raw, sourceID: sourceID)
        let n = media.count + 1
        media.append(Media(relID: "rIdImg\(n)", name: "image\(n).\(image.ext)", ext: image.ext,
                           data: image.data, pixelSize: ImageData.pixelSize(image.data)))
        mediaBySource[sourceID] = media.count - 1
        return media.count - 1
    }
}
