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

    @Environment(\.adfTheme) private var theme

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
                Text(code)
                    .textSelection(.enabled)
                    .padding(theme.spacing * 1.5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.1)))
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
}
