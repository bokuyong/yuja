import Foundation

/// IR → 일반 텍스트. 서식은 버리고, 표는 행마다 탭으로 칸을 나눈다.
public struct TextExporter {
    public init() {}

    public func export(_ document: Document) -> String {
        var out: [String] = []
        var lastWasBlockish = false

        for block in document.sections.flatMap(\.blocks) {
            guard let (text, blockish) = render(block, depth: 0) else { continue }
            // 제목·표 앞뒤로 빈 줄을 하나 둔다.
            if !out.isEmpty && (blockish || lastWasBlockish) { out.append("") }
            out.append(text)
            lastWasBlockish = blockish
        }
        return out.isEmpty ? "" : out.joined(separator: "\n") + "\n"
    }

    /// (텍스트, 앞뒤로 빈 줄이 필요한 블록인지)
    private func render(_ block: Block, depth: Int) -> (String, Bool)? {
        switch block {
        case .heading(_, let runs):
            let text = Self.clean(runs.text).replacingOccurrences(of: "\n", with: " ")
            return text.isEmpty ? nil : (text, true)

        case .paragraph(let runs, _):
            let text = Self.clean(runs.text)
            return text.isEmpty ? nil : (text, false)

        case .list(let items, let ordered):
            let indent = String(repeating: "  ", count: depth)
            var lines: [String] = []
            var number = 0
            for item in items {
                var first = true
                for child in item {
                    if case .list = child {
                        if let (text, _) = render(child, depth: depth + 1) { lines.append(text) }
                        continue
                    }
                    guard let (text, _) = render(child, depth: depth) else { continue }
                    if first {
                        number += 1
                        lines.append(indent + (ordered ? "\(number). " : "- ") + text)
                        first = false
                    } else {
                        lines.append(indent + "  " + text)
                    }
                }
            }
            return lines.isEmpty ? nil : (lines.joined(separator: "\n"), false)

        case .table(let table):
            if let cell = table.singleCell {
                let inner = cell.blocks.compactMap { render($0, depth: depth)?.0 }
                return inner.isEmpty ? nil : (inner.joined(separator: "\n"), true)
            }
            let rows = TableGrid(table).slots.map { row in
                row.map { slot -> String in
                    guard case .cell(let cell) = slot else { return "" }
                    return Self.flatten(cell.blocks)
                }.joined(separator: "\t")
            }
            return rows.isEmpty ? nil : (rows.joined(separator: "\n"), true)

        case .image(let ref):
            return ("[이미지: \(ref.path ?? ref.sourceID)]", false)

        case .pageBreak:
            return nil

        case .raw(let text):
            let cleaned = Self.clean(text)
            return cleaned.isEmpty ? nil : (cleaned, false)
        }
    }

    /// 표 셀 내용을 한 줄로.
    private static func flatten(_ blocks: [Block]) -> String {
        var pieces: [String] = []
        for block in blocks {
            switch block {
            case .heading(_, let runs), .paragraph(let runs, _):
                pieces.append(oneLine(runs.text))
            case .list(let items, _):
                pieces += items.map { flatten($0) }
            case .table(let nested):
                for row in TableGrid(nested).slots {
                    let cells = row.compactMap { slot -> String? in
                        guard case .cell(let cell) = slot else { return nil }
                        return flatten(cell.blocks)
                    }
                    pieces.append(cells.filter { !$0.isEmpty }.joined(separator: " / "))
                }
            case .image(let ref):
                pieces.append("[이미지: \(ref.path ?? ref.sourceID)]")
            case .raw(let text):
                pieces.append(oneLine(text))
            case .pageBreak:
                break
            }
        }
        return pieces.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// 줄 끝 공백 제거, 공백뿐인 줄 제거.
    private static func clean(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            .filter { $0.contains { !$0.isWhitespace } }
            .joined(separator: "\n")
    }
}
