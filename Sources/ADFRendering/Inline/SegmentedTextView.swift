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

    /// Concatenates all segments into one `AttributedString`, or `nil` when
    /// any segment is an atom.
    static func mergedText(_ segments: [InlineSegment]) -> AttributedString? {
        var merged = AttributedString()
        for segment in segments {
            guard case .text(let text) = segment else { return nil }
            merged.append(text)
        }
        return merged
    }

    /// Splits segments into layout tokens: word-level text chunks (so lines
    /// wrap), atoms, and explicit line breaks (hard breaks).
    static func tokens(for segments: [InlineSegment]) -> [InlineToken] {
        var tokens: [InlineToken] = []
        for segment in segments {
            switch segment {
            case .atom(let atom, _):
                tokens.append(InlineToken(id: tokens.count, kind: .atom(atom)))
            case .text(let text):
                appendTextTokens(text, to: &tokens)
            }
        }
        return tokens
    }

    /// Chunks an attributed run into word tokens (a word plus its trailing
    /// whitespace, attributes preserved) and line-break tokens for `\n`.
    private static func appendTextTokens(_ text: AttributedString, to tokens: inout [InlineToken]) {
        let characters = text.characters
        var chunkStart = text.startIndex
        var previousWasSpace = false
        var index = text.startIndex

        func flush(upTo end: AttributedString.Index) {
            guard chunkStart < end else { return }
            let chunk = AttributedString(text[chunkStart..<end])
            tokens.append(InlineToken(id: tokens.count, kind: .text(chunk)))
        }

        while index < text.endIndex {
            let character = characters[index]
            let next = characters.index(after: index)
            if character == "\n" {
                flush(upTo: index)
                tokens.append(InlineToken(id: tokens.count, kind: .lineBreak))
                chunkStart = next
                previousWasSpace = false
            } else if previousWasSpace, !character.isWhitespace {
                flush(upTo: index)
                chunkStart = index
                previousWasSpace = false
            } else {
                previousWasSpace = character.isWhitespace
            }
            index = next
        }
        flush(upTo: text.endIndex)
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
