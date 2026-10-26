#if canImport(UIKit)
import SwiftUI
import UIKit
import Testing
import ADFModel
import ADFPreparation
@testable import ADFRendering

/// Every TextKit 2-eligible top-level block of the demo's documents must
/// measure on both arms exactly as `Text` does: the parity suites cover
/// the rules, this covers the content they did not think of (`stress-5k`
/// block 503, a superscript wrapping onto a line of its own, measured
/// 3.33 pt short at large and shifted every row below it on a renderer
/// switch).
@Suite("TextKit 2 fixture sweep", .serialized)
@MainActor
struct TextKit2FixtureSweepTests {
    nonisolated static let documents = ["kitchen-sink", "stress-5k", "text-dense"]
    nonisolated static let sizes: [DynamicTypeSize] = [.large, .accessibility3]
    nonisolated static let width: CGFloat = 370
    nonisolated static let tolerance: CGFloat = 0.01

    /// Known residual: text with a link and an emoji. `Text` lays such
    /// text out with TextKit 1, but its height is not quite TextKit 1's:
    /// TextKit 1's line fragments count the emoji font's metrics (at AX3,
    /// 38.100/9.650 pt against the system font's 38.086/9.648: +0.0135 pt
    /// per emoji line), `Text`'s apparently do not. Measured: exactly 1 px
    /// taller in 8 of 10,820 sweep measurements (3x, `text-dense`, AX3),
    /// 4 px (1.333 pt) for `link-emoji-wrap` at AX5; never shorter.
    static func isLinkEmojiResidual(_ fixture: TK2Parity.Fixture, swiftUI: CGFloat, textKit2: CGFloat) -> Bool {
        guard let text = fixture.describableText,
              textKit2 - swiftUI > tolerance, textKit2 - swiftUI <= 1.5 else { return false }
        let hasLink = text.runs.contains { $0.link != nil }
        let hasEmoji = String(text.characters).unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }
        return hasLink && hasEmoji
    }

    static func fixtureData(_ name: String) throws -> Data {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() } // …/Tests/ADFRenderingTests/TextKit2 → repo root
        return try Data(contentsOf: url.appendingPathComponent("Fixtures/\(name).json"))
    }

    @Test("every eligible root of the demo documents measures as Text does")
    func everyEligibleRoot() async throws {
        var checked = 0
        var worst: (delta: CGFloat, description: String) = (0, "")
        var residuals = 0
        for document in Self.documents {
            let doc = try await ADFParser().parse(try Self.fixtureData(document))
            let blocks = DocumentPreparer(theme: TK2Parity.theme).prepare(doc)
            for (index, block) in blocks.enumerated() {
                guard case .richText(let segments, let style) = block.kind else { continue }
                let fixture = TK2Parity.Fixture(name: "\(document)#\(index)", segments: segments, style: style)
                guard fixture.describableText != nil else { continue }
                for size in Self.sizes {
                    let h = TK2Parity.heights(fixture, size: size, width: Self.width)
                    let delta = abs(h.swiftUI - h.textKit2)
                    let label = "\(fixture.name) \(size)"
                    checked += 1
                    if delta > worst.delta { worst = (delta, "\(label): swiftUI=\(h.swiftUI) textKit2=\(h.textKit2)") }
                    if Self.isLinkEmojiResidual(fixture, swiftUI: h.swiftUI, textKit2: h.textKit2) {
                        residuals += 1
                        withKnownIssue { #expect(delta <= Self.tolerance, "\(label): swiftUI=\(h.swiftUI) textKit2=\(h.textKit2)") }
                    } else {
                        #expect(delta <= Self.tolerance, "\(label): swiftUI=\(h.swiftUI) textKit2=\(h.textKit2)")
                    }
                }
            }
        }
        print("TK2 fixture sweep: \(checked) measurements, \(residuals) known residuals, worst |Δ| = \(worst.delta) \(worst.description)")
    }
}
#endif
