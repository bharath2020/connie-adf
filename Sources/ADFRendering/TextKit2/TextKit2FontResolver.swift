#if canImport(UIKit)
import SwiftUI
import UIKit
import ADFPreparation

/// Resolves a prepared `ADFFontSpec` to the `UIFont` SwiftUI would use for
/// the same semantic `Font` at a given content size category.
///
/// Fonts come from the text style's *preferred* descriptor
/// (`UIFont.preferredFont(forTextStyle:compatibleWith:)`), then symbolic
/// traits (bold / italic) and the monospaced design are layered on that
/// descriptor. That is what keeps the style's line metrics — ascent,
/// descent, leading — identical to SwiftUI's: a font created from a point
/// size (`UIFont.monospacedSystemFont(ofSize:…)`, `UIFontMetrics.scaledFont`)
/// carries the face's native metrics instead and changes the line pitch.
@MainActor
enum TextKit2FontResolver {
    private struct Key: Hashable {
        let spec: ADFFontSpec
        let category: UIContentSizeCategory
    }

    private static var cache: [Key: UIFont] = [:]

    /// The platform font for `spec` at `category`. Memoized: the same
    /// (spec, category) always returns the same `UIFont` instance.
    static func font(for spec: ADFFontSpec, category: UIContentSizeCategory) -> UIFont {
        let key = Key(spec: spec, category: category)
        if let cached = cache[key] { return cached }
        let font = resolve(spec, category: category)
        cache[key] = font
        return font
    }

    private static func resolve(_ spec: ADFFontSpec, category: UIContentSizeCategory) -> UIFont {
        let traits = UITraitCollection(preferredContentSizeCategory: category)
        let base = UIFont.preferredFont(forTextStyle: uiTextStyle(spec.textStyle), compatibleWith: traits)
        var descriptor = base.fontDescriptor
        if spec.monospaced, let mono = descriptor.withDesign(.monospaced) {
            descriptor = mono
        }
        var symbolic = descriptor.symbolicTraits
        if spec.bold { symbolic.insert(.traitBold) }
        if spec.italic { symbolic.insert(.traitItalic) }
        if symbolic != descriptor.symbolicTraits, let traited = descriptor.withSymbolicTraits(symbolic) {
            descriptor = traited
        }
        // Size 0 keeps the descriptor's (text-style) point size.
        return UIFont(descriptor: descriptor, size: 0)
    }

    static func uiTextStyle(_ style: ADFFontSpec.TextStyle) -> UIFont.TextStyle {
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
}

extension DynamicTypeSize {
    /// The UIKit content size category this SwiftUI size stands for —
    /// exhaustive, so the TextKit arm resolves fonts at exactly the size the
    /// `dynamicTypeSize` environment gives SwiftUI's `Text`.
    var uiContentSizeCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .extraLarge
        case .xxLarge: return .extraExtraLarge
        case .xxxLarge: return .extraExtraExtraLarge
        case .accessibility1: return .accessibilityMedium
        case .accessibility2: return .accessibilityLarge
        case .accessibility3: return .accessibilityExtraLarge
        case .accessibility4: return .accessibilityExtraExtraLarge
        case .accessibility5: return .accessibilityExtraExtraExtraLarge
        // Clamp a future rung to the ladder top (see
        // `approximateBodyPointSize`): the nearest size that exists.
        @unknown default: return .accessibilityExtraExtraExtraLarge
        }
    }
}
#endif
