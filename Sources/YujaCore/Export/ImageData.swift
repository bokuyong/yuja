import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 익스포터 공통 이미지 처리.
enum ImageData {
    /// 웹·오피스에서 그대로 쓸 수 있는 형식
    static let passthrough: Set<String> = ["png", "jpg", "jpeg", "gif"]

    /// PNG/JPEG/GIF는 그대로, 나머지(BMP 등)는 PNG로. 변환이 안 되면 원본 그대로.
    static func normalized(_ data: Data, sourceID: String) -> (data: Data, ext: String) {
        let ext = (sourceID as NSString).pathExtension.lowercased()
        if passthrough.contains(ext) { return (data, ext == "jpeg" ? "jpg" : ext) }
        if let png = convertToPNG(data) { return (png, "png") }
        return (data, ext.isEmpty ? "bin" : ext)
    }

    static func pixelSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0 else { return nil }
        return (w, h)
    }

    static func convertToPNG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
