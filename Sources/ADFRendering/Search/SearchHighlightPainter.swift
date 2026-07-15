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
        // Subtle first, current last, so the accent wins on overlap.
        for (range, isCurrent) in edits.sorted(by: { !$0.1 && $1.1 }) {
            let lower = min(max(range.lowerBound, 0), count)
            let upper = min(max(range.upperBound, 0), count)
            guard lower < upper else { continue }
            let characters = painted.characters
            let start = characters.index(painted.startIndex, offsetBy: lower)
            let end = characters.index(start, offsetBy: upper - lower)
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
