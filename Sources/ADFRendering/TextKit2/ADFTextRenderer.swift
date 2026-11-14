import SwiftUI

/// Which text engine draws top-level paragraphs and headings, the text of
/// top-level lists, and the code of top-level code blocks.
///
/// `.swiftUI` is the shipping path (`Text(AttributedString)`). `.textKit2`
/// routes plain (atom-free) top-level paragraphs and headings, the
/// leaders and direct paragraphs and headings of top-level lists (nested
/// lists included), and the code text of top-level code blocks, through a
/// UIKit-hosted TextKit 2 row. List text stays
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
/// A code block's badge, Copy button, box and horizontal scrolling are
/// SwiftUI under either setting. Its code text stays on SwiftUI too unless
/// it is set in a monospaced theme font spec and holds only printable ASCII
/// and line feeds (no tab, no other line break), and also when it is empty,
/// laid out right to left, matched by the active search, or would need a
/// drawing surface over the admission caps at the current text size.
///
/// Everything else stays on SwiftUI regardless of the setting: containers
/// and the lists, code and text inside them, captions, table cells, and
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

/// Whose text a leaf draws: a semantic kind, not only a label. `.list` is a
/// list row's leader or one of its direct paragraphs and headings
/// (`ListRowView` sets it on its content); `.code` is a code block's code
/// text (`CodeBlockView` sets it on its leaf); `.root` is everything else.
///
/// It decides three things. The eligibility verdict: `.list` text stays on
/// SwiftUI before iOS 26 (`TextKit2Eligibility.listsMatchText`), and
/// `.code` text is judged by the code rules, from its prepared shape, and
/// never by a list rule. The layout policy: `.code` never wraps
/// (`layoutPolicy`), and goes through the code gate (`TextKit2CodeGate`)
/// before it reaches a row. And the proof: a TextKit 2 row counts itself by
/// it, so `ADFTextKit2Stats.liveListRowCount` and `liveCodeRowCount` show
/// that list text and code, not only top-level text, are drawn by
/// TextKit 2.
///
/// The kind says what the text is, not where it sits: a later stage that
/// draws code inside a container keeps `.code` and adds the container's
/// context beside it.
enum TextKit2OwnerKind: Sendable, Hashable {
    case root
    case list
    case code

    /// How a row lays this kind of text out against a proposed width.
    var layoutPolicy: TextKit2LayoutPolicy {
        switch self {
        case .root, .list: return .wrapping
        case .code: return .natural
        }
    }
}

/// How a TextKit 2 row lays its text out against the width it is proposed
/// (`TextKit2RenderInputs.layoutPolicy`).
enum TextKit2LayoutPolicy: Sendable, Hashable {
    /// Lines wrap at the proposed width: paragraphs, headings, list text.
    /// One layout per distinct width, memoized.
    case wrapping
    /// Lines never wrap: code. The row lays out once per set of inputs, at
    /// its natural width, and that one layout answers every proposal and
    /// serves placement, the baselines, drawing and rectangle conversion.
    /// Lines are left-aligned with no shift.
    case natural
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
    /// `.richText`, `.listRows` and `.codeBlock` rows, and list rows pass it
    /// on to their own text only (`TextKit2Scope`). Every other position
    /// gets `.swiftUI`.
    var adfTextRenderer: ADFTextRenderer {
        get { self[ADFTextRendererKey.self] }
        set { self[ADFTextRendererKey.self] = newValue }
    }

    /// `View.adfRebuildControl` (diagnostics).
    var adfRebuildControl: Bool {
        get { self[ADFRebuildControlKey.self] }
        set { self[ADFRebuildControlKey.self] = newValue }
    }

    /// Whose text a leaf below draws (`TextKit2OwnerKind`): read by
    /// `TextEngineLeaf` for the eligibility verdict, the layout policy and
    /// the live-row counters. Not the renderer choice: setting it never
    /// turns TextKit 2 on.
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
