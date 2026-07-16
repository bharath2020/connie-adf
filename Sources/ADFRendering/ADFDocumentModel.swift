import Foundation
import Observation
import SwiftUI
import ADFModel
import ADFPreparation

/// Loads one ADF document for rendering: parses off-main via `ADFParser`,
/// then streams `DocumentPreparer.prepareStream` chunks into `blocks` on the
/// main actor, so the first screenful appears while the tail prepares.
@Observable @MainActor
public final class ADFDocumentModel {
    public enum Phase: Equatable, Sendable {
        case idle
        case parsing
        case preparing
        case ready
        case failed(String)
    }

    public private(set) var blocks: [RenderBlock] = []
    public private(set) var phase: Phase = .idle
    /// Top-level headings (logical item ID, plain-text title, level 1–6) in
    /// document order — the data source for table-of-contents menus. Initial
    /// full loads use each prepared block ID as the logical item ID.
    public private(set) var headings: [(id: String, title: String, level: Int)] = []
    /// Monotonic revision of explicit incremental mutations. Full document
    /// loads reset it to zero.
    public private(set) var documentRevision: UInt64 = 0
    /// Lazy-stack sections over `blocks`, maintained incrementally in
    /// `append` so `ADFDocumentView.body` never rebuilds the section
    /// structure during scroll (§8: no O(document) work in `body`). A table's
    /// header slice starts a section (as its pinned header) containing the
    /// row slices of the same table; every other run of blocks is a
    /// headerless section. Section IDs are stable as chunks stream in,
    /// because blocks only ever append at the end.
    private(set) var sections: [BlockSection] = []

    /// Find-in-page controller for this document (`run`/`next`/`previous`/
    /// `clear`, streamed `matchCount`, highlight payload). One per model.
    public let search: ADFDocumentSearch

    /// Expand blocks currently open, keyed by block ID. Owned here (not view
    /// `@State`) so expansion survives rows collapsing to spacers, and so
    /// search navigation can open expands programmatically.
    public var expandedBlocks: Set<String> = []

    /// Set to a logical top-level item ID (typically a `headings` entry) to
    /// ask the visible `ADFDocumentView` to scroll there; initial full loads
    /// use block IDs. The view consumes and clears it.
    public var scrollTarget: String?

    /// Animation the reader applies when honoring `scrollTarget`. Defaults
    /// to `.snappy` (a TOC jump); hosts driving scripted scrolls can
    /// substitute e.g. a long `.linear` for constant-velocity movement.
    /// Configuration, not UI state — hence not observed.
    @ObservationIgnored public var scrollTargetAnimation: Animation = .snappy

    /// Placement for the next `scrollTarget` consume. Set BEFORE
    /// `scrollTarget` (the consumer observes only `scrollTarget`); the view
    /// resets it to `.top` together with clearing the target.
    /// Configuration, not UI state — hence not observed.
    @ObservationIgnored public var scrollTargetPlacement: ADFScrollTargetPlacement = .top

    /// Scroll-anchoring registry the document view binds `scrollPosition(id:)`
    /// through. Owned here (not view `@State`) so search can read the
    /// top-visible row without any geometry. See `ScrollAnchorRegistry`.
    @ObservationIgnored let anchors = ScrollAnchorRegistry()

    let theme: ADFTheme

    @ObservationIgnored private let parser = ADFParser()
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var itemIDs: [String] = []
    @ObservationIgnored private var storesByItemID: [String: DocumentBlockStore] = [:]
    @ObservationIgnored private var itemPositionByID: [String: Int] = [:]
    @ObservationIgnored private var blockOwnerByID: [String: String] = [:]

    public init(theme: ADFTheme = .default) {
        self.theme = theme
        self.search = ADFDocumentSearch()
        self.search.model = self
    }

    deinit {
        // The load task captures `self` weakly, so releasing the model can
        // reach deinit mid-stream; cancelling here stops the detached
        // preparer promptly instead of at the next chunk boundary.
        loadTask?.cancel()
    }

    /// Parses `data` and streams prepared blocks in chunks of 50. Safe to
    /// call again: a previous in-flight load is cancelled first.
    public func load(data: Data) {
        loadTask?.cancel()
        blocks = []
        itemIDs = []
        storesByItemID = [:]
        itemPositionByID = [:]
        blockOwnerByID = [:]
        sections = []
        headings = []
        documentRevision = 0
        scrollTarget = nil
        scrollTargetPlacement = .top
        expandedBlocks = []
        search.reset()
        phase = .parsing

        let parser = self.parser
        let preparer = DocumentPreparer(theme: theme)
        // `self` stays weak for the whole stream: holding it strongly across
        // the loop would keep the model (and the detached preparer feeding
        // it) alive after the owner releases it. Each iteration re-checks;
        // when the model is gone the loop exits, ending the stream and
        // cancelling its producer.
        loadTask = Task { [weak self] in
            let document: ADFDocument
            do {
                document = try await parser.parse(data)
            } catch {
                if !Task.isCancelled {
                    self?.phase = .failed(String(describing: error))
                }
                return
            }
            guard self != nil, !Task.isCancelled else { return }
            self?.phase = .preparing
            for await chunk in preparer.prepareStream(document, chunkSize: 50) {
                guard let self, !Task.isCancelled else { return }
                self.append(chunk)
            }
            if !Task.isCancelled {
                self?.phase = .ready
            }
        }
    }

    private func append(_ chunk: [RenderBlock]) {
        search.indexAppended(chunk, theme: theme)
        blocks.append(contentsOf: chunk)
        let newIDs = chunk.map(\.id)
        let initialPosition = itemIDs.count
        itemIDs.append(contentsOf: newIDs)
        var nextSections = sections
        var newHeadings: [(id: String, title: String, level: Int)] = []
        for (offset, pair) in zip(newIDs, chunk).enumerated() {
            let (itemID, block) = pair
            let store = DocumentBlockStore(id: itemID, block: block)
            storesByItemID[itemID] = store
            itemPositionByID[itemID] = initialPosition + offset
            blockOwnerByID[block.id] = itemID
            Self.append(store, to: &nextSections)
            guard case .richText(let segments, let style) = block.kind, style.isHeading else {
                continue
            }
            newHeadings.append(
                (id: itemID, title: Self.plainTitle(of: segments), level: style.headingLevel ?? 1)
            )
        }
        sections = nextSections
        headings.append(contentsOf: newHeadings)
    }

    /// Atomically applies a versioned batch of prepared top-level mutations,
    /// then incrementally re-indexes only inserted/replaced search items.
    public func apply(
        _ mutations: [ADFDocumentMutation],
        revision: UInt64
    ) async throws {
        guard phase == .ready else {
            throw ADFDocumentMutationError.documentNotReady
        }
        guard revision > documentRevision else {
            throw ADFDocumentMutationError.staleRevision(
                current: documentRevision,
                received: revision
            )
        }
        if try await applyReplacementBatchIfPossible(mutations, revision: revision) {
            return
        }

        var nextIDs = itemIDs
        var nextBlocks = blocks
        var touchedItemIDs: Set<String> = []
        for mutation in mutations {
            switch mutation {
            case .insert(let item, let anchorID):
                guard !nextIDs.contains(item.id) else {
                    throw ADFDocumentMutationError.duplicateItemID(item.id)
                }
                guard !nextBlocks.contains(where: { $0.id == item.block.id }) else {
                    throw ADFDocumentMutationError.duplicateBlockID(item.block.id)
                }
                let destination: Int
                if let anchorID {
                    guard let anchor = nextIDs.firstIndex(of: anchorID) else {
                        throw ADFDocumentMutationError.missingAnchorID(anchorID)
                    }
                    destination = anchor + 1
                } else {
                    destination = 0
                }
                nextIDs.insert(item.id, at: destination)
                nextBlocks.insert(item.block, at: destination)
                touchedItemIDs.insert(item.id)

            case .replace(let itemID, let block):
                guard let index = nextIDs.firstIndex(of: itemID) else {
                    throw ADFDocumentMutationError.missingItemID(itemID)
                }
                if let duplicate = nextBlocks.firstIndex(where: { $0.id == block.id }),
                   duplicate != index {
                    throw ADFDocumentMutationError.duplicateBlockID(block.id)
                }
                nextBlocks[index] = block
                touchedItemIDs.insert(itemID)

            case .remove(let itemID):
                guard let index = nextIDs.firstIndex(of: itemID) else {
                    throw ADFDocumentMutationError.missingItemID(itemID)
                }
                nextIDs.remove(at: index)
                nextBlocks.remove(at: index)
                touchedItemIDs.remove(itemID)

            case .move(let itemID, let anchorID):
                guard let source = nextIDs.firstIndex(of: itemID) else {
                    throw ADFDocumentMutationError.missingItemID(itemID)
                }
                if anchorID == itemID { continue }
                if let anchorID, !nextIDs.contains(anchorID) {
                    throw ADFDocumentMutationError.missingAnchorID(anchorID)
                }
                let movedID = nextIDs.remove(at: source)
                let movedBlock = nextBlocks.remove(at: source)
                let destination: Int
                if let anchorID, let anchor = nextIDs.firstIndex(of: anchorID) {
                    destination = anchor + 1
                } else {
                    destination = 0
                }
                nextIDs.insert(movedID, at: destination)
                nextBlocks.insert(movedBlock, at: destination)
            }
        }

        let oldPositionByID = Dictionary(uniqueKeysWithValues: itemIDs.indices.map { (itemIDs[$0], $0) })
        var requiresSectionRebuild = nextIDs != itemIDs
        var requiresHeadingRebuild = requiresSectionRebuild
        for (position, id) in nextIDs.enumerated() where touchedItemIDs.contains(id) {
            guard let oldPosition = oldPositionByID[id] else {
                requiresSectionRebuild = true
                requiresHeadingRebuild = true
                continue
            }
            let oldBlock = blocks[oldPosition]
            let newBlock = nextBlocks[position]
            if Self.sectionRole(of: oldBlock) != Self.sectionRole(of: newBlock) {
                requiresSectionRebuild = true
            }
            if Self.headingValue(id: id, block: oldBlock) != Self.headingValue(id: id, block: newBlock) {
                requiresHeadingRebuild = true
            }
        }

        let nextIDSet = Set(nextIDs)
        let removed = itemIDs.filter { !nextIDSet.contains($0) }
        let upserts = zip(nextIDs, nextBlocks).compactMap { id, block -> ADFDocumentSearch.ItemUpsert? in
            guard touchedItemIDs.contains(id) else { return nil }
            return ADFDocumentSearch.ItemUpsert(id: id, block: block)
        }

        itemIDs = nextIDs
        blocks = nextBlocks
        itemPositionByID = Dictionary(uniqueKeysWithValues: nextIDs.indices.map { (nextIDs[$0], $0) })
        blockOwnerByID = Dictionary(uniqueKeysWithValues: zip(nextBlocks.map(\.id), nextIDs))
        documentRevision = revision
        updateDerivedState(
            requiresSectionRebuild: requiresSectionRebuild,
            requiresHeadingRebuild: requiresHeadingRebuild,
            touchedItemIDs: touchedItemIDs
        )
        await search.applyIndexChanges(
            upserts: upserts,
            removedIDs: removed,
            order: nextIDs,
            theme: theme
        )
    }

    /// Replacement-only updates are the common live-edit path. Their item
    /// order cannot change, so validate and publish them without rebuilding
    /// document-wide identity/order sets.
    private func applyReplacementBatchIfPossible(
        _ mutations: [ADFDocumentMutation],
        revision: UInt64
    ) async throws -> Bool {
        guard mutations.allSatisfy({ mutation in
            if case .replace = mutation { return true }
            return false
        }) else {
            return false
        }
        guard !mutations.isEmpty else {
            documentRevision = revision
            return true
        }

        var nextBlocks = blocks
        var nextBlockOwners = blockOwnerByID
        var replacements: [String: RenderBlock] = [:]
        var replacementOrder: [String] = []
        for mutation in mutations {
            guard case .replace(let itemID, let block) = mutation,
                  let position = itemPositionByID[itemID] else {
                if case .replace(let itemID, _) = mutation {
                    throw ADFDocumentMutationError.missingItemID(itemID)
                }
                return false
            }
            if let owner = nextBlockOwners[block.id], owner != itemID {
                throw ADFDocumentMutationError.duplicateBlockID(block.id)
            }
            let previous = nextBlocks[position]
            if nextBlockOwners[previous.id] == itemID {
                nextBlockOwners.removeValue(forKey: previous.id)
            }
            nextBlockOwners[block.id] = itemID
            nextBlocks[position] = block
            if replacements[itemID] == nil { replacementOrder.append(itemID) }
            replacements[itemID] = block
        }

        var requiresSectionRebuild = false
        var requiresHeadingRebuild = false
        for itemID in replacementOrder {
            guard let position = itemPositionByID[itemID], let replacement = replacements[itemID] else {
                continue
            }
            let original = blocks[position]
            if Self.sectionRole(of: original) != Self.sectionRole(of: replacement) {
                requiresSectionRebuild = true
            }
            if Self.headingValue(id: itemID, block: original)
                != Self.headingValue(id: itemID, block: replacement) {
                requiresHeadingRebuild = true
            }
        }

        blocks = nextBlocks
        blockOwnerByID = nextBlockOwners
        documentRevision = revision
        for itemID in replacementOrder {
            if let block = replacements[itemID] {
                storesByItemID[itemID]?.block = block
            }
        }
        if requiresSectionRebuild {
            rebuildSections()
        }
        if requiresHeadingRebuild {
            rebuildHeadings()
        }

        let upserts = replacementOrder.compactMap { itemID in
            replacements[itemID].map { ADFDocumentSearch.ItemUpsert(id: itemID, block: $0) }
        }
        await search.applyIndexChanges(
            upserts: upserts,
            removedIDs: [],
            order: nil,
            theme: theme
        )
        return true
    }

    private func updateDerivedState(
        requiresSectionRebuild: Bool,
        requiresHeadingRebuild: Bool,
        touchedItemIDs: Set<String>
    ) {
        let retainedIDs = Set(itemIDs)
        for removedID in Array(storesByItemID.keys) where !retainedIDs.contains(removedID) {
            storesByItemID.removeValue(forKey: removedID)
        }
        for (itemID, block) in zip(itemIDs, blocks) where touchedItemIDs.contains(itemID) {
            if let store = storesByItemID[itemID] {
                store.block = block
            } else {
                storesByItemID[itemID] = DocumentBlockStore(id: itemID, block: block)
            }
        }

        if requiresSectionRebuild {
            rebuildSections()
        }
        if requiresHeadingRebuild {
            rebuildHeadings()
        }
    }

    private func rebuildSections() {
        var rebuilt: [BlockSection] = []
        for itemID in itemIDs {
            guard let store = storesByItemID[itemID] else { continue }
            Self.append(store, to: &rebuilt)
        }
        sections = rebuilt
    }

    private func rebuildHeadings() {
        headings = zip(itemIDs, blocks).compactMap { id, block in
            Self.headingValue(id: id, block: block).map { value in
                (id: value.id, title: value.title, level: value.level)
            }
        }
    }

    /// Extends `sections` with one appended block in O(1): a table header
    /// slice opens a new section, row slices join the table section they
    /// follow contiguously (header slice IDs are `"<tableID>#header"`, row
    /// slices `"<tableID>#rows<n>"`), and everything else joins the trailing
    /// headerless section.
    private static func append(_ store: DocumentBlockStore, to sections: inout [BlockSection]) {
        let block = store.block
        if case .tableSlice(_, _, isHeaderSlice: true) = block.kind {
            sections.append(BlockSection(id: store.id, header: store, blocks: []))
            return
        }
        if case .tableSlice(_, _, isHeaderSlice: false) = block.kind,
           let last = sections.last, let header = last.header,
           block.id.hasPrefix(String(header.block.id.prefix(while: { $0 != "#" })) + "#") {
            sections[sections.count - 1].blocks.append(store)
            return
        }
        if let last = sections.last, last.header == nil {
            sections[sections.count - 1].blocks.append(store)
        } else {
            sections.append(BlockSection(id: "plain-\(store.id)", header: nil, blocks: [store]))
        }
    }

    private enum SectionRole: Equatable {
        case tableHeader(String)
        case tableRows(String)
        case ordinary
    }

    private static func sectionRole(of block: RenderBlock) -> SectionRole {
        guard case .tableSlice(_, _, let isHeader) = block.kind else { return .ordinary }
        let tableID = String(block.id.prefix(while: { $0 != "#" }))
        return isHeader ? .tableHeader(tableID) : .tableRows(tableID)
    }

    private struct HeadingValue: Equatable {
        let id: String
        let title: String
        let level: Int
    }

    private static func headingValue(
        id: String,
        block: RenderBlock
    ) -> HeadingValue? {
        guard case .richText(let segments, let style) = block.kind, style.isHeading else {
            return nil
        }
        return HeadingValue(id: id, title: plainTitle(of: segments), level: style.headingLevel ?? 1)
    }

    private static func plainTitle(of segments: [InlineSegment]) -> String {
        var title = ""
        for segment in segments {
            switch segment {
            case .text(let text):
                title += String(text.characters)
            case .atom(let atom, _):
                title += atom.fallbackText
            }
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled heading" : trimmed
    }
}

/// One lazy-stack section: an optional pinned header (a table's header
/// slice) plus its content blocks.
@Observable @MainActor
final class DocumentBlockStore: Identifiable {
    let id: String
    var block: RenderBlock {
        didSet { revision &+= 1 }
    }
    private(set) var revision = 0

    init(id: String, block: RenderBlock) {
        self.id = id
        self.block = block
    }
}

struct BlockSection: Identifiable {
    let id: String
    let header: DocumentBlockStore?
    var blocks: [DocumentBlockStore]
}
