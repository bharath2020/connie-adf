import Foundation
import SwiftUI
import ADFPreparation

/// A read-only snapshot of the TextKit 2 renderer's counters — the proof of
/// which text engine actually drew, independent of the host's switch state.
///
/// Every counter is about TextKit 2 rows only: text that falls back renders
/// through SwiftUI's `Text` and is not counted here (see
/// `ADFTextKit2Coverage` for which text falls back). A row whose text has
/// a link is laid out and drawn by its own TextKit 1 stack, as `Text` lays
/// out linked text: such rows and their draws are counted apart
/// (`textKit1Backed…`) and never as native TextKit 2 draws. `liveRowCount`,
/// `liveListRowCount`, `liveCodeRowCount` and `textKit1BackedRowCount`
/// count row views currently alive (back to zero once a switch to
/// `.swiftUI` has released them); the others are cumulative since launch.
/// Always zero on platforms without UIKit.
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

    public init(
        liveRowCount: Int, layoutCount: Int, drawCount: Int, nativeDrawCount: Int = 0,
        textKit1BackedRowCount: Int = 0, textKit1BackedDrawCount: Int = 0,
        liveListRowCount: Int = 0, conversionCount: Int = 0,
        liveCodeRowCount: Int = 0, codeNativeDrawCount: Int = 0
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

    public init(
        eligibleRoots: Int, fallbackRoots: Int, textFallbackRoots: Int = 0, linkRoots: Int = 0,
        eligibleTextLeaves: Int = 0, linkedTextLeaves: Int = 0, fallbackTextLeaves: Int = 0,
        listLeaderLeaves: Int = 0, listTrailingLeaves: Int = 0,
        eligibleCodeRoots: Int = 0, fallbackCodeRoots: Int = 0
    ) {
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
    /// scope, its top-level blocks and its top-level code blocks (see
    /// `ADFTextKit2Coverage`).
    public static func textKit2Coverage(of blocks: [RenderBlock]) -> ADFTextKit2Coverage {
        var coverage = ADFTextKit2Coverage(eligibleRoots: 0, fallbackRoots: 0)
        TextKit2Scope.forEachLeaf(in: blocks) { leaf in
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
    /// ADFTextKit2Coverage.eligibleCodeRoots`.
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
    ) -> (admittedCodeRoots: Int, gatedCodeRoots: Int) {
        var admitted = 0
        var gated = 0
        TextKit2Scope.forEachLeaf(in: blocks) { leaf in
            guard leaf.position == .codeRoot, case .eligible(let text) = leaf.verdict else { return }
            #if canImport(UIKit)
            let gate = TextKit2Scope.codeGate(
                text, sizeCategory: dynamicTypeSize.uiContentSizeCategory, legibilityWeight: legibilityWeight,
                displayScale: displayScale, layoutDirection: layoutDirection
            )
            if gate == nil { admitted += 1 } else { gated += 1 }
            #else
            _ = text
            gated += 1
            #endif
        }
        return (admitted, gated)
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
    /// for `owner`, or `nil` when it falls back (`verdict`). The preparer
    /// emits one merged run per gap, so the common case returns the stored
    /// value without building a new string.
    static func describableText(_ segments: [InlineSegment], owner: TextKit2OwnerKind = .root) -> AttributedString? {
        if case .eligible(let text) = verdict(segments, owner: owner) { return text }
        return nil
    }

    /// The prepared attributed text TextKit 2 draws for `owner`, or `nil`
    /// when it falls back (`verdict(_:owner:)` for attributed text): what
    /// `TextEngineLeaf` asks for text it is handed as one string (a code
    /// block's code), without building a segment array.
    static func describableText(_ text: AttributedString, owner: TextKit2OwnerKind) -> AttributedString? {
        if case .eligible(let text) = verdict(text, owner: owner) { return text }
        return nil
    }

    /// The engine verdict for prepared attributed text drawn for `owner`.
    /// Code (`.code`) is judged by the code rules (`codeVerdict`), never by
    /// a list rule or the list OS gate; any other owner's text is judged as
    /// the same text in one segment would be.
    static func verdict(_ text: AttributedString, owner: TextKit2OwnerKind) -> Verdict {
        switch owner {
        case .code: return codeVerdict(text)
        case .root, .list: return verdict([.text(text)], owner: owner)
        }
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
    /// text). The views (`TextEngineLeaf`) and the coverage walk
    /// (`TextKit2Scope.Leaf.verdict`) both decide through it.
    static func verdict(_ segments: [InlineSegment], owner: TextKit2OwnerKind = .root) -> Verdict {
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
    /// One owner's live code rows (`codeRows`).
    private struct CodeRowProof {
        /// Live rows drawing this owner's code: one, or two for a moment
        /// while a row is replaced (and across documents that share ids).
        var rows = 0
        /// Native draw passes those rows dispatched since the first of
        /// them came alive.
        var nativeDraws = 0
    }

    /// The per-owner code proof: live rows of kind `.code` by owner id.
    /// An owner is here exactly while such a row carries its id (joined
    /// and left where `liveCodeRowCount` moves, or where a code row's id
    /// changes), so it never holds more owners than `liveCodeRowCount`.
    private var codeRows: [String: CodeRowProof] = [:]
    /// The rebuild control's leaves (`View.adfRebuildControl`).
    private(set) var rebuildControlLiveRows = 0
    private(set) var rebuildControlAppearances = 0

    var snapshot: ADFTextKit2Stats {
        ADFTextKit2Stats(
            liveRowCount: liveRowCount, layoutCount: layoutCount,
            drawCount: drawCount, nativeDrawCount: nativeDrawCount,
            textKit1BackedRowCount: textKit1BackedRowCount, textKit1BackedDrawCount: textKit1BackedDrawCount,
            liveListRowCount: liveListRowCount, conversionCount: conversionCount,
            liveCodeRowCount: liveCodeRowCount, codeNativeDrawCount: codeNativeDrawCount
        )
    }

    /// Native draw passes of the live code rows, by owner id (`codeRows`).
    var codeRowDraws: [String: Int] {
        codeRows.mapValues(\.nativeDraws)
    }

    func rowCreated() {
        liveRowCount += 1
    }

    /// `ownerID`: the row's owner, which a code row leaves the per-owner
    /// proof by.
    func rowDestroyed(textKit1Backed: Bool = false, ownerKind: TextKit2OwnerKind = .root, ownerID: String? = nil) {
        liveRowCount -= 1
        if textKit1Backed { textKit1BackedRowCount -= 1 }
        count(ownerKind, by: -1, ownerID: ownerID)
    }

    /// A live row started (`true`) or stopped being laid out and drawn by
    /// its TextKit 1 stack.
    func row(textKit1Backed: Bool) {
        textKit1BackedRowCount += textKit1Backed ? 1 : -1
    }

    /// A live row's owner kind changed (`TextKit2OwnerKind`): it leaves
    /// the old kind's live count and joins the new one's. A new row is
    /// `.root`, which has no count of its own. `ownerID`: the row's owner
    /// at that moment (`nil` until it is first given one).
    func row(ownerKind new: TextKit2OwnerKind, was old: TextKit2OwnerKind, ownerID: String? = nil) {
        count(old, by: -1, ownerID: ownerID)
        count(new, by: 1, ownerID: ownerID)
    }

    /// A live row's owner id changed, its kind staying `ownerKind`: a code
    /// row moves in the per-owner proof (its draws so far stay with the old
    /// id, and go with it). Other kinds keep no per-owner record.
    func row(ownerID new: String?, was old: String?, ownerKind: TextKit2OwnerKind) {
        switch ownerKind {
        case .root, .list: break
        case .code:
            codeRow(old, by: -1)
            codeRow(new, by: 1)
        }
    }

    /// Exhaustive, so a new owner kind must decide its own live count.
    private func count(_ kind: TextKit2OwnerKind, by delta: Int, ownerID: String?) {
        switch kind {
        case .root: break
        case .list: liveListRowCount += delta
        case .code:
            liveCodeRowCount += delta
            codeRow(ownerID, by: delta)
        }
    }

    /// A code row joined (`1`) or left (`-1`) `ownerID`'s entry of the
    /// per-owner proof; the entry goes with its last row. A row without an
    /// owner id has no entry.
    private func codeRow(_ ownerID: String?, by delta: Int) {
        guard let ownerID else { return }
        var proof = codeRows[ownerID] ?? CodeRowProof()
        proof.rows += delta
        codeRows[ownerID] = proof.rows > 0 ? proof : nil
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
    /// (the per-owner proof, `codeRows`).
    func didDraw(native: Bool, textKit1: Bool = false, code: Bool = false, ownerID: String? = nil) {
        drawCount += 1
        if native { nativeDrawCount += 1 }
        if textKit1 { textKit1BackedDrawCount += 1 }
        if native, code {
            codeNativeDrawCount += 1
            if let ownerID { codeRows[ownerID]?.nativeDraws += 1 }
        }
    }

    /// A rebuild-control leaf appeared (`true`) or disappeared.
    func rebuildControlRow(appeared: Bool) {
        rebuildControlLiveRows += appeared ? 1 : -1
        if appeared { rebuildControlAppearances += 1 }
    }
}
