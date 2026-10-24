import Foundation
import ImageIO
import UniformTypeIdentifiers

/// IR의 이미지를 `img_N.<ext>`로 꺼내고 ImageRef.path를 채운다.
/// PNG/JPEG/GIF는 그대로, BMP 등 웹에서 못 쓰는 형식은 PNG로 바꾼다.
enum AssetExtractor {
    static let passthrough: Set<String> = ["png", "jpg", "jpeg", "gif"]

    struct Result {
        var document: Document
        var files: [URL]
    }

    static func extract(_ document: Document, from resources: ResourceProvider,
                        into directory: URL, linkBase: String) throws -> Result {
        var state = State(resources: resources, directory: directory, linkBase: linkBase)
        var document = document
        for i in document.sections.indices {
            document.sections[i].blocks = try document.sections[i].blocks.map { try state.visit($0) }
        }
        return Result(document: document, files: state.files)
    }

    private struct State {
        let resources: ResourceProvider
        let directory: URL
        let linkBase: String
        var files: [URL] = []
        var cache: [String: String] = [:]

        mutating func visit(_ block: Block) throws -> Block {
            switch block {
            case .image(var ref):
                ref.path = try write(ref.sourceID)
                return .image(ref)
            case .list(let items, let ordered):
                return .list(items: try items.map { try $0.map { try visit($0) } }, ordered: ordered)
            case .table(var table):
                for r in table.rows.indices {
                    for c in table.rows[r].indices {
                        table.rows[r][c].blocks = try table.rows[r][c].blocks.map { try visit($0) }
                    }
                }
                return .table(table)
            default:
                return block
            }
        }

        mutating func write(_ sourceID: String) throws -> String {
            if let done = cache[sourceID] { return done }

            let data = try resources.data(for: sourceID)
            let ext = (sourceID as NSString).pathExtension.lowercased()
            let index = files.count + 1

            let (bytes, outExt): (Data, String)
            if passthrough.contains(ext) {
                (bytes, outExt) = (data, ext)
            } else if let png = Self.convertToPNG(data) {
                (bytes, outExt) = (png, "png")
            } else {
                (bytes, outExt) = (data, ext.isEmpty ? "bin" : ext)
            }

            let name = "img_\(index).\(outExt)"
            let url = directory.appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try bytes.write(to: url)
            } catch {
                throw YujaError.writeFailed(url.path)
            }

            files.append(url)
            let link = linkBase.isEmpty ? name : linkBase + "/" + name
            cache[sourceID] = link
            return link
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
}
