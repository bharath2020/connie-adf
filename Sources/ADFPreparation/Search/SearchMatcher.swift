import Foundation

/// Pure string matching over indexed units. All offsets are Character
/// offsets (the unit of `AttributedString.characters`), so folded matches
/// (case/diacritic variants of different UTF lengths) stay aligned with the
/// original text.
public enum SearchMatcher {
    /// Non-overlapping hits of `query` in `text`, case- and
    /// diacritic-insensitive, as Character-offset ranges in `text`.
    public static func matchRanges(in text: String, query: String) -> [Range<Int>] {
        guard !query.isEmpty, !text.isEmpty else { return [] }
        var result: [Range<Int>] = []
        var searchStart = text.startIndex
        // Running Character offset of `searchStart`, so each hit converts
        // indices with a short local distance, not a scan from the start.
        var startOffset = 0
        while let found = text.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: searchStart..<text.endIndex,
            locale: nil
        ) {
            let lower = startOffset + text.distance(from: searchStart, to: found.lowerBound)
            let upper = lower + text.distance(from: found.lowerBound, to: found.upperBound)
            result.append(lower..<upper)
            searchStart = found.upperBound
            startOffset = upper
        }
        return result
    }

    /// Batch form used by the streaming scan: hits for `units`, whose global
    /// indices start at `unitIndexOffset`, in document order.
    public static func matches(
        in units: [SearchTextUnit],
        unitIndexOffset: Int,
        query: String
    ) -> [SearchMatch] {
        var result: [SearchMatch] = []
        for (localIndex, unit) in units.enumerated() {
            for range in matchRanges(in: unit.plainText, query: query) {
                result.append(SearchMatch(unitIndex: unitIndexOffset + localIndex, range: range))
            }
        }
        return result
    }

    /// Slices one match range through the unit's part map into paintable
    /// pieces: per-segment LOCAL Character ranges for text parts, plus the
    /// IDs of atom pills the range covers (pills highlight whole).
    public static func spans(
        for range: Range<Int>,
        in unit: SearchTextUnit
    ) -> (textSpans: [SearchHighlightSpan], atomIDs: [String]) {
        var textSpans: [SearchHighlightSpan] = []
        var atomIDs: [String] = []
        for part in unit.parts where part.range.overlaps(range) {
            switch part.source {
            case .textSegment(let segmentIndex):
                let lower = max(range.lowerBound, part.range.lowerBound) - part.range.lowerBound
                let upper = min(range.upperBound, part.range.upperBound) - part.range.lowerBound
                guard lower < upper else { continue }
                textSpans.append(SearchHighlightSpan(segmentIndex: segmentIndex, range: lower..<upper))
            case .atom(let id):
                atomIDs.append(id)
            }
        }
        return (textSpans, atomIDs)
    }
}
