#if canImport(UIKit)
import SwiftUI
import UIKit
import ADFModel
import ADFPreparation

/// Everything the TextKit 2 row's layout depends on. `Hashable` so the
/// representable re-applies only when something actually changed, and so a
/// measurement is a pure function of (inputs, width).
struct TextKit2TextInputs: Hashable {
    let text: AttributedString
    let alignment: ADFAlignment?
    let isHeading: Bool
    let sizeCategory: UIContentSizeCategory
    let layoutDirection: LayoutDirection
    let displayScale: CGFloat
}

extension NSAttributedString.Key {
    /// Run background fill, drawn by the row itself (see
    /// `TextKit2RowView.draw`) so its extent matches SwiftUI's; kept out of
    /// `.backgroundColor` so TextKit does not draw a second, shorter one.
    static let adfRunBackground = NSAttributedString.Key("adf.runBackground")
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

    /// Builds the TextKit string. `linkColor` is used only for link runs that
    /// carry no `textColor` / `backgroundColor`-derived mark colour — SwiftUI
    /// lets an explicit mark colour win over the link tint.
    static func attributedString(for inputs: TextKit2TextInputs, linkColor: UIColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let scale = baselineScale(for: inputs.sizeCategory)
        let fallbackSpec = ADFFontSpec(textStyle: .body)

        for run in inputs.text.runs {
            let string = String(inputs.text[run.range].characters)
            var attributes: [NSAttributedString.Key: Any] = [:]
            let spec = run.adfFontSpec ?? fallbackSpec
            attributes[.font] = TextKit2FontResolver.font(for: spec, category: inputs.sizeCategory)

            if let foreground = run.foregroundColor {
                attributes[.foregroundColor] = UIColor(foreground)
            } else if run.link != nil {
                attributes[.foregroundColor] = linkColor
            } else {
                attributes[.foregroundColor] = UIColor.label
            }
            if let background = run.backgroundColor {
                attributes[.adfRunBackground] = UIColor(background)
            }
            if run.underlineStyle != nil {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if run.strikethroughStyle != nil {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attributes[.link] = link
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

    /// Measured (parity corpus, see `TextKit2WrapParityTests`): SwiftUI's
    /// `Text` places line breaks exactly where TextKit does with no push-out
    /// strategy; `.standard` / `.pushOut` would move a word onto the last
    /// line where SwiftUI does not.
    static let lineBreakStrategy: NSParagraphStyle.LineBreakStrategy = []

    static func nsAlignment(_ alignment: ADFAlignment?, layoutDirection: LayoutDirection) -> NSTextAlignment {
        switch alignment {
        case nil: return .natural
        case .center: return .center
        case .end: return layoutDirection == .rightToLeft ? .left : .right
        }
    }
}
#endif
