#if canImport(UIKit)
import SwiftUI
import UIKit
import Testing
import ADFModel
import ADFPreparation
@testable import ADFRendering

/// Container leaves at widths a few ulps past the pixel grid (code review
/// F-R4: the container-leaf sweep's equal-height baseline shift, "D3").
///
/// A panel's child width carries its icon's measured width, so it is a sum
/// a few ulps off a pixel (225.66666666666669 at 3x). A paragraph whose
/// line fills it reports the next pixel (226), as `Text` does, and SwiftUI
/// places the row by proposing that width again. A row that laid out anew
/// there fitted a word more, came out a line shorter and was centred in
/// the slot measured first: its baselines a line low at an equal height.
/// The row now keeps the layout it reported
/// (`TextKit2RowView.layoutResult(forProposedWidth:)`). Each case is a
/// leaf the sweep found shifted before that, measured on both arms at the
/// widths its containers give it, comparing the height and the first and
/// last baselines within 0.01 pt (PR 1's one-pixel last-baseline residual
/// allowed, as the sweep allows it).
@Suite("TextKit 2 off-grid container widths", .serialized)
@MainActor
struct TextKit2OffGridWidthTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let document: String
        let owner: String
        let size: DynamicTypeSize
        /// The child width the sweep found shifted, as it prints it
        /// (`%.3f`): one of the document widths' child widths on 3x, or a
        /// fine-grid width (`d3FineWidths`) when `fineGrid`.
        let shiftedAt: String
        let fineGrid: Bool
        var testDescription: String { "\(document) \(owner) \(size) \(fineGrid ? "fine " : "")\(shiftedAt)" }
    }

    /// Real child widths (panels, from xSmall to xxLarge; sweep runs
    /// t-w7b and t-ed3a) and fine-grid widths (a column, quotes and a panel
    /// at Large; t-wfine1).
    nonisolated static let cases: [Case] = [
        Case(document: "stress-1k", owner: "0.566.0", size: .xLarge, shiftedAt: "322.667", fineGrid: false),
        Case(document: "stress-5k", owner: "0.1736.0", size: .xxLarge, shiftedAt: "225.667", fineGrid: false),
        Case(document: "stress-5k", owner: "0.2376.0", size: .xxLarge, shiftedAt: "294.667", fineGrid: false),
        Case(document: "stress-5k", owner: "0.2866.0", size: .xSmall, shiftedAt: "239.333", fineGrid: false),
        Case(document: "stress-5k", owner: "0.3286.0", size: .small, shiftedAt: "305.667", fineGrid: false),
        Case(document: "stress-5k", owner: "0.3656.0", size: .medium, shiftedAt: "301.667", fineGrid: false),
        Case(document: "containers-parity", owner: "0.54.0.0", size: .large, shiftedAt: "268.667", fineGrid: true),
        Case(document: "stress-1k", owner: "0.609.0", size: .large, shiftedAt: "273.667", fineGrid: true),
        Case(document: "stress-1k", owner: "0.866.0", size: .large, shiftedAt: "273.667", fineGrid: true),
        Case(document: "stress-5k", owner: "0.4209.0", size: .large, shiftedAt: "274.667", fineGrid: true),
    ]

    /// The TextKit 2 arm's guides at `width`, with each TextKit 2 row's
    /// placed bounds and how often it kept a reported layout
    /// (`TextKit2RowView.keptReportedLayoutCount`), read while the host is
    /// still in its window.
    static func textKit2Hosted(_ fixture: TK2Parity.Fixture, env: TK2Parity.Environment, width: CGFloat)
        -> (guides: (first: CGFloat, last: CGFloat, height: CGFloat), rows: [CGRect], kept: Int) {
        let box = TK2Parity.GuideBox()
        let root = VStack(alignment: .leading, spacing: 0) {
            TK2Parity.hosted(fixture, arm: .textKit2, env: env)
                .alignmentGuide(.leading) { dimensions in
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
        let views = TextKit2FallbackTests.rows(in: host.view)
        let rows = views.map { $0.convert($0.bounds, to: host.view) }
        let kept = views.reduce(0) { $0 + $1.keptReportedLayoutCount }
        window.isHidden = true
        window.rootViewController = nil
        return ((box.first, box.last, box.height), rows, kept)
    }

    @Test("a container leaf at a width a few ulps past a pixel sits as Text does when SwiftUI re-proposes the pixel it reported", arguments: cases)
    func offGridWidth(_ c: Case) async throws {
        let doc = try await ADFParser().parse(try TextKit2FixtureSweepTests.fixtureData(c.document))
        let blocks = DocumentPreparer(theme: TK2Parity.theme).prepare(doc)
        let entry = try #require(TextKit2FixtureSweepTests.containerChains(blocks)[c.owner], "\(c.owner): not a container leaf")
        let style = try #require(entry.style, "\(c.owner): a paragraph or heading")
        let env = TK2Parity.Environment(size: c.size)
        let widths: [CGFloat]
        if c.fineGrid {
            widths = [try #require(TextKit2FixtureSweepTests.d3FineWidths.first { String(format: "%.3f", $0) == c.shiftedAt })]
        } else {
            let inset = entry.chain.reduce(0) { $0 + $1.points(env) }
            widths = TextKit2FixtureSweepTests.containerDocumentWidths.map { $0 - 4 * TK2Parity.theme.spacing - inset }
        }
        let scale = TK2Parity.nativeScale
        let onePixel = 1 / scale
        let tolerance = TextKit2FixtureSweepTests.tolerance
        var reproposed = 0
        var keptAtShifted = 0
        for width in widths {
            let fixture = TK2Parity.Fixture(name: c.owner, segments: entry.segments, style: style)
            let swiftUI = TK2Parity.guides(fixture, arm: .swiftUI, env: env, width: width)
            let textKit2 = Self.textKit2Hosted(fixture, env: env, width: width)
            CATransaction.flush()
            let label = "\(c.testDescription) W=\(width) on \(scale)x: swiftUI=\(swiftUI) textKit2=\(textKit2.guides) rows=\(textKit2.rows)"
            let row = try #require(textKit2.rows.count == 1 ? textKit2.rows.first : nil, "\(label): one TextKit 2 row")
            // The row is proposed the leaf's width less its indentation.
            if row.width > width - fixture.indentation { reproposed += 1 }
            if String(format: "%.3f", width) == c.shiftedAt { keptAtShifted += textKit2.kept }
            var dLast = abs(swiftUI.last - textKit2.guides.last)
            if dLast > tolerance, abs(swiftUI.last - textKit2.guides.last - onePixel) <= tolerance { dLast = 0 }
            #expect(abs(swiftUI.height - textKit2.guides.height) <= tolerance, "\(label): height")
            #expect(abs(swiftUI.first - textKit2.guides.first) <= tolerance, "\(label): first baseline")
            #expect(dLast <= tolerance, "\(label): last baseline")
            #expect(abs(row.height - textKit2.guides.height) <= tolerance, "\(label): the row fills its slot")
            print("TK2_OFF_GRID \(label) kept=\(textKit2.kept)")
        }
        // Not vacuous: on 3x the width the sweep found shifted is off the
        // pixel grid and the row was placed one pixel wider than proposed.
        if scale == 3 {
            let shifted = try #require(widths.first { String(format: "%.3f", $0) == c.shiftedAt }, "\(c.testDescription): \(widths)")
            #expect(TextKit2RowView.proposalCeil(shifted, scale: scale) > shifted, "\(c.testDescription): \(shifted) is on the pixel grid")
            #expect(reproposed > 0, "\(c.testDescription): no row was re-proposed the pixel it reported")
            #expect(keptAtShifted > 0, "\(c.testDescription): the row did not keep its reported layout at \(shifted)")
        }
    }

    /// Delta review R1: text with a link is laid out and drawn by the
    /// row's TextKit 1 stack. Re-proposed the pixel it reported, the row
    /// keeps the layout (and the height) it reported, and the stack draws
    /// at the row's bounds, a fraction of a pixel wider, where a word more
    /// fits a line: a line or two fewer than the height holds. Measured,
    /// `Text` does exactly that (it draws linked text with TextKit 1 in a
    /// container as wide as its frame): its ink ends one or two line
    /// pitches above the last baseline it reports, and the row matches it
    /// pixel for pixel. Laying the stack out at the kept layout's width
    /// (the review's fix) draws the reported lines and differs from `Text`
    /// by 13,057 to 122,183 pixels at these widths (tk2fix log
    /// t-r3-r1fix-experiment); leaving linked rows out of the row fix
    /// reports a shorter height than `Text`. So a linked paragraph is
    /// hosted at widths an ulp past a pixel where its row reports the next
    /// pixel and a fresh layout there has another line count: both arms'
    /// guides match, and the rendered pixels pass PR 1's pixel rule (the
    /// same first and last ink rows and per-row ink counts, at most 0.2 %
    /// differing pixels). Guides alone cannot see the drawing.
    ///
    /// Delta review 2, R2: the same holds for centred and end-aligned
    /// text, and for where a link is hit. The stack aligns its lines in
    /// the bounds' width itself, so the row adds no alignment shift
    /// (`drawnShift`) to what it draws or to a link's rects
    /// (`segmentRects(for:)`), and both come from the one layout at the
    /// bounds' width. Each variant (`linkedVariants`) runs the comparison
    /// above; the three with a second link on the paragraph's last word,
    /// which sits on the last drawn line (a line or two above the last
    /// line of the layout a left-aligned row reported), also check the
    /// links' rects against the link-coloured pixels of both arms
    /// (`linkGeometryFailures`).
    ///
    /// Measured (17pro, iOS 26.3, 3x; pinR2 log t-r3): a centred or
    /// end-aligned linked row never reports the next pixel (0 of the 451
    /// off-grid widths from 200 to 350 pt, at Large and at xxLarge; a
    /// left-aligned one at 80 to 118 of the 118 to 173 scanned), so the
    /// row fix never fires for it and no kept layout is drawn. Its lines
    /// hug instead: it reports 0.333 to 3.667 pt less than it was
    /// proposed and is placed that narrow, from the layout measured at the
    /// proposal (`drawnShift` -0.167 to -3.667 pt). So such a row is
    /// hosted at 3 widths per size where it hugs: the stack draws at the
    /// narrower bounds, unshifted, exactly as `Text` (0 differing pixels
    /// in all 24 cases), and every link's ink lies in its rects (ink
    /// edges -0.78 to 2.46 px inside the rect's). Shifting the drawing or
    /// the rects by `drawnShift` would move them up to 11 px off `Text`'s.
    @Test("a linked (TextKit 1-backed) paragraph re-proposed the pixel it reported keeps its reported height and draws as Text draws it, pixel for pixel, left-aligned, centred and end-aligned, and its links are hit where they are drawn", arguments: linkedVariants)
    func linkedOffGridWidth(_ variant: LinkedVariant) async throws {
        let medium = "Ten tired otters cheer while a careful heron stares at the outer rim of the sunlit marsh in late autumn"
        var content = [
            TK2Parity.adfText(Self.leadingLink.text, marks: Self.linkMark(Self.leadingLink.url)),
            TK2Parity.adfText(" then " + medium + " and " + medium + " and " + medium + (variant.closingLink ? " and " : "")),
        ]
        var linkTexts = [Self.leadingLink]
        if variant.closingLink {
            content.append(TK2Parity.adfText(Self.closingLink.text, marks: Self.linkMark(Self.closingLink.url)))
            linkTexts.append(Self.closingLink)
        }
        let fixture = try await TK2Parity.fixture(
            "linked-off-grid-\(variant.name)",
            blockMarks: variant.align.map { "{\"type\":\"alignment\",\"attrs\":{\"align\":\"\($0)\"}}" },
            content: content.joined(separator: ","))
        let scale = TK2Parity.nativeScale
        let tolerance = TextKit2FixtureSweepTests.tolerance
        var compared = 0
        for size in [DynamicTypeSize.large, .xxLarge] {
            let env = TK2Parity.Environment(size: size)
            let inputs = try TK2Parity.inputs(fixture, env: env)
            // Widths hosted: up to 3 where the row reports the next pixel
            // and a fresh layout there has another line count (`found`),
            // and, for centred and end-aligned text, up to 3 more, 20 pt
            // apart, where it reports less than it was proposed (`hugged`).
            var found = 0
            var hugged = 0
            var lastHugged: CGFloat = 0
            var offGrid = 0
            var reportedPast = 0
            for pixels in Int(200 * scale)...Int(350 * scale) where variant.align != nil || found < 3 {
                let proposed = (CGFloat(pixels) / scale).nextUp
                let reported = TextKit2RowView.proposalCeil(proposed, scale: scale)
                guard reported > proposed else { continue }
                offGrid += 1
                let row = TextKit2RowView()
                row.apply(inputs)
                #expect(row.isTextKit1Backed)
                let first = row.layoutResult(forProposedWidth: proposed)
                let fresh = TextKit2RowView()
                fresh.apply(inputs)
                let freshLines = fresh.layoutResult(forProposedWidth: reported).lineCount
                let keeps = first.size.width == reported
                if keeps {
                    reportedPast += 1
                    guard found < 3, freshLines != first.lineCount else { continue }
                    found += 1
                } else {
                    guard variant.align != nil, hugged < 3, first.size.width < proposed, proposed - lastHugged >= 20 else { continue }
                    hugged += 1
                    lastHugged = proposed
                }
                let width = proposed + fixture.indentation
                let swiftUI = TK2Parity.guides(fixture, arm: .swiftUI, env: env, width: width)
                let textKit2 = Self.textKit2Hosted(fixture, env: env, width: width)
                CATransaction.flush()
                let label = "linked \(variant.name) \(size) W=\(width) on \(scale)x \(keeps ? "kept" : "hugged"): swiftUI=\(swiftUI) textKit2=\(textKit2.guides) rows=\(textKit2.rows) reported=\(first.size.width) lines=\(first.lineCount) fresh=\(freshLines)"
                if keeps {
                    #expect(textKit2.kept > 0, "\(label): the row was not re-proposed the pixel it reported")
                } else {
                    #expect(textKit2.kept == 0, "\(label): a row that reported less than its proposal kept a layout")
                    #expect((textKit2.rows.first?.width ?? .infinity) < proposed, "\(label): the row is not placed narrower than it was measured")
                }
                #expect(abs(swiftUI.height - textKit2.guides.height) <= tolerance, "\(label): height")
                #expect(abs(swiftUI.first - textKit2.guides.first) <= tolerance, "\(label): first baseline")
                #expect(abs(swiftUI.last - textKit2.guides.last) <= tolerance, "\(label): last baseline")
                let height = max(swiftUI.height + 40, 200)
                let a = try TK2Parity.render(fixture, arm: .swiftUI, env: env, width: width, height: height)
                let hosted = try Self.textKit2Rendered(fixture, env: env, width: width, height: height)
                defer { hosted.close() }
                let b = hosted.bitmap
                let pixelRule = TK2Caption.pixelFailures(a, b, dark: false)
                #expect(pixelRule.failures.isEmpty, "\(label): \(pixelRule.failures)")
                // Where the text ends against the last baseline both arms
                // report (pixel rows): a line fewer drawn ends a line up.
                let inkEnd = (TK2Parity.inkProfile(a, dark: false).lastInkRow ?? -1, TK2Parity.inkProfile(b, dark: false).lastInkRow ?? -1)
                // The row was placed at the pixel it reported and kept the
                // narrower layout there, as in the guides' host.
                #expect((hosted.row.keptReportedLayoutCount > 0) == keeps, "\(label): the rendered row kept \(hosted.row.keptReportedLayoutCount) reported layouts")
                let geometry = Self.linkGeometryFailures(hosted, swiftUI: a, links: linkTexts, text: NSString(string: String(inputs.text.characters)))
                #expect(geometry.failures.isEmpty, "\(label): \(geometry.failures.joined(separator: "; "))")
                print("TK2_OFF_GRID_LINKED \(label) kept=\(textKit2.kept) differing=\(pixelRule.differing)/\(pixelRule.total) failures=\(pixelRule.failures.count) lastInkRow=\(inkEnd.0)/\(inkEnd.1) lastBaselineRow=\(Int((swiftUI.last * scale).rounded())) bounds=\(hosted.row.bounds.width) drawn=\(hosted.row.drawn?.width ?? -1) shift=\(hosted.row.drawnShift) links: \(geometry.summary) linkFailures=\(geometry.failures.count)")
                compared += 1
            }
            print("TK2_OFF_GRID_LINKED_SCAN \(variant.name) \(size) on \(scale)x: offGridWidths=\(offGrid) reportedTheNextPixel=\(reportedPast) hosted kept=\(found) hugged=\(hugged)")
            // Not vacuous on 3x: some width's reported pixel fits a word
            // more (left-aligned), or the row was placed narrower than it
            // was measured (centred, end-aligned).
            if scale == 3 { #expect(found + hugged > 0, "\(variant.name) \(size): no linked width was hosted") }
            if scale == 3, variant.align == nil { #expect(found > 0, "\(variant.name) \(size): no linked width reported a pixel at which a fresh layout has another line count") }
        }
        if scale == 3 { #expect(compared > 0, "\(variant.name): nothing compared") }
    }

    struct LinkedVariant: Sendable, CustomTestStringConvertible {
        let name: String
        /// The paragraph's ADF alignment mark (`nil`: left-aligned).
        let align: String?
        /// Whether the paragraph's last word is a second link.
        let closingLink: Bool
        var testDescription: String { name }
    }

    /// The first is delta review R1's paragraph, unchanged.
    nonisolated static let linkedVariants: [LinkedVariant] = [
        LinkedVariant(name: "left", align: nil, closingLink: false),
        LinkedVariant(name: "left-closing-link", align: nil, closingLink: true),
        LinkedVariant(name: "centre", align: "center", closingLink: true),
        LinkedVariant(name: "end", align: "end", closingLink: true),
    ]

    nonisolated static let leadingLink = (text: "A linked phrase", url: "https://example.com")
    /// One word, so it never wraps and its rect ends at its last glyph.
    nonisolated static let closingLink = (text: "hereabouts", url: "https://example.com/closing")

    static func linkMark(_ url: String) -> String {
        "{\"type\":\"link\",\"attrs\":{\"href\":\"\(url)\"}}"
    }

    /// The TextKit 2 arm in a window (as `TK2Parity.render` hosts it), with
    /// its one row still placed: the bitmap and the row.
    @MainActor
    final class RenderedRow {
        let window: UIWindow
        let bitmap: TK2Parity.Bitmap
        let row: TextKit2RowView
        /// The row's origin in the window (and the bitmap), in points.
        let origin: CGPoint

        init(window: UIWindow, bitmap: TK2Parity.Bitmap, row: TextKit2RowView) {
            self.window = window
            self.bitmap = bitmap
            self.row = row
            origin = row.convert(CGPoint.zero, to: window)
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    static func textKit2Rendered(_ fixture: TK2Parity.Fixture, env: TK2Parity.Environment, width: CGFloat, height: CGFloat) throws -> RenderedRow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
        window.overrideUserInterfaceStyle = .light
        window.backgroundColor = .white
        let root = TK2Parity.hosted(fixture, arm: .textKit2, env: env)
            .frame(width: width, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea()
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        window.rootViewController = host
        window.isHidden = false
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        let rows = TextKit2FallbackTests.rows(in: host.view)
        guard rows.count == 1, let row = rows.first else {
            window.isHidden = true
            window.rootViewController = nil
            throw TestFailure("\(fixture.name): \(rows.count) TextKit 2 rows")
        }
        let bitmap = try TK2Parity.bitmap(of: window, width: width)
        return RenderedRow(window: window, bitmap: bitmap, row: row)
    }

    /// A pixel of link-coloured ink on white (the accent blue and its
    /// antialiased edge; body text is grey there, red equal to blue).
    static func isLinkInk(_ bitmap: TK2Parity.Bitmap, _ x: Int, _ y: Int) -> Bool {
        let p = bitmap[x, y]
        return p.b - p.r > 48
    }

    /// A link's rects against where it is drawn (delta review 2, R2). The
    /// row's rects for each link (`segmentRects(for:)`, what a tap is
    /// tested against) are compared with the link-coloured pixels of the
    /// row's own bitmap and of `Text`'s:
    /// - every link-coloured pixel lies in one of the rects, a pixel's
    ///   slack around each (a rect from another layout than the drawn one
    ///   leaves a link's ink outside: a line off, or a word along);
    /// - every rect holds link ink, whose first and last columns are no
    ///   more than a pixel outside the rect and no more than
    ///   `linkEdgeSlack` inside it (side bearings);
    /// - a tap at the centre of each rect's ink opens that link's URL.
    static func linkGeometryFailures(_ hosted: RenderedRow, swiftUI: TK2Parity.Bitmap, links: [(text: String, url: String)], text: NSString) -> (failures: [String], summary: String) {
        let scale = hosted.bitmap.scale
        var failures: [String] = []
        var summary: [String] = []
        var owners: [(pixels: (x: ClosedRange<Int>, y: ClosedRange<Int>), rect: CGRect, link: Int)] = []
        for (index, link) in links.enumerated() {
            let range = text.range(of: link.text)
            guard range.location != NSNotFound else {
                failures.append("'\(link.text)' is not in the row's text")
                continue
            }
            let rects = hosted.row.segmentRects(for: range)
            if rects.isEmpty { failures.append("'\(link.text)' has no rects") }
            for rect in rects {
                let placed = rect.offsetBy(dx: hosted.origin.x, dy: hosted.origin.y)
                let x = Int((placed.minX * scale).rounded(.down)) - 1...Int((placed.maxX * scale).rounded(.up))
                let y = Int((placed.minY * scale).rounded(.down)) - 1...Int((placed.maxY * scale).rounded(.up))
                owners.append(((x, y), rect, index))
            }
        }
        for (arm, bitmap) in [("Text", swiftUI), ("the row", hosted.bitmap)] {
            var outside = 0
            var firstOutside: (Int, Int)?
            var boxes: [(x: ClosedRange<Int>, y: ClosedRange<Int>)?] = Array(repeating: nil, count: owners.count)
            for y in 0..<bitmap.height {
                for x in 0..<bitmap.width where isLinkInk(bitmap, x, y) {
                    guard let owner = owners.firstIndex(where: { $0.pixels.x.contains(x) && $0.pixels.y.contains(y) }) else {
                        outside += 1
                        if firstOutside == nil { firstOutside = (x, y) }
                        continue
                    }
                    if let box = boxes[owner] {
                        boxes[owner] = (min(box.x.lowerBound, x)...max(box.x.upperBound, x), min(box.y.lowerBound, y)...max(box.y.upperBound, y))
                    } else {
                        boxes[owner] = (x...x, y...y)
                    }
                }
            }
            if outside > 0 {
                failures.append("\(arm): \(outside) link-coloured px outside every link rect, the first at \(firstOutside ?? (-1, -1)); rects (px) \(owners.map { "\($0.pixels.x) x \($0.pixels.y)" })")
            }
            for (owner, box) in zip(owners, boxes) {
                let name = "\(arm): '\(links[owner.link].text)' rect \(owner.rect)"
                guard let box else {
                    failures.append("\(name) holds no link-coloured px")
                    continue
                }
                let placed = owner.rect.offsetBy(dx: hosted.origin.x, dy: hosted.origin.y)
                let leading = CGFloat(box.x.lowerBound) - placed.minX * scale
                let trailing = placed.maxX * scale - CGFloat(box.x.upperBound + 1)
                let slack = linkEdgeSlack * scale
                if leading < -1 || leading > slack || trailing < -1 || trailing > slack {
                    failures.append("\(name): ink columns \(box.x) are \(leading) px and \(trailing) px inside the rect's edges (allowed -1...\(slack))")
                }
                summary.append("\(arm) '\(links[owner.link].text)' rect=\(owner.rect) ink=\(box.x)x\(box.y) edges=\(String(format: "%.2f/%.2f", leading, trailing))px")
                guard arm == "the row" else { continue }
                // The ink's centre, in the row's coordinates.
                let centre = CGPoint(
                    x: (CGFloat(box.x.lowerBound + box.x.upperBound + 1) / 2) / scale - hosted.origin.x,
                    y: (CGFloat(box.y.lowerBound + box.y.upperBound + 1) / 2) / scale - hosted.origin.y)
                let hit = hosted.row.link(at: centre)
                if hit?.absoluteString != links[owner.link].url {
                    failures.append("\(name): a tap at its ink's centre \(centre) hits \(hit?.absoluteString ?? "nothing")")
                }
            }
        }
        return (failures, summary.joined(separator: " | "))
    }

    /// How far inside a link rect's edge its first or last ink column may
    /// sit (points): a glyph's side bearing. Measured at most 0.82 pt
    /// (2.46 px on 3x).
    static let linkEdgeSlack: CGFloat = 1.5

    /// Delta review R6: a caption's row is a `.root` row too, outside
    /// `RichTextBlockView` (`MediaBlockView.caption`), so the row fix
    /// covers it. A wrapping caption under a media box in a panel takes
    /// the panel's child width, a few ulps past a pixel at some sizes. At
    /// every size containers keep TextKit 2 and every iPhone document
    /// width, the panel on both arms has the same height and baselines
    /// (PR 1's one-pixel last-baseline residual allowed) and passes PR 1's
    /// pixel rule over the whole panel. On 3x the caption must have been
    /// measured at an off-grid width in some case.
    ///
    /// Measured (17pro, iOS 26.3, 3x; tk2fix logs t-r4 and
    /// t-r5-caption-excluded): 80 cases, 48 with the caption at an off-grid
    /// width, 6 where the row kept a reported layout; with captions left
    /// out of the row fix the 80 results are the same, so the fix neither
    /// helps nor harms a caption here and its scope stays the owner kind.
    /// One case differed on both builds, in a guide only, while containers
    /// kept TextKit 2 up to AX3: at AX1 in a 320 pt document on 3x the
    /// panel's last baseline was 515.625 on SwiftUI's arm (off the pixel
    /// grid) and 515.167 on the row's, at an equal height and identical
    /// pixels. Its known-issue pin is removed (review N1): the test runs
    /// the sizes the container size rule keeps, and with the cut-off at
    /// xxxLarge (lead call C55) AX1 is not one, so the pin could never
    /// record. Every case is hard; if the cut-off moves past AX1 the case
    /// fails here and is decided then.
    @Test("a caption in a panel at an off-grid child width sits and draws as SwiftUI's does")
    func captionInPanelOffGridWidth() async throws {
        typealias C = TK2Caption
        let caption = "A caption under the image inside a panel, long enough to wrap onto several lines at every text size, so that one of its lines fills the width the panel gives it"
        let blocks = try await C.prepared([
            "{\"type\":\"panel\",\"attrs\":{\"panelType\":\"info\"},\"content\":[\(C.mediaNode(C.t(caption)))]}",
        ])
        let panel = try #require(blocks.first)
        guard case .panel(_, let children) = panel.kind, let child = children.first else {
            Issue.record("not a panel")
            return
        }
        let media = try C.media(child, name: "in-panel")
        let allowed: Set<TextKit2BlockKind> = [.richText, .panel, .media]
        let draws = TextKit2Scope.captionsUseTextKit2 && C.drawsRow(media.caption)
        let scale = TK2Parity.nativeScale
        let onePixel = 1 / scale
        var offGrid = 0
        var kept = 0
        var failures: [String] = []
        for size in DynamicTypeSize.allCases.filter(TextKit2Scope.containerSizeKeepsRenderer) {
            let env = TK2Parity.Environment(size: size)
            for documentWidth in TextKit2FixtureSweepTests.containerDocumentWidths {
                let width = documentWidth - 4 * TK2Parity.theme.spacing
                let a = C.Host(width: width)
                let b = C.Host(width: width)
                defer {
                    a.close()
                    b.close()
                }
                a.show(C.environment(BlockView(block: panel), arm: .swiftUI, env: env))
                b.show(C.environment(C.documentRow(panel, allowed: allowed), arm: .textKit2, env: env))
                try await a.settle()
                try await b.settle()
                let label = "\(size) W=\(width)"
                let rows = b.rows
                guard rows.count == (draws ? 1 : 0), a.rows.isEmpty else {
                    failures.append("\(label): TextKit 2 rows \(rows.map { $0.ownerID ?? "?" }), SwiftUI arm \(a.rows.count)")
                    continue
                }
                let measured = rows.first?.cachedWidths.filter { $0 < 100_000 } ?? []
                let off = measured.contains { TextKit2RowView.proposalCeil($0, scale: scale) > $0 }
                let rowKept = rows.first?.keptReportedLayoutCount ?? 0
                if off { offGrid += 1 }
                kept += rowKept
                let ga = a.guides, gb = b.guides
                var caseFailures: [String] = []
                if abs(ga.height - gb.height) > C.tolerance { caseFailures.append("height swiftUI=\(ga.height) textKit2=\(gb.height)") }
                if abs(ga.first - gb.first) > C.tolerance { caseFailures.append("first baseline swiftUI=\(ga.first) textKit2=\(gb.first)") }
                let lastDiffers = abs(ga.last - gb.last) > C.tolerance && abs(ga.last - gb.last - onePixel) > C.tolerance
                if lastDiffers {
                    caseFailures.append("last baseline swiftUI=\(ga.last) textKit2=\(gb.last)")
                }
                let height = (max(ga.height, gb.height) + 8).rounded(.up)
                let pixelRule = C.pixelFailures(try a.bitmap(height: height), try b.bitmap(height: height), dark: false)
                caseFailures += pixelRule.failures
                print("TK2_OFF_GRID_CAPTION \(label) on \(scale)x measured=\(measured) offGrid=\(off) kept=\(rowKept) h=\(ga.height)/\(gb.height) last=\(ga.last)/\(gb.last) differing=\(pixelRule.differing)/\(pixelRule.total) failures=\(caseFailures.count)")
                failures += caseFailures.map { "\(label) measured=\(measured) kept=\(rowKept): \($0)" }
            }
        }
        print("TK2_OFF_GRID_CAPTION_SUMMARY offGridCases=\(offGrid) kept=\(kept) failures=\(failures.count) draws=\(draws)")
        #expect(failures.isEmpty, "\(failures.prefix(6).joined(separator: "\n"))")
        // Not vacuous on 3x: the panel gave the caption an off-grid width.
        if scale == 3, draws { #expect(offGrid > 0, "no caption was measured at an off-grid width") }
    }

    /// The row fix's one case never arises on PR 1's corpus: every
    /// eligible top-level paragraph and heading of the root sweep's
    /// documents (`TextKit2FixtureSweepTests.documents`), laid out at each
    /// iPhone row width less its indentation (whole points), at five sizes,
    /// reports a width no wider than it was proposed, so nothing proposes
    /// it a reported overshoot, and re-proposing the reported width keeps
    /// nothing (`keptReportedLayoutCount` stays 0).
    @Test("the row fix never fires on PR 1's corpus at whole-point iPhone widths: no root reports past its proposal, and re-proposing its reported width keeps nothing")
    func neverFiresAtWholePointWidths() async throws {
        // The iPhone document widths' rows (`containerDocumentWidths` less
        // the document's margins): whole points, on every pixel grid.
        let rowWidths = TextKit2FixtureSweepTests.containerDocumentWidths.map { $0 - 4 * TK2Parity.theme.spacing }
        #expect(rowWidths.allSatisfy { $0 == $0.rounded() })
        var checked = 0
        var distinct: Set<String> = []
        for document in TextKit2FixtureSweepTests.documents {
            let doc = try await ADFParser().parse(try TextKit2FixtureSweepTests.fixtureData(document))
            let blocks = DocumentPreparer(theme: TK2Parity.theme).prepare(doc)
            for (index, block) in blocks.enumerated() {
                guard case .richText(let segments, let style) = block.kind,
                      case .eligible = TextKit2Eligibility.verdict(segments) else { continue }
                let fixture = TK2Parity.Fixture(name: "\(document)#\(index)", segments: segments, style: style)
                guard distinct.insert("\(fixture.describableText.map { String($0.characters) } ?? fixture.name) \(style)").inserted else { continue }
                for size in [DynamicTypeSize.xSmall, .large, .xxxLarge, .accessibility3, .accessibility5] {
                    let inputs = try TK2Parity.inputs(fixture, env: TK2Parity.Environment(size: size))
                    let view = TextKit2RowView()
                    view.apply(inputs)
                    for rowWidth in rowWidths {
                        let proposed = rowWidth - fixture.indentation
                        guard proposed > 0 else { continue }
                        let result = autoreleasepool { view.layoutResult(forProposedWidth: proposed) }
                        #expect(result.size.width <= proposed, "\(fixture.name) \(size) W=\(proposed): reported \(result.size.width)")
                        _ = view.layoutResult(forProposedWidth: result.size.width)
                        checked += 1
                    }
                    #expect(view.keptReportedLayoutCount == 0, "\(fixture.name) \(size): kept a reported layout")
                }
            }
        }
        print("TK2_OFF_GRID_CORPUS \(distinct.count) distinct roots, \(checked) whole-point proposals, scale \(TK2Parity.nativeScale)")
        #expect(checked > 0)
    }
}
#endif
