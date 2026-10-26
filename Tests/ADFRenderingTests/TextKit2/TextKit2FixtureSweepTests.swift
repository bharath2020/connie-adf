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
/// (`TextKit2Eligibility`), so it never reaches this check.
@Suite("TextKit 2 fixture sweep", .serialized)
@MainActor
struct TextKit2FixtureSweepTests {
    nonisolated static let documents = ["kitchen-sink", "stress-5k", "text-dense"]
    nonisolated static let sizes: [DynamicTypeSize] = [.large, .accessibility3]
    nonisolated static let width: CGFloat = 370
    nonisolated static let tolerance: CGFloat = 0.01
    /// Eligible roots per document (default theme; the same on iOS 18 and
    /// 26 — no root ends in two hard breaks). Pinned so a regression that
    /// makes text ineligible cannot pass the sweep by measuring nothing.
    nonisolated static let expectedEligible = ["kitchen-sink": 9, "stress-5k": 1_893, "text-dense": 2_192]

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
}
#endif
