import SwiftUI
import ADFModel
import ADFPreparation

/// Where the host's text engine choice applies. `DocumentRow` passes it to
/// top-level paragraphs and headings (`.richText`), top-level code blocks
/// (`.codeBlock`) and top-level lists (`.listRows`) unless a row holds both
/// a panel and an expand (`listKeepsRenderer`). A list row passes it to its
/// text when its text column holds one text block, or only body-styled
/// paragraphs (`rowKeepsRenderer`, `ListRowView`), laid out left to right
/// (`listDirectionKeepsRenderer`); any other row draws all its text on
/// SwiftUI. Before iOS 26 the leaf itself keeps list text on SwiftUI
/// (`TextKit2Eligibility.listsMatchText`, a `.osGatedList` fallback the
/// coverage counts). A code block has no children and only reads the
/// choice (`CodeBlockView`); its code goes to TextKit 2 when its content is
/// eligible (`TextKit2Eligibility.codeVerdict`) and the code gate admits it
/// where it is drawn (`codeGate`: left to right, within the canvas bound,
/// and before iOS 26 no interior empty line above AX3).
/// A container (panel, quote, expand, layout columns, extension, and media
/// for its caption) keeps the choice at the top level only when its kind
/// is in the container allow list (`containerChildKinds`: panels, quotes,
/// extension bodies, media, expands, layout columns, lists and code
/// blocks) and passes its whole-block rule (`blockKeepsRenderer`, for a panel
/// `panelKeepsRenderer`); its child boundary (`View.adfContainerChild`,
/// `childRenderer`) then passes the choice to the children the same list
/// and rules allow (paragraphs and headings, media, lists, code blocks, and
/// nested panels, quotes, extensions and expands so far; an expand's body
/// only once it is open and prepared), and in side-by-side layout columns
/// to none (`horizontalColumnKeepsRenderer`). A list below a boundary keeps
/// PR 2's row rules unchanged (A to D and the list gate, rule D against the
/// container's width bound) and stays on SwiftUI at the accessibility text
/// sizes (`nestedListSizeKeepsRenderer`). A code block reached that way is
/// the whole code block, as at the top level: the code rules and the code gate still
/// decide its text. A media block's only text is its caption
/// (`MediaBlockView.caption`, `captionsUseTextKit2`,
/// `captionLayoutKeepsRenderer`). Every other top-level kind (table, card,
/// plugin, unknown) gets `.swiftUI`, and so does everything inside it, and
/// so does every child kind the list does not hold; code inside a list
/// item gets `.swiftUI` from its row. Before iOS 26 container text, code
/// and captions stay on SwiftUI at the leaf
/// (`TextKit2Eligibility.containerTextMatchesText`,
/// `containerCodeVerdict`). Those three places are
/// the only ones that set `adfTextRenderer`. The coverage walk
/// (`forEachLeaf`) follows the same rules, so the diagnostics count
/// exactly the leaves the views may hand to TextKit 2 (stacked, left to
/// right).
enum TextKit2Scope {
    /// Whether a top-level block keeps the renderer choice rather than
    /// resetting it to `.swiftUI`: `.richText`, `.codeBlock`, a `.listRows`
    /// that `listKeepsRenderer`, and a container kind in `allowed` (the
    /// container allow list, `containerChildKinds`, unless a coverage walk
    /// is given another) that passes its whole-block rule
    /// (`blockKeepsRenderer`, the rule `childRenderer` applies to a nested
    /// one).
    static func inheritsRenderer(_ kind: RenderBlock.Kind, allowed: Set<TextKit2BlockKind> = containerChildKinds) -> Bool {
        switch kind {
        case .richText: return true
        case .listRows(let rows): return listKeepsRenderer(rows)
        case .codeBlock: return true
        case .panel, .quote, .extensionPlaceholder, .layoutColumns, .expand, .media:
            return allowed.contains(TextKit2BlockKind(kind)) && blockKeepsRenderer(kind)
        case .divider, .tableSlice, .mediaStrip, .card, .custom, .unknown:
            return false
        }
    }

    /// Whether a top-level list may hand its text to TextKit 2: unless a
    /// row holds both a panel and an expand. SwiftUI draws such a row on
    /// either engine, and the list's other rows then land differently on
    /// the two arms: lists-parity's embedded-blocks item (0.10.2: code,
    /// panel, quote, expand, table, rule) left the list's TextKit 2 rows
    /// drawn apart from `Text`'s at AX5 on a 402 pt phone (3x; the same
    /// height, different pixels from 1,000 pt down). Without its panel, or
    /// without its expand, the list matched; without its code block,
    /// quote, table or rule it did not. A list with one row holding any
    /// one of those kinds (code, panel, quote, expand, table, rule, a sync
    /// block, an item that starts with a code block) matched at six sizes
    /// and four widths, 3x and 2x. Every row of such a list keeps its text
    /// on SwiftUI; a row holding any other non-text block keeps only its
    /// own text there (`rowKeepsRenderer`).
    static func listKeepsRenderer(_ rows: [PreparedListRow]) -> Bool {
        !rows.contains { row in
            row.trailingBlocks.contains { if case .panel = $0.kind { return true }; return false }
                && row.trailingBlocks.contains { if case .expand = $0.kind { return true }; return false }
        }
    }

    /// Whether a list row's text may use TextKit 2: when its text column
    /// holds one text block (its leader, or a lone paragraph or heading),
    /// or only paragraphs, leader included, every run of them set in the
    /// body text style (`isBodyText`).
    ///
    /// A row's `HStack` lays its text column out a second time at the
    /// row's own height, and the column's `VStack` shares that height out
    /// among its blocks. A column of one block has the height to itself
    /// and matched in every shape measured. Columns of body paragraphs
    /// matched too, in height and first and last baselines, links, emoji,
    /// bold, italic and inline code included: every multi-paragraph row of
    /// list-dense and lists-parity at Large to AX5 on 375 and 320 pt
    /// documents, and synthetic shapes at xSmall to AX5 and Bold Text on
    /// four widths, at 3x and 2x. A column with a superscript, subscript or
    /// small-text run beside another block kept its height but put its
    /// last baseline up to 62 pt apart (list-dense 0.410.2 at AX5, 375 pt:
    /// 308.67 against 370.67). Such a column, a column with a heading
    /// beside other text, and a row holding any other block (a trailing
    /// list, a container, code, a table, media) keep all their text, and
    /// everything in their trailing blocks, on SwiftUI.
    static func rowKeepsRenderer(_ row: PreparedListRow) -> Bool {
        if row.trailingBlocks.isEmpty { return !row.segments.isEmpty }
        if row.segments.isEmpty, row.trailingBlocks.count == 1, case .richText = row.trailingBlocks[0].kind { return true }
        guard isBodyText(row.segments) else { return false }
        return row.trailingBlocks.allSatisfy { block in
            guard case .richText(let segments, let style) = block.kind, !style.isHeading else { return false }
            return isBodyText(segments)
        }
    }

    /// Whether every text run of `segments` is set in the body text style
    /// (`ADFFontSpec.textStyle`): no superscript, subscript or small text.
    static func isBodyText(_ segments: [InlineSegment]) -> Bool {
        segments.allSatisfy { segment in
            guard case .text(let text) = segment else { return true }
            return text.runs.allSatisfy { ($0.adfFontSpec?.textStyle ?? .body) == .body }
        }
    }

    /// Whether list text laid out in `direction` may use TextKit 2: left
    /// to right only. Right to left, `Text` measures a line that fills its
    /// column differently from left to right and from TextKit — at the
    /// 291.67 pt column of a 375 pt document at AX1 it reports 292 (a pixel
    /// wider than proposed), and at 292 a height a point short of
    /// TextKit's and its own left to right — so a list that grows
    /// to a row's reported width re-proposes every row, and the engines
    /// size them apart: lists-parity drew rows 2 px apart there, and `Text`
    /// truncated a line it had measured as fitting. Coverage counts
    /// (`forEachLeaf`) assume left to right.
    static func listDirectionKeepsRenderer(_ direction: LayoutDirection) -> Bool {
        direction == .leftToRight
    }

    /// The narrowest list text column TextKit 2 draws in. A list row's
    /// `HStack` proposes its text a zero width once the depth padding and
    /// marker column use up the list's width (deep nesting at accessibility
    /// sizes: `lists-parity`'s depth-4 row at AX3 on an iPhone SE, AX2 in a
    /// 320 pt Split View column). `Text` then sets one character per line,
    /// overflowing its zero-width frame; the TextKit 2 row answers a zero
    /// proposal with no layout (the stack also probes every list text with
    /// one, so laying it out would cost each leaf a character-wrapped
    /// layout, measured 4.9 times a column-width one). Measured on
    /// iOS 26.3, the arms agree at every positive width down to one pixel,
    /// so the threshold
    /// only absorbs rounding: a column narrower than this stays on SwiftUI.
    static let minimumListTextWidth: CGFloat = 1

    /// Rule D: whether list text may use TextKit 2 where the list's width
    /// bound (`adfTextWidthBound`) is `bound` and the text column sits
    /// `inset` points inside it: the row's depth padding, decision padding,
    /// marker column and the gap after it, and for a trailing paragraph or
    /// heading its own indentation. An unknown width (`.pending`) passes;
    /// `.unproven` fails; a known one passes when the column is at least
    /// `minimumListTextWidth` wide.
    static func listTextFits(_ bound: TextKit2WidthBound, inset: CGFloat) -> Bool {
        switch bound {
        case .pending: return true
        case .unproven: return false
        case .atLeast(let width): return width - inset >= minimumListTextWidth
        }
    }

    /// The narrowest width any wrapping leaf (paragraph, heading, list
    /// text) is drawn by TextKit 2 at: list rule D's 1 pt
    /// (`minimumListTextWidth`, where the evidence is), applied to every
    /// wrapping leaf. A layout column of zero percent proposes its blocks a
    /// zero width, and a paragraph's indentation takes up to 144 pt of what
    /// it is given; at a zero width `Text` sets one character per line,
    /// over 100 pt tall, where the TextKit 2 row lays nothing out.
    static let minimumTextWidth: CGFloat = minimumListTextWidth

    /// The under-1-pt guard: whether a wrapping leaf may use TextKit 2
    /// where the width bound (`adfTextWidthBound`) is `bound` and the leaf
    /// sits `inset` points inside the region it covers (a paragraph's
    /// indentation). `.pending` passes, `.unproven` fails, and a known
    /// bound passes when at least `minimumTextWidth` is left. Code is
    /// exempt: it never wraps (`TextKit2LayoutPolicy.natural`). A view-time
    /// rule (`TextKit2Leaf`); the coverage walk does not evaluate it.
    static func textFits(_ bound: TextKit2WidthBound, inset: CGFloat) -> Bool {
        switch bound {
        case .pending: return true
        case .unproven: return false
        case .atLeast(let width): return width - inset >= minimumTextWidth
        }
    }

    /// Where a text leaf sits in the scope. `root`, `listLeader`,
    /// `listTrailing` and `codeRoot` are depth 0: outside every container.
    enum Position: Sendable, Hashable {
        /// A top-level paragraph or heading.
        case root
        /// A list row's leading paragraph, owned by `PreparedListRow.id`.
        case listLeader
        /// A paragraph or heading among a list row's trailing blocks, owned
        /// by its own `RenderBlock.id`.
        case listTrailing
        /// The code text of a top-level code block, owned by the block's
        /// `RenderBlock.id`. Not a text leaf of the prose and list set: it
        /// has its own owner kind, verdict and coverage counts.
        case codeRoot
        /// A paragraph or heading below a container's child boundary.
        case containerProse
        /// A list row's leader in a list below a container's boundary.
        case containerListLeader
        /// A paragraph or heading among such a list row's trailing blocks.
        case containerListTrailing
        /// A media caption, owned by `PreparedMedia.id`.
        case caption
        /// The code text of a code block below a container's boundary.
        case containerCode

        /// The owner kind a view at this position draws its text for: the
        /// one the leaf's verdict is decided with. Exhaustive, so a new
        /// position never falls into another's rules (code never takes a
        /// list rule or the list OS gate; container prose and captions are
        /// root text, never list text).
        var ownerKind: TextKit2OwnerKind {
            switch self {
            case .root, .containerProse, .caption: return .root
            case .listLeader, .listTrailing, .containerListLeader, .containerListTrailing: return .list
            case .codeRoot, .containerCode: return .code
            }
        }

        /// Where a view at this position sits (`adfTextContainerContext`).
        /// Exhaustive, like `ownerKind`.
        var context: TextKit2ContainerContext {
            switch self {
            case .root, .listLeader, .listTrailing, .codeRoot: return .none
            case .containerProse, .containerListLeader, .containerListTrailing, .containerCode: return .container
            case .caption: return .caption
            }
        }
    }

    /// One text-bearing leaf in the scope: what a `TextEngineLeaf` draws.
    struct Leaf {
        let ownerID: String
        /// The leaf's inline content; empty for code (`code`).
        let segments: [InlineSegment]
        /// The block's style; `nil` for a leader, which the list row styles
        /// as body text (`ListRowView.leaderStyle(theme:)`), for code
        /// (`CodeBlockView.codeStyle(theme:)`) and for a caption.
        let style: TextBlockStyle?
        let position: Position
        /// The prepared code string of a `.codeRoot` or `.containerCode`
        /// leaf, as the view hands it to its leaf; `nil` at every other
        /// position.
        var code: AttributedString? = nil
        /// The media layout of a `.caption` leaf; `nil` at every other
        /// position.
        var mediaLayout: ADFMediaLayout? = nil

        /// The engine verdict for this leaf where it sits: what
        /// `TextEngineLeaf` decides for it. Paragraphs, headings, list
        /// text and captions are judged from their segments
        /// (`TextKit2Eligibility.verdict(_:owner:context:)`, which in the
        /// caption context also keeps a run-background caption on SwiftUI,
        /// `captionRunsKeepRenderer`), a caption then by its media layout
        /// (`captionLayoutKeepsRenderer`, which the caption's view passes as
        /// `allowsTextKit2`); code is judged
        /// from its prepared string by the code rules
        /// (`TextKit2Eligibility.codeVerdict`, and below a container
        /// `containerCodeVerdict`), never by a list rule.
        var verdict: TextKit2Eligibility.Verdict {
            switch position {
            case .root, .listLeader, .listTrailing, .containerProse, .containerListLeader, .containerListTrailing:
                return TextKit2Eligibility.verdict(segments, owner: position.ownerKind, context: position.context)
            case .caption:
                let verdict = TextKit2Eligibility.verdict(segments, owner: position.ownerKind, context: position.context)
                if case .eligible = verdict, let mediaLayout, !TextKit2Scope.captionLayoutKeepsRenderer(mediaLayout) {
                    return .fallback(.captionLayout)
                }
                return verdict
            case .codeRoot:
                return TextKit2Eligibility.codeVerdict(code ?? AttributedString())
            case .containerCode:
                return TextKit2Eligibility.containerCodeVerdict(code ?? AttributedString(), context: position.context)
            }
        }
    }

    /// Visits every leaf in the scope, in prepared (depth-first,
    /// column-major) order: top-level paragraphs and headings, list text,
    /// and the code of top-level code blocks (`.codeRoot`, which is not
    /// list text: a caller that wants the prose and list set skips it); and
    /// below every container the renderer reaches (`inheritsRenderer`,
    /// then `childRenderer` at each boundary, with `allowed` as the allow
    /// list), its paragraphs, headings, list text, code and captions at
    /// the container positions. Containers are walked as the views draw
    /// them stacked, left to right and below the accessibility text sizes
    /// (at Large); no other view-time rule (`containerGate`) is evaluated.
    /// A row with empty segments has no
    /// leader view, so it is not a leaf, and neither is an absent or empty
    /// caption. An expand's body is not prepared with the document, so the
    /// walk never enters one: it reports each expand in scope to
    /// `unpreparedExpand` instead.
    static func forEachLeaf(
        in blocks: [RenderBlock], allowed: Set<TextKit2BlockKind> = containerChildKinds,
        unpreparedExpand: (RenderBlock) -> Void = { _ in }, _ visit: (Leaf) -> Void
    ) {
        for block in blocks {
            switch block.kind {
            case .richText(let segments, let style):
                visit(Leaf(ownerID: block.id, segments: segments, style: style, position: .root))
            case .listRows(let rows) where listKeepsRenderer(rows):
                forEachLeaf(inList: rows, nested: false, visit)
            case .codeBlock(_, let code):
                visit(Leaf(ownerID: block.id, segments: [], style: nil, position: .codeRoot, code: code))
            default:
                guard inheritsRenderer(block.kind, allowed: allowed) else { continue }
                forEachLeaf(inContainer: block, allowed: allowed, unpreparedExpand: unpreparedExpand, visit)
            }
        }
    }

    /// `nested`: the list sits below a container's boundary.
    private static func forEachLeaf(inList rows: [PreparedListRow], nested: Bool, _ visit: (Leaf) -> Void) {
        for row in rows where rowKeepsRenderer(row) {
            if !row.segments.isEmpty {
                visit(Leaf(ownerID: row.id, segments: row.segments, style: nil, position: nested ? .containerListLeader : .listLeader))
            }
            for block in row.trailingBlocks {
                if case .richText(let segments, let style) = block.kind {
                    visit(Leaf(ownerID: block.id, segments: segments, style: style, position: nested ? .containerListTrailing : .listTrailing))
                }
            }
        }
    }

    /// The leaves under a container block the renderer reached (a
    /// top-level one, or a child its parent's boundary passed it to): its
    /// children through its own boundary, a caption, or for an expand the
    /// report that its body is not prepared.
    private static func forEachLeaf(
        inContainer block: RenderBlock, allowed: Set<TextKit2BlockKind>,
        unpreparedExpand: (RenderBlock) -> Void, _ visit: (Leaf) -> Void
    ) {
        func children(_ blocks: [RenderBlock], in parent: TextKit2ContainerParent) {
            for child in blocks where childRenderer(
                for: child.kind, in: parent, inherited: .textKit2, allowed: allowed, layoutDirection: .leftToRight,
                dynamicTypeSize: .large
            ) == .textKit2 {
                switch child.kind {
                case .richText(let segments, let style):
                    visit(Leaf(ownerID: child.id, segments: segments, style: style, position: .containerProse))
                case .listRows(let rows):
                    forEachLeaf(inList: rows, nested: true, visit)
                case .codeBlock(_, let code):
                    visit(Leaf(ownerID: child.id, segments: [], style: nil, position: .containerCode, code: code))
                default:
                    forEachLeaf(inContainer: child, allowed: allowed, unpreparedExpand: unpreparedExpand, visit)
                }
            }
        }
        switch block.kind {
        case .panel(_, let blocks): children(blocks, in: .panel)
        case .quote(let blocks): children(blocks, in: .quote)
        case .extensionPlaceholder(_, let body): children(body, in: .extensionBody)
        case .layoutColumns(let columns):
            for column in columns { children(column.blocks, in: .column(sideBySide: false)) }
        case .expand: unpreparedExpand(block)
        case .media(let media):
            if let caption = media.caption, !caption.isEmpty {
                visit(Leaf(ownerID: media.id, segments: caption, style: nil, position: .caption, mediaLayout: media.layout))
            }
        case .richText, .codeBlock, .listRows, .divider, .tableSlice, .mediaStrip, .card, .custom, .unknown:
            break
        }
    }
}

// MARK: - Code blocks

/// The view-time rules for a code block's code text. The content rules are
/// `TextKit2Eligibility.codeVerdict`; these depend on where and how the
/// block is drawn, so `TextKit2CodeGate` evaluates them when the switch is
/// on, and `ADFTextRenderer.textKit2CodeAdmission` evaluates the same
/// functions at an explicit environment.
extension TextKit2Scope {
    /// Why code that is eligible by content stays on SwiftUI where it is
    /// drawn (`codeGate`).
    enum CodeGate: Sendable, Hashable {
        /// Laid out right to left (`codeDirectionKeepsRenderer`).
        case direction
        /// No admitted canvas bound at this text size, weight and scale
        /// (`codeCanvasBound`): the bound is over a cap, or cannot be
        /// stated for this font.
        case canvas
        /// Before iOS 26, above AX3: code with an interior empty line
        /// (`codeEmptyLinesKeepRenderer`). On iOS 18.5 at AX5 the row was
        /// 1.333 / 3.667 pt taller than `Text` for one / three such lines.
        case osGatedEmptyLines
    }

    /// Whether code laid out in `direction` may use TextKit 2: left to
    /// right only. Code never wraps, so its row is laid out in an unbounded
    /// container (`TextKit2LayoutPolicy.natural`), where only left-aligned
    /// lines start at the row's own edge. Right to left, `Text` aligns the
    /// lines to the trailing edge, which needs a finite container and a
    /// second layout: that is a design of its own, so such code stays on
    /// SwiftUI. Coverage counts (`forEachLeaf`) assume left to right.
    static func codeDirectionKeepsRenderer(_ direction: LayoutDirection) -> Bool {
        direction == .leftToRight
    }

    /// The largest canvas a code row may need, per dimension, in pixels.
    ///
    /// A TextKit 2 row draws into one untiled canvas as large as the whole
    /// block, so its cost grows with the block, not with the viewport. This
    /// and `maximumCodeCanvasBytes` are provisional engineering admission
    /// caps chosen by judgement: not measured safe limits of any device,
    /// and no guarantee about memory (several admitted rows can be alive at
    /// once, and the nominal bytes are not the allocation). A block whose
    /// bound is over either cap stays on SwiftUI, exactly as on main.
    static let maximumCodeCanvasDimension = 8_192

    /// The largest nominal canvas a code row may need: bound width × bound
    /// height × 4 bytes, 16 MiB. See `maximumCodeCanvasDimension`.
    static let maximumCodeCanvasBytes = 16 * 1_024 * 1_024

    /// Lines of vertical ink reserve in the bound: one above the first
    /// line's box and one below the last line's. A layout fragment's
    /// rendering surface can reach past its line boxes; the code font's
    /// own glyph ink is checked to stay within half a line of them
    /// (`TextKit2CodeMetrics`), and the other half is margin.
    static let codeCanvasInkReserveLines: CGFloat = 2

    /// Points of vertical rounding reserve in the bound: the row rounds its
    /// canvas's vertical extent outwards to whole points, under a point at
    /// each edge.
    static let codeCanvasRoundingReservePoints: CGFloat = 2

    /// Pixels of horizontal reserve in the bound: one for the pixel-snapped
    /// frame SwiftUI places the row at, one for the difference between the
    /// typesetter's sum of advances and the bound's product.
    static let codeCanvasWidthReservePixels: CGFloat = 2

    /// The two metrics of a code font the canvas bound is stated in.
    struct CodeFontMetrics: Sendable, Hashable {
        /// The advance every printable ASCII glyph of the font has.
        let advance: CGFloat
        /// A line's height, at least the distance between two baselines:
        /// ascent + descent + the leading when it is positive.
        let lineHeight: CGFloat
    }

    /// An upper bound on the canvas a code row needs, with the inputs it
    /// was computed from. For an admitted row the canvas the row really
    /// allocates is never larger: `actual ≤ bound ≤ cap`.
    struct CodeCanvasBound: Sendable, Hashable {
        /// Inputs: the prepared shape's line facts, the font's metrics and
        /// the display scale.
        let maxLineUTF16: Int
        let lineCount: Int
        let advance: CGFloat
        let lineHeight: CGFloat
        let displayScale: CGFloat
        /// The bound, in pixels, and its nominal bytes (width × height × 4).
        let pixelWidth: Int
        let pixelHeight: Int
        let nominalBytes: Int

        /// Whether the bound is within both admission caps.
        var isWithinCaps: Bool {
            pixelWidth <= TextKit2Scope.maximumCodeCanvasDimension
                && pixelHeight <= TextKit2Scope.maximumCodeCanvasDimension
                && nominalBytes <= TextKit2Scope.maximumCodeCanvasBytes
        }
    }

    /// The canvas bound for code of `shape` set in a font with these
    /// metrics, whether or not it is within the caps; `nil` when no bound
    /// can be stated: the shape is outside the admitted cohort, an input is
    /// not finite and positive, or the arithmetic does not fit an `Int`.
    ///
    /// **Admitted cohort:** every scalar printable ASCII or LF
    /// (`ADFCodeShape.isPrintableASCIIAndLF`), at least one character on a
    /// line, in one monospaced font (the caller's `advance` is that font's
    /// fixed advance). Only there is `maxLineUTF16 × advance` a width no
    /// line exceeds: a tab's width depends on its column, a non-ASCII
    /// scalar can take a wider glyph or a fallback font, and another line
    /// break changes the line count.
    ///
    /// **What it bounds** (`TextKit2RowView.syncToBounds`): the canvas is
    /// the row's bounds horizontally, and vertically the bounds joined with
    /// the ink bounds, rounded outwards to whole points; its backing store
    /// is that frame times the display scale. The row is placed at its
    /// natural size: the longest line's width and the last baseline plus
    /// descent, each ceiled to a pixel.
    ///
    ///     pixelWidth  = ceil(maxLineUTF16 × advance × scale) + 2
    ///     pixelHeight = ceil(((lineCount + 2) × lineHeight + 2) × scale)
    ///
    /// Width: no line is wider than `maxLineUTF16` fixed advances; the two
    /// pixels are `codeCanvasWidthReservePixels`. Height: each line moves
    /// the baseline by at most `lineHeight`, so the line boxes end within
    /// `lineCount × lineHeight`; two more lines are the ink reserve
    /// (`codeCanvasInkReserveLines`) and two points the rounding reserve
    /// (`codeCanvasRoundingReservePoints`), which also covers the pixel
    /// ceil and pixel snap of the placed height because a line is at least
    /// two pixels tall (checked).
    static func codeCanvasEstimate(
        _ shape: ADFCodeShape, advance: CGFloat, lineHeight: CGFloat, displayScale: CGFloat
    ) -> CodeCanvasBound? {
        guard shape.isPrintableASCIIAndLF, shape.maxLineUTF16 > 0, shape.lineCount > 0,
              advance.isFinite, advance > 0, lineHeight.isFinite, lineHeight > 0,
              displayScale.isFinite, displayScale > 0, lineHeight * displayScale >= 2 else { return nil }
        // Floating point first, so nothing can trap: a product too large
        // for an `Int` (or not finite) fails the exact conversion below.
        let width = (CGFloat(shape.maxLineUTF16) * advance * displayScale).rounded(.up) + codeCanvasWidthReservePixels
        let points = (CGFloat(shape.lineCount) + codeCanvasInkReserveLines) * lineHeight + codeCanvasRoundingReservePoints
        let height = (points * displayScale).rounded(.up)
        guard let pixelWidth = Int(exactly: width), let pixelHeight = Int(exactly: height) else { return nil }
        let area = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
        let bytes = area.partialValue.multipliedReportingOverflow(by: 4)
        guard !area.overflow, !bytes.overflow else { return nil }
        return CodeCanvasBound(
            maxLineUTF16: shape.maxLineUTF16, lineCount: shape.lineCount,
            advance: advance, lineHeight: lineHeight, displayScale: displayScale,
            pixelWidth: pixelWidth, pixelHeight: pixelHeight, nominalBytes: bytes.partialValue
        )
    }

    /// The admitted canvas bound for code of `shape` set in a font with
    /// these metrics: `codeCanvasEstimate` when it is within both caps
    /// (`maximumCodeCanvasDimension` per dimension, `maximumCodeCanvasBytes`
    /// nominal), else `nil`, and the code stays on SwiftUI.
    static func codeCanvasBound(
        _ shape: ADFCodeShape, advance: CGFloat, lineHeight: CGFloat, displayScale: CGFloat
    ) -> CodeCanvasBound? {
        guard let bound = codeCanvasEstimate(shape, advance: advance, lineHeight: lineHeight, displayScale: displayScale),
              bound.isWithinCaps else { return nil }
        return bound
    }
}
