import SwiftUI

/// Which text engine draws top-level paragraphs and headings.
///
/// `.swiftUI` is the shipping path (`Text(AttributedString)`); `.textKit2`
/// routes plain (atom-free) paragraphs and headings through a UIKit-hosted
/// TextKit 2 row. Everything else — containers, lists, captions, table
/// cells, atom-bearing paragraphs — stays on SwiftUI regardless of the
/// setting. On platforms without UIKit, `.textKit2` behaves as `.swiftUI`.
public enum ADFTextRenderer: String, CaseIterable, Sendable, Identifiable {
    case swiftUI = "swiftui"
    case textKit2 = "textkit2"

    public var id: String { rawValue }

    /// Human-readable name for a host's renderer picker.
    public var displayName: String {
        switch self {
        case .swiftUI: return "SwiftUI"
        case .textKit2: return "TextKit 2"
        }
    }
}

private struct ADFTextRendererKey: EnvironmentKey {
    static let defaultValue: ADFTextRenderer = .swiftUI
}

extension EnvironmentValues {
    /// The text engine a `RichTextBlockView` should use. `ADFDocumentView`'s
    /// rows set it to the host's choice for top-level `.richText` blocks only;
    /// every other position inherits the `.swiftUI` default.
    var adfTextRenderer: ADFTextRenderer {
        get { self[ADFTextRendererKey.self] }
        set { self[ADFTextRendererKey.self] = newValue }
    }
}
