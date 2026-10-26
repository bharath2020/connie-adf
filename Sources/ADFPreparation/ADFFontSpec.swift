import Foundation

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
