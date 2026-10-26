import Foundation
import ADFPreparation

/// A read-only snapshot of the TextKit 2 renderer's counters — the proof of
/// which text engine actually drew, independent of the host's switch state.
///
/// Every counter is about TextKit 2 rows only: text that falls back renders
/// through SwiftUI's `Text` and is not counted here (see
/// `ADFTextKit2Coverage` for which roots fall back). A row whose text has
/// a link is laid out and drawn by its own TextKit 1 stack, as `Text` lays
/// out linked text: such rows and their draws are counted apart
/// (`textKit1Backed…`) and never as native TextKit 2 draws. `liveRowCount`
/// and `textKit1BackedRowCount` count row views currently alive (back to
/// zero once a switch to `.swiftUI` has released them); the others are
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

    public init(
        liveRowCount: Int, layoutCount: Int, drawCount: Int, nativeDrawCount: Int = 0,
        textKit1BackedRowCount: Int = 0, textKit1BackedDrawCount: Int = 0
    ) {
        self.liveRowCount = liveRowCount
        self.layoutCount = layoutCount
        self.drawCount = drawCount
        self.nativeDrawCount = nativeDrawCount
        self.textKit1BackedRowCount = textKit1BackedRowCount
        self.textKit1BackedDrawCount = textKit1BackedDrawCount
    }
}

/// How many top-level blocks of a document the TextKit 2 renderer draws
/// (`eligibleRoots`: see `TextKit2Eligibility`) versus how many stay on
/// SwiftUI (`fallbackRoots`: everything else — containers, lists, code,
/// tables, media, and the paragraphs and headings counted in
/// `textFallbackRoots`). Content-based, plus one OS rule (two or more
/// trailing hard breaks fall back before iOS 26), so the counts can differ
/// between iOS 18 and iOS 26 for the same document.
public struct ADFTextKit2Coverage: Sendable, Hashable {
    public var eligibleRoots: Int
    public var fallbackRoots: Int
    /// Of `fallbackRoots`: top-level paragraphs and headings that stay on
    /// SwiftUI (inline atoms, undescribable theme fonts, empty text,
    /// trailing hard breaks before iOS 26).
    public var textFallbackRoots: Int
    /// Of `eligibleRoots`: those containing a link, which the row lays out
    /// and draws with TextKit 1 (`ADFTextKit2Stats.textKit1BackedRowCount`).
    public var linkRoots: Int

    public init(eligibleRoots: Int, fallbackRoots: Int, textFallbackRoots: Int = 0, linkRoots: Int = 0) {
        self.eligibleRoots = eligibleRoots
        self.fallbackRoots = fallbackRoots
        self.textFallbackRoots = textFallbackRoots
        self.linkRoots = linkRoots
    }
}

extension ADFTextRenderer {
    /// The current TextKit 2 counters (see `ADFTextKit2Stats`).
    @MainActor
    public static var textKit2Stats: ADFTextKit2Stats {
        TextKit2Diagnostics.shared.snapshot
    }

    /// Classifies a document's top-level blocks (`ADFDocumentModel.blocks`)
    /// by whether the TextKit 2 renderer draws them.
    public static func textKit2Coverage(of blocks: [RenderBlock]) -> ADFTextKit2Coverage {
        var eligible = 0
        var textFallback = 0
        var linked = 0
        for block in blocks {
            guard case .richText(let segments, _) = block.kind else { continue }
            switch TextKit2Eligibility.verdict(segments) {
            case .eligible(let text):
                eligible += 1
                if text.runs.contains(where: { $0.link != nil }) { linked += 1 }
            case .fallback:
                textFallback += 1
            }
        }
        return ADFTextKit2Coverage(
            eligibleRoots: eligible, fallbackRoots: blocks.count - eligible,
            textFallbackRoots: textFallback, linkRoots: linked
        )
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
        /// placeholder with nothing to draw.
        case empty
        /// A run without a font spec (a theme font supplied as a raw
        /// SwiftUI `Font`): TextKit cannot resolve the font `Text` would.
        case undescribable
        /// Two or more trailing hard breaks before iOS 26, where `Text`
        /// also drops the middle empty line's negative leading at AX3+
        /// (0.333–1.333 pt shorter, no exact rule found).
        case trailingBreaks
    }

    enum Verdict: Sendable {
        case eligible(AttributedString)
        case fallback(Fallback)
    }

    /// The merged text of an all-text segment list that TextKit 2 draws,
    /// or `nil` when it falls back (`verdict`). The preparer emits one
    /// merged run per gap, so the common case returns the stored value
    /// without building a new string.
    static func describableText(_ segments: [InlineSegment]) -> AttributedString? {
        if case .eligible(let text) = verdict(segments) { return text }
        return nil
    }

    static func verdict(_ segments: [InlineSegment]) -> Verdict {
        // Atoms first, so an atom paragraph (word-chunked, many segments)
        // builds no throwaway merged string.
        for segment in segments {
            guard case .text = segment else { return .fallback(.atom) }
        }
        guard let text = SegmentedTextView.mergedText(segments) else { return .fallback(.atom) }
        guard !text.characters.isEmpty else { return .fallback(.empty) }
        for run in text.runs where run.adfFontSpec == nil {
            return .fallback(.undescribable)
        }
        if !trailingBreaksMatchText, text.characters.reversed().prefix(while: \.isNewline).count >= 2 {
            return .fallback(.trailingBreaks)
        }
        return .eligible(text)
    }

    /// Whether the row's trailing-break rule reproduces `Text` for two or
    /// more trailing breaks (measured exact on iOS 26.3; not on iOS 18.5).
    static var trailingBreaksMatchText: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }
}

/// The TextKit 2 rows' counters (§2.6 of the stack plan). Rows report
/// creation, destruction, owner changes, layouts and draws; tests and the
/// public snapshot read them. Plain integers: cheap enough to stay on in
/// Release, where the demo's renderer proof needs them.
@MainActor
final class TextKit2Diagnostics {
    static let shared = TextKit2Diagnostics()

    private(set) var liveRowCount = 0
    private(set) var layoutCount = 0
    private(set) var drawCount = 0
    private(set) var nativeDrawCount = 0
    private(set) var textKit1BackedRowCount = 0
    private(set) var textKit1BackedDrawCount = 0
    /// Live rows per owner (block) id.
    private var owners: [String: Int] = [:]

    var snapshot: ADFTextKit2Stats {
        ADFTextKit2Stats(
            liveRowCount: liveRowCount, layoutCount: layoutCount,
            drawCount: drawCount, nativeDrawCount: nativeDrawCount,
            textKit1BackedRowCount: textKit1BackedRowCount, textKit1BackedDrawCount: textKit1BackedDrawCount
        )
    }

    /// Live rows drawing the block `ownerID`.
    func liveRows(ownerID: String) -> Int {
        owners[ownerID] ?? 0
    }

    func rowCreated() {
        liveRowCount += 1
    }

    func rowDestroyed(ownerID: String?, textKit1Backed: Bool = false) {
        liveRowCount -= 1
        if textKit1Backed { textKit1BackedRowCount -= 1 }
        release(ownerID)
    }

    /// A live row started (`true`) or stopped being laid out and drawn by
    /// its TextKit 1 stack.
    func row(textKit1Backed: Bool) {
        textKit1BackedRowCount += textKit1Backed ? 1 : -1
    }

    func row(changedOwnerFrom old: String?, to new: String?) {
        guard old != new else { return }
        release(old)
        if let new { owners[new, default: 0] += 1 }
    }

    func didLayout() {
        layoutCount += 1
    }

    /// A draw pass; `native`: TextKit 2 drew at least one layout fragment;
    /// `textKit1`: the row's TextKit 1 stack drew it.
    func didDraw(native: Bool, textKit1: Bool = false) {
        drawCount += 1
        if native { nativeDrawCount += 1 }
        if textKit1 { textKit1BackedDrawCount += 1 }
    }

    private func release(_ ownerID: String?) {
        guard let ownerID, let count = owners[ownerID] else { return }
        owners[ownerID] = count > 1 ? count - 1 : nil
    }
}
