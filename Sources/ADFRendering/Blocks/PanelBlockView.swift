import SwiftUI
import ADFPreparation

/// Tinted rounded container with a leading icon; palette resolved from the
/// panel type (info/note/tip/success/warning/error/custom) in preparation.
struct PanelBlockView: View {
    let palette: PanelPalette
    let blocks: [RenderBlock]

    @Environment(\.adfTheme) private var theme
    @Environment(\.adfTextWidthBound) private var widthBound
    @Environment(\.font) private var font
    @Environment(\.imageScale) private var imageScale
    /// An upper bound on the icon's laid-out width, for the children's
    /// width bound only (`childWidthBound`), never for layout: the icon has
    /// no frame and keeps its own width.
    @ScaledMetric(relativeTo: .body) private var iconWidthBound: CGFloat = PanelBlockView.iconWidthBoundBase

    var body: some View {
        let childBound = childWidthBound
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
                        .adfContainerChild(block, in: .panel, widthBound: childBound)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(theme.spacing * 1.5)
        .background(RoundedRectangle(cornerRadius: theme.containerCornerRadius).fill(palette.background))
    }

    /// The base (Large) value of `iconWidthBound`, scaled with Dynamic Type
    /// relative to body text: no wider than the widest of the palette's
    /// symbols (`boundedIconSymbols`) at any text size, with or without
    /// Bold Text, at 2x and 3x (`TextKit2ContainerWidthTests.panelIconBound`).
    /// Measured on iOS 26.3 at 2x and 3x and on iOS 18.5 at 3x: the widest
    /// symbol needs a base of 24.8 pt, a margin of at least 5 pt.
    static let iconWidthBoundBase: CGFloat = 28

    /// The icons `iconWidthBound` is measured for: the default palettes'
    /// seven symbols. A host can build a `PanelPalette` with any other.
    static let boundedIconSymbols: Set<String> = [
        "info.circle.fill", "note.text", "lightbulb.fill", "checkmark.circle.fill",
        "exclamationmark.triangle.fill", "xmark.octagon.fill", "star.fill",
    ]

    /// The width bound the panel gives its children (`adfTextWidthBound`):
    /// its own less the padding on both sides, the stack's spacing and the
    /// icon (`iconWidthBound`). `.unproven` when the icon's width is not
    /// bounded: a symbol outside `boundedIconSymbols`, or a font or an
    /// image scale the icon inherits from the environment.
    private var childWidthBound: TextKit2WidthBound {
        guard font == nil, imageScale == .medium, Self.boundedIconSymbols.contains(palette.iconSystemName) else {
            return .unproven
        }
        return widthBound.narrowed(by: theme.spacing * 4.5 + iconWidthBound)
    }
}
