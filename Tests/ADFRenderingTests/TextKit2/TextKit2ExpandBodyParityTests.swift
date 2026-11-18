#if canImport(UIKit)
import SwiftUI
import UIKit
import Testing
import ADFModel
import ADFPreparation
@testable import ADFRendering

// Open expand and nested-expand bodies on TextKit 2 through the production
// path (PR 4 step 5): the real `BlockView(block:)` of an expand, opened on
// a model, hosted with the production container allow list (nothing
// widened) and the row's width bound. An expand's body is prepared by the
// view on opening and cached in view state, so each case waits for it
// (`TK2ExpandParity.pair`): TextKit 2 until every expected body row is up;
// SwiftUI in a fresh host (main's first render of the open body); then the
// TextKit 2 host flipped to SwiftUI and back, which must measure as the
// first time. The assertions are step 3's (`productionMatrix`): exactly
// the expected owners on TextKit 2 and none on SwiftUI; height and first
// and last baseline within 0.01 pt (PR 1's one-pixel last-baseline
// residual aside); the pixel comparison of PR 2's rows over the whole box,
// a pixel difference counting as the leaf's only where the same blocks
// alone at the body's child width differ the same way, owner by owner
// (probe call C1, `residualMismatch`). The title and chevron stay SwiftUI
// on both arms.
//
// These live in their own file (as an extension of the parity suite) so
// step 4's edits to the suite's file do not collide with them.

/// Shapes, expectations and hosting of the expand parity suites. Not a
/// suite.
enum TK2ExpandParity {
    typealias P = TK2ContainerProbe
    typealias B = TK2ContainerBody

    /// A whole top-level block and the expands to open in it.
    struct Shape: Sendable {
        let name: String
        let json: String
        /// Ids of the expands to open, outer first.
        let open: Set<String>
    }

    static func nestedExpand(_ body: [String], title: String = "Nested details") -> String {
        "{\"type\":\"nestedExpand\",\"attrs\":{\"title\":\"\(title)\"},\"content\":[\(body.joined(separator: ","))]}"
    }

    /// The step 3 body shapes in an open expand: every one has prose that
    /// migrates (from step 6 a list beside it follows PR 2's list rules,
    /// and from step 7 a code block beside it draws on TextKit 2, both
    /// left to right only).
    static var bodyShapes: [Shape] {
        B.shapes(for: .expand).map { Shape(name: $0.name, json: P.expand($0.body), open: ["0.0"]) }
    }

    /// Nested expands opened inside an open expand, beside prose, a heading
    /// and a list; a nested expand left closed in an open body; and a
    /// nested expand as a whole top-level block.
    static var nestedShapes: [Shape] {
        let p = { (count: Int, from: Int) in P.paragraph(P.t(P.words(count, from: from))) }
        let heading = P.heading(3, P.words(5, from: 4))
        let list = P.bulletList([P.item(p(4, 2)), P.item(p(9, 6))])
        let all = [
            Shape(name: "nestedInExpand", json: P.expand([p(16, 0), nestedExpand([p(22, 5), p(7, 1)]), p(10, 3)]), open: ["0.0", "0.0.1"]),
            Shape(name: "nestedHeadingList", json: P.expand([heading, nestedExpand([P.heading(4, P.words(4, from: 9)), p(18, 2), list, p(6, 12)])]), open: ["0.0", "0.0.1"]),
            Shape(name: "nestedQuoteInside", json: P.expand([nestedExpand([p(12, 7), P.quote([p(15, 3)])]), p(8, 11)]), open: ["0.0", "0.0.0"]),
            Shape(name: "nestedClosed", json: P.expand([p(14, 4), nestedExpand([p(20, 1)]), p(9, 8)]), open: ["0.0"]),
            Shape(name: "nestedTopLevel", json: nestedExpand([p(18, 6), P.quote([p(11, 2)]), p(5, 13)]), open: ["0.0"]),
        ]
        return all.filter { B.only?.contains($0.name) ?? true }
    }

    /// An expand's body, prepared as the view prepares it on opening.
    static func body(of block: RenderBlock) -> [RenderBlock] {
        guard case .expand(_, let nodes, _) = block.kind else { return [] }
        let root = ADFNode(id: "expand", type: "doc", kind: .doc(nodes))
        return DocumentPreparer(theme: P.theme).prepare(ADFDocument(version: 1, root: root, issues: []))
    }

    /// The text that draws on TextKit 2 under the production rules in the
    /// open expands among `blocks` (and in the open expands directly in
    /// their bodies), written out here rather than read from the walk:
    /// body prose by step 3's rules (`TK2ContainerBody.expectedOwners`).
    static func expectedOwners(_ blocks: [RenderBlock], open: Set<String>) -> Set<String> {
        var owners: Set<String> = []
        for block in blocks {
            guard case .expand = block.kind, open.contains(block.id) else { continue }
            let body = body(of: block)
            owners.formUnion(B.expectedOwners(body, inContainer: true))
            owners.formUnion(expectedOwners(body, open: open))
        }
        return owners
    }

    /// The code blocks that draw on TextKit 2 under the step 7 rules in the
    /// open expands among `blocks` (and in the open expands directly in
    /// their bodies), laid out in `direction`
    /// (`TK2ContainerBody.expectedCode`; none right to left).
    static func expectedCode(_ blocks: [RenderBlock], open: Set<String>, direction: LayoutDirection) -> Set<String> {
        var owners: Set<String> = []
        for block in blocks {
            guard case .expand = block.kind, open.contains(block.id) else { continue }
            let body = body(of: block)
            owners.formUnion(B.expectedCode(body, direction: direction, inContainer: true))
            owners.formUnion(expectedCode(body, open: open, direction: direction))
        }
        return owners
    }

    /// Every list leader and trailing paragraph or heading in the open
    /// expands among `blocks` (and in the open expands directly in their
    /// bodies): what rule C keeps on SwiftUI right to left
    /// (`TK2ContainerBody.listOwners(in:)`).
    static func listText(_ blocks: [RenderBlock], open: Set<String>) -> Set<String> {
        var owners: Set<String> = []
        for block in blocks {
            guard case .expand = block.kind, open.contains(block.id) else { continue }
            let body = body(of: block)
            owners.formUnion(B.listOwners(in: body))
            owners.formUnion(listText(body, open: open))
        }
        return owners
    }

    /// The list text rule D keeps on SwiftUI in the open expands among
    /// `blocks` laid out under `bound`: each open body at its expand's
    /// child width (2.5 spacings in, `TK2ContainerProbe.childWidth`), an
    /// open expand directly in it 2.5 spacings in again
    /// (`TK2ContainerLists.narrowListText`).
    @MainActor
    static func narrowListText(_ blocks: [RenderBlock], open: Set<String>, bound: CGFloat, size: DynamicTypeSize) -> Set<String> {
        var owners: Set<String> = []
        for block in blocks {
            guard case .expand = block.kind, open.contains(block.id) else { continue }
            let body = body(of: block)
            let inner = bound - P.spacing * 2.5
            owners.formUnion(TK2ContainerLists.narrowListText(in: body, bound: inner, size: size))
            owners.formUnion(narrowListText(body, open: open, bound: inner, size: size))
        }
        return owners
    }

    /// Every paragraph, heading and list leader in the open expands among
    /// `blocks`.
    static func allTextOwners(_ blocks: [RenderBlock], open: Set<String>) -> Set<String> {
        var owners: Set<String> = []
        for block in blocks {
            guard case .expand = block.kind, open.contains(block.id) else { continue }
            let body = body(of: block)
            owners.formUnion(B.allTextOwners(body))
            owners.formUnion(allTextOwners(body, open: open))
        }
        return owners
    }

    /// The outermost open body's blocks, for the leaf control.
    static func outerBody(_ block: RenderBlock) -> [RenderBlock] {
        body(of: block)
    }

    /// An open expand on both arms (`TK2ContainerProbe.expandPair`):
    /// TextKit 2 until `expected` rows are up and the geometry holds still;
    /// SwiftUI in a fresh host of its own (code review F-R20: the SwiftUI
    /// arm is main's first render of the open body, never a flipped one);
    /// then the TextKit 2 host flipped to SwiftUI and back, which must
    /// measure as the first time (`stable`). With no row expected (right
    /// to left) nothing signals the opened body: half a second of layout
    /// turns first, as the gated path waits.
    @MainActor
    static func pair<V: View>(
        width: CGFloat, pixels: Bool, dark: Bool = false, expected: Int, _ make: (ADFTextRenderer) -> V
    ) async throws -> (swiftUI: P.Arm, textKit2: P.Arm, stable: Bool) {
        try await P.expandPair(
            width: width, pixels: pixels, dark: dark, ready: { $0.count == expected }, minimumTurns: expected > 0 ? 0 : P.noRowTurns, make
        )
    }
}

extension TextKit2ContainerParityTests {
    typealias E = TK2ExpandParity

    /// Runs expand shapes over the matrix on the production path and
    /// asserts parity (the step 3 rules, `productionMatrix`).
    func expandMatrix(_ test: String, shapes: [E.Shape]) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let tally = P.Tally()
        var failures: [String] = []
        let gated = !TextKit2Eligibility.containerTextMatchesText
        for shape in shapes {
            let block = try #require(try await P.prepared([shape.json]).first)
            guard case .expand = block.kind else { throw TestFailure("\(shape.name): not an expand") }
            // Body prose and, from step 6, list text (`expectedOwners`).
            let text = E.expectedOwners([block], open: shape.open)
            let listText = E.listText([block], open: shape.open)
            // From step 7 the code blocks in the open bodies, left to right.
            let code = E.expectedCode([block], open: shape.open, direction: .leftToRight)
            let expectedLTR = text.union(code)
            let expected = expectedLTR
            let everyOwner = E.allTextOwners([block], open: shape.open)
            let children = E.outerBody(block)
            #expect(!text.subtracting(listText).isEmpty, "\(shape.name): no body prose migrates")
            print("CONTAINER_PARITY_SHAPE test=\(test) container=expand shape=\(shape.name) open=\(shape.open.sorted()) expected=\(expected.sorted()) prepared=\(P.shapeDescription(block)) body=\(children.map(P.shapeDescription).joined(separator: ","))")
            let model = ADFDocumentModel()
            model.expandedBlocks = shape.open

            if gated {
                // Before iOS 26: the gate. Settle on SwiftUI (the body is
                // prepared on opening), flip, and expect no row.
                let width = P.rowWidth(documentWidth: 375)
                let make = { (arm: ADFTextRenderer) in
                    P.environment(BlockView(block: block), arm: B.rowRenderer(block, arm), env: TK2Parity.Environment(), rowWidth: width, search: model.search, allowed: nil)
                }
                let host = P.Host(width: width)
                defer { host.close() }
                host.show(make(.swiftUI))
                for _ in 0..<50 { host.layout(); try await Task.sleep(for: .milliseconds(10)) }
                host.show(make(.textKit2))
                for _ in 0..<20 { host.layout(); try await Task.sleep(for: .milliseconds(10)) }
                if !host.rows.isEmpty {
                    failures.append("\(shape.name): before iOS 26 TextKit 2 drew \(P.arm(host).owners.sorted())")
                }
                continue
            }

            for (env, documentWidth) in P.cases() {
                do {
                    let width = P.rowWidth(documentWidth: documentWidth)
                    // As `productionMatrix`: nothing right to left (the
                    // container direction rule, lead dispositions F-Q6);
                    // no list text at the accessibility sizes (the
                    // nested-list size rule); nor list text where the
                    // body's bound leaves a row no text column (rule D).
                    let narrow = E.narrowListText([block], open: shape.open, bound: width, size: env.size)
                    var expected = expectedLTR.subtracting(narrow)
                    if env.direction == .rightToLeft { expected = [] }
                    // From AX4 nothing either (the container size
                    // rule, code review F-R4 and F-Q1).
                    if !TextKit2Scope.containerSizeKeepsRenderer(env.size) { expected = [] }
                    if !TextKit2Scope.nestedListSizeKeepsRenderer(env.size) { expected = expected.subtracting(listText) }
                    let pixels = P.comparesPixels(env, documentWidth: documentWidth)
                    let make = { (arm: ADFTextRenderer) in
                        P.environment(BlockView(block: block), arm: B.rowRenderer(block, arm), env: env, rowWidth: width, search: model.search, allowed: nil)
                    }
                    let (a, b, stable) = try await E.pair(width: width, pixels: pixels, dark: env.dark, expected: expected.count, make)
                    var verdict = P.geometry(a.guides, b.guides)
                    verdict.engine = a.rows.isEmpty && b.owners == expected && b.rows.count == expected.count
                    if !stable { verdict.notes.append("flipUnstable") }
                    if a.guides.height > P.Host.windowHeight - 20 { verdict.notes.append("taller-than-window") }
                    if pixels, let ba = a.bitmap, let bb = b.bitmap {
                        crops(&verdict, .expand, ba, bb, width: width, env: env, swiftUIArm: a, textKit2Arm: b)
                    }
                    if !verdict.pass {
                        // The leaf control: the body's blocks alone at the
                        // body's child width (C1).
                        verdict.leaf = try B.leafControl(children, in: .expand, width: P.childWidth(.expand, rowWidth: width, env: env), env: env)
                    }
                    let fields = "test=\(test) container=expand shape=\(shape.name) \(P.fields(env)) W=\(documentWidth)"
                    let key = "container=expand shape=\(shape.name) dir=\(env.direction == .rightToLeft ? "rtl" : "ltr")"
                    let accepted = verdict.engine && stable && verdict.geometryPass
                        && (verdict.pixelFailures.isEmpty || verdict.cause == "leafDrawing")
                    tally.add(key, label: "\(P.fields(env)) W=\(documentWidth) dH=\(P.format(verdict.dHeight)) dFirst=\(P.format(verdict.dFirst)) dLast=\(P.format(verdict.dLast)) px=\(verdict.pixelFailures.count)", verdict)
                    if !accepted || P.printsEveryCase || !verdict.pass {
                        print(P.line(fields, verdict, a, b).replacingOccurrences(of: "CONTAINER_PROBE ", with: "CONTAINER_PARITY ") + " accepted=\(accepted)")
                    }
                    if !accepted {
                        failures.append("\(fields): engine=\(verdict.engine) stable=\(stable) (textKit2 owners \(b.owners.sorted()), expected \(expected.sorted()), swiftUI rows \(a.rows.count)) dH=\(P.format(verdict.dHeight)) dFirst=\(P.format(verdict.dFirst)) dLast=\(P.format(verdict.dLast)) cause=\(verdict.cause) px=\(verdict.pixelFailures.first ?? "-")\(verdict.geometryPass && !verdict.pixelFailures.isEmpty ? " residualMismatch={\(verdict.residualMismatch ?? "-")}" : "")")
                        if let ba = a.bitmap, let bb = b.bitmap { P.dump(key, fields, ba, bb) }
                    }
                    let unexpected = b.owners.intersection(everyOwner).subtracting(expected)
                    if !unexpected.isEmpty { failures.append("\(fields): unexpected TextKit 2 owners \(unexpected.sorted())") }
                }
            }
        }
        tally.print(probe: test)
        print("CONTAINER_PARITY_TIME test=\(test) container=expand scale=\(TK2Parity.nativeScale) os=\(TK2Parity.osVersion) mode=\(P.mode) gated=\(gated) elapsed=\(clock.now - start)")
        #expect(failures.isEmpty, "\(failures.count) failing cases: \(failures.prefix(6))")
    }

    @Test("expandBody: open-expand body prose, list text (step 6) and code (step 7) match SwiftUI through the production path; the body stays on SwiftUI right to left and from AX4")
    func expandBody() async throws {
        try await expandMatrix("expandBody", shapes: E.bodyShapes)
    }

    @Test("nestedExpandBody: nested-expand bodies (open in an open expand, beside a heading, a list or a quote; closed; top-level) match SwiftUI through the production path")
    func nestedExpandBody() async throws {
        try await expandMatrix("nestedExpandBody", shapes: E.nestedShapes)
    }
}
#endif
