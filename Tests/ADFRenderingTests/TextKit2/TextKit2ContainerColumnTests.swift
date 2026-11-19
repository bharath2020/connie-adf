#if canImport(UIKit)
import SwiftUI
import UIKit
import Testing
import ADFModel
import ADFPreparation
@testable import ADFRendering

// Layout-column text on TextKit 2 through the production path (PR 4 step
// 4): the real `BlockView(block:)` of a layout section, hosted as a
// document row hosts it (the production container allow list, nothing
// widened; the row's width bound), on both renderers.
//
// The off-grid column probe (`offGridColumns`, `probes/results.md` §3.3)
// let no family keep the renderer in a side-by-side column
// (`TextKit2Scope.horizontalColumnKeepsRenderer`): side by side, every
// column child is drawn by SwiftUI on both arms (`.horizontalColumn`), and
// the suites assert that, exactly. Stacked columns (a compact width, or an
// accessibility text size) hand their children the section's own width,
// and their prose migrates: the suites assert parity there as step 3's do
// (height, first and last baseline within 0.01 pt, PR 1's one-pixel
// last-baseline residual aside, and PR 2's pixel rule; a pixel-only
// difference counts as the leaf's where the same blocks alone at the
// column's width differ too, probe call C1).
//
// The matrix is the probes' (`TK2ContainerProbe`): a sample by default,
// `ADF_CONTAINER_PROBES=family|full` at the test runner for the larger
// ones. Before iOS 26 container text is gated: the suites assert that no
// column leaf draws through TextKit 2.
//
// Each case prints `CONTAINER_PARITY test=… container=columns shape=… …`.

/// The sections and expectations of the step 4 column suites. Not a suite.
enum TK2ContainerColumns {
    typealias P = TK2ContainerProbe

    struct Section: Sendable {
        let name: String
        let json: String
    }

    /// The column shapes: the fixture's KP-S6 sections (25/75 with a
    /// heading, 33/67 with a link, 50/50 holding a panel and a quote,
    /// three equal columns), a column holding a list and a code block
    /// beside its prose (the list migrates from step 6 when the columns
    /// stack; from step 7 the code block draws on TextKit 2 when the
    /// columns stack, left to right: `TK2ContainerBody.expectedCode`), and
    /// containers nested in columns (a quote holding a panel; an extension
    /// body with a heading), and from step 6 lists in columns
    /// (`listSections`). `ADF_CONTAINER_PROBES_SHAPES=<name,…>` limits
    /// them.
    static var sections: [Section] { proseSections + listSections }

    /// Lists in columns (PR 4 step 6): the nested-list shapes of
    /// `TK2ContainerLists` beside a paragraph, and a list beside a list.
    static var listSections: [Section] {
        let p = { (count: Int, from: Int) in P.paragraph(P.t(P.words(count, from: from))) }
        let shapes = Dictionary(uniqueKeysWithValues: TK2ContainerLists.allShapes.map { ($0.name, $0.body) })
        let all: [Section] = [
            Section(name: "list-nestedList", json: P.section([(40, shapes["nestedList"]!), (60, [p(12, 3)])])),
            Section(name: "list-orderedTasks", json: P.section([(50, [p(6, 2)]), (50, shapes["orderedTasks"]!)])),
            Section(name: "list-ruleARow", json: P.section([(30, [p(5, 7)]), (70, shapes["ruleARow"]!)])),
            Section(name: "list-beside-list", json: P.section([(50, shapes["multiParagraphItem"]!), (50, shapes["decisions"]!)])),
        ]
        return all.filter { TK2ContainerBody.only?.contains($0.name) ?? true }
    }

    static var proseSections: [Section] {
        let p = { (count: Int, from: Int) in P.paragraph(P.t(P.words(count, from: from))) }
        let linked = P.paragraph(P.t(P.words(4, from: 2) + " "), P.t("a link in a column", P.link))
        let list = P.bulletList([P.item(p(6, 3)), P.item(p(3, 9))])
        let all: [Section] = [
            Section(name: "25-75", json: P.section([(25, [p(5, 0), p(3, 6)]), (75, [p(18, 2), P.heading(4, P.words(5, from: 4)), p(8, 11)])])),
            Section(name: "33-67", json: P.section([(33.33, [p(6, 1)]), (66.66, [p(14, 5), linked])])),
            Section(name: "50-50-panel-quote", json: P.section([(50, [P.panel([p(9, 3)])]), (50, [P.quote([p(10, 7)])])])),
            Section(name: "33-33-33", json: P.section([(33.33, [p(7, 0)]), (33.33, [p(5, 8)]), (33.33, [p(9, 14)])])),
            Section(name: "listAndCodeBeside", json: P.section([(50, [p(8, 4), list]), (50, [TK2ContainerBody.codeBlock, p(6, 12)])])),
            Section(name: "nested", json: P.section([
                (40, [P.quote([p(6, 2), P.panel([p(7, 9)], type: "note")])]),
                (60, [P.bodiedExtension([P.heading(3, P.words(3, from: 1)), p(10, 6)]), p(5, 16)]),
            ])),
        ]
        return all.filter { TK2ContainerBody.only?.contains($0.name) ?? true }
    }

    /// The paragraphs and headings below `blocks` that draw on TextKit 2
    /// under the step 4 rules when every section among them stacks,
    /// written out rather than read from the walk: prose in columns,
    /// quotes, bodied extensions and in panels whose body the probes kept
    /// (`TextKit2ContainerScopeTests.expectedPanelKeeps`); with
    /// `sideBySide`, only the column children of a family the off-grid
    /// probe passed (`TextKit2ContainerScopeTests.sideBySideFamilies`: none)
    /// and what is below them. List text from step 6 where PR 2's rules keep
    /// it (`TK2ContainerBody.listOwners`; never right to left, which the
    /// caller subtracts). No code or expand text (the code blocks are
    /// `TK2ContainerBody.expectedCode`).
    static func expectedOwners(_ blocks: [RenderBlock], sideBySide: Bool, inContainer: Bool = false) -> Set<String> {
        var owners: Set<String> = []
        for block in blocks {
            switch block.kind {
            case .richText: if inContainer { owners.insert(block.id) }
            case .listRows(let rows): if inContainer { owners.formUnion(TK2ContainerBody.listOwners(rows)) }
            case .quote(let children): owners.formUnion(expectedOwners(children, sideBySide: sideBySide, inContainer: true))
            case .extensionPlaceholder(_, let body): owners.formUnion(expectedOwners(body, sideBySide: sideBySide, inContainer: true))
            case .panel(_, let children):
                if TextKit2ContainerScopeTests.expectedPanelKeeps(children) {
                    owners.formUnion(expectedOwners(children, sideBySide: sideBySide, inContainer: true))
                }
            case .layoutColumns(let columns):
                for child in columns.flatMap(\.blocks) {
                    if sideBySide, !TextKit2ContainerScopeTests.sideBySideFamilies.contains(TextKit2ContainerScopeTests.family(child.kind)) { continue }
                    owners.formUnion(expectedOwners([child], sideBySide: sideBySide, inContainer: true))
                }
            default: continue
            }
        }
        return owners
    }

    /// Every paragraph, heading and list leader under `blocks`, columns
    /// included.
    static func allTextOwners(_ blocks: [RenderBlock]) -> Set<String> {
        var owners = TK2ContainerBody.allTextOwners(blocks)
        for block in blocks {
            if case .layoutColumns(let columns) = block.kind {
                owners.formUnion(allTextOwners(columns.flatMap(\.blocks)))
            }
        }
        return owners
    }

    /// The leaf control behind a column (`TK2ContainerBody.leafControl` for
    /// a stacked column): each child hosted alone at the column's width,
    /// document margins around it, with the renderer and context the
    /// column's boundary gives it.
    @MainActor
    static func leafControl(_ children: [RenderBlock], width: CGFloat, env: TK2Parity.Environment) throws -> P.LeafControl {
        var result = P.LeafControl()
        let margin = P.spacing * 2
        for child in children {
            let (a, b) = try P.pair(width: width + 2 * margin, pixels: true, dark: env.dark) { arm in
                let renderer = TextKit2Scope.childRenderer(
                    for: child.kind, in: .column(sideBySide: false), inherited: arm,
                    allowed: TextKit2Scope.containerChildKinds, layoutDirection: env.direction, dynamicTypeSize: env.size
                )
                return P.environment(
                    BlockView(block: child).padding(.horizontal, margin), arm: renderer, env: env, rowWidth: width, allowed: nil
                ).environment(\.adfTextContainerContext, .container)
            }
            result.add(a, b, dark: env.dark)
        }
        return result
    }

    /// A side-by-side section's per-column pixel crops
    /// (`ProportionalColumnsLayout`'s widths, mirrored right to left).
    @MainActor
    static func columnCrops(_ columns: [PreparedColumn], rowWidth: CGFloat, scale: CGFloat, rtl: Bool) -> [P.Crop] {
        var crops: [P.Crop] = []
        var x: CGFloat = 0
        for (index, width) in TextKit2ContainerParityTests.columnWidths(columns, totalWidth: rowWidth, spacing: P.spacing * 2).enumerated() {
            crops.append(P.Crop(name: "column\(index)", columns: P.columns(from: x, to: x + width, width: rowWidth, scale: scale, rtl: rtl)))
            x += width + P.spacing * 2
        }
        return crops
    }
}

extension TextKit2ContainerParityTests {
    typealias Columns = TK2ContainerColumns

    /// One section's matrix on the production path, stacked or side by
    /// side, asserting the engine (exactly the expected owners on TextKit
    /// 2, none on the SwiftUI arm) and parity.
    func columnMatrix(_ test: String, sideBySide: Bool, sections: [Columns.Section] = Columns.sections) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let tally = P.Tally()
        var failures: [String] = []
        let gated = !TextKit2Eligibility.containerTextMatchesText
        for section in sections {
            let block = try #require(try await P.prepared([section.json]).first)
            guard case .layoutColumns(let columns) = block.kind else { throw TestFailure("\(section.name): not a layout section") }
            let text = Columns.expectedOwners([block], sideBySide: sideBySide)
            let listText = TK2ContainerBody.listOwners(in: [block])
            // From step 7 the code blocks in stacked columns, left to right
            // (side by side no column family passes: C32).
            let code = TK2ContainerBody.expectedCode([block], direction: .leftToRight, sideBySide: sideBySide)
            let expectedLTR = text.union(code)
            let everyOwner = Columns.allTextOwners([block])
            print("CONTAINER_PARITY_SHAPE test=\(test) container=columns shape=\(section.name) sideBySide=\(sideBySide) expected=\(expectedLTR.sorted()) prepared=\(P.shapeDescription(block))")
            // The boundary's family rule, for every column child.
            for child in columns.flatMap(\.blocks) {
                let gate = TextKit2Scope.containerGate(for: child.kind, in: .column(sideBySide: sideBySide), layoutDirection: .leftToRight, dynamicTypeSize: .large)
                let family = TextKit2ContainerScopeTests.family(child.kind)
                let want: TextKit2Scope.ContainerGate? = sideBySide && !TextKit2ContainerScopeTests.sideBySideFamilies.contains(family) ? .horizontalColumn : nil
                if gate != want { failures.append("\(section.name) \(child.id): containerGate \(String(describing: gate)), expected \(String(describing: want))") }
            }

            if gated {
                // Before iOS 26: no column leaf draws through TextKit 2.
                let width = P.rowWidth(documentWidth: 375)
                let env = TK2Parity.Environment(size: .large)
                let (a, b) = try P.pair(width: width, pixels: false) { arm in
                    P.environment(BlockView(block: block), arm: TK2ContainerBody.rowRenderer(block, arm), env: env, rowWidth: width,
                                  sizeClass: sideBySide ? .regular : .compact, allowed: nil)
                }
                if !(a.rows.isEmpty && b.rows.isEmpty) { failures.append("\(section.name): before iOS 26 TextKit 2 drew \(b.owners.sorted())") }
                var notGated: [String] = []
                TextKit2Scope.forEachLeaf(in: [block]) { leaf in
                    // Prose, list text and, from step 7, code below the
                    // columns: every one is gated by the OS first
                    // (`containerCodeVerdict` for code).
                    guard [.containerProse, .containerListLeader, .containerListTrailing, .containerCode].contains(leaf.position) else { return }
                    if case .fallback(.osGatedContainer) = leaf.verdict { return }
                    if case .fallback = leaf.verdict { return }
                    notGated.append(leaf.ownerID)
                }
                if !notGated.isEmpty { failures.append("\(section.name): before iOS 26 not gated: \(notGated)") }
                continue
            }

            // Stacked: every case (`TK2ContainerProbe.cases()`), compact
            // width (and at the accessibility sizes also a regular width,
            // which stacks too). Side by side: a regular width below the
            // accessibility sizes.
            var cases: [(env: TK2Parity.Environment, sizeClass: UserInterfaceSizeClass, documentWidth: CGFloat)] = []
            for (env, documentWidth) in P.cases() {
                if sideBySide {
                    if !env.size.isAccessibilitySize { cases.append((env, .regular, documentWidth)) }
                } else {
                    cases.append((env, .compact, documentWidth))
                    if env.size.isAccessibilitySize { cases.append((env, .regular, documentWidth)) }
                }
            }
            if sideBySide, !P.fullMatrix, !P.familyMatrix {
                for documentWidth in P.documentWidths { cases.append((TK2Parity.Environment(size: .xxxLarge), .regular, documentWidth)) }
            }
            for (env, sizeClass, documentWidth) in cases {
                do {
                    let rowWidth = P.rowWidth(documentWidth: documentWidth)
                    let rtl = env.direction == .rightToLeft
                    // Right to left nothing below the section (the
                    // container direction rule, lead dispositions F-Q6); at
                    // the accessibility sizes no list text (the nested-list
                    // size rule); nor
                    // list text where a stacked column (the row's bound)
                    // leaves a row no text column (rule D).
                    let narrow = sideBySide ? [] : TK2ContainerLists.narrowListText(in: [block], bound: rowWidth, size: env.size)
                    var expected = expectedLTR.subtracting(narrow)
                    if rtl { expected = [] }
                    // From xxxLarge nothing either (the container size
                    // rule, lead call C55).
                    if !TextKit2Scope.containerSizeKeepsRenderer(env.size) { expected = [] }
                    if !TextKit2Scope.nestedListSizeKeepsRenderer(env.size) { expected = expected.subtracting(listText) }
                    let pixels = P.comparesPixels(env, documentWidth: documentWidth)
                    let (a, b) = try P.pair(width: rowWidth, pixels: pixels, dark: env.dark) { arm in
                        P.environment(BlockView(block: block), arm: TK2ContainerBody.rowRenderer(block, arm), env: env, rowWidth: rowWidth,
                                      sizeClass: sizeClass, allowed: nil)
                    }
                    var verdict = P.geometry(a.guides, b.guides)
                    if sideBySide {
                        // A custom layout has no text baselines of its own:
                        // side by side the section is compared by height
                        // and pixels, column by column.
                        verdict.dFirst = 0
                        verdict.dLast = 0
                    }
                    verdict.engine = a.rows.isEmpty && b.owners == expected && b.rows.count == expected.count
                    if pixels, let ba = a.bitmap, let bb = b.bitmap {
                        let crops = sideBySide
                            ? Columns.columnCrops(columns, rowWidth: rowWidth, scale: ba.scale, rtl: rtl)
                            : [P.Crop(name: "stacked", columns: 0..<ba.width)]
                        let background = sideBySide && section.name.contains("panel")
                            ? P.sample(ba, x: rtl ? rowWidth - P.spacing * 0.75 : P.spacing * 0.75, y: P.spacing * 2.5) : P.background(env)
                        P.pixels(&verdict, ba, bb, crops: crops, background: background, rows: b.rows, dark: env.dark)
                    }
                    if !verdict.pass {
                        // The column's blocks alone at its width.
                        var control = P.LeafControl()
                        let widths = sideBySide
                            ? TextKit2ContainerParityTests.columnWidths(columns, totalWidth: rowWidth, spacing: P.spacing * 2)
                            : Array(repeating: rowWidth, count: columns.count)
                        for (index, column) in columns.enumerated() {
                            control.merge(try Columns.leafControl(column.blocks, width: widths[index], env: env))
                        }
                        verdict.leaf = control
                    }
                    let mode = sideBySide ? "sideBySide" : (sizeClass == .regular ? "stackedAX" : "stacked")
                    let fields = "test=\(test) container=columns shape=\(section.name) mode=\(mode) \(P.fields(env)) W=\(documentWidth)"
                    let key = "container=columns shape=\(section.name) mode=\(mode) dir=\(rtl ? "rtl" : "ltr")"
                    // Side by side both arms draw SwiftUI: they must match
                    // exactly, with no leaf exception.
                    let accepted = verdict.engine && verdict.geometryPass
                        && (verdict.pixelFailures.isEmpty || (!expected.isEmpty && verdict.cause == "leafDrawing"))
                    tally.add(key, label: "\(P.fields(env)) W=\(documentWidth) dH=\(P.format(verdict.dHeight)) dFirst=\(P.format(verdict.dFirst)) dLast=\(P.format(verdict.dLast)) px=\(verdict.pixelFailures.count)", verdict)
                    if !accepted || P.printsEveryCase || !verdict.pass {
                        print(P.line(fields, verdict, a, b).replacingOccurrences(of: "CONTAINER_PROBE ", with: "CONTAINER_PARITY ") + " accepted=\(accepted)")
                    }
                    if !accepted {
                        failures.append("\(fields): engine=\(verdict.engine) (textKit2 owners \(b.owners.sorted()), expected \(expected.sorted()), swiftUI rows \(a.rows.count)) dH=\(P.format(verdict.dHeight)) dFirst=\(P.format(verdict.dFirst)) dLast=\(P.format(verdict.dLast)) cause=\(verdict.cause) px=\(verdict.pixelFailures.first ?? "-")\(verdict.geometryPass && !verdict.pixelFailures.isEmpty ? " residualMismatch={\(verdict.residualMismatch ?? "-")}" : "")")
                        if let ba = a.bitmap, let bb = b.bitmap { P.dump(key, fields, ba, bb) }
                    }
                    let unexpected = b.owners.intersection(everyOwner).subtracting(expected)
                    if !unexpected.isEmpty { failures.append("\(fields): unexpected TextKit 2 owners \(unexpected.sorted())") }
                }
            }
        }
        tally.print(probe: test)
        print("CONTAINER_PARITY_TIME test=\(test) container=columns scale=\(TK2Parity.nativeScale) os=\(TK2Parity.osVersion) mode=\(P.mode) gated=\(gated) elapsed=\(clock.now - start)")
        #expect(failures.isEmpty, "\(failures.count) failing cases: \(failures.prefix(6))")
    }

    @Test("stackedColumns: column prose (paragraphs, headings, panels, quotes and extension bodies in columns) matches SwiftUI through the production path when the columns stack; from step 7 code beside it draws on TextKit 2 left to right")
    func stackedColumns() async throws {
        // The list shapes run in `nestedListInStackedColumn`.
        try await columnMatrix("stackedColumns", sideBySide: false, sections: Columns.proseSections)
    }

    @Test("horizontalColumns: side by side, every column family stays on SwiftUI (the off-grid probe passed none) and both arms draw the section alike")
    func horizontalColumns() async throws {
        try await columnMatrix("horizontalColumns", sideBySide: true)
    }
}

// MARK: - Column scope: the width rules and the order

/// Records, per named probe, the width bound it reads, the width it is
/// proposed and where it sits. A custom block reads no text and sets no
/// renderer, so it sees exactly what the column above it wrote.
@MainActor
private final class ColumnProbeRecorder {
    var bounds: [String: TextKit2WidthBound] = [:]
    var frames: [String: CGRect] = [:]

    func complete(_ names: [String]) -> Bool {
        names.allSatisfy { bounds[$0] != nil && frames[$0] != nil }
    }
}

/// Claims every `blockCard` whose URL is `colprobe:<name>`.
private struct ColumnProbeRenderer: ADFCustomBlockRenderer {
    let rendererID = "test.column-probe"
    let recorder: ColumnProbeRecorder

    func claim(for node: ADFNode) -> ADFCustomBlockClaim? {
        guard case .blockCard(let url, _) = node.kind, let url, url.hasPrefix("colprobe:") else { return nil }
        return ADFCustomBlockClaim(String(url.dropFirst("colprobe:".count)), sizing: .reflowingText)
    }

    @MainActor
    func content(for value: String, context: ADFCustomBlockContext) -> some View {
        ColumnProbeView(name: value, recorder: recorder)
    }
}

private struct ColumnProbeView: View {
    let name: String
    let recorder: ColumnProbeRecorder
    @Environment(\.adfTextWidthBound) private var bound

    var body: some View {
        Color.clear
            .frame(height: 4)
            .onChange(of: bound, initial: true) { _, bound in recorder.bounds[name] = bound }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { recorder.frames[name] = $0 }
    }
}

extension TextKit2ContainerScopeTests {
    typealias CP = TK2ContainerProbe

    /// What one arm of a hosted document showed: its TextKit 2 rows by
    /// owner (window frames), and the column probes.
    struct ColumnArm {
        var rows: [String: CGRect]
        var bounds: [String: TextKit2WidthBound]
        var frames: [String: CGRect]
    }

    static func colprobe(_ name: String) -> String {
        "{\"type\":\"blockCard\",\"attrs\":{\"url\":\"colprobe:\(name)\"}}"
    }

    static func column(_ width: Double, _ content: [String]) -> String {
        "{\"type\":\"layoutColumn\",\"attrs\":{\"width\":\(width)},\"content\":[\(content.joined(separator: ","))]}"
    }

    static func section(_ columns: [String]) -> String {
        "{\"type\":\"layoutSection\",\"content\":[\(columns.joined(separator: ","))]}"
    }

    static func indented(_ level: Int, _ text: String) -> String {
        "{\"type\":\"paragraph\",\"marks\":[{\"type\":\"indentation\",\"attrs\":{\"level\":\(level)}}],\"content\":[{\"type\":\"text\",\"text\":\"\(text)\"}]}"
    }

    /// `content` in the document view (a window `width` wide: rows
    /// `width − 32`), under `arm`, at a horizontal size class, Large text;
    /// waits for every probe in `probes`.
    @MainActor
    static func hostColumns(
        _ content: [String], probes: [String], arm: ADFTextRenderer, width: CGFloat, sizeClass: UserInterfaceSizeClass
    ) async throws -> ColumnArm {
        let recorder = ColumnProbeRecorder()
        let json = "{\"version\":1,\"type\":\"doc\",\"content\":[\(content.joined(separator: ","))]}"
        let model = ADFDocumentModel(customRenderers: [ColumnProbeRenderer(recorder: recorder)])
        model.load(data: Data(json.utf8))
        for _ in 0..<500 where model.phase != .ready {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.phase == .ready)
        let document = ADFDocumentView(model: model, mediaProvider: TextKit2DiagnosticsTests.NoMedia(), textRenderer: arm)
            .environment(\.horizontalSizeClass, sizeClass)
            .dynamicTypeSize(.large)
        let hosted = TK2CodeLogic.Hosted(document, size: CGSize(width: width, height: 2_400))
        defer { hosted.close() }
        for _ in 0..<250 where !recorder.complete(probes) {
            hosted.window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        try await hosted.settle()
        #expect(recorder.complete(probes), "probes without a bound or a frame: \(probes.filter { recorder.bounds[$0] == nil || recorder.frames[$0] == nil })")
        var rows: [String: CGRect] = [:]
        for row in hosted.rows {
            if let owner = row.ownerID { rows[owner] = row.convert(row.bounds, to: nil) }
        }
        return ColumnArm(rows: rows, bounds: recorder.bounds, frames: recorder.frames)
    }

    /// Both arms of `content`; every probe's frame (its width, and its top:
    /// the bottom of the text above it) must be the same on both.
    @MainActor
    static func hostColumnPair(
        _ content: [String], probes: [String], width: CGFloat, sizeClass: UserInterfaceSizeClass, label: String
    ) async throws -> (swiftUI: ColumnArm, textKit2: ColumnArm) {
        let a = try await hostColumns(content, probes: probes, arm: .swiftUI, width: width, sizeClass: sizeClass)
        let c = try await hostColumns(content, probes: probes, arm: .textKit2, width: width, sizeClass: sizeClass)
        let scale = TK2Parity.nativeScale
        for name in probes {
            guard let fa = a.frames[name], let fc = c.frames[name] else { continue }
            #expect(abs(fa.minX - fc.minX) <= 0.5 / scale && abs(fa.width - fc.width) <= 0.5 / scale && abs(fa.minY - fc.minY) <= 0.5 / scale,
                    "\(label) \(name): frame \(fa) on SwiftUI, \(fc) on TextKit 2")
        }
        #expect(a.rows.isEmpty, "\(label): TextKit 2 rows on the SwiftUI arm: \(a.rows.keys.sorted())")
        return (a, c)
    }

    /// One column's blocks behind the stacked boundary, given the bound a
    /// side-by-side section computes for that column: the leaf's width
    /// rule alone (`containerGate(widthBound:inset:layoutPolicy:)`), which
    /// side by side the boundary's family rule (`.horizontalColumn`)
    /// precedes. Returns the owners that drew on TextKit 2.
    @MainActor
    static func widthRuleOwners(_ column: PreparedColumn, bound: CGFloat) throws -> (swiftUI: Set<String>, textKit2: Set<String>) {
        let env = TK2Parity.Environment(size: .large)
        let width = max(bound, 1)
        let (a, b) = try CP.pair(width: width, pixels: false) { arm in
            CP.environment(LayoutColumnContentView(column: column, sideBySide: false, widthBound: .atLeast(bound)),
                           arm: arm, env: env, rowWidth: width, sizeClass: .compact, allowed: nil)
        }
        return (a.owners, b.owners)
    }

    /// The common shape of the three negative-scope cases and the positive
    /// control (plan §4.2), hosted side by side and stacked:
    /// - production side by side: the boundary's family rule keeps every
    ///   owner on SwiftUI (`.horizontalColumn`), no TextKit 2 row, and the
    ///   same frames on both arms;
    /// - the width rule behind it, for `narrow` (owner, column index,
    ///   inset): `.narrowColumn` at the column's side-by-side bound
    ///   wherever `textFitsAt` says it does not fit, with no row through
    ///   the stacked boundary at that bound, and a row where it fits;
    /// - stacked (a compact width): every owner is a TextKit 2 row (each
    ///   column has the section's width).
    @MainActor
    static func columnEdgeCase(
        _ name: String, columns: [(percent: Double, blocks: [String])], owners: [String],
        narrow: [(owner: String, column: Int, inset: CGFloat)], windowWidths: [CGFloat]
    ) async throws -> [CGFloat: [CGFloat]] {
        let probes = columns.indices.map { "\(name)-\($0)" }
        let json = section(columns.enumerated().map { index, item in column(item.percent, item.blocks + [colprobe(probes[index])]) })
        let after = paragraph("After the section.")
        let blocks = DocumentPreparer(theme: .default).prepare(try await ADFParser().parse(Data("{\"version\":1,\"type\":\"doc\",\"content\":[\(json)]}".utf8)))
        guard case .layoutColumns(let prepared) = try #require(blocks.first).kind else { throw TestFailure("\(name): not a section") }
        var laidOut: [CGFloat: [CGFloat]] = [:]
        for windowWidth in windowWidths {
            let label = "\(name) W=\(windowWidth)"
            let rowWidth = windowWidth - 4 * ADFTheme.default.spacing
            // Production, side by side.
            let side = try await hostColumnPair([json, after], probes: probes, width: windowWidth, sizeClass: .regular, label: "\(label) side by side")
            #expect(side.textKit2.rows.keys.filter { $0.hasPrefix("0.0.") }.isEmpty,
                    "\(label) side by side: column text on TextKit 2: \(side.textKit2.rows.keys.sorted())")
            // The root paragraph after the section is a TextKit 2 row: the
            // switch reached the document (the control).
            #expect(side.textKit2.rows["0.1"] != nil, "\(label): the root paragraph after the section is not a TextKit 2 row")
            let fractions = { () -> [Double] in
                let total = columns.reduce(0) { $0 + max($1.percent, 0) }
                guard total > 0 else { return Array(repeating: 1 / Double(columns.count), count: columns.count) }
                return columns.map { max($0.percent, 0) / total }
            }()
            let shares = ProportionalColumnsLayout.columnWidths(totalWidth: rowWidth, fractions: fractions, spacing: ADFTheme.default.spacing * 2)
            laidOut[windowWidth] = probes.map { side.swiftUI.frames[$0]?.width ?? -1 }
            for (index, probe) in probes.enumerated() {
                // The column's bound is its share of the row, on the
                // TextKit 2 arm (the SwiftUI arm writes `.pending`).
                #expect(side.textKit2.bounds[probe] == .atLeast(shares[index]), "\(label) \(probe): bound \(String(describing: side.textKit2.bounds[probe])), share \(shares[index])")
                #expect(side.swiftUI.bounds[probe] == .pending, "\(label) \(probe): SwiftUI arm bound \(String(describing: side.swiftUI.bounds[probe]))")
            }
            for owner in owners {
                let block = try #require(prepared.flatMap(\.blocks).first { $0.id == owner }, "\(owner)")
                #expect(TextKit2Scope.containerGate(for: block.kind, in: .column(sideBySide: true), layoutDirection: .leftToRight, dynamicTypeSize: .large) == .horizontalColumn,
                        "\(label) \(owner): the side-by-side family rule")
            }
            // The width rule behind the family rule.
            for item in narrow {
                let bound = shares[item.column]
                let fits = TextKit2Scope.textFits(.atLeast(bound), inset: item.inset)
                #expect(TextKit2Scope.containerGate(widthBound: .atLeast(bound), inset: item.inset, layoutPolicy: .wrapping) == (fits ? nil : .narrowColumn),
                        "\(label) \(item.owner): bound \(bound) inset \(item.inset)")
                let drawn = try widthRuleOwners(prepared[item.column], bound: bound)
                #expect(drawn.swiftUI.isEmpty)
                if TextKit2Eligibility.containerTextMatchesText {
                    #expect(drawn.textKit2.contains(item.owner) == fits,
                            "\(label) \(item.owner) at bound \(bound): \(fits ? "fits, must draw on TextKit 2" : "narrowColumn, must stay on SwiftUI") (TextKit 2 owners \(drawn.textKit2.sorted()))")
                }
                print("COLUMN_EDGE case=\(name) W=\(windowWidth) owner=\(item.owner) column=\(item.column) bound=\(bound) inset=\(item.inset) fits=\(fits) widthRuleTK2=\(drawn.textKit2.contains(item.owner))")
            }
            // Stacked: each column has the row's width, and its prose is
            // TextKit 2.
            let stacked = try await hostColumnPair([json, after], probes: probes, width: windowWidth, sizeClass: .compact, label: "\(label) stacked")
            for probe in probes {
                #expect(stacked.textKit2.bounds[probe] == .atLeast(rowWidth), "\(label) stacked \(probe): \(String(describing: stacked.textKit2.bounds[probe]))")
            }
            let stackedOwners = Set(stacked.textKit2.rows.keys)
            #expect(stackedOwners.isSuperset(of: Self.passing(Set(owners))), "\(label) stacked: TextKit 2 owners \(stackedOwners.sorted()), expected \(owners)")
        }
        return laidOut
    }

    @Test("zeroPercentColumn: side by side a zero-percent column's paragraph stays on SwiftUI (the family rule; behind it the width rule answers narrowColumn at its 0 pt bound), its code block alike, with equal frames on both arms; stacked it is TextKit 2")
    @MainActor
    func zeroPercentColumn() async throws {
        let code = "{\"type\":\"codeBlock\",\"content\":[{\"type\":\"text\",\"text\":\"let zero = 0\\nprint(zero)\"}]}"
        _ = try await Self.columnEdgeCase(
            "zero", columns: [(0, [Self.paragraph("A paragraph in a zero-percent column."), code]), (100, [Self.paragraph("A paragraph beside it.")])],
            owners: ["0.0.0.0", "0.0.1.0"], narrow: [("0.0.0.0", 0, 0), ("0.0.1.0", 1, 0)], windowWidths: [402]
        )
    }

    @Test("negativePercentColumn: a negative-percent column takes no width; its paragraph stays on SwiftUI side by side (family rule; narrowColumn behind it), equal frames on both arms; stacked it is TextKit 2")
    @MainActor
    func negativePercentColumn() async throws {
        _ = try await Self.columnEdgeCase(
            "negative", columns: [(-25, [Self.paragraph("A paragraph in a negative-percent column.")]), (100, [Self.paragraph("A paragraph beside it.")])],
            owners: ["0.0.0.0", "0.0.1.0"], narrow: [("0.0.0.0", 0, 0), ("0.0.1.0", 1, 0)], windowWidths: [402]
        )
    }

    @Test("indentedParagraphInNarrowColumn: a level-6 paragraph (144 pt) in the 25 % column of a 25/75 section: side by side SwiftUI at 402 and 640 pt (family rule); behind it narrowColumn in the 88.5 pt column, TextKit 2 in the 148 pt one; stacked TextKit 2")
    @MainActor
    func indentedParagraphInNarrowColumn() async throws {
        let inset = CGFloat(6) * ADFTheme.default.spacing * 3
        #expect(inset == 144)
        _ = try await Self.columnEdgeCase(
            "indent6", columns: [(25, [Self.indented(6, "A level-6 indented paragraph in the narrow column.")]), (75, [Self.paragraph("The wide column beside it.")])],
            owners: ["0.0.0.0", "0.0.1.0"], narrow: [("0.0.0.0", 0, inset)], windowWidths: [402, 640]
        )
        // The plan's widths: 88.5 pt at 402 (row 370), 148 pt at 640 (row 608).
        #expect(ProportionalColumnsLayout.columnWidths(totalWidth: 370, fractions: [0.25, 0.75], spacing: 16)[0] == 88.5)
        #expect(ProportionalColumnsLayout.columnWidths(totalWidth: 608, fractions: [0.25, 0.75], spacing: 16)[0] == 148)
    }

    @Test("allNonPositiveColumnsAreEqual: a section whose columns are all at or below zero percent lays out as equal columns on both arms; its text is TextKit 2 where columns stack and behind the width rule, SwiftUI side by side (family rule)")
    @MainActor
    func allNonPositiveColumnsAreEqual() async throws {
        let laid = try await Self.columnEdgeCase(
            "allNonPositive", columns: [(0, [Self.paragraph("The first equal column.")]), (-10, [Self.paragraph("The second equal column.")])],
            owners: ["0.0.0.0", "0.0.1.0"], narrow: [("0.0.0.0", 0, 0), ("0.0.1.0", 1, 0)], windowWidths: [402]
        )
        let widths = try #require(laid[402])
        let scale = TK2Parity.nativeScale
        #expect(widths.count == 2 && abs(widths[0] - widths[1]) <= 1 / scale && abs(widths[0] - 177) <= 1 / scale,
                "equal columns of (370 − 16) / 2 = 177 pt: \(widths)")
    }

    @Test("columnOrderIsColumnMajor: the owner order and the accessibility order across columns are column-major, stacked and side by side, on both arms, and the same in both modes")
    @MainActor
    func columnOrderIsColumnMajor() async throws {
        let sentinels = ["COLA1", "COLA2", "COLB1", "COLB2", "COLB3"]
        let json = Self.section([
            Self.column(25, [Self.paragraph("COLA1 first in the narrow column."), Self.paragraph("COLA2 second in the narrow column.")]),
            Self.column(75, [
                Self.paragraph("COLB1 first in the wide column, long enough to wrap beside the narrow one."),
                "{\"type\":\"heading\",\"attrs\":{\"level\":4},\"content\":[{\"type\":\"text\",\"text\":\"COLB2 a heading in the wide column\"}]}",
                Self.paragraph("COLB3 last in the wide column."),
            ]),
        ])
        let blocks = DocumentPreparer(theme: .default).prepare(try await ADFParser().parse(Data("{\"version\":1,\"type\":\"doc\",\"content\":[\(json)]}".utf8)))
        let columnMajor = ["0.0.0.0", "0.0.0.1", "0.0.1.0", "0.0.1.1", "0.0.1.2"]
        // The owner order: the walk (and so the coverage and search
        // order) is column-major, whatever the mode.
        var walked: [String] = []
        TextKit2Scope.forEachLeaf(in: blocks) { walked.append($0.ownerID) }
        #expect(walked == columnMajor)
        var orders: [String: [String]] = [:]
        for sizeClass in [UserInterfaceSizeClass.compact, .regular] {
            for arm in [ADFTextRenderer.swiftUI, .textKit2] {
                let label = "\(sizeClass == .regular ? "side by side" : "stacked") \(arm)"
                let document = ADFDocumentView(model: try await Self.loadedModel(json), mediaProvider: TextKit2DiagnosticsTests.NoMedia(), textRenderer: arm)
                    .environment(\.horizontalSizeClass, sizeClass)
                    .dynamicTypeSize(.large)
                let hosted = TK2CodeLogic.Hosted(document, size: CGSize(width: 820, height: 1_600))
                defer { hosted.close() }
                try await hosted.settle()
                // TextKit 2 rows (stacked, TextKit 2 arm): their owners
                // top to bottom are column-major.
                let rows = hosted.rows.compactMap { row -> (String, CGRect)? in
                    guard let owner = row.ownerID else { return nil }
                    return (owner, row.convert(row.bounds, to: nil))
                }.sorted { $0.1.minY < $1.1.minY }
                let expectedRows = (arm == .textKit2 && sizeClass == .compact) ? Self.passing(Set(columnMajor)) : []
                #expect(Set(rows.map(\.0)) == expectedRows, "\(label): TextKit 2 rows \(rows.map(\.0))")
                #expect(rows.map(\.0) == columnMajor.filter { expectedRows.contains($0) }, "\(label): rows top to bottom \(rows.map(\.0))")
                // The accessibility order, as far as the tree lists the
                // column text without an assistive client (TextKit 2 rows
                // always; SwiftUI text not always, which the VoiceOver UI
                // test covers): column-major.
                let spoken = TK2CodeParity.spokenElements(under: hosted.host.view).compactMap { element in
                    sentinels.first { element.label.hasPrefix($0) }
                }
                orders[label] = spoken
                print("COLUMN_ORDER mode=\(label) spoken=\(spoken)")
                #expect(spoken == sentinels.filter { spoken.contains($0) }, "\(label): accessibility order \(spoken) is not column-major")
                if !expectedRows.isEmpty {
                    #expect(spoken == sentinels, "\(label): every TextKit 2 row is listed, column-major: \(spoken)")
                }
            }
        }
        // Where both modes list the whole section, they list it alike.
        let complete = orders.filter { $0.value == sentinels }.keys.sorted()
        print("COLUMN_ORDER complete=\(complete)")
        #expect(orders.values.allSatisfy { $0 == sentinels.filter($0.contains) })
    }

    @MainActor
    static func loadedModel(_ json: String) async throws -> ADFDocumentModel {
        let model = ADFDocumentModel()
        model.load(data: Data("{\"version\":1,\"type\":\"doc\",\"content\":[\(json)]}".utf8))
        for _ in 0..<500 where model.phase != .ready {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.phase == .ready)
        return model
    }
}
#endif
