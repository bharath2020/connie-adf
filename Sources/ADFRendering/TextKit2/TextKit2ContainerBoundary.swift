import SwiftUI
import ADFPreparation

// The container boundary: where a container (panel, quote, expand body,
// extension body, layout column) hands each child block the renderer, a
// lower bound on its width and the container context. One modifier,
// `adfContainerChild`, at the five child sites; one allow list,
// `TextKit2Scope.containerChildKinds`, that each stage of the container
// work widens by one family. Paragraphs and headings in panels, quotes and
// extension bodies joined first; every other container child still gets
// `.swiftUI`, as before containers joined the renderer's scope.

/// A `RenderBlock.Kind` case without its payload: what the container allow
/// list (`TextKit2Scope.containerChildKinds`) holds.
enum TextKit2BlockKind: Sendable, Hashable, CaseIterable {
    case richText
    case codeBlock
    case listRows
    case panel
    case quote
    case divider
    case tableSlice
    case media
    case mediaStrip
    case expand
    case layoutColumns
    case card
    case extensionPlaceholder
    case custom
    case unknown

    /// Exhaustive, so a new block kind must take a case of its own.
    init(_ kind: RenderBlock.Kind) {
        switch kind {
        case .richText: self = .richText
        case .codeBlock: self = .codeBlock
        case .listRows: self = .listRows
        case .panel: self = .panel
        case .quote: self = .quote
        case .divider: self = .divider
        case .tableSlice: self = .tableSlice
        case .media: self = .media
        case .mediaStrip: self = .mediaStrip
        case .expand: self = .expand
        case .layoutColumns: self = .layoutColumns
        case .card: self = .card
        case .extensionPlaceholder: self = .extensionPlaceholder
        case .custom: self = .custom
        case .unknown: self = .unknown
        }
    }
}

/// The container a child block sits in, as its boundary sees it
/// (`View.adfContainerChild`).
enum TextKit2ContainerParent: Sendable, Hashable {
    case panel
    case quote
    /// An open expand's (or nested expand's) prepared body.
    case expandBody
    /// A bodied extension placeholder's body.
    case extensionBody
    /// A layout column: side by side (`ProportionalColumnsLayout`, a
    /// regular width class at a non-accessibility text size) or stacked.
    case column(sideBySide: Bool)
}

/// Where a text leaf sits, beside whose text it is (`TextKit2OwnerKind`):
/// the kind says what the text is, the context where it is. A list leaf in
/// a quote is kind `.list`, context `.container`; a code block in a panel
/// is kind `.code`, context `.container`. The context never changes the
/// kind, so list rules still decide list text and code rules code.
enum TextKit2ContainerContext: Sendable, Hashable {
    /// Outside every container: top-level text, top-level lists and code.
    case none
    /// Below a container's child boundary (`View.adfContainerChild`).
    case container
    /// A media caption.
    case caption
}

private struct ADFTextContainerContextKey: EnvironmentKey {
    static let defaultValue: TextKit2ContainerContext = .none
}

private struct ADFContainerChildKindsKey: EnvironmentKey {
    static let defaultValue: Set<TextKit2BlockKind> = TextKit2Scope.containerChildKinds
}

extension EnvironmentValues {
    /// Where the text below sits (`TextKit2ContainerContext`). Written only
    /// in this file: `.container` by `adfContainerChild`. A TextKit 2 row
    /// counts itself by it (`TextKit2Diagnostics`), so container text is
    /// proved apart from top-level text. Not the renderer choice: setting
    /// it never turns TextKit 2 on.
    var adfTextContainerContext: TextKit2ContainerContext {
        get { self[ADFTextContainerContextKey.self] }
        set { self[ADFTextContainerContextKey.self] = newValue }
    }

    /// The block kinds a container boundary may pass the renderer to,
    /// `TextKit2Scope.containerChildKinds` unless a test host widens it to
    /// try a family before its stage. Read only by `adfContainerChild`; no
    /// library source writes it, so in an app it is always the production
    /// list. It can only add kinds: `childRenderer`'s whole-block rules and
    /// the kinds that never join (`TextKit2Scope.containerExcludedKinds`)
    /// still apply, and it never turns TextKit 2 back on below a boundary
    /// that reset it.
    var adfContainerChildKinds: Set<TextKit2BlockKind> {
        get { self[ADFContainerChildKindsKey.self] }
        set { self[ADFContainerChildKindsKey.self] = newValue }
    }
}

extension TextKit2Scope {
    /// The child kinds a container passes the renderer to. Each family
    /// joins in its own change: paragraphs and headings, panels, quotes and
    /// extension bodies first (here), then layout columns, expands, lists,
    /// code, media captions; until a kind is listed every child of that
    /// kind stays on SwiftUI, and so does everything below it.
    /// `inheritsRenderer` reads it for top-level container rows,
    /// `adfContainerChild` (through `adfContainerChildKinds`) at every child
    /// boundary, and the coverage walk (`forEachLeaf`) for both. Before
    /// iOS 26 the text it reaches still stays on SwiftUI
    /// (`TextKit2Eligibility.containerTextMatchesText`).
    static let containerChildKinds: Set<TextKit2BlockKind> = [.richText, .panel, .quote, .extensionPlaceholder]

    /// Kinds that never join the container scope, whatever an allow list
    /// says: tables (a later stage), plugin blocks (their renderer owns
    /// what is under them), dividers, media strips, cards and unknown
    /// nodes. `childRenderer` gives them `.swiftUI`.
    static let containerExcludedKinds: Set<TextKit2BlockKind> = [.tableSlice, .custom, .divider, .mediaStrip, .card, .unknown]

    /// The whole-block rule for a block the renderer may reach, as a
    /// top-level row (`inheritsRenderer`) or a container's child
    /// (`childRenderer`): a list passes rule B (`listKeepsRenderer`), a
    /// panel `panelKeepsRenderer`, an extension placeholder needs a body,
    /// media a caption (and `captionsUseTextKit2`); paragraphs, headings,
    /// code, quotes, expands and layout columns always pass; the excluded
    /// kinds (`containerExcludedKinds`) never do. Static: the view-time
    /// rules are `containerGate`'s.
    static func blockKeepsRenderer(_ kind: RenderBlock.Kind) -> Bool {
        switch kind {
        case .richText, .codeBlock, .quote, .expand, .layoutColumns: return true
        case .listRows(let rows): return listKeepsRenderer(rows)
        case .panel(_, let children): return panelKeepsRenderer(children)
        case .extensionPlaceholder(_, let body): return !body.isEmpty
        case .media(let media): return captionsUseTextKit2 && !(media.caption?.isEmpty ?? true)
        case .divider, .tableSlice, .mediaStrip, .card, .custom, .unknown: return false
        }
    }

    /// Which panel bodies may hand their text to TextKit 2: every body but
    /// one holding a list, a heading, a code block beside another block, or
    /// more than one block where a paragraph carries a superscript,
    /// subscript or small-text run (`isBodyText`). Such a panel keeps its
    /// whole body on SwiftUI (reason `panelShape`). From the panel shape
    /// probes (iOS 26.3 at 3x and 2x, iOS 18.5 at 3x; xSmall to AX5, Bold
    /// Text, documents 320 to 640 pt, both directions) and the step 3
    /// parity run (`TextKit2ContainerParityTests.panelBody`, iOS 26.3 3x,
    /// the full matrix), measured against the panel on SwiftUI:
    /// - A list beside a paragraph: main's panel (an `HStack` aligned on
    ///   first text baselines) truncates a list row at the panel's height
    ///   ("… november o…" at Medium in a 402 pt document; dLast 21–34 pt),
    ///   where TextKit 2 draws every line. TextKit 2 never imitates a
    ///   truncation, so the shape stays as main draws it.
    /// - A sub/superscript or small-text run beside another block: main
    ///   truncates that paragraph the same way (up to 50 pt of last
    ///   baseline at 2x). The same runs in a one-paragraph body match.
    /// - A code block beside a paragraph: main's panel cuts the code block
    ///   (still SwiftUI on both renderers) to its first line at most sizes
    ///   and widths (its last line 19–21 pt off), where the panel with
    ///   TextKit 2 prose shows every line. The same body in a quote, and
    ///   the same blocks alone, match: the panel's stack is the cause.
    /// - A heading and a paragraph: at AX5 in a 402 pt document (a
    ///   271.667 pt body) TextKit 2 sets the whole body, icon included,
    ///   31 pt low, and the blocks alone at that width do too: a leaf
    ///   shift, kept out here until the leaf is fixed.
    /// One paragraph, body paragraphs (links, inline code, bold, italic,
    /// emoji) and a paragraph with a nested quote matched within 0.01 pt.
    static func panelKeepsRenderer(_ children: [RenderBlock]) -> Bool {
        var smallRun = false
        var code = false
        for child in children {
            switch child.kind {
            case .listRows: return false
            case .codeBlock: code = true
            case .richText(let segments, let style):
                if style.isHeading { return false }
                if !isBodyText(segments) { smallRun = true }
            default: continue
            }
        }
        return !((smallRun || code) && children.count > 1)
    }

    /// Whether media captions may use TextKit 2 at all. Off until the
    /// caption family's own stage, which is separately droppable: no
    /// caption leaf exists yet.
    static let captionsUseTextKit2 = false

    /// The renderer a container hands a child block of `kind` in `parent`:
    /// `.swiftUI` whenever it inherited `.swiftUI` (so a container never
    /// turns TextKit 2 back on below a list row, a table cell or a
    /// container that reset it; the inherited value is the only renderer
    /// input, never a preference), and otherwise `.textKit2` only for a
    /// kind in `allowed` that passes its whole-block rule
    /// (`blockKeepsRenderer`) and the boundary's view-time rules
    /// (`containerGate(for:in:layoutDirection:)`). It does not consult
    /// `inheritsRenderer`, so a test host that widens `allowed` can nest a
    /// family before its stage.
    static func childRenderer(
        for kind: RenderBlock.Kind, in parent: TextKit2ContainerParent, inherited: ADFTextRenderer,
        allowed: Set<TextKit2BlockKind>, layoutDirection: LayoutDirection
    ) -> ADFTextRenderer {
        guard inherited == .textKit2, allowed.contains(TextKit2BlockKind(kind)), blockKeepsRenderer(kind),
              containerGate(for: kind, in: parent, layoutDirection: layoutDirection) == nil else { return .swiftUI }
        return .textKit2
    }

    // MARK: View-time container rules

    /// Why text eligible by content stays on SwiftUI inside a container for
    /// a reason only the view knows (the width, the layout direction, the
    /// size class). The coverage walk evaluates none of them: it counts a
    /// document as stacked and left to right, so coverage is the static
    /// potential. Decided by `containerGate`.
    enum ContainerGate: Sendable, Hashable, CaseIterable {
        /// A wrapping leaf whose width bound, less its own inset, is under
        /// `minimumTextWidth` (`textFits`).
        case narrowColumn
        /// A wrapping leaf below a container that cannot bound its insets
        /// (`TextKit2WidthBound.unproven`).
        case unprovenNestedWidth
        /// A panel laid out right to left (`panelDirectionKeepsRenderer`).
        case panelDirection
        /// A family kept out of side-by-side layout columns
        /// (`horizontalColumnKeepsRenderer`).
        case horizontalColumn
    }

    /// Whether a panel laid out in `direction` may pass the renderer to its
    /// body: in both directions. The panel shape probes found no failure
    /// right to left that the same shape does not have left to right (and
    /// `panelKeepsRenderer` excludes); the extra right-to-left differences
    /// were pixels the blocks alone reproduce, not the panel's. Kept as a
    /// rule so a direction found failing later is a one-line change.
    static func panelDirectionKeepsRenderer(_ direction: LayoutDirection) -> Bool {
        true
    }

    /// Whether a child of `kind` may keep the renderer in a side-by-side
    /// layout column. Every kind for now: written from the off-grid column
    /// probe when the column family is enabled. Stacked columns are
    /// unaffected.
    static func horizontalColumnKeepsRenderer(_ kind: TextKit2BlockKind) -> Bool {
        true
    }

    /// The boundary's view-time rules for a child of `kind` in `parent`
    /// laid out in `layoutDirection` (`childRenderer`): a panel's direction
    /// (`.panelDirection`), a side-by-side column's family
    /// (`.horizontalColumn`); `nil` when neither keeps it on SwiftUI.
    static func containerGate(
        for kind: RenderBlock.Kind, in parent: TextKit2ContainerParent, layoutDirection: LayoutDirection
    ) -> ContainerGate? {
        switch parent {
        case .panel:
            return panelDirectionKeepsRenderer(layoutDirection) ? nil : .panelDirection
        case .column(sideBySide: true):
            return horizontalColumnKeepsRenderer(TextKit2BlockKind(kind)) ? nil : .horizontalColumn
        case .quote, .expandBody, .extensionBody, .column(sideBySide: false):
            return nil
        }
    }

    /// The leaf's view-time width rules (`TextKit2Leaf`): for wrapping text,
    /// `.unprovenNestedWidth` under an `.unproven` bound and `.narrowColumn`
    /// when the bound less `inset` is under `minimumTextWidth` (`textFits`);
    /// `nil` for a `.pending` bound and for text that never wraps (code,
    /// `TextKit2LayoutPolicy.natural`, which its own gate decides).
    static func containerGate(
        widthBound: TextKit2WidthBound, inset: CGFloat, layoutPolicy: TextKit2LayoutPolicy
    ) -> ContainerGate? {
        guard layoutPolicy == .wrapping else { return nil }
        switch widthBound {
        case .pending: return nil
        case .unproven: return .unprovenNestedWidth
        case .atLeast: return textFits(widthBound, inset: inset) ? nil : .narrowColumn
        }
    }
}

extension TextKit2WidthBound {
    /// This bound for a region `inset` points narrower: a known width less
    /// the inset, clamped at 0; `.pending` and `.unproven` unchanged.
    func narrowed(by inset: CGFloat) -> TextKit2WidthBound {
        guard case .atLeast(let width) = self else { return self }
        return .atLeast(max(width - inset, 0))
    }

    /// This bound with a known width passed through `width` (a column's
    /// share of it), clamped at 0; `.pending` and `.unproven` unchanged.
    func mapWidth(_ width: (CGFloat) -> CGFloat) -> TextKit2WidthBound {
        guard case .atLeast(let known) = self else { return self }
        return .atLeast(max(width(known), 0))
    }
}

extension View {
    /// A container's child boundary, applied to each child `BlockView` of
    /// a panel, a quote, an expand body, an extension body and a layout
    /// column: writes the child's renderer (`TextKit2Scope.childRenderer`),
    /// the width bound the container computed for its children
    /// (`widthBound`: its own bound less its insets) and the context
    /// `.container`. Where the container itself inherited `.swiftUI` the
    /// bound is written as `.pending`, so the SwiftUI path depends on no
    /// width arithmetic.
    func adfContainerChild(_ block: RenderBlock, in parent: TextKit2ContainerParent, widthBound: TextKit2WidthBound) -> some View {
        modifier(TextKit2ContainerChild(kind: block.kind, parent: parent, widthBound: widthBound))
    }
}

/// `View.adfContainerChild`.
private struct TextKit2ContainerChild: ViewModifier {
    let kind: RenderBlock.Kind
    let parent: TextKit2ContainerParent
    let widthBound: TextKit2WidthBound

    @Environment(\.adfTextRenderer) private var inherited
    @Environment(\.adfContainerChildKinds) private var allowed
    @Environment(\.layoutDirection) private var layoutDirection

    func body(content: Content) -> some View {
        let renderer = TextKit2Scope.childRenderer(
            for: kind, in: parent, inherited: inherited, allowed: allowed, layoutDirection: layoutDirection
        )
        content
            .environment(\.adfTextRenderer, renderer)
            .environment(\.adfTextWidthBound, inherited == .textKit2 ? widthBound : .pending)
            .environment(\.adfTextContainerContext, .container)
    }
}
