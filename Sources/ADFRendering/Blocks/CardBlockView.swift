import SwiftUI
import ADFPreparation

/// Smart-link card for `blockCard` / `embedCard`. Unresolved cards show the
/// URL immediately (the smart-link resolver protocol is a later milestone);
/// `embedCard` falls back to the same card style — no iframe on iOS.
struct CardBlockView: View {
    let url: String?
    let title: String?
    let isEmbed: Bool

    @Environment(\.adfTheme) private var theme
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button(action: open) {
            HStack(spacing: theme.spacing * 1.5) {
                Image(systemName: isEmbed ? "rectangle.on.rectangle" : "link")
                    .imageScale(.small)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor.opacity(0.12))
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayTitle)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if destination != nil {
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(theme.spacing * 1.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.gray.opacity(0.2)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(destination == nil)
        .accessibilityLabel("Link card: \(displayTitle)")
    }

    private var destination: URL? {
        url.flatMap(URL.init(string:))
    }

    private var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let destination, let host = destination.host { return host }
        if let url, !url.isEmpty { return url }
        return "Link card"
    }

    private var subtitle: String? {
        guard let url, !url.isEmpty, url != displayTitle else { return nil }
        return url
    }

    private func open() {
        guard let destination else { return }
        openURL(destination)
    }
}

/// Neutral card for unregistered `extension` / `bodiedExtension` macros:
/// puzzle-piece icon + extension name, with a bodied extension's children
/// rendered below (§7).
struct ExtensionPlaceholderBlockView: View {
    let title: String
    let blocks: [RenderBlock]

    @Environment(\.adfTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing) {
            HStack(spacing: theme.spacing * 0.75) {
                Image(systemName: "puzzlepiece.extension")
                    .imageScale(.small)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            if !blocks.isEmpty {
                VStack(alignment: .leading, spacing: theme.spacing) {
                    ForEach(blocks) { block in
                        BlockView(block: block)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(theme.spacing * 1.5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    Color.gray.opacity(0.3),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Extension: \(title)")
    }
}
