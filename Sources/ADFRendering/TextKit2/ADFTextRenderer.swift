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

private struct ADFRebuildControlKey: EnvironmentKey {
    static let defaultValue = false
}

private struct ADFTextForegroundKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

extension EnvironmentValues {
    /// The text engine a `RichTextBlockView` should use. `ADFDocumentView`'s
    /// rows set it to the host's choice for top-level `.richText` blocks only;
    /// every other position inherits the `.swiftUI` default.
    var adfTextRenderer: ADFTextRenderer {
        get { self[ADFTextRendererKey.self] }
        set { self[ADFTextRendererKey.self] = newValue }
    }

    /// `View.adfRebuildControl` (diagnostics).
    var adfRebuildControl: Bool {
        get { self[ADFRebuildControlKey.self] }
        set { self[ADFRebuildControlKey.self] = newValue }
    }

    /// The host's document text colour (`ADFDocumentView(textForeground:)`),
    /// set alongside the SwiftUI `foregroundStyle` it applies. SwiftUI does
    /// not expose an inherited foreground style to UIKit-hosted views, so
    /// TextKit 2 rows read this explicit copy instead.
    var adfTextForeground: Color? {
        get { self[ADFTextForegroundKey.self] }
        set { self[ADFTextForegroundKey.self] = newValue }
    }
}

extension View {
    /// Diagnostics only (the lifecycle gate's memory control, never a
    /// renderer): while `on`, every eligible leaf that `.textKit2` would
    /// hand to a TextKit 2 row renders its SwiftUI `Text` in that row's
    /// place instead — the same leaves, swapped at the same `if`/`else`
    /// branch point, so a renderer switch rebuilds exactly the rows a
    /// TextKit 2 switch does, as plain SwiftUI. Counted in
    /// `ADFTextRenderer.rebuildControlRows`.
    @_spi(ADFDiagnostics)
    public func adfRebuildControl(_ on: Bool) -> some View {
        environment(\.adfRebuildControl, on)
    }
}
