import Foundation
import Observation
import SwiftUI
import ADFPreparation

/// Why a lookup left its link plain (a terminal stage, drawn as `.plain`).
enum SmartLinkFailure: Hashable, Sendable {
    case unauthorized
    case notFound
    /// Any other error the resolver threw.
    case other
}

/// A smart link's stage in one loaded document (design §2):
///
/// ```
///             row visible + dwell             resolver returns
///  .plain ───────────────────────▶ .resolving ─────────────────▶ .resolved   (terminal)
///    ▲                               │   │ resolver throws
///    │  demand drops to 0 (cancel)   │   └──────────────────────▶ .failed     (terminal, drawn plain)
///    └───────────────────────────────┘
/// ```
enum SmartLinkStage: Hashable, Sendable {
    /// The link as prepared (URL text, link colour). Also the stage of a
    /// cancelled lookup: cancellation is not failure, the next appearance
    /// retries.
    case plain
    /// A lookup is running: the same text, link colour at reduced opacity.
    case resolving
    /// An icon and the title, linking to the same URL.
    case resolved(ADFSmartLinkMetadata)
    /// The resolver threw: drawn exactly as `.plain`, never asked again in
    /// this document.
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
    /// was reloaded) before the resolver returned.
    public var cancellations = 0
    /// Calls running now.
    public var inFlight = 0
    /// Calls that returned a title.
    public var resolved = 0
    /// Calls that threw.
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
/// - Rows report viewport visibility (`setRowVisible`, from the row's
///   0.01-threshold `onScrollVisibilityChange` and `DocumentRow.onDisappear`).
/// - Text leaves whose owner has smart links attach on appear and detach on
///   disappear, with their row (`adfSmartLinkRowID`) and keys.
/// - A key's **demand** is the number of attached leaves holding it whose
///   row is visible. A leaf with no row (a pinned header, a host rendering
///   outside `DocumentRow`) and every leaf before iOS 18 / macOS 15 (no
///   visibility feed) counts as visible once attached.
/// - A demanded `.plain` key dwells (`SmartLinkTiming.dwell`), then waits
///   for one of `maxConcurrent` slots, then goes `.resolving` and asks the
///   resolver. Losing all demand drops the dwell or queue place, or cancels
///   the call and returns the key to `.plain`.
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
    /// Whether rows report visibility (iOS 18 / macOS 15 and later). Without
    /// a feed an attached leaf counts as visible.
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
        var rowID: String?
        var keys: [SmartLinkKey]
        /// Attachments under this leaf id still live (appear/disappear can
        /// overlap when a view is replaced).
        var count: Int
    }
    private var leaves: [String: Leaf] = [:]
    private var leavesByRow: [String: Set<String>] = [:]
    private var visibleRows: Set<String> = []
    private var demand: [SmartLinkKey: Int] = [:]

    private enum Phase {
        case dwelling(Task<Void, Never>?)
        case queued
        case running(Task<Void, Never>)
    }
    private struct Lookup {
        let id: Int
        let generation: Int
        var phase: Phase
    }
    private var lookups: [SmartLinkKey: Lookup] = [:]
    private var queue: [SmartLinkKey] = []
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

    // MARK: Leaves and rows

    /// A text leaf whose owner has smart links appeared (`onAppear`).
    func attach(leaf id: String, row: String?, keys: [SmartLinkKey]) {
        guard resolver != nil, !keys.isEmpty else { return }
        if var leaf = leaves[id] {
            leaf.count += 1
            leaves[id] = leaf
            update(leaf: id, row: row, keys: keys)
            return
        }
        leaves[id] = Leaf(rowID: row, keys: keys, count: 1)
        if let row { leavesByRow[row, default: []].insert(id) }
        if isVisible(row) { addDemand(keys) }
    }

    /// A live leaf's keys or row changed (its owner's content was replaced
    /// under a stable identity).
    func update(leaf id: String, row: String?, keys: [SmartLinkKey]) {
        guard resolver != nil else { return }
        guard var leaf = leaves[id] else {
            attach(leaf: id, row: row, keys: keys)
            return
        }
        guard leaf.rowID != row || leaf.keys != keys else { return }
        if isVisible(leaf.rowID) { removeDemand(leaf.keys) }
        if leaf.rowID != row {
            if let old = leaf.rowID { removeLeaf(id, fromRow: old) }
            if let row { leavesByRow[row, default: []].insert(id) }
        }
        leaf.rowID = row
        leaf.keys = keys
        leaves[id] = leaf
        if isVisible(row) { addDemand(keys) }
    }

    /// A leaf disappeared (`onDisappear`).
    func detach(leaf id: String) {
        guard var leaf = leaves[id] else { return }
        leaf.count -= 1
        guard leaf.count <= 0 else {
            leaves[id] = leaf
            return
        }
        leaves[id] = nil
        if let row = leaf.rowID { removeLeaf(id, fromRow: row) }
        if isVisible(leaf.rowID) { removeDemand(leaf.keys) }
    }

    /// A row's viewport visibility (at least one point on screen). Called on
    /// every crossing during a scroll: a set write and, only for rows with
    /// attached smart-link leaves, demand bookkeeping.
    func setRowVisible(_ row: String, _ visible: Bool) {
        guard resolver != nil, hasVisibilityFeed else { return }
        if visible {
            guard visibleRows.insert(row).inserted else { return }
        } else {
            guard visibleRows.remove(row) != nil else { return }
        }
        guard let ids = leavesByRow[row] else { return }
        for id in ids {
            guard let keys = leaves[id]?.keys else { continue }
            if visible { addDemand(keys) } else { removeDemand(keys) }
        }
    }

    private func removeLeaf(_ id: String, fromRow row: String) {
        leavesByRow[row]?.remove(id)
        if leavesByRow[row]?.isEmpty == true { leavesByRow[row] = nil }
    }

    private func isVisible(_ row: String?) -> Bool {
        guard let row, hasVisibilityFeed else { return true }
        return visibleRows.contains(row)
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

    /// Demand appeared for `key`: a `.plain` key without a lookup dwells.
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
    /// cancel its call (back to `.plain`).
    private func demandEnded(_ key: SmartLinkKey) {
        guard let lookup = lookups.removeValue(forKey: key) else { return }
        switch lookup.phase {
        case .dwelling(let task):
            task?.cancel()
        case .queued:
            queue.removeAll { $0 == key }
        case .running(let task):
            task.cancel()
            running -= 1
            stats.inFlight = running
            stats.cancellations += 1
            entry(for: key).publish(.plain)
            startQueued()
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
        // Detached: the resolver runs off the main actor; only the result
        // hops back. Cancelling this task cancels the resolver's work.
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: SmartLinkStage
            do {
                outcome = .resolved(try await resolver.resolve(url))
            } catch {
                outcome = .failed(Self.failure(for: error))
            }
            await self?.finish(key, id: id, outcome: outcome)
        }
        lookups[key] = Lookup(id: id, generation: generation, phase: .running(task))
    }

    private func finish(_ key: SmartLinkKey, id: Int, outcome: SmartLinkStage) {
        // A cancelled call (its lookup is gone) or one from an older
        // generation (`reset` cleared it) never lands.
        guard let lookup = lookups[key], lookup.id == id, lookup.generation == generation,
              case .running = lookup.phase else { return }
        lookups[key] = nil
        running -= 1
        stats.inFlight = running
        if case .resolved = outcome { stats.resolved += 1 } else { stats.failed += 1 }
        entry(for: key).publish(outcome)
        startQueued()
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
    /// every entry to `.plain`. Leaves and row visibility are kept — they
    /// describe live views, which detach (or, under a reused identity, stay
    /// and are asked about again) on their own — and keys still in demand
    /// start over.
    func reset() {
        generation += 1
        for lookup in lookups.values {
            switch lookup.phase {
            case .dwelling(let task): task?.cancel()
            case .queued: break
            case .running(let task):
                task.cancel()
                stats.cancellations += 1
            }
        }
        lookups = [:]
        queue = []
        running = 0
        stats.inFlight = 0
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
}

private struct ADFSmartLinksKey: EnvironmentKey {
    static let defaultValue: SmartLinkCoordinator? = nil
}

private struct ADFSmartLinkRowIDKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The document's smart-link coordinator, injected by `ADFDocumentView`
    /// (the reference never changes, so injecting it invalidates nothing).
    /// `nil` outside a document view: links stay plain.
    var adfSmartLinks: SmartLinkCoordinator? {
        get { self[ADFSmartLinksKey.self] }
        set { self[ADFSmartLinksKey.self] = newValue }
    }

    /// The top-level row (`DocumentRow`) a view sits in, set by the row for
    /// its block, so a smart-link leaf at any depth (list, table cell,
    /// panel, expand body) attaches to the row whose visibility gates it.
    /// `nil` outside a row (a pinned table header, a host's own layout).
    var adfSmartLinkRowID: String? {
        get { self[ADFSmartLinkRowIDKey.self] }
        set { self[ADFSmartLinkRowIDKey.self] = newValue }
    }
}
