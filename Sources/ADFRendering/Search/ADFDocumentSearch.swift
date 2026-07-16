import Foundation
import Observation
import SwiftUI
import ADFPreparation

/// Find-in-page controller for one `ADFDocumentModel`. Text indexing,
/// matching, and span generation run off-main. Results are retained per
/// stable top-level item so a document mutation only rescans changed items.
@Observable @MainActor
public final class ADFDocumentSearch {
    public private(set) var query: String = ""
    public private(set) var matchCount: Int = 0
    public private(set) var currentIndex: Int?
    public private(set) var isSearching: Bool = false
    public private(set) var isActive: Bool = false

    /// Compatibility/debug snapshot. Rendering leaves consume stable
    /// owner-scoped stores instead, so observing one owner's highlights does
    /// not subscribe it to every result in the document.
    public var highlights: ADFSearchHighlights {
        _ = resultsVersion
        var spansByOwner: [String: [SearchHighlightSpan]] = [:]
        var matchedAtomIDs: Set<String> = []
        for result in resultsByItem.values {
            for (owner, spans) in result.spansByOwner {
                spansByOwner[owner, default: []].append(contentsOf: spans)
            }
            for atomIDs in result.atomIDsByOwner.values {
                matchedAtomIDs.formUnion(atomIDs)
            }
        }
        let current: ADFSearchHighlights.Current?
        if let location = currentLocation,
           let result = resultsByItem[location.itemID],
           result.matches.indices.contains(location.matchIndex),
           let item = index.item(id: location.itemID) {
            let match = result.matches[location.matchIndex]
            let unit = item.units[match.unitIndex]
            current = .init(
                ownerID: unit.ownerID,
                spans: match.painting.textSpans,
                atomIDs: Set(match.painting.atomIDs),
                generation: generation
            )
        } else {
            current = nil
        }
        return ADFSearchHighlights(
            spansByOwner: spansByOwner,
            matchedAtomIDs: matchedAtomIDs,
            current: current
        )
    }

    @ObservationIgnored public var scrollMargin: CGFloat = 40
    @ObservationIgnored public var debounceInterval: Duration = .milliseconds(200)

    @ObservationIgnored internal weak var model: ADFDocumentModel?
    @ObservationIgnored internal let visibleRows = VisibleRowRegistry()
    @ObservationIgnored private var index = IncrementalSearchIndex()
    @ObservationIgnored private var resultsByItem: [String: SearchIndexedItemResult] = [:]
    @ObservationIgnored private var ownerStores: [String: SearchOwnerHighlights] = [:]
    @ObservationIgnored private var activeOwnerIDs: Set<String> = []
    @ObservationIgnored private var currentLocation: MatchLocation?
    @ObservationIgnored private var blockOrder: [String: Int] = [:]
    @ObservationIgnored private var scannedItemCount = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var indexEpoch = 0
    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored private var activeScanQuery: String?
    private var resultsVersion = 0
    private let scanBatchSize = 256

    private struct MatchLocation: Equatable {
        let itemID: String
        let matchIndex: Int
    }

    struct ItemUpsert: Sendable {
        let id: String
        let block: RenderBlock
    }

    init() {}

    deinit {
        indexTask?.cancel()
        scanTask?.cancel()
        debounceTask?.cancel()
    }

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
            if self.debounceInterval > .zero {
                try? await Task.sleep(for: self.debounceInterval)
            }
            guard !Task.isCancelled else { return }
            self.startScan()
        }
    }

    public func next() {
        guard matchCount > 0 else { return }
        navigate(toGlobalIndex: ((currentIndex ?? -1) + 1) % matchCount)
    }

    public func previous() {
        guard matchCount > 0 else { return }
        navigate(toGlobalIndex: ((currentIndex ?? 0) - 1 + matchCount) % matchCount)
    }

    public func clear() {
        query = ""
        debounceTask?.cancel()
        clearResults()
    }

    // MARK: Index lifecycle

    func indexAppended(_ chunk: [RenderBlock], indexer: SearchIndexer) {
        let previous = indexTask
        let epoch = indexEpoch
        indexTask = Task { [weak self] in
            _ = await previous?.value
            guard !Task.isCancelled else { return }
            let newItems = await Task.detached(priority: .userInitiated) {
                chunk.map { block in
                    SearchIndexedItem(
                        id: block.id,
                        topLevelBlockID: block.id,
                        units: indexer.units(for: [block])
                    )
                }
            }.value
            guard let self, !Task.isCancelled, self.indexEpoch == epoch else { return }
            for item in newItems {
                try? self.index.append(item)
            }
            self.rebuildBlockOrder()
            self.scanAppendedItemsIfNeeded()
        }
    }

    /// Applies a prepared-block delta after the model has atomically committed
    /// its corresponding row update. Only upserted items are re-indexed and,
    /// when a query is settled, re-scanned.
    func applyIndexChanges(
        upserts: [ItemUpsert],
        removedIDs: [String],
        order: [String]?,
        indexer: SearchIndexer
    ) async {
        _ = await indexTask?.value
        let wasSearching = isSearching
        scanTask?.cancel()
        scanGeneration += 1
        isSearching = false

        let indexed = await Task.detached(priority: .userInitiated) {
            upserts.map { upsert in
                SearchIndexedItem(
                    id: upsert.id,
                    topLevelBlockID: upsert.id,
                    units: indexer.units(for: [upsert.block])
                )
            }
        }.value

        for id in removedIDs {
            _ = try? index.remove(id: id)
            removeResult(for: id)
        }
        for item in indexed {
            if index.item(id: item.id) == nil {
                try? index.append(item)
            } else {
                try? index.replace(item)
                removeResult(for: item.id)
            }
        }
        if let order {
            try? index.setOrder(order)
            rebuildBlockOrder()
        }
        scannedItemCount = index.count

        guard let activeQuery = activeScanQuery, activeQuery == query else {
            resultsVersion &+= 1
            return
        }
        if wasSearching {
            startScan()
            return
        }

        isSearching = true
        let changedResults = await Task.detached(priority: .userInitiated) {
            indexed.map { IncrementalSearchIndex.result(for: $0, query: activeQuery) }
        }.value
        applyResults(changedResults)
        isSearching = false
        restoreSelectionAfterMutation()
    }

    func reset() {
        indexTask?.cancel()
        indexTask = nil
        indexEpoch += 1
        index = IncrementalSearchIndex()
        blockOrder = [:]
        query = ""
        debounceTask?.cancel()
        clearResults()
    }

    // MARK: Scanning

    private func clearResults() {
        scanTask?.cancel()
        scanTask = nil
        scanGeneration += 1
        activeScanQuery = nil
        resetMatches()
        isSearching = false
        if isActive { isActive = false }
    }

    private func resetMatches() {
        for ownerID in activeOwnerIDs {
            ownerStores[ownerID]?.clear()
        }
        activeOwnerIDs = []
        resultsByItem = [:]
        matchCount = 0
        currentIndex = nil
        currentLocation = nil
        scannedItemCount = 0
        resultsVersion &+= 1
    }

    private func startScan() {
        scanTask?.cancel()
        scanGeneration += 1
        resetMatches()
        isSearching = true
        if !isActive { isActive = true }
        activeScanQuery = query
        let scanID = scanGeneration
        scanTask = Task { [weak self] in
            await self?.drainScan(scanID: scanID)
        }
    }

    private func scanAppendedItemsIfNeeded() {
        guard let active = activeScanQuery, active == query, !isSearching else { return }
        isSearching = true
        let scanID = scanGeneration
        scanTask = Task { [weak self] in
            await self?.drainScan(scanID: scanID)
        }
    }

    private func drainScan(scanID: Int) async {
        guard let query = activeScanQuery else { return }
        while scannedItemCount < index.count {
            let start = scannedItemCount
            let end = min(start + scanBatchSize, index.count)
            let ids = Array(index.itemOrder[start..<end])
            let items = ids.compactMap { index.item(id: $0) }
            let found = await Task.detached(priority: .userInitiated) {
                items.map { IncrementalSearchIndex.result(for: $0, query: query) }
            }.value
            guard !Task.isCancelled, scanGeneration == scanID, activeScanQuery == query else {
                return
            }
            scannedItemCount = end
            applyResults(found)
        }
        isSearching = false
        // Auto-select whenever the first result exists, including a result
        // that arrived in a tail index batch after an empty initial scan.
        if currentLocation == nil, matchCount > 0 {
            navigate(toGlobalIndex: initialSelectionIndex())
        }
    }

    private func applyResults(_ found: [SearchIndexedItemResult]) {
        guard !found.isEmpty else { return }
        var total = matchCount
        for result in found {
            if let previous = resultsByItem[result.itemID] {
                total -= previous.matches.count
                clearBaseHighlights(for: previous)
            }
            resultsByItem[result.itemID] = result
            total += result.matches.count
            publishBaseHighlights(for: result)
        }
        matchCount = total
        resultsVersion &+= 1
    }

    private func removeResult(for itemID: String) {
        guard let old = resultsByItem[itemID] else { return }
        if currentLocation?.itemID == itemID {
            clearCurrentOwner()
        }
        resultsByItem.removeValue(forKey: itemID)
        clearBaseHighlights(for: old)
        matchCount -= old.matches.count
        if currentLocation?.itemID == itemID {
            currentLocation = nil
            currentIndex = nil
        }
        resultsVersion &+= 1
    }

    private func publishBaseHighlights(for result: SearchIndexedItemResult) {
        let owners = Set(result.spansByOwner.keys).union(result.atomIDsByOwner.keys)
        for ownerID in owners {
            let store = ownerHighlights(for: ownerID)
            store.setBase(
                spans: result.spansByOwner[ownerID] ?? [],
                atomIDs: result.atomIDsByOwner[ownerID] ?? []
            )
            activeOwnerIDs.insert(ownerID)
        }
    }

    private func clearBaseHighlights(for result: SearchIndexedItemResult) {
        let owners = Set(result.spansByOwner.keys).union(result.atomIDsByOwner.keys)
        for ownerID in owners {
            ownerHighlights(for: ownerID).setBase(spans: [], atomIDs: [])
        }
    }

    // MARK: Navigation

    private func initialSelectionIndex() -> Int {
        guard let topRow = model?.anchors.topRow,
              let topOrder = blockOrder[topRow] else { return 0 }
        var prefix = 0
        for (itemIndex, itemID) in index.itemOrder.enumerated() {
            let count = resultsByItem[itemID]?.matches.count ?? 0
            if itemIndex >= topOrder, count > 0 { return prefix }
            prefix += count
        }
        return 0
    }

    private func location(atGlobalIndex target: Int) -> MatchLocation? {
        guard target >= 0, target < matchCount else { return nil }
        var remaining = target
        for itemID in index.itemOrder {
            let count = resultsByItem[itemID]?.matches.count ?? 0
            if remaining < count {
                return MatchLocation(itemID: itemID, matchIndex: remaining)
            }
            remaining -= count
        }
        return nil
    }

    private func globalIndex(of location: MatchLocation) -> Int? {
        var prefix = 0
        for itemID in index.itemOrder {
            if itemID == location.itemID {
                guard let result = resultsByItem[itemID],
                      result.matches.indices.contains(location.matchIndex) else { return nil }
                return prefix + location.matchIndex
            }
            prefix += resultsByItem[itemID]?.matches.count ?? 0
        }
        return nil
    }

    private func navigate(toGlobalIndex index: Int) {
        guard let location = location(atGlobalIndex: index),
              let model,
              let result = resultsByItem[location.itemID],
              let item = self.index.item(id: location.itemID),
              result.matches.indices.contains(location.matchIndex) else { return }

        clearCurrentOwner()
        currentLocation = location
        currentIndex = index
        let match = result.matches[location.matchIndex]
        let unit = item.units[match.unitIndex]
        generation += 1
        let store = ownerHighlights(for: unit.ownerID)
        store.setCurrent(
            spans: match.painting.textSpans,
            atomIDs: Set(match.painting.atomIDs),
            generation: generation
        )
        activeOwnerIDs.insert(unit.ownerID)
        resultsVersion &+= 1

        let needsExpansion = !unit.expandAncestorIDs.allSatisfy(model.expandedBlocks.contains)
        if needsExpansion {
            model.expandedBlocks.formUnion(unit.expandAncestorIDs)
        }
        let target = unit.topLevelBlockID
        if !needsExpansion, visibleRows.isVisible(target) { return }

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
        model.scrollTargetPlacement = placement
        model.scrollTarget = target
    }

    private func clearCurrentOwner() {
        guard let location = currentLocation,
              let result = resultsByItem[location.itemID],
              result.matches.indices.contains(location.matchIndex),
              let item = index.item(id: location.itemID) else { return }
        let match = result.matches[location.matchIndex]
        ownerStores[item.units[match.unitIndex].ownerID]?.clearCurrent()
    }

    private func restoreSelectionAfterMutation() {
        if let location = currentLocation,
           let global = globalIndex(of: location) {
            currentIndex = global
            resultsVersion &+= 1
            return
        }
        currentLocation = nil
        currentIndex = nil
        if matchCount > 0 {
            navigate(toGlobalIndex: initialSelectionIndex())
        }
    }

    private func rebuildBlockOrder() {
        blockOrder = [:]
        for (position, itemID) in index.itemOrder.enumerated() {
            guard let item = index.item(id: itemID) else { continue }
            blockOrder[item.topLevelBlockID] = position
        }
    }

    // MARK: Leaf state

    func ownerHighlights(for ownerID: String) -> SearchOwnerHighlights {
        if let existing = ownerStores[ownerID] { return existing }
        let store = SearchOwnerHighlights()
        ownerStores[ownerID] = store
        return store
    }
}
