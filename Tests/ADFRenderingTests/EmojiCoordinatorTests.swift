import CoreGraphics
import Foundation
import Testing
import ADFPreparation
import ADFModel
@_spi(ADFDiagnostics) @testable import ADFRendering

/// An emoji resolver the test answers by hand: each call waits until
/// `answer` (keyed by short name), and honours cancellation. Records
/// whether any call ran on the main thread.
final class ScriptedEmojiResolver: ADFEmojiResolver, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [String: CheckedContinuation<ADFResolvedImage, any Error>] = [:]
    private var _calls: [String] = []
    private var _cancelled: [String] = []
    private var _mainThreadCalls = 0
    private var _running = 0
    private var _maxRunning = 0
    /// When set, a call ignores cancellation until `answer` (a resolver slow
    /// to stop).
    let ignoresCancellation: Bool

    init(ignoresCancellation: Bool = false) {
        self.ignoresCancellation = ignoresCancellation
    }

    var calls: [String] { lock.withLock { _calls } }
    var cancelled: [String] { lock.withLock { _cancelled } }
    var waitingNames: Set<String> { lock.withLock { Set(waiting.keys) } }
    var mainThreadCalls: Int { lock.withLock { _mainThreadCalls } }
    var maxRunning: Int { lock.withLock { _maxRunning } }

    func image(for emoji: ADFEmojiReference) async throws -> ADFResolvedImage {
        let name = emoji.shortName
        lock.withLock {
            _calls.append(name)
            if Thread.isMainThread { _mainThreadCalls += 1 }
            _running += 1
            _maxRunning = max(_maxRunning, _running)
        }
        defer { lock.withLock { _running -= 1 } }
        let ignores = ignoresCancellation
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelledAlready = lock.withLock { () -> Bool in
                    if Task.isCancelled, !ignores { return true }
                    waiting[name] = continuation
                    return false
                }
                if cancelledAlready { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let continuation = lock.withLock { () -> CheckedContinuation<ADFResolvedImage, any Error>? in
                _cancelled.append(name)
                return ignores ? nil : waiting.removeValue(forKey: name)
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func answer(_ name: String, _ result: Result<ADFResolvedImage, any Error>) {
        let continuation = lock.withLock { waiting.removeValue(forKey: name) }
        continuation?.resume(with: result)
    }
}

struct EmojiTestError: Error {}

/// The per-document custom-emoji coordinator (design `adf-res1` §4.3,
/// §4.6): lazy, one lookup per key, four slots, cancel on zero demand,
/// failure terminal, reset by generation, and the smart-link landing hold.
@Suite("Emoji coordinator")
@MainActor
struct EmojiCoordinatorTests {
    static let e1 = EmojiKey(id: "custom-e1", shortName: ":e1:")
    static let e2 = EmojiKey(id: nil, shortName: ":e2:")

    static func key(_ index: Int) -> EmojiKey { EmojiKey(id: "k\(index)", shortName: ":k\(index):") }

    static func image(width: Int = 4, height: Int = 4) -> ADFResolvedImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ADFResolvedImage(cgImage: context.makeImage()!, scale: 2)
    }

    /// A coordinator with a visibility feed, no dwell (unless a sleeper is
    /// given) and `resolver` installed.
    static func coordinator(
        _ resolver: any ADFEmojiResolver, sleeper: ManualSleeper? = nil, feed: Bool = true
    ) -> EmojiCoordinator {
        var timing = EmojiTiming()
        if let sleeper {
            timing.sleep = { try await sleeper.sleep($0) }
        } else {
            timing.dwell = .zero
        }
        let coordinator = EmojiCoordinator(timing: timing, hasVisibilityFeed: feed)
        coordinator.resolver = resolver
        return coordinator
    }

    /// Attaches `leaf` with `keys` and reports it visible (and fully).
    static func show(_ coordinator: EmojiCoordinator, _ leaf: String, _ keys: [EmojiKey], fully: Bool = true) {
        coordinator.attach(leaf: leaf, keys: keys)
        coordinator.setLeafVisible(leaf, true)
        coordinator.setLeafFullyVisible(leaf, fully)
    }

    @Test("lazy: no call for an attached leaf off screen; a visible key dwells first, then asks off the main actor")
    func lazy() async throws {
        let resolver = ScriptedEmojiResolver()
        let sleeper = ManualSleeper()
        let coordinator = Self.coordinator(resolver, sleeper: sleeper)

        // Attached (built in the render region) but not visible: nothing.
        coordinator.attach(leaf: "p1", keys: [Self.e1])
        try await Task.sleep(for: .milliseconds(50))
        #expect(resolver.calls.isEmpty)
        #expect(coordinator.pendingKeys.isEmpty)
        #expect(coordinator.stage(for: Self.e1) == .pending)

        // Visible: dwelling, still no call.
        coordinator.setLeafVisible("p1", true)
        try await smartLinkEventually("the dwell began") { sleeper.count == 1 }
        #expect(sleeper.requested == [.milliseconds(150)])
        #expect(resolver.calls.isEmpty)

        // Leaving during the dwell asks nothing.
        coordinator.setLeafVisible("p1", false)
        try await smartLinkEventually("the dwell was cancelled") { sleeper.count == 0 }
        #expect(coordinator.pendingKeys.isEmpty)

        // Visible past the dwell: one call, off the main thread.
        coordinator.setLeafVisible("p1", true)
        try await smartLinkEventually("the dwell began again") { sleeper.count == 1 }
        sleeper.wakeAll()
        try await smartLinkEventually("the call") { resolver.waitingNames == [":e1:"] }
        #expect(resolver.calls == [":e1:"])
        #expect(resolver.mainThreadCalls == 0)
        resolver.answer(":e1:", .success(Self.image()))
        try await smartLinkEventually("resolved") {
            if case .resolved = coordinator.stage(for: Self.e1) { return true }
            return false
        }
        let stats = coordinator.stats
        #expect(stats.resolverCalls == 1 && stats.resolved == 1 && stats.inFlight == 0, "\(stats)")
    }

    @Test("no resolver: leaves attach nothing and nothing is asked")
    func noResolver() async throws {
        let coordinator = EmojiCoordinator(timing: EmojiTiming(dwell: .zero), hasVisibilityFeed: true)
        Self.show(coordinator, "p1", [Self.e1])
        #expect(coordinator.attachedLeafIDs.isEmpty)
        #expect(coordinator.pendingKeys.isEmpty)
    }

    @Test("dedup: many leaves with one key make one call, and every leaf draws its image")
    func dedup() async throws {
        let resolver = ScriptedEmojiResolver()
        let coordinator = Self.coordinator(resolver)
        for index in 0..<20 {
            Self.show(coordinator, "p\(index)", [Self.e1])
        }
        try await smartLinkEventually("the call") { resolver.waitingNames == [":e1:"] }
        #expect(coordinator.demandCounts[Self.e1] == 20)
        try await Task.sleep(for: .milliseconds(30))
        #expect(resolver.calls == [":e1:"])

        let image = Self.image()
        resolver.answer(":e1:", .success(image))
        try await smartLinkEventually("resolved") { coordinator.stage(for: Self.e1) != .pending }
        for index in 0..<20 {
            let stages = coordinator.displayStages(for: [Self.e1], owner: "p\(index)")
            #expect(stages[Self.e1] == .resolved(image), "p\(index)")
        }
        #expect(coordinator.stats.resolverCalls == 1)
    }

    @Test("at most four calls at once; the rest queue and start as slots free")
    func fourSlots() async throws {
        let resolver = ScriptedEmojiResolver()
        let coordinator = Self.coordinator(resolver)
        let keys = (0..<7).map(Self.key)
        for (index, key) in keys.enumerated() {
            Self.show(coordinator, "p\(index)", [key])
        }
        try await smartLinkEventually("four calls") { resolver.waitingNames.count == 4 }
        try await Task.sleep(for: .milliseconds(30))
        #expect(resolver.calls.count == 4)
        #expect(coordinator.queuedKeys == Array(keys[4...]))
        #expect(coordinator.stats.inFlight == 4)

        resolver.answer(":k0:", .success(Self.image()))
        try await smartLinkEventually("the fifth call") { resolver.calls.count == 5 }
        #expect(resolver.calls.last == ":k4:")
        for name in resolver.waitingNames { resolver.answer(name, .success(Self.image())) }
        try await smartLinkEventually("the rest") { resolver.calls.count == 7 }
        for name in resolver.waitingNames { resolver.answer(name, .success(Self.image())) }
        try await smartLinkEventually("all landed") { coordinator.stats.inFlight == 0 && coordinator.pendingKeys.isEmpty }
        #expect(resolver.maxRunning <= 4)
        #expect(coordinator.stats.resolved == 7)
    }

    @Test("zero demand cancels the call (the key stays a box); it is asked again when it returns")
    func cancelAndReask() async throws {
        let resolver = ScriptedEmojiResolver()
        let coordinator = Self.coordinator(resolver)
        Self.show(coordinator, "p1", [Self.e1])
        Self.show(coordinator, "p2", [Self.e1])
        try await smartLinkEventually("the call") { resolver.waitingNames == [":e1:"] }

        // One of two leaves leaving keeps the call.
        coordinator.setLeafVisible("p1", false)
        try await Task.sleep(for: .milliseconds(30))
        #expect(resolver.cancelled.isEmpty)

        // The last one leaving cancels it; cancellation is not failure.
        coordinator.detach(leaf: "p2")
        try await smartLinkEventually("cancelled") { coordinator.stats.cancellations == 1 }
        #expect(resolver.cancelled == [":e1:"])
        #expect(coordinator.stage(for: Self.e1) == .pending)
        #expect(coordinator.stats.inFlight == 0)
        #expect(coordinator.pendingKeys.isEmpty)

        // Back on screen: asked again.
        coordinator.setLeafVisible("p1", true)
        try await smartLinkEventually("the second call") { resolver.calls.count == 2 && resolver.waitingNames == [":e1:"] }
        resolver.answer(":e1:", .success(Self.image()))
        try await smartLinkEventually("resolved") { coordinator.stage(for: Self.e1) != .pending }
        let stats = coordinator.stats
        #expect(stats.resolverCalls == stats.resolved + stats.failed + stats.cancellations + stats.inFlight, "\(stats)")
    }

    @Test("a cancelled call keeps its slot until it returns: never more than four calls, never two for one key")
    func cancelledCallHoldsSlot() async throws {
        let resolver = ScriptedEmojiResolver(ignoresCancellation: true)
        let coordinator = Self.coordinator(resolver)
        coordinator.timing.maxConcurrent = 1
        Self.show(coordinator, "p1", [Self.e1])
        try await smartLinkEventually("the call") { resolver.waitingNames == [":e1:"] }

        // e1 leaves (its call ignores the cancel); e2 comes on screen and
        // must wait for the slot; e1 coming back must not start a second
        // call while the first still runs.
        coordinator.setLeafVisible("p1", false)
        Self.show(coordinator, "p2", [Self.e2])
        coordinator.setLeafVisible("p1", true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(resolver.calls == [":e1:"])
        #expect(coordinator.queuedKeys == [Self.e2])

        // The stopping call returns: its result is dropped, the slot goes
        // to the queue first, and e1 (wanted again) starts over behind it.
        resolver.answer(":e1:", .success(Self.image()))
        try await smartLinkEventually("e2 started") { resolver.waitingNames == [":e2:"] }
        #expect(coordinator.stage(for: Self.e1) == .pending)
        resolver.answer(":e2:", .success(Self.image()))
        try await smartLinkEventually("e1 asked again") { resolver.waitingNames == [":e1:"] }
        #expect(resolver.calls == [":e1:", ":e2:", ":e1:"])
        #expect(resolver.maxRunning == 1)
        resolver.answer(":e1:", .success(Self.image()))
        try await smartLinkEventually("e1 resolved") { coordinator.stage(for: Self.e1) != .pending }
    }

    @Test("failure is terminal in the document: the short name, never asked again")
    func failureTerminal() async throws {
        let resolver = ScriptedEmojiResolver()
        let coordinator = Self.coordinator(resolver)
        Self.show(coordinator, "p1", [Self.e1])
        try await smartLinkEventually("the call") { resolver.waitingNames == [":e1:"] }
        resolver.answer(":e1:", .failure(EmojiTestError()))
        try await smartLinkEventually("failed") { coordinator.stage(for: Self.e1) == .failed }

        coordinator.detach(leaf: "p1")
        Self.show(coordinator, "p1", [Self.e1])
        Self.show(coordinator, "p2", [Self.e1])
        try await Task.sleep(for: .milliseconds(50))
        #expect(resolver.calls == [":e1:"])
        #expect(coordinator.stage(for: Self.e1) == .failed)
        #expect(coordinator.stats.failed == 1)
        // What a leaf draws for it: the short name.
        let stages = coordinator.displayStages(for: [Self.e1], owner: "p2")
        #expect(EmojiDisplay.shownKind(for: Self.e1, stages: stages) == .shortName)
    }

    @Test("a Confluence custom emoji (non-hex id, text = short name) is prepared as custom and resolves")
    func confluenceShapeResolves() async throws {
        let doc = try await ADFParser().parse(Data(#"""
        {"version":1,"type":"doc","content":[{"type":"paragraph","content":[
          {"type":"text","text":"go "},
          {"type":"emoji","attrs":{"shortName":":partyparrot:","id":"7b4d0c1e-party-parrot","text":":partyparrot:"}},
          {"type":"emoji","attrs":{"shortName":":grinning:","id":"1f600","text":"😀"}}
        ]}]}
        """#.utf8))
        let block = try #require(DocumentPreparer(theme: .default).prepare(doc).first)
        let key = EmojiKey(id: "7b4d0c1e-party-parrot", shortName: ":partyparrot:")
        #expect(block.emojiKeys == [key])

        let resolver = ScriptedEmojiResolver()
        let coordinator = Self.coordinator(resolver)
        Self.show(coordinator, "p1", block.emojiKeys)
        try await smartLinkEventually("the call") { resolver.waitingNames == [":partyparrot:"] }
        resolver.answer(":partyparrot:", .success(Self.image()))
        try await smartLinkEventually("resolved") {
            if case .resolved = coordinator.stage(for: key) { return true }
            return false
        }
        #expect(resolver.calls == [":partyparrot:"])
    }

    @Test("reset: late results from before it are dropped, keys still in demand start over")
    func resetDropsLateResults() async throws {
        let resolver = ScriptedEmojiResolver(ignoresCancellation: true)
        let coordinator = Self.coordinator(resolver)
        Self.show(coordinator, "p1", [Self.e1])
        Self.show(coordinator, "p2", [Self.e2])
        try await smartLinkEventually("both calls") { resolver.waitingNames == [":e1:", ":e2:"] }
        resolver.answer(":e2:", .failure(EmojiTestError()))
        try await smartLinkEventually("e2 failed") { coordinator.stage(for: Self.e2) == .failed }

        let generation = coordinator.generation
        coordinator.reset()
        #expect(coordinator.generation == generation + 1)
        // Terminal stages are cleared by a reload.
        #expect(coordinator.stage(for: Self.e2) == .pending)
        // The old e1 call still runs (it ignores the cancel) and comes back
        // late with an image: dropped.
        resolver.answer(":e1:", .success(Self.image()))
        try await smartLinkEventually("the late call ended") { coordinator.stats.cancellations == 1 }
        #expect(coordinator.stage(for: Self.e1) == .pending)
        // Both keys are still on screen: asked again in the new generation.
        try await smartLinkEventually("asked again") { resolver.waitingNames == [":e1:", ":e2:"] }
        #expect(resolver.calls.count == 4)
        resolver.answer(":e1:", .success(Self.image()))
        resolver.answer(":e2:", .success(Self.image()))
        try await smartLinkEventually("both resolved") {
            coordinator.stage(for: Self.e1) != .pending && coordinator.stage(for: Self.e2) != .pending
        }
        #expect(coordinator.stage(for: Self.e2) != .failed)
    }

    @Test("the image is squared once as it lands, and every reader gets that same bitmap")
    func squaredOnce() async throws {
        let resolver = ScriptedEmojiResolver()
        let coordinator = Self.coordinator(resolver)
        Self.show(coordinator, "p1", [Self.e1])
        try await smartLinkEventually("the call") { resolver.waitingNames == [":e1:"] }
        resolver.answer(":e1:", .success(Self.image(width: 8, height: 4)))
        try await smartLinkEventually("resolved") { coordinator.stage(for: Self.e1) != .pending }
        guard case .resolved(let image) = coordinator.stage(for: Self.e1) else {
            Issue.record("not resolved")
            return
        }
        #expect(image.cgImage.width == 8 && image.cgImage.height == 8)
        guard case .resolved(let again) = coordinator.stage(for: Self.e1) else { return }
        #expect(image.cgImage === again.cgImage)
    }

    @Test("landing hold: while scrolling, an outcome waits until every leaf showing the key is fully on screen, or rest")
    func landingHold() async throws {
        let resolver = ScriptedEmojiResolver()
        let coordinator = Self.coordinator(resolver)
        coordinator.scrollPhaseChanged(scrolling: true)
        // p1 straddles the screen's edge (visible, not fully); p2 is fully on screen.
        Self.show(coordinator, "p1", [Self.e1], fully: false)
        Self.show(coordinator, "p2", [Self.e1])
        // The leaves draw the box before anything lands.
        #expect(coordinator.displayStages(for: [Self.e1], owner: "p1")[Self.e1] == .pending)
        #expect(coordinator.displayStages(for: [Self.e1], owner: "p2")[Self.e1] == .pending)
        try await smartLinkEventually("the call") { resolver.waitingNames == [":e1:"] }

        // A failure (box -> short name, a width change) lands mid-scroll: held.
        resolver.answer(":e1:", .failure(EmojiTestError()))
        try await smartLinkEventually("held") { coordinator.heldStage(for: Self.e1) == .failed }
        #expect(coordinator.stage(for: Self.e1) == .pending)
        #expect(coordinator.stats.held == 1)
        // A leaf that already drew the key keeps its box; a leaf drawing it
        // for the first time draws the outcome at once (its final width).
        #expect(coordinator.displayStages(for: [Self.e1], owner: "p1")[Self.e1] == .pending)
        #expect(coordinator.displayStages(for: [Self.e1], owner: "p9")[Self.e1] == .failed)

        // p1 comes fully on screen: published.
        coordinator.setLeafFullyVisible("p1", true)
        #expect(coordinator.stage(for: Self.e1) == .failed)
        #expect(coordinator.heldStage(for: Self.e1) == nil)

        // Second key: held until scrolling stops.
        Self.show(coordinator, "p3", [Self.e2], fully: false)
        try await smartLinkEventually("the e2 call") { resolver.waitingNames == [":e2:"] }
        resolver.answer(":e2:", .success(Self.image()))
        try await smartLinkEventually("e2 held") { coordinator.heldStage(for: Self.e2) != nil }
        #expect(coordinator.stage(for: Self.e2) == .pending)
        coordinator.scrollPhaseChanged(scrolling: false)
        #expect(coordinator.heldStage(for: Self.e2) == nil)
        if case .resolved = coordinator.stage(for: Self.e2) {} else {
            Issue.record("e2 not published at rest: \(coordinator.stage(for: Self.e2))")
        }
    }

    @Test("at rest, or without a visibility feed, an outcome lands at once")
    func noHoldAtRest() async throws {
        for feed in [true, false] {
            let resolver = ScriptedEmojiResolver()
            let coordinator = Self.coordinator(resolver, feed: feed)
            if !feed { coordinator.scrollPhaseChanged(scrolling: true) }
            Self.show(coordinator, "p1", [Self.e1], fully: false)
            try await smartLinkEventually("the call") { resolver.waitingNames == [":e1:"] }
            resolver.answer(":e1:", .failure(EmojiTestError()))
            try await smartLinkEventually("published") { coordinator.stage(for: Self.e1) == .failed }
            #expect(coordinator.stats.held == 0)
        }
    }

    @Test("leaf redraws are counted only when what a leaf draws changes")
    func leafRefreshes() async throws {
        let resolver = ScriptedEmojiResolver()
        let coordinator = Self.coordinator(resolver)
        Self.show(coordinator, "p1", [Self.e1, Self.e2])
        _ = coordinator.displayStages(for: [Self.e1, Self.e2], owner: "p1")
        _ = coordinator.displayStages(for: [Self.e1, Self.e2], owner: "p1")
        #expect(coordinator.stats.leafRefreshes == 0)
        try await smartLinkEventually("both calls") { resolver.waitingNames.count == 2 }
        resolver.answer(":e1:", .success(Self.image()))
        try await smartLinkEventually("resolved") { coordinator.stage(for: Self.e1) != .pending }
        _ = coordinator.displayStages(for: [Self.e1, Self.e2], owner: "p1")
        #expect(coordinator.leafRefreshesByOwner == ["p1": 1])
        resolver.answer(":e2:", .success(Self.image()))
        try await smartLinkEventually("e2 resolved") { coordinator.stage(for: Self.e2) != .pending }
    }

    @Test("the leaf feed moves an attachment: same coordinator keeps demand; a newly fed coordinator takes the other's visibility")
    func attachmentMoves() async throws {
        let resolver = ScriptedEmojiResolver()
        let coordinator = Self.coordinator(resolver)
        Self.show(coordinator, "old", [Self.e1])
        try await smartLinkEventually("the call") { resolver.waitingNames == [":e1:"] }

        // apply(.replace) gave the block a new id: the running call survives.
        EmojiAttachment.move(
            from: EmojiAttachment(coordinator: coordinator, ownerID: "old", keys: [Self.e1]),
            to: EmojiAttachment(coordinator: coordinator, ownerID: "new", keys: [Self.e1])
        )
        #expect(coordinator.attachedLeafIDs == ["new"])
        #expect(coordinator.demandCounts[Self.e1] == 1)
        try await Task.sleep(for: .milliseconds(30))
        #expect(resolver.cancelled.isEmpty)

        // A leaf the smart-link coordinator already feeds gains an emoji
        // coordinator (installed later): it starts with the visibility the
        // other one knows, so a leaf on screen asks at once.
        let other = ScriptedEmojiResolver()
        let installed = Self.coordinator(other)
        EmojiAttachment.move(
            from: EmojiAttachment(coordinator: nil, ownerID: "p", keys: []),
            to: EmojiAttachment(coordinator: installed, ownerID: "p", keys: [Self.e2]),
            otherVisible: true, otherFullyVisible: true
        )
        try await smartLinkEventually("asked at once") { other.waitingNames == [":e2:"] }
        resolver.answer(":e1:", .success(Self.image()))
        other.answer(":e2:", .success(Self.image()))
    }
}
