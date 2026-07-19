import Foundation
import ADFPreparation

/// Builds the single flat accessibility label a TK2 row exposes for VoiceOver
/// (Task 25 — the "minimal exposure" pass over gap #8, `TextKit2RowUIView`'s
/// `accessibilityLabel` override).
///
/// TK2 rows draw glyphs directly onto an `NSTextLayoutManager`; unlike the
/// SwiftUI arm's `Text`, they carry no per-run accessibility elements of
/// their own — measured to be a total absence, not a "merged into one
/// opaque `AXTextArea`" collapse (see the assessment's Task 25 section). A
/// per-run element model is production work (the scope note); this pass's
/// bar is ONE label per row, reconstructed from the row's own already-
/// converted `TextRowContent.segmentStrings` (each `.text` segment's plain
/// string; atoms contribute `""` there — a pill has no searchable run) with
/// each `.atom` segment's `InlineAtom.fallbackText` substituted in its
/// place, concatenated in document order with no separator. This is the
/// exact shape `SearchIndexer.appendUnit`/`ADFDocumentModel.plainTitle`
/// already use to build the search corpus / TOC titles from the identical
/// `[InlineSegment]` input, so a VoiceOver announcement, a search hit, and a
/// TOC entry all describe a row with the same words (e.g. a date pill reads
/// "Jul 9, 2024", a mention reads "@Bharath" — never a bare placeholder).
enum RowAccessibilityLabel {
    /// `segments` and `segmentStrings` come from `TextKit2RowUIView`'s own
    /// `Inputs.Content.segments` / `TextRowContent.segmentStrings` — always
    /// built together, in lockstep, by `TextRowContent.make`, so they are
    /// the same length. Pure function, no UIKit, no live layout: safe to
    /// call from an accessibility-getter override with no caching — this
    /// only ever runs when VoiceOver/an inspector actually queries the
    /// label (Task 25's zero-idle-cost constraint), never on the
    /// `apply`/draw/scroll path.
    static func build(segments: [InlineSegment], segmentStrings: [String]) -> String {
        guard segments.count == segmentStrings.count else {
            // Defensive only — the two arrays are structurally guaranteed to
            // match by `TextRowContent.make`; an accessibility getter must
            // never trap on a caller mismatch, so fall back to whatever text
            // IS available rather than crash.
            return segmentStrings.joined()
        }
        var result = ""
        for (index, segment) in segments.enumerated() {
            switch segment {
            case .text:
                result += segmentStrings[index]
            case .atom(let atom, _):
                result += atom.fallbackText
            }
        }
        return result
    }

    /// Approximate heading detector ("approximate is acceptable, document" —
    /// Task 25's brief): true iff the row's FIRST `.text` segment's FIRST
    /// run carries a level-1–4 heading `FontSpec.style` (`.title`/`.title2`/
    /// `.title3`/`.headline` — see `ADFTheme.headingSpec`, which bakes
    /// exactly these four styles, bold, for `headingLevel` 1–4). Mirrors
    /// `TextKit2RowView.firstBaseline`'s own "first text run of `segments`"
    /// read, so this stays consistent with the row's other first-run-only
    /// approximations rather than inventing a second convention.
    ///
    /// Deliberately does NOT attempt levels 5–6: `ADFTheme.headingSpec`
    /// bakes those as `.subheadline`/`.footnote`, bold — but
    /// `InlineComposer.convert` ALSO uses those same two `FontSpec.style`
    /// values, unbolded, for the small-text and superscript/subscript marks.
    /// A bold run inside small/sup text (e.g. **~small~** or a bold
    /// footnote-style citation mark) would false-positive as a level-5/6
    /// heading under a bold-flag check, so this stays a level-1–4-only
    /// approximation — recorded as a known gap in the production scope note
    /// rather than guessing wrong on levels 5/6.
    static func isHeading(_ segments: [InlineSegment]) -> Bool {
        for segment in segments {
            guard case .text(let text) = segment else { continue }
            switch text.runs.first?[FontSpecAttribute.self]?.style {
            case .title, .title2, .title3, .headline: return true
            default: return false
            }
        }
        return false
    }
}
