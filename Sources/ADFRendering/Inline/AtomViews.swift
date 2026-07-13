import SwiftUI
import ADFModel
import ADFPreparation

/// Inline pill/chip for one non-text atom, interleaved with text by
/// `WrappingInlineLayout`.
struct AtomView: View {
    let atom: InlineAtom

    var body: some View {
        switch atom {
        case .mention(let text):
            MentionAtomView(text: text)
        case .status(let text, let color):
            AtomCapsule(text: text.uppercased(), tint: color.tint)
        case .date(let timestampMS):
            AtomCapsule(text: AtomFormatting.dateText(timestampMS), tint: .gray)
        case .emoji(let shortName):
            Text(":\(shortName):")
                .foregroundStyle(.secondary)
        case .inlineCard(let url):
            InlineCardChip(url: url)
        case .mediaInline(let attrs):
            AtomChip(icon: "paperclip", text: attrs.alt ?? "attachment")
        case .inlineExtension(let name):
            AtomChip(icon: "puzzlepiece.extension", text: name)
        }
    }
}

/// Mention capsule that, when the host injects `adfMentionContent`, presents
/// that content in a popover anchored to the capsule (a sheet in a compact
/// size class). Read-only otherwise.
private struct MentionAtomView: View {
    let text: String
    @Environment(\.adfMentionContent) private var mentionContent
    @State private var isPresented = false

    var body: some View {
        let name = AtomFormatting.mentionText(text)
        AtomCapsule(text: name, tint: .blue)
            .contentShape(Capsule())
            .onTapGesture { if mentionContent != nil { isPresented = true } }
            .accessibilityAddTraits(mentionContent == nil ? [] : .isButton)
            .popover(isPresented: $isPresented) {
                if let mentionContent { mentionContent(name) }
            }
    }
}

/// Rounded capsule with tinted text over a soft tinted background.
/// Padding scales with the `.callout` text it wraps so the pill keeps its
/// proportions at every Dynamic Type size.
struct AtomCapsule: View {
    let text: String
    let tint: Color

    @ScaledMetric(relativeTo: .callout) private var horizontalPadding: CGFloat = 8
    @ScaledMetric(relativeTo: .callout) private var verticalPadding: CGFloat = 2

    var body: some View {
        Text(text)
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(Capsule().fill(tint.opacity(0.18)))
            .foregroundStyle(tint)
    }
}

/// Neutral icon + text chip (inline card fallback, attachments, extensions).
struct AtomChip: View {
    let icon: String
    let text: String

    @Environment(\.adfTheme) private var theme
    @ScaledMetric(relativeTo: .callout) private var horizontalPadding: CGFloat = 8
    @ScaledMetric(relativeTo: .callout) private var verticalPadding: CGFloat = 2
    @ScaledMetric(relativeTo: .callout) private var iconSpacing: CGFloat = 4

    var body: some View {
        HStack(spacing: iconSpacing) {
            Image(systemName: icon)
                .imageScale(.small)
            Text(text)
                .lineLimit(1)
        }
        .font(.callout)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background(RoundedRectangle(cornerRadius: theme.chipCornerRadius).fill(Color.gray.opacity(0.14)))
    }
}

/// Smart-link chip: unresolved cards show the URL host immediately (title
/// resolution arrives with the smart-link resolver in a later milestone).
struct InlineCardChip: View {
    let url: String?

    var body: some View {
        if let url, let destination = URL(string: url) {
            Link(destination: destination) {
                AtomChip(icon: "link", text: displayText)
            }
        } else {
            AtomChip(icon: "link", text: displayText)
        }
    }

    private var displayText: String {
        guard let url, !url.isEmpty else { return "link" }
        return URL(string: url)?.host ?? url
    }
}

/// Nonisolated plain-text formatting shared by atom views, TOC titles, and
/// accessibility fallbacks.
enum AtomFormatting {
    static func dateText(_ timestampMS: Double) -> String {
        Date(timeIntervalSince1970: timestampMS / 1000)
            .formatted(date: .abbreviated, time: .omitted)
    }

    static func mentionText(_ text: String) -> String {
        text.hasPrefix("@") ? text : "@\(text)"
    }
}

extension ADFStatusColor {
    /// Capsule tint per schema color. `yellow` maps to orange for legible
    /// text on the tinted background.
    var tint: Color {
        switch self {
        case .neutral: return .gray
        case .purple: return .purple
        case .blue: return .blue
        case .red: return .red
        case .yellow: return .orange
        case .green: return .green
        }
    }
}

extension InlineAtom {
    /// Plain-text stand-in used for TOC titles and accessibility labels.
    var fallbackText: String {
        switch self {
        case .mention(let text):
            return AtomFormatting.mentionText(text)
        case .status(let text, _):
            return text
        case .date(let timestampMS):
            return AtomFormatting.dateText(timestampMS)
        case .emoji(let shortName):
            return ":\(shortName):"
        case .inlineCard(let url):
            return url ?? "link"
        case .mediaInline(let attrs):
            return attrs.alt ?? "attachment"
        case .inlineExtension(let name):
            return name
        }
    }
}
