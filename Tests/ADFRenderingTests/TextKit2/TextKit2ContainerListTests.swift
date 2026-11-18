#if canImport(UIKit)
import SwiftUI
import UIKit
import Testing
import ADFModel
import ADFPreparation
@testable import ADFRendering

// Lists nested in containers on TextKit 2 (PR 4 step 6): `.listRows` joins
// the container allow list, and PR 2's list rules apply unchanged at the
// nested position: rule A (`rowKeepsRenderer`) and rule B
// (`listKeepsRenderer`) from the prepared rows, rule C
// (`listDirectionKeepsRenderer`: left to right only), rule D
// (`listTextFits`) against the container's width bound, and before iOS 26
// the list gate (`listsMatchText`). Panels holding a list keep their body on
// SwiftUI (`panelKeepsRenderer`, the panel shape probes), and so does every
// side-by-side column (`horizontalColumnKeepsRenderer`, the off-grid probe):
// the minimum positions are a quote, an expand body, a bodied-extension
// body and a stacked layout column.
//
// The parity suites run the step 3 and step 4 matrices
// (`productionMatrix`, `columnMatrix`) over list shapes; the expected
// owners are written out from the rules, rule D included
// (`TK2ContainerLists.narrowListText`).

/// The list shapes and rule-D expectations of the step 6 suites. Not a
/// suite.
enum TK2ContainerLists {
    typealias P = TK2ContainerProbe
    typealias B = TK2ContainerBody

    static func orderedList(_ items: [String], order: Int = 1) -> String {
        "{\"type\":\"orderedList\",\"attrs\":{\"order\":\(order)},\"content\":[\(items.joined(separator: ","))]}"
    }

    static func taskList(_ items: [(text: String, done: Bool)]) -> String {
        let content = items.enumerated().map { index, item in
            "{\"type\":\"taskItem\",\"attrs\":{\"localId\":\"probe-task-\(index)\",\"state\":\"\(item.done ? "DONE" : "TODO")\"},\"content\":[\(P.t(item.text))]}"
        }
        return "{\"type\":\"taskList\",\"attrs\":{\"localId\":\"probe-tasks\"},\"content\":[\(content.joined(separator: ","))]}"
    }

    static func decisionList(_ items: [String]) -> String {
        let content = items.enumerated().map { index, text in
            "{\"type\":\"decisionItem\",\"attrs\":{\"localId\":\"probe-decision-\(index)\",\"state\":\"DECIDED\"},\"content\":[\(P.t(text))]}"
        }
        return "{\"type\":\"decisionList\",\"attrs\":{\"localId\":\"probe-decisions\"},\"content\":[\(content.joined(separator: ","))]}"
    }

    /// The nested-list shapes: a three-deep bullet list after a paragraph;
    /// an ordered list starting at 3 and a task list (open and done); an
    /// item of two body paragraphs, the first linked; a list whose middle
    /// row holds a code block (rule A keeps that row on SwiftUI, its
    /// siblings migrate); decisions after a paragraph. Every shape holds
    /// text that migrates. `ADF_CONTAINER_PROBES_SHAPES=<name,…>` limits
    /// them (`TK2ContainerBody.only`; `allShapes` is unfiltered).
    static var shapes: [B.Shape] { allShapes.filter { B.only?.contains($0.name) ?? true } }

    static var allShapes: [B.Shape] {
        let p = { (count: Int, from: Int) in P.paragraph(P.t(P.words(count, from: from))) }
        return [
            B.Shape(name: "nestedList", body: [
                p(10, 1),
                P.bulletList([
                    P.item(p(3, 5)),
                    P.item(p(12, 8), P.bulletList([P.item(p(5, 14), P.bulletList([P.item(p(6, 2))]))])),
                    P.item(p(2, 20)),
                ]),
            ], migrates: true),
            B.Shape(name: "orderedTasks", body: [
                orderedList([P.item(p(10, 1)), P.item(p(4, 9))], order: 3),
                taskList([(P.words(7, from: 3), false), (P.words(4, from: 12), true)]),
            ], migrates: true),
            B.Shape(name: "multiParagraphItem", body: [
                P.bulletList([
                    P.item(P.paragraph(P.t(P.words(5, from: 2) + " "), P.t("linked item words", P.link), P.t(" " + P.words(4, from: 9))), p(14, 6)),
                    P.item(p(5, 3)),
                ]),
            ], migrates: true),
            B.Shape(name: "ruleARow", body: [
                P.bulletList([P.item(p(6, 1)), P.item(p(7, 4), B.codeBlock), P.item(p(5, 10))]),
                p(8, 15),
            ], migrates: true),
            B.Shape(name: "decisions", body: [
                p(9, 4),
                decisionList([P.words(8, from: 2), P.words(3, from: 17)]),
            ], migrates: true),
        ]
    }

    /// `ListRowView.textColumnInset` at a type size: the depth padding,
    /// the decision padding, the marker column and the gap after it.
    @MainActor
    static func textColumnInset(_ row: PreparedListRow, size: DynamicTypeSize) -> CGFloat {
        let marker = TextKit2ListParityTests.markerWidth(size)
        let spacing = P.spacing
        return CGFloat(row.depth) * (marker + spacing) + (TextKit2ListParityTests.isDecision(row) ? 2 * spacing : 0) + marker + spacing
    }

    /// The list text below `blocks` that rule D keeps on SwiftUI at `size`
    /// where `blocks` are laid out under the width bound `bound`: each
    /// leader or trailing paragraph whose text column (the bound less the
    /// row's inset and, for a trailing paragraph, its indentation) is
    /// narrower than `minimumListTextWidth`. Containers narrow the bound
    /// as their boundaries do (quote 2, expand body 2.5, extension body 3
    /// spacings; a stacked column not at all); a panel holding a list keeps
    /// it on SwiftUI anyway, and side by side no column child migrates, so
    /// neither is walked.
    @MainActor
    static func narrowListText(in blocks: [RenderBlock], bound: CGFloat, size: DynamicTypeSize) -> Set<String> {
        var owners: Set<String> = []
        for block in blocks {
            switch block.kind {
            case .listRows(let rows):
                for row in rows {
                    let inset = textColumnInset(row, size: size)
                    if !row.segments.isEmpty, !TextKit2Scope.listTextFits(.atLeast(bound), inset: inset) { owners.insert(row.id) }
                    for trailing in row.trailingBlocks {
                        guard case .richText(_, let style) = trailing.kind else { continue }
                        let indent = RichTextBlockView.indentationPadding(style, theme: TK2Parity.theme)
                        if !TextKit2Scope.listTextFits(.atLeast(bound), inset: inset + indent) { owners.insert(trailing.id) }
                    }
                }
            case .quote(let children): owners.formUnion(narrowListText(in: children, bound: bound - P.spacing * 2, size: size))
            case .extensionPlaceholder(_, let body): owners.formUnion(narrowListText(in: body, bound: bound - P.spacing * 3, size: size))
            case .layoutColumns(let columns):
                for column in columns { owners.formUnion(narrowListText(in: column.blocks, bound: bound, size: size)) }
            default: continue
            }
        }
        return owners
    }
}

// MARK: - Parity: the four minimum positions

extension TextKit2ContainerParityTests {
    typealias L = TK2ContainerLists

    @Test("nestedListInQuote: list text in a quote (bullets three deep, ordered, tasks, a multi-paragraph item, decisions; a rule-A row beside) matches SwiftUI through the production path; rule C and rule D rows stay on SwiftUI")
    func nestedListInQuote() async throws {
        try await productionMatrix("nestedListInQuote", container: .quote, shapes: L.shapes, nested: false)
    }

    @Test("nestedListInExtensionBody: list text in a bodied extension's body matches SwiftUI through the production path")
    func nestedListInExtensionBody() async throws {
        try await productionMatrix("nestedListInExtensionBody", container: .bodiedExtension, shapes: L.shapes, nested: false)
    }

    /// Expand bodies are in the production allow list (step 5), so the
    /// body boundary and every rule below it run as in the app; the test
    /// first checks the list holds `.expand`, so the matrix can never pass
    /// with the expand body on SwiftUI.
    ///
    /// One full-matrix case is a strict known issue (lead call C35, option
    /// B): at AX4 a list 268 pt wide (here the 320 pt document's expand
    /// body) gives a depth-2 row a 12 pt text column, one glyph per line,
    /// and the engines break and place its last lines apart (dLast 28 pt).
    /// The list alone at 268 pt differs too, and so do a quote at a 316 pt
    /// document, an extension body at 324 and a stacked column at 300
    /// (`ADF_CONTAINER_PROBES_WIDTHS`): PR 2's rule D floor (1 pt), not the
    /// expand. The PR 4 description carries the follow-up (a text-column
    /// floor).
    @Test("nestedListInExpandBody: list text in an open expand's body matches SwiftUI through the production path")
    func nestedListInExpandBody() async throws {
        #expect(TextKit2Scope.containerChildKinds.contains(.expand), "expand bodies are in the production allow list (step 5)")
        try await productionMatrix(
            "nestedListInExpandBody", container: .expand, shapes: L.shapes, nested: false,
            knownIssues: [
                "shape=nestedList size=accessibility4 bold=0 dir=ltr W=320.0":
                    "PR 2 rule D residual (lead call C35): a 268 pt list at AX4 gives its depth-2 row a 12 pt text column, which the engines break apart; PR 4 description follow-up",
            ]
        )
    }

    @Test("nestedListInStackedColumn: list text in stacked layout columns (beside a paragraph, beside another list, a rule-A row among them) matches SwiftUI through the production path")
    func nestedListInStackedColumn() async throws {
        try await columnMatrix("nestedListInStackedColumn", sideBySide: false, sections: TK2ContainerColumns.listSections)
    }
}

// MARK: - Scope negatives

extension TextKit2ContainerScopeTests {
    /// A document hosted under `.textKit2` the way the app hosts it, at
    /// `width` in `direction` and `size` (compact width: columns stack);
    /// returns this window's rows by owner. `allowed` widens the allow
    /// list (`nil`: the production list).
    @MainActor
    static func hostedListRows(
        _ content: [String], allowed: Set<TextKit2BlockKind>? = nil, width: CGFloat = 390,
        direction: LayoutDirection = .leftToRight, size: DynamicTypeSize = .large
    ) async throws -> (blocks: [RenderBlock], rows: [String: TextKit2RowView]) {
        let json = "{\"version\":1,\"type\":\"doc\",\"content\":[\(content.joined(separator: ","))]}"
        let model = ADFDocumentModel()
        model.load(data: Data(json.utf8))
        for _ in 0..<500 where model.phase != .ready {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.phase == .ready)
        let document = ADFDocumentView(model: model, mediaProvider: TextKit2DiagnosticsTests.NoMedia(), textRenderer: .textKit2)
            .transformEnvironment(\.adfContainerChildKinds) { kinds in
                if let allowed { kinds = allowed }
            }
            .environment(\.layoutDirection, direction)
            .environment(\.horizontalSizeClass, .compact)
            .dynamicTypeSize(size)
        let hosted = TK2CodeLogic.Hosted(document, size: CGSize(width: width, height: 6_000))
        defer { hosted.close() }
        try await hosted.settle()
        try await hosted.settle()
        var rows: [String: TextKit2RowView] = [:]
        for row in hosted.rows { if let owner = row.ownerID { rows[owner] = row } }
        return (model.blocks, rows)
    }

    /// Every text owner under a list row (its leader, its trailing text
    /// and code, and everything inside its trailing containers;
    /// `TK2ContainerBody.allTextOwners` counts code blocks from step 7).
    static func descendants(of row: PreparedListRow) -> Set<String> {
        var owners: Set<String> = row.segments.isEmpty ? [] : [row.id]
        owners.formUnion(TK2ContainerBody.allTextOwners(row.trailingBlocks))
        return owners
    }

    @Test("rejectedListRowKeepsDescendantsSwiftUI: in a quote, a list row rule A rejects (a code block and a quote in the item) keeps its leader, its code block and the quote inside it on SwiftUI; a list rule B rejects keeps every row there; the sibling rows and the quote's prose migrate")
    @MainActor
    func rejectedListRowKeepsDescendantsSwiftUI() async throws {
        let p = { (text: String) in TK2ContainerProbe.paragraph(TK2ContainerProbe.t(text)) }
        let innerQuote = TK2ContainerProbe.quote([p("Quote inside a rejected row.")])
        let panel = Self.panelJSON([p("Panel in an item.")])
        let expand = "{\"type\":\"nestedExpand\",\"attrs\":{\"title\":\"E\"},\"content\":[\(p("Expand in an item."))]}"
        let content = [
            TK2ContainerProbe.quote([
                p("Quote prose before its list."),
                TK2ContainerProbe.bulletList([
                    TK2ContainerProbe.item(p("A kept row.")),
                    TK2ContainerProbe.item(p("A rejected row's leader."), TK2ContainerBody.codeBlock, innerQuote),
                    TK2ContainerProbe.item(p("Another kept row.")),
                ]),
                // Rule B: one row holds a panel and an expand.
                TK2ContainerProbe.bulletList([
                    TK2ContainerProbe.item(p("Mixed row."), panel, expand),
                    TK2ContainerProbe.item(p("Plain row of a rejected list.")),
                ]),
            ]),
        ]
        for allowed in [nil, Set(TextKit2BlockKind.allCases)] {
            let (blocks, rows) = try await Self.hostedListRows(content, allowed: allowed)
            guard case .quote(let children) = try #require(blocks.first).kind,
                  case .listRows(let ruleA) = children[1].kind, case .listRows(let ruleB) = children[2].kind else {
                throw TestFailure("unexpected prepared shape")
            }
            #expect(!TextKit2Scope.rowKeepsRenderer(ruleA[1]) && TextKit2Scope.rowKeepsRenderer(ruleA[0]))
            #expect(!TextKit2Scope.listKeepsRenderer(ruleB))
            var rejected = Self.descendants(of: ruleA[1])
            for row in ruleB { rejected.formUnion(Self.descendants(of: row)) }
            // The rule-A row's leader, code block and inner quote's
            // paragraph; the rule-B rows' leaders and the panel's paragraph
            // (the closed expand's body is not prepared).
            #expect(rejected.count == 6, "\(rejected.sorted())")
            let drawn = Set(rows.keys)
            #expect(drawn.isDisjoint(with: rejected), "\(String(describing: allowed)): \(drawn.intersection(rejected).sorted()) drew on TextKit 2")
            let expected: Set<String> = [children[0].id, ruleA[0].id, ruleA[2].id]
            #expect(drawn == Self.passing(expected), "\(String(describing: allowed)): \(drawn.sorted())")
            for owner in Self.passing(expected) { #expect(rows[owner]?.containerContext == .container, "\(owner)") }
        }
    }

    @Test("rtlListInContainerStaysSwiftUI: right to left, list text in a quote, an extension body and a stacked column stays on SwiftUI (rule C) while the prose beside it migrates; left to right the same lists migrate")
    @MainActor
    func rtlListInContainerStaysSwiftUI() async throws {
        let p = { (text: String) in TK2ContainerProbe.paragraph(TK2ContainerProbe.t(text)) }
        let list = TK2ContainerProbe.bulletList([TK2ContainerProbe.item(p("First row.")), TK2ContainerProbe.item(p("Second row."))])
        let content = [
            TK2ContainerProbe.quote([p("Quote prose."), list]),
            TK2ContainerProbe.bodiedExtension([p("Extension prose."), list]),
            TK2ContainerProbe.section([(50, [p("Column prose."), list]), (50, [p("Other column.")])]),
        ]
        let (blocks, ltr) = try await Self.hostedListRows(content, direction: .leftToRight)
        let listText = TK2ContainerBody.listOwners(in: blocks)
        #expect(listText.count == 6, "\(listText.sorted())")
        let prose = TK2ContainerColumns.allTextOwners(blocks).subtracting(listText)
        #expect(prose.count == 4, "\(prose.sorted())")
        #expect(Set(ltr.keys) == Self.passing(prose.union(listText)), "left to right: \(ltr.keys.sorted())")
        let (_, rtl) = try await Self.hostedListRows(content, direction: .rightToLeft)
        #expect(Set(rtl.keys) == Self.passing(prose), "right to left: \(rtl.keys.sorted())")
        #expect(!TextKit2Scope.listDirectionKeepsRenderer(.rightToLeft))
    }

    @Test("narrowNestedListStaysSwiftUI: rule D reads the container's bound: at a width where a depth-2 row has a text column at the top level, the same row in a quote (16 pt narrower) stays on SwiftUI while its shallower rows migrate")
    @MainActor
    func narrowNestedListStaysSwiftUI() async throws {
        let size = DynamicTypeSize.accessibility5
        let p = { (text: String) in TK2ContainerProbe.paragraph(TK2ContainerProbe.t(text)) }
        let list = TK2ContainerProbe.bulletList([
            TK2ContainerProbe.item(p("Top."), TK2ContainerProbe.bulletList([
                TK2ContainerProbe.item(p("Mid."), TK2ContainerProbe.bulletList([TK2ContainerProbe.item(p("ok"))])),
            ])),
        ])
        // The depth-2 text column at the top level is 8 pt wide (rule D
        // passes) and in the quote 8 pt short of nothing (it fails).
        let blocks = try await TK2ContainerProbe.prepared([list])
        guard case .listRows(let probeRows) = try #require(blocks.first).kind else { throw TestFailure("not a list") }
        let deep = try #require(probeRows.first { $0.depth == 2 })
        let inset = TK2ContainerLists.textColumnInset(deep, size: size)
        let documentWidth = (inset + 4 * TK2ContainerProbe.spacing + 8).rounded()
        let rowWidth = TK2ContainerProbe.rowWidth(documentWidth: documentWidth)
        #expect(TextKit2Scope.listTextFits(.atLeast(rowWidth), inset: inset))
        #expect(!TextKit2Scope.listTextFits(.atLeast(rowWidth - 2 * TK2ContainerProbe.spacing), inset: inset))

        let (hostedBlocks, rows) = try await Self.hostedListRows([list, TK2ContainerProbe.quote([list])], width: documentWidth, size: size)
        guard case .listRows(let top) = hostedBlocks[0].kind, case .quote(let quoted) = hostedBlocks[1].kind,
              case .listRows(let nested) = quoted[0].kind else { throw TestFailure("unexpected prepared shape") }
        let narrow = TK2ContainerLists.narrowListText(in: [hostedBlocks[1]], bound: rowWidth, size: size)
        #expect(narrow == [nested[2].id], "rule D written out: \(narrow.sorted())")
        let drawn = Set(rows.keys)
        // Top-level list text is PR 2's: on TextKit 2 from iOS 26.
        let topText = TextKit2Eligibility.listsMatchText ? Set(top.map(\.id)) : []
        #expect(drawn == topText.union(Self.passing([nested[0].id, nested[1].id])), "W=\(documentWidth) \(drawn.sorted())")
    }

    @Test("nestedListBeforeIOS26StaysSwiftUI: before iOS 26 list text in a quote, an extension body and a stacked column falls back as osGatedList (the list gate first) and draws no row; from iOS 26 it is eligible and draws")
    @MainActor
    func nestedListBeforeIOS26StaysSwiftUI() async throws {
        let p = { (text: String) in TK2ContainerProbe.paragraph(TK2ContainerProbe.t(text)) }
        let list = TK2ContainerProbe.bulletList([TK2ContainerProbe.item(p("Row."), p("Its second paragraph.")), TK2ContainerProbe.item(p("Next row."))])
        let content = [
            TK2ContainerProbe.quote([list]),
            TK2ContainerProbe.bodiedExtension([list]),
            TK2ContainerProbe.section([(50, [list]), (50, [p("Beside.")])]),
        ]
        let blocks = try await TK2ContainerProbe.prepared(content)
        let gated = !TextKit2Eligibility.listsMatchText
        var leaves = 0
        TextKit2Scope.forEachLeaf(in: blocks) { leaf in
            guard leaf.position == .containerListLeader || leaf.position == .containerListTrailing else { return }
            leaves += 1
            if gated {
                if case .fallback(.osGatedList) = leaf.verdict {} else { Issue.record("\(leaf.ownerID): \(leaf.verdict), expected osGatedList") }
            } else {
                if case .fallback = leaf.verdict { Issue.record("\(leaf.ownerID): \(leaf.verdict)") }
            }
        }
        #expect(leaves == 9, "three lists of three leaves")
        let (_, rows) = try await Self.hostedListRows(content)
        let listText = TK2ContainerBody.listOwners(in: blocks)
        #expect(Set(rows.keys).intersection(listText) == (gated ? [] : listText), "\(rows.keys.sorted())")
    }
}

// MARK: - First screen: one conversion per nested-list owner

extension TextKit2ContainerWidthTests {
    /// The width bound is `.pending` until the document has measured its
    /// width (`ADFDocumentView`), and rule D passes `.pending`; the known
    /// bound then replaces it. If that change flipped a leaf's engine, its
    /// owner would get a second row (or lose its row) and convert its text
    /// again. This hosts nested lists on the first screen (a quote, an
    /// extension body, a stacked column) and follows every TextKit 2 row
    /// turn by turn from the first layout: each nested-list owner is drawn
    /// by one row, which converts its text once (one `attributed` string)
    /// and never leaves. Prints `FIRST_SCREEN_LISTS owners=… rows=…
    /// conversions=…`.
    @Test("firstScreenNestedListConvertsOnce: each first-screen nested-list owner gets one row that converts once across the pending → known width change")
    @MainActor
    func firstScreenNestedListConvertsOnce() async throws {
        let p = { (count: Int, from: Int) in TK2ContainerProbe.paragraph(TK2ContainerProbe.t(TK2ContainerProbe.words(count, from: from))) }
        let shapes = Dictionary(uniqueKeysWithValues: TK2ContainerLists.allShapes.map { ($0.name, $0.body) })
        let nested = try #require(shapes["nestedList"])
        let tasks = try #require(shapes["orderedTasks"])
        let content = [
            TK2ContainerProbe.quote(nested),
            TK2ContainerProbe.bodiedExtension(tasks),
            TK2ContainerProbe.section([(40, [TK2ContainerProbe.bulletList([TK2ContainerProbe.item(p(4, 6)), TK2ContainerProbe.item(p(3, 11))])]), (60, [p(6, 3)])]),
        ]
        let json = Self.document(content)
        let model = ADFDocumentModel()
        model.load(data: Data(json.utf8))
        for _ in 0..<500 where model.phase != .ready {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.phase == .ready)
        let listText = TK2ContainerBody.listOwners(in: model.blocks)
        let document = ADFDocumentView(model: model, mediaProvider: TextKit2DiagnosticsTests.NoMedia(), textRenderer: .textKit2)
            .environment(\.horizontalSizeClass, .compact)
        let hosted = TK2CodeLogic.Hosted(document, size: CGSize(width: 390, height: 844))

        // Every row instance and every converted string seen per owner, and
        // the turns an owner was absent after it first appeared.
        var rowsByOwner: [String: Set<ObjectIdentifier>] = [:]
        var stringsByOwner: [String: Set<ObjectIdentifier>] = [:]
        var gaps: [String: Int] = [:]
        func sample() {
            var present: Set<String> = []
            for row in hosted.rows {
                guard let owner = row.ownerID, listText.contains(owner) else { continue }
                present.insert(owner)
                rowsByOwner[owner, default: []].insert(ObjectIdentifier(row))
                if row.attributed.length > 0 { stringsByOwner[owner, default: []].insert(ObjectIdentifier(row.attributed)) }
            }
            for owner in rowsByOwner.keys where !present.contains(owner) { gaps[owner, default: 0] += 1 }
        }
        sample()
        for _ in 0..<120 {
            hosted.window.layoutIfNeeded()
            sample()
            try await Task.sleep(for: .milliseconds(5))
        }
        try await hosted.settle()
        sample()
        hosted.close()

        let expected = TextKit2Eligibility.containerTextMatchesText ? listText : []
        let conversions = stringsByOwner.values.reduce(0) { $0 + $1.count }
        print("FIRST_SCREEN_LISTS owners=\(rowsByOwner.count) expected=\(expected.count) rows=\(rowsByOwner.values.reduce(0) { $0 + $1.count }) conversions=\(conversions) gaps=\(gaps.values.reduce(0, +))")
        #expect(listText.count == 11, "\(listText.sorted())")
        #expect(Set(rowsByOwner.keys) == expected, "first-screen nested-list owners \(rowsByOwner.keys.sorted())")
        for (owner, rows) in rowsByOwner {
            #expect(rows.count == 1, "\(owner): \(rows.count) rows")
            #expect(stringsByOwner[owner]?.count == 1, "\(owner): \(stringsByOwner[owner]?.count ?? 0) conversions")
            #expect(gaps[owner] == nil, "\(owner): absent \(gaps[owner] ?? 0) turns after appearing")
        }
    }
}
#endif
