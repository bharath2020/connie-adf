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
    /// where that segment's content begins. Each atom segment appends exactly
    /// one attachment character (U+FFFC, one UTF-16 unit — Task 10), so a
    /// following segment's absolute start advances past it.
    public let segmentUTF16Starts: [Int]

    /// Plain text per segment. Atom segments store `""` here (the pill has no
    /// searchable text) even though they contribute one attachment character
    /// to `attributed`; the absolute offset that character occupies is tracked
    /// by `segmentUTF16Starts`, so cross-segment `utf16Range` stays exact.
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
    /// `TextKit2RowView.nsAlignment` already resolves `.center` and (its
    /// direction-flipped) `.trailing` case to concrete values before calling
    /// `make`; its default case (no alignment mark — the common "leading"
    /// row) passes `.natural` through instead, since `NSTextAlignment` has no
    /// "leading" case of its own. `make` resolves THAT `.natural` signal to
    /// an explicit `.left`/`.right` per `rightToLeft` (Task 12) — mirroring
    /// `RichTextBlockView`'s `nil → .leading` mapping. This matters because
    /// leaving `paragraphStyle.alignment` as `.natural` would instead let
    /// `NSParagraphStyle` resolve it per-PARAGRAPH, from that text's own
    /// first-strong Bidi character — so an Arabic paragraph would render
    /// right-aligned even inside an LTR host, diverging from the SwiftUI arm.
    /// `baseWritingDirection` stays `.natural` regardless: per-paragraph Bidi
    /// run direction (which glyphs go which way within the line) is still
    /// TextKit's to resolve — only the alignment SIDE is pinned to the host.
    @MainActor
    public static func make(
        segments: [InlineSegment],
        categoryRawValue: String,
        alignment: NSTextAlignment,
        baselineScale: CGFloat,
        rightToLeft: Bool
    ) -> TextRowContent {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = alignment == .natural ? (rightToLeft ? .right : .left) : alignment
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
            case .atom(let atom, _):
                // Task 10: each atom contributes ONE attachment character
                // (U+FFFC) carrying a vector-drawn `AtomAttachment` pill. The
                // char keeps line metrics sane and advances following
                // segments' absolute UTF-16 starts; the segment's own stored
                // string stays "" (a pill has no searchable text).
                appendAtom(atom, categoryRawValue: categoryRawValue, into: result)
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

    /// Appends one attachment character for an atom. On iOS the character
    /// carries a vector-drawn `AtomAttachment` pill; on macOS (no render arm —
    /// `AtomAttachment` is UIKit-only) it is a bare U+FFFC so the UTF-16
    /// bookkeeping (`segmentUTF16Starts`, `attributed.length`) is identical on
    /// both platforms, keeping `utf16Range`'s cross-segment semantics testable
    /// under `swift test`. The character carries the body font so the line's
    /// metrics stay sane even when the pill is the row's only content.
    @MainActor
    private static func appendAtom(
        _ atom: InlineAtom,
        categoryRawValue: String,
        into result: NSMutableAttributedString
    ) {
        let font = FontSpecResolver.shared.font(for: .body, categoryRawValue: categoryRawValue)
        #if canImport(UIKit)
        let attachment = AtomAttachment(atom: atom, categoryRawValue: categoryRawValue)
        let attributed = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
        attributed.addAttribute(.font, value: font, range: NSRange(location: 0, length: attributed.length))
        result.append(attributed)
        #else
        _ = atom
        result.append(NSAttributedString(string: "\u{FFFC}", attributes: [.font: font]))
        #endif
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

    /// Inverse of `utf16Range`: the `Character` offset within
    /// `segmentStrings[index]` at which `utf16Offset` UTF-16 units of that
    /// segment's own text have been consumed. Used by the selection engine to
    /// turn a live row's UTF-16 hit (from `closestUTF16Offset`) back into a
    /// corpus part + `Character` offset. Surrogate-safe: it counts by
    /// `Character`, never slicing mid-scalar.
    public static func characterOffset(forUTF16Offset utf16Offset: Int, inSegment index: Int, of content: TextRowContent) -> Int {
        let string = content.segmentStrings[index]
        var utf16Count = 0
        var charCount = 0
        for character in string {
            if utf16Count >= utf16Offset { break }
            utf16Count += character.utf16.count
            charCount += 1
        }
        return charCount
    }
}
