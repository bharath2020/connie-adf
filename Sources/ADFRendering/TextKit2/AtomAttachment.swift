#if canImport(UIKit)
import UIKit
import SwiftUI
import ADFModel
import ADFPreparation

/// A vector-drawn inline pill/chip for one non-text `InlineAtom`.
///
/// Sized and painted entirely from `(atom, contentSizeCategory)` — a pure
/// function, no view hosting, no SwiftUI `ImageRenderer`, no
/// `NSTextAttachmentViewProvider` (§16 determinism). Mirrors `AtomView`'s
/// SwiftUI styling (`AtomCapsule` / `AtomChip` / emoji) so the TextKit 2
/// render arm matches the `WrappingInlineLayout` arm.
///
/// - `attachmentBounds(...)` returns a category-derived rect whose y-origin
///   drops the pill text's baseline onto the line baseline (mirroring
///   `WrappingInlineLayout`'s rowAscent − itemAscent placement).
/// - `image(forBounds:...)` renders the capsule/chip + text with a
///   `UIGraphicsImageRenderer`, reading the CURRENT traits at draw time so a
///   dark-mode flip repaints correctly without any content invalidation.
final class AtomAttachment: NSTextAttachment {
    private enum Style {
        case capsule(tint: UIColor)  // mention / status / date
        case chip                    // inline card / attachment / extension
        case plain                   // emoji `:name:` — secondary text, no bg
    }

    /// The pill's visible text (mention name, uppercased status, date, host,
    /// `:emoji:`), formatted exactly as `AtomView` would.
    let displayText: String
    /// Deterministic pill size — a pure function of `(atom, category)`.
    let pillSize: CGSize

    private let style: Style
    private let pillFont: UIFont
    private let horizontalPadding: CGFloat
    private let verticalPadding: CGFloat
    /// Pill-text baseline offset from the line baseline (negative = below).
    private let originY: CGFloat

    @MainActor
    init(atom: InlineAtom, categoryRawValue: String) {
        let traits = UITraitCollection(
            preferredContentSizeCategory: UIContentSizeCategory(rawValue: categoryRawValue))

        // `.callout` at this category — the text style the SwiftUI pills use.
        let callout = FontSpecResolver.shared.font(
            for: FontSpec(style: .callout), categoryRawValue: categoryRawValue)
        // Capsule/chip weight-medium callout; emoji rides the surrounding
        // prose (body), which is what SwiftUI's un-fonted `Text(":name:")`
        // inherits in a paragraph.
        let calloutMedium = UIFont.systemFont(ofSize: callout.pointSize, weight: .medium)
        let body = FontSpecResolver.shared.font(
            for: FontSpec(style: .body), categoryRawValue: categoryRawValue)

        let text: String
        let font: UIFont
        let style: Style
        switch atom {
        case .mention(let raw):
            text = AtomFormatting.mentionText(raw)
            font = calloutMedium
            style = .capsule(tint: .systemBlue)
        case .status(let raw, let color):
            text = raw.uppercased()
            font = calloutMedium
            style = .capsule(tint: color.uiTint)
        case .date(let ms):
            text = AtomFormatting.dateText(ms)
            font = calloutMedium
            style = .capsule(tint: .systemGray)
        case .emoji(let shortName):
            text = ":\(shortName):"
            font = body
            style = .plain
        case .inlineCard(let url):
            text = Self.cardText(url)
            font = callout
            style = .chip
        case .mediaInline(let attrs):
            text = attrs.alt ?? "attachment"
            font = callout
            style = .chip
        case .inlineExtension(let name):
            text = name
            font = callout
            style = .chip
        }

        // Paddings mirror AtomCapsule/AtomChip's @ScaledMetric(relativeTo:
        // .callout) 8/2 chrome. Using UIFontMetrics to scale chrome that
        // tracks a text style — NOT to resolve a semantic font — is the same
        // legal mirror the repo already applies to baked baseline offsets.
        let hPad: CGFloat
        let vPad: CGFloat
        switch style {
        case .plain:
            hPad = 0; vPad = 0            // emoji is bare inline text, no capsule
        case .capsule, .chip:
            let metrics = UIFontMetrics(forTextStyle: .callout)
            hPad = metrics.scaledValue(for: 8, compatibleWith: traits)
            vPad = metrics.scaledValue(for: 2, compatibleWith: traits)
        }

        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let width = textSize.width.rounded(.up) + hPad * 2
        let height = font.lineHeight.rounded(.up) + vPad * 2

        self.displayText = text
        self.style = style
        self.pillFont = font
        self.horizontalPadding = hPad
        self.verticalPadding = vPad
        self.pillSize = CGSize(width: width, height: height)
        // Drop the pill so its text baseline sits on the line baseline: the
        // text descender + bottom padding hang below, the ascent + top
        // padding rise above — WrappingInlineLayout's rowAscent − itemAscent.
        self.originY = font.descender - vPad

        super.init(data: nil, ofType: nil)
        // Belt-and-suspenders for layout paths that read `bounds` directly;
        // `attachmentBounds(...)` returns the identical rect.
        self.bounds = CGRect(origin: CGPoint(x: 0, y: originY), size: pillSize)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        CGRect(origin: CGPoint(x: 0, y: originY), size: pillSize)
    }

    override func image(
        forBounds imageBounds: CGRect,
        textContainer: NSTextContainer?,
        characterIndex charIndex: Int
    ) -> UIImage? {
        // Read the ambient traits (light/dark) at draw time and resolve every
        // dynamic color against them — so a dark-mode flip repaints correctly
        // the next time the row draws, with no content-storage invalidation.
        let traits = UITraitCollection.current
        let renderer = UIGraphicsImageRenderer(size: pillSize)
        return renderer.image { context in
            traits.performAsCurrent {
                draw(into: context.cgContext)
            }
        }
    }

    private func draw(into ctx: CGContext) {
        let rect = CGRect(origin: .zero, size: pillSize)
        let textColor: UIColor
        switch style {
        case .capsule(let tint):
            UIBezierPath(roundedRect: rect, cornerRadius: rect.height / 2).fill(with: tint.withAlphaComponent(0.18))
            textColor = tint
        case .chip:
            UIBezierPath(roundedRect: rect, cornerRadius: Self.chipCornerRadius)
                .fill(with: UIColor.systemGray.withAlphaComponent(0.14))
            textColor = .label
        case .plain:
            textColor = .secondaryLabel
        }
        (displayText as NSString).draw(
            at: CGPoint(x: horizontalPadding, y: verticalPadding),
            withAttributes: [.font: pillFont, .foregroundColor: textColor])
    }

    /// Default `ADFTheme.chipCornerRadius` — attachments are pure geometry
    /// with no environment, so the chip radius is the theme default the demo
    /// ships (SwiftUI chips read `theme.chipCornerRadius`, default 6).
    private static let chipCornerRadius: CGFloat = 6

    private static func cardText(_ url: String?) -> String {
        guard let url, !url.isEmpty else { return "link" }
        return URL(string: url)?.host ?? url
    }
}

private extension UIBezierPath {
    /// Fills the path with a color that resolves against the current traits.
    func fill(with color: UIColor) {
        color.setFill()
        fill()
    }
}

private extension ADFStatusColor {
    /// UIKit twin of `ADFStatusColor.tint` (SwiftUI). System colors keep
    /// dark-mode adaptivity; `yellow → orange` for legible text, matching the
    /// SwiftUI mapping.
    var uiTint: UIColor {
        switch self {
        case .neutral: return .systemGray
        case .purple: return .systemPurple
        case .blue: return .systemBlue
        case .red: return .systemRed
        case .yellow: return .systemOrange
        case .green: return .systemGreen
        }
    }
}
#endif
