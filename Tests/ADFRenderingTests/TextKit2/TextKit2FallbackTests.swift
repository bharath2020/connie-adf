#if canImport(UIKit)
import SwiftUI
import UIKit
import Testing
import ADFModel
import ADFPreparation
@testable import ADFRendering

/// What the TextKit 2 arm must NOT draw stays on SwiftUI's `Text`, so the
/// switch cannot move it: text with a link (`Text` lays it out with
/// TextKit 1, whose wrapping and line heights the row does not reproduce —
/// it measured 1 px to 22 pt off), two or more trailing hard breaks before
/// iOS 26, and inherited `Text` styling the row does not implement. Fixed
/// regression cases: each formerly measured mismatch, asserted as a
/// fallback, plus the document-level consequence the switch budget guards.
@Suite("TextKit 2 fallbacks", .serialized)
@MainActor
struct TextKit2FallbackTests {
    nonisolated static let width: CGFloat = 370
    /// The renderer switch's budget for a row's displacement (device pixels).
    nonisolated static let switchBudgetPixels: CGFloat = 2

    static func t(_ string: String, _ marks: String = "") -> String { TK2Parity.adfText(string, marks: marks) }
    static let link = "{\"type\":\"link\",\"attrs\":{\"href\":\"https://example.com\"}}"

    /// Linked text that measured off under TextKit 2 or TextKit 1.
    static func linkedFixtures() async throws -> [TK2Parity.Fixture] {
        let sup = "{\"type\":\"subsup\",\"attrs\":{\"type\":\"sup\"}}"
        let sub = "{\"type\":\"subsup\",\"attrs\":{\"type\":\"sub\"}}"
        let head = "actor batch table panel inline actor mark atlas anchor "
        let tail = "schema render raster fixture lazy glyph expand ledger glyph "
        return [
            // `text-dense` block 283, verbatim: TextKit 2 ends a line with the
            // emoji `Text` wraps (22 pt short at large); laid out by TextKit 1
            // it was still 1 px (AX3) to 4 px (AX5) taller than `Text`.
            try await TK2Parity.fixture("link-emoji-wrap", content: [
                t("stream mark glyph spline table token matrix atlas block ", "{\"type\":\"link\",\"attrs\":{\"href\":\"https://example.com/page/283\"}}"),
                t("scroll spline panel actor matrix spline document quartz theme cursor "),
                t("atlas chunk cursor render scroll buffer scroll stream \u{2764}\u{FE0F} "),
            ].joined(separator: ",")),
            try await TextKit2PixelParityTests.kitchenSinkParagraph(),
            try await TK2Parity.fixture("sup-linked", content: t(head) + "," + t(tail + tail + tail, sup + "," + link)),
            try await TK2Parity.fixture("sub-link-before", content: t(head, link) + "," + t(tail + tail + tail, sub) + "," + t(" " + head)),
        ]
    }

    static func twoTrailingBreaks() async throws -> [TK2Parity.Fixture] {
        [
            try await TK2Parity.fixture("two-trailing-hardbreaks", content: t("Short") + "," + TK2Parity.hardBreak + "," + TK2Parity.hardBreak),
            try await TK2Parity.fixture("h1-two-trailing-hardbreaks", kind: "heading", level: 1, content:
                t("Heading") + "," + TK2Parity.hardBreak + "," + TK2Parity.hardBreak),
        ]
    }

    /// Hosts `view` in a window at `width` and returns the TextKit 2 row
    /// views it created.
    static func rowViews(hosting view: some View) -> [TextKit2RowView] {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: Self.width, height: 2_000))
        let host = UIHostingController(rootView: view.frame(width: Self.width, alignment: .topLeading))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.isHidden = false
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        let rows = Self.rows(in: host.view)
        window.isHidden = true
        window.rootViewController = nil
        return rows
    }

    static func rows(in view: UIView) -> [TextKit2RowView] {
        var found: [TextKit2RowView] = []
        if let row = view as? TextKit2RowView { found.append(row) }
        for subview in view.subviews { found += rows(in: subview) }
        return found
    }

    @Test("text with a link stays on SwiftUI under .textKit2 and measures as Text does")
    func linkedTextFallsBack() async throws {
        let short = try await TK2Parity.fixture("short-link", content: Self.t("see ", Self.link) + "," + Self.t("plain"))
        for fixture in try await Self.linkedFixtures() + [short] {
            guard case .fallback(.link) = TextKit2Eligibility.verdict(fixture.segments) else {
                Issue.record("\(fixture.name) must fall back for its link")
                continue
            }
            for size in [DynamicTypeSize.large, .accessibility3, .accessibility5] {
                let h = TK2Parity.heights(fixture, size: size, width: Self.width)
                #expect(h.swiftUI == h.textKit2, "\(fixture.name) \(size): swiftUI=\(h.swiftUI) textKit2=\(h.textKit2)")
            }
            let rows = Self.rowViews(hosting: TK2Parity.hosted(fixture, arm: .textKit2, env: .init(size: .accessibility5)))
            #expect(rows.isEmpty, "\(fixture.name) created \(rows.count) TextKit 2 row(s)")
        }
    }

    @Test("two trailing hard breaks: exact on iOS 26, SwiftUI before it")
    func trailingBreaks() async throws {
        for fixture in try await Self.twoTrailingBreaks() {
            let verdict = TextKit2Eligibility.verdict(fixture.segments)
            if TextKit2Eligibility.trailingBreaksMatchText {
                guard case .eligible = verdict else {
                    Issue.record("\(fixture.name) must be eligible on iOS 26+")
                    continue
                }
            } else {
                guard case .fallback(.trailingBreaks) = verdict else {
                    Issue.record("\(fixture.name) must fall back before iOS 26")
                    continue
                }
            }
            for size in [DynamicTypeSize.large, .accessibility3, .accessibility5] {
                let h = TK2Parity.heights(fixture, size: size, width: Self.width)
                #expect(abs(h.swiftUI - h.textKit2) <= 0.01, "\(fixture.name) \(size): swiftUI=\(h.swiftUI) textKit2=\(h.textKit2)")
            }
        }
    }

    @Test("inherited Text styling the row does not reproduce keeps the row on SwiftUI")
    func environmentStylingFallsBack() async throws {
        typealias Leaf = TextKit2Leaf<EmptyView>
        #expect(Leaf.supportsEnvironment(lineSpacing: 0, textCase: nil, lineLimit: nil, minimumScaleFactor: 1, redactionReasons: []))
        #expect(!Leaf.supportsEnvironment(lineSpacing: 4, textCase: nil, lineLimit: nil, minimumScaleFactor: 1, redactionReasons: []))
        #expect(!Leaf.supportsEnvironment(lineSpacing: 0, textCase: .uppercase, lineLimit: nil, minimumScaleFactor: 1, redactionReasons: []))
        #expect(!Leaf.supportsEnvironment(lineSpacing: 0, textCase: nil, lineLimit: 2, minimumScaleFactor: 1, redactionReasons: []))
        #expect(!Leaf.supportsEnvironment(lineSpacing: 0, textCase: nil, lineLimit: nil, minimumScaleFactor: 0.5, redactionReasons: []))
        #expect(!Leaf.supportsEnvironment(lineSpacing: 0, textCase: nil, lineLimit: nil, minimumScaleFactor: 1, redactionReasons: .placeholder))

        let fixture = try await TK2Parity.plain("styled", TextKit2HeightParityTests.long)
        let plainRows = Self.rowViews(hosting: TK2Parity.hosted(fixture, arm: .textKit2, env: .init()))
        #expect(plainRows.count == 1, "an unstyled eligible paragraph is a TextKit 2 row")
        let styled = TK2Parity.hosted(fixture, arm: .textKit2, env: .init()).lineSpacing(6)
        #expect(Self.rowViews(hosting: styled).isEmpty, "line spacing must keep the paragraph on SwiftUI")

        func height(_ arm: ADFTextRenderer) -> CGFloat {
            let host = UIHostingController(rootView: TK2Parity.hosted(fixture, arm: arm, env: .init()).lineSpacing(6))
            host.safeAreaRegions = []
            return host.sizeThatFits(in: CGSize(width: Self.width, height: .greatestFiniteMagnitude)).height
        }
        #expect(height(.swiftUI) == height(.textKit2))
    }

    @Test("a heading below formerly mismatched rows does not move on a switch, either way", arguments: [DynamicTypeSize.accessibility3, .accessibility5])
    func headingBelowFallbacksStaysPut(size: DynamicTypeSize) async throws {
        let rows = try await Self.linkedFixtures() + (try await Self.twoTrailingBreaks())
        let heading = try await TK2Parity.heading(2, "Below the formerly mismatched rows")
        let box = TK2Parity.GuideBox()
        func document(_ arm: ADFTextRenderer) -> some View {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<(rows.count * 2), id: \.self) { index in
                    TK2Parity.hosted(rows[index % rows.count], arm: arm, env: .init(size: size))
                }
                TK2Parity.hosted(heading, arm: arm, env: .init(size: size))
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.frame(in: .global).minY
                    } action: { top in
                        box.first = top
                    }
            }
            .frame(width: Self.width, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea()
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: Self.width, height: 20_000))
        let host = UIHostingController(rootView: AnyView(document(.swiftUI)))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.isHidden = false
        func top(_ arm: ADFTextRenderer) -> CGFloat {
            host.rootView = AnyView(document(arm))
            window.layoutIfNeeded()
            host.view.layoutIfNeeded()
            return box.first
        }
        let off = top(.swiftUI)
        let on = top(.textKit2)
        let back = top(.swiftUI)
        window.isHidden = true
        window.rootViewController = nil
        let scale = TK2Parity.nativeScale
        #expect(off.isFinite && off > 0, "heading top not measured: \(off)")
        #expect(abs(on - off) * scale <= Self.switchBudgetPixels, "\(size) switch ON moved the heading \((on - off) * scale) px")
        #expect(abs(back - on) * scale <= Self.switchBudgetPixels, "\(size) switch OFF moved the heading \((back - on) * scale) px")
        print("TK2 fallback switch \(size): heading top OFF \(off) ON \(on) OFF \(back)")
    }

    @Test("a host text colour reaches TextKit 2 rows, including a change while ON")
    func hostForegroundReachesRows() async throws {
        let model = try await TextKit2DiagnosticsTests.loadedModel()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 1_600))
        func document(_ colour: Color?) -> ADFDocumentView {
            ADFDocumentView(model: model, mediaProvider: TextKit2DiagnosticsTests.NoMedia(), textRenderer: .textKit2, textForeground: colour)
        }
        let host = UIHostingController(rootView: document(.purple))
        window.rootViewController = host
        window.isHidden = false
        func foregrounds() async throws -> [Color?] {
            try await TextKit2DiagnosticsTests.settle(window)
            return Self.rows(in: host.view).map { $0.inputs?.inheritedForeground }
        }
        func drawn(_ row: TextKit2RowView) throws -> UIColor? {
            TextKit2TextBuilder.attributedString(for: try #require(row.inputs)).attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        }

        let purple = try await foregrounds()
        #expect(purple.count == 2 && purple.allSatisfy { $0 == .purple }, "\(purple)")
        if let row = Self.rows(in: host.view).first {
            #expect(try drawn(row)?.cgColor.components == UIColor(Color.purple).cgColor.components)
        }
        host.rootView = document(.orange)
        let orange = try await foregrounds()
        #expect(orange.count == 2 && orange.allSatisfy { $0 == .orange }, "\(orange)")
        host.rootView = document(nil)
        let inherited = try await foregrounds()
        #expect(inherited.count == 2 && inherited.allSatisfy { $0 == nil }, "\(inherited)")

        window.isHidden = true
        window.rootViewController = nil
    }
}
#endif
