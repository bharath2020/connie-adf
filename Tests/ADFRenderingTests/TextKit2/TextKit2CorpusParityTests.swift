#if canImport(UIKit)
import SwiftUI
import UIKit
import Testing
import ADFPreparation
@testable import ADFRendering

/// Corpus breadth (plan §4.5e): every case must measure the same height on
/// both arms and break into the same lines (per-line ink extents equal),
/// at a regular and an accessibility size, at whole and fractional widths.
@Suite("TextKit 2 corpus parity", .serialized)
@MainActor
struct TextKit2CorpusParityTests {
    nonisolated static let sizes: [DynamicTypeSize] = [.large, .accessibility2]
    nonisolated static let widths: [CGFloat] = [370, 353.333, 300.5]
    nonisolated static let tolerance: CGFloat = 0.01

    struct Case {
        let fixture: TK2Parity.Fixture
        var directions: [LayoutDirection] = [.leftToRight]
    }

    static func corpus() async throws -> [Case] {
        let medium = "The quick brown fox jumps over the lazy dog while seventeen purple elephants rehearse"
        func t(_ string: String, _ marks: String = "") -> String { TK2Parity.adfText(string, marks: marks) }
        var cases: [Case] = []
        for level in 1...6 {
            cases.append(Case(fixture: try await TK2Parity.heading(level, medium)))
        }
        cases.append(Case(fixture: try await TextKit2PixelParityTests.everyMark()))
        cases.append(Case(fixture: try await TK2Parity.fixture("trailing-hardbreak", content:
            t(medium) + "," + TK2Parity.hardBreak)))
        cases.append(Case(fixture: try await TK2Parity.fixture("two-trailing-hardbreaks", content:
            t("Short") + "," + TK2Parity.hardBreak + "," + TK2Parity.hardBreak)))
        cases.append(Case(fixture: try await TK2Parity.fixture("h1-trailing-hardbreak", kind: "heading", level: 1, content:
            t("Heading") + "," + TK2Parity.hardBreak)))
        cases.append(Case(fixture: try await TK2Parity.fixture("consecutive-hardbreaks", content:
            t("Before") + "," + TK2Parity.hardBreak + "," + TK2Parity.hardBreak + "," + TK2Parity.hardBreak + "," + t("after " + medium))))
        cases.append(Case(fixture: try await TK2Parity.plain("space-runs", "Columns    separated     by  runs   of        spaces and then " + medium)))
        cases.append(Case(fixture: try await TK2Parity.plain("nbsp", "Keep\u{00A0}these\u{00A0}words\u{00A0}together\u{00A0}on\u{00A0}one\u{00A0}line and let " + medium)))
        cases.append(Case(fixture: try await TK2Parity.plain("unbreakable",
            "See https://example.com/" + String(repeating: "averyveryverylongpathsegment", count: 6) + " for details")))
        cases.append(Case(fixture: try await TK2Parity.plain("emoji",
            "Family 👨‍👩‍👧‍👦 flags 🇯🇵🇺🇸🇮🇳 skin 👍🏽👋🏿 keycap 1️⃣ and " + medium + " 🎉🎉🎉")))
        cases.append(Case(fixture: try await TK2Parity.plain("combining",
            "Cafe\u{0301} na\u{0308}ive Zo\u{0308}e, Z\u{0335}a\u{0336}l\u{0337}g\u{0338}o, \u{0928}\u{092E}\u{0938}\u{094D}\u{0924}\u{0947} and " + medium)))
        cases.append(Case(fixture: try await TK2Parity.plain("arabic",
            "هذا نص عربي طويل يكفي ليلتف على عدة أسطر في العرض الضيق للتأكد من أن الأسطر تنكسر في نفس المواضع"),
            directions: [.leftToRight, .rightToLeft]))
        cases.append(Case(fixture: try await TK2Parity.plain("hebrew-mixed",
            "Release notes עבור גרסה 2.4 include TextKit 2 תמיכה מלאה and the parity harness בדיקות נוספות"),
            directions: [.leftToRight, .rightToLeft]))
        for level in [1, 2] {
            cases.append(Case(fixture: try await TK2Parity.fixture("indent-\(level)",
                blockMarks: "{\"type\":\"indentation\",\"attrs\":{\"level\":\(level)}}", content: t(medium + " " + medium))))
        }
        for align in ["center", "end"] {
            cases.append(Case(fixture: try await TK2Parity.fixture("align-\(align)",
                blockMarks: "{\"type\":\"alignment\",\"attrs\":{\"align\":\"\(align)\"}}", content: t(medium + " " + medium)),
                directions: [.leftToRight, .rightToLeft]))
        }
        return cases
    }

    /// Known residual: SwiftUI draws centred text into a pixel-aligned
    /// drawing layer that it sometimes outsets from the text frame by a
    /// fractional pixel (measured: 2.5 px a side for "align-center" at
    /// large, w=300.5 — layer 849 px around an 844 px frame), placing the
    /// glyphs 0.5 px left of the frame position TextKit (and SwiftUI in
    /// every other case) uses. Bitmaps are identical after that shift (sum
    /// of differences 0). The outset's rule is not known.
    /// Evidence: parity/align-center-offset/.
    static let knownOffsetCases: Set<String> = ["align-center large w=300.5", "align-center large rtl w=300.5"]

    @Test("every corpus case: equal heights and equal line breaks")
    func corpusMatches() async throws {
        var checked = 0
        for item in try await Self.corpus() {
            let fixture = item.fixture
            #expect(fixture.describableText != nil, "\(fixture.name) is not TextKit 2 eligible")
            for direction in item.directions {
                for size in Self.sizes {
                    let env = TK2Parity.Environment(size: size, direction: direction)
                    for width in Self.widths {
                        let h = TK2Parity.heights(fixture, env: env, width: width)
                        #expect(abs(h.swiftUI - h.textKit2) <= Self.tolerance, "\(fixture.name) \(env) w=\(width): swiftUI=\(h.swiftUI) textKit2=\(h.textKit2)")
                        let mismatches = try TK2Parity.lineBreakMismatches(fixture, env: env, width: width)
                        let label = "\(fixture.name) \(env) w=\(width)"
                        if Self.knownOffsetCases.contains(label) {
                            withKnownIssue("SwiftUI's fractional drawing-layer outset shifts centred glyphs 0.5 px") {
                                #expect(mismatches.isEmpty, "\(label):\n\(mismatches.joined(separator: "\n"))")
                            }
                        } else {
                            #expect(mismatches.isEmpty, "\(label):\n\(mismatches.joined(separator: "\n"))")
                        }
                        checked += 1
                    }
                }
            }
        }
        print("TK2 corpus parity: \(checked) case × direction × size × width checks")
    }

    @Test("an empty paragraph stays on SwiftUI")
    func emptyParagraph() async throws {
        let fixture = try await TK2Parity.fixture("empty", content: "")
        #expect(fixture.describableText == nil)
    }
}
#endif
