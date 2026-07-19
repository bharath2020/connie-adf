#if os(iOS)
import Foundation
import UIKit
import Testing
import ADFPreparation
@testable import ADFRendering

/// Proves `TextKit2RowUIView`'s geometry-query surface (Task 17) answers
/// character-level rect/caret/hit-test queries from the row's OWN real TK2
/// layout — never a shadow layout (the prototype's #1 drift class this
/// registry design replaces).
///
/// This suite only compiles/runs on iOS (the type it targets is
/// `#if os(iOS)`-gated) — reachable via `xcodebuild test -scheme
/// ADFRenderingTests -destination 'platform=iOS Simulator,...'`, not plain
/// `swift test` on macOS.
@Suite("TextKit2RowUIView row geometry") @MainActor
struct TextKit2RowGeometryTests {
    /// A two-line paragraph via an explicit newline, so the row wraps to
    /// exactly two lines at ANY measured width — deterministic regardless of
    /// which width the test measures at.
    private let paragraph = "First line text\nSecond line text"

    private func segment(_ s: String) -> InlineSegment {
        var t = AttributedString(s)
        t[FontSpecAttribute.self] = .body
        return .text(t)
    }

    /// Builds a row containing `paragraph` and runs it through real TK2
    /// layout at `width` (`measuredSize` → `TextRowLayout.measure` →
    /// `NSTextLayoutManager.ensureLayout`), so the geometry queries below
    /// read committed layout, not an unlaid-out content storage.
    private func makeRow(width: CGFloat = 300) -> TextKit2RowUIView {
        let view = TextKit2RowUIView()
        view.apply(TextKit2RowUIView.Inputs(
            content: TextKit2RowUIView.Inputs.Content(
                segments: [segment(paragraph)],
                categoryRawValue: "UICTContentSizeCategoryL",
                alignment: .natural,
                rightToLeft: false,
                displayScale: 3),
            paint: TextKit2RowUIView.Inputs.Paint(
                spans: [],
                currentSpans: [],
                dimCurrent: false,
                subtleColor: .yellow,
                currentColor: .orange,
                currentForeground: nil)))
        _ = view.measuredSize(forWidth: width)
        return view
    }

    @Test func selectionRectsForAMidLineRangeAreNonEmptyAndIndented() {
        let view = makeRow()
        // "First line text"[6..<10] == "line" — starts 6 UTF-16 units into
        // the first line, so the rect must be indented off the left edge.
        let midLineRange = NSRange(location: 6, length: 4)
        #expect(String(paragraph.prefix(10)).hasSuffix("line"))
        let rects = view.selectionRects(forUTF16: midLineRange)
        #expect(!rects.isEmpty)
        for rect in rects {
            #expect(rect.width > 0)
            #expect(rect.height > 0)
            #expect(rect.minX > 0)
        }
    }

    @Test func closestOffsetAtTopLeftIsZero() {
        let view = makeRow()
        let offset = view.closestUTF16Offset(to: CGPoint(x: 0, y: 0))
        #expect(offset == 0)
    }

    @Test func caretRectAtDocumentEndIsNeverNull() {
        let view = makeRow()
        let length = (paragraph as NSString).length
        let caret = view.caretRect(atUTF16: length)
        #expect(caret != nil)
        #expect(caret.map { !$0.isNull } ?? false)
    }

    // MARK: Task 21 — atom/link hit-testing + whole-pill geometry

    /// "tap here and [pill] end" on one line — five segments: plain text,
    /// LINKED text, plain text, one mention atom, plain text. Segment
    /// indices 0...4 line up 1:1 with this array, which the tests below key
    /// off directly (`content.segmentUTF16Starts[N]`).
    private func makeMixedRow(url: URL, width: CGFloat = 300) -> TextKit2RowUIView {
        var linked = AttributedString("here")
        linked[FontSpecAttribute.self] = .body
        linked[AttributeScopes.FoundationAttributes.LinkAttribute.self] = url

        let view = TextKit2RowUIView()
        view.apply(TextKit2RowUIView.Inputs(
            content: TextKit2RowUIView.Inputs.Content(
                segments: [
                    segment("tap "),
                    .text(linked),
                    segment(" and "),
                    .atom(.mention(text: "bharath"), id: "m1"),
                    segment(" end")
                ],
                categoryRawValue: "UICTContentSizeCategoryL",
                alignment: .natural,
                rightToLeft: false,
                displayScale: 3),
            paint: TextKit2RowUIView.Inputs.Paint(
                spans: [],
                currentSpans: [],
                dimCurrent: false,
                subtleColor: .yellow,
                currentColor: .orange,
                currentForeground: nil)))
        _ = view.measuredSize(forWidth: width)
        return view
    }

    /// The pill's ONE U+FFFC attachment char (Task 10) resolves to exactly
    /// one non-empty selection rect — the geometry `drawAtomPillHighlights`
    /// (whole-pill search tint, gap #3) and `RowGeometrySource.rects`'
    /// `.atom` case both key off.
    @Test func atomAttachmentCharProducesOnePillRect() {
        let view = makeMixedRow(url: URL(string: "https://example.com")!)
        guard let content = view.content else { Issue.record("row produced no content"); return }
        let atomStart = content.segmentUTF16Starts[3]
        let rects = view.selectionRects(forUTF16: NSRange(location: atomStart, length: 1))
        #expect(rects.count == 1)
        #expect(rects[0].width > 0)
        #expect(rects[0].height > 0)
    }

    @Test func segmentIndexForAtomIDMatches() {
        let view = makeMixedRow(url: URL(string: "https://example.com")!)
        #expect(view.segmentIndex(forAtomID: "m1") == 3)
        #expect(view.segmentIndex(forAtomID: "no-such-id") == nil)
    }

    /// `hitTest(atomOrLinkAt:)` at the LINK glyph's own rect resolves to the
    /// baked `.link` URL (`TextRowContent.convert` bakes `.link` from the
    /// `AttributeScopes.FoundationAttributes.LinkAttribute` run attribute).
    @Test func hitTestFindsLinkAtItsGlyphRect() {
        let url = URL(string: "https://example.com")!
        let view = makeMixedRow(url: url)
        guard let content = view.content else { Issue.record("row produced no content"); return }
        let linkStart = content.segmentUTF16Starts[1]
        guard let rect = view.selectionRects(forUTF16: NSRange(location: linkStart, length: 1)).first else {
            Issue.record("link glyph produced no rect"); return
        }
        let hit = view.hitTest(atomOrLinkAt: CGPoint(x: rect.midX, y: rect.midY))
        #expect(hit == .link(url))
    }

    /// `hitTest(atomOrLinkAt:)` at the PILL's own rect resolves to the
    /// atom's structural node ID, independent of the link case above.
    @Test func hitTestFindsAtomAtItsPillRect() {
        let view = makeMixedRow(url: URL(string: "https://example.com")!)
        guard let content = view.content else { Issue.record("row produced no content"); return }
        let atomStart = content.segmentUTF16Starts[3]
        guard let rect = view.selectionRects(forUTF16: NSRange(location: atomStart, length: 1)).first else {
            Issue.record("atom glyph produced no rect"); return
        }
        let hit = view.hitTest(atomOrLinkAt: CGPoint(x: rect.midX, y: rect.midY))
        #expect(hit == .atom(id: "m1"))
    }

    /// A point past the end of a short line resolves to a NEAREST character
    /// via `closestUTF16Offset` (used for text-selection seeding), but
    /// `hitTest(atomOrLinkAt:)` must reject it — unlike a selection seed, a
    /// tap in blank trailing space must never be misread as hitting that
    /// line's last glyph.
    @Test func hitTestMissesPastLineEnd() {
        let view = makeRow()
        let miss = view.hitTest(atomOrLinkAt: CGPoint(x: 290, y: 5))
        #expect(miss == nil)
    }
}
#endif
