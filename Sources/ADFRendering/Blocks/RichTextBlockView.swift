import SwiftUI
import ADFModel
import ADFPreparation

/// Paragraphs and headings: pre-composed inline segments plus block-level
/// styling (alignment / indentation / breakout marks, heading semantics).
struct RichTextBlockView: View {
    let segments: [InlineSegment]
    let style: TextBlockStyle

    @Environment(\.adfTheme) private var theme

    var body: some View {
        SegmentedTextView(segments: segments)
            .multilineTextAlignment(textAlignment)
            .textSelection(.enabled)
            .padding(.leading, indentationPadding)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
            .padding(.horizontal, breakoutCompensation)
            .accessibilityAddTraits(style.isHeading ? .isHeader : [])
            .accessibilityHeading(accessibilityHeadingLevel)
    }

    private var textAlignment: TextAlignment {
        switch style.alignment {
        case .center: return .center
        case .end: return .trailing
        case nil: return .leading
        }
    }

    private var frameAlignment: Alignment {
        switch style.alignment {
        case .center: return .center
        case .end: return .trailing
        case nil: return .leading
        }
    }

    /// Indentation mark: one leading step per level (1...6).
    private var indentationPadding: CGFloat {
        CGFloat(max(style.indentation, 0)) * theme.spacing * 3
    }

    /// Breakout marks widen the block into the document's horizontal margin
    /// (`ADFDocumentView` pads content by `theme.spacing * 2`): `wide`
    /// reclaims half of it, `full-width` all of it.
    private var breakoutCompensation: CGFloat {
        switch style.breakout {
        case .wide: return -theme.spacing
        case .fullWidth: return -theme.spacing * 2
        case nil: return 0
        }
    }

    private var accessibilityHeadingLevel: AccessibilityHeadingLevel {
        guard style.isHeading else { return .unspecified }
        switch style.headingLevel ?? 1 {
        case 1: return .h1
        case 2: return .h2
        case 3: return .h3
        case 4: return .h4
        case 5: return .h5
        default: return .h6
        }
    }
}
