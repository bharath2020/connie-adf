import Foundation
import ADFModel

/// Table slicing: a table becomes one header slice (when the first row is
/// all header cells) plus row slices of at most `tableRowsPerSlice` rows, so
/// a 2,000-row table still virtualizes inside the lazy scroll container. All
/// slices share one `PreparedTableLayout`.
///
/// Everything the table look needs per table — grid placement with
/// rowspans, natural column widths, numeric columns, the header-column
/// flag — is computed here once, off-main, so slices stay independent and
/// never measure or reconcile with each other while scrolling.
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
        let (layout, preparedRows) = preparedTable(attrs: attrs, rows: rows)

        var slices: [RenderBlock] = []
        var dataRows = preparedRows[...]
        if layout.hasHeaderRow, let first = preparedRows.first {
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

    // MARK: - Rows, cells and layout

    private struct SourceCell {
        let id: String
        let attrs: CellAttrs
        let content: [ADFNode]
        let isHeader: Bool
    }

    private struct SourceRow {
        let id: String
        let cells: [SourceCell]
    }

    private func preparedTable(attrs: TableAttrs, rows: [ADFNode]) -> (PreparedTableLayout, [PreparedTableRow]) {
        let sourceRows: [SourceRow] = rows.compactMap { row in
            guard case .tableRow(let cells) = row.kind else { return nil }
            return SourceRow(id: row.id, cells: cells.compactMap { cell in
                guard case .tableCell(let cellAttrs, let content, let isHeader) = cell.kind else { return nil }
                return SourceCell(id: cell.id, attrs: cellAttrs, content: content, isHeader: isHeader)
            })
        }

        let spans = sourceRows.map { row in
            row.cells.map { TableCellSpan(colspan: $0.attrs.colspan, rowspan: $0.attrs.rowspan) }
        }
        let isHeader = sourceRows.map { row in row.cells.map(\.isHeader) }
        let placement = TableGridPlacement.place(spans)
        let columnCount = placement.columnCount

        let hasHeaderRow = sourceRows.first.map { !$0.cells.isEmpty && $0.cells.allSatisfy(\.isHeader) } ?? false
        let hasHeaderColumn = placement.hasHeaderColumn(
            spans: spans, isHeader: isHeader, firstBodyRow: hasHeaderRow ? 1 : 0
        )

        // Prepared cell content (the expensive part), then the per-column
        // analysis over its plain text.
        var cellBlocks: [[[RenderBlock]]] = sourceRows.map { row in
            row.cells.map { $0.content.flatMap(blocks(for:)) }
        }
        var analysisCells: [TableColumnAnalysis.Cell] = []
        for (rowIndex, row) in sourceRows.enumerated() {
            for (cellIndex, cell) in row.cells.enumerated() {
                analysisCells.append(TableColumnAnalysis.Cell(
                    column: placement.cellColumns[rowIndex][cellIndex],
                    colspan: spans[rowIndex][cellIndex].colspan,
                    isHeader: cell.isHeader,
                    lines: Self.plainLines(of: cellBlocks[rowIndex][cellIndex])
                ))
            }
        }
        let measurer = TableTextMeasurer(pointSize: theme.bodyPointSize)
        let analysis = TableColumnAnalysis.analyze(
            cells: analysisCells,
            columnCount: columnCount,
            padding: TableColumnSizing.cellHorizontalPadding * 2,
            maxAdvancePerCharacter: Double(theme.bodyPointSize) * 1.5,
            measure: { measurer.width(of: $0, semibold: $1) }
        )

        // Numeric columns read trailing-aligned: their single-column cells'
        // paragraphs (header included) take `.end` unless authored otherwise.
        if analysis.numericColumns.contains(true) {
            for rowIndex in sourceRows.indices {
                for cellIndex in sourceRows[rowIndex].cells.indices {
                    let column = placement.cellColumns[rowIndex][cellIndex]
                    guard spans[rowIndex][cellIndex].colspan == 1,
                          column < analysis.numericColumns.count,
                          analysis.numericColumns[column] else { continue }
                    cellBlocks[rowIndex][cellIndex] = cellBlocks[rowIndex][cellIndex].map(Self.trailingAligned)
                }
            }
        }

        let preparedRows: [PreparedTableRow] = sourceRows.enumerated().map { rowIndex, row in
            let cells = row.cells.enumerated().map { cellIndex, cell in
                PreparedTableCell(
                    id: cell.id,
                    colspan: spans[rowIndex][cellIndex].colspan,
                    rowspan: placement.rowspans[rowIndex][cellIndex],
                    backgroundHex: cell.attrs.backgroundHex,
                    valign: cell.attrs.valign,
                    isHeader: cell.isHeader,
                    blocks: cellBlocks[rowIndex][cellIndex]
                )
            }
            let continuations = placement.continuations[rowIndex].map { continuation in
                let origin = sourceRows[continuation.originRow].cells[continuation.originCell]
                return PreparedTableContinuation(
                    originRow: continuation.originRow,
                    column: continuation.column,
                    colspan: continuation.colspan,
                    backgroundHex: origin.attrs.backgroundHex,
                    isHeader: origin.isHeader,
                    continuesBelow: continuation.continuesBelow
                )
            }
            return PreparedTableRow(
                id: row.id,
                cells: cells,
                index: rowIndex,
                cellColumns: placement.cellColumns[rowIndex],
                continuations: continuations
            )
        }

        let layout = PreparedTableLayout(
            columnWidths: Self.authoredColumnWidths(sourceRows, placement: placement),
            columnCount: columnCount,
            hasNumberColumn: attrs.isNumberColumnEnabled,
            naturalColumnWidths: analysis.naturalWidths,
            columnSamples: analysis.samples,
            numericColumns: analysis.numericColumns,
            hasHeaderRow: hasHeaderRow,
            hasHeaderColumn: hasHeaderColumn,
            rowCount: sourceRows.count
        )
        return (layout, preparedRows)
    }

    /// Column widths from `colwidth` attrs, surfaced only when every column
    /// has one (each cell's widths apply from its placed start column).
    private static func authoredColumnWidths(_ rows: [SourceRow], placement: TableGridPlacement) -> [Double]? {
        let columnCount = placement.columnCount
        var widths = [Double](repeating: 0, count: columnCount)
        for (rowIndex, row) in rows.enumerated() {
            for (cellIndex, cell) in row.cells.enumerated() {
                guard let colwidth = cell.attrs.colwidth else { continue }
                let column = placement.cellColumns[rowIndex][cellIndex]
                let span = max(cell.attrs.colspan, 1)
                for (offset, width) in colwidth.prefix(span).enumerated() {
                    let index = column + offset
                    if index < columnCount, widths[index] == 0, width > 0 {
                        widths[index] = width
                    }
                }
            }
        }
        return (!widths.isEmpty && widths.allSatisfy { $0 > 0 }) ? widths : nil
    }

    // MARK: - Plain text for column analysis

    /// A cell's plain text, one entry per rendered line: paragraphs and
    /// headings split at hard breaks, list rows (indented by depth to
    /// stand in for the marker column), and the same inside panels and
    /// quotes. Other content (media, code, nested tables) adds no line, so
    /// a column of it sits at the minimum width.
    static func plainLines(of blocks: [RenderBlock]) -> [String] {
        var lines: [String] = []
        for block in blocks {
            switch block.kind {
            case .richText(let segments, _):
                lines.append(contentsOf: plainText(of: segments).split(whereSeparator: \.isNewline).map(String.init))
            case .listRows(let rows):
                for row in rows {
                    let indent = String(repeating: "    ", count: row.depth + 1)
                    lines.append(indent + plainText(of: row.segments))
                }
            case .panel(_, let children), .quote(let children):
                lines.append(contentsOf: plainLines(of: children))
            default:
                break
            }
        }
        return lines
    }

    private static func plainText(of segments: [InlineSegment]) -> String {
        var text = ""
        for segment in segments {
            switch segment {
            case .text(let run):
                text += InlineComposer.plainText(of: run)
            case .atom(let atom, _):
                text += InlineComposer.fallbackText(atom)
            }
        }
        return text
    }

    /// A paragraph re-styled to trailing alignment (numeric columns), unless
    /// the author already aligned it.
    private static func trailingAligned(_ block: RenderBlock) -> RenderBlock {
        guard case .richText(let segments, let style) = block.kind, style.alignment == nil else { return block }
        let aligned = TextBlockStyle(
            font: style.font,
            isHeading: style.isHeading,
            headingLevel: style.headingLevel,
            alignment: .end,
            indentation: style.indentation,
            breakout: style.breakout
        )
        return RenderBlock(
            id: block.id,
            kind: .richText(segments: segments, style: aligned),
            breakout: block.breakout,
            smartLinkKeys: block.smartLinkKeys,
            emojiKeys: block.emojiKeys
        )
    }
}
