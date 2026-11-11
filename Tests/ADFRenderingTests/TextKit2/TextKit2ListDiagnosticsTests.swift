import Foundation
import Testing
import ADFModel
import ADFPreparation
@testable import ADFRendering

/// Leaf coverage (Fable F8), pinned from each fixture's structure by hand
/// (fixtures manifest, phase 4; re-read from the JSON), not from the walk
/// itself. A regression that drops list text from the scope, or makes it
/// ineligible, changes these numbers.
@Suite("TextKit 2 list coverage")
@MainActor
struct TextKit2ListCoverageTests {
    static func blocks(_ name: String) async throws -> [RenderBlock] {
        let doc = try await ADFParser().parse(try TextKit2ListCoverageTests.fixtureData(name))
        return DocumentPreparer(theme: .default).prepare(doc)
    }

    /// `lists` from iOS 26. Before it list text falls back
    /// (`TextKit2Eligibility.listsMatchText`, `.osGatedList`): the eligible
    /// and linked leaves are the roots' (`rootLeaves`), and the list leaves
    /// that were eligible count as fallbacks; the list leaf counts stay.
    static func pinned(_ lists: ADFTextKit2Coverage, rootLeaves: (eligible: Int, linked: Int)) -> ADFTextKit2Coverage {
        guard !TextKit2Eligibility.listsMatchText else { return lists }
        var gated = lists
        gated.fallbackTextLeaves += lists.eligibleTextLeaves - rootLeaves.eligible
        gated.eligibleTextLeaves = rootLeaves.eligible
        gated.linkedTextLeaves = rootLeaves.linked
        return gated
    }

    nonisolated static func fixtureData(_ name: String) throws -> Data {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() } // …/Tests/ADFRenderingTests/TextKit2 → repo root
        return try Data(contentsOf: url.appendingPathComponent("Fixtures/\(name).json"))
    }

    @Test("lists-parity: 8 root text blocks, 35 leaders; 2 atom leaders fall back, 2 linked")
    func listsParity() async throws {
        let blocks = try await Self.blocks("lists-parity")
        // 21 roots: 7 section headings + the closing paragraph (8 root
        // richText, all plain), 7 root lists, a panel, a quote, a table
        // (two slices), an expand and layout columns.
        #expect(blocks.count == 21)
        // Three root lists keep all their text on SwiftUI, as a row holds a
        // block other than text (`TextKit2Scope.listKeepsRenderer`): 0.8
        // (the code-first item 0.8.12), 0.10 (the embedded-blocks item
        // 0.10.2) and 0.12 (a sync block, a stray item). Leaders in the
        // other four: 12 + 12 + 7 task + 4 decision = 35 non-empty (the
        // empty task 0.5.5 has none); no row there holds more than one
        // block (`rowKeepsRenderer`), and none holds a trailing paragraph.
        // Atoms (fallback): 0.5.3, 0.6.1. Links (TextKit 1-backed): 0.5.4,
        // 0.6.2. The text inside the panel, quote, table, expand and layout
        // columns is out of scope.
        #expect(ADFTextRenderer.textKit2Coverage(of: blocks) == Self.pinned(ADFTextKit2Coverage(
            eligibleRoots: 8, fallbackRoots: 13, textFallbackRoots: 0, linkRoots: 0,
            eligibleTextLeaves: 41, linkedTextLeaves: 2, fallbackTextLeaves: 2,
            listLeaderLeaves: 35, listTrailingLeaves: 0
        ), rootLeaves: (8, 0)))
    }

    @Test("list-dense: 3,071 leaders and 239 list paragraphs and headings; 326 atom leaves fall back, 488 linked")
    func listDense() async throws {
        let blocks = try await Self.blocks("list-dense")
        // 600 root lists and nothing else. The generator's tally: leaders
        // 3,396 (atom 342, linked 515); trailing paragraphs 325 extra
        // (atom 38, linked 41) + 231 continuation (atom 20, linked 38) + 134
        // headings = 690; no trailing lists. Rows holding more than one
        // block keep all their text on SwiftUI
        // (`TextKit2Scope.rowKeepsRenderer`): the 325 items with an extra
        // paragraph (leaders: 31 atom, 58 linked; paragraphs: 38 atom, 41
        // linked) and the 63 continuation rows with a paragraph and a
        // heading (5 atom, 7 linked paragraphs). That leaves 3,071 leaders
        // (311 atom, 457 linked) and 168 continuation paragraphs (15 atom,
        // 31 linked) + 71 lone headings = 239 list paragraphs and headings.
        #expect(blocks.count == 600)
        #expect(ADFTextRenderer.textKit2Coverage(of: blocks) == Self.pinned(ADFTextKit2Coverage(
            eligibleRoots: 0, fallbackRoots: 600, textFallbackRoots: 0, linkRoots: 0,
            eligibleTextLeaves: 2_984, linkedTextLeaves: 488, fallbackTextLeaves: 326,
            listLeaderLeaves: 3_071, listTrailingLeaves: 239
        ), rootLeaves: (0, 0)))
    }

    @Test("kitchen-sink: the PR 1 root counts plus 8 plain list leaders")
    func kitchenSink() async throws {
        let blocks = try await Self.blocks("kitchen-sink")
        // Roots as pinned since PR 1 (10 eligible, 1 linked; the atom
        // paragraph and the status paragraph fall back). List leaders: the
        // bullet list (3, one nested), the ordered list (2), the task list
        // (2) and the decision list (1), all plain; no list paragraphs. The
        // lists in the layout columns, table and expand are out of scope.
        #expect(blocks.count == 38)
        #expect(ADFTextRenderer.textKit2Coverage(of: blocks) == Self.pinned(ADFTextKit2Coverage(
            eligibleRoots: 10, fallbackRoots: 28, textFallbackRoots: 2, linkRoots: 1,
            eligibleTextLeaves: 18, linkedTextLeaves: 1, fallbackTextLeaves: 2,
            listLeaderLeaves: 8, listTrailingLeaves: 0
        ), rootLeaves: (10, 1)))
    }

    /// The iOS 26 gate is one verdict (`TextKit2Eligibility.verdict`,
    /// owner `.list`): before iOS 26 exactly the list leaves eligible on
    /// iOS 26 fall back as `.osGatedList` (lists-parity 33, kitchen-sink 8,
    /// list-dense 2,984), never a root; from iOS 26 none does.
    @Test("before iOS 26 list text that is otherwise eligible falls back as osGatedList; roots never do")
    func osGatedLists() async throws {
        for (name, listEligible) in [("lists-parity", 33), ("kitchen-sink", 8), ("list-dense", 2_984)] {
            let blocks = try await Self.blocks(name)
            var gated = 0
            var gatedRoots = 0
            var otherwiseEligible = 0
            TextKit2Scope.forEachLeaf(in: blocks) { leaf in
                if case .fallback(.osGatedList) = leaf.verdict {
                    if leaf.position == .root { gatedRoots += 1 } else { gated += 1 }
                }
                if leaf.position != .root, case .eligible = TextKit2Eligibility.verdict(leaf.segments, owner: .root) {
                    otherwiseEligible += 1
                }
            }
            #expect(otherwiseEligible == listEligible, "\(name)")
            #expect(gatedRoots == 0, "\(name)")
            #expect(gated == (TextKit2Eligibility.listsMatchText ? 0 : listEligible), "\(name): \(gated) list leaves gated")
        }
    }
}

#if canImport(UIKit)
import SwiftUI
import UIKit

/// The live side of the list diagnostics: rows drawing list text count as
/// such, the rows drawn match the leaves the coverage walk counts, and rows
/// count their text conversions.
@Suite("TextKit 2 list diagnostics", .serialized)
@MainActor
struct TextKit2ListDiagnosticsTests {
    @Test("a row converts its text once per text or layout-input change, never for a re-apply or a flip")
    func conversions() {
        func text(_ string: String) -> AttributedString {
            var text = AttributedString(string)
            text.font = .body
            text.adfFontSpec = ADFFontSpec(textStyle: .body)
            return text
        }
        let diagnostics = TextKit2Diagnostics.shared
        let view = TextKit2RowView()
        let inputs = TextKit2RenderInputs(text: text("one"))
        var larger = inputs
        larger.sizeCategory = .accessibilityLarge
        // No suspension between the reads: only this view converts.
        let before = diagnostics.conversionCount
        view.apply(inputs)
        #expect(diagnostics.conversionCount - before == 1)
        view.apply(inputs)
        view.apply(inputs, colorScheme: .dark)
        #expect(diagnostics.conversionCount - before == 1)
        view.apply(larger, colorScheme: .dark)
        view.apply(TextKit2RenderInputs(text: text("two")), colorScheme: .dark)
        #expect(diagnostics.conversionCount - before == 3)
    }

    @Test("lists-parity: the rows drawn are exactly the eligible leaves the coverage counts, list rows counted as such")
    func listsParityRows() async throws {
        let diagnostics = TextKit2Diagnostics.shared
        let model = ADFDocumentModel()
        model.load(data: try TextKit2ListCoverageTests.fixtureData("lists-parity"))
        for _ in 0..<500 where model.phase != .ready {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.phase == .ready)

        var eligibleRoots: Set<String> = []
        var eligibleList: Set<String> = []
        TextKit2Scope.forEachLeaf(in: model.blocks) { leaf in
            guard case .eligible = leaf.verdict else { return }
            if leaf.position == .root { eligibleRoots.insert(leaf.ownerID) } else { eligibleList.insert(leaf.ownerID) }
        }
        // Before iOS 26 no list text is eligible (`TextKit2Eligibility.listsMatchText`,
        // `.osGatedList`): list text draws on SwiftUI, roots as in PR 1.
        let lists = TextKit2Eligibility.listsMatchText
        #expect(eligibleRoots.count == 8 && eligibleList.count == (lists ? 33 : 0))

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 9_000))
        let host = UIHostingController(rootView: ADFDocumentView(model: model, mediaProvider: TextKit2DiagnosticsTests.NoMedia(), textRenderer: .textKit2))
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await TextKit2DiagnosticsTests.settle(window)
        var rows = TextKit2FallbackTests.rows(in: host.view)
        let owners = rows.compactMap(\.ownerID)
        #expect(owners.count == Set(owners).count, "one row per owner")
        #expect(Set(rows.filter { $0.ownerKind == .root }.compactMap(\.ownerID)) == eligibleRoots)
        let listOwners = Set(rows.filter { $0.ownerKind == .list }.compactMap(\.ownerID))
        #expect(listOwners == eligibleList, "missing \(eligibleList.subtracting(listOwners).sorted()), unexpected \(listOwners.subtracting(eligibleList).sorted())")
        #expect(rows.filter(\.isTextKit1Backed).count == (lists ? 2 : 0))
        // Nothing inside an excluded container (the root panel, quote,
        // table, expand and layout columns) or a list that keeps its text
        // on SwiftUI (0.8, 0.10, 0.12).
        let excluded = ["0.8", "0.10", "0.12", "0.14", "0.15", "0.16", "0.17", "0.18"]
        for owner in owners {
            #expect(!excluded.contains { owner == $0 || owner.hasPrefix($0 + ".") || owner.hasPrefix($0 + "#") }, "\(owner) is inside an excluded block")
        }

        host.rootView = ADFDocumentView(model: model, mediaProvider: TextKit2DiagnosticsTests.NoMedia(), textRenderer: .swiftUI)
        try await TextKit2DiagnosticsTests.settle(window)
        // Released with this test's references: the live list count drops by
        // exactly the list rows.
        let listLive = diagnostics.liveListRowCount
        rows.removeAll()
        #expect(listLive - diagnostics.liveListRowCount == (lists ? 33 : 0))
    }
}
#endif
