#if canImport(UIKit)
import SwiftUI
import UIKit
import Testing
import ADFModel
import ADFPreparation
@testable import ADFRendering

/// Layout passes container text costs on first materialisation (PR 4 plan
/// §5 step 3 item 3, the cost probe), modelled on `TextKit2ListLayoutTests`:
/// through the real document view, per container kind, the TextKit 2 rows'
/// layout passes divided by the number of leaves (`layoutsPerLeaf`). Issue
/// 10's signature is 2: a list row's `HStack` sizes its text column with a
/// natural-width probe before proposing the width left over, so every list
/// leaf lays out once unbounded and once at its column width, where a root
/// paragraph lays out once. A panel is an `HStack` too (its icon beside the
/// body), so it may repeat that; a quote and an extension body are stacks
/// with padding. The values are recorded per kind and pinned, so a change in
/// how a container measures its body is a measured decision.
/// From iOS 26: before it container text stays on SwiftUI
/// (`TextKit2Eligibility.containerTextMatchesText`), which the suite then
/// asserts instead.
@Suite("TextKit 2 container layouts", .serialized)
@MainActor
struct TextKit2ContainerLayoutTests {
    static let long = "Container text long enough to wrap onto a second and a third line at phone width, with a few more words after it"

    static func paragraph(_ text: String) -> String {
        "{\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"\(text)\"}]}"
    }

    /// Three paragraphs per container (one short, two long); the nested
    /// case is a quote holding a paragraph and a panel of two paragraphs.
    static let body = [paragraph("Short container text"), paragraph(long), paragraph(long + " again")]
    static let cases: [(kind: String, json: String)] = [
        ("root", body.joined(separator: ",")),
        ("panel", "{\"type\":\"panel\",\"attrs\":{\"panelType\":\"info\"},\"content\":[\(body.joined(separator: ","))]}"),
        ("quote", "{\"type\":\"blockquote\",\"content\":[\(body.joined(separator: ","))]}"),
        ("extension", "{\"type\":\"bodiedExtension\",\"attrs\":{\"extensionKey\":\"k\",\"extensionType\":\"com.example\"},\"content\":[\(body.joined(separator: ","))]}"),
        ("panelInQuote", "{\"type\":\"blockquote\",\"content\":[\(paragraph(long)),{\"type\":\"panel\",\"attrs\":{\"panelType\":\"note\"},\"content\":[\(paragraph(long)),\(paragraph("Short panel text"))]}]}"),
    ]

    /// Layout passes per leaf on first materialisation through the document
    /// view at 390 pt, measured on iOS 26.3 (iPhone 17 Pro 3x and iPhone SE
    /// 2x alike), and the number of widths each leaf was laid out at. The
    /// panel repeats issue 10's signature: its `HStack` (icon beside the
    /// body) probes every body leaf at an unbounded width before proposing
    /// the column (302.33 pt at 3x, 302 at 2x), so each panel leaf lays out twice. A
    /// quote and an extension body propose their inset width once, like a
    /// root paragraph. In `panelInQuote` the quote's own paragraph lays out
    /// once and the two panel paragraphs twice each (5 passes, 3 leaves).
    static let expected: [String: (perLeaf: Double, widths: Int)] = [
        "root": (1, 1),
        "panel": (2, 2),
        "quote": (1, 1),
        "extension": (1, 1),
        "panelInQuote": (5.0 / 3.0, 2),
    ]

    struct Row {
        let owner: String
        let layouts: Int
        let widths: [CGFloat]
    }

    @Test("layoutsPerLeaf: layout passes per container leaf on first materialisation, per container kind, against root paragraphs")
    func layoutsPerLeaf() async throws {
        var summary: [String] = []
        for (kind, content) in Self.cases {
            let json = "{\"version\":1,\"type\":\"doc\",\"content\":[\(content)]}"
            let model = try await TK2CodeLogic.loadedModel(Data(json.utf8))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 1_600))
            let host = UIHostingController(rootView: TK2CodeLogic.documentView(model, .textKit2))
            window.rootViewController = host
            window.isHidden = false
            try await TextKit2DiagnosticsTests.settle(window)
            TextKit2DiagnosticsTests.render(window) // drawing adds no layout
            let rows = TextKit2FallbackTests.rows(in: host.view).map {
                Row(owner: $0.ownerID ?? "?", layouts: $0.relayoutCount, widths: $0.cachedWidths.sorted())
            }.sorted { $0.owner < $1.owner }
            let containerRows = TextKit2FallbackTests.rows(in: host.view).filter { $0.containerContext == .container }.count
            window.isHidden = true
            window.rootViewController = nil

            let leaves = 3 // three paragraphs per case
            if !TextKit2Eligibility.containerTextMatchesText {
                // Before iOS 26 only the root paragraphs draw on TextKit 2.
                #expect(rows.count == (kind == "root" ? leaves : 0), "\(kind): \(rows.map(\.owner))")
                continue
            }
            #expect(rows.count == leaves, "\(kind): \(rows.map(\.owner))")
            #expect(containerRows == (kind == "root" ? 0 : leaves), "\(kind)")
            let layouts = rows.reduce(0) { $0 + $1.layouts }
            let perLeaf = Double(layouts) / Double(max(rows.count, 1))
            let widthCount = rows.map(\.widths.count).max() ?? 0
            let line = "CONTAINER_LAYOUTS kind=\(kind) os=\(TK2Parity.osVersion) scale=\(TK2Parity.nativeScale) leaves=\(rows.count) layouts=\(layouts) perLeaf=\(perLeaf) rows=" +
                rows.map { "\($0.owner):\($0.layouts)@\($0.widths.map { $0.isFinite ? String(format: "%.2f", $0) : "inf" }.joined(separator: "/"))" }.joined(separator: ",")
            print(line)
            summary.append("\(kind)=\(perLeaf)")
            let pinned = try #require(Self.expected[kind])
            #expect(perLeaf == pinned.perLeaf, "\(line)")
            #expect(widthCount == pinned.widths, "\(line)")
        }
        print("CONTAINER_LAYOUTS_SUMMARY os=\(TK2Parity.osVersion) scale=\(TK2Parity.nativeScale) \(summary.joined(separator: " "))")
    }

    /// Layout passes to measure the hosted block once (fresh rows), per
    /// proposal, as `TextKit2ListLayoutTests.measuring` counts them for a
    /// list: a phone column and the unspecified (natural) proposal.
    @Test("measuring: layout passes per proposal for each container kind")
    func measuring() async throws {
        var lines: [String] = []
        for (kind, content) in Self.cases where kind != "root" {
            let json = "{\"version\":1,\"type\":\"doc\",\"content\":[\(content)]}"
            let block = try #require(try await TK2CodeLogic.prepared(Data(json.utf8)).first)
            for (name, width) in [("phone", CGFloat(358)), ("unspecified", nil)] as [(String, CGFloat?)] {
                let view = BlockView(block: block)
                    .environment(\.adfTextRenderer, .textKit2)
                    .environment(\.adfTextWidthBound, .atLeast(width ?? 358))
                    .environment(\.adfTheme, TK2Parity.theme)
                let root = width == nil ? AnyView(view.fixedSize(horizontal: true, vertical: false)) : AnyView(view)
                let host = UIHostingController(rootView: root)
                host.safeAreaRegions = []
                let fitting = CGSize(width: width ?? 390, height: CGFloat.greatestFiniteMagnitude)
                let counted = TextKit2ListLayoutTests.counting { _ = host.sizeThatFits(in: fitting) }
                lines.append("\(kind)/\(name): conversions=\(counted.conversions) layouts=\(counted.layouts)")
                if TextKit2Eligibility.containerTextMatchesText {
                    #expect(counted.conversions == 3, "\(kind) \(name): \(counted)")
                    #expect(counted.layouts >= 3, "\(kind) \(name): \(counted)")
                } else {
                    #expect(counted.conversions == 0 && counted.layouts == 0, "\(kind) \(name): gated before iOS 26")
                }
            }
        }
        print("CONTAINER_MEASURING os=\(TK2Parity.osVersion) scale=\(TK2Parity.nativeScale) \(lines.joined(separator: "; "))")
    }
}
#endif
