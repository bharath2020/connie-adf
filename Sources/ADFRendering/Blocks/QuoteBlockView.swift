import SwiftUI
import ADFPreparation

/// Blockquote: leading accent bar plus inset children.
struct QuoteBlockView: View {
    let blocks: [RenderBlock]

    @Environment(\.adfTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing) {
            ForEach(blocks) { block in
                BlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, theme.spacing * 2)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 3)
        }
    }
}
