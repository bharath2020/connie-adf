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
