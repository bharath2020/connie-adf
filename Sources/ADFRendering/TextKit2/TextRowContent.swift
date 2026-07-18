import Foundation
import SwiftUI
import ADFPreparation

#if canImport(UIKit)
import UIKit
private typealias PlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
private typealias PlatformColor = NSColor
#endif

private typealias SwiftUIAttrs = AttributeScopes.SwiftUIAttributes

/// A single text row's content, converted once from prepared `InlineSegment`s
/// into a plain `NSAttributedString` for TextKit 2 layout.
///
/// This is BASE text only — search-highlight and selection state never enter
/// this conversion; those are drawn in a later draw pass over the same
/// content, never baked into the string itself.
public struct TextRowContent {
    /// The row's full text, ready for TextKit 2 layout.
    public let attributed: NSAttributedString

    /// One entry per input segment: the UTF-16 offset (into `attributed`)
    /// where that segment's text begins. Atom segments append no run at all
    /// (a no-op), so a following segment can share the same start as one
    /// that preceded an atom.
    public let segmentUTF16Starts: [Int]

    /// Plain text per segment ("" for atoms in phase 2 — Task 10 gives atoms
    /// an attachment character instead).
    public let segmentStrings: [String]

    #if canImport(UIKit)
    private static let labelColor: PlatformColor = .label
    private static let linkTintColor: PlatformColor = .tintColor
    #elseif canImport(AppKit)
    private static let labelColor: PlatformColor = .labelColor
    private static let linkTintColor: PlatformColor = .linkColor
    #endif

    /// Converts `segments` into a single attributed string plus offset
    /// tables. Whole-string defaults (label-color foreground, one shared
    /// paragraph style) are applied first per run, then per-run attributes
    /// (SwiftUI color/underline/strike/baseline, Foundation link) override
    /// them — so unstyled text still tracks `.label`/`.labelColor` dynamically
    /// while marked-up runs keep their explicit styling.
    ///
    /// `rightToLeft` is accepted for signature parity with later tasks
    /// (measurement/attachment callers use the same `Inputs` shape); the
    /// paragraph style's writing direction is always `.natural` here, per
    /// the phase-2 spec — the caller has already resolved `alignment` using
    /// its own layout-direction knowledge before calling `make`.
    @MainActor
    public static func make(
        segments: [InlineSegment],
        categoryRawValue: String,
        alignment: NSTextAlignment,
        baselineScale: CGFloat,
        rightToLeft: Bool
    ) -> TextRowContent {
        _ = rightToLeft

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = alignment
        paragraphStyle.baseWritingDirection = .natural

        let result = NSMutableAttributedString()
        var starts: [Int] = []
        var strings: [String] = []
        starts.reserveCapacity(segments.count)
        strings.reserveCapacity(segments.count)

        for segment in segments {
            starts.append(result.length)
            switch segment {
            case .text(let text):
                strings.append(convert(text, categoryRawValue: categoryRawValue,
                                        baselineScale: baselineScale, paragraphStyle: paragraphStyle,
                                        into: result))
            case .atom:
                // Phase 2: atoms append nothing to the string (Task 10
                // replaces this with an `NSTextAttachment` character).
                strings.append("")
            }
        }

        return TextRowContent(attributed: result, segmentUTF16Starts: starts, segmentStrings: strings)
    }

    /// Converts one `.text` segment's runs, appending each run's substring
    /// (with its resolved attributes) to `result`. Returns the segment's
    /// plain text.
    @MainActor
    private static func convert(
        _ text: AttributedString,
        categoryRawValue: String,
        baselineScale: CGFloat,
        paragraphStyle: NSParagraphStyle,
        into result: NSMutableAttributedString
    ) -> String {
        var plain = ""
        for run in text.runs {
            let runString = String(text[run.range].characters)
            plain += runString

            let spec = run[FontSpecAttribute.self] ?? .body
            let font = FontSpecResolver.shared.font(for: spec, categoryRawValue: categoryRawValue)

            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: Self.labelColor,
                .paragraphStyle: paragraphStyle
            ]
            if let foreground = run[SwiftUIAttrs.ForegroundColorAttribute.self] {
                attrs[.foregroundColor] = PlatformColor(foreground)
            }
            if let background = run[SwiftUIAttrs.BackgroundColorAttribute.self] {
                attrs[.backgroundColor] = PlatformColor(background)
            }
            if run[SwiftUIAttrs.UnderlineStyleAttribute.self] != nil {
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if run[SwiftUIAttrs.StrikethroughStyleAttribute.self] != nil {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let baseline = run[SwiftUIAttrs.BaselineOffsetAttribute.self] {
                attrs[.baselineOffset] = CGFloat(baseline) * baselineScale
            }
            if let link = run[AttributeScopes.FoundationAttributes.LinkAttribute.self] {
                // SwiftUI's `Text` tints links automatically; this custom
                // conversion does not, so bake the tint explicitly — this
                // wins over any mark-driven foreground color, matching
                // SwiftUI's own precedence.
                attrs[.link] = link
                attrs[.foregroundColor] = Self.linkTintColor
            }

            result.append(NSAttributedString(string: runString, attributes: attrs))
        }
        return plain
    }

    /// Maps a `Character` range within `segmentStrings[index]` to the
    /// equivalent UTF-16 range within `content.attributed`, by walking the
    /// segment's stored string by `Character` and summing UTF-16 counts —
    /// O(segment length). Used only by search/selection queries, never
    /// during idle scroll/layout.
    public static func utf16Range(charRange: Range<Int>, inSegment index: Int, of content: TextRowContent) -> NSRange {
        let string = content.segmentStrings[index]
        var precedingUTF16 = 0
        var rangeUTF16 = 0
        for (charIndex, character) in string.enumerated() {
            if charIndex < charRange.lowerBound {
                precedingUTF16 += character.utf16.count
            } else if charIndex < charRange.upperBound {
                rangeUTF16 += character.utf16.count
            } else {
                break
            }
        }
        let location = content.segmentUTF16Starts[index] + precedingUTF16
        return NSRange(location: location, length: rangeUTF16)
    }
}
