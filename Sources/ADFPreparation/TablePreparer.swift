import Foundation
import ADFModel

/// Table slicing: a table becomes one header slice (when the first row is
/// all header cells) plus row slices of at most `tableRowsPerSlice` rows, so
/// a 2,000-row table still virtualizes inside the lazy scroll container. All
/// slices share one `PreparedTableLayout`.
extension BlockPreparer {
    /// Rows per non-header slice. Slices are what the lazy container
    /// materializes while scrolling — and it materializes them in batches
    /// (~16 rows at a time), so a batch of slices must build inside one
    /// 60 Hz frame budget. Measured on the §8 giant-table hitch gate
    /// (6 columns): 20-row slices ≈ 45 ms per single slice (hitch ratio 63),
    /// 5-row slices ≈ 45 ms per batch (ratio ~5.5), 2-row slices fit the
    /// budget (ratio < 5).
    static let tableRowsPerSlice = 2

    func tableSlices(for node: ADFNode, attrs: TableAttrs, rows: [ADFNode]) -> [RenderBlock] {
        let layout = tableLayout(attrs: attrs, rows: rows)
        let preparedRows = rows.compactMap(preparedRow(from:))

        var slices: [RenderBlock] = []
        var dataRows = preparedRows[...]
        if let first = preparedRows.first, !first.cells.isEmpty, first.cells.allSatisfy(\.isHeader) {
            slices.append(RenderBlock(
                id: "\(node.id)#header",
                kind: .tableSlice(layout, rows: [first], isHeaderSlice: true)
            ))
            dataRows = preparedRows.dropFirst()
        }

        var sliceIndex = 0
        var start = dataRows.startIndex
        while start < dataRows.endIndex {
            let end = min(start + Self.tableRowsPerSlice, dataRows.endIndex)
            slices.append(RenderBlock(
                id: "\(node.id)#rows\(sliceIndex)",
                kind: .tableSlice(layout, rows: Array(dataRows[start..<end]), isHeaderSlice: false)
            ))
            sliceIndex += 1
            start = end
        }
        return slices
    }

    // MARK: - Rows and cells

    private func preparedRow(from node: ADFNode) -> PreparedTableRow? {
        guard case .tableRow(let cells) = node.kind else { return nil }
        let preparedCells = cells.compactMap { cell -> PreparedTableCell? in
            guard case .tableCell(let attrs, let content, let isHeader) = cell.kind else { return nil }
            return PreparedTableCell(
                id: cell.id,
                colspan: max(attrs.colspan, 1),
                rowspan: max(attrs.rowspan, 1),
                backgroundHex: attrs.backgroundHex,
                valign: attrs.valign,
                isHeader: isHeader,
                blocks: content.flatMap(blocks(for:))
            )
        }
        return PreparedTableRow(id: node.id, cells: preparedCells)
    }

    // MARK: - Layout metadata

    /// Column count is the widest row (sum of colspans); column widths come
    /// from `colwidth` attrs and are surfaced only when every column has one.
    private func tableLayout(attrs: TableAttrs, rows: [ADFNode]) -> PreparedTableLayout {
        var columnCount = 0
        for row in rows {
            guard case .tableRow(let cells) = row.kind else { continue }
            var rowSpan = 0
            for cell in cells {
                guard case .tableCell(let cellAttrs, _, _) = cell.kind else { continue }
                rowSpan += max(cellAttrs.colspan, 1)
            }
            columnCount = max(columnCount, rowSpan)
        }

        var widths = [Double](repeating: 0, count: columnCount)
        for row in rows {
            guard case .tableRow(let cells) = row.kind else { continue }
            var column = 0
            for cell in cells {
                guard case .tableCell(let cellAttrs, _, _) = cell.kind else { continue }
                let span = max(cellAttrs.colspan, 1)
                if let colwidth = cellAttrs.colwidth {
                    for (offset, width) in colwidth.prefix(span).enumerated() {
                        let index = column + offset
                        if index < columnCount, widths[index] == 0, width > 0 {
                            widths[index] = width
                        }
                    }
                }
                column += span
            }
        }
        let columnWidths: [Double]? = (!widths.isEmpty && widths.allSatisfy { $0 > 0 }) ? widths : nil

        return PreparedTableLayout(
            columnWidths: columnWidths,
            columnCount: columnCount,
            hasNumberColumn: attrs.isNumberColumnEnabled
        )
    }
}
