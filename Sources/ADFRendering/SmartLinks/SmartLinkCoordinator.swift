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

/// A smart link's stage in one loaded document (design §2, §10):
///
/// ```
///          leaf visible + dwell, then 300 ms of lookup     resolver returns
///  .plain ──────────────────────────────────▶ .resolving ─────────────────▶ .resolved   (terminal)
///    │ ▲                                        │   │ resolver throws, or an empty title
///    │ │  demand drops to 0 (cancel)            │   └──────────────────────▶ .failed     (terminal, drawn plain)
///    │ └────────────────────────────────────────┘
///    └─ a lookup that lands within 300 ms goes straight to .resolved / .failed
/// ```
///
/// While the document scrolls, a `.resolved` outcome for a link whose leaf
/// is not fully on screen is held (`SmartLinkEntry.held`) until it is, or
/// until scrolling stops (design §10).
enum SmartLinkStage: Hashable, Sendable {
    /// The link as prepared (URL text, or an inline card's host; link
    /// colour). Also the stage of a cancelled lookup: cancellation is not
    /// failure, the next appearance retries.
    case plain
    /// A lookup has run for `SmartLinkTiming.resolvingDelay`: the same
    /// text, link colour at reduced opacity.
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

    /// An outcome kept without publishing it as `stage`. Not observed:
    /// storing it invalidates no leaf, so no row redraws. It is
    /// - a nearby lookup's (`.afterScrollingWithNearby`), made while no
    ///   leaf showing the key was on screen (design §8.5), or
    /// - a landed title held because the document was scrolling and a leaf
    ///   showing the key was not fully on screen (design §10); it stays
    ///   here if that leaf leaves the screen first.
    ///
    /// A leaf drawing the key for the first time draws it
    /// (`SmartLinkCoordinator.displayStages`), so a leaf built afterwards
    /// has its final height on its first frame; a leaf that already drew
    /// the key keeps what it drew. It becomes `stage` when the coordinator
    /// publishes it: when a leaf holding the key is on screen, at once at
    /// rest, else once every such leaf is fully on screen or scrolling
    /// stops.
    @ObservationIgnored private(set) var held: SmartLinkStage?
    /// Whether `held` came from a nearby lookup (a `prefetchHit` once it is
    /// published).
    @ObservationIgnored private(set) var heldFromNearby = false

    /// Writes `stage` only when it changes, so an unchanged write
    /// invalidates no reader.
    func publish(_ stage: SmartLinkStage) {
        guard stage != self.stage else { return }
        self.stage = stage
    }

    /// Keeps an outcome without publishing it.
    func hold(_ outcome: SmartLinkStage, nearby: Bool) {
        held = outcome
        heldFromNearby = nearby
    }

    /// Publishes the held outcome as the stage. Returns whether it came
    /// from a nearby lookup, or `nil` when nothing was held.
    func publishHeld() -> Bool? {
        guard let outcome = held else { return nil }
        let nearby = heldFromNearby
        held = nil
        heldFromNearby = false
        publish(outcome)
        return nearby
    }

    /// Back to `.plain` (a new document). Leaves that drew a held outcome
    /// did so without observing a change, so every reader is notified when
    /// one is dropped.
    func reset() {
        if held != nil {
            held = nil
            heldFromNearby = false
            withMutation(keyPath: \.stage) {}
        }
        publish(.plain)
    }
}

/// How the coordinator waits and how much it runs at once. Injectable so
/// tests drive the dwell by hand.
struct SmartLinkTiming: Sendable {
    /// How long a key must stay in demand before its lookup starts. Free to
    /// cancel: a fling past a link starts nothing. Zero starts at once.
    var dwell: Duration = .milliseconds(150)
    /// How long a visible lookup runs before its links show the loading
    /// look (`.resolving`, design §10). A lookup that lands or is cancelled
    /// sooner never shows it: a link passed in a fling costs no redraw, and
    /// a fast lookup goes from plain to its title in one. Zero shows it as
    /// the call starts.
    var resolvingDelay: Duration = .milliseconds(300)
    /// Lookups running at once; the rest queue in the order their dwell
    /// ended.
    var maxConcurrent = 4
    /// `.afterScrollingWithNearby`: keys per nearby batch. One of the four
    /// slots stays free for a link that comes on screen at rest.
    var prefetchBatchSize = 3
    /// `.afterScrollingWithNearby`: how far from the links on screen a link
    /// may be, in document positions (`SmartLinkNeighbourhood`), and still
    /// be looked up at rest — about one phone screen of paragraphs.
    var nearbyDistance = 12
    /// `.afterScrollingWithNearby`: the pause before each nearby batch is
    /// planned (after coming to rest, or after the previous batch ended).
    var prefetchPause: Duration = .milliseconds(150)
    /// Waits out a dwell, a resolving delay or a pause; throws when its
    /// task is cancelled.
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
}

/// What `.afterScrollingWithNearby` reads off the document: its top-level
/// blocks in order, a revision that changes whenever they are mutated, and
/// the row the scroll view tracks at its top. `ADFDocumentModel` conforms.
@MainActor
protocol SmartLinkDocument: AnyObject {
    var smartLinkBlocks: [RenderBlock] { get }
    var smartLinkRevision: UInt64 { get }
    /// The index in `smartLinkBlocks` of the row at the top of the screen.
    var smartLinkTopRowIndex: Int? { get }
}

/// The smart-link counters of one document model, cumulative across its
/// loads except `inFlight` (diagnostics: the demo's About sheet and tests).
/// `resolverCalls == resolved + failed + cancellations + inFlight`.
@_spi(ADFDiagnostics)
public struct ADFSmartLinkStats: Sendable, Hashable {
    /// Calls made to the host's resolver.
    public var resolverCalls = 0
    /// Calls cancelled because their link left the screen (or the document
    /// was reloaded, or a nearby lookup was stopped) before the resolver
    /// returned, counted when the cancelled call has ended.
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

    // Resolution modes (design §8).

    /// The document's resolution mode.
    public var resolution: ADFSmartLinkResolution = .whileScrolling
    /// Whether the document's scroll view is scrolling now (its phase is not
    /// idle). Always false before iOS 18 / macOS 15.
    public var isScrolling = false
    /// Times the document's scroll view came to rest.
    public var scrollEnds = 0
    /// Resolver calls started while the document was scrolling: zero under
    /// `.afterScrolling` and `.afterScrollingWithNearby`.
    public var scrollingCalls = 0
    /// Times a visible link's lookup was held back because the document was
    /// scrolling (`.afterScrolling`, `.afterScrollingWithNearby`).
    public var deferred = 0
    /// Links on screen now with no result, no nearby result and no lookup
    /// (dwelling, queued or running): waiting for the scroll to end.
    public var waiting = 0
    /// Nearby batches started (`.afterScrollingWithNearby`).
    public var prefetchBatches = 0
    /// Resolver calls started for nearby, off-screen links (included in
    /// `resolverCalls`).
    public var prefetchCalls = 0
    /// Nearby calls running now (included in `inFlight`).
    public var prefetchInFlight = 0
    /// Nearby calls cancelled (scrolling resumed, the mode changed, or the
    /// document reloaded), counted when they ended (included in
    /// `cancellations`).
    public var prefetchCancellations = 0
    /// Links that came on screen with a nearby result and showed it without
    /// a lookup.
    public var prefetchHits = 0
    /// The most keys one nearby batch held.
    public var largestPrefetchBatch = 0
    /// The most nearby calls that ran at once.
    public var peakPrefetchInFlight = 0
    /// The farthest a nearby link was from the links on screen, in document
    /// positions (`SmartLinkNeighbourhood`).
    public var farthestPrefetch = 0

    // Landing without layout shift; delayed loading look (design §10).

    /// Times a title (a lookup's, or a nearby one coming on screen) was held
    /// back because the document was scrolling and a leaf showing the link
    /// was not fully on screen. Each is shown once every such leaf is fully
    /// on screen, or when scrolling stops.
    public var titlesHeld = 0
    /// Links on screen now whose title is held: zero at rest.
    public var titlesHeldNow = 0
    /// Times a lookup's links showed the loading look (`.resolving`). A
    /// lookup shows it only after it has run for 300 ms, so a link passed in
    /// a fling, or a lookup that lands sooner, never does.
    public var resolvingShown = 0

    public init() {}
}

/// Per-document smart-link resolution, owned by `ADFDocumentModel` and
/// reached by leaves through `adfSmartLinks` (design §4, §8).
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
///   for one of `maxConcurrent` slots, then asks the resolver; once the
///   call has run for `resolvingDelay` the key goes `.resolving` (a call
///   that ends sooner never shows it, design §10). Losing all demand drops
///   the dwell or queue place, or cancels the call and returns the key to
///   `.plain`. A cancelled call keeps its slot until its task actually
///   ends, so a resolver slow to stop can never push the calls past
///   `maxConcurrent`, nor run two calls for one URL: a key asked for again
///   meanwhile restarts once the old call ends.
/// - Landing without layout shift (design §10, every mode): a title that
///   lands while the document scrolls is published only when every
///   attached leaf holding its key is fully on screen (`setLeafFullyVisible`,
///   the leaf's 1.0-threshold feed). Otherwise it is held
///   (`SmartLinkEntry.held`, not observed) and published when those leaves
///   are fully on screen or scrolling stops, so a paragraph that shrinks
///   under its new title never moves text across the screen's edge. The
///   same holds for a nearby result coming on screen. Failures are
///   published at once (they draw as the prepared text). Without a
///   visibility feed nothing is held.
/// - `resolution` (design §8): `.whileScrolling` ignores the scroll phase.
///   `.afterScrolling` holds every new dwell and the queue while the
///   document scrolls (`scrollPhaseChanged`) and starts the visible keys
///   once it rests; calls already running keep running.
///   `.afterScrollingWithNearby` also looks up, at rest, batches of the
///   off-screen keys nearest the screen (`SmartLinkNeighbourhood`), keeps
///   their outcomes unpublished (`SmartLinkEntry.held`) and cancels
///   them when scrolling resumes.
/// - `.resolved` and `.failed` are terminal until `reset()` (`load`), which
///   bumps the generation: every task is cancelled and late results are
///   dropped (block IDs repeat across documents).
///
/// Not observable: visibility, attach and scroll-phase callbacks write plain
/// stored properties, and observable state (`SmartLinkEntry.stage`) changes
/// at most once per real stage change — never per visibility crossing or
/// phase change (the §16/§20 livelocks: a visibility callback must write no
/// view state).
@MainActor
final class SmartLinkCoordinator {
    /// The host's resolver (`ADFDocumentView(smartLinkResolver:)`). `nil`:
    /// every link stays plain and the coordinator does no work.
    var resolver: (any ADFSmartLinkResolver)?
    var timing: SmartLinkTiming
    /// Whether leaves report visibility (iOS 18 / macOS 15 and later).
    /// Without a feed an attached leaf counts as visible, and nothing is
    /// looked up for nearby links.
    var hasVisibilityFeed: Bool
    /// When lookups start (`ADFDocumentView(smartLinkResolution:)`). Stored
    /// at once; its effects (starting what is now allowed, stopping nearby
    /// lookups) follow in the next main-actor turn, because the document
    /// view sets it while its parent's body is being evaluated. Setting the
    /// same value does nothing.
    var resolution: ADFSmartLinkResolution = .whileScrolling {
        didSet {
            guard resolution != oldValue else { return }
            Task { [weak self] in self?.applyResolution() }
        }
    }
    /// The document `.afterScrollingWithNearby` measures "nearby" in (set by
    /// `ADFDocumentModel`).
    weak var document: (any SmartLinkDocument)?

    /// Bumped by `reset()`; a lookup from an older generation never lands.
    private(set) var generation = 0
    private var counters = ADFSmartLinkStats()
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
    /// Leaves whose last full-visibility report (`setLeafFullyVisible`) said
    /// all of the leaf is on screen. Kept like `leafVisibility`: a report
    /// may come before the attach, and detaching forgets it.
    private var fullyVisible: Set<String> = []
    private var demand: [SmartLinkKey: Int] = [:]
    /// When each demanded key came on screen (a sequence number), so keys
    /// held during a scroll start in that order once it ends.
    private var demandOrder: [SmartLinkKey: Int] = [:]
    private var nextDemandOrder = 0

    private enum Phase {
        case dwelling(Task<Void, Never>?)
        case queued
        case running(Task<Void, Never>)
        /// Cancelled (demand ended, scrolling stopped a nearby lookup, or
        /// `reset`), still holding its slot until the resolver's task ends;
        /// its result is dropped.
        case stopping(Task<Void, Never>)

        var task: Task<Void, Never>? {
            switch self {
            case .dwelling(let task): return task
            case .queued: return nil
            case .running(let task), .stopping(let task): return task
            }
        }

        /// Not started yet.
        var isWaiting: Bool {
            switch self {
            case .dwelling, .queued: return true
            case .running, .stopping: return false
            }
        }
    }
    private struct Lookup {
        let id: Int
        let generation: Int
        var phase: Phase
        /// A nearby lookup for a key no visible leaf holds
        /// (`.afterScrollingWithNearby`): publishes no stage, and scrolling
        /// cancels it.
        var prefetch = false
        /// A running visible call's pending loading look: publishes
        /// `.resolving` once the call has run `resolvingDelay`. Cancelled
        /// whenever the call ends, stops or is reset.
        var dim: Task<Void, Never>?
    }
    private var lookups: [SmartLinkKey: Lookup] = [:]
    private var queue: [SmartLinkKey] = []
    /// Slots in use: calls running or stopping.
    private var running = 0
    private var nextLookupID = 0
    /// What each owner's leaf last drew, per key, for `leafRefreshes` and
    /// for held outcomes (`displayStages`). Forgotten when the owner's leaf
    /// detaches, so a leaf built later draws as a new one.
    private var shown: [String: [SmartLinkKey: SmartLinkStage]] = [:]

    // Scroll phase and nearby lookups (design §8).

    /// The document's scroll view is not idle (`scrollPhaseChanged`).
    private(set) var isScrolling = false
    private var scrollStartOffset: CGFloat?
    /// The last scroll's direction (toward the end by default): nearby keys
    /// at equal distance go that way first.
    private var scrollsDown = true
    /// Keys of the current nearby batch not yet ended.
    private var prefetchBatch: Set<SmartLinkKey> = []
    /// The pending nearby plan (after `prefetchPause`).
    private var prefetchTick: Task<Void, Never>?
    /// Nearby calls running or stopping.
    private var prefetchRunning = 0
    private var neighbourhood = SmartLinkNeighbourhood()
    private var neighbourhoodStamp: NeighbourhoodStamp?
    private struct NeighbourhoodStamp: Equatable {
        let generation: Int
        let revision: UInt64
    }

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
        // The document is gone: stop every dwell, resolver call and nearby
        // plan. Their tasks hold the coordinator weakly, so nothing lands
        // afterwards.
        for lookup in lookups.values {
            lookup.phase.task?.cancel()
            lookup.dim?.cancel()
        }
        prefetchTick?.cancel()
    }

    /// The counters, with the values that are read off the current state.
    var stats: ADFSmartLinkStats {
        var stats = counters
        stats.resolution = resolution
        stats.isScrolling = isScrolling
        stats.waiting = demand.keys.filter { key in
            guard lookups[key] == nil else { return false }
            guard let entry = entries[key] else { return true }
            return entry.stage == .plain && entry.held == nil
        }.count
        stats.prefetchInFlight = prefetchRunning
        stats.titlesHeldNow = heldKeys.count
        return stats
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
    ///
    /// A key still `.plain` with a held outcome (a nearby result, or a
    /// title held while its leaf was not fully on screen; read without
    /// observing it, design §8.5, §10) draws that outcome in a leaf drawing
    /// the key for the first time, so a leaf built after it landed has its
    /// final height on its first frame. A leaf that already drew the key
    /// keeps what it drew (the prepared text, or the outcome it drew first)
    /// until the outcome is published, so a redraw for another reason (the
    /// loading look of another link in the same paragraph) never reflows it
    /// mid-scroll. A loading look it drew counts as the prepared text: it
    /// only shows while a call runs.
    func displayStages(for keys: [SmartLinkKey], owner: String?) -> [SmartLinkKey: SmartLinkStage] {
        let previous = owner.flatMap { shown[$0] }
        var stages: [SmartLinkKey: SmartLinkStage] = [:]
        var drawn: [SmartLinkKey: SmartLinkStage] = [:]
        drawn.reserveCapacity(keys.count)
        for key in keys {
            let entry = entry(for: key)
            var stage = entry.stage
            if stage == .plain, let held = entry.held {
                if let before = previous?[key] {
                    stage = before == .resolving ? .plain : before
                } else {
                    stage = held
                }
            }
            stage = stage.displayed
            drawn[key] = stage
            if stage.changesDisplay { stages[key] = stage }
        }
        if let owner { noteDrawn(owner: owner, drawn) }
        return stages
    }

    private func noteDrawn(owner: String, _ drawn: [SmartLinkKey: SmartLinkStage]) {
        guard let previous = shown[owner] else {
            shown[owner] = drawn
            return
        }
        guard previous != drawn else { return }
        shown[owner] = drawn
        counters.leafRefreshes += 1
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
    /// `visible` and `fullyVisible` carry the visibility already known for
    /// this leaf (its view moved here from another owner id or coordinator,
    /// `SmartLinkTextLeaf`); a report the leaf already made wins.
    func attach(leaf id: String, keys: [SmartLinkKey], visible: Bool? = nil, fullyVisible: Bool? = nil) {
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
        // The leaf no longer holds back the titles of the keys it dropped.
        releaseHeld(old)
    }

    /// A leaf disappeared (`onDisappear`). Once its last attachment goes,
    /// its visibility is forgotten too (the render-region backstop), and so
    /// is what it drew: a leaf built later for the same owner is a new one
    /// (`displayStages`).
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
        // A leaf that was not fully on screen no longer holds titles back.
        releaseHeld(leaf.keys)
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

    /// Whether all of a leaf is on screen (inside the scroll view's visible
    /// region), from the leaf's 1.0-threshold `onScrollVisibilityChange`,
    /// reported on every crossing (design §10). A set update and, only when
    /// an attached leaf comes fully on screen, the titles it held back are
    /// published if no other leaf holds them back. Never invalidates a view.
    func setLeafFullyVisible(_ id: String, _ fully: Bool) {
        guard resolver != nil, hasVisibilityFeed else { return }
        guard fully else {
            fullyVisible.remove(id)
            return
        }
        // A report before the attach is kept for it, as for visibility.
        guard fullyVisible.insert(id).inserted, let keys = leaves[id]?.keys else { return }
        releaseHeld(keys)
    }

    /// The visibility this coordinator knows for a leaf: `nil` when it has
    /// had no report (or tracks nothing: no resolver, no feed).
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

    // MARK: Landing without layout shift (design §10)

    /// Whether a title for `key` may be published now: at rest, or without
    /// a visibility feed, always; while the document scrolls, only when
    /// every attached leaf holding the key is fully on screen. A leaf
    /// straddling an edge would reflow across it (a paragraph straddling
    /// the top edge shifts the whole screen); a leaf taller than the screen
    /// is never fully on screen, so its titles wait for rest; a leaf built
    /// off screen (attached, not visible) holds them back too.
    private func mayPublish(_ key: SmartLinkKey) -> Bool {
        guard hasVisibilityFeed, isScrolling else { return true }
        return !leaves.contains { id, leaf in !fullyVisible.contains(id) && leaf.keys.contains(key) }
    }

    /// Publishes the held titles among `keys` that are in demand and may be
    /// published now.
    private func releaseHeld(_ keys: some Sequence<SmartLinkKey>) {
        for key in keys where demand[key] != nil && entries[key]?.held != nil && mayPublish(key) {
            publishHeld(key)
        }
    }

    private func publishHeld(_ key: SmartLinkKey) {
        guard let nearby = entries[key]?.publishHeld() else { return }
        if nearby { counters.prefetchHits += 1 }
    }

    /// A visible lookup's outcome: published, unless it is a title landing
    /// while the document scrolls and a leaf holding the key is not fully
    /// on screen. Then it is held until it may be (`releaseHeld`). A
    /// failure is published at once: it draws as the prepared text, so it
    /// moves nothing, and it ends the loading look.
    private func land(_ key: SmartLinkKey, _ outcome: SmartLinkStage) {
        let entry = entry(for: key)
        if outcome.changesDisplay, !mayPublish(key) {
            entry.hold(outcome, nearby: false)
            counters.titlesHeld += 1
        } else {
            entry.publish(outcome)
        }
    }

    // MARK: Delayed loading look (design §10)

    /// A visible call is running: its links show the loading look once it
    /// has run for `resolvingDelay` (at once when that is zero). A call that
    /// lands or is cancelled sooner never shows it.
    private func showResolving(_ key: SmartLinkKey, id: Int) {
        let delay = timing.resolvingDelay
        guard delay > .zero else {
            publishResolving(key)
            return
        }
        let sleep = timing.sleep
        lookups[key]?.dim = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled else { return }
            self?.resolvingDelayEnded(key, id: id)
        }
    }

    private func resolvingDelayEnded(_ key: SmartLinkKey, id: Int) {
        guard let lookup = lookups[key], lookup.id == id, !lookup.prefetch, case .running = lookup.phase else { return }
        lookups[key]?.dim = nil
        publishResolving(key)
    }

    private func publishResolving(_ key: SmartLinkKey) {
        let entry = entry(for: key)
        guard entry.stage == .plain, entry.held == nil else { return }
        entry.publish(.resolving)
        counters.resolvingShown += 1
    }

    /// Stops a call's pending loading look.
    private func cancelDim(_ key: SmartLinkKey) {
        lookups[key]?.dim?.cancel()
        lookups[key]?.dim = nil
    }

    // MARK: Scroll phase (design §8.2)

    /// The document's scroll view changed phase (`onScrollPhaseChange`, iOS
    /// 18 / macOS 15): `scrolling` is any phase but idle (tracking,
    /// interacting, decelerating, animating), `offset` its vertical content
    /// offset. Writes plain stored properties only; never invalidates a
    /// view.
    func scrollPhaseChanged(scrolling: Bool, offset: CGFloat) {
        guard resolver != nil, scrolling != isScrolling else { return }
        isScrolling = scrolling
        if scrolling {
            scrollStartOffset = offset
            guard resolution != .whileScrolling else { return }
            holdVisibleDwells()
            stopPrefetching()
        } else {
            if let start = scrollStartOffset, offset != start { scrollsDown = offset > start }
            scrollStartOffset = nil
            counters.scrollEnds += 1
            // Every mode: the titles held while scrolling show now (design §10).
            releaseHeld(Array(demand.keys))
            guard resolution != .whileScrolling else { return }
            startDemanded()
            startQueued()
            schedulePrefetch()
        }
    }

    /// Whether new lookups wait for the scroll to end now.
    private var holdsLookups: Bool {
        resolution != .whileScrolling && isScrolling
    }

    /// Scrolling started under a mode that waits for rest: visible keys
    /// still dwelling lose their dwell and start over once it ends.
    private func holdVisibleDwells() {
        for (key, lookup) in lookups where !lookup.prefetch {
            guard case .dwelling(let task) = lookup.phase else { continue }
            task?.cancel()
            lookups[key] = nil
            counters.deferred += 1
        }
    }

    /// Every demanded key, in the order it came on screen, gets a dwell (or
    /// its nearby result) if it needs one.
    private func startDemanded() {
        let keys = demand.keys.sorted { (demandOrder[$0] ?? 0) < (demandOrder[$1] ?? 0) }
        for key in keys { demandStarted(key) }
    }

    /// The mode changed (a turn after `resolution` was set).
    private func applyResolution() {
        guard resolver != nil else { return }
        if resolution != .afterScrollingWithNearby { stopPrefetching() }
        if holdsLookups {
            holdVisibleDwells()
        } else {
            startDemanded()
            startQueued()
        }
        schedulePrefetch()
    }

    // MARK: Demand

    private func addDemand(_ keys: [SmartLinkKey]) {
        for key in keys {
            let count = demand[key, default: 0] + 1
            demand[key] = count
            if count == 1 {
                nextDemandOrder += 1
                demandOrder[key] = nextDemandOrder
                demandStarted(key, arrived: true)
            }
        }
        schedulePrefetch()
    }

    private func removeDemand(_ keys: [SmartLinkKey]) {
        for key in keys {
            guard let count = demand[key] else { continue }
            if count > 1 {
                demand[key] = count - 1
            } else {
                demand[key] = nil
                demandOrder[key] = nil
                demandEnded(key)
            }
        }
        schedulePrefetch()
    }

    /// Demand appeared for `key`. A nearby lookup for it becomes a visible
    /// one; a held outcome (a nearby result, or a title held while its leaf
    /// was not fully on screen) is published without a lookup — at once,
    /// or, while the document scrolls, once every leaf holding the key is
    /// fully on screen or scrolling stops (design §10); otherwise a
    /// `.plain` key without a lookup dwells — unless the document is
    /// scrolling under a mode that waits for rest. A key whose cancelled
    /// call is still stopping waits for it to end (`finish` starts it again
    /// then). `arrived`: the key just came on screen (counted as a held
    /// title if it waits), not a re-scan of keys already on screen.
    private func demandStarted(_ key: SmartLinkKey, arrived: Bool = false) {
        guard resolver != nil else { return }
        if let lookup = lookups[key] {
            if lookup.prefetch { promote(key) }
            return
        }
        let entry = entry(for: key)
        if let held = entry.held {
            if held.changesDisplay, !mayPublish(key) {
                if arrived { counters.titlesHeld += 1 }
            } else {
                publishHeld(key)
            }
            return
        }
        guard entry.stage == .plain else { return }
        guard !holdsLookups else {
            counters.deferred += 1
            return
        }
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
    /// cancel its call (back to `.plain`, which redraws nothing if the
    /// loading look never showed; the slot frees when the call's task
    /// ends). A title held for leaves that have all left the screen stays
    /// held, so a leaf built later draws it on its first frame and the key
    /// shows it when it is wanted again; only a loading look it showed is
    /// cleared (design §10).
    private func demandEnded(_ key: SmartLinkKey) {
        guard let lookup = lookups[key] else {
            if let entry = entries[key], entry.held != nil { entry.publish(.plain) }
            return
        }
        guard !lookup.prefetch else { return }
        switch lookup.phase {
        case .dwelling(let task):
            task?.cancel()
            lookups[key] = nil
        case .queued:
            queue.removeAll { $0 == key }
            lookups[key] = nil
        case .running(let task):
            task.cancel()
            cancelDim(key)
            lookups[key]?.phase = .stopping(task)
            entry(for: key).publish(.plain)
        case .stopping:
            break
        }
    }

    private func dwellEnded(_ key: SmartLinkKey, id: Int) {
        guard let lookup = lookups[key], lookup.id == id, case .dwelling = lookup.phase else { return }
        if holdsLookups {
            // Scrolling began as the dwell ended: start over at rest.
            lookups[key] = nil
            counters.deferred += 1
            return
        }
        if running < max(timing.maxConcurrent, 1) {
            start(key, id: id)
        } else {
            enqueue(key)
        }
    }

    /// Queues a key for a slot: a visible key goes ahead of every nearby
    /// key, a nearby key goes last.
    private func enqueue(_ key: SmartLinkKey) {
        lookups[key]?.phase = .queued
        if lookups[key]?.prefetch != true,
           let index = queue.firstIndex(where: { lookups[$0]?.prefetch == true }) {
            queue.insert(key, at: index)
        } else {
            queue.append(key)
        }
    }

    private func startQueued() {
        guard !holdsLookups else { return }
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
        let prefetch = lookups[key]?.prefetch ?? false
        running += 1
        counters.inFlight = running
        counters.resolverCalls += 1
        if isScrolling { counters.scrollingCalls += 1 }
        if prefetch {
            counters.prefetchCalls += 1
            prefetchRunning += 1
            counters.peakPrefetchInFlight = max(counters.peakPrefetchInFlight, prefetchRunning)
        }
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
        lookups[key] = Lookup(id: id, generation: generation, phase: .running(task), prefetch: prefetch)
        guard !prefetch else { return }
        showResolving(key, id: id)
        // A visible key leaving the queue may be the last visible work a
        // nearby batch waits for.
        schedulePrefetch()
    }

    /// A call's task ended. A current call lands its outcome (a nearby one
    /// unpublished, design §8.5; a visible title held while its leaf is not
    /// fully on screen during a scroll, §10); a cancelled one (stopping,
    /// possibly from an older generation) only frees its slot, and its key
    /// starts over if it is in demand again. Either way its pending loading
    /// look is dropped.
    private func finish(_ key: SmartLinkKey, id: Int, outcome: SmartLinkStage) {
        guard let lookup = lookups[key], lookup.id == id else { return }
        lookup.dim?.cancel()
        switch lookup.phase {
        case .running where lookup.generation == generation:
            lookups[key] = nil
            running -= 1
            counters.inFlight = running
            if case .resolved = outcome { counters.resolved += 1 } else { counters.failed += 1 }
            if lookup.prefetch {
                prefetchRunning -= 1
                entry(for: key).hold(outcome, nearby: true)
                leaveBatch(key)
            } else {
                land(key, outcome)
            }
        case .running, .stopping:
            lookups[key] = nil
            running -= 1
            counters.inFlight = running
            counters.cancellations += 1
            if lookup.prefetch {
                prefetchRunning -= 1
                counters.prefetchCancellations += 1
                leaveBatch(key)
            }
            // The freed slot goes to the queue first; the key, if wanted
            // again meanwhile, starts over behind it.
            startQueued()
            if demand[key] != nil { demandStarted(key) }
            schedulePrefetch()
            return
        case .dwelling, .queued:
            return
        }
        startQueued()
        schedulePrefetch()
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

    // MARK: Nearby lookups (design §8.5)

    /// A nearby lookup's key came on screen: it is a visible lookup now
    /// (shows `.resolving` if it runs for `resolvingDelay` from now, queues
    /// ahead of nearby keys if it waits, and scrolling no longer cancels
    /// it).
    private func promote(_ key: SmartLinkKey) {
        guard var lookup = lookups[key], lookup.prefetch else { return }
        switch lookup.phase {
        case .queued:
            lookup.prefetch = false
            lookups[key] = lookup
            queue.removeAll { $0 == key }
            enqueue(key)
            leaveBatch(key)
        case .running:
            lookup.prefetch = false
            lookups[key] = lookup
            prefetchRunning -= 1
            showResolving(key, id: lookup.id)
            leaveBatch(key)
        case .dwelling, .stopping:
            // A stopping nearby call restarts as a visible one when it ends.
            break
        }
    }

    /// A key left the current batch (ended, promoted, or stopped); the next
    /// batch is planned once none is left.
    private func leaveBatch(_ key: SmartLinkKey) {
        guard prefetchBatch.remove(key) != nil, prefetchBatch.isEmpty else { return }
        schedulePrefetch()
    }

    /// Scrolling resumed (or the mode changed, or a reload): no nearby plan,
    /// queued nearby keys dropped, running nearby calls cancelled (each
    /// holds its slot until it returns, call #33).
    private func stopPrefetching() {
        prefetchTick?.cancel()
        prefetchTick = nil
        prefetchBatch = []
        for (key, lookup) in lookups where lookup.prefetch {
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
    }

    /// Plans the next nearby batch after `prefetchPause`, when the mode,
    /// the platform and the document allow one and none is running or
    /// pending. Cheap to call on every event.
    private func schedulePrefetch() {
        guard resolution == .afterScrollingWithNearby, hasVisibilityFeed, resolver != nil, !isScrolling,
              prefetchBatch.isEmpty, prefetchTick == nil else { return }
        let pause = timing.prefetchPause
        let sleep = timing.sleep
        prefetchTick = Task { [weak self] in
            if pause > .zero {
                do { try await sleep(pause) } catch { return }
            }
            guard !Task.isCancelled else { return }
            self?.prefetchTick = nil
            self?.planPrefetchBatch()
        }
    }

    /// Starts one batch of at most `prefetchBatchSize` nearby keys, at rest,
    /// once no visible key is dwelling or queued (visible keys first).
    private func planPrefetchBatch() {
        guard resolution == .afterScrollingWithNearby, hasVisibilityFeed, resolver != nil, !isScrolling,
              prefetchBatch.isEmpty else { return }
        guard !lookups.values.contains(where: { !$0.prefetch && $0.phase.isWaiting }) else { return }
        let plan = nearbyKeys(limit: timing.prefetchBatchSize)
        guard !plan.isEmpty else { return }
        counters.prefetchBatches += 1
        counters.largestPrefetchBatch = max(counters.largestPrefetchBatch, plan.count)
        for (key, distance) in plan {
            counters.farthestPrefetch = max(counters.farthestPrefetch, distance)
            nextLookupID += 1
            let id = nextLookupID
            lookups[key] = Lookup(id: id, generation: generation, phase: .queued, prefetch: true)
            prefetchBatch.insert(key)
            if running < max(timing.maxConcurrent, 1) {
                start(key, id: id)
            } else {
                queue.append(key)
            }
        }
    }

    /// The nearest off-screen keys that need a lookup, at most `limit`,
    /// with their distance in positions from the visible span: candidates
    /// lie within `nearbyDistance` of the span, nearest first, ties toward
    /// the last scroll's direction, an owner's keys in document order.
    private func nearbyKeys(limit: Int) -> [(key: SmartLinkKey, distance: Int)] {
        guard limit > 0, let index = currentNeighbourhood() else { return [] }
        var low = Int.max
        var high = Int.min
        for (id, visible) in leafVisibility where visible && leaves[id] != nil {
            guard let position = index.position(ofOwner: id) else { continue }
            low = min(low, position)
            high = max(high, position)
        }
        if low > high {
            // No indexed link on screen: the row at the top of the screen.
            guard let row = document?.smartLinkTopRowIndex, let position = index.position(ofRow: row) else { return [] }
            low = position
            high = position
        }
        let reach = max(timing.nearbyDistance, 0)
        struct Candidate {
            let order: Int
            let owner: SmartLinkNeighbourhood.Owner
            let distance: Int
            let ahead: Bool
        }
        var candidates: [Candidate] = []
        for (order, owner) in zip(0..., index.owners(from: low - reach, through: high + reach)) {
            if leafVisibility[owner.id] == true, leaves[owner.id] != nil { continue }
            let distance = owner.position < low ? low - owner.position : max(owner.position - high, 0)
            let ahead = scrollsDown ? owner.position >= low : owner.position <= high
            candidates.append(Candidate(order: order, owner: owner, distance: distance, ahead: ahead))
        }
        let down = scrollsDown
        candidates.sort { a, b in
            if a.distance != b.distance { return a.distance < b.distance }
            if a.ahead != b.ahead { return a.ahead }
            return down ? a.order < b.order : a.order > b.order
        }
        var chosen: [(key: SmartLinkKey, distance: Int)] = []
        var seen: Set<SmartLinkKey> = []
        for candidate in candidates {
            for key in candidate.owner.keys where seen.insert(key).inserted && needsNearbyLookup(key) {
                chosen.append((key, candidate.distance))
                if chosen.count == limit { return chosen }
            }
        }
        return chosen
    }

    /// No leaf on screen holds it, nothing is looking it up, and it has no
    /// result (resolved, failed, nearby or held): dedup, cache and
    /// in-flight lookups are never asked again.
    private func needsNearbyLookup(_ key: SmartLinkKey) -> Bool {
        guard demand[key] == nil, lookups[key] == nil else { return false }
        guard let entry = entries[key] else { return true }
        return entry.stage == .plain && entry.held == nil
    }

    /// The document's positions, indexed on first use and extended as
    /// blocks stream in; rebuilt for a new document or a mutation.
    private func currentNeighbourhood() -> SmartLinkNeighbourhood? {
        guard let document else { return nil }
        let stamp = NeighbourhoodStamp(generation: generation, revision: document.smartLinkRevision)
        let blocks = document.smartLinkBlocks
        if stamp != neighbourhoodStamp || blocks.count < neighbourhood.rowCount {
            neighbourhood = SmartLinkNeighbourhood()
            neighbourhoodStamp = stamp
        }
        if blocks.count > neighbourhood.rowCount {
            neighbourhood.append(contentsOf: blocks[neighbourhood.rowCount...])
        }
        return neighbourhood
    }

    // MARK: Reload

    /// A new document is loading (`ADFDocumentModel.load`): bump the
    /// generation, cancel every dwell, queue place, call, pending loading
    /// look and nearby plan, and return every entry to `.plain` (dropping
    /// held outcomes: nearby results and held titles). Cancelled calls keep
    /// their slots until their tasks end. Leaves and their visibility are
    /// kept — they describe live views, which detach (or, under a reused
    /// identity, stay and are asked about again) on their own — and keys
    /// still in demand start over. The scroll phase is the view's, so it is
    /// kept too.
    func reset() {
        generation += 1
        prefetchTick?.cancel()
        prefetchTick = nil
        prefetchBatch = []
        for (key, lookup) in lookups {
            switch lookup.phase {
            case .dwelling(let task):
                task?.cancel()
                lookups[key] = nil
            case .queued:
                lookups[key] = nil
            case .running(let task):
                task.cancel()
                cancelDim(key)
                lookups[key]?.phase = .stopping(task)
            case .stopping:
                break
            }
        }
        queue = []
        shown = [:]
        neighbourhoodStamp = nil
        for entry in entries.values { entry.reset() }
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
    /// Keys of the current nearby batch (tests).
    var prefetchBatchKeys: Set<SmartLinkKey> { prefetchBatch }
    /// Keys with a nearby lookup (queued, running or stopping) (tests).
    var prefetchingKeys: Set<SmartLinkKey> { Set(lookups.filter { $0.value.prefetch }.keys) }
    /// The held (unpublished) outcome of `key`: a nearby result or a held
    /// title (tests).
    func heldStage(for key: SmartLinkKey) -> SmartLinkStage? { entries[key]?.held }
    /// Keys on screen (in demand) whose outcome is held: empty at rest.
    var heldKeys: Set<SmartLinkKey> { Set(demand.keys.filter { entries[$0]?.held != nil }) }
    /// Leaves that last reported all of themselves on screen (tests).
    var fullyVisibleLeafIDs: Set<String> { fullyVisible }
    /// Keys whose call has a pending loading look (tests).
    var pendingDimKeys: Set<SmartLinkKey> { Set(lookups.filter { $0.value.dim != nil }.keys) }
}

private struct ADFSmartLinksKey: EnvironmentKey {
    static let defaultValue: SmartLinkCoordinator? = nil
}

extension EnvironmentValues {
    /// The document's smart-link coordinator, injected by `ADFDocumentView`
    /// while it has a resolver (the reference never changes, so injecting it
    /// invalidates nothing). `nil` outside a document view or without a
    /// resolver: links stay as authored and leaves add nothing for them.
    var adfSmartLinks: SmartLinkCoordinator? {
        get { self[ADFSmartLinksKey.self] }
        set { self[ADFSmartLinksKey.self] = newValue }
    }
}
