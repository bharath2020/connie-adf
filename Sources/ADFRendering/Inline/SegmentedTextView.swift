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

    var body: some View {
        if let merged = Self.mergedText(segments) {
            Text(merged)
        } else {
            WrappingInlineLayout(lineSpacing: 3) {
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
/// Items on a line are vertically centered against the line's height.
struct WrappingInlineLayout: Layout {
    var lineSpacing: CGFloat = 3

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for (index, subview) in subviews.enumerated() {
            if subview[LineBreakLayoutKey.self] {
                current.items.append((index: index, size: .zero))
                rows.append(current)
                current = Row()
                continue
            }
            let size = subview.sizeThatFits(.unspecified)
            if !current.items.isEmpty, current.width + size.width > maxWidth {
                rows.append(current)
                current = Row()
            }
            current.items.append((index: index, size: size))
            current.width += size.width
            current.height = max(current.height, size.height)
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
                let yOffset = (row.height - item.size.height) / 2
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + yOffset),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width
            }
            y += row.height + lineSpacing
        }
    }
}
