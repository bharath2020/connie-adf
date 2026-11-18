import SwiftUI

/// Which text engine draws top-level paragraphs and headings, the text of
/// top-level lists, the code of top-level code blocks, the paragraphs,
/// headings, lists and code blocks in quotes, extension bodies, open expand
/// bodies and stacked layout columns, and the paragraphs and headings (and
/// a lone code block) in panels.
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
/// From iOS 26, paragraphs and headings in a panel, a quote, a bodied
/// extension or an open expand's (or nested expand's) body, and in those
/// nested in one another, go to TextKit 2 too; the container's icon, bar,
/// fill, border, padding and title (an expand's title and chevron
/// included) stay SwiftUI. A panel whose body holds a list or an expand, a
/// heading of its own, or a sub/superscript or small-text run or a code
/// block beside another block (directly or in a quote, extension body or
/// layout column in it) keeps its whole body on SwiftUI. Laid out right to
/// left, or at xxxLarge and above, every container keeps its body on
/// SwiftUI. An expand body is prepared when it opens, as before; the
/// renderer never starts or restarts that preparation. A layout section's
/// columns pass the same choice to their blocks while the columns stack
/// (compact width; at the accessibility text sizes, where they also
/// stack, the size rule keeps them on SwiftUI); columns laid out side by
/// side keep all their text on SwiftUI.
/// The lists in a quote, an expand or extension body or a stacked column
/// follow the list rules above at the width the container leaves them; a
/// panel holding a list keeps its whole body on SwiftUI. Code blocks in
/// those places follow their container's choice and then the code rules
/// above, as a top-level code block does (a panel holding code beside
/// another block keeps its whole body on SwiftUI).
///
/// A media caption's text follows the setting from iOS 26 when its text
/// is eligible (and has no highlighted or inline-code run) and its media
/// is in scope (a top-level row, or a child a container's boundary passes
/// the setting to), drawn in the caption's secondary foreground; the media
/// box is SwiftUI.
///
/// Everything else stays on SwiftUI regardless of the setting: side-by-side
/// layout columns, container bodies laid out right to left or at xxxLarge
/// and above, code inside a list item, table cells, and atom-bearing text. On platforms without UIKit, `.textKit2` behaves as `.swiftUI`.
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
/// The kind says what the text is, not where it sits: text below a
/// container's boundary keeps its kind (code stays `.code`, list text
/// `.list`), and the container context (`TextKit2ContainerContext`,
/// `adfTextContainerContext`) is carried beside it.
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

/// A guaranteed lower bound on the width text below it is laid out at
/// (`adfTextWidthBound`). It decides eligibility only, never layout: a
/// TextKit 2 row lays out at the width it is proposed (`sizeThatFits`),
/// but the engine is chosen earlier, in `body`, so a width-dependent rule
/// needs a width known before layout. Those rules are list rule D
/// (`TextKit2Scope.listTextFits`) and the under-1-pt guard on every
/// wrapping leaf (`TextKit2Scope.textFits`).
///
/// Because it is only a lower bound, a bound that is too small can keep
/// text on SwiftUI, never lay TextKit 2 text out wrongly. A bound larger
/// than the real width breaks the contract: whoever writes one removes
/// every inset between itself and the text below, or writes `unproven`.
enum TextKit2WidthBound: Sendable, Hashable {
    /// Not known yet: before the document's first width observation, or a
    /// host outside `ADFDocumentView`. Permissive, as an unknown list
    /// width always was: a restrictive first pass would build the first
    /// screen's leaves twice, once on each engine.
    case pending
    /// The text is laid out at least this many points wide.
    case atLeast(CGFloat)
    /// A container above the text cannot bound its insets. Restrictive:
    /// every wrapping leaf below stays on SwiftUI.
    case unproven
}

private struct ADFTextWidthBoundKey: EnvironmentKey {
    static let defaultValue: TextKit2WidthBound = .pending
}

private struct ADFTextForegroundKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

extension EnvironmentValues {
    /// The text engine a text leaf (`TextEngineLeaf`) should use.
    /// `ADFDocumentView`'s rows set it to the host's choice for top-level
    /// `.richText`, `.listRows` and `.codeBlock` rows and for the container
    /// kinds the container allow list holds, list rows pass it on to their
    /// own text only, and a container's child boundary
    /// (`View.adfContainerChild`) to the children that list allows
    /// (`TextKit2Scope`). Every other position gets `.swiftUI`.
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

    /// A lower bound on the width the text below is laid out at
    /// (`TextKit2WidthBound`), for eligibility only, never for layout.
    /// `ADFDocumentView`'s rows seed it with the row's content width, the
    /// document column widened or capped by the block's breakout mark
    /// (`TextKit2WidthBound.rowSeed`); `.pending` before the column is
    /// measured and in hosts outside the document view. Any view that
    /// passes it on into a narrower region must remove that region's
    /// insets first, or write `.unproven`. Read by a list row, which works
    /// out its text column from it (`TextKit2Scope.listTextFits`), and by
    /// every wrapping TextKit 2 leaf (`TextKit2Scope.textFits`).
    var adfTextWidthBound: TextKit2WidthBound {
        get { self[ADFTextWidthBoundKey.self] }
        set { self[ADFTextWidthBoundKey.self] = newValue }
    }

    /// The foreground colour text below inherits where the library styles
    /// its SwiftUI text with a foreground style: `.secondary` on a media
    /// caption (`View.adfCaptionLeaf`, its one setter); `nil`, the
    /// default, everywhere else. SwiftUI does not expose an inherited
    /// foreground style to UIKit, so a TextKit 2 row reads this explicit
    /// copy (`TextKit2RenderInputs.inheritedForeground`) for the runs the
    /// preparer did not colour. Internal: there is no public styling
    /// channel. A host's `.foregroundStyle`, `.tint` or `.fontWeight`
    /// around the document is still not observed by TextKit 2 rows.
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
