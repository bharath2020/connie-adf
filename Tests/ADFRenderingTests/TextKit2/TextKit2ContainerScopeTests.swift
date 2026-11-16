import Foundation
import SwiftUI
import Testing
import ADFModel
import ADFPreparation
@testable import ADFRendering

/// The container boundary's rules (plan §4.1, §3.3), as pure functions: the
/// renderer a container hands each child (`TextKit2Scope.childRenderer`)
/// over every block kind, every parent, both inherited values and every
/// allow-list stage; the top-level rows reading the same list and rules
/// (`inheritsRenderer`); the panel shape rule (`panelKeepsRenderer`); and
/// the view-time rules (`containerGate`). The production allow list holds
/// the families enabled so far (paragraphs and headings, panels, quotes,
/// extension bodies, expands). Cross-platform.
@Suite("TextKit 2 container scope: rules")
struct TextKit2ContainerScopeTests {
    /// The allow list at each stage of the container work (plan §5), and
    /// every kind at once (a test host's widest list).
    static let stages: [(name: String, kinds: Set<TextKit2BlockKind>)] = {
        var kinds: Set<TextKit2BlockKind> = []
        var stages: [(String, Set<TextKit2BlockKind>)] = [("step 2: none", kinds)]
        for (name, added) in [
            ("step 3: prose, panels, quotes, extension bodies", [TextKit2BlockKind.richText, .panel, .quote, .extensionPlaceholder]),
            ("step 4: layout columns", [.layoutColumns]),
            ("step 5: expands", [.expand]),
            ("step 6: lists", [.listRows]),
            ("step 7: code", [.codeBlock]),
            ("step 8: captions", [.media]),
        ] as [(String, [TextKit2BlockKind])] {
            kinds.formUnion(added)
            stages.append((name, kinds))
        }
        stages.append(("every kind", Set(TextKit2BlockKind.allCases)))
        return stages
    }()

    static let parents: [TextKit2ContainerParent] = [
        .panel, .quote, .expandBody, .extensionBody, .column(sideBySide: false), .column(sideBySide: true),
    ]

    /// Claims every `blockCard` whose URL starts `plugin:` (a plugin block).
    struct PluginClaim: ADFCustomBlockPreparer {
        let rendererID = "test.container-scope.plugin"
        func claim(for node: ADFNode) -> ADFCustomBlockClaim? {
            guard case .blockCard(let url, _) = node.kind, let url, url.hasPrefix("plugin:") else { return nil }
            return ADFCustomBlockClaim(url, sizing: .reflowingText)
        }
    }

    static func paragraph(_ text: String) -> String {
        "{\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"\(text)\"}]}"
    }

    static func item(_ content: String) -> String {
        "{\"type\":\"listItem\",\"content\":[\(content)]}"
    }

    /// One top-level node of every shape the boundary decides on: each
    /// `RenderBlock.Kind`, a list that fails rule B and one that passes,
    /// an extension with and without a body, media with and without a
    /// caption, an expand and a nested expand.
    static let samplesJSON = [
        paragraph("A paragraph."),
        "{\"type\":\"heading\",\"attrs\":{\"level\":2},\"content\":[{\"type\":\"text\",\"text\":\"A heading\"}]}",
        "{\"type\":\"codeBlock\",\"content\":[{\"type\":\"text\",\"text\":\"let x = 1\"}]}",
        "{\"type\":\"bulletList\",\"content\":[\(item(paragraph("A plain item.")))]}",
        // Rule B: a row holding both a panel and an expand keeps the whole
        // list on SwiftUI.
        "{\"type\":\"bulletList\",\"content\":[\(item(paragraph("Mixed.") + ",{\"type\":\"panel\",\"attrs\":{\"panelType\":\"note\"},\"content\":[\(paragraph("In a panel."))]},{\"type\":\"nestedExpand\",\"attrs\":{\"title\":\"E\"},\"content\":[\(paragraph("In an expand."))]}"))]}",
        "{\"type\":\"panel\",\"attrs\":{\"panelType\":\"info\"},\"content\":[\(paragraph("Panel text."))]}",
        "{\"type\":\"blockquote\",\"content\":[\(paragraph("Quoted."))]}",
        "{\"type\":\"rule\"}",
        "{\"type\":\"table\",\"content\":[{\"type\":\"tableRow\",\"content\":[{\"type\":\"tableCell\",\"content\":[\(paragraph("Cell."))]}]}]}",
        "{\"type\":\"mediaSingle\",\"attrs\":{\"layout\":\"center\"},\"content\":[{\"type\":\"media\",\"attrs\":{\"type\":\"external\",\"url\":\"placeholder://a\",\"width\":100,\"height\":50}},{\"type\":\"caption\",\"content\":[{\"type\":\"text\",\"text\":\"A caption.\"}]}]}",
        "{\"type\":\"mediaSingle\",\"attrs\":{\"layout\":\"center\"},\"content\":[{\"type\":\"media\",\"attrs\":{\"type\":\"external\",\"url\":\"placeholder://b\",\"width\":100,\"height\":50}}]}",
        "{\"type\":\"mediaGroup\",\"content\":[{\"type\":\"media\",\"attrs\":{\"type\":\"file\",\"id\":\"m1\",\"collection\":\"c\"}}]}",
        "{\"type\":\"expand\",\"attrs\":{\"title\":\"Expand\"},\"content\":[\(paragraph("In the body."))]}",
        "{\"type\":\"nestedExpand\",\"attrs\":{\"title\":\"Nested\"},\"content\":[\(paragraph("In the nested body."))]}",
        "{\"type\":\"layoutSection\",\"content\":[{\"type\":\"layoutColumn\",\"attrs\":{\"width\":50},\"content\":[\(paragraph("Left."))]},{\"type\":\"layoutColumn\",\"attrs\":{\"width\":50},\"content\":[\(paragraph("Right."))]}]}",
        "{\"type\":\"blockCard\",\"attrs\":{\"url\":\"https://example.com\"}}",
        "{\"type\":\"embedCard\",\"attrs\":{\"url\":\"https://example.com/embed\",\"layout\":\"center\"}}",
        "{\"type\":\"extension\",\"attrs\":{\"extensionKey\":\"toc\",\"extensionType\":\"com.example\"}}",
        "{\"type\":\"bodiedExtension\",\"attrs\":{\"extensionKey\":\"excerpt\",\"extensionType\":\"com.example\"},\"content\":[\(paragraph("Extension body."))]}",
        "{\"type\":\"blockCard\",\"attrs\":{\"url\":\"plugin:one\"}}",
        "{\"type\":\"someFutureNode\",\"content\":[]}",
    ]

    static func samples() async throws -> [RenderBlock] {
        let json = "{\"version\":1,\"type\":\"doc\",\"content\":[\(samplesJSON.joined(separator: ","))]}"
        let document = try await ADFParser().parse(Data(json.utf8))
        return DocumentPreparer(theme: .default, customPreparers: [PluginClaim()]).prepare(document)
    }

    /// The test's own exhaustive map from a kind to its case: a new
    /// `RenderBlock.Kind` case stops this suite compiling until it is
    /// decided here too.
    static func family(_ kind: RenderBlock.Kind) -> TextKit2BlockKind {
        switch kind {
        case .richText: return .richText
        case .codeBlock: return .codeBlock
        case .listRows: return .listRows
        case .panel: return .panel
        case .quote: return .quote
        case .divider: return .divider
        case .tableSlice: return .tableSlice
        case .media: return .media
        case .mediaStrip: return .mediaStrip
        case .expand: return .expand
        case .layoutColumns: return .layoutColumns
        case .card: return .card
        case .extensionPlaceholder: return .extensionPlaceholder
        case .custom: return .custom
        case .unknown: return .unknown
        }
    }

    /// The whole-block rules as this stage has them (plan §4.1, P17),
    /// written out independently of `blockKeepsRenderer`: a list by rule B;
    /// a panel by the panel shape probes (`expectedPanelKeeps`); an
    /// extension with a body; media with a caption (captions are on);
    /// tables, plugins, dividers, media strips, cards and unknown nodes
    /// never.
    static func expectedWholeBlock(_ kind: RenderBlock.Kind) -> Bool {
        switch kind {
        case .richText, .codeBlock, .quote, .expand, .layoutColumns: return true
        case .listRows(let rows): return TextKit2Scope.listKeepsRenderer(rows)
        case .panel(_, let children): return expectedPanelKeeps(children)
        case .extensionPlaceholder(_, let body): return !body.isEmpty
        case .media(let media): return !(media.caption?.isEmpty ?? true)
        case .divider, .tableSlice, .mediaStrip, .card, .custom, .unknown: return false
        }
    }

    /// The panel shape rule as the probes decided it (`probes/results.md`
    /// §1) and the step 3 parity run added (a code block beside prose),
    /// written out from the run attributes rather than through
    /// `isBodyText`: no list, no heading, and neither a code block nor a
    /// superscript, subscript or small-text run (a `.footnote` or
    /// `.subheadline` font spec) unless it is the whole body.
    static func expectedPanelKeeps(_ children: [RenderBlock]) -> Bool {
        var small = false
        for child in children {
            switch child.kind {
            case .listRows: return false
            case .codeBlock: small = true
            case .richText(let segments, let style):
                if style.isHeading { return false }
                for case .text(let text) in segments {
                    for run in text.runs {
                        if let style = run.adfFontSpec?.textStyle, style == .footnote || style == .subheadline { small = true }
                    }
                }
            default: break
            }
        }
        return children.count == 1 || !small
    }

    @Test("childRenderer is exhaustive: every kind, parent, inherited renderer, allow-list stage and direction")
    func childRendererIsExhaustive() async throws {
        let samples = try await Self.samples()
        // The samples hold every kind, and the boundary's own map agrees
        // with the test's.
        #expect(Set(samples.map { Self.family($0.kind) }) == Set(TextKit2BlockKind.allCases))
        for sample in samples {
            #expect(TextKit2BlockKind(sample.kind) == Self.family(sample.kind), "\(sample.id)")
        }
        // The shapes that matter to the rules are there.
        let lists = samples.compactMap { block -> [PreparedListRow]? in
            if case .listRows(let rows) = block.kind { return rows }
            return nil
        }
        #expect(lists.map(TextKit2Scope.listKeepsRenderer).sorted { !$0 && $1 } == [false, true], "one list passes rule B, one fails")
        let extensions = samples.compactMap { block -> Bool? in
            if case .extensionPlaceholder(_, let body) = block.kind { return body.isEmpty }
            return nil
        }
        #expect(Set(extensions) == [true, false], "an extension with a body and one without")
        let captions = samples.compactMap { block -> Bool? in
            if case .media(let media) = block.kind { return media.caption?.isEmpty ?? true }
            return nil
        }
        #expect(Set(captions) == [true, false], "media with a caption and without")

        var checked = 0
        for sample in samples {
            let family = Self.family(sample.kind)
            for parent in Self.parents {
                for inherited in ADFTextRenderer.allCases {
                    for (stage, allowed) in Self.stages {
                        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
                            let renderer = TextKit2Scope.childRenderer(
                                for: sample.kind, in: parent, inherited: inherited, allowed: allowed, layoutDirection: direction
                            )
                            // No view-time boundary rule keeps a family out
                            // at this stage (`containerGateTruthTable`).
                            let expected: ADFTextRenderer = inherited == .textKit2 && allowed.contains(family)
                                && Self.expectedWholeBlock(sample.kind) ? .textKit2 : .swiftUI
                            #expect(renderer == expected, "\(sample.id) \(family) in \(parent), inherited \(inherited), \(stage), \(direction)")
                            checked += 1
                        }
                    }
                }
            }
        }
        #expect(checked == samples.count * Self.parents.count * 2 * Self.stages.count * 2)

        // The excluded kinds never get TextKit 2, whatever the list says.
        #expect(TextKit2Scope.containerExcludedKinds == [.tableSlice, .custom, .divider, .mediaStrip, .card, .unknown])
        for sample in samples where TextKit2Scope.containerExcludedKinds.contains(Self.family(sample.kind)) {
            for parent in Self.parents {
                let renderer = TextKit2Scope.childRenderer(
                    for: sample.kind, in: parent, inherited: .textKit2, allowed: Set(TextKit2BlockKind.allCases), layoutDirection: .leftToRight
                )
                #expect(renderer == .swiftUI, "\(sample.id) in \(parent)")
            }
        }
    }

    @Test("top-level rows read the same allow list and whole-block rules; the production list holds prose, panels, quotes, extension bodies, captioned media and expands")
    func topLevelRowsReadTheAllowList() async throws {
        // Step 3: paragraphs and headings in panels, quotes and extension
        // bodies; step 8: captions; step 5: expands (their open bodies).
        // Each later stage changes this pin deliberately, with the family
        // it enables.
        #expect(TextKit2Scope.containerChildKinds == [.richText, .panel, .quote, .extensionPlaceholder, .media, .expand])
        #expect(EnvironmentValues().adfContainerChildKinds == TextKit2Scope.containerChildKinds)
        #expect(EnvironmentValues().adfTextContainerContext == .none)
        #expect(TextKit2Scope.captionsUseTextKit2 == true)

        let samples = try await Self.samples()
        for sample in samples {
            let family = Self.family(sample.kind)
            // In the app (the production list): PR 3's rows, and from
            // step 3 panels that pass their shape rule, quotes and bodied
            // extensions; from step 8 media with a caption; from step 5
            // expands and nested expands.
            let pr3: Bool
            switch sample.kind {
            case .richText, .codeBlock: pr3 = true
            case .listRows(let rows): pr3 = TextKit2Scope.listKeepsRenderer(rows)
            default: pr3 = false
            }
            let production: Bool
            switch sample.kind {
            case .panel(_, let children): production = Self.expectedPanelKeeps(children)
            case .quote, .expand: production = true
            case .extensionPlaceholder(_, let body): production = !body.isEmpty
            case .media(let media): production = !(media.caption?.isEmpty ?? true)
            default: production = pr3
            }
            #expect(TextKit2Scope.inheritsRenderer(sample.kind) == production, "\(sample.id) \(family)")
            for (stage, allowed) in Self.stages {
                let inherits = TextKit2Scope.inheritsRenderer(sample.kind, allowed: allowed)
                switch family {
                case .richText, .codeBlock, .listRows:
                    // PR 1–3's cases do not read the list.
                    #expect(inherits == pr3, "\(sample.id) \(family) at \(stage)")
                case .panel, .quote, .extensionPlaceholder, .layoutColumns, .expand, .media:
                    // A container row keeps the choice exactly when a
                    // boundary would pass it to the same block.
                    let nested = TextKit2Scope.childRenderer(
                        for: sample.kind, in: .quote, inherited: .textKit2, allowed: allowed, layoutDirection: .leftToRight
                    ) == .textKit2
                    #expect(inherits == nested, "\(sample.id) \(family) at \(stage)")
                    #expect(inherits == (allowed.contains(family) && Self.expectedWholeBlock(sample.kind)), "\(sample.id) \(family) at \(stage)")
                case .divider, .tableSlice, .mediaStrip, .card, .custom, .unknown:
                    #expect(!inherits, "\(sample.id) \(family) at \(stage)")
                }
            }
        }
    }

    @Test("containerGate: the width rules for wrapping leaves, none for code; no boundary rule fires before its family's probe decides it")
    @MainActor
    func containerGateTruthTable() {
        #expect(Set(TextKit2Scope.ContainerGate.allCases) == [.narrowColumn, .unprovenNestedWidth, .panelDirection, .horizontalColumn])

        // The leaf's width rules: (bound, inset) → the wrapping verdict.
        let wrapping: [(TextKit2WidthBound, CGFloat, TextKit2Scope.ContainerGate?)] = [
            (.pending, 0, nil), (.pending, 144, nil), (.pending, 10_000, nil),
            (.unproven, 0, .unprovenNestedWidth), (.unproven, -10_000, .unprovenNestedWidth),
            (.atLeast(343), 0, nil), (.atLeast(343), 342, nil), (.atLeast(343), 342.5, .narrowColumn),
            (.atLeast(1), 0, nil), (.atLeast(0.999), 0, .narrowColumn), (.atLeast(0), 0, .narrowColumn),
            (.atLeast(145), 144, nil), (.atLeast(144.5), 144, .narrowColumn),
            // A level-6 paragraph in the 25 % column of a 25/75 section:
            // 88.5 pt in a 402 pt document, 148 pt in a 640 pt one.
            (.atLeast(88.5), 144, .narrowColumn), (.atLeast(148), 144, nil),
        ]
        for (bound, inset, expected) in wrapping {
            #expect(TextKit2Scope.containerGate(widthBound: bound, inset: inset, layoutPolicy: .wrapping) == expected, "wrapping \(bound) inset \(inset)")
            // Code never wraps: its own gate decides it.
            #expect(TextKit2Scope.containerGate(widthBound: bound, inset: inset, layoutPolicy: .natural) == nil, "natural \(bound) inset \(inset)")
            // The width rules are the under-1-pt guard.
            #expect((expected == nil) == TextKit2Scope.textFits(bound, inset: inset), "textFits \(bound) inset \(inset)")
        }

        // The boundary's rules. The panel direction and the side-by-side
        // families are decided by their probes when those families are
        // enabled; until then neither keeps anything out.
        #expect(TextKit2Scope.panelDirectionKeepsRenderer(.leftToRight))
        #expect(TextKit2Scope.panelDirectionKeepsRenderer(.rightToLeft))
        for kind in TextKit2BlockKind.allCases {
            #expect(TextKit2Scope.horizontalColumnKeepsRenderer(kind), "\(kind)")
        }
        let kinds: [RenderBlock.Kind] = [
            .richText(segments: [], style: ListRowView.leaderStyle(theme: .default)),
            .quote([]), .panel(ADFTheme.default.panelPalette(.info, colorHex: nil), []), .listRows([]),
        ]
        for kind in kinds {
            for parent in Self.parents {
                for direction in [LayoutDirection.leftToRight, .rightToLeft] {
                    #expect(TextKit2Scope.containerGate(for: kind, in: parent, layoutDirection: direction) == nil, "\(kind) in \(parent) \(direction)")
                }
            }
        }
    }

    /// A text node with marks (JSON).
    static func text(_ string: String, _ marks: String...) -> String {
        marks.isEmpty ? "{\"type\":\"text\",\"text\":\"\(string)\"}"
            : "{\"type\":\"text\",\"text\":\"\(string)\",\"marks\":[\(marks.joined(separator: ","))]}"
    }

    /// The panel bodies the shape probes measured (`probes/results.md`
    /// §3.1), plus the shapes the fixtures hold beside them, with the
    /// outcome the probes decided: `true` keeps the body's text on
    /// TextKit 2.
    static let panelShapes: [(name: String, body: [String], keeps: Bool)] = {
        let sup = "{\"type\":\"subsup\",\"attrs\":{\"type\":\"sup\"}}"
        let sub = "{\"type\":\"subsup\",\"attrs\":{\"type\":\"sub\"}}"
        let small = "{\"type\":\"fontSize\",\"attrs\":{\"size\":\"small\"}}"
        let code = "{\"type\":\"code\"}"
        let link = "{\"type\":\"link\",\"attrs\":{\"href\":\"https://example.com\"}}"
        func p(_ content: String...) -> String { "{\"type\":\"paragraph\",\"content\":[\(content.joined(separator: ","))]}" }
        let heading = "{\"type\":\"heading\",\"attrs\":{\"level\":2},\"content\":[\(text("A heading"))]}"
        let list = "{\"type\":\"bulletList\",\"content\":[\(item(paragraph("An item")))]}"
        let task = "{\"type\":\"taskList\",\"attrs\":{\"localId\":\"t\"},\"content\":[{\"type\":\"taskItem\",\"attrs\":{\"localId\":\"t1\",\"state\":\"TODO\"},\"content\":[\(text("A task"))]}]}"
        let quote = "{\"type\":\"blockquote\",\"content\":[\(paragraph("Quoted"))]}"
        let codeBlock = "{\"type\":\"codeBlock\",\"content\":[\(text("let x = 1"))]}"
        let subsup = p(text("x"), text("2", sup), text(" H"), text("2", sub), text("O "), text("small print", small))
        return [
            ("onePara", [paragraph("One paragraph.")], true),
            ("bodyParas", [p(text("Linked", link), text(" and "), text("code", code)), paragraph("Second."), paragraph("Third.")], true),
            ("subsupAlone", [subsup], true),
            ("nestedQuote", [paragraph("Before the quote."), quote], true),
            ("codeAlone", [codeBlock], true),
            ("smallCodeBeside", [p(text("small code", small, code)), paragraph("A body paragraph.")], true),
            ("headingPara", [heading, paragraph("After the heading.")], false),
            ("headingAlone", [heading], false),
            ("subsupBeside", [paragraph("Before."), subsup, paragraph("After.")], false),
            ("subsupBesideQuote", [subsup, quote], false),
            ("nestedList", [paragraph("Before the list."), list], false),
            ("listAlone", [list], false),
            ("taskBeside", [paragraph("Before the tasks."), task], false),
            ("codeBeside", [paragraph("Before the code."), codeBlock], false),
            ("codeFirst", [codeBlock, paragraph("After the code.")], false),
        ]
    }()

    /// The paragraphs and headings a container body holds, through the
    /// quotes in it (a quote keeps the renderer) and the panels that keep it
    /// by the test's own rule; lists, code and other blocks hold none.
    static func proseCount(_ children: [RenderBlock]) -> Int {
        children.reduce(0) { count, child in
            switch child.kind {
            case .richText: return count + 1
            case .quote(let nested): return count + proseCount(nested)
            case .panel(_, let nested): return count + (expectedPanelKeeps(nested) ? proseCount(nested) : 0)
            default: return count
            }
        }
    }

    @Test("panelKeepsRenderer: the probed panel shapes keep or reset the renderer as the probes decided, as a top-level row, a nested child and in the coverage walk")
    func panelShapeRule() async throws {
        for shape in Self.panelShapes {
            let json = "{\"version\":1,\"type\":\"doc\",\"content\":[{\"type\":\"panel\",\"attrs\":{\"panelType\":\"info\"},\"content\":[\(shape.body.joined(separator: ","))]}]}"
            let blocks = DocumentPreparer(theme: .default).prepare(try await ADFParser().parse(Data(json.utf8)))
            let panel = try #require(blocks.first)
            guard case .panel(_, let children) = panel.kind else { throw TestFailure("\(shape.name): not a panel") }
            #expect(TextKit2Scope.panelKeepsRenderer(children) == shape.keeps, "\(shape.name)")
            #expect(Self.expectedPanelKeeps(children) == shape.keeps, "\(shape.name): the test's own rule")
            #expect(TextKit2Scope.blockKeepsRenderer(panel.kind) == shape.keeps, "\(shape.name)")
            #expect(TextKit2Scope.inheritsRenderer(panel.kind) == shape.keeps, "\(shape.name): top-level row")
            for parent in [TextKit2ContainerParent.quote, .extensionBody, .panel] {
                let nested = TextKit2Scope.childRenderer(
                    for: panel.kind, in: parent, inherited: .textKit2, allowed: TextKit2Scope.containerChildKinds, layoutDirection: .leftToRight
                )
                #expect(nested == (shape.keeps ? .textKit2 : .swiftUI), "\(shape.name) in \(parent)")
            }
            // The walk counts the body's prose only where the panel keeps
            // the renderer (reason `panelShape`, a static reason).
            var prose: [String] = []
            TextKit2Scope.forEachLeaf(in: blocks) { if $0.position == .containerProse { prose.append($0.ownerID) } }
            let paragraphs = Self.proseCount(children)
            #expect(prose.count == (shape.keeps ? paragraphs : 0), "\(shape.name): \(prose)")
            // A quote around the same body is not a panel: its prose counts.
            let quote = RenderBlock(id: "q", kind: .quote(children))
            var quoted = 0
            TextKit2Scope.forEachLeaf(in: [quote]) { if $0.position == .containerProse { quoted += 1 } }
            #expect(quoted == paragraphs, "\(shape.name) as a quote body")
        }
        // An empty panel keeps the renderer and has nothing to draw.
        #expect(TextKit2Scope.panelKeepsRenderer([]))
    }

    @Test("containerTextMatchesText: before iOS 26 container text and captions fall back as osGatedContainer, after the content reasons and the list gate; roots, lists and code outside containers are unaffected")
    func containerOSGate() throws {
        func segments(_ string: String) -> [InlineSegment] {
            var text = AttributedString(string)
            text.adfFontSpec = ADFFontSpec(textStyle: .body)
            return [.text(text)]
        }
        let gated = !TextKit2Eligibility.containerTextMatchesText
        #expect(TextKit2Eligibility.containerTextMatchesText == TextKit2Eligibility.listsMatchText, "both from iOS 26")
        func reason(_ verdict: TextKit2Eligibility.Verdict) -> TextKit2Eligibility.Fallback? {
            if case .fallback(let reason) = verdict { return reason }
            return nil
        }
        let plain = segments("Container text.")
        for context in [TextKit2ContainerContext.container, .caption] {
            #expect(reason(TextKit2Eligibility.verdict(plain, owner: .root, context: context)) == (gated ? .osGatedContainer : nil), "\(context)")
            // The list gate decides list text in a container first.
            #expect(reason(TextKit2Eligibility.verdict(plain, owner: .list, context: context)) == (gated ? .osGatedList : nil), "list in \(context)")
            // Content reasons come first.
            #expect(reason(TextKit2Eligibility.verdict(segments("\n"), owner: .root, context: context)) == .empty, "\(context)")
            #expect(reason(TextKit2Eligibility.verdict([.atom(.mention(text: "@a"), id: "m")], owner: .root, context: context)) == .atom, "\(context)")
        }
        #expect(reason(TextKit2Eligibility.verdict(plain, owner: .root, context: .none)) == nil, "root text is never container-gated")
        #expect(reason(TextKit2Eligibility.verdict(plain, owner: .list, context: .none)) == (gated ? .osGatedList : nil))
    }

    @Test("a width bound narrows by an inset and maps through a share, clamped at 0; pending and unproven pass unchanged")
    func boundArithmetic() {
        #expect(TextKit2WidthBound.atLeast(343).narrowed(by: 16) == .atLeast(327))
        #expect(TextKit2WidthBound.atLeast(10).narrowed(by: 16) == .atLeast(0))
        #expect(TextKit2WidthBound.pending.narrowed(by: 16) == .pending)
        #expect(TextKit2WidthBound.unproven.narrowed(by: 16) == .unproven)
        #expect(TextKit2WidthBound.atLeast(100).mapWidth { $0 / 4 } == .atLeast(25))
        #expect(TextKit2WidthBound.atLeast(100).mapWidth { $0 - 200 } == .atLeast(0))
        #expect(TextKit2WidthBound.pending.mapWidth { $0 / 4 } == .pending)
        #expect(TextKit2WidthBound.unproven.mapWidth { $0 / 4 } == .unproven)
        // The section's column shares: what the layout itself divides.
        let widths = ProportionalColumnsLayout.columnWidths(totalWidth: 370, fractions: [0.25, 0.75], spacing: 16)
        #expect(widths == [88.5, 265.5])
        #expect(ProportionalColumnsLayout.columnWidths(totalWidth: 608, fractions: [0.25, 0.75], spacing: 16) == [148, 444])
        #expect(ProportionalColumnsLayout.columnWidths(totalWidth: 10, fractions: [0.5, 0.5], spacing: 16) == [0, 0])
    }
}

#if canImport(UIKit)
import UIKit

/// Plugin blocks for the hosted negatives: claims a `blockCard` whose URL
/// starts `plugin:` and draws its value as plain SwiftUI text.
private struct ScopePluginRenderer: ADFCustomBlockRenderer {
    let rendererID = "test.container-scope.plugin-renderer"

    func claim(for node: ADFNode) -> ADFCustomBlockClaim? {
        guard case .blockCard(let url, _) = node.kind, let url, url.hasPrefix("plugin:") else { return nil }
        return ADFCustomBlockClaim(String(url.dropFirst("plugin:".count)), sizing: .reflowingText)
    }

    @MainActor
    func content(for value: String, context: ADFCustomBlockContext) -> some View {
        Text(value)
    }
}

/// The hosted negatives of plan §4.1 and the excluded panel shapes (§3.3,
/// reason `panelShape`), through the real document view under `.textKit2`:
/// each named owner draws no TextKit 2 row, with the production allow list
/// and (through a widened test host) with every kind allowed, while a
/// sibling the rules do pass draws one, so the negative is the scope's
/// doing and not an empty document.
extension TextKit2ContainerScopeTests {
    /// The document, hosted under `.textKit2`; returns this window's row
    /// owners by context. `allowed` widens the allow list (`nil`: the
    /// production list).
    @MainActor
    static func hostedOwners(
        _ content: [String], allowed: Set<TextKit2BlockKind>? = nil, openExpands: Set<String> = []
    ) async throws -> (all: Set<String>, container: Set<String>, root: Set<String>) {
        let json = "{\"version\":1,\"type\":\"doc\",\"content\":[\(content.joined(separator: ","))]}"
        let model = ADFDocumentModel(customRenderers: [ScopePluginRenderer()])
        model.load(data: Data(json.utf8))
        for _ in 0..<500 where model.phase != .ready {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.phase == .ready)
        model.expandedBlocks.formUnion(openExpands)
        let reachesExpands = (allowed ?? TextKit2Scope.containerChildKinds).contains(.expand)
        let document = ADFDocumentView(model: model, mediaProvider: TextKit2DiagnosticsTests.NoMedia(), textRenderer: .textKit2)
            .transformEnvironment(\.adfContainerChildKinds) { kinds in
                if let allowed { kinds = allowed }
            }
        let hosted = TK2CodeLogic.Hosted(document, size: CGSize(width: 390, height: 2_400))
        defer { hosted.close() }
        try await hosted.settle()
        if !openExpands.isEmpty, reachesExpands, TextKit2Eligibility.containerTextMatchesText {
            // The body is prepared off the main actor on first opening.
            for _ in 0..<100 where hosted.rows.isEmpty {
                try await Task.sleep(for: .milliseconds(20))
                hosted.window.layoutIfNeeded()
            }
            try await hosted.settle()
        }
        let rows = hosted.rows
        return (
            Set(rows.compactMap(\.ownerID)),
            Set(rows.filter { $0.containerContext == .container }.compactMap(\.ownerID)),
            Set(rows.filter { $0.containerContext == .none }.compactMap(\.ownerID))
        )
    }

    static func panelJSON(_ body: [String], type: String = "info") -> String {
        "{\"type\":\"panel\",\"attrs\":{\"panelType\":\"\(type)\"},\"content\":[\(body.joined(separator: ","))]}"
    }

    /// Container text drawn on TextKit 2 where the rules pass it: from
    /// iOS 26 (before it nothing below a container draws there).
    static func passing(_ owners: Set<String>) -> Set<String> {
        TextKit2Eligibility.containerTextMatchesText ? owners : []
    }

    @Test("containerUnderRejectedListRow: a quote and a panel in a list item that resets the renderer, and in a list that fails rule B, stay on SwiftUI even with every kind allowed")
    @MainActor
    func containerUnderRejectedListRow() async throws {
        let quote = "{\"type\":\"blockquote\",\"content\":[\(Self.paragraph("Quote in an item."))]}"
        let panel = Self.panelJSON([Self.paragraph("Panel in an item.")])
        let expand = "{\"type\":\"nestedExpand\",\"attrs\":{\"title\":\"E\"},\"content\":[\(Self.paragraph("Expand in an item."))]}"
        let content = [
            // 0.0: an item holding a paragraph, a quote and a panel (rule A:
            // the row resets the renderer below it).
            "{\"type\":\"bulletList\",\"content\":[\(Self.item(Self.paragraph("Item.") + "," + quote + "," + panel))]}",
            // 0.1: a list whose item holds a panel and an expand (rule B).
            "{\"type\":\"bulletList\",\"content\":[\(Self.item(Self.paragraph("Mixed.") + "," + panel + "," + expand)),\(Self.item(Self.paragraph("Plain.")))]}",
            // 0.2: a root quote, the positive control.
            quote,
        ]
        let excluded: Set<String> = ["0.0.0.1.0", "0.0.0.2.0", "0.1.0.1.0", "0.1.0.2.0"]
        for allowed in [nil, Set(TextKit2BlockKind.allCases)] {
            let owners = try await Self.hostedOwners(content, allowed: allowed)
            #expect(owners.all.isDisjoint(with: excluded), "\(String(describing: allowed)): \(owners.all.sorted())")
            #expect(owners.container == Self.passing(["0.2.0"]), "\(String(describing: allowed)): the root quote's paragraph is the control")
        }
    }

    @Test("tableInExpandBody: a table in an open expand body stays on SwiftUI, beside body prose that migrates (expands are allowed from step 5)")
    @MainActor
    func tableInExpandBody() async throws {
        let cell = "{\"type\":\"tableCell\",\"content\":[\(Self.paragraph("In a cell."))]}"
        let table = "{\"type\":\"table\",\"content\":[{\"type\":\"tableRow\",\"content\":[\(cell),\(cell)]}]}"
        // A nested expand in a quote (its boundary reads the allow list),
        // and a top-level expand holding the same body (its row reads the
        // production list, `inheritsRenderer`).
        let nested = "{\"type\":\"nestedExpand\",\"attrs\":{\"title\":\"Open\"},\"content\":[\(Self.paragraph("Expand body prose.")),\(table)]}"
        let root = "{\"type\":\"expand\",\"attrs\":{\"title\":\"Open root\"},\"content\":[\(Self.paragraph("Root expand prose.")),\(table)]}"
        let content = ["{\"type\":\"blockquote\",\"content\":[\(nested)]}", root]
        #expect(TextKit2Scope.containerChildKinds.contains(.expand), "expands are in the production list from step 5")
        // The production list and every kind alike: each body's paragraph
        // migrates, no table cell does.
        for allowed in [nil, Set(TextKit2BlockKind.allCases)] {
            let owners = try await Self.hostedOwners(content, allowed: allowed, openExpands: ["0.0.0", "0.1"])
            #expect(owners.container == Self.passing(["0.0.0.0", "0.1.0"]), "\(String(describing: allowed)): \(owners.all.sorted())")
            #expect(owners.all.allSatisfy { !$0.hasPrefix("0.0.0.1") && !$0.hasPrefix("0.1.1") },
                    "\(String(describing: allowed)): a table cell drew on TextKit 2: \(owners.all.sorted())")
        }
    }

    @Test("pluginBlockInPanel: a plugin block in a panel draws its own view; the panel's paragraph beside it migrates")
    @MainActor
    func pluginBlockInPanel() async throws {
        let plugin = "{\"type\":\"blockCard\",\"attrs\":{\"url\":\"plugin:A plugin's own text\"}}"
        let content = [Self.panelJSON([Self.paragraph("Panel prose beside a plugin."), plugin])]
        for allowed in [nil, Set(TextKit2BlockKind.allCases)] {
            let owners = try await Self.hostedOwners(content, allowed: allowed)
            #expect(owners.all == Self.passing(["0.0.0"]), "\(String(describing: allowed)): \(owners.all.sorted())")
            #expect(!owners.all.contains("0.0.1"))
        }
    }

    @Test("a root heading next to a panel is root text, never container proof: its row has no container context and is not in the container record")
    @MainActor
    func rootHeadingNextToPanel() async throws {
        let heading = "{\"type\":\"heading\",\"attrs\":{\"level\":2},\"content\":[{\"type\":\"text\",\"text\":\"Root heading\"}]}"
        // The panel holds a heading too, so its body stays on SwiftUI.
        let content = [heading, Self.panelJSON([heading, Self.paragraph("Kept on SwiftUI.")])]
        let owners = try await Self.hostedOwners(content)
        #expect(owners.root == ["0.0"])
        #expect(owners.container.isEmpty, "\(owners.container.sorted())")
    }

    @Test("panelShape: each excluded panel shape keeps its whole body on SwiftUI (no row for any owner), as a root panel and nested in a quote; the panels beside it migrate")
    @MainActor
    func excludedPanelShapesDrawNoRow() async throws {
        let excluded = Self.panelShapes.filter { !$0.keeps }
        #expect(excluded.map(\.name) == ["headingPara", "headingAlone", "subsupBeside", "subsupBesideQuote", "nestedList", "listAlone", "taskBeside", "codeBeside", "codeFirst"])
        var content: [String] = []
        for shape in excluded { content.append(Self.panelJSON(shape.body)) }
        // The same shapes inside a quote, after a paragraph of the quote's own.
        for shape in excluded {
            content.append("{\"type\":\"blockquote\",\"content\":[\(Self.paragraph("Quote prose.")),\(Self.panelJSON(shape.body))]}")
        }
        // A panel that keeps the renderer: the control.
        content.append(Self.panelJSON([Self.paragraph("A one-paragraph panel.")]))
        let owners = try await Self.hostedOwners(content)
        let n = excluded.count
        var expected: Set<String> = ["0.\(2 * n).0"]
        for index in n..<(2 * n) { expected.insert("0.\(index).0") }
        #expect(owners.all == Self.passing(expected), "missing \(Self.passing(expected).subtracting(owners.all).sorted()), unexpected \(owners.all.subtracting(Self.passing(expected)).sorted())")
    }
}
#endif
