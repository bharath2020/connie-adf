#if canImport(UIKit)
import SwiftUI
import UIKit
import Testing
import ADFPreparation
@testable import ADFRendering

/// Line breaks must land on the same word on both arms (plan §4.5c). The
/// corpus is nearly-full lines: words are appended, then suffixes, until
/// SwiftUI's line count jumps, so every string's last word sits within a
/// few points of a break. For each string both arms are rendered and the
/// first/last ink column of every line band must match exactly — a word
/// moved across a break shifts an extent by a whole word, even when the
/// line count holds. Mismatches log TextKit's line text.
@Suite("TextKit 2 line-break parity", .serialized)
@MainActor
struct TextKit2LineBreakParityTests {
    static let latin = "The quick brown fox jumps over the lazy dog while seventeen purple elephants quietly rehearse Beethoven near a shimmering river bank at dawn and then wander off toward the distant hills humming softly about breakfast extraordinarily well illuminated manuscripts".split(separator: " ").map(String.init)
    static let suffixes = ["", "s", "es", "ed", "ing", "ings", "ingly", "ingful", "ingfully"]
    nonisolated static let sizes: [DynamicTypeSize] = [.large, .xxxLarge]
    nonisolated static let widths: [CGFloat] = [370, 640, 353.333]

    @Test("near-full Latin lines break on the same words", arguments: sizes, widths)
    func nearFullLines(size: DynamicTypeSize, width: CGFloat) async throws {
        let env = TK2Parity.Environment(size: size)
        var compared = 0
        var lines = 0
        var previousHeight: CGFloat?
        for n in 1...Self.latin.count {
            let base = Self.latin.prefix(n).joined(separator: " ")
            for suffix in Self.suffixes {
                let fixture = try await TK2Parity.plain("wrap", base + suffix)
                let height = TK2Parity.height(fixture, arm: .swiftUI, env: env, width: width)
                let mismatches = try TK2Parity.lineBreakMismatches(fixture, env: env, width: width)
                compared += 1
                lines += try TK2Parity.layout(fixture, env: env, width: width).lineCount
                #expect(mismatches.isEmpty, "\(env) w=\(width) '\(base.suffix(40))\(suffix)':\n\(mismatches.joined(separator: "\n"))")
                // Once a word has pushed a new line, longer suffixes only
                // pad the new line.
                defer { previousHeight = height }
                if let previousHeight, height > previousHeight { break }
            }
        }
        print("TK2 line-break parity \(env) w=\(width): \(compared) strings, \(lines) lines compared")
    }

    static let scripts: [(name: String, words: [String])] = [
        ("korean", "다람쥐 헌 쳇바퀴에 타고파 키스의 고유조건은 입술끼리 만나야 하고 특별한 기술은 필요치 않다 정말로 아름다운 하늘 아래에서 우리는 함께 노래를 부르며 걸어갔습니다".split(separator: " ").map(String.init)),
        ("japanese", "いろはにほへと ちりぬるを わかよたれそ つねならむ うゐのおくやま けふこえて あさきゆめみし ゑひもせす 吾輩は猫である 名前はまだ無い どこで生れたかとんと見当がつかぬ".split(separator: " ").map(String.init)),
        ("arabic", "الكتابة العربية جميلة جدا وهي تكتب من اليمين إلى اليسار وتستخدم في كثير من البلدان حول العالم منذ قرون طويلة".split(separator: " ").map(String.init)),
        ("accented", "Ünïcödé façade naïve café résumé coöperate Ångström jalapeño über straße déjà vu crème brûlée piñata señor año".split(separator: " ").map(String.init)),
    ]

    @Test("near-full lines in other scripts break on the same words", arguments: [DynamicTypeSize.large, .xxxLarge])
    func otherScripts(size: DynamicTypeSize) async throws {
        var compared = 0
        for script in Self.scripts {
            for direction in [LayoutDirection.leftToRight, .rightToLeft] {
                let env = TK2Parity.Environment(size: size, direction: direction)
                for width in [CGFloat(370), 353.333] {
                    for n in 2...script.words.count {
                        let fixture = try await TK2Parity.plain(script.name, script.words.prefix(n).joined(separator: " "))
                        let mismatches = try TK2Parity.lineBreakMismatches(fixture, env: env, width: width)
                        compared += 1
                        #expect(mismatches.isEmpty, "\(script.name) \(env) w=\(width) n=\(n):\n\(mismatches.joined(separator: "\n"))")
                    }
                }
            }
        }
        print("TK2 line-break parity (scripts) \(size): \(compared) strings")
    }
}
#endif
