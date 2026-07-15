import Foundation
import Observation
import SwiftUI
import ADFPreparation

/// Find-in-page controller for one `ADFDocumentModel`, exposed as
/// `model.search`. Indexing and matching run OFF the main actor over the
/// `Sendable` prepared blocks; only compact results are published back here.
/// Match counts stream: they keep climbing while the scan (or the document
/// itself) is still loading.
@Observable @MainActor
public final class ADFDocumentSearch {
    // MARK: Observable metadata (the embedder's UI surface)

    public private(set) var query: String = ""
    public private(set) var matchCount: Int = 0
    /// 0-based position of the current match in document order; nil = none.
    public private(set) var currentIndex: Int?
    /// True while a scan (or the index build feeding it) is in flight.
    public private(set) var isSearching: Bool = false
    /// Highlight payload consumed by leaf text views via the environment.
    public private(set) var highlights: ADFSearchHighlights = .none

    // MARK: Configuration

    /// Viewport inset (points) left above/below a match when scrolling to it.
    @ObservationIgnored public var scrollMargin: CGFloat = 40
    /// Delay between `run(_:)` and the scan starting. `.zero` scans at once.
    @ObservationIgnored public var debounceInterval: Duration = .milliseconds(200)

    // MARK: Internal state (never observed — doctrine: high-frequency data
    // lives outside the observation graph)

    @ObservationIgnored internal weak var model: ADFDocumentModel?
    @ObservationIgnored internal let visibleRows = VisibleRowRegistry()
    @ObservationIgnored private var units: [SearchTextUnit] = []
    @ObservationIgnored private var matches: [SearchMatch] = []
    @ObservationIgnored private var blockOrder: [String: Int] = [:]
    @ObservationIgnored private var baseSpans: [String: [SearchHighlightSpan]] = [:]
    @ObservationIgnored private var baseAtoms: Set<String> = []
    @ObservationIgnored private var scannedUnitCount = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    private let scanBatchSize = 256

    public init() {}

    deinit {
        indexTask?.cancel()
        scanTask?.cancel()
        debounceTask?.cancel()
    }

    // MARK: Public API

    /// Sets the query and (after the debounce) restarts the scan. Re-running
    /// the current query is a no-op; an empty query clears.
    public func run(_ query: String) {
        guard query != self.query else { return }
        self.query = query
        debounceTask?.cancel()
        guard !query.isEmpty else {
            clearResults()
            return
        }
        debounceTask = Task { [weak self] in
            guard let self else { return }
            if let interval = self.debounceIntervalIfPositive() {
                try? await Task.sleep(for: interval)
            }
            guard !Task.isCancelled else { return }
            self.startScan()
        }
    }

    public func next() {
        guard !matches.isEmpty else { return }
        navigate(to: ((currentIndex ?? -1) + 1) % matches.count)
    }

    public func previous() {
        guard !matches.isEmpty else { return }
        navigate(to: ((currentIndex ?? 0) - 1 + matches.count) % matches.count)
    }

    /// Ends the search: clears query, results, and every highlight.
    public func clear() {
        query = ""
        debounceTask?.cancel()
        clearResults()
    }

    // MARK: Model hooks (internal)

    /// Called by the model for every appended chunk of top-level blocks.
    /// Index building chains sequentially off-main; an active query scans
    /// the new units as they land, so counts stream during document load.
    func indexAppended(_ chunk: [RenderBlock], theme: ADFTheme) {
        for block in chunk where blockOrder[block.id] == nil {
            blockOrder[block.id] = blockOrder.count
        }
        let previous = indexTask
        indexTask = Task { [weak self] in
            _ = await previous?.value
            guard !Task.isCancelled else { return }
            let indexer = SearchIndexer(theme: theme)
            let newUnits = await Task.detached(priority: .userInitiated) {
                indexer.units(for: chunk)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.units.append(contentsOf: newUnits)
            self.scanAppendedUnitsIfNeeded()
        }
    }

    /// Called on document (re)load: drops the index and every result.
    func reset() {
        indexTask?.cancel()
        indexTask = nil
        query = ""
        debounceTask?.cancel()
        units = []
        blockOrder = [:]
        clearResults()
    }

    // MARK: Scanning

    private func debounceIntervalIfPositive() -> Duration? {
        debounceInterval > .zero ? debounceInterval : nil
    }

    private func clearResults() {
        scanTask?.cancel()
        scanTask = nil
        matches = []
        matchCount = 0
        currentIndex = nil
        isSearching = false
        baseSpans = [:]
        baseAtoms = []
        scannedUnitCount = 0
        highlights = .none
    }

    private func startScan() {
        scanTask?.cancel()
        matches = []
        matchCount = 0
        currentIndex = nil
        baseSpans = [:]
        baseAtoms = []
        scannedUnitCount = 0
        highlights = .none
        isSearching = true
        scanTask = Task { [weak self] in
            await self?.drainScan(autoSelect: true)
        }
    }

    /// New units arrived while a query is active: resume scanning the tail.
    /// If a scan loop is already running it re-checks `units.count` each
    /// iteration and picks the tail up itself.
    private func scanAppendedUnitsIfNeeded() {
        guard !query.isEmpty, !isSearching else { return }
        isSearching = true
        scanTask = Task { [weak self] in
            await self?.drainScan(autoSelect: false)
        }
    }

    /// Scans units in batches; matching runs detached, results append on the
    /// main actor between batches — that is the "streamed counts" surface.
    private func drainScan(autoSelect: Bool) async {
        while scannedUnitCount < units.count {
            let start = scannedUnitCount
            let end = min(start + scanBatchSize, units.count)
            let batch = Array(units[start..<end])
            let query = self.query
            let found = await Task.detached(priority: .userInitiated) {
                SearchMatcher.matches(in: batch, unitIndexOffset: start, query: query)
            }.value
            guard !Task.isCancelled else { return }
            scannedUnitCount = end
            appendMatches(found)
        }
        isSearching = false
        if autoSelect, currentIndex == nil, !matches.isEmpty {
            navigate(to: initialSelectionIndex())
        }
    }

    private func appendMatches(_ found: [SearchMatch]) {
        guard !found.isEmpty else { return }
        matches.append(contentsOf: found)
        matchCount = matches.count
        for match in found {
            let unit = units[match.unitIndex]
            let painted = SearchMatcher.spans(for: match.range, in: unit)
            if !painted.textSpans.isEmpty {
                baseSpans[unit.ownerID, default: []].append(contentsOf: painted.textSpans)
            }
            baseAtoms.formUnion(painted.atomIDs)
        }
        highlights = ADFSearchHighlights(
            spansByOwner: baseSpans,
            matchedAtomIDs: baseAtoms,
            current: highlights.current
        )
    }

    // MARK: Navigation

    /// Browser behavior: the first match at/after the current viewport top.
    private func initialSelectionIndex() -> Int {
        guard let topRow = model?.anchors.topRow, let topOrder = blockOrder[topRow] else {
            return 0
        }
        return matches.firstIndex { match in
            (blockOrder[units[match.unitIndex].topLevelBlockID] ?? .max) >= topOrder
        } ?? 0
    }

    private func navigate(to index: Int) {
        guard let model, matches.indices.contains(index) else { return }
        currentIndex = index
        let match = matches[index]
        let unit = units[match.unitIndex]
        let painted = SearchMatcher.spans(for: match.range, in: unit)
        generation += 1
        highlights = ADFSearchHighlights(
            spansByOwner: baseSpans,
            matchedAtomIDs: baseAtoms,
            current: .init(
                ownerID: unit.ownerID,
                spans: painted.textSpans,
                atomIDs: Set(painted.atomIDs),
                generation: generation
            )
        )

        // Matches inside collapsed expands: open every ancestor first. The
        // expand needs a layout pass to reveal the body, so always scroll.
        let needsExpansion = !unit.expandAncestorIDs.allSatisfy(model.expandedBlocks.contains)
        if needsExpansion {
            model.expandedBlocks.formUnion(unit.expandAncestorIDs)
        }

        let target = unit.topLevelBlockID
        if !needsExpansion, visibleRows.isVisible(target) {
            return // On screen: restyle + flash only, no scroll.
        }
        let placement: ADFScrollTargetPlacement
        if let topRow = model.anchors.topRow,
           let topOrder = blockOrder[topRow],
           let targetOrder = blockOrder[target],
           targetOrder < topOrder {
            placement = .nearTop(margin: scrollMargin)
        } else if model.anchors.topRow == nil || blockOrder[model.anchors.topRow ?? ""] == nil {
            placement = .nearTop(margin: scrollMargin)
        } else {
            placement = .nearBottom(margin: scrollMargin)
        }
        model.scrollTargetPlacement = placement // BEFORE scrollTarget (observed).
        model.scrollTarget = target
    }
}
