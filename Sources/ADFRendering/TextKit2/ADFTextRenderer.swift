import SwiftUI

/// Which text engine draws top-level paragraphs, headings and lists.
///
/// `.swiftUI` is the shipping path (`Text(AttributedString)`); `.textKit2`
/// routes plain (atom-free) top-level paragraphs and headings, and the
/// leaders and direct paragraphs of top-level lists (nested lists
/// included), through a UIKit-hosted TextKit 2 row. Everything else stays
/// on SwiftUI regardless of the setting: containers and the lists and text
/// inside them, captions, table cells, and atom-bearing text. On platforms
/// without UIKit, `.textKit2` behaves as `.swiftUI`.
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

extension EnvironmentValues {
    /// The text engine a text leaf (`TextEngineLeaf`) should use.
    /// `ADFDocumentView`'s rows set it to the host's choice for top-level
    /// `.richText` and `.listRows` rows, and list rows pass it on to their
    /// own text only (`TextKit2Scope`). Every other position gets `.swiftUI`.
    var adfTextRenderer: ADFTextRenderer {
        get { self[ADFTextRendererKey.self] }
        set { self[ADFTextRendererKey.self] = newValue }
    }

    /// `View.adfRebuildControl` (diagnostics).
    var adfRebuildControl: Bool {
        get { self[ADFRebuildControlKey.self] }
        set { self[ADFRebuildControlKey.self] = newValue }
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
