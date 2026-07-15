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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                Text(displayedCode)
                    .textSelection(.enabled)
                    .padding(theme.spacing * 1.5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: theme.containerCornerRadius).fill(Color.gray.opacity(0.1)))
        .task(id: flashTrigger) { await runFlash() }
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
    private var displayedCode: AttributedString {
        guard let ownerID, let highlights = search?.highlights, highlights.isActive else {
            return code
        }
        let spans = highlights.spansByOwner[ownerID] ?? []
        let currentSpans = highlights.current?.ownerID == ownerID
            ? (highlights.current?.spans ?? []) : []
        guard !spans.isEmpty || !currentSpans.isEmpty else { return code }
        return SearchHighlightPainter.paint(
            text: code, spans: spans, currentSpans: currentSpans,
            theme: theme, dimCurrent: flashDimmed
        )
    }

    private struct FlashTrigger: Equatable {
        let generation: Int
        let isCurrentOwner: Bool
    }

    private var flashTrigger: FlashTrigger {
        let current = search?.highlights.current
        return FlashTrigger(
            generation: current?.generation ?? 0,
            isCurrentOwner: ownerID != nil && current?.ownerID == ownerID
        )
    }

    private func runFlash() async {
        flashDimmed = false
        guard flashTrigger.isCurrentOwner, flashTrigger.generation > 0, !reduceMotion else {
            return
        }
        for _ in 0..<2 {
            try? await Task.sleep(for: .milliseconds(130))
            guard !Task.isCancelled else { return }
            flashDimmed = true
            try? await Task.sleep(for: .milliseconds(130))
            guard !Task.isCancelled else { return }
            flashDimmed = false
        }
    }
}
