import XCTest
@testable import YujaCore

/// 픽스처마다 기대 출력(<이름>.expected.md / .txt)과 비교한다.
/// 기대 출력을 갱신하려면: YUJA_UPDATE_GOLDEN=1 swift test --filter GoldenTests
final class GoldenTests: XCTestCase {
    static let update = ProcessInfo.processInfo.environment["YUJA_UPDATE_GOLDEN"] == "1"

    func testFixturesMatchExpectedOutput() throws {
        let names = Fixtures.hwpxNames
        XCTAssertFalse(names.isEmpty, "픽스처가 없습니다: \(Fixtures.hwpxRoot.path)")
        let tmp = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }

        for name in names {
            let input = try Fixtures.makeHWPX(name, in: tmp)
            for format in [OutputFormat.md, .txt] {
                let output = tmp.appendingPathComponent("\(name).\(format.fileExtension)")
                try Converter.convert(input: input, output: output, options: ConvertOptions(format: format))
                let actual = try String(contentsOf: output, encoding: .utf8)
                let expectedURL = Fixtures.expectedURL(name, format.fileExtension)

                if Self.update {
                    try actual.write(to: expectedURL, atomically: true, encoding: .utf8)
                    continue
                }
                let expected = try String(contentsOf: expectedURL, encoding: .utf8)
                XCTAssertEqual(actual, expected, "\(name).\(format.fileExtension) 기대 출력과 다름")
            }
        }
    }

    func testImagesAreExtractedOncePerSourceAndBMPBecomesPNG() throws {
        let tmp = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let input = try Fixtures.makeHWPX("images", in: tmp)

        let result = try Converter.convert(input: input, output: tmp.appendingPathComponent("images.md"))
        XCTAssertEqual(result.assets.map(\.lastPathComponent), ["img_1.png", "img_2.png"])

        let converted = try Data(contentsOf: result.assets[1])
        XCTAssertEqual(Array(converted.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "BMP가 PNG로 변환되지 않음")
    }

    func testNoAssetsDirectoryWhenDocumentHasNoImages() throws {
        let tmp = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let input = try Fixtures.makeHWPX("paragraphs", in: tmp)

        let output = tmp.appendingPathComponent("paragraphs.md")
        try Converter.convert(input: input, output: output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Converter.defaultAssetsURL(for: output).path))
    }

    func testMetadataIsRead() throws {
        let tmp = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let document = try Converter.load(Fixtures.makeHWPX("paragraphs", in: tmp)).document
        XCTAssertEqual(document.meta.title, "유자 테스트 문서")
        XCTAssertEqual(document.meta.author, "Yuja")
        XCTAssertEqual(document.meta.sourceFormat, .hwpx)
    }

    func testZipWithForeignMimetypeIsRejected() throws {
        let tmp = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let mime = tmp.appendingPathComponent("mime")
        try "application/epub+zip".write(to: mime, atomically: true, encoding: .utf8)
        let input = try Fixtures.zip(["mimetype": mime], to: tmp.appendingPathComponent("book.hwpx"))

        XCTAssertThrowsError(try Converter.load(input)) { error in
            guard case .unsupportedFormat = error as? YujaError else { return XCTFail("\(error)") }
        }
    }
}
