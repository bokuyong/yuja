import XCTest
@testable import YujaCore

final class DetectTests: XCTestCase {
    func testCFBHeaderIsHWP5() throws {
        let head = Data(Detect.cfbMagic + [UInt8](repeating: 0, count: 24))
        XCTAssertEqual(try Detect.format(ofHead: head, pathExtension: "hwp"), .hwp5)
    }

    func testZipHeaderWithHWPXExtensionIsHWPX() throws {
        let head = Data(Detect.zipMagic + [UInt8](repeating: 0, count: 28))
        XCTAssertEqual(try Detect.format(ofHead: head, pathExtension: "hwpx"), .hwpx)
    }

    func testZipHeaderWithOtherExtensionIsRejected() {
        let head = Data(Detect.zipMagic)
        XCTAssertThrowsError(try Detect.format(ofHead: head, pathExtension: "docx"))
    }

    func testHWP3IsRejectedWithClearError() {
        let head = Data(Detect.hwp3Magic)
        XCTAssertThrowsError(try Detect.format(ofHead: head)) { error in
            XCTAssertEqual(error as? YujaError, .legacyHWP3)
        }
    }

    func testMissingFileThrowsFileNotFound() {
        let url = URL(fileURLWithPath: "/nonexistent/없는파일.hwpx")
        XCTAssertThrowsError(try Detect.format(of: url)) { error in
            XCTAssertEqual(error as? YujaError, .fileNotFound(url.path))
        }
    }
}
