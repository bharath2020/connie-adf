import Testing
@testable import ADFPreparation

@Suite("IncrementalSearchIndex")
struct IncrementalSearchIndexTests {
    private func unit(_ owner: String, _ text: String) -> SearchTextUnit {
        SearchTextUnit(
            ownerID: owner,
            topLevelBlockID: owner,
            expandAncestorIDs: [],
            plainText: text,
            parts: [.init(source: .textSegment(index: 0), range: 0..<text.count)]
        )
    }

    private func item(_ id: String, _ text: String) -> SearchIndexedItem {
        SearchIndexedItem(id: id, units: [unit(id, text)])
    }

    @Test("insert, move, replace, and remove preserve logical item order")
    func mutationsPreserveOrder() throws {
        var index = IncrementalSearchIndex()
        try index.append(item("a", "alpha"))
        try index.append(item("c", "charlie"))
        try index.insert(item("b", "bravo"), after: "a")
        #expect(index.itemOrder == ["a", "b", "c"])

        try index.move(id: "c", after: nil)
        #expect(index.itemOrder == ["c", "a", "b"])

        try index.replace(item("a", "updated alpha"))
        #expect(index.item(id: "a")?.units.first?.plainText == "updated alpha")

        let removed = try index.remove(id: "b")
        #expect(removed.id == "b")
        #expect(index.itemOrder == ["c", "a"])
    }

    @Test("mutation errors leave the index valid")
    func mutationErrors() throws {
        var index = IncrementalSearchIndex()
        try index.append(item("a", "alpha"))
        #expect(throws: IncrementalSearchIndexError.duplicateItem("a")) {
            try index.append(item("a", "again"))
        }
        #expect(throws: IncrementalSearchIndexError.invalidAnchor("missing")) {
            try index.insert(item("b", "bravo"), after: "missing")
        }
        #expect(throws: IncrementalSearchIndexError.missingItem("missing")) {
            try index.remove(id: "missing")
        }
        #expect(index.itemOrder == ["a"])
    }

    @Test("replacing one item changes only that item's query result")
    func replacementIsLocal() throws {
        var index = IncrementalSearchIndex()
        try index.append(item("a", "needle one"))
        try index.append(item("b", "plain"))
        try index.append(item("c", "needle three"))

        var results = Dictionary(uniqueKeysWithValues:
            index.results(query: "needle").map { ($0.itemID, $0) }
        )
        #expect(results.values.reduce(0) { $0 + $1.matches.count } == 2)
        let unchanged = results["a"]

        try index.replace(item("b", "needle two needle"))
        results["b"] = try #require(index.result(for: "b", query: "needle"))

        #expect(results["a"] == unchanged)
        #expect(results["b"]?.matches.count == 2)
        #expect(results.values.reduce(0) { $0 + $1.matches.count } == 4)
    }

    @Test("batch span slicing is identical to independent slicing")
    func batchSpanSlicingMatchesLegacy() {
        let indexed = SearchTextUnit(
            ownerID: "owner",
            topLevelBlockID: "owner",
            expandAncestorIDs: [],
            plainText: "one @bob two @bob",
            parts: [
                .init(source: .textSegment(index: 0), range: 0..<4),
                .init(source: .atom(id: "bob1"), range: 4..<8),
                .init(source: .textSegment(index: 2), range: 8..<13),
                .init(source: .atom(id: "bob2"), range: 13..<17),
            ]
        )
        let ranges = [0..<3, 4..<8, 9..<12, 13..<17]
        let batch = SearchMatcher.spans(for: ranges, in: indexed)
        let independent = ranges.map { range in
            let value = SearchMatcher.spans(for: range, in: indexed)
            return SearchMatchPainting(textSpans: value.textSpans, atomIDs: value.atomIDs)
        }
        #expect(batch == independent)
    }

    @Test("item results aggregate text spans and atom IDs by owner")
    func ownerPayloads() {
        let indexed = SearchTextUnit(
            ownerID: "owner",
            topLevelBlockID: "top",
            expandAncestorIDs: [],
            plainText: "ask @bob",
            parts: [
                .init(source: .textSegment(index: 0), range: 0..<4),
                .init(source: .atom(id: "bob"), range: 4..<8),
            ]
        )
        let result = IncrementalSearchIndex.result(
            for: SearchIndexedItem(id: "item", units: [indexed]),
            query: "ask @bob"
        )
        #expect(result.matches.count == 1)
        #expect(result.spansByOwner["owner"] == [
            SearchHighlightSpan(segmentIndex: 0, range: 0..<4)
        ])
        #expect(result.atomIDsByOwner["owner"] == ["bob"])
    }
}
