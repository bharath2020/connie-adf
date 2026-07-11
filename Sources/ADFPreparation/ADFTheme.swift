import SwiftUI
import ADFModel

/// Design tokens for preparation and rendering: fonts, spacing, and panel
/// palettes. Injected into `InlineComposer` / `DocumentPreparer` so every
/// `AttributedString` is built once, off-main, already styled.
public struct ADFTheme: Sendable, Hashable {
    /// Base font for body text.
    public var body: Font
    /// Monospaced font for inline code and code blocks.
    public var code: Font
    /// Base spacing unit in points.
    public var spacing: CGFloat
    /// Point size backing `body`. Used to derive metrics that need numbers
    /// (sub/superscript offset and size, the `fontSize: "small"` mark).
    public var bodyPointSize: CGFloat

    public init(
        body: Font = .body,
        code: Font = .system(.body, design: .monospaced),
        spacing: CGFloat = 8,
        bodyPointSize: CGFloat = 17
    ) {
        self.body = body
        self.code = code
        self.spacing = spacing
        self.bodyPointSize = bodyPointSize
    }

    public static let `default` = ADFTheme()

    /// Font for a heading of the given level (clamped to `1...6`).
    public func headingFont(_ level: Int) -> Font {
        switch min(max(level, 1), 6) {
        case 1: return .title.bold()
        case 2: return .title2.bold()
        case 3: return .title3.bold()
        case 4: return .headline
        case 5: return .subheadline.bold()
        default: return .footnote.bold()
        }
    }

    /// Derived font for `fontSize: "small"` runs (0.85× body).
    var smallFont: Font {
        .system(size: bodyPointSize * 0.85)
    }

    /// Derived font for sub/superscript runs (0.75× body).
    func subsupFont(monospaced: Bool) -> Font {
        .system(size: bodyPointSize * 0.75, design: monospaced ? .monospaced : .default)
    }

    /// Baseline shift for sub/superscript runs (±30% of body size).
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
        var hex = adfHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard !hex.isEmpty, hex.allSatisfy(\.isHexDigit), let value = UInt64(hex, radix: 16) else {
            return nil
        }
        let red: Double, green: Double, blue: Double, opacity: Double
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
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }
}
