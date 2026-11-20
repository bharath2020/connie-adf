#if canImport(UIKit)
import SwiftUI
import UIKit
import Testing
import ADFModel
import ADFPreparation
@testable import ADFRendering

/// The colour scheme is a paint input, not a layout input (Fable F3): a
/// light/dark flip on a mounted TextKit 2 row repaints it without
/// rebuilding its text or laying it out again, and the repainted pixels
/// match fresh rows created in each scheme — on every draw path: a plain
/// `.label` row (TextKit 2 fragment drawing), an author-coloured run, run
/// backgrounds drawn by the row (TextKit 2 line drawing), an accent
/// link (TextKit 1-backed drawing) and text in an inherited `.secondary`
/// foreground (a caption's, `adfTextForeground`). A flip together with a real width or
/// content change still lays out (and rebuilds) as before.
@Suite("TextKit 2 appearance flips", .serialized)
@MainActor
struct TextKit2AppearanceFlipTests {
    nonisolated static let width: CGFloat = 370
    nonisolated static let maxDifferingFraction = TextKit2PixelParityTests.maxDifferingFraction

    enum Case: String, CaseIterable, Sendable, CustomStringConvertible {
        case plainLabel, authorHex, runBackground, accentLink, secondaryForeground
        var description: String { rawValue }

        /// The inherited foreground the case's leaf is hosted with.
        var foreground: Color? { self == .secondaryForeground ? .secondary : nil }
    }

    static let wrapping = "after it, enough plain words to wrap the paragraph onto a second and a third line at the default size"

    static func fixture(_ kind: Case) async throws -> TK2Parity.Fixture {
        func t(_ string: String, _ marks: String = "") -> String { TK2Parity.adfText(string, marks: marks) }
        switch kind {
        case .plainLabel:
            return try await TK2Parity.plain("plain-label", "Plain label-coloured text " + wrapping)
        case .authorHex:
            return try await TK2Parity.fixture("author-hex", content: [
                t("Plain text, "),
                t("an author-red run", "{\"type\":\"textColor\",\"attrs\":{\"color\":\"#ff5630\"}}"),
                t(", and " + wrapping),
            ].joined(separator: ","))
        case .runBackground:
            return try await TK2Parity.fixture("run-background", content: [
                t("Plain text, "),
                t("a highlighted run", "{\"type\":\"backgroundColor\",\"attrs\":{\"color\":\"#fedec8\"}}"),
                t(", "),
                t("inline code", "{\"type\":\"code\"}"),
                t(", and " + wrapping),
            ].joined(separator: ","))
        case .secondaryForeground:
            return try await TK2Parity.plain("secondary-foreground", "Caption-coloured secondary text " + wrapping)
        case .accentLink:
            return try await TK2Parity.fixture("accent-link", content: [
                t("Plain text, "),
                t("an accent link", "{\"type\":\"link\",\"attrs\":{\"href\":\"https://example.com\"}}"),
                t(", and " + wrapping),
            ].joined(separator: ","))
        }
    }

    // MARK: Live flips

    @Test("a mounted row flips light → dark → light without rebuild or relayout, painting like fresh rows", arguments: Case.allCases)
    func liveFlip(_ kind: Case) async throws {
        let fixture = try await Self.fixture(kind)
        let height = Self.windowHeight(fixture)
        let foreground = kind.foreground
        let freshLight = try LiveRow.snapshot(fixture, width: Self.width, height: height, dark: false, foreground: foreground)
        let freshDark = try LiveRow.snapshot(fixture, width: Self.width, height: height, dark: true, foreground: foreground)

        let live = LiveRow(fixture, width: Self.width, height: height, dark: false, foreground: foreground)
        defer { live.close() }
        let row = try #require(live.row)
        #expect(row.isTextKit1Backed == (kind == .accentLink))
        #expect(row.inputs?.inheritedForeground == foreground, "the row's inherited foreground")
        _ = try live.bitmap()
        let placed = row.frame(in: live.window)
        let geometry = row.placedResult(for: row.bounds.size)
        let relayouts = row.relayoutCount
        let widths = row.cachedWidths
        let string = row.attributed
        #expect(!widths.isEmpty)

        for dark in [true, false] {
            let label = "\(kind) → \(dark ? "dark" : "light")"
            let diagnostics = TextKit2Diagnostics.shared
            let layouts = diagnostics.layoutCount
            let draws = diagnostics.drawCount
            live.update(fixture: fixture, width: Self.width, dark: dark, foreground: foreground)
            #expect(live.row === row, "\(label): the flip kept the row")
            #expect(row.traitCollection.userInterfaceStyle == (dark ? .dark : .light), "\(label): the row did not receive the scheme")
            LiveRow.display(live.window)
            #expect(diagnostics.drawCount > draws, "\(label): the flip did not repaint the canvas")
            print("TK2 appearance flip \(label): layoutCount +\(diagnostics.layoutCount - layouts), row relayouts \(relayouts) → \(row.relayoutCount), cached widths \(widths) → \(row.cachedWidths)")
            #expect(diagnostics.layoutCount == layouts, "\(label): \(diagnostics.layoutCount - layouts) layout passes")
            #expect(row.relayoutCount == relayouts, "\(label): the row relaid out")
            #expect(row.cachedWidths == widths, "\(label): the layout cache changed")
            #expect(row.attributed === string, "\(label): the text was rebuilt")
            #expect(row.frame(in: live.window) == placed, "\(label): the row moved or resized")
            let after = row.placedResult(for: row.bounds.size)
            #expect(after.size == geometry.size && after.firstBaseline == geometry.firstBaseline && after.lastBaseline == geometry.lastBaseline,
                    "\(label): geometry \(after.size) \(after.firstBaseline)/\(after.lastBaseline) vs \(geometry.size) \(geometry.firstBaseline)/\(geometry.lastBaseline)")
            Self.expectSamePixels(try live.bitmap(), dark ? freshDark : freshLight, dark: dark, label: label)
        }
    }

    @Test("a flip together with a width change still lays out at the new width")
    func flipWithWidthChange() async throws {
        let fixture = try await Self.fixture(.runBackground)
        let narrow: CGFloat = 300
        let height = Self.windowHeight(fixture, width: narrow)
        let live = LiveRow(fixture, width: Self.width, height: height, dark: false)
        defer { live.close() }
        let row = try #require(live.row)
        _ = try live.bitmap()
        let wide = row.bounds.size
        let relayouts = row.relayoutCount
        let layouts = TextKit2Diagnostics.shared.layoutCount

        live.update(fixture: fixture, width: narrow, dark: true)
        #expect(live.row === row)
        let bitmap = try live.bitmap()
        #expect(row.relayoutCount > relayouts, "the new width was not laid out")
        #expect(TextKit2Diagnostics.shared.layoutCount > layouts)
        #expect(row.currentContainerWidth == narrow)
        #expect(row.bounds.width <= narrow && row.bounds.size != wide, "\(row.bounds.size) vs \(wide)")

        let fresh = LiveRow(fixture, width: narrow, height: height, dark: true)
        defer { fresh.close() }
        let freshRow = try #require(fresh.row)
        #expect(row.bounds.size == freshRow.bounds.size)
        #expect(row.placedResult(for: row.bounds.size) == freshRow.placedResult(for: freshRow.bounds.size))
        Self.expectSamePixels(bitmap, try fresh.bitmap(), dark: true, label: "width + dark")
    }

    @Test("a flip together with a content change still rebuilds the text")
    func flipWithContentChange() async throws {
        let first = try await Self.fixture(.plainLabel)
        let second = try await Self.fixture(.runBackground)
        let height = max(Self.windowHeight(first), Self.windowHeight(second))
        let live = LiveRow(first, width: Self.width, height: height, dark: false)
        defer { live.close() }
        let row = try #require(live.row)
        _ = try live.bitmap()
        let string = row.attributed
        let relayouts = row.relayoutCount

        live.update(fixture: second, width: Self.width, dark: true)
        #expect(live.row === row)
        let bitmap = try live.bitmap()
        #expect(row.attributed !== string, "the new content was not rebuilt")
        #expect(row.attributed.string == String(try #require(second.describableText).characters))
        #expect(row.relayoutCount > relayouts, "the new content was not laid out")

        let fresh = LiveRow(second, width: Self.width, height: height, dark: true)
        defer { fresh.close() }
        let freshRow = try #require(fresh.row)
        #expect(row.bounds.size == freshRow.bounds.size)
        Self.expectSamePixels(bitmap, try fresh.bitmap(), dark: true, label: "content + dark")
    }

    // MARK: Row inputs

    private func text(_ string: String) -> AttributedString {
        var text = AttributedString(string)
        text.font = .body
        text.adfFontSpec = ADFFontSpec(textStyle: .body)
        return text
    }

    @Test("a scheme-only apply repaints and keeps the text, the layout cache and the container")
    func paintOnlyApply() throws {
        let view = TextKit2RowView()
        let inputs = TextKit2RenderInputs(text: text(TextKit2RowViewTests.sentence), displayScale: TK2Parity.nativeScale)
        view.apply(inputs, colorScheme: .light)
        #expect(view.overrideUserInterfaceStyle == .light)
        _ = view.layoutResult(forProposedWidth: 340)
        let placed = view.layoutResult(forProposedWidth: 300)
        view.frame = CGRect(origin: .zero, size: placed.size)
        view.layoutIfNeeded()
        let canvas = try #require(view.subviews.first)
        canvas.layer.displayIfNeeded()
        #expect(!canvas.layer.needsDisplay())
        let string = view.attributed
        let relayouts = view.relayoutCount
        let widths = view.cachedWidths
        let container = view.currentContainerWidth

        for scheme in [ColorScheme.dark, .light] {
            view.apply(inputs, colorScheme: scheme)
            #expect(view.overrideUserInterfaceStyle == (scheme == .dark ? .dark : .light))
            #expect(canvas.layer.needsDisplay(), "\(scheme): the flip must repaint")
            #expect(view.attributed === string, "\(scheme): the text was rebuilt")
            #expect(view.cachedWidths == widths, "\(scheme): the layout cache changed")
            #expect(view.currentContainerWidth == container)
            view.layoutIfNeeded()
            canvas.layer.displayIfNeeded()
            #expect(view.layoutResult(forProposedWidth: 300) == placed)
            #expect(view.relayoutCount == relayouts, "\(scheme): the row relaid out")
            view.apply(inputs, colorScheme: scheme)
            #expect(!canvas.layer.needsDisplay(), "\(scheme): re-applying the same scheme must not repaint")
        }
    }

    @Test("legibility weight and display scale stay layout inputs, with or without a flip", arguments: [false, true])
    func layoutInputsStillRebuild(flip: Bool) {
        let base = TextKit2RenderInputs(text: text(TextKit2RowViewTests.sentence), displayScale: 3)
        var bold = base
        bold.legibilityWeight = .bold
        var twoX = base
        twoX.displayScale = 2
        for (label, changed) in [("legibility weight", bold), ("display scale", twoX)] {
            let view = TextKit2RowView()
            view.apply(base, colorScheme: .light)
            _ = view.layoutResult(forProposedWidth: 300)
            let string = view.attributed
            let relayouts = view.relayoutCount
            view.apply(changed, colorScheme: flip ? .dark : .light)
            #expect(view.attributed !== string, "\(label): the text was not rebuilt")
            #expect(view.cachedWidths.isEmpty, "\(label): the layout cache survived")
            let after = view.layoutResult(forProposedWidth: 300)
            #expect(view.relayoutCount == relayouts + 1, "\(label): not laid out again")
            let fresh = TextKit2RowView()
            fresh.apply(changed)
            #expect(after == fresh.layoutResult(forProposedWidth: 300), "\(label): differs from a fresh row")
        }
    }

    // MARK: Helpers

    static func windowHeight(_ fixture: TK2Parity.Fixture, width: CGFloat = TextKit2AppearanceFlipTests.width) -> CGFloat {
        max(TK2Parity.height(fixture, arm: .swiftUI, env: TK2Parity.Environment(), width: width) + 40, 200)
    }

    /// The parity suites' pixel rule (`TextKit2PixelParityTests`): equal
    /// vertical ink profiles and ≤ 0.2 % of the ink band differing by more
    /// than 24 in a channel — and, stricter, no pixel differing at all.
    static func expectSamePixels(_ live: TK2Parity.Bitmap, _ fresh: TK2Parity.Bitmap, dark: Bool, label: String) {
        let pl = TK2Parity.inkProfile(live, dark: dark)
        let pf = TK2Parity.inkProfile(fresh, dark: dark)
        #expect(pf.firstInkRow != nil, "\(label): the fresh row rendered no ink")
        #expect(pl == pf, "\(label): ink profiles differ\n\(TK2Parity.rowDifferences(pf, pl))")
        let first = min(pl.firstInkRow ?? 0, pf.firstInkRow ?? 0)
        let last = max(pl.lastInkRow ?? 0, pf.lastInkRow ?? 0)
        let diff = TK2Parity.differingFraction(live, fresh, rows: first...last)
        var exact = 0
        for y in first...last {
            for x in 0..<live.width where live[x, y] != fresh[x, y] { exact += 1 }
        }
        print("TK2 appearance flip pixels \(label): differing \(diff.count)/\(diff.total), any difference \(exact)")
        #expect(diff.fraction <= maxDifferingFraction, "\(label): \(diff.count)/\(diff.total) pixels differ")
        // Same engine, same layout: the repainted row must equal the fresh
        // one exactly. The parity threshold alone (24 per channel) would
        // miss a stale accent link, whose light and dark blues differ by
        // about 10.
        #expect(exact == 0, "\(label): \(exact) pixels differ from the fresh row")
    }
}

/// One hosted TextKit 2 leaf kept alive in a window across updates, as
/// `TK2Parity.render` hosts it; the window's style is the system
/// appearance the row inherits through SwiftUI's environment.
@MainActor
final class LiveRow {
    struct Root: View {
        var fixture: TK2Parity.Fixture
        var width: CGFloat
        var foreground: Color? = nil

        var body: some View {
            TK2Parity.hosted(fixture, arm: .textKit2, env: TK2Parity.Environment(foreground: foreground))
                .frame(width: width, alignment: .topLeading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .ignoresSafeArea()
        }
    }

    let window: UIWindow
    let host: UIHostingController<Root>
    private(set) var width: CGFloat

    init(_ fixture: TK2Parity.Fixture, width: CGFloat, height: CGFloat, dark: Bool, foreground: Color? = nil) {
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: max(width, TextKit2AppearanceFlipTests.width), height: height))
        host = UIHostingController(rootView: Root(fixture: fixture, width: width, foreground: foreground))
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        self.width = width
        style(dark: dark)
        window.rootViewController = host
        window.isHidden = false
        settle()
    }

    /// A fresh row's pixels.
    static func snapshot(_ fixture: TK2Parity.Fixture, width: CGFloat, height: CGFloat, dark: Bool, foreground: Color? = nil) throws -> TK2Parity.Bitmap {
        let row = LiveRow(fixture, width: width, height: height, dark: dark, foreground: foreground)
        defer { row.close() }
        return try row.bitmap()
    }

    func update(fixture: TK2Parity.Fixture, width: CGFloat, dark: Bool, foreground: Color? = nil) {
        self.width = width
        host.rootView = Root(fixture: fixture, width: width, foreground: foreground)
        style(dark: dark)
        settle()
    }

    private func style(dark: Bool) {
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.backgroundColor = dark ? .black : .white
    }

    private func settle() {
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
    }

    /// The hosted TextKit 2 row view.
    var row: TextKit2RowView? { Self.find(in: host.view) }

    private static func find(in view: UIView) -> TextKit2RowView? {
        if let row = view as? TextKit2RowView { return row }
        for subview in view.subviews {
            if let row = find(in: subview) { return row }
        }
        return nil
    }

    /// The display pass a Core Animation commit runs: every layer marked
    /// as needing display draws now (and only those).
    static func display(_ view: UIView) {
        view.layer.displayIfNeeded()
        for subview in view.subviews { display(subview) }
    }

    func bitmap() throws -> TK2Parity.Bitmap {
        Self.display(window)
        return try TK2Parity.bitmap(of: window, width: width)
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
    }
}

private extension UIView {
    func frame(in window: UIWindow) -> CGRect { convert(bounds, to: window) }
}
#endif
