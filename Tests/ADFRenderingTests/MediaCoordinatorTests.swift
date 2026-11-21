import Foundation
import SwiftUI
import Testing
import ADFModel
@_spi(ADFDiagnostics) @testable import ADFRendering

/// A media provider the test answers by hand: each call waits until
/// `answer` (or answers at once from `answerEverything`), and honours
/// cancellation the way the protocol asks. `ignoresCancellation` makes a
/// call keep waiting after it is cancelled (a provider slow to stop).
final class ScriptedMediaProvider: ADFMediaProvider, @unchecked Sendable {
    struct TestError: Error {}

    private let lock = NSLock()
    /// Calls waiting for an answer, by call id (two calls for one source,
    /// at two sizes, may wait at once).
    private var waiting: [UUID: (source: MediaAttrs.Source, continuation: CheckedContinuation<Image, any Error>)] = [:]
    private var _calls: [MediaAttrs.Source] = []
    private var _sizes: [CGSize] = []
    private var _cancelled: [MediaAttrs.Source] = []
    private let answerEverything: (@Sendable (MediaAttrs.Source) -> Result<Image, any Error>)?
    private let ignoresCancellation: Bool

    init(answerEverything: (@Sendable (MediaAttrs.Source) -> Result<Image, any Error>)? = nil,
         ignoresCancellation: Bool = false) {
        self.answerEverything = answerEverything
        self.ignoresCancellation = ignoresCancellation
    }

    var calls: [MediaAttrs.Source] { lock.withLock { _calls } }
    var sizes: [CGSize] { lock.withLock { _sizes } }
    var cancelled: [MediaAttrs.Source] { lock.withLock { _cancelled } }
    var waitingSources: Set<MediaAttrs.Source> { lock.withLock { Set(waiting.values.map(\.source)) } }

    func image(for attrs: MediaAttrs, targetSize: CGSize) async throws -> Image {
        let source = attrs.source
        lock.withLock {
            _calls.append(source)
            _sizes.append(targetSize)
        }
        if let result = answerEverything?(source) { return try result.get() }
        let ignores = ignoresCancellation
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelledAlready = lock.withLock { () -> Bool in
                    if Task.isCancelled, !ignores { return true }
                    waiting[id] = (source, continuation)
                    return false
                }
                if cancelledAlready { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let call = lock.withLock { () -> (source: MediaAttrs.Source, continuation: CheckedContinuation<Image, any Error>)? in
                _cancelled.append(source)
                return ignores ? nil : waiting.removeValue(forKey: id)
            }
            call?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Answers every call waiting for `source`.
    func answer(_ source: MediaAttrs.Source, _ result: Result<Image, any Error>) {
        let calls = lock.withLock { () -> [CheckedContinuation<Image, any Error>] in
            let ids = waiting.filter { $0.value.source == source }.map(\.key)
            return ids.compactMap { waiting.removeValue(forKey: $0)?.continuation }
        }
        calls.forEach { $0.resume(with: result) }
    }
}

/// The per-document media coordinator (ADR §24): demand from visible media
/// views (and their strips), dwell, the four-slot cap, dedup, cancellation,
/// eviction, failure and the generation reset — driven directly, as the
/// views drive it.
@Suite("Media coordinator", .serialized)
@MainActor
struct MediaCoordinatorTests {
    nonisolated static func source(_ name: String) -> MediaAttrs.Source {
        .external(url: "https://example.com/\(name).png")
    }

    nonisolated static func attrs(_ name: String) -> MediaAttrs {
        MediaAttrs(source: source(name), width: 400, height: 300, alt: nil, mediaType: "image")
    }

    nonisolated static func key(_ name: String, width: Int = 343, height: Int = 257) -> MediaLoadKey {
        MediaLoadKey(source: source(name), width: width, height: height)
    }

    nonisolated static let picture = Image(systemName: "photo")

    static func coordinator(
        _ provider: any ADFMediaProvider, dwell: Duration = .zero, maxConcurrent: Int = 4,
        releaseDelay: Duration = .zero, sleeper: ManualSleeper? = nil, feed: Bool = true
    ) -> MediaCoordinator {
        var timing = MediaTiming(dwell: dwell, maxConcurrent: maxConcurrent, releaseDelay: releaseDelay)
        if let sleeper { timing.sleep = { try await sleeper.sleep($0) } }
        let coordinator = MediaCoordinator(timing: timing, hasVisibilityFeed: feed)
        coordinator.provider = provider
        return coordinator
    }

    /// Attaches a viewer and reports it on screen.
    static func show(_ coordinator: MediaCoordinator, _ viewer: String, _ name: String, group: String? = nil) {
        coordinator.attach(viewer: viewer, key: key(name), attrs: attrs(name), group: group)
        coordinator.setViewerVisible(viewer, true)
    }

    static func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @Test("lazy: attached without visibility asks nothing; visible asks only after the dwell; hidden during the dwell never asks")
    func lazyLoading() async throws {
        let provider = ScriptedMediaProvider(answerEverything: { _ in .success(Self.picture) })
        let sleeper = ManualSleeper()
        let coordinator = Self.coordinator(provider, dwell: .milliseconds(150), sleeper: sleeper)
        #expect(MediaTiming().dwell == .milliseconds(150))
        #expect(MediaTiming().maxConcurrent == 4)
        #expect(MediaTiming().releaseDelay == .seconds(1))

        // A prefetched row: attached, never reported visible.
        coordinator.attach(viewer: "m0", key: Self.key("prefetched"), attrs: Self.attrs("prefetched"), group: nil)
        await Self.settle()
        #expect(sleeper.count == 0)
        #expect(provider.calls.isEmpty)
        #expect(coordinator.demandCounts.isEmpty)

        // Two on screen: both dwell, nothing asked yet.
        Self.show(coordinator, "m1", "flung")
        Self.show(coordinator, "m2", "settled")
        try await smartLinkEventually("two dwells") { sleeper.count == 2 }
        #expect(sleeper.requested == [.milliseconds(150), .milliseconds(150)])
        #expect(provider.calls.isEmpty)

        // A fling: the first leaves before its dwell ends.
        coordinator.setViewerVisible("m1", false)
        try await smartLinkEventually("the cancelled dwell") { sleeper.count == 1 }
        sleeper.wakeAll()
        try await smartLinkEventually("settled landed") { coordinator.entry(for: Self.key("settled")).image != nil }
        await Self.settle()
        #expect(provider.calls == [Self.source("settled")])
        #expect(provider.sizes == [CGSize(width: 343, height: 257)])
        #expect(coordinator.entry(for: Self.key("flung")).image == nil)
        #expect(coordinator.entry(for: Self.key("prefetched")).image == nil)
        #expect(coordinator.counters.started == 1)
        #expect(coordinator.counters.finished == 1)
    }

    @Test("dedup: two viewers of one key make one call and read one entry")
    func dedup() async throws {
        let provider = ScriptedMediaProvider()
        let coordinator = Self.coordinator(provider)
        Self.show(coordinator, "block", "a")
        Self.show(coordinator, "copy", "a")
        try await smartLinkEventually("the call") { provider.waitingSources == [Self.source("a")] }
        #expect(coordinator.demandCounts[Self.key("a")] == 2)
        provider.answer(Self.source("a"), .success(Self.picture))
        try await smartLinkEventually("landed") { coordinator.entry(for: Self.key("a")).image != nil }
        #expect(provider.calls == [Self.source("a")])
        #expect(coordinator.entry(for: Self.key("a")) === coordinator.entry(for: Self.key("a")))
        // The same source at another size is another load.
        coordinator.attach(viewer: "thumb", key: Self.key("a", width: 160, height: 120), attrs: Self.attrs("a"), group: nil)
        coordinator.setViewerVisible("thumb", true)
        try await smartLinkEventually("the thumbnail's call") { provider.calls.count == 2 }
        #expect(provider.sizes.last == CGSize(width: 160, height: 120))
    }

    @Test("four slots: six visible keys make four calls; the fifth starts when one ends")
    func fourSlots() async throws {
        let provider = ScriptedMediaProvider()
        let coordinator = Self.coordinator(provider)
        let names = ["k1", "k2", "k3", "k4", "k5", "k6"]
        for (index, name) in names.enumerated() { Self.show(coordinator, "m\(index)", name) }
        try await smartLinkEventually("four calls") { provider.waitingSources.count == 4 }
        await Self.settle()
        #expect(provider.calls.count == 4)
        #expect(coordinator.running == 4)
        #expect(coordinator.queuedKeys == [Self.key("k5"), Self.key("k6")])
        provider.answer(Self.source("k1"), .success(Self.picture))
        try await smartLinkEventually("the fifth call") { provider.calls.count == 5 }
        #expect(provider.calls.last == Self.source("k5"))
        #expect(coordinator.running == 4)
        #expect(coordinator.counters.maxRunning == 4)
    }

    @Test("cancel: hidden while running cancels the call, publishes nothing, and keeps the slot until the task ends")
    func cancelWhileRunning() async throws {
        let provider = ScriptedMediaProvider(ignoresCancellation: true)
        let coordinator = Self.coordinator(provider, maxConcurrent: 1)
        Self.show(coordinator, "m1", "a")
        Self.show(coordinator, "m2", "b")
        try await smartLinkEventually("the call") { provider.waitingSources == [Self.source("a")] }
        #expect(coordinator.queuedKeys == [Self.key("b")])
        coordinator.setViewerVisible("m1", false)
        try await smartLinkEventually("the provider saw the cancellation") { provider.cancelled == [Self.source("a")] }
        // The cancelled call still holds the only slot.
        await Self.settle()
        #expect(coordinator.running == 1)
        #expect(provider.calls == [Self.source("a")])
        // The provider ignores the cancellation and returns an image anyway:
        // it is dropped.
        provider.answer(Self.source("a"), .success(Self.picture))
        try await smartLinkEventually("b starts in the freed slot") { provider.calls == [Self.source("a"), Self.source("b")] }
        #expect(coordinator.entry(for: Self.key("a")).image == nil)
        #expect(coordinator.entry(for: Self.key("a")).failed == false)
        #expect(coordinator.counters.cancelled == 1)
        provider.answer(Self.source("b"), .success(Self.picture))
        try await smartLinkEventually("b landed") { coordinator.entry(for: Self.key("b")).image != nil }
        let counters = coordinator.counters
        #expect(counters.started == counters.finished + counters.failed + counters.cancelled + counters.running)
    }

    @Test("cancel: a cooperative provider throws CancellationError and the key retries when it comes back")
    func cancelThenRetry() async throws {
        let provider = ScriptedMediaProvider()
        let coordinator = Self.coordinator(provider)
        Self.show(coordinator, "m1", "a")
        try await smartLinkEventually("the call") { provider.waitingSources == [Self.source("a")] }
        coordinator.detach(viewer: "m1")
        try await smartLinkEventually("the cancelled call ended") { coordinator.running == 0 }
        #expect(provider.cancelled == [Self.source("a")])
        #expect(coordinator.entry(for: Self.key("a")).image == nil)
        #expect(coordinator.entry(for: Self.key("a")).failed == false)
        Self.show(coordinator, "m1", "a")
        try await smartLinkEventually("the retry") { provider.calls.count == 2 }
    }

    @Test("eviction: a hidden image is released only after the release delay; coming back sooner keeps it with no new call")
    func eviction() async throws {
        let provider = ScriptedMediaProvider(answerEverything: { _ in .success(Self.picture) })
        let sleeper = ManualSleeper()
        let coordinator = Self.coordinator(provider, releaseDelay: .seconds(1), sleeper: sleeper)
        let a = Self.key("a")
        Self.show(coordinator, "m1", "a")
        try await smartLinkEventually("landed") { coordinator.entry(for: a).image != nil }

        // Hidden, then back before the delay ends: kept, nothing asked.
        coordinator.setViewerVisible("m1", false)
        try await smartLinkEventually("the release delay") { sleeper.count == 1 }
        #expect(sleeper.requested == [.seconds(1)])
        #expect(coordinator.pendingReleaseKeys == [a])
        #expect(coordinator.entry(for: a).image != nil)
        coordinator.setViewerVisible("m1", true)
        try await smartLinkEventually("the release cancelled") { sleeper.count == 0 }
        #expect(coordinator.pendingReleaseKeys.isEmpty)
        #expect(coordinator.entry(for: a).image != nil)
        #expect(provider.calls.count == 1)

        // Hidden for the whole delay: released.
        coordinator.setViewerVisible("m1", false)
        try await smartLinkEventually("the release delay again") { sleeper.count == 1 }
        sleeper.wakeAll()
        try await smartLinkEventually("released") { coordinator.entry(for: a).image == nil }
        #expect(coordinator.counters.released == 1)
        // Coming back loads again (from the provider's cache, in the app).
        coordinator.setViewerVisible("m1", true)
        try await smartLinkEventually("reloaded") { coordinator.entry(for: a).image != nil }
        #expect(provider.calls.count == 2)
    }

    @Test("failure: a failed key reports failed and is never asked again, even after hide and show")
    func failure() async throws {
        let provider = ScriptedMediaProvider(answerEverything: { _ in .failure(ScriptedMediaProvider.TestError()) })
        let coordinator = Self.coordinator(provider)
        Self.show(coordinator, "m1", "broken")
        try await smartLinkEventually("failed") { coordinator.entry(for: Self.key("broken")).failed }
        #expect(coordinator.entry(for: Self.key("broken")).image == nil)
        coordinator.setViewerVisible("m1", false)
        coordinator.setViewerVisible("m1", true)
        coordinator.detach(viewer: "m1")
        Self.show(coordinator, "m2", "broken")
        await Self.settle()
        #expect(provider.calls.count == 1)
        #expect(coordinator.counters.failed == 1)
        #expect(coordinator.pendingKeys.isEmpty)
    }

    @Test("reset: a new generation drops late results, clears entries and restarts keys still in demand")
    func reset() async throws {
        let provider = ScriptedMediaProvider()
        let coordinator = Self.coordinator(provider)
        let a = Self.key("a"), b = Self.key("b")
        Self.show(coordinator, "m1", "a")
        Self.show(coordinator, "m2", "b")
        try await smartLinkEventually("two calls") { provider.waitingSources.count == 2 }
        provider.answer(Self.source("b"), .success(Self.picture))
        try await smartLinkEventually("b landed") { coordinator.entry(for: b).image != nil }

        let before = coordinator.generation
        coordinator.reset()
        #expect(coordinator.generation == before + 1)
        #expect(coordinator.entry(for: b).image == nil)
        // a's old call is stopping (cancelled); both keys are still on screen
        // and start over: b at once, a once its old call ends.
        try await smartLinkEventually("b restarted") { provider.calls.filter { $0 == Self.source("b") }.count == 2 }
        try await smartLinkEventually("a's old call cancelled") { provider.cancelled.contains(Self.source("a")) }
        try await smartLinkEventually("a restarted") { provider.calls.filter { $0 == Self.source("a") }.count == 2 }
        #expect(coordinator.entry(for: a).image == nil)
        provider.answer(Self.source("a"), .success(Self.picture))
        try await smartLinkEventually("a landed in the new generation") { coordinator.entry(for: a).image != nil }
        #expect(coordinator.counters.cancelled == 1)
    }

    @Test("reset: a failure from the old generation is dropped and the key is asked again")
    func resetClearsFailure() async throws {
        let provider = ScriptedMediaProvider(answerEverything: { _ in .failure(ScriptedMediaProvider.TestError()) })
        let coordinator = Self.coordinator(provider)
        Self.show(coordinator, "m1", "a")
        try await smartLinkEventually("failed") { coordinator.entry(for: Self.key("a")).failed }
        coordinator.reset()
        #expect(coordinator.entry(for: Self.key("a")).failed == false)
        try await smartLinkEventually("asked again") { provider.calls.count == 2 }
    }

    @Test("group: a thumbnail visible in its strip loads only while the strip is on screen")
    func groupVisibility() async throws {
        let provider = ScriptedMediaProvider(answerEverything: { _ in .success(Self.picture) })
        let coordinator = Self.coordinator(provider)
        coordinator.attachGroup("strip")
        Self.show(coordinator, "t1", "a", group: "strip")
        Self.show(coordinator, "t2", "b", group: "strip")
        // Off to the right inside the strip.
        coordinator.attach(viewer: "t3", key: Self.key("c"), attrs: Self.attrs("c"), group: "strip")
        coordinator.setViewerVisible("t3", false)
        await Self.settle()
        #expect(provider.calls.isEmpty)
        #expect(coordinator.demandCounts.isEmpty)

        coordinator.setGroupVisible("strip", true)
        try await smartLinkEventually("both visible thumbnails landed") {
            coordinator.entry(for: Self.key("a")).image != nil && coordinator.entry(for: Self.key("b")).image != nil
        }
        #expect(Set(provider.calls) == [Self.source("a"), Self.source("b")])
        #expect(coordinator.demandCounts == [Self.key("a"): 1, Self.key("b"): 1])

        // The strip scrolls off: its thumbnails lose demand.
        coordinator.setGroupVisible("strip", false)
        #expect(coordinator.demandCounts.isEmpty)
        // The strip view goes: its visibility is forgotten.
        coordinator.setGroupVisible("strip", true)
        coordinator.detachGroup("strip")
        #expect(coordinator.knownGroupVisibility(of: "strip") == false)
        #expect(coordinator.demandCounts.isEmpty)
    }

    @Test("no feed: an attached viewer counts as visible and visibility reports are ignored")
    func noFeed() async throws {
        let provider = ScriptedMediaProvider(answerEverything: { _ in .success(Self.picture) })
        let coordinator = Self.coordinator(provider, feed: false)
        coordinator.attach(viewer: "m1", key: Self.key("a"), attrs: Self.attrs("a"), group: "strip")
        try await smartLinkEventually("landed") { coordinator.entry(for: Self.key("a")).image != nil }
        coordinator.setViewerVisible("m1", false)
        coordinator.setGroupVisible("strip", false)
        #expect(coordinator.demandCounts == [Self.key("a"): 1])
        #expect(coordinator.knownVisibility(of: "m1") == nil)
        coordinator.detach(viewer: "m1")
        #expect(coordinator.demandCounts.isEmpty)
    }

    @Test("a visibility report may come before the attach; a false for an unattached viewer is not kept")
    func visibilityBeforeAttach() async throws {
        let provider = ScriptedMediaProvider(answerEverything: { _ in .success(Self.picture) })
        let coordinator = Self.coordinator(provider)
        coordinator.setViewerVisible("m1", true)
        #expect(coordinator.demandCounts.isEmpty)
        coordinator.attach(viewer: "m1", key: Self.key("a"), attrs: Self.attrs("a"), group: nil)
        try await smartLinkEventually("landed") { coordinator.entry(for: Self.key("a")).image != nil }
        coordinator.setViewerVisible("gone", false)
        #expect(coordinator.knownVisibility(of: "gone") == nil)
    }

    @Test("update moves demand to the new key: the old load is cancelled, the new one starts")
    func updateMovesDemand() async throws {
        let provider = ScriptedMediaProvider()
        let coordinator = Self.coordinator(provider)
        let small = Self.key("a", width: 300, height: 225), large = Self.key("a", width: 600, height: 450)
        coordinator.attach(viewer: "m1", key: small, attrs: Self.attrs("a"), group: nil)
        coordinator.setViewerVisible("m1", true)
        try await smartLinkEventually("the first call") { provider.calls.count == 1 }
        // The box settled at a new size (rotation).
        coordinator.update(viewer: "m1", key: large, attrs: Self.attrs("a"))
        #expect(coordinator.demandCounts == [large: 1])
        try await smartLinkEventually("the old call cancelled") { provider.cancelled == [Self.source("a")] }
        try await smartLinkEventually("the new call") { provider.calls.count == 2 }
        #expect(provider.sizes == [CGSize(width: 300, height: 225), CGSize(width: 600, height: 450)])
        provider.answer(Self.source("a"), .success(Self.picture))
        try await smartLinkEventually("landed at the new size") { coordinator.entry(for: large).image != nil }
        #expect(coordinator.entry(for: small).image == nil)
    }

    @Test("overlapping appear/disappear under one viewer id keeps demand until the last detach")
    func overlappingAttachments() async throws {
        let provider = ScriptedMediaProvider()
        let coordinator = Self.coordinator(provider)
        Self.show(coordinator, "m1", "a")
        coordinator.attach(viewer: "m1", key: Self.key("a"), attrs: Self.attrs("a"), group: nil)
        try await smartLinkEventually("the call") { provider.calls.count == 1 }
        coordinator.detach(viewer: "m1")
        #expect(coordinator.demandCounts == [Self.key("a"): 1])
        #expect(provider.cancelled.isEmpty)
        coordinator.detach(viewer: "m1")
        #expect(coordinator.demandCounts.isEmpty)
        #expect(coordinator.attachedViewerIDs.isEmpty)
        try await smartLinkEventually("cancelled") { provider.cancelled == [Self.source("a")] }
    }
}
