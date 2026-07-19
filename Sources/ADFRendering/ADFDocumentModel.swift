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
    /// Monotonic document generation (spec §7 "document epoch is mandatory",
    /// Task 22). Bumps once on every `load()` and on any `apply(_:revision:)`
    /// batch that is not a **pure tail append** — see
    /// `bumpDocumentEpochIfNeeded(for:)`. Unlike `documentRevision`, this is
    /// **never reset to zero**: it is monotonic across documents, so a stale
    /// offset stamped against a PRIOR document's epoch stays inert even when
    /// a freshly loaded document reuses the same structural block IDs (the
    /// spec's stated reason the epoch is mandatory, not just a revision
    /// counter). The selection engine stamps every range write with this
    /// value and treats a mismatch as "this range belongs to a document
    /// generation that no longer exists."
    public private(set) var documentEpoch: UInt64 = 0
    /// Fires synchronously, in the same call that bumped `documentEpoch`, so
    /// the (single, iOS-only) selection controller can clamp/clear its
    /// session before anything else runs on this run-loop turn — no runloop
    /// hop, so a bump landing mid-gesture is caught before the gesture's next
    /// touch event. A plain closure (not `Observation`): a per-touch-move
    /// selection write must never be on this notification path.
    @ObservationIgnored public var onDocumentEpochChanged: (() -> Void)?
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

    /// The read-only text-selection range (spec §7, phase 4 / Task 19). A
    /// plain non-observed box (the `anchors` pattern) so UIKit's per-touch-move
    /// `selectedTextRange` writes during a handle drag invalidate no SwiftUI
    /// state. Populated only under the TK2 selection flag; `nil` at rest.
    @ObservationIgnored public let selection = SelectionState()

    /// The ONE coarse Bool SwiftUI observes for selection — flips at session
    /// start/end only (like `search.isActive`), so idle rows never re-evaluate
    /// on a per-touch-move selection write. `false` at rest.
    public private(set) var selectionSessionActive = false
    func setSelectionSessionActive(_ active: Bool) { selectionSessionActive = active }

    let theme: ADFTheme
    /// Registered block plugins: matching during preparation (in registration
    /// order) and view resolution during rendering both read from here — one
    /// source of truth, so the two can never disagree.
    @ObservationIgnored let customRenderers: ADFCustomRendererRegistry

    @ObservationIgnored private let parser = ADFParser()
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var itemIDs: [String] = []
    @ObservationIgnored private var storesByItemID: [String: DocumentBlockStore] = [:]
    @ObservationIgnored private var itemPositionByID: [String: Int] = [:]
    @ObservationIgnored private var blockOwnerByID: [String: String] = [:]

    public init(
        theme: ADFTheme = .default,
        customRenderers: [any ADFCustomBlockRenderer] = []
    ) {
        self.theme = theme
        self.customRenderers = ADFCustomRendererRegistry(customRenderers)
        self.search = ADFDocumentSearch()
        self.search.model = self
    }

    /// The indexer every index build for this document must use — same theme,
    /// same plugins as the preparer, so expand bodies index exactly what the
    /// view renders.
    var searchIndexer: SearchIndexer {
        SearchIndexer(theme: theme, customPreparers: customRenderers.preparers)
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
        // Monotonic — never reset (see the property doc). Bumped once here,
        // synchronously, so a session left over from the PREVIOUS document is
        // invalidated before the async parse/prepare stream even starts.
        documentEpoch &+= 1
        onDocumentEpochChanged?()
        scrollTarget = nil
        scrollTargetPlacement = .top
        expandedBlocks = []
        search.reset()
        phase = .parsing

        let parser = self.parser
        let preparer = DocumentPreparer(theme: theme, customPreparers: customRenderers.preparers)
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
        search.indexAppended(chunk, indexer: searchIndexer)
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

        // MUST read `itemIDs` (still the PRE-mutation set) before it's
        // reassigned below — `bumpDocumentEpochIfNeeded` judges "pure tail
        // append" against the tail as it stood BEFORE this batch.
        bumpDocumentEpochIfNeeded(for: mutations)
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
            indexer: searchIndexer
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

        // A replacement batch is, by construction (the `allSatisfy` guard
        // above), never a pure tail append — every mutation here is
        // `.replace`, which changes content offsets, so it always bumps.
        bumpDocumentEpochIfNeeded(for: mutations)
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
            indexer: searchIndexer
        )
        return true
    }

    // MARK: Document epoch (Task 22 — spec §7)

    /// The last top-level item's logical ID in document order, or `nil` on an
    /// empty document — the tail reference `bumpDocumentEpochIfNeeded`
    /// compares an append's `afterID` against. `internal`: production callers
    /// never need it (only `apply`'s own bump call does, via `itemIDs`
    /// directly); exposed for the epoch-guard unit tests (`@testable`).
    var lastItemID: String? { itemIDs.last }

    /// Bumps `documentEpoch` unless `mutations` is a **pure tail append**:
    /// every mutation is `.insert(_, afterID:)`, and walking them in order,
    /// each one's `afterID` matches the accumulating tail — the document's
    /// real last item ID before this batch, then each newly appended item in
    /// turn. A single `.replace`/`.remove`/`.move`, or an `.insert` anywhere
    /// but the tail, fails this and bumps. An EMPTY batch is a no-op (nothing
    /// changed) and never bumps.
    ///
    /// Pure tail appends are end-stable: nothing before the append moved, so
    /// every existing selection offset (all of which point somewhere at or
    /// before the OLD tail) stays valid — the reason streaming `load()`
    /// growth and this case are exempt while every other structural change
    /// is not.
    ///
    /// Must be called while `itemIDs` still reflects the state BEFORE this
    /// batch's mutations are committed — `apply(_:revision:)` and
    /// `applyReplacementBatchIfPossible` both call this immediately before
    /// they publish `itemIDs`/`blocks`.
    func bumpDocumentEpochIfNeeded(for mutations: [ADFDocumentMutation]) {
        guard !isPureTailAppend(mutations) else { return }
        documentEpoch &+= 1
        onDocumentEpochChanged?()
    }

    private func isPureTailAppend(_ mutations: [ADFDocumentMutation]) -> Bool {
        guard !mutations.isEmpty else { return true }
        var tail = lastItemID
        for mutation in mutations {
            guard case .insert(let item, let afterID) = mutation, afterID == tail else { return false }
            tail = item.id
        }
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
