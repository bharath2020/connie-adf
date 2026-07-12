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

    /// Gap between wrapped lines, scaled with Dynamic Type so line rhythm
    /// tracks the text size it separates.
    @ScaledMetric(relativeTo: .body) private var lineSpacing: CGFloat = 3

    var body: some View {
        if let merged = Self.mergedText(segments) {
            Text(merged)
        } else {
            WrappingInlineLayout(lineSpacing: lineSpacing) {
                ForEach(Self.tokens(for: segments)) { token in
                    InlineTokenView(token: token)
                }
            }
        }
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
            case .atom(let atom, _):
                tokens.append(InlineToken(id: tokens.count, kind: .atom(atom)))
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
        case atom(InlineAtom)
        case lineBreak
    }

    let id: Int
    let kind: Kind
}

struct InlineTokenView: View {
    let token: InlineToken

    var body: some View {
        switch token.kind {
        case .text(let text):
            Text(text)
        case .atom(let atom):
            AtomView(atom: atom)
        case .lineBreak:
            Color.clear
                .frame(width: 0, height: 0)
                .layoutValue(key: LineBreakLayoutKey.self, value: true)
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
