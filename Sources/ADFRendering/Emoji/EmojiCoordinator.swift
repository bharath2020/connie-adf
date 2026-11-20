import Foundation
import Observation
import SwiftUI
import ADFPreparation

/// The observable stage of one custom-emoji key: the only observable state
/// of the feature. Leaves whose owner shows the key read it
/// (`EmojiCoordinator.displayStages`), so a stage change invalidates exactly
/// those leaves, and the coordinator writes it at most once per real change.
@Observable @MainActor
final class EmojiEntry {
    private(set) var stage: EmojiStage = .pending

    /// An outcome kept without publishing it (not observed: storing it
    /// redraws nothing): it landed while the document scrolled and a leaf
    /// showing the key was not fully on screen (the smart-link landing
    /// rule, ADR §22). A leaf drawing the key for the first time draws it;
    /// a leaf that already drew the key keeps what it drew until it is
    /// published, so nothing reflows mid-scroll.
    @ObservationIgnored private(set) var held: EmojiStage?

    /// Writes `stage` only when it changes, so an unchanged write
    /// invalidates no reader.
    func publish(_ stage: EmojiStage) {
        guard stage != self.stage else { return }
        self.stage = stage
    }

    /// Keeps an outcome without publishing it.
    func hold(_ outcome: EmojiStage) {
        held = outcome
    }

    /// Publishes the held outcome as the stage. `false` when nothing was
    /// held.
    @discardableResult
    func publishHeld() -> Bool {
        guard let outcome = held else { return false }
        held = nil
        publish(outcome)
        return true
    }

    /// Back to `.pending` (a new document). Leaves that drew a held outcome
    /// did so without observing a change, so every reader is notified when
    /// one is dropped.
    func reset() {
        if held != nil {
            held = nil
            withMutation(keyPath: \.stage) {}
        }
        publish(.pending)
    }
}

/// How the emoji coordinator waits and how much it runs at once. Injectable
/// so tests drive the dwell by hand.
struct EmojiTiming: Sendable {
    /// How long a key must stay in demand before its lookup starts: a fling
    /// past an emoji starts nothing. Zero starts at once.
    var dwell: Duration = .milliseconds(150)
    /// Lookups running at once; the rest queue in the order their dwell
    /// ended.
    var maxConcurrent = 4
    /// Waits out a dwell; throws when its task is cancelled.
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
}

/// The custom-emoji counters of one document model, cumulative across its
/// loads except `inFlight` (diagnostics and tests).
/// `resolverCalls == resolved + failed + cancellations + inFlight`.
@_spi(ADFDiagnostics)
public struct ADFEmojiStats: Sendable, Hashable {
    /// Calls made to the host's resolver.
    public var resolverCalls = 0
    /// Calls cancelled (their emoji left the screen, or the document was
    /// reloaded) before the resolver returned, counted when they ended.
    public var cancellations = 0
    /// Calls running now, including cancelled calls whose task has not
    /// ended (each holds a slot until it does).
    public var inFlight = 0
    /// Calls that returned an image.
    public var resolved = 0
    /// Calls that threw.
    public var failed = 0
    /// Outcomes held back because the document was scrolling and a leaf
    /// showing the key was not fully on screen.
    public var held = 0
    /// Text-leaf evaluations that drew a different emoji display than the
    /// same leaf drew before: the redraws custom emoji caused. A leaf's
    /// first draw is not counted.
    public var leafRefreshes = 0

    public init() {}
}

/// Per-document custom-emoji lookups (design `adf-res1` §4.3, §4.6), owned
/// by `ADFDocumentModel` and reached by leaves through `adfEmoji` while the
/// host installed an `ADFEmojiResolver`. A small copy of the demand core of
/// `SmartLinkCoordinator` (ADR §22): no resolution modes, no nearby
/// prefetch, no loading look.
///
/// - Text leaves whose owner shows custom emoji attach on appear and detach
///   on disappear, with their keys, and report their own viewport
///   visibility through the one leaf feed they share with smart links
///   (`textLeafAttachment`).
/// - A key's **demand** is the number of attached leaves holding it that
///   are visible (before iOS 18 / macOS 15, with no feed, every attached
///   leaf counts as visible). A demanded `.pending` key dwells
///   (`EmojiTiming.dwell`), then waits for one of `maxConcurrent` slots,
///   then asks the resolver off the main actor. Other leaves with the same
///   key only add demand: one lookup per key.
/// - Losing all demand drops the dwell or queue place, or cancels the call
///   (the key stays `.pending`, still the box). A cancelled call keeps its
///   slot until its task ends; the key is asked again when it is back on
///   screen.
/// - The image is squared once as it lands (`EmojiDisplay.squared`), so
///   every display of it is the same bitmap.
/// - Landing (the smart-link rule): while the document scrolls, an outcome
///   is published only when every attached leaf holding the key is fully on
///   screen; otherwise it is held (`EmojiEntry.held`) until they are, or
///   until scrolling stops. A failure changes the emoji's width (box →
///   short name), so it must not reflow a leaf straddling the screen's
///   edge; an image lands in the box it replaces.
/// - `.resolved` and `.failed` are terminal until `reset()` (`load`), which
///   bumps the generation: every task is cancelled and late results are
///   dropped.
///
/// Not observable: visibility, attach and scroll-phase callbacks write plain
/// stored properties, and the only observable state (`EmojiEntry.stage`)
/// changes at most once per real stage change (§16/§20). Results never go
/// through `model.apply`.
@MainActor
final class EmojiCoordinator {
    /// The host's resolver (`ADFDocumentView(emojiResolver:)`). `nil`: the
    /// coordinator does no work (and the view injects no coordinator, so
    /// every custom emoji shows its short name).
    var resolver: (any ADFEmojiResolver)?
    var timing: EmojiTiming
    /// Whether leaves report visibility (iOS 18 / macOS 15 and later).
    /// Without a feed an attached leaf counts as visible and nothing is
    /// held.
    var hasVisibilityFeed: Bool

    /// Bumped by `reset()`; a lookup from an older generation never lands.
    private(set) var generation = 0
    private var counters = ADFEmojiStats()
    /// Emoji redraws per owner (see `ADFEmojiStats.leafRefreshes`).
    private(set) var leafRefreshesByOwner: [String: Int] = [:]

    /// Never removed (only reset to `.pending`): a leaf that survives a
    /// reload keeps observing the same entry object.
    private var entries: [EmojiKey: EmojiEntry] = [:]

    private struct Leaf {
        var keys: [EmojiKey]
        /// Attachments under this leaf id still live (appear/disappear can
        /// overlap when a view is replaced).
        var count: Int
    }
    private var leaves: [String: Leaf] = [:]
    /// The last visibility each leaf reported. A report may arrive before
    /// the leaf attaches; it is forgotten when the leaf detaches.
    private var leafVisibility: [String: Bool] = [:]
    /// Leaves whose last full-visibility report said all of the leaf is on
    /// screen.
    private var fullyVisible: Set<String> = []
    private var demand: [EmojiKey: Int] = [:]

    private enum Phase {
        case dwelling(Task<Void, Never>?)
        case queued
        case running(Task<Void, Never>)
        /// Cancelled (demand ended, or `reset`), still holding its slot
        /// until the resolver's task ends; its result is dropped.
        case stopping(Task<Void, Never>)

        var task: Task<Void, Never>? {
            switch self {
            case .dwelling(let task): return task
            case .queued: return nil
            case .running(let task), .stopping(let task): return task
            }
        }
    }
    private struct Lookup {
        let id: Int
        let generation: Int
        var phase: Phase
    }
    private var lookups: [EmojiKey: Lookup] = [:]
    private var queue: [EmojiKey] = []
    /// Slots in use: calls running or stopping.
    private var running = 0
    private var nextLookupID = 0
    /// What each owner's leaf last drew, per key, for `leafRefreshes` and
    /// for held outcomes (`displayStages`). Forgotten when the owner's leaf
    /// detaches, so a leaf built later draws as a new one.
    private var shown: [String: [EmojiKey: EmojiStage]] = [:]
    /// The document's scroll view is not idle (`scrollPhaseChanged`).
    private(set) var isScrolling = false

    init(timing: EmojiTiming = EmojiTiming(), hasVisibilityFeed: Bool? = nil) {
        self.timing = timing
        if let hasVisibilityFeed {
            self.hasVisibilityFeed = hasVisibilityFeed
        } else if #available(iOS 18.0, macOS 15.0, *) {
            self.hasVisibilityFeed = true
        } else {
            self.hasVisibilityFeed = false
        }
    }

    deinit {
        // The document is gone: stop every dwell and resolver call. Their
        // tasks hold the coordinator weakly, so nothing lands afterwards.
        for lookup in lookups.values {
            lookup.phase.task?.cancel()
        }
    }

    /// The counters, with `inFlight` read off the current state.
    var stats: ADFEmojiStats {
        var stats = counters
        stats.inFlight = running
        return stats
    }

    // MARK: Reading (leaves)

    /// The entry for `key`, created on first use.
    func entry(for key: EmojiKey) -> EmojiEntry {
        if let entry = entries[key] { return entry }
        let entry = EmojiEntry()
        entries[key] = entry
        return entry
    }

    /// The stage of `key` (an observation dependency on that entry only).
    func stage(for key: EmojiKey) -> EmojiStage {
        entry(for: key).stage
    }

    /// The stages of `keys`, read in a leaf's `body`: reading every entry is
    /// the leaf's observation dependency on exactly its own keys. Also
    /// counts the leaf's emoji redraw for `owner`.
    ///
    /// A key still `.pending` with a held outcome draws that outcome in a
    /// leaf drawing the key for the first time (a leaf built after it
    /// landed has its final width on its first frame); a leaf that already
    /// drew the key keeps what it drew until the outcome is published, so a
    /// redraw for another reason never reflows it mid-scroll.
    func displayStages(for keys: [EmojiKey], owner: String?) -> [EmojiKey: EmojiStage] {
        let previous = owner.flatMap { shown[$0] }
        var stages: [EmojiKey: EmojiStage] = [:]
        stages.reserveCapacity(keys.count)
        for key in keys {
            let entry = entry(for: key)
            var stage = entry.stage
            if stage == .pending, let held = entry.held {
                stage = previous?[key] ?? held
            }
            stages[key] = stage
        }
        if let owner { noteDrawn(owner: owner, stages) }
        return stages
    }

    private func noteDrawn(owner: String, _ drawn: [EmojiKey: EmojiStage]) {
        guard let previous = shown[owner] else {
            shown[owner] = drawn
            return
        }
        guard previous != drawn else { return }
        shown[owner] = drawn
        counters.leafRefreshes += 1
        leafRefreshesByOwner[owner, default: 0] += 1
    }

    // MARK: Leaves

    /// A text leaf whose owner shows custom emoji appeared (`onAppear`).
    /// `visible` and `fullyVisible` carry the visibility already known for
    /// this leaf (its view moved here from another owner id or
    /// coordinator); a report the leaf already made wins.
    func attach(leaf id: String, keys: [EmojiKey], visible: Bool? = nil, fullyVisible: Bool? = nil) {
        guard resolver != nil, !keys.isEmpty else { return }
        if hasVisibilityFeed, leafVisibility[id] == nil {
            if let visible { leafVisibility[id] = visible }
            if fullyVisible == true { self.fullyVisible.insert(id) }
        }
        if var leaf = leaves[id] {
            leaf.count += 1
            leaves[id] = leaf
            update(leaf: id, keys: keys)
            return
        }
        leaves[id] = Leaf(keys: keys, count: 1)
        if isVisible(id) { addDemand(keys) }
    }

    /// A live leaf's keys changed (its owner's content was replaced under a
    /// stable identity). Keys in both lists keep their demand throughout.
    func update(leaf id: String, keys: [EmojiKey]) {
        guard resolver != nil else { return }
        guard var leaf = leaves[id] else {
            attach(leaf: id, keys: keys)
            return
        }
        guard leaf.keys != keys else { return }
        let old = leaf.keys
        leaf.keys = keys
        leaves[id] = leaf
        if isVisible(id) {
            addDemand(keys)
            removeDemand(old)
        }
        // The leaf no longer holds back the outcomes of the keys it dropped.
        releaseHeld(old)
    }

    /// A leaf disappeared (`onDisappear`). Once its last attachment goes,
    /// its visibility and what it drew are forgotten too.
    func detach(leaf id: String) {
        guard var leaf = leaves[id] else { return }
        leaf.count -= 1
        guard leaf.count <= 0 else {
            leaves[id] = leaf
            return
        }
        let wasVisible = isVisible(id)
        leaves[id] = nil
        leafVisibility[id] = nil
        fullyVisible.remove(id)
        shown[id] = nil
        if wasVisible { removeDemand(leaf.keys) }
        releaseHeld(leaf.keys)
    }

    /// A leaf's viewport visibility (any point of it on screen), reported on
    /// every crossing: a dictionary write and, only for an attached leaf
    /// whose visibility changed, demand bookkeeping.
    func setLeafVisible(_ id: String, _ visible: Bool) {
        guard resolver != nil, hasVisibilityFeed else { return }
        let wasVisible = leafVisibility[id] == true
        guard let keys = leaves[id]?.keys else {
            // Not attached (yet): keep a `true` for the attach that follows.
            leafVisibility[id] = visible ? true : nil
            return
        }
        leafVisibility[id] = visible
        guard wasVisible != visible else { return }
        if visible { addDemand(keys) } else { removeDemand(keys) }
    }

    /// Whether all of a leaf is on screen, reported on every crossing. When
    /// an attached leaf comes fully on screen, the outcomes it held back
    /// are published if no other leaf holds them back.
    func setLeafFullyVisible(_ id: String, _ fully: Bool) {
        guard resolver != nil, hasVisibilityFeed else { return }
        guard fully else {
            fullyVisible.remove(id)
            return
        }
        guard fullyVisible.insert(id).inserted, let keys = leaves[id]?.keys else { return }
        releaseHeld(keys)
    }

    /// The visibility this coordinator knows for a leaf: `nil` when it has
    /// had no report (or tracks nothing: no feed).
    func knownVisibility(of id: String) -> Bool? {
        guard hasVisibilityFeed else { return nil }
        return leafVisibility[id]
    }

    /// Whether this coordinator knows all of a leaf to be on screen: `nil`
    /// when it tracks nothing (no feed).
    func knownFullVisibility(of id: String) -> Bool? {
        guard hasVisibilityFeed else { return nil }
        return fullyVisible.contains(id)
    }

    private func isVisible(_ id: String) -> Bool {
        !hasVisibilityFeed || leafVisibility[id] == true
    }

    // MARK: Landing (the smart-link rule)

    /// Whether an outcome for `key` may be published now: at rest, or
    /// without a feed, always; while the document scrolls, only when every
    /// attached leaf holding the key is fully on screen.
    private func mayPublish(_ key: EmojiKey) -> Bool {
        guard hasVisibilityFeed, isScrolling else { return true }
        return !leaves.contains { id, leaf in !fullyVisible.contains(id) && leaf.keys.contains(key) }
    }

    /// Publishes the held outcomes among `keys` that are in demand and may
    /// be published now.
    private func releaseHeld(_ keys: some Sequence<EmojiKey>) {
        for key in keys where demand[key] != nil && entries[key]?.held != nil && mayPublish(key) {
            entries[key]?.publishHeld()
        }
    }

    /// A lookup's outcome: published, or held while the document scrolls
    /// and a leaf holding the key is not fully on screen.
    private func land(_ key: EmojiKey, _ outcome: EmojiStage) {
        let entry = entry(for: key)
        if mayPublish(key) {
            entry.publish(outcome)
        } else {
            entry.hold(outcome)
            counters.held += 1
        }
    }

    /// The document's scroll view changed phase (`onScrollPhaseChange`, iOS
    /// 18 / macOS 15): `scrolling` is any phase but idle. Writes a plain
    /// Bool; at rest the held outcomes of keys on screen are published.
    func scrollPhaseChanged(scrolling: Bool) {
        guard resolver != nil, scrolling != isScrolling else { return }
        isScrolling = scrolling
        if !scrolling { releaseHeld(Array(demand.keys)) }
    }

    // MARK: Demand

    private func addDemand(_ keys: [EmojiKey]) {
        for key in keys {
            let count = demand[key, default: 0] + 1
            demand[key] = count
            if count == 1 { demandStarted(key) }
        }
    }

    private func removeDemand(_ keys: [EmojiKey]) {
        for key in keys {
            guard let count = demand[key] else { continue }
            if count > 1 {
                demand[key] = count - 1
            } else {
                demand[key] = nil
                demandEnded(key)
            }
        }
    }

    /// Demand appeared for `key`: a held outcome is published if it may be
    /// (else it waits for full visibility or rest); a `.pending` key without
    /// a lookup dwells. A key whose cancelled call is still stopping waits
    /// for it to end (`finish` starts it again then).
    private func demandStarted(_ key: EmojiKey) {
        guard resolver != nil, lookups[key] == nil else { return }
        let entry = entry(for: key)
        if entry.held != nil {
            if mayPublish(key) { entry.publishHeld() }
            return
        }
        guard entry.stage == .pending else { return }
        nextLookupID += 1
        let id = nextLookupID
        guard timing.dwell > .zero else {
            lookups[key] = Lookup(id: id, generation: generation, phase: .dwelling(nil))
            dwellEnded(key, id: id)
            return
        }
        let sleep = timing.sleep
        let dwell = timing.dwell
        let task = Task { [weak self] in
            do { try await sleep(dwell) } catch { return }
            guard !Task.isCancelled else { return }
            self?.dwellEnded(key, id: id)
        }
        lookups[key] = Lookup(id: id, generation: generation, phase: .dwelling(task))
    }

    /// Demand for `key` dropped to zero: drop its dwell or queue place, or
    /// cancel its call (the key stays `.pending`; the slot frees when the
    /// call's task ends). A held outcome stays held.
    private func demandEnded(_ key: EmojiKey) {
        guard let lookup = lookups[key] else { return }
        switch lookup.phase {
        case .dwelling(let task):
            task?.cancel()
            lookups[key] = nil
        case .queued:
            queue.removeAll { $0 == key }
            lookups[key] = nil
        case .running(let task):
            task.cancel()
            lookups[key]?.phase = .stopping(task)
        case .stopping:
            break
        }
    }

    private func dwellEnded(_ key: EmojiKey, id: Int) {
        guard let lookup = lookups[key], lookup.id == id, case .dwelling = lookup.phase else { return }
        if running < max(timing.maxConcurrent, 1) {
            start(key, id: id)
        } else {
            lookups[key]?.phase = .queued
            queue.append(key)
        }
    }

    private func startQueued() {
        while let key = queue.first, running < max(timing.maxConcurrent, 1) {
            queue.removeFirst()
            guard let lookup = lookups[key], case .queued = lookup.phase else { continue }
            start(key, id: lookup.id)
        }
    }

    private func start(_ key: EmojiKey, id: Int) {
        guard let resolver else {
            lookups[key] = nil
            return
        }
        running += 1
        counters.resolverCalls += 1
        let reference = key.reference
        // Detached: the resolver and the squaring run off the main actor;
        // only the outcome hops back. Cancelling this task cancels the
        // resolver's work.
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: EmojiStage
            do {
                outcome = .resolved(EmojiDisplay.squared(try await resolver.image(for: reference)))
            } catch {
                outcome = .failed
            }
            await self?.finish(key, id: id, outcome: outcome)
        }
        lookups[key] = Lookup(id: id, generation: generation, phase: .running(task))
    }

    /// A call's task ended. A current call lands its outcome; a cancelled
    /// one (stopping, possibly from an older generation) only frees its
    /// slot, and its key starts over if it is in demand again.
    private func finish(_ key: EmojiKey, id: Int, outcome: EmojiStage) {
        guard let lookup = lookups[key], lookup.id == id else { return }
        switch lookup.phase {
        case .running where lookup.generation == generation:
            lookups[key] = nil
            running -= 1
            if case .resolved = outcome { counters.resolved += 1 } else { counters.failed += 1 }
            land(key, outcome)
            startQueued()
        case .running, .stopping:
            lookups[key] = nil
            running -= 1
            counters.cancellations += 1
            // The freed slot goes to the queue first; the key, if wanted
            // again meanwhile, starts over behind it.
            startQueued()
            if demand[key] != nil { demandStarted(key) }
        case .dwelling, .queued:
            return
        }
    }

    // MARK: Reload

    /// A new document is loading (`ADFDocumentModel.load`): bump the
    /// generation, cancel every dwell, queue place and call, and return
    /// every entry to `.pending` (dropping held outcomes). Cancelled calls
    /// keep their slots until their tasks end. Leaves and their visibility
    /// are kept (they describe live views), and keys still in demand start
    /// over. The scroll phase is the view's, so it is kept too.
    func reset() {
        generation += 1
        for (key, lookup) in lookups {
            switch lookup.phase {
            case .dwelling(let task):
                task?.cancel()
                lookups[key] = nil
            case .queued:
                lookups[key] = nil
            case .running(let task):
                task.cancel()
                lookups[key]?.phase = .stopping(task)
            case .stopping:
                break
            }
        }
        queue = []
        shown = [:]
        for entry in entries.values { entry.reset() }
        for key in demand.keys.sorted(by: { $0.description < $1.description }) {
            demandStarted(key)
        }
    }

    // MARK: Test hooks

    /// Keys with a dwell, queue place or call (tests).
    var pendingKeys: Set<EmojiKey> { Set(lookups.keys) }
    /// Keys waiting for a slot, in order (tests).
    var queuedKeys: [EmojiKey] { queue }
    /// Current demand per key (tests).
    var demandCounts: [EmojiKey: Int] { demand }
    /// Attached leaf ids (tests).
    var attachedLeafIDs: Set<String> { Set(leaves.keys) }
    /// The held (unpublished) outcome of `key` (tests).
    func heldStage(for key: EmojiKey) -> EmojiStage? { entries[key]?.held }
}

private struct ADFEmojiKey: EnvironmentKey {
    static let defaultValue: EmojiCoordinator? = nil
}

extension EnvironmentValues {
    /// The document's custom-emoji coordinator, injected by `ADFDocumentView`
    /// while it has an emoji resolver (the reference never changes, so
    /// injecting it invalidates nothing). `nil` outside a document view or
    /// without a resolver: custom emoji show their short names and leaves
    /// add nothing for them.
    var adfEmoji: EmojiCoordinator? {
        get { self[ADFEmojiKey.self] }
        set { self[ADFEmojiKey.self] = newValue }
    }
}
