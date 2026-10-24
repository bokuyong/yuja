import XCTest
@testable import YujaCore

final class MarkdownExporterTests: XCTestCase {
    private func md(_ blocks: [Block], _ options: MarkdownOptions = MarkdownOptions()) -> String {
        MarkdownExporter(options: options).export(Document(sections: [Section(blocks: blocks)]))
    }

    private func p(_ text: String) -> Block { .paragraph(runs: [Run(text)], align: nil) }
    private func cell(_ text: String, _ colSpan: Int = 1, _ rowSpan: Int = 1) -> Cell {
        Cell(blocks: text.isEmpty ? [] : [p(text)], colSpan: colSpan, rowSpan: rowSpan)
    }

    // 구분 | 항목(↔2)
    //  ↕  | 금액 | 부가세
    private var mergedTable: Table {
        Table(rows: [
            [cell("구분", 1, 2), cell("항목", 2)],
            [cell("금액"), cell("부가세")],
        ])
    }

    func testGFMTableFlattensMergedCells() {
        XCTAssertEqual(md([.table(mergedTable)]), """
        | 구분 | 항목 |  |
        | --- | --- | --- |
        |  | 금액 | 부가세 |

        """)
    }

    func testSpanMarks() {
        XCTAssertEqual(md([.table(mergedTable)], MarkdownOptions(spanMarks: true)), """
        | 구분 (↕2) | 항목 (↔2) |  |
        | --- | --- | --- |
        |  | 금액 | 부가세 |

        """)
    }

    func testHTMLTableKeepsSpans() {
        XCTAssertEqual(md([.table(mergedTable)], MarkdownOptions(tableStyle: .html)), """
        <table>
        <tr><td rowspan="2">구분</td><td colspan="2">항목</td></tr>
        <tr><td>금액</td><td>부가세</td></tr>
        </table>

        """)
    }

    func testHTMLTableEscapesText() {
        let table = Table(rows: [[cell("<기업명> & 대표"), cell("a\nb")]])
        XCTAssertEqual(md([.table(table)], MarkdownOptions(tableStyle: .html)), """
        <table>
        <tr><td>&lt;기업명&gt; &amp; 대표</td><td>a<br>b</td></tr>
        </table>

        """)
    }

    func testRowShorterThanGridIsPadded() {
        let table = Table(rows: [[cell("a"), cell("b"), cell("c")], [cell("d")]])
        XCTAssertEqual(md([.table(table)]), """
        | a | b | c |
        | --- | --- | --- |
        | d |  |  |

        """)
    }

    func testSingleCellTableIsUnwrapped() {
        XCTAssertEqual(md([.table(Table(rows: [[cell("제목 상자")]]))]), "제목 상자\n")
    }

    func testEmphasisKeepsWhitespaceOutsideMarkers() {
        let runs = [Run("앞 "), Run(" 굵게 ", bold: true), Run("뒤"), Run("기울임", italic: true), Run("취소", strike: true)]
        XCTAssertEqual(md([.paragraph(runs: runs, align: nil)]), "앞 **굵게** 뒤*기울임*~~취소~~\n")
    }

    func testAdjacentRunsWithSameEmphasisAreMerged() {
        // 밑줄만 다른 굵은 런 두 개 → 하나의 ** 구간
        let runs = [Run("가", bold: true), Run("나", bold: true, underline: true)]
        XCTAssertEqual(md([.paragraph(runs: runs, align: nil)]), "**가나**\n")
    }

    func testEmphasisIsDroppedInHeadingsAndCells() {
        XCTAssertEqual(md([.heading(level: 2, runs: [Run("제목", bold: true)])]), "## 제목\n")
        let table = Table(rows: [[Cell(blocks: [.paragraph(runs: [Run("머리", bold: true)], align: nil)]), cell("x")]])
        XCTAssertTrue(md([.table(table)]).hasPrefix("| 머리 | x |"))
    }

    func testLineStartEscapes() {
        XCTAssertEqual(MarkdownExporter.escapeLineStart("# 제목 아님"), "\\# 제목 아님")
        XCTAssertEqual(MarkdownExporter.escapeLineStart("#해시태그"), "#해시태그")
        XCTAssertEqual(MarkdownExporter.escapeLineStart("> 인용 아님"), "\\> 인용 아님")
        XCTAssertEqual(MarkdownExporter.escapeLineStart("---"), "\\---")
        XCTAssertEqual(MarkdownExporter.escapeLineStart("="), "\\=")
        XCTAssertEqual(MarkdownExporter.escapeLineStart("____"), "\\____")
        XCTAssertEqual(MarkdownExporter.escapeLineStart("- 항목"), "- 항목")
    }

    func testInlineEscapes() {
        XCTAssertEqual(MarkdownExporter.escape("10~20", escapeTilde: false), "10~20")
        XCTAssertEqual(MarkdownExporter.escape("1~2", escapeTilde: true), "1\\~2")
        XCTAssertEqual(MarkdownExporter.escape("성명: ______", escapeTilde: false), "성명: ______")
        XCTAssertEqual(MarkdownExporter.escape("a_b", escapeTilde: false), "a\\_b")
        XCTAssertEqual(MarkdownExporter.escape("<기업명> <b>", escapeTilde: false), "<기업명> \\<b>")
        XCTAssertEqual(MarkdownExporter.escape("[붙임](1) [참고]", escapeTilde: false), "[붙임\\](1) [참고]")
    }

    func testNestedLists() {
        let list = Block.list(items: [
            [p("하나"), .list(items: [[p("하나-1")], [p("하나-2")]], ordered: false)],
            [p("둘")],
        ], ordered: true)
        XCTAssertEqual(md([list]), """
        1. 하나
           - 하나-1
           - 하나-2
        2. 둘

        """)
    }

    func testImageLinkWithSpacesIsBracketed() {
        let ref = ImageRef(sourceID: "BinData/image1.png", path: "내 문서_assets/img_1.png")
        XCTAssertEqual(md([.image(ref)]), "![](<내 문서_assets/img_1.png>)\n")
        XCTAssertEqual(md([.image(ImageRef(sourceID: "BinData/x.bmp"))]), "[이미지: BinData/x.bmp]\n")
    }

    func testPageBreakAndBlankParagraphsProduceNothing() {
        XCTAssertEqual(md([p("가"), .pageBreak, p("   "), p("나")]), "가\n\n나\n")
    }
}
