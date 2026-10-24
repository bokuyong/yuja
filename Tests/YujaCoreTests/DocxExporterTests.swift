import AppKit
import XCTest
import ZIPFoundation
@testable import YujaCore

final class DocxExporterTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = try Fixtures.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func convert(_ name: String) throws -> URL {
        let input = try Fixtures.makeHWPX(name, in: tmp)
        let output = tmp.appendingPathComponent("\(name).docx")
        try Converter.convert(input: input, output: output, options: ConvertOptions(format: .docx))
        return output
    }

    private func entry(_ docx: URL, _ path: String) throws -> Data {
        let archive = try Archive(url: docx, accessMode: .read)
        guard let entry = archive[path] else { throw XCTSkip("엔트리 없음: \(path)") }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return data
    }

    private func documentXML(_ blocks: [Block]) throws -> String {
        let parts = try DocxExporter().parts(Document(sections: [Section(blocks: blocks)]), resources: nil)
        return String(decoding: parts.first { $0.path == "word/document.xml" }!.data, as: UTF8.self)
    }

    // MARK: 골든

    /// word/document.xml을 픽스처별 기대값(<이름>.expected.docx.xml)과 비교한다.
    func testDocumentXMLMatchesGolden() throws {
        for name in Fixtures.hwpxNames {
            let xml = String(decoding: try entry(convert(name), "word/document.xml"), as: UTF8.self)
            let expectedURL = Fixtures.expectedURL(name, "docx.xml")
            if GoldenTests.update {
                try xml.write(to: expectedURL, atomically: true, encoding: .utf8)
                continue
            }
            XCTAssertEqual(xml, try String(contentsOf: expectedURL, encoding: .utf8), "\(name) document.xml 기대값과 다름")
        }
    }

    // MARK: 패키지 구조

    func testPackageHasRequiredPartsAndAllXMLIsWellFormed() throws {
        for name in Fixtures.hwpxNames {
            let docx = try convert(name)
            let archive = try Archive(url: docx, accessMode: .read)
            let paths = Set(archive.map(\.path))
            for required in ["[Content_Types].xml", "_rels/.rels", "word/document.xml", "word/styles.xml",
                             "word/numbering.xml", "word/settings.xml", "word/_rels/document.xml.rels", "docProps/core.xml"] {
                XCTAssertTrue(paths.contains(required), "\(name): \(required) 없음")
            }
            for path in paths where path.hasSuffix(".xml") || path.hasSuffix(".rels") {
                let parser = XMLParser(data: try entry(docx, path))
                XCTAssertTrue(parser.parse(), "\(name): \(path) XML 오류 \(String(describing: parser.parserError))")
            }
        }
    }

    func testImagesAreEmbeddedOnceAndRelationshipsResolve() throws {
        let docx = try convert("images")
        let archive = try Archive(url: docx, accessMode: .read)
        let media = archive.map(\.path).filter { $0.hasPrefix("word/media/") }.sorted()
        XCTAssertEqual(media, ["word/media/image1.png", "word/media/image2.png"])

        let rels = String(decoding: try entry(docx, "word/_rels/document.xml.rels"), as: UTF8.self)
        for path in media {
            XCTAssertTrue(rels.contains("Target=\"media/\((path as NSString).lastPathComponent)\""))
        }
        let types = String(decoding: try entry(docx, "[Content_Types].xml"), as: UTF8.self)
        XCTAssertTrue(types.contains("Extension=\"png\""))

        // 같은 그림이 두 번 쓰였으므로 그림 개체는 3개, 미디어는 2개
        let xml = String(decoding: try entry(docx, "word/document.xml"), as: UTF8.self)
        XCTAssertEqual(xml.components(separatedBy: "<w:drawing>").count - 1, 3)
        // 원본 표시 크기 36pt × 24pt → EMU
        XCTAssertTrue(xml.contains("<wp:extent cx=\"457200\" cy=\"304800\"/>"))
    }

    func testOutputIsDeterministic() throws {
        let a = try Data(contentsOf: convert("images"))
        let b = try Data(contentsOf: convert("images"))
        XCTAssertEqual(a, b)
    }

    func testNoImagesOptionWritesPlaceholder() throws {
        let input = try Fixtures.makeHWPX("images", in: tmp)
        let output = tmp.appendingPathComponent("noimg.docx")
        try Converter.convert(input: input, output: output, options: ConvertOptions(format: .docx, extractImages: false))
        let xml = String(decoding: try entry(output, "word/document.xml"), as: UTF8.self)
        XCTAssertFalse(xml.contains("<w:drawing>"))
        XCTAssertTrue(xml.contains("[이미지: BinData/image1.png]"))
    }

    // MARK: 텍스트 유실 / 실제 리더

    func testNoTextLossInDocumentXML() throws {
        for name in Fixtures.hwpxNames {
            let input = try Fixtures.makeHWPX(name, in: tmp)
            let fragments = try TextProbe.fragments(ofHWPX: input)
            let docx = tmp.appendingPathComponent("\(name).docx")
            try Converter.convert(input: input, output: docx, options: ConvertOptions(format: .docx))
            let text = Self.text(ofDocumentXML: String(decoding: try entry(docx, "word/document.xml"), as: UTF8.self))
            let missing = TextProbe.missing(fragments, in: text, markdown: false)
            XCTAssertTrue(missing.isEmpty, "\(name) DOCX 유실: \(missing)")
        }
    }

    /// macOS 내장 DOCX 리더(NSAttributedString)가 열 수 있고 본문 텍스트가 보이는지.
    func testAppleReaderOpensOutput() throws {
        for name in Fixtures.hwpxNames {
            let docx = try convert(name)
            let attributed = try NSAttributedString(
                url: docx, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
            XCTAssertFalse(attributed.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(name): 빈 문서로 읽힘")
        }
        let tables = try NSAttributedString(
            url: convert("tables"), options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        XCTAssertTrue(tables.string.contains("내부4"), "중첩 표 내용이 리더에서 안 보임")
    }

    static func text(ofDocumentXML xml: String) -> String {
        xml.replacingOccurrences(of: "<w:(tab|br)[^>]*/>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "</w:p>", with: " ")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: 단위

    func testMergedCellsUseGridSpanAndVMerge() throws {
        // 구분(↕2) | 항목(↔2)
        //          | 금액 | 부가세
        let table = Table(rows: [
            [Cell(blocks: [.paragraph(runs: [Run("구분")], align: nil)], rowSpan: 2),
             Cell(blocks: [.paragraph(runs: [Run("항목")], align: nil)], colSpan: 2)],
            [Cell(blocks: [.paragraph(runs: [Run("금액")], align: nil)]),
             Cell(blocks: [.paragraph(runs: [Run("부가세")], align: nil)])],
        ])
        let xml = try documentXML([.table(table)])
        XCTAssertEqual(xml.components(separatedBy: "<w:gridCol ").count - 1, 3)
        XCTAssertTrue(xml.contains("<w:gridSpan w:val=\"2\"/>"))
        XCTAssertTrue(xml.contains("<w:vMerge w:val=\"restart\"/>"))
        XCTAssertTrue(xml.contains("<w:vMerge/>"))
        // 두 행 모두 칸 수가 격자와 맞아야 한다: 1행 = 1 + span2, 2행 = vMerge + 2
        XCTAssertEqual(xml.components(separatedBy: "<w:tc>").count - 1, 5)
    }

    func testCellEndingWithTableGetsTrailingParagraph() throws {
        let inner = Table(rows: [[Cell(blocks: [.paragraph(runs: [Run("a")], align: nil)]),
                                  Cell(blocks: [.paragraph(runs: [Run("b")], align: nil)])]])
        let outer = Table(rows: [[Cell(blocks: [.table(inner)]), Cell()]])
        let xml = try documentXML([.table(outer)])
        XCTAssertTrue(xml.contains("</w:tbl>\n<w:p/></w:tc>"), "중첩 표 뒤 빈 문단 없음")
        XCTAssertTrue(xml.contains("<w:tcPr><w:tcW w:w=\"4513\" w:type=\"dxa\"/></w:tcPr><w:p/></w:tc>"), "빈 셀에 문단 없음")
    }

    func testOrderedListsRestartNumbering() throws {
        let list = Block.list(items: [[.paragraph(runs: [Run("하나")], align: nil)]], ordered: true)
        let parts = try DocxExporter().parts(Document(sections: [Section(blocks: [list, list])]), resources: nil)
        let numbering = String(decoding: parts.first { $0.path == "word/numbering.xml" }!.data, as: UTF8.self)
        XCTAssertTrue(numbering.contains("<w:num w:numId=\"2\">"))
        XCTAssertTrue(numbering.contains("<w:num w:numId=\"3\">"))
        XCTAssertEqual(numbering.components(separatedBy: "<w:startOverride w:val=\"1\"/>").count - 1, 2)
    }

    func testRunFormattingFollowsSchemaOrder() throws {
        let xml = try documentXML([.paragraph(runs: [Run("x", bold: true, italic: true, underline: true, strike: true)], align: .center)])
        XCTAssertTrue(xml.contains("<w:rPr><w:b/><w:bCs/><w:i/><w:iCs/><w:strike/><w:u w:val=\"single\"/></w:rPr>"))
        XCTAssertTrue(xml.contains("<w:pPr><w:jc w:val=\"center\"/></w:pPr>"))
    }

    func testSettingsDeclareModernCompatibilityMode() throws {
        let parts = try DocxExporter().parts(Document(), resources: nil)
        let settings = String(decoding: parts.first { $0.path == "word/settings.xml" }!.data, as: UTF8.self)
        XCTAssertTrue(settings.contains("w:name=\"compatibilityMode\" w:uri=\"http://schemas.microsoft.com/office/word\" w:val=\"15\""))
    }

    /// 쪽 나눔은 다음 문단의 pageBreakBefore로 (빈 나눔 문단 → Word에서 빈 쪽이 생길 수 있음)
    func testPageBreakBecomesPageBreakBefore() throws {
        let p = { (t: String) in Block.paragraph(runs: [Run(t)], align: nil) }
        let xml = try documentXML([.pageBreak, p("첫 쪽"), .pageBreak, p("둘째 쪽"),
                                   .pageBreak, .table(Table(rows: [[Cell(), Cell()]]))])
        XCTAssertFalse(xml.contains("w:type=\"page\""))
        // 문서 맨 앞 나눔은 무시 → 2개
        XCTAssertEqual(xml.components(separatedBy: "<w:pageBreakBefore/>").count - 1, 2)
        XCTAssertTrue(xml.contains("<w:p><w:pPr><w:pageBreakBefore/></w:pPr><w:r><w:t xml:space=\"preserve\">둘째 쪽</w:t>"))
        XCTAssertTrue(xml.contains("<w:pageBreakBefore/><w:spacing w:before=\"0\" w:after=\"0\" w:line=\"20\" w:lineRule=\"exact\"/></w:pPr></w:p>\n<w:tbl>"))
    }

    func testControlCharactersAreStripped() {
        XCTAssertEqual(DocxXML.escape("a\u{01}b<&>\u{FFFF}"), "ab&lt;&amp;&gt;")
    }

    func testColumnWidthsFromCellWidths() {
        // 1행: 100 | 300(↔2), 2행: 100 | 120 | 180
        let grid = TableGrid(Table(rows: [
            [Cell(width: 100), Cell(colSpan: 2, width: 300)],
            [Cell(width: 100), Cell(width: 120), Cell(width: 180)],
        ]))
        XCTAssertEqual(grid.columnWidths(), [100, 120, 180])

        // 병합 셀만으로 정해지는 열
        let spanned = TableGrid(Table(rows: [
            [Cell(width: 100), Cell(colSpan: 2, width: 300)],
            [Cell(width: 100), Cell(width: 120), Cell()],
        ]))
        XCTAssertEqual(spanned.columnWidths(), [100, 120, 180])

        XCTAssertNil(TableGrid(Table(rows: [[Cell(), Cell()]])).columnWidths())
    }

    func testWideTablesAreScaledToPage() {
        let grid = TableGrid(Table(rows: [[Cell(width: 500), Cell(width: 500)]]))  // 1000pt = 20000twip
        let widths = DocxBodyBuilder.columnWidths(grid, maxWidth: 9026)
        XCTAssertEqual(widths, [4513, 4513])
    }
}
