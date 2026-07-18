import SwiftUI
import ADFPreparation

/// Renders a composed inline sequence.
///
/// Fast path: when every segment is text, the runs concatenate into a single
/// `Text(AttributedString)`. When atoms (mentions, statuses, dates, …) are
/// present, a wrapping custom `Layout` interleaves word-level `Text` chunks
/// with inline pill views.
struct SegmentedTextView: View {
    let segments: [InlineSegment]
    /// ID search highlights are keyed by (`RenderBlock.id`, list-row id, or
    /// media id). `nil` opts out of search entirely (previews, chrome).
    var ownerID: String? = nil
    /// Block-level text alignment, forwarded to the TextKit 2 row so its
    /// paragraph style matches the SwiftUI `.multilineTextAlignment` the
    /// enclosing block applies. `nil` (the default) reads as natural/leading.
    var blockAlignment: TextAlignment? = nil

    /// Gap between wrapped lines, scaled with Dynamic Type so line rhythm
    /// tracks the text size it separates.
    @ScaledMetric(relativeTo: .body) private var lineSpacing: CGFloat = 3

    /// The live Dynamic Type factor: `1` at the default size, growing with
    /// larger accessibility sizes. Used to scale sub/superscript baseline
    /// offsets, which are baked as fixed points at preparation time and would
    /// otherwise stay put while the font grew.
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

    @Environment(\.adfDocumentSearch) private var search
    @Environment(\.adfTheme) private var theme
    /// Live Dynamic Type size, used to resolve the TK2 row's first-line
    /// baseline (font ascent) for enclosing `.firstTextBaseline` stacks.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// True inside a table cell — with `-textkit2NoCells`, cells stay on the
    /// SwiftUI path (giant-table gate fallback).
    @Environment(\.adfInTableCell) private var inTableCell
    /// Flash off-phase: while true the current match paints with the subtle
    /// color, so alternating it blinks the accent (§ arrival flash).
    @State private var flashDimmed = false

    var body: some View {
        let displayed = displayedSegments
        Group {
            if let merged = Self.mergedText(displayed) {
                #if os(iOS)
                if TextKit2Flags.enabled && (!inTableCell || TextKit2Flags.cellsEnabled) {
                    TextKit2RowView(segments: [.text(merged)], blockAlignment: blockAlignment)
                        .alignmentGuide(.firstTextBaseline) { _ in
                            TextKit2RowView.firstBaseline(
                                of: displayed,
                                categoryRawValue: UIContentSizeCategory(dynamicTypeSize).rawValue)
                        }
                } else {
                    Text(Self.scalingBaselineOffsets(in: merged, by: typeScale))
                }
                #else
                Text(Self.scalingBaselineOffsets(in: merged, by: typeScale))
                #endif
            } else {
                WrappingInlineLayout(lineSpacing: lineSpacing) {
                    ForEach(Self.tokens(for: displayed)) { token in
                        InlineTokenView(
                            token: token,
                            typeScale: typeScale,
                            atomHighlight: atomHighlight(for: token)
                        )
                    }
                }
            }
        }
        .searchArrivalFlash(ownerID: ownerID, dimmed: $flashDimmed)
    }

    // MARK: Search highlighting

    /// The zero-work gate: rows without matches return the stored segments
    /// untouched (no copy, no scan) — the path every row takes while
    /// scrolling with no search active, and every unmatched row during one.
    /// With no active session the gate reads ONE observable Bool
    /// (`isActive`, which flips at most twice per session) and never touches
    /// the `highlights` struct — leaf materialization during plain scrolling
    /// is what the §8 hitch gate measures.
    private var displayedSegments: [InlineSegment] {
        guard let ownerID, let search, search.isActive else {
            return segments
        }
        let highlights = search.ownerHighlights(for: ownerID)
        let spans = highlights.spans
        let currentSpans = highlights.currentSpans
        guard !spans.isEmpty || !currentSpans.isEmpty else { return segments }
        return SearchHighlightPainter.paint(
            segments: segments,
            spans: spans,
            currentSpans: currentSpans,
            theme: theme,
            dimCurrent: flashDimmed
        )
    }

    private func atomHighlight(for token: InlineToken) -> AtomHighlightState? {
        guard case .atom(_, let id) = token.kind,
              let ownerID, let search, search.isActive else { return nil }
        let highlights = search.ownerHighlights(for: ownerID)
        if highlights.currentAtomIDs.contains(id) {
            return .current(dimmed: flashDimmed)
        }
        return highlights.atomIDs.contains(id) ? .subtle : nil
    }

    /// Multiplies any baked sub/superscript baseline offsets by the Dynamic
    /// Type factor so the raise/drop tracks the font size. Returns the input
    /// untouched at the default size (factor `1`) — the overwhelmingly common
    /// case does zero work and never walks the runs.
    static func scalingBaselineOffsets(in text: AttributedString, by factor: CGFloat) -> AttributedString {
        guard factor != 1 else { return text }
        var scaled = text
        let edits: [(Range<AttributedString.Index>, CGFloat)] = scaled.runs.compactMap { run in
            run.baselineOffset.map { (run.range, $0 * factor) }
        }
        for (range, offset) in edits {
            scaled[range].baselineOffset = offset
        }
        return scaled
    }

    /// The pre-merged text run for all-text content, or `nil` when any
    /// segment is an atom. The preparer emits one merged run per gap, so the
    /// common case returns the existing value without building or copying an
    /// `AttributedString` inside `body` (§5.3).
    static func mergedText(_ segments: [InlineSegment]) -> AttributedString? {
        if segments.count == 1, case .text(let only) = segments[0] {
            return only
        }
        var merged = AttributedString()
        for segment in segments {
            guard case .text(let text) = segment else { return nil }
            merged.append(text)
        }
        return merged
    }

    /// Maps segments 1:1 to layout tokens. Word-level chunking already
    /// happened at preparation time (`InlineComposer.splitForWrappingLayout`),
    /// so no character scanning or attributed-string slicing runs here — a
    /// standalone `"\n"` chunk becomes an explicit line break.
    static func tokens(for segments: [InlineSegment]) -> [InlineToken] {
        var tokens: [InlineToken] = []
        tokens.reserveCapacity(segments.count)
        for segment in segments {
            switch segment {
            case .atom(let atom, let id):
                tokens.append(InlineToken(id: tokens.count, kind: .atom(atom, id: id)))
            case .text(let text):
                if isLineBreak(text) {
                    tokens.append(InlineToken(id: tokens.count, kind: .lineBreak))
                } else {
                    tokens.append(InlineToken(id: tokens.count, kind: .text(text)))
                }
            }
        }
        return tokens
    }

    /// True for a chunk that is exactly one `"\n"` (O(1), no full scan).
    private static func isLineBreak(_ text: AttributedString) -> Bool {
        let characters = text.characters
        guard let first = characters.first, first == "\n" else { return false }
        return characters.index(after: characters.startIndex) == characters.endIndex
    }
}

/// One unit placed by `WrappingInlineLayout`.
struct InlineToken: Identifiable, Hashable {
    enum Kind: Hashable {
        case text(AttributedString)
        case atom(InlineAtom, id: String)
        case lineBreak
    }

    let id: Int
    let kind: Kind
}

/// Whole-pill search emphasis for atoms (pills are plain `Text`, not
/// range-highlightable, so a matched pill tints entirely).
enum AtomHighlightState: Equatable {
    case subtle
    case current(dimmed: Bool)
}

struct InlineTokenView: View {
    let token: InlineToken
    /// Live Dynamic Type factor for scaling sub/superscript baseline offsets
    /// on word-chunk text tokens (see `SegmentedTextView`).
    var typeScale: CGFloat = 1
    var atomHighlight: AtomHighlightState? = nil

    @Environment(\.adfTheme) private var theme

    var body: some View {
        switch token.kind {
        case .text(let text):
            Text(SegmentedTextView.scalingBaselineOffsets(in: text, by: typeScale))
        case .atom(let atom, _):
            AtomView(atom: atom)
                .background {
                    if let atomHighlight {
                        RoundedRectangle(cornerRadius: theme.chipCornerRadius)
                            .fill(highlightColor(atomHighlight))
                    }
                }
        case .lineBreak:
            Color.clear
                .frame(width: 0, height: 0)
                .layoutValue(key: LineBreakLayoutKey.self, value: true)
        }
    }

    private func highlightColor(_ state: AtomHighlightState) -> Color {
        switch state {
        case .subtle, .current(dimmed: true):
            return theme.searchHighlight
        case .current(dimmed: false):
            return theme.searchCurrentHighlight
        }
    }
}

/// Marks a subview as a forced line break for `WrappingInlineLayout`.
struct LineBreakLayoutKey: LayoutValueKey {
    static let defaultValue = false
}

/// Flow layout: places subviews left-to-right, wrapping to a new line when
/// the proposed width is exhausted (or on an explicit line-break subview).
/// Items on a line share one text baseline — mixed font sizes (small marks,
/// sub/superscript) and atom pills sit on the same line as the prose around
/// them, exactly as `Text` would place them. Centering against the line
/// height instead makes baselines diverge by half the height difference.
struct WrappingInlineLayout: Layout {
    var lineSpacing: CGFloat = 3

    private struct Item {
        let index: Int
        let size: CGSize
        /// Distance from the item's top edge to its first text baseline.
        /// Views without text report their bottom edge, which keeps pills
        /// whose baseline doesn't propagate resting on the line's baseline.
        let ascent: CGFloat
    }

    private struct Row {
        var items: [Item] = []
        var width: CGFloat = 0
        /// Tallest top-to-baseline distance on the row.
        var ascent: CGFloat = 0
        /// Deepest baseline-to-bottom distance on the row.
        var descent: CGFloat = 0
        var height: CGFloat { ascent + descent }
    }

    private func rows(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for (index, subview) in subviews.enumerated() {
            if subview[LineBreakLayoutKey.self] {
                current.items.append(Item(index: index, size: .zero, ascent: 0))
                rows.append(current)
                current = Row()
                continue
            }
            let dimensions = subview.dimensions(in: .unspecified)
            let size = CGSize(width: dimensions.width, height: dimensions.height)
            let ascent = dimensions[VerticalAlignment.firstTextBaseline]
            if !current.items.isEmpty, current.width + size.width > maxWidth {
                rows.append(current)
                current = Row()
            }
            current.items.append(Item(index: index, size: size, ascent: ascent))
            current.width += size.width
            current.ascent = max(current.ascent, ascent)
            current.descent = max(current.descent, size.height - ascent)
        }
        if !current.items.isEmpty {
            rows.append(current)
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = rows(subviews: subviews, maxWidth: maxWidth)
        let height = rows.reduce(CGFloat.zero) { $0 + $1.height }
            + lineSpacing * CGFloat(max(rows.count - 1, 0))
        let contentWidth = rows.map(\.width).max() ?? 0
        let width = maxWidth.isFinite ? min(contentWidth, maxWidth) : contentWidth
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews: subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + row.ascent - item.ascent),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width
            }
            y += row.height + lineSpacing
        }
    }

    /// A `Layout`'s default text baselines are its bottom edge; without real
    /// ones, a baseline-aligned container (list rows, panels) would hang the
    /// whole first line's height below its neighbor's baseline. Report the
    /// first row's and last row's baselines.
    func explicitAlignment(
        of guide: VerticalAlignment,
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGFloat? {
        switch guide {
        case .firstTextBaseline:
            let rows = rows(subviews: subviews, maxWidth: bounds.width)
            guard let first = rows.first else { return nil }
            return bounds.minY + first.ascent
        case .lastTextBaseline:
            let rows = rows(subviews: subviews, maxWidth: bounds.width)
            guard let last = rows.last else { return nil }
            let lastRowTop = rows.dropLast().reduce(CGFloat.zero) { $0 + $1.height + lineSpacing }
            return bounds.minY + lastRowTop + last.ascent
        default:
            return nil
        }
    }
}
