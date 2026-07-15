import Foundation
import Testing
import ADFPreparation
@testable import ADFRendering

/// Polls a main-actor condition with yields; fails fast instead of hanging.
@MainActor
private func waitUntil(
    _ what: Comment,
    timeoutIterations: Int = 2_000,
    _ condition: () -> Bool
) async throws {
    for _ in 0..<timeoutIterations {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("timed out waiting for \(what)")
    throw TestFailure("timeout: \(what)")
}

@MainActor
private func readyModel(_ json: String) async throws -> ADFDocumentModel {
    let model = ADFDocumentModel()
    model.load(data: Data(json.utf8))
    try await waitUntil("document ready") { model.phase == .ready }
    model.search.debounceInterval = .zero
    return model
}

private let threeFoxes = """
{"version":1,"type":"doc","content":[
  {"type":"paragraph","content":[{"type":"text","text":"a fox leads"}]},
  {"type":"paragraph","content":[{"type":"text","text":"no match here"}]},
  {"type":"paragraph","content":[{"type":"text","text":"fox two and fox three"}]}
]}
"""

@Suite("ADFDocumentSearch")
@MainActor
struct ADFDocumentSearchTests {
    @Test("run streams counts, auto-selects the first match, and requests a scroll")
    func runFindsAndAutoSelects() async throws {
        let model = try await readyModel(threeFoxes)
        model.search.run("fox")
        try await waitUntil("scan done") { !model.search.isSearching && model.search.matchCount > 0 }
        #expect(model.search.matchCount == 3)
        #expect(model.search.currentIndex == 0)
        #expect(model.search.highlights.current?.ownerID == model.blocks[0].id)
        // No visibility reporting in tests → navigation always scrolls.
        #expect(model.scrollTarget == model.blocks[0].id)
        #expect(model.search.highlights.spansByOwner.count == 2) // blocks 0 and 2
    }

    @Test("next and previous wrap in both directions and bump the flash generation")
    func navigationWraps() async throws {
        let model = try await readyModel(threeFoxes)
        model.search.run("fox")
        try await waitUntil("scan done") { !model.search.isSearching && model.search.matchCount == 3 }
        let firstGeneration = try #require(model.search.highlights.current?.generation)

        model.search.next()
        #expect(model.search.currentIndex == 1)
        model.search.next()
        #expect(model.search.currentIndex == 2)
        model.search.next() // wraps
        #expect(model.search.currentIndex == 0)
        model.search.previous() // wraps back
        #expect(model.search.currentIndex == 2)
        let lastGeneration = try #require(model.search.highlights.current?.generation)
        #expect(lastGeneration == firstGeneration + 4)
    }

    @Test("navigation direction picks nearBottom for matches at/after the top row")
    func placementFollowsDirection() async throws {
        let model = try await readyModel(threeFoxes)
        model.search.run("fox")
        try await waitUntil("scan done") { !model.search.isSearching && model.search.matchCount == 3 }
        // Simulate the viewport sitting at the last block: match 0 is ABOVE.
        model.anchors.topRow = model.blocks[2].id
        model.scrollTarget = nil
        model.search.next() // from 0 → 1 (block 2, at top row → below/at)
        #expect(model.scrollTargetPlacement == .nearBottom(margin: model.search.scrollMargin))
        model.anchors.topRow = model.blocks[2].id
        model.search.next() // → 2 (same block, still nearBottom)
        model.search.next() // wraps → 0 (block 0, above top row)
        #expect(model.scrollTargetPlacement == .nearTop(margin: model.search.scrollMargin))
    }

    @Test("clear empties results, highlights, and query")
    func clearResets() async throws {
        let model = try await readyModel(threeFoxes)
        model.search.run("fox")
        try await waitUntil("scan done") { model.search.matchCount == 3 }
        model.search.clear()
        #expect(model.search.query.isEmpty)
        #expect(model.search.matchCount == 0)
        #expect(model.search.currentIndex == nil)
        #expect(model.search.highlights == .none)
    }

    @Test("matches inside collapsed expands are counted and navigation expands ancestors")
    func expandAutoExpands() async throws {
        let model = try await readyModel("""
        {"version":1,"type":"doc","content":[
          {"type":"paragraph","content":[{"type":"text","text":"intro"}]},
          {"type":"expand","attrs":{"title":"More"},"content":[
            {"type":"paragraph","content":[{"type":"text","text":"hidden fox"}]}
          ]}
        ]}
        """)
        #expect(model.expandedBlocks.isEmpty) // nothing expanded before the search
        model.search.run("fox")
        try await waitUntil("scan done") { !model.search.isSearching && model.search.matchCount == 1 }
        // Auto-select already navigated to the only match, expanding its
        // ancestor chain and requesting the scroll (an expanding target
        // always scrolls — it needs a layout pass to reveal the body).
        #expect(model.search.currentIndex == 0)
        #expect(model.expandedBlocks.contains(model.blocks[1].id))
        #expect(model.scrollTarget == model.blocks[1].id)
    }

    @Test("reload resets search state")
    func reloadResets() async throws {
        let model = try await readyModel(threeFoxes)
        model.search.run("fox")
        try await waitUntil("scan done") { model.search.matchCount == 3 }
        model.load(data: Data(threeFoxes.utf8))
        #expect(model.search.matchCount == 0)
        #expect(model.search.highlights == .none)
        try await waitUntil("re-ready") { model.phase == .ready }
    }

    @Test("empty query behaves as clear")
    func emptyQueryClears() async throws {
        let model = try await readyModel(threeFoxes)
        model.search.run("fox")
        try await waitUntil("scan done") { model.search.matchCount == 3 }
        model.search.run("")
        #expect(model.search.matchCount == 0)
        #expect(model.search.highlights == .none)
    }
}
