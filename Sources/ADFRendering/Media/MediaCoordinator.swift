import Foundation
import Observation
import SwiftUI
import ADFModel

/// What one media load is for: a source at a target size in points (the
/// reserved box, rounded). Two views showing the same source at the same
/// size share one key, so they share one provider call and one entry; the
/// same source at another size (a block and its thumbnail) is another load,
/// because the provider decodes downsampled to the size it is asked for.
struct MediaLoadKey: Hashable, Sendable {
    let source: MediaAttrs.Source
    let width: Int
    let height: Int

    init(source: MediaAttrs.Source, width: Int, height: Int) {
        self.source = source
        self.width = width
        self.height = height
    }

    /// The key for a box of `size` points, rounded; `nil` while the box has
    /// no area yet (not measured).
    init?(source: MediaAttrs.Source, size: CGSize) {
        guard size.width.isFinite, size.height.isFinite else { return nil }
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard width > 0, height > 0 else { return nil }
        self.init(source: source, width: width, height: height)
    }

    /// The size the provider decodes to.
    var targetSize: CGSize { CGSize(width: width, height: height) }
}

/// The observable state of one media load: the only observable state of the
/// feature. The media views showing the key read it in `body`, so a landing
/// (or a release) invalidates exactly those views, and the coordinator
/// writes it only when the value really changes.
@Observable @MainActor
final class MediaEntry {
    /// The decoded image, held only while a view showing the key is on
    /// screen (and `MediaTiming.releaseDelay` after the last one leaves):
    /// ADR §9's eviction rule. The provider's memory cache keeps the
    /// long-term copy, so a return is fast.
    private(set) var image: Image?
    /// The provider threw: the views draw the attachment chip, and the key
    /// is not asked again in this document generation.
    private(set) var failed = false

    func land(_ image: Image) {
        self.image = image
    }

    /// Drops the image. Returns whether there was one.
    @discardableResult
    func release() -> Bool {
        guard image != nil else { return false }
        image = nil
        return true
    }

    func fail() {
        guard !failed else { return }
        failed = true
    }

    /// Back to nothing loaded (a new document).
    func reset() {
        release()
        if failed { failed = false }
    }
}

/// How the coordinator waits and how much it runs at once. Injectable so
/// tests drive the dwell and the release delay by hand.
struct MediaTiming: Sendable {
    /// How long a key must stay on screen before its load starts. Free to
    /// cancel: a fling past a gallery starts nothing. Zero starts at once.
    var dwell: Duration = .milliseconds(150)
    /// Provider calls running at once; the rest queue in the order their
    /// dwell ended.
    var maxConcurrent = 4
    /// How long a loaded image is kept after the last view showing it left
    /// the screen, so a small scroll back and forth neither redraws nor asks
    /// again. Zero releases at once.
    var releaseDelay: Duration = .seconds(1)
    /// Waits out a dwell or a release delay; throws when its task is
    /// cancelled.
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
}

/// The media counters of one document, cumulative across its loads except
/// `running` (diagnostics: probes and tests).
/// `started == finished + failed + cancelled + running`.
@_spi(ADFDiagnostics)
public struct MediaCounters: Sendable, Hashable {
    /// Calls made to the host's provider.
    public var started = 0
    /// Calls that returned an image which landed.
    public var finished = 0
    /// Calls that ended without landing: cancelled because their media left
    /// the screen or the document reloaded (counted when the call ended), or
    /// that threw `CancellationError` on their own.
    public var cancelled = 0
    /// Calls that threw any other error.
    public var failed = 0
    /// Decoded images dropped because nothing showing them stayed on screen.
    public var released = 0
    /// The most calls that ran at once (never above `maxConcurrent`).
    public var maxRunning = 0
    /// Calls running now, including cancelled calls whose task has not ended
    /// yet (each holds a slot until it does).
    public var running = 0

    public init() {}
}

/// Per-document media loading, owned by `ADFDocumentModel` and reached by
/// the media views through `adfMedia` (ADR §24; the smart-link pattern of
/// §22 for block views).
///
/// - A media view (`MediaBlockView`, a strip's `MediaThumbnailView`) is a
///   **viewer**: it attaches on appear with its load key and detaches on
///   disappear (`mediaAttachment`), and reports its own viewport visibility
///   (`setViewerVisible`, from its 0.01-threshold `onScrollVisibilityChange`).
///   A strip's thumbnails only see the strip's inner horizontal scroll view,
///   so the strip reports its own visibility in the document
///   (`setGroupVisible`); a thumbnail counts as visible only when it and its
///   strip are. Before iOS 18 / macOS 15 (no feed) an attached viewer counts
///   as visible. With a feed, unknown visibility counts as not visible: a
///   prefetched row never loads.
/// - A key's **demand** is the number of visible viewers holding it. A key
///   that gains demand dwells (`MediaTiming.dwell`), then waits for one of
///   `maxConcurrent` slots, then asks the provider. Losing all demand drops
///   the dwell or queue place, or cancels the call; a cancelled call keeps
///   its slot until its task actually ends, so a provider slow to stop never
///   pushes the calls past the cap or runs two calls for one key.
/// - Eviction (ADR §9): a loaded image whose demand drops to zero is
///   released after `releaseDelay`, unless demand returns first (then it is
///   kept and nothing is asked). The coordinator never holds decoded images
///   for views nobody sees.
/// - A failure is terminal for the key until `reset()` (`load`), which bumps
///   the generation: every task is cancelled and late results are dropped
///   (block IDs repeat across documents).
/// - Results land at once, also while the document scrolls: unlike a smart
///   link's title, an image never changes layout, because the media box is
///   reserved from the attrs before any load (§9), so there is no landing
///   hold.
///
/// Not observable: visibility and attach callbacks write plain stored
/// properties, and observable state (`MediaEntry`) changes only when an image
/// lands, is released or fails — never per visibility crossing (the §16/§20
/// livelocks: a visibility callback must write no view state).
@MainActor
final class MediaCoordinator {
    /// The host's provider (`ADFDocumentView(mediaProvider:)`). `nil`: no
    /// load starts.
    var provider: (any ADFMediaProvider)?
    var timing: MediaTiming
    /// Whether viewers report visibility (iOS 18 / macOS 15 and later).
    /// Without a feed an attached viewer counts as visible.
    let hasVisibilityFeed: Bool

    /// Bumped by `reset()`; a load from an older generation never lands.
    private(set) var generation = 0
    private var storedCounters = MediaCounters()
    /// Slots in use: calls running or stopping.
    private(set) var running = 0

    /// Never removed (only reset): a view that survives a reload keeps
    /// observing the same entry object.
    private var entries: [MediaLoadKey: MediaEntry] = [:]

    private struct Viewer {
        var key: MediaLoadKey
        var attrs: MediaAttrs
        var group: String?
        /// Attachments under this viewer id still live (appear/disappear can
        /// overlap when a view is replaced).
        var count: Int
    }
    private var viewers: [String: Viewer] = [:]
    /// The last visibility each viewer reported. A `true` may arrive before
    /// the viewer attaches; it is forgotten when the viewer detaches.
    private var viewerVisibility: [String: Bool] = [:]
    /// Strips whose last report said they are on screen (`setGroupVisible`).
    private var visibleGroups: Set<String> = []
    /// Live strip views per group id (`attachGroup`).
    private var groupViews: [String: Int] = [:]
    private var groupMembers: [String: Set<String>] = [:]
    /// Viewers whose demand is counted: attached and visible.
    private var counted: Set<String> = []
    private var demand: [MediaLoadKey: Int] = [:]
    /// The attrs a demanded key is loaded with (the first viewer's).
    private var demandAttrs: [MediaLoadKey: MediaAttrs] = [:]

    private enum Phase {
        case dwelling(Task<Void, Never>?)
        case queued
        case running(Task<Void, Never>)
        /// Cancelled (demand ended, or `reset`), still holding its slot until
        /// the provider's task ends; its result is dropped.
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
        let attrs: MediaAttrs
        var phase: Phase
    }
    private var lookups: [MediaLoadKey: Lookup] = [:]
    private var queue: [MediaLoadKey] = []
    private var nextLookupID = 0

    private struct PendingRelease {
        let id: Int
        let task: Task<Void, Never>?
    }
    private var releases: [MediaLoadKey: PendingRelease] = [:]
    private var nextReleaseID = 0

    private enum Outcome: Sendable {
        case image(Image)
        case failed
        case cancelled
    }

    init(timing: MediaTiming = MediaTiming(), hasVisibilityFeed: Bool? = nil) {
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
        // The document is gone: stop every dwell, call and pending release.
        // Their tasks hold the coordinator weakly, so nothing lands
        // afterwards.
        for lookup in lookups.values { lookup.phase.task?.cancel() }
        for release in releases.values { release.task?.cancel() }
    }

    /// The counters, with `running` read off the current state.
    var counters: MediaCounters {
        var counters = storedCounters
        counters.running = running
        return counters
    }

    // MARK: Reading (views)

    /// The entry for `key`, created on first use. Reading its `image` and
    /// `failed` in `body` is the view's observation dependency on exactly its
    /// own key.
    func entry(for key: MediaLoadKey) -> MediaEntry {
        if let entry = entries[key] { return entry }
        let entry = MediaEntry()
        entries[key] = entry
        return entry
    }

    // MARK: Viewers

    /// A media view appeared with a measured box (`onAppear`, or its box got
    /// its first size). `visible` carries the visibility already known for
    /// this viewer (its view moved here from another viewer id or
    /// coordinator, `MediaAttachment.move`); a report the viewer already
    /// made wins. `group`: the strip a thumbnail sits in.
    func attach(viewer id: String, key: MediaLoadKey, attrs: MediaAttrs, group: String?, visible: Bool? = nil) {
        if hasVisibilityFeed, viewerVisibility[id] == nil, let visible {
            viewerVisibility[id] = visible
        }
        if var viewer = viewers[id] {
            viewer.count += 1
            viewers[id] = viewer
            update(viewer: id, key: key, attrs: attrs)
            return
        }
        viewers[id] = Viewer(key: key, attrs: attrs, group: group, count: 1)
        if let group { groupMembers[group, default: []].insert(id) }
        refresh(id)
    }

    /// A live viewer's key moved (its box settled on a new size, or its
    /// media was replaced under a stable identity). The new key gains demand
    /// before the old one loses it.
    func update(viewer id: String, key: MediaLoadKey, attrs: MediaAttrs) {
        guard var viewer = viewers[id], viewer.key != key || viewer.attrs != attrs else { return }
        let old = viewer.key
        viewer.key = key
        viewer.attrs = attrs
        viewers[id] = viewer
        guard old != key, counted.contains(id) else { return }
        addDemand(key, attrs: attrs)
        removeDemand(old)
    }

    /// A media view disappeared (`onDisappear`). Once its last attachment
    /// goes, its visibility is forgotten too: the backstop for a feed that
    /// never reports a final `false` (render-region exit).
    func detach(viewer id: String) {
        guard var viewer = viewers[id] else { return }
        viewer.count -= 1
        guard viewer.count <= 0 else {
            viewers[id] = viewer
            return
        }
        viewers[id] = nil
        viewerVisibility[id] = nil
        if let group = viewer.group {
            groupMembers[group]?.remove(id)
            if groupMembers[group]?.isEmpty == true { groupMembers[group] = nil }
        }
        if counted.remove(id) != nil { removeDemand(viewer.key) }
    }

    /// A viewer's viewport visibility (any point of it on screen in its
    /// nearest scroll view), reported on every crossing: a dictionary write
    /// and, only for an attached viewer whose visibility changed, demand
    /// bookkeeping.
    func setViewerVisible(_ id: String, _ visible: Bool) {
        guard hasVisibilityFeed else { return }
        guard viewers[id] != nil else {
            // Not attached (yet): keep a `true` for the attach that
            // follows; a `false` needs no record.
            viewerVisibility[id] = visible ? true : nil
            return
        }
        viewerVisibility[id] = visible
        refresh(id)
    }

    /// A strip's visibility in the document scroll view (`mediaGroupVisibility`).
    /// Its thumbnails count as visible only while it is.
    func setGroupVisible(_ group: String, _ visible: Bool) {
        guard hasVisibilityFeed else { return }
        let changed = visible ? visibleGroups.insert(group).inserted : visibleGroups.remove(group) != nil
        guard changed else { return }
        refreshGroup(group)
    }

    /// A strip view appeared (`mediaGroupVisibility`).
    func attachGroup(_ group: String, visible: Bool? = nil) {
        groupViews[group, default: 0] += 1
        if hasVisibilityFeed, visible == true, visibleGroups.insert(group).inserted {
            refreshGroup(group)
        }
    }

    /// A strip view disappeared. Once its last view goes, its visibility is
    /// forgotten (the backstop, as for viewers).
    func detachGroup(_ group: String) {
        guard let count = groupViews[group] else { return }
        guard count <= 1 else {
            groupViews[group] = count - 1
            return
        }
        groupViews[group] = nil
        if visibleGroups.remove(group) != nil { refreshGroup(group) }
    }

    /// The visibility this coordinator knows for a viewer: `nil` when it has
    /// had no report (or there is no feed).
    func knownVisibility(of id: String) -> Bool? {
        guard hasVisibilityFeed else { return nil }
        return viewerVisibility[id]
    }

    /// Whether this coordinator knows a strip to be on screen: `nil` without
    /// a feed.
    func knownGroupVisibility(of group: String) -> Bool? {
        guard hasVisibilityFeed else { return nil }
        return visibleGroups.contains(group)
    }

    private func isVisible(_ id: String) -> Bool {
        guard hasVisibilityFeed else { return true }
        guard viewerVisibility[id] == true else { return false }
        guard let group = viewers[id]?.group else { return true }
        return visibleGroups.contains(group)
    }

    /// Counts or uncounts a viewer's demand to match whether it is attached
    /// and visible.
    private func refresh(_ id: String) {
        guard let viewer = viewers[id] else { return }
        if isVisible(id) {
            if counted.insert(id).inserted { addDemand(viewer.key, attrs: viewer.attrs) }
        } else if counted.remove(id) != nil {
            removeDemand(viewer.key)
        }
    }

    private func refreshGroup(_ group: String) {
        guard let members = groupMembers[group] else { return }
        for id in members.sorted() { refresh(id) }
    }

    // MARK: Demand

    private func addDemand(_ key: MediaLoadKey, attrs: MediaAttrs) {
        let count = demand[key, default: 0] + 1
        demand[key] = count
        guard count == 1 else { return }
        demandAttrs[key] = attrs
        demandStarted(key)
    }

    private func removeDemand(_ key: MediaLoadKey) {
        guard let count = demand[key] else { return }
        if count > 1 {
            demand[key] = count - 1
            return
        }
        demand[key] = nil
        demandAttrs[key] = nil
        demandEnded(key)
    }

    /// Demand appeared for `key`. A loaded image whose release is pending is
    /// kept (nothing is asked); a failed key stays failed; otherwise a key
    /// without a load dwells. A key whose cancelled call is still stopping
    /// waits for it to end (`finish` starts it again then).
    private func demandStarted(_ key: MediaLoadKey) {
        if let release = releases.removeValue(forKey: key) {
            release.task?.cancel()
            return
        }
        guard provider != nil, lookups[key] == nil, let attrs = demandAttrs[key] else { return }
        let entry = entry(for: key)
        guard entry.image == nil, !entry.failed else { return }
        nextLookupID += 1
        let id = nextLookupID
        guard timing.dwell > .zero else {
            lookups[key] = Lookup(id: id, generation: generation, attrs: attrs, phase: .dwelling(nil))
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
        lookups[key] = Lookup(id: id, generation: generation, attrs: attrs, phase: .dwelling(task))
    }

    /// Demand for `key` dropped to zero: drop its dwell or queue place, or
    /// cancel its call (the slot frees when the call's task ends), or start
    /// the release of its loaded image.
    private func demandEnded(_ key: MediaLoadKey) {
        guard let lookup = lookups[key] else {
            if entries[key]?.image != nil { scheduleRelease(key) }
            return
        }
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

    private func dwellEnded(_ key: MediaLoadKey, id: Int) {
        guard let lookup = lookups[key], lookup.id == id, case .dwelling = lookup.phase else { return }
        if hasFreeSlot {
            start(key)
        } else {
            lookups[key]?.phase = .queued
            queue.append(key)
        }
    }

    private var hasFreeSlot: Bool { running < max(timing.maxConcurrent, 1) }

    private func startQueued() {
        while hasFreeSlot, !queue.isEmpty {
            let key = queue.removeFirst()
            guard let lookup = lookups[key], case .queued = lookup.phase else { continue }
            start(key)
        }
    }

    private func start(_ key: MediaLoadKey) {
        guard let provider, let lookup = lookups[key] else {
            lookups[key] = nil
            return
        }
        running += 1
        storedCounters.started += 1
        storedCounters.maxRunning = max(storedCounters.maxRunning, running)
        let id = lookup.id
        let attrs = lookup.attrs
        let size = key.targetSize
        // Detached: the provider fetches and decodes off the main actor; only
        // the outcome hops back. Cancelling this task cancels the provider's
        // work.
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: Outcome
            do {
                outcome = .image(try await provider.image(for: attrs, targetSize: size))
            } catch is CancellationError {
                outcome = .cancelled
            } catch {
                outcome = Task.isCancelled ? .cancelled : .failed
            }
            await self?.finish(key, id: id, outcome: outcome)
        }
        lookups[key]?.phase = .running(task)
    }

    /// A call's task ended. A current call lands its image (at once, also
    /// mid-scroll: the box is reserved, so nothing moves) or its failure; a
    /// cancelled one (stopping, possibly from an older generation) only frees
    /// its slot, and its key starts over if it is in demand again.
    private func finish(_ key: MediaLoadKey, id: Int, outcome: Outcome) {
        guard let lookup = lookups[key], lookup.id == id else { return }
        let restart: Bool
        switch lookup.phase {
        case .running where lookup.generation == generation:
            lookups[key] = nil
            running -= 1
            restart = false
            switch outcome {
            case .image(let image):
                storedCounters.finished += 1
                entry(for: key).land(image)
                // Defensive: a running call always has demand (losing it
                // stops the call), so this never releases at once.
                if demand[key] == nil { scheduleRelease(key) }
            case .failed:
                storedCounters.failed += 1
                entry(for: key).fail()
            case .cancelled:
                // The provider gave up on its own: nothing is published; the
                // key is asked again when it next comes on screen.
                storedCounters.cancelled += 1
            }
        case .running, .stopping:
            lookups[key] = nil
            running -= 1
            storedCounters.cancelled += 1
            restart = true
        case .dwelling, .queued:
            return
        }
        // The freed slot goes to the queue first; the key, if wanted again
        // meanwhile, starts over behind it.
        startQueued()
        if restart, demand[key] != nil { demandStarted(key) }
    }

    // MARK: Eviction

    private func scheduleRelease(_ key: MediaLoadKey) {
        guard releases[key] == nil else { return }
        nextReleaseID += 1
        let id = nextReleaseID
        guard timing.releaseDelay > .zero else {
            releases[key] = PendingRelease(id: id, task: nil)
            releaseEnded(key, id: id)
            return
        }
        let sleep = timing.sleep
        let delay = timing.releaseDelay
        let task = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled else { return }
            self?.releaseEnded(key, id: id)
        }
        releases[key] = PendingRelease(id: id, task: task)
    }

    private func releaseEnded(_ key: MediaLoadKey, id: Int) {
        guard releases[key]?.id == id else { return }
        releases[key] = nil
        guard demand[key] == nil else { return }
        if entries[key]?.release() == true { storedCounters.released += 1 }
    }

    // MARK: Reset

    /// A new document is loading (`ADFDocumentModel.load`): bump the
    /// generation, cancel every dwell, queue place, call and pending release,
    /// and reset every entry (no image, not failed). Cancelled calls keep
    /// their slots until their tasks end. Viewers and their visibility are
    /// kept — they describe live views, which detach (or, under a reused
    /// identity, stay and are asked about again) on their own — and keys
    /// still in demand start over.
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
        for release in releases.values { release.task?.cancel() }
        releases = [:]
        for entry in entries.values { entry.reset() }
        for key in demand.keys.sorted(by: { "\($0)" < "\($1)" }) {
            demandStarted(key)
        }
    }

    // MARK: Test hooks

    /// Keys with a dwell, queue place or call (tests).
    var pendingKeys: Set<MediaLoadKey> { Set(lookups.keys) }
    /// Keys waiting for a slot, in order (tests).
    var queuedKeys: [MediaLoadKey] { queue }
    /// Current demand per key (tests).
    var demandCounts: [MediaLoadKey: Int] { demand }
    /// Attached viewer ids (tests).
    var attachedViewerIDs: Set<String> { Set(viewers.keys) }
    /// Keys whose loaded image is waiting out `releaseDelay` (tests).
    var pendingReleaseKeys: Set<MediaLoadKey> { Set(releases.keys) }
}

private struct ADFMediaKey: EnvironmentKey {
    static let defaultValue: MediaCoordinator? = nil
}

extension EnvironmentValues {
    /// The document's media coordinator, injected by `ADFDocumentView` while
    /// it has a media provider (the reference never changes, so injecting it
    /// invalidates nothing). `nil` outside a document view or without a
    /// provider: media views draw their placeholder and add no feed.
    var adfMedia: MediaCoordinator? {
        get { self[ADFMediaKey.self] }
        set { self[ADFMediaKey.self] = newValue }
    }
}

// MARK: - View feeds

extension View {
    /// Attaches a media view to the document's coordinator as `viewer` and
    /// feeds it the view's own visibility: `attach` on appear, `detach` on
    /// disappear (the backstop: a view that leaves the render region is no
    /// longer visible), and, from iOS 18 / macOS 15, the view's
    /// `onScrollVisibilityChange(threshold: 0.01)`. A change of coordinator,
    /// viewer id, key or group under a stable view moves the attachment (and
    /// its known visibility). `key` is `nil` while the box is not measured:
    /// the feed runs (its report is kept for the attach) but nothing attaches.
    ///
    /// Without a coordinator (no provider) it adds nothing. Every callback
    /// writes only the coordinator's non-observable state, never view state
    /// (§16/§20: no `@State` bound to visibility).
    func mediaAttachment(viewer: String, key: MediaLoadKey?, attrs: MediaAttrs, group: String?) -> some View {
        modifier(MediaAttachment(viewer: viewer, key: key, attrs: attrs, group: group))
    }

    /// Reports a media strip's own visibility in the document scroll view
    /// (`MediaCoordinator.setGroupVisible`): its thumbnails' feeds only see
    /// the strip's horizontal scroll view. Apply it to that scroll view.
    func mediaGroupVisibility(group: String) -> some View {
        modifier(MediaGroupVisibility(group: group))
    }
}

struct MediaAttachment: ViewModifier {
    let viewer: String
    let key: MediaLoadKey?
    let attrs: MediaAttrs
    let group: String?

    @Environment(\.adfMedia) private var media

    /// What the view is attached as; a change moves the attachment. The
    /// coordinator is compared by identity.
    struct Attachment: Equatable {
        let coordinator: MediaCoordinator?
        let viewer: String
        let key: MediaLoadKey?
        let attrs: MediaAttrs
        let group: String?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.coordinator === rhs.coordinator && lhs.viewer == rhs.viewer && lhs.key == rhs.key
                && lhs.attrs == rhs.attrs && lhs.group == rhs.group
        }
    }

    // The `if let` is constant for a document view (a provider or not), so
    // it never flips during scrolling; installing or removing a provider
    // rebuilds the media views once.
    func body(content: Content) -> some View {
        if let media {
            visibilityFeed(content, media)
                .onAppear { [viewer, key, attrs, group] in
                    if let key { media.attach(viewer: viewer, key: key, attrs: attrs, group: group) }
                }
                .onDisappear { [viewer] in media.detach(viewer: viewer) }
                .onChange(of: Attachment(coordinator: media, viewer: viewer, key: key, attrs: attrs, group: group)) { old, new in
                    Self.move(from: old, to: new)
                }
        } else {
            content
        }
    }

    /// The `#available` branch sits on the media view, inside its row —
    /// never at a lazy stack's per-item position (§18).
    @ViewBuilder
    private func visibilityFeed(_ content: Content, _ media: MediaCoordinator) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content.onScrollVisibilityChange(threshold: 0.01) { [viewer] visible in
                media.setViewerVisible(viewer, visible)
            }
        } else {
            content
        }
    }

    /// Moves a live view's attachment. Under one coordinator, viewer id and
    /// group, a key change is an `update` (the new key gains demand first, so
    /// a running load the two keys share is not cancelled); a first key
    /// attaches, a lost key detaches. Otherwise the old attachment goes and
    /// the new one comes, carrying the visibility the old one knew, since a
    /// view that stays on screen reports no new crossing.
    @MainActor
    static func move(from old: Attachment, to new: Attachment) {
        if old.coordinator === new.coordinator, old.viewer == new.viewer, old.group == new.group {
            switch (old.key, new.key) {
            case (.some, .some(let key)):
                new.coordinator?.update(viewer: new.viewer, key: key, attrs: new.attrs)
            case (.none, .some(let key)):
                new.coordinator?.attach(viewer: new.viewer, key: key, attrs: new.attrs, group: new.group)
            case (.some, .none):
                old.coordinator?.detach(viewer: old.viewer)
            case (.none, .none):
                break
            }
            return
        }
        let visible = old.coordinator?.knownVisibility(of: old.viewer)
        let attachNew = {
            if let key = new.key {
                new.coordinator?.attach(viewer: new.viewer, key: key, attrs: new.attrs, group: new.group, visible: visible)
            }
        }
        let detachOld = {
            if old.key != nil { old.coordinator?.detach(viewer: old.viewer) }
        }
        if old.coordinator === new.coordinator, old.viewer != new.viewer {
            // A new viewer id under one coordinator: attach first, so a key
            // both show never loses demand.
            attachNew()
            detachOld()
        } else {
            detachOld()
            attachNew()
        }
    }
}

struct MediaGroupVisibility: ViewModifier {
    let group: String

    @Environment(\.adfMedia) private var media

    struct Attachment: Equatable {
        let coordinator: MediaCoordinator?
        let group: String

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.coordinator === rhs.coordinator && lhs.group == rhs.group
        }
    }

    func body(content: Content) -> some View {
        if let media {
            visibilityFeed(content, media)
                .onAppear { [group] in media.attachGroup(group) }
                .onDisappear { [group] in media.detachGroup(group) }
                .onChange(of: Attachment(coordinator: media, group: group)) { old, new in
                    let visible = old.coordinator?.knownGroupVisibility(of: old.group)
                    old.coordinator?.detachGroup(old.group)
                    new.coordinator?.attachGroup(new.group, visible: visible)
                }
        } else {
            content
        }
    }

    @ViewBuilder
    private func visibilityFeed(_ content: Content, _ media: MediaCoordinator) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content.onScrollVisibilityChange(threshold: 0.01) { [group] visible in
                media.setGroupVisible(group, visible)
            }
        } else {
            content
        }
    }
}
