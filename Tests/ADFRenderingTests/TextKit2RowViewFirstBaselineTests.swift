#if os(iOS)
import Foundation
import UIKit
import Testing
import ADFPreparation
@testable import ADFRendering

/// Task 23 — pure-atom-row `firstBaseline` fix: a row with NO `.text` run at
/// all (e.g. a paragraph made of atoms with no separating text) must recover
/// a non-zero baseline from its leading atom's own pill geometry
/// (`AtomAttachment.pillAscent`), not the stale `0` fallback — a `0` here
/// would misalign any enclosing `.firstTextBaseline` stack (list markers,
/// panel icons) against an atom-only row.
@Suite("TextKit2RowView.firstBaseline — pure-atom row") @MainActor
struct TextKit2RowViewFirstBaselineTests {
    private let large = UIContentSizeCategory.large.rawValue

    @Test func pureAtomRowReturnsNonZeroPillAscent() {
        let segments: [InlineSegment] = [.atom(.status(text: "done", color: .green), id: "atom-1")]
        let baseline = TextKit2RowView.firstBaseline(of: segments, categoryRawValue: large)
        #expect(baseline > 0)

        // Exactly `AtomAttachment.pillAscent` for the SAME atom+category —
        // the fallback's whole point is to derive from that pure function.
        let att = AtomAttachment(atom: .status(text: "done", color: .green), categoryRawValue: large)
        #expect(abs(baseline - att.pillAscent) <= 0.01)
    }

    @Test func multiAtomRowWithNoTextUsesLeadingAtom() {
        // Two atoms glued directly with no separating text segment at all —
        // the leading atom (mention, `calloutMedium`), not the second
        // (emoji, `body` — a genuinely different font/ascender), drives the
        // fallback.
        let segments: [InlineSegment] = [
            .atom(.mention(text: "@Bharath"), id: "atom-1"),
            .atom(.emoji(shortName: "smile"), id: "atom-2"),
        ]
        let baseline = TextKit2RowView.firstBaseline(of: segments, categoryRawValue: large)
        let leadingAscent = AtomAttachment(atom: .mention(text: "@Bharath"), categoryRawValue: large).pillAscent
        let trailingAscent = AtomAttachment(atom: .emoji(shortName: "smile"), categoryRawValue: large).pillAscent
        #expect(baseline == leadingAscent)
        #expect(leadingAscent != trailingAscent)  // sanity: the two really differ
    }

    /// Regression guard: an atom-LEADING row that DOES have a following text
    /// run must still use the text run's ascender — the pre-existing,
    /// correct behavior this task does NOT change (only the zero-text case
    /// changes).
    @Test func atomLeadingRowWithFollowingTextStillUsesTextAscender() {
        var text = AttributedString("trailing prose")
        text[FontSpecAttribute.self] = .body
        let segments: [InlineSegment] = [
            .atom(.mention(text: "@Bharath"), id: "atom-1"),
            .text(text),
        ]
        let baseline = TextKit2RowView.firstBaseline(of: segments, categoryRawValue: large)
        let bodyAscender = FontSpecResolver.shared.font(for: .body, categoryRawValue: large).ascender
        #expect(baseline == bodyAscender)
    }

    /// `pillAscent`'s own bar (brief): within 1pt of the pill's text-font
    /// ascent for a representative capsule atom.
    @Test func pureAtomRowBaselineWithin1ptOfPillTextAscent() {
        let segments: [InlineSegment] = [.atom(.mention(text: "@Bharath"), id: "atom-1")]
        let baseline = TextKit2RowView.firstBaseline(of: segments, categoryRawValue: large)
        let callout = FontSpecResolver.shared.font(for: FontSpec(style: .callout), categoryRawValue: large)
        let calloutMedium = UIFont.systemFont(ofSize: callout.pointSize, weight: .medium)
        #expect(abs(baseline - calloutMedium.ascender) <= 1.0)
    }
}
#endif
