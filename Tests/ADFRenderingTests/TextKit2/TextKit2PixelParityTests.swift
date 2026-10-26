#if canImport(UIKit)
import SwiftUI
import UIKit
import Testing
import ADFPreparation
@testable import ADFRendering

/// Both arms rendered into bitmaps at the device's native scale (3x on the
/// iPhone 17 Pro, 2x on the iPhone SE run), light and dark (plan §4.5d).
/// The vertical ink profile (first/last ink row, per-row ink counts) must
/// match exactly — that pins baselines, line pitch, background fills,
/// underlines and strikes — and the fraction of pixels differing by more
/// than 24 in any channel must stay within 0.2 % over the ink band.
@Suite("TextKit 2 pixel parity", .serialized)
@MainActor
struct TextKit2PixelParityTests {
    nonisolated static let width: CGFloat = 370
    nonisolated static let sizes: [DynamicTypeSize] = [.large, .xxxLarge, .accessibility3]
    nonisolated static let maxDifferingFraction = 0.002

    static func everyMark() async throws -> TK2Parity.Fixture {
        func t(_ string: String, _ marks: String = "") -> String { TK2Parity.adfText(string, marks: marks) }
        let content = [
            t("Plain "),
            t("bold ", "{\"type\":\"strong\"}"),
            t("italic ", "{\"type\":\"em\"}"),
            t("code ", "{\"type\":\"code\"}"),
            t("strike ", "{\"type\":\"strike\"}"),
            t("underline ", "{\"type\":\"underline\"}"),
            t("link ", "{\"type\":\"link\",\"attrs\":{\"href\":\"https://example.com\"}}"),
            t("red ", "{\"type\":\"textColor\",\"attrs\":{\"color\":\"#ff5630\"}}"),
            t("highlight ", "{\"type\":\"backgroundColor\",\"attrs\":{\"color\":\"#fedec8\"}}"),
            t("small ", "{\"type\":\"fontSize\",\"attrs\":{\"size\":\"small\"}}"),
            t("H"),
            t("2", "{\"type\":\"subsup\",\"attrs\":{\"type\":\"sub\"}}"),
            t("O and E=mc"),
            t("2", "{\"type\":\"subsup\",\"attrs\":{\"type\":\"sup\"}}"),
            TK2Parity.hardBreak,
            t("after the break with more words to wrap the paragraph onto several lines at every size."),
        ].joined(separator: ",")
        return try await TK2Parity.fixture("every-mark", content: content)
    }

    static func h1() async throws -> TK2Parity.Fixture {
        try await TK2Parity.heading(1, "Release notes for the TextKit 2 reader port and its parity harness")
    }

    private func compare(_ fixture: TK2Parity.Fixture, env: TK2Parity.Environment) throws {
        let height = max(TK2Parity.height(fixture, arm: .swiftUI, env: env, width: Self.width) + 40, 200)
        let a = try TK2Parity.render(fixture, arm: .swiftUI, env: env, width: Self.width, height: height)
        let b = try TK2Parity.render(fixture, arm: .textKit2, env: env, width: Self.width, height: height)
        let pa = TK2Parity.inkProfile(a, dark: env.dark)
        let pb = TK2Parity.inkProfile(b, dark: env.dark)
        let label = "\(fixture.name) \(env) @\(a.scale)x"
        #expect(pa.firstInkRow != nil, "\(label): SwiftUI arm rendered no ink")
        #expect(pa.firstInkRow == pb.firstInkRow, "\(label): first ink row swiftUI=\(String(describing: pa.firstInkRow)) textKit2=\(String(describing: pb.firstInkRow))")
        #expect(pa.lastInkRow == pb.lastInkRow, "\(label): last ink row swiftUI=\(String(describing: pa.lastInkRow)) textKit2=\(String(describing: pb.lastInkRow))")
        #expect(pa.rowCounts == pb.rowCounts, "\(label): per-row ink counts differ\n\(TK2Parity.rowDifferences(pa, pb))")
        let first = min(pa.firstInkRow ?? 0, pb.firstInkRow ?? 0)
        let last = max(pa.lastInkRow ?? 0, pb.lastInkRow ?? 0)
        let diff = TK2Parity.differingFraction(a, b, rows: first...last)
        print("TK2 pixel parity \(label): ink rows \(first)...\(last), differing pixels \(diff.count)/\(diff.total) = \(String(format: "%.4f", diff.fraction * 100)) %")
        #expect(diff.fraction <= Self.maxDifferingFraction, "\(label): \(diff.count)/\(diff.total) pixels differ (\(diff.fraction * 100) %)")
    }

    @Test("H1 heading renders identically", arguments: sizes, [false, true])
    func headingPixels(size: DynamicTypeSize, dark: Bool) async throws {
        try compare(try await Self.h1(), env: TK2Parity.Environment(size: size, dark: dark))
    }

    @Test("a paragraph carrying every mark renders identically", arguments: sizes, [false, true])
    func everyMarkPixels(size: DynamicTypeSize, dark: Bool) async throws {
        try compare(try await Self.everyMark(), env: TK2Parity.Environment(size: size, dark: dark))
    }
}
#endif
