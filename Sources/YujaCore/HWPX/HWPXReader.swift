import Foundation

public enum HWPXReader {
    public static func read(_ url: URL) throws -> LoadedDocument {
        let package = try HWPXPackage(url: url)

        let styles: HeaderStyles
        if let header = try package.entry("Contents/header.xml") {
            styles = try HeaderStyles.parse(header)
        } else {
            styles = HeaderStyles()
        }

        let paths = package.sectionPaths()
        guard !paths.isEmpty else {
            throw YujaError.corrupted("본문 섹션(Contents/section0.xml)이 없습니다")
        }

        let parser = SectionParser(
            styles: styles,
            binaryItems: package.manifest.items.mapValues(\.href)
        )
        let sections = try paths.map { path -> Section in
            guard let data = try package.entry(path) else {
                throw YujaError.corrupted("\(path)를 읽을 수 없습니다")
            }
            return try parser.parse(data)
        }

        let meta = Meta(title: package.manifest.title, author: package.manifest.author, sourceFormat: .hwpx)
        return LoadedDocument(document: Document(meta: meta, sections: sections), resources: package)
    }
}
