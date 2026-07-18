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
}
