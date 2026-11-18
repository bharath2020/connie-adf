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

/// A resolver slow to stop: every call waits until the test releases its
/// URL, whether or not it was cancelled, and then honours cancellation. It
/// records how many calls ran at once, in all and per URL.
final class SlowToStopSmartLinkResolver: ADFSmartLinkResolver, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [URL: [CheckedContinuation<Void, Never>]] = [:]
    private var released: Set<URL> = []
    private var _calls: [URL] = []
    private var running: [URL: Int] = [:]
    private var _maxRunning = 0
    private var _maxPerURL = 0

    var calls: [URL] { lock.withLock { _calls } }
    var maxRunning: Int { lock.withLock { _maxRunning } }
    var maxPerURL: Int { lock.withLock { _maxPerURL } }
    var runningURLs: [URL: Int] { lock.withLock { running.filter { $0.value > 0 } } }

    func resolve(_ url: URL) async throws -> ADFSmartLinkMetadata {
        lock.withLock {
            _calls.append(url)
            running[url, default: 0] += 1
            _maxRunning = max(_maxRunning, running.values.reduce(0, +))
            _maxPerURL = max(_maxPerURL, running[url] ?? 0)
        }
        defer { lock.withLock { running[url, default: 1] -= 1 } }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let go = lock.withLock { () -> Bool in
                if released.contains(url) { return true }
                waiting[url, default: []].append(continuation)
                return false
            }
            if go { continuation.resume() }
        }
        try Task.checkCancellation()
        return ADFSmartLinkMetadata(title: "Title \(url.lastPathComponent)")
    }

    /// Lets every call for `url`, now and later, return.
    func release(_ url: URL) {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            released.insert(url)
            return waiting.removeValue(forKey: url) ?? []
        }
        continuations.forEach { $0.resume() }
    }
}

/// The per-document coordinator (design §2, §4): demand from visible
/// leaves, dwell, the concurrency cap, dedup, cancellation, terminal stages
/// and the generation reset — driven directly, as the views drive it.
@Suite("Smart link coordinator", .serialized)
@MainActor
struct SmartLinkCoordinatorTests {
    nonisolated static func key(_ path: String) -> SmartLinkKey {
        SmartLinkKey("https://acme.atlassian.net/wiki/\(path)")!
    }

    nonisolated static let page = ADFSmartLinkMetadata(title: "Q3 Roadmap", icon: .page)

    /// The loading look shows as a call starts here (`resolvingDelay`
    /// zero): these tests prove the stage machine, and
    /// `SmartLinkLandingTests` proves the delay (design §10).
    static func coordinator(
        _ resolver: any ADFSmartLinkResolver, dwell: Duration = .zero, maxConcurrent: Int = 4,
        sleeper: ManualSleeper? = nil, feed: Bool = true, resolvingDelay: Duration = .zero
    ) -> SmartLinkCoordinator {
        var timing = SmartLinkTiming(dwell: dwell, resolvingDelay: resolvingDelay, maxConcurrent: maxConcurrent)
        if let sleeper { timing.sleep = { try await sleeper.sleep($0) } }
        let coordinator = SmartLinkCoordinator(timing: timing, hasVisibilityFeed: feed)
        coordinator.resolver = resolver
        return coordinator
    }

    /// Attaches a leaf and reports it on screen, all of it, as an on-screen
    /// paragraph does (a leaf straddling an edge reports only the first).
    static func show(_ coordinator: SmartLinkCoordinator, _ leaf: String, _ keys: [SmartLinkKey]) {
        coordinator.attach(leaf: leaf, keys: keys)
        coordinator.setLeafVisible(leaf, true)
        coordinator.setLeafFullyVisible(leaf, true)
    }

    @Test("a visible leaf's key goes plain → resolving → resolved, with one resolver call")
    func resolvesWhenVisible() async throws {
        let resolver = ScriptedSmartLinkResolver()
        let coordinator = Self.coordinator(resolver)
        let a = Self.key("a")
        coordinator.attach(leaf: "p1", keys: [a])
        #expect(coordinator.stage(for: a) == .plain)
        coordinator.setLeafVisible("p1", true)
        #expect(coordinator.stage(for: a) == .resolving)
        try await smartLinkEventually("the call") { resolver.waitingURLs == [a.url] }
        resolver.answer(a.url, .success(Self.page))
        try await smartLinkEventually("resolved") { coordinator.stage(for: a) == .resolved(Self.page) }
        #expect(resolver.calls == [a.url])
        #expect(coordinator.stats.resolverCalls == 1)
        #expect(coordinator.stats.resolved == 1)
        #expect(coordinator.stats.inFlight == 0)
    }

    @Test("only visible leaves resolve: attached leaves not on screen never call the resolver")
    func onlyVisibleLeavesResolve() async throws {
        let resolver = ScriptedSmartLinkResolver(answerEverything: { _ in .success(Self.page) })
        let coordinator = Self.coordinator(resolver)
        // Prefetched leaves (and list items below the screen in the same
        // tall row): attached (onAppear), reported not visible.
        coordinator.attach(leaf: "0.2", keys: [Self.key("prefetched")])
        coordinator.setLeafVisible("0.2", false)
        coordinator.attach(leaf: "0.9", keys: [Self.key("last-row")])
        Self.show(coordinator, "0.1", [Self.key("on-screen")])
        try await smartLinkEventually("on-screen resolved") { coordinator.stage(for: Self.key("on-screen")) == .resolved(Self.page) }
        // Give any stray work a chance to show up.
        for _ in 0..<20 { await Task.yield() }
        #expect(resolver.calls == [Self.key("on-screen").url])
        #expect(coordinator.stage(for: Self.key("prefetched")) == .plain)
        #expect(coordinator.stage(for: Self.key("last-row")) == .plain)
        #expect(coordinator.pendingKeys.isEmpty)
    }

    @Test("a visibility report may come before the attach; without a feed every attached leaf counts as visible")
    func visibilityOrderAndNoFeedFallback() async throws {
        let resolver = ScriptedSmartLinkResolver(answerEverything: { _ in .success(Self.page) })
        let early = Self.coordinator(resolver)
        early.setLeafVisible("p1", true)
        #expect(early.demandCounts.isEmpty)
        early.attach(leaf: "p1", keys: [Self.key("early")])
        try await smartLinkEventually("reported-then-attached leaf resolved") { early.stage(for: Self.key("early")) == .resolved(Self.page) }
        // A `false` for a leaf that is not attached is not kept.
        early.setLeafVisible("gone", false)
        #expect(early.knownVisibility(of: "gone") == nil)

        let noFeed = Self.coordinator(resolver, feed: false)
        noFeed.attach(leaf: "p1", keys: [Self.key("ios17")])
        try await smartLinkEventually("pre-18 leaf resolved") { noFeed.stage(for: Self.key("ios17")) == .resolved(Self.page) }
        // Without a feed, visibility reports are ignored.
        noFeed.setLeafVisible("p1", false)
        #expect(noFeed.stage(for: Self.key("ios17")) == .resolved(Self.page))
        #expect(noFeed.knownVisibility(of: "p1") == nil)
    }

    @Test("the same URL in many leaves is looked up once")
    func dedup() async throws {
        let resolver = ScriptedSmartLinkResolver()
        let coordinator = Self.coordinator(resolver)
        let a = Self.key("a"), b = Self.key("b")
        Self.show(coordinator, "p1", [a, b])
        Self.show(coordinator, "p2", [a])
        Self.show(coordinator, "li", [a])
        try await smartLinkEventually("both calls") { resolver.waitingURLs == [a.url, b.url] }
        #expect(resolver.calls.filter { $0 == a.url }.count == 1)
        #expect(coordinator.demandCounts[a] == 3)
        resolver.answer(a.url, .success(Self.page))
        resolver.answer(b.url, .failure(ADFSmartLinkError.notFound))
        try await smartLinkEventually("settled") { coordinator.stats.inFlight == 0 }
        #expect(coordinator.stage(for: a) == .resolved(Self.page))
        #expect(coordinator.stage(for: b) == .failed(.notFound))
        // Terminal: leaving and coming back asks nothing again.
        coordinator.setLeafVisible("p1", false)
        coordinator.setLeafVisible("p1", true)
        coordinator.detach(leaf: "p2")
        Self.show(coordinator, "p2", [a])
        for _ in 0..<20 { await Task.yield() }
        #expect(resolver.calls.count == 2)
    }

    @Test("leaving the screen cancels the call and returns the link to plain; coming back retries")
    func cancelOnLeave() async throws {
        let resolver = ScriptedSmartLinkResolver()
        let coordinator = Self.coordinator(resolver)
        let a = Self.key("a")
        Self.show(coordinator, "p1", [a])
        Self.show(coordinator, "p2", [a])
        try await smartLinkEventually("the call") { resolver.waitingURLs == [a.url] }
        // One of two leaves leaves: demand remains, the call keeps running.
        coordinator.setLeafVisible("p1", false)
        #expect(coordinator.stage(for: a) == .resolving)
        #expect(resolver.cancelled.isEmpty)
        // The last one leaves (render-region exit detaches the leaf).
        coordinator.detach(leaf: "p2")
        #expect(coordinator.stage(for: a) == .plain)
        try await smartLinkEventually("the resolver saw the cancellation") { resolver.cancelled == [a.url] }
        try await smartLinkEventually("the cancelled call ended") { coordinator.stats.inFlight == 0 }
        #expect(coordinator.stats.cancellations == 1)
        // Cancellation is not failure: the next appearance asks again.
        coordinator.setLeafVisible("p1", true)
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
        Self.show(coordinator, "p1", [flung])
        Self.show(coordinator, "p2", [settled])
        try await smartLinkEventually("two dwells") { sleeper.count == 2 }
        #expect(sleeper.requested == [.milliseconds(150), .milliseconds(150)])
        // Dwelling stays plain.
        #expect(coordinator.stage(for: flung) == .plain)
        #expect(resolver.calls.isEmpty)
        // A fling: the first leaf leaves before its dwell ends.
        coordinator.setLeafVisible("p1", false)
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
            Self.show(coordinator, "p\(index)", [key])
        }
        try await smartLinkEventually("four calls") { resolver.waitingURLs.count == 4 }
        #expect(coordinator.stats.inFlight == 4)
        #expect(coordinator.queuedKeys == [keys[4], keys[5]])
        #expect(coordinator.stage(for: keys[4]) == .plain)
        // A queued key that leaves loses its place without a call.
        coordinator.setLeafVisible("p4", false)
        #expect(coordinator.queuedKeys == [keys[5]])
        resolver.answer(keys[0].url, .success(Self.page))
        try await smartLinkEventually("the fifth key started") { resolver.waitingURLs.contains(keys[5].url) }
        #expect(coordinator.stats.inFlight == 4)
        #expect(!resolver.calls.contains(keys[4].url))
        // A cancelled call frees its slot too, once it has ended.
        coordinator.setLeafVisible("p4", true)
        #expect(coordinator.queuedKeys == [keys[4]])
        coordinator.setLeafVisible("p1", false)
        try await smartLinkEventually("the freed slot used") { resolver.waitingURLs.contains(keys[4].url) }
        #expect(coordinator.stats.inFlight == 4)
    }

    @Test("a cancelled call keeps its slot until it ends: never more than four calls, never two for one URL")
    func slowToStopResolverKeepsLimits() async throws {
        let resolver = SlowToStopSmartLinkResolver()
        let coordinator = Self.coordinator(resolver)
        let keys = (0..<5).map { Self.key("s\($0)") }
        for (index, key) in keys.enumerated() {
            Self.show(coordinator, "p\(index)", [key])
        }
        try await smartLinkEventually("four calls") { resolver.calls.count == 4 }
        #expect(coordinator.queuedKeys == [keys[4]])

        // s0 leaves: its call is cancelled, but the resolver has not stopped.
        coordinator.setLeafVisible("p0", false)
        #expect(coordinator.stage(for: keys[0]) == .plain)
        for _ in 0..<40 { await Task.yield() }
        #expect(resolver.calls.count == 4, "a fifth call started while a cancelled one still ran: \(resolver.calls.map(\.lastPathComponent))")
        #expect(coordinator.stats.inFlight == 4)
        #expect(coordinator.queuedKeys == [keys[4]])
        #expect(coordinator.stats.cancellations == 0)

        // s0 comes back while its old call still runs: no second call yet.
        coordinator.setLeafVisible("p0", true)
        for _ in 0..<40 { await Task.yield() }
        #expect(resolver.calls.filter { $0 == keys[0].url }.count == 1)

        // The old call finally stops: its slot goes to the queued s4 first,
        // and s0 starts over behind it.
        resolver.release(keys[0].url)
        try await smartLinkEventually("s4 started") { resolver.calls.contains(keys[4].url) }
        try await smartLinkEventually("the stopped call counted") { coordinator.stats.cancellations == 1 }
        #expect(coordinator.queuedKeys == [keys[0]])
        #expect(coordinator.stats.inFlight == 4)

        for key in keys.dropFirst() { resolver.release(key.url) }
        try await smartLinkEventually("all resolved") {
            keys.allSatisfy { coordinator.stage(for: $0) == .resolved(ADFSmartLinkMetadata(title: "Title \($0.url.lastPathComponent)")) }
        }
        #expect(resolver.maxRunning <= 4, "max running \(resolver.maxRunning)")
        #expect(resolver.maxPerURL == 1, "max per URL \(resolver.maxPerURL)")
        #expect(resolver.calls.filter { $0 == keys[0].url }.count == 2)
        let stats = coordinator.stats
        #expect(stats.resolverCalls == 6 && stats.resolved == 5 && stats.cancellations == 1 && stats.inFlight == 0, "\(stats)")
        #expect(stats.resolverCalls == stats.resolved + stats.failed + stats.cancellations + stats.inFlight)
    }

    @Test("releasing the coordinator cancels its calls and dwells")
    func deinitCancels() async throws {
        let resolver = ScriptedSmartLinkResolver()
        let sleeper = ManualSleeper()
        var coordinator: SmartLinkCoordinator? = Self.coordinator(resolver)
        let a = Self.key("a")
        Self.show(coordinator!, "p1", [a])
        try await smartLinkEventually("the call") { resolver.waitingURLs == [a.url] }
        var dwelling: SmartLinkCoordinator? = Self.coordinator(resolver, dwell: .milliseconds(150), sleeper: sleeper)
        Self.show(dwelling!, "p2", [Self.key("b")])
        try await smartLinkEventually("the dwell") { sleeper.count == 1 }

        weak var released = coordinator
        weak var releasedDwelling = dwelling
        coordinator = nil
        dwelling = nil
        #expect(released == nil && releasedDwelling == nil, "a coordinator outlived its owner")
        try await smartLinkEventually("the call cancelled") { resolver.cancelled == [a.url] }
        try await smartLinkEventually("the dwell cancelled") { sleeper.count == 0 }
        #expect(resolver.calls == [a.url])
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
        coordinator.attach(leaf: "p", keys: [Self.key("u"), Self.key("n"), Self.key("o")])
        try await smartLinkEventually("all failed") { coordinator.stats.failed == 3 }
        #expect(coordinator.stage(for: Self.key("u")) == .failed(.unauthorized))
        #expect(coordinator.stage(for: Self.key("n")) == .failed(.notFound))
        #expect(coordinator.stage(for: Self.key("o")) == .failed(.other))
        #expect(!SmartLinkStage.failed(.other).changesDisplay)
        coordinator.detach(leaf: "p")
        coordinator.attach(leaf: "p", keys: [Self.key("u")])
        for _ in 0..<20 { await Task.yield() }
        #expect(resolver.calls.count == 3)
    }

    @Test("a returned title is cleaned before it lands; a title empty once cleaned fails the lookup")
    func titlesAreCleaned() async throws {
        let messy = ADFSmartLinkMetadata(title: "  Q3\r\nRoadmap\u{2028}notes \u{202E}draft\u{202C}\t", icon: .issue)
        let blank = ADFSmartLinkMetadata(title: " \n\u{202E}\u{2066}\u{200F} \u{2029}", icon: .page)
        let resolver = ScriptedSmartLinkResolver(immediate: [
            Self.key("messy").url: .success(messy),
            Self.key("blank").url: .success(blank),
        ])
        let coordinator = Self.coordinator(resolver, feed: false)
        coordinator.attach(leaf: "p", keys: [Self.key("messy"), Self.key("blank")])
        try await smartLinkEventually("both settled") { coordinator.stats.resolved + coordinator.stats.failed == 2 }
        #expect(coordinator.stage(for: Self.key("messy")) == .resolved(ADFSmartLinkMetadata(title: "Q3 Roadmap notes draft", icon: .issue)))
        #expect(coordinator.stage(for: Self.key("blank")) == .failed(.emptyTitle))
        #expect(!SmartLinkStage.failed(.emptyTitle).changesDisplay)
        #expect(coordinator.stats.resolved == 1 && coordinator.stats.failed == 1)
    }

    @Test("reset (a new document) cancels everything, drops late results and starts demanded keys over")
    func generationReset() async throws {
        let resolver = ScriptedSmartLinkResolver()
        let coordinator = Self.coordinator(resolver)
        let a = Self.key("a"), done = Self.key("done")
        Self.show(coordinator, "p1", [done])
        try await smartLinkEventually("first call") { resolver.waitingURLs == [done.url] }
        resolver.answer(done.url, .success(Self.page))
        try await smartLinkEventually("resolved") { coordinator.stage(for: done) == .resolved(Self.page) }
        coordinator.detach(leaf: "p1")

        Self.show(coordinator, "p2", [a])
        try await smartLinkEventually("second call") { resolver.waitingURLs == [a.url] }
        let generation = coordinator.generation
        coordinator.reset()
        #expect(coordinator.generation == generation + 1)
        // Resolved entries return to plain; the in-flight call is cancelled.
        #expect(coordinator.stage(for: done) == .plain)
        try await smartLinkEventually("cancellation seen") { resolver.cancelled.contains(a.url) }
        try await smartLinkEventually("the cancelled call counted") { coordinator.stats.cancellations == 1 }
        // The still-attached visible leaf is asked about again in the new
        // generation (block ids repeat across documents), once the old call
        // has ended.
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
        let coordinator = Self.coordinator(gate, feed: false)
        let a = Self.key("a")
        coordinator.attach(leaf: "p", keys: [a])
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
        Self.show(coordinator, "p", [a])
        #expect(coordinator.demandCounts.isEmpty)
        #expect(coordinator.pendingKeys.isEmpty)
        #expect(coordinator.attachedLeafIDs.isEmpty)
        #expect(coordinator.knownVisibility(of: "p") == nil)
        #expect(coordinator.stage(for: a) == .plain)
        #expect(coordinator.stats == ADFSmartLinkStats())
    }

    @Test("a leaf whose keys change under a stable identity moves its demand; a key it keeps is not cancelled")
    func keysChange() async throws {
        let resolver = ScriptedSmartLinkResolver()
        let coordinator = Self.coordinator(resolver)
        let a = Self.key("a"), b = Self.key("b"), c = Self.key("c")
        Self.show(coordinator, "p", [a, c])
        try await smartLinkEventually("a and c asked") { resolver.waitingURLs == [a.url, c.url] }
        coordinator.update(leaf: "p", keys: [b, c])
        try await smartLinkEventually("b asked, a cancelled") { resolver.waitingURLs == [b.url, c.url] }
        #expect(coordinator.demandCounts == [b: 1, c: 1])
        #expect(coordinator.stage(for: a) == .plain)
        #expect(resolver.cancelled == [a.url])
        #expect(resolver.calls.filter { $0 == c.url }.count == 1)
    }

    @Test("an attachment moved to a new leaf id or coordinator keeps its visibility and leaves nothing behind")
    func attachmentMoves() async throws {
        let resolver = ScriptedSmartLinkResolver()
        let old = Self.coordinator(resolver)
        let a = Self.key("a")
        Self.show(old, "0.0", [a])
        try await smartLinkEventually("the call") { resolver.waitingURLs == [a.url] }
        // What `SmartLinkTextLeaf` does when the block id changes under a
        // live view: no new visibility crossing is reported.
        let visible = old.knownVisibility(of: "0.0")
        #expect(visible == true)
        #expect(old.knownFullVisibility(of: "0.0") == true)
        SmartLinkAttachment.move(
            from: .init(coordinator: old, ownerID: "0.0", keys: [a]),
            to: .init(coordinator: old, ownerID: "new-id", keys: [a])
        )
        #expect(old.attachedLeafIDs == ["new-id"])
        #expect(old.knownVisibility(of: "new-id") == true)
        #expect(old.knownFullVisibility(of: "new-id") == true, "the move lost the leaf's full visibility")
        #expect(old.fullyVisibleLeafIDs == ["new-id"])
        #expect(old.demandCounts == [a: 1])
        #expect(resolver.cancelled.isEmpty, "the move cancelled the lookup")

        // A new coordinator (the host swapped models) learns the visibility too.
        let new = Self.coordinator(resolver)
        SmartLinkAttachment.move(
            from: .init(coordinator: old, ownerID: "new-id", keys: [a]),
            to: .init(coordinator: new, ownerID: "new-id", keys: [a])
        )
        #expect(old.attachedLeafIDs.isEmpty && old.demandCounts.isEmpty)
        #expect(old.fullyVisibleLeafIDs.isEmpty)
        #expect(new.demandCounts == [a: 1])
        #expect(new.knownVisibility(of: "new-id") == true)
        #expect(new.knownFullVisibility(of: "new-id") == true)
        // A report the leaf already made wins over the carried one.
        new.setLeafVisible("x", true)
        new.attach(leaf: "x", keys: [Self.key("x")], visible: false)
        #expect(new.knownVisibility(of: "x") == true)
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

    @Test("leaf bodies are recorded per owner only while recording is on")
    func leafBodyRecording() {
        let coordinator = SmartLinkCoordinator(timing: SmartLinkTiming(dwell: .zero), hasVisibilityFeed: true)
        coordinator.noteLeafBody("0.1", engine: false)
        #expect(coordinator.leafBodiesByOwner.isEmpty)
        coordinator.recordsLeafBodies = true
        coordinator.noteLeafBody("0.1", engine: false)
        coordinator.noteLeafBody("0.1", engine: false)
        coordinator.noteLeafBody("0.2", engine: true)
        coordinator.noteLeafBody(nil, engine: false)
        #expect(coordinator.leafBodiesByOwner == ["0.1": 2])
        #expect(coordinator.engineLeafBodiesByOwner == ["0.2": 1])
        coordinator.recordsLeafBodies = true
        #expect(coordinator.leafBodiesByOwner.isEmpty)
    }
}
