import SwiftUI
import ADFModel
import ADFPreparation

/// Paragraphs and headings: pre-composed inline segments plus block-level
/// styling (alignment / indentation / breakout marks, heading semantics).
///
/// Two text engines share this leaf (`TextEngineLeaf`). The SwiftUI arm is
/// the shipping path. When the environment selects `.textKit2` AND the
/// content is eligible (`TextKit2Eligibility`: no inline atom, every run
/// with a font spec) AND no inherited styling the row cannot reproduce is
/// set AND the active search has no highlight for it AND at least 1 pt of
/// width is left beside its indentation (`TextKit2Leaf`), a UIKit-hosted
/// TextKit 2 row draws it instead. Without UIKit the SwiftUI arm always
/// runs.
struct RichTextBlockView: View {
    let segments: [InlineSegment]
    let style: TextBlockStyle
    var ownerID: String? = nil

    @Environment(\.adfTheme) private var theme

    var body: some View {
        content
            .padding(.leading, indentationPadding)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
            .accessibilityAddTraits(style.isHeading ? .isHeader : [])
            .accessibilityHeading(accessibilityHeadingLevel)
    }

    private var content: some View {
        // The leaf sits inside `body`'s indentation padding, so the
        // under-1-pt guard measures what is left of the width bound.
        TextEngineLeaf(segments: segments, style: style, ownerID: ownerID, widthInset: indentationPadding) { swiftUIText }
    }

    private var swiftUIText: some View {
        SegmentedTextView(segments: segments, ownerID: ownerID)
            .multilineTextAlignment(textAlignment)
            .textSelection(.enabled)
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
        Self.indentationPadding(style, theme: theme)
    }

    static func indentationPadding(_ style: TextBlockStyle, theme: ADFTheme) -> CGFloat {
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
