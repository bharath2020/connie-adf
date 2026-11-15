import Foundation
import SwiftUI
import Testing
import ADFModel
import ADFPreparation
@testable import ADFRendering

/// Why a code block's code stays on SwiftUI, by content (plan 3.5): the
/// verdict reads the first run's attributes and the prepared shape, in a
/// fixed order, and fails closed on anything that is not one shaped,
/// described, monospaced, plain run of printable ASCII and line feeds.
/// Cross-platform.
@Suite("TextKit 2 code fallbacks: content verdict")
struct TextKit2CodeVerdictTests {
    static let proportional = ADFFontSpec(textStyle: .body)
    static let boldMono = ADFFontSpec(textStyle: .body, bold: true, monospaced: true)

    static func reason(_ code: AttributedString) -> TextKit2Eligibility.Fallback? {
        TK2CodeLogic.reason(TextKit2Eligibility.codeVerdict(code))
    }

    static func linked(_ code: AttributedString) -> AttributedString {
        var code = code
        code.link = URL(string: "https://example.com")
        return code
    }

    static func raised(_ code: AttributedString) -> AttributedString {
        var code = code
        code[AttributeScopes.SwiftUIAttributes.BaselineOffsetAttribute.self] = 4
        return code
    }

    @Test("eligible code: one shaped monospaced run of printable ASCII and line feeds, handed back unmodified")
    func eligible() {
        let strings = ["x", "let x = 1", "let x = 1\nprint(x)", "a\n\nb", "  indented  ", "a\n", "\na", "{[(<~`|\\>)]} 0123456789"]
        for string in strings {
            let code = TK2CodeLogic.stamped(string)
            guard case .eligible(let text) = TextKit2Eligibility.codeVerdict(code) else {
                Issue.record("\(string.debugDescription) must be eligible: \(TextKit2Eligibility.codeVerdict(code))")
                continue
            }
            #expect(text == code, "\(string.debugDescription): the verdict must not modify the string")
        }
        // Any monospaced spec is eligible by content, not only the default.
        for spec in [Self.boldMono, ADFFontSpec(textStyle: .footnote, italic: true, monospaced: true)] {
            #expect(Self.reason(TK2CodeLogic.stamped("let x = 1", spec: spec)) == nil, "\(spec)")
        }
    }

    @Test("each content fallback reason")
    func eachReason() {
        typealias Fallback = TextKit2Eligibility.Fallback
        let twoRuns: AttributedString = TK2CodeLogic.stamped("ab") + TK2CodeLogic.stamped("cd", spec: Self.boldMono)
        let partlyShaped: AttributedString = TK2CodeLogic.stamped("ab") + TK2CodeLogic.stamped("cd", shape: nil)
        #expect(twoRuns.runs.count == 2 && partlyShaped.runs.count == 2)
        let cases: [(name: String, code: AttributedString, reason: Fallback)] = [
            // Nothing to draw.
            ("an empty string", AttributedString(), .empty),
            ("one line feed", TK2CodeLogic.stamped("\n"), .empty),
            ("line feeds only", TK2CodeLogic.stamped("\n\n\n"), .empty),
            ("CRLF only", TK2CodeLogic.stamped("\r\n"), .empty),
            // Fail closed: not one plain prepared run.
            ("no shape", TK2CodeLogic.stamped("let x = 1", shape: nil), .unshapedCode),
            ("two runs", twoRuns, .unshapedCode),
            ("a shape over part of the string", partlyShaped, .unshapedCode),
            ("a link", Self.linked(TK2CodeLogic.stamped("let x = 1")), .unshapedCode),
            ("a baseline offset", Self.raised(TK2CodeLogic.stamped("let x = 1")), .unshapedCode),
            // The font.
            ("no font spec (a raw theme font)", TK2CodeLogic.stamped("let x = 1", spec: nil), .undescribable),
            ("a proportional spec", TK2CodeLogic.stamped("let x = 1", spec: Self.proportional), .proportionalCode),
            ("a bold proportional spec", TK2CodeLogic.stamped("let x = 1", spec: ADFFontSpec(textStyle: .callout, bold: true)), .proportionalCode),
            // The characters.
            ("a tab", TK2CodeLogic.stamped("a\tb"), .codeTabs),
            ("a leading tab on a later line", TK2CodeLogic.stamped("all:\n\ttrue"), .codeTabs),
            ("CRLF", TK2CodeLogic.stamped("a\r\nb"), .codeLineBreaks),
            ("a lone CR", TK2CodeLogic.stamped("a\rb"), .codeLineBreaks),
            ("VT", TK2CodeLogic.stamped("a\u{0B}b"), .codeLineBreaks),
            ("FF", TK2CodeLogic.stamped("a\u{0C}b"), .codeLineBreaks),
            ("NEL", TK2CodeLogic.stamped("a\u{85}b"), .codeLineBreaks),
            ("U+2028", TK2CodeLogic.stamped("a\u{2028}b"), .codeLineBreaks),
            ("U+2029", TK2CodeLogic.stamped("a\u{2029}b"), .codeLineBreaks),
            ("an accented letter", TK2CodeLogic.stamped("caf\u{E9}"), .codeNonASCII),
            ("a combining mark", TK2CodeLogic.stamped("cafe\u{301}"), .codeNonASCII),
            ("an emoji", TK2CodeLogic.stamped("ok \u{1F600}"), .codeNonASCII),
            ("a CJK character", TK2CodeLogic.stamped("// \u{6F22}"), .codeNonASCII),
            ("NUL", TK2CodeLogic.stamped("a\u{0}b"), .codeControls),
            ("ESC", TK2CodeLogic.stamped("\u{1B}[0m"), .codeControls),
            ("DEL", TK2CodeLogic.stamped("a\u{7F}"), .codeControls),
        ]
        for item in cases {
            #expect(Self.reason(item.code) == item.reason, "\(item.name): \(TextKit2Eligibility.codeVerdict(item.code))")
            // What the engine leaf asks: no text to draw.
            #expect(TextKit2Eligibility.describableText(item.code, owner: .code) == nil, "\(item.name)")
        }
    }

    @Test("two or more trailing line feeds: eligible from iOS 26, a trailing-breaks fallback before it")
    func trailingLineFeeds() {
        let expected: TextKit2Eligibility.Fallback? = TextKit2Eligibility.trailingBreaksMatchText ? nil : .trailingBreaks
        #expect(Self.reason(TK2CodeLogic.stamped("x\n\n")) == expected)
        #expect(Self.reason(TK2CodeLogic.stamped("x\n\n\n")) == expected)
        #expect(Self.reason(TK2CodeLogic.stamped("a\nb\n\n")) == expected)
        // One trailing line feed is eligible on every OS.
        #expect(Self.reason(TK2CodeLogic.stamped("x\n")) == nil)
        // A break between other characters is not a trailing one.
        #expect(Self.reason(TK2CodeLogic.stamped("x\n\ny")) == nil)
    }

    @Test("the verdict order: empty, shape, newlines only, font spec, monospaced, plain run, characters, trailing breaks")
    func order() {
        // 1 before 2: an empty string has no run, so no shape to miss.
        #expect(Self.reason(AttributedString()) == .empty)
        #expect(Self.reason(AttributedString("")) == .empty)
        // 2 before 3: newline-only text without one shaped run is unshaped.
        #expect(Self.reason(TK2CodeLogic.stamped("\n", shape: nil)) == .unshapedCode)
        let twoNewlineRuns: AttributedString = TK2CodeLogic.stamped("\n") + TK2CodeLogic.stamped("\n\n")
        #expect(Self.reason(twoNewlineRuns) == .unshapedCode)
        // 2 before 4 and 5: the shape is checked before the font.
        #expect(Self.reason(TK2CodeLogic.stamped("x", spec: nil, shape: nil)) == .unshapedCode)
        #expect(Self.reason(TK2CodeLogic.stamped("x", spec: Self.proportional, shape: nil)) == .unshapedCode)
        // 3 before 4 and 5: newline-only text is empty whatever its font.
        #expect(Self.reason(TK2CodeLogic.stamped("\n", spec: nil)) == .empty)
        #expect(Self.reason(TK2CodeLogic.stamped("\n\n", spec: Self.proportional)) == .empty)
        // 4 and 5 before 6: the font before the link.
        #expect(Self.reason(Self.linked(TK2CodeLogic.stamped("x", spec: nil))) == .undescribable)
        #expect(Self.reason(Self.linked(TK2CodeLogic.stamped("x", spec: Self.proportional))) == .proportionalCode)
        // 4 and 5 before 7: the font before the characters.
        #expect(Self.reason(TK2CodeLogic.stamped("a\tb", spec: nil)) == .undescribable)
        #expect(Self.reason(TK2CodeLogic.stamped("a\tb", spec: Self.proportional)) == .proportionalCode)
        #expect(Self.reason(TK2CodeLogic.stamped("caf\u{E9}", spec: Self.proportional)) == .proportionalCode)
        // 6 before 7: a link or baseline offset before the characters.
        #expect(Self.reason(Self.linked(TK2CodeLogic.stamped("a\tb"))) == .unshapedCode)
        #expect(Self.reason(Self.raised(TK2CodeLogic.stamped("caf\u{E9}"))) == .unshapedCode)
        // Within 7: tabs, then other line breaks, then non-ASCII, then controls.
        #expect(Self.reason(TK2CodeLogic.stamped("\t\r\u{E9}\u{0}")) == .codeTabs)
        #expect(Self.reason(TK2CodeLogic.stamped("\r\u{E9}\u{0}")) == .codeLineBreaks)
        #expect(Self.reason(TK2CodeLogic.stamped("a\u{2028}")) == .codeLineBreaks)
        #expect(Self.reason(TK2CodeLogic.stamped("\u{E9}\u{0}")) == .codeNonASCII)
        #expect(Self.reason(TK2CodeLogic.stamped("\u{0}")) == .codeControls)
        // 7 before 8: the characters before the trailing breaks, on every OS.
        #expect(Self.reason(TK2CodeLogic.stamped("a\tb\n\n")) == .codeTabs)
        #expect(Self.reason(TK2CodeLogic.stamped("caf\u{E9}\n\n\n")) == .codeNonASCII)
        // 6 before 8.
        #expect(Self.reason(Self.linked(TK2CodeLogic.stamped("x\n\n"))) == .unshapedCode)
    }

    @Test("the verdict reads the prepared shape and never scans the characters")
    func readsTheShape() {
        // The shape is the only source of the character facts (a view body
        // runs the verdict on every pass, so it must be constant time): a
        // shape that says tabs keeps plain text out, and plain facts let any
        // text in. Only the preparer writes shapes, from the text itself
        // (`CodeFixturePreparationTests`).
        let plain = ADFCodeShape(lineCount: 1, maxLineUTF16: 3)
        #expect(Self.reason(TK2CodeLogic.stamped("a\tb", shape: plain)) == nil)
        let tabs = ADFCodeShape(lineCount: 1, maxLineUTF16: 3, isPrintableASCIIAndLF: false, hasTabs: true)
        #expect(Self.reason(TK2CodeLogic.stamped("abc", shape: tabs)) == .codeTabs)
        let unflagged = ADFCodeShape(lineCount: 1, maxLineUTF16: 3, isPrintableASCIIAndLF: false)
        #expect(Self.reason(TK2CodeLogic.stamped("abc", shape: unflagged)) == .codeControls)
        let newlines = ADFCodeShape(lineCount: 1, maxLineUTF16: 3, isAllNewlines: true)
        #expect(Self.reason(TK2CodeLogic.stamped("abc", shape: newlines)) == .empty)
    }

    /// Seven code blocks, `0.0` to `0.6`: plain, empty, one line feed, a
    /// tab, an accented letter, CRLF, two trailing line feeds.
    static func mixedDocument() throws -> Data {
        try TK2CodeLogic.document([
            TK2CodeLogic.code("let a = 1\nprint(a)"),
            TK2CodeLogic.code(""),
            TK2CodeLogic.code("\n"),
            TK2CodeLogic.code("a\tb"),
            TK2CodeLogic.code("caf\u{E9}"),
            TK2CodeLogic.code("a\r\nb"),
            TK2CodeLogic.code("x\n\n"),
        ])
    }

    static func reasons(_ blocks: [RenderBlock]) -> [String: TextKit2Eligibility.Fallback?] {
        var reasons: [String: TextKit2Eligibility.Fallback?] = [:]
        TextKit2Scope.forEachLeaf(in: blocks) { leaf in
            guard leaf.position == .codeRoot else { return }
            reasons.updateValue(TK2CodeLogic.reason(leaf.verdict), forKey: leaf.ownerID)
        }
        return reasons
    }

    @Test("through the real preparer: the default theme, a custom monospaced spec, a raw code font and a proportional spec")
    func preparedThemes() async throws {
        typealias Fallback = TextKit2Eligibility.Fallback
        let data = try Self.mixedDocument()
        let trailing: Fallback? = TextKit2Eligibility.trailingBreaksMatchText ? nil : .trailingBreaks
        let monospaced: [String: Fallback?] = [
            "0.0": nil, "0.1": .empty, "0.2": .empty, "0.3": .codeTabs, "0.4": .codeNonASCII,
            "0.5": .codeLineBreaks, "0.6": trailing,
        ]
        let eligible = trailing == nil ? 2 : 1

        let defaults = try await TK2CodeLogic.prepared(data)
        #expect(defaults.count == 7)
        #expect(Self.reasons(defaults) == monospaced)
        let coverage = ADFTextRenderer.textKit2Coverage(of: defaults)
        #expect(coverage.eligibleCodeRoots == eligible && coverage.fallbackCodeRoots == 7 - eligible)

        // A custom monospaced spec is described and monospaced: the same.
        let custom = ADFTheme(codeFontSpec: ADFFontSpec(textStyle: .footnote, bold: true, monospaced: true))
        let customBlocks = try await TK2CodeLogic.prepared(data, theme: custom)
        #expect(Self.reasons(customBlocks) == monospaced)

        // A raw code font: no spec, so nothing but empty code has another
        // reason.
        let raw = ADFTheme(code: .system(size: 13, design: .monospaced))
        #expect(raw.codeFontSpec == nil)
        let rawBlocks = try await TK2CodeLogic.prepared(data, theme: raw)
        let undescribable: [String: Fallback?] = [
            "0.0": .undescribable, "0.1": .empty, "0.2": .empty, "0.3": .undescribable, "0.4": .undescribable,
            "0.5": .undescribable, "0.6": .undescribable,
        ]
        #expect(Self.reasons(rawBlocks) == undescribable)
        let rawCoverage = ADFTextRenderer.textKit2Coverage(of: rawBlocks)
        #expect(rawCoverage.eligibleCodeRoots == 0 && rawCoverage.fallbackCodeRoots == 7)

        // A spec that is not monospaced.
        let proportional = ADFTheme(codeFontSpec: Self.proportional)
        let proportionalBlocks = try await TK2CodeLogic.prepared(data, theme: proportional)
        let notMonospaced: [String: Fallback?] = [
            "0.0": .proportionalCode, "0.1": .empty, "0.2": .empty, "0.3": .proportionalCode, "0.4": .proportionalCode,
            "0.5": .proportionalCode, "0.6": .proportionalCode,
        ]
        #expect(Self.reasons(proportionalBlocks) == notMonospaced)
        let proportionalCoverage = ADFTextRenderer.textKit2Coverage(of: proportionalBlocks)
        #expect(proportionalCoverage.eligibleCodeRoots == 0 && proportionalCoverage.fallbackCodeRoots == 7)
    }
}

/// The canvas bound's arithmetic (plan 3.5, advice finding 1), as pure
/// functions of a shape, two font metrics and a display scale:
///
///     pixelWidth  = ceil(maxLineUTF16 × advance × scale) + 2
///     pixelHeight = ceil(((lineCount + 2) × lineHeight + 2) × scale)
///     nominalBytes = pixelWidth × pixelHeight × 4
///
/// admitted while each dimension is at most 8,192 pixels and the bytes at
/// most 16 MiB. Cross-platform.
@Suite("TextKit 2 code fallbacks: canvas bound arithmetic")
struct TextKit2CodeCanvasBoundTests {
    static func shape(lines: Int, columns: Int) -> ADFCodeShape {
        ADFCodeShape(lineCount: lines, maxLineUTF16: columns)
    }

    static func estimate(_ shape: ADFCodeShape, _ advance: CGFloat, _ lineHeight: CGFloat, _ scale: CGFloat) -> TextKit2Scope.CodeCanvasBound? {
        TextKit2Scope.codeCanvasEstimate(shape, advance: advance, lineHeight: lineHeight, displayScale: scale)
    }

    static func bound(_ shape: ADFCodeShape, _ advance: CGFloat, _ lineHeight: CGFloat, _ scale: CGFloat) -> TextKit2Scope.CodeCanvasBound? {
        TextKit2Scope.codeCanvasBound(shape, advance: advance, lineHeight: lineHeight, displayScale: scale)
    }

    @Test("the caps and the reserves")
    func constants() {
        #expect(TextKit2Scope.maximumCodeCanvasDimension == 8_192)
        #expect(TextKit2Scope.maximumCodeCanvasBytes == 16_777_216)
        #expect(TextKit2Scope.codeCanvasInkReserveLines == 2)
        #expect(TextKit2Scope.codeCanvasRoundingReservePoints == 2)
        #expect(TextKit2Scope.codeCanvasWidthReservePixels == 2)
    }

    @Test("a worked example, and the formula recomputed over a grid of inputs")
    func arithmetic() throws {
        // 8 lines of at most 39 columns in a 10.24 pt wide, 20.29 pt tall
        // font at 3x: ceil(39 × 10.24 × 3) + 2 = 1,199 + 2;
        // ceil((10 × 20.29 + 2) × 3) = ceil(614.7).
        let shape = Self.shape(lines: 8, columns: 39)
        let example = try #require(Self.bound(shape, 10.24, 20.29, 3))
        #expect(example.pixelWidth == 1_201)
        #expect(example.pixelHeight == 615)
        #expect(example.nominalBytes == 2_954_460)
        #expect(example.isWithinCaps)
        // The inputs travel with the bound.
        #expect(example.maxLineUTF16 == 39 && example.lineCount == 8)
        #expect(example.advance == 10.24 && example.lineHeight == 20.29 && example.displayScale == 3)
        // An admitted bound is its estimate.
        #expect(Self.estimate(shape, 10.24, 20.29, 3) == example)

        let advances: [Double] = [6.02, 10.24, 14.5]
        let lineHeights: [Double] = [14.32, 20.29, 31]
        let scales: [Double] = [1, 2, 3]
        var checked = 0
        for columns in [1, 2, 39, 80, 120] {
            for lines in [1, 2, 8, 40] {
                for advance in advances {
                    for lineHeight in lineHeights {
                        for scale in scales {
                            let stated = try #require(Self.estimate(
                                Self.shape(lines: lines, columns: columns), CGFloat(advance), CGFloat(lineHeight), CGFloat(scale)
                            ))
                            let width = Int((Double(columns) * advance * scale).rounded(.up)) + 2
                            let points = (Double(lines) + 2) * lineHeight + 2
                            let height = Int((points * scale).rounded(.up))
                            let label = "\(columns)x\(lines) advance \(advance) line \(lineHeight) @\(scale)"
                            #expect(stated.pixelWidth == width, "\(label)")
                            #expect(stated.pixelHeight == height, "\(label)")
                            #expect(stated.nominalBytes == width * height * 4, "\(label)")
                            checked += 1
                        }
                    }
                }
            }
        }
        #expect(checked == 540)
    }

    @Test("width: exactly at the limit, one pixel over, one column over")
    func widthLimit() throws {
        // 273 columns × 10 pt × 3 = 8,190 px, plus the 2 px reserve: 8,192.
        let atLimit = try #require(Self.bound(Self.shape(lines: 1, columns: 273), 10, 20, 3))
        #expect(atLimit.pixelWidth == 8_192)
        #expect(atLimit.pixelHeight == 186)
        #expect(atLimit.nominalBytes == 6_094_848)

        // A thousandth of a point more advance: 8,190.819 px ceils to 8,191.
        #expect(Self.bound(Self.shape(lines: 1, columns: 273), 10.001, 20, 3) == nil)
        let onePixelOver = try #require(Self.estimate(Self.shape(lines: 1, columns: 273), 10.001, 20, 3))
        #expect(onePixelOver.pixelWidth == 8_193)
        #expect(!onePixelOver.isWithinCaps)

        // One more column.
        #expect(Self.bound(Self.shape(lines: 1, columns: 274), 10, 20, 3) == nil)
        let oneColumnOver = try #require(Self.estimate(Self.shape(lines: 1, columns: 274), 10, 20, 3))
        #expect(oneColumnOver.pixelWidth == 8_222)
        #expect(oneColumnOver.nominalBytes <= TextKit2Scope.maximumCodeCanvasBytes, "over by width alone")
    }

    @Test("height: exactly at the limit, one pixel over, one line over")
    func heightLimit() throws {
        // (176 + 2) lines × 23 pt + 2 pt = 4,096 pt, at 2x: 8,192 px.
        let atLimit = try #require(Self.bound(Self.shape(lines: 176, columns: 25), 10, 23, 2))
        #expect(atLimit.pixelHeight == 8_192)
        #expect(atLimit.pixelWidth == 502)
        #expect(atLimit.nominalBytes == 16_449_536)

        // A thousandth of a point more line height: 8,192.356 px ceils to 8,193.
        #expect(Self.bound(Self.shape(lines: 176, columns: 25), 10, 23.001, 2) == nil)
        let onePixelOver = try #require(Self.estimate(Self.shape(lines: 176, columns: 25), 10, 23.001, 2))
        #expect(onePixelOver.pixelHeight == 8_193)

        // One more line.
        #expect(Self.bound(Self.shape(lines: 177, columns: 25), 10, 23, 2) == nil)
        let oneLineOver = try #require(Self.estimate(Self.shape(lines: 177, columns: 25), 10, 23, 2))
        #expect(oneLineOver.pixelHeight == 8_238)
    }

    @Test("bytes: exactly 16 MiB, then one pixel, one column or one line more with both dimensions far under the limit")
    func byteLimit() throws {
        // 341 × 3 × 2 + 2 = 2,048 px wide; ((71 + 2) × 14 + 2) × 2 = 2,048 px tall.
        let atLimit = try #require(Self.bound(Self.shape(lines: 71, columns: 341), 3, 14, 2))
        #expect(atLimit.pixelWidth == 2_048 && atLimit.pixelHeight == 2_048)
        #expect(atLimit.nominalBytes == TextKit2Scope.maximumCodeCanvasBytes)

        #expect(Self.bound(Self.shape(lines: 71, columns: 341), 3.001, 14, 2) == nil)
        let onePixelWider = try #require(Self.estimate(Self.shape(lines: 71, columns: 341), 3.001, 14, 2))
        #expect(onePixelWider.pixelWidth == 2_049 && onePixelWider.pixelHeight == 2_048)
        #expect(onePixelWider.nominalBytes == 16_785_408)

        #expect(Self.bound(Self.shape(lines: 71, columns: 342), 3, 14, 2) == nil)
        let oneColumnMore = try #require(Self.estimate(Self.shape(lines: 71, columns: 342), 3, 14, 2))
        #expect(oneColumnMore.pixelWidth == 2_054 && oneColumnMore.nominalBytes == 16_826_368)

        #expect(Self.bound(Self.shape(lines: 72, columns: 341), 3, 14, 2) == nil)
        let oneLineMore = try #require(Self.estimate(Self.shape(lines: 72, columns: 341), 3, 14, 2))
        #expect(oneLineMore.pixelHeight == 2_076 && oneLineMore.nominalBytes == 17_006_592)
    }

    @Test("isWithinCaps: each cap is inclusive and checked by itself")
    func withinCaps() {
        func canvas(_ width: Int, _ height: Int, bytes: Int) -> TextKit2Scope.CodeCanvasBound {
            TextKit2Scope.CodeCanvasBound(
                maxLineUTF16: 1, lineCount: 1, advance: 1, lineHeight: 2, displayScale: 1,
                pixelWidth: width, pixelHeight: height, nominalBytes: bytes
            )
        }
        #expect(canvas(8_192, 1, bytes: 32_768).isWithinCaps)
        #expect(!canvas(8_193, 1, bytes: 32_772).isWithinCaps)
        #expect(canvas(1, 8_192, bytes: 32_768).isWithinCaps)
        #expect(!canvas(1, 8_193, bytes: 32_772).isWithinCaps)
        #expect(canvas(2_048, 2_048, bytes: 16_777_216).isWithinCaps)
        #expect(!canvas(2_048, 2_048, bytes: 16_777_217).isWithinCaps)
    }

    @Test("very wide and short, very narrow and tall")
    func extremeShapes() throws {
        // One line of 260 columns: 7,990 × 189 px.
        let wide = try #require(Self.bound(Self.shape(lines: 1, columns: 260), 10.24, 20.29, 3))
        #expect(wide.pixelWidth == 7_990 && wide.pixelHeight == 189)
        #expect(Self.bound(Self.shape(lines: 1, columns: 270), 10.24, 20.29, 3) == nil)
        // 132 lines of one column: 33 × 8,163 px.
        let tall = try #require(Self.bound(Self.shape(lines: 132, columns: 1), 10.24, 20.29, 3))
        #expect(tall.pixelWidth == 33 && tall.pixelHeight == 8_163)
        #expect(Self.bound(Self.shape(lines: 133, columns: 1), 10.24, 20.29, 3) == nil)
        // A lower display scale admits what a higher one refuses.
        #expect(Self.bound(Self.shape(lines: 1, columns: 270), 10.24, 20.29, 2) != nil)
        #expect(Self.bound(Self.shape(lines: 133, columns: 1), 10.24, 20.29, 2) != nil)
    }

    @Test("the bound never shrinks when the code, the font or the scale grows")
    func monotonic() throws {
        let base = try #require(Self.estimate(Self.shape(lines: 12, columns: 60), 10.24, 20.29, 2))
        let grown: [(String, TextKit2Scope.CodeCanvasBound?)] = [
            ("a column more", Self.estimate(Self.shape(lines: 12, columns: 61), 10.24, 20.29, 2)),
            ("a line more", Self.estimate(Self.shape(lines: 13, columns: 60), 10.24, 20.29, 2)),
            ("a wider advance", Self.estimate(Self.shape(lines: 12, columns: 60), 10.5, 20.29, 2)),
            ("a taller line", Self.estimate(Self.shape(lines: 12, columns: 60), 10.24, 20.5, 2)),
            ("a higher scale", Self.estimate(Self.shape(lines: 12, columns: 60), 10.24, 20.29, 3)),
        ]
        for (name, candidate) in grown {
            let larger = try #require(candidate, "\(name)")
            #expect(larger.pixelWidth >= base.pixelWidth && larger.pixelHeight >= base.pixelHeight, "\(name)")
            #expect(larger.nominalBytes > base.nominalBytes, "\(name)")
        }
        // Only the line count and the longest line matter: the trailing
        // newline count is already in the line count.
        #expect(Self.estimate(ADFCodeShape("ab\n"), 10.24, 20.29, 2) == Self.estimate(Self.shape(lines: 2, columns: 2), 10.24, 20.29, 2))
    }

    @Test("no bound for a non-finite or non-positive input, a line under two pixels, an empty shape or one outside the cohort")
    func rejectedInputs() {
        let shape = Self.shape(lines: 8, columns: 39)
        #expect(Self.estimate(shape, 10.24, 20.29, 3) != nil)
        let bad: [CGFloat] = [0, -1, -.infinity, .infinity, .nan, -.nan]
        for value in bad {
            #expect(Self.estimate(shape, value, 20.29, 3) == nil, "advance \(value)")
            #expect(Self.estimate(shape, 10.24, value, 3) == nil, "line height \(value)")
            #expect(Self.estimate(shape, 10.24, 20.29, value) == nil, "scale \(value)")
            #expect(Self.bound(shape, value, value, value) == nil, "all \(value)")
        }

        // A line must be at least two pixels tall (the rounding reserve's
        // premise).
        #expect(Self.estimate(shape, 10.24, 0.5, 3) == nil)
        #expect(Self.estimate(shape, 10.24, 0.999, 2) == nil)
        #expect(Self.estimate(shape, 10.24, 1, 2) != nil)
        #expect(Self.estimate(shape, 10.24, 0.5, 4) != nil)

        // Nothing on a line, or no line.
        #expect(Self.estimate(Self.shape(lines: 3, columns: 0), 10.24, 20.29, 3) == nil)
        #expect(Self.estimate(Self.shape(lines: 0, columns: 5), 10.24, 20.29, 3) == nil)
        #expect(Self.estimate(Self.shape(lines: -1, columns: 5), 10.24, 20.29, 3) == nil)
        #expect(Self.estimate(Self.shape(lines: 3, columns: -1), 10.24, 20.29, 3) == nil)
        #expect(Self.estimate(ADFCodeShape(""), 10.24, 20.29, 3) == nil)
        #expect(Self.estimate(ADFCodeShape("\n\n"), 10.24, 20.29, 3) == nil)

        // Outside the admitted cohort: anything but printable ASCII and LF.
        for text in ["a\tb", "caf\u{E9}", "a\r\nb", "a\u{0}b", "a\u{2028}b"] {
            #expect(Self.estimate(ADFCodeShape(text), 10.24, 20.29, 3) == nil, "\(text.debugDescription)")
            #expect(Self.bound(ADFCodeShape(text), 10.24, 20.29, 3) == nil, "\(text.debugDescription)")
        }
        let unprintable = ADFCodeShape(lineCount: 1, maxLineUTF16: 5, isPrintableASCIIAndLF: false)
        #expect(Self.estimate(unprintable, 10.24, 20.29, 3) == nil)
    }

    @Test("overflow-sized inputs give no bound instead of trapping; huge representable ones give an estimate over the caps")
    func overflow() throws {
        // Too large for an Int, or not finite, once multiplied.
        #expect(Self.estimate(Self.shape(lines: Int.max, columns: Int.max), 10.24, 20.29, 3) == nil)
        #expect(Self.estimate(Self.shape(lines: 1, columns: Int.max), 1, 2, 1) == nil)
        #expect(Self.estimate(Self.shape(lines: Int.max, columns: 1), 1, 2, 1) == nil)
        #expect(Self.estimate(Self.shape(lines: 8, columns: 39), 1e300, 20.29, 3) == nil)
        #expect(Self.estimate(Self.shape(lines: 8, columns: 39), 10.24, 1e300, 3) == nil)
        #expect(Self.estimate(Self.shape(lines: 8, columns: 39), 10.24, 20.29, 1e300) == nil)
        let largest = CGFloat.greatestFiniteMagnitude
        #expect(Self.estimate(Self.shape(lines: 8, columns: 39), largest, largest, largest) == nil)

        // One line, advance 1, line height 2, scale 1: the height is 8 px,
        // and a width of 2^n columns is exactly 2^n px (the 2 px reserve is
        // below the precision there). 2^60 × 8 overflows the area; 2^59 × 8
        // fits and × 4 overflows the bytes; 2^57 × 8 × 4 = 2^62 fits.
        #expect(Self.estimate(Self.shape(lines: 1, columns: 1 << 60), 1, 2, 1) == nil, "area overflow")
        #expect(Self.estimate(Self.shape(lines: 1, columns: 1 << 59), 1, 2, 1) == nil, "byte overflow")
        let huge = try #require(Self.estimate(Self.shape(lines: 1, columns: 1 << 57), 1, 2, 1))
        #expect(huge.pixelWidth == 1 << 57 && huge.pixelHeight == 8)
        #expect(huge.nominalBytes == 1 << 62)
        #expect(!huge.isWithinCaps)
        #expect(Self.bound(Self.shape(lines: 1, columns: 1 << 57), 1, 2, 1) == nil)

        // A million lines of a million columns: stated, and far over.
        let million = try #require(Self.estimate(Self.shape(lines: 1_000_000, columns: 1_000_000), 10, 20, 3))
        #expect(million.pixelWidth == 30_000_002 && million.pixelHeight == 60_000_126)
        #expect(million.nominalBytes == 7_200_015_600_001_008)
        #expect(!million.isWithinCaps)
        #expect(Self.bound(Self.shape(lines: 1_000_000, columns: 1_000_000), 10, 20, 3) == nil)
    }
}

#if canImport(UIKit)
import UIKit

/// The view-time side of the code fallbacks (plan 3.5, 3.6): the font
/// metrics the bound is stated in, the code gate (layout direction, then the
/// canvas bound at the current text size, weight and scale), the invariant
/// `actual canvas ≤ admitted bound ≤ limit` against rows really laid out,
/// and the real code view falling back and returning.
@Suite("TextKit 2 code fallbacks", .serialized)
@MainActor
struct TextKit2CodeFallbackTests {
    nonisolated static let monoSpecs: [ADFFontSpec] = [
        ADFFontSpec(textStyle: .body, monospaced: true),
        ADFFontSpec(textStyle: .body, bold: true, monospaced: true),
        ADFFontSpec(textStyle: .body, italic: true, monospaced: true),
        ADFFontSpec(textStyle: .footnote, monospaced: true),
        ADFFontSpec(textStyle: .title2, bold: true, italic: true, monospaced: true),
    ]

    nonisolated static let weights: [LegibilityWeight?] = [nil, .regular, .bold]

    static func fits(_ code: AttributedString, _ category: UIContentSizeCategory, weight: LegibilityWeight? = nil, scale: CGFloat) -> Bool {
        TextKit2Scope.codeFitsCanvas(code, sizeCategory: category, legibilityWeight: weight, displayScale: scale)
    }

    /// The code gate; `emptyLinesMatchText` is this runtime's answer unless
    /// a test passes the other OS's.
    static func gate(
        _ code: AttributedString, _ category: UIContentSizeCategory = .large, weight: LegibilityWeight? = nil,
        scale: CGFloat = 3, direction: LayoutDirection = .leftToRight,
        emptyLinesMatchText: Bool = TextKit2Scope.codeEmptyLinesMatchText
    ) -> TextKit2Scope.CodeGate? {
        TextKit2Scope.codeGate(
            code, sizeCategory: category, legibilityWeight: weight, displayScale: scale, layoutDirection: direction,
            emptyLinesMatchText: emptyLinesMatchText
        )
    }

    /// The longest one-line code the pure bound admits in a font with
    /// these metrics at `scale`.
    static func longestAdmittedLine(_ metrics: TextKit2Scope.CodeFontMetrics, scale: CGFloat) -> Int {
        var columns = 1
        while columns < 100_000, TextKit2Scope.codeCanvasBound(
            ADFCodeShape(lineCount: 1, maxLineUTF16: columns + 1),
            advance: metrics.advance, lineHeight: metrics.lineHeight, displayScale: scale
        ) != nil {
            columns += 1
        }
        return columns
    }

    /// The pixels a canvas of this many points takes at `scale` (a hair of
    /// floating-point noise absorbed).
    static func pixels(_ points: CGFloat, scale: CGFloat) -> Int {
        Int((points * scale - 0.000_001).rounded(.up))
    }

    // MARK: Font metrics

    @Test("every monospaced spec has fixed-pitch metrics at every text size and weight; a proportional spec has none")
    func metrics() {
        for spec in Self.monoSpecs {
            for category in TextKit2RowViewTests.categories {
                for weight in Self.weights {
                    let label = "\(spec) \(category.rawValue) \(String(describing: weight))"
                    guard let metrics = TextKit2CodeMetrics.metrics(for: spec, category: category, legibilityWeight: weight) else {
                        Issue.record("no metrics for \(label)")
                        continue
                    }
                    let font = TextKit2FontResolver.font(for: spec, category: category, legibilityWeight: weight)
                    #expect(metrics.advance.isFinite && metrics.advance > 0, "\(label)")
                    #expect(metrics.lineHeight.isFinite && metrics.lineHeight >= font.ascender - font.descender - 0.001, "\(label)")
                    // No printable ASCII glyph is wider than the advance.
                    for sample in ["0", "W", "i", " ", "~", "@", "_"] {
                        let width = (sample as NSString).size(withAttributes: [.font: font]).width
                        #expect(width <= metrics.advance + 0.01, "\(label): \(sample) is \(width) wide, advance \(metrics.advance)")
                    }
                    // Memoized: the same value again.
                    #expect(TextKit2CodeMetrics.metrics(for: spec, category: category, legibilityWeight: weight) == metrics, "\(label)")
                }
            }
        }
        // The default weight argument is no weight.
        #expect(TextKit2CodeMetrics.metrics(for: TK2CodeLogic.mono, category: .large)
            == TextKit2CodeMetrics.metrics(for: TK2CodeLogic.mono, category: .large, legibilityWeight: nil))

        let proportional = [
            ADFFontSpec(textStyle: .body), ADFFontSpec(textStyle: .body, bold: true), ADFFontSpec(textStyle: .title, italic: true),
        ]
        for spec in proportional {
            for category in TextKit2RowViewTests.categories {
                #expect(TextKit2CodeMetrics.metrics(for: spec, category: category) == nil, "\(spec) \(category.rawValue)")
            }
        }
    }

    @Test("the metrics grow with the text size, so the same code needs a larger canvas")
    func metricsGrowWithTextSize() throws {
        var previous: TextKit2Scope.CodeFontMetrics?
        for category in TextKit2RowViewTests.categories {
            let metrics = try #require(TextKit2CodeMetrics.metrics(for: TK2CodeLogic.mono, category: category))
            if let previous {
                #expect(metrics.advance >= previous.advance, "\(category.rawValue)")
                #expect(metrics.lineHeight >= previous.lineHeight, "\(category.rawValue)")
            }
            previous = metrics
        }
        let large = try #require(TextKit2CodeMetrics.metrics(for: TK2CodeLogic.mono, category: .large))
        let largest = try #require(TextKit2CodeMetrics.metrics(for: TK2CodeLogic.mono, category: .accessibilityExtraExtraExtraLarge))
        #expect(largest.advance > large.advance * 2 && largest.lineHeight > large.lineHeight * 2)
    }

    // MARK: The gate

    @Test("non-monospaced and custom specs: only a monospaced spec has a bound, whatever its style and traits")
    func specs() {
        let shape = ADFCodeShape(lineCount: 8, maxLineUTF16: 39)
        for spec in Self.monoSpecs {
            for weight in Self.weights {
                let bound = TextKit2Scope.codeCanvasBound(
                    shape, fontSpec: spec, sizeCategory: .large, legibilityWeight: weight, displayScale: 3
                )
                #expect(bound != nil, "\(spec) \(String(describing: weight))")
                #expect(bound?.isWithinCaps == true)
                #expect(bound?.maxLineUTF16 == 39 && bound?.lineCount == 8 && bound?.displayScale == 3)
                #expect(TextKit2Scope.codeFitsCanvas(
                    shape, fontSpec: spec, sizeCategory: .large, legibilityWeight: weight, displayScale: 3
                ))
                // The bound is stated in that spec's own metrics.
                let metrics = TextKit2CodeMetrics.metrics(for: spec, category: .large, legibilityWeight: weight)
                #expect(bound?.advance == metrics?.advance && bound?.lineHeight == metrics?.lineHeight)
            }
        }
        for spec in [ADFFontSpec(textStyle: .body), ADFFontSpec(textStyle: .body, bold: true), ADFFontSpec(textStyle: .caption)] {
            #expect(TextKit2Scope.codeCanvasBound(
                shape, fontSpec: spec, sizeCategory: .large, legibilityWeight: nil, displayScale: 3
            ) == nil, "\(spec)")
            #expect(!TextKit2Scope.codeFitsCanvas(
                shape, fontSpec: spec, sizeCategory: .large, legibilityWeight: nil, displayScale: 3
            ), "\(spec)")
        }
        // The string's own spec decides, read from its one run.
        let footnote = ADFFontSpec(textStyle: .footnote, monospaced: true)
        let small = TextKit2Scope.codeCanvasBound(
            TK2CodeLogic.stamped("let x = 1", spec: footnote), sizeCategory: .large, legibilityWeight: nil, displayScale: 3
        )
        let body = TextKit2Scope.codeCanvasBound(
            TK2CodeLogic.stamped("let x = 1"), sizeCategory: .large, legibilityWeight: nil, displayScale: 3
        )
        #expect(small != nil && body != nil)
        #expect((small?.pixelWidth ?? .max) < (body?.pixelWidth ?? 0), "a footnote-sized font needs a narrower canvas")
    }

    @Test("the canvas rules fail closed on code that is not one shaped, described, monospaced run")
    func failClosed() {
        let boldMono = ADFFontSpec(textStyle: .body, bold: true, monospaced: true)
        let refused: [(String, AttributedString)] = [
            ("no shape", TK2CodeLogic.stamped("let x = 1", shape: nil)),
            ("two runs", TK2CodeLogic.stamped("ab") + TK2CodeLogic.stamped("cd", spec: boldMono)),
            ("a shape over part of the string", TK2CodeLogic.stamped("ab") + TK2CodeLogic.stamped("cd", shape: nil)),
            ("no font spec", TK2CodeLogic.stamped("let x = 1", spec: nil)),
            ("a proportional spec", TK2CodeLogic.stamped("let x = 1", spec: ADFFontSpec(textStyle: .body))),
            ("an empty string", AttributedString()),
            ("line feeds only", TK2CodeLogic.stamped("\n\n")),
            ("a tab", TK2CodeLogic.stamped("a\tb")),
            ("an accented letter", TK2CodeLogic.stamped("caf\u{E9}")),
        ]
        for (name, code) in refused {
            #expect(TextKit2Scope.codeCanvasBound(code, sizeCategory: .large, legibilityWeight: nil, displayScale: 3) == nil, "\(name)")
            #expect(!Self.fits(code, .large, scale: 3), "\(name)")
            #expect(Self.gate(code) == .canvas, "\(name)")
        }
        // A plain block passes.
        #expect(Self.gate(TK2CodeLogic.stamped("let x = 1\nprint(x)")) == nil)
    }

    @Test("non-finite, non-positive and overflow-sized inputs are gated, never trapped on")
    func badEnvironment() async throws {
        let code = TK2CodeLogic.stamped("let x = 1\nprint(x)")
        let bad: [CGFloat] = [0, -3, .infinity, -.infinity, .nan, 0.000_001, 1e300]
        for scale in bad {
            #expect(TextKit2Scope.codeCanvasBound(code, sizeCategory: .large, legibilityWeight: nil, displayScale: scale) == nil, "scale \(scale)")
            #expect(!Self.fits(code, .large, scale: scale), "scale \(scale)")
            #expect(Self.gate(code, scale: scale) == .canvas, "scale \(scale)")
        }
        let oversized = [
            ADFCodeShape(lineCount: Int.max, maxLineUTF16: Int.max),
            ADFCodeShape(lineCount: 1, maxLineUTF16: Int.max),
            ADFCodeShape(lineCount: Int.max, maxLineUTF16: 1),
            ADFCodeShape(lineCount: 1 << 40, maxLineUTF16: 1 << 40),
            ADFCodeShape(lineCount: 0, maxLineUTF16: 0),
            ADFCodeShape(lineCount: -5, maxLineUTF16: -5),
        ]
        for shape in oversized {
            #expect(TextKit2Scope.codeCanvasBound(
                shape, fontSpec: TK2CodeLogic.mono, sizeCategory: .large, legibilityWeight: nil, displayScale: 3
            ) == nil, "\(shape)")
            // The gate reads the shape from the string, whatever it holds.
            #expect(Self.gate(TK2CodeLogic.stamped("x", shape: shape)) == .canvas, "\(shape)")
        }

        // The public measurement at such an environment: every eligible
        // block is gated, none admitted.
        let data = try TK2CodeLogic.document([TK2CodeLogic.code("let a = 1"), TK2CodeLogic.code("let b = 2")])
        let blocks = try await TK2CodeLogic.prepared(data)
        for scale in bad {
            let admission = ADFTextRenderer.textKit2CodeAdmission(
                of: blocks, dynamicTypeSize: .large, legibilityWeight: nil, displayScale: scale, layoutDirection: .leftToRight
            )
            #expect(admission.admittedCodeRoots == 0 && admission.gatedCodeRoots == 2, "scale \(scale)")
        }
    }

    @Test("right to left: the direction keeps code on SwiftUI and is judged before the canvas")
    func rightToLeft() async throws {
        #expect(TextKit2Scope.codeDirectionKeepsRenderer(.leftToRight))
        #expect(!TextKit2Scope.codeDirectionKeepsRenderer(.rightToLeft))
        let code = TK2CodeLogic.stamped("let x = 1\nprint(x)")
        let huge = TK2CodeLogic.stamped(String(repeating: "x", count: 5_000))
        #expect(Self.gate(code) == nil)
        #expect(Self.gate(code, direction: .rightToLeft) == .direction)
        #expect(Self.gate(huge) == .canvas)
        // Both rules refuse it: the direction is the answer.
        #expect(Self.gate(huge, direction: .rightToLeft) == .direction)
        #expect(Self.gate(TK2CodeLogic.stamped("x", shape: nil), direction: .rightToLeft) == .direction)

        let hosted = TK2CodeLogic.Hosted(TK2CodeLogic.codeView(code))
        defer { hosted.close() }
        try await hosted.settle()
        #expect(hosted.codeRows.count == 1)
        hosted.show(TK2CodeLogic.codeView(code, direction: .rightToLeft))
        try await hosted.settle()
        #expect(hosted.rows.isEmpty, "right to left, the code draws on SwiftUI")
        #expect(hosted.scrollViews.count == 1, "the code block is still there")
        hosted.show(TK2CodeLogic.codeView(code))
        try await hosted.settle()
        #expect(hosted.codeRows.count == 1)
    }

    // MARK: Interior empty lines before iOS 26

    /// Code with and without an interior empty line, every one within the
    /// canvas bound at AX5 and Bold Text on 2x and 3x.
    nonisolated static let emptyLineCodes: [(name: String, string: String, interior: Bool)] = [
        ("one interior empty line", "let a = 1\n\nlet b = 2", true),
        ("three interior empty lines", "let a = 1\n\n\n\nlet b = 2", true),
        ("two empty first lines (the second is interior)", "\n\nlet a = 1", true),
        ("an empty first line", "\nlet a = 1\nlet b = 2", false),
        ("one trailing line feed", "let a = 1\nlet b = 2\n", false),
        ("a line of spaces", "if ready {\n    \n    start(now)\n}", false),
        ("no empty line", "let a = 1\nlet b = 2", false),
    ]

    @Test("interior empty lines: on SwiftUI at AX4 and AX5 before iOS 26, admitted at every size from iOS 26; empty first and trailing lines never gated")
    func interiorEmptyLines() {
        #expect(TextKit2Scope.largestEmptyLinesCodeSizeBeforeiOS26 == .accessibilityExtraLarge)
        // The default answer is this runtime's OS.
        #expect(TextKit2Scope.codeEmptyLinesMatchText == (ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26))
        let categories: [UIContentSizeCategory] = [
            .large, .accessibilityLarge, .accessibilityExtraLarge, .accessibilityExtraExtraLarge, .accessibilityExtraExtraExtraLarge,
        ]
        let aboveAX3: Set<UIContentSizeCategory> = [.accessibilityExtraExtraLarge, .accessibilityExtraExtraExtraLarge]
        var gatedCount = 0
        for item in Self.emptyLineCodes {
            let code = TK2CodeLogic.stamped(item.string)
            #expect(((code.runs.first?.adfCodeShape?.interiorEmptyLineCount ?? 0) > 0) == item.interior, "\(item.name)")
            for matchText in [false, true] {
                for category in categories {
                    for weight in [LegibilityWeight?.none, .bold] {
                        for scale in [CGFloat(2), 3] {
                            let label = "\(item.name), \(category.rawValue), \(String(describing: weight)), @\(scale), match \(matchText)"
                            let gated = !matchText && item.interior && aboveAX3.contains(category)
                            let expected: TextKit2Scope.CodeGate? = gated ? .osGatedEmptyLines : nil
                            #expect(Self.gate(code, category, weight: weight, scale: scale, emptyLinesMatchText: matchText) == expected, "\(label)")
                            #expect(TextKit2Scope.codeEmptyLinesKeepRenderer(
                                code, sizeCategory: category, emptyLinesMatchText: matchText
                            ) == !gated, "\(label)")
                            if gated { gatedCount += 1 }
                        }
                    }
                }
            }
        }
        // Not vacuous: three codes × two sizes × two weights × two scales.
        #expect(gatedCount == 24)
    }

    @Test("interior empty lines are judged after the direction and the canvas, from the prepared shape alone")
    func interiorEmptyLinesOrder() {
        let ax5 = UIContentSizeCategory.accessibilityExtraExtraExtraLarge
        let code = TK2CodeLogic.stamped("let a = 1\n\nlet b = 2")
        #expect(Self.gate(code, ax5, emptyLinesMatchText: false) == .osGatedEmptyLines)
        #expect(Self.gate(code, ax5, emptyLinesMatchText: true) == nil)
        // The production default (no `emptyLinesMatchText` argument) is the
        // runtime's answer: gated before iOS 26, admitted from it.
        let byDefault = TextKit2Scope.codeGate(
            code, sizeCategory: ax5, legibilityWeight: nil, displayScale: 3, layoutDirection: .leftToRight
        )
        let keepsByDefault = TextKit2Scope.codeEmptyLinesKeepRenderer(code, sizeCategory: ax5)
        if #available(iOS 26.0, *) {
            #expect(byDefault == nil)
            #expect(keepsByDefault)
        } else {
            #expect(byDefault == .osGatedEmptyLines)
            #expect(!keepsByDefault)
        }
        // The direction first, then the canvas.
        #expect(Self.gate(code, ax5, direction: .rightToLeft, emptyLinesMatchText: false) == .direction)
        let huge = TK2CodeLogic.stamped(String(repeating: "x", count: 5_000) + "\n\nx")
        #expect(Self.gate(huge, ax5, emptyLinesMatchText: false) == .canvas)
        #expect(Self.gate(huge, .large, emptyLinesMatchText: false) == .canvas)

        // The prepared shape decides; the characters are never scanned.
        let claimed = ADFCodeShape(lineCount: 3, maxLineUTF16: 9, interiorEmptyLineCount: 1)
        #expect(Self.gate(TK2CodeLogic.stamped("let a = 1\nx\nlet b = 2", shape: claimed), ax5, emptyLinesMatchText: false) == .osGatedEmptyLines)
        let unclaimed = ADFCodeShape(lineCount: 3, maxLineUTF16: 9)
        #expect(Self.gate(TK2CodeLogic.stamped("let a = 1\n\nlet b = 2", shape: unclaimed), ax5, emptyLinesMatchText: false) == nil)

        // The pure rule: any count above zero, only above AX3, only where
        // `Text` does not match.
        for count in [0, 1, 7] {
            let shape = ADFCodeShape(lineCount: count + 2, maxLineUTF16: 9, interiorEmptyLineCount: count)
            for category in [UIContentSizeCategory.accessibilityExtraLarge, .accessibilityExtraExtraLarge, ax5] {
                let gated = count > 0 && category != .accessibilityExtraLarge
                #expect(TextKit2Scope.codeEmptyLinesKeepRenderer(shape, sizeCategory: category, emptyLinesMatchText: false) == !gated, "\(count) \(category.rawValue)")
                #expect(TextKit2Scope.codeEmptyLinesKeepRenderer(shape, sizeCategory: category, emptyLinesMatchText: true), "\(count) \(category.rawValue)")
            }
        }

        // Not one prepared run: no shape to read, so it fails closed (in the
        // gate the canvas has already answered for such a string).
        for matchText in [false, true] {
            #expect(!TextKit2Scope.codeEmptyLinesKeepRenderer(TK2CodeLogic.stamped("let a = 1", shape: nil), sizeCategory: .large, emptyLinesMatchText: matchText))
            #expect(!TextKit2Scope.codeEmptyLinesKeepRenderer(AttributedString(), sizeCategory: .large, emptyLinesMatchText: matchText))
            #expect(Self.gate(TK2CodeLogic.stamped("let a = 1", shape: nil), ax5, emptyLinesMatchText: matchText) == .canvas)
        }
    }

    @Test("hosted: a Text Size change moves code with an interior empty line off the row above AX3 before iOS 26, and back; from iOS 26 it stays")
    func hostedEmptyLinesCrossing() async throws {
        let gatedOnThisOS = !TextKit2Scope.codeEmptyLinesMatchText
        let code = TK2CodeLogic.stamped("let a = 1\n\nlet b = 2")
        let hosted = TK2CodeLogic.Hosted(TK2CodeLogic.codeView(code, size: .accessibility3))
        defer { hosted.close() }
        try await hosted.settle()
        #expect(hosted.codeRows.count == 1, "at AX3 a row draws it on every OS")
        for size in [DynamicTypeSize.accessibility4, .accessibility5] {
            for legibility in [LegibilityWeight?.none, .bold] {
                hosted.show(TK2CodeLogic.codeView(code, size: size, legibility: legibility))
                try await hosted.settle()
                let label = "\(size) \(String(describing: legibility))"
                #expect(hosted.codeRows.count == (gatedOnThisOS ? 0 : 1), "\(label): \(hosted.codeRows.count) code rows")
                #expect(hosted.scrollViews.count == 1, "\(label): the code block is still there")
            }
        }
        hosted.show(TK2CodeLogic.codeView(code, size: .accessibility3))
        try await hosted.settle()
        #expect(hosted.codeRows.count == 1, "back at AX3 the row returns")

        // The public measurement counts the same: `0.0` has an interior
        // empty line, `0.1` an empty first line, `0.2` a trailing line feed.
        let data = try TK2CodeLogic.document([
            TK2CodeLogic.code("let a = 1\n\nlet b = 2"),
            TK2CodeLogic.code("\nlet a = 1\nlet b = 2"),
            TK2CodeLogic.code("let a = 1\nlet b = 2\n"),
        ])
        let blocks = try await TK2CodeLogic.prepared(data)
        for size in [DynamicTypeSize.large, .accessibility3, .accessibility4, .accessibility5] {
            let admission = ADFTextRenderer.textKit2CodeAdmission(
                of: blocks, dynamicTypeSize: size, legibilityWeight: nil, displayScale: 3, layoutDirection: .leftToRight
            )
            let gated = gatedOnThisOS && size > .accessibility3 ? 1 : 0
            #expect(admission.admittedCodeRoots == 3 - gated && admission.gatedCodeRoots == gated,
                    "\(size): admitted \(admission.admittedCodeRoots), gated \(admission.gatedCodeRoots)")
        }
    }

    @Test("a Text Size change moves a block across the canvas limit", arguments: [CGFloat(2), 3])
    func sizeCategoryCrossesTheLimit(scale: CGFloat) throws {
        let large = try #require(TextKit2CodeMetrics.metrics(for: TK2CodeLogic.mono, category: .large))
        let columns = Self.longestAdmittedLine(large, scale: scale)
        #expect(columns > 100, "\(columns) columns at Large")
        let atLimit = TK2CodeLogic.stamped(String(repeating: "x", count: columns))
        let over = TK2CodeLogic.stamped(String(repeating: "x", count: columns + 1))

        // At Large: the longest line fits, one column more does not.
        #expect(Self.fits(atLimit, .large, scale: scale))
        #expect(Self.gate(atLimit, .large, scale: scale) == nil)
        #expect(!Self.fits(over, .large, scale: scale))
        #expect(Self.gate(over, .large, scale: scale) == .canvas)
        let bound = try #require(TextKit2Scope.codeCanvasBound(atLimit, sizeCategory: .large, legibilityWeight: nil, displayScale: scale))
        #expect(bound.pixelWidth <= TextKit2Scope.maximumCodeCanvasDimension)
        #expect(bound.pixelWidth + Int((large.advance * scale).rounded(.up)) > TextKit2Scope.maximumCodeCanvasDimension,
                "within a column of the limit: \(bound.pixelWidth) px")

        // Up the ladder: admitted up to Large, gated above it, and never
        // admitted again above a gated size.
        var gated = false
        for category in TextKit2RowViewTests.categories {
            let admitted = Self.fits(atLimit, category, scale: scale)
            #expect(!(gated && admitted), "\(category.rawValue): admitted above a gated size")
            if !admitted { gated = true }
        }
        for category in [UIContentSizeCategory.extraSmall, .small, .medium, .large] {
            #expect(Self.fits(atLimit, category, scale: scale), "\(category.rawValue)")
        }
        for category in [UIContentSizeCategory.extraExtraExtraLarge, .accessibilityMedium, .accessibilityExtraExtraExtraLarge] {
            #expect(!Self.fits(atLimit, category, scale: scale), "\(category.rawValue)")
            #expect(Self.gate(atLimit, category, scale: scale) == .canvas, "\(category.rawValue)")
        }
        // Bold Text is part of the decision: the bound uses that weight's
        // metrics.
        let bold = try #require(TextKit2CodeMetrics.metrics(for: TK2CodeLogic.mono, category: .large, legibilityWeight: .bold))
        let boldColumns = Self.longestAdmittedLine(bold, scale: scale)
        // `LegibilityWeight.bold`, not `.bold`: with the bare member the
        // macro's four-argument call resolves to its optional-result overload
        // with a `Void` result, so the `Bool` is discarded and the check
        // always passes.
        #expect(Self.fits(TK2CodeLogic.stamped(String(repeating: "x", count: boldColumns)), .large, weight: LegibilityWeight.bold, scale: scale))
        #expect(!Self.fits(TK2CodeLogic.stamped(String(repeating: "x", count: boldColumns + 1)), .large, weight: LegibilityWeight.bold, scale: scale))
    }

    @Test("hosted: the code row leaves at a text size that needs too large a canvas and returns at one that fits")
    func hostedSizeCrossing() async throws {
        let large = try #require(TextKit2CodeMetrics.metrics(for: TK2CodeLogic.mono, category: .large))
        let columns = Self.longestAdmittedLine(large, scale: TK2Parity.nativeScale)
        let code = TK2CodeLogic.stamped(String(repeating: "x", count: columns))

        let hosted = TK2CodeLogic.Hosted(TK2CodeLogic.codeView(code, size: .large))
        defer { hosted.close() }
        try await hosted.settle()
        let row = try #require(hosted.codeRows.first, "at Large the line fits and a row draws it")
        #expect(row.inputs?.displayScale == TK2Parity.nativeScale)
        #expect(row.inputs?.sizeCategory == .large)

        hosted.show(TK2CodeLogic.codeView(code, size: .accessibility5))
        try await hosted.settle()
        #expect(hosted.rows.isEmpty, "at AX5 the same line needs a canvas over the limit")
        #expect(hosted.scrollViews.count == 1, "the code block is still there, on SwiftUI")

        hosted.show(TK2CodeLogic.codeView(code, size: .large))
        try await hosted.settle()
        #expect(hosted.codeRows.count == 1, "back at Large the row returns")
    }

    // MARK: actual canvas ≤ admitted bound ≤ limit

    nonisolated static let invariantCategories: [UIContentSizeCategory] = [
        .extraSmall, .large, .extraExtraExtraLarge, .accessibilityMedium, .accessibilityExtraExtraExtraLarge,
    ]

    /// Eight lines of 34 to 39 columns, like a stress fixture's code block.
    nonisolated static let block: String = (0..<8).map { String(repeating: "w", count: 34 + $0 % 6) }.joined(separator: "\n")
    nonisolated static let tallColumn: String = Array(repeating: "x", count: 120).joined(separator: "\n")
    nonisolated static let square: String = Array(repeating: String(repeating: "m", count: 80), count: 80).joined(separator: "\n")

    /// Shapes of very different proportions (all printable ASCII and line
    /// feeds), admitted at some sizes and over a cap at others.
    nonisolated static let invariantStrings: [(name: String, string: String)] = [
        ("one character", "x"),
        ("eight lines of 34 to 39 columns", block),
        ("one line of 300 columns", String(repeating: "W", count: 300)),
        ("120 lines of one column", tallColumn),
        ("80 lines of 80 columns", square),
        ("spaces and an empty line", "    indented\n\n        deeper    \nend"),
        ("punctuation, digits and descenders", "{[(<@#$%^&*~`|\\/>)]} 0123456789 MWmw_il1 gjpqy"),
        ("a trailing line feed", "let a = 1\n"),
    ]

    @Test("actual canvas ≤ admitted bound ≤ limit, for rows really laid out across shapes, specs, text sizes, weights and scales")
    func canvasInvariant() {
        var admitted = 0
        var gated = 0
        var tightest: (slack: Int, label: String) = (Int.max, "")
        for spec in Self.monoSpecs {
            for category in Self.invariantCategories {
                for weight in [LegibilityWeight?.none, .bold] {
                    for scale in [CGFloat(2), 3] {
                        for item in Self.invariantStrings {
                            let label = "\(item.name), \(spec), \(category.rawValue), \(String(describing: weight)), @\(scale)"
                            let text = TK2CodeLogic.stamped(item.string, spec: spec)
                            guard let bound = TextKit2Scope.codeCanvasBound(
                                text, sizeCategory: category, legibilityWeight: weight, displayScale: scale
                            ) else {
                                gated += 1
                                continue
                            }
                            admitted += 1
                            // bound ≤ limit.
                            #expect(bound.pixelWidth <= TextKit2Scope.maximumCodeCanvasDimension, "\(label)")
                            #expect(bound.pixelHeight <= TextKit2Scope.maximumCodeCanvasDimension, "\(label)")
                            #expect(bound.nominalBytes <= TextKit2Scope.maximumCodeCanvasBytes, "\(label)")

                            // actual ≤ bound: the row as the code view makes
                            // it, placed at the size it measures, and a pixel
                            // larger each way (a pixel-snapped frame).
                            let row = TextKit2RowView()
                            row.ownerKind = .code
                            row.apply(TextKit2RenderInputs(
                                text: text, sizeCategory: category, displayScale: scale, legibilityWeight: weight,
                                layoutPolicy: .natural
                            ))
                            let size = row.measuredSize(forProposedWidth: nil)
                            for extra in [CGFloat(0), 1 / scale] {
                                row.frame = CGRect(x: 0, y: 0, width: size.width + extra, height: size.height + extra)
                                row.layoutIfNeeded()
                                let canvas = row.canvasFrame
                                let width = Self.pixels(canvas.width, scale: scale)
                                let height = Self.pixels(canvas.height, scale: scale)
                                #expect(width <= bound.pixelWidth, "\(label): canvas \(width) px wide, bound \(bound.pixelWidth)")
                                #expect(height <= bound.pixelHeight, "\(label): canvas \(height) px tall, bound \(bound.pixelHeight)")
                                #expect(width * height * 4 <= bound.nominalBytes, "\(label)")
                                let slack = min(bound.pixelWidth - width, bound.pixelHeight - height)
                                if slack < tightest.slack { tightest = (slack, label) }
                            }
                            // One layout, and no line wrapped: the bound
                            // counted on at most this many lines.
                            #expect(row.relayoutCount == 1, "\(label): \(row.relayoutCount) layouts")
                            let lines = row.drawn?.lineCount ?? Int.max
                            #expect(lines <= bound.lineCount, "\(label): \(lines) lines drawn, \(bound.lineCount) counted")
                        }
                    }
                }
            }
        }
        // Not vacuous: most are admitted, and some are over a cap.
        #expect(admitted >= 200, "\(admitted) admitted")
        #expect(gated >= 20, "\(gated) gated")
        print("TK2 code canvas invariant: \(admitted) admitted rows laid out, \(gated) gated; tightest slack \(tightest.slack) px (\(tightest.label))")
    }

    @Test("hosted: the real code row's canvas is within the bound of its own render inputs")
    func hostedCanvasInvariant() async throws {
        let code = TK2CodeLogic.stamped(Self.block)
        for size in [DynamicTypeSize.large, .xxxLarge, .accessibility2] {
            for legibility in [LegibilityWeight?.none, .bold] {
                let label = "\(size) \(String(describing: legibility))"
                let hosted = TK2CodeLogic.Hosted(TK2CodeLogic.codeView(code, size: size, legibility: legibility))
                defer { hosted.close() }
                try await hosted.settle()
                let row = try #require(hosted.codeRows.first, "\(label): no code row")
                let inputs = try #require(row.inputs)
                // The row's inputs are the environment the gate decided in.
                #expect(inputs.sizeCategory == size.uiContentSizeCategory, "\(label)")
                #expect(inputs.legibilityWeight == legibility, "\(label)")
                #expect(inputs.layoutDirection == .leftToRight && inputs.layoutPolicy == .natural, "\(label)")
                let bound = try #require(TextKit2Scope.codeCanvasBound(
                    inputs.text, sizeCategory: inputs.sizeCategory, legibilityWeight: inputs.legibilityWeight,
                    displayScale: inputs.displayScale
                ), "\(label): a drawn row must have an admitted bound")
                #expect(bound.isWithinCaps, "\(label)")
                let canvas = row.canvasFrame
                let width = Self.pixels(canvas.width, scale: inputs.displayScale)
                let height = Self.pixels(canvas.height, scale: inputs.displayScale)
                #expect(width > 0 && height > 0, "\(label): canvas \(canvas)")
                #expect(width <= bound.pixelWidth, "\(label): canvas \(width) px wide, bound \(bound.pixelWidth)")
                #expect(height <= bound.pixelHeight, "\(label): canvas \(height) px tall, bound \(bound.pixelHeight)")
                #expect(row.relayoutCount == 1, "\(label): \(row.relayoutCount) layouts")
                #expect(row.drawn?.lineCount == 8, "\(label)")
            }
        }
    }

    // MARK: The real code view

    @Test("code that falls back never reaches the text builder or a row; eligible code does")
    func fallbacksNeverReachTheTextBuilder() {
        let diagnostics = TextKit2Diagnostics.shared
        let fallbacks: [(String, AttributedString)] = [
            ("undescribable", TK2CodeLogic.stamped("let x = 1", spec: nil)),
            ("proportional", TK2CodeLogic.stamped("let x = 1", spec: ADFFontSpec(textStyle: .body))),
            ("unshaped", TK2CodeLogic.stamped("let x = 1", shape: nil)),
            ("linked", TextKit2CodeVerdictTests.linked(TK2CodeLogic.stamped("let x = 1"))),
            ("tab", TK2CodeLogic.stamped("a\tb")),
            ("non-ASCII", TK2CodeLogic.stamped("caf\u{E9}")),
            ("CRLF", TK2CodeLogic.stamped("a\r\nb")),
            ("control", TK2CodeLogic.stamped("a\u{0}b")),
            ("line feeds only", TK2CodeLogic.stamped("\n\n")),
            ("empty", AttributedString()),
            ("over the canvas", TK2CodeLogic.stamped(String(repeating: "x", count: 5_000))),
        ]
        for (name, code) in fallbacks {
            // No suspension between the two reads: only this view could
            // convert text.
            let conversions = diagnostics.conversionCount
            let layouts = diagnostics.layoutCount
            let rows = TextKit2FallbackTests.rowViews(hosting: TK2CodeLogic.codeView(code, ownerID: name))
            #expect(rows.isEmpty, "\(name): \(rows.count) row(s)")
            #expect(diagnostics.conversionCount == conversions, "\(name): the text builder ran")
            #expect(diagnostics.layoutCount == layouts, "\(name): a row laid out")
        }

        // The control: the same hosting of eligible code makes one code row,
        // which converts its text.
        let conversions = diagnostics.conversionCount
        let rows = TextKit2FallbackTests.rowViews(hosting: TK2CodeLogic.codeView(TK2CodeLogic.stamped("let x = 1"), ownerID: "control"))
        #expect(rows.count == 1, "control: \(rows.count) row(s)")
        #expect(rows.first?.ownerKind == .code)
        #expect(diagnostics.conversionCount - conversions >= 1, "control: no conversion")
    }

    @Test("hosted: Bold Text and a custom monospaced spec draw in the font the string's own spec resolves to")
    func hostedFonts() async throws {
        let cases: [(spec: ADFFontSpec, legibility: LegibilityWeight?)] = [
            (TK2CodeLogic.mono, nil),
            (TK2CodeLogic.mono, .bold),
            (ADFFontSpec(textStyle: .footnote, bold: true, monospaced: true), nil),
            (ADFFontSpec(textStyle: .body, italic: true, monospaced: true), .bold),
        ]
        for item in cases {
            let label = "\(item.spec) \(String(describing: item.legibility))"
            let code = TK2CodeLogic.stamped("let x = 1\nprint(x)", spec: item.spec)
            let view = TK2CodeLogic.codeView(code, theme: ADFTheme(codeFontSpec: item.spec), legibility: item.legibility)
            let hosted = TK2CodeLogic.Hosted(view)
            defer { hosted.close() }
            try await hosted.settle()
            let row = try #require(hosted.codeRows.first, "\(label): no code row")
            #expect(row.inputs?.legibilityWeight == item.legibility, "\(label)")
            let font = row.attributed.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
            #expect(font == TextKit2FontResolver.font(for: item.spec, category: .large, legibilityWeight: item.legibility), "\(label)")
        }

        // A later ambient theme does not change the font: the string's own
        // spec is the font, for the bound and for the row alike.
        let code = TK2CodeLogic.stamped("let x = 1", spec: TK2CodeLogic.mono)
        let other = ADFTheme(codeFontSpec: ADFFontSpec(textStyle: .title, monospaced: true))
        let hosted = TK2CodeLogic.Hosted(TK2CodeLogic.codeView(code, theme: other))
        defer { hosted.close() }
        try await hosted.settle()
        let row = try #require(hosted.codeRows.first)
        let font = row.attributed.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        #expect(font == TextKit2FontResolver.font(for: TK2CodeLogic.mono, category: .large, legibilityWeight: nil))
    }

    @Test("search: a code block with highlights draws on SwiftUI while the search is active, and returns to TextKit 2 after it")
    func searchHighlights() async throws {
        // `0.0` a paragraph, `0.1` the code the query matches once, `0.2`
        // code it does not match.
        let data = try TK2CodeLogic.document([
            TK2CodeLogic.paragraph("Intro text"),
            TK2CodeLogic.code("let total = 1\nprint(total)"),
            TK2CodeLogic.code("let other = 2"),
        ])
        let model = try await TK2CodeLogic.loadedModel(data)
        model.search.debounceInterval = .zero
        let hosted = TK2CodeLogic.Hosted(TK2CodeLogic.documentView(model, .textKit2))
        defer { hosted.close() }
        func owners() async throws -> Set<String> {
            try await hosted.settle()
            return hosted.owners
        }

        let before = try await owners()
        #expect(before == ["0.0", "0.1", "0.2"], "\(before.sorted())")
        #expect(Set(hosted.codeRows.compactMap(\.ownerID)) == ["0.1", "0.2"])
        let codeBlocks = hosted.scrollViews.count

        model.search.run("print")
        for _ in 0..<500 where model.search.isSearching || model.search.matchCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.search.matchCount == 1)
        let searching = try await owners()
        #expect(searching == ["0.0", "0.2"], "the matched code block leaves TextKit 2: \(searching.sorted())")
        #expect(hosted.scrollViews.count == codeBlocks, "and stays on screen, on SwiftUI")

        // The current match (the arrival flash's owner) stays on SwiftUI too.
        model.search.next()
        let current = try await owners()
        #expect(current == searching, "\(current.sorted())")

        model.search.clear()
        let cleared = try await owners()
        #expect(cleared == before, "the code row returns: \(cleared.sorted())")
        let returned = try #require(hosted.codeRows.first { $0.ownerID == "0.1" })
        #expect(returned.inputs.map { String($0.text.characters) } == "let total = 1\nprint(total)")
    }
}
#endif
