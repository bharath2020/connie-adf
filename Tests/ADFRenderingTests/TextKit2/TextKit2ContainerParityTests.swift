#if canImport(UIKit)
import SwiftUI
import UIKit
import Testing
import ADFModel
import ADFPreparation
@testable import ADFRendering

// Container text on TextKit 2: the step 1a probes (PR 4 plan §5 step 1a).
// The recorded results (`<data>/probes/results.md`) were taken on
// unmodified production code (main be500c8), where no container set the
// renderer. From step 2 on the container boundary (`adfContainerChild`)
// passes the renderer only to kinds in `adfContainerChildKinds`, so this
// host widens that list to every probed family (`probedKinds`, no code and
// no media) and seeds the row's width bound as a document row does. The
// real `BlockView(block:)` of a panel, quote, open expand, bodied extension
// or layout section, hosted under `.environment(\.adfTextRenderer,
// .textKit2)`, then hands TextKit 2 to the text nested in it; the same
// tree under `.swiftUI` is the reference. Code blocks are kept out of every
// probe document.
//
// Every case first checks that its subject draws through TextKit 2 (a
// `tk2-row` for the probed owner on the TextKit 2 arm, none on the SwiftUI
// arm), so a probe cannot pass on two SwiftUI renders; that check is the
// suite's assertion. The parity outcome itself is recorded, not asserted:
// the probes decide which shapes the scope functions keep on SwiftUI
// (`panelKeepsRenderer`, `panelDirectionKeepsRenderer`,
// `horizontalColumnKeepsRenderer`, the panel icon bound), so a divergence
// here is a result, not a regression. Each case prints one line:
//
//   CONTAINER_PROBE probe=… container=… shape=… size=… bold=… dir=… W=… scale=… os=… result=pass|fail dH=… dFirst=… dLast=… …
//   CONTAINER_PROBE_SUMMARY probe=… container=… shape=… dir=… scale=… os=… cases=… pass=… fail=… worst…
//   PANEL_ICON os=… scale=… size=… bold=… symbol=… width=… inSitu=… bound28=… unit=…
//
// The matrix is sampled unless `ADF_CONTAINER_PROBES=full` reaches the test
// runner (`TEST_RUNNER_ADF_CONTAINER_PROBES=full xcodebuild test …`).
//
// From step 3 container text is gated before iOS 26
// (`TextKit2Eligibility.containerTextMatchesText`): there the probes assert
// that the gate holds (no TextKit 2 row for container text) instead of
// measuring, and the iOS 18.5 results in `probes/results.md` were taken
// before the gate existed.
//
// PR 1's leaf residual (linked text, an emoji pair, inline code and bold at
// AX3 in a 219 pt column) is pinned on its own in a quote body
// (`linkedEmojiCodeResidualInQuote`); no other case carries a known-issue
// mask.

/// Documents, hosting, measurement and comparison the container probes
/// share. Not a suite.
enum TK2ContainerProbe {
    nonisolated static let tolerance: CGFloat = 0.01
    static var theme: ADFTheme { TK2Parity.theme }
    static var spacing: CGFloat { theme.spacing }

    /// The matrix: `full` (`ADF_CONTAINER_PROBES=full`), `family` (every
    /// family sampled: `familySizes` at 320 and 402 pt, both directions,
    /// Bold Text off and on) or a small default sample.
    static var mode: String { ProcessInfo.processInfo.environment["ADF_CONTAINER_PROBES"] ?? "sample" }
    static var fullMatrix: Bool { mode == "full" }
    static var familyMatrix: Bool { mode == "family" }
    /// Whether every case prints its line (not only failures).
    static var printsEveryCase: Bool { mode != "sample" }
    /// xxLarge is the largest size the container size rule
    /// (`containerSizeKeepsRenderer`) keeps on TextKit 2 and xxxLarge the
    /// first it keeps on SwiftUI (lead call C55); the rest stand for the
    /// sizes around them.
    static let familySizes: [DynamicTypeSize] = [.xSmall, .large, .xxLarge, .xxxLarge, .accessibility3, .accessibility5]

    // MARK: Documents

    static let fillerWords = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa quebec romeo sierra tango uniform victor whiskey xray yankee zulu"
        .split(separator: " ").map(String.init)

    static func words(_ count: Int, from start: Int = 0) -> String {
        (0..<count).map { fillerWords[(start + $0) % fillerWords.count] }.joined(separator: " ")
    }

    static func t(_ string: String, _ marks: String = "") -> String { TK2Parity.adfText(string, marks: marks) }
    static func paragraph(_ content: String...) -> String { "{\"type\":\"paragraph\",\"content\":[\(content.joined(separator: ","))]}" }
    static func heading(_ level: Int, _ text: String) -> String {
        "{\"type\":\"heading\",\"attrs\":{\"level\":\(level)},\"content\":[\(t(text))]}"
    }
    static func item(_ children: String...) -> String { "{\"type\":\"listItem\",\"content\":[\(children.joined(separator: ","))]}" }
    static func bulletList(_ items: [String]) -> String { "{\"type\":\"bulletList\",\"content\":[\(items.joined(separator: ","))]}" }
    static func panel(_ body: [String], type: String = "info", color: String? = nil) -> String {
        let colorAttr = color.map { ",\"panelColor\":\"\($0)\"" } ?? ""
        return "{\"type\":\"panel\",\"attrs\":{\"panelType\":\"\(type)\"\(colorAttr)},\"content\":[\(body.joined(separator: ","))]}"
    }
    static func quote(_ body: [String]) -> String { "{\"type\":\"blockquote\",\"content\":[\(body.joined(separator: ","))]}" }
    static func expand(_ body: [String]) -> String {
        "{\"type\":\"expand\",\"attrs\":{\"title\":\"Probe details\"},\"content\":[\(body.joined(separator: ","))]}"
    }
    static func bodiedExtension(_ body: [String]) -> String {
        "{\"type\":\"bodiedExtension\",\"attrs\":{\"extensionType\":\"com.example.probe\",\"extensionKey\":\"probe-macro\"},\"content\":[\(body.joined(separator: ","))]}"
    }
    static func section(_ columns: [(width: Double, body: [String])]) -> String {
        let content = columns.map { "{\"type\":\"layoutColumn\",\"attrs\":{\"width\":\($0.width)},\"content\":[\($0.body.joined(separator: ","))]}" }
        return "{\"type\":\"layoutSection\",\"content\":[\(content.joined(separator: ","))]}"
    }

    static let link = "{\"type\":\"link\",\"attrs\":{\"href\":\"https://example.com/probe\"}}"
    static let strong = "{\"type\":\"strong\"}"
    static let em = "{\"type\":\"em\"}"
    static let code = "{\"type\":\"code\"}"
    static let sub = "{\"type\":\"subsup\",\"attrs\":{\"type\":\"sub\"}}"
    static let sup = "{\"type\":\"subsup\",\"attrs\":{\"type\":\"sup\"}}"
    static let small = "{\"type\":\"fontSize\",\"attrs\":{\"size\":\"small\"}}"

    @MainActor
    static func prepared(_ nodes: [String]) async throws -> [RenderBlock] {
        let json = "{\"version\":1,\"type\":\"doc\",\"content\":[\(nodes.joined(separator: ","))]}"
        return DocumentPreparer(theme: theme).prepare(try await ADFParser().parse(Data(json.utf8)))
    }

    /// A container body of the `panelShapes` matrix (plan §5 step 1a).
    struct Shape: Sendable {
        let name: String
        let body: [String]
    }

    /// One paragraph; body paragraphs only (link, inline code, bold,
    /// italic); a heading and a paragraph (an emoji pair, no link or code,
    /// so PR 1's leaf residual stays apart); a superscript, subscript and
    /// small-text run beside other paragraphs (the cause behind list
    /// rule A); a nested list; a nested quote; and, bounding the
    /// sub/superscript rule, the same runs in a lone paragraph. With
    /// `ADF_CONTAINER_PROBES_SHAPES=<name,…>` only the named shapes run.
    static var shapes: [Shape] {
        let only = ProcessInfo.processInfo.environment["ADF_CONTAINER_PROBES_SHAPES"].map { Set($0.split(separator: ",").map(String.init)) }
        return allShapes.filter { only?.contains($0.name) ?? true }
    }

    static var allShapes: [Shape] {
        [
            Shape(name: "onePara", body: [paragraph(t(words(30)))]),
            Shape(name: "bodyParas", body: [
                paragraph(t(words(12) + " "), t("linked words", link), t(" " + words(6, from: 12) + " "), t("code", code), t(" " + words(5, from: 18), strong)),
                paragraph(t(words(11, from: 3), em)),
                paragraph(t(words(4, from: 7))),
            ]),
            Shape(name: "headingPara", body: [heading(2, words(7, from: 2)), paragraph(t(words(10, from: 9) + " \u{1F600}\u{1F389} " + words(10, from: 4)))]),
            Shape(name: "subsupBeside", body: [
                paragraph(t(words(14))),
                paragraph(t("x"), t("2", sup), t(" " + words(5, from: 4) + " H"), t("2", sub), t("O " + words(4, from: 10) + " "), t("small print words", small)),
                paragraph(t(words(3, from: 6))),
            ]),
            Shape(name: "nestedList", body: [
                paragraph(t(words(12, from: 1))),
                bulletList([
                    item(paragraph(t(words(3, from: 5)))),
                    item(paragraph(t(words(12, from: 8))), bulletList([item(paragraph(t(words(5, from: 14))))])),
                    item(paragraph(t(words(2, from: 20)))),
                ]),
            ]),
            Shape(name: "nestedQuote", body: [paragraph(t(words(12, from: 2))), quote([paragraph(t(words(16, from: 6)))])]),
            Shape(name: "subsupAlone", body: [
                paragraph(t(words(14) + " x"), t("2", sup), t(" " + words(5, from: 4) + " H"), t("2", sub), t("O " + words(4, from: 10) + " "), t("small print words", small), t(" " + words(6, from: 16))),
            ]),
        ]
    }

    enum Container: String, CaseIterable, Sendable {
        case panel, quote, expand
        case bodiedExtension = "extension"

        func wrap(_ body: [String]) -> String {
            switch self {
            case .panel: return TK2ContainerProbe.panel(body)
            case .quote: return TK2ContainerProbe.quote(body)
            case .expand: return TK2ContainerProbe.expand(body)
            case .bodiedExtension: return TK2ContainerProbe.bodiedExtension(body)
            }
        }
    }

    /// The prepared children of a container block, or its expand body's
    /// first node id (an expand's body is prepared by the view on opening).
    static func probedOwner(_ block: RenderBlock) -> String? {
        switch block.kind {
        case .panel(_, let blocks), .quote(let blocks), .extensionPlaceholder(_, let blocks):
            return firstTextOwner(blocks)
        case .expand(_, let nodes, _):
            return nodes.first?.id
        case .layoutColumns(let columns):
            return columns.lazy.compactMap { firstTextOwner($0.blocks) }.first
        default:
            return firstTextOwner([block])
        }
    }

    /// The prepared shape of a block, for the log: kinds, nested.
    static func shapeDescription(_ block: RenderBlock) -> String {
        func list(_ blocks: [RenderBlock]) -> String { blocks.map(shapeDescription).joined(separator: ",") }
        switch block.kind {
        case .richText(_, let style): return style.isHeading ? "heading" : "paragraph"
        case .listRows(let rows): return "list(\(rows.count) rows)"
        case .panel(_, let children): return "panel[\(list(children))]"
        case .quote(let children): return "quote[\(list(children))]"
        case .extensionPlaceholder(_, let children): return "extension[\(list(children))]"
        case .expand(_, let nodes, _): return "expand[\(nodes.count) nodes: \(nodes.map(\.id).joined(separator: ","))]"
        case .layoutColumns(let columns): return "columns[\(columns.map { "\($0.widthPercent)%:" + list($0.blocks) }.joined(separator: " | "))]"
        default: return "other"
        }
    }

    /// The first text owner in `blocks`, depth first: a paragraph or
    /// heading, or a list row's leader.
    static func firstTextOwner(_ blocks: [RenderBlock]) -> String? {
        for block in blocks {
            switch block.kind {
            case .richText: return block.id
            case .listRows(let rows): if let row = rows.first(where: { !$0.segments.isEmpty }) { return row.id }
            case .panel(_, let children), .quote(let children), .extensionPlaceholder(_, let children):
                if let owner = firstTextOwner(children) { return owner }
            default: continue
            }
        }
        return nil
    }

    // MARK: Hosting

    /// The container child kinds the probe host enables before their stage
    /// (`adfContainerChildKinds`): the probed families, never code or media.
    static let probedKinds: Set<TextKit2BlockKind> = [.richText, .listRows, .panel, .quote, .expand, .extensionPlaceholder, .layoutColumns]

    /// `view` with the environment a document row gives its block: the
    /// renderer, the row's width bound (`adfTextWidthBound`, which the
    /// document seeds with its column on every row), the probed container
    /// kinds (`allowed`; `nil` keeps the production list, as the app has
    /// it), theme, direction, Bold Text, Dynamic Type, and the horizontal
    /// size class when one is given.
    @MainActor
    static func environment<V: View>(
        _ view: V, arm: ADFTextRenderer, env: TK2Parity.Environment, rowWidth: CGFloat,
        sizeClass: UserInterfaceSizeClass? = nil, search: ADFDocumentSearch? = nil,
        allowed: Set<TextKit2BlockKind>? = probedKinds
    ) -> some View {
        view
            .environment(\.adfTextRenderer, arm)
            .environment(\.adfTextWidthBound, .atLeast(rowWidth))
            .transformEnvironment(\.adfContainerChildKinds) { kinds in
                if let allowed { kinds = allowed }
            }
            .environment(\.adfTheme, theme)
            .environment(\.adfDocumentSearch, search)
            .environment(\.layoutDirection, env.direction)
            .environment(\.legibilityWeight, env.legibility)
            .transformEnvironment(\.horizontalSizeClass) { value in
                if let sizeClass { value = sizeClass }
            }
            .dynamicTypeSize(env.size)
    }

    struct Guides {
        var first: CGFloat
        var last: CGFloat
        var height: CGFloat
    }

    /// A view laid out at a width and its own height at the top-leading
    /// corner of a scene-less window at the device's native scale, kept up
    /// for inspection, re-hosting (a renderer flip) and rendering. Its
    /// enclosing stack reads the view's height and first and last text
    /// baselines as a baseline-aligned parent would (`TK2Parity.guides`).
    @MainActor
    final class Host {
        static let windowHeight: CGFloat = 9_000
        let window: UIWindow
        let controller: UIHostingController<AnyView>
        let box = TK2Parity.GuideBox()
        let width: CGFloat

        init(width: CGFloat, dark: Bool = false) {
            self.width = width
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: Self.windowHeight))
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            window.backgroundColor = dark ? .black : .white
            controller = UIHostingController(rootView: AnyView(EmptyView()))
            controller.view.backgroundColor = .clear
            controller.safeAreaRegions = []
            window.rootViewController = controller
            window.isHidden = false
        }

        /// Hosts `view`. The guides start over (NaN until the stack next
        /// reads them) unless `keepGuides`: a re-hosting that changes no
        /// layout (a renderer flip with no TextKit 2 row on either side)
        /// does not re-run the stack's alignment and leaves them as they
        /// were.
        func show(_ view: some View, keepGuides: Bool = false) {
            let box = box
            let width = width
            if !keepGuides {
                box.first = .nan
                box.last = .nan
                box.height = .nan
            }
            controller.rootView = AnyView(
                VStack(alignment: .leading, spacing: 0) {
                    view.fixedSize(horizontal: false, vertical: true).alignmentGuide(.leading) { dimensions in
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
            )
            layout()
        }

        func layout() {
            window.layoutIfNeeded()
            controller.view.layoutIfNeeded()
        }

        var guides: Guides { Guides(first: box.first, last: box.last, height: box.height) }
        var rows: [TextKit2RowView] { TextKit2FallbackTests.rows(in: controller.view) }

        /// The top `height` points of the window at the native scale.
        func bitmap(height: CGFloat) throws -> TK2Parity.Bitmap {
            try TK2Parity.bitmap(of: window, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    /// What one arm measured.
    struct Arm {
        var guides: Guides
        /// TextKit 2 rows by owner, with their owner kind and window frame.
        var rows: [(owner: String, kind: TextKit2OwnerKind, frame: CGRect)]
        var bitmap: TK2Parity.Bitmap?

        var owners: Set<String> { Set(rows.map(\.owner)) }
        var listRows: Int { rows.filter { $0.kind == .list }.count }
    }

    @MainActor
    static func arm(_ host: Host) -> Arm {
        Arm(guides: host.guides, rows: host.rows.map { row in
            (row.ownerID ?? "?", row.ownerKind, row.convert(row.bounds, to: nil))
        }, bitmap: nil)
    }

    /// Both arms in fresh hosts (`make` builds the hosted view for an
    /// arm), in dark appearance with `dark`; with `pixels`, both rendered
    /// over the same rectangle.
    @MainActor
    static func pair<V: View>(width: CGFloat, pixels: Bool, dark: Bool = false, _ make: (ADFTextRenderer) -> V) throws -> (swiftUI: Arm, textKit2: Arm) {
        let hostA = Host(width: width, dark: dark)
        let hostB = Host(width: width, dark: dark)
        defer {
            hostA.close()
            hostB.close()
        }
        hostA.show(make(.swiftUI))
        hostB.show(make(.textKit2))
        var a = arm(hostA), b = arm(hostB)
        if pixels {
            let height = (max(a.guides.height, b.guides.height) + 16).rounded(.up)
            a.bitmap = try hostA.bitmap(height: height)
            b.bitmap = try hostB.bitmap(height: height)
        }
        return (a, b)
    }

    /// The layout turns an open expand that draws no TextKit 2 row settles
    /// for before it is measured (`expandPair`'s `minimumTurns`).
    static let noRowTurns = 50

    /// An open expand on both arms, each in a fresh host. Its body is
    /// prepared by a `.task` on first opening and cached in view state, so
    /// each arm waits for it: TextKit 2 until `ready` holds for its rows
    /// and the geometry holds still; SwiftUI (no rows to wait for) until
    /// its geometry holds still at the TextKit 2 arm's height, or for 6 s,
    /// so a body that never lands there is measured as it is. The TextKit
    /// 2 host is then flipped to SwiftUI and back (the live switch: an
    /// environment change, the same view identity), and must measure as
    /// the first time (`stable`). Neither arm is measured after a flip.
    ///
    /// With no TextKit 2 row expected (a body the direction or size rule
    /// keeps on SwiftUI) nothing signals the opened body: `ready` is then
    /// `{ $0.isEmpty }` and each TextKit 2 settle first runs `minimumTurns`
    /// layout turns (`noRowTurns`, half a second), as the gated path waits.
    /// Such a flip changes no layout, so SwiftUI does not re-read the
    /// guides; the flips keep them (`Host.show(keepGuides:)`). A flip that
    /// did change the layout re-reads them, and the flipped host must
    /// draw the first time's pixels, else it is unstable.
    @MainActor
    static func expandPair<V: View>(
        width: CGFloat, pixels: Bool, dark: Bool = false, ready: @escaping ([TextKit2RowView]) -> Bool = { !$0.isEmpty },
        minimumTurns: Int = 0, _ make: (ADFTextRenderer) -> V
    ) async throws -> (swiftUI: Arm, textKit2: Arm, stable: Bool) {
        let host = Host(width: width, dark: dark)
        let swiftUIHost = Host(width: width, dark: dark)
        defer {
            host.close()
            swiftUIHost.close()
        }
        func settle(_ host: Host, _ what: String, turns: Int = 600, minimum: Int = 0, until done: () -> Bool) async throws -> Bool {
            var stableTurns = 0
            var last = ""
            for turn in 0..<turns {
                host.layout()
                let now = "\(host.guides.height) \(host.guides.first) \(host.guides.last) \(host.rows.count)"
                // With no row to wait for, a laid-out text guide (the
                // title's at least) marks a drawn expand.
                let drawn = minimum == 0 || !host.guides.first.isNaN
                stableTurns = (now == last && turn >= minimum && drawn && done()) ? stableTurns + 1 : 0
                last = now
                if stableTurns >= 3 { return true }
                try await Task.sleep(for: .milliseconds(10))
            }
            return false
        }
        host.show(make(.textKit2))
        guard try await settle(host, "first TextKit 2", minimum: minimumTurns, until: { ready(host.rows) }) else {
            throw TestFailure("the open expand did not settle (first TextKit 2: \(host.rows.count) rows)")
        }
        var b = arm(host)
        let height = (b.guides.height + 64).rounded(.up)
        if pixels { b.bitmap = try host.bitmap(height: height) }
        let firstDrawing: TK2Parity.Bitmap? = try minimumTurns > 0 ? (b.bitmap ?? host.bitmap(height: height)) : nil
        // The SwiftUI arm, fresh: main's first render of the open body.
        swiftUIHost.show(make(.swiftUI))
        let target = b.guides.height
        if !(try await settle(swiftUIHost, "SwiftUI", until: { swiftUIHost.rows.isEmpty && abs(swiftUIHost.guides.height - target) <= tolerance })) {
            _ = try await settle(swiftUIHost, "SwiftUI", turns: 50) { swiftUIHost.rows.isEmpty }
        }
        var a = arm(swiftUIHost)
        if pixels { a.bitmap = try swiftUIHost.bitmap(height: height) }
        // The live switch on the TextKit 2 host: off and on again.
        let noRow = minimumTurns > 0
        host.show(make(.swiftUI), keepGuides: noRow)
        guard try await settle(host, "SwiftUI after the flip", until: { host.rows.isEmpty }) else {
            throw TestFailure("the open expand did not settle (SwiftUI after the flip: \(host.rows.count) rows)")
        }
        host.show(make(.textKit2), keepGuides: noRow)
        guard try await settle(host, "TextKit 2 again", minimum: minimumTurns, until: { ready(host.rows) }) else {
            throw TestFailure("the open expand did not settle (TextKit 2 again: \(host.rows.count) rows)")
        }
        let again = arm(host)
        var stable = again.guides.height == b.guides.height && again.guides.first == b.guides.first
            && again.guides.last == b.guides.last && again.owners == b.owners
        if !stable {
            print("EXPAND_FLIP_UNSTABLE first=\(b.guides.height)/\(b.guides.first)/\(b.guides.last)/\(b.owners.sorted()) again=\(again.guides.height)/\(again.guides.first)/\(again.guides.last)/\(again.owners.sorted())")
        }
        // Kept guides prove nothing about the drawing: with no row the
        // flipped host must also draw the first time's pixels.
        if noRow, stable, let first = firstDrawing, try host.bitmap(height: height).rgba != first.rgba {
            print("EXPAND_FLIP_UNSTABLE pixels first=\(b.guides.height)/\(b.guides.first)/\(b.guides.last)")
            stable = false
        }
        return (a, b, stable)
    }

    // MARK: Comparison

    /// |x − y|, with two NaNs (no text guide on either arm) equal.
    nonisolated static func delta(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
        if x.isNaN && y.isNaN { return 0 }
        if x.isNaN || y.isNaN { return .infinity }
        return abs(x - y)
    }

    /// One case's outcome.
    struct Verdict {
        var dHeight: CGFloat = 0
        var dFirst: CGFloat = 0
        var dLast: CGFloat = 0
        /// SwiftUI's last-baseline guide one pixel below TextKit 2's (PR 1
        /// residual 1, `TextKit2ListParityTests.rowGeometry`): recorded,
        /// not a failure.
        var lastResidual = false
        var pixelsCompared = false
        var pixelFailures: [String] = []
        /// Pixels differing by more than 24 in a channel over the whole
        /// rendered rectangle.
        var differing = 0
        /// The probed owner drew through TextKit 2, and nothing did on the
        /// SwiftUI arm.
        var engine = true
        /// The pixel failures of a container's own chrome: its `icon` or
        /// `bar` crop, or the icon's offset from the first text ink. No
        /// TextKit 2 leaf draws there, so none is ever a leaf's residual.
        var chromeFailures: [String] = []
        /// Whether a chrome failure is the icon's offset from the first
        /// text ink (`marker`), not a crop's ink.
        var chromeOffsetFailed = false
        /// The differing pixels in the chrome crops' columns (`y * width +
        /// x`), when a chrome crop failed.
        var chromeDiffering: [Int] = []
        /// Where this case's differing pixels lie, by TextKit 2 owner
        /// (`TK2ContainerProbe.residual`), when any differ.
        var residual: Residual? = nil
        /// The same blocks hosted alone at the container's child width (no
        /// container), when the case failed (`LeafControl`). A container
        /// failure its blocks reproduce alone, owner by owner and row by
        /// row (`residualMismatch`), is the leaf's, not the container's.
        var leaf: LeafControl? = nil
        /// The last pixel row of dark (text) ink in the content, per arm.
        var textInkEnd: (swiftUI: Int?, textKit2: Int?)? = nil
        var notes: [String] = []

        /// At the same height and the same first baseline, the SwiftUI
        /// arm's text ink ends at least two pixel rows above the TextKit 2
        /// arm's: SwiftUI (main) drew fewer lines (a truncated or clipped
        /// paragraph). Text that starts lower on one arm is a shift, not a
        /// lost line.
        var mainDropsLines: Bool {
            guard dHeight <= TK2ContainerProbe.tolerance, dFirst <= TK2ContainerProbe.tolerance,
                  let end = textInkEnd, let a = end.swiftUI, let b = end.textKit2 else { return false }
            return b - a >= 2
        }

        /// Where a failure comes from: `mainDropsLines` (main's own drawing
        /// loses lines there), `leafAtWidth` (the blocks alone, at the same
        /// width with document margins, lay out apart too),
        /// `leafDrawing` (they alone differ in pixels only, the same owners
        /// in the same rows by about as many pixels: `residualMismatch` is
        /// `nil`), else `container`; `engine` when TextKit 2 did not draw
        /// the subject.
        var cause: String {
            if !engine { return "engine" }
            guard !pass else { return "-" }
            if mainDropsLines { return "mainDropsLines" }
            guard let leaf else { return "unchecked" }
            let leafGeometry = leaf.dHeight > TK2ContainerProbe.tolerance || leaf.dFirst > TK2ContainerProbe.tolerance
                || leaf.dLast > TK2ContainerProbe.tolerance
            if leafGeometry { return "leafAtWidth" }
            if geometryPass, leaf.pixelFailures > 0, residualMismatch == nil { return "leafDrawing" }
            return "container"
        }

        /// Why a pixel failure is not the leaf residual the leaf control
        /// shows, or `nil` when it is. The residual must account for every
        /// differing pixel, owner by owner (lead dispositions M3):
        /// - no failure on the container's chrome (`chromeFailures`),
        ///   unless every differing pixel in the chrome's columns is an
        ///   owner's overhang (below) that the owner alone shows at the
        ///   same place: a line-initial italic glyph's tail reaching into
        ///   a panel's icon column;
        /// - every differing pixel in the band of pixel rows of a TextKit 2
        ///   row on the TextKit 2 arm (`residualSlack` around it): none
        ///   outside, where chrome and text that both arms draw with
        ///   SwiftUI are. Those left or right of the row are its overhang
        ///   (`Residual.overhang`): SwiftUI's `Text` draws a line-initial
        ///   italic "j"'s tail past its frame, which the row clips at its
        ///   bounds (`TextKit2RowView`; the block alone shows it too);
        /// - for each owner with differing pixels, the same owner hosted
        ///   alone differs too, in the same pixel rows of its row (one row
        ///   either way, for a fractional placement), by exactly as many
        ///   pixels (`residualCountSlack`), and every one of its differing
        ///   pixels, overhang included, differing alone at the same place
        ///   relative to its row (one pixel either way, horizontally too:
        ///   review N4, Astra delta2 R3), so the same count in the same
        ///   rows at other x positions is not the leaf's residual;
        /// - no owner differs by more than `residualOwnerCap` pixels: a
        ///   residual is a few antialiased glyph edges, so a defect that
        ///   its leaf reproduces alone at the same width (a re-wrapped
        ///   line) is still rejected (delta review R2).
        /// A second defect beside a residual (another owner, other rows of
        /// the same owner, more pixels in them, past the row's edge, or
        /// chrome) fails, and so does the residual displaced along its
        /// rows (`TextKit2ContainerResidualTests`).
        var residualMismatch: String? {
            guard let leaf else { return "no leaf control" }
            if let chrome = chromeFailures.first {
                guard !chromeOffsetFailed, !chromeDiffering.isEmpty, let residual else { return "chrome: \(chrome)" }
                for pixel in chromeDiffering {
                    guard let (owner, offset) = residual.overhangAt[pixel], leaf.residual.differs(owner, at: offset) else {
                        return "chrome: \(chrome)"
                    }
                }
            }
            guard let residual else { return "no differing pixel to attribute" }
            if residual.unowned > 0 {
                return "\(residual.unowned) differing px outside every TextKit 2 row, first at \(residual.unownedFirst.map { "\($0.x),\($0.y)" } ?? "-")"
            }
            if residual.owners.isEmpty { return "no differing pixel to attribute" }
            for owner in residual.owners.keys.sorted() {
                let here = residual.owners[owner]!
                if here.count > TK2ContainerProbe.residualOwnerCap {
                    return "\(owner): \(here.count) px differ, past the per-owner cap of \(TK2ContainerProbe.residualOwnerCap)"
                }
                guard let alone = leaf.residual.owners[owner], alone.count > 0 else {
                    return "\(owner): \(here.count) px differ in the container, none alone"
                }
                var near = Set<Int>()
                for row in alone.rows { near.formUnion([row - 1, row, row + 1]) }
                let outside = here.rows.subtracting(near)
                if !outside.isEmpty {
                    return "\(owner): rows \(outside.sorted().prefix(4)) of its row differ in the container, not alone"
                }
                let unmatched = (residual.overhang[owner] ?? []).filter { !leaf.residual.differs(owner, at: $0) }
                if !unmatched.isEmpty {
                    return "\(owner): \(unmatched.count) px past its row's edges differ in the container, not alone"
                }
                if abs(here.count - alone.count) > TK2ContainerProbe.residualCountSlack {
                    return "\(owner): \(here.count) px differ in the container, \(alone.count) alone"
                }
                let displaced = (residual.offsets[owner] ?? []).filter { !leaf.residual.differs(owner, at: $0) }
                if let first = displaced.min(by: { ($0.y, $0.x) < ($1.y, $1.x) }) {
                    return "\(owner): \(displaced.count) px differ at other places of its row in the container than alone, first at \(first.x),\(first.y) of the row"
                }
            }
            return nil
        }

        var geometryPass: Bool {
            dHeight <= TK2ContainerProbe.tolerance && dFirst <= TK2ContainerProbe.tolerance
                && (dLast <= TK2ContainerProbe.tolerance || lastResidual)
        }
        var pass: Bool { geometryPass && pixelFailures.isEmpty }
    }

    @MainActor
    static func geometry(_ a: Guides, _ b: Guides) -> Verdict {
        var verdict = Verdict()
        verdict.dHeight = delta(a.height, b.height)
        verdict.dFirst = delta(a.first, b.first)
        verdict.dLast = delta(a.last, b.last)
        let onePixel = 1 / TK2Parity.nativeScale
        if verdict.dLast > tolerance, abs(a.last - b.last - onePixel) <= tolerance { verdict.lastResidual = true }
        return verdict
    }

    /// A crop of the rendered rectangle: pixel columns, compared against
    /// `background`.
    struct Crop {
        let name: String
        let columns: Range<Int>
    }

    /// Compares the crops of both arms' bitmaps (PR 2's row-pixel rule:
    /// first and last ink rows, per-row ink counts, each band's first and
    /// last ink column, at most 0.2 % differing pixels), and the offset
    /// of `marker`'s first ink row from `content`'s (an icon, a bar). A
    /// failure of an `icon` or `bar` crop, or of the offset, is the
    /// container's chrome (`Verdict.chromeFailures`). With `rows` (the
    /// TextKit 2 arm's), differing pixels are attributed to their owners
    /// (`residual`). `dark`: text ink is light (`lastTextRow`).
    @MainActor
    static func pixels(
        _ verdict: inout Verdict, _ a: TK2Parity.Bitmap, _ b: TK2Parity.Bitmap, crops: [Crop], background: (Int, Int, Int),
        marker: (marker: Crop, content: Crop)? = nil, rows: [(owner: String, kind: TextKit2OwnerKind, frame: CGRect)]? = nil,
        dark: Bool = false
    ) {
        verdict.pixelsCompared = true
        guard a.width == b.width, a.height == b.height else {
            verdict.pixelFailures.append("bitmaps differ in size \(a.width)x\(a.height) / \(b.width)x\(b.height)")
            return
        }
        verdict.differing = TK2Parity.differingPixels(a, b, columns: 0..<a.width, rows: 0..<a.height).count
        if let rows, verdict.differing > 0 { verdict.residual = residual(a, b, rows: rows) }
        var inks: [String: (TextKit2ListParityTests.Ink, TextKit2ListParityTests.Ink)] = [:]
        for crop in crops {
            let ia = TextKit2ListParityTests.ink(a, columns: crop.columns, background: background)
            let ib = TextKit2ListParityTests.ink(b, columns: crop.columns, background: background)
            inks[crop.name] = (ia, ib)
            let failures = TextKit2ListParityTests.compareInk(crop.name, ia, ib, a, b, columns: crop.columns)
            verdict.pixelFailures += failures
            if Self.chromeCrops.contains(crop.name), !failures.isEmpty {
                verdict.chromeFailures += failures
                verdict.chromeDiffering += differingIndices(a, b, columns: crop.columns)
            }
        }
        if let text = crops.first(where: { !Self.chromeCrops.contains($0.name) }) {
            verdict.textInkEnd = (lastTextRow(a, columns: text.columns, dark: dark), lastTextRow(b, columns: text.columns, dark: dark))
        }
        if let marker, let m = inks[marker.marker.name], let c = inks[marker.content.name] {
            let offset = { (m: TextKit2ListParityTests.Ink, c: TextKit2ListParityTests.Ink) -> Int? in
                guard let first = m.firstRow, let text = c.firstRow else { return nil }
                return first - text
            }
            let oa = offset(m.0, c.0), ob = offset(m.1, c.1)
            if oa != ob {
                let failure = "\(marker.marker.name) offset from the first text ink swiftUI=\(String(describing: oa)) textKit2=\(String(describing: ob))"
                verdict.pixelFailures.append(failure)
                verdict.chromeFailures.append(failure)
                verdict.chromeOffsetFailed = true
            }
            verdict.notes.append("markerOffset=\(oa.map(String.init) ?? "nil")/\(ob.map(String.init) ?? "nil")")
        }
    }

    /// The crops of a container's own chrome (a panel's icon column, a
    /// quote's bar), where no TextKit 2 leaf draws.
    static let chromeCrops: Set<String> = ["icon", "bar"]

    /// The last pixel row holding text ink: a pixel dark in every channel
    /// in light appearance, light in every channel in dark appearance
    /// (text; not the backgrounds, borders or the tinted panel icon).
    static func lastTextRow(_ bitmap: TK2Parity.Bitmap, columns: Range<Int>, dark: Bool = false) -> Int? {
        let columns = columns.clamped(to: 0..<bitmap.width)
        guard !columns.isEmpty else { return nil }
        return bitmap.rgba.withUnsafeBufferPointer { pixels -> Int? in
            for y in stride(from: bitmap.height - 1, through: 0, by: -1) {
                var i = (y * bitmap.width + columns.lowerBound) * 4
                for _ in columns {
                    let isText = dark
                        ? pixels[i] > 95 && pixels[i + 1] > 95 && pixels[i + 2] > 95
                        : pixels[i] < 160 && pixels[i + 1] < 160 && pixels[i + 2] < 160
                    if isText { return y }
                    i += 4
                }
            }
            return nil
        }
    }

    // MARK: Residual attribution

    /// Where one comparison's differing pixels lie (more than 24 apart in
    /// a channel, as `Verdict.differing` counts them): for each TextKit 2
    /// owner, how many lie in its row and which pixel rows of the row
    /// (from the row's top edge on the device's pixel grid); `unowned`,
    /// those outside every TextKit 2 row of the TextKit 2 arm.
    struct Residual: Sendable {
        /// A pixel's place relative to its row's top-left device pixel.
        struct Offset: Hashable, Sendable {
            let x: Int
            let y: Int
        }

        var owners: [String: (count: Int, rows: Set<Int>)] = [:]
        /// Every pixel counted in `owners`, relative to its row.
        var offsets: [String: Set<Offset>] = [:]
        /// The owners' differing pixels in the band of pixel rows of their
        /// row but left or right of it (counted in `owners` too): glyph
        /// overhang the row does not draw, relative to the row.
        var overhang: [String: Set<Offset>] = [:]
        /// The same pixels by place in the bitmap (`y * width + x`), for
        /// one comparison (not merged).
        var overhangAt: [Int: (owner: String, offset: Offset)] = [:]
        var unowned = 0
        var unownedFirst: (x: Int, y: Int)? = nil

        mutating func merge(_ other: Residual) {
            for (owner, entry) in other.owners {
                var mine = owners[owner] ?? (0, [])
                mine.count += entry.count
                mine.rows.formUnion(entry.rows)
                owners[owner] = mine
            }
            for (owner, entry) in other.offsets { offsets[owner, default: []].formUnion(entry) }
            for (owner, entry) in other.overhang { overhang[owner, default: []].formUnion(entry) }
            unowned += other.unowned
            if unownedFirst == nil { unownedFirst = other.unownedFirst }
        }

        /// Whether `owner` has a differing pixel at `offset` of its row, one
        /// pixel either way (a fractional placement).
        func differs(_ owner: String, at offset: Offset) -> Bool {
            guard let mine = offsets[owner] else { return false }
            for dy in -1...1 {
                for dx in -1...1 where mine.contains(Offset(x: offset.x + dx, y: offset.y + dy)) { return true }
            }
            return false
        }

        var summary: String {
            let parts = owners.keys.sorted().map { owner in
                let past = overhang[owner]?.count ?? 0
                return "\(owner):\(owners[owner]!.count)\(past > 0 ? "(\(past) past)" : "")"
            }
            return "{\(parts.joined(separator: ","))\(unowned > 0 ? ",unowned:\(unowned)" : "")}"
        }
    }

    /// How far outside its row's bounds an owner's ink may differ, in
    /// points on every side: glyph ink drawn past the line box
    /// (antialiased edges, italic overhang). Under half the smallest gap
    /// between two text rows (a list's row spacing, 6 pt), so no pixel is
    /// near two rows, and far under a quote's or a panel's inset to its
    /// bar or icon.
    static let residualSlack: CGFloat = 2

    /// How many more or fewer differing pixels an owner may show in its
    /// container than alone: none. Every accepted leaf-drawing case
    /// matched its leaf control's count exactly (428 accepted cases in the
    /// family and default matrices at 3x and 2x, largest difference 0:
    /// fixP logs t-f1, t-w9, t-w10, t-w12, t-w15, t-w17, t-s1; delta
    /// review R2).
    static let residualCountSlack = 0

    /// The most pixels one owner's residual may differ by. Measured over
    /// the same 428 accepted cases, taken when containers kept TextKit 2
    /// up to AX3: at most 170 px for an owner (an AX3 paragraph in an
    /// extension body, 320 pt), and 359 px at AX5 before the size rule (a
    /// panel paragraph, t-f1). 512 is the next power of two above every
    /// measured residual; a defect of thousands of pixels (a re-wrapped
    /// line is 13,000 and up) fails whether or not its leaf reproduces it
    /// alone (`TextKit2ContainerResidualTests`).
    static let residualOwnerCap = 512

    /// The residual of `a` against `b` by TextKit 2 owner: `rows` are the
    /// TextKit 2 arm's rows (window frames; the bitmaps start at the
    /// window's origin).
    static func residual(
        _ a: TK2Parity.Bitmap, _ b: TK2Parity.Bitmap, rows: [(owner: String, kind: TextKit2OwnerKind, frame: CGRect)]
    ) -> Residual {
        let scale = a.scale
        let rects: [(owner: String, x: Range<Int>, y: Range<Int>, top: Int, left: Int)] = rows.map { row in
            let grown = row.frame.insetBy(dx: -residualSlack, dy: -residualSlack)
            let x0 = Int((grown.minX * scale).rounded(.down)), x1 = Int((grown.maxX * scale).rounded(.up))
            let y0 = Int((grown.minY * scale).rounded(.down)), y1 = Int((grown.maxY * scale).rounded(.up))
            return (row.owner, x0..<max(x0, x1), y0..<max(y0, y1), Int((row.frame.minY * scale).rounded()), Int((row.frame.minX * scale).rounded()))
        }
        func distance(_ x: Int, _ range: Range<Int>) -> Int { x < range.lowerBound ? range.lowerBound - x : x - range.upperBound + 1 }
        var result = Residual()
        guard a.width == b.width, a.height == b.height else { return result }
        a.rgba.withUnsafeBufferPointer { p in
            b.rgba.withUnsafeBufferPointer { q in
                for y in 0..<a.height {
                    var i = y * a.width * 4
                    for x in 0..<a.width {
                        let differs = abs(Int(p[i]) - Int(q[i])) > 24 || abs(Int(p[i + 1]) - Int(q[i + 1])) > 24
                            || abs(Int(p[i + 2]) - Int(q[i + 2])) > 24
                        i += 4
                        guard differs else { continue }
                        if let rect = rects.first(where: { $0.x.contains(x) && $0.y.contains(y) }) {
                            var entry = result.owners[rect.owner] ?? (0, [])
                            entry.count += 1
                            entry.rows.insert(y - rect.top)
                            result.owners[rect.owner] = entry
                            result.offsets[rect.owner, default: []].insert(Residual.Offset(x: x - rect.left, y: y - rect.top))
                        } else if let rect = rects.filter({ $0.y.contains(y) }).min(by: { distance(x, $0.x) < distance(x, $1.x) }) {
                            // In the row's band of pixel rows, left or right
                            // of it: its overhang.
                            var entry = result.owners[rect.owner] ?? (0, [])
                            entry.count += 1
                            entry.rows.insert(y - rect.top)
                            result.owners[rect.owner] = entry
                            let offset = Residual.Offset(x: x - rect.left, y: y - rect.top)
                            result.offsets[rect.owner, default: []].insert(offset)
                            result.overhang[rect.owner, default: []].insert(offset)
                            result.overhangAt[y * a.width + x] = (rect.owner, offset)
                        } else {
                            result.unowned += 1
                            if result.unownedFirst == nil { result.unownedFirst = (x, y) }
                        }
                    }
                }
            }
        }
        return result
    }

    /// The pixels of `columns` more than 24 apart in a channel, as
    /// `y * width + x`.
    static func differingIndices(_ a: TK2Parity.Bitmap, _ b: TK2Parity.Bitmap, columns: Range<Int>) -> [Int] {
        guard a.width == b.width, a.height == b.height else { return [] }
        let columns = columns.clamped(to: 0..<a.width)
        var result: [Int] = []
        for y in 0..<a.height {
            for x in columns {
                let i = (y * a.width + x) * 4
                if abs(Int(a.rgba[i]) - Int(b.rgba[i])) > 24 || abs(Int(a.rgba[i + 1]) - Int(b.rgba[i + 1])) > 24
                    || abs(Int(a.rgba[i + 2]) - Int(b.rgba[i + 2])) > 24 {
                    result.append(y * a.width + x)
                }
            }
        }
        return result
    }

    /// The page background the hosts draw on, in light or dark appearance.
    static func background(_ env: TK2Parity.Environment) -> (Int, Int, Int) { env.dark ? (0, 0, 0) : (255, 255, 255) }

    /// The pixel columns `[from, to)` points span, mirrored right to left.
    static func columns(from: CGFloat, to: CGFloat, width: CGFloat, scale: CGFloat, rtl: Bool) -> Range<Int> {
        let lo = rtl ? width - to : from
        let hi = rtl ? width - from : to
        let pixelWidth = Int((width * scale + 0.01).rounded(.down))
        let lower = max(0, Int((lo * scale).rounded()))
        let upper = min(pixelWidth, Int((hi * scale).rounded()))
        return lower..<max(lower, upper)
    }

    /// The background at a point of a bitmap (points).
    static func sample(_ bitmap: TK2Parity.Bitmap, x: CGFloat, y: CGFloat) -> (Int, Int, Int) {
        let px = min(max(Int(x * bitmap.scale), 0), bitmap.width - 1)
        let py = min(max(Int(y * bitmap.scale), 0), bitmap.height - 1)
        let p = bitmap[px, py]
        return (p.r, p.g, p.b)
    }

    /// The layout width of a panel's icon, as `PanelBlockView` draws it
    /// (no frame, the inherited font: none set, so body), at `env`.
    @MainActor
    static func iconWidth(_ symbol: String, env: TK2Parity.Environment) -> CGFloat {
        let key = "\(symbol) \(env.size) \(env.legibility == .bold)"
        if let cached = iconWidths[key] { return cached }
        let width = TK2Parity.attachedSize(
            Image(systemName: symbol)
                .environment(\.legibilityWeight, env.legibility)
                .dynamicTypeSize(env.size),
            width: 200
        ).width
        iconWidths[key] = width
        return width
    }
    @MainActor static var iconWidths: [String: CGFloat] = [:]

    // MARK: Reporting

    static func format(_ value: CGFloat) -> String {
        value.isFinite ? String(format: "%.3f", value) : "\(value)"
    }

    /// Per-group totals: one line per probe × container × shape × direction.
    @MainActor
    final class Tally {
        struct Group {
            var cases = 0
            var pass = 0
            var geometryFail = 0
            var pixelFail = 0
            var engineFail = 0
            var lastResidual = 0
            var pixelCases = 0
            var worstHeight: CGFloat = 0
            var worstFirst: CGFloat = 0
            var worstLast: CGFloat = 0
            var maxDiffering = 0
            var causes: [String: Int] = [:]
            var firstFailure = ""
            var firstContainerFailure = ""
        }
        var groups: [String: Group] = [:]
        var order: [String] = []

        func add(_ key: String, label: String, _ verdict: Verdict) {
            if groups[key] == nil { order.append(key); groups[key] = Group() }
            var group = groups[key]!
            group.cases += 1
            if verdict.pass && verdict.engine { group.pass += 1 }
            if !verdict.geometryPass { group.geometryFail += 1 }
            if !verdict.pixelFailures.isEmpty { group.pixelFail += 1 }
            if !verdict.engine { group.engineFail += 1 }
            if verdict.lastResidual { group.lastResidual += 1 }
            if verdict.pixelsCompared { group.pixelCases += 1 }
            group.worstHeight = max(group.worstHeight, verdict.dHeight)
            group.worstFirst = max(group.worstFirst, verdict.dFirst)
            group.worstLast = max(group.worstLast, verdict.lastResidual ? 0 : verdict.dLast)
            group.maxDiffering = max(group.maxDiffering, verdict.differing)
            if group.firstFailure.isEmpty, !(verdict.pass && verdict.engine) { group.firstFailure = label }
            let cause = verdict.cause
            if cause != "-" { group.causes[cause, default: 0] += 1 }
            if cause == "container" || cause == "unchecked", group.firstContainerFailure.isEmpty { group.firstContainerFailure = label }
            groups[key] = group
        }

        func print(probe: String) {
            for key in order {
                let g = groups[key]!
                Swift.print("CONTAINER_PROBE_SUMMARY probe=\(probe) \(key) scale=\(TK2Parity.nativeScale) os=\(TK2Parity.osVersion) cases=\(g.cases) pass=\(g.pass) geometryFail=\(g.geometryFail) pixelFail=\(g.pixelFail)/\(g.pixelCases) engineFail=\(g.engineFail) lastResidual1px=\(g.lastResidual) worstDH=\(TK2ContainerProbe.format(g.worstHeight)) worstDFirst=\(TK2ContainerProbe.format(g.worstFirst)) worstDLast=\(TK2ContainerProbe.format(g.worstLast)) maxDiffering=\(g.maxDiffering) causes=\(g.causes.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")) firstFailure={\(g.firstFailure)} firstContainerFailure={\(g.firstContainerFailure)}")
            }
        }
    }

    @MainActor
    static func line(_ fields: String, _ verdict: Verdict, _ a: Arm, _ b: Arm) -> String {
        var line = "CONTAINER_PROBE \(fields) scale=\(TK2Parity.nativeScale) os=\(TK2Parity.osVersion) result=\(verdict.pass && verdict.engine ? "pass" : "fail")"
        line += " dH=\(format(verdict.dHeight)) dFirst=\(format(verdict.dFirst)) dLast=\(format(verdict.dLast))\(verdict.lastResidual ? "(residual1px)" : "")"
        line += " h=\(format(a.guides.height))/\(format(b.guides.height)) first=\(format(a.guides.first))/\(format(b.guides.first)) last=\(format(a.guides.last))/\(format(b.guides.last))"
        line += " tk2Rows=\(b.rows.count) listRows=\(b.listRows) engine=\(verdict.engine)"
        if verdict.pixelsCompared { line += " differing=\(verdict.differing) pixelFailures=\(verdict.pixelFailures.count)" }
        line += " cause=\(verdict.cause)"
        if let end = verdict.textInkEnd { line += " textInkEnd=\(end.swiftUI.map(String.init) ?? "nil")/\(end.textKit2.map(String.init) ?? "nil")" }
        if let leaf = verdict.leaf {
            line += " leaf=dH:\(format(leaf.dHeight)),dFirst:\(format(leaf.dFirst)),dLast:\(format(leaf.dLast)),differing:\(leaf.differing),pixelFailures:\(leaf.pixelFailures)"
            if !verdict.pass, verdict.geometryPass {
                line += " residual=\(verdict.residual?.summary ?? "-") leafResidual=\(leaf.residual.summary)"
                if let mismatch = verdict.residualMismatch { line += " residualMismatch={\(mismatch)}" }
            }
        }
        if !verdict.notes.isEmpty { line += " " + verdict.notes.joined(separator: " ") }
        if let failure = verdict.pixelFailures.first { line += " firstPixelFailure={\(failure)}" }
        return line
    }

    // MARK: Matrix

    /// `ADF_CONTAINER_PROBES_WIDTHS=<pt,…>` and `ADF_CONTAINER_PROBES_SIZES=<name,…>`
    /// (`DynamicTypeSize` case names) replace the mode's document widths and
    /// sizes, to reproduce one case.
    static var documentWidths: [CGFloat] {
        if let widths = override("ADF_CONTAINER_PROBES_WIDTHS", { Double($0).map { CGFloat($0) } }) { return widths }
        return fullMatrix ? [320, 375, 402, 640] : familyMatrix ? [320, 402] : [375]
    }
    static var sizes: [DynamicTypeSize] {
        if let sizes = override("ADF_CONTAINER_PROBES_SIZES", { name in DynamicTypeSize.allCases.first { "\($0)" == name } }) { return sizes }
        return fullMatrix ? DynamicTypeSize.allCases : familyMatrix ? familySizes : [.large, .xxLarge]
    }
    static func override<T>(_ key: String, _ parse: (String) -> T?) -> [T]? {
        guard let value = ProcessInfo.processInfo.environment[key] else { return nil }
        let parsed = value.split(separator: ",").compactMap { parse(String($0)) }
        return parsed.isEmpty ? nil : parsed
    }
    static var directions: [LayoutDirection] { fullMatrix || familyMatrix ? [.leftToRight, .rightToLeft] : [.leftToRight] }
    static var weights: [LegibilityWeight?] { fullMatrix || familyMatrix ? [nil, .bold] : [nil] }
    /// Whether a case is also compared as pixels: every case of the sample;
    /// in the full matrix, `familySizes` at 320 and
    /// 402 pt (geometry runs at every size and width), or every case with
    /// `ADF_CONTAINER_PROBES_PIXELS=all`.
    static func comparesPixels(_ env: TK2Parity.Environment, documentWidth: CGFloat) -> Bool {
        guard fullMatrix, ProcessInfo.processInfo.environment["ADF_CONTAINER_PROBES_PIXELS"] != "all" else { return true }
        return familySizes.contains(env.size) && [320, 402].contains(documentWidth)
    }

    /// The width a container gives its children (PR 4 plan §4.2's insets;
    /// a panel's icon at its measured width).
    @MainActor
    static func childWidth(_ container: Container, rowWidth: CGFloat, env: TK2Parity.Environment) -> CGFloat {
        switch container {
        case .panel: return rowWidth - spacing * 4.5 - iconWidth("info.circle.fill", env: env)
        case .quote: return rowWidth - spacing * 2
        case .expand: return rowWidth - spacing * 2.5
        case .bodiedExtension: return rowWidth - spacing * 3
        }
    }

    /// The leaf control: the blocks of a container hosted alone, at the
    /// container's child width, on both arms. Summed |Δheight|, the largest
    /// |Δ first| and |Δ last baseline| (net of PR 1 residual 1), the
    /// differing pixels, how many blocks failed the pixel rule on their
    /// own, and where their differing pixels lie by owner (`residual`).
    struct LeafControl {
        var dHeight: CGFloat = 0
        var dFirst: CGFloat = 0
        var dLast: CGFloat = 0
        var differing = 0
        var pixelFailures = 0
        var residual = Residual()

        /// Adds one block hosted alone (`a`, `b`: its two arms).
        @MainActor
        mutating func add(_ a: Arm, _ b: Arm, dark: Bool) {
            var verdict = TK2ContainerProbe.geometry(a.guides, b.guides)
            dHeight += verdict.dHeight
            dFirst = max(dFirst, verdict.dFirst)
            dLast = max(dLast, verdict.lastResidual ? 0 : verdict.dLast)
            if let x = a.bitmap, let y = b.bitmap {
                TK2ContainerProbe.pixels(
                    &verdict, x, y, crops: [Crop(name: "leaf", columns: 0..<x.width)], background: dark ? (0, 0, 0) : (255, 255, 255),
                    rows: b.rows, dark: dark
                )
            }
            differing += verdict.differing
            if !verdict.pixelFailures.isEmpty { pixelFailures += 1 }
            if let residual = verdict.residual { self.residual.merge(residual) }
        }

        /// Adds another control's blocks (a layout section's other column).
        mutating func merge(_ other: LeafControl) {
            dHeight += other.dHeight
            dFirst = max(dFirst, other.dFirst)
            dLast = max(dLast, other.dLast)
            differing += other.differing
            pixelFailures += other.pixelFailures
            residual.merge(other.residual)
        }
    }

    /// Hosts each block alone at `width` on both arms, inset by the
    /// document's 16 pt margins as a top-level row is (so ink a glyph draws
    /// outside its frame is in the picture, as in a container): the leaf
    /// control.
    @MainActor
    static func leafControl(_ blocks: [RenderBlock], width: CGFloat, env: TK2Parity.Environment) throws -> LeafControl {
        var result = LeafControl()
        let margin = spacing * 2
        for block in blocks {
            let (a, b) = try pair(width: width + 2 * margin, pixels: true, dark: env.dark) { arm in
                environment(BlockView(block: block).padding(.horizontal, margin), arm: arm, env: env, rowWidth: width)
            }
            result.add(a, b, dark: env.dark)
        }
        return result
    }

    /// With `ADF_CONTAINER_PROBES_DUMP=<directory>`, failing cases' bitmaps
    /// are written there as PNGs (both arms and a difference mask), at most
    /// `dumpLimit` per group.
    static var dumpDirectory: String? { ProcessInfo.processInfo.environment["ADF_CONTAINER_PROBES_DUMP"] }
    static let dumpLimit = 2
    @MainActor static var dumped: [String: Int] = [:]

    @MainActor
    static func dump(_ group: String, _ name: String, _ a: TK2Parity.Bitmap, _ b: TK2Parity.Bitmap) {
        guard let directory = dumpDirectory, a.width == b.width, a.height == b.height else { return }
        guard dumped[group, default: 0] < dumpLimit else { return }
        dumped[group, default: 0] += 1
        var mask = a.rgba
        for i in stride(from: 0, to: mask.count, by: 4) {
            let differs = abs(Int(a.rgba[i]) - Int(b.rgba[i])) > 24 || abs(Int(a.rgba[i + 1]) - Int(b.rgba[i + 1])) > 24 || abs(Int(a.rgba[i + 2]) - Int(b.rgba[i + 2])) > 24
            if differs { (mask[i], mask[i + 1], mask[i + 2]) = (255, 0, 0) } else { (mask[i], mask[i + 1], mask[i + 2]) = (mask[i] / 3 + 170, mask[i + 1] / 3 + 170, mask[i + 2] / 3 + 170) }
        }
        let safe = name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_" }
        for (suffix, rgba) in [("swiftUI", a.rgba), ("textKit2", b.rgba), ("diff", mask)] {
            guard let provider = CGDataProvider(data: Data(rgba) as CFData),
                  let image = CGImage(width: a.width, height: a.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: a.width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                  let png = UIImage(cgImage: image).pngData() else { continue }
            try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(String(safe))-\(suffix).png"))
        }
    }

    /// The width a document row gives its block: 16 pt in from each side.
    static func rowWidth(documentWidth: CGFloat) -> CGFloat { documentWidth - 4 * spacing }

    static func environments() -> [TK2Parity.Environment] {
        var all: [TK2Parity.Environment] = []
        for direction in directions {
            for weight in weights {
                for size in sizes { all.append(TK2Parity.Environment(size: size, direction: direction, legibility: weight)) }
            }
        }
        return all
    }

    /// The production matrices' cases: every environment at every
    /// document width, and in the sample (no mode, no override) a fixed
    /// set of corners besides, so the default run also sees a 320 pt
    /// document, right to left, Bold Text, dark appearance and the
    /// accessibility sizes (`sampleCorners`).
    static func cases() -> [(env: TK2Parity.Environment, documentWidth: CGFloat)] {
        var all: [(env: TK2Parity.Environment, documentWidth: CGFloat)] = []
        for env in environments() {
            for documentWidth in documentWidths { all.append((env, documentWidth)) }
        }
        if mode == "sample", !overridden { all += sampleCorners }
        return all
    }

    /// The sample's corner cases (code review F-R5; sizes after lead call
    /// C55): xxLarge (the largest size the container size rule keeps on
    /// TextKit 2), xxxLarge (the first it keeps on SwiftUI), AX3 and AX5
    /// (past it: the body on SwiftUI on both arms) in a 320 pt document;
    /// right to left with Bold Text at Large in a 320 pt document and at
    /// xxLarge and AX3 in a 375 pt one; dark appearance at Large, xxLarge
    /// and AX3 in a 375 pt document.
    static let sampleCorners: [(env: TK2Parity.Environment, documentWidth: CGFloat)] = [
        (TK2Parity.Environment(size: .accessibility5), 320),
        (TK2Parity.Environment(size: .accessibility3), 320),
        (TK2Parity.Environment(size: .xxxLarge), 320),
        (TK2Parity.Environment(size: .xxLarge), 320),
        (TK2Parity.Environment(size: .large, direction: .rightToLeft, legibility: .bold), 320),
        (TK2Parity.Environment(size: .xxLarge, direction: .rightToLeft, legibility: .bold), 375),
        (TK2Parity.Environment(size: .accessibility3, direction: .rightToLeft, legibility: .bold), 375),
        (TK2Parity.Environment(size: .large, dark: true), 375),
        (TK2Parity.Environment(size: .xxLarge, dark: true), 375),
        (TK2Parity.Environment(size: .accessibility3, dark: true), 375),
    ]

    /// Whether `ADF_CONTAINER_PROBES_WIDTHS` or `ADF_CONTAINER_PROBES_SIZES`
    /// replaced the matrix.
    static var overridden: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["ADF_CONTAINER_PROBES_WIDTHS"] != nil || environment["ADF_CONTAINER_PROBES_SIZES"] != nil
    }

    static func fields(_ env: TK2Parity.Environment) -> String {
        "size=\(env.size) bold=\(env.legibility == .bold ? 1 : 0) dir=\(env.direction == .rightToLeft ? "rtl" : "ltr")\(env.dark ? " dark=1" : "")"
    }
}

@Suite("TextKit 2 container probes (PR 4 step 1a)", .serialized)
@MainActor
struct TextKit2ContainerParityTests {
    typealias P = TK2ContainerProbe

    // MARK: panelShapes, quoteExpandExtensionShapes

    /// Before iOS 26: the container gate holds for every shape of
    /// `container` (no TextKit 2 row for its text, even with the probed
    /// kinds allowed), at one environment.
    func assertContainerGate(_ container: P.Container, probe: String) async throws {
        var drawn: [String] = []
        let width = P.rowWidth(documentWidth: 375)
        for shape in P.shapes {
            let block = try #require(try await P.prepared([container.wrap(shape.body)]).first)
            let model = ADFDocumentModel()
            if container == .expand { model.expandedBlocks.insert(block.id) }
            let make = { (arm: ADFTextRenderer) in
                P.environment(BlockView(block: block), arm: arm, env: TK2Parity.Environment(), rowWidth: width, search: model.search)
            }
            let b: P.Arm
            if container == .expand {
                // The body is prepared on opening: settle on the SwiftUI arm
                // first, then flip (the gate leaves no row to wait for).
                let host = P.Host(width: width)
                defer { host.close() }
                host.show(make(.swiftUI))
                for _ in 0..<50 { host.layout(); try await Task.sleep(for: .milliseconds(10)) }
                host.show(make(.textKit2))
                for _ in 0..<20 { host.layout(); try await Task.sleep(for: .milliseconds(10)) }
                b = P.arm(host)
            } else {
                b = try P.pair(width: width, pixels: false, make).textKit2
            }
            if !b.rows.isEmpty { drawn.append("\(shape.name): \(b.owners.sorted())") }
        }
        print("CONTAINER_PROBE_GATE probe=\(probe) container=\(container.rawValue) os=\(TK2Parity.osVersion) drawn=\(drawn.count)")
        #expect(drawn.isEmpty, "before iOS 26 container text drew on TextKit 2: \(drawn)")
    }

    /// Runs the shape matrix on one container kind, recording each case.
    func shapeMatrix(_ container: P.Container, probe: String) async throws {
        guard TextKit2Eligibility.containerTextMatchesText else {
            try await assertContainerGate(container, probe: probe)
            return
        }
        let clock = ContinuousClock()
        let start = clock.now
        let tally = P.Tally()
        var engineMisses: [String] = []
        for shape in P.shapes {
            let blocks = try await P.prepared([container.wrap(shape.body)])
            let block = try #require(blocks.first)
            let owner = try #require(P.probedOwner(block), "\(container) \(shape.name): no text owner")
            let leaves = try await P.prepared(shape.body)
            print("CONTAINER_PROBE_SHAPE container=\(container.rawValue) shape=\(shape.name) owner=\(owner) prepared=\(P.shapeDescription(block))")
            let model = ADFDocumentModel()
            if container == .expand { model.expandedBlocks.insert(block.id) }
            for env in P.environments() {
                for documentWidth in P.documentWidths {
                    let width = P.rowWidth(documentWidth: documentWidth)
                    let pixels = P.comparesPixels(env, documentWidth: documentWidth)
                    let make = { (arm: ADFTextRenderer) in
                        P.environment(BlockView(block: block), arm: arm, env: env, rowWidth: width, search: model.search)
                    }
                    // Right to left and from xxxLarge the container keeps
                    // its body on SwiftUI (the container direction rule,
                    // lead dispositions F-Q6; the container size rule, lead
                    // call C55): the engine is then no row.
                    let rtl = env.direction == .rightToLeft || !TextKit2Scope.containerSizeKeepsRenderer(env.size)
                    let a: P.Arm, b: P.Arm
                    var stable = true
                    if container == .expand {
                        (a, b, stable) = try await P.expandPair(
                            width: width, pixels: pixels, ready: rtl ? { $0.isEmpty } : { !$0.isEmpty }, minimumTurns: rtl ? P.noRowTurns : 0, make
                        )
                    } else {
                        (a, b) = try P.pair(width: width, pixels: pixels, make)
                    }
                    var verdict = P.geometry(a.guides, b.guides)
                    verdict.engine = a.rows.isEmpty && (rtl ? b.rows.isEmpty : b.owners.contains(owner))
                    if !stable { verdict.notes.append("flipUnstable") }
                    if a.guides.height > P.Host.windowHeight - 20 { verdict.notes.append("taller-than-window") }
                    if pixels, let ba = a.bitmap, let bb = b.bitmap {
                        crops(&verdict, container, ba, bb, width: width, env: env, swiftUIArm: a, textKit2Arm: b)
                    }
                    let fields = "probe=\(probe) container=\(container.rawValue) shape=\(shape.name) \(P.fields(env)) W=\(documentWidth)"
                    let key = "container=\(container.rawValue) shape=\(shape.name) dir=\(env.direction == .rightToLeft ? "rtl" : "ltr")"
                    if !(verdict.pass && verdict.engine) {
                        verdict.leaf = try P.leafControl(leaves, width: P.childWidth(container, rowWidth: width, env: env), env: env)
                        var bitmaps = (a.bitmap, b.bitmap)
                        if !pixels {
                            // A failing case outside the pixel sample is
                            // rendered too: for the text-ink check and the dump.
                            let (pa, pb): (P.Arm, P.Arm)
                            if container == .expand {
                                (pa, pb, _) = try await P.expandPair(
                                    width: width, pixels: true, ready: rtl ? { $0.isEmpty } : { !$0.isEmpty }, minimumTurns: rtl ? P.noRowTurns : 0, make
                                )
                            } else {
                                (pa, pb) = try P.pair(width: width, pixels: true, make)
                            }
                            bitmaps = (pa.bitmap, pb.bitmap)
                            if let ba = pa.bitmap, let bb = pb.bitmap {
                                var extra = P.Verdict()
                                crops(&extra, container, ba, bb, width: width, env: env, swiftUIArm: pa, textKit2Arm: pb)
                                verdict.textInkEnd = extra.textInkEnd
                                verdict.notes.append("unsampledPixelFailures=\(extra.pixelFailures.count)")
                            }
                        }
                        if let ba = bitmaps.0, let bb = bitmaps.1 { P.dump(key, fields, ba, bb) }
                    }
                    tally.add(key, label: "\(P.fields(env)) W=\(documentWidth) dH=\(P.format(verdict.dHeight)) dFirst=\(P.format(verdict.dFirst)) dLast=\(P.format(verdict.dLast)) px=\(verdict.pixelFailures.count)", verdict)
                    if !(verdict.pass && verdict.engine) || P.printsEveryCase {
                        print(P.line(fields, verdict, a, b))
                    }
                    if !verdict.engine { engineMisses.append("\(fields): owner \(owner) swiftUIRows=\(a.rows.count) textKit2Owners=\(b.owners.sorted())") }
                }
            }
        }
        tally.print(probe: probe)
        print("CONTAINER_PROBE_TIME probe=\(probe) container=\(container.rawValue) scale=\(TK2Parity.nativeScale) os=\(TK2Parity.osVersion) mode=\(P.mode) elapsed=\(clock.now - start)")
        // The probe's own claim: its subject drew through TextKit 2 on the
        // TextKit 2 arm and not at all on the SwiftUI arm.
        #expect(engineMisses.isEmpty, "\(engineMisses.count) cases did not engage TextKit 2: \(engineMisses.prefix(4))")
    }

    /// The crops a container is compared in: a panel's icon column and
    /// content (on its own background), a quote's bar and content, an
    /// expand's or extension's whole box. With `textKit2Arm`, differing
    /// pixels are attributed to its rows (`TK2ContainerProbe.residual`).
    func crops(
        _ verdict: inout P.Verdict, _ container: P.Container, _ a: TK2Parity.Bitmap, _ b: TK2Parity.Bitmap, width: CGFloat,
        env: TK2Parity.Environment, swiftUIArm arm: P.Arm, textKit2Arm: P.Arm? = nil
    ) {
        let rtl = env.direction == .rightToLeft
        let s = P.spacing
        let all = P.Crop(name: "whole", columns: 0..<a.width)
        let rows = textKit2Arm?.rows
        switch container {
        case .panel:
            let icon = P.iconWidth("info.circle.fill", env: env)
            let split = s * 1.5 + icon + s * 0.75
            let background = P.sample(a, x: rtl ? width - s * 0.75 : s * 0.75, y: arm.guides.height / 2)
            let iconCrop = P.Crop(name: "icon", columns: P.columns(from: 0, to: split, width: width, scale: a.scale, rtl: rtl))
            let content = P.Crop(name: "content", columns: P.columns(from: split, to: width, width: width, scale: a.scale, rtl: rtl))
            P.pixels(&verdict, a, b, crops: [iconCrop, content], background: background, marker: (iconCrop, content), rows: rows, dark: env.dark)
        case .quote:
            let bar = P.Crop(name: "bar", columns: P.columns(from: 0, to: s, width: width, scale: a.scale, rtl: rtl))
            let content = P.Crop(name: "content", columns: P.columns(from: s, to: width, width: width, scale: a.scale, rtl: rtl))
            P.pixels(&verdict, a, b, crops: [bar, content], background: P.background(env), rows: rows, dark: env.dark)
        case .expand, .bodiedExtension:
            P.pixels(&verdict, a, b, crops: [all], background: P.background(env), rows: rows, dark: env.dark)
        }
    }

    @Test("panelShapes: panel bodies of each shape, both directions, against SwiftUI (record only; engine asserted)")
    func panelShapes() async throws {
        try await shapeMatrix(.panel, probe: "panelShapes")
    }

    @Test("quoteExpandExtensionShapes: the panel shape matrix on quote, open expand and extension bodies (record only; engine asserted)",
          arguments: [TK2ContainerProbe.Container.quote, .expand, .bodiedExtension])
    func quoteExpandExtensionShapes(container: P.Container) async throws {
        try await shapeMatrix(container, probe: "quoteExpandExtensionShapes")
    }

    // MARK: offGridColumns

    /// A family in a column, then a sibling paragraph (whose last baseline
    /// is the column's: the next sibling's position at 0.01 pt).
    static func columnBody(_ family: String, column: Int) -> [String] {
        let sibling = P.paragraph(P.t("Next sibling " + P.words(3 + column, from: 9)))
        let length = [22, 14, 8][column % 3]
        switch family {
        case "paragraph": return [P.paragraph(P.t(P.words(length, from: column * 5))), sibling]
        case "list": return [P.bulletList([P.item(P.paragraph(P.t(P.words(length, from: column)))), P.item(P.paragraph(P.t(P.words(4, from: 11))))]), sibling]
        case "panel": return [P.panel([P.paragraph(P.t(P.words(length, from: column * 3)))]), sibling]
        default: return [P.quote([P.paragraph(P.t(P.words(length, from: column * 2)))]), sibling]
        }
    }

    /// `ProportionalColumnsLayout`'s column widths, by the same
    /// arithmetic (`LayoutColumnsView.fractions`, `columnWidths`).
    static func columnWidths(_ columns: [PreparedColumn], totalWidth: CGFloat, spacing: CGFloat) -> [CGFloat] {
        let total = columns.reduce(0) { $0 + max($1.widthPercent, 0) }
        let fractions = total > 0
            ? columns.map { max($0.widthPercent, 0) / total }
            : Array(repeating: 1 / Double(max(columns.count, 1)), count: columns.count)
        let available = max(totalWidth - spacing * CGFloat(max(columns.count - 1, 0)), 0)
        return (0..<columns.count).map { index in
            let fraction = index < fractions.count ? fractions[index] : 1 / Double(columns.count)
            return available * CGFloat(fraction)
        }
    }

    /// Side-by-side columns (`horizontalSizeClass = .regular`, sizes below
    /// the accessibility range) at row widths whose columns fall off the
    /// pixel grid — three equal columns at the readable cap (640: 202.667),
    /// x.333 and x.667 widths, a width a third of a point off the whole
    /// point (3x) or half a point (2x) — and real 33.33 % / 66.66 %
    /// columns. AX3 and AX5 stack the columns (a control, on SwiftUI on
    /// both arms: the container size rule). From xxxLarge each column
    /// alone stays on SwiftUI too, so xxLarge is the largest size the
    /// column's leaf is measured at on TextKit 2.
    ///
    /// From step 4 the whole section goes through the production path
    /// (the production allow list, `BlockView` as a document row hosts
    /// it): side by side no family keeps the renderer
    /// (`horizontalColumnKeepsRenderer`, decided by this probe), so the
    /// engine asserted there is SwiftUI on both arms, and stacked the
    /// families the production list holds draw on TextKit 2 (lists from
    /// step 6). Each column is still measured alone at its exact width
    /// behind the stacked boundary with the probed families allowed (the
    /// layout's own proposal: height, first and last baseline at 0.01 pt,
    /// the last being the sibling paragraph's): the leaf at the column's
    /// width as the boundary would hand it if the family were allowed,
    /// recorded so a TextKit 2 leaf fix can be re-probed here.
    @Test("offGridColumns: paragraph, list, panel and quote in columns at off-grid widths: each column alone (record only; TextKit 2 asserted) and the section through the production path (SwiftUI side by side, the production families on TextKit 2 stacked)")
    func offGridColumns() async throws {
        let gated = !TextKit2Eligibility.containerTextMatchesText
        let clock = ContinuousClock()
        let start = clock.now
        let tally = P.Tally()
        var engineMisses: [String] = []
        let offGrid: CGFloat = TK2Parity.nativeScale == 2 ? 370.5 : 370 + 1.0 / 3
        // Before iOS 26 container text is gated: one width and size per
        // family, asserting that no row draws.
        let widths: [CGFloat] = gated ? [370] : P.fullMatrix ? [288, 343, 370, offGrid, 608, 639, 640] : P.familyMatrix ? [288, 370, offGrid, 640] : [370, 640]
        var environments: [TK2Parity.Environment] = []
        let sideBySide: [DynamicTypeSize] = gated ? [.large] : P.fullMatrix ? [.xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge] : P.familyMatrix ? [.xSmall, .large, .xxLarge, .xxxLarge] : [.large, .xxLarge, .xxxLarge]
        environments += sideBySide.map { TK2Parity.Environment(size: $0) }
        if !gated, P.fullMatrix || P.familyMatrix {
            environments += [DynamicTypeSize.xSmall, .large, .xxxLarge].map { TK2Parity.Environment(size: $0, legibility: .bold) }
            environments += [DynamicTypeSize.xSmall, .large, .xxxLarge].map { TK2Parity.Environment(size: $0, direction: .rightToLeft) }
            environments += [DynamicTypeSize.accessibility3, .accessibility5].map { TK2Parity.Environment(size: $0) }
        }
        for family in ["paragraph", "list", "panel", "quote"] {
            for (sectionName, percents) in [("equal3", [33.33, 33.33, 33.33]), ("third", [33.33, 66.66])] {
                let columnsJSON = percents.enumerated().map { (width: $0.element, body: Self.columnBody(family, column: $0.offset)) }
                let blocks = try await P.prepared([P.section(columnsJSON)])
                let block = try #require(blocks.first)
                guard case .layoutColumns(let columns) = block.kind else { throw TestFailure("not a layout section") }
                let owner = try #require(P.firstTextOwner(columns[0].blocks))
                print("CONTAINER_PROBE_SHAPE container=columns shape=\(family)/\(sectionName) owner=\(owner) prepared=\(P.shapeDescription(block))")
                for env in environments {
                    for rowWidth in widths {
                        let rtl = env.direction == .rightToLeft
                        // List text stays on SwiftUI before iOS 26, right to
                        // left and, below a container, at the accessibility
                        // sizes (`nestedListSizeKeepsRenderer`); all
                        // container text before iOS 26.
                        let listOnSwiftUI = !TextKit2Eligibility.listsMatchText || rtl
                            || !TextKit2Scope.nestedListSizeKeepsRenderer(env.size)
                        // Right to left and from xxxLarge no family: the
                        // container direction and size rules (lead
                        // dispositions F-Q6; lead call C55).
                        let big = !TextKit2Scope.containerSizeKeepsRenderer(env.size)
                        let familyOnTextKit2 = !gated && !rtl && !big && (family != "list" || !listOnSwiftUI)
                        let stacked = env.size.isAccessibilitySize
                        let columnWidths = stacked ? Array(repeating: rowWidth, count: columns.count) : Self.columnWidths(columns, totalWidth: rowWidth, spacing: P.spacing * 2)
                        let fields = "probe=offGridColumns container=columns shape=\(family)/\(sectionName) \(P.fields(env)) W=\(P.format(rowWidth))"
                        let key = "container=columns shape=\(family)/\(sectionName) dir=\(rtl ? "rtl" : "ltr") mode=\(stacked ? "stacked" : "sideBySide")"
                        // Each column at its own width, behind the stacked
                        // boundary (no side-by-side family rule).
                        for (index, column) in columns.enumerated() {
                            let width = columnWidths[index]
                            let (a, b) = try P.pair(width: width, pixels: false) { arm in
                                P.environment(LayoutColumnContentView(column: column, sideBySide: false, widthBound: .atLeast(width)), arm: arm, env: env, rowWidth: rowWidth, sizeClass: .regular)
                            }
                            var verdict = P.geometry(a.guides, b.guides)
                            let columnOwner = P.firstTextOwner(column.blocks) ?? "?"
                            verdict.engine = a.rows.isEmpty && (!familyOnTextKit2 || b.owners.contains(columnOwner)) && (!(gated || rtl || big) || b.rows.isEmpty)
                            if !familyOnTextKit2 {
                                verdict.notes.append(gated ? "familyOnSwiftUI(osGatedContainer)" : rtl ? "familyOnSwiftUI(containerDirection)"
                                    : big ? "familyOnSwiftUI(containerSize)"
                                    : env.size.isAccessibilitySize ? "familyOnSwiftUI(nestedListSize)" : "familyOnSwiftUI(listRules)")
                            }
                            let columnFields = fields + " column=\(index) colW=\(String(format: "%.4f", width))"
                            if !(verdict.pass && verdict.engine) {
                                verdict.leaf = try P.leafControl(column.blocks, width: width, env: env)
                            }
                            tally.add(key + " part=column", label: "\(P.fields(env)) W=\(P.format(rowWidth)) col\(index)=\(P.format(width)) dH=\(P.format(verdict.dHeight)) dFirst=\(P.format(verdict.dFirst)) dLast=\(P.format(verdict.dLast))", verdict)
                            if !(verdict.pass && verdict.engine) || P.printsEveryCase { print(P.line(columnFields, verdict, a, b)) }
                            if !verdict.engine { engineMisses.append("\(columnFields): owner \(columnOwner) textKit2Owners=\(b.owners.sorted())") }
                        }
                        // The whole section through the production path,
                        // as pixels column by column.
                        let (a, b) = try P.pair(width: rowWidth, pixels: true) { arm in
                            P.environment(BlockView(block: block), arm: TK2ContainerBody.rowRenderer(block, arm), env: env, rowWidth: rowWidth,
                                          sizeClass: .regular, allowed: nil)
                        }
                        var verdict = P.geometry(a.guides, b.guides)
                        // A custom layout has no text baselines of its own:
                        // the section is compared by height and pixels.
                        verdict.dFirst = 0
                        verdict.dLast = 0
                        // Production: side by side no family; stacked the
                        // families in the production allow list (the
                        // sibling paragraph always; lists from step 6).
                        // At the accessibility sizes (where the columns
                        // stack here) lists stay on SwiftUI
                        // (`nestedListSizeKeepsRenderer`).
                        let production: Set<String> = gated || rtl || big ? [] : TK2ContainerColumns.expectedOwners([block], sideBySide: !stacked)
                            .subtracting(env.size.isAccessibilitySize ? TK2ContainerBody.listOwners(in: [block]) : [])
                        verdict.engine = a.rows.isEmpty && b.owners == production
                        if production.isEmpty {
                            verdict.notes.append(rtl ? "productionOnSwiftUI(containerDirection)" : big ? "productionOnSwiftUI(containerSize)"
                                : stacked ? "productionOnSwiftUI(allowList)" : "productionOnSwiftUI(horizontalColumn)")
                        }
                        if let ba = a.bitmap, let bb = b.bitmap {
                            var crops: [P.Crop] = []
                            var x: CGFloat = 0
                            for (index, width) in columnWidths.enumerated() {
                                if stacked {
                                    crops.append(P.Crop(name: "stacked", columns: 0..<ba.width))
                                    break
                                }
                                crops.append(P.Crop(name: "column\(index)", columns: P.columns(from: x, to: x + width, width: rowWidth, scale: ba.scale, rtl: rtl)))
                                x += width + P.spacing * 2
                            }
                            let background = family == "panel" && !stacked ? P.sample(ba, x: rtl ? rowWidth - P.spacing * 0.75 : P.spacing * 0.75, y: P.spacing * 2.5) : (255, 255, 255)
                            P.pixels(&verdict, ba, bb, crops: crops, background: background, rows: b.rows)
                            if !(verdict.pass && verdict.engine) {
                                // The column control: each column's content
                                // alone at its width, as pixels.
                                var control = P.LeafControl()
                                for (index, column) in columns.enumerated() {
                                    let (ca, cb) = try P.pair(width: columnWidths[index], pixels: true) { arm in
                                        P.environment(LayoutColumnContentView(column: column, sideBySide: !stacked, widthBound: .atLeast(columnWidths[index])), arm: arm, env: env, rowWidth: rowWidth, sizeClass: .regular)
                                    }
                                    var cv = P.geometry(ca.guides, cb.guides)
                                    control.dHeight += cv.dHeight
                                    control.dFirst = max(control.dFirst, cv.dFirst)
                                    control.dLast = max(control.dLast, cv.lastResidual ? 0 : cv.dLast)
                                    if let x = ca.bitmap, let y = cb.bitmap {
                                        let bg = family == "panel" ? P.sample(x, x: rtl ? columnWidths[index] - P.spacing * 0.75 : P.spacing * 0.75, y: P.spacing * 2.5) : (255, 255, 255)
                                        P.pixels(&cv, x, y, crops: [P.Crop(name: "column", columns: 0..<x.width)], background: bg, rows: cb.rows)
                                    }
                                    control.differing += cv.differing
                                    if !cv.pixelFailures.isEmpty { control.pixelFailures += 1 }
                                    if let residual = cv.residual { control.residual.merge(residual) }
                                }
                                verdict.leaf = control
                                P.dump(key, fields, ba, bb)
                            }
                        }
                        tally.add(key + " part=section", label: "\(P.fields(env)) W=\(P.format(rowWidth)) dH=\(P.format(verdict.dHeight)) px=\(verdict.pixelFailures.count)", verdict)
                        if !(verdict.pass && verdict.engine) || P.printsEveryCase { print(P.line(fields + " part=section", verdict, a, b)) }
                        if !verdict.engine { engineMisses.append("\(fields) section (production): textKit2Owners=\(b.owners.sorted()) swiftUIRows=\(a.rows.count)") }
                    }
                }
            }
        }
        tally.print(probe: "offGridColumns")
        print("CONTAINER_PROBE_TIME probe=offGridColumns scale=\(TK2Parity.nativeScale) os=\(TK2Parity.osVersion) mode=\(P.mode) elapsed=\(clock.now - start)")
        #expect(engineMisses.isEmpty, "\(engineMisses.count) cases had the wrong engine (a column alone not on TextKit 2, or the section not as production draws it): \(engineMisses.prefix(4))")
    }

    // MARK: panelIconMeasurement

    /// The panel icon's layout width (`Image(systemName:)` with no frame,
    /// inheriting the environment's font: none, so body) for the seven
    /// palette symbols × the 12 Dynamic Type sizes × Bold Text, against
    /// `@ScaledMetric(relativeTo: .body)` of 28 (the bound step 2 pins),
    /// and the base value the measured widths require. The width is also
    /// read in place: in a real panel, a TextKit 2 paragraph starts at the
    /// padding, the icon and the stack spacing (left to right).
    @Test("panelIconMeasurement: the seven panel symbols at every size and weight against a scaled 28 pt bound (record only)")
    func panelIconMeasurement() async throws {
        let types: [(ADFPanelType, String?)] = [(.info, nil), (.note, nil), (.tip, nil), (.success, nil), (.warning, nil), (.error, nil), (.custom, "#FF8800")]
        let s = P.spacing
        var requiredBase: CGFloat = 0
        var worst = ""
        var inSituMismatches: [String] = []
        for weight in [LegibilityWeight?.none, .bold] {
            for size in DynamicTypeSize.allCases {
                let env = TK2Parity.Environment(size: size, legibility: weight)
                let traits = UITraitCollection(preferredContentSizeCategory: size.uiContentSizeCategory)
                let bound = UIFontMetrics(forTextStyle: .body).scaledValue(for: 28, compatibleWith: traits)
                // The scale factor at this size (`scaledValue` rounds to the
                // pixel, so a base of 1 would overstate the base needed).
                let unit = UIFontMetrics(forTextStyle: .body).scaledValue(for: 1_000, compatibleWith: traits) / 1_000
                var sizeMax: CGFloat = 0
                for (type, color) in types {
                    let palette = P.theme.panelPalette(type, colorHex: color)
                    let width = P.iconWidth(palette.iconSystemName, env: env)
                    let standalone = TK2Parity.attachedSize(
                        Image(systemName: palette.iconSystemName).foregroundStyle(palette.accent)
                            .environment(\.legibilityWeight, weight).dynamicTypeSize(size),
                        width: 200
                    )
                    // In place: the paragraph's leading edge in a real panel.
                    let json = P.panel([P.paragraph(P.t("Panel text"))], type: type.rawValue, color: color)
                    let block = try #require(try await P.prepared([json]).first)
                    let host = P.Host(width: 370)
                    host.show(P.environment(BlockView(block: block), arm: .textKit2, env: env, rowWidth: 370))
                    let row = host.rows.first
                    let inSitu = row.map { $0.convert($0.bounds, to: nil).minX - s * 3 }
                    host.close()
                    if !TextKit2Eligibility.containerTextMatchesText {
                        // Before iOS 26 the panel's text is gated: no row to
                        // read the icon's width from in place.
                        if row != nil { inSituMismatches.append("\(palette.iconSystemName) \(size): a TextKit 2 row in a panel before iOS 26") }
                    } else if !TextKit2Scope.containerSizeKeepsRenderer(size) {
                        // From xxxLarge the panel's body stays on SwiftUI
                        // (the container size rule): no row to read from;
                        // the standalone width is recorded.
                        if row != nil { inSituMismatches.append("\(palette.iconSystemName) \(size): a TextKit 2 row in a panel from xxxLarge") }
                    } else if let inSitu {
                        if abs(inSitu - width) > 1 / TK2Parity.nativeScale + P.tolerance {
                            inSituMismatches.append("\(palette.iconSystemName) \(size) bold=\(weight == .bold): standalone \(width) in place \(inSitu)")
                        }
                    } else {
                        inSituMismatches.append("\(palette.iconSystemName) \(size): no TextKit 2 row in the panel")
                    }
                    sizeMax = max(sizeMax, width, inSitu ?? 0)
                    let ratio = max(width, inSitu ?? 0) / unit
                    if ratio > requiredBase {
                        requiredBase = ratio
                        worst = "\(palette.iconSystemName) \(size) bold=\(weight == .bold ? 1 : 0)"
                    }
                    print("PANEL_ICON os=\(TK2Parity.osVersion) scale=\(TK2Parity.nativeScale) size=\(size) bold=\(weight == .bold ? 1 : 0) symbol=\(palette.iconSystemName) width=\(P.format(width)) height=\(P.format(standalone.height)) inSitu=\(inSitu.map(P.format) ?? "nil") bound28=\(P.format(bound)) unit=\(P.format(unit)) fits=\(max(width, inSitu ?? 0) <= bound)")
                }
                print("PANEL_ICON_SIZE os=\(TK2Parity.osVersion) scale=\(TK2Parity.nativeScale) size=\(size) bold=\(weight == .bold ? 1 : 0) max=\(P.format(sizeMax)) bound28=\(P.format(bound)) margin=\(P.format(bound - sizeMax)) baseNeeded=\(P.format(sizeMax / unit))")
            }
        }
        print("PANEL_ICON_SUMMARY os=\(TK2Parity.osVersion) scale=\(TK2Parity.nativeScale) requiredBase=\(P.format(requiredBase)) worst={\(worst)} base28Holds=\(requiredBase <= 28)")
        // The in-place reading must agree with the standalone width (within
        // the pixel the row view's frame is placed on).
        #expect(inSituMismatches.isEmpty, "\(inSituMismatches.prefix(6))")
    }

    // MARK: PR 1's leaf residual, pinned on its own

    /// PR 1's leaf residual (`TextKit2HeightParityTests.linkedEmojiCodeResidual`:
    /// linked text with an emoji pair, inline code and bold at AX3 in a
    /// 219 pt column, a pixel short on TextKit 2) in a quote body 235 pt
    /// wide (219 pt inside its 16 pt inset). Pinned as its own case so a
    /// fix shows up as an unexpected pass; no other container case carries
    /// a known-issue mask. Without the link, or without the emoji, the
    /// quote matches.
    ///
    /// The residual needs AX3, and from xxxLarge the container size rule
    /// keeps a quote's body on SwiftUI (lead call C55): the residual then
    /// cannot reach a quote, and the test asserts that instead (no row on
    /// either arm, equal heights, no mask). The pin applies again, as
    /// written, when the cut-off moves past AX3.
    @Test("PR 1 leaf residual in a quote body (linked text with an emoji pair and inline code, a pixel short at AX3, 219 pt): out of reach while the container size rule keeps an AX3 quote on SwiftUI, pinned where it does not")
    func linkedEmojiCodeResidualInQuote() async throws {
        func content(link linked: Bool, emoji: Bool) -> String {
            P.paragraph(
                P.t(P.words(6) + " "),
                P.t("linked words", linked ? P.link : ""),
                P.t(" " + P.words(4, from: 6) + (emoji ? " \u{1F600}\u{1F389} " : " ")),
                P.t("code", P.code),
                P.t(" " + P.words(5, from: 10), P.strong)
            )
        }
        let env = TK2Parity.Environment(size: .accessibility3)
        // Whether the container size rule passes the quote its renderer at
        // AX3: not while its cut-off is xxxLarge.
        let reaches = TextKit2Scope.containerSizeKeepsRenderer(env.size) && TextKit2Eligibility.containerTextMatchesText
        let width: CGFloat = 219 + P.spacing * 2
        var results: [String] = []
        for (name, linked, emoji) in [("residual", true, true), ("no-link", false, true), ("no-emoji", true, false)] {
            let block = try #require(try await P.prepared([P.quote([content(link: linked, emoji: emoji)])]).first)
            let owner = try #require(P.probedOwner(block))
            let (a, b) = try P.pair(width: width, pixels: false) { arm in
                P.environment(BlockView(block: block), arm: arm, env: env, rowWidth: width)
            }
            if reaches {
                #expect(a.rows.isEmpty && b.owners.contains(owner), "\(name): TextKit 2 did not draw the quote's paragraph")
            } else {
                #expect(a.rows.isEmpty && b.rows.isEmpty, "\(name): the quote's paragraph stays on SwiftUI (before iOS 26, or the container size rule)")
            }
            let dH = abs(a.guides.height - b.guides.height)
            results.append("\(name) swiftUI=\(a.guides.height) textKit2=\(b.guides.height)")
            if name == "residual", TextKit2Scope.containerSizeKeepsRenderer(env.size) {
                // Measured on iOS 26 (576 against 575.5 at 2x, 575.67 at
                // 3x). iOS 18.5 lays the paragraph out equal on both arms
                // (528 here), so there the case is asserted, not masked:
                // the mask stays where PR 1 measured it and never widens.
                // (PR 1's own pin, `TextKit2HeightParityTests
                // .linkedEmojiCodeResidual`, has no such condition and
                // reports "Known issue was not recorded" on iOS 18.5.)
                withKnownIssue("PR 1 leaf residual: linked text with an emoji pair and inline code measures a pixel short at AX3, 219 pt (here in a quote body)") {
                    #expect(dH <= P.tolerance, "swiftUI=\(a.guides.height) textKit2=\(b.guides.height)")
                } when: {
                    ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
                }
            } else {
                #expect(dH <= P.tolerance, "\(name): swiftUI=\(a.guides.height) textKit2=\(b.guides.height)")
            }
        }
        print("CONTAINER_PROBE_RESIDUAL scale=\(TK2Parity.nativeScale) os=\(TK2Parity.osVersion) quote W=\(width) AX3: \(results.joined(separator: "; "))")
    }
}
#endif
