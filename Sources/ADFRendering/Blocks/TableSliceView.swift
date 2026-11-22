import SwiftUI
import ADFModel
import ADFPreparation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// One virtualized slice of a table: the header row, or a small batch of
/// data rows (`TablePreparer` splits big tables so they stay lazy and each
/// slice materializes within one frame budget).
///
/// The look (Direction A, ADF-TBL1 B1a): content-aware column widths,
/// hairline row separators only (no outer box, no vertical grid lines but
/// the 1 pt line after a header column), an opaque header-row fill with a
/// 1 pt separator under it, numeric columns trailing-aligned, rowspans
/// merged by placement (`PreparedTableRow.cellColumns` / `continuations`),
/// a trailing fade while more columns remain, a header column pinned while
/// the table scrolls, and 8 pt page spacing above and below the table
/// (12 pt total next to a paragraph, whose own padding adds 4 pt).
///
/// The slice wraps in a horizontal `ScrollView` sized to the resolved column
/// widths, so wide tables pan instead of squeezing. Slices of one table must
/// pan together (they are separate lazy rows, yet read as one table): on
/// iOS 18+ they share a horizontal offset through `TableScrollSync`. iOS 17
/// lacks the `ScrollPosition` content-offset API, so there each slice pans
/// independently (documented floor).
///
/// The fade, the pinned column and its shadow follow the slice's OWN scroll
/// offset through `visualEffect` (render-time geometry, iOS 17+): no
/// `@State`, no body invalidation per frame, nothing bound to scroll
/// visibility — and identical across synced slices because their offsets
/// are.
struct TableSliceView: View {
    let tableID: String
    let layout: PreparedTableLayout
    let rows: [PreparedTableRow]
    let isHeaderSlice: Bool

    @Environment(\.adfTableScrollSync) private var scrollSync
    @Environment(\.adfTablePinnedHeader) private var isPinnedHeader

    var body: some View {
        let top = topSpacing
        let bottom = bottomSpacing
        // Only a table's first and last slices carry spacing; the rest skip
        // the padding layout entirely (a slice is measured on every lazy
        // stack pass, §8 hitch budget). The branch is stable per slice.
        if top == 0 && bottom == 0 {
            slice
        } else {
            slice.padding(EdgeInsets(top: top, leading: 0, bottom: bottom, trailing: 0))
        }
    }

    @ViewBuilder
    private var slice: some View {
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

    /// 8 pt above the table, on its first slice. Not on a header slice
    /// pinned by the document (it would pin as a blank band above the
    /// header): `ADFDocumentView` puts that gap in the previous section's
    /// footer, which scrolls away normally.
    private var topSpacing: CGFloat {
        guard rows.first?.index == 0 else { return 0 }
        if isHeaderSlice && isPinnedHeader { return 0 }
        return TableStyle.pageGap
    }

    /// 8 pt below the table, on the slice holding its last row.
    private var bottomSpacing: CGFloat {
        guard layout.rowCount > 0, rows.last?.index == layout.rowCount - 1 else { return 0 }
        return TableStyle.pageGap
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

    /// Starts at the width the last measured slice reported
    /// (`TableContainerWidthMemo`), not 0: slices of a document share one
    /// width, so a newly materialized slice lays out once at its real
    /// widths instead of laying out at zero and again a frame later (with
    /// the fade inserted on the second pass).
    @State private var containerWidth = TableContainerWidthMemo.lastWidth
    /// Dynamic Type size: the current body point size (17 at the default
    /// size) comes from it (`TableBodyPointSize`). Column clamps scale by
    /// that size / 17, and a non-default size re-measures the layout's
    /// width samples at it.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .footnote) private var numberColumnWidth: CGFloat = TableMetrics.numberColumnWidth
    @Environment(\.adfTheme) private var theme
    @Environment(\.pixelLength) private var pixelLength

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
        let metrics = sliceMetrics
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows, id: \.id) { row in
                    TableRowView(row: row, metrics: metrics, isHeaderRow: isHeaderSlice)
                }
            }
            .overlay(alignment: .trailing) {
                // Only a table wider than its slice can overflow; one that
                // fits carries no fade (and no per-frame effect) at all.
                if metrics.scrolls {
                    TableOverflowFade()
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
            TableContainerWidthMemo.lastWidth = width
        }
    }

    /// Column widths and the pin decision for this slice: pure functions of
    /// the table's shared layout, the container width and the type size
    /// (`TableColumnSizing`), so every slice of a table resolves the same
    /// values. The only measurement — re-measuring a few width samples at a
    /// non-default type size — is cached per table content and size.
    private var sliceMetrics: TableSliceMetrics {
        let gutter = layout.hasNumberColumn ? numberColumnWidth : 0
        let bodyPointSize = TableBodyPointSize.pointSize(for: dynamicTypeSize)
        let scale = Double(bodyPointSize) / TableColumnSizing.basePointSize
        let columnCount = max(layout.columnCount, 1)
        let natural: [Double]
        if let authored = layout.columnWidths, authored.count == columnCount {
            natural = []
        } else if abs(scale - 1) < 0.01 {
            natural = layout.naturalColumnWidths
        } else {
            natural = TableNaturalWidthCache.naturalWidths(
                for: layout, pointSize: Double(theme.bodyPointSize) * scale, insetScale: scale
            )
        }
        let widths = TableColumnSizing.columnWidths(
            natural: natural,
            numeric: layout.numericColumns,
            authored: layout.columnWidths,
            columnCount: layout.columnCount,
            availableWidth: Double(max(containerWidth - gutter, 0)),
            scale: scale
        )
        let pins = TableColumnSizing.pinsHeaderColumn(
            columnWidths: widths,
            gutterWidth: Double(gutter),
            containerWidth: Double(containerWidth),
            hasHeaderColumn: layout.hasHeaderColumn
        )
        let totalWidth = Double(gutter) + widths.reduce(0, +)
        return TableSliceMetrics(
            columnWidths: widths.map { CGFloat($0) },
            gutterWidth: gutter,
            scrolls: containerWidth > 0 && totalWidth > Double(containerWidth) + 0.5,
            hasHeaderRow: layout.hasHeaderRow,
            hasHeaderColumn: layout.hasHeaderColumn,
            pinsHeaderColumn: pins,
            numericColumns: layout.numericColumns,
            hairline: pixelLength
        )
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
    /// Width given to a cell past the declared column count (malformed
    /// rows), so nothing collapses to zero: the content-aware minimum.
    static let minColumnWidth = CGFloat(TableColumnSizing.minColumnWidth)
    /// Width of the numbered-row gutter column (scaled via `@ScaledMetric`).
    static let numberColumnWidth: CGFloat = 44
    /// Cell padding: 10 pt horizontal, 8 pt vertical.
    static let cellHorizontalPadding = CGFloat(TableColumnSizing.cellHorizontalPadding)
    static let cellVerticalPadding = CGFloat(TableColumnSizing.cellVerticalPadding)
    static let cellPadding = EdgeInsets(
        top: cellVerticalPadding, leading: cellHorizontalPadding,
        bottom: cellVerticalPadding, trailing: cellHorizontalPadding
    )
}

/// Direction A table colors and fixed geometry.
enum TableStyle {
    /// Opaque tertiary-system-fill look behind the header row.
    static let headerFill = dynamicColor(
        light: .init(red: 0xF0, green: 0xF0, blue: 0xF2), dark: .init(red: 0x1C, green: 0x1C, blue: 0x1E)
    )
    /// 1 pt separators: under the header row and after the header column.
    static let headerSeparator = dynamicColor(
        light: .init(red: 0xC6, green: 0xC6, blue: 0xC8), dark: .init(red: 0x38, green: 0x38, blue: 0x3A)
    )
    /// Hairline row separators.
    static let rowSeparator = dynamicColor(
        light: .init(red: 60, green: 60, blue: 67, alpha: 0.22), dark: .init(red: 84, green: 84, blue: 88, alpha: 0.6)
    )
    /// Number gutter fill in body rows (unchanged from main).
    static let gutterFill = Color.gray.opacity(0.06)
    /// Page spacing above and below a table. A paragraph's own 4 pt
    /// vertical padding adds to it, so paragraph→table and table→paragraph
    /// read 12 pt in total.
    static let pageGap: CGFloat = 8
    /// Trailing overflow fade width.
    static let fadeWidth: CGFloat = 28
    /// Soft shadow trailing a pinned header column once scrolled.
    static let pinnedShadowWidth: CGFloat = 8

    struct RGBA: Sendable {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat

        /// Components 0–255, alpha 0–1.
        init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
            self.red = red / 255
            self.green = green / 255
            self.blue = blue / 255
            self.alpha = alpha
        }
    }

    private static func dynamicColor(light: RGBA, dark: RGBA) -> Color {
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
        })
        #elseif canImport(AppKit)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
        })
        #else
        return Color(red: light.red, green: light.green, blue: light.blue, opacity: light.alpha)
        #endif
    }
}

/// The container width the most recently measured table slice reported:
/// the initial width of the next slice to materialize (usually exact —
/// the slices of a document share its width — and corrected by that
/// slice's own measurement when not).
@MainActor
enum TableContainerWidthMemo {
    static var lastWidth: CGFloat = 0
}

/// The `.body` text style's point size at a Dynamic Type size, exactly as
/// the body text in the cells resolves it (`UIFont.preferredFont`).
/// `@ScaledMetric(relativeTo: .body)` of 17 is not exact at accessibility
/// sizes (about 32 pt where body text is 33 pt at AX2), which left column 0
/// a few points short and wrapped "Component" mid-word. Cached per size.
@MainActor
enum TableBodyPointSize {
    private static var cache: [DynamicTypeSize: CGFloat] = [:]

    static func pointSize(for size: DynamicTypeSize) -> CGFloat {
        if let cached = cache[size] { return cached }
        #if canImport(UIKit)
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
        let pointSize = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits).pointSize
        #else
        let pointSize = CGFloat(TableColumnSizing.basePointSize)
        #endif
        cache[size] = pointSize
        return pointSize
    }
}

/// Re-measured natural widths for a non-default type size, cached by table
/// content (its width samples) and point size, so the slices of a table
/// measure once per size between them — not per slice, never per scroll.
@MainActor
enum TableNaturalWidthCache {
    private struct Key: Hashable {
        let samples: [[PreparedTableColumnSample]]
        let pointSize: Double
        let insetScale: Double
    }

    private static var entries: [Key: [Double]] = [:]
    private static let capacity = 64

    static func naturalWidths(for layout: PreparedTableLayout, pointSize: Double, insetScale: Double) -> [Double] {
        guard !layout.columnSamples.isEmpty else { return layout.naturalColumnWidths }
        let key = Key(
            samples: layout.columnSamples,
            pointSize: (pointSize * 4).rounded() / 4,
            insetScale: insetScale
        )
        if let cached = entries[key] { return cached }
        let measurer = TableTextMeasurer(pointSize: CGFloat(key.pointSize), insetScale: key.insetScale)
        let widths = TableColumnAnalysis.naturalWidths(
            samples: layout.columnSamples,
            padding: TableColumnSizing.cellHorizontalPadding * 2,
            measure: measurer.width(of:)
        )
        if entries.count >= capacity { entries.removeAll(keepingCapacity: true) }
        entries[key] = widths
        return widths
    }
}

/// What every row of a slice shares: resolved widths and the table-level
/// flags. Built once per slice body evaluation.
struct TableSliceMetrics {
    /// Data column widths (without the number gutter).
    let columnWidths: [CGFloat]
    /// Number gutter width, 0 without a number column.
    let gutterWidth: CGFloat
    /// The columns are wider than the slice: it scrolls horizontally.
    let scrolls: Bool
    let hasHeaderRow: Bool
    let hasHeaderColumn: Bool
    let pinsHeaderColumn: Bool
    let numericColumns: [Bool]
    let hairline: CGFloat
    /// Grid widths as `TableRowLayout` places them: the gutter (when
    /// present) is grid column 0 and data column `c` is grid column
    /// `c + columnOffset`.
    let gridWidths: [CGFloat]
    let columnOffset: Int

    init(
        columnWidths: [CGFloat],
        gutterWidth: CGFloat,
        scrolls: Bool,
        hasHeaderRow: Bool,
        hasHeaderColumn: Bool,
        pinsHeaderColumn: Bool,
        numericColumns: [Bool],
        hairline: CGFloat
    ) {
        self.columnWidths = columnWidths
        self.gutterWidth = gutterWidth
        self.scrolls = scrolls
        self.hasHeaderRow = hasHeaderRow
        self.hasHeaderColumn = hasHeaderColumn
        self.pinsHeaderColumn = pinsHeaderColumn
        self.numericColumns = numericColumns
        self.hairline = hairline
        self.columnOffset = gutterWidth > 0 ? 1 : 0
        self.gridWidths = gutterWidth > 0 ? [gutterWidth] + columnWidths : columnWidths
    }

    /// Row index of the first body row (no top divider above it: the header
    /// separator, or nothing in a headerless table).
    var firstBodyRowIndex: Int { hasHeaderRow ? 1 : 0 }

    /// Width of the gutter plus the first column: the pinned group, and the
    /// x of the header-column separator.
    var leadingGroupWidth: CGFloat { gutterWidth + (columnWidths.first ?? 0) }

    func isNumeric(column: Int) -> Bool {
        column >= 0 && column < numericColumns.count && numericColumns[column]
    }
}

/// One table row placed by `TableRowLayout` (plus the optional number
/// gutter, which participates as an extra leading grid column).
///
/// With a pinned header column, the column-0 cell, the gutter, an opaque
/// backdrop and a trailing shadow stay inside the row's layout (so they
/// share its height) and are shifted by the scroll offset at render time
/// (`TableStickyLeading`), drawn above the scrolling cells.
struct TableRowView: View {
    let row: PreparedTableRow
    let metrics: TableSliceMetrics
    let isHeaderRow: Bool

    var body: some View {
        TableRowLayout(columnWidths: metrics.gridWidths) {
            if metrics.pinsHeaderColumn {
                pinnedRowContent
            } else {
                // The common path: one placed view per cell and the gutter,
                // no per-cell conditionals (each extra node is paid on every
                // row a scroll materializes, §8 hitch budget).
                if metrics.gutterWidth > 0 {
                    TableNumberCellView(text: numberText)
                        .layoutValue(key: TableCellPlacementKey.self, value: TableCellPlacement(column: 0))
                }
                ForEach(row.cells.indices, id: \.self) { index in
                    cellView(at: index)
                }
            }
        }
        // Fills and dividers draw once per row as flat layers behind the
        // placed cells — keeping them out of the cell subviews lets
        // `TableRowLayout` place every cell with the same proposal it
        // measured with (one cached text layout per cell instead of two,
        // §8 hitch budget).
        .background {
            TableRowUnderlay(
                layers: underlayLayers,
                showsHeaderRowSeparator: isHeaderRow,
                headerColumnSeparatorX: metrics.hasHeaderColumn && !metrics.pinsHeaderColumn
                    ? metrics.leadingGroupWidth : nil
            )
        }
        .accessibilityElement(children: .contain)
    }

    /// Row content while the header column is pinned: the scrolling cells,
    /// then the opaque backdrop and shadow, the gutter and the column-0
    /// cell, each shifted by the scroll offset at render time.
    @ViewBuilder
    private var pinnedRowContent: some View {
        let pinnedIndex = pinnedCellIndex
        ForEach(row.cells.indices, id: \.self) { index in
            if index != pinnedIndex {
                cellView(at: index)
            }
        }
        TablePinnedBackdrop(
            gutterWidth: metrics.gutterWidth,
            gutterFill: gutterFill,
            cellFill: columnZeroFill,
            gutterShowsTopDivider: showsTopDivider,
            cellShowsTopDivider: showsTopDivider && !columnZeroIsContinuation,
            showsHeaderSeparator: isHeaderRow,
            hairline: metrics.hairline
        )
        .modifier(TableStickyLeading(originX: 0))
        .zIndex(1)
        .layoutValue(
            key: TableCellPlacementKey.self,
            value: TableCellPlacement(column: 0, span: metrics.columnOffset + 1, fillsRow: true)
        )

        TablePinnedShadow()
            .modifier(TableStickyLeading(originX: metrics.leadingGroupWidth, revealsWhenScrolled: true))
            .zIndex(1)
            .layoutValue(
                key: TableCellPlacementKey.self,
                value: TableCellPlacement(
                    column: metrics.columnOffset + 1, fillsRow: true, fixedWidth: TableStyle.pinnedShadowWidth
                )
            )
        if metrics.gutterWidth > 0 {
            TableNumberCellView(text: numberText)
                .modifier(TableStickyLeading(originX: 0))
                .zIndex(2)
                .layoutValue(key: TableCellPlacementKey.self, value: TableCellPlacement(column: 0))
        }
        if let pinnedIndex {
            cellContent(at: pinnedIndex)
                .modifier(TableStickyLeading(originX: metrics.gutterWidth))
                .zIndex(2)
                .layoutValue(
                    key: TableCellPlacementKey.self,
                    value: TableCellPlacement(column: metrics.columnOffset, valign: row.cells[pinnedIndex].valign)
                )
        }
    }

    /// A scrolling cell with its placement (one layout value, outermost, so
    /// it reaches `TableRowLayout` directly).
    private func cellView(at index: Int) -> some View {
        let cell = row.cells[index]
        let startColumn = column(at: index)
        return cellContent(at: index)
            .layoutValue(
                key: TableCellPlacementKey.self,
                value: TableCellPlacement(
                    column: startColumn + metrics.columnOffset, span: max(cell.colspan, 1), valign: cell.valign
                )
            )
    }

    private func cellContent(at index: Int) -> TableCellView {
        let cell = row.cells[index]
        let startColumn = column(at: index)
        return TableCellView(cell: cell, isNumeric: cell.colspan <= 1 && metrics.isNumeric(column: startColumn))
    }

    /// Data column a cell starts at (preparation's placement; sequential for
    /// a row built without one).
    private func column(at index: Int) -> Int {
        if index < row.cellColumns.count { return row.cellColumns[index] }
        return row.cells.prefix(index).reduce(0) { $0 + max($1.colspan, 1) }
    }

    private var pinnedCellIndex: Int? {
        row.cells.indices.first { column(at: $0) == 0 }
    }

    private var columnZeroIsContinuation: Bool {
        pinnedCellIndex == nil && row.continuations.contains { $0.column == 0 }
    }

    /// A body row draws a hairline above itself, except the first body row
    /// (it sits under the header separator, or tops a headerless table).
    private var showsTopDivider: Bool {
        !isHeaderRow && row.index > metrics.firstBodyRowIndex
    }

    private var gutterFill: Color? {
        isHeaderRow ? TableStyle.headerFill : TableStyle.gutterFill
    }

    private var columnZeroFill: Color? {
        if let index = pinnedCellIndex { return fill(for: row.cells[index]) }
        if let continuation = row.continuations.first(where: { $0.column == 0 }) {
            return fill(for: continuation)
        }
        return nil
    }

    /// Author fills win; otherwise only the header row is filled (header
    /// cells in body rows — a header column — are semibold with no fill).
    private func fill(for cell: PreparedTableCell) -> Color? {
        if let hex = cell.backgroundHex, let color = Color(adfHex: hex) {
            return color
        }
        return isHeaderRow && cell.isHeader ? TableStyle.headerFill : nil
    }

    /// A rowspan continuation repeats its spanning cell's fill.
    private func fill(for continuation: PreparedTableContinuation) -> Color? {
        if let hex = continuation.backgroundHex, let color = Color(adfHex: hex) {
            return color
        }
        let spansFromHeaderRow = metrics.hasHeaderRow && continuation.originRow == 0
        return spansFromHeaderRow && continuation.isHeader ? TableStyle.headerFill : nil
    }

    /// The row's fills and top dividers as flat layers, left to right
    /// across every grid column: a fill only where a cell, the gutter or a
    /// rowspan continuation has one, and the hairline as merged runs that
    /// skip continuations (so a merged cell reads as one). A plain row is a
    /// single divider layer.
    private var underlayLayers: [TableRowUnderlay.Layer] {
        struct Item {
            let start: Int
            let span: Int
            let fill: Color?
            let showsTopDivider: Bool
        }
        let divider = showsTopDivider
        let offset = metrics.columnOffset
        var items: [Item] = []
        items.reserveCapacity(row.cells.count + row.continuations.count + 1)
        if offset > 0 {
            items.append(Item(start: 0, span: 1, fill: gutterFill, showsTopDivider: divider))
        }
        for index in row.cells.indices {
            let cell = row.cells[index]
            items.append(Item(
                start: column(at: index) + offset,
                span: max(cell.colspan, 1),
                fill: fill(for: cell),
                showsTopDivider: divider
            ))
        }
        for continuation in row.continuations {
            items.append(Item(
                start: continuation.column + offset,
                span: max(continuation.colspan, 1),
                fill: fill(for: continuation),
                showsTopDivider: false
            ))
        }
        items.sort { $0.start < $1.start }

        let widths = metrics.gridWidths
        var layers: [TableRowUnderlay.Layer] = []
        var runStart: CGFloat?
        var x: CGFloat = 0
        func extendRun(_ shows: Bool) {
            if shows {
                if runStart == nil { runStart = x }
            } else if let start = runStart {
                layers.append(.init(x: start, width: x - start, kind: .divider))
                runStart = nil
            }
        }
        var cursor = 0
        for item in items where item.start >= cursor {
            if item.start > cursor {
                // Blank filler for positions a malformed row leaves empty.
                extendRun(divider)
                x += TableRowLayout.width(ofColumns: cursor, span: item.start - cursor, in: widths)
            }
            let width = TableRowLayout.width(ofColumns: item.start, span: item.span, in: widths)
            extendRun(item.showsTopDivider)
            if let fill = item.fill {
                layers.append(.init(x: x, width: width, kind: .fill(fill)))
            }
            x += width
            cursor = item.start + item.span
        }
        if cursor < widths.count {
            extendRun(divider)
            x += TableRowLayout.width(ofColumns: cursor, span: widths.count - cursor, in: widths)
        }
        extendRun(false)
        return layers
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

/// Read-only gutter cell for `isNumberColumnEnabled` tables (fill and
/// dividers come from the row's `TableRowUnderlay` or pinned backdrop).
struct TableNumberCellView: View {
    let text: String

    @Environment(\.adfTheme) private var theme

    var body: some View {
        Text(text)
            .font(.footnote.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(theme.spacing * 0.75)
            .frame(maxWidth: .infinity, alignment: .top)
    }
}

/// One row's fills and dividers, laid behind the placed cells as plain
/// color layers (deliberately not a `Canvas`: rasterizing a bitmap per
/// row is far more expensive than flat `Rectangle` layers, §7c). Only the
/// layers that draw something exist — fills where a cell has one, the
/// hairline as merged runs — so a plain row is one layer; each is offset
/// at render time, not laid out. Cell content stays at its measured
/// natural height while fills and dividers always cover the full row
/// height — an empty cell is blank at full row height with its divider
/// kept.
struct TableRowUnderlay: View {
    struct Layer {
        enum Kind {
            case fill(Color)
            /// Hairline along the top edge (the row separator).
            case divider
        }

        let x: CGFloat
        let width: CGFloat
        let kind: Kind
    }

    let layers: [Layer]
    /// 1 pt separator under the header row.
    let showsHeaderRowSeparator: Bool
    /// x of the 1 pt line after an unpinned header column (`nil`: none;
    /// a pinned column's backdrop draws its own).
    let headerColumnSeparatorX: CGFloat?

    @Environment(\.pixelLength) private var hairline

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(layers.indices, id: \.self) { index in
                layer(layers[index])
            }
            if showsHeaderRowSeparator {
                Rectangle()
                    .fill(TableStyle.headerSeparator)
                    .frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            if let x = headerColumnSeparatorX {
                Rectangle()
                    .fill(TableStyle.headerSeparator)
                    .frame(width: 1)
                    .offset(x: x - 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func layer(_ layer: Layer) -> some View {
        switch layer.kind {
        case .fill(let color):
            Rectangle()
                .fill(color)
                .frame(width: layer.width)
                .offset(x: layer.x)
        case .divider:
            Rectangle()
                .fill(TableStyle.rowSeparator)
                .frame(width: layer.width, height: hairline)
                .offset(x: layer.x)
        }
    }
}

/// Opaque backing of a pinned header column in one row (gutter plus column
/// 0): page background under the cell's own fill, so scrolled cells pass
/// beneath it, with the row's dividers redrawn on top and the 1 pt
/// separator along its trailing edge.
struct TablePinnedBackdrop: View {
    let gutterWidth: CGFloat
    let gutterFill: Color?
    let cellFill: Color?
    let gutterShowsTopDivider: Bool
    let cellShowsTopDivider: Bool
    let showsHeaderSeparator: Bool
    let hairline: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            if gutterWidth > 0 {
                part(fill: gutterFill, showsTopDivider: gutterShowsTopDivider)
                    .frame(width: gutterWidth)
            }
            part(fill: cellFill, showsTopDivider: cellShowsTopDivider)
        }
        .background(Rectangle().fill(.background))
        .overlay(alignment: .bottom) {
            if showsHeaderSeparator {
                Rectangle()
                    .fill(TableStyle.headerSeparator)
                    .frame(height: 1)
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(TableStyle.headerSeparator)
                .frame(width: 1)
        }
        .accessibilityHidden(true)
    }

    private func part(fill: Color?, showsTopDivider: Bool) -> some View {
        Rectangle()
            .fill(fill ?? Color.clear)
            .overlay(alignment: .top) {
                if showsTopDivider {
                    Rectangle()
                        .fill(TableStyle.rowSeparator)
                        .frame(height: hairline)
                }
            }
    }
}

/// Soft shadow trailing a pinned header column; revealed only once the
/// table is scrolled (`TableStickyLeading(revealsWhenScrolled:)`).
struct TablePinnedShadow: View {
    var body: some View {
        LinearGradient(
            colors: [Color.black.opacity(0.12), Color.black.opacity(0)],
            startPoint: .leading,
            endPoint: .trailing
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 28 pt fade from clear to the page background at the visible trailing
/// edge of a slice's scroll content while more columns remain to the
/// right; gone at the end (and on a table that fits). Positioned and faded
/// by `visualEffect` from the scroll view's own geometry — render-time
/// only, no state.
struct TableOverflowFade: View {
    var body: some View {
        Rectangle()
            .fill(.background)
            .mask {
                LinearGradient(colors: [Color.black.opacity(0), Color.black], startPoint: .leading, endPoint: .trailing)
            }
            .frame(width: TableStyle.fadeWidth)
            .visualEffect { effect, proxy in
                let remaining = TableScrollGeometry.trailingOverflow(
                    visibleMaxX: proxy.bounds(of: .scrollView(axis: .horizontal))?.maxX,
                    width: proxy.size.width
                )
                return effect
                    .offset(x: -max(remaining, 0))
                    .opacity(TableScrollGeometry.fadeOpacity(remaining: remaining, fadeWidth: proxy.size.width))
            }
            .allowsHitTesting(false)
    }
}

/// Keeps a pinned-column part at the visible leading edge of its slice's
/// horizontal scroll view: shifts it right by the scroll offset at render
/// time (`visualEffect`), so its layout — and the row height it shares —
/// never changes. `revealsWhenScrolled` also fades it in once the offset
/// passes 0 (the pinned column's shadow).
struct TableStickyLeading: ViewModifier {
    /// The part's x within the row at rest.
    let originX: CGFloat
    var isEnabled = true
    var revealsWhenScrolled = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            let restingX = originX
            let reveals = revealsWhenScrolled
            content.visualEffect { effect, proxy in
                let shift = TableScrollGeometry.stickyShift(
                    restingX: restingX,
                    minXInScrollView: proxy.frame(in: .scrollView(axis: .horizontal)).minX
                )
                return effect
                    .offset(x: shift)
                    .opacity(reveals ? TableScrollGeometry.shadowOpacity(shift: shift) : 1)
            }
        } else {
            content
        }
    }
}

/// Pure scroll-geometry math for the render-time table effects (callable
/// from `visualEffect`'s nonisolated closures).
enum TableScrollGeometry {
    /// How far a part laid out at `restingX` must shift to stay at the
    /// visible leading edge: the scroll offset, never negative (a leading
    /// bounce moves the column with the content).
    static func stickyShift(restingX: CGFloat, minXInScrollView: CGFloat) -> CGFloat {
        max(0, restingX - minXInScrollView)
    }

    /// Shadow fades in over the first 8 pt of scrolling.
    static func shadowOpacity(shift: CGFloat) -> Double {
        Double(min(max(shift / TableStyle.pinnedShadowWidth, 0), 1))
    }

    /// Content width left beyond the visible trailing edge, from the fade
    /// strip's own frame (laid out flush with the content's trailing edge):
    /// `width - visibleMaxX` in its local coordinates; 0 outside a scroll
    /// view.
    static func trailingOverflow(visibleMaxX: CGFloat?, width: CGFloat) -> CGFloat {
        guard let visibleMaxX else { return 0 }
        return width - visibleMaxX
    }

    static func fadeOpacity(remaining: CGFloat, fadeWidth: CGFloat) -> Double {
        guard remaining > 0.5, fadeWidth > 0 else { return 0 }
        return Double(min(remaining / fadeWidth, 1))
    }
}

/// One table cell: nested prepared blocks with background, header emphasis,
/// numeric alignment, and vertical alignment from the cell attrs.
struct TableCellView: View {
    let cell: PreparedTableCell
    /// In a numeric column: trailing-aligned with monospaced digits (the
    /// paragraphs themselves were trailing-aligned in preparation).
    var isNumeric = false

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

    @ViewBuilder
    private var styledContent: some View {
        if isNumeric {
            paddedContent.monospacedDigit()
        } else {
            paddedContent
        }
    }

    private var paddedContent: some View {
        content
            .fontWeight(cell.isHeader ? .semibold : nil)
            .padding(TableMetrics.cellPadding)
            .frame(maxWidth: .infinity, alignment: isNumeric ? .topTrailing : .topLeading)
    }

    /// Most cells hold exactly one block (a paragraph); rendering it without
    /// the stack wrapper keeps a 30-cell slice's view graph small enough to
    /// materialize inside one frame during scroll (§8 hitch budget). An
    /// empty cell keeps one blank line so an all-empty row keeps a text
    /// row's height.
    @ViewBuilder
    private var content: some View {
        if cell.blocks.count == 1, let only = cell.blocks.first {
            BlockView(block: only)
        } else if cell.blocks.isEmpty {
            Text(verbatim: " ")
                .font(theme.body)
                .accessibilityHidden(true)
        } else {
            VStack(alignment: .leading, spacing: theme.spacing * 0.5) {
                ForEach(cell.blocks) { block in
                    BlockView(block: block)
                }
            }
        }
    }
}

/// Where a subview sits inside `TableRowLayout`: start grid column,
/// colspan, vertical alignment (`nil` reads as top), whether it is a
/// decoration that takes the full row height without counting toward it
/// (pinned backdrop, shadow), and a fixed width overriding the spanned
/// columns' (the pinned shadow). One layout value per subview keeps each
/// materialized cell to a single extra modifier.
struct TableCellPlacement {
    var column: Int = 0
    var span: Int = 1
    var valign: ADFVAlign?
    var fillsRow = false
    var fixedWidth: CGFloat?
}

struct TableCellPlacementKey: LayoutValueKey {
    static let defaultValue = TableCellPlacement()
}

/// Places one row of table cells against fixed column widths, honoring each
/// cell's start column (rowspan placement leaves covered columns empty),
/// colspan (each cell's width is the sum of the columns it spans) and
/// `valign` (an offset from the row top; the row height is the tallest
/// cell's). Cells are placed with exactly the proposal they were measured
/// with, so SwiftUI's per-proposal size cache guarantees one layout pass per
/// cell — full-height backgrounds and dividers come from
/// `TableRowUnderlay`, not from stretching the cells. Row-filling
/// decorations (`TableCellFillsRowKey`) are not measured and are placed at
/// the full row height.
struct TableRowLayout: Layout {
    let columnWidths: [CGFloat]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        var width = columnWidths.reduce(0, +)
        var height: CGFloat = 0
        for subview in subviews {
            let placement = subview[TableCellPlacementKey.self]
            if placement.fillsRow { continue }
            let column = placement.column
            let span = max(placement.span, 1)
            let cellWidth = Self.width(ofColumns: column, span: span, in: columnWidths)
            let size = subview.sizeThatFits(ProposedViewSize(width: cellWidth, height: nil))
            height = max(height, size.height)
            width = max(width, Self.x(ofColumn: column, in: columnWidths) + cellWidth)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            let placement = subview[TableCellPlacementKey.self]
            let column = placement.column
            let span = max(placement.span, 1)
            let x = bounds.minX + Self.x(ofColumn: column, in: columnWidths)
            if placement.fillsRow {
                let width = placement.fixedWidth
                    ?? Self.width(ofColumns: column, span: span, in: columnWidths)
                subview.place(
                    at: CGPoint(x: x, y: bounds.minY),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: width, height: bounds.height)
                )
                continue
            }
            let cellWidth = Self.width(ofColumns: column, span: span, in: columnWidths)
            let cellProposal = ProposedViewSize(width: cellWidth, height: nil)
            var y = bounds.minY
            switch placement.valign {
            case .middle:
                y += (bounds.height - subview.sizeThatFits(cellProposal).height) / 2
            case .bottom:
                y += bounds.height - subview.sizeThatFits(cellProposal).height
            case .top, nil:
                break
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: cellProposal)
        }
    }

    /// Leading x of grid column `column`: the widths before it, plus the
    /// minimum width per column past the declared count (malformed rows).
    static func x(ofColumn column: Int, in columnWidths: [CGFloat]) -> CGFloat {
        let inside = min(max(column, 0), columnWidths.count)
        let beyond = max(column - columnWidths.count, 0)
        return columnWidths.prefix(inside).reduce(0, +) + CGFloat(beyond) * TableMetrics.minColumnWidth
    }

    /// Width of a cell spanning `span` columns starting at `startColumn`.
    /// Cells past the declared column count (malformed rows) get the minimum
    /// column width so nothing collapses to zero.
    static func width(ofColumns startColumn: Int, span: Int, in columnWidths: [CGFloat]) -> CGFloat {
        guard startColumn < columnWidths.count else {
            return TableMetrics.minColumnWidth
        }
        let end = min(startColumn + max(span, 1), columnWidths.count)
        return columnWidths[max(startColumn, 0)..<end].reduce(0, +)
    }
}
