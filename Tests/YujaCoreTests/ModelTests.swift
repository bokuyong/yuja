import XCTest
@testable import YujaCore

final class ModelTests: XCTestCase {
    func testPlainTextFragmentsCoversNestedBlocks() {
        let table = Table(rows: [[
            Cell(blocks: [.paragraph(runs: [Run("셀1")], align: nil)]),
            Cell(blocks: [.paragraph(runs: [Run("셀2")], align: nil)], colSpan: 2),
        ]])
        let doc = Document(sections: [Section(blocks: [
            .heading(level: 1, runs: [Run("제목", bold: true)]),
            .list(items: [[.paragraph(runs: [Run("항목")], align: nil)]], ordered: false),
            .table(table),
            .image(ImageRef(sourceID: "BinData/image1.png", altText: "그림")),
            .pageBreak,
            .raw("수식"),
        ])])

        XCTAssertEqual(doc.plainTextFragments, ["제목", "항목", "셀1", "셀2", "그림", "수식"])
    }
}
