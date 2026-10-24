import Foundation

/// 원본 컨테이너 안의 내장 파일(이미지 등)을 꺼내 준다.
public protocol ResourceProvider {
    func data(for sourceID: String) throws -> Data
}

public struct LoadedDocument {
    public var document: Document
    public var resources: ResourceProvider

    public init(document: Document, resources: ResourceProvider) {
        self.document = document
        self.resources = resources
    }
}

public enum OutputFormat: String, CaseIterable, Sendable {
    case md, txt, docx, pdf

    public var fileExtension: String { rawValue }
}

public struct ConvertOptions {
    public var format: OutputFormat
    public var markdown: MarkdownOptions
    public var extractImages: Bool

    public init(format: OutputFormat = .md, markdown: MarkdownOptions = MarkdownOptions(), extractImages: Bool = true) {
        self.format = format
        self.markdown = markdown
        self.extractImages = extractImages
    }
}

public struct ConvertResult {
    public var output: URL
    public var assets: [URL]
}

public enum Converter {
    public static func load(_ url: URL) throws -> LoadedDocument {
        switch try Detect.format(of: url) {
        case .hwpx: return try HWPXReader.read(url)
        case .hwp5: return try HWP5Reader.read(url)
        }
    }

    /// 기본 출력 경로: 원본 옆, 확장자만 교체.
    public static func defaultOutputURL(for input: URL, format: OutputFormat) -> URL {
        input.deletingPathExtension().appendingPathExtension(format.fileExtension)
    }

    /// 이미지 폴더 기본값: `<출력파일명>_assets` (출력 파일 옆)
    public static func defaultAssetsURL(for output: URL) -> URL {
        output.deletingLastPathComponent()
            .appendingPathComponent(output.deletingPathExtension().lastPathComponent + "_assets", isDirectory: true)
    }

    @discardableResult
    public static func convert(input: URL, output: URL? = nil, assetsDirectory: URL? = nil,
                               options: ConvertOptions = ConvertOptions()) throws -> ConvertResult {
        let output = output ?? defaultOutputURL(for: input, format: options.format)
        let loaded = try load(input)
        var document = loaded.document
        var assets: [URL] = []

        if options.extractImages && (options.format == .md || options.format == .txt) {
            let dir = assetsDirectory ?? defaultAssetsURL(for: output)
            let extracted = try AssetExtractor.extract(
                document, from: loaded.resources, into: dir,
                linkBase: relativePath(from: output.deletingLastPathComponent(), to: dir)
            )
            document = extracted.document
            assets = extracted.files
        }

        let text: String
        switch options.format {
        case .md: text = MarkdownExporter(options: options.markdown).export(document)
        case .txt: text = TextExporter().export(document)
        case .docx:
            // 이미지는 파일 안(word/media)에 들어가므로 따로 꺼내지 않는다.
            // extractImages가 꺼져 있으면 자리표시 문단으로 대신한다.
            try DocxExporter().write(document, resources: options.extractImages ? loaded.resources : nil, to: output)
            return ConvertResult(output: output, assets: [])
        case .pdf: throw YujaError.notImplemented("PDF 출력 (Phase 4 예정)")
        }

        do {
            try text.write(to: output, atomically: true, encoding: .utf8)
        } catch {
            throw YujaError.writeFailed(output.path)
        }
        return ConvertResult(output: output, assets: assets)
    }

    /// 링크용 상대 경로. 출력 폴더 아래가 아니면 절대 경로를 쓴다.
    static func relativePath(from base: URL, to target: URL) -> String {
        // /tmp → /private/tmp 같은 심볼릭 링크 차이를 없애고 비교한다.
        let basePath = base.resolvingSymlinksInPath().path
        // 이미지 폴더는 아직 없을 수 있으므로 부모 폴더 기준으로 푼다.
        let targetPath = target.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(target.lastPathComponent).path
        let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        if targetPath.hasPrefix(prefix) { return String(targetPath.dropFirst(prefix.count)) }
        return targetPath
    }
}
