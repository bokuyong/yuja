import Foundation

public enum SourceFormat: String, Equatable, Sendable {
    case hwpx
    case hwp5
}

public enum Detect {
    static let zipMagic: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
    static let cfbMagic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
    static let hwp3Magic = Array("HWP Document File V3".utf8)

    /// 매직넘버를 우선 보고, 확장자는 보조로만 사용한다.
    public static func format(of url: URL) throws -> SourceFormat {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw YujaError.fileNotFound(url.path)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 32) ?? Data()
        return try format(ofHead: head, pathExtension: url.pathExtension)
    }

    public static func format(ofHead head: Data, pathExtension: String = "") throws -> SourceFormat {
        let bytes = [UInt8](head)
        if bytes.starts(with: cfbMagic) { return .hwp5 }
        // HWPX는 ZIP이지만 DOCX 등 다른 ZIP과 구분하려면 mimetype 엔트리 확인이 필요하다.
        // Phase 1에서 ZIP을 열 때 검증하고, 여기서는 확장자로 1차 판별한다.
        if bytes.starts(with: zipMagic) {
            if pathExtension.isEmpty || pathExtension.lowercased() == "hwpx" { return .hwpx }
            throw YujaError.unsupportedFormat("ZIP 파일이지만 확장자가 .\(pathExtension)입니다")
        }
        if bytes.starts(with: hwp3Magic) { throw YujaError.legacyHWP3 }
        throw YujaError.unsupportedFormat("HWP/HWPX 파일이 아닙니다")
    }
}
