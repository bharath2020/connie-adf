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

    @Test("lists-parity: 8 root text blocks, 46 leaders; 6 atom leaders fall back, 3 linked")
    func listsParity() async throws {
        let blocks = try await Self.blocks("lists-parity")
        // 21 roots: 7 section headings + the closing paragraph (8 root
        // richText, all plain), 7 root lists, a panel, a quote, a table
        // (two slices), an expand and layout columns.
        #expect(blocks.count == 21)
        // One root list keeps all its text on SwiftUI: 0.10, whose
        // embedded-blocks item 0.10.2 holds a panel and an expand
        // (`TextKit2Scope.listKeepsRenderer`). In the other six, a row
        // holding a block other than text keeps its own text on SwiftUI
        // (`rowKeepsRenderer`): the code-first item 0.8.12 (its paragraph
        // follows the code block) and both rows of 0.12 (a sync block's
        // list, a stray item's list). Leaders: 12 + 12 + 7 task + 4 decision
        // + 11 in 0.8 (0.8.0–0.8.10) = 46 non-empty (the empty task 0.5.5
        // and 0.8.11 have none); no row in those lists holds a trailing
        // paragraph without a code block or a list beside it. Atoms
        // (fallback): 0.5.3, 0.6.1, 0.8.7–0.8.10. Links (TextKit 1-backed):
        // 0.5.4, 0.6.2, 0.8.2. The text inside the panel, quote, table,
        // expand and layout columns is out of scope.
        #expect(ADFTextRenderer.textKit2Coverage(of: blocks) == Self.pinned(ADFTextKit2Coverage(
            eligibleRoots: 8, fallbackRoots: 13, textFallbackRoots: 0, linkRoots: 0,
            eligibleTextLeaves: 48, linkedTextLeaves: 3, fallbackTextLeaves: 6,
            listLeaderLeaves: 46, listTrailingLeaves: 0
        ), rootLeaves: (8, 0)))
    }

    @Test("list-dense: 3,382 leaders and 550 list paragraphs and headings; 395 atom leaves fall back, 586 linked")
    func listDense() async throws {
        let blocks = try await Self.blocks("list-dense")
        // 600 root lists and nothing else. The generator's tally: leaders
        // 3,396 (atom 342, linked 515); trailing paragraphs 325 extra
        // (atom 38, linked 41) + 231 continuation (atom 20, linked 38) + 134
        // headings = 690; no trailing lists. Rows whose column holds more
        // than one block keep all their text on SwiftUI unless every block
        // is a body-styled paragraph (`TextKit2Scope.rowKeepsRenderer`):
        // the 14 items whose leader or extra paragraph has a sub/superscript
        // or small-text run (14 plain leaders; 13 plain and 1 linked
        // paragraph) and the 63 continuation rows with a paragraph and a
        // heading (5 atom, 7 linked paragraphs). That leaves 3,382 leaders
        // (342 atom, 515 linked) and 311 extra paragraphs (38 atom, 40
        // linked) + 168 continuation paragraphs (15 atom, 31 linked) + 71
        // lone headings = 550 list paragraphs and headings: 395 atom leaves,
        // 586 linked, 3,537 eligible.
        #expect(blocks.count == 600)
        #expect(ADFTextRenderer.textKit2Coverage(of: blocks) == Self.pinned(ADFTextKit2Coverage(
            eligibleRoots: 0, fallbackRoots: 600, textFallbackRoots: 0, linkRoots: 0,
            eligibleTextLeaves: 3_537, linkedTextLeaves: 586, fallbackTextLeaves: 395,
            listLeaderLeaves: 3_382, listTrailingLeaves: 550
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
        // The one top-level code block (0.12, two lines of printable ASCII)
        // is an eligible code root: counted apart, in none of the text
        // counts, and still one of the 28 legacy fallback roots.
        #expect(blocks.count == 38)
        #expect(ADFTextRenderer.textKit2Coverage(of: blocks) == Self.pinned(ADFTextKit2Coverage(
            eligibleRoots: 10, fallbackRoots: 28, textFallbackRoots: 2, linkRoots: 1,
            eligibleTextLeaves: 18, linkedTextLeaves: 1, fallbackTextLeaves: 2,
            listLeaderLeaves: 8, listTrailingLeaves: 0,
            eligibleCodeRoots: 1, fallbackCodeRoots: 0
        ), rootLeaves: (10, 1)))
    }

    /// The iOS 26 gate is one verdict (`TextKit2Eligibility.verdict`,
    /// owner `.list`): before iOS 26 exactly the list leaves eligible on
    /// iOS 26 fall back as `.osGatedList` (lists-parity 40, kitchen-sink 8,
    /// list-dense 3,537), never a root; from iOS 26 none does. A top-level
    /// code block (kitchen-sink's 0.12) is not list text: it is judged by
    /// the code rules and never takes the gate, so it counts with the roots
    /// here.
    @Test("before iOS 26 list text that is otherwise eligible falls back as osGatedList; roots never do")
    func osGatedLists() async throws {
        for (name, listEligible) in [("lists-parity", 40), ("kitchen-sink", 8), ("list-dense", 3_537)] {
            let blocks = try await Self.blocks(name)
            var gated = 0
            var gatedRoots = 0
            var otherwiseEligible = 0
            TextKit2Scope.forEachLeaf(in: blocks) { leaf in
                let isListText = leaf.position.ownerKind == .list
                if case .fallback(.osGatedList) = leaf.verdict {
                    if isListText { gated += 1 } else { gatedRoots += 1 }
                }
                if isListText, case .eligible = TextKit2Eligibility.verdict(leaf.segments, owner: .root) {
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
            switch leaf.position.ownerKind {
            case .root: eligibleRoots.insert(leaf.ownerID)
            case .list: eligibleList.insert(leaf.ownerID)
            case .code: break // top-level code is PR 3's; not counted here
            }
        }
        // Before iOS 26 no list text is eligible (`TextKit2Eligibility.listsMatchText`,
        // `.osGatedList`): list text draws on SwiftUI, roots as in PR 1.
        let lists = TextKit2Eligibility.listsMatchText
        #expect(eligibleRoots.count == 8 && eligibleList.count == (lists ? 40 : 0))

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
        #expect(rows.filter(\.isTextKit1Backed).count == (lists ? 3 : 0))
        // Nothing inside an excluded container (the root panel, quote,
        // table, expand and layout columns), a row holding a block other
        // than text (0.8.12, both rows of 0.12) or the list that keeps its
        // text on SwiftUI (0.10).
        let excluded = ["0.8.12", "0.10", "0.12", "0.14", "0.15", "0.16", "0.17", "0.18"]
        for owner in owners {
            #expect(!excluded.contains { owner == $0 || owner.hasPrefix($0 + ".") || owner.hasPrefix($0 + "#") }, "\(owner) is inside an excluded block")
        }

        host.rootView = ADFDocumentView(model: model, mediaProvider: TextKit2DiagnosticsTests.NoMedia(), textRenderer: .swiftUI)
        try await TextKit2DiagnosticsTests.settle(window)
        // Released with this test's references: the live list count drops by
        // exactly the list rows.
        let listLive = diagnostics.liveListRowCount
        rows.removeAll()
        #expect(listLive - diagnostics.liveListRowCount == (lists ? 40 : 0))
    }
}
#endif
