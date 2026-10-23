import Foundation

// 중간 표현(IR). 모든 파서(HWPX, HWP5)는 이 타입으로 변환하고,
// 모든 익스포터(MD, TXT, DOCX, PDF)는 이 타입만 소비한다.

public struct Document: Equatable, Sendable {
    public var meta: Meta
    public var sections: [Section]

    public init(meta: Meta = Meta(), sections: [Section] = []) {
        self.meta = meta
        self.sections = sections
    }
}

public struct Meta: Equatable, Sendable {
    public var title: String?
    public var author: String?
    public var sourceFormat: SourceFormat?

    public init(title: String? = nil, author: String? = nil, sourceFormat: SourceFormat? = nil) {
        self.title = title
        self.author = author
        self.sourceFormat = sourceFormat
    }
}

public struct Section: Equatable, Sendable {
    public var blocks: [Block]

    public init(blocks: [Block] = []) {
        self.blocks = blocks
    }
}

public indirect enum Block: Equatable, Sendable {
    case heading(level: Int, runs: [Run])
    case paragraph(runs: [Run], align: Align?)
    case list(items: [[Block]], ordered: Bool)
    case table(Table)
    case image(ImageRef)
    case pageBreak
    /// 해석하지 못한 요소. 텍스트만이라도 유실 없이 보존한다.
    case raw(String)
}

public enum Align: String, Equatable, Sendable {
    case left, center, right, justify
}

public struct Run: Equatable, Sendable {
    public var text: String
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var strike: Bool

    public init(_ text: String, bold: Bool = false, italic: Bool = false, underline: Bool = false, strike: Bool = false) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strike = strike
    }
}

public struct Table: Equatable, Sendable {
    public var rows: [[Cell]]

    public init(rows: [[Cell]] = []) {
        self.rows = rows
    }
}

public struct Cell: Equatable, Sendable {
    public var blocks: [Block]
    public var colSpan: Int
    public var rowSpan: Int

    public init(blocks: [Block] = [], colSpan: Int = 1, rowSpan: Int = 1) {
        self.blocks = blocks
        self.colSpan = colSpan
        self.rowSpan = rowSpan
    }
}

public struct ImageRef: Equatable, Sendable {
    /// 원본 컨테이너 안의 식별자 (HWPX: BinData 경로, HWP5: BinData 스트림 이름)
    public var sourceID: String
    /// 추출 후 저장된 상대 경로 (`<출력파일명>_assets/img_N.png`). 추출 전이면 nil.
    public var path: String?
    public var altText: String?

    public init(sourceID: String, path: String? = nil, altText: String? = nil) {
        self.sourceID = sourceID
        self.path = path
        self.altText = altText
    }
}

// MARK: - 텍스트 수집 (유실 0 검사용)

extension Document {
    /// 문서에 포함된 모든 텍스트를 순서대로 모은다. "텍스트 유실 0" 테스트의 기준값.
    public var plainTextFragments: [String] {
        sections.flatMap { $0.blocks.flatMap(\.plainTextFragments) }
    }
}

extension Block {
    public var plainTextFragments: [String] {
        switch self {
        case .heading(_, let runs), .paragraph(let runs, _):
            return runs.map(\.text)
        case .list(let items, _):
            return items.flatMap { $0.flatMap(\.plainTextFragments) }
        case .table(let table):
            return table.rows.flatMap { $0.flatMap { $0.blocks.flatMap(\.plainTextFragments) } }
        case .image(let ref):
            return ref.altText.map { [$0] } ?? []
        case .pageBreak:
            return []
        case .raw(let text):
            return [text]
        }
    }
}
