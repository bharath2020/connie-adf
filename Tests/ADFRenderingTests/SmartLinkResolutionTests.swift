import Foundation
import SwiftUI
import Testing
import ADFModel
import ADFPreparation
@_spi(ADFDiagnostics) @testable import ADFRendering

/// A document the coordinator reads nearby positions from: its top-level
/// blocks, a mutation revision and the row at the top of the screen.
@MainActor
final class StubSmartLinkDocument: SmartLinkDocument {
    var smartLinkBlocks: [RenderBlock]
    var smartLinkRevision: UInt64 = 0
    var smartLinkTopRowIndex: Int?

    init(_ blocks: [RenderBlock]) {
        smartLinkBlocks = blocks
    }
}

/// Resolution modes (design §8): when lookups start relative to the
/// document's scroll phase, and `.afterScrollingWithNearby`'s batches of
/// off-screen links — driven by hand with injected phase and visibility
/// events, a stub document and a scripted resolver.
@Suite("Smart link resolution modes", .serialized)
@MainActor
struct SmartLinkResolutionTests {
    nonisolated static func key(_ name: String) -> SmartLinkKey {
        SmartLinkKey("https://acme.atlassian.net/wiki/\(name)")!
    }

    nonisolated static let page = ADFSmartLinkMetadata(title: "Title", icon: .page)

    static let style = TextBlockStyle(
        font: .body, isHeading: false, headingLevel: nil, alignment: nil, indentation: 0, breakout: nil
    )

    static func paragraph(_ id: String, _ keys: [SmartLinkKey] = []) -> RenderBlock {
        RenderBlock(id: id, kind: .richText(segments: [], style: style), smartLinkKeys: keys)
    }

    /// Top-level rows `p0…p<count-1>`, each one position, row `i` holding
    /// the key `n<i>` (rows in `plain` hold none).
    static func paragraphs(_ count: Int, plain: Set<Int> = []) -> [RenderBlock] {
        (0..<count).map { index in
            paragraph("p\(index)", plain.contains(index) ? [] : [key("n\(index)")])
        }
    }

    static func coordinator(
        _ resolver: any ADFSmartLinkResolver, mode: ADFSmartLinkResolution, blocks: [RenderBlock] = [],
        dwell: Duration = .zero, maxConcurrent: Int = 4, sleeper: ManualSleeper? = nil, feed: Bool = true
    ) async -> (SmartLinkCoordinator, StubSmartLinkDocument) {
        var timing = SmartLinkTiming(dwell: dwell, maxConcurrent: maxConcurrent)
        timing.prefetchPause = .zero
        if let sleeper { timing.sleep = { try await sleeper.sleep($0) } }
        let coordinator = SmartLinkCoordinator(timing: timing, hasVisibilityFeed: feed)
        coordinator.resolver = resolver
        let document = StubSmartLinkDocument(blocks)
        coordinator.document = document
        coordinator.resolution = mode
        // The mode's effects land a main-actor turn later.
        await settle()
        return (coordinator, document)
    }

    static func show(_ coordinator: SmartLinkCoordinator, _ leaf: String, _ keys: [SmartLinkKey]) {
        coordinator.attach(leaf: leaf, keys: keys)
        coordinator.setLeafVisible(leaf, true)
    }

    /// Gives queued tasks (dwells, nearby plans, landing results) a chance.
    static func settle() async {
        for _ in 0..<40 { await Task.yield() }
    }

    static func names(_ urls: some Sequence<URL>) -> Set<String> {
        Set(urls.map(\.lastPathComponent))
    }

    // MARK: Mode 1

    @Test("whileScrolling is today's behaviour: a link that comes on screen mid-scroll is looked up mid-scroll")
    func whileScrollingIgnoresThePhase() async throws {
        #expect(ADFSmartLinkResolution.allCases == [.whileScrolling, .afterScrolling, .afterScrollingWithNearby])
        #expect(ADFSmartLinkResolution.allCases.map(\.displayName)
            == ["While Scrolling", "After Scrolling", "After Scrolling + Nearby"])
        #expect(SmartLinkCoordinator().resolution == .whileScrolling)
        let resolver = ScriptedSmartLinkResolver(answerEverything: { _ in .success(Self.page) })
        let (coordinator, document) = await Self.coordinator(resolver, mode: .whileScrolling, blocks: Self.paragraphs(30))
        defer { withExtendedLifetime(document) {} }
        coordinator.scrollPhaseChanged(scrolling: true, offset: 0)
        Self.show(coordinator, "p3", [Self.key("n3")])
        try await smartLinkEventually("resolved mid-scroll") { coordinator.stage(for: Self.key("n3")) == .resolved(Self.page) }
        #expect(coordinator.stats.scrollingCalls == 1)
        #expect(coordinator.stats.isScrolling)
        coordinator.scrollPhaseChanged(scrolling: false, offset: 400)
        await Self.settle()
        #expect(coordinator.stats.scrollEnds == 1)
        // Never prefetches.
        #expect(Self.names(resolver.calls) == ["n3"])
        #expect(coordinator.stats.prefetchCalls == 0 && coordinator.stats.deferred == 0)
    }

    // MARK: Mode 2

    @Test("afterScrolling starts nothing while scrolling, then exactly the visible keys at rest, in the order they came")
    func afterScrollingStartsVisibleKeysAtRest() async throws {
        let resolver = ScriptedSmartLinkResolver(answerEverything: { _ in .success(Self.page) })
        let (coordinator, document) = await Self.coordinator(resolver, mode: .afterScrolling, blocks: Self.paragraphs(30))
        defer { withExtendedLifetime(document) {} }
        coordinator.scrollPhaseChanged(scrolling: true, offset: 0)
        Self.show(coordinator, "p5", [Self.key("n5")])
        Self.show(coordinator, "p6", [Self.key("n6")])
        // Flung past: on screen during the scroll, gone before it ends.
        Self.show(coordinator, "p7", [Self.key("n7")])
        await Self.settle()
        #expect(resolver.calls.isEmpty, "a lookup started while scrolling: \(resolver.calls)")
        #expect(coordinator.pendingKeys.isEmpty)
        #expect(coordinator.stats.waiting == 3)
        #expect(coordinator.stats.deferred == 3)
        coordinator.setLeafVisible("p7", false)
        Self.show(coordinator, "p8", [Self.key("n8")])
        #expect(coordinator.stage(for: Self.key("n5")) == .plain)

        coordinator.scrollPhaseChanged(scrolling: false, offset: 900)
        try await smartLinkEventually("the visible keys resolved") { coordinator.stats.resolved == 3 }
        await Self.settle()
        #expect(Self.names(resolver.calls) == ["n5", "n6", "n8"], "\(resolver.calls)")
        #expect(coordinator.stage(for: Self.key("n7")) == .plain)
        let stats = coordinator.stats
        #expect(stats.scrollingCalls == 0 && stats.waiting == 0 && stats.prefetchCalls == 0, "\(stats)")
        #expect(stats.scrollEnds == 1)
    }

    @Test("afterScrolling: the keys held during a scroll start in the order they came on screen")
    func afterScrollingStartsInArrivalOrder() async throws {
        let resolver = ScriptedSmartLinkResolver()
        let (coordinator, document) = await Self.coordinator(resolver, mode: .afterScrolling, maxConcurrent: 1)
        defer { withExtendedLifetime(document) {} }
        coordinator.scrollPhaseChanged(scrolling: true, offset: 0)
        for name in ["c", "a", "b"] { Self.show(coordinator, "p\(name)", [Self.key(name)]) }
        coordinator.scrollPhaseChanged(scrolling: false, offset: 300)
        try await smartLinkEventually("the first call") { resolver.waitingURLs.count == 1 }
        #expect(Self.names(resolver.calls) == ["c"])
        #expect(coordinator.queuedKeys == [Self.key("a"), Self.key("b")])
    }

    @Test("afterScrolling: a running call survives a new scroll, a dwell does not, and the queue waits for rest")
    func afterScrollingRunningDwellingQueued() async throws {
        let resolver = ScriptedSmartLinkResolver()
        let sleeper = ManualSleeper()
        let (coordinator, document) = await Self.coordinator(
            resolver, mode: .afterScrolling, dwell: .milliseconds(150), maxConcurrent: 1, sleeper: sleeper
        )
        defer { withExtendedLifetime(document) {} }
        let a = Self.key("a"), b = Self.key("b"), c = Self.key("c")
        Self.show(coordinator, "pa", [a])
        try await smartLinkEventually("a's dwell") { sleeper.count == 1 }
        sleeper.wakeAll()
        try await smartLinkEventually("a's call") { resolver.waitingURLs == [a.url] }
        // b dwells, then queues behind a (one slot).
        Self.show(coordinator, "pb", [b])
        try await smartLinkEventually("b's dwell") { sleeper.count == 1 }
        sleeper.wakeAll()
        try await smartLinkEventually("b queued") { coordinator.queuedKeys == [b] }
        // c dwells.
        Self.show(coordinator, "pc", [c])
        try await smartLinkEventually("c's dwell") { sleeper.count == 1 }

        coordinator.scrollPhaseChanged(scrolling: true, offset: 0)
        try await smartLinkEventually("c's dwell dropped") { sleeper.count == 0 }
        #expect(coordinator.stage(for: a) == .resolving, "a running call was stopped by the scroll")
        #expect(resolver.cancelled.isEmpty)
        // a lands mid-scroll; its free slot does not go to b until rest.
        resolver.answer(a.url, .success(Self.page))
        try await smartLinkEventually("a resolved mid-scroll") { coordinator.stage(for: a) == .resolved(Self.page) }
        await Self.settle()
        #expect(coordinator.queuedKeys == [b])
        #expect(resolver.calls == [a.url])

        coordinator.scrollPhaseChanged(scrolling: false, offset: 200)
        try await smartLinkEventually("b started at rest") { resolver.waitingURLs == [b.url] }
        // c dwells again (a new dwell, at rest).
        try await smartLinkEventually("c dwells again") { sleeper.count == 1 }
        sleeper.wakeAll()
        try await smartLinkEventually("c queued behind b") { coordinator.queuedKeys == [c] }
        #expect(coordinator.stats.scrollingCalls == 0)
    }

    @Test("without a scroll-phase feed (iOS 17 / macOS 14) afterScrolling resolves as whileScrolling and nothing is prefetched")
    func noFeedFallsBackToWhileScrolling() async throws {
        let resolver = ScriptedSmartLinkResolver(answerEverything: { _ in .success(Self.page) })
        let blocks = Self.paragraphs(30)
        for mode in [ADFSmartLinkResolution.afterScrolling, .afterScrollingWithNearby] {
            let (coordinator, document) = await Self.coordinator(resolver, mode: mode, blocks: blocks, feed: false)
            defer { withExtendedLifetime(document) {} }
            coordinator.attach(leaf: "p10", keys: [Self.key("n10")])
            try await smartLinkEventually("\(mode) resolved") { coordinator.stage(for: Self.key("n10")) == .resolved(Self.page) }
            await Self.settle()
            #expect(coordinator.stats.prefetchCalls == 0, "\(mode) prefetched without a visibility feed")
        }
        #expect(Self.names(resolver.calls) == ["n10"])
    }

    // MARK: Mode 3

    @Test("afterScrollingWithNearby: batches of at most 3 nearest keys, one at a time, never beyond 12 positions")
    func nearbyBatches() async throws {
        let resolver = ScriptedSmartLinkResolver()
        let (coordinator, document) = await Self.coordinator(
            resolver, mode: .afterScrollingWithNearby, blocks: Self.paragraphs(60)
        )
        defer { withExtendedLifetime(document) {} }
        #expect(SmartLinkTiming().prefetchBatchSize == 3)
        #expect(SmartLinkTiming().nearbyDistance == 12)
        #expect(SmartLinkTiming().prefetchPause == .milliseconds(150))
        // The lazy stack built rows 29 and 31 around the visible row 30:
        // attached, not visible.
        coordinator.attach(leaf: "p29", keys: [Self.key("n29")])
        coordinator.setLeafVisible("p29", false)
        coordinator.attach(leaf: "p31", keys: [Self.key("n31")])
        Self.show(coordinator, "p30", [Self.key("n30")])
        // The visible key first, then batch 1: distance 1 below (the
        // default direction), distance 1 above, distance 2 below.
        try await smartLinkEventually("batch 1") { resolver.waitingURLs.count == 4 }
        #expect(Self.names(resolver.waitingURLs) == ["n30", "n31", "n29", "n32"])
        #expect(coordinator.prefetchBatchKeys == [Self.key("n31"), Self.key("n29"), Self.key("n32")])
        // A nearby lookup publishes no stage: no off-screen leaf redraws.
        #expect(coordinator.stage(for: Self.key("n31")) == .plain)
        #expect(coordinator.stats.prefetchInFlight == 3)

        // One batch at a time: two of three answered, no new batch.
        resolver.answer(Self.key("n31").url, .success(Self.page))
        resolver.answer(Self.key("n29").url, .success(Self.page))
        await Self.settle()
        #expect(resolver.calls.count == 4)
        #expect(coordinator.stage(for: Self.key("n31")) == .plain)
        #expect(coordinator.prefetchedStage(for: Self.key("n31")) == .resolved(Self.page))
        // Drawn by a leaf built now, without observing anything new.
        #expect(coordinator.displayStages(for: [Self.key("n31")], owner: nil) == [Self.key("n31"): .resolved(Self.page)])

        resolver.answer(Self.key("n32").url, .success(Self.page))
        try await smartLinkEventually("batch 2") { resolver.calls.count == 7 }
        #expect(Self.names(resolver.calls.suffix(3)) == ["n28", "n33", "n27"])

        // Run the rest to the end.
        for _ in 0..<20 {
            for url in resolver.waitingURLs { resolver.answer(url, .success(Self.page)) }
            await Self.settle()
        }
        try await smartLinkEventually("nothing left nearby") { resolver.waitingURLs.isEmpty }
        await Self.settle()
        let expected = Set((18...42).map { "n\($0)" })
        #expect(Self.names(resolver.calls) == expected, "asked beyond 12 positions, or missed one: \(Self.names(resolver.calls).symmetricDifference(expected))")
        #expect(resolver.calls.count == expected.count, "a URL was asked twice")
        let stats = coordinator.stats
        #expect(stats.prefetchCalls == 24 && stats.prefetchBatches == 8, "\(stats)")
        #expect(stats.largestPrefetchBatch == 3 && stats.peakPrefetchInFlight == 3, "\(stats)")
        #expect(stats.farthestPrefetch == 12, "\(stats)")
        #expect(stats.resolverCalls == stats.resolved + stats.failed + stats.cancellations + stats.inFlight)
        #expect(stats.scrollingCalls == 0)
    }

    @Test("afterScrollingWithNearby: a prefetched link coming on screen shows its title with no lookup, even mid-scroll")
    func prefetchedLinkShowsWithoutLookup() async throws {
        let resolver = ScriptedSmartLinkResolver(answerEverything: { _ in .success(Self.page) })
        let (coordinator, document) = await Self.coordinator(
            resolver, mode: .afterScrollingWithNearby, blocks: Self.paragraphs(20)
        )
        defer { withExtendedLifetime(document) {} }
        Self.show(coordinator, "p5", [Self.key("n5")])
        // Positions 0–4 and 6–17: everything within 12 of row 5.
        try await smartLinkEventually("prefetched all within reach") { coordinator.stats.prefetchCalls == 17 }
        try await smartLinkEventually("landed") { coordinator.stats.inFlight == 0 }
        let calls = resolver.calls.count
        #expect(coordinator.stage(for: Self.key("n9")) == .plain)

        coordinator.scrollPhaseChanged(scrolling: true, offset: 0)
        Self.show(coordinator, "p9", [Self.key("n9")])
        #expect(coordinator.stage(for: Self.key("n9")) == .resolved(Self.page), "the prefetched title was not shown on arrival")
        #expect(coordinator.stats.prefetchHits == 1)
        await Self.settle()
        #expect(resolver.calls.count == calls, "a prefetched link was looked up again")
        #expect(coordinator.stats.scrollingCalls == 0)
    }

    @Test("afterScrollingWithNearby: scrolling cancels the running batch; at the next rest planning starts again")
    func scrollingStopsPrefetching() async throws {
        let resolver = ScriptedSmartLinkResolver()
        let (coordinator, document) = await Self.coordinator(
            resolver, mode: .afterScrollingWithNearby, blocks: Self.paragraphs(40)
        )
        Self.show(coordinator, "p20", [Self.key("n20")])
        try await smartLinkEventually("batch 1") { coordinator.stats.prefetchInFlight == 3 }
        resolver.answer(Self.key("n20").url, .success(Self.page))
        let batch = coordinator.prefetchBatchKeys

        coordinator.scrollPhaseChanged(scrolling: true, offset: 1_000)
        #expect(coordinator.prefetchBatchKeys.isEmpty)
        try await smartLinkEventually("the batch cancelled") { Self.names(resolver.cancelled) == Self.names(batch.map(\.url)) }
        try await smartLinkEventually("the cancelled calls ended") { coordinator.stats.prefetchCancellations == 3 }
        let stats = coordinator.stats
        #expect(stats.prefetchInFlight == 0 && stats.inFlight == 0 && stats.cancellations == 3, "\(stats)")
        for key in batch {
            #expect(coordinator.stage(for: key) == .plain && coordinator.prefetchedStage(for: key) == nil)
        }
        await Self.settle()
        #expect(resolver.calls.count == 4, "a batch started while scrolling")

        // Scrolled up: rows 9–11 on screen now.
        coordinator.setLeafVisible("p20", false)
        document.smartLinkTopRowIndex = 9
        Self.show(coordinator, "p10", [Self.key("n10")])
        coordinator.scrollPhaseChanged(scrolling: false, offset: 400)
        // Up was the last direction: at equal distance, above first.
        try await smartLinkEventually("a new batch at rest") { coordinator.stats.prefetchBatches == 2 }
        // The batch's calls reach the resolver on a background executor.
        try await smartLinkEventually("the batch's calls arrived") { resolver.calls.count == 8 }
        #expect(Self.names(resolver.calls.suffix(3)) == ["n9", "n11", "n8"], "\(resolver.calls.suffix(4))")
        #expect(coordinator.stats.scrollingCalls == 0)
    }

    @Test("afterScrollingWithNearby: cached, in-flight, demanded and repeated URLs are never asked again")
    func prefetchDedup() async throws {
        let resolver = ScriptedSmartLinkResolver()
        let shared = Self.key("shared"), done = Self.key("done"), fresh = Self.key("fresh")
        let blocks = [
            Self.paragraph("p0", [done]),
            Self.paragraph("p1", [shared]),
            Self.paragraph("p2", [shared, done, fresh]),
            Self.paragraph("p3", [fresh, shared]),
        ]
        // Visible first, under afterScrolling: `done` resolves, `shared` is
        // still being looked up when nearby lookups begin.
        let (coordinator, document) = await Self.coordinator(resolver, mode: .afterScrolling, blocks: blocks)
        defer { withExtendedLifetime(document) {} }
        Self.show(coordinator, "p0", [done])
        try await smartLinkEventually("done's call") { resolver.waitingURLs == [done.url] }
        resolver.answer(done.url, .success(Self.page))
        try await smartLinkEventually("done resolved") { coordinator.stage(for: done) == .resolved(Self.page) }
        coordinator.setLeafVisible("p0", false)
        Self.show(coordinator, "p1", [shared])
        try await smartLinkEventually("shared's call") { resolver.waitingURLs == [shared.url] }
        coordinator.resolution = .afterScrollingWithNearby
        try await smartLinkEventually("only fresh is prefetched") { coordinator.stats.prefetchCalls == 1 }
        await Self.settle()
        #expect(resolver.calls.filter { $0 == shared.url }.count == 1)
        #expect(resolver.calls.filter { $0 == done.url }.count == 1)
        #expect(Self.names(coordinator.prefetchingKeys.map(\.url)) == ["fresh"])
        resolver.answer(fresh.url, .failure(ADFSmartLinkError.notFound))
        resolver.answer(shared.url, .success(Self.page))
        try await smartLinkEventually("fresh cached as failed") { coordinator.prefetchedStage(for: fresh) == .failed(.notFound) }
        await Self.settle()
        #expect(resolver.calls.count == 3, "\(resolver.calls)")
        // A cached failure is terminal: on screen it is published, never asked again.
        Self.show(coordinator, "p3", [fresh, shared])
        #expect(coordinator.stage(for: fresh) == .failed(.notFound))
        await Self.settle()
        #expect(resolver.calls.count == 3)
    }

    @Test("afterScrollingWithNearby: a link that comes on screen during its nearby lookup becomes a visible lookup")
    func promotion() async throws {
        let resolver = ScriptedSmartLinkResolver()
        let (coordinator, document) = await Self.coordinator(
            resolver, mode: .afterScrollingWithNearby, blocks: Self.paragraphs(10)
        )
        defer { withExtendedLifetime(document) {} }
        Self.show(coordinator, "p0", [Self.key("n0")])
        try await smartLinkEventually("batch 1") { coordinator.prefetchBatchKeys == [Self.key("n1"), Self.key("n2"), Self.key("n3")] }
        Self.show(coordinator, "p1", [Self.key("n1")])
        #expect(coordinator.stage(for: Self.key("n1")) == .resolving)
        #expect(coordinator.prefetchBatchKeys == [Self.key("n2"), Self.key("n3")])
        #expect(coordinator.stats.prefetchInFlight == 2)
        // A visible lookup now: a scroll does not cancel it.
        coordinator.scrollPhaseChanged(scrolling: true, offset: 0)
        try await smartLinkEventually("the other two cancelled") { Self.names(resolver.cancelled) == ["n2", "n3"] }
        resolver.answer(Self.key("n1").url, .success(Self.page))
        try await smartLinkEventually("n1 published") { coordinator.stage(for: Self.key("n1")) == .resolved(Self.page) }
    }

    @Test("afterScrollingWithNearby: a batch waits for visible keys still dwelling, and visible keys queue ahead")
    func visibleFirst() async throws {
        let resolver = ScriptedSmartLinkResolver()
        let sleeper = ManualSleeper()
        var timing = SmartLinkTiming(dwell: .milliseconds(150), maxConcurrent: 4)
        timing.prefetchPause = .zero
        // Dwells go through the manual sleeper; nearby pauses are zero.
        timing.sleep = { duration in
            if duration > .zero { try await sleeper.sleep(duration) }
        }
        let coordinator = SmartLinkCoordinator(timing: timing, hasVisibilityFeed: true)
        coordinator.resolver = resolver
        let document = StubSmartLinkDocument(Self.paragraphs(30))
        coordinator.document = document
        coordinator.resolution = .afterScrollingWithNearby
        await Self.settle()
        Self.show(coordinator, "p10", [Self.key("n10")])
        try await smartLinkEventually("the visible dwell") { sleeper.count == 1 }
        await Self.settle()
        #expect(resolver.calls.isEmpty && coordinator.stats.prefetchBatches == 0, "a batch started before the visible key")
        sleeper.wakeAll()
        try await smartLinkEventually("visible, then a batch") { resolver.calls.count == 4 }
        #expect(resolver.calls.first == Self.key("n10").url)
        // All four slots busy: a newly visible key queues ahead of nothing
        // (nearby keys are all running), then starts first when one frees.
        Self.show(coordinator, "p25", [Self.key("n25")])
        try await smartLinkEventually("its dwell") { sleeper.count == 1 }
        sleeper.wakeAll()
        try await smartLinkEventually("queued") { coordinator.queuedKeys == [Self.key("n25")] }
        resolver.answer(Self.key("n11").url, .success(Self.page))
        try await smartLinkEventually("the freed slot went to the visible key") { resolver.waitingURLs.contains(Self.key("n25").url) }
    }

    @Test("afterScrollingWithNearby: with no link on screen, the row at the top of the screen anchors the plan")
    func topRowAnchor() async throws {
        let resolver = ScriptedSmartLinkResolver()
        let blocks = Self.paragraphs(40, plain: Set(0...25))
        let (coordinator, document) = await Self.coordinator(resolver, mode: .afterScrollingWithNearby, blocks: blocks)
        document.smartLinkTopRowIndex = 20
        coordinator.scrollPhaseChanged(scrolling: true, offset: 0)
        coordinator.scrollPhaseChanged(scrolling: false, offset: 500)
        try await smartLinkEventually("a batch from row 20") { resolver.calls.count == 3 }
        #expect(Self.names(resolver.calls) == ["n26", "n27", "n28"])
        for url in resolver.waitingURLs { resolver.answer(url, .success(Self.page)) }
        for _ in 0..<6 {
            for url in resolver.waitingURLs { resolver.answer(url, .success(Self.page)) }
            await Self.settle()
        }
        #expect(Self.names(resolver.calls) == Set((26...32).map { "n\($0)" }), "\(resolver.calls)")
    }

    @Test("switching modes at runtime: to whileScrolling starts held keys at once; leaving nearby stops batches")
    func runtimeSwitch() async throws {
        let resolver = ScriptedSmartLinkResolver()
        let (coordinator, document) = await Self.coordinator(resolver, mode: .afterScrolling, blocks: Self.paragraphs(30))
        defer { withExtendedLifetime(document) {} }
        coordinator.scrollPhaseChanged(scrolling: true, offset: 0)
        Self.show(coordinator, "p10", [Self.key("n10")])
        await Self.settle()
        #expect(resolver.calls.isEmpty)
        coordinator.resolution = .whileScrolling
        // Stored at once, applied a turn later.
        #expect(coordinator.stats.resolution == .whileScrolling)
        try await smartLinkEventually("started mid-scroll") { resolver.waitingURLs == [Self.key("n10").url] }
        coordinator.scrollPhaseChanged(scrolling: false, offset: 100)

        coordinator.resolution = .afterScrollingWithNearby
        try await smartLinkEventually("a batch") { coordinator.stats.prefetchInFlight == 3 }
        coordinator.resolution = .afterScrolling
        try await smartLinkEventually("the batch stopped") { coordinator.stats.prefetchCancellations == 3 }
        await Self.settle()
        #expect(coordinator.stats.prefetchBatches == 1)
        // Setting the same mode again does nothing.
        coordinator.resolution = .afterScrolling
        await Self.settle()
        #expect(coordinator.stats.prefetchBatches == 1)
    }

    @Test("a reload drops prefetched results and stops batches; no resolver means no work at all")
    func resetAndNoResolver() async throws {
        let resolver = ScriptedSmartLinkResolver(answerEverything: { _ in .success(Self.page) })
        let (coordinator, document) = await Self.coordinator(
            resolver, mode: .afterScrollingWithNearby, blocks: Self.paragraphs(10)
        )
        defer { withExtendedLifetime(document) {} }
        Self.show(coordinator, "p0", [Self.key("n0")])
        try await smartLinkEventually("prefetched") { coordinator.prefetchedStage(for: Self.key("n4")) == .resolved(Self.page) }
        try await smartLinkEventually("settled") { coordinator.stats.inFlight == 0 && coordinator.stats.prefetchCalls == 9 }
        coordinator.reset()
        #expect(coordinator.prefetchedStage(for: Self.key("n4")) == nil)
        #expect(coordinator.displayStages(for: [Self.key("n4")], owner: nil).isEmpty)

        let idle = SmartLinkCoordinator(hasVisibilityFeed: true)
        idle.document = StubSmartLinkDocument(Self.paragraphs(10))
        idle.resolution = .afterScrollingWithNearby
        idle.scrollPhaseChanged(scrolling: true, offset: 0)
        idle.attach(leaf: "p0", keys: [Self.key("n0")])
        idle.setLeafVisible("p0", true)
        idle.scrollPhaseChanged(scrolling: false, offset: 10)
        await Self.settle()
        let stats = idle.stats
        #expect(stats.scrollEnds == 0 && !stats.isScrolling && stats.prefetchBatches == 0 && stats.resolverCalls == 0, "\(stats)")
        #expect(idle.demandCounts.isEmpty && idle.pendingKeys.isEmpty)
    }

    // MARK: Positions

    @Test("positions: a top-level row is one, each top-level list row is one, nested content shares its row's")
    func neighbourhoodPositions() {
        let k = (0..<12).map { Self.key("k\($0)") }
        func row(_ id: String, _ keys: [SmartLinkKey], trailing: [RenderBlock] = []) -> PreparedListRow {
            PreparedListRow(id: id, depth: 0, marker: .bullet(depth: 0), segments: [], trailingBlocks: trailing, smartLinkKeys: keys)
        }
        let cell = PreparedTableCell(id: "c", colspan: 1, rowspan: 1, backgroundHex: nil, valign: nil, isHeader: false,
                                     blocks: [Self.paragraph("cell-p", [k[6]])])
        let media = PreparedMedia(
            id: "m", attrs: MediaAttrs(source: .external(url: "https://example.com/a.png"), width: nil, height: nil, alt: nil, mediaType: nil),
            layout: .center, widthFraction: nil, pixelWidth: nil, caption: nil, borderHex: nil, linkHref: nil,
            captionSmartLinkKeys: [k[8]]
        )
        let blocks = [
            Self.paragraph("p0", [k[0]]),                                                    // position 0
            RenderBlock(id: "list", kind: .listRows([                                        // positions 1, 2, 3
                row("li1", [k[1]]),
                row("li2", []),
                row("li3", [k[2]], trailing: [RenderBlock(id: "nested", kind: .listRows([row("li3a", [k[3]])]))]),
            ])),
            RenderBlock(id: "panel", kind: .panel(PanelPalette(background: .blue, accent: .blue, iconSystemName: "info.circle"), [Self.paragraph("panel-p", [k[4]]),  // position 4
                                                          Self.paragraph("panel-q", [k[5]])])),
            RenderBlock(id: "table#rows0", kind: .tableSlice(                                // position 5
                PreparedTableLayout(columnWidths: nil, columnCount: 1, hasNumberColumn: false),
                rows: [PreparedTableRow(id: "r", cells: [cell])], isHeaderSlice: false)),
            RenderBlock(id: "expand", kind: .expand(title: "More", body: [], isNested: false)),  // position 6
            RenderBlock(id: "media", kind: .media(media)),                                   // position 7
            Self.paragraph("p-last", [k[9]]),                                                // position 8
        ]
        let index = SmartLinkNeighbourhood(blocks)
        #expect(index.rowCount == 7 && index.positionCount == 9)
        let positions = ["p0": 0, "li1": 1, "li3": 3, "li3a": 3, "panel-p": 4, "panel-q": 4, "cell-p": 5, "m": 7, "p-last": 8]
        for (owner, position) in positions {
            #expect(index.position(ofOwner: owner) == position, "\(owner)")
        }
        #expect(index.position(ofOwner: "li2") == nil, "an owner without smart links is not indexed")
        #expect((0..<7).map { index.position(ofRow: $0) } == [0, 1, 4, 5, 6, 7, 8])
        #expect(index.owners(from: 3, through: 5).map(\.id) == ["li3", "li3a", "panel-p", "panel-q", "cell-p"])
        #expect(index.owners(from: 9, through: 20).isEmpty)
    }
}
