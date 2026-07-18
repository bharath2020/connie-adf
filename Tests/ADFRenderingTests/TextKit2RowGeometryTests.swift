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
}
#endif
