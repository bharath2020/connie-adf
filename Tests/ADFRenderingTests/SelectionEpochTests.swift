import Foundation
import SwiftUI
import Testing
import ADFPreparation
@testable import ADFRendering

/// Task 22 — the real `documentEpoch` (replacing the `documentRevision`
/// placeholder), the pure tail-append-vs-structural-change classifier, and
/// `SelectionState.clampedRange` — the mid-gesture cancel/clamp guard's pure
/// core. All macOS-runnable (no UIKit): `SelectionController` itself is
/// iOS-only, so its controller-level wiring (`documentDidChange()`, the
/// gesture-cancel path) is covered by the on-simulator verification instead.
@Suite("Selection epoch guard")
@MainActor
struct SelectionEpochTests {

    // MARK: Fixtures

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// Polls a main-actor condition with yields; fails fast instead of
    /// hanging. Mirrors `ADFDocumentSearchTests`'s helper of the same shape.
    private func waitUntil(
        _ what: Comment,
        timeoutIterations: Int = 2_000,
        _ condition: () -> Bool
    ) async throws {
        for _ in 0..<timeoutIterations {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("timed out waiting for \(what)")
        throw TestFailure("timeout: \(what)")
    }

    private let threeParagraphs = """
    {"version":1,"type":"doc","content":[
      {"type":"paragraph","content":[{"type":"text","text":"alpha"}]},
      {"type":"paragraph","content":[{"type":"text","text":"bravo"}]},
      {"type":"paragraph","content":[{"type":"text","text":"charlie"}]}
    ]}
    """

    private func readyModel(_ json: String) async throws -> ADFDocumentModel {
        let model = ADFDocumentModel()
        model.load(data: Data(json.utf8))
        try await waitUntil("document ready") { model.phase == .ready }
        return model
    }

    /// A minimal richText `RenderBlock` for mutation fixtures — the tests
    /// below only care about identity (`id`) and epoch bookkeeping, never
    /// rendered content.
    private func paragraphBlock(id: String, text: String) -> RenderBlock {
        RenderBlock(
            id: id,
            kind: .richText(
                segments: [.text(AttributedString(text))],
                style: TextBlockStyle(
                    font: .body, isHeading: false, headingLevel: nil,
                    alignment: nil, indentation: 0, breakout: nil
                )
            )
        )
    }

    // MARK: load() — monotonic, never reset

    @Test("load() bumps documentEpoch synchronously, and a reload bumps again without resetting to zero")
    func loadBumpsEpochMonotonically() {
        let model = ADFDocumentModel()
        #expect(model.documentEpoch == 0) // fresh, never loaded

        model.load(data: Data(threeParagraphs.utf8))
        let afterFirstLoad = model.documentEpoch
        #expect(afterFirstLoad == 1) // bumped exactly once, synchronously — no need to await `.ready`

        // A second load (a reload, possibly of a document that reuses the
        // SAME structural block IDs) bumps AGAIN rather than resetting to 0
        // like `documentRevision` — the spec's stated reason a monotonic
        // epoch is mandatory: a stale offset stamped against the FIRST
        // document's epoch must stay inert even though IDs can recur.
        model.load(data: Data(threeParagraphs.utf8))
        #expect(model.documentEpoch == 2)
    }

    @Test("load() fires onDocumentEpochChanged synchronously, once per load")
    func loadFiresEpochChangeCallback() {
        let model = ADFDocumentModel()
        var fireCount = 0
        model.onDocumentEpochChanged = { fireCount += 1 }
        model.load(data: Data(threeParagraphs.utf8))
        #expect(fireCount == 1)
        model.load(data: Data(threeParagraphs.utf8))
        #expect(fireCount == 2)
    }

    // MARK: scrollTarget — structural-navigation callback (A1, register #18)

    @Test("assigning a non-nil scrollTarget fires onScrollTargetChanged synchronously; nil does not")
    func scrollTargetFiresChangeCallbackOnlyForNonNil() {
        let model = ADFDocumentModel()
        var fireCount = 0
        model.onScrollTargetChanged = { fireCount += 1 }

        model.scrollTarget = "heading-3"      // a jump — fires
        #expect(fireCount == 1)

        model.scrollTarget = "heading-7"      // another jump — fires again
        #expect(fireCount == 2)

        model.scrollTarget = nil              // the consumer's clear — does NOT fire
        #expect(fireCount == 2)
    }

    @Test("load() clears scrollTarget to nil and never fires the structural-scroll callback")
    func loadDoesNotFireScrollTargetCallback() {
        let model = ADFDocumentModel()
        model.scrollTarget = "heading-3"
        var fireCount = 0
        model.onScrollTargetChanged = { fireCount += 1 } // wired AFTER the initial set
        model.load(data: Data(threeParagraphs.utf8))
        #expect(fireCount == 0)               // load() sets scrollTarget = nil only
        #expect(model.scrollTarget == nil)
    }

    // MARK: bumpDocumentEpochIfNeeded — pure tail append vs structural change

    @Test("an insert whose afterID is nil on an EMPTY document is a pure tail append — no bump")
    func pureTailAppendOnEmptyDocumentDoesNotBumpEpoch() {
        let model = ADFDocumentModel()
        #expect(model.lastItemID == nil)
        let before = model.documentEpoch
        model.bumpDocumentEpochIfNeeded(for: [
            .insert(ADFDocumentItem(id: "z", block: paragraphBlock(id: "z-block", text: "z")), afterID: nil)
        ])
        #expect(model.documentEpoch == before)
    }

    @Test("a single insert chained after the real last item is a pure tail append — no bump")
    func pureTailAppendDoesNotBumpEpoch() async throws {
        let model = try await readyModel(threeParagraphs)
        let lastID = try #require(model.lastItemID)
        let before = model.documentEpoch
        model.bumpDocumentEpochIfNeeded(for: [
            .insert(ADFDocumentItem(id: "d", block: paragraphBlock(id: "d-block", text: "delta")), afterID: lastID)
        ])
        #expect(model.documentEpoch == before)
    }

    @Test("a chained multi-insert batch, each appending after the previous, is still a pure tail append")
    func chainedMultiInsertTailAppendDoesNotBumpEpoch() async throws {
        let model = try await readyModel(threeParagraphs)
        let lastID = try #require(model.lastItemID)
        let before = model.documentEpoch
        model.bumpDocumentEpochIfNeeded(for: [
            .insert(ADFDocumentItem(id: "d", block: paragraphBlock(id: "d-block", text: "delta")), afterID: lastID),
            .insert(ADFDocumentItem(id: "e", block: paragraphBlock(id: "e-block", text: "echo")), afterID: "d"),
        ])
        #expect(model.documentEpoch == before)
    }

    @Test("an empty mutation batch is a no-op and never bumps")
    func emptyBatchDoesNotBumpEpoch() {
        let model = ADFDocumentModel()
        let before = model.documentEpoch
        model.bumpDocumentEpochIfNeeded(for: [])
        #expect(model.documentEpoch == before)
    }

    @Test("replace, remove, and move each bump the epoch")
    func replaceRemoveMoveBumpEpoch() async throws {
        let model = try await readyModel(threeParagraphs)
        let itemID = try #require(model.lastItemID)

        let e0 = model.documentEpoch
        model.bumpDocumentEpochIfNeeded(for: [
            .replace(itemID: itemID, block: paragraphBlock(id: itemID, text: "replaced"))
        ])
        #expect(model.documentEpoch > e0)

        let e1 = model.documentEpoch
        model.bumpDocumentEpochIfNeeded(for: [.remove(itemID: itemID)])
        #expect(model.documentEpoch > e1)

        let e2 = model.documentEpoch
        model.bumpDocumentEpochIfNeeded(for: [.move(itemID: itemID, afterID: nil)])
        #expect(model.documentEpoch > e2)
    }

    @Test("an insert anywhere but the tail bumps the epoch")
    func nonTailInsertBumpsEpoch() async throws {
        let model = try await readyModel(threeParagraphs)
        #expect(model.lastItemID != nil) // a non-empty document
        let before = model.documentEpoch
        // afterID: nil inserts at the BEGINNING, not after the real last
        // item — not a pure tail append.
        model.bumpDocumentEpochIfNeeded(for: [
            .insert(ADFDocumentItem(id: "mid", block: paragraphBlock(id: "mid-block", text: "mid")), afterID: nil)
        ])
        #expect(model.documentEpoch > before)
    }

    @Test("a batch mixing a tail insert with a structural mutation bumps (not pure)")
    func mixedBatchBumpsEpoch() async throws {
        let model = try await readyModel(threeParagraphs)
        let lastID = try #require(model.lastItemID)
        let before = model.documentEpoch
        model.bumpDocumentEpochIfNeeded(for: [
            .insert(ADFDocumentItem(id: "d", block: paragraphBlock(id: "d-block", text: "delta")), afterID: lastID),
            .remove(itemID: lastID),
        ])
        #expect(model.documentEpoch > before)
    }

    // MARK: apply() end-to-end — the real production path

    @Test("apply() with a replacement bumps the epoch via the replace-only fast path")
    func applyReplacementBumpsEpochViaFastPath() async throws {
        let model = try await readyModel(threeParagraphs)
        let itemID = try #require(model.blocks.first?.id)
        let before = model.documentEpoch
        try await model.apply(
            [.replace(itemID: itemID, block: paragraphBlock(id: itemID, text: "replaced"))],
            revision: 1
        )
        #expect(model.documentEpoch > before)
    }

    @Test("apply() with an insert bumps the epoch via the general (non-fast) path")
    func applyStructuralMutationBumpsEpochViaGeneralPath() async throws {
        let model = try await readyModel(threeParagraphs)
        let before = model.documentEpoch
        try await model.apply(
            [.insert(
                ADFDocumentItem(id: "inserted", block: paragraphBlock(id: "inserted-block", text: "new")),
                afterID: nil
            )],
            revision: 1
        )
        #expect(model.documentEpoch > before)
    }

    @Test("apply() fires onDocumentEpochChanged exactly once for a bumping batch")
    func applyFiresEpochChangeCallback() async throws {
        let model = try await readyModel(threeParagraphs)
        var fireCount = 0
        model.onDocumentEpochChanged = { fireCount += 1 }
        let itemID = try #require(model.blocks.first?.id)
        try await model.apply(
            [.replace(itemID: itemID, block: paragraphBlock(id: itemID, text: "replaced"))],
            revision: 1
        )
        #expect(fireCount == 1)
    }

    // MARK: SelectionState.clampedRange — the mid-gesture cancel/clamp core

    @Test("an epoch mismatch clears the range regardless of its bounds")
    func epochMismatchClears() {
        let state = SelectionState()
        state.utf16Range = 10..<20
        state.epoch = 5
        let cleared = SelectionState.clampedRange(
            state.utf16Range, stampEpoch: state.epoch, currentEpoch: 6, documentUTF16Length: 100
        )
        #expect(cleared == nil)
    }

    @Test("a same-epoch, in-bounds range passes through unchanged")
    func sameEpochInBoundsRangeIsKept() {
        let kept = SelectionState.clampedRange(
            0..<3, stampEpoch: 6, currentEpoch: 6, documentUTF16Length: 100
        )
        #expect(kept == 0..<3)
    }

    @Test("a same-epoch, out-of-range tail clamps into the document's new bounds")
    func sameEpochOutOfRangeTailClamps() {
        let clamped = SelectionState.clampedRange(
            90..<200, stampEpoch: 6, currentEpoch: 6, documentUTF16Length: 100
        )
        #expect(clamped == 90..<100)
    }

    @Test("a range that clamps to empty (fully past the new document end) clears instead of persisting a degenerate range")
    func clampingToEmptyClears() {
        let cleared = SelectionState.clampedRange(
            150..<200, stampEpoch: 6, currentEpoch: 6, documentUTF16Length: 100
        )
        #expect(cleared == nil)
    }

    @Test("a nil range is always nil, epoch match or not")
    func nilRangeStaysNil() {
        #expect(SelectionState.clampedRange(nil, stampEpoch: 6, currentEpoch: 6, documentUTF16Length: 100) == nil)
        #expect(SelectionState.clampedRange(nil, stampEpoch: 5, currentEpoch: 6, documentUTF16Length: 100) == nil)
    }
}
