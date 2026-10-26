#if canImport(UIKit)
import SwiftUI
import UIKit
import Testing
import ADFPreparation
@testable import ADFRendering

/// The TextKit 2 arm must report exactly the height SwiftUI's `Text` does
/// for the same prepared block — any per-row drift (TextKit charging the
/// font leading on the last line is ≈1.67 pt for body) accumulates down a
/// document and shifts every scroll anchor (plan §4.5a).
@Suite("TextKit 2 height parity", .serialized)
@MainActor
struct TextKit2HeightParityTests {
    nonisolated static let sizes: [DynamicTypeSize] = [.xSmall, .large, .xxxLarge, .accessibility1, .accessibility3, .accessibility5]
    /// Phone column widths, a fractional width, and narrow iPad-column widths.
    nonisolated static let widths: [CGFloat] = [370, 640, 353.333, 320, 300.5]
    nonisolated static let tolerance: CGFloat = 0.01

    static let short = "Quarterly planning notes"
    static let medium = "The quick brown fox jumps over the lazy dog while seventeen purple elephants rehearse"
    static let long = "The quick brown fox jumps over the lazy dog while seventeen purple elephants quietly rehearse Beethoven near a shimmering river bank at dawn and then wander off toward the distant hills humming softly about breakfast"

    static func fixtures() async throws -> [TK2Parity.Fixture] {
        var fixtures: [TK2Parity.Fixture] = []
        for (label, string) in [("1", short), ("2", medium), ("3", long)] {
            fixtures.append(try await TK2Parity.plain("body-\(label)", string))
            for level in 1...6 {
                fixtures.append(try await TK2Parity.fixture("h\(level)-\(label)", kind: "heading", level: level, content: TK2Parity.adfText(string)))
            }
            fixtures.append(try await TK2Parity.fixture("mono-\(label)", content:
                TK2Parity.adfText("Call ") + "," + TK2Parity.adfText("prepare(document)", marks: "{\"type\":\"code\"}") + "," + TK2Parity.adfText(" before " + string)))
            fixtures.append(try await TK2Parity.fixture("subsup-\(label)", content:
                TK2Parity.adfText("H") + "," + TK2Parity.adfText("2", marks: "{\"type\":\"subsup\",\"attrs\":{\"type\":\"sub\"}}") + ","
                + TK2Parity.adfText("O and E=mc") + "," + TK2Parity.adfText("2", marks: "{\"type\":\"subsup\",\"attrs\":{\"type\":\"sup\"}}") + ","
                + TK2Parity.adfText(" " + string)))
        }
        fixtures.append(try await TK2Parity.fixture("bold-italic", content:
            TK2Parity.adfText("Mixed ", marks: "{\"type\":\"strong\"}") + "," + TK2Parity.adfText("emphasis ", marks: "{\"type\":\"em\"}") + "," + TK2Parity.adfText(medium)))
        fixtures.append(try await TK2Parity.fixture("small", content:
            TK2Parity.adfText("Fine print ", marks: "{\"type\":\"fontSize\",\"attrs\":{\"size\":\"small\"}}") + "," + TK2Parity.adfText(medium)))
        fixtures.append(try await TK2Parity.fixture("hardbreak", content:
            TK2Parity.adfText("First line") + "," + TK2Parity.hardBreak + "," + TK2Parity.adfText(medium)))
        fixtures.append(try await TK2Parity.fixture("centered", blockMarks: "{\"type\":\"alignment\",\"attrs\":{\"align\":\"center\"}}", content:
            TK2Parity.adfText(medium)))
        // `text-dense` block 283, verbatim: TextKit 2 ended a line with
        // the emoji that `Text` (TextKit 1, the text has a link) wraps —
        // one line (22 pt) short at large.
        fixtures.append(try await TK2Parity.fixture("link-emoji-wrap", content: [
            TK2Parity.adfText("stream mark glyph spline table token matrix atlas block ", marks: "{\"type\":\"link\",\"attrs\":{\"href\":\"https://example.com/page/283\"}}"),
            TK2Parity.adfText("scroll spline panel actor matrix spline document quartz theme cursor "),
            TK2Parity.adfText("atlas chunk cursor render scroll buffer scroll stream \u{2764}\u{FE0F} "),
        ].joined(separator: ",")))
        return fixtures + (try await subsupLineFixtures())
    }

    /// Sub/superscript runs long enough to wrap: lines set wholly in a
    /// raised or dropped run, first, middle and last, with and without
    /// colour, links and a highlight. `stress-5k` block 503 (verbatim) was
    /// 3.33 pt short at large and 24 pt at AX3: TextKit 2 lets a raised
    /// run's offset eat its descent, `Text` does not.
    static func subsupLineFixtures() async throws -> [TK2Parity.Fixture] {
        func t(_ string: String, _ marks: String = "") -> String { TK2Parity.adfText(string, marks: marks) }
        let sup = "{\"type\":\"subsup\",\"attrs\":{\"type\":\"sup\"}}"
        let sub = "{\"type\":\"subsup\",\"attrs\":{\"type\":\"sub\"}}"
        let color = "{\"attrs\":{\"color\":\"#36b37e\"},\"type\":\"textColor\"}"
        let link = "{\"type\":\"link\",\"attrs\":{\"href\":\"https://example.com\"}}"
        let highlight = "{\"type\":\"backgroundColor\",\"attrs\":{\"color\":\"#fedec8\"}}"
        let head = "actor batch table panel inline actor mark atlas anchor "
        let tail = "schema render raster fixture lazy glyph expand ledger glyph "
        var cases: [(String, String)] = [
            ("stress-5k-503", t(head) + "," + t(tail, color + "," + sup)),
        ]
        for (name, mark) in [("sup", sup), ("sub", sub)] {
            cases += [
                ("\(name)-last", t(head + head) + "," + t(tail + tail, mark)),
                ("\(name)-last-colour", t(head + head) + "," + t(tail + tail, color + "," + mark)),
                ("\(name)-first", t(tail + tail, mark) + "," + t(" " + head + head)),
                ("\(name)-middle", t(head) + "," + t(tail + tail + tail, mark) + "," + t(" " + head + head)),
                ("\(name)-middle-highlight", t(head) + "," + t(tail + tail + tail, mark + "," + highlight) + "," + t(" " + head)),
                ("\(name)-link-before", t(head, link) + "," + t(tail + tail + tail, mark) + "," + t(" " + head)),
                ("\(name)-linked", t(head) + "," + t(tail + tail + tail, mark + "," + link)),
                ("\(name)-then-break", t(head) + "," + t(tail + tail, mark) + "," + TK2Parity.hardBreak + "," + t(head)),
                ("\(name)-trailing-break", t(head) + "," + t(tail + tail, mark) + "," + TK2Parity.hardBreak),
            ]
        }
        var fixtures: [TK2Parity.Fixture] = []
        for (name, content) in cases {
            fixtures.append(try await TK2Parity.fixture(name, content: content))
        }
        return fixtures
    }

    @Test("every style × size × width measures identically on both arms")
    func heightsMatch() async throws {
        let fixtures = try await Self.fixtures()
        var worst: (delta: CGFloat, description: String) = (0, "")
        var checked = 0
        for fixture in fixtures {
            #expect(fixture.describableText != nil, "\(fixture.name) is not TextKit 2 eligible")
            for size in Self.sizes {
                for width in Self.widths {
                    let h = TK2Parity.heights(fixture, size: size, width: width)
                    let delta = abs(h.swiftUI - h.textKit2)
                    checked += 1
                    if delta > worst.delta {
                        worst = (delta, "\(fixture.name) \(size) w=\(width): swiftUI=\(h.swiftUI) textKit2=\(h.textKit2)")
                    }
                    let label = "\(fixture.name) \(size) w=\(width): swiftUI=\(h.swiftUI) textKit2=\(h.textKit2)"
                    if TextKit2FixtureSweepTests.isLinkEmojiResidual(fixture, swiftUI: h.swiftUI, textKit2: h.textKit2) {
                        withKnownIssue { #expect(delta <= Self.tolerance, "\(label)") }
                    } else {
                        #expect(delta <= Self.tolerance, "\(label)")
                    }
                }
            }
        }
        print("TK2 height parity: \(checked) measurements at scale \(TK2Parity.nativeScale), worst |Δ| = \(worst.delta) \(worst.description)")
    }

    @Test("heights match under right-to-left layout and the Bold Text setting")
    func heightsMatchAcrossLayoutInputs() async throws {
        let fixtures = try await Self.fixtures()
        let environments = [
            TK2Parity.Environment(size: .large, direction: .rightToLeft),
            TK2Parity.Environment(size: .accessibility3, direction: .rightToLeft),
            TK2Parity.Environment(size: .large, legibility: .bold),
            TK2Parity.Environment(size: .xxxLarge, legibility: .bold),
            TK2Parity.Environment(size: .accessibility5, direction: .rightToLeft, legibility: .bold),
        ]
        var checked = 0
        for fixture in fixtures {
            for env in environments {
                for width in [CGFloat(370), 300.5] {
                    let h = TK2Parity.heights(fixture, env: env, width: width)
                    checked += 1
                    let label = "\(fixture.name) \(env) w=\(width): swiftUI=\(h.swiftUI) textKit2=\(h.textKit2)"
                    if TextKit2FixtureSweepTests.isLinkEmojiResidual(fixture, swiftUI: h.swiftUI, textKit2: h.textKit2) {
                        withKnownIssue { #expect(abs(h.swiftUI - h.textKit2) <= Self.tolerance, "\(label)") }
                    } else {
                        #expect(abs(h.swiftUI - h.textKit2) <= Self.tolerance, "\(label)")
                    }
                }
            }
        }
        print("TK2 height parity (rtl / bold text): \(checked) measurements")
    }

    @Test("an empty paragraph stays on SwiftUI (nothing to draw) and keeps its height")
    func emptyParagraph() async throws {
        let fixture = try await TK2Parity.fixture("empty", content: "")
        #expect(fixture.describableText == nil)
        for size in Self.sizes {
            let h = TK2Parity.heights(fixture, size: size, width: 370)
            #expect(abs(h.swiftUI - h.textKit2) <= Self.tolerance, "\(size): swiftUI=\(h.swiftUI) textKit2=\(h.textKit2)")
        }
    }

    @Test("stacked rows do not drift: 20 rows sum to the same height")
    func noCumulativeDrift() async throws {
        let body = try await TK2Parity.plain("drift", Self.medium)
        let heading = try await TK2Parity.heading(2, Self.medium)
        for size in [DynamicTypeSize.large, .xxxLarge, .accessibility3, .accessibility5] {
            var swiftUI: CGFloat = 0
            var textKit2: CGFloat = 0
            for index in 0..<20 {
                let h = TK2Parity.heights(index.isMultiple(of: 3) ? heading : body, size: size, width: 353.333)
                swiftUI += h.swiftUI
                textKit2 += h.textKit2
            }
            #expect(abs(swiftUI - textKit2) <= Self.tolerance, "\(size): 20 rows swiftUI=\(swiftUI) textKit2=\(textKit2)")
        }
    }

    @Test("atom-bearing paragraphs stay on the SwiftUI path under .textKit2")
    func atomsFallBack() async throws {
        let fixture = try await TK2Parity.fixture("mention", content:
            TK2Parity.adfText("Ping ") + ",{\"type\":\"mention\",\"attrs\":{\"id\":\"1\",\"text\":\"@sam\"}}," + TK2Parity.adfText(" about " + Self.medium))
        #expect(fixture.describableText == nil)
        let h = TK2Parity.heights(fixture, size: .large, width: 370)
        #expect(h.swiftUI == h.textKit2)
    }
}
#endif
