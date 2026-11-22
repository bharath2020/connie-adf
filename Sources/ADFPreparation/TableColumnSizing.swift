import Foundation
import CoreText
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// Pure table geometry for the Direction A table look (ADF-TBL1 B1a): grid
// placement with rowspan, per-column content analysis (natural widths,
// numeric columns), on-screen width resolution and the header-column pin
// decision. Everything here is free of SwiftUI and view state, so it runs
// once per table in preparation (placement, analysis) or as plain
// arithmetic in a slice's body (sizing, pinning) and is unit-tested directly.

/// The colspan / rowspan of one source cell, as authored (values below 1
/// read as 1).
package struct TableCellSpan: Sendable, Hashable {
    package let colspan: Int
    package let rowspan: Int

    package init(colspan: Int, rowspan: Int) {
        self.colspan = max(colspan, 1)
        self.rowspan = max(rowspan, 1)
    }
}

/// Where every cell of a table lands on the column grid once rowspans
/// reserve the positions they cover.
///
/// The HTML table model: walking a row left to right, a cell starts at the
/// first column not held by a rowspan from an earlier row. Without this a
/// row under a rowspan would start at column 0 and every cell would shift
/// one column left, under the wrong header.
package struct TableGridPlacement: Sendable, Hashable {
    /// A position in a row covered by a cell from an earlier row.
    package struct Continuation: Sendable, Hashable {
        package let originRow: Int
        package let originCell: Int
        package let column: Int
        package let colspan: Int
        /// The span carries on into the next row too.
        package let continuesBelow: Bool
    }

    /// Start column of each cell, per row (parallel to the input).
    package var cellColumns: [[Int]]
    /// Each cell's rowspan clamped to the rows left in the table.
    package var rowspans: [[Int]]
    /// Covered positions per row, in column order.
    package var continuations: [[Continuation]]
    /// Grid width: the furthest column any cell or continuation reaches.
    package var columnCount: Int

    package static func place(_ rows: [[TableCellSpan]]) -> TableGridPlacement {
        struct ActiveSpan {
            let originRow: Int
            let originCell: Int
            let column: Int
            let colspan: Int
            let lastRow: Int
        }

        var result = TableGridPlacement(cellColumns: [], rowspans: [], continuations: [], columnCount: 0)
        result.cellColumns.reserveCapacity(rows.count)
        result.rowspans.reserveCapacity(rows.count)
        result.continuations.reserveCapacity(rows.count)
        var active: [ActiveSpan] = []

        for (rowIndex, row) in rows.enumerated() {
            active.removeAll { $0.lastRow < rowIndex }
            let covering = active.sorted { $0.column < $1.column }
            var occupied = Set<Int>()
            var continuations: [Continuation] = []
            continuations.reserveCapacity(covering.count)
            for span in covering {
                for column in span.column..<(span.column + span.colspan) {
                    occupied.insert(column)
                }
                continuations.append(Continuation(
                    originRow: span.originRow,
                    originCell: span.originCell,
                    column: span.column,
                    colspan: span.colspan,
                    continuesBelow: span.lastRow > rowIndex
                ))
                result.columnCount = max(result.columnCount, span.column + span.colspan)
            }

            var columns: [Int] = []
            var rowspans: [Int] = []
            columns.reserveCapacity(row.count)
            rowspans.reserveCapacity(row.count)
            var column = 0
            for (cellIndex, cell) in row.enumerated() {
                while occupied.contains(column) { column += 1 }
                let rowspan = min(cell.rowspan, rows.count - rowIndex)
                columns.append(column)
                rowspans.append(rowspan)
                if rowspan > 1 {
                    active.append(ActiveSpan(
                        originRow: rowIndex,
                        originCell: cellIndex,
                        column: column,
                        colspan: cell.colspan,
                        lastRow: rowIndex + rowspan - 1
                    ))
                }
                column += cell.colspan
                result.columnCount = max(result.columnCount, column)
            }
            result.cellColumns.append(columns)
            result.rowspans.append(rowspans)
            result.continuations.append(continuations)
        }
        return result
    }

    /// Whether the table has a header column: in every body row (from
    /// `firstBodyRow` on) the cell at column 0, origin or rowspan
    /// continuation, is a header cell, and no row's column-0 cell spans
    /// more than one column (a pinned column must be exactly column 0).
    package func hasHeaderColumn(spans: [[TableCellSpan]], isHeader: [[Bool]], firstBodyRow: Int) -> Bool {
        guard firstBodyRow < cellColumns.count else { return false }
        for rowIndex in cellColumns.indices {
            let isBodyRow = rowIndex >= firstBodyRow
            if let cellIndex = cellColumns[rowIndex].firstIndex(of: 0) {
                if spans[rowIndex][cellIndex].colspan != 1 { return false }
                if isBodyRow, !isHeader[rowIndex][cellIndex] { return false }
            } else if let continuation = continuations[rowIndex].first(where: { $0.column == 0 }) {
                if continuation.colspan != 1 { return false }
                if isBodyRow, !isHeader[continuation.originRow][continuation.originCell] { return false }
            } else if isBodyRow {
                return false
            }
        }
        return true
    }
}

/// Per-column content analysis of one table: natural single-line widths
/// and numeric columns.
package struct TableColumnAnalysis: Sendable, Hashable {
    /// One cell's analysis input.
    package struct Cell: Sendable, Hashable {
        package let column: Int
        package let colspan: Int
        package let isHeader: Bool
        /// The cell's text, one entry per line (paragraph, hard break,
        /// list row), with its styling and insets.
        package let lines: [PreparedTableColumnSample]

        package init(column: Int, colspan: Int, isHeader: Bool, lines: [PreparedTableColumnSample]) {
            self.column = column
            self.colspan = colspan
            self.isHeader = isHeader
            self.lines = lines
        }

        package init(column: Int, colspan: Int, isHeader: Bool, lines: [String]) {
            self.init(
                column: column,
                colspan: colspan,
                isHeader: isHeader,
                lines: lines.map { PreparedTableColumnSample(text: $0, isSemibold: false) }
            )
        }
    }

    /// Longest line prefix measured: any text this long is wider than the
    /// maximum column at any glyph width, so the rest cannot matter.
    package static let maxMeasuredCharacters = 120

    /// Samples kept per column for re-measuring at another type size.
    package static let samplesPerColumn = 3

    package var naturalWidths: [Double]
    package var samples: [[PreparedTableColumnSample]]
    package var numericColumns: [Bool]

    /// Natural widths are each column's widest single-column cell line
    /// (`measure(line)` rounded up to a whole point, header cells
    /// semibold) plus `padding`; multi-column cells are ignored. `samples`
    /// keeps the widest measured lines per column. A column is numeric
    /// when it has at least one non-empty single-column non-header cell
    /// and every such cell is a single line that `isNumeric` accepts.
    ///
    /// Bounded work: per column, lines are measured longest first and the
    /// scan stops once no remaining line could beat the widest so far
    /// (`length × maxAdvancePerCharacter` plus its insets) or the widest already reaches
    /// `widthCap` (columns clamp there anyway) — a big table measures a
    /// handful of lines per column, not every cell.
    package static func analyze(
        cells: [Cell],
        columnCount: Int,
        padding: Double,
        maxAdvancePerCharacter: Double,
        widthCap: Double = TableColumnSizing.maxColumnWidth,
        measure: (PreparedTableColumnSample) -> Double
    ) -> TableColumnAnalysis {
        struct Candidate {
            let sample: PreparedTableColumnSample
            let bound: Double
        }

        let count = max(columnCount, 0)
        var candidates = [[Candidate]](repeating: [], count: count)
        var sawNumber = [Bool](repeating: false, count: count)
        var sawOther = [Bool](repeating: false, count: count)

        for cell in cells where cell.colspan == 1 && cell.column >= 0 && cell.column < count {
            var nonEmpty: [String] = []
            for line in cell.lines {
                let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                nonEmpty.append(trimmed)
                let text = String(trimmed.prefix(maxMeasuredCharacters))
                let sample = PreparedTableColumnSample(
                    text: text,
                    isSemibold: cell.isHeader || line.isSemibold,
                    isBold: line.isBold,
                    isMonospaced: line.isMonospaced,
                    scaledInset: line.scaledInset,
                    fixedInset: line.fixedInset
                )
                let bound = Double(text.count) * maxAdvancePerCharacter + line.scaledInset + line.fixedInset
                candidates[cell.column].append(Candidate(sample: sample, bound: bound))
            }
            if !cell.isHeader, !nonEmpty.isEmpty {
                if nonEmpty.count == 1, isNumeric(nonEmpty[0]) {
                    sawNumber[cell.column] = true
                } else {
                    sawOther[cell.column] = true
                }
            }
        }

        var natural = [Double](repeating: 0, count: count)
        var samples = [[PreparedTableColumnSample]](repeating: [], count: count)
        for column in 0..<count {
            let sorted = candidates[column].sorted { $0.bound > $1.bound }
            var widest = 0.0
            var seen = Set<PreparedTableColumnSample>()
            var measured: [(width: Double, sample: PreparedTableColumnSample)] = []
            for candidate in sorted {
                if candidate.bound + padding <= widest { break }
                let sample = candidate.sample
                guard seen.insert(sample).inserted else { continue }
                let width = measure(sample).rounded(.up)
                measured.append((width, sample))
                widest = max(widest, width + padding)
                if widest >= widthCap { break }
            }
            natural[column] = widest
            samples[column] = measured
                .sorted { $0.width > $1.width }
                .prefix(samplesPerColumn)
                .map { $0.sample }
        }

        let numeric = (0..<count).map { sawNumber[$0] && !sawOther[$0] }
        return TableColumnAnalysis(naturalWidths: natural, samples: samples, numericColumns: numeric)
    }

    /// Natural widths from a layout's samples at whatever size `measure`
    /// measures: the widest sample per column rounded up, plus `padding`
    /// (0 for a column without samples).
    package static func naturalWidths(
        samples: [[PreparedTableColumnSample]],
        padding: Double,
        measure: (PreparedTableColumnSample) -> Double
    ) -> [Double] {
        samples.map { column in
            column.reduce(0.0) { widest, sample in
                max(widest, measure(sample).rounded(.up) + padding)
            }
        }
    }

    /// A number or percentage: `^[+\-−]?[\d,.]+%?$` on the trimmed text,
    /// with at least one digit (so "." or "-" alone is not a number).
    package static func isNumeric(_ text: String) -> Bool {
        var body = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if let first = body.first, first == "+" || first == "-" || first == "\u{2212}" {
            body = body.dropFirst()
        }
        if body.last == "%" { body = body.dropLast() }
        guard !body.isEmpty else { return false }
        var sawDigit = false
        for character in body {
            if character.isASCII, character.isWholeNumber {
                sawDigit = true
            } else if character != "," && character != "." {
                return false
            }
        }
        return sawDigit
    }
}

/// On-screen column widths and the header-column pin decision. Pure
/// arithmetic over a table's prepared layout, so every slice of a table
/// resolves the same widths from the same inputs.
package enum TableColumnSizing {
    /// Body point size the clamps are stated at; widths scale by
    /// `currentBodyPointSize / basePointSize` with Dynamic Type.
    package static let basePointSize: Double = 17
    package static let minColumnWidth: Double = 72
    package static let maxColumnWidth: Double = 240
    /// Cell padding (each side): 10 pt horizontal, 8 pt vertical.
    package static let cellHorizontalPadding: Double = 10
    package static let cellVerticalPadding: Double = 8
    /// The pinned header column may take at most this share of the width.
    package static let pinnedColumnMaxFraction: Double = 0.4
    /// List marker column width at the default text size
    /// (`ListBlockView`'s scaled `markerWidth`).
    package static let listMarkerWidth: Double = 28
    /// Horizontal padding of an inline atom's capsule or chip at the
    /// default text size (8 pt each side).
    package static let atomPadding: Double = 16
    /// An icon chip's (inline card, attachment, extension) icon and the
    /// gap after it at the default text size.
    package static let atomIconWidth: Double = 20

    /// Resolved column widths for one table.
    ///
    /// - Authored `colwidth`s for every column are used exactly (main's
    ///   behaviour, unscaled).
    /// - Otherwise each column is its natural width (measured at the
    ///   current text size) clamped to [72, 240] × `scale`, where `scale`
    ///   is the current body point size / 17. When
    ///   the sum is narrower than `availableWidth`, the spare width goes to
    ///   the non-numeric columns in proportion to their widths (numeric
    ///   columns stay natural); a table of only numeric columns shares it
    ///   across all of them.
    package static func columnWidths(
        natural: [Double],
        numeric: [Bool],
        authored: [Double]?,
        columnCount: Int,
        availableWidth: Double,
        scale: Double
    ) -> [Double] {
        let count = max(columnCount, 1)
        if let authored, authored.count == count {
            return authored
        }
        let scale = scale > 0 ? scale : 1
        let lower = minColumnWidth * scale
        let upper = maxColumnWidth * scale
        var widths = (0..<count).map { index -> Double in
            let width = index < natural.count ? natural[index] : 0
            return min(max(width, lower), upper)
        }
        let spare = availableWidth - widths.reduce(0, +)
        guard spare > 0.5 else { return widths }

        var flexible = (0..<count).filter { !(($0 < numeric.count) && numeric[$0]) }
        if flexible.isEmpty { flexible = Array(0..<count) }
        let flexibleTotal = flexible.reduce(0) { $0 + widths[$1] }
        guard flexibleTotal > 0 else { return widths }
        for index in flexible {
            widths[index] += spare * widths[index] / flexibleTotal
        }
        return widths
    }

    /// Pin the header column only when the table scrolls horizontally (its
    /// columns plus the number gutter are wider than the container), it
    /// has a header column, and the first column takes at most 40 % of the
    /// width available to columns.
    package static func pinsHeaderColumn(
        columnWidths: [Double],
        gutterWidth: Double,
        containerWidth: Double,
        hasHeaderColumn: Bool
    ) -> Bool {
        guard hasHeaderColumn, containerWidth > 0, let first = columnWidths.first else { return false }
        let total = gutterWidth + columnWidths.reduce(0, +)
        guard total > containerWidth + 0.5 else { return false }
        let available = max(containerWidth - gutterWidth, 0)
        return first <= available * pinnedColumnMaxFraction
    }
}

/// Single-line widths of cell lines in the system font at one point size
/// via CoreText: regular, semibold or bold, proportional or monospaced
/// (inline code), plus each line's insets (`scaledInset × insetScale +
/// fixedInset`). Thread-safe: preparation measures off-main (one per
/// table), and a slice at a non-default type size re-measures a layout's
/// few samples (cached by the rendering layer).
///
/// Digits are measured monospaced (tabular): numeric columns render with
/// `.monospacedDigit()`, whose digits are wider than the proportional ones
/// ("361,060" is 66.3 pt against 62.6 pt at 17 pt), so a proportional
/// measurement wraps the widest number. Other text with digits measures a
/// little wide, never narrow. A line with any bold or code run measures
/// all of it that way: a little wide, never narrow.
package struct TableTextMeasurer {
    #if canImport(UIKit)
    private typealias PlatformFont = UIFont
    #elseif canImport(AppKit)
    private typealias PlatformFont = NSFont
    #endif

    /// Indexed by weight (regular, semibold, bold), proportional then
    /// monospaced.
    private let fonts: [PlatformFont]
    private let insetScale: Double

    /// `insetScale` scales the lines' `scaledInset`: the Dynamic Type
    /// scale the text is measured at (1 at the default size).
    package init(pointSize: CGFloat, insetScale: Double = 1) {
        let weights: [PlatformFont.Weight] = [.regular, .semibold, .bold]
        fonts = weights.map { PlatformFont.monospacedDigitSystemFont(ofSize: pointSize, weight: $0) }
            + weights.map { PlatformFont.monospacedSystemFont(ofSize: pointSize, weight: $0) }
        self.insetScale = insetScale
    }

    package func width(of line: PreparedTableColumnSample) -> Double {
        let weight = line.isBold ? 2 : (line.isSemibold ? 1 : 0)
        let font = fonts[(line.isMonospaced ? 3 : 0) + weight]
        let string = NSAttributedString(string: line.text, attributes: [.font: font])
        let ctLine = CTLineCreateWithAttributedString(string)
        let text = Double(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
        return text + line.scaledInset * insetScale + line.fixedInset
    }
}
