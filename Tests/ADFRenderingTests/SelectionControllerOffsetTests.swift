import Foundation
import CoreGraphics
import Testing
import ADFPreparation
@testable import ADFRendering

/// MacOS-runnable core of the Task 19 `SelectionController`: the UTF-16 offset
/// arithmetic, the grapheme-boundary ingestion guard (Task 18 review #1), and
/// the geometry resolver's per-owner rect splitting + collapsed-row
/// interpolation. Geometry is injected via a fixed-rect `SelectionGeometrySource`
/// stub, so `selectionRects` / `closestPosition` math is exercised without
/// `UITextInteraction` (iOS-only). See `SelectionControllerSimTests` conceptual
/// coverage for the interaction wiring itself.
@MainActor
@Suite("SelectionController offsets & geometry")
struct SelectionControllerOffsetTests {

    // MARK: Fixtures

    private func textUnit(owner: String, _ text: String, expands: [String] = []) -> SearchTextUnit {
        SearchTextUnit(ownerID: owner, topLevelBlockID: owner, expandAncestorIDs: expands,
                       plainText: text,
                       parts: [.init(source: .textSegment(index: 0), range: 0..<text.count)])
    }
    private func item(_ id: String, _ units: [SearchTextUnit]) -> SearchIndexedItem {
        SearchIndexedItem(id: id, topLevelBlockID: id, units: units)
    }

    /// A fixed-rect geometry source: live owners return one preset rect per
    /// slice; collapsed owners are absent from `liveOwners` and drive
    /// interpolation from `brackets`.
    private final class FakeGeometrySource: SelectionGeometrySource {
        var liveOwners: Set<String> = []
        var ownerRects: [String: CGRect] = [:]
        var brackets: [Int: (above: CGRect?, below: CGRect?)] = [:]
        var caretRects: [String: CGRect] = [:]
        var closest: (ownerID: String, source: SearchTextUnit.Part.Source, localCharOffset: Int)?

        func isLive(ownerID: String) -> Bool { liveOwners.contains(ownerID) }
        func rects(ownerID: String, slice: SelectionTextModel.PartSlice) -> [CGRect] {
            guard liveOwners.contains(ownerID), let rect = ownerRects[ownerID] else { return [] }
            return [rect]
        }
        func caretRect(ownerID: String, anchor: SelectionTextModel.CaretAnchor) -> CGRect? {
            caretRects[ownerID]
        }
        func closestRowAnchor(
            toContainerPoint point: CGPoint
        ) -> (ownerID: String, source: SearchTextUnit.Part.Source, localCharOffset: Int)? { closest }
        func bracketingLiveFrames(order: Int) -> (above: CGRect?, below: CGRect?) {
            brackets[order] ?? (nil, nil)
        }
    }

    private func resolver(_ model: SelectionTextModel, _ source: FakeGeometrySource) -> SelectionGeometryResolver {
        SelectionGeometryResolver(model: model, source: source, isVisible: { _ in true })
    }

    // MARK: The spec's named regression — word-select past a non-BMP scalar

    @Test func wordSelectAfterNonBMPScalarStaysAligned() {
        // "a😄 word": 😄 is a 2-UTF-16-unit surrogate pair. UTF-16 offsets:
        // a=0, 😄=[1,3), space=[3,4), word=[4,8).
        let model = SelectionTextModel.build(orderedItems: [
            item("b0", [textUnit(owner: "b0", "a😄 word")])
        ])
        #expect(model.totalUTF16Length == 8)

        // The word "word" — the range the tokenizer produces (computed via the
        // model) copies back to exactly "word" across the non-BMP scalar.
        #expect(model.text(inUTF16: 4..<8, isVisible: { _ in true }) == "word")
        // And selecting the emoji cluster copies the whole scalar, never half a
        // surrogate.
        #expect(model.text(inUTF16: 0..<3, isVisible: { _ in true }) == "a😄")

        // A gesture landing at UTF-16 offset 2 (mid-😄) must snap to a grapheme
        // boundary before entering the model — the ingestion guard. Offset 2 is
        // equidistant from the pair's edges (1 and 3); the nearer-edge rule
        // resolves the tie to the lower edge.
        #expect(model.snapToGraphemeBoundary(2) == 1)
        // Boundaries (0, unit end, and offsets already aligned) pass through.
        #expect(model.snapToGraphemeBoundary(0) == 0)
        #expect(model.snapToGraphemeBoundary(4) == 4)
        #expect(model.snapToGraphemeBoundary(8) == 8)
    }

    // MARK: Collapsed-owner interpolation

    @Test func collapsedOwnerInterpolatesBetweenLiveNeighbors() {
        let model = SelectionTextModel.build(orderedItems: [
            item("b0", [textUnit(owner: "b0", "first")]),
            item("b1", [textUnit(owner: "b1", "middle")]),  // collapsed
            item("b2", [textUnit(owner: "b2", "last")]),
        ])
        let source = FakeGeometrySource()
        source.liveOwners = ["b0", "b2"]  // b1 not live → interpolated
        source.ownerRects["b0"] = CGRect(x: 0, y: 0, width: 100, height: 20)
        source.ownerRects["b2"] = CGRect(x: 0, y: 60, width: 100, height: 20)
        // b1's document order is its unit index (1).
        source.brackets[1] = (above: CGRect(x: 0, y: 0, width: 100, height: 20),
                              below: CGRect(x: 0, y: 60, width: 100, height: 20))

        let rects = resolver(model, source).selectionRects(forUTF16: 0..<model.totalUTF16Length)
        #expect(rects.count == 3)
        let collapsed = rects[1].rect  // b1's synthesized rect, in document order
        // Lies strictly between the two live neighbors and is non-empty.
        #expect(collapsed.minY >= 20)
        #expect(collapsed.maxY <= 60)
        #expect(collapsed.height > 0)
        #expect(collapsed.width > 0)
    }

    // MARK: containsStart / containsEnd from range membership

    @Test func containsStartEndFromRangeMembership() {
        let model = SelectionTextModel.build(orderedItems: [
            item("b0", [textUnit(owner: "b0", "alpha")]),
            item("b1", [textUnit(owner: "b1", "bravo")]),
            item("b2", [textUnit(owner: "b2", "charlie")]),
        ])
        let source = FakeGeometrySource()
        source.liveOwners = ["b0", "b1", "b2"]
        // Insert rects in REVERSE document order to prove membership, not
        // insertion order, drives the endpoint handles.
        source.ownerRects["b2"] = CGRect(x: 0, y: 40, width: 100, height: 20)
        source.ownerRects["b1"] = CGRect(x: 0, y: 20, width: 100, height: 20)
        source.ownerRects["b0"] = CGRect(x: 0, y: 0, width: 100, height: 20)

        let rects = resolver(model, source).selectionRects(forUTF16: 0..<model.totalUTF16Length)
        #expect(rects.count == 3)
        // First owner (b0) owns the start handle; last owner (b2) the end handle.
        #expect(rects[0].containsStart == true)
        #expect(rects[0].containsEnd == false)
        #expect(rects[1].containsStart == false)
        #expect(rects[1].containsEnd == false)
        #expect(rects[2].containsStart == false)
        #expect(rects[2].containsEnd == true)
    }

    // MARK: closestPosition lifts a row anchor to a global offset and snaps

    @Test func closestOffsetLiftsRowAnchorToGlobalAndSnapsAcrossAtom() {
        // "@Bharath done": atom part [0,8) (fallbackText), text " done" [8,13).
        let atomUnit = SearchTextUnit(
            ownerID: "b0", topLevelBlockID: "b0", expandAncestorIDs: [],
            plainText: "@Bharath done",
            parts: [.init(source: .atom(id: "m1"), range: 0..<8),
                    .init(source: .textSegment(index: 1), range: 8..<13)])
        let model = SelectionTextModel.build(orderedItems: [item("b0", [atomUnit])])
        let source = FakeGeometrySource()
        source.liveOwners = ["b0"]

        // A hit inside the text segment lifts straight to a global offset.
        source.closest = (ownerID: "b0", source: .textSegment(index: 1), localCharOffset: 2)
        #expect(resolver(model, source).closestGlobalOffset(toContainerPoint: .zero) == 10) // 8 + 2

        // A hit at the pill's leading edge resolves to the atom's start...
        source.closest = (ownerID: "b0", source: .atom(id: "m1"), localCharOffset: 0)
        #expect(resolver(model, source).closestGlobalOffset(toContainerPoint: .zero) == 0)
        // ...and past it, to the atom's trailing edge (never strictly inside).
        source.closest = (ownerID: "b0", source: .atom(id: "m1"), localCharOffset: 1)
        #expect(resolver(model, source).closestGlobalOffset(toContainerPoint: .zero) == 8)
    }

    // MARK: snapIngestedRange — whole-atom expansion for atom-interior
    // word/drag seeds (Task 19 review fix round 1, the "Important" finding)

    /// "due Jul 9, 2024": text "due " [0,4) + one multi-word atom "Jul 9,
    /// 2024" [4,15) (fallbackText, 11 chars — all ASCII, so Character ==
    /// UTF-16 offsets). Shared fixture for the three tests below.
    private func dueDateModel() -> SelectionTextModel {
        let unit = SearchTextUnit(
            ownerID: "b0", topLevelBlockID: "b0", expandAncestorIDs: [],
            plainText: "due Jul 9, 2024",
            parts: [.init(source: .textSegment(index: 0), range: 0..<4),
                    .init(source: .atom(id: "date1"), range: 4..<15)])
        return SelectionTextModel.build(orderedItems: [item("b0", [unit])])
    }

    @Test func wordSeedInsideMultiWordAtomExpandsToWholeAtom() {
        let model = dueDateModel()
        let r = resolver(model, FakeGeometrySource())
        // The tokenizer's word "Jul" is [4,7) — wholly inside the atom
        // [4,15), touching its LEADING edge. Nearer-edge-snapping each
        // endpoint independently would snap BOTH to the atom's start (4),
        // collapsing to an empty range (the finding this fixes).
        #expect(r.snapIngestedRange(4..<7) == 4..<15)
    }

    @Test func tailWordSeedInsideMultiWordAtomExpandsToWholeAtom() {
        let model = dueDateModel()
        let r = resolver(model, FakeGeometrySource())
        // The tail word "2024" is [11,15) — wholly inside the atom, touching
        // its TRAILING edge. Nearer-edge snap would snap both ends forward to
        // 15, also collapsing to empty.
        #expect(r.snapIngestedRange(11..<15) == 4..<15)
    }

    @Test func adjacentWordSeedOutsideAtomResolvesTight() {
        // Regression pin (Task 19 deviation note): a word seed adjacent to —
        // but not inside — an atom must NOT be pulled into it. "due" is
        // [0,3), one char short of the atom's start (4); must resolve tight.
        let model = dueDateModel()
        let r = resolver(model, FakeGeometrySource())
        #expect(r.snapIngestedRange(0..<3) == 0..<3)
    }

    // MARK: Caret never null; hidden units excluded

    @Test func caretRectFallsBackWhenNoLiveRow() {
        let model = SelectionTextModel.build(orderedItems: [
            item("b0", [textUnit(owner: "b0", "text")])
        ])
        let source = FakeGeometrySource()  // nothing live, no brackets
        let rect = resolver(model, source).caretRect(forUTF16: 2)
        #expect(rect.height > 0)  // never .null / .zero-height
        #expect(!rect.isNull)
    }

    @Test func hiddenExpandUnitsExcludedFromRects() {
        let model = SelectionTextModel.build(orderedItems: [
            item("b0", [textUnit(owner: "b0", "open")]),
            item("b1", [textUnit(owner: "b1", "hidden", expands: ["e0"])]),
            item("b2", [textUnit(owner: "b2", "tail")]),
        ])
        let source = FakeGeometrySource()
        source.liveOwners = ["b0", "b1", "b2"]
        source.ownerRects["b0"] = CGRect(x: 0, y: 0, width: 100, height: 20)
        source.ownerRects["b1"] = CGRect(x: 0, y: 20, width: 100, height: 20)
        source.ownerRects["b2"] = CGRect(x: 0, y: 40, width: 100, height: 20)
        // e0 closed → b1 hidden and contributes no rect.
        let hidden = SelectionGeometryResolver(model: model, source: source, isVisible: { unit in
            !unit.expandAncestorIDs.contains("e0")
        })
        let rects = hidden.selectionRects(forUTF16: 0..<model.totalUTF16Length)
        #expect(rects.count == 2)  // b0 and b2 only
        #expect(rects[0].containsStart == true)
        #expect(rects[1].containsEnd == true)
    }
}
