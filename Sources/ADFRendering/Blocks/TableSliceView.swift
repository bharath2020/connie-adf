import SwiftUI
import ADFModel
import ADFPreparation

/// One virtualized slice of a table: the header row, or a batch of ≤20 data
/// rows (`TablePreparer` splits big tables so they stay lazy).
///
/// Colspan is honored exactly by `TableRowLayout`. Rowspan is the documented
/// v1 simplification: a spanning cell renders in its origin row only, so
/// content is never lost but the geometry doesn't merge vertically.
///
/// The slice wraps in a horizontal `ScrollView` sized to the resolved column
/// widths, so wide tables pan instead of squeezing. Each slice scrolls
/// independently (slices are separate lazy rows; shared offset is a
/// non-goal for v1).
struct TableSliceView: View {
    let layout: PreparedTableLayout
    let rows: [PreparedTableRow]
    let isHeaderSlice: Bool

    @Environment(\.adfTheme) private var theme
    @State private var containerWidth = CGFloat.zero

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows, id: \.id) { row in
                    TableRowView(
                        row: row,
                        columnWidths: resolvedColumnWidths,
                        hasNumberColumn: layout.hasNumberColumn,
                        isHeaderRow: isHeaderSlice
                    )
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            containerWidth = width
        }
    }

    /// Exact widths from `colwidth` attrs when complete; otherwise an equal
    /// split of the container width with a per-column minimum (which is what
    /// makes wide tables overflow into horizontal scrolling).
    private var resolvedColumnWidths: [CGFloat] {
        let count = max(layout.columnCount, 1)
        if let widths = layout.columnWidths, widths.count == count {
            return widths.map { CGFloat($0) }
        }
        let gutter = layout.hasNumberColumn ? TableMetrics.numberColumnWidth : 0
        let available = max(containerWidth - gutter, 0)
        let equal = available / CGFloat(count)
        return Array(repeating: max(equal, TableMetrics.minColumnWidth), count: count)
    }
}

/// Table sizing constants, nonisolated so both the (MainActor) views and the
/// (nonisolated) `TableRowLayout` can read them.
enum TableMetrics {
    /// Floor for measured columns when the table carries no `colwidth` attrs.
    static let minColumnWidth: CGFloat = 96
    /// Width of the numbered-row gutter column.
    static let numberColumnWidth: CGFloat = 44
}

/// One table row placed by `TableRowLayout` (plus the optional number
/// gutter, which participates as an extra leading column).
struct TableRowView: View {
    let row: PreparedTableRow
    let columnWidths: [CGFloat]
    let hasNumberColumn: Bool
    let isHeaderRow: Bool

    var body: some View {
        TableRowLayout(columnWidths: effectiveWidths) {
            if hasNumberColumn {
                TableNumberCellView(text: numberText)
            }
            ForEach(row.cells, id: \.id) { cell in
                TableCellView(cell: cell)
                    .layoutValue(key: TableCellSpanKey.self, value: max(cell.colspan, 1))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var effectiveWidths: [CGFloat] {
        hasNumberColumn ? [TableMetrics.numberColumnWidth] + columnWidths : columnWidths
    }

    /// Row ordinal parsed from the structural path ID (the row's child index
    /// within the table). With a header row at index 0, data rows read 1…n —
    /// matching Confluence numbering. Headerless numbered tables read from 0
    /// (documented simplification).
    private var numberText: String {
        guard !isHeaderRow else { return "" }
        guard let last = row.id.split(separator: ".").last, let index = Int(last) else {
            return ""
        }
        return String(index)
    }
}

/// Read-only gutter cell for `isNumberColumnEnabled` tables.
struct TableNumberCellView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.gray.opacity(0.06))
            .border(Color.gray.opacity(0.25), width: 0.5)
    }
}

/// One table cell: nested prepared blocks with background, header emphasis,
/// and vertical alignment from the cell attrs.
struct TableCellView: View {
    let cell: PreparedTableCell

    @Environment(\.adfTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing * 0.5) {
            ForEach(cell.blocks) { block in
                BlockView(block: block)
            }
        }
        .fontWeight(cell.isHeader ? .semibold : nil)
        .padding(theme.spacing)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: contentAlignment)
        .background(backgroundColor)
        .border(Color.gray.opacity(0.25), width: 0.5)
    }

    private var contentAlignment: Alignment {
        switch cell.valign {
        case .middle: return .leading
        case .bottom: return .bottomLeading
        case .top, nil: return .topLeading
        }
    }

    private var backgroundColor: Color {
        if let hex = cell.backgroundHex, let color = Color(adfHex: hex) {
            return color
        }
        return cell.isHeader ? Color.gray.opacity(0.08) : .clear
    }
}

/// Colspan of a cell subview inside `TableRowLayout`.
struct TableCellSpanKey: LayoutValueKey {
    static let defaultValue: Int = 1
}

/// Places one row of table cells against fixed column widths, honoring
/// colspan: each cell's width is the sum of the columns it spans, and every
/// cell is stretched to the row's height (tallest cell wins) so backgrounds
/// and grid lines fill the full cell box.
struct TableRowLayout: Layout {
    let columnWidths: [CGFloat]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        var column = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
        for subview in subviews {
            let span = max(subview[TableCellSpanKey.self], 1)
            let cellWidth = self.cellWidth(startColumn: column, span: span)
            let size = subview.sizeThatFits(ProposedViewSize(width: cellWidth, height: nil))
            width += cellWidth
            height = max(height, size.height)
            column += span
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var column = 0
        var x = bounds.minX
        for subview in subviews {
            let span = max(subview[TableCellSpanKey.self], 1)
            let cellWidth = self.cellWidth(startColumn: column, span: span)
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: cellWidth, height: bounds.height)
            )
            x += cellWidth
            column += span
        }
    }

    /// Width of a cell spanning `span` columns starting at `startColumn`.
    /// Cells past the declared column count (malformed rows) get the minimum
    /// column width so nothing collapses to zero.
    private func cellWidth(startColumn: Int, span: Int) -> CGFloat {
        guard startColumn < columnWidths.count else {
            return TableMetrics.minColumnWidth
        }
        let end = min(startColumn + span, columnWidths.count)
        return columnWidths[startColumn..<end].reduce(0, +)
    }
}
