import SwiftUI
import ADFPreparation

/// Tinted rounded container with a leading icon; palette resolved from the
/// panel type (info/note/tip/success/warning/error/custom) in preparation.
struct PanelBlockView: View {
    let palette: PanelPalette
    let blocks: [RenderBlock]

    @Environment(\.adfTheme) private var theme

    var body: some View {
        // Baseline alignment: the icon sits on the first line of text like a
        // leading glyph would; `.top` aligns the symbol's bounding box with
        // the line box instead, floating it above the cap height.
        HStack(alignment: .firstTextBaseline, spacing: theme.spacing * 1.5) {
            Image(systemName: palette.iconSystemName)
                .foregroundStyle(palette.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: theme.spacing) {
                ForEach(blocks) { block in
                    BlockView(block: block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(theme.spacing * 1.5)
        .background(RoundedRectangle(cornerRadius: theme.containerCornerRadius).fill(palette.background))
    }
}
