import Foundation

/// 병합 셀(colSpan/rowSpan)을 펼친 직사각형 격자.
/// HWPX의 tr에는 실제 셀만 들어 있으므로, 덮인 칸을 계산해서 채운다.
struct TableGrid {
    enum Slot {
        case cell(Cell)
        /// 병합으로 덮인 칸. origin은 원래 셀의 (row, col)
        case covered(originRow: Int, originCol: Int)
        case empty
    }

    var slots: [[Slot]]
    var columnCount: Int { slots.first?.count ?? 0 }

    init(_ table: Table) {
        var grid: [[Slot?]] = []
        func ensure(_ r: Int, _ c: Int) {
            while grid.count <= r { grid.append([]) }
            while grid[r].count <= c { grid[r].append(nil) }
        }

        for (r, row) in table.rows.enumerated() {
            ensure(r, 0)
            var c = 0
            for cell in row {
                while c < grid[r].count && grid[r][c] != nil { c += 1 }
                for dr in 0..<cell.rowSpan {
                    for dc in 0..<cell.colSpan {
                        ensure(r + dr, c + dc)
                        grid[r + dr][c + dc] = (dr == 0 && dc == 0) ? .cell(cell) : .covered(originRow: r, originCol: c)
                    }
                }
                c += cell.colSpan
            }
        }

        let width = grid.map(\.count).max() ?? 0
        slots = grid.map { row in (0..<width).map { $0 < row.count ? (row[$0] ?? .empty) : .empty } }
    }
}

extension TableGrid {
    /// 셀 폭(pt)으로 열 폭을 푼다. 폭 정보가 하나도 없으면 nil.
    ///
    /// 1칸짜리 셀로 먼저 정하고, 병합 셀은 "모르는 열 = 셀 폭 − 아는 열 합"을 나눠 채운다.
    /// 끝까지 모르는 열은 아는 열의 평균으로.
    func columnWidths() -> [Double]? {
        var origins: [(col: Int, span: Int, width: Double)] = []
        for row in slots {
            for (c, slot) in row.enumerated() {
                if case .cell(let cell) = slot, let w = cell.width {
                    origins.append((c, min(cell.colSpan, columnCount - c), w))
                }
            }
        }
        guard !origins.isEmpty else { return nil }

        var widths = [Double?](repeating: nil, count: columnCount)
        for o in origins where o.span == 1 && widths[o.col] == nil { widths[o.col] = o.width }

        var changed = true
        while changed {
            changed = false
            // 병합 셀 중 모르는 열이 가장 적은 것부터 (하나뿐이면 정확히 풀린다)
            let pending = origins.compactMap { o -> (Range<Int>, Double, [Int])? in
                let range = o.col..<(o.col + o.span)
                let unknown = range.filter { widths[$0] == nil }
                return unknown.isEmpty ? nil : (range, o.width, unknown)
            }.sorted { $0.2.count < $1.2.count }
            guard let (range, width, unknown) = pending.first else { break }
            let known = range.compactMap { widths[$0] }.reduce(0, +)
            let share = max(width - known, 0) / Double(unknown.count)
            for c in unknown { widths[c] = share }
            changed = true
        }

        let known = widths.compactMap { $0 }.filter { $0 > 0 }
        let fallback = known.isEmpty ? 1 : known.reduce(0, +) / Double(known.count)
        return widths.map { w in (w ?? 0) > 0 ? w! : fallback }
    }
}

extension Table {
    /// 1×1 표 (제목 상자 등 장식용으로 흔함)
    var singleCell: Cell? {
        guard rows.count == 1, rows[0].count == 1 else { return nil }
        return rows[0][0]
    }
}

extension Run {
    var hasVisibleText: Bool { text.contains { !$0.isWhitespace } }
}

extension Array where Element == Run {
    var text: String { map(\.text).joined() }
    var hasVisibleText: Bool { contains { $0.hasVisibleText } }
}
