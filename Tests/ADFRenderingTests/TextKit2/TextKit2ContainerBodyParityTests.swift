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
    /// code block, which stays on SwiftUI until code joins the allow list
    /// (the fixtures hold it: containers-parity 0.71, 0.77, 0.78). A panel
    /// keeps a heading, a list and a superscript or small-text run beside
    /// another block on SwiftUI (`panelKeepsRenderer`); in a quote or an
    /// extension body only the list (and the code) does.
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

    /// The paragraphs and headings in `blocks` that draw on TextKit 2 under
    /// the step 3 rules, written out here rather than read from the walk:
    /// prose in quotes and bodied extensions, and in panels whose body the
    /// probes kept (`TextKit2ContainerScopeTests.expectedPanelKeeps`); no
    /// list, code, expand or column text.
    static func expectedOwners(_ blocks: [RenderBlock], inContainer: Bool = false) -> Set<String> {
        var owners: Set<String> = []
        for block in blocks {
            switch block.kind {
            case .richText: if inContainer { owners.insert(block.id) }
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

    /// Every paragraph, heading and list leader under `blocks`.
    static func allTextOwners(_ blocks: [RenderBlock]) -> Set<String> {
        var owners: Set<String> = []
        for block in blocks {
            switch block.kind {
            case .richText: owners.insert(block.id)
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
    static func rowRenderer(_ block: RenderBlock, _ arm: ADFTextRenderer) -> ADFTextRenderer {
        TextKit2Scope.inheritsRenderer(block.kind) ? arm : .swiftUI
    }

    /// The leaf control on the production path: each child of the
    /// container hosted alone at the child width (document margins around
    /// it, as `TK2ContainerProbe.leafControl`), with the renderer and
    /// context the container's boundary gives it, so a list or code block
    /// that stays on SwiftUI in the container stays on SwiftUI here.
    @MainActor
    static func leafControl(
        _ children: [RenderBlock], in container: P.Container, width: CGFloat, env: TK2Parity.Environment
    ) throws -> (dHeight: CGFloat, dFirst: CGFloat, dLast: CGFloat, differing: Int, pixelFailures: Int) {
        var result: (dHeight: CGFloat, dFirst: CGFloat, dLast: CGFloat, differing: Int, pixelFailures: Int) = (0, 0, 0, 0, 0)
        let margin = P.spacing * 2
        for child in children {
            let (a, b) = try P.pair(width: width + 2 * margin, pixels: true) { arm in
                let renderer = TextKit2Scope.childRenderer(
                    for: child.kind, in: parent(container), inherited: arm,
                    allowed: TextKit2Scope.containerChildKinds, layoutDirection: env.direction
                )
                return P.environment(
                    BlockView(block: child).padding(.horizontal, margin), arm: renderer, env: env, rowWidth: width, allowed: nil
                ).environment(\.adfTextContainerContext, .container)
            }
            var verdict = P.geometry(a.guides, b.guides)
            result.dHeight += verdict.dHeight
            result.dFirst = max(result.dFirst, verdict.dFirst)
            result.dLast = max(result.dLast, verdict.lastResidual ? 0 : verdict.dLast)
            if let x = a.bitmap, let y = b.bitmap {
                P.pixels(&verdict, x, y, crops: [P.Crop(name: "leaf", columns: 0..<x.width)], background: (255, 255, 255))
            }
            result.differing += verdict.differing
            if !verdict.pixelFailures.isEmpty { result.pixelFailures += 1 }
        }
        return result
    }
}

extension TextKit2ContainerParityTests {
    typealias B = TK2ContainerBody

    /// Runs one container's shapes over the matrix on the production path
    /// and asserts parity (or, for a shape the rules keep on SwiftUI, that
    /// no TextKit 2 row draws). `nested` cases are whole documents whose
    /// outer container is `container`.
    func productionMatrix(_ test: String, container: P.Container, shapes: [B.Shape], nested: Bool) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let tally = P.Tally()
        var failures: [String] = []
        let gated = !TextKit2Eligibility.containerTextMatchesText
        for shape in shapes {
            let json = nested ? shape.body[0] : container.wrap(shape.body)
            let block = try #require(try await P.prepared([json]).first)
            let children: [RenderBlock]
            switch block.kind {
            case .panel(_, let blocks), .quote(let blocks), .extensionPlaceholder(_, let blocks): children = blocks
            default: throw TestFailure("\(shape.name): not a panel, quote or extension")
            }
            let expected = shape.migrates ? B.expectedOwners([block]) : []
            #expect(shape.migrates == !expected.isEmpty, "\(shape.name): the shape's text and its expectation disagree")
            let everyOwner = B.allTextOwners([block])
            print("CONTAINER_PARITY_SHAPE test=\(test) container=\(container.rawValue) shape=\(shape.name) migrates=\(shape.migrates) expected=\(expected.sorted()) prepared=\(P.shapeDescription(block))")

            if gated {
                // Before iOS 26: the gate. One environment is enough; the
                // engine is all there is to compare.
                let width = P.rowWidth(documentWidth: 375)
                let env = TK2Parity.Environment(size: .large)
                let (a, b) = try P.pair(width: width, pixels: false) { arm in
                    P.environment(BlockView(block: block), arm: B.rowRenderer(block, arm), env: env, rowWidth: width, allowed: nil)
                }
                if !(a.rows.isEmpty && b.rows.isEmpty) {
                    failures.append("\(shape.name): before iOS 26 TextKit 2 drew \(b.owners.sorted())")
                }
                var notGated: [String] = []
                var leaves = 0
                TextKit2Scope.forEachLeaf(in: [block]) { leaf in
                    guard leaf.position == .containerProse else { return }
                    leaves += 1
                    if case .fallback(.osGatedContainer) = leaf.verdict { return }
                    notGated.append(leaf.ownerID)
                }
                if !notGated.isEmpty || leaves != expected.count {
                    failures.append("\(shape.name): before iOS 26 \(leaves) container leaves, not gated: \(notGated)")
                }
                continue
            }

            for env in P.environments() {
                for documentWidth in P.documentWidths {
                    let width = P.rowWidth(documentWidth: documentWidth)
                    let pixels = shape.migrates && P.comparesPixels(env, documentWidth: documentWidth)
                    let (a, b) = try P.pair(width: width, pixels: pixels) { arm in
                        P.environment(BlockView(block: block), arm: B.rowRenderer(block, arm), env: env, rowWidth: width, allowed: nil)
                    }
                    var verdict = P.geometry(a.guides, b.guides)
                    // The engine: exactly the expected owners on TextKit 2,
                    // nothing on the SwiftUI arm, and for a shape kept on
                    // SwiftUI no row at all.
                    verdict.engine = a.rows.isEmpty && b.owners == expected && b.rows.count == expected.count
                    if pixels, let ba = a.bitmap, let bb = b.bitmap {
                        crops(&verdict, container, ba, bb, width: width, env: env, swiftUIArm: a)
                    }
                    if !verdict.pass, verdict.geometryPass {
                        // Pixels only: the leaf's (C1) when the same blocks
                        // alone at the child width differ too.
                        verdict.leaf = try B.leafControl(children, in: container, width: P.childWidth(container, rowWidth: width, env: env), env: env)
                    } else if !verdict.geometryPass {
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
                        failures.append("\(fields): engine=\(verdict.engine) (textKit2 owners \(b.owners.sorted()), expected \(expected.sorted()), swiftUI rows \(a.rows.count)) dH=\(P.format(verdict.dHeight)) dFirst=\(P.format(verdict.dFirst)) dLast=\(P.format(verdict.dLast)) cause=\(verdict.cause) px=\(verdict.pixelFailures.first ?? "-")")
                        if let ba = a.bitmap, let bb = b.bitmap { P.dump(key, fields, ba, bb) }
                    }
                    // Nothing outside the expected owners (a list or code
                    // block left on SwiftUI) drew through TextKit 2.
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

    @Test("quoteBody: quote prose matches SwiftUI through the production path, beside lists and code that stay on SwiftUI")
    func quoteBody() async throws {
        try await productionMatrix("quoteBody", container: .quote, shapes: B.shapes(for: .quote), nested: false)
    }

    @Test("extensionBody: bodied-extension prose matches SwiftUI through the production path, beside lists and code that stay on SwiftUI")
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
