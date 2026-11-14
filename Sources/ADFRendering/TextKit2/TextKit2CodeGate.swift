#if canImport(UIKit)
import CoreText
import SwiftUI
import UIKit
import ADFPreparation

/// The code-only step between `TextEngineLeaf` and `TextKit2Leaf`: code
/// that is eligible by content (`TextKit2Eligibility.codeVerdict`) goes on
/// to the TextKit 2 row only where it is drawn left to right and within the
/// canvas bound at the current text size, weight and display scale
/// (`TextKit2Scope.codeGate`); otherwise `fallback`, the SwiftUI `Text`
/// exactly as on main.
///
/// Only constructed when the switch is ON and the text is code, so the
/// SwiftUI arm reads none of these environment values, and `TextKit2Leaf`,
/// which every paragraph and list leaf goes through, gains none. The size
/// category is an input, so a Text Size change can move a block across the
/// bound; both arms report the same height, so nothing jumps. A plain
/// `if`/`else`, like the leaves around it. No view state: the decision is
/// a pure function of the prepared text and the environment.
struct TextKit2CodeGate<Fallback: View>: View {
    let text: AttributedString
    let style: TextBlockStyle
    let ownerID: String?
    let fallback: Fallback

    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.displayScale) private var displayScale

    init(text: AttributedString, style: TextBlockStyle, ownerID: String?, @ViewBuilder fallback: () -> Fallback) {
        self.text = text
        self.style = style
        self.ownerID = ownerID
        self.fallback = fallback()
    }

    var body: some View {
        if TextKit2Scope.codeGate(
            text, sizeCategory: dynamicTypeSize.uiContentSizeCategory, legibilityWeight: legibilityWeight,
            displayScale: displayScale, layoutDirection: layoutDirection
        ) == nil {
            TextKit2Leaf(text: text, style: style, ownerID: ownerID, ownerKind: .code) { fallback }
        } else {
            fallback
        }
    }
}

extension TextKit2Scope {
    /// What keeps prepared code on SwiftUI where it is drawn, or `nil` when
    /// the TextKit 2 row may draw it: the layout direction first, then the
    /// canvas bound. `text` is a code string the content verdict found
    /// eligible; the rule is a pure function of it and these four
    /// environment values, the same ones the row's render inputs take.
    @MainActor
    static func codeGate(
        _ text: AttributedString, sizeCategory: UIContentSizeCategory, legibilityWeight: LegibilityWeight?,
        displayScale: CGFloat, layoutDirection: LayoutDirection
    ) -> CodeGate? {
        guard codeDirectionKeepsRenderer(layoutDirection) else { return .direction }
        guard codeFitsCanvas(
            text, sizeCategory: sizeCategory, legibilityWeight: legibilityWeight, displayScale: displayScale
        ) else { return .canvas }
        return nil
    }

    /// Whether prepared code has an admitted canvas bound at this text
    /// size, weight and scale (`codeCanvasBound`).
    @MainActor
    static func codeFitsCanvas(
        _ text: AttributedString, sizeCategory: UIContentSizeCategory, legibilityWeight: LegibilityWeight?,
        displayScale: CGFloat
    ) -> Bool {
        codeCanvasBound(
            text, sizeCategory: sizeCategory, legibilityWeight: legibilityWeight, displayScale: displayScale
        ) != nil
    }

    /// Whether code of `shape` set in `fontSpec` has an admitted canvas
    /// bound at this text size, weight and scale.
    @MainActor
    static func codeFitsCanvas(
        _ shape: ADFCodeShape, fontSpec: ADFFontSpec, sizeCategory: UIContentSizeCategory,
        legibilityWeight: LegibilityWeight?, displayScale: CGFloat
    ) -> Bool {
        codeCanvasBound(
            shape, fontSpec: fontSpec, sizeCategory: sizeCategory, legibilityWeight: legibilityWeight,
            displayScale: displayScale
        ) != nil
    }

    /// The admitted canvas bound of prepared code, read in constant time
    /// from its one run: the prepared shape and the run's own font spec,
    /// the font the text builder resolves for the row (never a later
    /// ambient theme). `nil` when the string is not one prepared run, or
    /// has no admitted bound.
    @MainActor
    static func codeCanvasBound(
        _ text: AttributedString, sizeCategory: UIContentSizeCategory, legibilityWeight: LegibilityWeight?,
        displayScale: CGFloat
    ) -> CodeCanvasBound? {
        guard let run = text.runs.first, run.range.upperBound == text.endIndex,
              let shape = run.adfCodeShape, let fontSpec = run.adfFontSpec else { return nil }
        return codeCanvasBound(
            shape, fontSpec: fontSpec, sizeCategory: sizeCategory, legibilityWeight: legibilityWeight,
            displayScale: displayScale
        )
    }

    /// The admitted canvas bound for code of `shape` set in `fontSpec` at
    /// this text size, weight and scale, or `nil` (the code stays on
    /// SwiftUI): the spec is not monospaced or its font is not fixed-pitch
    /// (`TextKit2CodeMetrics`), the shape is outside the admitted cohort,
    /// or the bound is over a cap (`codeCanvasBound(_:advance:lineHeight:displayScale:)`).
    @MainActor
    static func codeCanvasBound(
        _ shape: ADFCodeShape, fontSpec: ADFFontSpec, sizeCategory: UIContentSizeCategory,
        legibilityWeight: LegibilityWeight?, displayScale: CGFloat
    ) -> CodeCanvasBound? {
        guard let metrics = TextKit2CodeMetrics.metrics(
            for: fontSpec, category: sizeCategory, legibilityWeight: legibilityWeight
        ) else { return nil }
        return codeCanvasBound(shape, advance: metrics.advance, lineHeight: metrics.lineHeight, displayScale: displayScale)
    }
}

/// The metrics the code canvas bound needs from a code font: the font the
/// text builder resolves for the same spec, size category and legibility
/// weight (`TextKit2FontResolver`), measured once and memoized.
@MainActor
enum TextKit2CodeMetrics {
    private struct Key: Hashable {
        let spec: ADFFontSpec
        let category: UIContentSizeCategory
        let legibilityWeight: LegibilityWeight?
    }

    /// `nil` values are memoized too: a font with no admitted metrics.
    private static var cache: [Key: TextKit2Scope.CodeFontMetrics?] = [:]

    /// Printable ASCII, U+0020 to U+007E: every scalar an admitted code
    /// string can hold besides LF.
    private static let printableASCII = [UniChar](0x20...0x7E)

    /// The largest spread between two printable ASCII advances that still
    /// counts as one fixed advance (the widest is the one used).
    private static let fixedPitchTolerance: CGFloat = 0.01

    /// The fixed advance and line height of the font for `spec`, or `nil`
    /// when no conservative bound can be stated for it:
    /// - the spec is not monospaced;
    /// - the font lacks a printable ASCII glyph (a fallback font would draw
    ///   it, at another width and height);
    /// - the printable ASCII advances differ, so the font is not
    ///   fixed-pitch after all;
    /// - a printable ASCII glyph inks more than half a line beyond the
    ///   font's ascent or descent, which the bound's ink reserve
    ///   (`TextKit2Scope.codeCanvasInkReserveLines`) would not cover.
    ///
    /// The advance is the widest of the glyphs' nominal advances and the
    /// mean advance of the same characters typeset as one line, so a
    /// tracking the typesetter adds for the size is included; a narrower
    /// typeset line never lowers it.
    static func metrics(
        for spec: ADFFontSpec, category: UIContentSizeCategory, legibilityWeight: LegibilityWeight? = nil
    ) -> TextKit2Scope.CodeFontMetrics? {
        let key = Key(spec: spec, category: category, legibilityWeight: legibilityWeight)
        if let cached = cache[key] { return cached }
        let metrics = measure(key)
        cache.updateValue(metrics, forKey: key)
        return metrics
    }

    private static func measure(_ key: Key) -> TextKit2Scope.CodeFontMetrics? {
        guard key.spec.monospaced else { return nil }
        let font = TextKit2FontResolver.font(for: key.spec, category: key.category, legibilityWeight: key.legibilityWeight)
        let coreTextFont = font as CTFont
        let count = printableASCII.count
        var glyphs = [CGGlyph](repeating: 0, count: count)
        guard CTFontGetGlyphsForCharacters(coreTextFont, printableASCII, &glyphs, count) else { return nil }

        var advances = [CGSize](repeating: .zero, count: count)
        _ = CTFontGetAdvancesForGlyphs(coreTextFont, .horizontal, glyphs, &advances, count)
        var widest: CGFloat = 0
        var narrowest = CGFloat.greatestFiniteMagnitude
        for advance in advances {
            widest = max(widest, advance.width)
            narrowest = min(narrowest, advance.width)
        }
        guard widest.isFinite, narrowest > 0, widest - narrowest <= fixedPitchTolerance else { return nil }

        let sample = NSAttributedString(string: String(decoding: printableASCII, as: UTF16.self), attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(sample as CFAttributedString)
        let typeset = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) / CGFloat(count)
        guard typeset.isFinite else { return nil }
        let advance = max(widest, typeset)

        let lineHeight = font.ascender - font.descender + max(font.leading, 0)
        guard lineHeight.isFinite, lineHeight > 0 else { return nil }
        let ink = CTFontGetBoundingRectsForGlyphs(coreTextFont, .horizontal, glyphs, nil, count)
        guard !ink.isNull, !ink.isInfinite,
              ink.maxY - font.ascender <= lineHeight / 2,
              -ink.minY + font.descender <= lineHeight / 2 else { return nil }

        return TextKit2Scope.CodeFontMetrics(advance: advance, lineHeight: lineHeight)
    }
}
#endif
