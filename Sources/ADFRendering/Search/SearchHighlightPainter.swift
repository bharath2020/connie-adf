import SwiftUI
import ADFPreparation

/// Applies search-highlight attributes to prepared text. Pure functions,
/// called from `body` ONLY when the owner has matches (the caller's guard is
/// the zero-work-common-case gate; see `scalingBaselineOffsets` precedent).
enum SearchHighlightPainter {
    private typealias SUI = AttributeScopes.SwiftUIAttributes

    /// Returns `segments` with match backgrounds applied. Returns the input
    /// value untouched (no copy) when there is nothing to paint.
    static func paint(
        segments: [InlineSegment],
        spans: [SearchHighlightSpan],
        currentSpans: [SearchHighlightSpan],
        theme: ADFTheme,
        dimCurrent: Bool
    ) -> [InlineSegment] {
        guard !spans.isEmpty || !currentSpans.isEmpty else { return segments }
        // Group edits per segment; subtle first so current overwrites.
        var edits: [Int: [(Range<Int>, Bool)]] = [:]
        for span in spans { edits[span.segmentIndex, default: []].append((span.range, false)) }
        for span in currentSpans { edits[span.segmentIndex, default: []].append((span.range, true)) }
        var painted = segments
        for (index, segmentEdits) in edits {
            guard painted.indices.contains(index), case .text(let text) = painted[index] else {
                continue // Atom spans never reach here; stale indices are skipped.
            }
            painted[index] = .text(apply(segmentEdits, to: text, theme: theme, dimCurrent: dimCurrent))
        }
        return painted
    }

    /// Single-string form for code blocks (segmentIndex is ignored; the code
    /// block is one attributed string).
    static func paint(
        text: AttributedString,
        spans: [SearchHighlightSpan],
        currentSpans: [SearchHighlightSpan],
        theme: ADFTheme,
        dimCurrent: Bool
    ) -> AttributedString {
        guard !spans.isEmpty || !currentSpans.isEmpty else { return text }
        let edits = spans.map { ($0.range, false) } + currentSpans.map { ($0.range, true) }
        return apply(edits, to: text, theme: theme, dimCurrent: dimCurrent)
    }

    private static func apply(
        _ edits: [(Range<Int>, Bool)],
        to text: AttributedString,
        theme: ADFTheme,
        dimCurrent: Bool
    ) -> AttributedString {
        var painted = text
        let count = painted.characters.count
        let clamped = edits.compactMap { range, isCurrent -> (Range<Int>, Bool)? in
            let lower = min(max(range.lowerBound, 0), count)
            let upper = min(max(range.upperBound, 0), count)
            return lower < upper ? (lower..<upper, isCurrent) : nil
        }

        // A fixed-size direct path avoids a full character walk for the
        // overwhelmingly common one-to-four-edit case. The threshold is a
        // constant, so this remains O(text length + edits); larger edit sets
        // resolve every Character offset in one forward walk.
        let offsets = Set(clamped.flatMap { [$0.0.lowerBound, $0.0.upperBound] })
        var indices: [Int: AttributedString.Index] = [:]
        indices.reserveCapacity(offsets.count)
        let characters = painted.characters
        if clamped.count <= 4 {
            for offset in offsets {
                indices[offset] = characters.index(painted.startIndex, offsetBy: offset)
            }
        } else {
            var cursor = painted.startIndex
            for offset in 0...count {
                if offsets.contains(offset) {
                    indices[offset] = cursor
                }
                if offset < count {
                    cursor = characters.index(after: cursor)
                }
            }
        }

        // Callers append subtle edits first, so current accent edits overwrite.
        for (range, isCurrent) in clamped {
            guard let start = indices[range.lowerBound], let end = indices[range.upperBound] else {
                continue
            }
            let accent = isCurrent && !dimCurrent
            painted[start..<end][SUI.BackgroundColorAttribute.self] =
                accent ? theme.searchCurrentHighlight : theme.searchHighlight
            if accent, let foreground = theme.searchCurrentForeground {
                painted[start..<end][SUI.ForegroundColorAttribute.self] = foreground
            }
        }
        return painted
    }
}
