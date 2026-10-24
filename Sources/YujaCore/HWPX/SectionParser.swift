import Foundation

/// Contents/sectionN.xml → IR Section. XMLParser(SAX)로 한 번 훑으면서 만든다.
///
/// 표·그림·글상자 같은 개체는 hp:run 안에 인라인으로 들어 있으므로,
/// 문단은 "텍스트 조각"과 "블록"이 섞인 순서열로 모았다가 문단이 끝날 때 펼친다.
struct SectionParser {
    let styles: HeaderStyles
    /// manifest id → 패키지 안 경로 (hc:img binaryItemIDRef 해석용)
    let binaryItems: [String: String]

    func parse(_ data: Data) throws -> Section {
        let delegate = SectionDelegate(styles: styles, binaryItems: binaryItems)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse() else {
            let reason = parser.parserError?.localizedDescription ?? "알 수 없는 오류"
            throw YujaError.corrupted("본문 XML을 해석할 수 없습니다 (\(reason))")
        }
        return Section(blocks: delegate.finish())
    }
}

// MARK: - 빌더

private enum Segment {
    case text(Run)
    case block(Block)
}

/// 컨테이너(구역, 셀, 글상자 …) 안의 항목. 목록 문단은 나중에 묶어서 Block.list로 만든다.
private enum Item {
    case block(Block)
    case listItem(level: Int, ordered: Bool, runs: [Run])
}

private final class ParagraphBuilder {
    let shape: ParaShape
    let pageBreak: Bool
    var charShape = CharShape()
    var segments: [Segment] = []
    /// 각주·글상자 등 문단 흐름 밖의 내용. 문단 뒤에 붙인다.
    var trailing: [Block] = []

    init(shape: ParaShape, pageBreak: Bool) {
        self.shape = shape
        self.pageBreak = pageBreak
    }

    func appendText(_ text: String) {
        guard !text.isEmpty else { return }
        let c = charShape
        if case .text(var last)? = segments.last,
           last.bold == c.bold, last.italic == c.italic, last.underline == c.underline, last.strike == c.strike {
            last.text += text
            segments[segments.count - 1] = .text(last)
        } else {
            segments.append(.text(Run(text, bold: c.bold, italic: c.italic, underline: c.underline, strike: c.strike)))
        }
    }

    func items() -> [Item] {
        var out: [Item] = []
        if pageBreak { out.append(.block(.pageBreak)) }

        var runs: [Run] = []
        func flushRuns() {
            guard !runs.isEmpty else { return }
            switch shape.heading {
            case .outline:
                out.append(.block(.heading(level: min(shape.level + 1, 6), runs: runs)))
            case .number:
                out.append(.listItem(level: shape.level, ordered: true, runs: runs))
            case .bullet:
                out.append(.listItem(level: shape.level, ordered: false, runs: runs))
            case .none:
                out.append(.block(.paragraph(runs: runs, align: shape.align)))
            }
            runs = []
        }

        for segment in segments {
            switch segment {
            case .text(let run): runs.append(run)
            case .block(let block):
                flushRuns()
                out.append(.block(block))
            }
        }
        flushRuns()
        out += trailing.map(Item.block)
        return out
    }
}

private final class TableBuilder {
    var rows: [[Cell]] = []
    var cell = Cell()
}

private final class SectionDelegate: NSObject, XMLParserDelegate {
    let styles: HeaderStyles
    let binaryItems: [String: String]

    private var elements: [String] = []
    private var containers: [[Item]] = [[]]
    private var paragraphs: [ParagraphBuilder] = []
    private var tables: [TableBuilder] = []
    private var textDepth = 0
    private var script: String?
    /// hp:switch 안의 hp:default는 hp:case와 같은 내용의 대체 표기라 건너뛴다.
    private var skipDepth = 0

    init(styles: HeaderStyles, binaryItems: [String: String]) {
        self.styles = styles
        self.binaryItems = binaryItems
    }

    func finish() -> [Block] {
        fold(containers.first ?? [])
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        if skipDepth > 0 { skipDepth += 1; return }
        if name == "default" && elements.last == "switch" { skipDepth = 1; return }
        elements.append(name)

        switch name {
        case "p":
            let shape = styles.paraShape(attributes["paraPrIDRef"].flatMap(Int.init) ?? 0)
            paragraphs.append(ParagraphBuilder(shape: shape, pageBreak: attributes["pageBreak"] == "1"))
        case "run":
            paragraphs.last?.charShape = styles.charShape(attributes["charPrIDRef"].flatMap(Int.init) ?? 0)
        case "t":
            textDepth += 1
        case "lineBreak":
            paragraphs.last?.appendText("\n")
        case "tab":
            paragraphs.last?.appendText("\t")
        case "nbSpace", "fwSpace":
            paragraphs.last?.appendText(" ")
        case "hyphen":
            paragraphs.last?.appendText("-")
        case "checkBtn", "radioBtn":
            let mark = attributes["value"] == "CHECKED" ? "☑" : "☐"
            paragraphs.last?.appendText(mark + (attributes["caption"] ?? ""))

        case "tbl":
            tables.append(TableBuilder())
        case "tr":
            tables.last?.rows.append([])
        case "tc":
            tables.last?.cell = Cell()
        case "cellSpan":
            tables.last?.cell.colSpan = max(1, attributes["colSpan"].flatMap(Int.init) ?? 1)
            tables.last?.cell.rowSpan = max(1, attributes["rowSpan"].flatMap(Int.init) ?? 1)
        case "subList":
            containers.append([])

        case "img":
            if let id = attributes["binaryItemIDRef"] {
                appendBlock(.image(ImageRef(sourceID: binaryItems[id] ?? id)))
            }
        case "script":
            script = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard skipDepth == 0 else { return }
        if textDepth > 0 {
            paragraphs.last?.appendText(string)
        } else if script != nil {
            script? += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if skipDepth > 0 { skipDepth -= 1; return }

        switch name {
        case "t":
            textDepth -= 1
        case "script":
            let text = (script ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { appendBlock(.raw(text)) }
            script = nil

        case "subList":
            let blocks = fold(containers.removeLast())
            let parent = elements.count >= 2 ? elements[elements.count - 2] : nil
            if parent == "tc" {
                tables.last?.cell.blocks += blocks
            } else if let paragraph = paragraphs.last {
                paragraph.trailing += blocks
            } else {
                containers[containers.count - 1] += blocks.map(Item.block)
            }
        case "tc":
            if let table = tables.last {
                if table.rows.isEmpty { table.rows.append([]) }
                table.rows[table.rows.count - 1].append(table.cell)
            }
        case "tbl":
            if let table = tables.popLast() {
                appendBlock(.table(Table(rows: table.rows.filter { !$0.isEmpty })))
            }
        case "p":
            if let paragraph = paragraphs.popLast() {
                containers[containers.count - 1] += paragraph.items()
            }
        default:
            break
        }

        elements.removeLast()
    }

    // MARK: -

    private func appendBlock(_ block: Block) {
        if let paragraph = paragraphs.last {
            paragraph.segments.append(.block(block))
        } else {
            containers[containers.count - 1].append(.block(block))
        }
    }

    /// 연속된 목록 문단을 Block.list로 묶는다.
    private func fold(_ items: [Item]) -> [Block] {
        var out: [Block] = []
        var pending: [(level: Int, ordered: Bool, runs: [Run])] = []

        func flush() {
            if !pending.isEmpty { out.append(Self.buildList(pending[...])) }
            pending = []
        }

        for item in items {
            switch item {
            case .listItem(let level, let ordered, let runs):
                pending.append((level, ordered, runs))
            case .block(let block):
                flush()
                out.append(block)
            }
        }
        flush()
        return out
    }

    private static func buildList(_ entries: ArraySlice<(level: Int, ordered: Bool, runs: [Run])>) -> Block {
        let base = entries.map(\.level).min() ?? 0
        var items: [[Block]] = []
        var index = entries.startIndex

        while index < entries.endIndex {
            let entry = entries[index]
            if entry.level <= base {
                items.append([.paragraph(runs: entry.runs, align: nil)])
                index += 1
            } else {
                var end = index
                while end < entries.endIndex && entries[end].level > base { end += 1 }
                let nested = buildList(entries[index..<end])
                if items.isEmpty { items.append([]) }
                items[items.count - 1].append(nested)
                index = end
            }
        }
        return .list(items: items, ordered: entries.first?.ordered ?? false)
    }
}
