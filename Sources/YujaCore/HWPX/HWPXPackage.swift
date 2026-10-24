import Foundation
import ZIPFoundation

/// HWPX ZIP 컨테이너. 엔트리 단위로 꺼내 읽는다.
final class HWPXPackage: ResourceProvider {
    static let mimetype = "application/hwp+zip"

    private let archive: Archive
    let manifest: ContentManifest

    init(url: URL) throws {
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw YujaError.corrupted("ZIP 컨테이너를 열 수 없습니다")
        }

        if let mime = try Self.read(archive, "mimetype").flatMap({ String(data: $0, encoding: .utf8) }),
           mime.trimmingCharacters(in: .whitespacesAndNewlines) != Self.mimetype {
            throw YujaError.unsupportedFormat("HWPX가 아닌 ZIP 파일입니다 (mimetype: \(mime))")
        }

        if let hpf = try Self.read(archive, "Contents/content.hpf") {
            manifest = try ContentManifest.parse(hpf)
        } else {
            manifest = ContentManifest()
        }
    }

    func entry(_ path: String) throws -> Data? {
        try Self.read(archive, path)
    }

    /// 본문 섹션 경로를 순서대로. spine을 우선하고, 없으면 파일명 번호순.
    func sectionPaths() -> [String] {
        let fromSpine = manifest.spine.compactMap { manifest.items[$0]?.href }
            .filter { Self.isSectionPath($0) }
        if !fromSpine.isEmpty { return fromSpine }

        return archive.map(\.path)
            .filter { Self.isSectionPath($0) }
            .sorted { Self.sectionNumber($0) < Self.sectionNumber($1) }
    }

    // MARK: ResourceProvider

    func data(for sourceID: String) throws -> Data {
        guard let data = try entry(sourceID) else {
            throw YujaError.corrupted("내장 파일이 없습니다: \(sourceID)")
        }
        return data
    }

    // MARK: -

    private static func read(_ archive: Archive, _ path: String) throws -> Data? {
        guard let entry = archive[path] else { return nil }
        var out = Data()
        out.reserveCapacity(Int(entry.uncompressedSize))
        do {
            _ = try archive.extract(entry) { out.append($0) }
        } catch {
            throw YujaError.corrupted("\(path) 압축을 풀 수 없습니다")
        }
        return out
    }

    private static func isSectionPath(_ path: String) -> Bool {
        path.hasPrefix("Contents/section") && path.hasSuffix(".xml")
    }

    private static func sectionNumber(_ path: String) -> Int {
        Int(path.dropFirst("Contents/section".count).dropLast(".xml".count)) ?? Int.max
    }
}

/// Contents/content.hpf (OPF 패키지 문서)
struct ContentManifest {
    struct Item { var href: String; var mediaType: String? }

    var title: String?
    var author: String?
    var items: [String: Item] = [:]
    var spine: [String] = []

    static func parse(_ data: Data) throws -> ContentManifest {
        let delegate = ManifestDelegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse() else {
            throw YujaError.corrupted("content.hpf를 해석할 수 없습니다")
        }
        return delegate.manifest
    }
}

private final class ManifestDelegate: NSObject, XMLParserDelegate {
    var manifest = ContentManifest()
    private var capture: String?
    private var captureKey: String?

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        switch name {
        case "item":
            if let id = attributes["id"], let href = attributes["href"] {
                manifest.items[id] = .init(href: href, mediaType: attributes["media-type"])
            }
        case "itemref":
            if let idref = attributes["idref"] { manifest.spine.append(idref) }
        case "title":
            capture = ""; captureKey = "title"
        case "meta" where attributes["name"] == "creator":
            capture = ""; captureKey = "creator"
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        capture? += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard let text = capture, name == "title" || name == "meta" else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
            if captureKey == "title" { manifest.title = value } else { manifest.author = value }
        }
        capture = nil
        captureKey = nil
    }
}
