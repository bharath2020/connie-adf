import CoreGraphics
import SwiftUI
import ADFPreparation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Where one custom emoji's lookup stands, as the leaves draw it. The
/// document's emoji coordinator (a later slice) keeps one per key, behind
/// an observable entry; a leaf hands the stages of its own keys to
/// `EmojiDisplay.apply`. With no resolver installed there are no stages at
/// all (`apply(nil, …)`): every custom emoji shows its short name.
enum EmojiStage: Equatable, Sendable {
    /// Not landed yet (not asked, dwelling, queued or in flight): a blank
    /// square the size of the font's ascent (`EmojiDisplay.Box`), so nothing
    /// moves when the image lands.
    case pending
    /// The image, drawn in that same square.
    case resolved(ADFResolvedImage)
    /// The lookup threw: the short name, as with no resolver.
    case failed

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.pending, .pending), (.failed, .failed): return true
        case (.resolved(let a), .resolved(let b)): return EmojiImage(a) == EmojiImage(b)
        default: return false
        }
    }
}

extension EmojiKey {
    /// The public reference the host's `ADFEmojiResolver` is asked about.
    var reference: ADFEmojiReference { ADFEmojiReference(id: id, shortName: shortName) }
}

/// A resolved emoji image as an attribute value: equal when it is the same
/// bitmap at the same scale (`CGImage` is immutable), so a TextKit 2 row's
/// inputs compare without touching pixels.
struct EmojiImage: Hashable, @unchecked Sendable {
    // `@unchecked`: see `ADFResolvedImage`.
    let resolved: ADFResolvedImage

    init(_ resolved: ADFResolvedImage) {
        self.resolved = resolved
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.resolved.cgImage === rhs.resolved.cgImage && lhs.resolved.scale == rhs.resolved.scale
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(resolved.cgImage))
        hasher.combine(resolved.scale)
    }
}

/// What a displayed custom emoji is showing, set by `EmojiDisplay` on every
/// character it produced for the emoji: both renderers draw it, and the
/// spoken text of both derives from it.
struct EmojiShown: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// The short name as authored (`":ld-custom-6:"`), in the secondary
        /// colour: no resolver, or the lookup failed.
        case shortName
        /// A blank square the size of the font's ascent (one U+FFFC): the
        /// lookup has not landed.
        case box
        /// The image in that square (one U+FFFC).
        case image(EmojiImage)
    }

    let key: EmojiKey
    let kind: Kind
    /// The emoji's place among its owner's custom emoji, from 0 in text
    /// order. Keeps two adjacent emoji with the same key distinct runs, so
    /// each is drawn and spoken on its own.
    let occurrence: Int
}

/// The displayed-text attribute `EmojiDisplay` adds (rendering-only:
/// prepared text never carries it).
enum EmojiShownAttribute: AttributedStringKey, Sendable {
    typealias Value = EmojiShown
    static let name = "adf.emojiShown"
}

/// The one pure function from custom-emoji stages to displayed text, shared
/// by both renderers so they cannot diverge, and the spoken text both
/// derive from it.
///
/// Prepared text holds each custom emoji as one U+FFFC carrying its key
/// (`adfEmoji`). The leaves of an owner with emoji keys (`emojiKeys` not
/// empty: nearly no owner) run `apply` after search painting and the
/// smart-link substitution, on every evaluation, whether or not a resolver
/// is installed: the raw U+FFFC is never drawn.
///
/// - SwiftUI composes a box or image as `Text(Image(…))` in the leaf's
///   `Text` (`SmartLinkDisplay.composedText`, `text(_:box:)`).
/// - The TextKit 2 builder makes each box or image an `NSTextAttachment`
///   with square bounds of the font's ascent, on the baseline
///   (`TextKit2TextBuilder.emojiAttachment`). Neither engine's line grows
///   (`Box`).
/// - The short name is ordinary text in both.
enum EmojiDisplay {
    private typealias SUI = AttributeScopes.SwiftUIAttributes
    private typealias Emoji = AttributeScopes.ADFAttributes.EmojiAttribute

    // MARK: Displayed text

    /// `segments` with every custom emoji replaced by what its stage shows:
    /// the short name (no stages, which means no resolver; or `.failed`),
    /// a blank square (`.pending`, or a key without a stage while a
    /// resolver is installed) or the image (`.resolved`). Returns the input
    /// untouched when no segment holds an emoji.
    ///
    /// A word-chunked (atom) paragraph is not chunked again: a short name
    /// holds no whitespace, so it stays inside the chunk the U+FFFC was in.
    static func apply(_ stages: [EmojiKey: EmojiStage]?, to segments: [InlineSegment]) -> [InlineSegment] {
        var result: [InlineSegment]?
        var occurrence = 0
        for (index, segment) in segments.enumerated() {
            guard case .text(let text) = segment,
                  let displayed = apply(stages, to: text, occurrence: &occurrence) else {
                result?.append(segment)
                continue
            }
            if result == nil { result = Array(segments[..<index]) }
            result?.append(.text(displayed))
        }
        return result ?? segments
    }

    /// One attributed string with its custom emoji replaced, or `nil` when
    /// it holds none. `occurrence` numbers the emoji across an owner's
    /// segments.
    static func apply(
        _ stages: [EmojiKey: EmojiStage]?, to text: AttributedString, occurrence: inout Int
    ) -> AttributedString? {
        let runs = text.runs[Emoji.self]
        guard runs.contains(where: { $0.0 != nil }) else { return nil }
        var output = AttributedString()
        for (key, range) in runs {
            guard let key else {
                output.append(text[range])
                continue
            }
            var attributes = text[range].runs.first?.attributes ?? AttributeContainer()
            attributes[Emoji.self] = nil
            let kind = shownKind(for: key, stages: stages)
            // Adjacent emoji with the same key share one prepared run.
            for _ in text[range].characters {
                var piece = attributes
                piece[EmojiShownAttribute.self] = EmojiShown(key: key, kind: kind, occurrence: occurrence)
                occurrence += 1
                switch kind {
                case .shortName:
                    piece[SUI.ForegroundColorAttribute.self] = Color.secondary
                    output.append(AttributedString(key.shortName, attributes: piece))
                case .box, .image:
                    output.append(AttributedString(String(EmojiKey.character), attributes: piece))
                }
            }
        }
        return output
    }

    /// What a key's stage shows. `nil` stages: no resolver, the short name.
    static func shownKind(for key: EmojiKey, stages: [EmojiKey: EmojiStage]?) -> EmojiShown.Kind {
        guard let stages else { return .shortName }
        switch stages[key] ?? .pending {
        case .pending: return .box
        case .resolved(let image): return .image(EmojiImage(image))
        case .failed: return .shortName
        }
    }

    /// The custom emoji keys in prepared segments, de-duplicated in text
    /// order: for a leaf whose caller did not hand it the owner's
    /// `emojiKeys` (a media caption). Walks the runs of each text segment.
    static func keys(in segments: [InlineSegment]) -> [EmojiKey] {
        var keys: [EmojiKey] = []
        for segment in segments {
            guard case .text(let text) = segment else { continue }
            for (key, _) in text.runs[Emoji.self] {
                if let key, !keys.contains(key) { keys.append(key) }
            }
        }
        return keys
    }

    // MARK: Spoken text

    /// How VoiceOver names a custom emoji: its short name without the
    /// surrounding colons, hyphens and underscores read as spaces, e.g.
    /// `":ld-custom-6:"` → `"ld custom 6"`. A name with nothing left is read
    /// as "emoji".
    static func spokenName(_ shortName: String) -> String {
        let words = shortName
            .split(whereSeparator: { $0 == ":" || $0 == "-" || $0 == "_" || $0.isWhitespace })
            .joined(separator: " ")
        return words.isEmpty ? "emoji" : words
    }

    // MARK: The square box

    /// The square a box or image fills: it sits on the baseline and its
    /// side is the run font's ascent, so the line keeps its height and
    /// baselines on both engines.
    ///
    /// Not the line height: `Text` counts an inline image's whole height as
    /// ascent and ignores a baseline the image carries
    /// (`UIImage.withBaselineOffset`), and `Text.baselineOffset` lowering it
    /// adds the offset to the descent instead. Measured: a line-height square
    /// lowered by the descent made a body line 4 pt taller on iOS 26.3 (6 pt
    /// on macOS) and dropped its baseline, while TextKit 2 (which counts
    /// only fonts, `TextKit2RowView.glyphMetrics`) kept it, so the two
    /// engines disagreed and a failed lookup (box → short name) moved every
    /// row below. A square no taller than the ascent changes neither
    /// (`EmojiDisplayTests.swiftUILineMetrics`, `textKit2LineMetrics`).
    struct Box: Hashable, Sendable {
        let side: CGFloat

        /// The box for a font's ascent, floored to a sixth of a point (a
        /// whole pixel at 2x and 3x) so rounding never makes it taller than
        /// the ascent.
        init(ascent: CGFloat) {
            side = (max(ascent, 0) * 6).rounded(.down) / 6
        }
    }

    #if canImport(UIKit)
    /// The box for a resolved platform font (TextKit 2).
    static func box(for font: UIFont) -> Box {
        Box(ascent: font.ascender)
    }
    #endif

    /// The environment SwiftUI resolves a run's font in, for the box of a
    /// `Text` piece: the Dynamic Type size and the Bold Text setting.
    struct Metrics: Hashable, Sendable {
        var dynamicTypeSize: DynamicTypeSize = .large
        var legibilityWeight: LegibilityWeight? = nil

        /// The box for a run's font spec; the body style when the run has
        /// none (rows with an undescribable font never reach TextKit 2, and
        /// SwiftUI then sizes the box as body text).
        @MainActor
        func box(for spec: ADFFontSpec?) -> Box {
            let spec = spec ?? ADFFontSpec(textStyle: .body)
            #if canImport(UIKit)
            return EmojiDisplay.box(for: TextKit2FontResolver.font(
                for: spec, category: dynamicTypeSize.uiContentSizeCategory, legibilityWeight: legibilityWeight
            ))
            #elseif canImport(AppKit)
            let font = NSFont.preferredFont(forTextStyle: EmojiDisplay.appKitTextStyle(spec.textStyle))
            return Box(ascent: font.ascender)
            #else
            return Box(ascent: 16)
            #endif
        }
    }

    #if canImport(AppKit) && !canImport(UIKit)
    static func appKitTextStyle(_ style: ADFFontSpec.TextStyle) -> NSFont.TextStyle {
        switch style {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .body: return .body
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        }
    }
    #endif

    // MARK: Images

    /// A fully transparent 1×1 bitmap: the box, scaled to its side.
    nonisolated(unsafe) static let blank: CGImage = {
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }()

    /// `image` as a square bitmap: itself when it already is one, else
    /// centred on a transparent square of its longer side, so it fills the
    /// box at its own aspect ratio and the box never changes width. Run
    /// once where an image lands (the coordinator), never per display: a
    /// new bitmap per call would make every displayed text unequal.
    /// `text(_:box:)` and the TextKit 2 attachment scale a bitmap by its
    /// longer side, so an image that was not squared draws narrower than
    /// the box.
    static func squared(_ image: ADFResolvedImage) -> ADFResolvedImage {
        let width = image.cgImage.width, height = image.cgImage.height
        guard width != height, width > 0, height > 0 else { return image }
        let side = max(width, height)
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.draw(image.cgImage, in: CGRect(x: (side - width) / 2, y: (side - height) / 2, width: width, height: height))
        guard let squared = context.makeImage() else { return image }
        return ADFResolvedImage(cgImage: squared, scale: image.scale)
    }

    /// The bitmap a box or image piece draws, square.
    static func bitmap(_ kind: EmojiShown.Kind) -> CGImage? {
        switch kind {
        case .shortName: return nil
        case .box: return blank
        case .image(let image): return image.resolved.cgImage
        }
    }

    // MARK: SwiftUI

    /// A box or image piece as a `Text`: the square bitmap scaled to the
    /// box's side, on the baseline (`Box`), where the TextKit 2 attachment
    /// draws it too. `nil` for a short-name piece (drawn as its attributed
    /// text).
    static func text(_ kind: EmojiShown.Kind, box: Box) -> Text? {
        guard let bitmap = bitmap(kind), box.side > 0 else { return nil }
        let pixels = CGFloat(max(bitmap.width, bitmap.height))
        return Text(Image(decorative: bitmap, scale: pixels / box.side))
    }
}
