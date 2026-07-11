import SwiftUI
import ADFModel
import ADFPreparation

/// One virtualized slice of a table: the header row, or a small batch of
/// data rows (`TablePreparer` splits big tables so they stay lazy and each
/// slice materializes within one frame budget).
///
/// Colspan is honored exactly by `TableRowLayout`. Rowspan is the documented
/// v1 simplification: a spanning cell renders in its origin row only, so
/// content is never lost but the geometry doesn't merge vertically.
///
/// The slice wraps in a horizontal `ScrollView` sized to the resolved column
/// widths, so wide tables pan instead of squeezing. Slices of one table must
/// pan together (they are separate lazy rows, yet read as one table): on
/// iOS 18+ they share a horizontal offset through `TableScrollSync`. iOS 17
/// lacks the `ScrollPosition` content-offset API, so there each slice pans
/// independently (documented floor).
struct TableSliceView: View {
    let tableID: String
    let layout: PreparedTableLayout
    let rows: [PreparedTableRow]
    let isHeaderSlice: Bool

    @Environment(\.adfTableScrollSync) private var scrollSync

    var body: some View {
        if #available(iOS 18.0, macOS 15.0, *), let scrollSync {
            SynchronizedTableSlice(
                tableID: tableID,
                layout: layout,
                rows: rows,
                isHeaderSlice: isHeaderSlice,
                scrollSync: scrollSync
            )
        } else {
            TableSliceScrollView(layout: layout, rows: rows, isHeaderSlice: isHeaderSlice)
        }
    }
}

/// The horizontal scroll view and its row content, without any cross-slice
/// synchronization. This is the whole slice on iOS 17, and the body that the
/// iOS 18+ synchronized slice layers offset-sharing modifiers onto.
private struct TableSliceScrollView<Modifiers: ViewModifier>: View {
    let layout: PreparedTableLayout
    let rows: [PreparedTableRow]
    let isHeaderSlice: Bool
    let scrollModifiers: Modifiers

    @State private var containerWidth = CGFloat.zero

    init(
        layout: PreparedTableLayout,
        rows: [PreparedTableRow],
        isHeaderSlice: Bool,
        scrollModifiers: Modifiers = EmptyModifier()
    ) {
        self.layout = layout
        self.rows = rows
        self.isHeaderSlice = isHeaderSlice
        self.scrollModifiers = scrollModifiers
    }

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
        .modifier(scrollModifiers)
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

/// iOS 18+ slice that keeps its horizontal offset in lockstep with the other
/// visible slices of the same table.
///
/// Only the slice the user is actively dragging or that is decelerating
/// publishes its `contentOffset.x` to the shared `TableScrollSync`; every
/// other visible slice follows via `ScrollPosition.scrollTo(x:)`. Two guards
/// break feedback loops: a follower never publishes (it isn't the driver),
/// and it only scrolls when the shared offset differs from its own by more
/// than half a point — so a value never scrolls its own author back. A slice
/// re-materializing into an already-panned table adopts the shared offset on
/// appear, lining up with the pinned header instead of resetting to column 0.
@available(iOS 18.0, macOS 15.0, *)
private struct SynchronizedTableSlice: View {
    let tableID: String
    let layout: PreparedTableLayout
    let rows: [PreparedTableRow]
    let isHeaderSlice: Bool
    let scrollSync: TableScrollSync

    @State private var position = ScrollPosition()
    @State private var currentX: CGFloat = 0
    @State private var isDriving = false

    var body: some View {
        TableSliceScrollView(
            layout: layout,
            rows: rows,
            isHeaderSlice: isHeaderSlice,
            scrollModifiers: SyncModifiers(
                position: $position,
                onOffsetChange: { x in
                    currentX = x
                    if isDriving { scrollSync.publish(x, for: tableID) }
                },
                onPhaseChange: { phase in
                    // A user-driven slice publishes; programmatic follows
                    // (`.animating`) and idle slices must not.
                    isDriving = phase == .interacting || phase == .decelerating
                }
            )
        )
        .onChange(of: scrollSync.sharedOffset(for: tableID)) { _, target in
            follow(target)
        }
        .onAppear {
            scrollSync.retain(tableID)
            follow(scrollSync.sharedOffset(for: tableID))
        }
        .onDisappear {
            scrollSync.release(tableID)
        }
    }

    private func follow(_ target: CGFloat?) {
        guard !isDriving, let target, abs(target - currentX) > 0.5 else { return }
        position.scrollTo(x: target)
    }
}

/// The offset-sharing modifiers layered onto a slice's scroll view: binds its
/// `ScrollPosition`, reports its content offset and scroll phase. Isolated in
/// a modifier gated to iOS 18 so `TableSliceScrollView` (and its iOS 17 use)
/// need not store an iOS-18-only `ScrollPosition`.
@available(iOS 18.0, macOS 15.0, *)
private struct SyncModifiers: ViewModifier {
    @Binding var position: ScrollPosition
    let onOffsetChange: (CGFloat) -> Void
    let onPhaseChange: (ScrollPhase) -> Void

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollPhaseChange { _, phase, _ in
                onPhaseChange(phase)
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.x
            } action: { _, x in
                onOffsetChange(x)
            }
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
                    .layoutValue(key: TableCellVAlignKey.self, value: cell.valign)
            }
        }
        // Grid lines and cell fills draw once per row in a single Canvas —
        // keeping them out of the cell subviews lets `TableRowLayout` place
        // every cell with the same proposal it measured with (one cached
        // text layout per cell instead of two, §8 hitch budget).
        .background { TableRowUnderlay(cells: decorations) }
        .accessibilityElement(children: .contain)
    }

    private var effectiveWidths: [CGFloat] {
        hasNumberColumn ? [TableMetrics.numberColumnWidth] + columnWidths : columnWidths
    }

    private var decorations: [TableRowUnderlay.Cell] {
        var cells: [TableRowUnderlay.Cell] = []
        cells.reserveCapacity(row.cells.count + 1)
        if hasNumberColumn {
            cells.append(.init(width: TableMetrics.numberColumnWidth, fill: Color.gray.opacity(0.06)))
        }
        var column = 0
        for cell in row.cells {
            let span = max(cell.colspan, 1)
            let width = TableRowLayout.width(ofColumns: column, span: span, in: columnWidths)
            cells.append(.init(width: width, fill: fillColor(for: cell)))
            column += span
        }
        return cells
    }

    private func fillColor(for cell: PreparedTableCell) -> Color? {
        if let hex = cell.backgroundHex, let color = Color(adfHex: hex) {
            return color
        }
        return cell.isHeader ? Color.gray.opacity(0.08) : nil
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

/// Read-only gutter cell for `isNumberColumnEnabled` tables (fill and grid
/// lines come from the row's `TableRowUnderlay`).
struct TableNumberCellView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .top)
    }
}

/// One row's grid lines and cell fills, laid behind the placed cells as
/// plain color layers (deliberately not a `Canvas`: rasterizing a bitmap per
/// row is far more expensive than flat `Rectangle` layers). Cell content
/// stays at its measured natural height while fills and borders always cover
/// the full row height.
struct TableRowUnderlay: View {
    struct Cell {
        let width: CGFloat
        let fill: Color?
    }

    let cells: [Cell]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(cells.indices, id: \.self) { index in
                Rectangle()
                    .fill(cells[index].fill ?? Color.clear)
                    .border(Color.gray.opacity(0.25), width: 0.5)
                    .frame(width: cells[index].width)
            }
        }
    }
}

/// One table cell: nested prepared blocks with background, header emphasis,
/// and vertical alignment from the cell attrs.
struct TableCellView: View {
    let cell: PreparedTableCell

    @Environment(\.adfTheme) private var theme

    var body: some View {
        // An author-supplied cell fill is a fixed color (Confluence palettes
        // are light pastels), while the default text color follows the color
        // scheme — white text on `#f4f5f7` in dark mode is illegible. Derive
        // the cell's foreground from the fill's luminance instead; runs with
        // explicit `textColor` marks keep their own attribute.
        if let contrast = cell.backgroundHex.flatMap({ ADFHexColor($0)?.contrastingForeground }) {
            styledContent.foregroundStyle(contrast)
        } else {
            styledContent
        }
    }

    private var styledContent: some View {
        content
            .fontWeight(cell.isHeader ? .semibold : nil)
            .padding(theme.spacing)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Most cells hold exactly one block (a paragraph); rendering it without
    /// the stack wrapper keeps a 30-cell slice's view graph small enough to
    /// materialize inside one frame during scroll (§8 hitch budget).
    @ViewBuilder
    private var content: some View {
        if cell.blocks.count == 1, let only = cell.blocks.first {
            BlockView(block: only)
        } else {
            VStack(alignment: .leading, spacing: theme.spacing * 0.5) {
                ForEach(cell.blocks) { block in
                    BlockView(block: block)
                }
            }
        }
    }
}

/// Colspan of a cell subview inside `TableRowLayout`.
struct TableCellSpanKey: LayoutValueKey {
    static let defaultValue: Int = 1
}

/// Vertical alignment of a cell subview inside `TableRowLayout` (`nil` reads
/// as top).
struct TableCellVAlignKey: LayoutValueKey {
    static let defaultValue: ADFVAlign? = nil
}

/// Places one row of table cells against fixed column widths, honoring
/// colspan (each cell's width is the sum of the columns it spans) and
/// `valign` (an offset from the row top; the row height is the tallest
/// cell's). Cells are placed with exactly the proposal they were measured
/// with, so SwiftUI's per-proposal size cache guarantees one layout pass per
/// cell — full-height backgrounds and grid lines come from
/// `TableRowUnderlay`, not from stretching the cells.
struct TableRowLayout: Layout {
    let columnWidths: [CGFloat]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        var column = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
        for subview in subviews {
            let span = max(subview[TableCellSpanKey.self], 1)
            let cellWidth = Self.width(ofColumns: column, span: span, in: columnWidths)
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
            let cellWidth = Self.width(ofColumns: column, span: span, in: columnWidths)
            let cellProposal = ProposedViewSize(width: cellWidth, height: nil)
            var y = bounds.minY
            switch subview[TableCellVAlignKey.self] {
            case .middle:
                y += (bounds.height - subview.sizeThatFits(cellProposal).height) / 2
            case .bottom:
                y += bounds.height - subview.sizeThatFits(cellProposal).height
            case .top, nil:
                break
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: cellProposal)
            x += cellWidth
            column += span
        }
    }

    /// Width of a cell spanning `span` columns starting at `startColumn`.
    /// Cells past the declared column count (malformed rows) get the minimum
    /// column width so nothing collapses to zero.
    static func width(ofColumns startColumn: Int, span: Int, in columnWidths: [CGFloat]) -> CGFloat {
        guard startColumn < columnWidths.count else {
            return TableMetrics.minColumnWidth
        }
        let end = min(startColumn + max(span, 1), columnWidths.count)
        return columnWidths[startColumn..<end].reduce(0, +)
    }
}
