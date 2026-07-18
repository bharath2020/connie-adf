import Foundation
import SwiftUI

/// Semantic, size-independent description of a run's font — the dual-scope
/// twin of the SwiftUI `Font` baked by `InlineComposer`. Resolved to a
/// concrete platform font at the view layer per Dynamic Type size, so
/// nothing size-dependent is baked at preparation time (ADR §19).
public struct FontSpec: Sendable, Hashable, Codable {
    public enum Style: String, Sendable, Hashable, Codable, CaseIterable {
        case body, callout, title, title2, title3, headline, subheadline, footnote
    }

    public var style: Style
    public var bold: Bool
    public var italic: Bool
    public var monospaced: Bool

    public init(style: Style = .body, bold: Bool = false, italic: Bool = false, monospaced: Bool = false) {
        self.style = style
        self.bold = bold
        self.italic = italic
        self.monospaced = monospaced
    }

    public static let body = FontSpec()
}

/// Attributed-string key carrying the `FontSpec` for each styled run.
public enum FontSpecAttribute: CodableAttributedStringKey {
    public typealias Value = FontSpec
    public static let name = "com.connie.adf.fontSpec"
}

public extension AttributeScopes {
    /// ADF's attribute scope: the dual-scope font spec plus the SwiftUI and
    /// Foundation scopes the composer already writes.
    struct ADFAttributes: AttributeScope {
        public let fontSpec: FontSpecAttribute
        public let swiftUI: SwiftUIAttributes
        public let foundation: FoundationAttributes
    }

    var adf: ADFAttributes.Type { ADFAttributes.self }
}

public extension AttributeDynamicLookup {
    subscript<T: AttributedStringKey>(
        dynamicMember keyPath: KeyPath<AttributeScopes.ADFAttributes, T>
    ) -> T { self[T.self] }
}
