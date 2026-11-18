import Foundation
import SwiftUI
import ADFPreparation
#if canImport(UIKit)
import UIKit
#endif

/// A read-only snapshot of the TextKit 2 renderer's counters — the proof of
/// which text engine actually drew, independent of the host's switch state.
///
/// Every counter is about TextKit 2 rows only: text that falls back renders
/// through SwiftUI's `Text` and is not counted here (see
/// `ADFTextKit2Coverage` for which text falls back). A row whose text has
/// a link is laid out and drawn by its own TextKit 1 stack, as `Text` lays
/// out linked text: such rows and their draws are counted apart
/// (`textKit1Backed…`) and never as native TextKit 2 draws. `liveRowCount`,
/// `liveListRowCount`, `liveCodeRowCount`, `liveContainerRowCount`,
/// `liveCaptionRowCount`, `liveOffWindowRowCount` and
/// `textKit1BackedRowCount` count row views currently alive (back to zero
/// once a switch to `.swiftUI` has released them); the others are
/// cumulative since launch. Always zero on platforms without UIKit.
public struct ADFTextKit2Stats: Sendable, Hashable {
    /// TextKit 2 row views currently alive.
    public var liveRowCount: Int
    /// Full `ensureLayout` passes performed by TextKit 2 rows since launch.
    public var layoutCount: Int
    /// `draw(_:)` passes of TextKit 2 rows since launch.
    public var drawCount: Int
    /// Draw passes in which TextKit 2 itself drew glyphs (at least one
    /// `NSTextLayoutFragment`) — the proof that native TextKit 2 rendering
    /// ran, not merely that a row view existed.
    public var nativeDrawCount: Int
    /// Of `liveRowCount`: rows laid out and drawn by their TextKit 1 stack
    /// (text with a link).
    public var textKit1BackedRowCount: Int
    /// Of `drawCount`: draw passes TextKit 1 performed (never counted in
    /// `nativeDrawCount`).
    public var textKit1BackedDrawCount: Int
    /// Of `liveRowCount`: rows drawing list text, a list row's leader or one
    /// of its direct paragraphs and headings (the list-native proof: a
    /// top-level heading drawing natively proves nothing about lists).
    public var liveListRowCount: Int
    /// Conversions of prepared text (`AttributedString`) into the
    /// `NSAttributedString` a row lays out, since launch: one when a row
    /// first gets its text and one per later text or layout-input change,
    /// never for an appearance flip.
    public var conversionCount: Int
    /// Of `liveRowCount`: rows drawing a code block's code text (the
    /// code-native proof: a paragraph or list row drawing natively proves
    /// nothing about code).
    public var liveCodeRowCount: Int
    /// Of `nativeDrawCount`: the native draw passes of rows drawing code,
    /// counted where TextKit 2 drew the fragments. A live code row that has
    /// not drawn yet does not count.
    public var codeNativeDrawCount: Int
    /// Of `liveRowCount`: rows drawing text below a container's boundary
    /// that is not code (paragraphs, headings and list text in a panel,
    /// quote, expand body, extension body or layout column): the
    /// container-native proof. A code block in a container counts as code
    /// only, so a code row never proves container text.
    public var liveContainerRowCount: Int
    /// Of `nativeDrawCount`: the native draw passes of those container rows.
    public var containerNativeDrawCount: Int
    /// Of `textKit1BackedDrawCount`: the draw passes of those container
    /// rows that their TextKit 1 stack performed (linked text; never
    /// native proof).
    public var containerTextKit1DrawCount: Int
    /// Of `liveRowCount`: rows drawing a media caption.
    public var liveCaptionRowCount: Int
    /// Of `nativeDrawCount`: the native draw passes of caption rows.
    public var captionNativeDrawCount: Int
    /// Of `liveRowCount`: row views alive outside any window (`window ==
    /// nil`), such as rows the lazy stack keeps after showing them, with
    /// the engine they were built with. Not every row missing from an
    /// accessibility census: rows the lazy stack keeps in its window
    /// beyond the viewport are not counted (list-dense with TextKit 2 at
    /// L6's census points, iOS 26.3: 0, 0 and 16 here against 5, 16 and
    /// 16 live rows outside the census). A row is counted from its
    /// creation until it first enters a window, so a count read before
    /// the first layout pass (`-rendererStats` at READY) can include every
    /// row.
    public var liveOffWindowRowCount: Int

    public init(
        liveRowCount: Int, layoutCount: Int, drawCount: Int, nativeDrawCount: Int = 0,
        textKit1BackedRowCount: Int = 0, textKit1BackedDrawCount: Int = 0,
        liveListRowCount: Int = 0, conversionCount: Int = 0,
        liveCodeRowCount: Int = 0, codeNativeDrawCount: Int = 0,
        liveContainerRowCount: Int = 0, containerNativeDrawCount: Int = 0, containerTextKit1DrawCount: Int = 0,
        liveCaptionRowCount: Int = 0, captionNativeDrawCount: Int = 0, liveOffWindowRowCount: Int = 0
    ) {
        self.liveRowCount = liveRowCount
        self.layoutCount = layoutCount
        self.drawCount = drawCount
        self.nativeDrawCount = nativeDrawCount
        self.textKit1BackedRowCount = textKit1BackedRowCount
        self.textKit1BackedDrawCount = textKit1BackedDrawCount
        self.liveListRowCount = liveListRowCount
        self.conversionCount = conversionCount
        self.liveCodeRowCount = liveCodeRowCount
        self.codeNativeDrawCount = codeNativeDrawCount
        self.liveContainerRowCount = liveContainerRowCount
        self.containerNativeDrawCount = containerNativeDrawCount
        self.containerTextKit1DrawCount = containerTextKit1DrawCount
        self.liveCaptionRowCount = liveCaptionRowCount
        self.captionNativeDrawCount = captionNativeDrawCount
        self.liveOffWindowRowCount = liveOffWindowRowCount
    }
}

/// Which of a document's text the TextKit 2 renderer may draw, from its
/// prepared blocks (static: it does not know an active search, which keeps
/// highlighted owners on SwiftUI, or the host's text environment, so it is
/// potential coverage; the live counters in `ADFTextKit2Stats` are the
/// execution proof). Content-based, plus one OS rule (two or more trailing
/// hard breaks fall back before iOS 26), so the counts can differ between
/// iOS 18 and iOS 26 for the same document.
///
/// **Text leaves** count every text-bearing view in the renderer's scope
/// (`TextKit2Scope`): top-level paragraphs and headings, list leaders (a
/// row with empty segments has none) and a list row's direct paragraphs
/// and headings, at every list depth. Text inside containers, tables,
/// captions and expand bodies, including lists there, is out of scope and
/// not counted. Each leaf is eligible or falls back:
/// `eligibleTextLeaves + fallbackTextLeaves == eligibleRoots +
/// textFallbackRoots + listLeaderLeaves + listTrailingLeaves`.
///
/// The text leaves are that established prose and list set, not all text
/// TextKit 2 may draw: code is counted apart, below.
///
/// **Roots (root richText, legacy)**: `eligibleRoots`, `fallbackRoots`,
/// `textFallbackRoots` and `linkRoots` keep their PR 1 meaning, top-level
/// blocks only. `fallbackRoots` is every top-level block that is not an
/// eligible paragraph or heading, top-level lists and code blocks
/// included. It is not a count of blocks drawn wholly by SwiftUI; use the
/// leaf and code counts for that.
///
/// **Code roots**: `eligibleCodeRoots` and `fallbackCodeRoots` split the
/// top-level code blocks by the content verdict alone
/// (`eligibleCodeRoots + fallbackCodeRoots ==` the top-level code blocks).
/// Code is never in `eligibleRoots`, `eligibleTextLeaves` or
/// `fallbackTextLeaves`. Code inside a list item or a container is out of
/// scope and not counted. Whether an eligible code block is really drawn by
/// TextKit 2 also depends on where it is drawn (layout direction, the
/// canvas bound at the text size, weight and display scale, and before
/// iOS 26 interior empty lines above AX3), which these
/// static counts assume favourable: `ADFTextRenderer.textKit2CodeAdmission`
/// measures that at an explicit environment.
///
/// **Containers and captions** (static potential): every field above keeps
/// its depth-0 meaning, so text below a container's boundary and captions
/// join none of them. Text the container allow list lets the renderer
/// reach below a container is counted apart: its paragraphs, headings and
/// list text (`eligibleContainerLeaves + fallbackContainerLeaves`, with
/// `linkedContainerLeaves` a subset of the eligible ones and
/// `containerListLeaves` the list text among them), its code
/// (`eligibleNestedCode`, `fallbackNestedCode`), and media captions
/// (`eligibleCaptionLeaves`, `fallbackCaptionLeaves`). Containers are
/// counted as drawn stacked and left to right; a view-time rule (a narrow
/// column, a right-to-left panel, a family kept out of side-by-side
/// columns) can still keep counted text on SwiftUI. Expand bodies are not
/// prepared with the document, so their text is never counted:
/// `unpreparedExpands` counts the expands in scope whose bodies the count
/// could not enter. Before iOS 26 the container leaves, nested code and
/// captions in scope count as fallbacks
/// (`TextKit2Eligibility.containerTextMatchesText`, `containerCodeVerdict`).
public struct ADFTextKit2Coverage: Sendable, Hashable {
    /// Top-level paragraphs and headings TextKit 2 draws (root richText,
    /// legacy).
    public var eligibleRoots: Int
    /// Every other top-level block (root richText, legacy).
    public var fallbackRoots: Int
    /// Of `fallbackRoots`: top-level paragraphs and headings that stay on
    /// SwiftUI (inline atoms, undescribable theme fonts, empty text,
    /// trailing hard breaks before iOS 26) (root richText, legacy).
    public var textFallbackRoots: Int
    /// Of `eligibleRoots`: those containing a link, which the row lays out
    /// and draws with TextKit 1 (`ADFTextKit2Stats.textKit1BackedRowCount`)
    /// (root richText, legacy).
    public var linkRoots: Int
    /// Text leaves TextKit 2 draws: the eligible roots plus eligible list
    /// leaders and list rows' direct paragraphs and headings.
    public var eligibleTextLeaves: Int
    /// Of `eligibleTextLeaves`: those containing a link (TextKit 1-backed
    /// rows).
    public var linkedTextLeaves: Int
    /// Text leaves in scope that stay on SwiftUI (the reasons above).
    public var fallbackTextLeaves: Int
    /// Text leaves that are list leaders, eligible or not.
    public var listLeaderLeaves: Int
    /// Text leaves that are a list row's direct paragraphs and headings,
    /// eligible or not.
    public var listTrailingLeaves: Int
    /// Top-level code blocks whose code text TextKit 2 may draw, by
    /// content: non-empty, in a monospaced theme font spec, printable ASCII
    /// and line feeds only (and, before iOS 26, not ending in two or more
    /// line feeds).
    public var eligibleCodeRoots: Int
    /// Top-level code blocks whose code stays on SwiftUI for a content
    /// reason.
    public var fallbackCodeRoots: Int
    /// Paragraphs, headings and list text below a container's boundary in
    /// scope that TextKit 2 may draw.
    public var eligibleContainerLeaves: Int
    /// Of `eligibleContainerLeaves`: those containing a link (TextKit
    /// 1-backed rows).
    public var linkedContainerLeaves: Int
    /// Paragraphs, headings and list text below a container's boundary in
    /// scope that stay on SwiftUI by content.
    public var fallbackContainerLeaves: Int
    /// Of the container leaves (eligible or not): list leaders and list
    /// rows' direct paragraphs and headings.
    public var containerListLeaves: Int
    /// Non-empty media captions in scope that TextKit 2 may draw, and that
    /// stay on SwiftUI by content.
    public var eligibleCaptionLeaves: Int
    public var fallbackCaptionLeaves: Int
    /// Code blocks below a container's boundary in scope, by the content
    /// verdict (`TextKit2Eligibility.containerCodeVerdict`: PR 3's content
    /// rules from iOS 26, `osGatedContainer` before it): never in the code
    /// root counts, so `eligibleCodeRoots + fallbackCodeRoots` still sums to
    /// the top-level code blocks.
    public var eligibleNestedCode: Int
    public var fallbackNestedCode: Int
    /// Expands (nested ones included) in scope whose bodies, not prepared
    /// with the document, the count could not enter.
    public var unpreparedExpands: Int

    public init(
        eligibleRoots: Int, fallbackRoots: Int, textFallbackRoots: Int = 0, linkRoots: Int = 0,
        eligibleTextLeaves: Int = 0, linkedTextLeaves: Int = 0, fallbackTextLeaves: Int = 0,
        listLeaderLeaves: Int = 0, listTrailingLeaves: Int = 0,
        eligibleCodeRoots: Int = 0, fallbackCodeRoots: Int = 0,
        eligibleContainerLeaves: Int = 0, linkedContainerLeaves: Int = 0, fallbackContainerLeaves: Int = 0,
        containerListLeaves: Int = 0, eligibleCaptionLeaves: Int = 0, fallbackCaptionLeaves: Int = 0,
        eligibleNestedCode: Int = 0, fallbackNestedCode: Int = 0, unpreparedExpands: Int = 0
    ) {
        self.eligibleContainerLeaves = eligibleContainerLeaves
        self.linkedContainerLeaves = linkedContainerLeaves
        self.fallbackContainerLeaves = fallbackContainerLeaves
        self.containerListLeaves = containerListLeaves
        self.eligibleCaptionLeaves = eligibleCaptionLeaves
        self.fallbackCaptionLeaves = fallbackCaptionLeaves
        self.eligibleNestedCode = eligibleNestedCode
        self.fallbackNestedCode = fallbackNestedCode
        self.unpreparedExpands = unpreparedExpands
        self.eligibleRoots = eligibleRoots
        self.fallbackRoots = fallbackRoots
        self.textFallbackRoots = textFallbackRoots
        self.linkRoots = linkRoots
        self.eligibleTextLeaves = eligibleTextLeaves
        self.linkedTextLeaves = linkedTextLeaves
        self.fallbackTextLeaves = fallbackTextLeaves
        self.listLeaderLeaves = listLeaderLeaves
        self.listTrailingLeaves = listTrailingLeaves
        self.eligibleCodeRoots = eligibleCodeRoots
        self.fallbackCodeRoots = fallbackCodeRoots
    }
}

extension ADFTextRenderer {
    /// The current TextKit 2 counters (see `ADFTextKit2Stats`).
    @MainActor
    public static var textKit2Stats: ADFTextKit2Stats {
        TextKit2Diagnostics.shared.snapshot
    }

    /// The live TextKit 2 rows drawing a code block's code, by owner
    /// (`RenderBlock.id`): for each, the native draw passes its live row
    /// has dispatched since that row came alive. The per-owner proof
    /// behind `ADFTextKit2Stats.codeNativeDrawCount`: a count above zero
    /// says TextKit 2 itself drew that block's code, which a total cannot
    /// say for one block. A live row that has not drawn yet is listed with
    /// zero; a block whose code is on SwiftUI is absent; an entry goes when
    /// its row is released, so the snapshot never holds more owners than
    /// there are live code rows (`liveCodeRowCount`). A row without an
    /// owner id (a preview) is not listed. A count says the row drew, not
    /// that it is on screen now. Always empty on platforms without UIKit.
    @_spi(ADFDiagnostics)
    @MainActor
    public static var textKit2CodeRowDraws: [String: Int] {
        TextKit2Diagnostics.shared.codeRowDraws
    }

    /// The live TextKit 2 rows drawing container text that is not code (a
    /// paragraph or heading by its `RenderBlock.id`, a nested list's text
    /// by its `PreparedListRow.id` or trailing block's id), by owner, with
    /// the native draw passes each live row has dispatched: the per-owner
    /// proof behind `ADFTextKit2Stats.containerNativeDrawCount`, kept as
    /// `textKit2CodeRowDraws` is (zero for a row that has not drawn natively
    /// yet, a linked TextKit 1-backed row included; an entry goes with its
    /// last row; never more owners than `liveContainerRowCount`). Always
    /// empty on platforms without UIKit.
    @_spi(ADFDiagnostics)
    @MainActor
    public static var textKit2ContainerRowDraws: [String: Int] {
        TextKit2Diagnostics.shared.containerRowDraws
    }

    /// The live TextKit 2 rows drawing a media caption, by owner
    /// (`PreparedMedia.id`), with their native draw passes, kept as
    /// `textKit2CodeRowDraws` is. Always empty on platforms without UIKit.
    @_spi(ADFDiagnostics)
    @MainActor
    public static var textKit2CaptionRowDraws: [String: Int] {
        TextKit2Diagnostics.shared.captionRowDraws
    }

    /// Leaves currently rendered by the rebuild control
    /// (`View.adfRebuildControl`; on screen or held by the lazy stack), and
    /// how many have appeared since launch — the proof that a control switch
    /// rebuilt rows rather than doing nothing.
    @_spi(ADFDiagnostics)
    @MainActor
    public static var rebuildControlRows: (live: Int, appeared: Int) {
        (TextKit2Diagnostics.shared.rebuildControlLiveRows, TextKit2Diagnostics.shared.rebuildControlAppearances)
    }

    /// Classifies a document's text (`ADFDocumentModel.blocks`) by whether
    /// the TextKit 2 renderer draws it: its text leaves in the renderer's
    /// scope, its top-level blocks, its top-level code blocks, and the text
    /// below its containers and in its captions (see
    /// `ADFTextKit2Coverage`).
    public static func textKit2Coverage(of blocks: [RenderBlock]) -> ADFTextKit2Coverage {
        textKit2Coverage(of: blocks, allowed: TextKit2Scope.containerChildKinds)
    }

    /// `textKit2Coverage(of:)` with `allowed` as the container allow list
    /// (`TextKit2Scope.containerChildKinds` in the app; a test widens it to
    /// count a family before its stage).
    static func textKit2Coverage(of blocks: [RenderBlock], allowed: Set<TextKit2BlockKind>) -> ADFTextKit2Coverage {
        var coverage = ADFTextKit2Coverage(eligibleRoots: 0, fallbackRoots: 0)
        // Counted apart from `coverage`, which the leaf visitor writes: the
        // walk takes the two closures together.
        var unpreparedExpands = 0
        TextKit2Scope.forEachLeaf(in: blocks, allowed: allowed, unpreparedExpand: { _ in unpreparedExpands += 1 }) { leaf in
            let root = leaf.position == .root
            switch leaf.position {
            case .root: break
            case .listLeader: coverage.listLeaderLeaves += 1
            case .listTrailing: coverage.listTrailingLeaves += 1
            case .codeRoot:
                // Code has its own two counts and joins no text-leaf or
                // root total: those keep meaning the prose and list set.
                if case .eligible = leaf.verdict {
                    coverage.eligibleCodeRoots += 1
                } else {
                    coverage.fallbackCodeRoots += 1
                }
                return
            case .containerProse, .containerListLeader, .containerListTrailing:
                // Container text joins no depth-0 total.
                if leaf.position != .containerProse { coverage.containerListLeaves += 1 }
                switch leaf.verdict {
                case .eligible(let text):
                    coverage.eligibleContainerLeaves += 1
                    if text.runs.contains(where: { $0.link != nil }) { coverage.linkedContainerLeaves += 1 }
                case .fallback:
                    coverage.fallbackContainerLeaves += 1
                }
                return
            case .caption:
                if case .eligible = leaf.verdict {
                    coverage.eligibleCaptionLeaves += 1
                } else {
                    coverage.fallbackCaptionLeaves += 1
                }
                return
            case .containerCode:
                if case .eligible = leaf.verdict {
                    coverage.eligibleNestedCode += 1
                } else {
                    coverage.fallbackNestedCode += 1
                }
                return
            }
            switch leaf.verdict {
            case .eligible(let text):
                let linked = text.runs.contains { $0.link != nil }
                coverage.eligibleTextLeaves += 1
                if linked { coverage.linkedTextLeaves += 1 }
                if root {
                    coverage.eligibleRoots += 1
                    if linked { coverage.linkRoots += 1 }
                }
            case .fallback:
                coverage.fallbackTextLeaves += 1
                if root { coverage.textFallbackRoots += 1 }
            }
        }
        coverage.unpreparedExpands = unpreparedExpands
        coverage.fallbackRoots = blocks.count - coverage.eligibleRoots
        return coverage
    }

    /// Measures, at an explicit environment, how many of a document's
    /// content-eligible top-level code blocks the TextKit 2 renderer would
    /// really draw there (`admittedCodeRoots`) and how many a view-time
    /// rule keeps on SwiftUI (`gatedCodeRoots`): right-to-left layout, no
    /// admitted canvas bound at this text size, legibility weight and
    /// display scale, or, before iOS 26, an interior empty line above AX3
    /// (`TextKit2Scope.CodeGate`). `admittedCodeRoots + gatedCodeRoots ==
    /// ADFTextKit2Coverage.eligibleCodeRoots`. The same split of the
    /// content-eligible code below containers in scope is
    /// `nestedCodeAdmitted` and `nestedCodeGated`, which sum to
    /// `ADFTextKit2Coverage.eligibleNestedCode` and never join the root
    /// counts.
    ///
    /// It applies the rule the code views apply, to the same prepared text,
    /// so pass the environment the document is drawn in (the size after any
    /// `dynamicTypeSize` override). It still does not know an active search
    /// or inherited `Text` styling, which keep a block on SwiftUI too. On
    /// platforms without UIKit nothing is drawn by TextKit 2, so every
    /// eligible block counts as gated.
    @MainActor
    public static func textKit2CodeAdmission(
        of blocks: [RenderBlock],
        dynamicTypeSize: DynamicTypeSize,
        legibilityWeight: LegibilityWeight?,
        displayScale: CGFloat,
        layoutDirection: LayoutDirection
    ) -> (admittedCodeRoots: Int, gatedCodeRoots: Int, nestedCodeAdmitted: Int, nestedCodeGated: Int) {
        textKit2CodeAdmission(
            of: blocks, allowed: TextKit2Scope.containerChildKinds, dynamicTypeSize: dynamicTypeSize,
            legibilityWeight: legibilityWeight, displayScale: displayScale, layoutDirection: layoutDirection
        )
    }

    /// `textKit2CodeAdmission(of:…)` with `allowed` as the container allow
    /// list (as `textKit2Coverage(of:allowed:)`).
    @MainActor
    static func textKit2CodeAdmission(
        of blocks: [RenderBlock],
        allowed: Set<TextKit2BlockKind>,
        dynamicTypeSize: DynamicTypeSize,
        legibilityWeight: LegibilityWeight?,
        displayScale: CGFloat,
        layoutDirection: LayoutDirection
    ) -> (admittedCodeRoots: Int, gatedCodeRoots: Int, nestedCodeAdmitted: Int, nestedCodeGated: Int) {
        var admitted = 0
        var gated = 0
        var nestedAdmitted = 0
        var nestedGated = 0
        TextKit2Scope.forEachLeaf(in: blocks, allowed: allowed) { leaf in
            let nested: Bool
            switch leaf.position {
            case .codeRoot: nested = false
            case .containerCode: nested = true
            case .root, .listLeader, .listTrailing, .containerProse, .containerListLeader, .containerListTrailing, .caption:
                return
            }
            guard case .eligible(let text) = leaf.verdict else { return }
            #if canImport(UIKit)
            let isAdmitted = TextKit2Scope.codeGate(
                text, sizeCategory: dynamicTypeSize.uiContentSizeCategory, legibilityWeight: legibilityWeight,
                displayScale: displayScale, layoutDirection: layoutDirection
            ) == nil
            #else
            _ = text
            let isAdmitted = false
            #endif
            switch (nested, isAdmitted) {
            case (false, true): admitted += 1
            case (false, false): gated += 1
            case (true, true): nestedAdmitted += 1
            case (true, false): nestedGated += 1
            }
        }
        return (admitted, gated, nestedAdmitted, nestedGated)
    }
}

/// Which prepared rich text the TextKit 2 arm draws. Anything else stays
/// on SwiftUI's `Text`, unchanged — the arm only takes text whose size and
/// pixels it reproduces exactly (`docs/TextKit2-Stack.md` §6.4). Text with
/// a link is eligible: the row lays it out and draws it with TextKit 1, as
/// `Text` does.
enum TextKit2Eligibility {
    /// Why a paragraph or heading stays on SwiftUI.
    enum Fallback: Sendable, Hashable {
        /// An inline atom (mention, status, …): PR 6.
        case atom
        /// Empty text: SwiftUI sizes an empty `Text` from a fixed 12 pt
        /// system font (measured: 14 pt tall at every Dynamic Type size), a
        /// placeholder with nothing to draw. Text of hard breaks only draws
        /// nothing either, and `Text` puts its baselines where no line
        /// metric does (one break at Large: both at 22 pt, where a body
        /// line's baseline sits at 16.33 pt); a list marker aligns to them.
        case empty
        /// A run without a font spec (a theme font supplied as a raw
        /// SwiftUI `Font`): TextKit cannot resolve the font `Text` would.
        case undescribable
        /// Two or more trailing hard breaks before iOS 26, where `Text`
        /// also drops the middle empty line's negative leading at AX3+
        /// (0.333–1.333 pt shorter, no exact rule found).
        case trailingBreaks
        /// List text (a list row's leader, or a paragraph or heading in its
        /// text column) before iOS 26, where list rows miss `Text`'s
        /// placement (`listsMatchText`).
        case osGatedList
        /// Text below a container's boundary (`TextKit2ContainerContext
        /// .container`), code there included (`containerCodeVerdict`), or a
        /// caption (`.caption`) before iOS 26 (`containerTextMatchesText`).
        case osGatedContainer
        /// A caption under a media layout whose caption frame does not match
        /// `Text`'s (`TextKit2Scope.captionLayoutKeepsRenderer`).
        case captionLayout
        /// Non-empty code that is not one plain prepared run: no
        /// `ADFCodeShape` over all of it (text assembled outside
        /// `DocumentPreparer`), more than one run, or a link or baseline
        /// offset on it. The code rules read the shape instead of scanning
        /// the text, and the single natural layout and the canvas bound
        /// assume one plain run, so this fails closed.
        case unshapedCode
        /// Code whose font spec is not monospaced: no fixed advance, so no
        /// conservative width bound.
        case proportionalCode
        /// Code with a horizontal tab: its width depends on its column.
        case codeTabs
        /// Code with a line break other than LF: CR (so CRLF too), VT, FF,
        /// NEL, U+2028 or U+2029.
        case codeLineBreaks
        /// Code with a scalar above U+007F (and no tab or other line
        /// break): a wider glyph or a fallback font can draw it.
        case codeNonASCII
        /// Code with another control character (U+0000 to U+001F but tab
        /// and the line breaks, or U+007F).
        case codeControls
    }

    enum Verdict: Sendable {
        case eligible(AttributedString)
        case fallback(Fallback)
    }

    /// The merged text of an all-text segment list that TextKit 2 draws
    /// for `owner` in `context`, or `nil` when it falls back (`verdict`).
    /// The preparer emits one merged run per gap, so the common case
    /// returns the stored value without building a new string.
    static func describableText(
        _ segments: [InlineSegment], owner: TextKit2OwnerKind = .root, context: TextKit2ContainerContext = .none
    ) -> AttributedString? {
        if case .eligible(let text) = verdict(segments, owner: owner, context: context) { return text }
        return nil
    }

    /// The prepared attributed text TextKit 2 draws for `owner` in
    /// `context`, or `nil` when it falls back (`verdict(_:owner:context:)`
    /// for attributed text): what `TextEngineLeaf` asks for text it is
    /// handed as one string (a code block's code), without building a
    /// segment array.
    static func describableText(
        _ text: AttributedString, owner: TextKit2OwnerKind, context: TextKit2ContainerContext = .none
    ) -> AttributedString? {
        if case .eligible(let text) = verdict(text, owner: owner, context: context) { return text }
        return nil
    }

    /// The engine verdict for prepared attributed text drawn for `owner` in
    /// `context`. Code (`.code`) is judged by the code rules (`codeVerdict`,
    /// below a container `containerCodeVerdict`), never by a list rule or
    /// the list OS gate; any other owner's text is judged as the same text
    /// in one segment would be.
    static func verdict(_ text: AttributedString, owner: TextKit2OwnerKind, context: TextKit2ContainerContext = .none) -> Verdict {
        switch (owner, context) {
        case (.code, .none): return codeVerdict(text)
        case (.code, .container), (.code, .caption): return containerCodeVerdict(text, context: context)
        case (.root, _), (.list, _): return verdict([.text(text)], owner: owner, context: context)
        }
    }

    /// The engine verdict for a code block's code text below a container's
    /// boundary (`context` `.container`). Before iOS 26 it is
    /// `.osGatedContainer` first, whatever the content: the container gate
    /// keeps everything below a boundary on SwiftUI there
    /// (`containerTextMatchesText`; no hosted sweep of code at container
    /// widths has run on an older runtime). From iOS 26 it is PR 3's content
    /// verdict (`codeVerdict`) unchanged, and the code gate
    /// (`TextKit2Scope.codeGate`: direction, canvas bound) then decides
    /// where the block is drawn, as for top-level code. The view (through
    /// `verdict(_:owner:context:)`) and the coverage walk
    /// (`TextKit2Scope.Leaf.verdict`, counted in `eligibleNestedCode` and
    /// `fallbackNestedCode`) both decide through it. `matchesText` is the
    /// OS rule, passed explicitly only by tests; top-level code
    /// (`context` `.none`) is never gated here.
    static func containerCodeVerdict(
        _ code: AttributedString, context: TextKit2ContainerContext,
        matchesText: Bool = TextKit2Eligibility.containerTextMatchesText
    ) -> Verdict {
        if context != .none, !matchesText { return .fallback(.osGatedContainer) }
        return codeVerdict(code)
    }

    /// The engine verdict for a code block's code text, by content. The
    /// view (`CodeBlockView`, through `TextEngineLeaf`) and the coverage
    /// walk (`TextKit2Scope.Leaf.verdict`) both decide through it; where
    /// the block is drawn is the code gate's (`TextKit2Scope.codeGate`).
    ///
    /// Constant time: it reads the first run's attributes and the prepared
    /// `ADFCodeShape`, and never scans the characters (a view body runs it
    /// on every evaluation). In order:
    /// 1. an empty string, which has no run to carry a shape: `.empty`;
    /// 2. not one run with a shape over all of it: `.unshapedCode`;
    /// 3. newlines only: `.empty`, as for any text;
    /// 4. no font spec (the theme's code font is a raw `Font`):
    ///    `.undescribable`;
    /// 5. a font spec that is not monospaced: `.proportionalCode`;
    /// 6. a link or a baseline offset on the run: `.unshapedCode`;
    /// 7. outside printable ASCII and LF: `.codeTabs`, else
    ///    `.codeLineBreaks`, else `.codeNonASCII`, else `.codeControls`;
    /// 8. two or more trailing line feeds before iOS 26: `.trailingBreaks`,
    ///    as for any text.
    ///
    /// Steps 5 and 7 are the admitted cohort of the canvas bound
    /// (`TextKit2Scope.codeCanvasEstimate`): only there is a conservative
    /// bound proven. The string is never modified.
    static func codeVerdict(_ text: AttributedString) -> Verdict {
        guard let run = text.runs.first else { return .fallback(.empty) }
        guard run.range.upperBound == text.endIndex, let shape = run.adfCodeShape else {
            return .fallback(.unshapedCode)
        }
        if shape.isAllNewlines { return .fallback(.empty) }
        guard let fontSpec = run.adfFontSpec else { return .fallback(.undescribable) }
        guard fontSpec.monospaced else { return .fallback(.proportionalCode) }
        guard run.link == nil, run.baselineOffset == nil else { return .fallback(.unshapedCode) }
        guard shape.isPrintableASCIIAndLF else {
            if shape.hasTabs { return .fallback(.codeTabs) }
            if shape.hasOtherLineBreaks { return .fallback(.codeLineBreaks) }
            if shape.hasNonASCII { return .fallback(.codeNonASCII) }
            return .fallback(.codeControls)
        }
        if !trailingBreaksMatchText, shape.trailingNewlineCount >= 2 {
            return .fallback(.trailingBreaks)
        }
        return .eligible(text)
    }

    /// The engine verdict for text drawn for `owner` (top-level or list
    /// text, or a caption) in `context` (`TextKit2ContainerContext`). The
    /// views (`TextEngineLeaf`) and the coverage walk
    /// (`TextKit2Scope.Leaf.verdict`) both decide through it. Before
    /// iOS 26, text below a container's boundary and captions fall back as
    /// `.osGatedContainer` (`containerTextMatchesText`), after the content
    /// reasons and the list gate. List text in a container is still
    /// `.list`, so the list rules below apply to it unchanged.
    static func verdict(
        _ segments: [InlineSegment], owner: TextKit2OwnerKind = .root, context: TextKit2ContainerContext = .none
    ) -> Verdict {
        // Atoms first, so an atom paragraph (word-chunked, many segments)
        // builds no throwaway merged string.
        for segment in segments {
            guard case .text = segment else { return .fallback(.atom) }
        }
        guard let text = SegmentedTextView.mergedText(segments) else { return .fallback(.atom) }
        guard !text.characters.allSatisfy(\.isNewline) else { return .fallback(.empty) }
        for run in text.runs where run.adfFontSpec == nil {
            return .fallback(.undescribable)
        }
        if !trailingBreaksMatchText, text.characters.reversed().prefix(while: \.isNewline).count >= 2 {
            return .fallback(.trailingBreaks)
        }
        if owner == .list, !listsMatchText { return .fallback(.osGatedList) }
        if context != .none, !containerTextMatchesText { return .fallback(.osGatedContainer) }
        return .eligible(text)
    }

    /// Whether the row's trailing-break rule reproduces `Text` for two or
    /// more trailing breaks (measured exact on iOS 26.3; not on iOS 18.5).
    static var trailingBreaksMatchText: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// Whether list text may use TextKit 2 on this OS: from iOS 26. On
    /// iOS 18.5 (3x) list rows missed the parity iOS 26.3 holds: a row
    /// whose words are wider than its column (lists-parity's depth-three
    /// `LP-ORDERED-L4-A` leader at AX3) laid out a pixel taller on TextKit 2
    /// than `Text`, so lists and documents grew by up to 3 pt (AX1–AX3, and
    /// xxxLarge with Bold Text) in documents 320–402 pt wide; text in a
    /// column 16 pt wide or narrower measured up to 1.7 pt taller; and
    /// Hebrew text filling its column reported a width a pixel narrower
    /// than `Text`'s. None of it reproduces on iOS 26.3. Before iOS 26 list
    /// text that would otherwise be eligible falls back as `.osGatedList`;
    /// top-level paragraphs and headings are unaffected.
    static var listsMatchText: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// Whether text below a container's boundary (code there included,
    /// `containerCodeVerdict`) and captions may use TextKit 2 on this OS:
    /// from iOS 26, where the container parity suites
    /// (`TextKit2ContainerParityTests`) were measured. Before iOS 26 such
    /// text that would otherwise be eligible falls back as
    /// `.osGatedContainer`, and the coverage counts it; only a hosted sweep
    /// at real container widths on that runtime may lift the gate. Root
    /// text, top-level lists and top-level code are unaffected.
    static var containerTextMatchesText: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }
}

/// The TextKit 2 rows' counters (§2.6 of the stack plan). Rows report
/// creation, destruction, layouts and draws; tests and the public snapshot
/// read them. Process-wide: a test compares them only across a span with
/// no suspension, since other suites' rows come and go across one (block
/// ids are document paths, so they don't tell documents apart either).
/// Plain integers: cheap enough to stay on in Release, where the demo's
/// renderer proof needs them.
@MainActor
final class TextKit2Diagnostics {
    static let shared = TextKit2Diagnostics()

    private(set) var liveRowCount = 0
    private(set) var layoutCount = 0
    private(set) var drawCount = 0
    private(set) var nativeDrawCount = 0
    private(set) var textKit1BackedRowCount = 0
    private(set) var textKit1BackedDrawCount = 0
    private(set) var liveListRowCount = 0
    private(set) var conversionCount = 0
    private(set) var liveCodeRowCount = 0
    private(set) var codeNativeDrawCount = 0
    private(set) var liveContainerRowCount = 0
    private(set) var containerNativeDrawCount = 0
    private(set) var containerTextKit1DrawCount = 0
    private(set) var liveCaptionRowCount = 0
    private(set) var captionNativeDrawCount = 0
    private(set) var liveOffWindowRowCount = 0
    /// One owner's live rows in one per-owner proof (`codeRows`,
    /// `containerRows`, `captionRows`).
    private struct OwnerRowProof {
        /// Live rows drawing this owner's text: one, or two for a moment
        /// while a row is replaced (and across documents that share ids).
        var rows = 0
        /// Native draw passes those rows dispatched since the first of
        /// them came alive.
        var nativeDraws = 0
    }

    /// The per-owner proofs, by owner id: live rows of kind `.code`
    /// (`codeRows`); live rows in a container's context whose kind is not
    /// `.code` (`containerRows`); live rows in a caption's context
    /// (`captionRows`). An owner is in one exactly while such a row carries
    /// its id (joined and left where the matching live count moves, or
    /// where such a row's id changes), so none holds more owners than its
    /// live count.
    private var codeRows: [String: OwnerRowProof] = [:]
    private var containerRows: [String: OwnerRowProof] = [:]
    private var captionRows: [String: OwnerRowProof] = [:]
    /// The rebuild control's leaves (`View.adfRebuildControl`).
    private(set) var rebuildControlLiveRows = 0
    private(set) var rebuildControlAppearances = 0

    var snapshot: ADFTextKit2Stats {
        ADFTextKit2Stats(
            liveRowCount: liveRowCount, layoutCount: layoutCount,
            drawCount: drawCount, nativeDrawCount: nativeDrawCount,
            textKit1BackedRowCount: textKit1BackedRowCount, textKit1BackedDrawCount: textKit1BackedDrawCount,
            liveListRowCount: liveListRowCount, conversionCount: conversionCount,
            liveCodeRowCount: liveCodeRowCount, codeNativeDrawCount: codeNativeDrawCount,
            liveContainerRowCount: liveContainerRowCount, containerNativeDrawCount: containerNativeDrawCount,
            containerTextKit1DrawCount: containerTextKit1DrawCount,
            liveCaptionRowCount: liveCaptionRowCount, captionNativeDrawCount: captionNativeDrawCount,
            liveOffWindowRowCount: liveOffWindowRowCount
        )
    }

    /// Native draw passes of the live code rows, by owner id (`codeRows`).
    var codeRowDraws: [String: Int] {
        codeRows.mapValues(\.nativeDraws)
    }

    /// Native draw passes of the live container rows that are not code, by
    /// owner id (`containerRows`).
    var containerRowDraws: [String: Int] {
        containerRows.mapValues(\.nativeDraws)
    }

    /// Native draw passes of the live caption rows, by owner id
    /// (`captionRows`).
    var captionRowDraws: [String: Int] {
        captionRows.mapValues(\.nativeDraws)
    }

    func rowCreated() {
        liveRowCount += 1
    }

    /// `ownerID`: the row's owner, which a code, container or caption row
    /// leaves its per-owner proof by. `offWindow`: the row was counted as
    /// outside any window (`row(offWindow:)`).
    func rowDestroyed(
        textKit1Backed: Bool = false, ownerKind: TextKit2OwnerKind = .root, context: TextKit2ContainerContext = .none,
        offWindow: Bool = false, ownerID: String? = nil
    ) {
        liveRowCount -= 1
        if textKit1Backed { textKit1BackedRowCount -= 1 }
        if offWindow { liveOffWindowRowCount -= 1 }
        count(ownerKind, context, by: -1, ownerID: ownerID)
    }

    /// A live row started (`true`) or stopped being laid out and drawn by
    /// its TextKit 1 stack.
    func row(textKit1Backed: Bool) {
        textKit1BackedRowCount += textKit1Backed ? 1 : -1
    }

    /// A live row left every window (`true`: a new row, or one the lazy
    /// stack keeps off screen) or entered one (`false`).
    func row(offWindow: Bool) {
        liveOffWindowRowCount += offWindow ? 1 : -1
    }

    /// A live row's owner kind changed (`TextKit2OwnerKind`), its context
    /// staying `context`: it leaves the old kind's live counts and joins
    /// the new one's. A new row is `.root` in no container, which has no
    /// count of its own. `ownerID`: the row's owner at that moment (`nil`
    /// until it is first given one).
    func row(ownerKind new: TextKit2OwnerKind, was old: TextKit2OwnerKind, context: TextKit2ContainerContext = .none, ownerID: String? = nil) {
        count(old, context, by: -1, ownerID: ownerID)
        count(new, context, by: 1, ownerID: ownerID)
    }

    /// A live row's context changed (`TextKit2ContainerContext`), its kind
    /// staying `ownerKind`: it leaves the old context's live counts and
    /// joins the new one's.
    func row(context new: TextKit2ContainerContext, was old: TextKit2ContainerContext, ownerKind: TextKit2OwnerKind, ownerID: String? = nil) {
        count(ownerKind, old, by: -1, ownerID: ownerID)
        count(ownerKind, new, by: 1, ownerID: ownerID)
    }

    /// A live row's owner id changed, its kind and context staying: a row
    /// in a per-owner proof (code, container or caption) moves there (its
    /// draws so far stay with the old id, and go with it). Other rows keep
    /// no per-owner record.
    func row(ownerID new: String?, was old: String?, ownerKind: TextKit2OwnerKind, context: TextKit2ContainerContext = .none) {
        guard let proof = Self.proof(ownerKind, context) else { return }
        ownerRow(proof, old, by: -1)
        ownerRow(proof, new, by: 1)
    }

    /// A per-owner proof (`codeRows`, `containerRows`, `captionRows`).
    private enum Proof {
        case code, container, caption
    }

    /// The per-owner proof a row of `kind` in `context` belongs to, if
    /// any: code by its kind wherever it sits; container text that is not
    /// code (the container proof never counts a code row); captions.
    private static func proof(_ kind: TextKit2OwnerKind, _ context: TextKit2ContainerContext) -> Proof? {
        switch (kind, context) {
        case (.code, _): return .code
        case (.root, .none), (.list, .none): return nil
        case (.root, .container), (.list, .container): return .container
        case (.root, .caption), (.list, .caption): return .caption
        }
    }

    /// Exhaustive, so a new owner kind or context must decide its own live
    /// counts.
    private func count(_ kind: TextKit2OwnerKind, _ context: TextKit2ContainerContext, by delta: Int, ownerID: String?) {
        switch kind {
        case .root: break
        case .list: liveListRowCount += delta
        case .code: liveCodeRowCount += delta
        }
        guard let proof = Self.proof(kind, context) else { return }
        switch proof {
        case .code: break
        case .container: liveContainerRowCount += delta
        case .caption: liveCaptionRowCount += delta
        }
        ownerRow(proof, ownerID, by: delta)
    }

    /// A row joined (`1`) or left (`-1`) `ownerID`'s entry of a per-owner
    /// proof; the entry goes with its last row. A row without an owner id
    /// has no entry.
    private func ownerRow(_ proof: Proof, _ ownerID: String?, by delta: Int) {
        guard let ownerID else { return }
        func update(_ rows: inout [String: OwnerRowProof]) {
            var entry = rows[ownerID] ?? OwnerRowProof()
            entry.rows += delta
            rows[ownerID] = entry.rows > 0 ? entry : nil
        }
        switch proof {
        case .code: update(&codeRows)
        case .container: update(&containerRows)
        case .caption: update(&captionRows)
        }
    }

    /// A row converted its prepared text into the string it lays out.
    func didConvert() {
        conversionCount += 1
    }

    func didLayout() {
        layoutCount += 1
    }

    /// A draw pass; `native`: TextKit 2 drew at least one layout fragment;
    /// `textKit1`: the row's TextKit 1 stack drew it; `code`: the row
    /// draws a code block's code (`TextKit2OwnerKind.code`), so a native
    /// pass is also a code-native one, counted for the row's `ownerID` too
    /// (the per-owner proof, `codeRows`); `context`: where the row's text
    /// sits, so a pass of a container row that is not code also counts as
    /// a container one (native, or TextKit 1-backed), and a pass of a
    /// caption row as a caption one, each for the row's `ownerID` in its
    /// own proof when native.
    func didDraw(
        native: Bool, textKit1: Bool = false, code: Bool = false, context: TextKit2ContainerContext = .none,
        ownerID: String? = nil
    ) {
        drawCount += 1
        if native { nativeDrawCount += 1 }
        if textKit1 { textKit1BackedDrawCount += 1 }
        if native, code {
            codeNativeDrawCount += 1
            if let ownerID { codeRows[ownerID]?.nativeDraws += 1 }
        }
        switch context {
        case .none:
            break
        case .container:
            guard !code else { break }
            if textKit1 { containerTextKit1DrawCount += 1 }
            if native {
                containerNativeDrawCount += 1
                if let ownerID { containerRows[ownerID]?.nativeDraws += 1 }
            }
        case .caption:
            if native {
                captionNativeDrawCount += 1
                if let ownerID { captionRows[ownerID]?.nativeDraws += 1 }
            }
        }
    }

    /// A rebuild-control leaf appeared (`true`) or disappeared.
    func rebuildControlRow(appeared: Bool) {
        rebuildControlLiveRows += appeared ? 1 : -1
        if appeared { rebuildControlAppearances += 1 }
    }
}

#if canImport(UIKit)
/// One TextKit 2 row in a window at one moment
/// (`ADFTextRenderer.textKit2RowFrames(in:)`).
@_spi(ADFDiagnostics)
public struct ADFTextKit2RowFrame: Sendable, Hashable {
    /// What the row draws (`TextKit2OwnerKind`).
    public enum Kind: String, Sendable, Hashable {
        case root, list, code
    }

    /// The block the row draws (`RenderBlock.id`).
    public var ownerID: String
    public var kind: Kind
    /// Where the row can draw (its bounds and its canvas, which covers the
    /// ink overhang), in the window's coordinates, points.
    public var frame: CGRect
    /// `frame` clipped by every clipping ancestor (the document's scroll
    /// view, a code block's horizontal scroll view, a layer mask) and by
    /// the window; nil when nothing of it is shown (clipped away, or the
    /// row or an ancestor hidden or transparent).
    public var visible: CGRect?

    public init(ownerID: String, kind: Kind, frame: CGRect, visible: CGRect?) {
        self.ownerID = ownerID
        self.kind = kind
        self.frame = frame
        self.visible = visible
    }
}

extension ADFTextKit2RowFrame.Kind {
    /// Exhaustive, so a new owner kind must pick its name.
    init(_ kind: TextKit2OwnerKind) {
        switch kind {
        case .root: self = .root
        case .list: self = .list
        case .code: self = .code
        }
    }
}

extension ADFTextRenderer {
    /// A one-shot walk of `window`'s view hierarchy: every TextKit 2 row in
    /// it that has an owner id, with its frame and visible part, in
    /// hierarchy order. It reads geometry only (frames, bounds, conversions,
    /// clipping, hidden and alpha). It lays nothing out, keeps nothing and
    /// observes nothing, so it adds no state to any row and no work to any
    /// frame (ADR §8, §16, §20). Diagnostics only: the library never calls
    /// it; the demo's capture-geometry hook does, once per request. A row
    /// outside the window (a cached, never-shown row) is not listed.
    @_spi(ADFDiagnostics)
    @MainActor
    public static func textKit2RowFrames(in window: UIWindow) -> [ADFTextKit2RowFrame] {
        var rows: [ADFTextKit2RowFrame] = []
        func walk(_ view: UIView, clip: CGRect, shown: Bool) {
            let shown = shown && !view.isHidden && view.alpha > 0.01
            var clip = clip
            if view.clipsToBounds {
                clip = clip.intersection(view.convert(view.bounds, to: window))
            }
            if let mask = view.layer.mask {
                clip = clip.intersection(view.convert(mask.frame, to: window))
            }
            if let row = view as? TextKit2RowView, let owner = row.ownerID {
                let frame = row.convert(row.bounds.union(row.canvasFrame), to: window)
                let visible = frame.intersection(clip)
                rows.append(ADFTextKit2RowFrame(
                    ownerID: owner, kind: ADFTextKit2RowFrame.Kind(row.ownerKind), frame: frame,
                    visible: shown && !visible.isNull && !visible.isEmpty ? visible : nil
                ))
            }
            for subview in view.subviews {
                walk(subview, clip: clip, shown: shown)
            }
        }
        walk(window, clip: window.bounds, shown: true)
        return rows
    }
}
#endif
