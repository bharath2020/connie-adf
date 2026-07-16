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

    @Test("a table-header match scrolls to the header slice, whose ID names a section")
    func tableHeaderMatchScrolls() async throws {
        let model = try await readyModel("""
        {"version":1,"type":"doc","content":[{"type":"table","content":[
          {"type":"tableRow","content":[
            {"type":"tableHeader","content":[{"type":"paragraph","content":[{"type":"text","text":"zebra header"}]}]}
          ]},
          {"type":"tableRow","content":[
            {"type":"tableCell","content":[{"type":"paragraph","content":[{"type":"text","text":"plain one"}]}]}
          ]},
          {"type":"tableRow","content":[
            {"type":"tableCell","content":[{"type":"paragraph","content":[{"type":"text","text":"plain two"}]}]}
          ]}
        ]}]}
        """)
        model.search.run("zebra") // header-only term
        try await waitUntil("scan done") { !model.search.isSearching && model.search.matchCount == 1 }
        // The requested scroll target is the header slice itself. That ID is
        // resolvable by `ScrollViewProxy.scrollTo` because the header slice's
        // ID doubles as its `BlockSection.id` — the identity `ADFDocumentView`
        // gives the whole pinned section in the lazy stack (verified live:
        // navigation from both directions lands the pinned header on screen).
        let target = try #require(model.scrollTarget)
        #expect(target.hasSuffix("#header"))
        #expect(target == model.blocks[0].id)
        #expect(model.sections.map(\.id).contains(target))
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

    @Test("querying a still-loading document streams counts to the full total")
    func streamedLoadCounts() async throws {
        var paragraphs: [String] = []
        for index in 0..<300 {
            let text = index % 2 == 0 ? "needle alpha \(index)" : "plain filler \(index)"
            paragraphs.append(#"{"type":"paragraph","content":[{"type":"text","text":"\#(text)"}]}"#)
        }
        let json = #"{"version":1,"type":"doc","content":[\#(paragraphs.joined(separator: ","))]}"#
        let model = ADFDocumentModel()
        model.search.debounceInterval = .zero
        model.load(data: Data(json.utf8))
        model.search.run("needle")   // query while chunks are still streaming in
        try await waitUntil("ready") { model.phase == .ready }
        try await waitUntil("scan drains to full total") {
            !model.search.isSearching && model.search.matchCount == 150
        }
        #expect(model.search.matchCount == 150)   // no double-counted, no skipped units
    }

    @Test("reloading mid-stream never leaks the previous document's units")
    func reloadMidStreamLeaksNothing() async throws {
        var paragraphs: [String] = []
        for index in 0..<300 {
            paragraphs.append(#"{"type":"paragraph","content":[{"type":"text","text":"stale needle \#(index)"}]}"#)
        }
        let bigJson = #"{"version":1,"type":"doc","content":[\#(paragraphs.joined(separator: ","))]}"#
        let model = ADFDocumentModel()
        model.search.debounceInterval = .zero
        model.load(data: Data(bigJson.utf8))
        try await waitUntil("first chunk lands") { !model.blocks.isEmpty }
        // Reload immediately, while index tasks for the big doc may still be in flight.
        model.load(data: Data(#"{"version":1,"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"fresh only"}]}]}"#.utf8))
        try await waitUntil("second doc ready") { model.phase == .ready }
        model.search.run("needle")
        try await waitUntil("scan settles") { !model.search.isSearching }
        // Let any straggler index tasks from the first document complete, then re-check.
        try? await Task.sleep(for: .milliseconds(200))
        try await waitUntil("still settled") { !model.search.isSearching }
        #expect(model.search.matchCount == 0)
        #expect(model.search.highlights == .none)
    }
}
