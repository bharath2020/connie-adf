import SwiftUI
import ADFPreparation

/// Flattened list rows (bullet / ordered / task / decision) with a
/// fixed-width marker column and a flexible content column, so wrapped lines
/// align under the text rather than the marker.
struct ListBlockView: View {
    let rows: [PreparedListRow]

    @Environment(\.adfTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing(theme: theme)) {
            ForEach(rows, id: \.id) { row in
                ListRowView(row: row)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The vertical gap between two rows. A task checkbox's tap band
    /// (`TaskHitArea`) reaches half of it above and below its row.
    nonisolated static func rowSpacing(theme: ADFTheme) -> CGFloat {
        theme.spacing * 0.75
    }
}

/// One list row: marker column (fixed width, trailing-aligned) + content.
///
/// The text engine choice reaches a list only from a top-level list row
/// (`DocumentRow`, `TextKit2Scope`). The row passes it to its leader
/// (`TextEngineLeaf`, owned by the row's id) and its trailing paragraphs
/// and headings when its text column holds one text block or only
/// body-styled paragraphs (`TextKit2Scope.rowKeepsRenderer`); any other
/// row, and everything in its trailing blocks, draws on SwiftUI. Text whose column has no room
/// left (deep nesting at accessibility sizes) stays on SwiftUI too
/// (`TextKit2Scope.listTextFits`), and so does every list row laid out
/// right to left (`TextKit2Scope.listDirectionKeepsRenderer`). Before
/// iOS 26 the leaves keep list text on SwiftUI themselves
/// (`TextKit2Eligibility.listsMatchText`, by `adfTextOwnerKind`). The marker
/// column, spacing, depth padding and decision background are SwiftUI
/// chrome under either engine.
struct ListRowView: View {
    let row: PreparedListRow

    @Environment(\.adfTheme) private var theme
    @Environment(\.adfTextRenderer) private var renderer
    @Environment(\.adfListWidth) private var listWidth
    @Environment(\.layoutDirection) private var layoutDirection
    /// Marker column width, scaled with Dynamic Type so glyphs stay aligned
    /// with the text they annotate.
    @ScaledMetric(relativeTo: .body) private var markerWidth: CGFloat = 28
    /// Whether a touch is down on the task checkbox's tap band, so the glyph
    /// shows the pressed dimming its own button would.
    @State private var isTaskPressed = false

    var body: some View {
        let keepsRenderer = TextKit2Scope.listDirectionKeepsRenderer(layoutDirection) && TextKit2Scope.rowKeepsRenderer(row)
        HStack(alignment: .firstTextBaseline, spacing: theme.spacing) {
            markerView
                .frame(width: markerWidth, alignment: .trailing)
            VStack(alignment: .leading, spacing: theme.spacing * 0.5) {
                if !row.segments.isEmpty {
                    TextEngineLeaf(segments: row.segments, style: Self.leaderStyle(theme: theme), ownerID: row.id,
                                   allowsTextKit2: keepsRenderer && TextKit2Scope.listTextFits(textColumnWidth)) {
                        SegmentedTextView(segments: row.segments, ownerID: row.id)
                            .textSelection(.enabled)
                    }
                }
                ForEach(row.trailingBlocks) { block in
                    BlockView(block: block)
                        .environment(\.adfTextRenderer, keepsRenderer && textFits(block) ? renderer : .swiftUI)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.adfTextOwnerKind, .list)
        }
        .overlay(alignment: .topLeading) { taskHitArea }
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

    /// The width the row's `HStack` proposes its text column: the list's
    /// width less the depth padding, the decision padding, the marker
    /// column and the gap after it. `nil` when the list's width is unknown.
    private var textColumnWidth: CGFloat? {
        guard let listWidth else { return nil }
        let inset = CGFloat(row.depth) * (markerWidth + theme.spacing) + (isDecision ? 2 * theme.spacing : 0)
        return listWidth - inset - markerWidth - theme.spacing
    }

    /// Whether a trailing paragraph or heading has room for TextKit 2, less
    /// its own indentation.
    private func textFits(_ block: RenderBlock) -> Bool {
        guard case .richText(_, let style) = block.kind else { return false }
        return TextKit2Scope.listTextFits(textColumnWidth.map { $0 - RichTextBlockView.indentationPadding(style, theme: theme) })
    }

    /// A task row's enlarged checkbox tap target, over the marker column and
    /// the gap after it (never the text column). Draws nothing.
    @ViewBuilder
    private var taskHitArea: some View {
        if case .task(let id, let done) = row.marker {
            TaskHitAreaView(
                id: id,
                adfDone: done,
                columnWidth: markerWidth + theme.spacing,
                leadingOutset: TaskHitArea.leadingOutset(markerWidth: markerWidth, spacing: theme.spacing),
                verticalOutset: TaskHitArea.verticalOutset(rowSpacing: ListBlockView.rowSpacing(theme: theme)),
                isPressed: $isTaskPressed
            )
        }
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
            TaskMarkerView(id: id, adfDone: done, isPressed: isTaskPressed)
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
/// handler when present, read-only otherwise. The glyph's button is the
/// accessibility element (VoiceOver activates it); touches land on the row's
/// larger `TaskHitAreaView`, which sits over the glyph and reports its
/// press as `isPressed`.
private struct TaskMarkerView: View {
    let id: String
    let adfDone: Bool
    let isPressed: Bool
    @Environment(\.adfInteractionHandler) private var handler
    @Environment(\.adfTaskStates) private var taskStates

    private var isDone: Bool { taskStates[id] ?? adfDone }

    var body: some View {
        let glyph = Image(systemName: isDone ? "checkmark.square.fill" : "square")
        if let handler {
            Button {
                handler(.taskToggled(id: id, isDone: !isDone))
            } label: {
                Text(glyph)
                    .foregroundStyle(isDone ? Color.accentColor : Color.secondary)
                    .opacity(isPressed ? TaskHitArea.pressedOpacity : 1)
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

/// Geometry of a task checkbox's tap band. The glyph is about 20 pt square,
/// well under Apple's 44 × 44 pt minimum, so the band grows the target
/// without moving or resizing anything drawn:
///
/// - Across: the marker column plus the gap before the text, and up to one
///   `spacing` further toward the leading edge (into the depth indent, or
///   the document margin at depth 0) until the band is 44 pt wide. It never
///   reaches the text column, so text selection and links keep their taps.
/// - Down: the row's height plus half the row gap above and below, capped
///   at 44 pt. Neighbouring rows' bands meet in the middle of the gap and
///   never overlap, so a dense single-line task list gets bands as tall as
///   its row pitch, and a wrapped task gets the full 44 pt.
enum TaskHitArea {
    /// Apple's minimum comfortable touch target side.
    static let minimumSide: CGFloat = 44

    /// The glyph's opacity while its tap band is pressed.
    static let pressedOpacity: Double = 0.4

    /// How far the band reaches toward the leading edge past the marker
    /// column: what a 44 pt width still needs, at most one `spacing`.
    static func leadingOutset(markerWidth: CGFloat, spacing: CGFloat) -> CGFloat {
        min(max(minimumSide - markerWidth - spacing, 0), spacing)
    }

    /// How far the band reaches above and below its row: half the gap
    /// between rows, so neighbouring bands abut without overlapping.
    static func verticalOutset(rowSpacing: CGFloat) -> CGFloat {
        rowSpacing / 2
    }

    /// The band's height for a row of `rowHeight`.
    static func height(rowHeight: CGFloat, verticalOutset: CGFloat) -> CGFloat {
        min(rowHeight + 2 * verticalOutset, minimumSide)
    }
}

/// The task checkbox's tap band (`TaskHitArea`): a clear button laid over
/// the row's top-leading corner. Its frame is the marker column plus the
/// gap; negative padding lets the clear label overhang that frame by the
/// outsets, so layout and drawing are unchanged. While a touch is down it
/// sets `isPressed`, which dims the glyph. Hidden from accessibility —
/// `TaskMarkerView`'s glyph stays the element VoiceOver reads and activates.
private struct TaskHitAreaView: View {
    let id: String
    let adfDone: Bool
    /// The marker column plus the gap before the text.
    let columnWidth: CGFloat
    let leadingOutset: CGFloat
    let verticalOutset: CGFloat
    @Binding var isPressed: Bool
    @Environment(\.adfInteractionHandler) private var handler
    @Environment(\.adfTaskStates) private var taskStates

    private var isDone: Bool { taskStates[id] ?? adfDone }

    var body: some View {
        if let handler {
            Button {
                handler(.taskToggled(id: id, isDone: !isDone))
            } label: {
                // Proposed the row's height plus both outsets (the negative
                // vertical padding below), capped at the 44 pt maximum —
                // `TaskHitArea.height(rowHeight:verticalOutset:)`.
                Color.clear
                    .frame(width: columnWidth + leadingOutset)
                    .frame(maxHeight: TaskHitArea.minimumSide)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TaskHitAreaButtonStyle(isPressed: $isPressed))
            .accessibilityHidden(true)
            .padding(.leading, -leadingOutset)
            .padding(.vertical, -verticalOutset)
        }
    }
}

/// The tap band's button style: draws the clear label as is and mirrors the
/// press into `isPressed`.
private struct TaskHitAreaButtonStyle: ButtonStyle {
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in
                isPressed = pressed
            }
    }
}
