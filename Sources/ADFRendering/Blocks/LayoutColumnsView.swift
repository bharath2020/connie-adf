import SwiftUI
import ADFPreparation

/// Multi-column layout section: columns side-by-side at their prepared width
/// percentages, collapsing to a vertical stack at compact horizontal size
/// class (iOS) or accessibility Dynamic Type sizes.
struct LayoutColumnsView: View {
    let columns: [PreparedColumn]

    @Environment(\.adfTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        if isCollapsed {
            VStack(alignment: .leading, spacing: theme.spacing * 2) {
                ForEach(columns, id: \.id) { column in
                    LayoutColumnContentView(column: column)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ProportionalColumnsLayout(fractions: fractions, spacing: theme.spacing * 2) {
                ForEach(columns, id: \.id) { column in
                    LayoutColumnContentView(column: column)
                }
            }
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

/// One column's prepared blocks, top-aligned.
struct LayoutColumnContentView: View {
    let column: PreparedColumn

    @Environment(\.adfTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing) {
            ForEach(column.blocks) { block in
                BlockView(block: block)
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
        let widths = columnWidths(totalWidth: totalWidth, count: subviews.count)
        var height: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(ProposedViewSize(width: widths[index], height: nil))
            height = max(height, size.height)
        }
        return CGSize(width: totalWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let widths = columnWidths(totalWidth: bounds.width, count: subviews.count)
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

    private func columnWidths(totalWidth: CGFloat, count: Int) -> [CGFloat] {
        let available = max(totalWidth - spacing * CGFloat(max(count - 1, 0)), 0)
        return (0..<count).map { index in
            let fraction = index < fractions.count ? fractions[index] : 1 / Double(count)
            return available * CGFloat(fraction)
        }
    }
}
