import SwiftUI
import ADFPreparation

/// Blockquote: leading accent bar plus inset children.
struct QuoteBlockView: View {
    let blocks: [RenderBlock]

    @Environment(\.adfTheme) private var theme
    /// Accent bar thickness, scaled with Dynamic Type so the bar keeps its
    /// visual weight next to larger text.
    @ScaledMetric(relativeTo: .body) private var barWidth: CGFloat = 3

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing) {
            ForEach(blocks) { block in
                BlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, theme.spacing * 2)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: barWidth / 2)
                .fill(Color.secondary.opacity(0.35))
                .frame(width: barWidth)
        }
    }
}
