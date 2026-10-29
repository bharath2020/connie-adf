import Foundation
import SwiftUI
import ADFModel

/// Design tokens for preparation and rendering: fonts, spacing, and panel
/// palettes. Injected into `InlineComposer` / `DocumentPreparer` so every
/// `AttributedString` is built once, off-main, already styled.
public struct ADFTheme: Sendable, Hashable {
    /// Base font for body text. Assigning a raw `Font` here marks the body
    /// as undescribable (`bodyFontSpec` becomes `nil`): a `Font` cannot be
    /// introspected, so a non-SwiftUI text engine can no longer resolve the
    /// same platform font and those blocks stay on SwiftUI. Prefer setting
    /// `bodyFontSpec`, which derives this font.
    public var body: Font {
        get { storedBody }
        set {
            storedBody = newValue
            storedBodyFontSpec = nil
        }
    }
    /// Monospaced font for inline code and code blocks (see `body` for how
    /// assigning a raw `Font` interacts with `codeFontSpec`).
    public var code: Font {
        get { storedCode }
        set {
            storedCode = newValue
            storedCodeFontSpec = nil
        }
    }
    /// Base spacing unit in points.
    public var spacing: CGFloat
    /// Point size backing `body`. Used to derive metrics that need numbers
    /// (sub/superscript offset and size, the `fontSize: "small"` mark).
    public var bodyPointSize: CGFloat
    /// Corner radius for chip-scale elements (inline atoms, unknown-content
    /// pills, card icon wells).
    public var chipCornerRadius: CGFloat
    /// Corner radius for block containers (panels, code blocks, expands,
    /// media boxes, decision rows).
    public var containerCornerRadius: CGFloat
    /// Corner radius for interactive cards (smart-link block/embed cards).
    public var cardCornerRadius: CGFloat
    /// Background for every search match (subtle, translucent).
    public var searchHighlight: Color
    /// Background for the CURRENT search match (accent). The default is an
    /// opaque bright yellow-orange; pair a custom value with a suitable
    /// `searchCurrentForeground`.
    public var searchCurrentHighlight: Color
    /// Foreground forced over `searchCurrentHighlight` so the current match
    /// stays legible in both schemes. `nil` keeps the run's own foreground.
    public var searchCurrentForeground: Color?
    /// Semantic description of `body` — the source of truth when present.
    /// Setting a spec derives `body` from it, so the two never disagree;
    /// `nil` means the body font is a raw `Font` no other engine can
    /// reproduce. Baked on every unmarked body run.
    public var bodyFontSpec: ADFFontSpec? {
        get { storedBodyFontSpec }
        set {
            storedBodyFontSpec = newValue
            if let newValue { storedBody = Font(adfFontSpec: newValue) }
        }
    }
    /// Semantic description of `code` (see `bodyFontSpec`).
    public var codeFontSpec: ADFFontSpec? {
        get { storedCodeFontSpec }
        set {
            storedCodeFontSpec = newValue
            if let newValue { storedCode = Font(adfFontSpec: newValue) }
        }
    }

    private var storedBody: Font
    private var storedCode: Font
    private var storedBodyFontSpec: ADFFontSpec?
    private var storedCodeFontSpec: ADFFontSpec?

    /// Spec-first construction: pass `bodyFontSpec` / `codeFontSpec` (or
    /// nothing, for the system text styles) and the SwiftUI fonts are
    /// derived from them. Passing a raw `body` / `code` font without its
    /// spec keeps that font for SwiftUI and marks it undescribable; passing
    /// both asserts they describe the same face.
    public init(
        body: Font? = nil,
        code: Font? = nil,
        spacing: CGFloat = 8,
        bodyPointSize: CGFloat = 17,
        chipCornerRadius: CGFloat = 6,
        containerCornerRadius: CGFloat = 8,
        cardCornerRadius: CGFloat = 10,
        searchHighlight: Color = .yellow.opacity(0.3),
        searchCurrentHighlight: Color = Color(red: 1.0, green: 0.78, blue: 0.16),
        searchCurrentForeground: Color? = .black,
        bodyFontSpec: ADFFontSpec? = nil,
        codeFontSpec: ADFFontSpec? = nil
    ) {
        let resolvedBodySpec = body == nil ? (bodyFontSpec ?? ADFFontSpec(textStyle: .body)) : bodyFontSpec
        let resolvedCodeSpec = code == nil ? (codeFontSpec ?? ADFFontSpec(textStyle: .body, monospaced: true)) : codeFontSpec
        self.storedBody = body ?? Font(adfFontSpec: resolvedBodySpec!)
        self.storedCode = code ?? Font(adfFontSpec: resolvedCodeSpec!)
        self.storedBodyFontSpec = resolvedBodySpec
        self.storedCodeFontSpec = resolvedCodeSpec
        self.spacing = spacing
        self.bodyPointSize = bodyPointSize
        self.chipCornerRadius = chipCornerRadius
        self.containerCornerRadius = containerCornerRadius
        self.cardCornerRadius = cardCornerRadius
        self.searchHighlight = searchHighlight
        self.searchCurrentHighlight = searchCurrentHighlight
        self.searchCurrentForeground = searchCurrentForeground
    }

    public static let `default` = ADFTheme()

    /// Font for a heading of the given level (clamped to `1...6`), derived
    /// from `headingFontSpec(_:)` so the two can never disagree.
    public func headingFont(_ level: Int) -> Font {
        Font(adfFontSpec: headingFontSpec(level))
    }

    /// Semantic spec of a heading level: the text style plus the bold trait
    /// (`.headline` is semibold by itself, so H4 carries no extra bold).
    public func headingFontSpec(_ level: Int) -> ADFFontSpec {
        switch min(max(level, 1), 6) {
        case 1: return ADFFontSpec(textStyle: .title, bold: true)
        case 2: return ADFFontSpec(textStyle: .title2, bold: true)
        case 3: return ADFFontSpec(textStyle: .title3, bold: true)
        case 4: return ADFFontSpec(textStyle: .headline)
        case 5: return ADFFontSpec(textStyle: .subheadline, bold: true)
        default: return ADFFontSpec(textStyle: .footnote, bold: true)
        }
    }

    /// Font for `fontSize: "small"` runs. A semantic text style (not a fixed
    /// point size) so the run scales with Dynamic Type alongside body text —
    /// `.subheadline` is ~0.88× body, matching the intended "slightly smaller".
    var smallFont: Font {
        Font(adfFontSpec: smallFontSpec)
    }

    /// Semantic spec of `smallFont`.
    var smallFontSpec: ADFFontSpec {
        ADFFontSpec(textStyle: .subheadline)
    }

    /// Font for sub/superscript runs. `.footnote` (~0.76× body) as a semantic
    /// style so it tracks Dynamic Type; a fixed `.system(size:)` would freeze
    /// while the surrounding body text grew.
    func subsupFont(monospaced: Bool) -> Font {
        .system(.footnote, design: monospaced ? .monospaced : .default)
    }

    /// Semantic spec of `subsupFont(monospaced:)`.
    func subsupFontSpec(monospaced: Bool) -> ADFFontSpec {
        ADFFontSpec(textStyle: .footnote, monospaced: monospaced)
    }

    /// Baseline shift for sub/superscript runs at the default text size
    /// (±30% of body). The view scales this by the live Dynamic Type factor
    /// (`SegmentedTextView`), so the raise tracks the growing font rather than
    /// staying a fixed point value.
    func subsupBaselineOffset(isSup: Bool) -> CGFloat {
        (isSup ? 1 : -1) * bodyPointSize * 0.3
    }

    /// Background tint applied to inline `code` runs.
    var codeBackground: Color {
        Color.gray.opacity(0.18)
    }

    /// Palette for a panel of the given type; `custom` panels honor the
    /// `panelColor` hex attribute when present.
    public func panelPalette(_ type: ADFPanelType, colorHex: String?) -> PanelPalette {
        switch type {
        case .info:
            return PanelPalette(background: Color.blue.opacity(0.12), accent: .blue, iconSystemName: "info.circle.fill")
        case .note:
            return PanelPalette(background: Color.purple.opacity(0.12), accent: .purple, iconSystemName: "note.text")
        case .tip:
            return PanelPalette(background: Color.teal.opacity(0.12), accent: .teal, iconSystemName: "lightbulb.fill")
        case .success:
            return PanelPalette(background: Color.green.opacity(0.12), accent: .green, iconSystemName: "checkmark.circle.fill")
        case .warning:
            return PanelPalette(background: Color.yellow.opacity(0.16), accent: .yellow, iconSystemName: "exclamationmark.triangle.fill")
        case .error:
            return PanelPalette(background: Color.red.opacity(0.12), accent: .red, iconSystemName: "xmark.octagon.fill")
        case .custom:
            let accent = colorHex.flatMap(Color.init(adfHex:)) ?? .gray
            return PanelPalette(background: accent.opacity(0.12), accent: accent, iconSystemName: "star.fill")
        }
    }
}

/// Resolved colors and icon for one panel.
public struct PanelPalette: Sendable, Hashable {
    public let background: Color
    public let accent: Color
    public let iconSystemName: String

    public init(background: Color, accent: Color, iconSystemName: String) {
        self.background = background
        self.accent = accent
        self.iconSystemName = iconSystemName
    }
}

extension Color {
    /// Parses an ADF hex color string (`#RGB`, `#RRGGBB`, or `#RRGGBBAA`,
    /// leading `#` optional). Returns `nil` for malformed input.
    public init?(adfHex: String) {
        guard let parsed = ADFHexColor(adfHex) else { return nil }
        self.init(
            .sRGB,
            red: parsed.red,
            green: parsed.green,
            blue: parsed.blue,
            opacity: parsed.opacity
        )
    }
}

/// Parsed sRGB components of an ADF hex color, plus the contrast math that
/// keeps text legible over author-supplied fills. Author hexes are fixed
/// colors (Confluence palettes are authored for light mode), so in dark mode
/// the scheme's default white text can land on a near-white fill; anything
/// rendered over such a fill derives its foreground from the fill's
/// luminance instead of the color scheme.
package struct ADFHexColor: Sendable, Hashable {
    package let red: Double
    package let green: Double
    package let blue: Double
    package let opacity: Double

    /// Accepts `#RGB`, `#RRGGBB`, or `#RRGGBBAA` (leading `#` optional).
    package init?(_ adfHex: String) {
        var hex = adfHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard !hex.isEmpty, hex.allSatisfy(\.isHexDigit), let value = UInt64(hex, radix: 16) else {
            return nil
        }
        switch hex.count {
        case 3:
            red = Double((value >> 8) & 0xF) / 15
            green = Double((value >> 4) & 0xF) / 15
            blue = Double(value & 0xF) / 15
            opacity = 1
        case 6:
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
            opacity = 1
        case 8:
            red = Double((value >> 24) & 0xFF) / 255
            green = Double((value >> 16) & 0xFF) / 255
            blue = Double((value >> 8) & 0xFF) / 255
            opacity = Double(value & 0xFF) / 255
        default:
            return nil
        }
    }

    /// WCAG 2.x relative luminance (linearized sRGB; ignores opacity).
    package var relativeLuminance: Double {
        func linearized(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearized(red) + 0.7152 * linearized(green) + 0.0722 * linearized(blue)
    }

    /// The text color with the higher WCAG contrast ratio over this fill —
    /// black above luminance 0.179 (where black's ratio overtakes white's),
    /// white below. `nil` when the fill is too transparent to dominate
    /// whatever renders beneath it (the scheme default stays correct then).
    package var contrastingForeground: Color? {
        guard opacity >= 0.6 else { return nil }
        return relativeLuminance >= 0.179 ? .black : .white
    }
}
