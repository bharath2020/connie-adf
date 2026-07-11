import SwiftUI
import ADFPreparation

/// Flattened list rows (bullet / ordered / task / decision) with a
/// fixed-width marker column and a flexible content column, so wrapped lines
/// align under the text rather than the marker.
struct ListBlockView: View {
    let rows: [PreparedListRow]

    @Environment(\.adfTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing * 0.75) {
            ForEach(rows, id: \.id) { row in
                ListRowView(row: row)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One list row: marker column (fixed width, trailing-aligned) + content.
struct ListRowView: View {
    let row: PreparedListRow

    @Environment(\.adfTheme) private var theme
    /// Marker column width, scaled with Dynamic Type so glyphs stay aligned
    /// with the text they annotate.
    @ScaledMetric(relativeTo: .body) private var markerWidth: CGFloat = 28

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.spacing) {
            markerView
                .frame(width: markerWidth, alignment: .trailing)
            VStack(alignment: .leading, spacing: theme.spacing * 0.5) {
                SegmentedTextView(segments: row.segments)
                    .textSelection(.enabled)
                ForEach(row.trailingBlocks) { block in
                    BlockView(block: block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(row.depth) * (markerWidth + theme.spacing))
        .padding(isDecision ? theme.spacing : 0)
        .background {
            if isDecision {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.08))
            }
        }
    }

    private var isDecision: Bool {
        if case .decision = row.marker { return true }
        return false
    }

    @ViewBuilder
    private var markerView: some View {
        switch row.marker {
        case .bullet(let depth):
            Text(Self.bulletGlyph(depth: depth))
                .accessibilityHidden(true)
        case .ordered(let text):
            Text(text)
                .monospacedDigit()
        case .task(let done):
            // Read-only checkbox glyph per spec (§6.3).
            Text(Image(systemName: done ? "checkmark.square.fill" : "square"))
                .foregroundStyle(done ? Color.accentColor : Color.secondary)
                .accessibilityLabel(done ? "Completed task" : "Task")
        case .decision:
            // Decision glyph; the row itself gets the tinted container.
            Text(Image(systemName: "diamond"))
                .foregroundStyle(Color.orange)
                .accessibilityLabel("Decision")
        }
    }

    /// Bullet glyph per nesting depth: • ◦ ▪ cycling every three levels.
    static func bulletGlyph(depth: Int) -> String {
        switch max(depth, 0) % 3 {
        case 0: return "•"
        case 1: return "◦"
        default: return "▪"
        }
    }
}
