import Foundation
import Testing
import ADFPreparation
@testable import ADFRendering

@Suite("SelectionTextModel")
struct SelectionTextModelTests {
    private func textUnit(owner: String, top: String, _ text: String, expands: [String] = []) -> SearchTextUnit {
        SearchTextUnit(ownerID: owner, topLevelBlockID: top, expandAncestorIDs: expands,
                       plainText: text,
                       parts: [.init(source: .textSegment(index: 0), range: 0..<text.count)])
    }
    private func item(_ id: String, _ units: [SearchTextUnit]) -> SearchIndexedItem {
        SearchIndexedItem(id: id, topLevelBlockID: id, units: units)
    }

    @Test func prefixSumsCountUTF16IncludingJoiners() {
        let m = SelectionTextModel.build(orderedItems: [
            item("b0", [textUnit(owner: "b0", top: "b0", "ab")]),      // 2 utf16
            item("b1", [textUnit(owner: "b1", top: "b1", "c😄")]),     // c=1, 😄=2 → 3 utf16
        ])
        // unit0 starts at 0; unit1 starts after "ab" (2) + one "\n" joiner (1) = 3
        #expect(m.unitUTF16Starts == [0, 3])
        #expect(m.totalUTF16Length == 2 /*unit0*/ + 1 /*joiner*/ + 3 /*unit1*/)  // = 6
    }

    @Test func locateAndGlobalOffsetRoundTripAcrossJoiner() {
        let m = SelectionTextModel.build(orderedItems: [
            item("b0", [textUnit(owner: "b0", top: "b0", "ab")]),
            item("b1", [textUnit(owner: "b1", top: "b1", "cd")]),
        ])
        // global 4 = unit1 local 0 (unit0 len 2 + joiner 1 = 3 is unit1 start → local 1 = global 4)
        #expect(m.globalOffset(unit: 1, localUTF16: 1) == 4)
        let loc = m.locate(utf16: 4)
        #expect(loc?.unit == 1 && loc?.local == 1)
    }

    @Test func copyIsDocumentOrderJoinedByNewline() {
        let m = SelectionTextModel.build(orderedItems: [
            item("b0", [textUnit(owner: "b0", top: "b0", "hello")]),
            item("b1", [textUnit(owner: "b1", top: "b1", "world")]),
        ])
        #expect(m.text(inUTF16: 0..<m.totalUTF16Length, isVisible: { _ in true }) == "hello\nworld")
    }

    @Test func hiddenExpandUnitsExcludedFromCopy() {
        let m = SelectionTextModel.build(orderedItems: [
            item("b0", [textUnit(owner: "b0", top: "b0", "open")]),
            item("b1", [textUnit(owner: "b1", top: "e0", "hidden", expands: ["e0"])]),
            item("b2", [textUnit(owner: "b2", top: "b2", "tail")]),
        ])
        // e0 closed → its unit contributes nothing; endpoints snap across it.
        let copied = m.text(inUTF16: 0..<m.totalUTF16Length, isVisible: { !$0.expandAncestorIDs.contains("e0") })
        #expect(copied == "open\ntail")
    }

    @Test func atomRangeSnapsToNearerEdge() {
        // "@Bharath" is one atom part (fallbackText, 8 chars = 8 utf16).
        let atomUnit = SearchTextUnit(
            ownerID: "b0", topLevelBlockID: "b0", expandAncestorIDs: [],
            plainText: "@Bharath done",
            parts: [.init(source: .atom(id: "m1"), range: 0..<8),
                    .init(source: .textSegment(index: 1), range: 8..<13)])  // " done"
        let m = SelectionTextModel.build(orderedItems: [item("b0", [atomUnit])])
        #expect(m.snapAcrossAtoms(2, forward: true) == 8)    // inside atom, nearer forward edge
        #expect(m.snapAcrossAtoms(2, forward: false) == 0)   // inside atom, nearer back edge
        #expect(m.snapAcrossAtoms(9, forward: true) == 9)    // in " done" text — unchanged
    }

    // MARK: atomRange(containing:) — Task 19 review fix round 1 (whole-atom
    // expansion for atom-interior word/drag seeds)

    @Test func atomRangeContainingReturnsWholeAtomForWhollyInteriorRange() {
        // "due Jul 9, 2024": text "due " [0,4) + atom "Jul 9, 2024" [4,15)
        // (fallbackText, 11 chars — all ASCII, so Character == UTF-16 offsets).
        let unit = SearchTextUnit(
            ownerID: "b0", topLevelBlockID: "b0", expandAncestorIDs: [],
            plainText: "due Jul 9, 2024",
            parts: [.init(source: .textSegment(index: 0), range: 0..<4),
                    .init(source: .atom(id: "date1"), range: 4..<15)])
        let m = SelectionTextModel.build(orderedItems: [item("b0", [unit])])

        #expect(m.atomRange(containing: 4..<7) == 4..<15)     // "Jul" — leading word
        #expect(m.atomRange(containing: 11..<15) == 4..<15)   // "2024" — tail word
        #expect(m.atomRange(containing: 4..<15) == 4..<15)    // the whole pill itself
        #expect(m.atomRange(containing: 0..<3) == nil)        // "due" — outside the atom
        #expect(m.atomRange(containing: 0..<15) == nil)       // spans text + atom — not WHOLLY inside
        #expect(m.atomRange(containing: 4..<4) == nil)        // empty range never expands
    }

    // MARK: partSlices — geometry slicing (Task 18 review #2: had zero coverage)

    /// A multi-part unit (text · atom · text) sliced by a range spanning all
    /// three: text parts report their intersected `Character` sub-range; the
    /// atom reports its WHOLE contribution on any overlap (atomicity).
    @Test func partSlicesMultiPartWithAtomOverlap() {
        // "Hi@Xdone": "Hi"[0,2) · atom "@X"[2,4) · "done"[4,8); all BMP so
        // Character offsets == UTF-16 offsets.
        let unit = SearchTextUnit(
            ownerID: "b0", topLevelBlockID: "b0", expandAncestorIDs: [],
            plainText: "Hi@Xdone",
            parts: [.init(source: .textSegment(index: 0), range: 0..<2),
                    .init(source: .atom(id: "m1"), range: 2..<4),
                    .init(source: .textSegment(index: 2), range: 4..<8)])
        let m = SelectionTextModel.build(orderedItems: [item("b0", [unit])])

        let slices = m.partSlices(forUTF16: 1..<6, isVisible: { _ in true })
        #expect(slices.count == 3)
        #expect(slices[0].source == .textSegment(index: 0))
        #expect(slices[0].localCharRange == 1..<2)          // "i" — the intersected tail of "Hi"
        #expect(slices[1].source == .atom(id: "m1"))
        #expect(slices[1].localCharRange == 0..<2)          // whole pill despite partial overlap
        #expect(slices[2].source == .textSegment(index: 2))
        #expect(slices[2].localCharRange == 0..<2)          // "do" — the intersected head of "done"
        #expect(slices.allSatisfy { $0.unit == 0 })
    }

    /// A range that lands STRICTLY inside the atom still selects the whole pill,
    /// and touches no neighboring text part.
    @Test func partSlicesAtomInteriorSelectsWholePill() {
        let unit = SearchTextUnit(
            ownerID: "b0", topLevelBlockID: "b0", expandAncestorIDs: [],
            plainText: "Hi@Xdone",
            parts: [.init(source: .textSegment(index: 0), range: 0..<2),
                    .init(source: .atom(id: "m1"), range: 2..<4),
                    .init(source: .textSegment(index: 2), range: 4..<8)])
        let m = SelectionTextModel.build(orderedItems: [item("b0", [unit])])

        let slices = m.partSlices(forUTF16: 3..<4, isVisible: { _ in true })  // one unit inside "@X"
        #expect(slices.count == 1)
        #expect(slices[0].source == .atom(id: "m1"))
        #expect(slices[0].localCharRange == 0..<2)
    }

    /// A multi-unit range: each visible unit contributes its own text slice,
    /// with `localCharRange` measured within that unit's part (not the joined
    /// document), and hidden units drop out entirely.
    @Test func partSlicesSpansUnitsAndSkipsHidden() {
        let m = SelectionTextModel.build(orderedItems: [
            item("b0", [textUnit(owner: "b0", top: "b0", "alpha")]),                    // [0,5)
            item("b1", [textUnit(owner: "b1", top: "e0", "bravo", expands: ["e0"])]),   // [6,11) hidden
            item("b2", [textUnit(owner: "b2", top: "b2", "charlie")]),                  // [12,19)
        ])
        // Range from mid-"alpha" through mid-"charlie", with e0 closed.
        let slices = m.partSlices(forUTF16: 2..<15, isVisible: { !$0.expandAncestorIDs.contains("e0") })
        #expect(slices.count == 2)                       // b0 and b2 only; b1 hidden
        #expect(slices[0].unit == 0)
        #expect(slices[0].localCharRange == 2..<5)       // "pha"
        #expect(slices[1].unit == 2)
        #expect(slices[1].localCharRange == 0..<3)       // "cha"
    }
}
