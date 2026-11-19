#if canImport(UIKit)
import SwiftUI
import UIKit
import Testing
import ADFModel
import ADFPreparation
@testable import ADFRendering

// Container text on TextKit 2 through the production path (PR 4 step 3):
// the real `BlockView(block:)` of a panel, a quote, a bodied extension and
// of those nested in one another, hosted with the production container
// allow list (`TextKit2Scope.containerChildKinds`, nothing widened) and the
// row's width bound, on both renderers. Unlike the step 1a probes these
// assert: every shape that migrates matches SwiftUI within 0.01 pt in
// height and first and last baseline (PR 1's one-pixel last-baseline
// residual aside) and passes the pixel comparison of PR 2's rows; a pixel
// difference counts as the leaf's, not the container's, only where the
// same blocks hosted alone at the container's child width, with the
// renderer the container gives each, differ too (probe call C1). A shape
// the scope rules keep on SwiftUI (`panelKeepsRenderer`) must draw no
// TextKit 2 row at all.
//
// The matrix is the probes' (`TK2ContainerProbe`): a small sample by
// default, `ADF_CONTAINER_PROBES=family|full` at the test runner for the
// sampled and full matrices of plan §7.3. Before iOS 26 container text is
// gated (`TextKit2Eligibility.containerTextMatchesText`): the suites assert
// that no container leaf draws through TextKit 2, they do not skip.
//
// Each case prints `CONTAINER_PARITY test=… container=… shape=… size=… bold=…
// dir=… W=… result=pass|fail …`, and each group a `CONTAINER_PARITY_SUMMARY`.

/// The shapes and expectations of the step 3 parity suites. Not a suite.
enum TK2ContainerBody {
    typealias P = TK2ContainerProbe

    /// A container body (or a whole nested document) and whether its text
    /// reaches TextKit 2 under the production rules from iOS 26.
    struct Shape: Sendable {
        let name: String
        let body: [String]
        let migrates: Bool
    }

    static var codeBlock: String {
        "{\"type\":\"codeBlock\",\"content\":[\(P.t("let total = items.reduce(0, +)\nprint(total)"))]}"
    }

    /// The probe shapes (`TK2ContainerProbe.allShapes`) plus prose beside a
    /// code block (the fixtures hold it: containers-parity 0.71, 0.77,
    /// 0.78). A panel keeps a heading, a list, a code block and a
    /// superscript or small-text run beside another block on SwiftUI
    /// (`panelKeepsRenderer`); in a quote or an extension body nothing
    /// does: lists joined at step 6 and, from PR 4 step 7, the code block
    /// there draws on TextKit 2 too, left to right (`expectedCode`).
    static func shapes(for container: P.Container) -> [Shape] {
        let probe = Dictionary(uniqueKeysWithValues: P.allShapes.map { ($0.name, $0.body) })
        let codeBeside = [P.paragraph(P.t(P.words(14, from: 3))), codeBlock, P.paragraph(P.t(P.words(5, from: 11)))]
        let panelExcluded: Set<String> = ["headingPara", "subsupBeside", "nestedList"]
        var shapes = ["onePara", "bodyParas", "headingPara", "subsupBeside", "nestedList", "nestedQuote", "subsupAlone"].map { name in
            Shape(name: name, body: probe[name]!, migrates: container != .panel || !panelExcluded.contains(name))
        }
        // A code block beside prose keeps a panel on SwiftUI: main's panel
        // cuts the code block (the step 3 parity run); a quote and an
        // extension body match.
        shapes.append(Shape(name: "codeBeside", body: codeBeside, migrates: container != .panel))
        return shapes.filter { only?.contains($0.name) ?? true }
    }

    /// `ADF_CONTAINER_PROBES_SHAPES=<name,…>` limits every matrix to the
    /// named shapes.
    static var only: Set<String>? {
        ProcessInfo.processInfo.environment["ADF_CONTAINER_PROBES_SHAPES"].map { Set($0.split(separator: ",").map(String.init)) }
    }

    /// Containers nested in one another, as whole top-level blocks (plan
    /// §5 step 3: panel in quote, quote in panel, panel in extension), with
    /// a heading beside the inner container and a panel whose own body
    /// stays on SwiftUI inside a quote that migrates.
    static var nestedShapes: [(shape: Shape, outer: P.Container)] {
        let p = { (count: Int, from: Int) in P.paragraph(P.t(P.words(count, from: from))) }
        let heading = P.heading(3, P.words(5, from: 4))
        let all: [(Shape, P.Container)] = [
            (Shape(name: "panelInQuote", body: [P.quote([p(16, 0), P.panel([p(22, 5)])])], migrates: true), .quote),
            (Shape(name: "headingPanelInQuote", body: [P.quote([heading, P.panel([p(18, 2)], type: "note"), p(9, 7)])], migrates: true), .quote),
            (Shape(name: "excludedPanelInQuote", body: [P.quote([p(12, 1), P.panel([heading, p(14, 3)], type: "tip")])], migrates: true), .quote),
            (Shape(name: "quoteInPanel", body: [P.panel([p(14, 6), P.quote([p(20, 9)])])], migrates: true), .panel),
            (Shape(name: "quoteHeadingInPanel", body: [P.panel([P.quote([heading, p(18, 12)])])], migrates: true), .panel),
            (Shape(name: "panelInExtension", body: [P.bodiedExtension([p(15, 2), P.panel([p(20, 8)], type: "warning")])], migrates: true), .bodiedExtension),
            (Shape(name: "headingPanelInExtension", body: [P.bodiedExtension([heading, P.panel([p(12, 10)]), p(10, 1)])], migrates: true), .bodiedExtension),
        ]
        return all.filter { only?.contains($0.0.name) ?? true }
    }

    /// The paragraphs, headings and list text in `blocks` that draw on
    /// TextKit 2 under the step 3 and step 6 rules, laid out left to right,
    /// written out here rather than read from the walk: prose in quotes and
    /// bodied extensions, and in panels whose body the probes kept
    /// (`TextKit2ContainerScopeTests.expectedPanelKeeps`); list text in
    /// those containers where PR 2's rules keep the list and the row
    /// (`listOwners`; a panel holding a list keeps its body on SwiftUI); no
    /// code, expand or column text.
    static func expectedOwners(_ blocks: [RenderBlock], inContainer: Bool = false) -> Set<String> {
        var owners: Set<String> = []
        for block in blocks {
            switch block.kind {
            case .richText: if inContainer { owners.insert(block.id) }
            case .listRows(let rows): if inContainer { owners.formUnion(listOwners(rows)) }
            case .quote(let children): owners.formUnion(expectedOwners(children, inContainer: true))
            case .extensionPlaceholder(_, let body): owners.formUnion(expectedOwners(body, inContainer: true))
            case .panel(_, let children):
                if TextKit2ContainerScopeTests.expectedPanelKeeps(children) {
                    owners.formUnion(expectedOwners(children, inContainer: true))
                }
            default: continue
            }
        }
        return owners
    }

    /// The text of a list below a container's boundary that TextKit 2
    /// draws left to right (PR 2's rules, unchanged at the nested position):
    /// none when rule B rejects the list; else each row rule A keeps, its
    /// leader (when it has text) and its trailing paragraphs and headings.
    /// Rule D passes at every width the matrices use below the
    /// accessibility sizes; right to left rule C, and at the accessibility
    /// sizes the nested-list size rule (`nestedListSizeKeepsRenderer`),
    /// keep every list row on SwiftUI (`listOwners(in:)`, subtracted per
    /// environment).
    static func listOwners(_ rows: [PreparedListRow]) -> Set<String> {
        guard TextKit2Scope.listKeepsRenderer(rows) else { return [] }
        var owners: Set<String> = []
        for row in rows where TextKit2Scope.rowKeepsRenderer(row) {
            if !row.segments.isEmpty { owners.insert(row.id) }
            for block in row.trailingBlocks {
                if case .richText = block.kind { owners.insert(block.id) }
            }
        }
        return owners
    }

    /// Every list leader and trailing paragraph or heading under `blocks`
    /// (in containers too): what rule C keeps on SwiftUI right to left.
    static func listOwners(in blocks: [RenderBlock]) -> Set<String> {
        var owners: Set<String> = []
        for block in blocks {
            switch block.kind {
            case .listRows(let rows):
                for row in rows {
                    if !row.segments.isEmpty { owners.insert(row.id) }
                    for trailing in row.trailingBlocks {
                        if case .richText = trailing.kind { owners.insert(trailing.id) }
                    }
                }
            case .quote(let children), .panel(_, let children), .extensionPlaceholder(_, let children):
                owners.formUnion(listOwners(in: children))
            case .layoutColumns(let columns):
                for column in columns { owners.formUnion(listOwners(in: column.blocks)) }
            default: continue
            }
        }
        return owners
    }

    /// The code blocks below a container in `blocks` that draw on TextKit 2
    /// under the step 7 rules (`containerChildKinds` holds `.codeBlock`),
    /// laid out in `direction`, written out rather than read from the walk:
    /// code in quotes, bodied extensions, panels whose body the probes kept
    /// (`TextKit2ContainerScopeTests.expectedPanelKeeps`) and stacked layout
    /// columns (side by side, only below a family the off-grid probe passed:
    /// none). Right to left the code gate keeps code on SwiftUI
    /// (`codeDirectionKeepsRenderer`), so the set is empty. Every code block
    /// these suites build is a few short lines of printable ASCII, far
    /// under the canvas bound at every size.
    static func expectedCode(
        _ blocks: [RenderBlock], direction: LayoutDirection, sideBySide: Bool = false, inContainer: Bool = false
    ) -> Set<String> {
        guard direction == .leftToRight, TextKit2Scope.containerChildKinds.contains(.codeBlock) else { return [] }
        var owners: Set<String> = []
        for block in blocks {
            switch block.kind {
            case .codeBlock: if inContainer { owners.insert(block.id) }
            case .quote(let children):
                owners.formUnion(expectedCode(children, direction: direction, sideBySide: sideBySide, inContainer: true))
            case .extensionPlaceholder(_, let body):
                owners.formUnion(expectedCode(body, direction: direction, sideBySide: sideBySide, inContainer: true))
            case .panel(_, let children):
                if TextKit2ContainerScopeTests.expectedPanelKeeps(children) {
                    owners.formUnion(expectedCode(children, direction: direction, sideBySide: sideBySide, inContainer: true))
                }
            case .layoutColumns(let columns):
                for child in columns.flatMap(\.blocks) {
                    if sideBySide, !TextKit2ContainerScopeTests.sideBySideFamilies.contains(TextKit2ContainerScopeTests.family(child.kind)) { continue }
                    owners.formUnion(expectedCode([child], direction: direction, sideBySide: sideBySide, inContainer: true))
                }
            default: continue
            }
        }
        return owners
    }

    /// Every paragraph, heading, list leader and code block under `blocks`.
    static func allTextOwners(_ blocks: [RenderBlock]) -> Set<String> {
        var owners: Set<String> = []
        for block in blocks {
            switch block.kind {
            case .richText, .codeBlock: owners.insert(block.id)
            case .listRows(let rows):
                for row in rows {
                    if !row.segments.isEmpty { owners.insert(row.id) }
                    owners.formUnion(allTextOwners(row.trailingBlocks))
                }
            case .quote(let children), .panel(_, let children), .extensionPlaceholder(_, let children):
                owners.formUnion(allTextOwners(children))
            default: continue
            }
        }
        return owners
    }

    /// The parent a container gives its children (`adfContainerChild`).
    static func parent(_ container: P.Container) -> TextKit2ContainerParent {
        switch container {
        case .panel: return .panel
        case .quote: return .quote
        case .expand: return .expandBody
        case .bodiedExtension: return .extensionBody
        }
    }

    /// The renderer a document row passes its top-level block, as
    /// `DocumentRow.rowTextRenderer` does: the switch for a block the
    /// production scope inherits into (`TextKit2Scope.inheritsRenderer`,
    /// whole-block rules included), SwiftUI otherwise. Hosting the block
    /// with the switch itself would skip the top-level panel rule.
    static func rowRenderer(
        _ block: RenderBlock, _ arm: ADFTextRenderer, allowed: Set<TextKit2BlockKind> = TextKit2Scope.containerChildKinds
    ) -> ADFTextRenderer {
        TextKit2Scope.inheritsRenderer(block.kind, allowed: allowed) ? arm : .swiftUI
    }

    /// The leaf control on the production path: each child of the
    /// container hosted alone at the child width (document margins around
    /// it, as `TK2ContainerProbe.leafControl`), with the renderer and
    /// context the container's boundary gives it, so a list (or a code
    /// block laid out right to left) that stays on SwiftUI in the container
    /// stays on SwiftUI here.
    @MainActor
    static func leafControl(
        _ children: [RenderBlock], in container: P.Container, width: CGFloat, env: TK2Parity.Environment
    ) throws -> P.LeafControl {
        var result = P.LeafControl()
        for (a, b) in try leafArms(children, in: container, width: width, env: env) { result.add(a, b, dark: env.dark) }
        return result
    }

    /// Each child hosted alone as the leaf control hosts it, both arms
    /// rendered (`TextKit2ContainerResidualTests` paints defects into them).
    @MainActor
    static func leafArms(
        _ children: [RenderBlock], in container: P.Container, width: CGFloat, env: TK2Parity.Environment
    ) throws -> [(swiftUI: P.Arm, textKit2: P.Arm)] {
        let margin = P.spacing * 2
        return try children.map { child in
            try P.pair(width: width + 2 * margin, pixels: true, dark: env.dark) { arm in
                let renderer = TextKit2Scope.childRenderer(
                    for: child.kind, in: parent(container), inherited: arm,
                    allowed: TextKit2Scope.containerChildKinds, layoutDirection: env.direction, dynamicTypeSize: env.size
                )
                return P.environment(
                    BlockView(block: child).padding(.horizontal, margin), arm: renderer, env: env, rowWidth: width, allowed: nil
                ).environment(\.adfTextContainerContext, .container)
            }
        }
    }
}

extension TextKit2ContainerParityTests {
    typealias B = TK2ContainerBody

    /// Runs one container's shapes over the matrix on the production path
    /// and asserts parity (or, for a shape the rules keep on SwiftUI, that
    /// no TextKit 2 row draws). `nested` cases are whole documents whose
    /// outer container is `container`. `allowed`: the container allow list
    /// (`nil`: the production one); an open expand's body (prepared by the
    /// view on opening) is expected as the same body in a quote, whose
    /// prepared ids (node paths) it shares. Right to left (rule C) and at
    /// the accessibility sizes (`nestedListSizeKeepsRenderer`) no list text
    /// is expected. The cases are `TK2ContainerProbe.cases()`: the mode's
    /// environments and widths, and in the sample its corners (320 pt,
    /// right to left, Bold Text, dark, AX).
    func productionMatrix(
        _ test: String, container: P.Container, shapes: [B.Shape], nested: Bool, allowed: Set<TextKit2BlockKind>? = nil
    ) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let tally = P.Tally()
        var failures: [String] = []
        let gated = !TextKit2Eligibility.containerTextMatchesText
        let allowList = allowed ?? TextKit2Scope.containerChildKinds
        for shape in shapes {
            let json = nested ? shape.body[0] : container.wrap(shape.body)
            let block = try #require(try await P.prepared([json]).first)
            // The blocks the expectation reads: the container itself, or
            // for an expand the same body in a quote.
            var stand = block
            let children: [RenderBlock]
            switch block.kind {
            case .panel(_, let blocks), .quote(let blocks), .extensionPlaceholder(_, let blocks): children = blocks
            case .expand where !nested:
                stand = try #require(try await P.prepared([P.quote(shape.body)]).first)
                guard case .quote(let blocks) = stand.kind else { throw TestFailure("\(shape.name): no stand-in body") }
                children = blocks
            default: throw TestFailure("\(shape.name): not a panel, quote, expand or extension")
            }
            let text = shape.migrates ? B.expectedOwners([stand]) : []
            let listText = B.listOwners(in: [stand])
            #expect(shape.migrates == !text.isEmpty, "\(shape.name): the shape's text and its expectation disagree")
            // From step 7 the code blocks beside that text, left to right.
            let code = shape.migrates ? B.expectedCode([stand], direction: .leftToRight) : []
            let expected = text.union(code)
            let everyOwner = B.allTextOwners([stand])
            let model = ADFDocumentModel()
            if case .expand = block.kind { model.expandedBlocks.insert(block.id) }
            /// `rows`: whether TextKit 2 rows are expected (an expand
            /// waits for them).
            func host(_ width: CGFloat, _ env: TK2Parity.Environment, pixels: Bool, rows: Bool) async throws -> (P.Arm, P.Arm) {
                let make = { (arm: ADFTextRenderer) in
                    P.environment(BlockView(block: block), arm: B.rowRenderer(block, arm, allowed: allowList), env: env,
                                  rowWidth: width, search: model.search, allowed: allowed)
                }
                guard case .expand = block.kind else { return try P.pair(width: width, pixels: pixels, dark: env.dark, make) }
                if !rows {
                    // Nothing to wait for on TextKit 2: settle the opened
                    // body on SwiftUI, then flip.
                    let host = P.Host(width: width, dark: env.dark)
                    defer { host.close() }
                    host.show(make(.swiftUI))
                    for _ in 0..<50 { host.layout(); try await Task.sleep(for: .milliseconds(10)) }
                    let a = P.arm(host)
                    host.show(make(.textKit2))
                    for _ in 0..<20 { host.layout(); try await Task.sleep(for: .milliseconds(10)) }
                    return (a, P.arm(host))
                }
                let (a, b, _) = try await P.expandPair(width: width, pixels: pixels, dark: env.dark, make)
                return (a, b)
            }
            print("CONTAINER_PARITY_SHAPE test=\(test) container=\(container.rawValue) shape=\(shape.name) migrates=\(shape.migrates) expected=\(expected.sorted()) prepared=\(P.shapeDescription(block))")

            if gated {
                // Before iOS 26: the gate. One environment is enough; the
                // engine is all there is to compare.
                let width = P.rowWidth(documentWidth: 375)
                let env = TK2Parity.Environment(size: .large)
                let (a, b) = try await host(width, env, pixels: false, rows: false)
                if !(a.rows.isEmpty && b.rows.isEmpty) {
                    failures.append("\(shape.name): before iOS 26 TextKit 2 drew \(b.owners.sorted())")
                }
                var notGated: [String] = []
                var leaves = 0
                // Prose, list text and, from step 7, code below the
                // container: every one is gated by the OS first
                // (`containerCodeVerdict` for code).
                TextKit2Scope.forEachLeaf(in: [stand], allowed: allowList) { leaf in
                    guard [.containerProse, .containerListLeader, .containerListTrailing, .containerCode].contains(leaf.position) else { return }
                    leaves += 1
                    // List text meets the list gate first (`osGatedList`).
                    if case .fallback(.osGatedContainer) = leaf.verdict { return }
                    if case .fallback(.osGatedList) = leaf.verdict { return }
                    notGated.append(leaf.ownerID)
                }
                if !notGated.isEmpty || leaves != expected.count {
                    failures.append("\(shape.name): before iOS 26 \(leaves) container leaves, not gated: \(notGated)")
                }
                continue
            }

            for (env, documentWidth) in P.cases() {
                do {
                    let width = P.rowWidth(documentWidth: documentWidth)
                    let pixels = shape.migrates && P.comparesPixels(env, documentWidth: documentWidth)
                    // The engine: exactly the expected owners on TextKit 2
                    // (nothing right to left, the container direction
                    // rule of lead dispositions F-Q6; no list text at the
                    // accessibility sizes, the nested-list size rule; nor
                    // list text where the container's bound leaves a row
                    // no text column, rule D), nothing on the SwiftUI arm,
                    // and for a shape kept on SwiftUI no row at all.
                    let narrow = TK2ContainerLists.narrowListText(
                        in: children, bound: P.childWidth(container, rowWidth: width, env: env), size: env.size
                    )
                    var expected = expected.subtracting(narrow)
                    if env.direction == .rightToLeft { expected = [] }
                    // From xxxLarge nothing either (the container size
                    // rule, lead call C55).
                    if !TextKit2Scope.containerSizeKeepsRenderer(env.size) { expected = [] }
                    if !TextKit2Scope.nestedListSizeKeepsRenderer(env.size) { expected = expected.subtracting(listText) }
                    let (a, b) = try await host(width, env, pixels: pixels, rows: !expected.isEmpty)
                    var verdict = P.geometry(a.guides, b.guides)
                    verdict.engine = a.rows.isEmpty && b.owners == expected && b.rows.count == expected.count
                    if pixels, let ba = a.bitmap, let bb = b.bitmap {
                        crops(&verdict, container, ba, bb, width: width, env: env, swiftUIArm: a, textKit2Arm: b)
                    }
                    if !verdict.pass {
                        // The leaf control: a pixel-only failure is the
                        // leaf's (C1) when the same blocks alone at the
                        // child width differ the same way, owner by owner
                        // (`residualMismatch`).
                        verdict.leaf = try B.leafControl(children, in: container, width: P.childWidth(container, rowWidth: width, env: env), env: env)
                    }
                    let fields = "test=\(test) container=\(container.rawValue) shape=\(shape.name) \(P.fields(env)) W=\(documentWidth)"
                    let key = "container=\(container.rawValue) shape=\(shape.name) dir=\(env.direction == .rightToLeft ? "rtl" : "ltr")"
                    let accepted = verdict.engine && verdict.geometryPass && (verdict.pixelFailures.isEmpty || verdict.cause == "leafDrawing")
                    tally.add(key, label: "\(P.fields(env)) W=\(documentWidth) dH=\(P.format(verdict.dHeight)) dFirst=\(P.format(verdict.dFirst)) dLast=\(P.format(verdict.dLast)) px=\(verdict.pixelFailures.count)", verdict)
                    if !accepted || P.printsEveryCase || !verdict.pass {
                        print(P.line(fields, verdict, a, b).replacingOccurrences(of: "CONTAINER_PROBE ", with: "CONTAINER_PARITY ") + " accepted=\(accepted)")
                    }
                    if !accepted {
                        let failure = "\(fields): engine=\(verdict.engine) (textKit2 owners \(b.owners.sorted()), expected \(expected.sorted()), swiftUI rows \(a.rows.count)) dH=\(P.format(verdict.dHeight)) dFirst=\(P.format(verdict.dFirst)) dLast=\(P.format(verdict.dLast)) cause=\(verdict.cause) px=\(verdict.pixelFailures.first ?? "-")\(verdict.geometryPass && !verdict.pixelFailures.isEmpty ? " residualMismatch={\(verdict.residualMismatch ?? "-")}" : "")"
                        failures.append(failure)
                        if let ba = a.bitmap, let bb = b.bitmap { P.dump(key, fields, ba, bb) }
                    }
                    // Nothing outside the expected owners (a list, or code
                    // laid out right to left, left on SwiftUI) drew through
                    // TextKit 2.
                    let unexpected = b.owners.intersection(everyOwner).subtracting(expected)
                    if !unexpected.isEmpty { failures.append("\(fields): unexpected TextKit 2 owners \(unexpected.sorted())") }
                }
            }
        }
        tally.print(probe: test)
        print("CONTAINER_PARITY_TIME test=\(test) container=\(container.rawValue) scale=\(TK2Parity.nativeScale) os=\(TK2Parity.osVersion) mode=\(P.mode) gated=\(gated) elapsed=\(clock.now - start)")
        #expect(failures.isEmpty, "\(failures.count) failing cases: \(failures.prefix(6))")
    }

    @Test("panelBody: panel prose matches SwiftUI through the production path; the excluded panel shapes (heading, list, sub/sup or a code block beside a block) draw no TextKit 2 row")
    func panelBody() async throws {
        try await productionMatrix("panelBody", container: .panel, shapes: B.shapes(for: .panel), nested: false)
    }

    @Test("quoteBody: quote prose (and from step 6 its lists) matches SwiftUI through the production path, beside code that draws on TextKit 2 from step 7 (left to right)")
    func quoteBody() async throws {
        try await productionMatrix("quoteBody", container: .quote, shapes: B.shapes(for: .quote), nested: false)
    }

    @Test("extensionBody: bodied-extension prose (and from step 6 its lists) matches SwiftUI through the production path, beside code that draws on TextKit 2 from step 7 (left to right)")
    func extensionBody() async throws {
        try await productionMatrix("extensionBody", container: .bodiedExtension, shapes: B.shapes(for: .bodiedExtension), nested: false)
    }

    @Test("nestedContainers: panel in quote, quote in panel, panel in extension (headings beside, an excluded panel inside) match SwiftUI through the production path")
    func nestedContainers() async throws {
        for container in [P.Container.quote, .panel, .bodiedExtension] {
            let shapes = B.nestedShapes.filter { $0.outer == container }.map(\.shape)
            guard !shapes.isEmpty else { continue }
            try await productionMatrix("nestedContainers", container: container, shapes: shapes, nested: true)
        }
    }
}
#endif
