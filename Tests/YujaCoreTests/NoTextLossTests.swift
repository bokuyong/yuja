import XCTest
@testable import YujaCore

/// 원본의 모든 hp:t 텍스트가 MD·TXT 출력에 들어 있는지 검사한다.
///
/// 로컬 실문서 묶음으로도 돌릴 수 있다 (저장소에 넣지 않는 파일용):
///   YUJA_CORPUS_DIR=~/somewhere swift test --filter NoTextLossTests
final class NoTextLossTests: XCTestCase {
    func testFixtures() throws {
        let tmp = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        for name in Fixtures.hwpxNames {
            try assertNoTextLoss(Fixtures.makeHWPX(name, in: tmp))
        }
    }

    func testLocalCorpus() throws {
        guard let dir = ProcessInfo.processInfo.environment["YUJA_CORPUS_DIR"] else {
            throw XCTSkip("YUJA_CORPUS_DIR 미설정")
        }
        let root = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        let files = Fixtures.regularFiles(under: root).map(\.1).filter { $0.pathExtension.lowercased() == "hwpx" }
        XCTAssertFalse(files.isEmpty, "\(root.path)에 .hwpx가 없습니다")
        for file in files { try assertNoTextLoss(file) }
    }

    private func assertNoTextLoss(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let fragments = try TextProbe.fragments(ofHWPX: url)
        let document = try Converter.load(url).document

        let md = MarkdownExporter().export(document)
        let mdMissing = TextProbe.missing(fragments, in: md, markdown: true)
        XCTAssertTrue(mdMissing.isEmpty, "\(url.lastPathComponent) MD 유실: \(mdMissing.prefix(10))", file: file, line: line)

        let html = MarkdownExporter(options: MarkdownOptions(tableStyle: .html)).export(document)
        let htmlMissing = TextProbe.missing(fragments, in: Self.unescapeHTML(html), markdown: true)
        XCTAssertTrue(htmlMissing.isEmpty, "\(url.lastPathComponent) MD(html 표) 유실: \(htmlMissing.prefix(10))", file: file, line: line)

        let txt = TextExporter().export(document)
        let txtMissing = TextProbe.missing(fragments, in: txt, markdown: false)
        XCTAssertTrue(txtMissing.isEmpty, "\(url.lastPathComponent) TXT 유실: \(txtMissing.prefix(10))", file: file, line: line)

        let parts = try DocxExporter().parts(document, resources: nil)
        let body = String(decoding: parts.first { $0.path == "word/document.xml" }!.data, as: UTF8.self)
        let docxMissing = TextProbe.missing(fragments, in: DocxExporterTests.text(ofDocumentXML: body), markdown: false)
        XCTAssertTrue(docxMissing.isEmpty, "\(url.lastPathComponent) DOCX 유실: \(docxMissing.prefix(10))", file: file, line: line)
    }

    private static func unescapeHTML(_ text: String) -> String {
        // 익스포터가 만드는 태그만 지운다 (본문의 "<기업명>" 같은 글자는 남김)
        text.replacingOccurrences(of: "</?(table|tr|td|br|ul|ol|li|img)\\b[^>]*>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
