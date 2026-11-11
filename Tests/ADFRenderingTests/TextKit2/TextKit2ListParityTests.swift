#if canImport(UIKit)
import SwiftUI
import UIKit
import Testing
import ADFModel
import ADFPreparation
@testable import ADFRendering

/// Hosted list parity (Astra §5): lists drawn through the real
/// `ListBlockView` / `ListRowView` (and, for whole documents,
/// `ADFDocumentView`), on both arms, at the widths their text is actually
/// proposed — the document's content column less the depth padding,
/// decision padding, marker column (scaled with Dynamic Type) and gap.
/// Heights and baselines must agree to 0.01 pt; marker and content crops of
/// each row are compared as pixels independently, so an exact leaf height
/// cannot hide a shifted marker, and whole lists and documents are compared
/// as composites, so it cannot hide accumulated spacing either.
///
/// Lists: the seven root lists of `lists-parity` (every marker family,
/// nesting to depth 4, ordered starts, tasks, decisions, continuations,
/// marks, links, atoms, emoji, hard breaks, embedded and trailing blocks)
/// and `composite` below (later-line link + emoji + sub/superscript
/// leaders, three-digit ordinals, long roman markers).
@Suite("TextKit 2 hosted list parity", .serialized,
       .enabled(if: TextKit2Eligibility.listsMatchText, "before iOS 26 lists keep their text on SwiftUI"))
@MainActor
struct TextKit2ListParityTests {
    nonisolated static let tolerance: CGFloat = 0.01
    /// iPhone SE, iPhone 17 Pro, a narrow iPad Split View pane and a
    /// fractional width.
    static var documentWidths: [CGFloat] { [375, 402, 320, fractionalDocumentWidth] }
    /// A width off the whole-point grid, within a hair of the device's
    /// pixel grid as a window's width is: 385.333 at 3x, 385.5 at 2x. At
    /// 2x, 385.333 is a third of a pixel off the grid, so every column
    /// ceils past its proposal, and `Text`, proposed that ceiled width
    /// next, can keep the layout it measured where a new layout fits one
    /// more word per line (measured: a task leader at AX5 drew 31 pt lower
    /// on TextKit 2). No 2x window is that wide.
    static var fractionalDocumentWidth: CGFloat { TK2Parity.nativeScale == 2 ? 385.5 : 385.333 }
    nonisolated static let maxDifferingFraction = 0.002
    static var theme: ADFTheme { TK2Parity.theme }

    /// The width the document proposes a top-level list: its content
    /// column, 16 pt in from each side (`ADFDocumentView`).
    static func listWidth(documentWidth: CGFloat) -> CGFloat { documentWidth - 4 * theme.spacing }

    /// `ListRowView.markerWidth` at a size (`@ScaledMetric(relativeTo: .body)` of 28).
    static func markerWidth(_ size: DynamicTypeSize) -> CGFloat {
        UIFontMetrics(forTextStyle: .body).scaledValue(for: 28, compatibleWith: UITraitCollection(preferredContentSizeCategory: size.uiContentSizeCategory))
    }

    static func isDecision(_ row: PreparedListRow) -> Bool {
        if case .decision = row.marker { return true }
        return false
    }

    /// The row's text column, as its `HStack` proposes it.
    static func textColumn(_ row: PreparedListRow, listWidth: CGFloat, size: DynamicTypeSize) -> CGFloat {
        let marker = markerWidth(size)
        return listWidth - CGFloat(row.depth) * (marker + theme.spacing) - (isDecision(row) ? 2 * theme.spacing : 0) - marker - theme.spacing
    }

    // MARK: Lists under test

    static func t(_ string: String, _ marks: String = "") -> String { TK2Parity.adfText(string, marks: marks) }
    static func paragraph(_ content: [String]) -> String { "{\"type\":\"paragraph\",\"content\":[\(content.joined(separator: ","))]}" }
    static func item(_ children: String...) -> String { "{\"type\":\"listItem\",\"content\":[\(children.joined(separator: ","))]}" }
    static func list(_ type: String, order: Int? = nil, _ items: [String]) -> String {
        "{\"type\":\"\(type)\"\(order.map { ",\"attrs\":{\"order\":\($0)}" } ?? ""),\"content\":[\(items.joined(separator: ","))]}"
    }
    static let link = "{\"type\":\"link\",\"attrs\":{\"href\":\"https://example.com/later-line\"}}"
    static let sub = "{\"type\":\"subsup\",\"attrs\":{\"type\":\"sub\"}}"
    static let sup = "{\"type\":\"subsup\",\"attrs\":{\"type\":\"sup\"}}"
    static let filler = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa".split(separator: " ")

    /// A linked leader whose later line holds a sub- or superscript and an
    /// emoji (PR 1's unmeasured AX3+ case: TextKit 1 treats a line after a
    /// separator as a first line for negative leading).
    static func laterLineContent(filler count: Int, mark: String, emojiFirst: Bool) -> [String] {
        let tail = emojiFirst
            ? [t(" \u{1F9EA} H"), t("2", mark), t("O tail")]
            : [t(" H"), t("2", mark), t("O \u{1F9EA} tail")]
        return [t("Linked opening words", link), t(" " + filler.prefix(count).joined(separator: " "))] + tail
    }

    static var compositeJSON: String {
        var laterLine: [String] = []
        for count in [2, 6, 10, 14] {
            for (mark, emojiFirst) in [(sub, false), (sup, true), (sup, false), (sub, true)] {
                laterLine.append(item(paragraph(laterLineContent(filler: count, mark: mark, emojiFirst: emojiFirst))))
            }
        }
        let romans = list("orderedList", order: 37, [
            item(paragraph([t("Thirty-seven, a roman marker at depth two")])),
            item(paragraph([t("Thirty-eight: xxxviii. is the longest marker in this list and may overflow its column")])),
        ])
        let alpha = list("orderedList", order: 26, [
            item(paragraph([t("Alphabetic z")]), romans),
            item(paragraph([t("Alphabetic aa after z, wrapping onto a second line at phone widths")])),
        ])
        let ordinals = list("orderedList", order: 98, [
            item(paragraph([t("Ninety-eight")])),
            item(paragraph([t("Ninety-nine, before the marker gains a digit")]), alpha),
            item(paragraph([t("One hundred: a three-digit ordinal with a leader long enough to wrap twice at the larger sizes")])),
            item(paragraph([t("One hundred and one")])),
        ])
        return "{\"version\":1,\"type\":\"doc\",\"content\":[\(list("bulletList", laterLine)),\(ordinals)]}"
    }

    struct ListCase {
        let name: String
        let block: RenderBlock
        var rows: [PreparedListRow] {
            if case .listRows(let rows) = block.kind { return rows }
            return []
        }
    }

    static func blocks(_ data: Data, theme: ADFTheme = TK2Parity.theme) async throws -> [RenderBlock] {
        DocumentPreparer(theme: theme).prepare(try await ADFParser().parse(data))
    }

    static func lists() async throws -> [ListCase] {
        var cases: [ListCase] = []
        for (document, data) in [("lists-parity", try TextKit2ListCoverageTests.fixtureData("lists-parity")), ("composite", Data(compositeJSON.utf8))] {
            for block in try await blocks(data) {
                if case .listRows = block.kind { cases.append(ListCase(name: "\(document) \(block.id)", block: block)) }
            }
        }
        return cases
    }

    /// Whether a list has text the TextKit 2 arm draws (eligible leaves in
    /// rows that keep the renderer, laid out left to right); the arm must
    /// engage exactly then.
    static func drawsTextKit2(_ block: RenderBlock, direction: LayoutDirection = .leftToRight) -> Bool {
        var found = false
        TextKit2Scope.forEachLeaf(in: [block]) { if case .eligible = $0.verdict { found = true } }
        return found && TextKit2Scope.listDirectionKeepsRenderer(direction)
    }

    // MARK: Hosting

    /// A list block as `ADFDocumentView`'s row hosts it (a list with a row
    /// holding anything but text gets `.swiftUI`).
    static func hostedList(_ block: RenderBlock, arm: ADFTextRenderer, env: TK2Parity.Environment, listWidth: CGFloat, theme: ADFTheme = TK2Parity.theme) -> some View {
        BlockView(block: block)
            .environment(\.adfTextRenderer, TextKit2Scope.inheritsRenderer(block.kind) ? arm : .swiftUI)
            .environment(\.adfListWidth, listWidth)
            .environment(\.adfTheme, theme)
            .environment(\.layoutDirection, env.direction)
            .environment(\.legibilityWeight, env.legibility)
            .dynamicTypeSize(env.size)
    }

    /// One row as its list hosts it.
    static func hostedRow(_ row: PreparedListRow, arm: ADFTextRenderer, env: TK2Parity.Environment, listWidth: CGFloat) -> some View {
        ListRowView(row: row)
            .environment(\.adfTextRenderer, arm)
            .environment(\.adfListWidth, listWidth)
            .environment(\.adfTheme, theme)
            .environment(\.layoutDirection, env.direction)
            .environment(\.legibilityWeight, env.legibility)
            .dynamicTypeSize(env.size)
    }

    /// Measured size and the text conversions (TextKit 2 rows built) it took.
    static func measure(_ view: some View, width: CGFloat) -> (size: CGSize, conversions: Int) {
        let host = UIHostingController(rootView: view)
        host.safeAreaRegions = []
        let before = TextKit2Diagnostics.shared.conversionCount
        let size = host.sizeThatFits(in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        return (size, TextKit2Diagnostics.shared.conversionCount - before)
    }

    /// First and last text baselines and height, as an enclosing
    /// baseline-aligned container reads them (`TK2Parity.guides`). The view
    /// gets an unspecified height, as the document's lazy stack proposes
    /// (a finite one would let `Text` truncate).
    static func guides(_ view: some View, width: CGFloat) -> (first: CGFloat, last: CGFloat, height: CGFloat) {
        let box = TK2Parity.GuideBox()
        let root = VStack(alignment: .leading, spacing: 0) {
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
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 2_000))
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

    /// `view` laid out at `width` (and an unspecified height, as in the
    /// document) in a window at the native scale, rendered; with the number
    /// of TextKit 2 rows it drew (engine proof).
    static func render(_ view: some View, width: CGFloat, height: CGFloat, dark: Bool) throws -> (bitmap: TK2Parity.Bitmap, textKit2Rows: Int) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.backgroundColor = dark ? .black : .white
        let host = UIHostingController(rootView: view
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea())
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        window.rootViewController = host
        window.isHidden = false
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        return (try TK2Parity.bitmap(of: window, width: width), TextKit2FallbackTests.rows(in: host.view).count)
    }

    // MARK: Pixels

    /// Ink in a column range: per pixel row, the count and the first and
    /// last ink column. Ink is any channel more than 8 off `background`.
    struct Ink: Equatable {
        var counts: [Int]
        var starts: [Int]
        var ends: [Int]

        var firstRow: Int? { counts.firstIndex { $0 > 0 } }
        var lastRow: Int? { counts.lastIndex { $0 > 0 } }

        /// Runs of consecutive ink rows (a line of text, a rule).
        var bands: [ClosedRange<Int>] {
            var bands: [ClosedRange<Int>] = []
            var start: Int?
            for (y, count) in counts.enumerated() {
                if count > 0 { start = start ?? y } else if let s = start { bands.append(s...(y - 1)); start = nil }
            }
            if let s = start { bands.append(s...(counts.count - 1)) }
            return bands
        }

        /// First and last ink column over `rows`.
        func extent(_ rows: ClosedRange<Int>) -> ClosedRange<Int>? {
            var first = Int.max, last = Int.min
            for y in rows where y < counts.count && counts[y] > 0 {
                first = min(first, starts[y])
                last = max(last, ends[y])
            }
            return first <= last ? first...last : nil
        }
    }

    static func ink(_ bitmap: TK2Parity.Bitmap, columns: Range<Int>, background: (Int, Int, Int)) -> Ink {
        var ink = Ink(counts: Array(repeating: 0, count: bitmap.height), starts: Array(repeating: 0, count: bitmap.height), ends: Array(repeating: 0, count: bitmap.height))
        let lower = max(columns.lowerBound, 0), upper = min(columns.upperBound, bitmap.width)
        guard lower < upper else { return ink }
        bitmap.rgba.withUnsafeBufferPointer { pixels in
            for y in 0..<bitmap.height {
                var count = 0, first = -1, last = -1
                var i = (y * bitmap.width + lower) * 4
                for x in lower..<upper {
                    if abs(Int(pixels[i]) - background.0) > 8 || abs(Int(pixels[i + 1]) - background.1) > 8 || abs(Int(pixels[i + 2]) - background.2) > 8 {
                        count += 1
                        if first < 0 { first = x }
                        last = x
                    }
                    i += 4
                }
                ink.counts[y] = count
                ink.starts[y] = first
                ink.ends[y] = last
            }
        }
        return ink
    }

    /// Pixels differing by more than 24 in any channel, over a crop.
    static func differing(_ a: TK2Parity.Bitmap, _ b: TK2Parity.Bitmap, columns: Range<Int>, rows: ClosedRange<Int>) -> (count: Int, total: Int) {
        let lower = max(columns.lowerBound, 0), upper = min(columns.upperBound, a.width, b.width)
        let rows = max(rows.lowerBound, 0)...min(rows.upperBound, a.height - 1, b.height - 1)
        guard lower < upper, !rows.isEmpty else { return (0, 0) }
        var count = 0
        a.rgba.withUnsafeBufferPointer { p in
            b.rgba.withUnsafeBufferPointer { q in
                for y in rows {
                    var i = (y * a.width + lower) * 4
                    for _ in lower..<upper {
                        if abs(Int(p[i]) - Int(q[i])) > 24 || abs(Int(p[i + 1]) - Int(q[i + 1])) > 24 || abs(Int(p[i + 2]) - Int(q[i + 2])) > 24 { count += 1 }
                        i += 4
                    }
                }
            }
        }
        return (count, (upper - lower) * rows.count)
    }

    /// Compares one crop of both arms: first and last ink rows, per-row ink
    /// counts, each band's first and last ink column (line starts and
    /// ends, rule and decoration ends) and the differing-pixel fraction.
    /// Returns the failures.
    static func compareCrop(_ name: String, _ a: TK2Parity.Bitmap, _ b: TK2Parity.Bitmap, columns: Range<Int>, background: (Int, Int, Int)) -> [String] {
        compareInk(name, ink(a, columns: columns, background: background), ink(b, columns: columns, background: background), a, b, columns: columns)
    }

    static func compareInk(_ name: String, _ ia: Ink, _ ib: Ink, _ a: TK2Parity.Bitmap, _ b: TK2Parity.Bitmap, columns: Range<Int>) -> [String] {
        var failures: [String] = []
        if ia.firstRow != ib.firstRow || ia.lastRow != ib.lastRow {
            failures.append("\(name): ink rows swiftUI=\(String(describing: ia.firstRow))…\(String(describing: ia.lastRow)) textKit2=\(String(describing: ib.firstRow))…\(String(describing: ib.lastRow))")
        }
        if ia.counts != ib.counts {
            let rows = ia.counts.indices.filter { ia.counts[$0] != ib.counts[$0] }
            failures.append("\(name): per-row ink counts differ on \(rows.count) rows, first \(rows.prefix(6).map { "\($0): \(ia.counts[$0])/\(ib.counts[$0])" })")
        }
        for band in ia.bands where ia.extent(band) != ib.extent(band) {
            failures.append("\(name): band \(band) ink columns swiftUI=\(String(describing: ia.extent(band))) textKit2=\(String(describing: ib.extent(band)))")
        }
        if let first = ia.firstRow, let last = ia.lastRow {
            let diff = differing(a, b, columns: columns, rows: first...last)
            if Double(diff.count) > Double(diff.total) * maxDifferingFraction {
                failures.append("\(name): \(diff.count)/\(diff.total) pixels differ")
            }
        }
        return failures
    }

    static func background(dark: Bool) -> (Int, Int, Int) { dark ? (0, 0, 0) : (255, 255, 255) }

    // MARK: Tests

    @Test("every list's height matches at every size and document width")
    func groupHeights() async throws {
        var worst: (delta: CGFloat, description: String) = (0, "")
        var checked = 0
        for list in try await Self.lists() {
            for size in DynamicTypeSize.allCases {
                for documentWidth in Self.documentWidths {
                    let width = Self.listWidth(documentWidth: documentWidth)
                    let env = TK2Parity.Environment(size: size)
                    let a = Self.measure(Self.hostedList(list.block, arm: .swiftUI, env: env, listWidth: width), width: width)
                    let b = Self.measure(Self.hostedList(list.block, arm: .textKit2, env: env, listWidth: width), width: width)
                    let delta = abs(a.size.height - b.size.height)
                    let label = "\(list.name) \(size) W=\(documentWidth): swiftUI=\(a.size.height) textKit2=\(b.size.height)"
                    checked += 1
                    if delta > worst.delta { worst = (delta, label) }
                    #expect(delta <= Self.tolerance, "\(label)")
                    #expect(a.conversions == 0, "\(label): SwiftUI arm built TextKit 2 rows")
                    #expect((b.conversions > 0) == Self.drawsTextKit2(list.block), "\(label): TextKit 2 arm built \(b.conversions) rows")
                }
            }
        }
        print("TK2 list parity heights: \(checked) list × size × width at scale \(TK2Parity.nativeScale), worst |Δ| = \(worst.delta) \(worst.description)")
    }

    @Test("list heights match under right-to-left layout, Bold Text and dark appearance")
    func groupHeightsAcrossLayoutInputs() async throws {
        let environments = [
            TK2Parity.Environment(size: .large, direction: .rightToLeft),
            TK2Parity.Environment(size: .accessibility3, direction: .rightToLeft),
            TK2Parity.Environment(size: .large, legibility: .bold),
            TK2Parity.Environment(size: .xxxLarge, legibility: .bold),
            TK2Parity.Environment(size: .accessibility5, direction: .rightToLeft, legibility: .bold),
            TK2Parity.Environment(size: .large, dark: true),
        ]
        var checked = 0
        for list in try await Self.lists() {
            for env in environments {
                for documentWidth in [CGFloat(375), Self.fractionalDocumentWidth] {
                    let width = Self.listWidth(documentWidth: documentWidth)
                    let scheme: ColorScheme = env.dark ? .dark : .light
                    let a = Self.measure(Self.hostedList(list.block, arm: .swiftUI, env: env, listWidth: width).environment(\.colorScheme, scheme), width: width)
                    let b = Self.measure(Self.hostedList(list.block, arm: .textKit2, env: env, listWidth: width).environment(\.colorScheme, scheme), width: width)
                    checked += 1
                    #expect(abs(a.size.height - b.size.height) <= Self.tolerance, "\(list.name) \(env) W=\(documentWidth): swiftUI=\(a.size.height) textKit2=\(b.size.height)")
                    #expect((b.conversions > 0) == Self.drawsTextKit2(list.block, direction: env.direction), "\(list.name) \(env): TextKit 2 arm built \(b.conversions) rows")
                }
            }
        }
        print("TK2 list parity heights (rtl / bold text / dark): \(checked) measurements")
    }

    @Test("every row's height and first and last baselines match, at its real width")
    func rowGeometry() async throws {
        let environments = [DynamicTypeSize.xSmall, .large, .xxxLarge, .accessibility1, .accessibility3, .accessibility5].map { TK2Parity.Environment(size: $0) }
            + [TK2Parity.Environment(size: .large, direction: .rightToLeft), TK2Parity.Environment(size: .accessibility3, legibility: .bold)]
        let onePixel = 1 / TK2Parity.nativeScale
        var checked = 0
        var lastBaselineResiduals = 0
        for list in try await Self.lists() {
            for row in list.rows {
                for env in environments {
                    for documentWidth in Self.documentWidths {
                        let width = Self.listWidth(documentWidth: documentWidth)
                        let s = Self.guides(Self.hostedRow(row, arm: .swiftUI, env: env, listWidth: width), width: width)
                        let t = Self.guides(Self.hostedRow(row, arm: .textKit2, env: env, listWidth: width), width: width)
                        let label = "\(list.name) row \(row.id) \(env) W=\(documentWidth)"
                        checked += 1
                        #expect(abs(s.height - t.height) <= Self.tolerance, "\(label): height swiftUI=\(s.height) textKit2=\(t.height)")
                        #expect(abs(s.first - t.first) <= Self.tolerance, "\(label): first baseline swiftUI=\(s.first) textKit2=\(t.first)")
                        if abs(s.last - t.last - onePixel) <= Self.tolerance {
                            // PR 1 residual 1: `Text`'s last-baseline guide
                            // sits a pixel below its drawn baseline.
                            lastBaselineResiduals += 1
                            withKnownIssue("SwiftUI's last-baseline guide is 1 px below its drawn baseline") {
                                #expect(abs(s.last - t.last) <= Self.tolerance, "\(label): last baseline swiftUI=\(s.last) textKit2=\(t.last)")
                            }
                        } else {
                            #expect(abs(s.last - t.last) <= Self.tolerance, "\(label): last baseline swiftUI=\(s.last) textKit2=\(t.last)")
                        }
                    }
                }
            }
        }
        print("TK2 list parity row geometry: \(checked) row × environment × width, \(lastBaselineResiduals) with SwiftUI's last-baseline guide +1 px")
    }

    /// Marker and content crops of each row, light and dark, at the
    /// iPhone SE and fractional widths: the marker (and decision
    /// background) must sit at the same pixels relative to the text, and
    /// the text's lines start, end and decorate identically.
    @Test("every row's marker and content crops render identically")
    func rowPixels() async throws {
        var environments: [TK2Parity.Environment] = []
        for size in [DynamicTypeSize.large, .xxxLarge, .accessibility3] {
            environments.append(TK2Parity.Environment(size: size))
            environments.append(TK2Parity.Environment(size: size, dark: true))
        }
        environments += [
            TK2Parity.Environment(size: .large, direction: .rightToLeft),
            TK2Parity.Environment(size: .accessibility3, direction: .rightToLeft, dark: true),
            TK2Parity.Environment(size: .large, legibility: .bold),
        ]
        var compared = 0
        var engaged = 0
        var failures: [String] = []
        for list in try await Self.lists() {
            for row in list.rows {
                for env in environments {
                    for documentWidth in [CGFloat(375), Self.fractionalDocumentWidth] {
                        let width = Self.listWidth(documentWidth: documentWidth)
                        let label = "\(list.name) row \(row.id) \(env) W=\(documentWidth)"
                        let rowHeight = Self.measure(Self.hostedRow(row, arm: .swiftUI, env: env, listWidth: width), width: width).size.height
                        let a = try Self.render(Self.hostedRow(row, arm: .swiftUI, env: env, listWidth: width), width: width, height: rowHeight + 24, dark: env.dark)
                        let b = try Self.render(Self.hostedRow(row, arm: .textKit2, env: env, listWidth: width), width: width, height: rowHeight + 24, dark: env.dark)
                        #expect(a.textKit2Rows == 0, "\(label)")
                        if b.textKit2Rows > 0 { engaged += 1 }
                        let scale = a.bitmap.scale
                        let inset = CGFloat(row.depth) * (Self.markerWidth(env.size) + Self.theme.spacing) + (Self.isDecision(row) ? Self.theme.spacing : 0)
                        let split = Int(((inset + Self.markerWidth(env.size) + Self.theme.spacing / 2) * scale).rounded())
                        let pixelWidth = a.bitmap.width
                        let rtl = env.direction == .rightToLeft
                        let marker = rtl ? (pixelWidth - split)..<pixelWidth : 0..<split
                        let content = rtl ? 0..<(pixelWidth - split) : split..<pixelWidth
                        // A decision row's background is ink against the
                        // window: compare against the background itself,
                        // sampled in its padding beside the marker.
                        var background = Self.background(dark: env.dark)
                        if Self.isDecision(row) {
                            let x = rtl ? pixelWidth - 3 : 2
                            let sample = a.bitmap[x, Int(rowHeight / 2 * scale)]
                            background = (sample.r, sample.g, sample.b)
                        }
                        let ma = Self.ink(a.bitmap, columns: marker, background: background), ca = Self.ink(a.bitmap, columns: content, background: background)
                        let mb = Self.ink(b.bitmap, columns: marker, background: background), cb = Self.ink(b.bitmap, columns: content, background: background)
                        var all = Self.compareInk("\(label) marker", ma, mb, a.bitmap, b.bitmap, columns: marker)
                            + Self.compareInk("\(label) content", ca, cb, a.bitmap, b.bitmap, columns: content)
                        // The marker's offset from the first line of text.
                        let offset = { (m: Ink, c: Ink) -> Int? in
                            guard let first = m.firstRow, let text = c.firstRow else { return nil }
                            return first - text
                        }
                        let offsetA = offset(ma, ca), offsetB = offset(mb, cb)
                        if offsetA != offsetB { all.append("\(label): marker offset from the first text ink swiftUI=\(String(describing: offsetA)) textKit2=\(String(describing: offsetB))") }
                        // A row with no text column draws its text outside
                        // it (`narrowColumnRows`), on both arms.
                        let hasColumn = Self.textColumn(row, listWidth: width, size: env.size) >= TextKit2Scope.minimumListTextWidth
                        #expect(ca.firstRow != nil || row.segments.isEmpty || !hasColumn, "\(label): SwiftUI drew no content ink")
                        compared += 1
                        failures += all
                        if let known = Self.knownRunBackgroundEdge(label, scale: scale) {
                            withKnownIssue(known) {
                                for failure in all { Issue.record(Comment(rawValue: failure)) }
                            }
                        } else {
                            for failure in all { Issue.record(Comment(rawValue: failure)) }
                        }
                    }
                }
            }
        }
        #expect(engaged > compared / 2, "TextKit 2 drew \(engaged) of \(compared) rows")
        print("TK2 list parity row pixels: \(compared) row comparisons at scale \(TK2Parity.nativeScale), TextKit 2 engaged in \(engaged), \(failures.count) failures")
    }

    /// Residuals of the shared run-background drawing (PR 1,
    /// `TextKit2RowView.RunBackgrounds`), not of the list: each reproduces
    /// pixel for pixel when the marks leader is drawn as a root paragraph
    /// at the row's column width. At xxxLarge in dark appearance (2x and
    /// 3x), `Text`'s highlight band on the last line (a subscript and a
    /// superscript beside it) covers part of one more pixel row; in light
    /// appearance that partial row is within the ink threshold. With Bold
    /// Text at 2x, `Text`'s inline-code band fills one more pixel column at
    /// its right edge (the code grey, 235, over the line's 41 rows). Known
    /// issues, so a fix fails here.
    static func knownRunBackgroundEdge(_ label: String, scale: CGFloat) -> Comment? {
        for width in ["375.0", "\(Self.fractionalDocumentWidth)"] {
            if label == "lists-parity 0.8 row 0.8.1 xxxLarge dark W=\(width)" {
                return "PR 1 run-background residual: the highlight band's antialiased bottom edge row on a sub/superscript line, dark"
            }
            if scale == 2, label == "lists-parity 0.8 row 0.8.1 large boldText W=\(width)" {
                return "PR 1 run-background residual: the inline-code band's right edge column, Bold Text at 2x"
            }
        }
        return nil
    }

    /// Whole lists as one picture: row origins (spacing), decision
    /// backgrounds and every row's ink, at the iPhone SE width.
    @Test("whole lists render identically")
    func listPixels() async throws {
        let environments = [
            TK2Parity.Environment(size: .large),
            TK2Parity.Environment(size: .accessibility1),
            TK2Parity.Environment(size: .large, dark: true),
            TK2Parity.Environment(size: .large, direction: .rightToLeft),
        ]
        var compared = 0
        for list in try await Self.lists() {
            for env in environments {
                let width = Self.listWidth(documentWidth: 375)
                let label = "\(list.name) \(env)"
                let height = Self.measure(Self.hostedList(list.block, arm: .swiftUI, env: env, listWidth: width), width: width).size.height + 24
                let a = try Self.render(Self.hostedList(list.block, arm: .swiftUI, env: env, listWidth: width), width: width, height: height, dark: env.dark)
                let b = try Self.render(Self.hostedList(list.block, arm: .textKit2, env: env, listWidth: width), width: width, height: height, dark: env.dark)
                #expect((b.textKit2Rows > 0) == Self.drawsTextKit2(list.block, direction: env.direction), "\(label): \(b.textKit2Rows) TextKit 2 rows")
                let failures = Self.compareCrop(label, a.bitmap, b.bitmap, columns: 0..<a.bitmap.width, background: Self.background(dark: env.dark))
                for failure in failures { Issue.record(Comment(rawValue: failure)) }
                compared += 1
            }
        }
        print("TK2 list parity whole-list pixels: \(compared) comparisons")
    }

    /// Whole documents through `ADFDocumentView`, every row materialised (a
    /// window taller than the document): the same scroll content height
    /// and the same pixels, band by band, top to bottom. Row origins,
    /// spacing, markers and text all land in the same place, so nothing a
    /// per-row comparison measures in isolation can drift in the document.
    @Test("whole documents render identically on both arms", arguments: [
        TK2Parity.Environment(size: .large),
        TK2Parity.Environment(size: .xSmall),
        TK2Parity.Environment(size: .xxxLarge),
        TK2Parity.Environment(size: .accessibility1),
        TK2Parity.Environment(size: .accessibility3),
        TK2Parity.Environment(size: .accessibility5),
        TK2Parity.Environment(size: .accessibility1, direction: .rightToLeft),
        TK2Parity.Environment(size: .large, dark: true),
        TK2Parity.Environment(size: .xxxLarge, legibility: .bold),
    ])
    func documents(env: TK2Parity.Environment) async throws {
        for documentWidth in Self.documentWidths {
            for (document, data) in [("lists-parity", try TextKit2ListCoverageTests.fixtureData("lists-parity")), ("composite", Data(Self.compositeJSON.utf8))] {
                let label = "\(document) W=\(documentWidth) \(env)"
                var windows: [UIWindow] = []
                var heights: [CGFloat] = []
                var textKit2Rows: [TextKit2RowView] = []
                for arm in [ADFTextRenderer.swiftUI, .textKit2] {
                    let model = ADFDocumentModel()
                    model.load(data: data)
                    for _ in 0..<500 where model.phase != .ready {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    try #require(model.phase == .ready)
                    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: documentWidth, height: Self.documentWindowHeight))
                    window.overrideUserInterfaceStyle = env.dark ? .dark : .light
                    window.backgroundColor = env.dark ? .black : .white
                    let host = UIHostingController(rootView: ADFDocumentView(model: model, mediaProvider: TextKit2DiagnosticsTests.NoMedia(), textRenderer: arm)
                        .environment(\.layoutDirection, env.direction)
                        .environment(\.legibilityWeight, env.legibility)
                        .dynamicTypeSize(env.size))
                    host.safeAreaRegions = []
                    window.rootViewController = host
                    window.isHidden = false
                    try await TextKit2DiagnosticsTests.settle(window)
                    heights.append(try #require(Self.scrollView(in: host.view)).contentSize.height)
                    if arm == .textKit2 { textKit2Rows = TextKit2FallbackTests.rows(in: host.view) }
                    windows.append(window)
                }
                defer {
                    for window in windows {
                        window.isHidden = true
                        window.rootViewController = nil
                    }
                }
                #expect(heights[1] < Self.documentWindowHeight, "\(label): document taller than the window; rows were not all materialised")
                #expect(abs(heights[0] - heights[1]) <= Self.tolerance, "\(label): content height swiftUI=\(heights[0]) textKit2=\(heights[1])")
                // Right to left, list text stays on SwiftUI
                // (`TextKit2Scope.listDirectionKeepsRenderer`).
                #expect(textKit2Rows.contains { $0.ownerKind == .list } == (env.direction == .leftToRight), "\(label): TextKit 2 list rows \(textKit2Rows.filter { $0.ownerKind == .list }.count)")
                #expect(textKit2Rows.allSatisfy { $0.bounds.width > 0 }, "\(label): a TextKit 2 row was placed with no width")
                var differing: [String] = []
                var y: CGFloat = 0
                while y < min(heights[0], Self.documentWindowHeight) {
                    let a = try Self.band(of: windows[0], y: y), b = try Self.band(of: windows[1], y: y)
                    let diff = Self.differing(a, b, columns: 0..<a.width, rows: 0...(a.height - 1))
                    if diff.count > 0 { differing.append("y=\(y): \(diff.count) px") }
                    y += Self.bandHeight
                }
                #expect(differing.isEmpty, "\(label): bands differ: \(differing)")
                print("TK2 list parity document \(label): content height \(heights[0]) on both arms, \(textKit2Rows.count) TextKit 2 rows, \(differing.isEmpty ? "pixel-identical" : "\(differing.count) bands differ")")
            }
        }
    }

    static let documentWindowHeight: CGFloat = 90_000
    static let bandHeight: CGFloat = 1_000

    /// A band of the laid-out window, `bandHeight` tall from `y`, at the
    /// native scale (`TK2Parity.bitmap(of:width:)` for a whole window).
    static func band(of window: UIWindow, y: CGFloat) throws -> TK2Parity.Bitmap {
        let scale = window.traitCollection.displayScale
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let width = window.bounds.width
        let image = UIGraphicsImageRenderer(bounds: CGRect(x: 0, y: y, width: width, height: bandHeight), format: format).image { context in
            window.layer.render(in: context.cgContext)
        }
        let cgImage = try #require(image.cgImage)
        let pixelWidth = min(cgImage.width, Int((width * scale + 0.01).rounded(.down)))
        var data = [UInt8](repeating: 0, count: pixelWidth * cgImage.height * 4)
        let context = try #require(CGContext(
            data: &data, width: pixelWidth, height: cgImage.height, bitsPerComponent: 8, bytesPerRow: pixelWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return TK2Parity.Bitmap(width: pixelWidth, height: cgImage.height, scale: scale, rgba: data)
    }

    static func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for subview in view.subviews {
            if let scroll = scrollView(in: subview) { return scroll }
        }
        return nil
    }

    // MARK: Mixed text columns

    /// A row's text column shares the row's height out among its blocks
    /// on the `HStack`'s second pass (`TextKit2Scope.rowKeepsRenderer`).
    /// A row whose column holds one block (a leader, or a lone paragraph
    /// or heading after a nested list; superscript, emoji and inline code
    /// lines included) stays on TextKit 2 and matches; a row with more
    /// than one block, whether paragraphs, a heading, a container or a
    /// trailing list, keeps all its text on SwiftUI, so it matches by
    /// construction — the fixture's embedded-blocks and sync-block items
    /// among them, which drew their text up to 14.5 pt off before.
    @Test("rows with more than one block in their text column stay on SwiftUI; one-block rows stay on TextKit 2")
    func mixedColumns() async throws {
        func words(_ n: Int) -> String { Self.filler.prefix(n).joined(separator: " ") }
        let heading = { (level: Int, n: Int) in "{\"type\":\"heading\",\"attrs\":{\"level\":\(level)},\"content\":[\(Self.t(words(n)))]}" }
        let code = "{\"type\":\"code\"}"
        let panel = "{\"type\":\"panel\",\"attrs\":{\"panelType\":\"info\"},\"content\":[\(Self.paragraph([Self.t("A panel paragraph long enough to wrap in a narrow column")]))]}"
        let stray = "{\"type\":\"listItem\",\"content\":[\(Self.list("bulletList", [Self.item(Self.paragraph([Self.t(words(3))])), Self.item(Self.paragraph([Self.t(words(12))])), Self.item(Self.paragraph([Self.t(words(3))]))]))]}"
        let mixedLine = [Self.t(words(10) + " \u{1F600}\u{1F389} "), Self.t("code", code), Self.t(" " + words(6) + " x"), Self.t("2", Self.sup), Self.t(" " + words(8))]
        let nested = Self.list("bulletList", [Self.item(Self.paragraph([Self.t(words(2))]))])
        let shapes: [(name: String, item: String, keeps: Bool)] = [
            ("lone leader", Self.item(Self.paragraph(mixedLine)), true),
            ("lone paragraph", Self.item(Self.paragraph([Self.t(words(4))]), nested, Self.paragraph(mixedLine)), true),
            ("lone heading", Self.item(Self.paragraph([Self.t(words(4))]), nested, heading(2, 12)), true),
            ("two paragraphs", Self.item(Self.paragraph([Self.t(words(12))]), Self.paragraph([Self.t(words(3))])), false),
            ("superscript beside a paragraph", Self.item(Self.paragraph([Self.t(words(12))]), Self.paragraph([Self.t("x"), Self.t("2", Self.sup), Self.t(" " + words(3))]), Self.paragraph([Self.t(words(3))])), false),
            ("heading after the leader", Self.item(Self.paragraph([Self.t(words(12))]), heading(2, 12), Self.paragraph([Self.t(words(3))])), false),
            ("paragraph then heading", Self.item(Self.paragraph([Self.t(words(3))]), Self.paragraph([Self.t(words(12))]), heading(2, 12)), false),
            ("trailing list", Self.item(Self.paragraph([Self.t(words(14))]), stray), false),
            ("panel", Self.item(Self.paragraph([Self.t(words(12))]), panel), false),
        ]
        var cases: [(name: String, row: PreparedListRow, keeps: Bool)] = []
        for shape in shapes {
            let json = "{\"version\":1,\"type\":\"doc\",\"content\":[\(Self.list("bulletList", [shape.item]))]}"
            guard case .listRows(let rows) = try #require(try await Self.blocks(Data(json.utf8)).first).kind else { continue }
            // The row under test holds the shape's trailing blocks (for the
            // lone paragraph and heading, the continuation after the nested
            // list), or the leader alone.
            let row = try #require(rows.last { !$0.trailingBlocks.isEmpty } ?? rows.first)
            #expect(TextKit2Scope.rowKeepsRenderer(row) == shape.keeps, "\(shape.name)")
            cases.append((shape.name, row, shape.keeps))
        }
        let parity = try await Self.lists().first { $0.name == "lists-parity 0.10" }?.rows.first { $0.id == "0.10.2" }
        let sync = try await Self.lists().first { $0.name == "lists-parity 0.12" }?.rows.first { $0.id == "0.12.0" }
        cases.append(("lists-parity embedded blocks", try #require(parity), false))
        cases.append(("lists-parity sync block", try #require(sync), false))
        let onePixel = 1 / TK2Parity.nativeScale
        var checked = 0
        for (name, row, keeps) in cases {
            for size in [DynamicTypeSize.large, .xxxLarge, .accessibility3, .accessibility5] {
                for documentWidth in [CGFloat(402), 320] {
                    let width = Self.listWidth(documentWidth: documentWidth)
                    let env = TK2Parity.Environment(size: size)
                    let label = "\(name) \(size) W=\(documentWidth)"
                    let s = Self.guides(Self.hostedRow(row, arm: .swiftUI, env: env, listWidth: width), width: width)
                    let t = Self.guides(Self.hostedRow(row, arm: .textKit2, env: env, listWidth: width), width: width)
                    #expect(abs(s.height - t.height) <= Self.tolerance, "\(label): height swiftUI=\(s.height) textKit2=\(t.height)")
                    #expect(abs(s.first - t.first) <= Self.tolerance, "\(label): first baseline swiftUI=\(s.first) textKit2=\(t.first)")
                    // PR 1 residual 1 (`rowGeometry`): one pixel, SwiftUI's.
                    #expect(abs(s.last - t.last) <= Self.tolerance || abs(s.last - t.last - onePixel) <= Self.tolerance, "\(label): last baseline swiftUI=\(s.last) textKit2=\(t.last)")
                    let drawn = try Self.render(Self.hostedRow(row, arm: .textKit2, env: env, listWidth: width), width: width, height: s.height + 24, dark: false).textKit2Rows
                    #expect((drawn > 0) == keeps, "\(label): \(drawn) TextKit 2 rows")
                    checked += 1
                }
            }
        }
        print("TK2 list parity mixed columns: \(checked) row comparisons, \(cases.filter(\.keeps).count) of \(cases.count) shapes on TextKit 2")
    }

    // MARK: Column-filling lines

    /// Reports the width its subview gives each of `widths` (unspecified
    /// height), in order.
    struct WidthProbe: Layout {
        let widths: [CGFloat]
        let record: ([CGFloat]) -> Void

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            record(widths.map { subviews[0].sizeThatFits(ProposedViewSize(width: $0, height: nil)).width })
            return subviews[0].sizeThatFits(proposal)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews[0].place(at: bounds.origin, proposal: proposal)
        }
    }

    /// A list text column is a sum of pixel lengths (the list's width less
    /// marker columns and gaps), a few ulps off a pixel. A line that fills
    /// it reports the column ceiled as SwiftUI ceils it
    /// (`TextKit2RowView.proposalCeil`); a pixel narrower and the list
    /// holding the row was narrower than with `Text`, re-proposing every
    /// row and shifting it (`lists-parity` 0.8, AX1, iPhone SE).
    @Test("text filling its column reports the width Text does at every list column width")
    func columnFillingWidths() async throws {
        var widths: [CGFloat] = []
        for size in DynamicTypeSize.allCases {
            let marker = Self.markerWidth(size)
            for documentWidth in Self.documentWidths + [353.333, 1_024] {
                for depth in 0...3 {
                    let column = Self.listWidth(documentWidth: documentWidth) - CGFloat(depth) * (marker + Self.theme.spacing) - marker - Self.theme.spacing
                    if column > 40 { widths.append(column) }
                }
            }
        }
        let fixtures = [
            try await TK2Parity.plain("plain", TextKit2ListLayoutTests.long),
            try await TK2Parity.plain("unicode", "Café naïve Zoë 日本語 中文 한국어 \u{1F469}\u{1F3FD}\u{200D}\u{1F4BB} and more words to wrap across the column width"),
            try await TK2Parity.plain("rtl", "\u{05E9}\u{05DC}\u{05D5}\u{05DD} \u{05E2}\u{05D5}\u{05DC}\u{05DD} with mixed English words that wrap across several lines of the column"),
            try await TK2Parity.fixture("linked", content: [Self.t("Linked words at the start", Self.link), Self.t(" then " + TextKit2ListLayoutTests.long)].joined(separator: ",")),
        ]
        var checked = 0
        var filling = 0
        for fixture in fixtures {
            for size in [DynamicTypeSize.large, .xxxLarge, .accessibility1, .accessibility3] {
                var reported: [[CGFloat]] = []
                for arm in [ADFTextRenderer.swiftUI, .textKit2] {
                    var widthsSeen: [CGFloat] = []
                    let leaf = TextEngineLeaf(segments: fixture.segments, style: ListRowView.leaderStyle(theme: Self.theme), ownerID: fixture.name) {
                        SegmentedTextView(segments: fixture.segments, ownerID: fixture.name)
                    }
                    let probe = WidthProbe(widths: widths) { widthsSeen = $0 } { leaf }
                        .environment(\.adfTextRenderer, arm).environment(\.adfTheme, Self.theme).dynamicTypeSize(size)
                    _ = Self.measure(probe, width: 1_100)
                    reported.append(widthsSeen)
                }
                try #require(reported[0].count == widths.count && reported[1].count == widths.count)
                for (index, width) in widths.enumerated() {
                    checked += 1
                    if reported[0][index] > width - 0.5 { filling += 1 }
                    #expect(reported[0][index] == reported[1][index], "\(fixture.name) \(size) column \(String(format: "%.15f", width)): swiftUI=\(reported[0][index]) textKit2=\(reported[1][index])")
                }
            }
        }
        #expect(filling > checked / 4, "only \(filling) of \(checked) widths had a line filling the column")
        print("TK2 list parity column-filling widths: \(checked) widths, \(filling) with a line filling the column")
    }

    // MARK: Narrow columns

    /// The evidence behind `TextKit2Scope.minimumListTextWidth`. At every
    /// positive width down to one pixel a TextKit 2 row measures as `Text`
    /// does; at a zero width `Text` sets one character per line and the
    /// row lays nothing out.
    @Test("text measures as Text does at every positive width; a zero width is the one difference")
    func narrowWidths() async throws {
        let fixtures = [
            try await TK2Parity.plain("body", TextKit2ListLayoutTests.long),
            try await TK2Parity.heading(3, "A heading wrapped at a few points wide"),
            try await TK2Parity.fixture("linked-emoji", content: [Self.t("Linked words", Self.link), Self.t(" then an emoji \u{1F9EA} and H"), Self.t("2", Self.sub), Self.t("O")].joined(separator: ",")),
            TK2Parity.Fixture(name: "leader", segments: (try await TK2Parity.plain("x", "Leader text at a sliver of a column")).segments, style: ListRowView.leaderStyle(theme: Self.theme)),
        ]
        let onePixel = 1 / TK2Parity.nativeScale
        for fixture in fixtures {
            for size in [DynamicTypeSize.large, .accessibility5] {
                for width in [onePixel, 0.5, 1, 2, 4, 8, 16, 36] {
                    let h = TK2Parity.heights(fixture, size: size, width: width)
                    #expect(abs(h.swiftUI - h.textKit2) <= Self.tolerance, "\(fixture.name) \(size) w=\(width): swiftUI=\(h.swiftUI) textKit2=\(h.textKit2)")
                }
                let zero = TK2Parity.heights(fixture, size: size, width: 0)
                #expect(zero.swiftUI > 100 && zero.textKit2 == 0, "\(fixture.name) \(size) w=0: swiftUI=\(zero.swiftUI) textKit2=\(zero.textKit2)")
            }
        }
    }

    /// The deepest `lists-parity` rows leave no text column at AX3 on an
    /// iPhone SE and at AX2 in a 320 pt pane; the row's `HStack` proposes
    /// such text a zero width. Those rows, and only those, stay on SwiftUI
    /// (`TextKit2Scope.listTextFits`), so the list matches; without the
    /// list's width (an unknown host) they would be drawn by TextKit 2 and
    /// the list would not.
    @Test("rows without a text column stay on SwiftUI; their neighbours stay on TextKit 2")
    func narrowColumnRows() async throws {
        let lists = try await Self.lists()
        let list = try #require(lists.first { $0.name == "lists-parity 0.1" })
        var degenerateSeen = 0
        for (documentWidth, size) in [(CGFloat(375), DynamicTypeSize.accessibility3), (375, .accessibility5), (320, .accessibility2), (402, .accessibility4)] {
            let width = Self.listWidth(documentWidth: documentWidth)
            let env = TK2Parity.Environment(size: size)
            let label = "W=\(documentWidth) \(size)"
            let narrow = Set(list.rows.filter { !$0.segments.isEmpty && Self.textColumn($0, listWidth: width, size: size) < TextKit2Scope.minimumListTextWidth }.map(\.id))
            let roomy = Set(list.rows.filter { !$0.segments.isEmpty && Self.textColumn($0, listWidth: width, size: size) >= TextKit2Scope.minimumListTextWidth }.map(\.id))
            #expect(!narrow.isEmpty, "\(label): expected a row without a text column")
            degenerateSeen += narrow.count
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 30_000))
            let host = UIHostingController(rootView: Self.hostedList(list.block, arm: .textKit2, env: env, listWidth: width)
                .frame(width: width, alignment: .topLeading).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).ignoresSafeArea())
            host.safeAreaRegions = []
            window.rootViewController = host
            window.isHidden = false
            window.layoutIfNeeded()
            let owners = Set(TextKit2FallbackTests.rows(in: host.view).compactMap(\.ownerID))
            window.isHidden = true
            window.rootViewController = nil
            let eligibleRoomy = Set(list.rows.filter {
                roomy.contains($0.id) && TextKit2Scope.rowKeepsRenderer($0) && TextKit2Eligibility.describableText($0.segments) != nil
            }.map(\.id))
            #expect(owners.isDisjoint(with: narrow), "\(label): TextKit 2 rows in no column: \(owners.intersection(narrow).sorted())")
            #expect(eligibleRoomy.isSubset(of: owners), "\(label): rows with a column not on TextKit 2: \(eligibleRoomy.subtracting(owners).sorted())")
            let a = Self.measure(Self.hostedList(list.block, arm: .swiftUI, env: env, listWidth: width), width: width).size.height
            let b = Self.measure(Self.hostedList(list.block, arm: .textKit2, env: env, listWidth: width), width: width).size.height
            #expect(abs(a - b) <= Self.tolerance, "\(label): swiftUI=\(a) textKit2=\(b)")
            // The same list in a host that does not know its width.
            let unknown = Self.measure(BlockView(block: list.block).environment(\.adfTextRenderer, .textKit2).environment(\.adfTheme, Self.theme).dynamicTypeSize(size), width: width).size.height
            #expect(unknown < a - 100, "\(label): without the list width TextKit 2 collapses the rows with no column (swiftUI=\(a), unknown width=\(unknown))")
        }
        print("TK2 list parity narrow columns: \(degenerateSeen) rows without a text column kept on SwiftUI")
    }

    // MARK: Later-line link + emoji + sub/superscript

    @Test("a linked leader whose later line has a sub/superscript and an emoji measures as Text does at AX3+", arguments: [DynamicTypeSize.large, .accessibility3, .accessibility4, .accessibility5])
    func laterLineLinkEmojiSubsup(size: DynamicTypeSize) async throws {
        var checked = 0
        var laterLines = 0
        for count in stride(from: 0, through: 16, by: 2) {
            for (markName, mark) in [("sub", Self.sub), ("sup", Self.sup)] {
                for emojiFirst in [false, true] {
                    let content = Self.laterLineContent(filler: count, mark: mark, emojiFirst: emojiFirst).joined(separator: ",")
                    let root = try await TK2Parity.fixture("later-\(count)-\(markName)-\(emojiFirst)", content: content)
                    let leader = TK2Parity.Fixture(name: root.name + "-leader", segments: root.segments, style: ListRowView.leaderStyle(theme: Self.theme))
                    let text = String(try #require(root.describableText).characters) as NSString
                    let emoji = text.range(of: "\u{1F9EA}").location
                    let script = text.range(of: "H2O").location + 1
                    for documentWidth in Self.documentWidths {
                        let width = Self.listWidth(documentWidth: documentWidth) - Self.markerWidth(size) - Self.theme.spacing
                        for fixture in [root, leader] {
                            let h = TK2Parity.heights(fixture, size: size, width: width)
                            checked += 1
                            #expect(abs(h.swiftUI - h.textKit2) <= Self.tolerance, "\(fixture.name) \(size) w=\(width): swiftUI=\(h.swiftUI) textKit2=\(h.textKit2)")
                        }
                        let lines = try TK2Parity.layout(leader, env: TK2Parity.Environment(size: size), width: width).lines
                        let line = { (offset: Int) in lines.firstIndex { NSLocationInRange(offset, $0.range) } }
                        if let index = line(emoji), index > 0, line(script) == index { laterLines += 1 }
                    }
                }
            }
        }
        // The case is real: the emoji and the raised or lowered run share a
        // line after the first.
        #expect(laterLines > 0, "\(size): no leader put the emoji and the sub/superscript on one later line")
        print("TK2 list parity later-line link+emoji+subsup \(size): \(checked) measurements, \(laterLines) with both on one later line")
    }

    // MARK: Fallbacks

    /// Text TextKit 2 cannot match stays on SwiftUI inside a list, with its
    /// eligible neighbours on TextKit 2: an atom, empty text (the leader of
    /// a whitespace-free empty item has no leaf; a hard break alone is
    /// empty), two trailing hard breaks before iOS 26, right-to-left
    /// layout, a list with a row holding a code block, host styling the
    /// row does not reproduce, and a theme with a raw SwiftUI font.
    @Test("fallback text in a list stays on SwiftUI; eligible neighbours stay on TextKit 2")
    func fallbacks() async throws {
        let mention = "{\"type\":\"mention\",\"attrs\":{\"id\":\"1\",\"text\":\"@sam\"}}"
        let fallbackList = Self.list("bulletList", [
            Self.item(Self.paragraph([Self.t("Plain neighbour before")])),
            Self.item(Self.paragraph([Self.t("Ping "), mention, Self.t(" about the atom")])),
            Self.item(Self.paragraph([Self.t("Plain neighbour after the atom")])),
            Self.item(Self.paragraph([Self.t("Two trailing breaks"), TK2Parity.hardBreak, TK2Parity.hardBreak])),
            Self.item(
                Self.paragraph([Self.t("Plain neighbour after the breaks")]),
                Self.list("bulletList", [Self.item(Self.paragraph([Self.t("Nested plain neighbour")]))]),
                Self.paragraph([Self.t("A paragraph with an atom, alone after the nested list "), mention])
            ),
            Self.item(Self.paragraph([TK2Parity.hardBreak])),
            Self.item(Self.paragraph([Self.t("Last plain neighbour")])),
        ])
        let json = "{\"version\":1,\"type\":\"doc\",\"content\":[\(fallbackList)]}"
        let blocks = try await Self.blocks(Data(json.utf8))
        let block = try #require(blocks.first)
        guard case .listRows(let rows) = block.kind else {
            Issue.record("not a list")
            return
        }
        var leaves: [String: Bool] = [:]
        TextKit2Scope.forEachLeaf(in: blocks) { leaf in
            if case .eligible = leaf.verdict { leaves[leaf.ownerID] = true } else { leaves[leaf.ownerID] = false }
        }
        try #require(rows.count == 9, "rows: \(rows.map(\.id))")
        #expect(leaves[rows[1].id] == false, "the atom leader falls back")
        // The continuation row after the nested list holds the atom
        // paragraph alone, so the row keeps the renderer and the leaf falls
        // back on its own.
        #expect(TextKit2Scope.rowKeepsRenderer(rows[6]) && rows[6].segments.isEmpty)
        #expect(leaves[try #require(rows[6].trailingBlocks.first).id] == false, "the atom paragraph falls back")
        if case .fallback(.empty) = TextKit2Eligibility.verdict(rows[7].segments) {} else {
            Issue.record("a hard break alone is empty: \(TextKit2Eligibility.verdict(rows[7].segments))")
        }
        #expect(leaves[rows[3].id] == TextKit2Eligibility.trailingBreaksMatchText, "two trailing breaks: eligible exactly on iOS 26+")
        for index in [0, 2, 4, 5, 8] { #expect(leaves[rows[index].id] == true, "plain neighbour \(rows[index].id)") }
        let eligible = Set(leaves.filter(\.value).keys)
        var verdicts: [String] = []
        TextKit2Scope.forEachLeaf(in: blocks) { verdicts.append("\($0.ownerID): \($0.verdict)") }
        print("TK2 list parity fallbacks: \(verdicts)")

        func textKit2Owners(_ view: some View, width: CGFloat) -> Set<String> {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 3_000))
            let host = UIHostingController(rootView: view.frame(width: width, alignment: .topLeading).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).ignoresSafeArea())
            host.safeAreaRegions = []
            window.rootViewController = host
            window.isHidden = false
            window.layoutIfNeeded()
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            return Set(TextKit2FallbackTests.rows(in: host.view).compactMap(\.ownerID))
        }
        let width = Self.listWidth(documentWidth: 375)
        for size in [DynamicTypeSize.large, .accessibility3] {
            let env = TK2Parity.Environment(size: size)
            #expect(textKit2Owners(Self.hostedList(block, arm: .textKit2, env: env, listWidth: width), width: width) == eligible, "\(size)")
            let a = Self.measure(Self.hostedList(block, arm: .swiftUI, env: env, listWidth: width), width: width).size.height
            let b = Self.measure(Self.hostedList(block, arm: .textKit2, env: env, listWidth: width), width: width).size.height
            #expect(abs(a - b) <= Self.tolerance, "\(size): swiftUI=\(a) textKit2=\(b)")
        }

        // Right to left, every list row keeps its text on SwiftUI
        // (`TextKit2Scope.listDirectionKeepsRenderer`).
        let rtl = TK2Parity.Environment(direction: .rightToLeft)
        #expect(textKit2Owners(Self.hostedList(block, arm: .textKit2, env: rtl, listWidth: width), width: width).isEmpty)

        // A list with a row holding a code block keeps every row on
        // SwiftUI; a text-only list beside it does not
        // (`TextKit2Scope.listKeepsRenderer`).
        let code = "{\"type\":\"codeBlock\",\"content\":[\(Self.t("let x = 1"))]}"
        let pair = "{\"version\":1,\"type\":\"doc\",\"content\":[\(Self.list("bulletList", [Self.item(Self.paragraph([Self.t("Plain item")])), Self.item(Self.paragraph([Self.t("Item with code")]), code)])),\(Self.list("bulletList", [Self.item(Self.paragraph([Self.t("Text-only list")]))]))]}"
        let pairBlocks = try await Self.blocks(Data(pair.utf8))
        try #require(pairBlocks.count == 2)
        var pairLeaves: [String] = []
        TextKit2Scope.forEachLeaf(in: pairBlocks) { pairLeaves.append($0.ownerID) }
        #expect(pairLeaves == ["0.1.0"], "leaves: \(pairLeaves)")
        #expect(textKit2Owners(Self.hostedList(pairBlocks[0], arm: .textKit2, env: TK2Parity.Environment(), listWidth: width), width: width).isEmpty)
        #expect(textKit2Owners(Self.hostedList(pairBlocks[1], arm: .textKit2, env: TK2Parity.Environment(), listWidth: width), width: width) == ["0.1.0"])

        // Host styling the row does not reproduce: every list leaf falls back.
        let styled = Self.hostedList(block, arm: .textKit2, env: TK2Parity.Environment(), listWidth: width).lineSpacing(6)
        #expect(textKit2Owners(styled, width: width).isEmpty)
        let cased = Self.hostedList(block, arm: .textKit2, env: TK2Parity.Environment(), listWidth: width).textCase(.uppercase)
        #expect(textKit2Owners(cased, width: width).isEmpty)

        // A raw-font theme: no run has a font spec, nothing is eligible.
        let rawTheme = ADFTheme(body: .custom("Georgia", size: 17))
        let rawBlock = try #require(try await Self.blocks(Data(json.utf8), theme: rawTheme).first)
        let raw = Self.hostedList(rawBlock, arm: .textKit2, env: TK2Parity.Environment(), listWidth: width, theme: rawTheme)
        #expect(textKit2Owners(raw, width: width).isEmpty)
        let rawA = Self.measure(Self.hostedList(rawBlock, arm: .swiftUI, env: TK2Parity.Environment(), listWidth: width, theme: rawTheme), width: width).size.height
        let rawB = Self.measure(raw, width: width).size.height
        #expect(abs(rawA - rawB) <= Self.tolerance, "raw-font theme: swiftUI=\(rawA) textKit2=\(rawB)")
    }
}
#endif
