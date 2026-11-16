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
/// (`inheritsRenderer`); and the view-time rules (`containerGate`). The
/// production allow list is empty at this stage, so no container child
/// keeps TextKit 2 in the app. Cross-platform.
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
    /// a panel always, until the panel shapes are decided; an extension
    /// with a body; no caption yet; tables, plugins, dividers, media
    /// strips, cards and unknown nodes never.
    static func expectedWholeBlock(_ kind: RenderBlock.Kind) -> Bool {
        switch kind {
        case .richText, .codeBlock, .quote, .expand, .layoutColumns: return true
        case .listRows(let rows): return TextKit2Scope.listKeepsRenderer(rows)
        case .panel: return true
        case .extensionPlaceholder(_, let body): return !body.isEmpty
        case .media: return false
        case .divider, .tableSlice, .mediaStrip, .card, .custom, .unknown: return false
        }
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

    @Test("top-level rows read the same allow list and whole-block rules; the production list is empty, so every container row stays SwiftUI")
    func topLevelRowsReadTheAllowList() async throws {
        // Step 2: no family is enabled. Each later stage changes this pin
        // deliberately, with the family it enables.
        #expect(TextKit2Scope.containerChildKinds.isEmpty)
        #expect(EnvironmentValues().adfContainerChildKinds == TextKit2Scope.containerChildKinds)
        #expect(EnvironmentValues().adfTextContainerContext == .none)
        #expect(TextKit2Scope.captionsUseTextKit2 == false)

        let samples = try await Self.samples()
        for sample in samples {
            let family = Self.family(sample.kind)
            // In the app (the production list): PR 3's rows only.
            let pr3: Bool
            switch sample.kind {
            case .richText, .codeBlock: pr3 = true
            case .listRows(let rows): pr3 = TextKit2Scope.listKeepsRenderer(rows)
            default: pr3 = false
            }
            #expect(TextKit2Scope.inheritsRenderer(sample.kind) == pr3, "\(sample.id) \(family)")
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
