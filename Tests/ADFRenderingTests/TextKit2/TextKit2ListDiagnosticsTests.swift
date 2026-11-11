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

    nonisolated static func fixtureData(_ name: String) throws -> Data {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() } // …/Tests/ADFRenderingTests/TextKit2 → repo root
        return try Data(contentsOf: url.appendingPathComponent("Fixtures/\(name).json"))
    }

    @Test("lists-parity: 8 root text blocks, 58 leaders, 6 list paragraphs; 6 atom leaders fall back, 3 linked")
    func listsParity() async throws {
        let blocks = try await Self.blocks("lists-parity")
        // 21 roots: 7 section headings + the closing paragraph (8 root
        // richText, all plain), 7 root lists, a panel, a quote, a table
        // (two slices), an expand and layout columns.
        #expect(blocks.count == 21)
        // Leaders: 55 non-empty in the root lists (12 + 12 + 7 task + 4
        // decision + 11 + 7 + 2; empty: the empty task 0.5.5, the empty
        // paragraph 0.8.11, the code-first item 0.8.12 and the two
        // continuation rows of 0.10.1) + 3 in trailing lists (the sync block
        // 0.12.0.1.0 and the stray item 0.12.1.1.0). List paragraphs: 0.8.12.1
        // (after a code block), 0.10.0.1, 0.10.0.2, 0.10.1.2, 0.10.1.4 and
        // the heading 0.10.1.5. Atoms (fallback): 0.5.3, 0.6.1, 0.8.7–0.8.10.
        // Links (TextKit 1-backed): 0.5.4, 0.6.2, 0.8.2. Hard breaks and the
        // Unicode emoji are text; no leaf ends in two breaks. The text inside
        // the panel, quote, table, expand, layout columns and the items'
        // embedded blocks is out of scope.
        #expect(ADFTextRenderer.textKit2Coverage(of: blocks) == ADFTextKit2Coverage(
            eligibleRoots: 8, fallbackRoots: 13, textFallbackRoots: 0, linkRoots: 0,
            eligibleTextLeaves: 66, linkedTextLeaves: 3, fallbackTextLeaves: 6,
            listLeaderLeaves: 58, listTrailingLeaves: 6
        ))
    }

    @Test("list-dense: 3,396 leaders and 690 list paragraphs; 400 atom leaves fall back, 594 linked")
    func listDense() async throws {
        let blocks = try await Self.blocks("list-dense")
        // 600 root lists and nothing else. The generator's tally: leaders
        // 3,396 (atom 342, linked 515); trailing paragraphs 325 extra
        // (atom 38, linked 41) + 231 continuation (atom 20, linked 38) + 134
        // headings = 690; no trailing lists.
        #expect(blocks.count == 600)
        #expect(ADFTextRenderer.textKit2Coverage(of: blocks) == ADFTextKit2Coverage(
            eligibleRoots: 0, fallbackRoots: 600, textFallbackRoots: 0, linkRoots: 0,
            eligibleTextLeaves: 3_686, linkedTextLeaves: 594, fallbackTextLeaves: 400,
            listLeaderLeaves: 3_396, listTrailingLeaves: 690
        ))
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
        #expect(ADFTextRenderer.textKit2Coverage(of: blocks) == ADFTextKit2Coverage(
            eligibleRoots: 10, fallbackRoots: 28, textFallbackRoots: 2, linkRoots: 1,
            eligibleTextLeaves: 18, linkedTextLeaves: 1, fallbackTextLeaves: 2,
            listLeaderLeaves: 8, listTrailingLeaves: 0
        ))
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
            guard TextKit2Eligibility.describableText(leaf.segments) != nil else { return }
            if leaf.position == .root { eligibleRoots.insert(leaf.ownerID) } else { eligibleList.insert(leaf.ownerID) }
        }
        #expect(eligibleRoots.count == 8 && eligibleList.count == 58)

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
        #expect(rows.filter(\.isTextKit1Backed).count == 3)
        // Nothing inside an excluded container: the root panel, quote,
        // table, expand and layout columns, or an item's embedded blocks.
        let excluded = ["0.14", "0.15", "0.16", "0.17", "0.18", "0.8.12.0"] + (1...6).map { "0.10.2.\($0)" }
        for owner in owners {
            #expect(!excluded.contains { owner == $0 || owner.hasPrefix($0 + ".") || owner.hasPrefix($0 + "#") }, "\(owner) is inside an excluded block")
        }

        host.rootView = ADFDocumentView(model: model, mediaProvider: TextKit2DiagnosticsTests.NoMedia(), textRenderer: .swiftUI)
        try await TextKit2DiagnosticsTests.settle(window)
        // Released with this test's references: the live list count drops by
        // exactly the list rows.
        let listLive = diagnostics.liveListRowCount
        rows.removeAll()
        #expect(listLive - diagnostics.liveListRowCount == 58)
    }
}
#endif
