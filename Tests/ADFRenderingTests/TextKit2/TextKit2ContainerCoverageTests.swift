import Foundation
import SwiftUI
import Testing
import ADFModel
@testable import ADFPreparation
@_spi(ADFDiagnostics) @testable import ADFRendering

/// A document with text below every kind of container, counted by hand
/// (plan §6.2–§6.3). Top-level ids are `0.0`, `0.1`, … in order.
enum TK2ContainerCoverage {
    static func link(_ string: String) -> [String: Any] {
        ["type": "text", "text": string, "marks": [["type": "link", "attrs": ["href": "https://example.com"]]]]
    }

    static func item(_ children: [[String: Any]]) -> [String: Any] {
        TK2CodeLogic.node("listItem", children)
    }

    static func column(_ width: Double, _ children: [[String: Any]]) -> [String: Any] {
        TK2CodeLogic.node("layoutColumn", attrs: ["width": width], children)
    }

    static func panel(_ type: String, _ children: [[String: Any]]) -> [String: Any] {
        TK2CodeLogic.node("panel", attrs: ["panelType": type], children)
    }

    /// With every kind allowed, from iOS 26 (before it every container
    /// leaf falls back, `osGatedContainer`, the nested list leader as
    /// `osGatedList`):
    ///
    /// | id | node | counts |
    /// |---|---|---|
    /// | 0.0 | paragraph | root, eligible |
    /// | 0.1 | code | code root, eligible |
    /// | 0.2 | quote: paragraph, code, list of one item | container prose, nested code, container list leader: all eligible |
    /// | 0.3 | quote: linked paragraph, heading | container prose ×2, one linked |
    /// | 0.4 | section: [paragraph] [paragraph, panel: paragraph] | container prose ×3 |
    /// | 0.5 | expand | an unprepared expand |
    /// | 0.6 | panel: nested expand | nothing (`panelKeepsRenderer`: an expand, whose body is prepared on opening) |
    /// | 0.7 | bodied extension: paragraph | container prose |
    /// | 0.8 | extension without a body | nothing |
    /// | 0.9 | media with a caption | caption: eligible from iOS 26, `osGatedContainer` before |
    /// | 0.10 | table: paragraph | nothing (tables are excluded) |
    /// | 0.11 | list: leader, trailing paragraph | list leader, list trailing |
    /// | 0.12 | panel: paragraph with a mention | container prose, fallback (inline atom) |
    /// | 0.13 | quote: code with a tab | nested code, fallback (not printable ASCII) |
    /// | 0.14 | quote: list whose item holds a panel and an expand | nothing (rule B) |
    /// | 0.15 | panel: heading, paragraph | nothing (`panelKeepsRenderer`: a heading) |
    ///
    /// With the production list (step 3: prose, panels, quotes, extension
    /// bodies; step 8: media; step 5: expands; step 4: layout columns; step
    /// 6: lists; step 7: code) only 0.2.0, the list leader in 0.2, 0.3.0,
    /// 0.3.1, 0.4.0.0, 0.4.1.0, 0.4.1.1.0, 0.7.0 and 0.12.0 are container
    /// leaves (0.14's list fails rule B), 0.9's caption is the one caption
    /// leaf, 0.2.1 and 0.13.0 are nested code (0.13.0 a fallback by content
    /// from iOS 26; both `osGatedContainer` before it), and the expand 0.5
    /// is reported unprepared: an expand's body is prepared when it opens,
    /// so listing expands adds no leaf. The panel 0.6 holds a nested
    /// expand, whose body the panel's shape rule cannot see, so its body
    /// stays on SwiftUI and the walk never reaches 0.6.0.
    static func content() -> [[String: Any]] {
        let paragraph = TK2CodeLogic.paragraph
        return [
            paragraph("Root prose."),
            TK2CodeLogic.code("let root = 1"),
            TK2CodeLogic.node("blockquote", [
                paragraph("In a panel."),
                TK2CodeLogic.code("let inPanel = 2"),
                TK2CodeLogic.node("bulletList", [item([paragraph("Panel item")])]),
            ]),
            TK2CodeLogic.node("blockquote", [
                TK2CodeLogic.node("paragraph", [TK2CodeLogic.text("See "), link("the link")]),
                TK2CodeLogic.node("heading", attrs: ["level": 3], [TK2CodeLogic.text("A quoted heading")]),
            ]),
            TK2CodeLogic.node("layoutSection", [
                column(30, [paragraph("Left column.")]),
                column(70, [paragraph("Right column."), panel("note", [paragraph("Deep in a column.")])]),
            ]),
            TK2CodeLogic.node("expand", attrs: ["title": "Closed"], [paragraph("Not prepared.")]),
            panel("tip", [TK2CodeLogic.node("nestedExpand", attrs: ["title": "Nested"], [paragraph("Not prepared either.")])]),
            TK2CodeLogic.node("bodiedExtension", attrs: ["extensionKey": "excerpt", "extensionType": "com.example"], [
                paragraph("Extension body."),
            ]),
            ["type": "extension", "attrs": ["extensionKey": "toc", "extensionType": "com.example"]],
            TK2CodeLogic.node("mediaSingle", attrs: ["layout": "center"], [
                ["type": "media", "attrs": ["type": "external", "url": "placeholder://media", "width": 100, "height": 50]],
                TK2CodeLogic.node("caption", [TK2CodeLogic.text("A caption.")]),
            ]),
            TK2CodeLogic.node("table", [
                TK2CodeLogic.node("tableRow", [TK2CodeLogic.node("tableCell", [paragraph("In a cell.")])]),
            ]),
            TK2CodeLogic.node("bulletList", [item([paragraph("Top item"), paragraph("Trailing paragraph.")])]),
            panel("error", [
                TK2CodeLogic.node("paragraph", [
                    TK2CodeLogic.text("Ask "),
                    ["type": "mention", "attrs": ["id": "u1", "text": "@someone"]],
                ]),
            ]),
            TK2CodeLogic.node("blockquote", [TK2CodeLogic.code("a\tb")]),
            TK2CodeLogic.node("blockquote", [
                TK2CodeLogic.node("bulletList", [item([
                    paragraph("Mixed item"),
                    panel("info", [paragraph("A panel in an item.")]),
                    TK2CodeLogic.node("nestedExpand", attrs: ["title": "E"], [paragraph("An expand in an item.")]),
                ])]),
            ]),
            panel("note", [
                TK2CodeLogic.node("heading", attrs: ["level": 2], [TK2CodeLogic.text("A panel heading")]),
                paragraph("Beside a heading."),
            ]),
        ]
    }

    static func blocks() async throws -> [RenderBlock] {
        try await TK2CodeLogic.prepared(try TK2CodeLogic.document(content()))
    }

    /// Every kind: the widest allow list a test host can set.
    static let every = Set(TextKit2BlockKind.allCases)

    /// The fixtures the named tests sweep besides the synthetic document:
    /// those with containers, captions or nested code.
    static let containerFixtures = [
        "containers-parity", "containers-dense", "containers-expand", "captions-parity", "media-gallery",
        "kitchen-sink", "lists-parity", "code-parity",
    ]

    /// Every fixture in `Fixtures/`.
    static func allFixtures() throws -> [String] {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        let names = try FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("Fixtures").path)
        return names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(".json".count)) }.sorted()
    }

    /// The coverage with every field added for containers and captions set
    /// to zero: the fields PR 1–3 defined.
    static func legacy(_ coverage: ADFTextKit2Coverage) -> ADFTextKit2Coverage {
        ADFTextKit2Coverage(
            eligibleRoots: coverage.eligibleRoots, fallbackRoots: coverage.fallbackRoots,
            textFallbackRoots: coverage.textFallbackRoots, linkRoots: coverage.linkRoots,
            eligibleTextLeaves: coverage.eligibleTextLeaves, linkedTextLeaves: coverage.linkedTextLeaves,
            fallbackTextLeaves: coverage.fallbackTextLeaves, listLeaderLeaves: coverage.listLeaderLeaves,
            listTrailingLeaves: coverage.listTrailingLeaves, eligibleCodeRoots: coverage.eligibleCodeRoots,
            fallbackCodeRoots: coverage.fallbackCodeRoots
        )
    }

    /// Captioned media the production list (steps 3 and 4 and captions)
    /// reaches, written out independently of the walk: at the top level,
    /// and in quotes, bodied extensions, panels whose body the probes kept
    /// (`TextKit2ContainerScopeTests.expectedPanelKeeps`) and layout
    /// columns (counted stacked, as the walk counts them; step 4: CAP-13 in
    /// captions-parity is the one such caption in the fixtures), nested in
    /// one another; never in a list, table or expand.
    static func captionsInScope(_ blocks: [RenderBlock]) -> Int {
        var count = 0
        for block in blocks {
            switch block.kind {
            case .media(let media): if !(media.caption?.isEmpty ?? true) { count += 1 }
            case .quote(let children): count += captionsInScope(children)
            case .extensionPlaceholder(_, let body): count += captionsInScope(body)
            case .panel(_, let children):
                if TextKit2ContainerScopeTests.expectedPanelKeeps(children) { count += captionsInScope(children) }
            case .layoutColumns(let columns): count += captionsInScope(columns.flatMap(\.blocks))
            default: continue
            }
        }
        return count
    }

    /// Leaves the walk visits, by position.
    static func visits(_ blocks: [RenderBlock], allowed: Set<TextKit2BlockKind>) -> [TextKit2Scope.Position: Int] {
        var visits: [TextKit2Scope.Position: Int] = [:]
        TextKit2Scope.forEachLeaf(in: blocks, allowed: allowed) { visits[$0.position, default: 0] += 1 }
        return visits
    }

    /// Top-level code blocks.
    static func topLevelCode(_ blocks: [RenderBlock]) -> Int {
        blocks.filter { if case .codeBlock = $0.kind { return true }; return false }.count
    }
}

/// The coverage walk below containers (plan §6.2–§6.3): container text,
/// nested code and captions count only in their own fields; the legacy
/// fields keep their depth-0 meaning; the sums hold at every allow-list
/// stage; unprepared expands are counted, not entered; the walk visits
/// owners in search's order. With the production list (steps 3 to 7 and
/// captions) only the container leaf fields move, where a panel, quote,
/// extension body or layout column holds prose or (not in a panel) a list,
/// the nested code fields, where one holds code, the caption fields, where
/// captioned media is in scope, and `unpreparedExpands`, where the walk
/// reaches an expand.
@Suite("TextKit 2 container coverage")
@MainActor
struct TextKit2ContainerCoverageTests {
    static var stages: [(name: String, kinds: Set<TextKit2BlockKind>)] { TextKit2ContainerScopeTests.stages }

    @Test("the hand-counted document: container prose, nested lists, nested code and unprepared expands count in their own fields only")
    func handCounted() async throws {
        let blocks = try await TK2ContainerCoverage.blocks()
        let lists = TextKit2Eligibility.listsMatchText
        // Before iOS 26 every container leaf and every nested code block
        // falls back (`containerTextMatchesText`, `containerCodeVerdict`).
        let containers = TextKit2Eligibility.containerTextMatchesText
        // Each top-level node prepares to one block.
        #expect(blocks.count == 16)
        let all = ADFTextRenderer.textKit2Coverage(of: blocks, allowed: TK2ContainerCoverage.every)
        let expected = ADFTextKit2Coverage(
            eligibleRoots: 1, fallbackRoots: blocks.count - 1, textFallbackRoots: 0, linkRoots: 0,
            eligibleTextLeaves: lists ? 3 : 1, linkedTextLeaves: 0, fallbackTextLeaves: lists ? 0 : 2,
            listLeaderLeaves: 1, listTrailingLeaves: 1, eligibleCodeRoots: 1, fallbackCodeRoots: 0,
            eligibleContainerLeaves: containers ? 8 : 0, linkedContainerLeaves: containers ? 1 : 0, fallbackContainerLeaves: containers ? 1 : 9,
            containerListLeaves: 1, eligibleCaptionLeaves: containers ? 1 : 0, fallbackCaptionLeaves: containers ? 0 : 1,
            eligibleNestedCode: containers ? 1 : 0, fallbackNestedCode: containers ? 1 : 2, unpreparedExpands: 1
        )
        #expect(all == expected)

        // The empty list: the legacy fields only.
        let legacy = TK2ContainerCoverage.legacy(expected)
        #expect(ADFTextRenderer.textKit2Coverage(of: blocks, allowed: []) == legacy)
        // The production list (steps 3 to 7 and captions): prose in the
        // quotes 0.2 and 0.3, the section 0.4 (both columns and the panel
        // in one, counted stacked), the extension 0.7 and the panel 0.12
        // (an atom: a fallback), and the list leader in the quote 0.2 (step
        // 6; before iOS 26 an `osGatedList` fallback); the panel 0.15 holds
        // a heading, so its body stays on SwiftUI, and the list in the
        // quote 0.14 fails rule B. The caption of the top-level media 0.9
        // (from iOS 26; `osGatedContainer` before). The top-level expand
        // 0.5 is reported, not entered; the panel 0.6 holds a nested
        // expand, so its body stays on SwiftUI (`panelKeepsRenderer`) and
        // the walk never reaches it. Step 7: the code in the quotes 0.2 (eligible) and 0.13
        // (a tab: a fallback), both gated before iOS 26.
        var production = legacy
        production.eligibleContainerLeaves = containers ? 8 : 0
        production.linkedContainerLeaves = containers ? 1 : 0
        production.fallbackContainerLeaves = containers ? 1 : 9
        production.containerListLeaves = 1
        production.eligibleCaptionLeaves = containers ? 1 : 0
        production.fallbackCaptionLeaves = containers ? 0 : 1
        production.unpreparedExpands = 1
        production.eligibleNestedCode = containers ? 1 : 0
        production.fallbackNestedCode = containers ? 1 : 2
        #expect(ADFTextRenderer.textKit2Coverage(of: blocks) == production)
        var visitedProduction: [String] = []
        TextKit2Scope.forEachLeaf(in: blocks) { if $0.position.context == .container { visitedProduction.append($0.ownerID) } }
        let quotedListRow: String? = {
            guard case .quote(let children) = blocks[2].kind, case .listRows(let rows) = children[2].kind else { return nil }
            return rows.first?.id
        }()
        #expect(visitedProduction == ["0.2.0", "0.2.1", try #require(quotedListRow), "0.3.0", "0.3.1", "0.4.0.0", "0.4.1.0", "0.4.1.1.0", "0.7.0", "0.12.0", "0.13.0"])

        // The order and position of every leaf the widest walk visits.
        var visited: [(String, TextKit2Scope.Position)] = []
        TextKit2Scope.forEachLeaf(in: blocks, allowed: TK2ContainerCoverage.every) { visited.append(($0.ownerID, $0.position)) }
        let rowIDs = blocks.compactMap { block -> String? in
            guard case .listRows(let rows) = block.kind else { return nil }
            return rows.first?.id
        }
        let panelRow: String? = {
            guard case .quote(let children) = blocks[2].kind, case .listRows(let rows) = children[2].kind else { return nil }
            return rows.first?.id
        }()
        let listRow = try #require(rowIDs.first)
        guard case .media(let media) = blocks[9].kind else {
            Issue.record("0.9 is not media")
            return
        }
        let expectedVisits: [(String, TextKit2Scope.Position)] = [
            ("0.0", .root), ("0.1", .codeRoot),
            ("0.2.0", .containerProse), ("0.2.1", .containerCode), (try #require(panelRow), .containerListLeader),
            ("0.3.0", .containerProse), ("0.3.1", .containerProse),
            ("0.4.0.0", .containerProse), ("0.4.1.0", .containerProse), ("0.4.1.1.0", .containerProse),
            ("0.7.0", .containerProse),
            (media.id, .caption),
            (listRow, .listLeader), ("0.11.0.1", .listTrailing),
            ("0.12.0", .containerProse), ("0.13.0", .containerCode),
        ]
        #expect(visited.map(\.0) == expectedVisits.map(\.0))
        #expect(visited.map(\.1) == expectedVisits.map(\.1))
    }

    @Test("legacy fields keep their depth-0 meaning: widening the allow list moves no PR 1–3 field, on the hand-counted document and the container fixtures")
    func legacyFieldsKeepDepthZeroMeaning() async throws {
        var documents = [("hand-counted", try await TK2ContainerCoverage.blocks())]
        for name in TK2ContainerCoverage.containerFixtures {
            documents.append((name, try await TextKit2ListCoverageTests.blocks(name)))
        }
        for (name, blocks) in documents {
            let production = TK2ContainerCoverage.legacy(ADFTextRenderer.textKit2Coverage(of: blocks))
            let empty = ADFTextRenderer.textKit2Coverage(of: blocks, allowed: [])
            #expect(empty == TK2ContainerCoverage.legacy(empty), "\(name): a new field is nonzero with the empty list")
            #expect(production == empty, "\(name): the production list moved a legacy field")
            for (stage, allowed) in Self.stages {
                let coverage = ADFTextRenderer.textKit2Coverage(of: blocks, allowed: allowed)
                #expect(TK2ContainerCoverage.legacy(coverage) == TK2ContainerCoverage.legacy(production), "\(name) at \(stage)")
                // Depth 0: the roots are the top-level blocks.
                #expect(coverage.eligibleRoots + coverage.fallbackRoots == blocks.count, "\(name) at \(stage)")
            }
        }
    }

    @Test("sum invariants: container leaves, captions and nested code each sum to the leaves the walk visits at their positions, at every stage")
    func containerSumInvariant() async throws {
        var documents = [("hand-counted", try await TK2ContainerCoverage.blocks())]
        for name in TK2ContainerCoverage.containerFixtures {
            documents.append((name, try await TextKit2ListCoverageTests.blocks(name)))
        }
        var widest: [String: ADFTextKit2Coverage] = [:]
        for (name, blocks) in documents {
            for (stage, allowed) in Self.stages {
                let coverage = ADFTextRenderer.textKit2Coverage(of: blocks, allowed: allowed)
                let visits = TK2ContainerCoverage.visits(blocks, allowed: allowed)
                let prose = visits[.containerProse, default: 0]
                let listText = visits[.containerListLeader, default: 0] + visits[.containerListTrailing, default: 0]
                let label = "\(name) at \(stage)"
                #expect(coverage.eligibleContainerLeaves + coverage.fallbackContainerLeaves == prose + listText, "\(label)")
                #expect(coverage.linkedContainerLeaves <= coverage.eligibleContainerLeaves, "\(label)")
                #expect(coverage.containerListLeaves == listText, "\(label)")
                #expect(coverage.eligibleCaptionLeaves + coverage.fallbackCaptionLeaves == visits[.caption, default: 0], "\(label)")
                #expect(coverage.eligibleNestedCode + coverage.fallbackNestedCode == visits[.containerCode, default: 0], "\(label)")
                // No caption leaf where media is not allowed.
                if !allowed.contains(.media) { #expect(visits[.caption, default: 0] == 0, "\(label)") }
                if allowed.isEmpty {
                    #expect(prose + listText + visits[.containerCode, default: 0] == 0, "\(label): nothing below a container")
                }
            }
            widest[name] = ADFTextRenderer.textKit2Coverage(of: blocks, allowed: TK2ContainerCoverage.every)
        }
        // The container fixtures do hold container text, so the sums above
        // are not all zero. Before iOS 26 that text is gated
        // (`osGatedContainer`): it counts as fallback, none as eligible.
        if TextKit2Eligibility.containerTextMatchesText {
            #expect((widest["containers-parity"]?.eligibleContainerLeaves ?? 0) > 0)
        } else {
            #expect(widest["containers-parity"]?.eligibleContainerLeaves == 0, "gated before iOS 26")
            #expect((widest["containers-parity"]?.fallbackContainerLeaves ?? 0) > 0)
        }
        #expect((widest["lists-parity"]?.containerListLeaves ?? 0) > 0, "lists-parity has lists in a panel, a quote and columns")
    }

    @Test("nested code has its own fields: the root code counts are the top-level code blocks at every stage, and admission splits each set apart")
    func nestedCodeFieldsKeepRootInvariant() async throws {
        var documents = [("hand-counted", try await TK2ContainerCoverage.blocks())]
        for name in TK2ContainerCoverage.containerFixtures {
            documents.append((name, try await TextKit2ListCoverageTests.blocks(name)))
        }
        for (name, blocks) in documents {
            let roots = TK2ContainerCoverage.topLevelCode(blocks)
            let production = ADFTextRenderer.textKit2CodeAdmissionIncludingNested(
                of: blocks, dynamicTypeSize: .large, legibilityWeight: nil, displayScale: 3, layoutDirection: .leftToRight
            )
            // The public root-only admission keeps PR 3's two-element shape
            // (two-value destructuring compiles) and is the extended
            // walk's root pair.
            let (rootAdmitted, rootGated) = ADFTextRenderer.textKit2CodeAdmission(
                of: blocks, dynamicTypeSize: .large, legibilityWeight: nil, displayScale: 3, layoutDirection: .leftToRight
            )
            #expect(rootAdmitted == production.admittedCodeRoots && rootGated == production.gatedCodeRoots, "\(name)")
            // From step 7 the production list holds code: its nested code is
            // split by admission as the root code is.
            let productionCoverage = ADFTextRenderer.textKit2Coverage(of: blocks)
            #expect(production.nestedCodeAdmitted + production.nestedCodeGated == productionCoverage.eligibleNestedCode, "\(name)")
            for (stage, allowed) in Self.stages {
                let label = "\(name) at \(stage)"
                let coverage = ADFTextRenderer.textKit2Coverage(of: blocks, allowed: allowed)
                #expect(coverage.eligibleCodeRoots + coverage.fallbackCodeRoots == roots, "\(label)")
                let admission = ADFTextRenderer.textKit2CodeAdmissionIncludingNested(
                    of: blocks, allowed: allowed, dynamicTypeSize: .large, legibilityWeight: nil, displayScale: 3,
                    layoutDirection: .leftToRight
                )
                #expect(admission.admittedCodeRoots + admission.gatedCodeRoots == coverage.eligibleCodeRoots, "\(label)")
                #expect(admission.nestedCodeAdmitted + admission.nestedCodeGated == coverage.eligibleNestedCode, "\(label)")
                #expect(admission.admittedCodeRoots == production.admittedCodeRoots, "\(label): the root admission does not move")
                #expect(admission.gatedCodeRoots == production.gatedCodeRoots, "\(label)")
                if !allowed.contains(.codeBlock) {
                    #expect(coverage.eligibleNestedCode + coverage.fallbackNestedCode == 0, "\(label): code is not allowed yet")
                }
            }
        }
        // The hand-counted document: one eligible nested code block, which
        // is admitted at Large, and one falling back by content; before
        // iOS 26 both nested blocks are gated by the OS
        // (`containerCodeVerdict`), so neither is eligible.
        let blocks = try await TK2ContainerCoverage.blocks()
        let nested = TextKit2Eligibility.containerTextMatchesText ? 1 : 0
        for allowed in [TK2ContainerCoverage.every, TextKit2Scope.containerChildKinds] {
            let admission = ADFTextRenderer.textKit2CodeAdmissionIncludingNested(
                of: blocks, allowed: allowed, dynamicTypeSize: .large, legibilityWeight: nil, displayScale: 3,
                layoutDirection: .leftToRight
            )
            #if canImport(UIKit)
            let expected = [1, 0, nested, 0]
            #else
            let expected = [0, 1, 0, nested]
            #endif
            #expect([admission.admittedCodeRoots, admission.gatedCodeRoots, admission.nestedCodeAdmitted, admission.nestedCodeGated] == expected)
            // Delta review R7: where the container size rule or the
            // direction rule keeps container bodies on SwiftUI, nested
            // code is gated, never admitted; the root pair does not move
            // with the direction rule.
            let kept = DynamicTypeSize.allCases.filter { !TextKit2Scope.containerSizeKeepsRenderer($0) }
            #expect(!kept.isEmpty)
            for (size, direction) in kept.map({ ($0, LayoutDirection.leftToRight) }) + [(.large, .rightToLeft)] {
                let gated = ADFTextRenderer.textKit2CodeAdmissionIncludingNested(
                    of: blocks, allowed: allowed, dynamicTypeSize: size, legibilityWeight: nil, displayScale: 3,
                    layoutDirection: direction
                )
                #expect(gated.nestedCodeAdmitted == 0 && gated.nestedCodeGated == nested, "\(size) \(direction): \(gated)")
                #expect(gated.admittedCodeRoots + gated.gatedCodeRoots == 1, "\(size) \(direction): \(gated)")
            }
        }
    }

    @Test("expands whose bodies are not prepared are counted, never entered: top-level and nested, only where the allow list reaches them")
    func unpreparedExpandsAreCounted() async throws {
        let blocks = try await TK2ContainerCoverage.blocks()
        let cases: [(Set<TextKit2BlockKind>, Int, String)] = [
            ([], 0, "the empty list"),
            (TextKit2Scope.containerChildKinds, 1, "the production list (steps 3 to 7 and captions): the top-level expand; the panel holding the nested one keeps its body on SwiftUI"),
            ([.expand], 1, "the top-level expand only: the nested one is in a panel"),
            ([.panel], 0, "the panel holds an expand, so its body stays on SwiftUI"),
            ([.panel, .expand], 1, "both: the panel holding the nested one still keeps its body on SwiftUI"),
            (TK2ContainerCoverage.every, 1, "every kind: the expand in a list item is never reached"),
        ]
        for (allowed, expected, label) in cases {
            var reported: [String] = []
            TextKit2Scope.forEachLeaf(in: blocks, allowed: allowed, unpreparedExpand: { reported.append($0.id) }) { _ in }
            #expect(reported.count == expected, "\(label): \(reported)")
            #expect(ADFTextRenderer.textKit2Coverage(of: blocks, allowed: allowed).unpreparedExpands == expected, "\(label)")
            for id in reported {
                let block = Self.find(id, in: blocks)
                if case .expand = block?.kind {} else { Issue.record("\(id) is not an expand") }
            }
        }
        // A nested expand the walk does reach: in a quote, and in a quote
        // in a panel beside a paragraph (the panel's shape rule looks
        // through the quote and finds the expand, so that one is not).
        let nested = try await TK2CodeLogic.prepared(try TK2CodeLogic.document([
            TK2CodeLogic.node("blockquote", [
                TK2CodeLogic.paragraph("Quoted."),
                TK2CodeLogic.node("nestedExpand", attrs: ["title": "In a quote"], [TK2CodeLogic.paragraph("Not prepared.")]),
            ]),
            TK2ContainerCoverage.panel("info", [
                TK2CodeLogic.paragraph("Beside."),
                TK2CodeLogic.node("blockquote", [
                    TK2CodeLogic.node("nestedExpand", attrs: ["title": "In a panel's quote"], [TK2CodeLogic.paragraph("Not prepared.")]),
                ]),
            ]),
        ]))
        var reportedNested: [String] = []
        TextKit2Scope.forEachLeaf(in: nested, unpreparedExpand: { reportedNested.append($0.id) }) { _ in }
        #expect(reportedNested == ["0.0.1"], "\(reportedNested)")
        #expect(ADFTextRenderer.textKit2Coverage(of: nested).unpreparedExpands == 1)
        guard case .panel(_, let panelBody) = nested[1].kind else { throw TestFailure("not a panel") }
        #expect(!TextKit2Scope.panelKeepsRenderer(panelBody))
        // containers-expand: every top-level expand is reported once the
        // family is allowed (the production list from step 5): the chain
        // 0.0, CE-TALL 0.305 and CE-OPEN-1 … 5 (hand count, `expandPins`);
        // their nested expands sit in bodies the walk never enters.
        let fixture = try await TextKit2ListCoverageTests.blocks("containers-expand")
        let topLevel = fixture.filter { if case .expand = $0.kind { return true }; return false }.count
        #expect(topLevel == 7)
        #expect(ADFTextRenderer.textKit2Coverage(of: fixture).unpreparedExpands == topLevel)
        #expect(ADFTextRenderer.textKit2Coverage(of: fixture, allowed: []).unpreparedExpands == 0)
        #expect(ADFTextRenderer.textKit2Coverage(of: fixture, allowed: [.expand]).unpreparedExpands == topLevel)
        #expect(ADFTextRenderer.textKit2Coverage(of: fixture, allowed: TK2ContainerCoverage.every).unpreparedExpands >= topLevel)
    }

    /// A fixture's container leaves as hand-counted from its JSON for the
    /// step-4 scope (`<data>/cols/tools/handcount4.py`, step 3's
    /// `handcount.py` with layout sections added; both re-implement the
    /// rules over the raw ADF, not the walk): by the innermost container
    /// (panel, quote, extension body, layout column), the headings among
    /// them, the linked and the fallback (inline atom) ones, and the
    /// top-level panels whose shape keeps their body on SwiftUI.
    struct FixturePin {
        let name: String
        let panel: Int
        let quote: Int
        let extensionBody: Int
        let column: Int
        let headings: Int
        let linked: Int
        let atoms: Int
        let panelShapeExcluded: [String]
        /// List leaves (leaders and row paragraphs) by the container that
        /// holds the list (step 6): "quote", "extension" or "column".
        var lists: [String: Int] = [:]
        /// Plain captions in scope (step 8): on captioned media at the top
        /// level or in a panel, quote, extension body or stacked layout
        /// column that passes the renderer; eligible from iOS 26.
        var captions = 0
        /// Expands the walk reports unprepared with the production list
        /// (`unpreparedExpands`), hand-counted from the JSON
        /// (`<data>/expand/tools/expandcount.py`): top-level ones and those
        /// in a panel, quote or extension body the walk enters; and those
        /// in layout columns, which count once the column family is listed.
        var expands = 0
        var expandsInColumns = 0
        /// Code blocks below the containers the walk enters with the
        /// production list (step 7), hand-counted from the JSON
        /// (`<data>/code7/tools/nestedcode.py`); every one is in PR 3's
        /// admitted cohort, so eligible from iOS 26 and `osGatedContainer`
        /// before it.
        var nestedCode = 0
        // View-time reasons (`TextKit2Scope.ContainerGate`: a right-to-left
        // container, an unproven width, a side-by-side column, a nested list at
        // an accessibility size, a column under 1 pt) are not the static
        // walk's: it counts left to right, stacked, at Large
        // (`forEachLeaf`). The hosted scope tests prove each one
        // (`TextKit2ContainerScopeTests`; code review F-R19 removed a
        // constant pinned to itself here).

        var listLeaves: Int { lists.values.reduce(0, +) }
        var leaves: Int { panel + quote + extensionBody + column + listLeaves }

        /// `expands`, plus `expandsInColumns` once columns are listed.
        var unpreparedExpands: Int {
            expands + (TextKit2Scope.containerChildKinds.contains(.layoutColumns) ? expandsInColumns : 0)
        }
    }

    /// containers-parity: panels 0.1–0.8 (one paragraph each, every
    /// palette), 0.16, 0.17, 0.18, 0.21, 0.23 (an atom), 0.33 (and the quote
    /// in it), 0.83 (beside the plugin card), and the panels in 0.32 and
    /// 0.34; quotes 0.19, 0.20 (two),
    /// 0.24 (an atom), 0.27, 0.28 (a heading among three), 0.29 (three deep,
    /// four leaves), 0.32 (and the panel in it), 0.36 (quote > panel >
    /// quote); extensions 0.22 (three), 0.34 (and its panel), 0.35 (a quote
    /// in it), 0.39 (a heading among three). The panels 0.11 and 0.12
    /// (headings), 0.15 (a superscript run beside a second paragraph), 0.63
    /// (a list), and 0.71, 0.77 and 0.78 (prose beside code blocks) keep
    /// their bodies on SwiftUI; 0.10 is empty. Columns (step 4): the
    /// sections 0.46 (five, a heading among them), 0.47 (three, one
    /// linked), 0.48 (a panel and a quote, one leaf each), 0.49 (three),
    /// 0.52–0.55 (two each: the zero, negative, indented and all
    /// non-positive cases), 0.60 (two, beside the nested expand) and 0.76
    /// (the paragraph beside the column code); 0.68 holds only lists.
    /// Links: 0.16.0, 0.18.0, 0.22.1, 0.47.1.1.
    /// kitchen-sink: seven one-paragraph panels, a quote, a bodied
    /// extension and two column paragraphs (its expand is reported
    /// unprepared, below).
    /// stress-1k: 80 top-level one-paragraph panels and 80 top-level quotes
    /// of one to three paragraphs (119 leaves); its other panels and quotes
    /// sit in list items and expands (its layout sections are in expand
    /// bodies), out of scope at step 4.
    /// Lists (step 6), all leaders, all plain: containers-parity's quote
    /// 0.64 (an ordered list of two rows; a bullet list whose first row
    /// holds a panel, so rule A keeps that row on SwiftUI, and its second
    /// row; two tasks: five leaders), the quote 0.65 (Hebrew and Arabic
    /// rows in a left-to-right layout: two), the extension 0.67 (two
    /// ordered rows and a nested bullet: three) and the section 0.68 (a
    /// three-deep list in the 25 % column; two ordered rows and a decision
    /// in the 75 %: six); the panel 0.63's list stays on SwiftUI with its
    /// panel and the expand 0.66 is not prepared. kitchen-sink and
    /// stress-1k have no list in a container the scope reaches.
    /// Captions (step 8, counted from the JSON): containers-parity has
    /// none; kitchen-sink's one (0.23, plain) is top-level; stress-1k's ten
    /// (0.95, 0.195, … 0.995) are all in expands, whose bodies the walk
    /// does not enter. None of the three has a caption in a layout column
    /// (`<data>/merge/tools/captioncount.py --columns`), so step 4 moves no
    /// caption pin here. Expands (step 5): containers-parity's top-level
    /// 0.58, 0.59, 0.66, 0.74 and 0.82, and the nested expand in column
    /// 0.60.0 once columns join; kitchen-sink's 0.22; stress-1k's 100
    /// top-level expands (blocks 45–49 of every 50).
    static let pins: [FixturePin] = [
        FixturePin(name: "containers-parity", panel: 18, quote: 17, extensionBody: 7, column: 22, headings: 3, linked: 4, atoms: 2,
                   panelShapeExcluded: ["0.11", "0.12", "0.15", "0.63", "0.71", "0.77", "0.78"],
                   lists: ["quote": 7, "extension": 3, "column": 6], expands: 5, expandsInColumns: 1, nestedCode: 6),
        FixturePin(name: "kitchen-sink", panel: 7, quote: 1, extensionBody: 1, column: 2, headings: 0, linked: 0, atoms: 0, panelShapeExcluded: [],
                   captions: 1, expands: 1),
        FixturePin(name: "stress-1k", panel: 80, quote: 119, extensionBody: 0, column: 0, headings: 0, linked: 43, atoms: 0, panelShapeExcluded: [],
                   expands: 100),
    ]

    /// The innermost container kind above each container leaf the walk
    /// visits (owner id → "panel", "quote", "extension" or "column"); for
    /// list text, the container holding the list.
    static func innermostContainers(_ blocks: [RenderBlock]) -> [String: String] {
        var found: [String: String] = [:]
        func walk(_ blocks: [RenderBlock], in container: String?) {
            for block in blocks {
                switch block.kind {
                case .richText: if let container { found[block.id] = container }
                case .listRows(let rows):
                    guard let container else { continue }
                    for row in rows {
                        found[row.id] = container
                        for trailing in row.trailingBlocks { found[trailing.id] = container }
                    }
                case .panel(_, let children): walk(children, in: "panel")
                case .quote(let children): walk(children, in: "quote")
                case .extensionPlaceholder(_, let body): walk(body, in: "extension")
                case .layoutColumns(let columns): walk(columns.flatMap(\.blocks), in: "column")
                default: continue
                }
            }
        }
        walk(blocks, in: nil)
        return found
    }

    @Test("fixturePins: hand-counted container leaves of containers-parity, kitchen-sink and stress-1k at step 7, by container, list text apart, with the excluded panel shapes, their captions, the unprepared expands and the nested code; before iOS 26 every leaf and nested code block is gated")
    func fixturePins() async throws {
        let containers = TextKit2Eligibility.containerTextMatchesText
        for pin in Self.pins {
            let blocks = try await TextKit2ListCoverageTests.blocks(pin.name)
            let coverage = ADFTextRenderer.textKit2Coverage(of: blocks)
            let eligible = pin.leaves - pin.atoms
            #expect(coverage.eligibleContainerLeaves == (containers ? eligible : 0), "\(pin.name): \(coverage)")
            #expect(coverage.linkedContainerLeaves == (containers ? pin.linked : 0), "\(pin.name): \(coverage)")
            #expect(coverage.fallbackContainerLeaves == (containers ? pin.atoms : pin.leaves), "\(pin.name): \(coverage)")
            #expect(coverage.containerListLeaves == pin.listLeaves, "\(pin.name)")
            #expect(coverage.eligibleNestedCode == (containers ? pin.nestedCode : 0), "\(pin.name): \(coverage)")
            #expect(coverage.fallbackNestedCode == (containers ? 0 : pin.nestedCode), "\(pin.name): \(coverage)")
            #expect(coverage.unpreparedExpands == pin.unpreparedExpands, "\(pin.name): \(coverage.unpreparedExpands) unprepared expands")
            #expect(coverage.eligibleCaptionLeaves == (containers ? pin.captions : 0), "\(pin.name): \(coverage)")
            #expect(coverage.fallbackCaptionLeaves == (containers ? 0 : pin.captions), "\(pin.name): \(coverage)")

            // The leaves by their innermost container, and the reasons.
            let kinds = Self.innermostContainers(blocks)
            var byKind: [String: Int] = [:]
            var listsByKind: [String: Int] = [:]
            var listReasons: [TextKit2Eligibility.Fallback: Int] = [:]
            var headings = 0
            var reasons: [TextKit2Eligibility.Fallback: Int] = [:]
            TextKit2Scope.forEachLeaf(in: blocks) { leaf in
                if leaf.position == .containerListLeader || leaf.position == .containerListTrailing {
                    listsByKind[kinds[leaf.ownerID] ?? "?", default: 0] += 1
                    if case .fallback(let reason) = leaf.verdict { listReasons[reason, default: 0] += 1 }
                }
                guard leaf.position == .containerProse else { return }
                byKind[kinds[leaf.ownerID] ?? "?", default: 0] += 1
                if leaf.style?.isHeading == true { headings += 1 }
                if case .fallback(let reason) = leaf.verdict { reasons[reason, default: 0] += 1 }
            }
            #expect(byKind == ["panel": pin.panel, "quote": pin.quote, "extension": pin.extensionBody, "column": pin.column].filter { $0.value > 0 }, "\(pin.name): \(byKind)")
            #expect(headings == pin.headings, "\(pin.name)")
            var expectedReasons: [TextKit2Eligibility.Fallback: Int] = [:]
            if pin.atoms > 0 { expectedReasons[.atom] = pin.atoms }
            if !containers { expectedReasons[.osGatedContainer] = eligible - pin.listLeaves }
            #expect(reasons == expectedReasons, "\(pin.name): \(reasons)")
            // List text: by the container holding the list; before iOS 26
            // the list gate decides it first.
            #expect(listsByKind == pin.lists, "\(pin.name): \(listsByKind)")
            #expect(listReasons == (containers || pin.listLeaves == 0 ? [:] : [.osGatedList: pin.listLeaves]), "\(pin.name): \(listReasons)")

            // The panels whose shape keeps their body on SwiftUI.
            let excluded = blocks.filter { block in
                if case .panel(_, let children) = block.kind { return !TextKit2Scope.panelKeepsRenderer(children) }
                return false
            }.map(\.id)
            #expect(excluded == pin.panelShapeExcluded, "\(pin.name)")
        }
    }

    nonisolated static func find(_ id: String, in blocks: [RenderBlock]) -> RenderBlock? {
        for block in blocks {
            if block.id == id { return block }
            let children: [RenderBlock]
            switch block.kind {
            case .panel(_, let blocks), .quote(let blocks), .extensionPlaceholder(_, let blocks): children = blocks
            case .layoutColumns(let columns): children = columns.flatMap(\.blocks)
            case .listRows(let rows): children = rows.flatMap(\.trailingBlocks)
            default: children = []
            }
            if let found = find(id, in: children) { return found }
        }
        return nil
    }

    /// Whether a leaf has text search would index (search skips units whose
    /// text is only whitespace).
    static func indexable(_ leaf: TextKit2Scope.Leaf) -> Bool {
        if let code = leaf.code {
            return !String(code.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return leaf.segments.contains { segment in
            switch segment {
            case .text(let text): return !String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .atom(let atom, _): return !InlineComposer.fallbackText(atom).isEmpty
            }
        }
    }

    @Test("the walk visits owners in search's order: an order-preserving subsequence of the indexed units outside expand bodies, code included, on every fixture")
    func coverageWalkerMatchesSearchIndexerOwnerOrder() async throws {
        let indexer = SearchIndexer(theme: .default)
        var documents = [("hand-counted", try await TK2ContainerCoverage.blocks())]
        for name in try TK2ContainerCoverage.allFixtures() {
            documents.append((name, try await TextKit2ListCoverageTests.blocks(name)))
        }
        for (name, blocks) in documents {
            let units = indexer.units(for: blocks).filter(\.expandAncestorIDs.isEmpty).map(\.ownerID)
            for (stage, allowed) in [("production", TextKit2Scope.containerChildKinds), ("every kind", TK2ContainerCoverage.every)] {
                var owners: [String] = []
                var codeOwners = 0
                TextKit2Scope.forEachLeaf(in: blocks, allowed: allowed) { leaf in
                    guard Self.indexable(leaf) else { return }
                    owners.append(leaf.ownerID)
                    if leaf.code != nil { codeOwners += 1 }
                }
                var next = units.startIndex
                var missing: String?
                for owner in owners {
                    guard let found = units[next...].firstIndex(of: owner) else {
                        missing = owner
                        break
                    }
                    next = found + 1
                }
                #expect(missing == nil, "\(name) (\(stage)): \(missing ?? "") is not in search's order after its predecessors")
                if name == "code-parity" { #expect(codeOwners > 0, "code owners are in the sequence") }
            }
        }
    }

    /// Expands the walk reports unprepared with the production list, on
    /// every fixture, hand-counted from the JSON (`expandcount.py`, which
    /// re-implements the scope over the raw ADF, not the walk): (expands
    /// reached without layout columns, those inside layout columns, which
    /// count once the column family is listed).
    static let expandPins: [String: (expands: Int, inColumns: Int)] = [
        "captions-parity": (1, 0), "code-dense": (0, 0), "code-parity": (1, 0), "code-tall": (0, 0),
        "containers-dense": (40, 0), "containers-expand": (7, 0), "containers-parity": (5, 1), "emoji-custom": (0, 0),
        "giant-table": (0, 0),
        "kitchen-sink": (1, 0), "list-dense": (0, 0), "list-tall": (0, 0), "lists-links": (0, 0), "lists-parity": (1, 0),
        "long-paragraph": (0, 0), "media-gallery": (0, 0), "smart-links": (6, 0), "stress-1k": (100, 0),
        "stress-5k": (500, 0), "text-dense": (0, 0), "youtube-dense": (0, 0), "youtube": (1, 0),
    ]

    /// Container list leaves per fixture with the production list, hand
    /// counted from the JSON (leaders and row paragraphs of the lists in
    /// quotes, extension bodies and columns that rules A and B keep):
    /// containers-parity 16 (`fixturePins`), containers-dense 206 (76 in
    /// quotes, 55 in extension bodies, 75 in columns), lists-parity 5 (its
    /// quote 0.15 and section 0.18); none elsewhere. Lists inside expand
    /// bodies (containers-expand 11, containers-parity 3, lists-parity 3,
    /// stress-1k 110, stress-5k 550 list nodes) are not counted: the walk
    /// never enters an unprepared body.
    static let containerListLeaves = ["containers-parity": 16, "containers-dense": 206, "lists-parity": 5]

    /// Nested code the walk counts with the production list, on every
    /// fixture, hand-counted from the JSON (`<data>/code7/tools/nestedcode.py`,
    /// which re-implements the scope over the raw ADF, not the walk):
    /// containers-parity 0.52.0.1 (the zero-percent column, stacked), 0.72.0
    /// (a quote), 0.73.0.0 (a quote in a panel), 0.75.0 (an extension body),
    /// 0.76.0.0 and 0.76.1.1 (a 50/50 section); its other code sits in panels
    /// whose body the shape rule keeps on SwiftUI (0.71, 0.77, 0.78), an
    /// expand (0.74), a table and a list item. containers-dense: the four in
    /// quotes (0.5.1, 0.215.2, 0.425.2, 0.635.5); its other eight sit beside
    /// prose in panels. Every one is in PR 3's admitted cohort, under the
    /// canvas bound at Large on 3x. Every other fixture: none (lists, which
    /// joined at step 6, hold no code a row keeps: code in a list item
    /// stays SwiftUI).
    static let nestedCodePins: [String: Int] = ["containers-parity": 6, "containers-dense": 4]

    @Test("with the production list (steps 3 to 7 and captions) only the container leaf fields, as the step-6 stage counts them, container list text where the hand count has it, the nested code and the unprepared expands, as hand-counted, and the caption fields, for the captioned media in scope, move; listing expands adds no leaf and listing code moves only the nested code fields; the legacy fields are the empty list's")
    func newFieldsReadZeroOnEveryFixture() async throws {
        let step6 = try #require(Self.stages.first { $0.name.hasPrefix("step 6") }).kinds
        let step7 = try #require(Self.stages.first { $0.name.hasPrefix("step 7") }).kinds
        // The step-7 stage holds steps 3 to 7 (expands included); captions
        // (step 8) joined before columns, expands, lists and code in this
        // PR.
        let production = step7.union([.media])
        #expect(production == TextKit2Scope.containerChildKinds)
        let containers = TextKit2Eligibility.containerTextMatchesText
        let columns = TextKit2Scope.containerChildKinds.contains(.layoutColumns)
        let fixtures = try TK2ContainerCoverage.allFixtures()
        #expect(Set(fixtures) == Set(Self.expandPins.keys), "every fixture has an expand pin")
        for name in fixtures {
            let blocks = try await TextKit2ListCoverageTests.blocks(name)
            // The default list is `production` (pinned above), so the
            // default coverage is the production list's.
            let coverage = ADFTextRenderer.textKit2Coverage(of: blocks)
            let pin = try #require(Self.expandPins[name], "\(name): no expand pin")
            #expect(coverage.unpreparedExpands == pin.expands + (columns ? pin.inColumns : 0), "\(name): \(coverage.unpreparedExpands) unprepared expands")
            // Listing expands moves nothing but `unpreparedExpands`: their
            // bodies are prepared on opening, never by the walk (nor the
            // lists and code in them).
            var withoutExpands = ADFTextRenderer.textKit2Coverage(of: blocks, allowed: production.subtracting([.expand]))
            #expect(withoutExpands.unpreparedExpands == 0, "\(name)")
            withoutExpands.unpreparedExpands = coverage.unpreparedExpands
            #expect(coverage == withoutExpands, "\(name)")
            // Listing code moves nothing but the nested code fields.
            var withoutCode = ADFTextRenderer.textKit2Coverage(of: blocks, allowed: production.subtracting([.codeBlock]))
            #expect(withoutCode.eligibleNestedCode + withoutCode.fallbackNestedCode == 0, "\(name)")
            withoutCode.eligibleNestedCode = coverage.eligibleNestedCode
            withoutCode.fallbackNestedCode = coverage.fallbackNestedCode
            #expect(coverage == withoutCode, "\(name)")
            let nested = Self.nestedCodePins[name] ?? 0
            #expect(coverage.eligibleNestedCode == (containers ? nested : 0), "\(name): \(coverage)")
            #expect(coverage.fallbackNestedCode == (containers ? 0 : nested), "\(name): \(coverage)")
            // Media adds captions only: the container leaf fields are the
            // step-6 stage's.
            let atStep6 = ADFTextRenderer.textKit2Coverage(of: blocks, allowed: step6)
            #expect(coverage.eligibleContainerLeaves == atStep6.eligibleContainerLeaves
                && coverage.linkedContainerLeaves == atStep6.linkedContainerLeaves
                && coverage.fallbackContainerLeaves == atStep6.fallbackContainerLeaves
                && coverage.containerListLeaves == atStep6.containerListLeaves, "\(name): \(coverage)")
            #expect(TK2ContainerCoverage.legacy(coverage) == ADFTextRenderer.textKit2Coverage(of: blocks, allowed: []), "\(name)")
            #expect(coverage.containerListLeaves == Self.containerListLeaves[name, default: 0], "\(name): \(coverage)")
            #expect(coverage.eligibleCaptionLeaves + coverage.fallbackCaptionLeaves == TK2ContainerCoverage.captionsInScope(blocks), "\(name): \(coverage)")
            if !TextKit2Eligibility.containerTextMatchesText {
                #expect(coverage.eligibleContainerLeaves == 0 && coverage.linkedContainerLeaves == 0, "\(name): container text is gated before iOS 26")
                #expect(coverage.eligibleCaptionLeaves == 0, "\(name): captions are gated before iOS 26")
            }
            #expect(coverage.eligibleCodeRoots + coverage.fallbackCodeRoots == TK2ContainerCoverage.topLevelCode(blocks), "\(name)")
            let admission = ADFTextRenderer.textKit2CodeAdmissionIncludingNested(
                of: blocks, dynamicTypeSize: .large, legibilityWeight: nil, displayScale: 3, layoutDirection: .leftToRight
            )
            // Every nested block is under the canvas bound at Large on 3x,
            // left to right: all admitted.
            #if canImport(UIKit)
            #expect(admission.nestedCodeAdmitted == coverage.eligibleNestedCode && admission.nestedCodeGated == 0, "\(name)")
            #else
            #expect(admission.nestedCodeAdmitted == 0 && admission.nestedCodeGated == coverage.eligibleNestedCode, "\(name)")
            #endif
        }
    }
}

#if canImport(UIKit)
import UIKit

/// The live side: rows report their context at both draw sites, the
/// off-window count follows the row's window, and the container and
/// caption per-owner records list exactly their live owners.
///
/// The counters are process-wide: a counter is only compared across a span
/// with no suspension in it, and a per-owner record is only read for owner
/// ids no other suite uses (`tk2-container-coverage.…`).
@Suite("TextKit 2 container diagnostics", .serialized)
@MainActor
struct TextKit2ContainerDiagnosticsTests {
    static func text(_ string: String, link: Bool = false) -> AttributedString {
        var text = AttributedString(string)
        text.font = .body
        text.adfFontSpec = ADFFontSpec(textStyle: .body)
        if link { text.link = URL(string: "https://example.com") }
        return text
    }

    /// A row as the representable makes one: kind and context first, then
    /// inputs and owner; measured, placed and drawn once.
    static func row(
        _ kind: TextKit2OwnerKind, _ context: TextKit2ContainerContext, ownerID: String, link: Bool = false
    ) -> TextKit2RowView {
        let row = TextKit2RowView()
        row.ownerKind = kind
        row.containerContext = context
        if kind == .code {
            row.apply(TextKit2CodeDiagnosticsTests.inputs("let x = 1"), ownerID: ownerID)
            TextKit2CodeDiagnosticsTests.place(row, at: row.measuredSize(forProposedWidth: nil))
        } else {
            row.apply(TextKit2RenderInputs(text: text("Container text \(ownerID)", link: link)), ownerID: ownerID)
            TextKit2CodeDiagnosticsTests.place(row, at: row.measuredSize(forProposedWidth: 300))
        }
        return row
    }

    @Test("context counters count at both draw sites: container native and TextKit 1-backed draws, caption draws, never a code row's")
    func contextCountersCountAtBothDrawSites() {
        let diagnostics = TextKit2Diagnostics.shared
        let prefix = "tk2-container-coverage.draws."
        // No suspension in this test: the counters move only by these rows.
        let before = diagnostics.snapshot
        autoreleasepool {
            let prose = Self.row(.root, .container, ownerID: prefix + "prose")
            let linked = Self.row(.root, .container, ownerID: prefix + "linked", link: true)
            let list = Self.row(.list, .container, ownerID: prefix + "list")
            let code = Self.row(.code, .container, ownerID: prefix + "code")
            let caption = Self.row(.root, .caption, ownerID: prefix + "caption")
            let root = Self.row(.root, .none, ownerID: prefix + "root")
            #expect(linked.isTextKit1Backed && !prose.isTextKit1Backed)

            var now = diagnostics.snapshot
            #expect(now.liveContainerRowCount - before.liveContainerRowCount == 3, "prose, linked and list text; not code")
            #expect(now.liveCaptionRowCount - before.liveCaptionRowCount == 1)
            #expect(now.liveCodeRowCount - before.liveCodeRowCount == 1)
            #expect(now.liveListRowCount - before.liveListRowCount == 1)
            #expect(now.containerNativeDrawCount == before.containerNativeDrawCount, "measuring and placing draw nothing")

            for row in [prose, linked, list, code, caption, root] { TextKit2CodeDiagnosticsTests.draw(row) }
            now = diagnostics.snapshot
            #expect(now.drawCount - before.drawCount == 6)
            #expect(now.nativeDrawCount - before.nativeDrawCount == 5, "all but the linked row")
            #expect(now.textKit1BackedDrawCount - before.textKit1BackedDrawCount == 1)
            #expect(now.containerNativeDrawCount - before.containerNativeDrawCount == 2, "the prose and list rows")
            #expect(now.containerTextKit1DrawCount - before.containerTextKit1DrawCount == 1, "the linked row, at the TextKit 1 site")
            #expect(now.captionNativeDrawCount - before.captionNativeDrawCount == 1)
            #expect(now.codeNativeDrawCount - before.codeNativeDrawCount == 1, "the code row is code, not container proof")

            // A row's context changes: it moves between the live counts.
            prose.containerContext = .caption
            now = diagnostics.snapshot
            #expect(now.liveContainerRowCount - before.liveContainerRowCount == 2)
            #expect(now.liveCaptionRowCount - before.liveCaptionRowCount == 2)
            TextKit2CodeDiagnosticsTests.draw(prose)
            #expect(diagnostics.snapshot.captionNativeDrawCount - before.captionNativeDrawCount == 2)
            #expect(diagnostics.snapshot.containerNativeDrawCount - before.containerNativeDrawCount == 2)
            withExtendedLifetime([prose, linked, list, code, caption, root]) {}
        }
        let after = diagnostics.snapshot
        #expect(after.liveRowCount == before.liveRowCount)
        #expect(after.liveContainerRowCount == before.liveContainerRowCount)
        #expect(after.liveCaptionRowCount == before.liveCaptionRowCount)
        #expect(after.liveCodeRowCount == before.liveCodeRowCount)
        #expect(after.liveListRowCount == before.liveListRowCount)
        #expect(after.textKit1BackedRowCount == before.textKit1BackedRowCount)
        #expect(after.liveOffWindowRowCount == before.liveOffWindowRowCount)
    }

    @Test("the off-window count: a new row is outside any window; it follows the row into and out of windows, with its superview too; a release balances it")
    func offWindowRowsAreCounted() {
        let diagnostics = TextKit2Diagnostics.shared
        // No suspension in this test.
        let off = diagnostics.liveOffWindowRowCount
        let live = diagnostics.liveRowCount
        autoreleasepool {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
            window.isHidden = false
            let row = TextKit2RowView()
            #expect(diagnostics.liveOffWindowRowCount - off == 1, "a new row is outside any window")
            window.addSubview(row)
            #expect(diagnostics.liveOffWindowRowCount == off, "in a window")
            let container = UIView()
            container.addSubview(row)
            #expect(diagnostics.liveOffWindowRowCount - off == 1, "moved under a view outside any window")
            window.addSubview(container)
            #expect(diagnostics.liveOffWindowRowCount == off, "in the window with its superview")
            container.removeFromSuperview()
            #expect(diagnostics.liveOffWindowRowCount - off == 1, "out with its superview")
            window.addSubview(row)
            #expect(diagnostics.liveOffWindowRowCount == off)
            // A second row released while still in the window's hierarchy,
            // and one released having never been in a window.
            let second = TextKit2RowView()
            window.addSubview(second)
            _ = TextKit2RowView()
            #expect(diagnostics.liveOffWindowRowCount == off, "the never-placed row was released at once")
            #expect(diagnostics.liveRowCount - live == 2)
            #expect(diagnostics.liveOffWindowRowCount <= diagnostics.liveRowCount)
            row.removeFromSuperview()
            #expect(diagnostics.liveOffWindowRowCount - off == 1)
            window.isHidden = true
            withExtendedLifetime((window, row, second, container)) {}
        }
        #expect(diagnostics.liveRowCount == live)
        #expect(diagnostics.liveOffWindowRowCount == off, "every release balanced")
    }

    /// A quote whose children carry ids no other suite uses: prose and code.
    static func quote() async throws -> (quote: RenderBlock, prose: String, code: String) {
        let prepared = try await TK2CodeLogic.prepared(try TK2CodeLogic.document([
            TK2CodeLogic.paragraph("Quoted prose."), TK2CodeLogic.code("let quoted = 1"),
        ]))
        let proseID = "tk2-container-coverage.records.prose"
        let codeID = "tk2-container-coverage.records.code"
        let quote = RenderBlock(id: "tk2-container-coverage.records.quote", kind: .quote([
            RenderBlock(id: proseID, kind: prepared[0].kind), RenderBlock(id: codeID, kind: prepared[1].kind),
        ]))
        return (quote, proseID, codeID)
    }

    static func quoteView(_ quote: RenderBlock, _ renderer: ADFTextRenderer) -> some View {
        BlockView(block: quote)
            .environment(\.adfTextRenderer, renderer)
            .environment(\.adfContainerChildKinds, [.richText, .codeBlock])
            .environment(\.adfTextWidthBound, .atLeast(358))
            .frame(width: 358)
    }

    @Test("per-owner records: with the switch OFF neither lists a container owner; ON, the container record lists the container's prose (not its code) and counts its native draws; caption entries follow what rows report")
    func perOwnerDrawRecords() async throws {
        let diagnostics = TextKit2Diagnostics.shared
        let (quote, prose, code) = try await Self.quote()

        let hosted = TK2CodeLogic.Hosted(Self.quoteView(quote, .swiftUI))
        defer { hosted.close() }
        try await hosted.settle()
        #expect(hosted.rows.isEmpty, "switch OFF: no row")
        #expect(ADFTextRenderer.textKit2ContainerRowDraws[prose] == nil)
        #expect(ADFTextRenderer.textKit2CodeRowDraws[code] == nil)

        hosted.show(Self.quoteView(quote, .textKit2))
        try await hosted.settle()
        var rows = hosted.rows
        // Before iOS 26 the prose stays on SwiftUI (`osGatedContainer`),
        // and from PR 4 step 7 so does the code beside it: nested code is
        // gated by the OS first (`containerCodeVerdict`, P14).
        let containers = TextKit2Eligibility.containerTextMatchesText
        #expect(Set(rows.compactMap(\.ownerID)) == (containers ? [prose, code] : []))
        for row in rows {
            #expect(row.containerContext == .container, "\(row.ownerID ?? "?")")
            #expect(row.ownerKind == (row.ownerID == code ? .code : .root), "\(row.ownerID ?? "?")")
        }
        // No suspension from here to the last read.
        #expect(ADFTextRenderer.textKit2ContainerRowDraws == diagnostics.containerRowDraws)
        #expect(ADFTextRenderer.textKit2CaptionRowDraws == diagnostics.captionRowDraws)
        #expect(ADFTextRenderer.textKit2ContainerRowDraws[code] == nil, "code is never container proof")
        #expect((ADFTextRenderer.textKit2CodeRowDraws[code] != nil) == containers, "nested code is in the code record (from iOS 26)")
        #expect(diagnostics.containerRowDraws.count <= diagnostics.liveContainerRowCount)
        if containers {
            let listed = try #require(ADFTextRenderer.textKit2ContainerRowDraws[prose], "a live container row is listed, drawn or not")
            let native = diagnostics.containerNativeDrawCount
            for row in rows { TK2CodeLogic.draw(row) }
            #expect(ADFTextRenderer.textKit2ContainerRowDraws[prose] == listed + 1)
            #expect(diagnostics.containerNativeDrawCount - native == 1)
            // Two rows drawn, one container draw: the code row's draw is
            // never a container draw.
            #expect(rows.count == 2)
        } else {
            #expect(ADFTextRenderer.textKit2ContainerRowDraws[prose] == nil, "gated before iOS 26: no container row")
            #expect(ADFTextRenderer.textKit2CodeRowDraws[code] == nil, "gated before iOS 26: no nested code row")
        }

        hosted.show(Self.quoteView(quote, .swiftUI))
        try await hosted.settle()
        #expect(hosted.rows.isEmpty)
        rows.removeAll()
        #expect(ADFTextRenderer.textKit2ContainerRowDraws[prose] == nil, "its owner goes with its row")
        #expect(ADFTextRenderer.textKit2CodeRowDraws[code] == nil)

        // Captions: the record is driven as a row reports itself. No
        // suspension from here on.
        let caption = "tk2-container-coverage.records.caption"
        let liveCaption = diagnostics.liveCaptionRowCount
        let captionNative = diagnostics.captionNativeDrawCount
        let liveRows = diagnostics.liveRowCount
        diagnostics.rowCreated()
        diagnostics.row(context: .caption, was: .none, ownerKind: .root, ownerID: nil)
        #expect(diagnostics.liveCaptionRowCount - liveCaption == 1)
        #expect(diagnostics.captionRowDraws[caption] == nil, "no entry before an id")
        diagnostics.row(ownerID: caption, was: nil, ownerKind: .root, context: .caption)
        #expect(ADFTextRenderer.textKit2CaptionRowDraws[caption] == 0)
        #expect(diagnostics.containerRowDraws[caption] == nil, "a caption is not container proof")
        diagnostics.didDraw(native: true, context: .caption, ownerID: caption)
        diagnostics.didDraw(native: false, textKit1: true, context: .caption, ownerID: caption)
        #expect(ADFTextRenderer.textKit2CaptionRowDraws[caption] == 1, "native draws only")
        #expect(diagnostics.captionNativeDrawCount - captionNative == 1)
        diagnostics.rowDestroyed(context: .caption, ownerID: caption)
        #expect(ADFTextRenderer.textKit2CaptionRowDraws[caption] == nil)
        #expect(diagnostics.liveCaptionRowCount == liveCaption)
        #expect(diagnostics.liveRowCount == liveRows)
        #expect(diagnostics.captionRowDraws.count <= diagnostics.liveCaptionRowCount)
    }
}
#endif
