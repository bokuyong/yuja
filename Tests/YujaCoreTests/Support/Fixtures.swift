import Foundation
import ZIPFoundation

/// Tests/Fixtures/hwpx/<이름>/ 폴더(풀어 놓은 HWPX)를 테스트 때 .hwpx로 묶는다.
/// `_common/`의 파일이 기본이고, 픽스처 폴더의 같은 경로 파일이 덮어쓴다.
enum Fixtures {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Support
        .deletingLastPathComponent()  // YujaCoreTests
        .deletingLastPathComponent()  // Tests
        .appendingPathComponent("Fixtures")

    static var hwpxRoot: URL { root.appendingPathComponent("hwpx") }

    static var hwpxNames: [String] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: hwpxRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .filter { !$0.hasPrefix("_") }
            .sorted()
    }

    static func expectedURL(_ name: String, _ ext: String) -> URL {
        hwpxRoot.appendingPathComponent("\(name).expected.\(ext)")
    }

    static func makeHWPX(_ name: String, in directory: URL) throws -> URL {
        var files: [String: URL] = [:]
        for base in [hwpxRoot.appendingPathComponent("_common"), hwpxRoot.appendingPathComponent(name)] {
            for (path, url) in regularFiles(under: base) { files[path] = url }
        }
        return try zip(files, to: directory.appendingPathComponent("\(name).hwpx"))
    }

    /// 경로 → 파일. mimetype이 있으면 첫 엔트리·무압축으로 넣는다 (HWPX 규칙).
    static func zip(_ files: [String: URL], to output: URL) throws -> URL {
        try? FileManager.default.removeItem(at: output)
        let archive = try Archive(url: output, accessMode: .create)
        let ordered = files.keys.sorted { a, b in a == "mimetype" ? b != "mimetype" : (b == "mimetype" ? false : a < b) }
        for path in ordered {
            let data = try Data(contentsOf: files[path]!)
            try archive.addEntry(
                with: path, type: .file, uncompressedSize: Int64(data.count),
                compressionMethod: path == "mimetype" ? .none : .deflate,
                provider: { position, size in data.subdata(in: Int(position)..<Int(position) + size) }
            )
        }
        return output
    }

    static func regularFiles(under base: URL) -> [(String, URL)] {
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        let prefix = base.resolvingSymlinksInPath().path + "/"
        var out: [(String, URL)] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  url.lastPathComponent != ".DS_Store" else { continue }
            let full = url.resolvingSymlinksInPath().path
            guard full.hasPrefix(prefix) else { continue }
            out.append((String(full.dropFirst(prefix.count)), url))
        }
        return out
    }

    static func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("yuja-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
