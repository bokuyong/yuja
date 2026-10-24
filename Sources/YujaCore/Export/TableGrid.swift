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
