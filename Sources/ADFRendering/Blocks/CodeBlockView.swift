import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Monospaced code block: horizontal scroll for long lines, language badge,
/// and a copy button. The code string arrives pre-attributed (theme code
/// font applied in preparation).
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
                #if os(iOS)
                if TextKit2Flags.enabled {
                    TextKit2RowView(segments: [.text(displayedCode)])
                        .padding(theme.spacing * 1.5)
                } else {
                    Text(displayedCode)
                        .textSelection(.enabled)
                        .padding(theme.spacing * 1.5)
                }
                #else
                Text(displayedCode)
                    .textSelection(.enabled)
                    .padding(theme.spacing * 1.5)
                #endif
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: theme.containerCornerRadius).fill(Color.gray.opacity(0.1)))
        .searchArrivalFlash(ownerID: ownerID, dimmed: $flashDimmed)
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
