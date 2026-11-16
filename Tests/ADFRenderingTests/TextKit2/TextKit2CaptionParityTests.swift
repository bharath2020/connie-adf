#if canImport(UIKit)
import SwiftUI
import UIKit
import Testing
import ADFModel
import ADFPreparation
@testable import ADFRendering

// Media captions on TextKit 2 (PR 4 plan §4.4, step 8), measured through
// the real caption (`MediaBlockView.caption`, the leaf `MediaBlockView`
// draws) and the real media view (`BlockView`), with the renderer set on
// the hosted view as a document row or a container boundary sets it.
//
// The caption's drop rules (plan §4.4), each fixed before it was run:
// 1. `captionFontIsPreparedRunFont`: `.font(.footnote)` changes no caption
//    metric (every prepared caption run carries its own font), and the
//    TextKit 2 row has the caption's height and baselines.
// 2. `secondaryForegroundPixels`: the TextKit 2 row draws the caption's
//    hierarchical `.secondary` foreground as `Text` does.
// 3. `captionFrameMatches`: the caption's and the media box's frames match
//    under each media layout; a layout that fails keeps its captions on
//    SwiftUI (`TextKit2Scope.captionLayoutKeepsRenderer`).
// (Rule 4, the media-row hang count, is the UI test K9.)
//
// Before iOS 26 every caption stays on SwiftUI (the container OS gate,
// `TextKit2Eligibility.containerTextMatchesText`, which the caption context
// takes): there the suites assert that no caption row exists and that the
// arms are the same SwiftUI drawing; they do not skip.

/// Caption documents, hosting and measurement the caption suites share.
/// Not a suite.
enum TK2Caption {
    static var theme: ADFTheme { TK2Parity.theme }
    nonisolated static let tolerance: CGFloat = 0.01
    nonisolated static let width: CGFloat = 370

    static func t(_ string: String, _ marks: String = "") -> String { TK2Parity.adfText(string, marks: marks) }
    static let strong = "{\"type\":\"strong\"}"
    static let em = "{\"type\":\"em\"}"
    static let code = "{\"type\":\"code\"}"
    static let strike = "{\"type\":\"strike\"}"
    static let underline = "{\"type\":\"underline\"}"
    static let small = "{\"type\":\"fontSize\",\"attrs\":{\"size\":\"small\"}}"
    static let sub = "{\"type\":\"subsup\",\"attrs\":{\"type\":\"sub\"}}"
    static let sup = "{\"type\":\"subsup\",\"attrs\":{\"type\":\"sup\"}}"
    static let link = "{\"type\":\"link\",\"attrs\":{\"href\":\"https://example.com/caption\"}}"
    static let red = "{\"type\":\"textColor\",\"attrs\":{\"color\":\"#ff5630\"}}"
    /// A light fill: the composer derives a black contrast foreground for
    /// its text (`ADFHexColor.contrastingForeground`).
    static let highlight = "{\"type\":\"backgroundColor\",\"attrs\":{\"color\":\"#fedec8\"}}"
    static let placeholder = "{\"type\":\"placeholder\",\"attrs\":{\"text\":\"Type a caption\"}}"
    static let mention = "{\"type\":\"mention\",\"attrs\":{\"id\":\"u1\",\"text\":\"@someone\"}}"

    /// The seven media layouts, as ADF writes them.
    static let layouts = ["center", "wrap-left", "wrap-right", "align-start", "align-end", "wide", "full-width"]

    /// A `mediaSingle` with a caption of `content` (inline ADF JSON; `nil`
    /// for no caption node), as the captions-parity fixture writes them:
    /// a 640 × 480 external image shown `pixelWidth` points wide, or
    /// `percent` of the column.
    static func mediaNode(_ content: String?, layout: String = "center", pixelWidth: Int? = 240, percent: Double? = nil) -> String {
        var attrs = "\"layout\":\"\(layout)\""
        if let pixelWidth { attrs += ",\"width\":\(pixelWidth),\"widthType\":\"pixel\"" }
        if let percent { attrs += ",\"width\":\(percent),\"widthType\":\"percentage\"" }
        let media = "{\"type\":\"media\",\"attrs\":{\"type\":\"external\",\"url\":\"placeholder://caption-tests\",\"width\":640,\"height\":480}}"
        let caption = content.map { ",{\"type\":\"caption\",\"content\":[\($0)]}" } ?? ""
        return "{\"type\":\"mediaSingle\",\"attrs\":{\(attrs)},\"content\":[\(media)\(caption)]}"
    }

    @MainActor
    static func prepared(_ nodes: [String], theme: ADFTheme = TK2Caption.theme) async throws -> [RenderBlock] {
        let json = "{\"version\":1,\"type\":\"doc\",\"content\":[\(nodes.joined(separator: ","))]}"
        return DocumentPreparer(theme: theme).prepare(try await ADFParser().parse(Data(json.utf8)))
    }

    /// One prepared media block and its media.
    struct Media {
        let name: String
        let block: RenderBlock
        let media: PreparedMedia
        var caption: [InlineSegment] { media.caption ?? [] }
        var owner: String { media.id }
    }

    static func media(_ block: RenderBlock, name: String) throws -> Media {
        guard case .media(let media) = block.kind else { throw TestFailure("\(name): \(block.id) is not a media block") }
        return Media(name: name, block: block, media: media)
    }

    @MainActor
    static func media(_ name: String, _ content: String?, layout: String = "center", pixelWidth: Int? = 240, percent: Double? = nil,
                      theme: ADFTheme = TK2Caption.theme) async throws -> Media {
        let nodes = [mediaNode(content, layout: layout, pixelWidth: pixelWidth, percent: percent)]
        return try media(try #require(try await prepared(nodes, theme: theme).first), name: name)
    }

    /// Drop rule 1's captions: one per run font a caption can carry.
    @MainActor
    static func fontCaptions() async throws -> [Media] {
        let words = "under the image, long enough to wrap onto a second line at the larger sizes"
        return [
            try await media("plain", t("A plain caption " + words)),
            try await media("bold", [t("A caption with "), t("bold words", strong), t(" " + words)].joined(separator: ",")),
            try await media("italic", [t("A caption with "), t("italic words", em), t(" " + words)].joined(separator: ",")),
            try await media("inline-code", [t("A caption with "), t("inline code", code), t(" " + words)].joined(separator: ",")),
            try await media("small", [t("A caption with "), t("small text", small), t(" " + words)].joined(separator: ",")),
            try await media("sub-superscript", [t("H"), t("2", sub), t("O and E=mc"), t("2", sup), t(" " + words)].joined(separator: ",")),
            try await media("hard-break", [t("A first caption line"), TK2Parity.hardBreak, t("and a second line " + words)].joined(separator: ",")),
            try await media("text-emoji", t("A caption with emoji \u{2705} \u{2764}\u{FE0F} \u{1F680} " + words)),
        ]
    }

    /// Drop rule 2's captions (plan §4.3): the inline content of each, so
    /// the same marks can be hosted as a root paragraph too.
    static let foregroundCaptions: [(name: String, content: String)] = [
        ("plain", t("A plain caption under the image, in the secondary colour")),
        ("underline", [t("A caption with "), t("underlined words", underline), t(" in it")].joined(separator: ",")),
        ("strikethrough", [t("A caption with "), t("struck words", strike), t(" in it")].joined(separator: ",")),
        ("text-emoji", t("A caption with emoji \u{2705} \u{2764}\u{FE0F} \u{1F680} and words")),
        ("inline-code", [t("A caption with "), t("inline code", code), t(" on its band")].joined(separator: ",")),
        ("contrast-colour", [t("A caption with "), t("highlighted words", highlight), t(" on a light fill")].joined(separator: ",")),
        ("bold-italic", [t("A caption with "), t("bold", strong), t(" and "), t("italic", em), t(" words")].joined(separator: ",")),
        ("placeholder", [t("A caption with a placeholder: "), placeholder].joined(separator: ",")),
        ("author-colour", [t("A caption with "), t("red words", red), t(" in it")].joined(separator: ",")),
        ("link", [t("A caption with "), t("a linked source", link), t(" in it")].joined(separator: ",")),
        ("link-author-colour", [t("A caption with "), t("a red link", link + "," + red), t(" in it")].joined(separator: ",")),
    ]

    /// Drop rule 3's captions: narrower than a 200 pt box, one line wider
    /// than it, and several lines at a phone's column.
    static let frameCaptions: [(name: String, content: String)] = [
        ("short", t("Short caption")),
        ("one-line", t("A one-line caption wider than the image box")),
        ("wrapping", t("A long caption that wraps across several lines at phone width, so its height and its line breaks must match under the image on both engines")),
    ]

    // MARK: The caption on each arm

    /// The SwiftUI caption exactly as `MediaBlockView` draws it on main
    /// (`footnote` true), or the same segments without the `.footnote`
    /// font.
    @MainActor
    @ViewBuilder
    static func swiftUICaption(_ segments: [InlineSegment], ownerID: String, footnote: Bool) -> some View {
        if footnote {
            SegmentedTextView(segments: segments, ownerID: ownerID)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            SegmentedTextView(segments: segments, ownerID: ownerID)
                .foregroundStyle(.secondary)
        }
    }

    /// The caption as `MediaBlockView` draws it: its text leaf, on the
    /// renderer the environment holds.
    @MainActor
    static func leaf(_ segments: [InlineSegment], ownerID: String, layout: ADFMediaLayout = .center) -> some View {
        MediaBlockView.caption(segments, ownerID: ownerID, layout: layout, theme: theme)
    }

    /// `block` with the renderer a document row gives it under the
    /// TextKit 2 switch (`TextKit2Scope.inheritsRenderer`) for the allow
    /// list `allowed`, which its container boundaries read too.
    @MainActor
    static func documentRow(_ block: RenderBlock, allowed: Set<TextKit2BlockKind>) -> some View {
        BlockView(block: block)
            .environment(\.adfTextRenderer, TextKit2Scope.inheritsRenderer(block.kind, allowed: allowed) ? .textKit2 : .swiftUI)
            .environment(\.adfContainerChildKinds, allowed)
    }

    /// `view` with a document row's environment for `arm`.
    @MainActor
    static func environment<V: View>(_ view: V, arm: ADFTextRenderer, env: TK2Parity.Environment, theme: ADFTheme = TK2Caption.theme) -> some View {
        view
            .environment(\.adfTextRenderer, arm)
            .environment(\.adfTheme, theme)
            .environment(\.layoutDirection, env.direction)
            .environment(\.legibilityWeight, env.legibility)
            .dynamicTypeSize(env.size)
    }

    /// Whether TextKit 2 draws a caption of `segments` on this OS: its
    /// verdict in the caption context (every caption falls back before
    /// iOS 26, `osGatedContainer`).
    static func drawsRow(_ segments: [InlineSegment]) -> Bool {
        if case .eligible = TextKit2Eligibility.verdict(segments, owner: .root, context: .caption) { return true }
        return false
    }

    /// Whether this OS draws captions on TextKit 2 at all.
    nonisolated static var captionsDrawOnThisOS: Bool { TextKit2Eligibility.containerTextMatchesText }

    nonisolated static func format(_ value: CGFloat) -> String { String(format: "%.3f", Double(value)) }

    // MARK: Hosting

    /// A view laid out at a width and its own height at the top-leading
    /// corner of a scene-less window at the device's native scale (light
    /// or dark), kept up for inspection and rendering; its enclosing stack
    /// reads the view's height and text baselines (`TK2ContainerProbe.Host`
    /// with a scheme and a settle, for media whose box follows a measured
    /// width).
    @MainActor
    final class Host {
        let window: UIWindow
        let controller: UIHostingController<AnyView>
        let box = TK2Parity.GuideBox()
        let width: CGFloat

        init(width: CGFloat, height: CGFloat = 2_000, dark: Bool = false) {
            self.width = width
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            window.backgroundColor = dark ? .black : .white
            controller = UIHostingController(rootView: AnyView(EmptyView()))
            controller.view.backgroundColor = .clear
            controller.safeAreaRegions = []
            window.rootViewController = controller
            window.isHidden = false
        }

        func show(_ view: some View) {
            let box = box
            box.first = .nan
            box.last = .nan
            box.height = .nan
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

        /// Lays out until the guides and the rows (with their frames) stop
        /// changing: a percentage-width box follows the width the media
        /// view measured, a run-loop turn later.
        func settle(turns: Int = 30) async throws {
            var last = ""
            var stable = 0
            for _ in 0..<turns {
                layout()
                let now = "\(box.height) \(box.first) \(box.last) " + rows.map { "\($0.ownerID ?? "?")@\($0.convert($0.bounds, to: nil))" }.joined(separator: ",")
                stable = now == last ? stable + 1 : 0
                if stable >= 2 { return }
                last = now
                try await Task.sleep(for: .milliseconds(10))
            }
            throw TestFailure("the hosted view did not settle")
        }

        var guides: TK2ContainerProbe.Guides { TK2ContainerProbe.Guides(first: box.first, last: box.last, height: box.height) }
        var rows: [TextKit2RowView] { TextKit2FallbackTests.rows(in: controller.view) }

        /// The top `height` points of the window at the native scale.
        func bitmap(height: CGFloat) throws -> TK2Parity.Bitmap {
            LiveRow.display(window)
            return try TK2Parity.bitmap(of: window, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    // MARK: Pixels

    /// PR 1's pixel rule (`TextKit2PixelParityTests.compare`): the same
    /// first and last ink rows, the same ink count on every pixel row, and
    /// at most 0.2 % of the ink band's pixels differing by more than 24 in
    /// a channel. Empty when the bitmaps pass.
    @MainActor
    static func pixelFailures(_ a: TK2Parity.Bitmap, _ b: TK2Parity.Bitmap, dark: Bool) -> (failures: [String], differing: Int, total: Int) {
        guard a.width == b.width, a.height == b.height else {
            return (["bitmaps differ in size \(a.width)x\(a.height) / \(b.width)x\(b.height)"], 0, 0)
        }
        let pa = TK2Parity.inkProfile(a, dark: dark)
        let pb = TK2Parity.inkProfile(b, dark: dark)
        var failures: [String] = []
        if pa.firstInkRow == nil { failures.append("the SwiftUI arm rendered no ink") }
        if pa.firstInkRow != pb.firstInkRow || pa.lastInkRow != pb.lastInkRow {
            failures.append("ink rows swiftUI=\(String(describing: pa.firstInkRow))…\(String(describing: pa.lastInkRow)) textKit2=\(String(describing: pb.firstInkRow))…\(String(describing: pb.lastInkRow))")
        }
        if pa.rowCounts != pb.rowCounts {
            failures.append("per-row ink counts differ\n\(TK2Parity.rowDifferences(pa, pb))")
        }
        let first = min(pa.firstInkRow ?? 0, pb.firstInkRow ?? 0)
        let last = max(pa.lastInkRow ?? 0, pb.lastInkRow ?? 0)
        let diff = TK2Parity.differingFraction(a, b, rows: first...last)
        if diff.fraction > TextKit2PixelParityTests.maxDifferingFraction {
            failures.append("\(diff.count)/\(diff.total) pixels differ (\(String(format: "%.4f", diff.fraction * 100)) %)")
        }
        return (failures, diff.count, diff.total)
    }

    /// The ink box of the pixel rows `rows` of a bitmap: first and last
    /// ink row (bitmap rows) and first and last ink column, or `nil`.
    @MainActor
    static func inkBox(_ bitmap: TK2Parity.Bitmap, rows: Range<Int>, dark: Bool) -> (rows: ClosedRange<Int>, columns: ClosedRange<Int>)? {
        let ink = TextKit2ListParityTests.ink(bitmap, columns: 0..<bitmap.width, background: TextKit2ListParityTests.background(dark: dark))
        var firstRow: Int?, lastRow: Int?, firstColumn = Int.max, lastColumn = Int.min
        for y in rows.clamped(to: 0..<bitmap.height) where ink.counts[y] > 0 {
            firstRow = firstRow ?? y
            lastRow = y
            firstColumn = min(firstColumn, ink.starts[y])
            lastColumn = max(lastColumn, ink.ends[y])
        }
        guard let firstRow, let lastRow else { return nil }
        return (firstRow...lastRow, firstColumn...lastColumn)
    }

    // MARK: Frames

    /// One media block on both arms (drop rule 3): the whole block's height
    /// and last baseline within 0.01 pt (PR 1 residual 1 recorded apart);
    /// the TextKit 2 row only where the caption is drawn by TextKit 2 on
    /// this OS and under this layout, owned by the media; the caption's
    /// size, alone at the column's width, within 0.01 pt between the arms
    /// and equal to the placed row's; and, rendered, the ink box of the
    /// media box and of the caption at the same rows, their columns
    /// within one device pixel. Returns the failures, the residual-1 flag
    /// and whether a TextKit 2 caption row was compared.
    @MainActor
    static func compareFrames(_ media: Media, env: TK2Parity.Environment, width: CGFloat) async throws -> (failures: [String], residual: Bool, compared: Bool) {
        let a = Host(width: width)
        let b = Host(width: width)
        defer {
            a.close()
            b.close()
        }
        a.show(environment(BlockView(block: media.block), arm: .swiftUI, env: env))
        b.show(environment(BlockView(block: media.block), arm: .textKit2, env: env))
        try await a.settle()
        try await b.settle()
        var failures: [String] = []
        let drawn = drawsRow(media.caption) && TextKit2Scope.captionLayoutKeepsRenderer(media.media.layout)
        if !a.rows.isEmpty { failures.append("the SwiftUI arm has \(a.rows.count) TextKit 2 rows") }
        let rows = b.rows
        if rows.count != (drawn ? 1 : 0) || (drawn && rows.first?.ownerID != media.owner) {
            failures.append("TextKit 2 rows \(rows.map { $0.ownerID ?? "?" }), expected \(drawn ? media.owner : "none")")
        }
        let ga = a.guides, gb = b.guides
        if abs(ga.height - gb.height) > tolerance { failures.append("block height swiftUI=\(ga.height) textKit2=\(gb.height)") }
        var residual = false
        let onePixel = 1 / TK2Parity.nativeScale
        if abs(ga.last - gb.last) > tolerance {
            if abs(ga.last - gb.last - onePixel) <= tolerance { residual = true } else {
                failures.append("block last baseline swiftUI=\(ga.last) textKit2=\(gb.last)")
            }
        }
        guard drawn, let row = rows.first, row.ownerID == media.owner else { return (failures, residual, false) }
        let placed = row.convert(row.bounds, to: nil)
        let layout = media.media.layout
        let sa = TK2Parity.attachedSize(environment(leaf(media.caption, ownerID: media.owner, layout: layout), arm: .swiftUI, env: env), width: width)
        let sb = TK2Parity.attachedSize(environment(leaf(media.caption, ownerID: media.owner, layout: layout), arm: .textKit2, env: env), width: width)
        if abs(sa.width - sb.width) > tolerance || abs(sa.height - sb.height) > tolerance {
            failures.append("caption size swiftUI=\(sa) textKit2=\(sb)")
        }
        if abs(placed.width - sb.width) > tolerance || abs(placed.height - sb.height) > tolerance {
            failures.append("placed row \(placed.size), alone \(sb)")
        }
        let scale = TK2Parity.nativeScale
        let height = (max(ga.height, gb.height) + 8).rounded(.up)
        let ba = try a.bitmap(height: height), bb = try b.bitmap(height: height)
        // The box ends above the caption: half the stack's spacing above
        // the caption row separates them.
        let split = Int(((placed.minY - theme.spacing * 0.375) * scale).rounded())
        for (name, band) in [("box", 0..<split), ("caption", split..<ba.height)] {
            let ia = inkBox(ba, rows: band, dark: env.dark), ib = inkBox(bb, rows: band, dark: env.dark)
            guard let ia, let ib else {
                failures.append("\(name): ink swiftUI=\(ia.map { "\($0)" } ?? "none") textKit2=\(ib.map { "\($0)" } ?? "none")")
                continue
            }
            if ia.rows != ib.rows { failures.append("\(name): ink rows swiftUI=\(ia.rows) textKit2=\(ib.rows)") }
            if abs(ia.columns.lowerBound - ib.columns.lowerBound) > 1 || abs(ia.columns.upperBound - ib.columns.upperBound) > 1 {
                failures.append("\(name): ink columns swiftUI=\(ia.columns) textKit2=\(ib.columns)")
            }
        }
        return (failures, residual, true)
    }
}

@Suite("TextKit 2 caption parity", .serialized)
@MainActor
struct TextKit2CaptionParityTests {
    typealias C = TK2Caption

    /// Drop rule 1 (plan §4.4): for plain, bold, italic, inline-code,
    /// small, sub/superscript, hard-break and text-emoji captions, at every
    /// type size xSmall…AX5 with Bold Text off and on, at a one-line and a
    /// wrapping width: the SwiftUI caption with `.font(.footnote)` has the
    /// height and first and last baselines of the same segments without
    /// it (within 0.01 pt), and of the TextKit 2 row. A SwiftUI last
    /// baseline exactly one pixel below the row's is PR 1's residual 1
    /// (`TextKit2ListParityTests.rowGeometry`): recorded as a known issue
    /// once the two arms' text is checked to sit on the same pixel rows.
    @Test("drop rule 1: the caption font is the prepared run font (.footnote changes no caption metric; the TextKit 2 row matches)")
    func captionFontIsPreparedRunFont() async throws {
        let captions = try await C.fontCaptions()
        // Every run carries a font spec: only the OS gate keeps them off.
        for caption in captions {
            #expect(TextKit2Eligibility.describableText(caption.caption) != nil, "\(caption.name): not describable")
        }
        let onePixel = 1 / TK2Parity.nativeScale
        var checked = 0
        var residuals = 0
        var worstFootnote: (delta: CGFloat, label: String) = (0, "")
        var worstRow: (delta: CGFloat, label: String) = (0, "")
        for width in [C.width, 220] {
            let host = TK2ContainerProbe.Host(width: width)
            defer { host.close() }
            for caption in captions {
                let owner = caption.owner
                let drawn = C.drawsRow(caption.caption)
                for size in DynamicTypeSize.allCases {
                    for bold in [false, true] {
                        let env = TK2Parity.Environment(size: size, legibility: bold ? .bold : nil)
                        let label = "\(caption.name) \(env) W=\(Int(width))"
                        host.show(C.environment(C.swiftUICaption(caption.caption, ownerID: owner, footnote: true), arm: .swiftUI, env: env))
                        let footnote = host.guides
                        host.show(C.environment(C.swiftUICaption(caption.caption, ownerID: owner, footnote: false), arm: .swiftUI, env: env))
                        let plain = host.guides
                        host.show(C.environment(C.leaf(caption.caption, ownerID: owner), arm: .textKit2, env: env))
                        let row = host.guides
                        let rows = host.rows
                        #expect(rows.count == (drawn ? 1 : 0) && (!drawn || rows.first?.ownerID == owner), "\(label): TextKit 2 rows \(rows.map { $0.ownerID ?? "?" })")
                        checked += 1

                        // .footnote changes nothing.
                        let dFootnote = max(abs(footnote.height - plain.height), abs(footnote.first - plain.first), abs(footnote.last - plain.last))
                        if dFootnote > worstFootnote.delta { worstFootnote = (dFootnote, label) }
                        #expect(abs(footnote.height - plain.height) <= C.tolerance, "\(label): height footnote=\(footnote.height) plain=\(plain.height)")
                        #expect(abs(footnote.first - plain.first) <= C.tolerance, "\(label): first baseline footnote=\(footnote.first) plain=\(plain.first)")
                        #expect(abs(footnote.last - plain.last) <= C.tolerance, "\(label): last baseline footnote=\(footnote.last) plain=\(plain.last)")

                        // The TextKit 2 row matches the SwiftUI caption.
                        let dRow = max(abs(footnote.height - row.height), abs(footnote.first - row.first), abs(footnote.last - row.last))
                        if dRow > worstRow.delta { worstRow = (dRow, label) }
                        #expect(abs(footnote.height - row.height) <= C.tolerance, "\(label): height swiftUI=\(footnote.height) textKit2=\(row.height)")
                        #expect(abs(footnote.first - row.first) <= C.tolerance, "\(label): first baseline swiftUI=\(footnote.first) textKit2=\(row.first)")
                        if drawn, abs(footnote.last - row.last - onePixel) <= C.tolerance {
                            // Residual 1 is the guide, not the drawing: the
                            // two arms' text has the same ink rows.
                            host.show(C.environment(C.swiftUICaption(caption.caption, ownerID: owner, footnote: true), arm: .swiftUI, env: env))
                            let inkHeight = (footnote.height + 8).rounded(.up)
                            let swiftUIInk = TK2Parity.inkProfile(try host.bitmap(height: inkHeight), dark: false)
                            host.show(C.environment(C.leaf(caption.caption, ownerID: owner), arm: .textKit2, env: env))
                            let rowInk = TK2Parity.inkProfile(try host.bitmap(height: inkHeight), dark: false)
                            #expect(swiftUIInk.firstInkRow == rowInk.firstInkRow && swiftUIInk.lastInkRow == rowInk.lastInkRow,
                                    "\(label): ink rows swiftUI=\(String(describing: swiftUIInk.firstInkRow))…\(String(describing: swiftUIInk.lastInkRow)) textKit2=\(String(describing: rowInk.firstInkRow))…\(String(describing: rowInk.lastInkRow))")
                            residuals += 1
                            withKnownIssue("PR 1 residual 1: SwiftUI's last-baseline guide is 1 px below its drawn baseline") {
                                #expect(abs(footnote.last - row.last) <= C.tolerance, "\(label): last baseline swiftUI=\(footnote.last) textKit2=\(row.last)")
                            }
                        } else {
                            #expect(abs(footnote.last - row.last) <= C.tolerance, "\(label): last baseline swiftUI=\(footnote.last) textKit2=\(row.last)")
                        }
                    }
                }
            }
        }
        print("CAPTION_FONT os=\(UIDevice.current.systemVersion) scale=\(TK2Parity.nativeScale) cases=\(checked) worstFootnoteDelta=\(C.format(worstFootnote.delta)) [\(worstFootnote.label)] worstRowDelta=\(C.format(worstRow.delta)) [\(worstRow.label)] lastBaselineResidual1=\(residuals)")
    }

    /// Drop rule 2 (plan §4.3, §4.4): the SwiftUI caption draws in the
    /// hierarchical `.secondary` style (`MediaBlockView`'s
    /// `.foregroundStyle(.secondary)`, not `Color.secondary`); the TextKit 2
    /// row in the inherited foreground the caption leaf sets. Every mark
    /// that colours, decorates or fills text, light and dark, Large and
    /// AX3, at the device's scale, under PR 1's pixel rule with no known
    /// issue. A miss the same marks also show as a root paragraph (no
    /// inherited colour) is PR 1's residual, not this rule's.
    @Test("drop rule 2: the caption's secondary foreground draws as Text draws it", arguments: [DynamicTypeSize.large, .accessibility3], [false, true])
    func secondaryForegroundPixels(size: DynamicTypeSize, dark: Bool) async throws {
        let env = TK2Parity.Environment(size: size, dark: dark)
        var failed = 0
        for caption in C.foregroundCaptions {
            let media = try await C.media(caption.name, caption.content)
            let label = "\(caption.name) \(env) @\(TK2Parity.nativeScale)x"
            let drawn = C.drawsRow(media.caption)
            let a = C.Host(width: C.width, dark: dark)
            let b = C.Host(width: C.width, dark: dark)
            defer {
                a.close()
                b.close()
            }
            a.show(C.environment(C.leaf(media.caption, ownerID: media.owner), arm: .swiftUI, env: env))
            b.show(C.environment(C.leaf(media.caption, ownerID: media.owner), arm: .textKit2, env: env))
            #expect(a.rows.isEmpty, "\(label): a row on the SwiftUI arm")
            let rows = b.rows
            #expect(rows.count == (drawn ? 1 : 0), "\(label): \(rows.count) TextKit 2 rows")
            if let row = rows.first {
                #expect(row.ownerID == media.owner && row.containerContext == .caption, "\(label): owner \(row.ownerID ?? "?") context \(row.containerContext)")
                #expect(row.inputs?.inheritedForeground == .secondary, "\(label): the row's inherited foreground")
            }
            let height = (max(a.guides.height, b.guides.height) + 16).rounded(.up)
            let verdict = C.pixelFailures(try a.bitmap(height: height), try b.bitmap(height: height), dark: dark)
            print("CAPTION_SECONDARY case=\(caption.name) size=\(size) dark=\(dark) scale=\(TK2Parity.nativeScale) os=\(UIDevice.current.systemVersion) row=\(drawn) differing=\(verdict.differing)/\(verdict.total) result=\(verdict.failures.isEmpty ? "pass" : "fail")")
            if caption.name == "plain", drawn {
                // Control: the same row without the caption's foreground
                // (the label colour) is seen as different.
                let c = C.Host(width: C.width, dark: dark)
                defer { c.close() }
                c.show(C.environment(
                    TextEngineLeaf(segments: media.caption, style: MediaBlockView.captionStyle(theme: C.theme), ownerID: media.owner) { EmptyView() }
                        .environment(\.adfTextContainerContext, .caption),
                    arm: .textKit2, env: env
                ))
                #expect(c.rows.first?.inputs?.inheritedForeground == nil)
                let control = C.pixelFailures(try a.bitmap(height: height), try c.bitmap(height: height), dark: dark)
                #expect(!control.failures.isEmpty, "\(label): the comparison does not see the foreground")
                print("CAPTION_SECONDARY_CONTROL size=\(size) dark=\(dark) differing=\(control.differing)/\(control.total) seen=\(!control.failures.isEmpty)")
            }
            guard !verdict.failures.isEmpty else { continue }
            // The exception: the same marks as a root paragraph.
            let root = try await TK2Parity.fixture(caption.name + "-root", content: caption.content)
            let rootHeight = max(TK2Parity.height(root, arm: .swiftUI, env: env, width: C.width) + 40, 200)
            let rootVerdict = C.pixelFailures(
                try TK2Parity.render(root, arm: .swiftUI, env: env, width: C.width, height: rootHeight),
                try TK2Parity.render(root, arm: .textKit2, env: env, width: C.width, height: rootHeight), dark: dark
            )
            if rootVerdict.failures.isEmpty {
                failed += 1
                Issue.record("\(label): drop rule 2 fires: \(verdict.failures.joined(separator: "; "))")
            } else {
                print("CAPTION_SECONDARY_ROOT_RESIDUAL case=\(caption.name) size=\(size) dark=\(dark) root=\(rootVerdict.failures.joined(separator: "; "))")
                withKnownIssue("PR 1's residual: the same marks miss as a root paragraph") {
                    Issue.record("\(label): \(verdict.failures.joined(separator: "; "))")
                }
            }
        }
        print("CAPTION_SECONDARY_SUMMARY size=\(size) dark=\(dark) scale=\(TK2Parity.nativeScale) cases=\(C.foregroundCaptions.count) ruleFailures=\(failed)")
    }

    /// Drop rule 3 (plan §4.4): under each of the seven media layouts, a
    /// caption narrower than the box, one line wider than it and one that
    /// wraps, under a 200 pt and a 66.66 % box, Large and AX3, left to
    /// right and right to left (the device gives 3x or 2x): the media
    /// block's height, the caption's size and the box's and caption's
    /// placement match (`TK2Caption.compareFrames`). A layout whose cases
    /// fail keeps its captions on SwiftUI
    /// (`TextKit2Scope.captionLayoutKeepsRenderer`, reason
    /// `captionLayout`), so its TextKit 2 arm has no caption row here.
    @Test("drop rule 3: the caption and the media box sit where SwiftUI puts them under every layout")
    func captionFrameMatches() async throws {
        var summary: [String: (cases: Int, failed: Int, compared: Int, residuals: Int)] = [:]
        for layout in C.layouts {
            for caption in C.frameCaptions {
                for box in [(pixel: Int?.some(200), percent: Double?.none), (pixel: nil, percent: 66.66)] {
                    let media = try await C.media(caption.name, caption.content, layout: layout, pixelWidth: box.pixel, percent: box.percent)
                    for size in [DynamicTypeSize.large, .accessibility3] {
                        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
                            let env = TK2Parity.Environment(size: size, direction: direction)
                            let boxName = box.pixel.map { "\($0)pt" } ?? "\(box.percent ?? 0)%"
                            let label = "\(layout) \(caption.name) box=\(boxName) \(env) @\(TK2Parity.nativeScale)x"
                            let result = try await C.compareFrames(media, env: env, width: C.width)
                            var entry = summary[layout] ?? (0, 0, 0, 0)
                            entry.cases += 1
                            if !result.failures.isEmpty { entry.failed += 1 }
                            if result.compared { entry.compared += 1 }
                            if result.residual { entry.residuals += 1 }
                            summary[layout] = entry
                            print("CAPTION_FRAME layout=\(layout) caption=\(caption.name) box=\(boxName) size=\(size) dir=\(direction == .rightToLeft ? "rtl" : "ltr") scale=\(TK2Parity.nativeScale) os=\(UIDevice.current.systemVersion) row=\(result.compared) result=\(result.failures.isEmpty ? "pass" : "fail")\(result.residual ? " residual1" : "") \(result.failures.joined(separator: "; "))")
                            #expect(result.failures.isEmpty, "\(label): \(result.failures.joined(separator: "; "))")
                        }
                    }
                }
            }
        }
        for layout in C.layouts {
            let entry = summary[layout] ?? (0, 0, 0, 0)
            let keeps = TextKit2Scope.captionLayoutKeepsRenderer(ADFMediaLayout(rawValue: layout) ?? .center)
            print("CAPTION_FRAME_SUMMARY layout=\(layout) keeps=\(keeps) cases=\(entry.cases) failed=\(entry.failed) rowsCompared=\(entry.compared) residual1=\(entry.residuals) scale=\(TK2Parity.nativeScale) os=\(UIDevice.current.systemVersion)")
            // Where captions draw on TextKit 2, every kept layout was compared.
            if keeps, C.captionsDrawOnThisOS { #expect(entry.compared == entry.cases, "\(layout): \(entry.compared)/\(entry.cases) caption rows compared") }
        }
    }

    /// The layout sweep (plan §5 step 8): media-gallery's 30 plain
    /// captions, under all seven layouts with pixel and percentage widths,
    /// at two phone columns, through the same frame comparison.
    @Test("media-gallery: every caption, under all seven layouts, lays out and sits as SwiftUI's does")
    func mediaGalleryLayoutSweep() async throws {
        let blocks = try await TextKit2ListCoverageTests.blocks("media-gallery")
        let captioned = try blocks.compactMap { block -> TK2Caption.Media? in
            guard case .media(let media) = block.kind, let caption = media.caption, !caption.isEmpty else { return nil }
            return try C.media(block, name: block.id)
        }
        #expect(captioned.count == 30)
        #expect(Set(captioned.map(\.media.layout.rawValue)) == Set(C.layouts))
        #expect(captioned.allSatisfy { TextKit2Eligibility.describableText($0.caption) != nil }, "plain captions")
        var compared = 0
        var residuals = 0
        for width in [C.width, 343] {
            for media in captioned {
                let env = TK2Parity.Environment(size: .large)
                let result = try await C.compareFrames(media, env: env, width: width)
                if result.compared { compared += 1 }
                if result.residual { residuals += 1 }
                #expect(result.failures.isEmpty, "\(media.name) \(media.media.layout) W=\(Int(width)): \(result.failures.joined(separator: "; "))")
            }
        }
        print("CAPTION_GALLERY scale=\(TK2Parity.nativeScale) os=\(UIDevice.current.systemVersion) cases=\(captioned.count * 2) rowsCompared=\(compared) residual1=\(residuals)")
        if C.captionsDrawOnThisOS {
            let kept = captioned.filter { TextKit2Scope.captionLayoutKeepsRenderer($0.media.layout) }.count
            #expect(compared == kept * 2)
        } else {
            #expect(compared == 0)
        }
    }

    @Test("the caption's style is the list leader's: body text, no heading, no alignment")
    func captionStyleEqualsLeaderStyle() {
        for theme in [ADFTheme.default, ADFTheme(body: .custom("Georgia", size: 17))] {
            #expect(MediaBlockView.captionStyle(theme: theme) == ListRowView.leaderStyle(theme: theme))
        }
        let style = MediaBlockView.captionStyle(theme: .default)
        #expect(style.alignment == nil && !style.isHeading && style.indentation == 0)
    }

    @Test("a caption's row is owned by its media (the search owner), in the caption context, drawn in the inherited secondary foreground")
    func captionOwnerIsMediaID() async throws {
        let media = try await C.media("owner", C.t("A caption owned by its media"))
        #expect(media.owner != media.block.id, "the media node, not the mediaSingle")
        // Search indexes the caption under the same owner.
        let units = SearchIndexer(theme: C.theme).units(for: [media.block])
        #expect(units.map(\.ownerID) == [media.owner])

        let host = C.Host(width: C.width)
        defer { host.close() }
        host.show(C.environment(BlockView(block: media.block), arm: .textKit2, env: TK2Parity.Environment()))
        try await host.settle()
        let rows = host.rows
        guard C.drawsRow(media.caption) else {
            #expect(rows.isEmpty, "before iOS 26 the caption stays on SwiftUI")
            return
        }
        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.ownerID == media.owner)
        #expect(row.accessibilityIdentifier == "tk2-row:\(media.owner)")
        #expect(row.ownerKind == .root)
        #expect(row.containerContext == .caption)
        #expect(row.inputs?.inheritedForeground == .secondary)
    }

    @Test("no caption, an empty caption and a caption of hard breaks only create no row; only a non-empty caption is a leaf")
    func emptyCaptionCreatesNoRow() async throws {
        let cases = [
            try await C.media("no-caption", nil),
            try await C.media("empty-caption", ""),
            try await C.media("break-only", [TK2Parity.hardBreak, TK2Parity.hardBreak].joined(separator: ",")),
        ]
        for media in cases {
            let host = C.Host(width: C.width)
            defer { host.close() }
            host.show(C.environment(BlockView(block: media.block), arm: .textKit2, env: TK2Parity.Environment()))
            try await host.settle()
            #expect(host.rows.isEmpty, "\(media.name): \(host.rows.count) rows")
            let all = ADFTextRenderer.textKit2Coverage(of: [media.block], allowed: [.media])
            // No caption, or an empty one, is no leaf; text of breaks only
            // is a leaf that falls back (`.empty`), once captions are on.
            let leaves = media.name == "break-only" && TextKit2Scope.captionsUseTextKit2 ? 1 : 0
            #expect(all.eligibleCaptionLeaves == 0 && all.fallbackCaptionLeaves == leaves, "\(media.name): \(all)")
        }
        #expect(TextKit2Scope.blockKeepsRenderer(cases[0].block.kind) == false, "no caption: the media row keeps nothing")
        #expect(TextKit2Scope.blockKeepsRenderer(cases[1].block.kind) == false, "an empty caption: the media row keeps nothing")
    }

    @Test("a caption with an inline atom stays on SwiftUI on both arms")
    func atomCaptionStaysSwiftUI() async throws {
        let media = try await C.media("atom", [C.t("A caption by "), C.mention, C.t(" with words")].joined(separator: ","))
        guard case .fallback(.atom) = TextKit2Eligibility.verdict(media.caption, owner: .root, context: .caption) else {
            Issue.record("the atom caption must fall back as an atom")
            return
        }
        let all = ADFTextRenderer.textKit2Coverage(of: [media.block], allowed: [.media])
        #expect(all.eligibleCaptionLeaves == 0 && all.fallbackCaptionLeaves == (TextKit2Scope.captionsUseTextKit2 ? 1 : 0))
        try await Self.expectSameSwiftUIDrawing(media, theme: C.theme)
    }

    @Test("a raw-font theme keeps captions on SwiftUI on both arms")
    func rawFontThemeCaptionStaysSwiftUI() async throws {
        let raw = ADFTheme(body: .custom("Georgia", size: 17))
        let media = try await C.media("raw-font", C.t("A caption in a theme whose body font is a raw Font"), theme: raw)
        guard case .fallback(.undescribable) = TextKit2Eligibility.verdict(media.caption, owner: .root, context: .caption) else {
            Issue.record("the raw-font caption must fall back as undescribable")
            return
        }
        try await Self.expectSameSwiftUIDrawing(media, theme: raw)
    }

    /// No TextKit 2 row on either arm, and the two arms' pixels identical.
    static func expectSameSwiftUIDrawing(_ media: TK2Caption.Media, theme: ADFTheme) async throws {
        let a = C.Host(width: C.width)
        let b = C.Host(width: C.width)
        defer {
            a.close()
            b.close()
        }
        a.show(C.environment(BlockView(block: media.block), arm: .swiftUI, env: TK2Parity.Environment(), theme: theme))
        b.show(C.environment(BlockView(block: media.block), arm: .textKit2, env: TK2Parity.Environment(), theme: theme))
        try await a.settle()
        try await b.settle()
        #expect(a.rows.isEmpty && b.rows.isEmpty, "\(media.name): rows \(a.rows.count)/\(b.rows.count)")
        let height = (max(a.guides.height, b.guides.height) + 8).rounded(.up)
        let pa = try a.bitmap(height: height), pb = try b.bitmap(height: height)
        #expect(pa.rgba == pb.rgba, "\(media.name): the arms draw differently")
    }

    @Test("a caption in a container follows the boundary: TextKit 2 only where the boundary allows media, in the caption context")
    func captionInContainerFollowsTheBoundary() async throws {
        let blocks = try await C.prepared([
            "{\"type\":\"panel\",\"attrs\":{\"panelType\":\"info\"},\"content\":[\(C.mediaNode(C.t("A caption inside a panel")))]}",
        ])
        let panel = try #require(blocks.first)
        guard case .panel(_, let children) = panel.kind, let child = children.first else {
            Issue.record("not a panel")
            return
        }
        let media = try C.media(child, name: "in-panel")
        // The panel's boundary passes the renderer to its media only when
        // the list holds `.media` and captions are on.
        let cases: [(allowed: Set<TextKit2BlockKind>, expectsRow: Bool)] = [
            ([.richText, .panel], false),
            ([.richText, .panel, .media], TextKit2Scope.captionsUseTextKit2),
        ]
        for (allowed, expectsRow) in cases {
            let host = C.Host(width: C.width)
            defer { host.close() }
            host.show(C.environment(C.documentRow(panel, allowed: allowed), arm: .textKit2, env: TK2Parity.Environment()))
            try await host.settle()
            let rows = host.rows
            let drawn = expectsRow && C.drawsRow(media.caption)
            #expect(rows.count == (drawn ? 1 : 0), "allowed \(allowed): \(rows.map { $0.ownerID ?? "?" })")
            if let row = rows.first {
                #expect(row.ownerID == media.owner)
                #expect(row.containerContext == .caption, "the caption's context wins over the container's")
                #expect(row.inputs?.inheritedForeground == .secondary)
            }
        }
    }
}

extension TextKit2ContainerScopeTests {
    /// Plan §4.3: the inherited foreground has one setter, the caption
    /// leaf. Hosted through the real views under TextKit 2: a root
    /// paragraph, a list leader, a panel's paragraph and a code block draw
    /// with no inherited foreground; a caption with `.secondary`. Each
    /// position is checked where this OS draws it on TextKit 2.
    @Test("the inherited foreground has one setter: a caption row draws in .secondary; root, list, panel and code rows inherit nothing")
    @MainActor
    func inheritedForegroundHasOneSetter() async throws {
        let blocks = try await TK2Caption.prepared([
            Self.paragraph("A root paragraph."),
            "{\"type\":\"bulletList\",\"content\":[\(Self.item(Self.paragraph("A list leader.")))]}",
            "{\"type\":\"panel\",\"attrs\":{\"panelType\":\"info\"},\"content\":[\(Self.paragraph("A panel paragraph."))]}",
            "{\"type\":\"codeBlock\",\"content\":[{\"type\":\"text\",\"text\":\"let x = 1\"}]}",
            TK2Caption.mediaNode(TK2Caption.t("A caption.")),
        ])
        let allowed: Set<TextKit2BlockKind> = [.richText, .panel, .media]
        let host = TK2Caption.Host(width: TK2Caption.width)
        defer { host.close() }
        host.show(TK2Caption.environment(
            VStack(alignment: .leading, spacing: 0) { ForEach(blocks) { TK2Caption.documentRow($0, allowed: allowed) } },
            arm: .textKit2, env: TK2Parity.Environment()
        ))
        try await host.settle()
        let rows = Dictionary(host.rows.map { ($0.ownerID ?? "?", $0) }, uniquingKeysWith: { first, _ in first })

        // Each owner, where this OS draws it on TextKit 2 (the caption once
        // captions are on).
        var expected: [(owner: String, drawn: Bool, foreground: Color?)] = []
        TextKit2Scope.forEachLeaf(in: blocks, allowed: allowed) { leaf in
            guard leaf.position != .codeRoot else { return }
            let drawn: Bool
            if case .eligible = leaf.verdict { drawn = true } else { drawn = false }
            expected.append((leaf.ownerID, drawn, leaf.position == .caption ? .secondary : nil))
        }
        let code = try #require(blocks.first { if case .codeBlock = $0.kind { return true }; return false })
        expected.append((code.id, rows[code.id] != nil, nil))
        #expect(expected.count == (TextKit2Scope.captionsUseTextKit2 ? 5 : 4), "root, list leader, panel paragraph, code, caption: \(expected.map(\.owner))")
        #expect(rows[code.id] != nil, "the code row is drawn")
        for item in expected {
            let row = rows[item.owner]
            #expect((row != nil) == item.drawn, "\(item.owner): row \(row != nil), drawn \(item.drawn)")
            if let row {
                #expect(row.inputs?.inheritedForeground == item.foreground, "\(item.owner): \(String(describing: row.inputs?.inheritedForeground))")
            }
        }
        #expect(rows.values.filter { $0.inputs?.inheritedForeground != nil }.allSatisfy { $0.containerContext == .caption })
    }
}
#endif
