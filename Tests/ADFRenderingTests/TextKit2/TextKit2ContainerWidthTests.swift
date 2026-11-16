import Foundation
import CoreGraphics
import Testing
import ADFModel
import ADFPreparation
@testable import ADFRendering

/// The width contract at root level: `adfTextWidthBound` is a guaranteed
/// lower bound on the width text is laid out at, for eligibility only.
/// `DocumentRow` seeds it with the row's content width, breakout included
/// (`TextKit2WidthBound.rowSeed`); list rule D (`TextKit2Scope.listTextFits`)
/// and the under-1-pt guard on every wrapping leaf (`TextKit2Scope.textFits`)
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

    func complete(_ names: [String]) -> Bool {
        names.allSatisfy { name in
            guard widths[name] != nil, let bound = bounds[name] else { return false }
            return bound != .pending
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
    /// probe in `probes` to report a known bound and a width, and returns
    /// the window and its root view (keep the window until done).
    @MainActor
    fileprivate static func host(
        _ json: String, probes: [String], recorder: WidthProbeRecorder, width: CGFloat = windowWidth,
        sizeClass: UserInterfaceSizeClass = .compact, openExpands: Bool = false
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
        for _ in 0..<250 where !recorder.complete(probes) {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        try await TextKit2DiagnosticsTests.settle(window)
        #expect(recorder.complete(probes), "probes without a known bound or width: \(probes.filter { recorder.bounds[$0] == nil || recorder.bounds[$0] == .pending || recorder.widths[$0] == nil })")
        return window
    }

    @MainActor
    fileprivate static func close(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    /// Layout sections with a breakout mark, two 50 % columns each. The
    /// bound reaching a column's blocks is the row seed: the section's own
    /// width, capped by the custom width where there is one (never the bare
    /// column). Stacked (compact width), a column's blocks are proposed the
    /// section's width, so the seed is already a true lower bound there. Side
    /// by side, the columns pass the seed through unnarrowed until the
    /// column boundary writes its own bound (PR 4 step 4); the seed is then
    /// still bounded by the section's width, which is checked here.
    @Test("a layout section's breakout and custom width reach its columns as the row seed, never the bare column", arguments: [false, true])
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
        let window = try await Self.host(Self.document(blocks), probes: probes, recorder: recorder, sizeClass: sizeClass)
        defer { Self.close(window) }
        let scale = window.traitCollection.displayScale
        let spacing = ADFTheme.default.spacing * 2
        for item in Self.breakoutCases {
            let label = "\(item.name) \(sideBySide ? "side by side" : "stacked")"
            let first = recorder.widths["\(item.name)-0"] ?? 0, second = recorder.widths["\(item.name)-1"] ?? 0
            // The section's laid-out width, from its columns.
            let section = sideBySide ? first + spacing + second : first
            #expect(abs(section - item.rowWidth) <= 1 / scale, "\(label): section laid out \(section) wide, expected \(item.rowWidth)")
            for probe in ["\(item.name)-0", "\(item.name)-1"] {
                #expect(recorder.bounds[probe] == .atLeast(item.rowWidth), "\(label) \(probe): bound \(String(describing: recorder.bounds[probe]))")
                guard case .atLeast(let bound) = recorder.bounds[probe] else { continue }
                #expect(bound <= section, "\(label) \(probe): bound \(bound) over the section's width \(section)")
                if !sideBySide {
                    let laid = recorder.widths[probe] ?? 0
                    #expect(bound <= laid, "\(label) \(probe): bound \(bound) over the width the block is laid out at, \(laid)")
                }
            }
            if item.rowWidth < Self.column {
                // The test tells the seeds apart: the bare column is wider
                // than this row really is.
                #expect(Self.column > section + 1, "\(label): a capped section narrower than the column")
            }
        }
    }

    /// Open expands with a breakout mark. The bound reaching the body is the
    /// row seed: the expand's own width (body width + its horizontal padding,
    /// 1.25 × spacing each side), capped by the custom width where there is
    /// one, never the bare column. The body's padding is removed by the
    /// expand body boundary (PR 4 step 5), not by the seed; until then the
    /// seed is bounded by the expand's width, which is checked here.
    @Test("an expand's breakout and custom width reach its body as the row seed, never the bare column")
    @MainActor
    func breakoutCappedExpand() async throws {
        let recorder = WidthProbeRecorder()
        let cases = Self.breakoutCases.filter { $0.name != "full" }
        let blocks = cases.map { item in
            "{\"type\":\"expand\",\"attrs\":{\"title\":\"\(item.name)\"}\(Self.breakoutMarks(item.mode, item.width)),\"content\":[\(Self.probe(item.name))]}"
        }
        let window = try await Self.host(Self.document(blocks), probes: cases.map(\.name), recorder: recorder, openExpands: true)
        defer { Self.close(window) }
        let scale = window.traitCollection.displayScale
        let padding = ADFTheme.default.spacing * 1.25 * 2
        for item in cases {
            let body = recorder.widths[item.name] ?? 0
            let expand = body + padding
            #expect(abs(expand - item.rowWidth) <= 1 / scale, "\(item.name): expand laid out \(expand) wide, expected \(item.rowWidth)")
            #expect(recorder.bounds[item.name] == .atLeast(item.rowWidth), "\(item.name): bound \(String(describing: recorder.bounds[item.name]))")
            guard case .atLeast(let bound) = recorder.bounds[item.name] else { continue }
            #expect(bound <= expand, "\(item.name): bound \(bound) over the expand's width \(expand)")
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
#endif
