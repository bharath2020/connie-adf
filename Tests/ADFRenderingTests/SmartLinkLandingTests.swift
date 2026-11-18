import Foundation
import Observation
import Testing
import ADFPreparation
@_spi(ADFDiagnostics) @testable import ADFRendering

/// Watches one entry's stage the way a leaf reading it in its body does:
/// every change it registers is one invalidation of every leaf showing the
/// URL. `seen` lists the stage after each, read when the watcher's task
/// runs: two changes before that (in one main-actor turn, or while the
/// test's own poll resumes first) record as one, the last stage, so a test
/// settles between changes it counts.
@MainActor
final class StageWatcher {
    let entry: SmartLinkEntry
    private(set) var seen: [SmartLinkStage] = []
    var changes: Int { seen.count }

    init(_ entry: SmartLinkEntry) {
        self.entry = entry
        track()
    }

    private func track() {
        withObservationTracking {
            _ = entry.stage
        } onChange: { [weak self] in
            Task { @MainActor in self?.changed() }
        }
    }

    private func changed() {
        seen.append(entry.stage)
        track()
    }
}

/// Design §10: a title that lands while the document scrolls waits until
/// every leaf showing its link is fully on screen, or scrolling stops (P1,
/// no layout shift across the screen's edge); and a lookup shows the
/// loading look only after it has run 300 ms (P2, no redraws for links
/// passed in a fling). Driven by hand: injected phase and visibility
/// (`setLeafVisible` is the leaf's 0.01 feed, `setLeafFullyVisible` its
/// 0.99999 feed), a scripted resolver and a manual sleeper for the delay.
@Suite("Smart link landing and loading look", .serialized)
@MainActor
struct SmartLinkLandingTests {
    nonisolated static func key(_ name: String) -> SmartLinkKey {
        SmartLinkKey("https://acme.atlassian.net/wiki/\(name)")!
    }

    nonisolated static let page = ADFSmartLinkMetadata(title: "Title", icon: .page)

    /// No dwell; the loading look at once unless a delay is given (its
    /// sleeps go to `sleeper`, the only sleeps then: no dwell, no pause).
    static func coordinator(
        _ resolver: any ADFSmartLinkResolver, mode: ADFSmartLinkResolution = .whileScrolling,
        resolvingDelay: Duration = .zero, sleeper: ManualSleeper? = nil, feed: Bool = true, blocks: [RenderBlock] = []
    ) async -> (SmartLinkCoordinator, StubSmartLinkDocument) {
        var timing = SmartLinkTiming(dwell: .zero, resolvingDelay: resolvingDelay)
        timing.prefetchPause = .zero
        if let sleeper { timing.sleep = { try await sleeper.sleep($0) } }
        let coordinator = SmartLinkCoordinator(timing: timing, hasVisibilityFeed: feed)
        coordinator.resolver = resolver
        let document = StubSmartLinkDocument(blocks)
        coordinator.document = document
        coordinator.resolution = mode
        await settle()
        return (coordinator, document)
    }

    /// A leaf on screen, all of it.
    static func show(_ coordinator: SmartLinkCoordinator, _ leaf: String, _ keys: [SmartLinkKey]) {
        coordinator.attach(leaf: leaf, keys: keys)
        coordinator.setLeafVisible(leaf, true)
        coordinator.setLeafFullyVisible(leaf, true)
    }

    /// A leaf on screen, but not all of it: straddling an edge, or taller
    /// than the screen.
    static func straddle(_ coordinator: SmartLinkCoordinator, _ leaf: String, _ keys: [SmartLinkKey]) {
        coordinator.attach(leaf: leaf, keys: keys)
        coordinator.setLeafVisible(leaf, true)
        coordinator.setLeafFullyVisible(leaf, false)
    }

    static func settle() async {
        for _ in 0..<40 { await Task.yield() }
    }

    // MARK: P1 — hold a landing title until its leaf is fully on screen or scrolling stops

    @Test("a title landing mid-scroll on a leaf straddling the edge is held, unobserved, until the leaf is fully on screen")
    func heldUntilFullyOnScreen() async throws {
        let resolver = ScriptedSmartLinkResolver()
        let (coordinator, document) = await Self.coordinator(resolver)
        defer { withExtendedLifetime(document) {} }
        let a = Self.key("a")
        coordinator.scrollPhaseChanged(scrolling: true, offset: 0)
        Self.straddle(coordinator, "p1", [a])
        try await smartLinkEventually("the call") { resolver.waitingURLs == [a.url] }
        #expect(coordinator.stage(for: a) == .resolving)
        #expect(coordinator.displayStages(for: [a], owner: "p1") == [a: .resolving])
        let watcher = StageWatcher(coordinator.entry(for: a))
        let refreshes = coordinator.stats.leafRefreshes

        resolver.answer(a.url, .success(Self.page))
        try await smartLinkEventually("the title held") { coordinator.heldStage(for: a) == .resolved(Self.page) }
        await Self.settle()
        #expect(coordinator.stage(for: a) == .resolving, "a title landed on a leaf straddling the edge mid-scroll")
        #expect(watcher.changes == 0, "the held title invalidated the leaf: \(watcher.seen)")
        #expect(coordinator.heldKeys == [a])
        #expect(coordinator.displayStages(for: [a], owner: "p1") == [a: .resolving])
        var stats = coordinator.stats
        #expect(stats.titlesHeld == 1 && stats.titlesHeldNow == 1 && stats.resolved == 1 && stats.inFlight == 0, "\(stats)")
        #expect(stats.leafRefreshes == refreshes)

        // Still scrolling, the leaf comes fully on screen: the title shows.
        coordinator.setLeafFullyVisible("p1", true)
        #expect(coordinator.stage(for: a) == .resolved(Self.page))
        #expect(coordinator.heldKeys.isEmpty && coordinator.heldStage(for: a) == nil)
        await Self.settle()
        #expect(watcher.seen == [.resolved(Self.page)])
        #expect(coordinator.displayStages(for: [a], owner: "p1") == [a: .resolved(Self.page)])
        stats = coordinator.stats
        #expect(stats.isScrolling && stats.titlesHeldNow == 0 && stats.titlesHeld == 1, "\(stats)")
        #expect(resolver.calls == [a.url])
    }

    @Test("in every mode a title that lands mid-scroll on a leaf never fully on screen is shown when scrolling stops; a mode change does not release it",
          arguments: ADFSmartLinkResolution.allCases)
    func heldUntilScrollingStops(mode: ADFSmartLinkResolution) async throws {
        let resolver = ScriptedSmartLinkResolver()
        let (coordinator, document) = await Self.coordinator(resolver, mode: mode)
        defer { withExtendedLifetime(document) {} }
        let a = Self.key("tall")
        // A leaf taller than the screen, looked up at rest; scrolling
        // resumes before its title lands.
        Self.straddle(coordinator, "tall", [a])
        try await smartLinkEventually("the call") { resolver.waitingURLs == [a.url] }
        coordinator.scrollPhaseChanged(scrolling: true, offset: 0)
        resolver.answer(a.url, .success(Self.page))
        try await smartLinkEventually("held") { coordinator.heldKeys == [a] }
        #expect(coordinator.stage(for: a) == .resolving, "\(mode): the title landed mid-scroll")

        // Switching modes mid-scroll applies the mode, not the title.
        coordinator.resolution = mode == .whileScrolling ? .afterScrolling : .whileScrolling
        await Self.settle()
        #expect(coordinator.stage(for: a) == .resolving, "\(mode): a mode change released the held title")
        #expect(coordinator.stats.titlesHeld == 1, "\(coordinator.stats)")
        coordinator.resolution = mode
        await Self.settle()

        coordinator.scrollPhaseChanged(scrolling: false, offset: 600)
        #expect(coordinator.stage(for: a) == .resolved(Self.page), "\(mode): not shown at rest")
        let stats = coordinator.stats
        #expect(stats.titlesHeld == 1 && stats.titlesHeldNow == 0 && stats.scrollEnds == 1, "\(stats)")
        #expect(resolver.calls == [a.url])
    }

    @Test("a held title whose leaf leaves is kept: no loading look stays, a leaf built later draws the title, and wanted again it shows without a lookup")
    func heldTitleOutlivesItsLeaf() async throws {
        let resolver = ScriptedSmartLinkResolver()
        let (coordinator, document) = await Self.coordinator(resolver)
        defer { withExtendedLifetime(document) {} }
        let a = Self.key("a")
        coordinator.scrollPhaseChanged(scrolling: true, offset: 0)
        Self.straddle(coordinator, "p1", [a])
        try await smartLinkEventually("the call") { resolver.waitingURLs == [a.url] }
        _ = coordinator.displayStages(for: [a], owner: "p1")
        resolver.answer(a.url, .success(Self.page))
        try await smartLinkEventually("held") { coordinator.heldKeys == [a] }

        // It scrolls off the top, still built (attached, not visible).
        coordinator.setLeafVisible("p1", false)
        #expect(coordinator.stage(for: a) == .plain, "the loading look stayed after the leaf left")
        #expect(coordinator.heldStage(for: a) == .resolved(Self.page), "the held title was lost")
        #expect(coordinator.heldKeys.isEmpty && coordinator.stats.titlesHeldNow == 0)
        // The leaf that drew the loading look, still built off screen,
        // redraws as the prepared text: same height, nothing moves.
        #expect(coordinator.displayStages(for: [a], owner: "p1").isEmpty)
        // A leaf built now draws the title on its first frame, never the
        // loading look.
        #expect(coordinator.displayStages(for: [a], owner: "p2") == [a: .resolved(Self.page)])
        // The first leaf leaves the render region; built again, it is a new
        // leaf and draws the title too.
        coordinator.detach(leaf: "p1")
        #expect(coordinator.displayStages(for: [a], owner: "p1") == [a: .resolved(Self.page)])

        // Wanted again mid-scroll by a leaf not fully on screen yet: held,
        // and the leaf keeps the title it drew first.
        Self.straddle(coordinator, "p2", [a])
        #expect(coordinator.stage(for: a) == .plain && coordinator.heldKeys == [a])
        #expect(coordinator.displayStages(for: [a], owner: "p2") == [a: .resolved(Self.page)])
        #expect(coordinator.stats.titlesHeld == 2, "\(coordinator.stats)")
        coordinator.setLeafFullyVisible("p2", true)
        #expect(coordinator.stage(for: a) == .resolved(Self.page))
        await Self.settle()
        #expect(resolver.calls == [a.url], "a held title was looked up again")
        #expect(coordinator.stats.prefetchHits == 0, "a held title counted as a nearby hit")

        // At rest, a held title is shown at once when wanted again.
        let b = Self.key("b")
        Self.straddle(coordinator, "q1", [b])
        try await smartLinkEventually("b's call") { resolver.waitingURLs == [b.url] }
        resolver.answer(b.url, .success(Self.page))
        try await smartLinkEventually("b held") { coordinator.heldKeys == [b] }
        coordinator.detach(leaf: "q1")
        coordinator.scrollPhaseChanged(scrolling: false, offset: 100)
        #expect(coordinator.stage(for: b) == .plain, "a title was published for a link no longer on screen")
        Self.straddle(coordinator, "q1", [b])
        #expect(coordinator.stage(for: b) == .resolved(Self.page))
    }

    @Test("a nearby title coming on screen mid-scroll waits for its leaf to be fully on screen; a leaf that already drew it keeps it")
    func nearbyTitleGatedMidScroll() async throws {
        let resolver = ScriptedSmartLinkResolver(answerEverything: { _ in .success(Self.page) })
        let (coordinator, document) = await Self.coordinator(
            resolver, mode: .afterScrollingWithNearby, blocks: SmartLinkResolutionTests.paragraphs(20)
        )
        defer { withExtendedLifetime(document) {} }
        let n9 = Self.key("n9"), n10 = Self.key("n10")
        Self.show(coordinator, "p5", [Self.key("n5")])
        try await smartLinkEventually("prefetched all within reach") { coordinator.stats.prefetchCalls == 17 }
        try await smartLinkEventually("landed") { coordinator.stats.inFlight == 0 }
        let calls = resolver.calls.count
        // Row 9 was built before its title landed (drew the URL); row 10
        // is built now and draws the title on its first frame.
        #expect(coordinator.displayStages(for: [n10], owner: "p10") == [n10: .resolved(Self.page)])
        let watcher = StageWatcher(coordinator.entry(for: n9))

        coordinator.scrollPhaseChanged(scrolling: true, offset: 0)
        Self.straddle(coordinator, "p9", [n9])
        Self.straddle(coordinator, "p10", [n10])
        #expect(coordinator.stage(for: n9) == .plain, "a nearby title landed on a leaf straddling the edge mid-scroll")
        #expect(coordinator.heldKeys == [n9, n10])
        #expect(coordinator.displayStages(for: [n10], owner: "p10") == [n10: .resolved(Self.page)],
                "a leaf that drew the title on its first frame stopped drawing it")
        var stats = coordinator.stats
        #expect(stats.prefetchHits == 0 && stats.titlesHeld == 2 && stats.titlesHeldNow == 2, "\(stats)")

        coordinator.setLeafFullyVisible("p9", true)
        #expect(coordinator.stage(for: n9) == .resolved(Self.page))
        await Self.settle()
        #expect(watcher.seen == [.resolved(Self.page)])
        coordinator.scrollPhaseChanged(scrolling: false, offset: 300)
        #expect(coordinator.stage(for: n10) == .resolved(Self.page))
        stats = coordinator.stats
        #expect(stats.prefetchHits == 2 && stats.titlesHeldNow == 0, "\(stats)")
        await Self.settle()
        #expect(resolver.calls.count >= calls)
        #expect(!resolver.calls.dropFirst(calls).contains(n9.url) && !resolver.calls.dropFirst(calls).contains(n10.url),
                "a nearby title was looked up again")
    }

    @Test("nothing is held at rest, without a visibility feed, or for a failure")
    func notHeld() async throws {
        let resolver = ScriptedSmartLinkResolver()
        // At rest: a leaf taller than the screen shows its title at once.
        let (rest, restDocument) = await Self.coordinator(resolver)
        defer { withExtendedLifetime(restDocument) {} }
        let a = Self.key("rest")
        Self.straddle(rest, "tall", [a])
        try await smartLinkEventually("a's call") { resolver.waitingURLs.contains(a.url) }
        resolver.answer(a.url, .success(Self.page))
        try await smartLinkEventually("shown at rest") { rest.stage(for: a) == .resolved(Self.page) }
        #expect(rest.stats.titlesHeld == 0)

        // No feed (iOS 17 / macOS 14): nothing is held, even mid-scroll.
        let (noFeed, noFeedDocument) = await Self.coordinator(resolver, feed: false)
        defer { withExtendedLifetime(noFeedDocument) {} }
        let b = Self.key("nofeed")
        noFeed.scrollPhaseChanged(scrolling: true, offset: 0)
        noFeed.attach(leaf: "p", keys: [b])
        noFeed.setLeafFullyVisible("p", false)
        try await smartLinkEventually("b's call") { resolver.waitingURLs.contains(b.url) }
        resolver.answer(b.url, .success(Self.page))
        try await smartLinkEventually("shown without a feed") { noFeed.stage(for: b) == .resolved(Self.page) }
        #expect(noFeed.stats.titlesHeld == 0 && noFeed.knownFullVisibility(of: "p") == nil)

        // A failure draws as the prepared text: published at once, ending
        // the loading look, mid-scroll on a straddling leaf too.
        let (failing, failingDocument) = await Self.coordinator(resolver)
        defer { withExtendedLifetime(failingDocument) {} }
        let c = Self.key("fails")
        failing.scrollPhaseChanged(scrolling: true, offset: 0)
        Self.straddle(failing, "p", [c])
        try await smartLinkEventually("c's call") { resolver.waitingURLs.contains(c.url) }
        #expect(failing.stage(for: c) == .resolving)
        resolver.answer(c.url, .failure(ADFSmartLinkError.notFound))
        try await smartLinkEventually("failed at once") { failing.stage(for: c) == .failed(.notFound) }
        #expect(failing.stats.titlesHeld == 0 && failing.heldKeys.isEmpty)
    }

    @Test("every attached leaf holding the link must be fully on screen: one built off screen holds the title back until it goes")
    func everyAttachedLeafCounts() async throws {
        let resolver = ScriptedSmartLinkResolver()
        let (coordinator, document) = await Self.coordinator(resolver)
        defer { withExtendedLifetime(document) {} }
        let a = Self.key("a")
        coordinator.scrollPhaseChanged(scrolling: true, offset: 0)
        Self.show(coordinator, "on-screen", [a])
        // The same URL in a row the lazy stack built below the screen.
        coordinator.attach(leaf: "below", keys: [a])
        try await smartLinkEventually("the call") { resolver.waitingURLs == [a.url] }
        resolver.answer(a.url, .success(Self.page))
        try await smartLinkEventually("held") { coordinator.heldKeys == [a] }
        // A report for the on-screen leaf again changes nothing.
        coordinator.setLeafFullyVisible("on-screen", false)
        coordinator.setLeafFullyVisible("on-screen", true)
        #expect(coordinator.stage(for: a) == .resolving)
        // The built row leaves the render region: nothing holds it back.
        coordinator.detach(leaf: "below")
        #expect(coordinator.stage(for: a) == .resolved(Self.page))
    }

    @Test("a leaf whose keys change no longer holds the dropped link's title back")
    func keysChangeReleases() async throws {
        let resolver = ScriptedSmartLinkResolver()
        let (coordinator, document) = await Self.coordinator(resolver)
        defer { withExtendedLifetime(document) {} }
        let a = Self.key("a"), b = Self.key("b")
        coordinator.scrollPhaseChanged(scrolling: true, offset: 0)
        Self.show(coordinator, "full", [a])
        Self.straddle(coordinator, "edge", [a])
        try await smartLinkEventually("the call") { resolver.waitingURLs == [a.url] }
        resolver.answer(a.url, .success(Self.page))
        try await smartLinkEventually("held") { coordinator.heldKeys == [a] }
        coordinator.update(leaf: "edge", keys: [b])
        #expect(coordinator.stage(for: a) == .resolved(Self.page))
        #expect(coordinator.demandCounts[a] == 1 && coordinator.demandCounts[b] == 1)
    }

    @Test("a leaf that already drew a held link keeps drawing it when another link in it redraws")
    func leafKeepsWhatItDrewWhileHeld() async throws {
        let resolver = ScriptedSmartLinkResolver()
        let sleeper = ManualSleeper()
        let (coordinator, document) = await Self.coordinator(resolver, resolvingDelay: .milliseconds(300), sleeper: sleeper)
        defer { withExtendedLifetime(document) {} }
        let a = Self.key("a"), b = Self.key("b")
        coordinator.scrollPhaseChanged(scrolling: true, offset: 0)
        Self.straddle(coordinator, "p1", [a, b])
        try await smartLinkEventually("both calls") { resolver.waitingURLs == [a.url, b.url] }
        try await smartLinkEventually("two pending loading looks") { sleeper.count == 2 }
        #expect(coordinator.displayStages(for: [a, b], owner: "p1").isEmpty)
        // a lands fast (no loading look) and is held; b is slow.
        resolver.answer(a.url, .success(Self.page))
        try await smartLinkEventually("a held") { coordinator.heldKeys == [a] }
        try await smartLinkEventually("a's loading look dropped") { sleeper.count == 1 }
        #expect(coordinator.stage(for: a) == .plain)
        // b's loading look redraws the leaf: a still draws as prepared.
        sleeper.wakeAll()
        try await smartLinkEventually("b loading") { coordinator.stage(for: b) == .resolving }
        #expect(coordinator.displayStages(for: [a, b], owner: "p1") == [b: .resolving],
                "another link's redraw showed a held title mid-scroll")
        coordinator.setLeafFullyVisible("p1", true)
        #expect(coordinator.displayStages(for: [a, b], owner: "p1") == [a: .resolved(Self.page), b: .resolving])
    }

    @Test("a reload drops held titles and starts the link over")
    func resetDropsHeldTitles() async throws {
        let resolver = ScriptedSmartLinkResolver()
        let (coordinator, document) = await Self.coordinator(resolver)
        defer { withExtendedLifetime(document) {} }
        let a = Self.key("a")
        coordinator.scrollPhaseChanged(scrolling: true, offset: 0)
        Self.straddle(coordinator, "p1", [a])
        try await smartLinkEventually("the call") { resolver.waitingURLs == [a.url] }
        resolver.answer(a.url, .success(Self.page))
        try await smartLinkEventually("held") { coordinator.heldKeys == [a] }
        _ = coordinator.displayStages(for: [a], owner: "p1")
        let watcher = StageWatcher(coordinator.entry(for: a))
        coordinator.reset()
        #expect(coordinator.heldStage(for: a) == nil && coordinator.stage(for: a) != .resolved(Self.page))
        #expect(coordinator.heldKeys.isEmpty)
        // The still-visible leaf is asked about again in the new document.
        try await smartLinkEventually("asked again") { resolver.calls.count == 2 }
        coordinator.scrollPhaseChanged(scrolling: false, offset: 10)
        #expect(coordinator.stage(for: a) == .resolving, "the old document's title was shown")
        await Self.settle()
        #expect(watcher.changes >= 1, "the reload did not redraw the leaf")
        resolver.answer(a.url, .success(ADFSmartLinkMetadata(title: "New", icon: .issue)))
        try await smartLinkEventually("the new title") { coordinator.stage(for: a) == .resolved(ADFSmartLinkMetadata(title: "New", icon: .issue)) }
    }

    // MARK: P2 — the loading look only after 300 ms

    @Test("a link passed before its lookup has run 300 ms never shows the loading look: no redraw at all")
    func cancelledBeforeTheDelayCostsNothing() async throws {
        #expect(SmartLinkTiming().resolvingDelay == .milliseconds(300))
        let resolver = ScriptedSmartLinkResolver()
        let sleeper = ManualSleeper()
        let (coordinator, document) = await Self.coordinator(resolver, resolvingDelay: .milliseconds(300), sleeper: sleeper)
        defer { withExtendedLifetime(document) {} }
        let a = Self.key("a")
        let watcher = StageWatcher(coordinator.entry(for: a))
        Self.show(coordinator, "p1", [a])
        _ = coordinator.displayStages(for: [a], owner: "p1")
        try await smartLinkEventually("the call") { resolver.waitingURLs == [a.url] }
        try await smartLinkEventually("the pending loading look") { sleeper.count == 1 }
        #expect(sleeper.requested == [.milliseconds(300)])
        #expect(coordinator.stage(for: a) == .plain)
        #expect(coordinator.pendingDimKeys == [a])

        // The fling passes it.
        coordinator.setLeafVisible("p1", false)
        #expect(coordinator.pendingDimKeys.isEmpty)
        try await smartLinkEventually("the loading look cancelled") { sleeper.count == 0 }
        try await smartLinkEventually("the call ended") { coordinator.stats.cancellations == 1 }
        await Self.settle()
        #expect(watcher.changes == 0, "a link passed in a fling redrew: \(watcher.seen)")
        #expect(coordinator.displayStages(for: [a], owner: "p1").isEmpty)
        let stats = coordinator.stats
        #expect(stats.resolvingShown == 0 && stats.leafRefreshes == 0 && stats.inFlight == 0, "\(stats)")
    }

    @Test("a lookup that lands within 300 ms goes from plain to its title in one redraw")
    func fastLookupGoesStraightToItsTitle() async throws {
        let resolver = ScriptedSmartLinkResolver()
        let sleeper = ManualSleeper()
        let (coordinator, document) = await Self.coordinator(resolver, resolvingDelay: .milliseconds(300), sleeper: sleeper)
        defer { withExtendedLifetime(document) {} }
        let a = Self.key("a")
        let watcher = StageWatcher(coordinator.entry(for: a))
        Self.show(coordinator, "p1", [a])
        try await smartLinkEventually("the pending loading look") { sleeper.count == 1 && resolver.waitingURLs == [a.url] }
        resolver.answer(a.url, .success(Self.page))
        try await smartLinkEventually("resolved") { coordinator.stage(for: a) == .resolved(Self.page) }
        try await smartLinkEventually("the loading look cancelled") { sleeper.count == 0 }
        sleeper.wakeAll()
        await Self.settle()
        #expect(watcher.seen == [.resolved(Self.page)])
        #expect(coordinator.stats.resolvingShown == 0)
    }

    @Test("a lookup still running after 300 ms shows the loading look; cancelled then, it returns to plain")
    func slowLookupShowsTheLoadingLook() async throws {
        let resolver = ScriptedSmartLinkResolver()
        let sleeper = ManualSleeper()
        let (coordinator, document) = await Self.coordinator(resolver, resolvingDelay: .milliseconds(300), sleeper: sleeper)
        defer { withExtendedLifetime(document) {} }
        let a = Self.key("a")
        let watcher = StageWatcher(coordinator.entry(for: a))
        Self.show(coordinator, "p1", [a])
        try await smartLinkEventually("the pending loading look") { sleeper.count == 1 && resolver.waitingURLs == [a.url] }
        sleeper.wakeAll()
        try await smartLinkEventually("loading") { coordinator.stage(for: a) == .resolving }
        #expect(coordinator.pendingDimKeys.isEmpty)
        #expect(coordinator.stats.resolvingShown == 1)
        await Self.settle()
        #expect(watcher.seen == [.resolving])
        coordinator.setLeafVisible("p1", false)
        #expect(coordinator.stage(for: a) == .plain)
        await Self.settle()
        #expect(watcher.seen == [.resolving, .plain])
    }

    @Test("a loading look due after a held landing never replaces the held title")
    func lateLoadingLookNeverOverwritesAHeldTitle() async throws {
        let resolver = ScriptedSmartLinkResolver()
        let sleeper = ManualSleeper()
        let (coordinator, document) = await Self.coordinator(resolver, resolvingDelay: .milliseconds(300), sleeper: sleeper)
        defer { withExtendedLifetime(document) {} }
        let a = Self.key("a")
        coordinator.scrollPhaseChanged(scrolling: true, offset: 0)
        Self.straddle(coordinator, "p1", [a])
        try await smartLinkEventually("the pending loading look") { sleeper.count == 1 && resolver.waitingURLs == [a.url] }
        // The delay ends and the title lands in the same turn.
        sleeper.wakeAll()
        resolver.answer(a.url, .success(Self.page))
        try await smartLinkEventually("held") { coordinator.heldKeys == [a] }
        await Self.settle()
        #expect(coordinator.heldStage(for: a) == .resolved(Self.page), "the loading look replaced the held title")
        #expect(coordinator.stage(for: a) != .resolved(Self.page))
        coordinator.setLeafFullyVisible("p1", true)
        await Self.settle()
        #expect(coordinator.stage(for: a) == .resolved(Self.page))
        #expect(coordinator.pendingDimKeys.isEmpty)
    }

    @Test("a reload or a released coordinator stops a pending loading look")
    func resetAndDeinitStopTheDelay() async throws {
        let resolver = ScriptedSmartLinkResolver()
        let sleeper = ManualSleeper()
        let (coordinator, document) = await Self.coordinator(resolver, resolvingDelay: .milliseconds(300), sleeper: sleeper)
        defer { withExtendedLifetime(document) {} }
        let a = Self.key("a")
        let watcher = StageWatcher(coordinator.entry(for: a))
        Self.show(coordinator, "p1", [a])
        try await smartLinkEventually("the pending loading look") { sleeper.count == 1 && resolver.waitingURLs == [a.url] }
        coordinator.reset()
        #expect(sleeper.count == 0, "the reload left the old call's loading look pending")
        // The visible leaf is asked about again, with a new delay.
        try await smartLinkEventually("asked again") { resolver.calls.count == 2 && sleeper.count == 1 }
        resolver.answer(a.url, .success(Self.page))
        try await smartLinkEventually("resolved") { coordinator.stage(for: a) == .resolved(Self.page) }
        await Self.settle()
        #expect(watcher.seen == [.resolved(Self.page)], "a loading look from before the reload showed")

        var released: SmartLinkCoordinator? = await Self.coordinator(resolver, resolvingDelay: .milliseconds(300), sleeper: sleeper).0
        Self.show(released!, "p1", [Self.key("b")])
        try await smartLinkEventually("b's pending loading look") { sleeper.count == 1 }
        weak var gone = released
        released = nil
        #expect(gone == nil)
        try await smartLinkEventually("the loading look cancelled with the coordinator") { sleeper.count == 0 }
    }

    @Test("a nearby call that comes on screen shows the loading look only after the delay")
    func promotedNearbyCallWaitsForTheDelay() async throws {
        let resolver = ScriptedSmartLinkResolver()
        let sleeper = ManualSleeper()
        let (coordinator, document) = await Self.coordinator(
            resolver, mode: .afterScrollingWithNearby, resolvingDelay: .milliseconds(300), sleeper: sleeper,
            blocks: SmartLinkResolutionTests.paragraphs(10)
        )
        defer { withExtendedLifetime(document) {} }
        let n0 = Self.key("n0"), n1 = Self.key("n1")
        Self.show(coordinator, "p0", [n0])
        try await smartLinkEventually("batch 1") { coordinator.prefetchBatchKeys == [n1, Self.key("n2"), Self.key("n3")] }
        try await smartLinkEventually("n1's call") { resolver.waitingURLs.contains(n1.url) }
        // Only the visible call has a pending loading look.
        #expect(coordinator.pendingDimKeys == [n0])
        Self.show(coordinator, "p1", [n1])
        #expect(coordinator.stage(for: n1) == .plain, "a promoted call showed the loading look at once")
        #expect(coordinator.pendingDimKeys == [n0, n1])
        try await smartLinkEventually("two pending loading looks") { sleeper.count == 2 }
        sleeper.wakeAll()
        try await smartLinkEventually("both loading") {
            coordinator.stage(for: n0) == .resolving && coordinator.stage(for: n1) == .resolving
        }
        #expect(coordinator.stats.resolvingShown == 2)
    }
}
