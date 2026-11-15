import SwiftUI
import CoreText
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
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
            BulletMarkerView(depth: depth)
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

    /// A bullet's diameter (the square's side) as a fraction of the body
    /// text's capital height. Measured from the size the captain asked for
    /// (a Slack message on iPhone: dots 17.8 px across by their ink area,
    /// beside 37 px capitals); the system font's own • is about 0.28.
    static let bulletDiameterToCapHeight: CGFloat = 0.48

    /// Bullet glyph per bullet-list nesting level (ordered-list ancestors
    /// don't count): • ◦ ▪ cycling every three levels. `BulletMarkerView`
    /// draws each as a shape; this names it.
    static func bulletGlyph(depth: Int) -> String {
        switch max(depth, 0) % 3 {
        case 0: return "•"
        case 1: return "◦"
        default: return "▪"
        }
    }
}

/// A bullet marker: a filled dot (•), a ring (◦) or a flat square (▪),
/// each `ListRowView.bulletDiameterToCapHeight` of the body text's capital
/// height across, in the text colour.
///
/// The marks are shapes sized from the body font's metrics at the current
/// Dynamic Type size, not glyphs: the system font's • is smaller than the
/// size asked for, and it has no ▪ at all (the fallback draws an emoji, a
/// large glossy square). A hidden • lays the marker out, so the column,
/// first-baseline alignment and row height are the glyph's, and each mark
/// is centred where that glyph's dot is centred: `midY` above the baseline,
/// on the first line of the item's text. The ring's stroke keeps the
/// font's ◦ proportion, so it reads at text weight.
struct BulletMarkerView: View {
    let depth: Int
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.legibilityWeight) private var legibilityWeight

    var body: some View {
        let metrics = BulletMetrics.body(size: dynamicTypeSize, bold: legibilityWeight == .bold)
        let side = metrics.capHeight * ListRowView.bulletDiameterToCapHeight
        Text(ListRowView.bulletGlyph(depth: 0))
            .hidden()
            .overlay(alignment: Alignment(horizontal: .center, vertical: .firstTextBaseline)) {
                mark(side: side, ringWidth: side * metrics.ringWidthToDiameter)
                    .frame(width: side, height: side)
                    .alignmentGuide(.firstTextBaseline) { $0.height / 2 + metrics.dotMidY }
            }
    }

    @ViewBuilder
    private func mark(side: CGFloat, ringWidth: CGFloat) -> some View {
        switch max(depth, 0) % 3 {
        case 0: Circle()
        case 1: Circle().strokeBorder(lineWidth: ringWidth)
        default: Rectangle()
        }
    }
}

/// The body text style's metrics a bullet is drawn from, at a Dynamic Type
/// size: its capital height, how far its dot's (•) centre sits above the
/// baseline, and its ring's (◦) stroke as a fraction of the ring's
/// diameter. A marker inherits the body text style.
enum BulletMetrics {
    struct Metrics: Equatable {
        var capHeight: CGFloat
        var dotMidY: CGFloat
        var ringWidthToDiameter: CGFloat
    }

    private struct Key: Hashable {
        var size: DynamicTypeSize
        var bold: Bool
    }

    @MainActor private static var cache: [Key: Metrics] = [:]

    @MainActor
    static func body(size: DynamicTypeSize, bold: Bool) -> Metrics {
        let key = Key(size: size, bold: bold)
        if let metrics = cache[key] { return metrics }
        let metrics = measure(font(size: size, bold: bold))
        cache[key] = metrics
        return metrics
    }

    static func font(size: DynamicTypeSize, bold: Bool) -> CTFont {
        #if canImport(UIKit)
        var traits = UITraitCollection(preferredContentSizeCategory: size.uiContentSizeCategory)
        if bold { traits = UITraitCollection(traitsFrom: [traits, UITraitCollection(legibilityWeight: .bold)]) }
        return UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits) as CTFont
        #else
        return NSFont.preferredFont(forTextStyle: .body) as CTFont
        #endif
    }

    static func measure(_ font: CTFont) -> Metrics {
        let capHeight = CTFontGetCapHeight(font)
        // Without the glyphs: the system font's proportions.
        var metrics = Metrics(capHeight: capHeight, dotMidY: capHeight * 0.4, ringWidthToDiameter: 0.12)
        if let dot = glyph(0x2022, in: font) {
            var bounds = CGRect.zero
            var glyph = dot
            CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, &bounds, 1)
            metrics.dotMidY = bounds.midY
        }
        // The ring's outline is two circles; their widths give the stroke.
        if let ring = glyph(0x25E6, in: font), let path = CTFontCreatePathForGlyph(font, ring, nil) {
            let widths = subpathBounds(path).map(\.width).sorted()
            if widths.count == 2, let outer = widths.last, let inner = widths.first, outer > 0 {
                metrics.ringWidthToDiameter = (outer - inner) / 2 / outer
            }
        }
        return metrics
    }

    /// The bounds of each closed outline of a glyph path.
    private static func subpathBounds(_ path: CGPath) -> [CGRect] {
        var bounds: [CGRect] = []
        var current = CGMutablePath()
        path.applyWithBlock { element in
            let points = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint:
                if !current.isEmpty { bounds.append(current.boundingBoxOfPath) }
                current = CGMutablePath()
                current.move(to: points[0])
            case .addLineToPoint: current.addLine(to: points[0])
            case .addQuadCurveToPoint: current.addQuadCurve(to: points[1], control: points[0])
            case .addCurveToPoint: current.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closeSubpath: current.closeSubpath()
            @unknown default: break
            }
        }
        if !current.isEmpty { bounds.append(current.boundingBoxOfPath) }
        return bounds
    }

    private static func glyph(_ character: UniChar, in font: CTFont) -> CGGlyph? {
        var character = character
        var glyph: CGGlyph = 0
        return CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) ? glyph : nil
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
