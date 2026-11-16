import Foundation
import Observation
import SwiftUI
import ADFPreparation

/// Why a lookup left its link plain (a terminal stage, drawn as `.plain`).
enum SmartLinkFailure: Hashable, Sendable {
    case unauthorized
    case notFound
    /// The resolver returned a title that is empty once cleaned
    /// (`SmartLinkDisplay.cleanedTitle`): nothing to show beside an icon.
    case emptyTitle
    /// Any other error the resolver threw.
    case other
}

/// A smart link's stage in one loaded document (design §2):
///
/// ```
///             leaf visible + dwell            resolver returns
///  .plain ───────────────────────▶ .resolving ─────────────────▶ .resolved   (terminal)
///    ▲                               │   │ resolver throws, or an empty title
///    │  demand drops to 0 (cancel)   │   └──────────────────────▶ .failed     (terminal, drawn plain)
///    └───────────────────────────────┘
/// ```
enum SmartLinkStage: Hashable, Sendable {
    /// The link as prepared (URL text, or an inline card's host; link
    /// colour). Also the stage of a cancelled lookup: cancellation is not
    /// failure, the next appearance retries.
    case plain
    /// A lookup is running: the same text, link colour at reduced opacity.
    case resolving
    /// An icon and the title, linking to the same URL.
    case resolved(ADFSmartLinkMetadata)
    /// The resolver threw, or its title was empty: drawn exactly as
    /// `.plain`, never asked again in this document.
    case failed(SmartLinkFailure)

    /// Whether the stage draws something other than the prepared text.
    var changesDisplay: Bool {
        switch self {
        case .resolving, .resolved: return true
        case .plain, .failed: return false
        }
    }

    /// The stage as drawn: `.failed` draws as `.plain`.
    var displayed: SmartLinkStage { changesDisplay ? self : .plain }
}

/// The observable stage of one smart-link key: the only observable state of
/// the feature. Leaves whose owner contains the key read it, so a stage
/// change invalidates exactly those leaves (the `SearchOwnerHighlights`
/// pattern), and the coordinator writes it at most once per real change.
@Observable @MainActor
final class SmartLinkEntry {
    private(set) var stage: SmartLinkStage = .plain

    /// Writes `stage` only when it changes, so an unchanged write
    /// invalidates no reader.
    func publish(_ stage: SmartLinkStage) {
        guard stage != self.stage else { return }
        self.stage = stage
    }
}

/// How the coordinator waits and how much it runs at once. Injectable so
/// tests drive the dwell by hand.
struct SmartLinkTiming: Sendable {
    /// How long a key must stay in demand before its lookup starts. Free to
    /// cancel: a fling past a link starts nothing. Zero starts at once.
    var dwell: Duration = .milliseconds(150)
    /// Lookups running at once; the rest queue in the order their dwell
    /// ended.
    var maxConcurrent = 4
    /// Waits out a dwell; throws when its task is cancelled.
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
}

/// The smart-link counters of one document model, cumulative across its
/// loads except `inFlight` (diagnostics: the demo's About sheet and tests).
/// `resolverCalls == resolved + failed + cancellations + inFlight`.
@_spi(ADFDiagnostics)
public struct ADFSmartLinkStats: Sendable, Hashable {
    /// Calls made to the host's resolver.
    public var resolverCalls = 0
    /// Calls cancelled because their link left the screen (or the document
    /// was reloaded) before the resolver returned, counted when the
    /// cancelled call has ended.
    public var cancellations = 0
    /// Calls running now, including cancelled calls whose task has not
    /// ended yet (each holds one of the four slots until it does).
    public var inFlight = 0
    /// Calls that returned a title.
    public var resolved = 0
    /// Calls that threw, or returned a title that is empty once cleaned.
    public var failed = 0
    /// Text-leaf evaluations that drew a different smart-link display
    /// (plain, resolving, resolved) than the same leaf drew before: the
    /// redraws smart links caused. A leaf's first draw is not counted.
    public var leafRefreshes = 0

    public init() {}
}

/// Per-document smart-link resolution, owned by `ADFDocumentModel` and
/// reached by leaves through `adfSmartLinks` (design §4).
///
/// - Text leaves whose owner has smart links attach on appear and detach on
///   disappear, with their keys (`SmartLinkTextLeaf.smartLinkAttachment`),
///   and each reports its own viewport visibility (`setLeafVisible`, from
///   the leaf's 0.01-threshold `onScrollVisibilityChange`). Visibility is
///   per leaf, not per row: a tall list row resolves only the items on
///   screen. Detaching (render-region exit) forgets the leaf's visibility,
///   the backstop for a feed that never reports a final `false`.
/// - A key's **demand** is the number of attached leaves holding it that
///   are visible. Before iOS 18 / macOS 15 (no visibility feed) an attached
///   leaf counts as visible.
/// - A demanded `.plain` key dwells (`SmartLinkTiming.dwell`), then waits
///   for one of `maxConcurrent` slots, then goes `.resolving` and asks the
///   resolver. Losing all demand drops the dwell or queue place, or cancels
///   the call and returns the key to `.plain`. A cancelled call keeps its
///   slot until its task actually ends, so a resolver slow to stop can
///   never push the calls past `maxConcurrent`, nor run two calls for one
///   URL: a key asked for again meanwhile restarts once the old call ends.
/// - `.resolved` and `.failed` are terminal until `reset()` (`load`), which
///   bumps the generation: every task is cancelled and late results are
///   dropped (block IDs repeat across documents).
///
/// Not observable: visibility and attach callbacks write plain
/// dictionaries, and observable state (`SmartLinkEntry.stage`) changes at
/// most once per real stage change — never per visibility crossing (the
/// §16/§20 livelocks: a visibility callback must write no view state).
@MainActor
final class SmartLinkCoordinator {
    /// The host's resolver (`ADFDocumentView(smartLinkResolver:)`). `nil`:
    /// every link stays plain and the coordinator does no work.
    var resolver: (any ADFSmartLinkResolver)?
    var timing: SmartLinkTiming
    /// Whether leaves report visibility (iOS 18 / macOS 15 and later).
    /// Without a feed an attached leaf counts as visible.
    var hasVisibilityFeed: Bool

    /// Bumped by `reset()`; a lookup from an older generation never lands.
    private(set) var generation = 0
    private(set) var stats = ADFSmartLinkStats()
    /// Smart-link redraws per owner (see `ADFSmartLinkStats.leafRefreshes`).
    private(set) var leafRefreshesByOwner: [String: Int] = [:]

    /// Never removed (only reset to `.plain`): a leaf that survives a reload
    /// keeps observing the same entry object.
    private var entries: [SmartLinkKey: SmartLinkEntry] = [:]

    private struct Leaf {
        var keys: [SmartLinkKey]
        /// Attachments under this leaf id still live (appear/disappear can
        /// overlap when a view is replaced).
        var count: Int
    }
    private var leaves: [String: Leaf] = [:]
    /// The last visibility each leaf reported, by leaf id. A report may
    /// arrive before the leaf attaches; it is forgotten when the leaf
    /// detaches (and a `false` for a detached leaf is not kept).
    private var leafVisibility: [String: Bool] = [:]
    private var demand: [SmartLinkKey: Int] = [:]

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
    private var lookups: [SmartLinkKey: Lookup] = [:]
    private var queue: [SmartLinkKey] = []
    /// Slots in use: calls running or stopping.
    private var running = 0
    private var nextLookupID = 0
    /// What each owner's leaf last drew, for `leafRefreshes`.
    private var shown: [String: [SmartLinkStage]] = [:]

    init(timing: SmartLinkTiming = SmartLinkTiming(), hasVisibilityFeed: Bool? = nil) {
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

    // MARK: Reading (leaves)

    /// The entry for `key`, created on first use.
    func entry(for key: SmartLinkKey) -> SmartLinkEntry {
        if let entry = entries[key] { return entry }
        let entry = SmartLinkEntry()
        entries[key] = entry
        return entry
    }

    /// The stage of `key` (an observation dependency on that entry only).
    func stage(for key: SmartLinkKey) -> SmartLinkStage {
        entry(for: key).stage
    }

    /// The stages among `keys` that change the display, read in a leaf's
    /// `body`: reading every entry is the leaf's observation dependency on
    /// exactly its own keys. Empty when every key draws as prepared. Also
    /// counts the leaf's smart-link redraw for `owner`.
    func displayStages(for keys: [SmartLinkKey], owner: String?) -> [SmartLinkKey: SmartLinkStage] {
        var stages: [SmartLinkKey: SmartLinkStage] = [:]
        var drawn: [SmartLinkStage] = []
        drawn.reserveCapacity(keys.count)
        for key in keys {
            let stage = entry(for: key).stage.displayed
            drawn.append(stage)
            if stage.changesDisplay { stages[key] = stage }
        }
        if let owner { noteDrawn(owner: owner, drawn) }
        return stages
    }

    private func noteDrawn(owner: String, _ drawn: [SmartLinkStage]) {
        guard let previous = shown[owner] else {
            shown[owner] = drawn
            return
        }
        guard previous != drawn else { return }
        shown[owner] = drawn
        stats.leafRefreshes += 1
        leafRefreshesByOwner[owner, default: 0] += 1
    }

    // MARK: Leaf body diagnostics

    /// Records text-leaf body evaluations per owner while on (tests; off by
    /// default, when each leaf pays one Bool check). Unlike
    /// `leafRefreshes`, it counts every leaf of this document, with smart
    /// links or not, so a test can prove that leaves without the changed
    /// link did not run their bodies at all. Turning it on starts empty.
    var recordsLeafBodies = false {
        didSet {
            leafBodiesByOwner = [:]
            engineLeafBodiesByOwner = [:]
        }
    }
    /// `SegmentedTextView` bodies (SwiftUI-drawn text) per owner.
    private(set) var leafBodiesByOwner: [String: Int] = [:]
    /// `SmartLinkTextLeaf` bodies (every paragraph, heading and list
    /// leader, before the engine choice) per owner.
    private(set) var engineLeafBodiesByOwner: [String: Int] = [:]

    /// One text-leaf body evaluation for `owner` (see `recordsLeafBodies`).
    func noteLeafBody(_ owner: String?, engine: Bool) {
        guard recordsLeafBodies, let owner else { return }
        if engine {
            engineLeafBodiesByOwner[owner, default: 0] += 1
        } else {
            leafBodiesByOwner[owner, default: 0] += 1
        }
    }

    // MARK: Leaves

    /// A text leaf whose owner has smart links appeared (`onAppear`).
    /// `visible` carries a visibility already known for this leaf (its
    /// view moved here from another owner id or coordinator,
    /// `SmartLinkTextLeaf`); a report the leaf already made wins.
    func attach(leaf id: String, keys: [SmartLinkKey], visible: Bool? = nil) {
        guard resolver != nil, !keys.isEmpty else { return }
        if hasVisibilityFeed, leafVisibility[id] == nil, let visible {
            leafVisibility[id] = visible
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
    /// stable identity). Keys in both lists keep their demand throughout,
    /// so their lookups are not cancelled and restarted.
    func update(leaf id: String, keys: [SmartLinkKey]) {
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
    }

    /// A leaf disappeared (`onDisappear`). Once its last attachment goes,
    /// its visibility is forgotten too (the render-region backstop).
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
        if wasVisible { removeDemand(leaf.keys) }
    }

    /// A leaf's viewport visibility (any point of it on screen), reported on
    /// every crossing during a scroll: a dictionary write and, only for an
    /// attached leaf whose visibility changed, demand bookkeeping.
    func setLeafVisible(_ id: String, _ visible: Bool) {
        guard resolver != nil, hasVisibilityFeed else { return }
        let wasVisible = leafVisibility[id] == true
        guard let keys = leaves[id]?.keys else {
            // Not attached (yet): keep a `true` for the attach that
            // follows; a `false` needs no record.
            leafVisibility[id] = visible ? true : nil
            return
        }
        leafVisibility[id] = visible
        guard wasVisible != visible else { return }
        if visible { addDemand(keys) } else { removeDemand(keys) }
    }

    /// The visibility this coordinator knows for a leaf: `nil` when it has
    /// had no report (or tracks nothing: no resolver, no feed).
    func knownVisibility(of id: String) -> Bool? {
        guard hasVisibilityFeed else { return nil }
        return leafVisibility[id]
    }

    private func isVisible(_ id: String) -> Bool {
        !hasVisibilityFeed || leafVisibility[id] == true
    }

    // MARK: Demand

    private func addDemand(_ keys: [SmartLinkKey]) {
        for key in keys {
            let count = demand[key, default: 0] + 1
            demand[key] = count
            if count == 1 { demandStarted(key) }
        }
    }

    private func removeDemand(_ keys: [SmartLinkKey]) {
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

    /// Demand appeared for `key`: a `.plain` key without a lookup dwells. A
    /// key whose cancelled call is still stopping waits for it to end
    /// (`finish` starts it again then).
    private func demandStarted(_ key: SmartLinkKey) {
        guard resolver != nil, lookups[key] == nil, entry(for: key).stage == .plain else { return }
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
    /// cancel its call (back to `.plain`; the slot frees when the call's
    /// task ends).
    private func demandEnded(_ key: SmartLinkKey) {
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
            entry(for: key).publish(.plain)
        case .stopping:
            break
        }
    }

    private func dwellEnded(_ key: SmartLinkKey, id: Int) {
        guard let lookup = lookups[key], lookup.id == id, case .dwelling = lookup.phase else { return }
        if running < max(timing.maxConcurrent, 1) {
            start(key, id: id)
        } else {
            lookups[key]?.phase = .queued
            queue.append(key)
        }
    }

    private func startQueued() {
        while running < max(timing.maxConcurrent, 1), !queue.isEmpty {
            let key = queue.removeFirst()
            guard let lookup = lookups[key], case .queued = lookup.phase else { continue }
            start(key, id: lookup.id)
        }
    }

    private func start(_ key: SmartLinkKey, id: Int) {
        guard let resolver else {
            lookups[key] = nil
            return
        }
        running += 1
        stats.inFlight = running
        stats.resolverCalls += 1
        entry(for: key).publish(.resolving)
        let url = key.url
        // Detached: the resolver runs off the main actor, and so does title
        // cleaning; only the outcome hops back. Cancelling this task
        // cancels the resolver's work.
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: SmartLinkStage
            do {
                outcome = Self.outcome(for: try await resolver.resolve(url))
            } catch {
                outcome = .failed(Self.failure(for: error))
            }
            await self?.finish(key, id: id, outcome: outcome)
        }
        lookups[key] = Lookup(id: id, generation: generation, phase: .running(task))
    }

    /// A call's task ended. A current call lands its outcome; a cancelled
    /// one (stopping, possibly from an older generation) only frees its
    /// slot, and its key starts over if it is in demand again.
    private func finish(_ key: SmartLinkKey, id: Int, outcome: SmartLinkStage) {
        guard let lookup = lookups[key], lookup.id == id else { return }
        switch lookup.phase {
        case .running where lookup.generation == generation:
            lookups[key] = nil
            running -= 1
            stats.inFlight = running
            if case .resolved = outcome { stats.resolved += 1 } else { stats.failed += 1 }
            entry(for: key).publish(outcome)
        case .running, .stopping:
            lookups[key] = nil
            running -= 1
            stats.inFlight = running
            stats.cancellations += 1
            // The freed slot goes to the queue first; the key, if wanted
            // again meanwhile, starts over behind it.
            startQueued()
            if demand[key] != nil { demandStarted(key) }
            return
        case .dwelling, .queued:
            return
        }
        startQueued()
    }

    /// What a returned lookup shows: its title cleaned for display
    /// (`SmartLinkDisplay.cleanedTitle`), or a failure when nothing is left.
    nonisolated static func outcome(for metadata: ADFSmartLinkMetadata) -> SmartLinkStage {
        guard let title = SmartLinkDisplay.cleanedTitle(metadata.title) else {
            return .failed(.emptyTitle)
        }
        return .resolved(ADFSmartLinkMetadata(title: title, icon: metadata.icon))
    }

    nonisolated private static func failure(for error: any Error) -> SmartLinkFailure {
        switch error as? ADFSmartLinkError {
        case .unauthorized: return .unauthorized
        case .notFound: return .notFound
        case nil: return .other
        }
    }

    // MARK: Reload

    /// A new document is loading (`ADFDocumentModel.load`): bump the
    /// generation, cancel every dwell, queue place and call, and return
    /// every entry to `.plain`. Cancelled calls keep their slots until their
    /// tasks end. Leaves and their visibility are kept — they describe live
    /// views, which detach (or, under a reused identity, stay and are asked
    /// about again) on their own — and keys still in demand start over.
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
        for entry in entries.values { entry.publish(.plain) }
        for key in demand.keys.sorted(by: { $0.description < $1.description }) {
            demandStarted(key)
        }
    }

    // MARK: Test hooks

    /// Keys with a dwell, queue place or call (tests).
    var pendingKeys: Set<SmartLinkKey> { Set(lookups.keys) }
    /// Keys waiting for a slot, in order (tests).
    var queuedKeys: [SmartLinkKey] { queue }
    /// Current demand per key (tests).
    var demandCounts: [SmartLinkKey: Int] { demand }
    /// Attached leaf ids (tests).
    var attachedLeafIDs: Set<String> { Set(leaves.keys) }
}

private struct ADFSmartLinksKey: EnvironmentKey {
    static let defaultValue: SmartLinkCoordinator? = nil
}

extension EnvironmentValues {
    /// The document's smart-link coordinator, injected by `ADFDocumentView`
    /// (the reference never changes, so injecting it invalidates nothing).
    /// `nil` outside a document view: links stay plain.
    var adfSmartLinks: SmartLinkCoordinator? {
        get { self[ADFSmartLinksKey.self] }
        set { self[ADFSmartLinksKey.self] = newValue }
    }
}
