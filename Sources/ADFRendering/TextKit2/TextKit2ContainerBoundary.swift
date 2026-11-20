import SwiftUI
import ADFModel
import ADFPreparation

// The container boundary: where a container (panel, quote, expand body,
// extension body, layout column) hands each child block the renderer, a
// lower bound on its width and the container context. One modifier,
// `adfContainerChild`, at the five child sites; one allow list,
// `TextKit2Scope.containerChildKinds`, that each stage of the container
// work widens by one family. Paragraphs and headings in panels, quotes and
// extension bodies joined first, then open expand and nested-expand bodies,
// then layout columns (stacked; side by side no family keeps the renderer,
// `horizontalColumnKeepsRenderer`), then lists (where the list rules A–D
// and the iOS 26 list gate pass at the nested width, below the
// accessibility text sizes, `nestedListSizeKeepsRenderer`; never in a
// panel, whose shape rule keeps a body holding a list on SwiftUI), then code
// blocks (PR 3's code block, whole, through `BlockView`: its own gate
// still decides its code text); every other container child still gets
// `.swiftUI`, as before containers joined the renderer's scope. Right to
// left (`containerDirectionKeepsRenderer`) and from xxxLarge
// (`containerSizeKeepsRenderer`) every container keeps its body on SwiftUI.
// So a list below a boundary and a column stacked by an accessibility size
// stay on SwiftUI from xxxLarge too; `nestedListSizeKeepsRenderer` only
// names the reason a list reports at the accessibility sizes.

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
    /// in this file: `.container` by `adfContainerChild`, `.caption` by
    /// `adfCaptionLeaf`. A TextKit 2 row
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
    /// extension bodies first, media for its caption (`captionsUseTextKit2`),
    /// expands (an expand or nested expand passes the renderer to its open
    /// body, which is prepared on opening as before, so the coverage walk
    /// reports it as unprepared rather than entering it), layout columns,
    /// lists, then code blocks; until a kind is listed every child of that
    /// kind stays on SwiftUI, and so does everything below it.
    /// `inheritsRenderer` reads it for top-level container rows,
    /// `adfContainerChild` (through `adfContainerChildKinds`) at every child
    /// boundary, and the coverage walk (`forEachLeaf`) for both. Before
    /// iOS 26 the text it reaches still stays on SwiftUI
    /// (`TextKit2Eligibility.containerTextMatchesText`, and for code
    /// `containerCodeVerdict`). A layout section passes the renderer to its
    /// columns' blocks when the columns stack (compact width; at the
    /// accessibility text sizes they stack too, but from xxxLarge the size
    /// rule keeps them on SwiftUI, `containerSizeKeepsRenderer`); side by
    /// side, no family keeps it yet
    /// (`horizontalColumnKeepsRenderer`). A list below a boundary is drawn
    /// by the list row as at the top level: rules A–D and the iOS 26 list
    /// gate decide its rows, rule D at the width bound the containers above
    /// it computed (`ListRowView`); a row they reject keeps everything in it
    /// on SwiftUI. A panel holding a list keeps its whole body on SwiftUI
    /// (`panelKeepsRenderer`), side by side no list keeps the renderer, and
    /// from xxxLarge no list below a boundary does (the size rule; at an
    /// accessibility text size it reports `nestedListSizeKeepsRenderer`).
    /// A code block that receives the renderer is PR 3's whole code block:
    /// its code text still passes the content rules and the code gate
    /// (direction, canvas bound) where it is drawn; a panel holding code
    /// beside another block keeps its body on SwiftUI (`panelKeepsRenderer`).
    static let containerChildKinds: Set<TextKit2BlockKind> = [.richText, .panel, .quote, .extensionPlaceholder, .media, .expand, .layoutColumns, .listRows, .codeBlock]

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
    ///
    /// The list, code and small-run conditions read the whole body, through
    /// the quotes, extension bodies, layout columns and panels in it (code
    /// review F-R8): the panel's stack lays out every descendant again, so
    /// a list in a quote in the panel, or code or a small run in a quote
    /// beside a paragraph, keeps the body on SwiftUI as the same block
    /// directly in the panel does; "beside" counts the body's blocks at any
    /// depth. An expand in the body (its body is prepared on opening, out
    /// of this rule's sight) keeps it on SwiftUI too. ADF's schema puts
    /// none of these containers in a panel, but the parser accepts them
    /// (containers-parity 0.33, 0.73). The heading condition stays on the
    /// direct children: a heading in a quote in a panel matched (the
    /// nested shape `quoteHeadingInPanel`).
    static func panelKeepsRenderer(_ children: [RenderBlock]) -> Bool {
        var smallRun = false
        var code = false
        var blocks = 0
        func walk(_ body: [RenderBlock], direct: Bool) -> Bool {
            for child in body {
                switch child.kind {
                case .listRows, .expand: return false
                case .codeBlock:
                    code = true
                    blocks += 1
                case .richText(let segments, let style):
                    if style.isHeading {
                        if direct { return false }
                    } else if !isBodyText(segments) {
                        smallRun = true
                    }
                    blocks += 1
                case .quote(let nested), .extensionPlaceholder(_, let nested), .panel(_, let nested):
                    guard walk(nested, direct: false) else { return false }
                case .layoutColumns(let columns):
                    for column in columns {
                        guard walk(column.blocks, direct: false) else { return false }
                    }
                default: blocks += 1
                }
            }
            return true
        }
        guard walk(children, direct: true) else { return false }
        return !((smallRun || code) && max(children.count, blocks) > 1)
    }

    /// Whether media captions may use TextKit 2 at all: the caption
    /// family's switch, separately droppable (false keeps every caption on
    /// SwiftUI, with `.media` in the allow list or not).
    static let captionsUseTextKit2 = true

    /// Which media layouts keep a caption on TextKit 2 where its renderer
    /// is: those whose caption and media box sit where SwiftUI puts them
    /// (`TextKit2CaptionParityTests.captionFrameMatches`). A layout that
    /// does not keeps its captions on SwiftUI, reason `captionLayout`. The
    /// caption's view (`MediaBlockView.caption`) and the coverage walk
    /// (`Leaf.verdict`) both read it. Exhaustive, so a new layout is
    /// decided here.
    static func captionLayoutKeepsRenderer(_ layout: ADFMediaLayout) -> Bool {
        switch layout {
        case .center, .wrapLeft, .wrapRight, .alignStart, .alignEnd, .wide, .fullWidth: return true
        }
    }

    /// Whether a caption's runs keep it on TextKit 2: none carries a run
    /// background (a `backgroundColor` mark's fill, or inline code's band,
    /// `ADFTheme.codeBackground`). A caption whose text has one stays on
    /// SwiftUI, reason `captionRunBackground` (lead dispositions M2,
    /// reversing C42). Measured cause: a caption is centred under the
    /// default `.center` layout, and centred text with a run background is
    /// PR 1's residual 5: the row draws the band one device pixel larger
    /// than `Text` (CAP-07, captions-parity 0.7.0, in dark mode: 0.574 %
    /// and 0.774 % of its text crop differ at sizes 0 and 3, against the
    /// visual gate's 0.5 %; glyphs in place). Fixing the band needs `Text`'s
    /// own line origins (the PR 6 follow-up), so the caption family keeps
    /// every run-background caption on SwiftUI, centred or not, inline code
    /// included. The caption verdict reads it
    /// (`TextKit2Eligibility.verdict(_:owner:context:)` in the caption
    /// context), so the view and the coverage walk agree.
    static func captionRunsKeepRenderer(_ text: AttributedString) -> Bool {
        !text.runs.contains { $0.backgroundColor != nil }
    }

    /// The renderer a container hands a child block of `kind` in `parent`:
    /// `.swiftUI` whenever it inherited `.swiftUI` (so a container never
    /// turns TextKit 2 back on below a list row, a table cell or a
    /// container that reset it; the inherited value is the only renderer
    /// input, never a preference), and otherwise `.textKit2` only for a
    /// kind in `allowed` that passes its whole-block rule
    /// (`blockKeepsRenderer`) and the boundary's view-time rules
    /// (`containerGate(for:in:layoutDirection:dynamicTypeSize:)`). It does
    /// not consult `inheritsRenderer`, so a test host that widens `allowed`
    /// can nest a family before its stage.
    static func childRenderer(
        for kind: RenderBlock.Kind, in parent: TextKit2ContainerParent, inherited: ADFTextRenderer,
        allowed: Set<TextKit2BlockKind>, layoutDirection: LayoutDirection, dynamicTypeSize: DynamicTypeSize
    ) -> ADFTextRenderer {
        guard inherited == .textKit2, allowed.contains(TextKit2BlockKind(kind)), blockKeepsRenderer(kind),
              containerGate(for: kind, in: parent, layoutDirection: layoutDirection, dynamicTypeSize: dynamicTypeSize) == nil
        else { return .swiftUI }
        return .textKit2
    }

    // MARK: View-time container rules

    /// Why text eligible by content stays on SwiftUI inside a container for
    /// a reason only the view knows (the width, the layout direction, the
    /// size class, the text size). The coverage walk evaluates none of
    /// them: it counts a document as stacked, left to right and below the
    /// accessibility text sizes, so coverage is the static potential.
    /// Decided by `containerGate`.
    enum ContainerGate: Sendable, Hashable, CaseIterable {
        /// A wrapping leaf whose width bound, less its own inset, is under
        /// `minimumTextWidth` (`textFits`).
        case narrowColumn
        /// A wrapping leaf below a container that cannot bound its insets
        /// (`TextKit2WidthBound.unproven`).
        case unprovenNestedWidth
        /// A child of a container laid out right to left
        /// (`containerDirectionKeepsRenderer`).
        case containerDirection
        /// A family kept out of side-by-side layout columns
        /// (`horizontalColumnKeepsRenderer`).
        case horizontalColumn
        /// A list below a container's boundary at an accessibility text
        /// size (`nestedListSizeKeepsRenderer`): the reason it reports
        /// there, ahead of `.containerSize`, whose outcome is the same.
        case nestedListSize
        /// A child of a container at xxxLarge or above
        /// (`containerSizeKeepsRenderer`).
        case containerSize
    }

    /// Whether a container laid out in `direction` may pass the renderer to
    /// its children (a panel, a quote, an expand body, an extension body or
    /// a layout column): left to right only. Right to left, container
    /// bodies stay on SwiftUI (lead dispositions M3, F-Q6). Measured once
    /// a leaf-drawing failure had to be the leaf's own pixels (the step 3
    /// to 7 family matrices, iOS 26.3, 3x): at AX5 in a 320 pt document, a
    /// quote's paragraph in a stacked 50/50 column differs in 30,159 pixels
    /// (the whole paragraph's ink, drawn at another horizontal pixel
    /// phase) while the same quote alone matches, and a panel holding a
    /// paragraph and a quote (Bold Text) differs in its icon column and in
    /// 55,677 pixels of the quote's paragraph that the blocks alone do not
    /// differ in. Left to right the same cases pass. Lists and code were
    /// already kept on SwiftUI right to left below a boundary (rule C, the
    /// code gate); this keeps the prose, headings and captions there too.
    static func containerDirectionKeepsRenderer(_ direction: LayoutDirection) -> Bool {
        direction == .leftToRight
    }

    /// Whether a child of `kind` may keep the renderer in a side-by-side
    /// layout column (reason `.horizontalColumn` when not): no family yet.
    /// From the off-grid column probe (iOS 26.3 at 3x and 2x, iOS 18.5 at
    /// 3x; three equal and 33.33/66.66 % sections at row widths 288 to
    /// 640 pt, xSmall to xxxLarge, Bold Text, both directions), measured
    /// against the same columns on SwiftUI:
    /// - Paragraphs and quotes: in the 90.667 pt column of a 288 pt row at
    ///   2x (off the pixel grid) TextKit 2 sets the text 11 to 22 pt low
    ///   (half a line or a line at that size), with the same height.
    /// - Lists and panels: the same shift at 3x too, in columns of 85 to
    ///   118 pt on and off the grid (10 to 19 pt; a panel's height 0.5 pt
    ///   at 2x), and a panel's first baseline 11 pt off where the blocks
    ///   alone matched (iOS 18.5, a 112.778 pt column).
    /// Otherwise the same blocks hosted alone at the column's width shift
    /// the same way: the TextKit 2 leaf's shift at those widths, not the
    /// column's. A family returns here when a leaf fix passes the probe.
    /// Extension bodies, expands, code and captions were not probed side
    /// by side and stay out with them. Stacked columns (compact width,
    /// accessibility sizes) passed every case and are unaffected by this
    /// rule: their children are proposed the section's width. The size
    /// rule still applies to them (`containerSizeKeepsRenderer`), so a
    /// column stacked only by an accessibility size stays on SwiftUI.
    static func horizontalColumnKeepsRenderer(_ kind: TextKit2BlockKind) -> Bool {
        switch kind {
        case .richText, .quote, .panel, .listRows: return false
        case .extensionPlaceholder, .expand, .codeBlock, .media, .layoutColumns: return false
        case .divider, .tableSlice, .mediaStrip, .card, .custom, .unknown: return false
        }
    }

    /// Whether a list below a container's boundary may keep the renderer
    /// at the text size `size`: below the accessibility sizes only. With
    /// the size rule's cut-off at xxxLarge (`containerSizeKeepsRenderer`)
    /// this rule changes no outcome: every container child stays on
    /// SwiftUI from xxxLarge. It is the reason a list reports at the
    /// accessibility sizes (`.nestedListSize`, checked first), and it
    /// decides again if that cut-off moves up. At those sizes a
    /// row's marker column and depth padding (about 85 pt a level at AX4)
    /// take most of a nested list's width, and a deep row's text column
    /// narrows to a glyph or less. Measured (iOS 26.3, 3x, the step 6
    /// parity matrix and `ADF_CONTAINER_PROBES_WIDTHS`): a list 268 pt wide
    /// at AX4, in a quote of a 316 pt document, an extension body at 324,
    /// an open expand body at 320 and a stacked column at 300, gives its
    /// depth-2 row a 12 pt column; `Text` and TextKit 2 break its one-glyph
    /// lines apart and the list's first or last baseline lands 28 pt off
    /// (624,490 to 817,989 differing pixels), and in a bodied extension at
    /// 316 with Bold Text so does a 260 pt one. The same list hosted alone
    /// at that width differs too: PR 2's list leaf in that regime (rule D,
    /// `listTextFits`, only rejects a column under 1 pt), which top-level
    /// lists keep unchanged. Containers narrow a list by their insets, so
    /// below a boundary the whole accessibility range stays on SwiftUI,
    /// whatever the width: a category rule, not a measured column floor.
    /// Below the accessibility sizes a marker and gap take under 50 pt a
    /// level, and no measured list case failed.
    static func nestedListSizeKeepsRenderer(_ size: DynamicTypeSize) -> Bool {
        !size.isAccessibilitySize
    }

    /// Whether a container at the text size `size` may pass the renderer
    /// to its children: below xxxLarge only. A measured corpus limit, not
    /// a size mechanism (lead call C55, delta review D-R4): the cut-off is
    /// the smallest size with a real container-body miss, a rule fixed
    /// before the probe ran. That size is xxxLarge, one case (iOS 26.3,
    /// 3x): a panel holding a nested quote in a 320 pt document with Bold
    /// Text, left to right. The quote's paragraph breaks its first line a
    /// word earlier on TextKit 2 than `Text` does, at the same height and
    /// baselines (15,669 differing pixels). The cause is the row's kept
    /// layout, not the size: the paragraph is proposed 208.333 pt, reports
    /// 208.667 pt and is proposed 208.667 pt again; the row keeps the
    /// 208.333 pt layout
    /// (`TextKit2RowView.layoutResult(forProposedWidth:)`) and `Text` lays
    /// out anew there. Without the kept layout the case passes, and a
    /// paragraph is set a line low at the same height elsewhere (31 panel
    /// leaves at real widths, xSmall to AX5), so the kept layout stays. It
    /// is 1 of 576 left-to-right panel pixel cases (12 sizes, 8 document
    /// widths, 3 shapes); AX1 to AX3 pass all of them.
    /// Below xxxLarge the container-leaf sweep (baselines and heights;
    /// every eligible container leaf of containers-parity, kitchen-sink,
    /// stress-1k and stress-5k at the width its containers give it in 320
    /// to 440 pt documents, and at off-grid widths 268 to 276 pt) and 288
    /// of those panel pixel cases are clean.
    /// An earlier reading set the cut-off at AX4, for long words broken
    /// apart differently at AX4 and AX5. It was wrong: 42 of the sweep's 51
    /// misses there came from the test host (2,000 pt tall, where `Text`
    /// truncates a taller leaf and the row does not), and the other 9 are
    /// AX5 at fine-grid widths no document width gives.
    /// So from xxxLarge every container keeps its body on SwiftUI, at
    /// every document width. Stacked columns and lists below a boundary
    /// follow: a list at an accessibility size reports `nestedListSize`
    /// first (lead dispositions M1), with the same outcome. The cut-off
    /// moves up when the row matches `Text` in that case and the sweep is
    /// clean from xxxLarge to AX3.
    static func containerSizeKeepsRenderer(_ size: DynamicTypeSize) -> Bool {
        size < .xxxLarge
    }

    /// The boundary's view-time rules for a child of `kind` in `parent`
    /// laid out in `layoutDirection` at `dynamicTypeSize`
    /// (`childRenderer`): the container's direction
    /// (`.containerDirection`), a side-by-side column's family
    /// (`.horizontalColumn`), a list at an accessibility size
    /// (`.nestedListSize`, a reported reason only: the next rule keeps it
    /// out too), the text size (`.containerSize`); `nil` when
    /// none keeps it on SwiftUI.
    static func containerGate(
        for kind: RenderBlock.Kind, in parent: TextKit2ContainerParent, layoutDirection: LayoutDirection,
        dynamicTypeSize: DynamicTypeSize
    ) -> ContainerGate? {
        if !containerDirectionKeepsRenderer(layoutDirection) { return .containerDirection }
        switch parent {
        case .column(sideBySide: true):
            if !horizontalColumnKeepsRenderer(TextKit2BlockKind(kind)) { return .horizontalColumn }
        case .panel, .quote, .expandBody, .extensionBody, .column(sideBySide: false):
            break
        }
        if case .listRows = kind, !nestedListSizeKeepsRenderer(dynamicTypeSize) { return .nestedListSize }
        if !containerSizeKeepsRenderer(dynamicTypeSize) { return .containerSize }
        return nil
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
    /// bound is written as `.pending`, so no SwiftUI child reads the
    /// container's arithmetic. (The five container views still read their
    /// own bound and compute the child bound on that path; nothing below
    /// them uses it, and the drawing does not depend on it.)
    func adfContainerChild(_ block: RenderBlock, in parent: TextKit2ContainerParent, widthBound: TextKit2WidthBound) -> some View {
        modifier(TextKit2ContainerChild(kind: block.kind, parent: parent, widthBound: widthBound))
    }
}

extension View {
    /// A media caption's text leaf (`MediaBlockView.caption`), its one
    /// use: writes the context `.caption` and the foreground the caption's
    /// SwiftUI text is drawn in, `.secondary` (`adfTextForeground`, which
    /// nothing else sets), so a TextKit 2 row draws the caption's uncoloured
    /// runs as `Text` does and counts itself as a caption. Writes no
    /// renderer: the caption takes the one its media row, or the boundary
    /// of the container it sits in, passed down.
    func adfCaptionLeaf() -> some View {
        environment(\.adfTextContainerContext, .caption)
            .environment(\.adfTextForeground, .secondary)
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        let renderer = TextKit2Scope.childRenderer(
            for: kind, in: parent, inherited: inherited, allowed: allowed, layoutDirection: layoutDirection,
            dynamicTypeSize: dynamicTypeSize
        )
        content
            .environment(\.adfTextRenderer, renderer)
            .environment(\.adfTextWidthBound, inherited == .textKit2 ? widthBound : .pending)
            .environment(\.adfTextContainerContext, .container)
    }
}
