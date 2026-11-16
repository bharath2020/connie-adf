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
    /// | 0.6 | panel: nested expand | an unprepared expand |
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
    /// bodies; step 8: media) only 0.2.0, 0.3.0, 0.3.1, 0.7.0 and 0.12.0 are
    /// container leaves, and 0.9's caption is the one caption leaf: lists,
    /// code, columns and expands are not listed yet.
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

    /// Captioned media the production list (step 3 and captions) reaches,
    /// written out independently of the walk: at the top level, and in
    /// quotes, bodied extensions and panels whose body the probes kept
    /// (`TextKit2ContainerScopeTests.expectedPanelKeeps`), nested in one
    /// another; never in a list, table, expand or layout column.
    static func captionsInScope(_ blocks: [RenderBlock]) -> Int {
        var count = 0
        for block in blocks {
            switch block.kind {
            case .media(let media): if !(media.caption?.isEmpty ?? true) { count += 1 }
            case .quote(let children): count += captionsInScope(children)
            case .extensionPlaceholder(_, let body): count += captionsInScope(body)
            case .panel(_, let children):
                if TextKit2ContainerScopeTests.expectedPanelKeeps(children) { count += captionsInScope(children) }
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
/// owners in search's order. With the production list (step 3 and
/// captions) only the container leaf fields move, where a panel, quote or
/// extension body holds prose, and the caption fields, where captioned
/// media is in scope.
@Suite("TextKit 2 container coverage")
@MainActor
struct TextKit2ContainerCoverageTests {
    static var stages: [(name: String, kinds: Set<TextKit2BlockKind>)] { TextKit2ContainerScopeTests.stages }

    @Test("the hand-counted document: container prose, nested lists, nested code and unprepared expands count in their own fields only")
    func handCounted() async throws {
        let blocks = try await TK2ContainerCoverage.blocks()
        let lists = TextKit2Eligibility.listsMatchText
        // Before iOS 26 every container leaf falls back
        // (`containerTextMatchesText`); nested code keeps the code rules
        // until code joins the allow list.
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
            eligibleNestedCode: 1, fallbackNestedCode: 1, unpreparedExpands: 2
        )
        #expect(all == expected)

        // The empty list: the legacy fields only.
        let legacy = TK2ContainerCoverage.legacy(expected)
        #expect(ADFTextRenderer.textKit2Coverage(of: blocks, allowed: []) == legacy)
        // The production list (step 3 and captions): prose in the quotes
        // 0.2 and 0.3, the extension 0.7 and the panel 0.12 (an atom: a
        // fallback); the panel 0.15 holds a heading, so its body stays on
        // SwiftUI. The caption of the top-level media 0.9 (from iOS 26;
        // `osGatedContainer` before).
        var production = legacy
        production.eligibleContainerLeaves = containers ? 4 : 0
        production.linkedContainerLeaves = containers ? 1 : 0
        production.fallbackContainerLeaves = containers ? 1 : 5
        production.eligibleCaptionLeaves = containers ? 1 : 0
        production.fallbackCaptionLeaves = containers ? 0 : 1
        #expect(ADFTextRenderer.textKit2Coverage(of: blocks) == production)
        var visitedProduction: [String] = []
        TextKit2Scope.forEachLeaf(in: blocks) { if $0.position.context == .container { visitedProduction.append($0.ownerID) } }
        #expect(visitedProduction == ["0.2.0", "0.3.0", "0.3.1", "0.7.0", "0.12.0"])

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
            let production = ADFTextRenderer.textKit2CodeAdmission(
                of: blocks, dynamicTypeSize: .large, legibilityWeight: nil, displayScale: 3, layoutDirection: .leftToRight
            )
            #expect(production.nestedCodeAdmitted == 0 && production.nestedCodeGated == 0, "\(name): no nested code with the production list")
            for (stage, allowed) in Self.stages {
                let label = "\(name) at \(stage)"
                let coverage = ADFTextRenderer.textKit2Coverage(of: blocks, allowed: allowed)
                #expect(coverage.eligibleCodeRoots + coverage.fallbackCodeRoots == roots, "\(label)")
                let admission = ADFTextRenderer.textKit2CodeAdmission(
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
        // is admitted at Large, and one falling back by content.
        let blocks = try await TK2ContainerCoverage.blocks()
        let admission = ADFTextRenderer.textKit2CodeAdmission(
            of: blocks, allowed: TK2ContainerCoverage.every, dynamicTypeSize: .large, legibilityWeight: nil, displayScale: 3,
            layoutDirection: .leftToRight
        )
        #if canImport(UIKit)
        let expected = [1, 0, 1, 0]
        #else
        let expected = [0, 1, 0, 1]
        #endif
        #expect([admission.admittedCodeRoots, admission.gatedCodeRoots, admission.nestedCodeAdmitted, admission.nestedCodeGated] == expected)
    }

    @Test("expands whose bodies are not prepared are counted, never entered: top-level and nested, only where the allow list reaches them")
    func unpreparedExpandsAreCounted() async throws {
        let blocks = try await TK2ContainerCoverage.blocks()
        let cases: [(Set<TextKit2BlockKind>, Int, String)] = [
            ([], 0, "the production list"),
            ([.expand], 1, "the top-level expand only: the nested one is in a panel"),
            ([.panel], 0, "the panel is entered, the nested expand in it is not allowed"),
            ([.panel, .expand], 2, "both"),
            (TK2ContainerCoverage.every, 2, "every kind: the expand in a list item is never reached"),
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
        // containers-expand: every top-level expand is reported once the
        // family is allowed, and none with the production list.
        let fixture = try await TextKit2ListCoverageTests.blocks("containers-expand")
        let topLevel = fixture.filter { if case .expand = $0.kind { return true }; return false }.count
        #expect(topLevel > 0)
        #expect(ADFTextRenderer.textKit2Coverage(of: fixture).unpreparedExpands == 0)
        #expect(ADFTextRenderer.textKit2Coverage(of: fixture, allowed: [.expand]).unpreparedExpands == topLevel)
        #expect(ADFTextRenderer.textKit2Coverage(of: fixture, allowed: TK2ContainerCoverage.every).unpreparedExpands >= topLevel)
    }

    /// A fixture's container leaves as hand-counted from its JSON for the
    /// step-3 scope (`<data>/step3/tools/handcount.py`, which re-implements
    /// the rules over the raw ADF, not the walk): by the innermost
    /// container (panel, quote, extension body), the headings among them,
    /// the linked and the fallback (inline atom) ones, and the top-level
    /// panels whose shape keeps their body on SwiftUI.
    struct FixturePin {
        let name: String
        let panel: Int
        let quote: Int
        let extensionBody: Int
        let headings: Int
        let linked: Int
        let atoms: Int
        let panelShapeExcluded: [String]
        /// Plain captions in scope (step 8): on captioned media at the top
        /// level or in a panel, quote or extension body that passes the
        /// renderer; eligible from iOS 26.
        var captions = 0
        /// Leaves expected to stay on SwiftUI for a view-time reason on the
        /// gate device (iPhone, left to right, the demo's environment): none
        /// at step 3. No panel is right to left, the demo sets no font or
        /// image scale on the document (`unprovenNestedWidth`), and no
        /// container leaf is under 1 pt wide.
        let viewTimeFallbacks = 0

        var leaves: Int { panel + quote + extensionBody }
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
    /// their bodies on SwiftUI; 0.10 is empty. Links:
    /// 0.16.0, 0.18.0, 0.22.1.
    /// kitchen-sink: seven one-paragraph panels, a quote and a bodied
    /// extension (the two column paragraphs and the expand wait for their
    /// families).
    /// stress-1k: 80 top-level one-paragraph panels and 80 top-level quotes
    /// of one to three paragraphs (119 leaves); its other panels and quotes
    /// sit in list items, expands and columns, out of scope at step 3.
    /// Captions (step 8, counted from the JSON): containers-parity has
    /// none; kitchen-sink's one (0.23, plain) is top-level; stress-1k's ten
    /// (0.95, 0.195, … 0.995) are all in expands, out of scope.
    static let pins: [FixturePin] = [
        FixturePin(name: "containers-parity", panel: 17, quote: 16, extensionBody: 7, headings: 2, linked: 3, atoms: 2,
                   panelShapeExcluded: ["0.11", "0.12", "0.15", "0.63", "0.71", "0.77", "0.78"]),
        FixturePin(name: "kitchen-sink", panel: 7, quote: 1, extensionBody: 1, headings: 0, linked: 0, atoms: 0, panelShapeExcluded: [], captions: 1),
        FixturePin(name: "stress-1k", panel: 80, quote: 119, extensionBody: 0, headings: 0, linked: 43, atoms: 0, panelShapeExcluded: []),
    ]

    /// The innermost container kind above each container leaf the walk
    /// visits (owner id → "panel", "quote" or "extension").
    static func innermostContainers(_ blocks: [RenderBlock]) -> [String: String] {
        var found: [String: String] = [:]
        func walk(_ blocks: [RenderBlock], in container: String?) {
            for block in blocks {
                switch block.kind {
                case .richText: if let container { found[block.id] = container }
                case .panel(_, let children): walk(children, in: "panel")
                case .quote(let children): walk(children, in: "quote")
                case .extensionPlaceholder(_, let body): walk(body, in: "extension")
                default: continue
                }
            }
        }
        walk(blocks, in: nil)
        return found
    }

    @Test("fixturePins: hand-counted container leaves of containers-parity, kitchen-sink and stress-1k at step 3, by container, with the excluded panel shapes, and their captions; before iOS 26 every one is gated")
    func fixturePins() async throws {
        let containers = TextKit2Eligibility.containerTextMatchesText
        for pin in Self.pins {
            let blocks = try await TextKit2ListCoverageTests.blocks(pin.name)
            let coverage = ADFTextRenderer.textKit2Coverage(of: blocks)
            let eligible = pin.leaves - pin.atoms
            #expect(coverage.eligibleContainerLeaves == (containers ? eligible : 0), "\(pin.name): \(coverage)")
            #expect(coverage.linkedContainerLeaves == (containers ? pin.linked : 0), "\(pin.name): \(coverage)")
            #expect(coverage.fallbackContainerLeaves == (containers ? pin.atoms : pin.leaves), "\(pin.name): \(coverage)")
            #expect(coverage.containerListLeaves == 0, "\(pin.name)")
            #expect(coverage.eligibleNestedCode + coverage.fallbackNestedCode + coverage.unpreparedExpands == 0, "\(pin.name)")
            #expect(coverage.eligibleCaptionLeaves == (containers ? pin.captions : 0), "\(pin.name): \(coverage)")
            #expect(coverage.fallbackCaptionLeaves == (containers ? 0 : pin.captions), "\(pin.name): \(coverage)")

            // The leaves by their innermost container, and the reasons.
            let kinds = Self.innermostContainers(blocks)
            var byKind: [String: Int] = [:]
            var headings = 0
            var reasons: [TextKit2Eligibility.Fallback: Int] = [:]
            TextKit2Scope.forEachLeaf(in: blocks) { leaf in
                guard leaf.position == .containerProse else { return }
                byKind[kinds[leaf.ownerID] ?? "?", default: 0] += 1
                if leaf.style?.isHeading == true { headings += 1 }
                if case .fallback(let reason) = leaf.verdict { reasons[reason, default: 0] += 1 }
            }
            #expect(byKind == ["panel": pin.panel, "quote": pin.quote, "extension": pin.extensionBody].filter { $0.value > 0 }, "\(pin.name): \(byKind)")
            #expect(headings == pin.headings, "\(pin.name)")
            var expectedReasons: [TextKit2Eligibility.Fallback: Int] = [:]
            if pin.atoms > 0 { expectedReasons[.atom] = pin.atoms }
            if !containers { expectedReasons[.osGatedContainer] = eligible }
            #expect(reasons == expectedReasons, "\(pin.name): \(reasons)")
            #expect(pin.viewTimeFallbacks == 0)

            // The panels whose shape keeps their body on SwiftUI.
            let excluded = blocks.filter { block in
                if case .panel(_, let children) = block.kind { return !TextKit2Scope.panelKeepsRenderer(children) }
                return false
            }.map(\.id)
            #expect(excluded == pin.panelShapeExcluded, "\(pin.name)")
        }
    }

    static func find(_ id: String, in blocks: [RenderBlock]) -> RenderBlock? {
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

    @Test("with the production list (step 3 and captions) only the container leaf fields, as the step-3 stage counts them, and the caption fields, for the captioned media in scope, move; no nested code, container list leaf or unprepared expand on any fixture; the legacy fields are the empty list's")
    func newFieldsReadZeroOnEveryFixture() async throws {
        let step3 = try #require(Self.stages.first { $0.name.hasPrefix("step 3") }).kinds
        let production = step3.union([.media])
        #expect(production == TextKit2Scope.containerChildKinds)
        for name in try TK2ContainerCoverage.allFixtures() {
            let blocks = try await TextKit2ListCoverageTests.blocks(name)
            let coverage = ADFTextRenderer.textKit2Coverage(of: blocks)
            #expect(coverage == ADFTextRenderer.textKit2Coverage(of: blocks, allowed: production), "\(name)")
            // Media adds captions only: the container leaf fields are the
            // step-3 stage's.
            let atStep3 = ADFTextRenderer.textKit2Coverage(of: blocks, allowed: step3)
            #expect(coverage.eligibleContainerLeaves == atStep3.eligibleContainerLeaves
                && coverage.linkedContainerLeaves == atStep3.linkedContainerLeaves
                && coverage.fallbackContainerLeaves == atStep3.fallbackContainerLeaves, "\(name): \(coverage)")
            #expect(TK2ContainerCoverage.legacy(coverage) == ADFTextRenderer.textKit2Coverage(of: blocks, allowed: []), "\(name)")
            #expect(coverage.containerListLeaves == 0, "\(name): \(coverage)")
            #expect(coverage.eligibleNestedCode + coverage.fallbackNestedCode == 0 && coverage.unpreparedExpands == 0, "\(name): \(coverage)")
            #expect(coverage.eligibleCaptionLeaves + coverage.fallbackCaptionLeaves == TK2ContainerCoverage.captionsInScope(blocks), "\(name): \(coverage)")
            if !TextKit2Eligibility.containerTextMatchesText {
                #expect(coverage.eligibleContainerLeaves == 0 && coverage.linkedContainerLeaves == 0, "\(name): container text is gated before iOS 26")
                #expect(coverage.eligibleCaptionLeaves == 0, "\(name): captions are gated before iOS 26")
            }
            #expect(coverage.eligibleCodeRoots + coverage.fallbackCodeRoots == TK2ContainerCoverage.topLevelCode(blocks), "\(name)")
            let admission = ADFTextRenderer.textKit2CodeAdmission(
                of: blocks, dynamicTypeSize: .large, legibilityWeight: nil, displayScale: 3, layoutDirection: .leftToRight
            )
            #expect(admission.nestedCodeAdmitted == 0 && admission.nestedCodeGated == 0, "\(name)")
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
        // Before iOS 26 the prose stays on SwiftUI (`osGatedContainer`);
        // the code row is the code family's and is not gated.
        let containers = TextKit2Eligibility.containerTextMatchesText
        #expect(Set(rows.compactMap(\.ownerID)) == (containers ? [prose, code] : [code]))
        for row in rows {
            #expect(row.containerContext == .container, "\(row.ownerID ?? "?")")
            #expect(row.ownerKind == (row.ownerID == code ? .code : .root), "\(row.ownerID ?? "?")")
        }
        // No suspension from here to the last read.
        #expect(ADFTextRenderer.textKit2ContainerRowDraws == diagnostics.containerRowDraws)
        #expect(ADFTextRenderer.textKit2CaptionRowDraws == diagnostics.captionRowDraws)
        #expect(ADFTextRenderer.textKit2ContainerRowDraws[code] == nil, "code is never container proof")
        #expect(ADFTextRenderer.textKit2CodeRowDraws[code] != nil, "nested code is in the code record")
        #expect(diagnostics.containerRowDraws.count <= diagnostics.liveContainerRowCount)
        if containers {
            let listed = try #require(ADFTextRenderer.textKit2ContainerRowDraws[prose], "a live container row is listed, drawn or not")
            let native = diagnostics.containerNativeDrawCount
            for row in rows { TK2CodeLogic.draw(row) }
            #expect(ADFTextRenderer.textKit2ContainerRowDraws[prose] == listed + 1)
            #expect(diagnostics.containerNativeDrawCount - native == 1)
        } else {
            #expect(ADFTextRenderer.textKit2ContainerRowDraws[prose] == nil, "gated before iOS 26: no container row")
            let native = diagnostics.containerNativeDrawCount
            for row in rows { TK2CodeLogic.draw(row) }
            #expect(diagnostics.containerNativeDrawCount == native, "a code row's draw is never a container draw")
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
