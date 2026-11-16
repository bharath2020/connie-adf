import Foundation
import Testing
import ADFPreparation
@_spi(ADFDiagnostics) @testable import ADFRendering

/// A resolver the test answers by hand: each call waits until `answer`
/// (or answers at once from `immediate`), and honours cancellation the way
/// the protocol asks.
final class ScriptedSmartLinkResolver: ADFSmartLinkResolver, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [URL: CheckedContinuation<ADFSmartLinkMetadata, any Error>] = [:]
    private var _calls: [URL] = []
    private var _cancelled: [URL] = []
    private let immediate: [URL: Result<ADFSmartLinkMetadata, any Error>]
    private let answerEverything: (@Sendable (URL) -> Result<ADFSmartLinkMetadata, any Error>)?

    init(immediate: [URL: Result<ADFSmartLinkMetadata, any Error>] = [:],
         answerEverything: (@Sendable (URL) -> Result<ADFSmartLinkMetadata, any Error>)? = nil) {
        self.immediate = immediate
        self.answerEverything = answerEverything
    }

    var calls: [URL] { lock.withLock { _calls } }
    var cancelled: [URL] { lock.withLock { _cancelled } }
    var waitingURLs: Set<URL> { lock.withLock { Set(waiting.keys) } }

    func resolve(_ url: URL) async throws -> ADFSmartLinkMetadata {
        lock.withLock { _calls.append(url) }
        if let result = immediate[url] ?? answerEverything?(url) { return try result.get() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelledAlready = lock.withLock { () -> Bool in
                    if Task.isCancelled { return true }
                    waiting[url] = continuation
                    return false
                }
                if cancelledAlready { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let continuation = lock.withLock { () -> CheckedContinuation<ADFSmartLinkMetadata, any Error>? in
                _cancelled.append(url)
                return waiting.removeValue(forKey: url)
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func answer(_ url: URL, _ result: Result<ADFSmartLinkMetadata, any Error>) {
        let continuation = lock.withLock { waiting.removeValue(forKey: url) }
        continuation?.resume(with: result)
    }
}

/// A dwell the test ends by hand.
final class ManualSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var sleepers: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var _requested: [Duration] = []

    var count: Int { lock.withLock { sleepers.count } }
    var requested: [Duration] { lock.withLock { _requested } }

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        lock.withLock { _requested.append(duration) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelledAlready = lock.withLock { () -> Bool in
                    if Task.isCancelled { return true }
                    sleepers[id] = continuation
                    return false
                }
                if cancelledAlready { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let continuation = lock.withLock { sleepers.removeValue(forKey: id) }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func wakeAll() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            defer { sleepers = [:] }
            return Array(sleepers.values)
        }
        all.forEach { $0.resume() }
    }
}

/// Polls `condition` on the main actor (the coordinator's results hop back
/// there) until it holds, or fails after about two seconds.
@MainActor
func smartLinkEventually(_ what: String, _ condition: () -> Bool) async throws {
    for _ in 0..<400 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("timed out waiting for \(what)")
    throw TestFailure("timed out waiting for \(what)")
}

/// The per-document coordinator (design §2, §4): demand from visible rows,
/// dwell, the concurrency cap, dedup, cancellation, terminal stages and the
/// generation reset — driven directly, as the views drive it.
@Suite("Smart link coordinator", .serialized)
@MainActor
struct SmartLinkCoordinatorTests {
    nonisolated static func key(_ path: String) -> SmartLinkKey {
        SmartLinkKey("https://acme.atlassian.net/wiki/\(path)")!
    }

    nonisolated static let page = ADFSmartLinkMetadata(title: "Q3 Roadmap", icon: .page)

    static func coordinator(
        _ resolver: ScriptedSmartLinkResolver, dwell: Duration = .zero, maxConcurrent: Int = 4,
        sleeper: ManualSleeper? = nil, feed: Bool = true
    ) -> SmartLinkCoordinator {
        var timing = SmartLinkTiming(dwell: dwell, maxConcurrent: maxConcurrent)
        if let sleeper { timing.sleep = { try await sleeper.sleep($0) } }
        let coordinator = SmartLinkCoordinator(timing: timing, hasVisibilityFeed: feed)
        coordinator.resolver = resolver
        return coordinator
    }

    @Test("a visible leaf's key goes plain → resolving → resolved, with one resolver call")
    func resolvesWhenVisible() async throws {
        let resolver = ScriptedSmartLinkResolver()
        let coordinator = Self.coordinator(resolver)
        let a = Self.key("a")
        coordinator.attach(leaf: "p1", row: "0.1", keys: [a])
        #expect(coordinator.stage(for: a) == .plain)
        coordinator.setRowVisible("0.1", true)
        #expect(coordinator.stage(for: a) == .resolving)
        try await smartLinkEventually("the call") { resolver.waitingURLs == [a.url] }
        resolver.answer(a.url, .success(Self.page))
        try await smartLinkEventually("resolved") { coordinator.stage(for: a) == .resolved(Self.page) }
        #expect(resolver.calls == [a.url])
        #expect(coordinator.stats.resolverCalls == 1)
        #expect(coordinator.stats.resolved == 1)
        #expect(coordinator.stats.inFlight == 0)
    }

    @Test("only visible rows resolve: attached leaves in rows not on screen never call the resolver")
    func onlyVisibleRowsResolve() async throws {
        let resolver = ScriptedSmartLinkResolver(answerEverything: { _ in .success(Self.page) })
        let coordinator = Self.coordinator(resolver)
        // Prefetched rows: attached (onAppear) but never reported visible.
        coordinator.attach(leaf: "p2", row: "0.2", keys: [Self.key("prefetched")])
        coordinator.attach(leaf: "p9", row: "0.9", keys: [Self.key("last-row")])
        coordinator.attach(leaf: "p1", row: "0.1", keys: [Self.key("on-screen")])
        coordinator.setRowVisible("0.1", true)
        try await smartLinkEventually("on-screen resolved") { coordinator.stage(for: Self.key("on-screen")) == .resolved(Self.page) }
        // Give any stray work a chance to show up.
        for _ in 0..<20 { await Task.yield() }
        #expect(resolver.calls == [Self.key("on-screen").url])
        #expect(coordinator.stage(for: Self.key("prefetched")) == .plain)
        #expect(coordinator.stage(for: Self.key("last-row")) == .plain)
        #expect(coordinator.pendingKeys.isEmpty)
    }

    @Test("a leaf outside any row, and every leaf without a visibility feed, counts as visible once attached")
    func fallbacksTreatAttachAsVisible() async throws {
        let resolver = ScriptedSmartLinkResolver(answerEverything: { _ in .success(Self.page) })
        let rowless = Self.coordinator(resolver)
        rowless.attach(leaf: "header-cell", row: nil, keys: [Self.key("pinned")])
        try await smartLinkEventually("pinned header resolved") { rowless.stage(for: Self.key("pinned")) == .resolved(Self.page) }

        let noFeed = Self.coordinator(resolver, feed: false)
        noFeed.attach(leaf: "p1", row: "0.1", keys: [Self.key("ios17")])
        try await smartLinkEventually("pre-18 leaf resolved") { noFeed.stage(for: Self.key("ios17")) == .resolved(Self.page) }
        // Without a feed, row visibility reports are ignored.
        noFeed.setRowVisible("0.1", false)
        #expect(noFeed.stage(for: Self.key("ios17")) == .resolved(Self.page))
    }

    @Test("the same URL in many leaves and rows is looked up once")
    func dedup() async throws {
        let resolver = ScriptedSmartLinkResolver()
        let coordinator = Self.coordinator(resolver)
        let a = Self.key("a"), b = Self.key("b")
        coordinator.attach(leaf: "p1", row: "0.1", keys: [a, b])
        coordinator.attach(leaf: "p2", row: "0.2", keys: [a])
        coordinator.attach(leaf: "li", row: "0.3", keys: [a])
        for row in ["0.1", "0.2", "0.3"] { coordinator.setRowVisible(row, true) }
        try await smartLinkEventually("both calls") { resolver.waitingURLs == [a.url, b.url] }
        #expect(resolver.calls.filter { $0 == a.url }.count == 1)
        #expect(coordinator.demandCounts[a] == 3)
        resolver.answer(a.url, .success(Self.page))
        resolver.answer(b.url, .failure(ADFSmartLinkError.notFound))
        try await smartLinkEventually("settled") { coordinator.stats.inFlight == 0 }
        #expect(coordinator.stage(for: a) == .resolved(Self.page))
        #expect(coordinator.stage(for: b) == .failed(.notFound))
        // Terminal: leaving and coming back asks nothing again.
        coordinator.setRowVisible("0.1", false)
        coordinator.setRowVisible("0.1", true)
        coordinator.detach(leaf: "p2")
        coordinator.attach(leaf: "p2", row: "0.2", keys: [a])
        for _ in 0..<20 { await Task.yield() }
        #expect(resolver.calls.count == 2)
    }

    @Test("leaving the screen cancels the call and returns the link to plain; coming back retries")
    func cancelOnLeave() async throws {
        let resolver = ScriptedSmartLinkResolver()
        let coordinator = Self.coordinator(resolver)
        let a = Self.key("a")
        coordinator.attach(leaf: "p1", row: "0.1", keys: [a])
        coordinator.attach(leaf: "p2", row: "0.2", keys: [a])
        coordinator.setRowVisible("0.1", true)
        coordinator.setRowVisible("0.2", true)
        try await smartLinkEventually("the call") { resolver.waitingURLs == [a.url] }
        // One of two rows leaves: demand remains, the call keeps running.
        coordinator.setRowVisible("0.1", false)
        #expect(coordinator.stage(for: a) == .resolving)
        #expect(resolver.cancelled.isEmpty)
        // The last one leaves (render-region exit detaches the leaf).
        coordinator.detach(leaf: "p2")
        #expect(coordinator.stage(for: a) == .plain)
        try await smartLinkEventually("the resolver saw the cancellation") { resolver.cancelled == [a.url] }
        #expect(coordinator.stats.cancellations == 1)
        #expect(coordinator.stats.inFlight == 0)
        // Cancellation is not failure: the next appearance asks again.
        coordinator.setRowVisible("0.1", true)
        try await smartLinkEventually("the retry") { resolver.calls == [a.url, a.url] }
        resolver.answer(a.url, .success(Self.page))
        try await smartLinkEventually("resolved") { coordinator.stage(for: a) == .resolved(Self.page) }
        let stats = coordinator.stats
        #expect(stats.resolverCalls == stats.resolved + stats.failed + stats.cancellations + stats.inFlight)
    }

    @Test("a 150 ms dwell: nothing is asked until it ends, and a key that leaves during it is never asked")
    func dwell() async throws {
        let resolver = ScriptedSmartLinkResolver(answerEverything: { _ in .success(Self.page) })
        let sleeper = ManualSleeper()
        let coordinator = Self.coordinator(resolver, dwell: .milliseconds(150), sleeper: sleeper)
        #expect(SmartLinkTiming().dwell == .milliseconds(150))
        let flung = Self.key("flung"), settled = Self.key("settled")
        coordinator.attach(leaf: "p1", row: "0.1", keys: [flung])
        coordinator.attach(leaf: "p2", row: "0.2", keys: [settled])
        coordinator.setRowVisible("0.1", true)
        coordinator.setRowVisible("0.2", true)
        try await smartLinkEventually("two dwells") { sleeper.count == 2 }
        #expect(sleeper.requested == [.milliseconds(150), .milliseconds(150)])
        // Dwelling stays plain.
        #expect(coordinator.stage(for: flung) == .plain)
        #expect(resolver.calls.isEmpty)
        // A fling: the first row leaves before its dwell ends.
        coordinator.setRowVisible("0.1", false)
        try await smartLinkEventually("the cancelled dwell") { sleeper.count == 1 }
        sleeper.wakeAll()
        try await smartLinkEventually("settled resolved") { coordinator.stage(for: settled) == .resolved(Self.page) }
        for _ in 0..<20 { await Task.yield() }
        #expect(resolver.calls == [settled.url])
        #expect(coordinator.stage(for: flung) == .plain)
        #expect(coordinator.stats.cancellations == 0)
    }

    @Test("at most four lookups run at once; the rest queue in order and start as slots free")
    func concurrencyCap() async throws {
        let resolver = ScriptedSmartLinkResolver()
        let coordinator = Self.coordinator(resolver)
        #expect(SmartLinkTiming().maxConcurrent == 4)
        let keys = (0..<6).map { Self.key("k\($0)") }
        for (index, key) in keys.enumerated() {
            coordinator.attach(leaf: "p\(index)", row: "0.\(index)", keys: [key])
            coordinator.setRowVisible("0.\(index)", true)
        }
        try await smartLinkEventually("four calls") { resolver.waitingURLs.count == 4 }
        #expect(coordinator.stats.inFlight == 4)
        #expect(coordinator.queuedKeys == [keys[4], keys[5]])
        #expect(coordinator.stage(for: keys[4]) == .plain)
        // A queued key that leaves loses its place without a call.
        coordinator.setRowVisible("0.4", false)
        #expect(coordinator.queuedKeys == [keys[5]])
        resolver.answer(keys[0].url, .success(Self.page))
        try await smartLinkEventually("the fifth key started") { resolver.waitingURLs.contains(keys[5].url) }
        #expect(coordinator.stats.inFlight == 4)
        #expect(!resolver.calls.contains(keys[4].url))
        // A cancelled call frees its slot too.
        coordinator.setRowVisible("0.4", true)
        #expect(coordinator.queuedKeys == [keys[4]])
        coordinator.setRowVisible("0.1", false)
        try await smartLinkEventually("the freed slot used") { resolver.waitingURLs.contains(keys[4].url) }
        #expect(coordinator.stats.inFlight == 4)
    }

    @Test("failures are terminal and classified; other errors fail as .other")
    func failures() async throws {
        struct Boom: Error {}
        let resolver = ScriptedSmartLinkResolver(immediate: [
            Self.key("u").url: .failure(ADFSmartLinkError.unauthorized),
            Self.key("n").url: .failure(ADFSmartLinkError.notFound),
            Self.key("o").url: .failure(Boom()),
        ])
        let coordinator = Self.coordinator(resolver, feed: false)
        coordinator.attach(leaf: "p", row: nil, keys: [Self.key("u"), Self.key("n"), Self.key("o")])
        try await smartLinkEventually("all failed") { coordinator.stats.failed == 3 }
        #expect(coordinator.stage(for: Self.key("u")) == .failed(.unauthorized))
        #expect(coordinator.stage(for: Self.key("n")) == .failed(.notFound))
        #expect(coordinator.stage(for: Self.key("o")) == .failed(.other))
        #expect(!SmartLinkStage.failed(.other).changesDisplay)
        coordinator.detach(leaf: "p")
        coordinator.attach(leaf: "p", row: nil, keys: [Self.key("u")])
        for _ in 0..<20 { await Task.yield() }
        #expect(resolver.calls.count == 3)
    }

    @Test("reset (a new document) cancels everything, drops late results and starts demanded keys over")
    func generationReset() async throws {
        let resolver = ScriptedSmartLinkResolver()
        let coordinator = Self.coordinator(resolver)
        let a = Self.key("a"), done = Self.key("done")
        coordinator.attach(leaf: "p1", row: "0.1", keys: [done])
        coordinator.setRowVisible("0.1", true)
        try await smartLinkEventually("first call") { resolver.waitingURLs == [done.url] }
        resolver.answer(done.url, .success(Self.page))
        try await smartLinkEventually("resolved") { coordinator.stage(for: done) == .resolved(Self.page) }
        coordinator.detach(leaf: "p1")

        coordinator.attach(leaf: "p2", row: "0.2", keys: [a])
        coordinator.setRowVisible("0.2", true)
        try await smartLinkEventually("second call") { resolver.waitingURLs == [a.url] }
        let generation = coordinator.generation
        coordinator.reset()
        #expect(coordinator.generation == generation + 1)
        // Resolved entries return to plain; the in-flight call is cancelled.
        #expect(coordinator.stage(for: done) == .plain)
        #expect(coordinator.stats.cancellations == 1)
        try await smartLinkEventually("cancellation seen") { resolver.cancelled.contains(a.url) }
        // The still-attached visible leaf is asked about again in the new
        // generation (block ids repeat across documents).
        try await smartLinkEventually("restarted") { resolver.calls.filter { $0 == a.url }.count == 2 }
        #expect(coordinator.stage(for: a) == .resolving)
        resolver.answer(a.url, .success(ADFSmartLinkMetadata(title: "New document", icon: .issue)))
        try await smartLinkEventually("new generation resolved") {
            coordinator.stage(for: a) == .resolved(ADFSmartLinkMetadata(title: "New document", icon: .issue))
        }
    }

    @Test("a late result from before a reset never lands")
    func lateResultDropped() async throws {
        let gate = ScriptedSmartLinkResolver()
        let coordinator = Self.coordinator(gate)
        let a = Self.key("a")
        coordinator.attach(leaf: "p", row: nil, keys: [a])
        try await smartLinkEventually("call") { gate.waitingURLs == [a.url] }
        // The leaf goes away and a new document loads; nothing demands `a`.
        coordinator.detach(leaf: "p")
        coordinator.reset()
        // Even if the resolver ignores cancellation and answers anyway:
        gate.answer(a.url, .success(Self.page))
        for _ in 0..<40 { await Task.yield() }
        #expect(coordinator.stage(for: a) == .plain)
        #expect(coordinator.stats.resolved == 0)
    }

    @Test("without a resolver nothing is tracked or asked")
    func noResolverNoWork() async throws {
        let coordinator = SmartLinkCoordinator(timing: SmartLinkTiming(dwell: .zero), hasVisibilityFeed: true)
        let a = Self.key("a")
        coordinator.attach(leaf: "p", row: "0.1", keys: [a])
        coordinator.setRowVisible("0.1", true)
        #expect(coordinator.demandCounts.isEmpty)
        #expect(coordinator.pendingKeys.isEmpty)
        #expect(coordinator.stage(for: a) == .plain)
        #expect(coordinator.stats == ADFSmartLinkStats())
    }

    @Test("a leaf whose keys change under a stable identity moves its demand")
    func keysChange() async throws {
        let resolver = ScriptedSmartLinkResolver()
        let coordinator = Self.coordinator(resolver)
        let a = Self.key("a"), b = Self.key("b")
        coordinator.attach(leaf: "p", row: "0.1", keys: [a])
        coordinator.setRowVisible("0.1", true)
        try await smartLinkEventually("a asked") { resolver.waitingURLs == [a.url] }
        coordinator.update(leaf: "p", row: "0.1", keys: [b])
        try await smartLinkEventually("b asked, a cancelled") { resolver.waitingURLs == [b.url] }
        #expect(coordinator.demandCounts == [b: 1])
        #expect(coordinator.stage(for: a) == .plain)
    }

    @Test("leaf redraws are counted per owner, only when what the leaf draws changes")
    func leafRefreshCounting() {
        let coordinator = SmartLinkCoordinator(timing: SmartLinkTiming(dwell: .zero), hasVisibilityFeed: true)
        let a = Self.key("a")
        // First draw: not a refresh.
        #expect(coordinator.displayStages(for: [a], owner: "0.1").isEmpty)
        #expect(coordinator.displayStages(for: [a], owner: "0.1").isEmpty)
        #expect(coordinator.stats.leafRefreshes == 0)
        coordinator.entry(for: a).publish(.resolving)
        #expect(coordinator.displayStages(for: [a], owner: "0.1") == [a: .resolving])
        // The other arm reading the same state is not another refresh.
        _ = coordinator.displayStages(for: [a], owner: "0.1")
        coordinator.entry(for: a).publish(.failed(.notFound))
        #expect(coordinator.displayStages(for: [a], owner: "0.1").isEmpty)
        #expect(coordinator.stats.leafRefreshes == 2)
        #expect(coordinator.leafRefreshesByOwner == ["0.1": 2])
    }
}
