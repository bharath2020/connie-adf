#if canImport(UIKit)
import SwiftUI
import UIKit
import Testing
import ADFModel
import ADFPreparation
@testable import ADFRendering

/// Every TextKit 2-eligible top-level block of the demo's documents must
/// measure on both arms exactly as `Text` does — no exemptions: the parity
/// suites cover the rules, this covers the content they did not think of
/// (`stress-5k` block 503, a superscript wrapping onto a line of its own,
/// measured 3.33 pt short at large and shifted every row below it on a
/// renderer switch). Content the arm cannot match exactly is not eligible
/// (`TextKit2Eligibility`), so it never reaches this check. List text (list
/// leaders and a list row's paragraphs) is swept the same way.
@Suite("TextKit 2 fixture sweep", .serialized)
@MainActor
struct TextKit2FixtureSweepTests {
    nonisolated static let documents = ["kitchen-sink", "stress-5k", "text-dense"]
    nonisolated static let sizes: [DynamicTypeSize] = [.large, .accessibility3]
    nonisolated static let width: CGFloat = 370
    nonisolated static let tolerance: CGFloat = 0.01
    /// Eligible roots per document (default theme; the same on iOS 18 and
    /// 26 — no root ends in two hard breaks), linked roots included: 1, 507
    /// and 808 of them are TextKit 1-backed. Pinned so a regression that
    /// makes text ineligible cannot pass the sweep by measuring nothing.
    nonisolated static let expectedEligible = ["kitchen-sink": 10, "stress-5k": 2_400, "text-dense": 3_000]

    static func fixtureData(_ name: String) throws -> Data {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() } // …/Tests/ADFRenderingTests/TextKit2 → repo root
        return try Data(contentsOf: url.appendingPathComponent("Fixtures/\(name).json"))
    }

    @Test("every eligible root of the demo documents measures as Text does")
    func everyEligibleRoot() async throws {
        var checked = 0
        var worst: (delta: CGFloat, description: String) = (0, "")
        var fallbacks: [TextKit2Eligibility.Fallback: Int] = [:]
        for document in Self.documents {
            let doc = try await ADFParser().parse(try Self.fixtureData(document))
            let blocks = DocumentPreparer(theme: TK2Parity.theme).prepare(doc)
            var eligible = 0
            for (index, block) in blocks.enumerated() {
                guard case .richText(let segments, let style) = block.kind else { continue }
                let fixture = TK2Parity.Fixture(name: "\(document)#\(index)", segments: segments, style: style)
                if case .fallback(let reason) = TextKit2Eligibility.verdict(segments) {
                    fallbacks[reason, default: 0] += 1
                    continue
                }
                eligible += 1
                for size in Self.sizes {
                    let h = TK2Parity.heights(fixture, size: size, width: Self.width)
                    let delta = abs(h.swiftUI - h.textKit2)
                    let label = "\(fixture.name) \(size)"
                    checked += 1
                    if delta > worst.delta { worst = (delta, "\(label): swiftUI=\(h.swiftUI) textKit2=\(h.textKit2)") }
                    #expect(delta <= Self.tolerance, "\(label): swiftUI=\(h.swiftUI) textKit2=\(h.textKit2)")
                }
            }
            #expect(eligible == Self.expectedEligible[document], "\(document): \(eligible) eligible roots")
        }
        #expect(checked == Self.expectedEligible.values.reduce(0, +) * Self.sizes.count)
        print("TK2 fixture sweep: \(checked) measurements, worst |Δ| = \(worst.delta) \(worst.description); text roots on SwiftUI: \(fallbacks)")
    }

    nonisolated static let listDocuments = ["kitchen-sink", "stress-5k", "lists-parity", "list-dense"]
    /// Eligible list leaves per document: leaders and a row's direct
    /// paragraphs and headings at any depth, in rows that keep the
    /// renderer (`TextKit2Scope`), linked ones included (0, 0, 3 and 586
    /// are TextKit 1-backed). Pinned so a walk that finds no list text, or
    /// text that all falls back, fails here rather than passing by
    /// measuring nothing.
    nonisolated static let expectedEligibleListLeaves = ["kitchen-sink": 8, "stress-5k": 7_543, "lists-parity": 40, "list-dense": 3_537]

    /// The leader as `ListRowView` hosts it, on one arm.
    static func leaderHeight(_ segments: [InlineSegment], arm: ADFTextRenderer, size: DynamicTypeSize, width: CGFloat) -> CGFloat {
        let leader = TextEngineLeaf(segments: segments, style: ListRowView.leaderStyle(theme: TK2Parity.theme), ownerID: nil) {
            SegmentedTextView(segments: segments).textSelection(.enabled)
        }
        let host = UIHostingController(rootView: leader
            .environment(\.adfTextRenderer, arm)
            .environment(\.adfTheme, TK2Parity.theme)
            .dynamicTypeSize(size))
        host.safeAreaRegions = []
        return host.sizeThatFits(in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)).height
    }

    /// The same leaf drawn as list text: a leader as the list row hosts it,
    /// a row's paragraph or heading as `RichTextBlockView`. Measured at the
    /// sweep width (the list's own column widths are the hosted list
    /// parity's), each distinct (text, style) once. From iOS 26: before it
    /// lists keep their text on SwiftUI (`TextKit2Eligibility.listsMatchText`).
    @Test("every eligible list leaf of the demo documents measures as Text does",
          .enabled(if: TextKit2Eligibility.listsMatchText, "before iOS 26 lists keep their text on SwiftUI"))
    func everyEligibleListLeaf() async throws {
        struct Key: Hashable {
            let segments: [InlineSegment]
            let style: TextBlockStyle?
        }
        var checked = 0
        var worst: (delta: CGFloat, description: String) = (0, "")
        var fallbacks: [TextKit2Eligibility.Fallback: Int] = [:]
        for document in Self.listDocuments {
            let doc = try await ADFParser().parse(try Self.fixtureData(document))
            let blocks = DocumentPreparer(theme: TK2Parity.theme).prepare(doc)
            var leaves: [TextKit2Scope.Leaf] = []
            TextKit2Scope.forEachLeaf(in: blocks) { leaf in
                if leaf.position != .root { leaves.append(leaf) }
            }
            var eligible = 0
            var measured: Set<Key> = []
            for leaf in leaves {
                if case .fallback(let reason) = leaf.verdict {
                    fallbacks[reason, default: 0] += 1
                    continue
                }
                eligible += 1
                guard measured.insert(Key(segments: leaf.segments, style: leaf.style)).inserted else { continue }
                for size in Self.sizes {
                    let h: (swiftUI: CGFloat, textKit2: CGFloat)
                    if let style = leaf.style {
                        h = TK2Parity.heights(TK2Parity.Fixture(name: leaf.ownerID, segments: leaf.segments, style: style), size: size, width: Self.width)
                    } else {
                        h = (Self.leaderHeight(leaf.segments, arm: .swiftUI, size: size, width: Self.width),
                             Self.leaderHeight(leaf.segments, arm: .textKit2, size: size, width: Self.width))
                    }
                    let delta = abs(h.swiftUI - h.textKit2)
                    let label = "\(document) \(leaf.ownerID) (\(leaf.position)) \(size): swiftUI=\(h.swiftUI) textKit2=\(h.textKit2)"
                    checked += 1
                    if delta > worst.delta { worst = (delta, label) }
                    #expect(delta <= Self.tolerance, "\(label)")
                }
            }
            #expect(eligible == Self.expectedEligibleListLeaves[document], "\(document): \(eligible) eligible list leaves")
            #expect(!measured.isEmpty, "\(document): no list leaf measured")
            print("TK2 list sweep \(document): \(eligible) eligible list leaves, \(measured.count) distinct measured")
        }
        #expect(checked > 0)
        print("TK2 list sweep: \(checked) measurements, worst |Δ| = \(worst.delta) \(worst.description); list text on SwiftUI: \(fallbacks)")
    }
}
#endif
