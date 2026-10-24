import Foundation

// 파서 공통: 문단 → IR 블록. HWPX·HWP5 파서가 같이 쓴다.
//
// 문단은 "텍스트 조각"과 "블록"(표·그림 등 인라인 개체)이 섞인 순서열로 모았다가
// 문단이 끝날 때 펼친다. 목록 문단은 컨테이너가 끝날 때 묶어서 Block.list로 만든다.

enum Segment {
    case text(Run)
    case block(Block)
}

/// 컨테이너(구역, 셀, 글상자 …) 안의 항목. 목록 문단은 나중에 묶어서 Block.list로 만든다.
enum Item {
    case block(Block)
    case listItem(level: Int, ordered: Bool, runs: [Run])
}

final class ParagraphBuilder {
    let shape: ParaShape
    let pageBreak: Bool
    var charShape = CharShape()
    var segments: [Segment] = []
    /// 각주·글상자 등 문단 흐름 밖의 내용. 문단 뒤에 붙인다.
    var trailing: [Block] = []

    init(shape: ParaShape, pageBreak: Bool) {
        self.shape = shape
        self.pageBreak = pageBreak
    }

    func appendText(_ text: String) {
        guard !text.isEmpty else { return }
        let c = charShape
        if case .text(var last)? = segments.last, !last.equation,
           last.bold == c.bold, last.italic == c.italic, last.underline == c.underline, last.strike == c.strike {
            last.text += text
            segments[segments.count - 1] = .text(last)
        } else {
            segments.append(.text(Run(text, bold: c.bold, italic: c.italic, underline: c.underline, strike: c.strike)))
        }
    }

    /// 수식은 앞뒤 텍스트와 합치지 않는 별도 런으로 문장 안에 둔다.
    func appendEquation(_ script: String) {
        let script = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else { return }
        segments.append(.text(Run(script, equation: true)))
    }

    func items() -> [Item] {
        var out: [Item] = []
        if pageBreak { out.append(.block(.pageBreak)) }

        var runs: [Run] = []
        func flushRuns() {
            guard !runs.isEmpty else { return }
            switch shape.heading {
            case .outline:
                out.append(.block(.heading(level: min(shape.level + 1, 6), runs: runs)))
            case .number:
                out.append(.listItem(level: shape.level, ordered: true, runs: runs))
            case .bullet:
                out.append(.listItem(level: shape.level, ordered: false, runs: runs))
            case .none:
                out.append(.block(.paragraph(runs: runs, align: shape.align)))
            }
            runs = []
        }

        for segment in segments {
            switch segment {
            case .text(let run): runs.append(run)
            case .block(let block):
                flushRuns()
                out.append(.block(block))
            }
        }
        flushRuns()
        out += trailing.map(Item.block)
        return out
    }
}

enum BlockBuilder {
    /// 연속된 목록 문단을 Block.list로 묶는다.
    static func fold(_ items: [Item]) -> [Block] {
        var out: [Block] = []
        var pending: [(level: Int, ordered: Bool, runs: [Run])] = []

        func flush() {
            if !pending.isEmpty { out.append(buildList(pending[...])) }
            pending = []
        }

        for item in items {
            switch item {
            case .listItem(let level, let ordered, let runs):
                pending.append((level, ordered, runs))
            case .block(let block):
                flush()
                out.append(block)
            }
        }
        flush()
        return out
    }

    private static func buildList(_ entries: ArraySlice<(level: Int, ordered: Bool, runs: [Run])>) -> Block {
        let base = entries.map(\.level).min() ?? 0
        var items: [[Block]] = []
        var index = entries.startIndex

        while index < entries.endIndex {
            let entry = entries[index]
            if entry.level <= base {
                items.append([.paragraph(runs: entry.runs, align: nil)])
                index += 1
            } else {
                var end = index
                while end < entries.endIndex && entries[end].level > base { end += 1 }
                let nested = buildList(entries[index..<end])
                if items.isEmpty { items.append([]) }
                items[items.count - 1].append(nested)
                index = end
            }
        }
        return .list(items: items, ordered: entries.first?.ordered ?? false)
    }
}
