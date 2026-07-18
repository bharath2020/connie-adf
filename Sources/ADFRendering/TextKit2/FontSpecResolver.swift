import Foundation
import SwiftUI
import ADFPreparation
#if canImport(UIKit)
import UIKit
public typealias ADFPlatformFont = UIFont
#elseif canImport(AppKit)
import AppKit
public typealias ADFPlatformFont = NSFont
#endif

/// Resolves semantic `FontSpec`s to concrete platform fonts.
///
/// Resolution goes through `preferredFont(forTextStyle:)` — NEVER
/// `UIFontMetrics` scaling of a base point size, which follows the
/// `@ScaledMetric` curve and diverges from semantic fonts across the
/// accessibility range (measured 37pt vs 40pt at AX3). On iOS the category
/// comes from the SwiftUI environment (per-document §19 shifts included);
/// trait-argument-less calls are forbidden in this layer.
@MainActor
public final class FontSpecResolver {
    public static let shared = FontSpecResolver()
    private struct Key: Hashable { let spec: FontSpec; let category: String }
    private var cache: [Key: ADFPlatformFont] = [:]

    /// Counts calls to `resolve(_:categoryRawValue:)` — i.e. cache misses.
    /// Exposed (internal, private(set)) so tests can prove memoization
    /// actually short-circuits resolution, rather than relying on
    /// UIFont/NSFont's own interning to coincidentally satisfy `===`.
    private(set) var resolutionCount = 0

    public func font(for spec: FontSpec, categoryRawValue: String) -> ADFPlatformFont {
        let key = Key(spec: spec, category: categoryRawValue)
        if let hit = cache[key] { return hit }
        let resolved = resolve(spec, categoryRawValue: categoryRawValue)
        cache[key] = resolved
        return resolved
    }

    #if canImport(UIKit)
    private func resolve(_ spec: FontSpec, categoryRawValue: String) -> UIFont {
        resolutionCount += 1
        let traits = UITraitCollection(
            preferredContentSizeCategory: UIContentSizeCategory(rawValue: categoryRawValue))
        let base = UIFont.preferredFont(forTextStyle: spec.style.uiTextStyle, compatibleWith: traits)
        var font = base
        if spec.monospaced {
            font = .monospacedSystemFont(ofSize: base.pointSize, weight: spec.bold ? .semibold : .regular)
        }
        var symbolic = font.fontDescriptor.symbolicTraits
        if spec.bold, !spec.monospaced { symbolic.insert(.traitBold) }
        if spec.italic { symbolic.insert(.traitItalic) }
        if let descriptor = font.fontDescriptor.withSymbolicTraits(symbolic) {
            font = UIFont(descriptor: descriptor, size: 0)
        }
        return font
    }
    #elseif canImport(AppKit)
    private func resolve(_ spec: FontSpec, categoryRawValue _: String) -> NSFont {
        resolutionCount += 1
        // macOS: single-size resolution — `swift test` exercises mapping and
        // memoization; category behavior is iOS-gate territory.
        let base = NSFont.preferredFont(forTextStyle: spec.style.nsTextStyle, options: [:])
        var font = base
        if spec.monospaced {
            font = .monospacedSystemFont(ofSize: base.pointSize, weight: spec.bold ? .semibold : .regular)
        }
        var traits: NSFontDescriptor.SymbolicTraits = font.fontDescriptor.symbolicTraits
        if spec.bold, !spec.monospaced { traits.insert(.bold) }
        if spec.italic { traits.insert(.italic) }
        let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
        font = NSFont(descriptor: descriptor, size: 0) ?? font
        return font
    }
    #endif
}

extension FontSpec.Style {
    #if canImport(UIKit)
    var uiTextStyle: UIFont.TextStyle {
        switch self {
        case .body: .body
        case .callout: .callout
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .footnote: .footnote
        }
    }
    #elseif canImport(AppKit)
    var nsTextStyle: NSFont.TextStyle {
        switch self {
        case .body: .body
        case .callout: .callout
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .footnote: .footnote
        }
    }
    #endif
}

#if canImport(UIKit)
public extension UIContentSizeCategory {
    /// Exhaustive bridge from the SwiftUI environment value — the ONLY legal
    /// trait source in the TK2 layer (per-document §19 shifts ride it).
    init(_ size: DynamicTypeSize) {
        switch size {
        case .xSmall: self = .extraSmall
        case .small: self = .small
        case .medium: self = .medium
        case .large: self = .large
        case .xLarge: self = .extraLarge
        case .xxLarge: self = .extraExtraLarge
        case .xxxLarge: self = .extraExtraExtraLarge
        case .accessibility1: self = .accessibilityMedium
        case .accessibility2: self = .accessibilityLarge
        case .accessibility3: self = .accessibilityExtraLarge
        case .accessibility4: self = .accessibilityExtraExtraLarge
        case .accessibility5: self = .accessibilityExtraExtraExtraLarge
        @unknown default: self = .large
        }
    }
}
#endif
