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
///
/// The text engine choice reaches a list only from a top-level list row
/// (`DocumentRow`, `TextKit2Scope`). The row passes it to its leader
/// (`TextEngineLeaf`, owned by the row's id) and to its direct paragraphs,
/// headings and lists. Every other trailing block gets `.swiftUI`, and so
/// does everything inside it. The marker column, spacing, depth padding and
/// decision background are SwiftUI chrome under either engine.
struct ListRowView: View {
    let row: PreparedListRow

    @Environment(\.adfTheme) private var theme
    @Environment(\.adfTextRenderer) private var renderer
    /// Marker column width, scaled with Dynamic Type so glyphs stay aligned
    /// with the text they annotate.
    @ScaledMetric(relativeTo: .body) private var markerWidth: CGFloat = 28

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.spacing) {
            markerView
                .frame(width: markerWidth, alignment: .trailing)
            VStack(alignment: .leading, spacing: theme.spacing * 0.5) {
                if !row.segments.isEmpty {
                    TextEngineLeaf(segments: row.segments, style: Self.leaderStyle(theme: theme), ownerID: row.id) {
                        SegmentedTextView(segments: row.segments, ownerID: row.id)
                            .textSelection(.enabled)
                    }
                }
                ForEach(row.trailingBlocks) { block in
                    BlockView(block: block)
                        .environment(\.adfTextRenderer, TextKit2Scope.inheritsRenderer(block.kind) ? renderer : .swiftUI)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(row.depth) * (markerWidth + theme.spacing))
        .padding(isDecision ? theme.spacing : 0)
        .background {
            if isDecision {
                RoundedRectangle(cornerRadius: theme.containerCornerRadius)
                    .fill(Color.gray.opacity(0.08))
            }
        }
    }

    /// A leader is body text: the preparer composes it like a top-level
    /// paragraph and drops its block marks, so no alignment, indentation or
    /// heading applies. (The TextKit 2 row reads only `alignment` and
    /// `isHeading`; the fonts come from the runs.)
    static func leaderStyle(theme: ADFTheme) -> TextBlockStyle {
        TextBlockStyle(font: theme.body, isHeading: false, headingLevel: nil, alignment: nil, indentation: 0, breakout: nil)
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
        case .task(let id, let done):
            TaskMarkerView(id: id, adfDone: done)
        case .decision:
            // Decision glyph; the row itself gets the tinted container.
            Text(Image(systemName: "diamond"))
                .foregroundStyle(Color.orange)
                .accessibilityLabel("Decision")
        case .continuation:
            // Item content resuming after a nested list: empty marker column
            // keeps the content aligned under the item's first line.
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
        }
    }

    /// Bullet glyph per bullet-list nesting level (ordered-list ancestors
    /// don't count): • ◦ ▪ cycling every three levels.
    static func bulletGlyph(depth: Int) -> String {
        switch max(depth, 0) % 3 {
        case 0: return "•"
        case 1: return "◦"
        default: return "▪"
        }
    }
}

/// Task checkbox. Shows `adfTaskStates[id] ?? adfDone`; toggles via the host
/// handler when present, read-only otherwise. Only the glyph is tappable.
private struct TaskMarkerView: View {
    let id: String
    let adfDone: Bool
    @Environment(\.adfInteractionHandler) private var handler
    @Environment(\.adfTaskStates) private var taskStates

    private var isDone: Bool { taskStates[id] ?? adfDone }

    var body: some View {
        let glyph = Image(systemName: isDone ? "checkmark.square.fill" : "square")
        if let handler {
            Button {
                handler(.taskToggled(id: id, isDone: !isDone))
            } label: {
                Text(glyph).foregroundStyle(isDone ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityLabel(isDone ? "Completed task" : "Task")
            .accessibilityHint("Toggles the task")
        } else {
            Text(glyph)
                .foregroundStyle(isDone ? Color.accentColor : Color.secondary)
                .accessibilityLabel(isDone ? "Completed task" : "Task")
        }
    }
}
