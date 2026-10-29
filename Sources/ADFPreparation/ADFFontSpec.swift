import Foundation
import SwiftUI

/// A platform-neutral description of a run's font: a semantic text style
/// plus the symbolic traits the marks added.
///
/// Baked on every text run at preparation time next to the SwiftUI `Font`
/// (`AttributeScopes.ADFAttributes.FontSpecAttribute`). SwiftUI keeps
/// reading `Font`; a UIKit/TextKit engine resolves a `UIFont` from this
/// value instead — from the text style's preferred descriptor (so Dynamic
/// Type and the style's line metrics are preserved), never from a point
/// size.
public struct ADFFontSpec: Sendable, Hashable, Codable {
    /// Mirrors the platform text-style ladder; raw values are stable for
    /// encoding.
    public enum TextStyle: String, Sendable, Hashable, Codable, CaseIterable {
        case largeTitle
        case title
        case title2
        case title3
        case headline
        case subheadline
        case body
        case callout
        case footnote
        case caption
        case caption2
    }

    public var textStyle: TextStyle
    public var bold: Bool
    public var italic: Bool
    public var monospaced: Bool

    public init(textStyle: TextStyle, bold: Bool = false, italic: Bool = false, monospaced: Bool = false) {
        self.textStyle = textStyle
        self.bold = bold
        self.italic = italic
        self.monospaced = monospaced
    }
}

extension Font {
    /// The SwiftUI font a spec describes: the text style's own font (the
    /// `.body` / `.title` / … statics, or `.system(_:design: .monospaced)`)
    /// with `.bold()` / `.italic()` layered on — the same expressions the
    /// theme used before specs existed, so derived fonts compare equal to
    /// them and render identically.
    public init(adfFontSpec spec: ADFFontSpec) {
        var font: Font
        if spec.monospaced {
            font = .system(spec.textStyle.swiftUITextStyle, design: .monospaced)
        } else {
            switch spec.textStyle {
            case .largeTitle: font = .largeTitle
            case .title: font = .title
            case .title2: font = .title2
            case .title3: font = .title3
            case .headline: font = .headline
            case .subheadline: font = .subheadline
            case .body: font = .body
            case .callout: font = .callout
            case .footnote: font = .footnote
            case .caption: font = .caption
            case .caption2: font = .caption2
            }
        }
        if spec.bold { font = font.bold() }
        if spec.italic { font = font.italic() }
        self = font
    }
}

extension ADFFontSpec.TextStyle {
    /// The SwiftUI text style of the same name.
    public var swiftUITextStyle: Font.TextStyle {
        switch self {
        case .largeTitle: return .largeTitle
        case .title: return .title
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .body: return .body
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption
        case .caption2: return .caption2
        }
    }
}

extension AttributeScopes {
    /// ADFKit's own attributed-string attributes.
    public struct ADFAttributes: AttributeScope {
        /// The semantic font spec of a text run (see `ADFFontSpec`).
        public let adfFontSpec: FontSpecAttribute

        public enum FontSpecAttribute: CodableAttributedStringKey {
            public typealias Value = ADFFontSpec
            public static let name = "adf.fontSpec"
        }
    }

    public var adf: ADFAttributes.Type { ADFAttributes.self }
}

extension AttributeDynamicLookup {
    public subscript<T: AttributedStringKey>(
        dynamicMember keyPath: KeyPath<AttributeScopes.ADFAttributes, T>
    ) -> T {
        self[T.self]
    }
}
