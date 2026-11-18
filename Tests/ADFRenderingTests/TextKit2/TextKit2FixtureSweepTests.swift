#if canImport(UIKit)
import SwiftUI
import UIKit
import Testing
import ADFModel
import ADFPreparation
@testable import ADFRendering

/// Every TextKit 2-eligible top-level block of the demo's documents must
/// measure on both arms exactly as `Text` does — no exemptions: the parity
/// suites cover the rules, this covers the content they did not think of
/// (`stress-5k` block 503, a superscript wrapping onto a line of its own,
/// measured 3.33 pt short at large and shifted every row below it on a
/// renderer switch). Content the arm cannot match exactly is not eligible
/// (`TextKit2Eligibility`), so it never reaches this check. List text (list
/// leaders and a list row's paragraphs) is swept the same way, and so is
/// every top-level code block the code gate hands to TextKit 2: the block's
/// size and its code's scroll extent (`everyAdmittedCodeRoot`). Container
/// text (paragraphs and headings in panels, quotes and extension bodies) is
/// swept at the widths its containers give it, by height and first and
/// last baseline (`everyEligibleContainerLeaf`).
@Suite("TextKit 2 fixture sweep", .serialized)
@MainActor
struct TextKit2FixtureSweepTests {
    nonisolated static let documents = ["kitchen-sink", "stress-5k", "text-dense"]
    nonisolated static let sizes: [DynamicTypeSize] = [.large, .accessibility3]
    nonisolated static let width: CGFloat = 370
    nonisolated static let tolerance: CGFloat = 0.01
    /// Eligible roots per document (default theme; the same on iOS 18 and
    /// 26 — no root ends in two hard breaks), linked roots included: 1, 507
    /// and 808 of them are TextKit 1-backed. Pinned so a regression that
    /// makes text ineligible cannot pass the sweep by measuring nothing.
    nonisolated static let expectedEligible = ["kitchen-sink": 10, "stress-5k": 2_400, "text-dense": 3_000]

    static func fixtureData(_ name: String) throws -> Data {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() } // …/Tests/ADFRenderingTests/TextKit2 → repo root
        return try Data(contentsOf: url.appendingPathComponent("Fixtures/\(name).json"))
    }

    @Test("every eligible root of the demo documents measures as Text does")
    func everyEligibleRoot() async throws {
        var checked = 0
        var worst: (delta: CGFloat, description: String) = (0, "")
        var fallbacks: [TextKit2Eligibility.Fallback: Int] = [:]
        for document in Self.documents {
            let doc = try await ADFParser().parse(try Self.fixtureData(document))
            let blocks = DocumentPreparer(theme: TK2Parity.theme).prepare(doc)
            var eligible = 0
            for (index, block) in blocks.enumerated() {
                guard case .richText(let segments, let style) = block.kind else { continue }
                let fixture = TK2Parity.Fixture(name: "\(document)#\(index)", segments: segments, style: style)
                if case .fallback(let reason) = TextKit2Eligibility.verdict(segments) {
                    fallbacks[reason, default: 0] += 1
                    continue
                }
                eligible += 1
                for size in Self.sizes {
                    let h = TK2Parity.heights(fixture, size: size, width: Self.width)
                    let delta = abs(h.swiftUI - h.textKit2)
                    let label = "\(fixture.name) \(size)"
                    checked += 1
                    if delta > worst.delta { worst = (delta, "\(label): swiftUI=\(h.swiftUI) textKit2=\(h.textKit2)") }
                    #expect(delta <= Self.tolerance, "\(label): swiftUI=\(h.swiftUI) textKit2=\(h.textKit2)")
                }
            }
            #expect(eligible == Self.expectedEligible[document], "\(document): \(eligible) eligible roots")
        }
        #expect(checked == Self.expectedEligible.values.reduce(0, +) * Self.sizes.count)
        print("TK2 fixture sweep: \(checked) measurements, worst |Δ| = \(worst.delta) \(worst.description); text roots on SwiftUI: \(fallbacks)")
    }

    nonisolated static let listDocuments = ["kitchen-sink", "stress-5k", "lists-parity", "list-dense"]
    /// Eligible list leaves per document: leaders and a row's direct
    /// paragraphs and headings at any depth, in rows that keep the
    /// renderer (`TextKit2Scope`), linked ones included (0, 0, 3 and 586
    /// are TextKit 1-backed). Pinned so a walk that finds no list text, or
    /// text that all falls back, fails here rather than passing by
    /// measuring nothing. From step 6 the walk also reaches list text below
    /// a container: lists-parity's 40 top-level leaves gain the five
    /// leaders of the quote 0.15 (two) and the layout section 0.18 (three);
    /// the other documents hold no list in a container the scope reaches.
    nonisolated static let expectedEligibleListLeaves = ["kitchen-sink": 8, "stress-5k": 7_543, "lists-parity": 45, "list-dense": 3_537]

    /// The leader as `ListRowView` hosts it, on one arm.
    static func leaderHeight(_ segments: [InlineSegment], arm: ADFTextRenderer, size: DynamicTypeSize, width: CGFloat) -> CGFloat {
        let leader = TextEngineLeaf(segments: segments, style: ListRowView.leaderStyle(theme: TK2Parity.theme), ownerID: nil) {
            SegmentedTextView(segments: segments).textSelection(.enabled)
        }
        let host = UIHostingController(rootView: leader
            .environment(\.adfTextRenderer, arm)
            .environment(\.adfTheme, TK2Parity.theme)
            .dynamicTypeSize(size))
        host.safeAreaRegions = []
        return host.sizeThatFits(in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)).height
    }

    /// The same leaf drawn as list text: a leader as the list row hosts it,
    /// a row's paragraph or heading as `RichTextBlockView`. Measured at the
    /// sweep width (the list's own column widths are the hosted list
    /// parity's), each distinct (text, style) once. From iOS 26: before it
    /// lists keep their text on SwiftUI (`TextKit2Eligibility.listsMatchText`).
    @Test("every eligible list leaf of the demo documents measures as Text does",
          .enabled(if: TextKit2Eligibility.listsMatchText, "before iOS 26 lists keep their text on SwiftUI"))
    func everyEligibleListLeaf() async throws {
        struct Key: Hashable {
            let segments: [InlineSegment]
            let style: TextBlockStyle?
        }
        var checked = 0
        var worst: (delta: CGFloat, description: String) = (0, "")
        var fallbacks: [TextKit2Eligibility.Fallback: Int] = [:]
        for document in Self.listDocuments {
            let doc = try await ADFParser().parse(try Self.fixtureData(document))
            let blocks = DocumentPreparer(theme: TK2Parity.theme).prepare(doc)
            var leaves: [TextKit2Scope.Leaf] = []
            // List text only: the walk also visits top-level code blocks
            // (`.codeRoot`: kitchen-sink 1, stress-5k 400), which are not
            // list leaves and carry no segments to measure here
            // (`everyAdmittedCodeRoot` sweeps them).
            TextKit2Scope.forEachLeaf(in: blocks) { leaf in
                if leaf.position.ownerKind == .list { leaves.append(leaf) }
            }
            var eligible = 0
            var measured: Set<Key> = []
            for leaf in leaves {
                if case .fallback(let reason) = leaf.verdict {
                    fallbacks[reason, default: 0] += 1
                    continue
                }
                eligible += 1
                guard measured.insert(Key(segments: leaf.segments, style: leaf.style)).inserted else { continue }
                for size in Self.sizes {
                    let h: (swiftUI: CGFloat, textKit2: CGFloat)
                    if let style = leaf.style {
                        h = TK2Parity.heights(TK2Parity.Fixture(name: leaf.ownerID, segments: leaf.segments, style: style), size: size, width: Self.width)
                    } else {
                        h = (Self.leaderHeight(leaf.segments, arm: .swiftUI, size: size, width: Self.width),
                             Self.leaderHeight(leaf.segments, arm: .textKit2, size: size, width: Self.width))
                    }
                    let delta = abs(h.swiftUI - h.textKit2)
                    let label = "\(document) \(leaf.ownerID) (\(leaf.position)) \(size): swiftUI=\(h.swiftUI) textKit2=\(h.textKit2)"
                    checked += 1
                    if delta > worst.delta { worst = (delta, label) }
                    #expect(delta <= Self.tolerance, "\(label)")
                }
            }
            #expect(eligible == Self.expectedEligibleListLeaves[document], "\(document): \(eligible) eligible list leaves")
            #expect(!measured.isEmpty, "\(document): no list leaf measured")
            print("TK2 list sweep \(document): \(eligible) eligible list leaves, \(measured.count) distinct measured")
        }
        #expect(checked > 0)
        print("TK2 list sweep: \(checked) measurements, worst |Δ| = \(worst.delta) \(worst.description); list text on SwiftUI: \(fallbacks)")
    }

    // MARK: Container leaves

    nonisolated static let containerDocuments = ["containers-parity", "kitchen-sink", "stress-1k", "stress-5k"]
    /// Container leaves in scope per document (step 3: paragraphs and
    /// headings in panels, quotes and bodied extensions; step 4: and in
    /// layout columns; step 6: list text in those but panels), as
    /// hand-counted from the JSON (`TextKit2ContainerCoverageTests.fixturePins`;
    /// containers-parity 64 prose leaves and 16 list leaders, its 0.64,
    /// 0.65, 0.67 and 0.68; stress-5k 400 one-paragraph panels and 400
    /// quotes of 606 paragraphs, its layout sections all in expand bodies),
    /// with the eligible ones (containers-parity has two atom paragraphs).
    nonisolated static let expectedContainerLeaves: [String: (leaves: Int, eligible: Int)] = [
        "containers-parity": (80, 78), "kitchen-sink": (11, 11), "stress-1k": (199, 199), "stress-5k": (1_006, 1_006),
    ]
    /// The document widths whose rows (16 pt in from each side) the
    /// container leaves are swept in: the iPhone widths, 320 (SE, first
    /// generation; Slide Over), 375, 390, 393, 402, 414, 430 and 440 pt
    /// (code review F-R4).
    nonisolated static let containerDocumentWidths: [CGFloat] = [320, 375, 390, 393, 402, 414, 430, 440]
    /// The text sizes the container leaves are swept at: xSmall to AX3,
    /// every size the container size rule (`containerSizeKeepsRenderer`)
    /// keeps on TextKit 2. Swept at AX4 and AX5 (code review F-R4, F-Q1),
    /// panel bodies 183 to 271 pt wide and quote bodies near 268 pt broke
    /// long words apart, so from AX4 every container keeps its body on
    /// SwiftUI. `ADF_SWEEP_CONTAINER_SIZES=<name,…>`
    /// (`DynamicTypeSize` case names) replaces the sizes; a size the rule
    /// keeps on SwiftUI is then measured and its misses printed
    /// (`TK2_CONTAINER_SWEEP_RULE`), not asserted: the rule's evidence,
    /// reproducible. List text is swept below the accessibility sizes only
    /// (`nestedListSizeKeepsRenderer`).
    nonisolated static var containerSizes: [DynamicTypeSize] {
        let names = ProcessInfo.processInfo.environment["ADF_SWEEP_CONTAINER_SIZES"]?.split(separator: ",").map(String.init) ?? []
        let sizes = names.compactMap { name in DynamicTypeSize.allCases.first { "\($0)" == name } }
        return sizes.isEmpty ? DynamicTypeSize.allCases.filter(TextKit2Scope.containerSizeKeepsRenderer) : sizes
    }
    /// A fine grid of child widths around the one width D3 was measured at
    /// in a body (a 271.667 pt panel body at AX5, `probes/results.md` §D3):
    /// 268 to 276 pt in steps of a third of a point, for every distinct
    /// container prose leaf whatever its container, at Large, AX4 and AX5
    /// (or the sizes `ADF_SWEEP_FINE_SIZES=<name,…>` names) where the sizes
    /// include them (`ADF_SWEEP_CONTAINER_SIZES`): Large by default. The
    /// steps are sums a few ulps off the pixel grid, as a panel's child
    /// width is: D3's cause (a row re-proposed the next pixel it reported,
    /// `TextKit2RowView.layoutResult(forProposedWidth:)`), which put quote
    /// and column leaves a line low at Large here too.
    nonisolated static let d3FineWidths: [CGFloat] = (0...24).map { 268 + CGFloat($0) / 3 }
    nonisolated static var d3FineSizes: [DynamicTypeSize] {
        let names = ProcessInfo.processInfo.environment["ADF_SWEEP_FINE_SIZES"]?.split(separator: ",").map(String.init) ?? []
        let sizes = names.compactMap { name in DynamicTypeSize.allCases.first { "\($0)" == name } }
        return sizes.isEmpty ? [.large, .accessibility4, .accessibility5] : sizes
    }
    /// Whether the fine grid takes list text too (`ADF_SWEEP_FINE_LISTS=1`):
    /// evidence for PR 2's list leaf at off-grid widths, which the row fix
    /// leaves out (`.list` rows lay out anew when re-proposed). Its misses
    /// print as `TK2_CONTAINER_SWEEP_LIST_FINE` and are not asserted.
    nonisolated static var fineGridLists: Bool { ProcessInfo.processInfo.environment["ADF_SWEEP_FINE_LISTS"] == "1" }

    /// The first and last text baselines and height of `view` laid out at
    /// `width` as a baseline-aligned parent reads them (`TK2Parity.guides`).
    @MainActor
    static func guides(_ view: some View, width: CGFloat) -> (first: CGFloat, last: CGFloat, height: CGFloat) {
        let box = TK2Parity.GuideBox()
        let root = VStack(alignment: .leading, spacing: 0) {
            view.alignmentGuide(.leading) { dimensions in
                let first = dimensions[.firstTextBaseline]
                let last = dimensions[.lastTextBaseline]
                let height = dimensions.height
                MainActor.assumeIsolated {
                    box.first = first
                    box.last = last
                    box.height = height
                }
                return dimensions[.leading]
            }
        }
        .frame(width: width, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 4_000))
        let host = UIHostingController(rootView: root)
        host.safeAreaRegions = []
        window.rootViewController = host
        window.isHidden = false
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        window.isHidden = true
        window.rootViewController = nil
        return (box.first, box.last, box.height)
    }

    /// The list leader as `ListRowView` hosts it, on one arm (`leaderHeight`).
    @MainActor
    static func leader(_ segments: [InlineSegment], arm: ADFTextRenderer, size: DynamicTypeSize) -> some View {
        TextEngineLeaf(segments: segments, style: ListRowView.leaderStyle(theme: TK2Parity.theme), ownerID: nil) {
            SegmentedTextView(segments: segments).textSelection(.enabled)
        }
        .environment(\.adfTextRenderer, arm)
        .environment(\.adfTheme, TK2Parity.theme)
        .dynamicTypeSize(size)
    }

    /// One leaf's guides on both arms at `width` and `size`: a paragraph or
    /// heading as `RichTextBlockView`, a leader (`style` `nil`) as the list
    /// row hosts it.
    @MainActor
    static func leafGuides(
        _ segments: [InlineSegment], style: TextBlockStyle?, name: String, size: DynamicTypeSize, width: CGFloat
    ) -> (swiftUI: (first: CGFloat, last: CGFloat, height: CGFloat), textKit2: (first: CGFloat, last: CGFloat, height: CGFloat)) {
        if let style {
            let fixture = TK2Parity.Fixture(name: name, segments: segments, style: style)
            let env = TK2Parity.Environment(size: size)
            return (TK2Parity.guides(fixture, arm: .swiftUI, env: env, width: width), TK2Parity.guides(fixture, arm: .textKit2, env: env, width: width))
        }
        return (guides(leader(segments, arm: .swiftUI, size: size), width: width), guides(leader(segments, arm: .textKit2, size: size), width: width))
    }

    /// One container a leaf sits in, outermost first: what it takes from
    /// the width it is given (`PanelBlockView`: padding on both sides, the
    /// stack spacing and its icon; `QuoteBlockView`: its leading inset;
    /// the extension body: its inset; a layout column, stacked as on these
    /// phone widths: nothing, each column is proposed the section's width;
    /// a list row: its depth padding, decision padding, marker column and
    /// gap, `ListRowView.textColumnInset`).
    enum Inset: Hashable {
        case panel(symbol: String)
        case quote
        case extensionBody
        case stackedColumn
        case listRow(depth: Int, decision: Bool)

        @MainActor
        func points(_ env: TK2Parity.Environment) -> CGFloat {
            let spacing = TK2Parity.theme.spacing
            switch self {
            case .panel(let symbol): return spacing * 4.5 + TK2ContainerProbe.iconWidth(symbol, env: env)
            case .quote: return spacing * 2
            case .extensionBody: return spacing * 3
            case .stackedColumn: return 0
            case .listRow(let depth, let decision):
                let marker = TextKit2ListParityTests.markerWidth(env.size)
                return CGFloat(depth) * (marker + spacing) + (decision ? 2 * spacing : 0) + marker + spacing
            }
        }
    }

    /// The paragraphs, headings and list text below panels, quotes,
    /// extension bodies and layout columns in `blocks`, with the containers
    /// above each, outermost first, and for list text its row last (a
    /// leader has no block style: `nil`).
    @MainActor
    static func containerChains(_ blocks: [RenderBlock], chain: [Inset] = []) -> [String: (segments: [InlineSegment], style: TextBlockStyle?, chain: [Inset])] {
        var found: [String: (segments: [InlineSegment], style: TextBlockStyle?, chain: [Inset])] = [:]
        for block in blocks {
            switch block.kind {
            case .richText(let segments, let style): if !chain.isEmpty { found[block.id] = (segments, style, chain) }
            case .listRows(let rows) where !chain.isEmpty:
                for row in rows {
                    let rowChain = chain + [.listRow(depth: row.depth, decision: TextKit2ListParityTests.isDecision(row))]
                    if !row.segments.isEmpty { found[row.id] = (row.segments, nil, rowChain) }
                    for trailing in row.trailingBlocks {
                        if case .richText(let segments, let style) = trailing.kind { found[trailing.id] = (segments, style, rowChain) }
                    }
                }
            case .panel(let palette, let children): found.merge(containerChains(children, chain: chain + [.panel(symbol: palette.iconSystemName)])) { a, _ in a }
            case .quote(let children): found.merge(containerChains(children, chain: chain + [.quote])) { a, _ in a }
            case .extensionPlaceholder(_, let body): found.merge(containerChains(body, chain: chain + [.extensionBody])) { a, _ in a }
            case .layoutColumns(let columns): found.merge(containerChains(columns.flatMap(\.blocks), chain: chain + [.stackedColumn])) { a, _ in a }
            default: continue
            }
        }
        return found
    }

    /// Every container leaf the production scope hands to TextKit 2, swept
    /// at the width its containers actually give it (the row width less
    /// each container's inset, the panel's icon measured at that size, and
    /// for list text its row's inset; a list leader hosted as the list row
    /// hosts it), comparing the height and the first and last baselines
    /// within 0.01 pt (code review F-R4: D3's signature is a baseline shift
    /// at an equal height, which a height alone cannot see; PR 1's
    /// one-pixel last-baseline residual is recorded apart). Document widths
    /// `containerDocumentWidths`, sizes `containerSizes`, and the fine grid
    /// `d3FineWidths` at `d3FineSizes`; each distinct (text, style, width,
    /// size) once over all documents. A width under 1 pt stays on SwiftUI
    /// (rule D, the under-1-pt guard) and is not measured. Before iOS 26
    /// container text is gated: every leaf must fall back as
    /// `osGatedContainer` (list text as `osGatedList`), which the sweep
    /// asserts instead of measuring.
    @Test("every eligible container leaf of the demo documents measures and sits as Text does at its effective child width (height, first and last baseline)")
    func everyEligibleContainerLeaf() async throws {
        struct Key: Hashable {
            let segments: [InlineSegment]
            let style: TextBlockStyle?
            let width: CGFloat
            let size: DynamicTypeSize
        }
        let clock = ContinuousClock()
        let start = clock.now
        var checked = 0
        var residual1 = 0
        var worst: (delta: CGFloat, description: String) = (0, "")
        var widthsSeen: Set<CGFloat> = []
        var measured: Set<Key> = []
        var failures: [String] = []
        var ruleMisses = 0
        let onePixel = 1 / TK2Parity.nativeScale
        var listFine = (checked: 0, misses: 0, d3: 0)
        func measure(_ entry: (segments: [InlineSegment], style: TextBlockStyle?, chain: [Inset]), owner: String, document: String, width: CGFloat, size: DynamicTypeSize, listFineGrid: Bool = false) {
            guard width >= TextKit2Scope.minimumTextWidth else { return }
            guard measured.insert(Key(segments: entry.segments, style: entry.style, width: width, size: size)).inserted else { return }
            widthsSeen.insert(width)
            // Each measurement's windows and hosts released, and their layers
            // committed, as it ends: tens of thousands left to the end of the
            // loop made one autorelease pool drain (each host removing its
            // notification observers) and then one Core Animation commit
            // run past 10 minutes each.
            let g = autoreleasepool { Self.leafGuides(entry.segments, style: entry.style, name: owner, size: size, width: width) }
            CATransaction.flush()
            let dHeight = abs(g.swiftUI.height - g.textKit2.height)
            let dFirst = abs(g.swiftUI.first - g.textKit2.first)
            var dLast = abs(g.swiftUI.last - g.textKit2.last)
            if dLast > Self.tolerance, abs(g.swiftUI.last - g.textKit2.last - onePixel) <= Self.tolerance {
                residual1 += 1
                dLast = 0
            }
            let delta = max(dHeight, dFirst, dLast)
            let label = "\(document) \(owner) in \(entry.chain) \(size) W=\(String(format: "%.3f", width)): h=\(g.swiftUI.height)/\(g.textKit2.height) first=\(g.swiftUI.first)/\(g.textKit2.first) last=\(g.swiftUI.last)/\(g.textKit2.last)"
            let signature = dHeight <= Self.tolerance && dFirst > Self.tolerance ? "d3Signature " : ""
            if listFineGrid {
                // Evidence only (`fineGridLists`).
                listFine.checked += 1
                guard delta > Self.tolerance else { return }
                listFine.misses += 1
                if !signature.isEmpty { listFine.d3 += 1 }
                print("TK2_CONTAINER_SWEEP_LIST_FINE \(signature)\(label)")
                return
            }
            checked += 1
            if delta > worst.delta { worst = (delta, label) }
            guard delta > Self.tolerance else { return }
            if TextKit2Scope.containerSizeKeepsRenderer(size) {
                failures.append(label)
                print("TK2_CONTAINER_SWEEP_MISS \(signature)\(label)")
            } else {
                // On SwiftUI in production (the container size rule):
                // recorded as the rule's evidence.
                ruleMisses += 1
                print("TK2_CONTAINER_SWEEP_RULE \(signature)\(label)")
            }
        }
        for document in Self.containerDocuments {
            let doc = try await ADFParser().parse(try Self.fixtureData(document))
            let blocks = DocumentPreparer(theme: TK2Parity.theme).prepare(doc)
            var leaves: [TextKit2Scope.Leaf] = []
            TextKit2Scope.forEachLeaf(in: blocks) { leaf in
                if [.containerProse, .containerListLeader, .containerListTrailing].contains(leaf.position) { leaves.append(leaf) }
            }
            let chains = Self.containerChains(blocks)
            let pin = try #require(Self.expectedContainerLeaves[document])
            #expect(leaves.count == pin.leaves, "\(document): \(leaves.count) container leaves")
            var eligible = 0
            var gated = 0
            let before = measured.count
            for leaf in leaves {
                switch leaf.verdict {
                case .fallback(.osGatedContainer), .fallback(.osGatedList): gated += 1; continue
                case .fallback: continue
                case .eligible: eligible += 1
                }
                let entry = try #require(chains[leaf.ownerID], "\(document) \(leaf.ownerID): no container chain")
                let isList = leaf.position != .containerProse
                for size in Self.containerSizes {
                    // A nested list stays on SwiftUI at the accessibility sizes.
                    if isList, !TextKit2Scope.nestedListSizeKeepsRenderer(size) { continue }
                    let env = TK2Parity.Environment(size: size)
                    let inset = entry.chain.reduce(0) { $0 + $1.points(env) }
                    for documentWidth in Self.containerDocumentWidths {
                        measure(entry, owner: leaf.ownerID, document: document, width: documentWidth - 4 * TK2Parity.theme.spacing - inset, size: size)
                    }
                }
                if isList {
                    guard Self.fineGridLists else { continue }
                    for size in Self.d3FineSizes where Self.containerSizes.contains(size) && TextKit2Scope.nestedListSizeKeepsRenderer(size) {
                        for width in Self.d3FineWidths { measure(entry, owner: leaf.ownerID, document: document, width: width, size: size, listFineGrid: true) }
                    }
                    continue
                }
                for size in Self.d3FineSizes where Self.containerSizes.contains(size) {
                    for width in Self.d3FineWidths { measure(entry, owner: leaf.ownerID, document: document, width: width, size: size) }
                }
            }
            if TextKit2Eligibility.containerTextMatchesText {
                #expect(eligible == pin.eligible && gated == 0, "\(document): \(eligible) eligible container leaves")
            } else {
                #expect(eligible == 0 && gated == pin.eligible, "\(document): before iOS 26 \(gated) gated, \(eligible) eligible")
            }
            print("TK2 container sweep \(document): \(leaves.count) container leaves, \(eligible) eligible, \(gated) gated, \(measured.count - before) new distinct measured")
        }
        if TextKit2Eligibility.containerTextMatchesText { #expect(checked > 0, "no container leaf measured") }
        if Self.fineGridLists {
            print("TK2 container sweep list fine grid: \(listFine.checked) measurements, \(listFine.misses) misses, \(listFine.d3) with the d3 signature")
        }
        print("TK2 container sweep: \(checked) measurements at \(widthsSeen.count) child widths, \(failures.count) misses, \(ruleMisses) under the size rule, residual1 \(residual1), worst |Δ| = \(worst.delta) \(worst.description); elapsed \(clock.now - start)")
        #expect(failures.isEmpty, "\(failures.count) container leaves miss Text's height or baselines: \(failures.prefix(6))")
    }

    // MARK: Code roots

    nonisolated static let codeDocuments = ["kitchen-sink", "stress-5k", "code-dense", "code-parity"]
    /// Top-level code blocks eligible by content, as `TextKit2CodeCoverageTests`
    /// pins them from a hand count of the JSON: non-empty printable ASCII and
    /// line feeds with no trailing line feed, so eligible on every OS. The
    /// generated code fixtures get their hand-counted pins in that suite;
    /// here they rest on the sums against the production counts and on the
    /// floor of one measured root per text size.
    nonisolated static let expectedEligibleCodeRoots = ["kitchen-sink": 1, "stress-5k": 400]

    /// One arm's sizes of a hosted code block at the sweep width.
    struct CodeSizes {
        /// The whole block: header, padding and box.
        let view: CGSize
        /// The horizontal scroll view's content: the code's natural size
        /// plus padding. The view takes the column's width whatever the
        /// code's, so a line measured short or long shows only here.
        let content: CGSize
        /// TextKit 2 rows in the block, and the owners of those drawing code.
        let rows: Int
        let codeOwners: [String]
    }

    /// A code block as a document row hosts it (`TK2Parity.hostedCode`: the
    /// real `BlockView` → `CodeBlockView`), sized on one arm the way
    /// `TK2CodeParity.measure` takes its sizes, without its bitmaps: pixels
    /// are the E2 matrix's to prove, and rendering every code-dense block at
    /// its natural width would cost minutes. Both steps run in a window, so
    /// the code gate reads the device's display scale, the scale the sweep
    /// admits at (`TK2Parity.attachedSize`).
    static func codeSizes(_ block: RenderBlock, arm: ADFTextRenderer, size: DynamicTypeSize) async throws -> CodeSizes {
        let view = TK2Parity.hostedCode(block, arm: arm, env: TK2Parity.Environment(size: size))
        let viewSize = TK2Parity.attachedSize(view, width: Self.width)
        let host = TK2Parity.Host(view, width: Self.width, height: max(viewSize.height.rounded(.up) + 16, 64))
        defer { host.close() }
        // A scroll view can take a run-loop turn to size its content.
        try await host.settle()
        guard let scroll = TK2Parity.scrollViews(in: host.view).first else {
            throw TestFailure("\(block.id) \(arm) \(size): no horizontal scroll view")
        }
        let rows = TextKit2FallbackTests.rows(in: host.view)
        return CodeSizes(
            view: viewSize, content: scroll.contentSize, rows: rows.count,
            codeOwners: rows.filter { $0.ownerKind == .code }.compactMap { $0.ownerID }
        )
    }

    /// Every top-level code block the production scope hands to TextKit 2
    /// at the sweep's text sizes on this device: eligible by content (the
    /// coverage walk's verdict, `TextKit2Eligibility.codeVerdict`) and
    /// admitted by the code gate (`TextKit2Scope.codeGate`: left to right,
    /// within the canvas bound at that size and display scale, and before
    /// iOS 26 no interior empty line above AX3). Each must
    /// be one TextKit 2 code row on that arm and none on the other, and
    /// match `Text` within 0.01 pt in the block's height and width and in
    /// its scroll content's width and height. No exemptions: code the gate
    /// or the content rules keep on SwiftUI is counted, not measured, and
    /// the counts must add up to the top-level code blocks and agree with
    /// the app's own admission counts, so nothing leaves the sweep unseen.
    /// Breakout is the document row's (`blockBreakout`), outside `BlockView`:
    /// it widens the viewport, not the code, so it is not in these sizes.
    @Test("every admitted code root of the demo documents measures as Text does")
    func everyAdmittedCodeRoot() async throws {
        let scale = TK2Parity.nativeScale
        let scaleText = TK2CodeParity.scaleText(scale)
        var checked = 0
        var worst: (delta: CGFloat, description: String) = (0, "")
        for document in Self.codeDocuments {
            let doc = try await ADFParser().parse(try Self.fixtureData(document))
            let blocks = DocumentPreparer(theme: TK2Parity.theme).prepare(doc)
            let codeBlocks = blocks.filter { TextKit2CodeCoverageTests.isCode($0) }
            try #require(!codeBlocks.isEmpty, "\(document): no top-level code block")
            var leaves: [TextKit2Scope.Leaf] = []
            TextKit2Scope.forEachLeaf(in: blocks) { leaf in
                if leaf.position == .codeRoot { leaves.append(leaf) }
            }
            // The walk must visit each top-level code block (found here by
            // kind) once and in order: then none is skipped, and each leaf
            // pairs with the block hosted for it.
            try #require(leaves.map(\.ownerID) == codeBlocks.map(\.id),
                          "\(document): \(leaves.count) code roots, \(codeBlocks.count) top-level code blocks")

            var eligible: [(block: RenderBlock, code: AttributedString)] = []
            var fallbacks: [TextKit2Eligibility.Fallback: Int] = [:]
            for (block, leaf) in zip(codeBlocks, leaves) {
                switch leaf.verdict {
                case .eligible(let code): eligible.append((block: block, code: code))
                case .fallback(let reason): fallbacks[reason, default: 0] += 1
                }
            }
            let fallbackCount = fallbacks.values.reduce(0, +)
            let coverage = ADFTextRenderer.textKit2Coverage(of: blocks)
            #expect(coverage.eligibleCodeRoots == eligible.count, "\(document): eligibleCodeRoots \(coverage.eligibleCodeRoots), walk \(eligible.count)")
            #expect(coverage.fallbackCodeRoots == fallbackCount, "\(document): fallbackCodeRoots \(coverage.fallbackCodeRoots), walk \(fallbackCount)")
            if let pinned = Self.expectedEligibleCodeRoots[document] {
                #expect(eligible.count == pinned, "\(document): \(eligible.count) eligible code roots")
            }

            for size in Self.sizes {
                // What the app reports for this environment (`codeAdmitted=`,
                // `codeGated=`): the sweep's own split must agree with it.
                let admission = ADFTextRenderer.textKit2CodeAdmission(
                    of: blocks, dynamicTypeSize: size, legibilityWeight: nil, displayScale: scale, layoutDirection: .leftToRight
                )
                var measured = 0
                var gated: [TextKit2Scope.CodeGate: Int] = [:]
                for (block, code) in eligible {
                    if let gate = TextKit2Scope.codeGate(
                        code, sizeCategory: size.uiContentSizeCategory, legibilityWeight: nil,
                        displayScale: scale, layoutDirection: .leftToRight
                    ) {
                        gated[gate, default: 0] += 1
                        continue
                    }
                    let label = "\(document) \(block.id) \(size) @\(scaleText)x"
                    let a = try await Self.codeSizes(block, arm: .swiftUI, size: size)
                    let b = try await Self.codeSizes(block, arm: .textKit2, size: size)
                    // Without these the sizes below could compare `Text` with itself.
                    #expect(a.rows == 0, "\(label): the SwiftUI arm holds \(a.rows) TextKit 2 rows")
                    #expect(b.rows == 1 && b.codeOwners == [block.id], "\(label): \(b.rows) TextKit 2 rows, code rows owned by \(b.codeOwners)")
                    let pairs: [(name: String, swiftUI: CGFloat, textKit2: CGFloat)] = [
                        ("height", a.view.height, b.view.height),
                        ("width", a.view.width, b.view.width),
                        ("scroll content width", a.content.width, b.content.width),
                        ("scroll content height", a.content.height, b.content.height),
                    ]
                    for pair in pairs {
                        let delta = abs(pair.swiftUI - pair.textKit2)
                        let description = "\(label) \(pair.name): swiftUI=\(pair.swiftUI) textKit2=\(pair.textKit2)"
                        if delta > worst.delta { worst = (delta, description) }
                        #expect(delta <= Self.tolerance, "\(description)")
                    }
                    measured += 1
                    checked += 1
                }
                let gatedCount = gated.values.reduce(0, +)
                let counts = "\(measured) measured, \(gatedCount) gated, \(fallbackCount) content fallbacks, \(codeBlocks.count) top-level code blocks"
                #expect(measured + gatedCount == coverage.eligibleCodeRoots, "\(document) \(size): \(counts), \(coverage.eligibleCodeRoots) eligible")
                #expect(measured + gatedCount + fallbackCount == codeBlocks.count, "\(document) \(size): \(counts)")
                #expect(measured == admission.admittedCodeRoots && gatedCount == admission.gatedCodeRoots,
                        "\(document) \(size): \(counts); the app counts \(admission.admittedCodeRoots) admitted, \(admission.gatedCodeRoots) gated")
                #expect(measured > 0, "\(document) \(size): no code root admitted, so none was measured")
                print("TK2 code sweep \(document) \(size) @\(scaleText)x os=\(TK2Parity.osVersion): \(codeBlocks.count) top-level code blocks, "
                    + "\(eligible.count) eligible, \(admission.admittedCodeRoots) admitted, \(measured) measured, "
                    + "\(gatedCount) gated (canvas \(gated[.canvas, default: 0]), direction \(gated[.direction, default: 0]), "
                    + "empty lines \(gated[.osGatedEmptyLines, default: 0])), "
                    + "\(fallbackCount) content fallbacks \(fallbacks)")
            }
        }
        #expect(checked > 0)
        print("TK2 code sweep: \(checked) code roots measured on both arms, worst |Δ| = \(worst.delta) \(worst.description)")
    }
}
#endif
