import Foundation
import Testing
@testable import ADFPreparation

@Suite("SearchMatcher")
struct SearchMatcherTests {
    @Test("matching is case- and diacritic-insensitive")
    func foldedMatching() {
        #expect(SearchMatcher.matchRanges(in: "My Résumé here", query: "resume") == [3..<9])
        #expect(SearchMatcher.matchRanges(in: "HELLO hello HeLLo", query: "hello") == [0..<5, 6..<11, 12..<17])
    }

    @Test("matches never overlap; the scanner advances past each hit")
    func nonOverlapping() {
        #expect(SearchMatcher.matchRanges(in: "aaaa", query: "aa") == [0..<2, 2..<4])
    }

    @Test("empty query and empty text match nothing")
    func emptyInputs() {
        #expect(SearchMatcher.matchRanges(in: "abc", query: "").isEmpty)
        #expect(SearchMatcher.matchRanges(in: "", query: "a").isEmpty)
    }

    @Test("batch matching offsets unit indices and preserves document order")
    func batchMatching() {
        let unit = SearchTextUnit(
            ownerID: "a", topLevelBlockID: "a", expandAncestorIDs: [],
            plainText: "fox and fox",
            parts: [.init(source: .textSegment(index: 0), range: 0..<11)]
        )
        let matches = SearchMatcher.matches(in: [unit, unit], unitIndexOffset: 7, query: "fox")
        #expect(matches == [
            SearchMatch(unitIndex: 7, range: 0..<3),
            SearchMatch(unitIndex: 7, range: 8..<11),
            SearchMatch(unitIndex: 8, range: 0..<3),
            SearchMatch(unitIndex: 8, range: 8..<11),
        ])
    }

    @Test("a match slices into per-segment local spans across chunk boundaries")
    func spansAcrossSegments() {
        // plainText "one two", split as chunks: "one " (seg 0) + "two" (seg 1)
        let unit = SearchTextUnit(
            ownerID: "a", topLevelBlockID: "a", expandAncestorIDs: [],
            plainText: "one two",
            parts: [
                .init(source: .textSegment(index: 0), range: 0..<4),
                .init(source: .textSegment(index: 1), range: 4..<7),
            ]
        )
        let result = SearchMatcher.spans(for: 2..<6, in: unit) // "e tw"
        #expect(result.textSpans == [
            SearchHighlightSpan(segmentIndex: 0, range: 2..<4),
            SearchHighlightSpan(segmentIndex: 1, range: 0..<2),
        ])
        #expect(result.atomIDs.isEmpty)
    }

    @Test("a match covering an atom reports the atom ID and clips text spans around it")
    func spansOverAtom() {
        // "ask " (seg 0) + "@bob" (atom n1) + " now" (seg 2, chunked as " now")
        let unit = SearchTextUnit(
            ownerID: "a", topLevelBlockID: "a", expandAncestorIDs: [],
            plainText: "ask @bob now",
            parts: [
                .init(source: .textSegment(index: 0), range: 0..<4),
                .init(source: .atom(id: "n1"), range: 4..<8),
                .init(source: .textSegment(index: 2), range: 8..<12),
            ]
        )
        let result = SearchMatcher.spans(for: 0..<10, in: unit)
        #expect(result.textSpans == [
            SearchHighlightSpan(segmentIndex: 0, range: 0..<4),
            SearchHighlightSpan(segmentIndex: 2, range: 0..<2),
        ])
        #expect(result.atomIDs == ["n1"])
    }
}
