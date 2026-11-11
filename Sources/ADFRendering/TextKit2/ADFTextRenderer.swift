import SwiftUI

/// Which text engine draws top-level paragraphs and headings, and the text
/// of top-level lists.
///
/// `.swiftUI` is the shipping path (`Text(AttributedString)`). `.textKit2`
/// routes plain (atom-free) top-level paragraphs and headings, and the
/// leaders and direct paragraphs and headings of top-level lists (nested
/// lists included), through a UIKit-hosted TextKit 2 row. List text stays
/// on SwiftUI where TextKit 2 was measured to miss `Text`'s placement:
/// - a row whose item holds more than one text block, unless they are all
///   body-styled paragraphs (so not a heading or a sub/superscript beside
///   other text);
/// - a row whose item holds anything but text (a code block, a container,
///   a list under another node);
/// - every row of a list in which one row holds both a panel and an expand;
/// - text laid out right to left;
/// - a text column with no room;
/// - every list before iOS 26.
///
/// Everything else stays on SwiftUI regardless of the setting: containers
/// and the lists and text inside them, captions, table cells, and
/// atom-bearing text. On platforms without UIKit, `.textKit2` behaves as
/// `.swiftUI`.
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

/// Whose text a leaf draws. `.list` is a list row's leader or one of its
/// direct paragraphs and headings (`ListRowView` sets it on its content);
/// `.root` is everything else. A TextKit 2 row counts itself by it, so
/// `ADFTextKit2Stats.liveListRowCount` proves that list text, not only
/// top-level text, is drawn by TextKit 2; and the eligibility verdict keeps
/// `.list` text on SwiftUI before iOS 26
/// (`TextKit2Eligibility.listsMatchText`).
enum TextKit2OwnerKind: Sendable, Hashable {
    case root
    case list
}

private struct ADFTextOwnerKindKey: EnvironmentKey {
    static let defaultValue: TextKit2OwnerKind = .root
}

private struct ADFListWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
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

    /// `TextKit2OwnerKind` (diagnostics).
    var adfTextOwnerKind: TextKit2OwnerKind {
        get { self[ADFTextOwnerKindKey.self] }
        set { self[ADFTextOwnerKindKey.self] = newValue }
    }

    /// The width a top-level list is laid out at, the document's content
    /// column (`ADFDocumentView`'s rows); `nil` when the host does not know
    /// it. A list row works out its own text column from it, and keeps
    /// that text on SwiftUI when the column has no room
    /// (`TextKit2Scope.listTextFits`). Only top-level lists draw TextKit 2
    /// text (`TextKit2Scope.rowKeepsRenderer`), so nested ones never need it.
    var adfListWidth: CGFloat? {
        get { self[ADFListWidthKey.self] }
        set { self[ADFListWidthKey.self] = newValue }
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
