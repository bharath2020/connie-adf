#if canImport(UIKit)
import SwiftUI
import UIKit
import ADFModel
import ADFPreparation

/// Everything a TextKit 2 row's text and layout depend on, resolved from
/// the prepared block and the SwiftUI environment. `Hashable` so the row
/// rebuilds only when something actually changed, and so a measurement is
/// a pure function of (inputs, width) — the cache key of §2.8. The colour
/// scheme is not among them: the built string is the same in both schemes
/// (its colours are dynamic, resolved when the row draws), so the scheme
/// is the row's paint input, applied apart
/// (`TextKit2RowView.apply(_:colorScheme:ownerID:)`).
///
/// `layoutPolicy` says whether the text wraps at the proposed width
/// (`.wrapping`, the default: paragraphs, headings, list text) or is laid
/// out once at its natural width and never wraps (`.natural`: code, see
/// `TextKit2OwnerKind.layoutPolicy`). It is part of the key, so changing
/// it rebuilds the row's text and lays it out again.
struct TextKit2RenderInputs: Hashable {
    var text: AttributedString
    var alignment: ADFAlignment?
    var isHeading: Bool
    var sizeCategory: UIContentSizeCategory
    var layoutDirection: LayoutDirection
    var displayScale: CGFloat
    var legibilityWeight: LegibilityWeight?
    var layoutPolicy: TextKit2LayoutPolicy

    init(
        text: AttributedString,
        alignment: ADFAlignment? = nil,
        isHeading: Bool = false,
        sizeCategory: UIContentSizeCategory = .large,
        layoutDirection: LayoutDirection = .leftToRight,
        displayScale: CGFloat = 3,
        legibilityWeight: LegibilityWeight? = nil,
        layoutPolicy: TextKit2LayoutPolicy = .wrapping
    ) {
        self.text = text
        self.alignment = alignment
        self.isHeading = isHeading
        self.sizeCategory = sizeCategory
        self.layoutDirection = layoutDirection
        self.displayScale = displayScale
        self.legibilityWeight = legibilityWeight
        self.layoutPolicy = layoutPolicy
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
    /// A resolved smart link's title (`SmartLinkShown`), on its icon, space
    /// and title: the row names the link's VoiceOver action by it.
    static let adfLinkTitle = NSAttributedString.Key("adf.linkTitle")
}

/// Converts a prepared SwiftUI `AttributedString` into the
/// `NSAttributedString` the TextKit 2 row lays out.
@MainActor
enum TextKit2TextBuilder {
    /// The Dynamic Type factor SwiftUI's `@ScaledMetric(relativeTo: .body)`
    /// reports for a value of 1 at this category — what `SegmentedTextView`
    /// multiplies baked sub/superscript baseline offsets by. Memoized per
    /// category.
    static func baselineScale(for category: UIContentSizeCategory) -> CGFloat {
        if let cached = baselineScales[category] { return cached }
        let scale = UIFontMetrics(forTextStyle: .body)
            .scaledValue(for: 1, compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
        baselineScales[category] = scale
        return scale
    }

    private static var baselineScales: [UIContentSizeCategory: CGFloat] = [:]

    /// Builds the TextKit string. Foreground precedence per run: the
    /// prepared foreground (an author `textColor`, or the contrast colour
    /// the composer derived from a `backgroundColor` mark) first; then, for
    /// a link run, `linkColor` (`Text` colours links with the tint, which a
    /// foreground style does not override); else `.label`.
    ///
    /// Displayed smart links (`SmartLinkDisplay`, the input the leaf hands
    /// over): a resolving run is an ordinary run whose dimmed colour is its
    /// prepared foreground; a resolved link's icon character becomes an
    /// `NSTextAttachment` (`smartLinkIcon`), and its runs carry the title
    /// for the row's link action (`adfLinkTitle`).
    static func attributedString(for inputs: TextKit2RenderInputs, linkColor: UIColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let scale = baselineScale(for: inputs.sizeCategory)
        let fallbackSpec = ADFFontSpec(textStyle: .body)
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
            } else if run.link != nil {
                attributes[.foregroundColor] = linkColor
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
            if case .resolved(_, let title)? = run[SmartLinkShownAttribute.self]?.kind {
                attributes[.adfLinkTitle] = title
            }
            if let icon = run[SmartLinkIconAttribute.self], let font = attributes[.font] as? UIFont,
               let image = smartLinkIcon(icon, font: font, color: attributes[.foregroundColor] as? UIColor ?? linkColor) {
                let attachment = NSMutableAttributedString(attachment: image)
                attachment.addAttributes(attributes, range: NSRange(location: 0, length: attachment.length))
                result.append(attachment)
                continue
            }
            result.append(NSAttributedString(string: string, attributes: attributes))
        }

        let paragraph = NSMutableParagraphStyle()
        // Text that never wraps (`.natural`) is laid out in the row's
        // unbounded container, where only left-aligned lines start at the
        // row's own edge: a right-aligned or centred line would sit against
        // the far end of that container. So its lines are always left
        // aligned, whatever the style or layout direction asks; the break
        // mode below never acts on it, because no line reaches the
        // container's width (`TextKit2RowView.layoutResult`).
        paragraph.alignment = inputs.layoutPolicy == .natural
            ? .left
            : nsAlignment(inputs.alignment, layoutDirection: inputs.layoutDirection)
        paragraph.baseWritingDirection = .natural
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineBreakStrategy = lineBreakStrategy
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }

    /// A resolved smart link's icon: the kind's SF Symbol at the run's font
    /// (point size and weight, as `Text(Image(systemName:))` sizes it from
    /// the font), tinted with the link colour, its baseline on the text's
    /// baseline. `nil` if the symbol is missing (the icon character then
    /// draws nothing visible).
    static func smartLinkIcon(_ icon: ADFSmartLinkMetadata.Icon, font: UIFont, color: UIColor) -> NSTextAttachment? {
        let configuration = UIImage.SymbolConfiguration(font: font)
        guard let symbol = UIImage(systemName: SmartLinkDisplay.symbolName(icon), withConfiguration: configuration) else {
            return nil
        }
        let image = symbol.withTintColor(color, renderingMode: .alwaysOriginal)
        let attachment = NSTextAttachment(image: image)
        let baseline = image.baselineOffsetFromBottom ?? 0
        attachment.bounds = CGRect(x: 0, y: -baseline, width: image.size.width, height: image.size.height)
        return attachment
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
