import SwiftUI
import ADFPreparation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Monospaced code block: horizontal scroll for long lines, language badge,
/// and a copy button. The code string arrives pre-attributed (theme code
/// font, font spec and shape applied in preparation).
///
/// The badge, the Copy button, the padding, the box, the horizontal scroll
/// view and the search arrival flash are SwiftUI under either text engine:
/// this view is the code block's chrome and viewport, and only the code
/// text inside the scroll view goes through the shared engine leaf
/// (`TextEngineLeaf`). The leaf gets the stored `code`, never the
/// highlighted copy: while the active search has highlights for this block
/// the leaf itself falls back, so highlights and the flash draw exactly as
/// on main. Under TextKit 2 the code text has no long-press selection yet;
/// the SwiftUI text, and every fallback, keeps it. Copy always takes the
/// prepared string.
///
/// The code never wraps on either engine: the scroll view's viewport takes
/// the width this view is given, and the text inside keeps its natural
/// width (the scroll extent). The renderer choice is only read here, never
/// set: a code block has no children to pass it to.
struct CodeBlockView: View {
    let language: String?
    let code: AttributedString
    /// `RenderBlock.id`; nil opts out of search (previews).
    var ownerID: String? = nil

    @Environment(\.adfTheme) private var theme
    @Environment(\.adfDocumentSearch) private var search
    @State private var flashDimmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: theme.spacing) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(action: copyCode) {
                    Label("Copy", systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Copy code")
            }
            .padding(.horizontal, theme.spacing * 1.5)
            .padding(.top, theme.spacing)

            ScrollView(.horizontal, showsIndicators: false) {
                TextEngineLeaf(text: code, style: Self.codeStyle(theme: theme), ownerID: ownerID) {
                    Text(displayedCode)
                        .textSelection(.enabled)
                }
                .environment(\.adfTextOwnerKind, .code)
                .padding(theme.spacing * 1.5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: theme.containerCornerRadius).fill(Color.gray.opacity(0.1)))
        .searchArrivalFlash(ownerID: ownerID, dimmed: $flashDimmed)
    }

    /// The style the engine leaf is given. The TextKit 2 row reads only
    /// `alignment` and `isHeading` (the font comes from the code's own
    /// font spec), and code is neither aligned nor a heading.
    static func codeStyle(theme: ADFTheme) -> TextBlockStyle {
        TextBlockStyle(font: theme.code, isHeading: false, headingLevel: nil, alignment: nil, indentation: 0, breakout: nil)
    }

    private func copyCode() {
        let text = String(code.characters)
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    /// Zero-work gate: unmatched code blocks return the stored string as-is.
    /// Idle sessions read one observable Bool, never the highlights struct
    /// (see `SegmentedTextView.displayedSegments`).
    private var displayedCode: AttributedString {
        guard let ownerID, let search, search.isActive else {
            return code
        }
        let highlights = search.ownerHighlights(for: ownerID)
        let spans = highlights.spans
        let currentSpans = highlights.currentSpans
        guard !spans.isEmpty || !currentSpans.isEmpty else { return code }
        return SearchHighlightPainter.paint(
            text: code, spans: spans, currentSpans: currentSpans,
            theme: theme, dimCurrent: flashDimmed
        )
    }
}
