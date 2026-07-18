import SwiftUI
import ADFModel
import ADFPreparation

/// Paragraphs and headings: pre-composed inline segments plus block-level
/// styling (alignment / indentation / breakout marks, heading semantics).
struct RichTextBlockView: View {
    let segments: [InlineSegment]
    let style: TextBlockStyle
    var ownerID: String? = nil

    @Environment(\.adfTheme) private var theme

    var body: some View {
        SegmentedTextView(segments: segments, ownerID: ownerID, blockAlignment: textAlignment)
            .multilineTextAlignment(textAlignment)
            .textSelection(.enabled)
            .padding(.leading, indentationPadding)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
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

    // Breakout is applied centrally by `ADFDocumentView` from
    // `RenderBlock.breakout` (root-level blocks only, per schema), so this
    // view no longer compensates — `style.breakout` remains available as
    // prepared data.

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
