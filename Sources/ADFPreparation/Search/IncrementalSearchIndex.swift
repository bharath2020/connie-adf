import Foundation

/// One independently replaceable top-level search item. `id` is a logical
/// identity supplied by the document update stream; it must not be a
/// structural array position when inserts and removals are possible.
public struct SearchIndexedItem: Sendable, Hashable, Identifiable {
    public let id: String
    public let topLevelBlockID: String
    public let units: [SearchTextUnit]

    public init(id: String, topLevelBlockID: String? = nil, units: [SearchTextUnit]) {
        let resolvedTopLevelID = topLevelBlockID ?? units.first?.topLevelBlockID ?? id
        self.id = id
        self.topLevelBlockID = resolvedTopLevelID
        if topLevelBlockID == nil {
            self.units = units
        } else {
            self.units = units.map { unit in
                SearchTextUnit(
                    ownerID: unit.ownerID,
                    topLevelBlockID: resolvedTopLevelID,
                    expandAncestorIDs: unit.expandAncestorIDs,
                    plainText: unit.plainText,
                    parts: unit.parts
                )
            }
        }
    }
}

/// A match addressed within one independently replaceable search item.
public struct SearchIndexedItemMatch: Sendable, Hashable {
    public let unitIndex: Int
    public let range: Range<Int>
    public let painting: SearchMatchPainting

    public init(unitIndex: Int, range: Range<Int>, painting: SearchMatchPainting) {
        self.unitIndex = unitIndex
        self.range = range
        self.painting = painting
    }
}

/// Query results for one item, including owner-grouped payloads that can be
/// published as a delta without rebuilding a document-wide highlight map.
public struct SearchIndexedItemResult: Sendable, Equatable {
    public let itemID: String
    public let matches: [SearchIndexedItemMatch]
    public let spansByOwner: [String: [SearchHighlightSpan]]
    public let atomIDsByOwner: [String: Set<String>]

    public init(
        itemID: String,
        matches: [SearchIndexedItemMatch],
        spansByOwner: [String: [SearchHighlightSpan]],
        atomIDsByOwner: [String: Set<String>]
    ) {
        self.itemID = itemID
        self.matches = matches
        self.spansByOwner = spansByOwner
        self.atomIDsByOwner = atomIDsByOwner
    }
}

public enum IncrementalSearchIndexError: Error, Equatable, Sendable {
    case duplicateItem(String)
    case missingItem(String)
    case invalidAnchor(String)
}

/// Ordered, independently replaceable search corpus. Mutations touch only
/// the changed item's text units; ordering metadata remains a compact array.
public struct IncrementalSearchIndex: Sendable {
    public private(set) var itemOrder: [String] = []
    private var itemsByID: [String: SearchIndexedItem] = [:]

    public init() {}

    public var count: Int { itemOrder.count }

    public func item(id: String) -> SearchIndexedItem? {
        itemsByID[id]
    }

    public var orderedItems: [SearchIndexedItem] {
        itemOrder.compactMap { itemsByID[$0] }
    }

    public mutating func append(_ item: SearchIndexedItem) throws {
        guard itemsByID[item.id] == nil else {
            throw IncrementalSearchIndexError.duplicateItem(item.id)
        }
        itemsByID[item.id] = item
        itemOrder.append(item.id)
    }

    /// Inserts after `anchorID`; nil means the beginning of the document.
    public mutating func insert(
        _ item: SearchIndexedItem,
        after anchorID: String?
    ) throws {
        guard itemsByID[item.id] == nil else {
            throw IncrementalSearchIndexError.duplicateItem(item.id)
        }
        let insertionIndex: Int
        if let anchorID {
            guard let anchorIndex = itemOrder.firstIndex(of: anchorID) else {
                throw IncrementalSearchIndexError.invalidAnchor(anchorID)
            }
            insertionIndex = anchorIndex + 1
        } else {
            insertionIndex = 0
        }
        itemsByID[item.id] = item
        itemOrder.insert(item.id, at: insertionIndex)
    }

    public mutating func replace(_ item: SearchIndexedItem) throws {
        guard itemsByID[item.id] != nil else {
            throw IncrementalSearchIndexError.missingItem(item.id)
        }
        itemsByID[item.id] = item
    }

    @discardableResult
    public mutating func remove(id: String) throws -> SearchIndexedItem {
        guard let old = itemsByID.removeValue(forKey: id),
              let index = itemOrder.firstIndex(of: id) else {
            throw IncrementalSearchIndexError.missingItem(id)
        }
        itemOrder.remove(at: index)
        return old
    }

    /// Moves after `anchorID`; nil means the beginning of the document.
    public mutating func move(id: String, after anchorID: String?) throws {
        guard let oldIndex = itemOrder.firstIndex(of: id) else {
            throw IncrementalSearchIndexError.missingItem(id)
        }
        if anchorID == id { return }
        if let anchorID, !itemOrder.contains(anchorID) {
            throw IncrementalSearchIndexError.invalidAnchor(anchorID)
        }
        itemOrder.remove(at: oldIndex)
        let destination: Int
        if let anchorID, let anchorIndex = itemOrder.firstIndex(of: anchorID) {
            destination = anchorIndex + 1
        } else {
            destination = 0
        }
        itemOrder.insert(id, at: destination)
    }

    /// Replaces document order without rebuilding any item's text index.
    public mutating func setOrder(_ ids: [String]) throws {
        let expected = Set(itemsByID.keys)
        guard ids.count == expected.count, Set(ids) == expected else {
            let missing = expected.subtracting(ids).first
                ?? Set(ids).subtracting(expected).first
                ?? "unknown"
            throw IncrementalSearchIndexError.missingItem(missing)
        }
        itemOrder = ids
    }

    public func result(for itemID: String, query: String) -> SearchIndexedItemResult? {
        guard let item = itemsByID[itemID] else { return nil }
        return Self.result(for: item, query: query)
    }

    public func results(query: String) -> [SearchIndexedItemResult] {
        orderedItems.map { Self.result(for: $0, query: query) }
    }

    /// Pure item scan used both by the controller's detached tasks and by the
    /// benchmark harness. Span generation is linear per unit.
    public static func result(
        for item: SearchIndexedItem,
        query: String
    ) -> SearchIndexedItemResult {
        var matches: [SearchIndexedItemMatch] = []
        var spansByOwner: [String: [SearchHighlightSpan]] = [:]
        var atomIDsByOwner: [String: Set<String>] = [:]

        for (unitIndex, unit) in item.units.enumerated() {
            let ranges = SearchMatcher.matchRanges(in: unit.plainText, query: query)
            let paintings = SearchMatcher.spans(for: ranges, in: unit)
            for (range, painting) in zip(ranges, paintings) {
                matches.append(SearchIndexedItemMatch(
                    unitIndex: unitIndex,
                    range: range,
                    painting: painting
                ))
                if !painting.textSpans.isEmpty {
                    spansByOwner[unit.ownerID, default: []].append(contentsOf: painting.textSpans)
                }
                if !painting.atomIDs.isEmpty {
                    atomIDsByOwner[unit.ownerID, default: []].formUnion(painting.atomIDs)
                }
            }
        }
        return SearchIndexedItemResult(
            itemID: item.id,
            matches: matches,
            spansByOwner: spansByOwner,
            atomIDsByOwner: atomIDsByOwner
        )
    }
}
