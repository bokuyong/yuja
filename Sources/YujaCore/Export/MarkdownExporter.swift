import Foundation

public struct MarkdownOptions: Sendable {
    public enum TableStyle: String, CaseIterable, Sendable {
        /// GFM 표. 병합 셀은 덮인 칸을 빈 칸으로 채워 평탄화한다.
        case gfm
        /// 병합을 colspan/rowspan으로 보존하는 HTML `<table>`
        case html
    }

    public var tableStyle: TableStyle
    /// GFM 표에서 병합 셀 원래 칸에 `(↔2)` `(↕3)` 표기를 붙인다.
    public var spanMarks: Bool

    public init(tableStyle: TableStyle = .gfm, spanMarks: Bool = false) {
        self.tableStyle = tableStyle
        self.spanMarks = spanMarks
    }
}

/// IR → Markdown (GFM). LLM 입력용이라 불필요한 이스케이프·공백은 줄인다.
///
/// - 강조(굵게·기울임·취소선)는 본문 문단에만 쓴다. 제목·표 셀에서는 생략.
/// - 1×1 표(제목 상자)는 표를 벗기고 내용만 낸다.
/// - 쪽 나눔은 출력하지 않는다.
public struct MarkdownExporter {
    public var options: MarkdownOptions

    public init(options: MarkdownOptions = MarkdownOptions()) {
        self.options = options
    }

    public func export(_ document: Document) -> String {
        let chunks = document.sections.flatMap { render($0.blocks) }
        return chunks.isEmpty ? "" : chunks.joined(separator: "\n\n") + "\n"
    }

    // MARK: 블록

    func render(_ blocks: [Block]) -> [String] {
        blocks.compactMap(render)
    }

    func render(_ block: Block) -> String? {
        switch block {
        case .heading(let level, let runs):
            let text = Self.normalizeLines(inline(runs, emphasis: false)).joined(separator: " ")
            guard !text.isEmpty else { return nil }
            return String(repeating: "#", count: max(1, min(level, 6))) + " " + text

        case .paragraph(let runs, _):
            guard runs.hasVisibleText else { return nil }
            return Self.blockText(inline(runs, emphasis: true))

        case .list(let items, let ordered):
            return list(items, ordered: ordered)

        case .table(let table):
            if let cell = table.singleCell {
                let inner = render(cell.blocks)
                return inner.isEmpty ? nil : inner.joined(separator: "\n\n")
            }
            guard !table.rows.isEmpty else { return nil }
            return options.tableStyle == .html ? htmlTable(table) : gfmTable(table)

        case .image(let ref):
            return Self.image(ref)

        case .pageBreak:
            return nil

        case .raw(let text):
            guard text.contains(where: { !$0.isWhitespace }) else { return nil }
            return Self.blockText(Self.escape(text, escapeTilde: Self.hasTildePair(text)))
        }
    }

    private func list(_ items: [[Block]], ordered: Bool) -> String? {
        var out: [String] = []
        var number = 0
        for item in items {
            let body = render(item).joined(separator: "\n")
            guard !body.isEmpty else { continue }
            number += 1
            let marker = ordered ? "\(number). " : "- "
            let indent = String(repeating: " ", count: marker.count)
            let lines = body.components(separatedBy: "\n")
            out.append(([marker + lines[0]] + lines.dropFirst().map { $0.isEmpty ? $0 : indent + $0 })
                .joined(separator: "\n"))
        }
        return out.isEmpty ? nil : out.joined(separator: "\n")
    }

    // MARK: 표 (GFM)

    private func gfmTable(_ table: Table) -> String? {
        let grid = TableGrid(table)
        guard grid.columnCount > 0 else { return nil }

        let rows: [[String]] = grid.slots.map { row in
            row.map { slot in
                guard case .cell(let cell) = slot else { return "" }
                var text = cellText(cell.blocks)
                if options.spanMarks {
                    var marks: [String] = []
                    if cell.colSpan > 1 { marks.append("(↔\(cell.colSpan))") }
                    if cell.rowSpan > 1 { marks.append("(↕\(cell.rowSpan))") }
                    if !marks.isEmpty { text += (text.isEmpty ? "" : " ") + marks.joined(separator: " ") }
                }
                return text
            }
        }

        func line(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |" }
        var lines = [line(rows[0]), line(Array(repeating: "---", count: grid.columnCount))]
        lines += rows.dropFirst().map(line)
        return lines.joined(separator: "\n")
    }

    /// 표 셀 한 칸에 들어갈 한 줄짜리 Markdown. 줄바꿈은 `<br>`.
    private func cellText(_ blocks: [Block]) -> String {
        var pieces: [String] = []
        for block in blocks {
            switch block {
            case .heading(_, let runs), .paragraph(let runs, _):
                let lines = Self.normalizeLines(inline(runs, emphasis: false))
                if !lines.isEmpty { pieces.append(lines.joined(separator: "<br>")) }
            case .list(let items, let ordered):
                for (i, item) in items.enumerated() {
                    let text = cellText(item)
                    if !text.isEmpty { pieces.append((ordered ? "\(i + 1). " : "• ") + text) }
                }
            case .table(let nested):
                if let cell = nested.singleCell {
                    let text = cellText(cell.blocks)
                    if !text.isEmpty { pieces.append(text) }
                } else {
                    for row in TableGrid(nested).slots {
                        let cells = row.compactMap { slot -> String? in
                            guard case .cell(let cell) = slot else { return nil }
                            let text = cellText(cell.blocks)
                            return text.isEmpty ? nil : text
                        }
                        if !cells.isEmpty { pieces.append(cells.joined(separator: " / ")) }
                    }
                }
            case .image(let ref):
                pieces.append(Self.image(ref))
            case .raw(let text):
                let lines = Self.normalizeLines(Self.escape(text, escapeTilde: Self.hasTildePair(text)))
                if !lines.isEmpty { pieces.append(lines.joined(separator: "<br>")) }
            case .pageBreak:
                break
            }
        }
        return pieces.joined(separator: "<br>").replacingOccurrences(of: "|", with: "\\|")
    }

    // MARK: 표 (HTML)

    private func htmlTable(_ table: Table) -> String {
        var lines = ["<table>"]
        for row in table.rows {
            let cells = row.map { cell -> String in
                var attrs = ""
                if cell.colSpan > 1 { attrs += " colspan=\"\(cell.colSpan)\"" }
                if cell.rowSpan > 1 { attrs += " rowspan=\"\(cell.rowSpan)\"" }
                return "<td\(attrs)>\(cellHTML(cell.blocks))</td>"
            }
            lines.append("<tr>" + cells.joined() + "</tr>")
        }
        lines.append("</table>")
        return lines.joined(separator: "\n")
    }

    private func cellHTML(_ blocks: [Block]) -> String {
        var pieces: [String] = []
        for block in blocks {
            switch block {
            case .heading(_, let runs), .paragraph(let runs, _):
                let lines = Self.normalizeLines(Self.htmlEscape(runs.text))
                if !lines.isEmpty { pieces.append(lines.joined(separator: "<br>")) }
            case .list(let items, let ordered):
                let tag = ordered ? "ol" : "ul"
                let lis = items.map { "<li>\(cellHTML($0))</li>" }.joined()
                if !items.isEmpty { pieces.append("<\(tag)>\(lis)</\(tag)>") }
            case .table(let nested):
                if let cell = nested.singleCell {
                    let html = cellHTML(cell.blocks)
                    if !html.isEmpty { pieces.append(html) }
                } else {
                    pieces.append(htmlTable(nested).replacingOccurrences(of: "\n", with: ""))
                }
            case .image(let ref):
                let src = Self.htmlEscape(ref.path ?? ref.sourceID)
                pieces.append("<img src=\"\(src)\" alt=\"\(Self.htmlEscape(ref.altText ?? ""))\">")
            case .raw(let text):
                let lines = Self.normalizeLines(Self.htmlEscape(text))
                if !lines.isEmpty { pieces.append(lines.joined(separator: "<br>")) }
            case .pageBreak:
                break
            }
        }
        return pieces.joined(separator: "<br>")
    }

    // MARK: 인라인

    /// 런 목록 → 인라인 Markdown. 줄바꿈(\n)은 그대로 남긴다.
    func inline(_ runs: [Run], emphasis: Bool) -> String {
        let escapeTilde = Self.hasTildePair(runs.text)

        // 같은 강조끼리 합친다 (밑줄은 Markdown에 없으므로 무시).
        var merged: [Run] = []
        for run in runs {
            if let last = merged.last, last.bold == run.bold, last.italic == run.italic, last.strike == run.strike {
                merged[merged.count - 1].text += run.text
            } else {
                merged.append(run)
            }
        }

        return merged.map { run in
            let text = Self.escape(run.text, escapeTilde: escapeTilde)
            guard emphasis, run.bold || run.italic || run.strike, run.hasVisibleText else { return text }
            let open = (run.strike ? "~~" : "") + (run.bold && run.italic ? "***" : run.bold ? "**" : run.italic ? "*" : "")
            let close = String(open.reversed())
            return text.components(separatedBy: "\n").map { line in
                let lead = line.prefix { $0.isWhitespace }
                let trail = line.reversed().prefix { $0.isWhitespace }
                guard lead.count < line.count else { return line }
                let core = line.dropFirst(lead.count).dropLast(trail.count)
                return lead + open + core + close + String(trail.reversed())
            }.joined(separator: "\n")
        }.joined()
    }

    // MARK: 텍스트 정리·이스케이프

    /// 줄 단위로 앞뒤 공백 제거, 탭·연속 공백을 한 칸으로, 빈 줄 제거.
    static func normalizeLines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").compactMap { raw in
            var line = raw.replacingOccurrences(of: "\t", with: " ")
            while line.contains("  ") { line = line.replacingOccurrences(of: "  ", with: " ") }
            line = line.trimmingCharacters(in: .whitespaces)
            return line.isEmpty ? nil : line
        }
    }

    /// 문단 본문: 줄을 정리하고 줄 머리에서 블록 문법으로 오인될 것만 막는다.
    static func blockText(_ text: String) -> String? {
        let lines = normalizeLines(text).map(escapeLineStart)
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    static func escapeLineStart(_ line: String) -> String {
        // ATX 제목: "# ", "## " …
        let hashes = line.prefix { $0 == "#" }.count
        if (1...6).contains(hashes) {
            let rest = line.dropFirst(hashes)
            if rest.isEmpty || rest.first == " " { return "\\" + line }
        }
        // 인용
        if line.hasPrefix(">") { return "\\" + line }
        // 수평선 / setext 밑줄: "---", "===", "***", "___"
        let compact = line.filter { $0 != " " }
        if let first = compact.first, "-=*_".contains(first), compact.allSatisfy({ $0 == first }) {
            // '-'·'='는 한 글자로도 setext 밑줄이 되고, '*'·'_'는 3개 이상이어야 수평선
            if first == "-" || first == "=" || compact.count >= 3 { return "\\" + line }
        }
        return line
    }

    /// 인라인 이스케이프. 한국어 문서에 흔한 기호(~, ___, [ ])는 실제로 문법이 될 때만 막는다.
    static func escape(_ text: String, escapeTilde: Bool) -> String {
        let chars = Array(text)
        var out = ""
        out.reserveCapacity(chars.count)
        for (i, ch) in chars.enumerated() {
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            switch ch {
            case "\\", "`", "*":
                out.append("\\")
            case "_":
                // 빈칸 채우기용 밑줄(___ 이상)은 강조가 될 수 없으므로 그대로 둔다.
                if underscoreRunLength(chars, at: i) < 3 { out.append("\\") }
            case "~" where escapeTilde:
                out.append("\\")
            case "]" where next == "(" || next == "[":
                out.append("\\")
            case "<":
                if let n = next, n.isASCII && (n.isLetter || n == "/" || n == "!" || n == "?") { out.append("\\") }
            default:
                break
            }
            out.append(ch)
        }
        return out
    }

    private static func underscoreRunLength(_ chars: [Character], at index: Int) -> Int {
        var start = index, end = index
        while start > 0 && chars[start - 1] == "_" { start -= 1 }
        while end + 1 < chars.count && chars[end + 1] == "_" { end += 1 }
        return end - start + 1
    }

    /// "10~20" 처럼 물결이 하나뿐이면 취소선이 될 수 없으므로 이스케이프하지 않는다.
    static func hasTildePair(_ text: String) -> Bool {
        text.filter { $0 == "~" }.count >= 2
    }

    static func image(_ ref: ImageRef) -> String {
        guard let path = ref.path else {
            return "[이미지: \(escape(ref.sourceID, escapeTilde: false))]"
        }
        let alt = escape(ref.altText ?? "", escapeTilde: false)
        let needsBrackets = path.contains { " ()<>".contains($0) }
        return "![\(alt)](\(needsBrackets ? "<\(path)>" : path))"
    }

    static func htmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
