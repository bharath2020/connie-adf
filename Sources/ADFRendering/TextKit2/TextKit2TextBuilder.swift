#if canImport(UIKit)
import SwiftUI
import UIKit
import ADFModel
import ADFPreparation

/// Everything a TextKit 2 row's layout and drawing depend on, resolved from
/// the prepared block and the SwiftUI environment. `Hashable` so the row
/// re-applies only when something actually changed, and so a measurement is
/// a pure function of (inputs, width) — the cache key of §2.8.
///
/// The `inherited…` fields stand for styling a container applies to its
/// text through view modifiers (a table header's semibold, a dark-mode
/// contrast foreground). Top-level rows have none; the fields exist so the
/// later container adapters feed them here instead of inventing their own
/// channel. `inheritedForeground` is honoured by the builder;
/// `inheritedFontWeight` is carried (cache key, redraw decision) and is
/// applied by the first adapter that sets it.
struct TextKit2RenderInputs: Hashable {
    var text: AttributedString
    var alignment: ADFAlignment?
    var isHeading: Bool
    var sizeCategory: UIContentSizeCategory
    var layoutDirection: LayoutDirection
    var displayScale: CGFloat
    var legibilityWeight: LegibilityWeight?
    var colorScheme: ColorScheme
    var inheritedForeground: Color?
    var inheritedFontWeight: Font.Weight?
    var inheritedTint: Color?

    init(
        text: AttributedString,
        alignment: ADFAlignment? = nil,
        isHeading: Bool = false,
        sizeCategory: UIContentSizeCategory = .large,
        layoutDirection: LayoutDirection = .leftToRight,
        displayScale: CGFloat = 3,
        legibilityWeight: LegibilityWeight? = nil,
        colorScheme: ColorScheme = .light,
        inheritedForeground: Color? = nil,
        inheritedFontWeight: Font.Weight? = nil,
        inheritedTint: Color? = nil
    ) {
        self.text = text
        self.alignment = alignment
        self.isHeading = isHeading
        self.sizeCategory = sizeCategory
        self.layoutDirection = layoutDirection
        self.displayScale = displayScale
        self.legibilityWeight = legibilityWeight
        self.colorScheme = colorScheme
        self.inheritedForeground = inheritedForeground
        self.inheritedFontWeight = inheritedFontWeight
        self.inheritedTint = inheritedTint
    }
}

extension NSAttributedString.Key {
    /// Run background fill of text without a link, drawn by the row itself
    /// (see `TextKit2RowView`) so its extent matches SwiftUI's; kept out of
    /// `.backgroundColor` so TextKit does not draw a second, shorter one.
    /// (Text with a link is drawn by TextKit 1, which fills
    /// `.backgroundColor` as SwiftUI does.)
    static let adfRunBackground = NSAttributedString.Key("adf.runBackground")
    /// A link's destination. Kept out of `.link`, which makes TextKit
    /// restyle the run with its own link colour and underline.
    static let adfLink = NSAttributedString.Key("adf.link")
}

/// Converts a prepared SwiftUI `AttributedString` into the
/// `NSAttributedString` the TextKit 2 row lays out.
@MainActor
enum TextKit2TextBuilder {
    /// The Dynamic Type factor SwiftUI's `@ScaledMetric(relativeTo: .body)`
    /// reports for a value of 1 at this category — what `SegmentedTextView`
    /// multiplies baked sub/superscript baseline offsets by.
    static func baselineScale(for category: UIContentSizeCategory) -> CGFloat {
        UIFontMetrics(forTextStyle: .body)
            .scaledValue(for: 1, compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
    }

    /// Builds the TextKit string. Foreground precedence per run: the
    /// prepared foreground (an author `textColor`, or the contrast colour
    /// the composer derived from a `backgroundColor` mark) first; then the
    /// inherited foreground; then the link tint, only for link runs nothing
    /// else coloured; else `.label`. `linkColor` is the row's tint
    /// (`inheritedTint` wins when set).
    static func attributedString(for inputs: TextKit2RenderInputs, linkColor: UIColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let scale = baselineScale(for: inputs.sizeCategory)
        let fallbackSpec = ADFFontSpec(textStyle: .body)
        let inheritedForeground = inputs.inheritedForeground.map(UIColor.init)
        let tint = inputs.inheritedTint.map(UIColor.init) ?? linkColor
        let hasLink = inputs.text.runs.contains { $0.link != nil }

        for run in inputs.text.runs {
            let string = String(inputs.text[run.range].characters)
            var attributes: [NSAttributedString.Key: Any] = [:]
            // Rows are only built for fully described text
            // (`TextKit2Eligibility`); the fallback never applies there.
            let spec = run.adfFontSpec ?? fallbackSpec
            attributes[.font] = TextKit2FontResolver.font(
                for: spec, category: inputs.sizeCategory, legibilityWeight: inputs.legibilityWeight
            )

            if let foreground = run.foregroundColor {
                attributes[.foregroundColor] = UIColor(foreground)
            } else if let inheritedForeground {
                attributes[.foregroundColor] = inheritedForeground
            } else if run.link != nil {
                attributes[.foregroundColor] = tint
            } else {
                attributes[.foregroundColor] = UIColor.label
            }
            if let background = run.backgroundColor {
                attributes[hasLink ? .backgroundColor : .adfRunBackground] = UIColor(background)
            }
            if run.underlineStyle != nil {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if run.strikethroughStyle != nil {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attributes[.adfLink] = link
            }
            if let offset = run.baselineOffset {
                attributes[.baselineOffset] = offset * scale
            }
            result.append(NSAttributedString(string: string, attributes: attributes))
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = nsAlignment(inputs.alignment, layoutDirection: inputs.layoutDirection)
        paragraph.baseWritingDirection = .natural
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineBreakStrategy = lineBreakStrategy
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }

    /// Measured, not assumed (`TextKit2LineBreakParityTests`; plan §4.2):
    /// SwiftUI's `Text` breaks lines exactly as TextKit does with the
    /// `.standard` strategy. Per-line ink extents of 2,052 near-full Latin
    /// strings at large/xxxLarge × 370/640/353.333 pt matched with
    /// `.standard` and `.pushOut` and missed 66 times with no strategy (one
    /// word later on nearly full lines); 1,278 Korean, Japanese, Arabic and
    /// accented-Latin strings matched only with `.standard` (`.pushOut`
    /// alone missed 257 Korean strings — `.standard` adds Hangul word
    /// priority).
    static let lineBreakStrategy: NSParagraphStyle.LineBreakStrategy = .standard

    /// The paragraph alignment SwiftUI's `multilineTextAlignment` produces:
    /// leading / trailing resolve against the SwiftUI layout direction, not
    /// the text's own direction (`.natural` would right-align an Arabic
    /// paragraph in a left-to-right layout, where SwiftUI keeps it left).
    static func nsAlignment(_ alignment: ADFAlignment?, layoutDirection: LayoutDirection) -> NSTextAlignment {
        let rtl = layoutDirection == .rightToLeft
        switch alignment {
        case nil: return rtl ? .right : .left
        case .center: return .center
        case .end: return rtl ? .left : .right
        }
    }
}
#endif
