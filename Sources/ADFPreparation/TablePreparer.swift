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

    // Plain index loops throughout: this runs over every cell of a table
    // (thousands in a big one), and closure-based `map`/`enumerated`
    // chains cost several times more per cell in unoptimized builds.
    private func preparedTable(attrs: TableAttrs, rows: [ADFNode]) -> (PreparedTableLayout, [PreparedTableRow]) {
        var sourceRows: [SourceRow] = []
        var spans: [[TableCellSpan]] = []
        var isHeader: [[Bool]] = []
        sourceRows.reserveCapacity(rows.count)
        spans.reserveCapacity(rows.count)
        isHeader.reserveCapacity(rows.count)
        for row in rows {
            guard case .tableRow(let cells) = row.kind else { continue }
            var sourceCells: [SourceCell] = []
            var rowSpans: [TableCellSpan] = []
            var rowHeaders: [Bool] = []
            sourceCells.reserveCapacity(cells.count)
            rowSpans.reserveCapacity(cells.count)
            rowHeaders.reserveCapacity(cells.count)
            for cell in cells {
                guard case .tableCell(let cellAttrs, let content, let cellIsHeader) = cell.kind else { continue }
                sourceCells.append(SourceCell(id: cell.id, attrs: cellAttrs, content: content, isHeader: cellIsHeader))
                rowSpans.append(TableCellSpan(colspan: cellAttrs.colspan, rowspan: cellAttrs.rowspan))
                rowHeaders.append(cellIsHeader)
            }
            sourceRows.append(SourceRow(id: row.id, cells: sourceCells))
            spans.append(rowSpans)
            isHeader.append(rowHeaders)
        }

        let placement = TableGridPlacement.place(spans)
        let columnCount = placement.columnCount

        let hasHeaderRow = isHeader.first.map { !$0.isEmpty && !$0.contains(false) } ?? false
        let hasHeaderColumn = placement.hasHeaderColumn(
            spans: spans, isHeader: isHeader, firstBodyRow: hasHeaderRow ? 1 : 0
        )

        // Prepared cell content (the expensive part), then the per-column
        // analysis over its plain text. A cell's lines are read only when
        // the analysis asks for them (columns it has settled skip the rest
        // of their cells).
        var cellBlocks: [[[RenderBlock]]] = []
        var analysisCells: [TableColumnAnalysis.Cell] = []
        var analysisBlocks: [[RenderBlock]] = []
        cellBlocks.reserveCapacity(sourceRows.count)
        for rowIndex in 0..<sourceRows.count {
            let cells = sourceRows[rowIndex].cells
            var rowBlocks: [[RenderBlock]] = []
            rowBlocks.reserveCapacity(cells.count)
            for cellIndex in 0..<cells.count {
                let content = cells[cellIndex].content.flatMap(blocks(for:))
                rowBlocks.append(content)
                analysisCells.append(TableColumnAnalysis.Cell(
                    column: placement.cellColumns[rowIndex][cellIndex],
                    colspan: spans[rowIndex][cellIndex].colspan,
                    isHeader: cells[cellIndex].isHeader,
                    lines: [PreparedTableColumnSample]()
                ))
                analysisBlocks.append(content)
            }
            cellBlocks.append(rowBlocks)
        }
        let measurer = TableTextMeasurer(pointSize: theme.bodyPointSize)
        let spacing = Double(theme.spacing)
        let analysis = TableColumnAnalysis.analyze(
            cells: analysisCells,
            columnCount: columnCount,
            padding: TableColumnSizing.cellHorizontalPadding * 2,
            maxAdvancePerCharacter: Double(theme.bodyPointSize) * 1.5,
            styleScale: { max(measurer.pointSize(of: $0) / Double(theme.bodyPointSize), 1) },
            lines: { Self.measuredLines(of: analysisBlocks[$0], spacing: spacing) },
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

        var preparedRows: [PreparedTableRow] = []
        preparedRows.reserveCapacity(sourceRows.count)
        for rowIndex in 0..<sourceRows.count {
            let row = sourceRows[rowIndex]
            var cells: [PreparedTableCell] = []
            cells.reserveCapacity(row.cells.count)
            for cellIndex in 0..<row.cells.count {
                let cell = row.cells[cellIndex]
                cells.append(PreparedTableCell(
                    id: cell.id,
                    colspan: spans[rowIndex][cellIndex].colspan,
                    rowspan: placement.rowspans[rowIndex][cellIndex],
                    backgroundHex: cell.attrs.backgroundHex,
                    valign: cell.attrs.valign,
                    isHeader: cell.isHeader,
                    blocks: cellBlocks[rowIndex][cellIndex]
                ))
            }
            var continuations: [PreparedTableContinuation] = []
            for continuation in placement.continuations[rowIndex] {
                let origin = sourceRows[continuation.originRow].cells[continuation.originCell]
                continuations.append(PreparedTableContinuation(
                    originRow: continuation.originRow,
                    column: continuation.column,
                    colspan: continuation.colspan,
                    backgroundHex: origin.attrs.backgroundHex,
                    isHeader: origin.isHeader,
                    continuesBelow: continuation.continuesBelow
                ))
            }
            preparedRows.append(PreparedTableRow(
                id: row.id,
                cells: cells,
                index: rowIndex,
                cellColumns: placement.cellColumns[rowIndex],
                continuations: continuations
            ))
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
        for rowIndex in 0..<rows.count {
            let cells = rows[rowIndex].cells
            for cellIndex in 0..<cells.count {
                guard let colwidth = cells[cellIndex].attrs.colwidth else { continue }
                let column = placement.cellColumns[rowIndex][cellIndex]
                let span = max(cells[cellIndex].attrs.colspan, 1)
                for offset in 0..<min(span, colwidth.count) {
                    let index = column + offset
                    let width = colwidth[offset]
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

        func append(_ piece: Substring, spec: ADFFontSpec?) {
            text += piece
            guard Self.hasVisibleText(piece) else { return }
            let style = spec?.textStyle ?? .body
            if spec?.bold == true { isBold = true }
            if style == .headline { isSemibold = true }
            if spec?.monospaced == true { isMonospaced = true }
            if !hasStyle || style.defaultPointSize > textStyle.defaultPointSize { textStyle = style }
            hasStyle = true
        }

        for segment in segments {
            switch segment {
            case .text(let run):
                // One pass over the runs: each custom emoji character is
                // spelled as its short name (`InlineComposer.replacingEmoji`)
                // and hard breaks end the line.
                for piece in run.runs {
                    let spec = piece[AttributeScopes.ADFAttributes.FontSpecAttribute.self]
                    let chunk: String
                    if let emoji = piece[AttributeScopes.ADFAttributes.EmojiAttribute.self] {
                        chunk = String(repeating: emoji.shortName, count: run[piece.range].characters.count)
                    } else {
                        chunk = String(run[piece.range].characters)
                    }
                    guard Self.mayContainNewline(chunk) else {
                        append(chunk[...], spec: spec)
                        continue
                    }
                    let lines = chunk.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                    for (index, line) in lines.enumerated() {
                        if index > 0 { endLine() }
                        append(line, spec: spec)
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

    /// False only when `text` has none of the newline characters
    /// (`Character.isNewline`): no U+000A–U+000D, and no U+0085 (UTF-8
    /// C2 85) or U+2028/U+2029 (E2 80 A8/A9) lead byte.
    private static func mayContainNewline(_ text: String) -> Bool {
        var text = text
        return text.withUTF8 { bytes in
            for byte in bytes where (byte >= 0x0A && byte <= 0x0D) || byte == 0xC2 || byte == 0xE2 {
                return true
            }
            return false
        }
    }

    /// Whether `piece` has a non-whitespace character; an ASCII byte other
    /// than a space or a tab/newline control answers without the
    /// character walk.
    private static func hasVisibleText(_ piece: Substring) -> Bool {
        var piece = piece
        let asciiVisible = piece.withUTF8 { bytes in
            for byte in bytes where byte < 0x80 && byte != 0x20 && !(byte >= 0x09 && byte <= 0x0D) {
                return true
            }
            return false
        }
        return asciiVisible || piece.contains(where: { !$0.isWhitespace })
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
