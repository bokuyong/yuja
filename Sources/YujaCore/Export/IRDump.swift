import Foundation

/// `yuja inspect`용 IR 트리 덤프.
public enum IRDump {
    public static func dump(_ document: Document, previewLength: Int = 40) -> String {
        var lines: [String] = []
        let meta = document.meta
        lines.append("format: \(meta.sourceFormat?.rawValue ?? "?")")
        if let title = meta.title { lines.append("title: \(title)") }
        if let author = meta.author { lines.append("author: \(author)") }
        lines.append("sections: \(document.sections.count)")

        for (i, section) in document.sections.enumerated() {
            lines.append("[section \(i)] blocks: \(section.blocks.count)")
            for block in section.blocks { dump(block, depth: 1, into: &lines, preview: previewLength) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func dump(_ block: Block, depth: Int, into lines: inout [String], preview: Int) {
        let pad = String(repeating: "  ", count: depth)
        func quote(_ text: String) -> String {
            let flat = text.replacingOccurrences(of: "\n", with: "⏎").replacingOccurrences(of: "\t", with: "⇥")
            return "\"" + (flat.count > preview ? flat.prefix(preview) + "…" : flat) + "\""
        }

        switch block {
        case .heading(let level, let runs):
            lines.append("\(pad)heading(\(level)) \(quote(runs.text))")
        case .paragraph(let runs, let align):
            let styles = Set(runs.flatMap { run -> [String] in
                [run.bold ? "b" : nil, run.italic ? "i" : nil, run.underline ? "u" : nil, run.strike ? "s" : nil,
                 run.equation ? "eq" : nil].compactMap { $0 }
            }).sorted().joined()
            let tags = [align.map(\.rawValue), styles.isEmpty ? nil : styles].compactMap { $0 }
            lines.append("\(pad)paragraph\(tags.isEmpty ? "" : "[" + tags.joined(separator: ",") + "]") \(quote(runs.text))")
        case .list(let items, let ordered):
            lines.append("\(pad)list(\(ordered ? "ordered" : "bullet"), \(items.count) items)")
            for item in items {
                lines.append("\(pad)  item")
                for child in item { dump(child, depth: depth + 2, into: &lines, preview: preview) }
            }
        case .table(let table):
            let grid = TableGrid(table)
            lines.append("\(pad)table \(grid.slots.count)x\(grid.columnCount)")
            for (r, row) in table.rows.enumerated() {
                for (c, cell) in row.enumerated() {
                    let span = (cell.colSpan > 1 || cell.rowSpan > 1) ? " span \(cell.colSpan)x\(cell.rowSpan)" : ""
                    lines.append("\(pad)  cell[\(r),\(c)]\(span)")
                    for child in cell.blocks { dump(child, depth: depth + 2, into: &lines, preview: preview) }
                }
            }
        case .image(let ref):
            lines.append("\(pad)image \(ref.sourceID)\(ref.path.map { " → \($0)" } ?? "")")
        case .pageBreak:
            lines.append("\(pad)pageBreak")
        case .raw(let text):
            lines.append("\(pad)raw \(quote(text))")
        }
    }
}
