import Foundation

public enum YujaError: Error, Equatable, LocalizedError {
    case fileNotFound(String)
    case unsupportedFormat(String)
    case encrypted
    case drmProtected
    case legacyHWP3
    case corrupted(String)
    case notImplemented(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "파일을 찾을 수 없습니다: \(path)"
        case .unsupportedFormat(let detail):
            return "지원하지 않는 파일 형식입니다: \(detail)"
        case .encrypted:
            return "암호가 걸린 문서는 변환할 수 없습니다."
        case .drmProtected:
            return "DRM·공인인증서로 보호된 문서는 변환할 수 없습니다."
        case .legacyHWP3:
            return "HWP 3.x 이하 구버전 문서는 지원하지 않습니다."
        case .corrupted(let detail):
            return "문서가 손상되었거나 읽을 수 없습니다: \(detail)"
        case .notImplemented(let feature):
            return "아직 구현되지 않은 기능입니다: \(feature)"
        case .writeFailed(let path):
            return "파일을 저장할 수 없습니다: \(path)"
        }
    }
}
