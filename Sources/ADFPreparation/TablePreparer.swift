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
                    lines: Self.measuredLines(of: cellBlocks[rowIndex][cellIndex], spacing: Double(theme.spacing))
                ))
            }
        }
        let measurer = TableTextMeasurer(pointSize: theme.bodyPointSize)
        let analysis = TableColumnAnalysis.analyze(
            cells: analysisCells,
            columnCount: columnCount,
            padding: TableColumnSizing.cellHorizontalPadding * 2,
            maxAdvancePerCharacter: Double(theme.bodyPointSize) * 1.5,
            styleScale: { max(measurer.pointSize(of: $0) / Double(theme.bodyPointSize), 1) },
            measure: measurer.width(of:)
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

    // MARK: - Lines for column analysis

    /// A cell's lines as rendered, for column analysis: paragraphs and
    /// headings split at hard breaks, list rows (inset by their marker
    /// columns: `(depth + 1) × (marker + spacing)`, a decision's padding
    /// too), and the same inside panels and quotes. Each line records its
    /// bold and code runs and its inline chips' padding. Other content
    /// (media, code, nested tables) adds no line, so a column of it sits
    /// at the minimum width.
    static func measuredLines(of blocks: [RenderBlock], spacing: Double) -> [PreparedTableColumnSample] {
        var lines: [PreparedTableColumnSample] = []
        for block in blocks {
            switch block.kind {
            case .richText(let segments, _):
                lines.append(contentsOf: measuredLines(of: segments, scaledInset: 0, fixedInset: 0))
            case .listRows(let rows):
                for row in rows {
                    let columns = Double(row.depth + 1)
                    var fixedInset = columns * spacing
                    if case .decision = row.marker { fixedInset += 2 * spacing }
                    lines.append(contentsOf: measuredLines(
                        of: row.segments, scaledInset: columns * TableColumnSizing.listMarkerWidth, fixedInset: fixedInset
                    ))
                }
            case .panel(_, let children), .quote(let children):
                lines.append(contentsOf: measuredLines(of: children, spacing: spacing))
            default:
                break
            }
        }
        return lines
    }

    private static func measuredLines(
        of segments: [InlineSegment],
        scaledInset: Double,
        fixedInset: Double
    ) -> [PreparedTableColumnSample] {
        var lines: [PreparedTableColumnSample] = []
        var text = ""
        var isBold = false
        var isSemibold = false
        var isMonospaced = false
        var textStyle = ADFFontSpec.TextStyle.body
        var hasStyle = false
        var atomInset = 0.0

        func endLine() {
            lines.append(PreparedTableColumnSample(
                text: text,
                isSemibold: isSemibold,
                isBold: isBold,
                isMonospaced: isMonospaced,
                textStyle: textStyle,
                scaledInset: scaledInset + atomInset,
                fixedInset: fixedInset
            ))
            text = ""
            isBold = false
            isSemibold = false
            isMonospaced = false
            textStyle = .body
            hasStyle = false
            atomInset = 0
        }

        for segment in segments {
            switch segment {
            case .text(let run):
                let spelled = InlineComposer.replacingEmoji(in: run)
                for (spec, range) in spelled.runs[AttributeScopes.ADFAttributes.FontSpecAttribute.self] {
                    let pieces = String(spelled[range].characters)
                        .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                    for (index, piece) in pieces.enumerated() {
                        if index > 0 { endLine() }
                        text += piece
                        guard piece.contains(where: { !$0.isWhitespace }) else { continue }
                        let style = spec?.textStyle ?? .body
                        if spec?.bold == true { isBold = true }
                        if style == .headline { isSemibold = true }
                        if spec?.monospaced == true { isMonospaced = true }
                        if !hasStyle || style.defaultPointSize > textStyle.defaultPointSize { textStyle = style }
                        hasStyle = true
                    }
                }
            case .atom(let atom, _):
                if !hasStyle || textStyle.defaultPointSize < ADFFontSpec.TextStyle.body.defaultPointSize {
                    textStyle = .body
                }
                hasStyle = true
                switch atom {
                case .status(let label, _):
                    text += label.uppercased()
                    atomInset += TableColumnSizing.atomPadding
                case .mention, .date:
                    text += InlineComposer.fallbackText(atom)
                    atomInset += TableColumnSizing.atomPadding
                case .inlineCard, .mediaInline, .inlineExtension:
                    text += InlineComposer.fallbackText(atom)
                    atomInset += TableColumnSizing.atomPadding + TableColumnSizing.atomIconWidth
                }
            }
        }
        endLine()
        return lines
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
