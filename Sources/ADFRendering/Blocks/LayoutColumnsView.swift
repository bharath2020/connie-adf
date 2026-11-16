import SwiftUI
import ADFPreparation

/// Multi-column layout section: columns side-by-side at their prepared width
/// percentages, collapsing to a vertical stack at compact horizontal size
/// class (iOS) or accessibility Dynamic Type sizes.
struct LayoutColumnsView: View {
    let columns: [PreparedColumn]

    @Environment(\.adfTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.adfTextWidthBound) private var widthBound
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        if isCollapsed {
            // Stacked columns have no inset: each is proposed the section's
            // width, so the section's bound holds for every column.
            VStack(alignment: .leading, spacing: theme.spacing * 2) {
                ForEach(columns, id: \.id) { column in
                    LayoutColumnContentView(column: column, sideBySide: false, widthBound: widthBound)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let fractions = self.fractions
            let spacing = theme.spacing * 2
            ProportionalColumnsLayout(fractions: fractions, spacing: spacing) {
                ForEach(columns, id: \.id) { column in
                    LayoutColumnContentView(
                        column: column, sideBySide: true,
                        widthBound: sideBySideBound(of: column, fractions: fractions, spacing: spacing)
                    )
                }
            }
        }
    }

    /// A side-by-side column's width bound: its share of the section's
    /// bound, as the layout divides the section's width
    /// (`ProportionalColumnsLayout.columnWidths`). The share grows with the
    /// width it is taken of, so a share of a lower bound is a lower bound.
    private func sideBySideBound(of column: PreparedColumn, fractions: [Double], spacing: CGFloat) -> TextKit2WidthBound {
        guard let index = columns.firstIndex(where: { $0.id == column.id }) else { return .unproven }
        return widthBound.mapWidth { width in
            let widths = ProportionalColumnsLayout.columnWidths(totalWidth: width, fractions: fractions, spacing: spacing)
            return index < widths.count ? widths[index] : 0
        }
    }

    private var isCollapsed: Bool {
        if dynamicTypeSize.isAccessibilitySize { return true }
        #if os(iOS)
        if horizontalSizeClass == .compact { return true }
        #endif
        return false
    }

    /// Column width percentages normalized to fractions of 1. Malformed
    /// totals (zero or negative) fall back to equal columns.
    private var fractions: [Double] {
        let total = columns.reduce(0) { $0 + max($1.widthPercent, 0) }
        guard total > 0 else {
            return Array(repeating: 1 / Double(max(columns.count, 1)), count: columns.count)
        }
        return columns.map { max($0.widthPercent, 0) / total }
    }
}

/// One column's prepared blocks, top-aligned. `sideBySide`: the column is
/// laid out beside its siblings (`ProportionalColumnsLayout`), not stacked;
/// `widthBound`: the bound the section computed for this column's blocks.
struct LayoutColumnContentView: View {
    let column: PreparedColumn
    let sideBySide: Bool
    let widthBound: TextKit2WidthBound

    @Environment(\.adfTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing) {
            ForEach(column.blocks) { block in
                BlockView(block: block)
                    .adfContainerChild(block, in: .column(sideBySide: sideBySide), widthBound: widthBound)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Horizontal layout dividing the proposed width between children by fixed
/// fractions (top-aligned; height is the tallest column).
struct ProportionalColumnsLayout: Layout {
    let fractions: [Double]
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        guard let totalWidth = proposal.width, totalWidth.isFinite else {
            // Ideal-size query: sum of children's ideal sizes.
            var width: CGFloat = spacing * CGFloat(subviews.count - 1)
            var height: CGFloat = 0
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                width += size.width
                height = max(height, size.height)
            }
            return CGSize(width: width, height: height)
        }
        let widths = Self.columnWidths(totalWidth: totalWidth, fractions: fractions, spacing: spacing, count: subviews.count)
        var height: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(ProposedViewSize(width: widths[index], height: nil))
            height = max(height, size.height)
        }
        return CGSize(width: totalWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let widths = Self.columnWidths(totalWidth: bounds.width, fractions: fractions, spacing: spacing, count: subviews.count)
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: widths[index], height: nil)
            )
            x += widths[index] + spacing
        }
    }

    /// The width of each of `fractions.count` columns laid out side by side
    /// in `totalWidth`, `spacing` apart: each column's fraction of what the
    /// gaps leave (`LayoutColumnsView` normalises the fractions to sum to 1).
    /// The layout divides its width with it, and the section's width bound
    /// for each column is the same share of the section's bound.
    static func columnWidths(totalWidth: CGFloat, fractions: [Double], spacing: CGFloat) -> [CGFloat] {
        columnWidths(totalWidth: totalWidth, fractions: fractions, spacing: spacing, count: fractions.count)
    }

    /// The widths of `count` columns: a column past the end of `fractions`
    /// takes an equal share.
    private static func columnWidths(totalWidth: CGFloat, fractions: [Double], spacing: CGFloat, count: Int) -> [CGFloat] {
        let available = max(totalWidth - spacing * CGFloat(max(count - 1, 0)), 0)
        return (0..<count).map { index in
            let fraction = index < fractions.count ? fractions[index] : 1 / Double(count)
            return available * CGFloat(fraction)
        }
    }
}
