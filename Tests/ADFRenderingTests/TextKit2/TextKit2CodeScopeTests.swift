import Foundation
import SwiftUI
import Testing
import ADFModel
import ADFPreparation
@testable import ADFRendering

/// Shared plumbing for the code-block logic suites (scope, fallbacks and
/// diagnostics): code strings stamped as the preparer stamps them, small
/// ADF documents built as JSON objects, and (with UIKit) hosting of the real
/// code and document views. The pixel and size parity suite has its own.
enum TK2CodeLogic {
    /// The default theme's code font spec.
    static let mono = ADFFontSpec(textStyle: .body, monospaced: true)

    /// A code string as `DocumentPreparer` prepares one: the code font, the
    /// font spec (when the theme has one) and the shape of the text, over
    /// the whole string.
    static func stamped(_ string: String, spec: ADFFontSpec? = mono) -> AttributedString {
        var code = AttributedString(string)
        let font: Font = spec.map { Font(adfFontSpec: $0) } ?? Font.system(size: 13, design: .monospaced)
        code[AttributeScopes.SwiftUIAttributes.FontAttribute.self] = font
        if let spec { code.adfFontSpec = spec }
        code.adfCodeShape = ADFCodeShape(string)
        return code
    }

    /// The same string carrying `shape` instead of its measured one (`nil`:
    /// no shape, as for text assembled outside the preparer).
    static func stamped(_ string: String, spec: ADFFontSpec? = mono, shape: ADFCodeShape?) -> AttributedString {
        var code = stamped(string, spec: spec)
        code.adfCodeShape = shape
        return code
    }

    /// Why a verdict falls back; `nil` when it is eligible.
    static func reason(_ verdict: TextKit2Eligibility.Verdict) -> TextKit2Eligibility.Fallback? {
        if case .fallback(let reason) = verdict { return reason }
        return nil
    }

    // MARK: ADF JSON

    static func text(_ string: String) -> [String: Any] {
        ["type": "text", "text": string]
    }

    static func paragraph(_ string: String) -> [String: Any] {
        ["type": "paragraph", "content": [text(string)]]
    }

    /// A code block node; empty text gives a node without content.
    static func code(_ string: String, language: String? = nil) -> [String: Any] {
        var node: [String: Any] = ["type": "codeBlock"]
        if !string.isEmpty { node["content"] = [text(string)] }
        if let language { node["attrs"] = ["language": language] }
        return node
    }

    static func node(_ type: String, attrs: [String: Any]? = nil, _ content: [[String: Any]]) -> [String: Any] {
        var node: [String: Any] = ["type": type, "content": content]
        if let attrs { node["attrs"] = attrs }
        return node
    }

    /// The JSON of a document whose top-level nodes are `content` (ids
    /// `0.0`, `0.1`, … in order).
    static func document(_ content: [[String: Any]]) throws -> Data {
        let object: [String: Any] = ["version": 1, "type": "doc", "content": content]
        return try JSONSerialization.data(withJSONObject: object)
    }

    static func prepared(_ data: Data, theme: ADFTheme = .default) async throws -> [RenderBlock] {
        let doc = try await ADFParser().parse(data)
        return DocumentPreparer(theme: theme).prepare(doc)
    }

    /// The prepared code string of the top-level code block `id`.
    static func preparedCode(_ id: String, in blocks: [RenderBlock]) throws -> AttributedString {
        let block = try #require(blocks.first { $0.id == id }, "no block \(id)")
        guard case .codeBlock(_, let code) = block.kind else {
            throw TestFailure("block \(id) is not a code block")
        }
        return code
    }
}

/// Where code may be drawn by TextKit 2, as rules (plan 3.2): a top-level
/// code block keeps the renderer choice and is a `.codeRoot` leaf of its
/// own kind. From PR 4 step 7 a code block below a container the renderer
/// reaches (a panel whose body passes the shape rule, a quote, an expand
/// body, a stacked layout column) is a `.containerCode` leaf of the same
/// kind; code in a list item, a table cell or a side-by-side column stays
/// out of scope. Cross-platform.
@Suite("TextKit 2 code scope: rules")
struct TextKit2CodeScopeRuleTests {
    /// Code at the top level (`0.0`, `0.7`) and inside every kind of
    /// container: a list item after its paragraph (`0.1.0.1`), a list item
    /// that is only code (`0.1.1.0`), a panel (`0.2.0`), an expand (`0.3`,
    /// whose body is prepared when it opens), a quote (`0.4.0`), a layout
    /// column (`0.5.0.0`) and a table cell (`0.6.0.0.0`). The list's third
    /// item is plain text (`0.1.2`).
    static func content() -> [[String: Any]] {
        let item = { (children: [[String: Any]]) in TK2CodeLogic.node("listItem", children) }
        let column = { (children: [[String: Any]]) in TK2CodeLogic.node("layoutColumn", attrs: ["width": 50], children) }
        let cell = TK2CodeLogic.node("tableCell", [TK2CodeLogic.code("let inCell = 8")])
        return [
            TK2CodeLogic.code("let top = 1", language: "swift"),
            TK2CodeLogic.node("bulletList", [
                item([TK2CodeLogic.paragraph("Item with code"), TK2CodeLogic.code("let inItem = 2")]),
                item([TK2CodeLogic.code("let codeFirst = 3")]),
                item([TK2CodeLogic.paragraph("Plain item")]),
            ]),
            TK2CodeLogic.node("panel", attrs: ["panelType": "info"], [TK2CodeLogic.code("let inPanel = 4")]),
            TK2CodeLogic.node("expand", attrs: ["title": "Details"], [TK2CodeLogic.code("let inExpand = 5")]),
            TK2CodeLogic.node("blockquote", [TK2CodeLogic.code("let inQuote = 6")]),
            TK2CodeLogic.node("layoutSection", [
                column([TK2CodeLogic.code("let inColumn = 7")]),
                column([TK2CodeLogic.paragraph("Column text")]),
            ]),
            TK2CodeLogic.node("table", [TK2CodeLogic.node("tableRow", [cell])]),
            TK2CodeLogic.code("let last = 9"),
        ]
    }

    /// The code blocks prepared inside containers (the expand's body is not
    /// prepared with the document).
    static let nestedCode: Set<String> = ["0.1.0.1", "0.1.1.0", "0.2.0", "0.4.0", "0.5.0.0", "0.6.0.0.0"]

    /// Ids of the code blocks below the top level of a prepared tree.
    static func nestedCodeIDs(_ blocks: [RenderBlock], nested: Bool = false) -> Set<String> {
        var found: Set<String> = []
        for block in blocks {
            switch block.kind {
            case .codeBlock:
                if nested { found.insert(block.id) }
            case .panel(_, let children), .quote(let children), .extensionPlaceholder(_, let children):
                found.formUnion(nestedCodeIDs(children, nested: true))
            case .listRows(let rows):
                found.formUnion(nestedCodeIDs(rows.flatMap(\.trailingBlocks), nested: true))
            case .tableSlice(_, let rows, _):
                found.formUnion(nestedCodeIDs(rows.flatMap { $0.cells.flatMap(\.blocks) }, nested: true))
            case .layoutColumns(let columns):
                found.formUnion(nestedCodeIDs(columns.flatMap(\.blocks), nested: true))
            default:
                break
            }
        }
        return found
    }

    @Test("a top-level code block keeps the renderer choice; a container keeps it as the container allow list says and, from step 7, passes it to its code, except side by side; a list item and a table cell never do")
    func inheritsRenderer() async throws {
        let blocks = try await TK2CodeLogic.prepared(try TK2CodeLogic.document(Self.content()))
        #expect(Self.nestedCodeIDs(blocks) == Self.nestedCode)
        for block in blocks {
            let inherits = TextKit2Scope.inheritsRenderer(block.kind)
            switch block.kind {
            case .codeBlock:
                #expect(["0.0", "0.7"].contains(block.id), "\(block.id)")
                #expect(inherits, "\(block.id): a top-level code block keeps the choice")
            case .listRows:
                #expect(block.id == "0.1")
                #expect(inherits, "\(block.id): the list keeps the choice for its own text")
            case .panel, .quote, .layoutColumns, .expand:
                // From PR 4 step 3 the panel (its body passes the shape
                // rule) and the quote keep the choice for their prose, from
                // step 4 the layout section and from step 5 the expand for
                // its open body's; from step 7 they pass it to their code
                // (below).
                #expect(["0.2", "0.3", "0.4", "0.5"].contains(block.id), "\(block.id)")
                #expect(inherits, "\(block.id): panels, quotes, layout columns and expands are in the container allow list")
            default:
                #expect(!inherits, "\(block.id): a container must reset the choice")
            }
            let children: [RenderBlock]
            switch block.kind {
            case .panel(_, let blocks), .quote(let blocks): children = blocks
            case .layoutColumns(let columns): children = columns.flatMap(\.blocks)
            default: children = []
            }
            for child in children where TextKit2CodeCoverageTests.isCode(child) {
                // PR 4 step 7: code joined the container allow list. Every
                // migrated parent passes the renderer to a code block, but a
                // side-by-side column (no family keeps it there, lead call
                // C32); a parent that inherited SwiftUI never does.
                for parent in [TextKit2ContainerParent.panel, .quote, .expandBody, .extensionBody, .column(sideBySide: false), .column(sideBySide: true)] {
                    for direction in [LayoutDirection.leftToRight, .rightToLeft] {
                        let renderer = TextKit2Scope.childRenderer(
                            for: child.kind, in: parent, inherited: .textKit2, allowed: TextKit2Scope.containerChildKinds, layoutDirection: direction,
                            dynamicTypeSize: .large
                        )
                        // Right to left no container passes it (the
                        // container direction rule, lead dispositions F-Q6).
                        let expected: ADFTextRenderer = parent == .column(sideBySide: true) || direction == .rightToLeft ? .swiftUI : .textKit2
                        #expect(renderer == expected, "\(child.id) in \(parent) \(direction): code is in the container allow list from step 7")
                        #expect(TextKit2Scope.childRenderer(
                            for: child.kind, in: parent, inherited: .swiftUI, allowed: TextKit2Scope.containerChildKinds, layoutDirection: direction,
                            dynamicTypeSize: .large
                        ) == .swiftUI, "\(child.id) in \(parent): never turned back on below SwiftUI")
                    }
                    // Before step 7's list (the step-5 stage), the same code
                    // stayed on SwiftUI: the allow list is what changed.
                    let step5 = TextKit2Scope.containerChildKinds.subtracting([.codeBlock])
                    #expect(TextKit2Scope.childRenderer(
                        for: child.kind, in: parent, inherited: .textKit2, allowed: step5, layoutDirection: .leftToRight, dynamicTypeSize: .large
                    ) == .swiftUI, "\(child.id) in \(parent) without code in the list")
                }
            }
        }
        let kinds = blocks.filter { if case .codeBlock = $0.kind { return true } else { return false } }
        #expect(kinds.map(\.id) == ["0.0", "0.7"])

        // The kind decides, not the content: an empty or ineligible code
        // block still keeps the choice (its leaf falls back by itself).
        #expect(TextKit2Scope.inheritsRenderer(.codeBlock(language: nil, code: AttributedString())))
        #expect(TextKit2Scope.inheritsRenderer(.codeBlock(language: "make", code: TK2CodeLogic.stamped("all:\n\ttrue"))))
        let code = RenderBlock(id: "q.0", kind: .codeBlock(language: nil, code: TK2CodeLogic.stamped("x")))
        #expect(TextKit2Scope.inheritsRenderer(.quote([code])), "a quote keeps the choice for its prose")
        #expect(TextKit2Scope.childRenderer(
            for: code.kind, in: .quote, inherited: .textKit2, allowed: TextKit2Scope.containerChildKinds, layoutDirection: .leftToRight,
            dynamicTypeSize: .large
        ) == .textKit2, "and from step 7 for its code")
        // A panel keeps it only where its body passes the shape rule: code
        // alone does, code beside a paragraph does not (step 3's rule).
        #expect(TextKit2Scope.inheritsRenderer(.panel(ADFTheme.default.panelPalette(.info, colorHex: nil), [code])))
        let beside = RenderBlock(id: "p.0", kind: .richText(segments: [], style: TextBlockStyle(
            font: ADFTheme.default.body, isHeading: false, headingLevel: nil, alignment: nil, indentation: 0, breakout: nil
        )))
        #expect(!TextKit2Scope.inheritsRenderer(.panel(ADFTheme.default.panelPalette(.info, colorHex: nil), [beside, code])))
        #expect(!TextKit2Scope.inheritsRenderer(.divider))
        #expect(!TextKit2Scope.inheritsRenderer(.unknown(typeName: "mystery")))
    }

    @Test("the coverage walk visits top-level code as code roots and, from step 7, code in a panel, a quote and a stacked column as container code; never code in a list item or a table cell")
    func leaves() async throws {
        let blocks = try await TK2CodeLogic.prepared(try TK2CodeLogic.document(Self.content()))
        var owners: [String] = []
        var positions: [TextKit2Scope.Position] = []
        var codeLeaves: [TextKit2Scope.Leaf] = []
        TextKit2Scope.forEachLeaf(in: blocks) { leaf in
            owners.append(leaf.ownerID)
            positions.append(leaf.position)
            if leaf.position == .codeRoot || leaf.position == .containerCode { codeLeaves.append(leaf) }
        }
        // The two top-level code blocks and the one list row that keeps the
        // renderer (the two items holding code keep their text on SwiftUI);
        // from PR 4 step 4 the column's paragraph (container prose); from
        // step 7 the code in the panel, the quote and the column (container
        // code). The expand's body is not prepared with the document, and
        // the code in the list items and the table cell stays out.
        #expect(owners == ["0.0", "0.1.2", "0.2.0", "0.4.0", "0.5.0.0", "0.5.1.0", "0.7"])
        #expect(positions == [.codeRoot, .listLeader, .containerCode, .containerCode, .containerCode, .containerProse, .codeRoot])
        #expect(Set(owners).intersection(Self.nestedCode) == ["0.2.0", "0.4.0", "0.5.0.0"])
        for leaf in codeLeaves {
            // A code leaf carries the block's prepared string and nothing a
            // prose leaf carries.
            #expect(leaf.segments.isEmpty && leaf.style == nil, "\(leaf.ownerID)")
            let block = try #require(TextKit2ContainerCoverageTests.find(leaf.ownerID, in: blocks), "no block \(leaf.ownerID)")
            guard case .codeBlock(_, let stored) = block.kind else {
                Issue.record("\(leaf.ownerID) is not a code block")
                continue
            }
            #expect(leaf.code == stored, "\(leaf.ownerID)")
            // Container code is gated before iOS 26 (`containerCodeVerdict`).
            if leaf.position == .containerCode, !TextKit2Eligibility.containerTextMatchesText {
                #expect(TK2CodeLogic.reason(leaf.verdict) == .osGatedContainer, "\(leaf.ownerID)")
                continue
            }
            guard case .eligible(let text) = leaf.verdict else {
                Issue.record("\(leaf.ownerID): \(leaf.verdict)")
                continue
            }
            #expect(text == leaf.code, "\(leaf.ownerID): the verdict hands back the stored string")
        }

        // Code is counted apart from the text leaves: top-level code in the
        // two code-root counts, code below a container in the two nested
        // counts, so the root sum still holds (plan §6.3).
        let coverage = ADFTextRenderer.textKit2Coverage(of: blocks)
        let containers = TextKit2Eligibility.containerTextMatchesText
        #expect(coverage.eligibleCodeRoots == 2 && coverage.fallbackCodeRoots == 0)
        #expect(coverage.eligibleCodeRoots + coverage.fallbackCodeRoots == 2, "the top-level code blocks")
        #expect(coverage.eligibleNestedCode == (containers ? 3 : 0) && coverage.fallbackNestedCode == (containers ? 0 : 3), "\(coverage)")
        #expect(coverage.eligibleRoots == 0 && coverage.fallbackRoots == blocks.count)
        #expect(coverage.listLeaderLeaves == 1 && coverage.listTrailingLeaves == 0)
        #expect(coverage.eligibleTextLeaves + coverage.fallbackTextLeaves == 1)
    }

    @Test("code is its own owner kind: judged by the code rules, laid out once, never by a list rule")
    func ownerKind() {
        #expect(TextKit2Scope.Position.root.ownerKind == .root)
        #expect(TextKit2Scope.Position.listLeader.ownerKind == .list)
        #expect(TextKit2Scope.Position.listTrailing.ownerKind == .list)
        #expect(TextKit2Scope.Position.codeRoot.ownerKind == .code)
        #expect(TextKit2OwnerKind.root.layoutPolicy == .wrapping)
        #expect(TextKit2OwnerKind.list.layoutPolicy == .wrapping)
        #expect(TextKit2OwnerKind.code.layoutPolicy == .natural)

        // The same eligible string as code never takes the list OS gate.
        let plain = TK2CodeLogic.stamped("let x = 1")
        #expect(TK2CodeLogic.reason(TextKit2Eligibility.verdict(plain, owner: .code)) == nil)
        let asList = TK2CodeLogic.reason(TextKit2Eligibility.verdict(plain, owner: .list))
        let gated: TextKit2Eligibility.Fallback? = TextKit2Eligibility.listsMatchText ? nil : .osGatedList
        #expect(asList == gated)
        let codeLeaf = TextKit2Scope.Leaf(ownerID: "c", segments: [], style: nil, position: .codeRoot, code: plain)
        #expect(TK2CodeLogic.reason(codeLeaf.verdict) == nil)

        // And prose rules do not judge code: a tab is fine in a paragraph,
        // not in code.
        let tabbed = TK2CodeLogic.stamped("a\tb")
        #expect(TK2CodeLogic.reason(TextKit2Eligibility.verdict(tabbed, owner: .root)) == nil)
        #expect(TK2CodeLogic.reason(TextKit2Eligibility.verdict(tabbed, owner: .code)) == .codeTabs)
        #expect(TextKit2Eligibility.describableText(tabbed, owner: .code) == nil)
        #expect(TextKit2Eligibility.describableText(plain, owner: .code) == plain)

        // A code leaf without a string is empty code, not prose.
        let missing = TextKit2Scope.Leaf(ownerID: "m", segments: [.text(plain)], style: nil, position: .codeRoot)
        #expect(TK2CodeLogic.reason(missing.verdict) == .empty)
    }
}

#if canImport(UIKit)
import UIKit

extension TK2CodeLogic {
    /// A window hosting one SwiftUI view, for looking at the row views it
    /// creates.
    @MainActor
    final class Hosted {
        let window: UIWindow
        let host: UIHostingController<AnyView>

        init(_ view: some View, size: CGSize = CGSize(width: 390, height: 1_600)) {
            window = UIWindow(frame: CGRect(origin: .zero, size: size))
            host = UIHostingController(rootView: AnyView(view))
            window.rootViewController = host
            window.isHidden = false
        }

        func show(_ view: some View) {
            host.rootView = AnyView(view)
        }

        func settle() async throws {
            try await TextKit2DiagnosticsTests.settle(window)
        }

        /// This window's TextKit 2 rows.
        var rows: [TextKit2RowView] { TextKit2FallbackTests.rows(in: host.view) }

        /// This window's rows drawing code.
        var codeRows: [TextKit2RowView] { rows.filter { $0.ownerKind == .code } }

        /// The owners of this window's rows.
        var owners: Set<String> { Set(rows.compactMap(\.ownerID)) }

        /// The scroll views in this window: the document's own and one per
        /// code block on screen (a code block's viewport is a horizontal
        /// scroll view under either engine).
        var scrollViews: [UIScrollView] { TK2CodeLogic.scrollViews(in: host.view) }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    @MainActor
    static func scrollViews(in view: UIView) -> [UIScrollView] {
        var found: [UIScrollView] = []
        if let scrollView = view as? UIScrollView { found.append(scrollView) }
        for subview in view.subviews { found += scrollViews(in: subview) }
        return found
    }

    /// The real code block view around `code`, in the environment a
    /// document row gives it.
    @MainActor
    static func codeView(
        _ code: AttributedString, ownerID: String? = "code", renderer: ADFTextRenderer = .textKit2,
        theme: ADFTheme = .default, size: DynamicTypeSize = .large,
        direction: LayoutDirection = .leftToRight, legibility: LegibilityWeight? = nil
    ) -> some View {
        CodeBlockView(language: nil, code: code, ownerID: ownerID)
            .environment(\.adfTextRenderer, renderer)
            .environment(\.adfTheme, theme)
            .environment(\.layoutDirection, direction)
            .environment(\.legibilityWeight, legibility)
            .dynamicTypeSize(size)
    }

    /// A model loaded with `data`, ready.
    @MainActor
    static func loadedModel(_ data: Data, theme: ADFTheme = .default) async throws -> ADFDocumentModel {
        let model = ADFDocumentModel(theme: theme)
        model.load(data: data)
        for _ in 0..<500 where model.phase != .ready {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.phase == .ready)
        return model
    }

    @MainActor
    static func documentView(_ model: ADFDocumentModel, _ renderer: ADFTextRenderer) -> ADFDocumentView {
        ADFDocumentView(model: model, mediaProvider: TextKit2DiagnosticsTests.NoMedia(), textRenderer: renderer)
    }

    /// Draws `row` once, now, through its canvas (as a display pass does).
    @MainActor
    static func draw(_ row: TextKit2RowView) {
        for canvas in row.subviews {
            canvas.setNeedsDisplay()
            canvas.layer.displayIfNeeded()
        }
    }
}

/// Through the real views under `.textKit2` (plan 3.2, 3.3): a top-level
/// code block's code is drawn by a TextKit 2 row identified
/// `tk2-row:<block id>`; a code block inside a list item or a table cell
/// gets none, because the list row resets the choice and a table never
/// keeps it. From PR 4 step 7 a code block in a panel, an open expand, a
/// quote or a stacked layout column gets one too (from iOS 26), through its
/// container's boundary; side by side a column keeps it on SwiftUI.
@Suite("TextKit 2 code scope", .serialized)
@MainActor
struct TextKit2CodeScopeTests {
    @Test("top-level code gets a TextKit 2 row; from step 7 so does code in a panel, an open expand, a quote and a stacked column (iOS 26); code in a list item and a table cell gets none")
    func scope() async throws {
        let model = try await TK2CodeLogic.loadedModel(try TK2CodeLogic.document(TextKit2CodeScopeRuleTests.content()))
        // The nested code blocks exist as prepared code, so their absence
        // below is the scope's doing, not a missing block.
        #expect(TextKit2CodeScopeRuleTests.nestedCodeIDs(model.blocks) == TextKit2CodeScopeRuleTests.nestedCode)

        let hosted = TK2CodeLogic.Hosted(TK2CodeLogic.documentView(model, .textKit2), size: CGSize(width: 390, height: 4_000))
        defer { hosted.close() }
        try await hosted.settle()

        // Open the expand (its body is prepared on first opening) and wait
        // for its code block's viewport to appear.
        let collapsed = hosted.scrollViews.count
        model.expandedBlocks.insert("0.3")
        for _ in 0..<250 where hosted.scrollViews.count <= collapsed {
            hosted.window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        try await hosted.settle()
        let expanded = hosted.scrollViews.count
        #expect(expanded == collapsed + 1, "the expand's code block is on screen: \(collapsed) → \(expanded) scroll views")
        // The document's scroll view and the nine code blocks' viewports:
        // every code block is on screen, on either engine.
        #expect(expanded >= 1 + 9, "\(expanded) scroll views")

        let found = Set(TextKit2DiagnosticsTests.identifiers(in: hosted.host.view).map { String($0.dropFirst("tk2-row:".count)) })
        var expected: Set<String> = ["0.0", "0.7"]
        let stacked = hosted.window.traitCollection.horizontalSizeClass != .regular
        // PR 4 step 7: the code in the panel, the quote and the open
        // expand's body, and while the columns stack the code in the
        // column, from iOS 26 (before it nested code is
        // `osGatedContainer`). Never the list items' or the table cell's.
        var nestedRows: Set<String> = []
        if TextKit2Eligibility.containerTextMatchesText {
            nestedRows = ["0.2.0", "0.3.0", "0.4.0"]
            if stacked { nestedRows.insert("0.5.0.0") }
        }
        expected.formUnion(nestedRows)
        // The plain list item beside the two items holding code (from
        // iOS 26; before it lists keep their text on SwiftUI).
        if TextKit2Eligibility.listsMatchText { expected.insert("0.1.2") }
        // The paragraph in the layout column beside the column holding code
        // while the columns stack (PR 4 step 4: a phone's compact width;
        // side by side no family keeps the renderer), from iOS 26 (before
        // it container text stays on SwiftUI).
        if TextKit2Eligibility.containerTextMatchesText, stacked { expected.insert("0.5.1.0") }
        #expect(found == expected, "missing \(expected.subtracting(found).sorted()), unexpected \(found.subtracting(expected).sorted())")
        #expect(found.intersection(TextKit2CodeScopeRuleTests.nestedCode) == nestedRows.subtracting(["0.3.0"]))
        // The list items' and the table cell's code never.
        #expect(found.isDisjoint(with: ["0.1.0.1", "0.1.1.0", "0.6.0.0.0"]))

        // The code rows are code rows: counted as such, never wrapping; the
        // nested ones carry the container context beside the owner kind.
        let rows = hosted.rows
        #expect(Set(rows.filter { $0.ownerKind == .code }.compactMap(\.ownerID)) == nestedRows.union(["0.0", "0.7"]))
        #expect(Set(rows.filter { $0.ownerKind == .code && $0.containerContext == .container }.compactMap(\.ownerID)) == nestedRows)
        for row in rows {
            let policy: TextKit2LayoutPolicy = row.ownerKind == .code ? .natural : .wrapping
            #expect(row.inputs?.layoutPolicy == policy, "\(row.ownerID ?? "?")")
        }

        // Switching back releases them; the same code blocks stay on screen.
        hosted.show(TK2CodeLogic.documentView(model, .swiftUI))
        try await hosted.settle()
        #expect(TextKit2DiagnosticsTests.identifiers(in: hosted.host.view).isEmpty)
        #expect(hosted.scrollViews.count == expanded)
    }

    @Test("the code view only reads the renderer choice: SwiftUI by default, a code row when its row passes TextKit 2 on")
    func codeViewReadsTheChoice() async throws {
        let code = TK2CodeLogic.stamped("let answer = 42\nprint(answer)")
        // No renderer in the environment: the default is SwiftUI.
        let plain = TK2CodeLogic.Hosted(CodeBlockView(language: "swift", code: code, ownerID: "plain"))
        defer { plain.close() }
        try await plain.settle()
        #expect(plain.rows.isEmpty)
        #expect(plain.scrollViews.count == 1, "the code block's own viewport")

        let on = TK2CodeLogic.Hosted(TK2CodeLogic.codeView(code, ownerID: "on"))
        defer { on.close() }
        try await on.settle()
        let rows = on.rows
        #expect(rows.count == 1)
        #expect(rows.first?.ownerKind == .code)
        #expect(rows.first?.ownerID == "on")
        #expect(rows.first?.accessibilityIdentifier == "tk2-row:on")
        #expect(rows.first?.inputs?.text == code, "the row draws the stored string")
        // The row sits inside the code block's own horizontal scroll view.
        let scrollView = try #require(on.scrollViews.first)
        #expect(on.scrollViews.count == 1)
        #expect(rows.first?.isDescendant(of: scrollView) == true)

        // Explicitly off: no row either.
        on.show(TK2CodeLogic.codeView(code, ownerID: "on", renderer: .swiftUI))
        try await on.settle()
        #expect(on.rows.isEmpty)
    }
}
#endif
