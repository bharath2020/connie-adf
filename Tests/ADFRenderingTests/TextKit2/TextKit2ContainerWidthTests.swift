import Foundation
import CoreGraphics
import Testing
import ADFModel
import ADFPreparation
@testable import ADFRendering

/// The width contract: `adfTextWidthBound` is a guaranteed lower bound on
/// the width text is laid out at, for eligibility only. `DocumentRow` seeds
/// it with the row's content width, breakout included
/// (`TextKit2WidthBound.rowSeed`); each container boundary narrows it for
/// its children (`View.adfContainerChild`, plan §4.2) and writes `.pending`
/// under a SwiftUI parent; list rule D (`TextKit2Scope.listTextFits`) and
/// the under-1-pt guard on every wrapping leaf (`TextKit2Scope.textFits`)
/// read it.
@Suite("TextKit 2 container width contract", .serialized)
struct TextKit2ContainerWidthTests {
    /// The document margin `ADFDocumentView` passes its rows (2 × spacing).
    static let margin: CGFloat = 16

    @Test("a row's content width is the column, widened by its breakout mark and capped by the mark's custom width")
    func rowContentWidth() {
        let column: CGFloat = 343
        let cases: [(BlockBreakout?, CGFloat, String)] = [
            (nil, 343, "no breakout"),
            (BlockBreakout(mode: .wide, width: nil), 359, "wide: half the margin each side"),
            (BlockBreakout(mode: .fullWidth, width: nil), 375, "full width: the whole margin each side"),
            (BlockBreakout(mode: .wide, width: 200), 200, "wide, capped below the column"),
            (BlockBreakout(mode: .fullWidth, width: 250), 250, "full width, capped below the column"),
            (BlockBreakout(mode: .fullWidth, width: 360), 360, "full width, capped between the column and full width"),
            (BlockBreakout(mode: .wide, width: 1_000), 359, "wide, with a cap above its width"),
            (BlockBreakout(mode: .wide, width: .infinity), 359, "an infinite cap"),
            (BlockBreakout(mode: .wide, width: 0), 0, "a zero cap"),
            (BlockBreakout(mode: .fullWidth, width: -40), 0, "a negative cap clamps at 0"),
            (BlockBreakout(mode: .wide, width: -.infinity), 0, "a cap of minus infinity clamps at 0"),
            (BlockBreakout(mode: .wide, width: .nan), 0, "a cap that is not a number counts as 0"),
        ]
        for (breakout, expected, label) in cases {
            let width = TextKit2WidthBound.rowContentWidth(container: column, breakout: breakout, margin: Self.margin)
            #expect(width == expected, "\(label): \(width)")
            let seed = TextKit2WidthBound.rowSeed(container: column, breakout: breakout, margin: Self.margin)
            #expect(seed == .atLeast(expected), "\(label): \(seed)")
        }
        // Before the stack's first width observation the seed is permissive.
        for container in [CGFloat(0), -1, .nan] {
            for breakout in [nil, BlockBreakout(mode: .fullWidth, width: 200)] {
                #expect(TextKit2WidthBound.rowSeed(container: container, breakout: breakout, margin: Self.margin) == .pending)
            }
        }
    }

    @Test("textFits: pending passes, unproven fails, a known bound passes with 1 pt left after the inset; rule D is the same test")
    func textFitsTruthTable() {
        #expect(TextKit2Scope.minimumTextWidth == 1)
        #expect(TextKit2Scope.minimumListTextWidth == 1)
        let cases: [(TextKit2WidthBound, CGFloat, Bool)] = [
            (.pending, 0, true), (.pending, 144, true), (.pending, 10_000, true),
            (.unproven, 0, false), (.unproven, 144, false), (.unproven, -10_000, false),
            (.atLeast(343), 0, true), (.atLeast(343), 144, true), (.atLeast(343), 342, true), (.atLeast(343), 342.5, false),
            (.atLeast(1), 0, true), (.atLeast(0.999), 0, false), (.atLeast(1.0 / 3), 0, false), (.atLeast(0), 0, false),
            (.atLeast(145), 144, true), (.atLeast(144.5), 144, false), (.atLeast(144), 144, false),
            // A level-6 paragraph (144 pt indent) in the 25 % column of a 25/75
            // section: 88.5 pt in a 402 pt document, 148 pt in a 640 pt one.
            (.atLeast(88.5), 144, false), (.atLeast(148), 144, true),
        ]
        for (bound, inset, expected) in cases {
            #expect(TextKit2Scope.textFits(bound, inset: inset) == expected, "textFits(\(bound), inset: \(inset))")
            #expect(TextKit2Scope.listTextFits(bound, inset: inset) == expected, "listTextFits(\(bound), inset: \(inset))")
        }
    }
}

#if canImport(UIKit)
import SwiftUI
import UIKit

/// What each width probe saw: the bound it read and the width it was laid
/// out at, by probe name.
@MainActor
private final class WidthProbeRecorder {
    var bounds: [String: TextKit2WidthBound] = [:]
    var widths: [String: CGFloat] = [:]
    /// Each probe's leading edge in the window (global coordinates).
    var minXs: [String: CGFloat] = [:]
    /// Each hosted top-level block's leading edge, by block id
    /// (`DirectBlocks`).
    var blockMinXs: [String: CGFloat] = [:]

    /// Whether every probe in `names` reported a width and a bound, a known
    /// one when `known` (a bound reaches a probe as `.pending` before the
    /// stack's first width observation, and stays `.pending` below a
    /// container whose boundary gets SwiftUI).
    func complete(_ names: [String], known: Bool = true) -> Bool {
        names.allSatisfy { name in
            guard widths[name] != nil, minXs[name] != nil, let bound = bounds[name] else { return false }
            return !known || bound != .pending
        }
    }
}

/// Claims every `blockCard` whose URL is `probe:<name>` and draws a probe
/// that fills the width it is proposed and records it with the width bound
/// it reads. A custom block sets no renderer and reads no text, so it sees
/// exactly what the views above it wrote.
private struct WidthProbeRenderer: ADFCustomBlockRenderer {
    let rendererID = "test.width-probe"
    let recorder: WidthProbeRecorder

    func claim(for node: ADFNode) -> ADFCustomBlockClaim? {
        guard case .blockCard(let url, _) = node.kind, let url, url.hasPrefix("probe:") else { return nil }
        return ADFCustomBlockClaim(String(url.dropFirst("probe:".count)), sizing: .reflowingText)
    }

    @MainActor
    func content(for value: String, context: ADFCustomBlockContext) -> some View {
        WidthProbeView(name: value, recorder: recorder)
    }
}

private struct WidthProbeView: View {
    let name: String
    let recorder: WidthProbeRecorder
    @Environment(\.adfTextWidthBound) private var bound

    var body: some View {
        Color.clear
            .frame(height: 12)
            .onChange(of: bound, initial: true) { _, bound in recorder.bounds[name] = bound }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { recorder.widths[name] = $0 }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: { recorder.minXs[name] = $0 }
    }
}

extension TextKit2ContainerWidthTests {
    static func probe(_ name: String) -> String {
        "{\"type\":\"blockCard\",\"attrs\":{\"url\":\"probe:\(name)\"}}"
    }

    static func breakoutMarks(_ mode: String?, _ width: Double?) -> String {
        guard let mode else { return "" }
        let custom = width.map { ",\"width\":\($0)" } ?? ""
        return ",\"marks\":[{\"type\":\"breakout\",\"attrs\":{\"mode\":\"\(mode)\"\(custom)}}]"
    }

    static func document(_ blocks: [String]) -> String {
        "{\"version\":1,\"type\":\"doc\",\"content\":[\(blocks.joined(separator: ","))]}"
    }

    /// The breakout cases at a 375 pt window: a 343 pt document column inside
    /// the 16 pt margins. The custom widths 200 and 250 cap the row below the
    /// column, where a seed of the bare column would be too large.
    static let breakoutCases: [(name: String, mode: String?, width: Double?, rowWidth: CGFloat)] = [
        ("plain", nil, nil, 343),
        ("wide", "wide", nil, 359),
        ("full", "full-width", nil, 375),
        ("wide200", "wide", 200, 200),
        ("full250", "full-width", 250, 250),
    ]
    static let windowWidth: CGFloat = 375
    static let column: CGFloat = 343

    /// Hosts `json` in `ADFDocumentView` with the switch ON, waits for every
    /// probe in `probes` to report a width and a bound (a known one when
    /// `known`), and returns the window (keep it until done).
    @MainActor
    fileprivate static func host(
        _ json: String, probes: [String], recorder: WidthProbeRecorder, width: CGFloat = windowWidth,
        sizeClass: UserInterfaceSizeClass = .compact, openExpands: Bool = false, known: Bool = true
    ) async throws -> UIWindow {
        let model = ADFDocumentModel(customRenderers: [WidthProbeRenderer(recorder: recorder)])
        model.load(data: Data(json.utf8))
        for _ in 0..<500 where model.phase != .ready {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.phase == .ready)
        if openExpands {
            for block in model.blocks {
                if case .expand = block.kind { model.expandedBlocks.insert(block.id) }
            }
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 3_000))
        let host = UIHostingController(rootView: ADFDocumentView(
            model: model, mediaProvider: TextKit2DiagnosticsTests.NoMedia(), textRenderer: .textKit2
        ).environment(\.horizontalSizeClass, sizeClass))
        window.rootViewController = host
        window.isHidden = false
        try await waitForProbes(probes, recorder: recorder, window: window, known: known)
        return window
    }

    @MainActor
    fileprivate static func waitForProbes(
        _ probes: [String], recorder: WidthProbeRecorder, window: UIWindow, known: Bool = true
    ) async throws {
        for _ in 0..<250 where !recorder.complete(probes, known: known) {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        try await TextKit2DiagnosticsTests.settle(window)
        let incomplete = probes.filter { name in
            recorder.bounds[name] == nil || (known && recorder.bounds[name] == .pending) || recorder.widths[name] == nil
        }
        #expect(incomplete.isEmpty, "probes without a\(known ? " known" : "") bound or a width: \(incomplete)")
    }

    @MainActor
    fileprivate static func close(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    /// Layout sections with a breakout mark, two 50 % columns each. The
    /// section's laid-out width is the row seed: its own width, capped by
    /// the custom width where there is one (never the bare column). The
    /// bound reaching a column's blocks comes from the column boundary
    /// (`adfContainerChild`): while the production allow list leaves layout
    /// columns out (PR 4 before step 4), the section's row is SwiftUI and
    /// the boundary writes `.pending`; once they are in, it is the seed
    /// stacked (each column is proposed the section's width) and the
    /// column's share of it side by side.
    @Test("a layout section's breakout and custom width reach its columns through the column boundary, never as the bare column", arguments: [false, true])
    @MainActor
    func breakoutCappedColumns(sideBySide: Bool) async throws {
        let sizeClass: UserInterfaceSizeClass = sideBySide ? .regular : .compact
        let recorder = WidthProbeRecorder()
        let blocks = Self.breakoutCases.map { item in
            "{\"type\":\"layoutSection\"\(Self.breakoutMarks(item.mode, item.width)),\"content\":["
                + "{\"type\":\"layoutColumn\",\"attrs\":{\"width\":50},\"content\":[\(Self.probe("\(item.name)-0"))]},"
                + "{\"type\":\"layoutColumn\",\"attrs\":{\"width\":50},\"content\":[\(Self.probe("\(item.name)-1"))]}]}"
        }
        let probes = Self.breakoutCases.flatMap { ["\($0.name)-0", "\($0.name)-1"] }
        let enabled = TextKit2Scope.containerChildKinds.contains(.layoutColumns)
        let window = try await Self.host(
            Self.document(blocks), probes: probes, recorder: recorder, sizeClass: sizeClass, known: enabled
        )
        defer { Self.close(window) }
        let scale = window.traitCollection.displayScale
        let spacing = ADFTheme.default.spacing * 2
        for item in Self.breakoutCases {
            let label = "\(item.name) \(sideBySide ? "side by side" : "stacked")"
            let first = recorder.widths["\(item.name)-0"] ?? 0, second = recorder.widths["\(item.name)-1"] ?? 0
            // The section's laid-out width, from its columns.
            let section = sideBySide ? first + spacing + second : first
            #expect(abs(section - item.rowWidth) <= 1 / scale, "\(label): section laid out \(section) wide, expected \(item.rowWidth)")
            let shares = ProportionalColumnsLayout.columnWidths(totalWidth: item.rowWidth, fractions: [0.5, 0.5], spacing: spacing)
            for (index, probe) in ["\(item.name)-0", "\(item.name)-1"].enumerated() {
                let expected: TextKit2WidthBound = enabled ? .atLeast(sideBySide ? shares[index] : item.rowWidth) : .pending
                #expect(recorder.bounds[probe] == expected, "\(label) \(probe): bound \(String(describing: recorder.bounds[probe])), expected \(expected)")
                guard case .atLeast(let bound) = recorder.bounds[probe] else { continue }
                #expect(bound <= section, "\(label) \(probe): bound \(bound) over the section's width \(section)")
                let laid = recorder.widths[probe] ?? 0
                #expect(bound <= laid + 1 / scale, "\(label) \(probe): bound \(bound) over the width the block is laid out at, \(laid)")
            }
            if item.rowWidth < Self.column {
                // The test tells the seeds apart: the bare column is wider
                // than this row really is.
                #expect(Self.column > section + 1, "\(label): a capped section narrower than the column")
            }
        }
    }

    /// Open expands with a breakout mark. The expand's laid-out width is the
    /// row seed: its body's width plus its horizontal padding (1.25 ×
    /// spacing each side), capped by the custom width where there is one,
    /// never the bare column. The bound reaching the body comes from the
    /// expand body boundary: `.pending` while the production allow list
    /// leaves expands out (PR 4 before step 5), and the seed less the
    /// body's padding once they are in.
    @Test("an expand's breakout and custom width reach its body through the expand body boundary, never as the bare column")
    @MainActor
    func breakoutCappedExpand() async throws {
        let recorder = WidthProbeRecorder()
        let cases = Self.breakoutCases.filter { $0.name != "full" }
        let blocks = cases.map { item in
            "{\"type\":\"expand\",\"attrs\":{\"title\":\"\(item.name)\"}\(Self.breakoutMarks(item.mode, item.width)),\"content\":[\(Self.probe(item.name))]}"
        }
        let enabled = TextKit2Scope.containerChildKinds.contains(.expand)
        let window = try await Self.host(
            Self.document(blocks), probes: cases.map(\.name), recorder: recorder, openExpands: true, known: enabled
        )
        defer { Self.close(window) }
        let scale = window.traitCollection.displayScale
        let padding = ADFTheme.default.spacing * 1.25 * 2
        for item in cases {
            let body = recorder.widths[item.name] ?? 0
            let expand = body + padding
            #expect(abs(expand - item.rowWidth) <= 1 / scale, "\(item.name): expand laid out \(expand) wide, expected \(item.rowWidth)")
            let expected: TextKit2WidthBound = enabled ? .atLeast(max(item.rowWidth - padding, 0)) : .pending
            #expect(recorder.bounds[item.name] == expected, "\(item.name): bound \(String(describing: recorder.bounds[item.name])), expected \(expected)")
            guard case .atLeast(let bound) = recorder.bounds[item.name] else { continue }
            #expect(bound <= body + 1 / scale, "\(item.name): bound \(bound) over the body's width \(body)")
            if item.rowWidth < Self.column {
                #expect(Self.column > expand + 1, "\(item.name): a capped expand narrower than the column")
            }
        }
    }

    /// The seed reaches root leaves through the under-1-pt guard
    /// (`TextKit2Leaf`): a level-6 paragraph (144 pt indent) is TextKit 2 in
    /// a 343 pt column and SwiftUI in a 128 pt one; a paragraph whose
    /// breakout caps it at half a point stays SwiftUI at both, which only the
    /// breakout-aware seed can tell; a plain paragraph is TextKit 2 at both;
    /// code under the same cap keeps TextKit 2, because code never wraps and
    /// the guard exempts it.
    @Test("root leaves read the row seed through the under-1-pt guard; code is exempt", arguments: [CGFloat(375), 160])
    @MainActor
    func rootLeafGuard(windowWidth: CGFloat) async throws {
        let json = Self.document([
            "{\"type\":\"paragraph\",\"marks\":[{\"type\":\"indentation\",\"attrs\":{\"level\":6}}],\"content\":[{\"type\":\"text\",\"text\":\"Indented six levels.\"}]}",
            "{\"type\":\"paragraph\"\(Self.breakoutMarks("wide", 0.5)),\"content\":[{\"type\":\"text\",\"text\":\"Capped at half a point.\"}]}",
            "{\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"A plain paragraph.\"}]}",
            "{\"type\":\"codeBlock\"\(Self.breakoutMarks("wide", 0.5)),\"content\":[{\"type\":\"text\",\"text\":\"let x = 1\"}]}",
        ])
        let model = ADFDocumentModel()
        model.load(data: Data(json.utf8))
        for _ in 0..<500 where model.phase != .ready {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.phase == .ready)
        #expect(model.blocks.map(\.id) == ["0.0", "0.1", "0.2", "0.3"])
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: windowWidth, height: 3_000))
        let host = UIHostingController(rootView: ADFDocumentView(model: model, mediaProvider: TextKit2DiagnosticsTests.NoMedia(), textRenderer: .textKit2))
        window.rootViewController = host
        window.isHidden = false
        defer { Self.close(window) }
        try await TextKit2DiagnosticsTests.settle(window)
        try await TextKit2DiagnosticsTests.settle(window)
        let found = Set(TextKit2DiagnosticsTests.identifiers(in: host.view).map { String($0.dropFirst("tk2-row:".count)) })
        let expected: Set<String> = windowWidth > 300 ? ["0.0", "0.2", "0.3"] : ["0.2", "0.3"]
        #expect(found == expected, "W=\(windowWidth): missing \(expected.subtracting(found).sorted()), unexpected \(found.subtracting(expected).sorted())")
    }
}

/// The type size and Bold Text setting one hosted block is drawn at
/// (`DirectBlocks`).
private struct BlockStyle {
    var size: DynamicTypeSize = .large
    var weight: LegibilityWeight = .regular
}

/// Prepared top-level blocks hosted directly, outside `ADFDocumentView`, as
/// a container row with the switch ON would draw them: renderer `.textKit2`,
/// every kind in the allow list (a test host's widening, plan §4.1), and
/// each block's bound the width it is proposed. Expands read their state
/// from the model through the search environment.
private struct DirectBlocks: View {
    let blocks: [RenderBlock]
    let model: ADFDocumentModel
    let width: CGFloat
    let styles: [String: BlockStyle]
    let recorder: WidthProbeRecorder

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(blocks) { block in
                    let style = styles[block.id] ?? BlockStyle()
                    BlockView(block: block)
                        .environment(\.adfTextWidthBound, .atLeast(width))
                        .environment(\.legibilityWeight, style.weight)
                        .dynamicTypeSize(style.size)
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: {
                            recorder.blockMinXs[block.id] = $0
                        }
                }
            }
            .frame(width: width, alignment: .leading)
        }
        .environment(\.adfTextRenderer, .textKit2)
        .environment(\.adfContainerChildKinds, Set(TextKit2BlockKind.allCases))
        .environment(\.adfTheme, model.theme)
        .environment(\.adfCustomRenderers, model.customRenderers)
        .environment(\.adfDocumentSearch, model.search)
    }
}

extension TextKit2ContainerWidthTests {
    /// The five boundary sites; the column site has two width rules, by
    /// whether its columns sit side by side (regular width) or stack.
    enum Site: String, CaseIterable {
        case panel, quote, expand, extensionBody, columns
    }

    /// The fractions of the test's sections: uneven, so each column's share
    /// is its own.
    static let columnFractions: [Double] = [0.3, 0.7]

    /// `site` holding `content(column)` (column 0, and 1 for a section).
    static func wrap(_ site: Site, nested: Bool, _ content: (Int) -> String) -> String {
        switch site {
        case .panel:
            return "{\"type\":\"panel\",\"attrs\":{\"panelType\":\"info\"},\"content\":[\(content(0))]}"
        case .quote:
            return "{\"type\":\"blockquote\",\"content\":[\(content(0))]}"
        case .expand:
            return "{\"type\":\"\(nested ? "nestedExpand" : "expand")\",\"attrs\":{\"title\":\"E\"},\"content\":[\(content(0))]}"
        case .extensionBody:
            return "{\"type\":\"bodiedExtension\",\"attrs\":{\"extensionKey\":\"k\",\"extensionType\":\"t\"},\"content\":[\(content(0))]}"
        case .columns:
            let columns = columnFractions.indices.map { index in
                "{\"type\":\"layoutColumn\",\"attrs\":{\"width\":\(columnFractions[index] * 100)},\"content\":[\(content(index))]}"
            }
            return "{\"type\":\"layoutSection\",\"content\":[\(columns.joined(separator: ","))]}"
        }
    }

    /// The bound each site's rule (plan §4.2) gives a child, written out
    /// from the views' geometry: the panel's padding (1.5 × spacing each
    /// side), stack spacing (1.5 × spacing) and icon bound (its base at
    /// Large); the quote's leading inset (2 × spacing); the expand body's
    /// padding (1.25 × spacing each side); the extension body's padding
    /// (1.5 × spacing each side); a stacked column's full width, or a side
    /// by side column's share.
    @MainActor
    static func childBound(_ site: Site, of parent: CGFloat, column: Int, sideBySide: Bool) -> CGFloat {
        let spacing = ADFTheme.default.spacing
        switch site {
        case .panel: return max(parent - spacing * 4.5 - PanelBlockView.iconWidthBoundBase, 0)
        case .quote: return max(parent - spacing * 2, 0)
        case .expand: return max(parent - spacing * 2.5, 0)
        case .extensionBody: return max(parent - spacing * 3, 0)
        case .columns:
            guard sideBySide else { return parent }
            return ProportionalColumnsLayout.columnWidths(totalWidth: parent, fractions: columnFractions, spacing: spacing * 2)[column]
        }
    }

    /// Every site holding a probe (depth 1), and every site in every site
    /// (depth 2), with the bound each probe must read.
    @MainActor
    static func lowerBoundCases(width: CGFloat, sideBySide: Bool) -> (blocks: [String], expected: [String: CGFloat]) {
        var blocks: [String] = []
        var expected: [String: CGFloat] = [:]
        for outer in Site.allCases {
            blocks.append(wrap(outer, nested: false) { column in
                let name = "1.\(outer.rawValue)\(column)"
                expected[name] = childBound(outer, of: width, column: column, sideBySide: sideBySide)
                return probe(name)
            })
            for inner in Site.allCases {
                blocks.append(wrap(outer, nested: false) { column in
                    let outerBound = childBound(outer, of: width, column: column, sideBySide: sideBySide)
                    return wrap(inner, nested: true) { innerColumn in
                        let name = "2.\(outer.rawValue)\(column).\(inner.rawValue)\(innerColumn)"
                        expected[name] = childBound(inner, of: outerBound, column: innerColumn, sideBySide: sideBySide)
                        return probe(name)
                    }
                })
            }
        }
        return (blocks, expected)
    }

    /// The ids of every expand in `node`, nested ones and those in expand
    /// bodies included (a body's blocks keep their nodes' ids).
    static func expandIDs(_ node: ADFNode) -> Set<String> {
        var ids: Set<String> = []
        if case .expand = node.kind { ids.insert(node.id) }
        for child in node.children { ids.formUnion(expandIDs(child)) }
        return ids
    }

    /// Hosts `json`'s blocks directly (`DirectBlocks`), every expand open,
    /// and waits for every probe in `probes` to report a known bound.
    @MainActor
    fileprivate static func hostDirect(
        _ json: String, probes: [String], recorder: WidthProbeRecorder, width: CGFloat, sideBySide: Bool,
        styles: [String: BlockStyle] = [:]
    ) async throws -> UIWindow {
        let data = Data(json.utf8)
        let model = ADFDocumentModel(customRenderers: [WidthProbeRenderer(recorder: recorder)])
        model.load(data: data)
        for _ in 0..<500 where model.phase != .ready {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.phase == .ready)
        model.expandedBlocks.formUnion(Self.expandIDs(try await ADFParser().parse(data).root))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 1_000))
        let host = UIHostingController(rootView: DirectBlocks(
            blocks: model.blocks, model: model, width: width, styles: styles, recorder: recorder
        ).environment(\.horizontalSizeClass, sideBySide ? .regular : .compact))
        window.rootViewController = host
        window.isHidden = false
        try await waitForProbes(probes, recorder: recorder, window: window)
        return window
    }

    /// The proof of the width contract (plan §4.2): for each of the six
    /// width rules, one and two levels deep, the bound a container writes
    /// for a child is what its rule gives and is no wider than the width
    /// the child is laid out at (to a pixel: frames are pixel-snapped).
    @Test("boundIsLowerBound: every boundary's bound, one and two levels deep, is its rule's value and at most the child's width", arguments: [CGFloat(320), 375, 402, 640], [false, true])
    @MainActor
    func boundIsLowerBound(width: CGFloat, sideBySide: Bool) async throws {
        let cases = Self.lowerBoundCases(width: width, sideBySide: sideBySide)
        let probes = cases.expected.keys.sorted()
        // Depth 1: four sites with one probe, a section with two; depth 2:
        // the same six slots in each of the six outer slots.
        #expect(probes.count == 6 + 6 * 6)
        let recorder = WidthProbeRecorder()
        let window = try await Self.hostDirect(
            Self.document(cases.blocks), probes: probes, recorder: recorder, width: width, sideBySide: sideBySide
        )
        defer { Self.close(window) }
        let scale = window.traitCollection.displayScale
        let label = "W=\(width) \(sideBySide ? "side by side" : "stacked")"
        for name in probes {
            let expected = cases.expected[name] ?? -1
            guard case .atLeast(let bound) = recorder.bounds[name], let laid = recorder.widths[name] else {
                Issue.record("\(label) \(name): bound \(String(describing: recorder.bounds[name])), width \(String(describing: recorder.widths[name]))")
                continue
            }
            #expect(abs(bound - expected) < 0.001, "\(label) \(name): bound \(bound), rule gives \(expected)")
            #expect(bound <= laid + 1 / scale, "\(label) \(name): bound \(bound) over the width the child is laid out at, \(laid)")
        }
    }

    /// The panel's icon bound (plan §4.2): the seven palette symbols at the
    /// twelve type sizes, with and without Bold Text, at this display's
    /// scale. The icon's width is measured where the panel lays it out
    /// (the probe's leading edge less the panel's, its padding and the
    /// stack's spacing), and must be no wider than the bound the panel
    /// implies (its width less its padding, spacing and the child's bound).
    /// The base value is `PanelBlockView.iconWidthBoundBase`; the widest
    /// icons are printed (`PANEL_ICON`) so a raised base can be read off.
    @Test("panelIconBound: no palette symbol is wider than the panel's icon bound, at any type size, with or without Bold Text")
    @MainActor
    func panelIconBound() async throws {
        let types = ["info", "note", "tip", "success", "warning", "error", "custom"]
        let theme = ADFTheme.default
        #expect(Set(types.map { theme.panelPalette(ADFPanelType(rawValue: $0)!, colorHex: nil).iconSystemName }) == PanelBlockView.boundedIconSymbols)
        var blocks: [String] = []
        var styles: [String: BlockStyle] = [:]
        var panels: [(name: String, id: String, type: String, size: DynamicTypeSize, bold: Bool)] = []
        for type in types {
            for size in DynamicTypeSize.allCases {
                for bold in [false, true] {
                    let name = "icon.\(type).\(size).\(bold ? "bold" : "regular")"
                    let id = "0.\(blocks.count)"
                    blocks.append("{\"type\":\"panel\",\"attrs\":{\"panelType\":\"\(type)\"},\"content\":[\(Self.probe(name))]}")
                    styles[id] = BlockStyle(size: size, weight: bold ? .bold : .regular)
                    panels.append((name, id, type, size, bold))
                }
            }
        }
        #expect(DynamicTypeSize.allCases.count == 12)
        let width: CGFloat = 375
        let recorder = WidthProbeRecorder()
        let window = try await Self.hostDirect(
            Self.document(blocks), probes: panels.map(\.name), recorder: recorder, width: width, sideBySide: false, styles: styles
        )
        defer { Self.close(window) }
        let scale = window.traitCollection.displayScale
        let spacing = theme.spacing
        var widest: [DynamicTypeSize: (icon: CGFloat, bound: CGFloat, name: String)] = [:]
        for panel in panels {
            guard case .atLeast(let childBound) = recorder.bounds[panel.name], let probeX = recorder.minXs[panel.name],
                  let panelX = recorder.blockMinXs[panel.id], let laid = recorder.widths[panel.name] else {
                Issue.record("\(panel.name): bound \(String(describing: recorder.bounds[panel.name])) or geometry missing")
                continue
            }
            let icon = probeX - panelX - spacing * 3
            // The same width from the other side: the panel's width less
            // its padding, spacing and the probe.
            #expect(abs(icon - (width - spacing * 4.5 - laid)) <= 1 / scale, "\(panel.name): icon \(icon) against \(width - spacing * 4.5 - laid)")
            let bound = width - spacing * 4.5 - childBound
            #expect(icon <= bound + 0.001, "\(panel.name): icon \(icon) pt wider than its bound \(bound) pt")
            if icon > (widest[panel.size]?.icon ?? -1) { widest[panel.size] = (icon, bound, panel.name) }
        }
        var base: CGFloat = 0
        for size in DynamicTypeSize.allCases {
            guard let entry = widest[size] else { continue }
            // The bound scales linearly with the base, so the base that
            // would make this size's bound exactly its widest icon:
            let needed = entry.icon / entry.bound * PanelBlockView.iconWidthBoundBase
            base = max(base, needed)
            print("PANEL_ICON scale=\(scale) size=\(size) widest=\(entry.icon) bound=\(entry.bound) symbol=\(entry.name) base-needed=\(needed)")
        }
        print("PANEL_ICON scale=\(scale) base=\(PanelBlockView.iconWidthBoundBase) base-needed=\(base)")
    }
}
#endif
