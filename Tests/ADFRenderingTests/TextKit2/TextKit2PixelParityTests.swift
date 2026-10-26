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

    /// The demo's kitchen-sink paragraph, verbatim: its link sits on a line
    /// after one holding a subscript, whose baseline is fractional.
    static func kitchenSinkParagraph() async throws -> TK2Parity.Fixture {
        func t(_ string: String, _ marks: String = "") -> String { TK2Parity.adfText(string, marks: marks) }
        let content = [
            t("bold", "{\"type\":\"strong\"}"), t(" italic", "{\"type\":\"em\"}"),
            t(" underline", "{\"type\":\"underline\"}"), t(" strike", "{\"type\":\"strike\"}"),
            t(" let x = 1", "{\"type\":\"code\"}"), t(" H"),
            t("2", "{\"type\":\"subsup\",\"attrs\":{\"type\":\"sub\"}}"), t("O and x"),
            t("2", "{\"type\":\"subsup\",\"attrs\":{\"type\":\"sup\"}}"),
            t(" colored", "{\"type\":\"textColor\",\"attrs\":{\"color\":\"#ff5630\"}}"),
            t(" highlighted", "{\"type\":\"backgroundColor\",\"attrs\":{\"color\":\"#fedec8\"}}"),
            t(" small", "{\"type\":\"fontSize\",\"attrs\":{\"size\":\"small\"}}"),
            t(" a link", "{\"type\":\"link\",\"attrs\":{\"href\":\"https://example.com\",\"title\":\"Example\"}}"),
            t(" annotated", "{\"type\":\"annotation\",\"attrs\":{\"id\":\"anno-1\",\"annotationType\":\"inlineComment\"}}"),
            TK2Parity.hardBreak, t("after the break"),
        ].joined(separator: ",")
        return try await TK2Parity.fixture("kitchen-sink-paragraph", content: content)
    }

    /// A linked, struck paragraph wrapping below a subscript line: every
    /// later line has a fractional baseline.
    static func linkAfterSubscript() async throws -> TK2Parity.Fixture {
        let medium = "Ten tired otters cheer while a careful heron stares at the outer rim of the sunlit marsh in late autumn"
        return try await TK2Parity.fixture("link-after-subscript", content: [
            TK2Parity.adfText("H"),
            TK2Parity.adfText("2", marks: "{\"type\":\"subsup\",\"attrs\":{\"type\":\"sub\"}}"),
            TK2Parity.adfText("O " + medium + " " + medium, marks: "{\"type\":\"link\",\"attrs\":{\"href\":\"https://example.com\"}},{\"type\":\"strike\"}"),
        ].joined(separator: ","))
    }

    /// A centred, highlighted paragraph opening with a link: TextKit 1
    /// fills whole line fragments, extends line-ending whitespace to the
    /// frame's edge, and sizes the frame by its lines' used rects.
    static func centredHighlightAfterLink() async throws -> TK2Parity.Fixture {
        let medium = "The quick brown fox jumps over the lazy dog while seventeen purple elephants rehearse"
        return try await TK2Parity.fixture("centred-highlight-after-link", blockMarks: "{\"type\":\"alignment\",\"attrs\":{\"align\":\"center\"}}", content: [
            TK2Parity.adfText("go", marks: "{\"type\":\"link\",\"attrs\":{\"href\":\"https://example.com\"}}"),
            TK2Parity.adfText(" " + medium + " " + medium, marks: "{\"type\":\"backgroundColor\",\"attrs\":{\"color\":\"#fedec8\"}}"),
        ].joined(separator: ","))
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

    @Test("link decorations on lines with fractional baselines", arguments: sizes, [false, true])
    func fractionalBaselineLinkPixels(size: DynamicTypeSize, dark: Bool) async throws {
        let env = TK2Parity.Environment(size: size, dark: dark)
        try compare(try await Self.kitchenSinkParagraph(), env: env)
        try compare(try await Self.linkAfterSubscript(), env: env)
    }

    @Test("text with a link: backgrounds and frame as TextKit 1 draws them", arguments: sizes, [false, true])
    func linkTextBackgroundPixels(size: DynamicTypeSize, dark: Bool) async throws {
        try compare(try await Self.centredHighlightAfterLink(), env: TK2Parity.Environment(size: size, dark: dark))
    }

    @Test("a paragraph carrying every mark renders identically", arguments: sizes, [false, true])
    func everyMarkPixels(size: DynamicTypeSize, dark: Bool) async throws {
        try compare(try await Self.everyMark(), env: TK2Parity.Environment(size: size, dark: dark))
    }
}
#endif
