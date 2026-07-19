#if os(iOS)
import Foundation
import UIKit
import Testing
import ADFPreparation
@testable import ADFRendering

/// Task 25 — iOS-lane coverage for `TextKit2RowUIView`'s minimal
/// accessibility exposure: proves the getter overrides read LIVE content
/// (never a cached/stale snapshot from a previous `apply()`), and that
/// `RowAccessibilityLabel`'s pure logic (covered directly, macOS-side, by
/// `RowAccessibilityLabelTests`) is wired up correctly end-to-end through
/// `Inputs.Content.segments` → `TextRowContent.segmentStrings`.
///
/// This suite only compiles/runs on iOS (the type it targets is
/// `#if os(iOS)`-gated) — reachable via `xcodebuild test -scheme
/// ADFRenderingTests -destination 'platform=iOS Simulator,...'`, not plain
/// `swift test` on macOS.
@Suite("TextKit2RowUIView accessibility") @MainActor
struct TextKit2RowAccessibilityTests {
    private let large = UIContentSizeCategory.large.rawValue

    private func textSegment(_ s: String, style: FontSpec.Style = .body) -> InlineSegment {
        var t = AttributedString(s)
        t[FontSpecAttribute.self] = FontSpec(style: style)
        return .text(t)
    }

    private func apply(_ view: TextKit2RowUIView, segments: [InlineSegment]) {
        view.apply(TextKit2RowUIView.Inputs(
            content: TextKit2RowUIView.Inputs.Content(
                segments: segments,
                categoryRawValue: large,
                alignment: .natural,
                rightToLeft: false,
                displayScale: 3),
            paint: TextKit2RowUIView.Inputs.Paint(
                spans: [], currentSpans: [], dimCurrent: false,
                subtleColor: .yellow, currentColor: .orange, currentForeground: nil)))
    }

    @Test func isAccessibilityElementIsTrueEvenBeforeAnyApply() {
        let view = TextKit2RowUIView()
        #expect(view.isAccessibilityElement)
        // No content applied yet — the label getter must not crash, and
        // reports nil rather than a garbage/empty string.
        #expect(view.accessibilityLabel == nil)
    }

    @Test func accessibilityLabelReflectsAppliedTextContent() {
        let view = TextKit2RowUIView()
        apply(view, segments: [textSegment("hello world")])
        #expect(view.accessibilityLabel == "hello world")
    }

    @Test func accessibilityLabelUpdatesLiveAcrossReapply() {
        let view = TextKit2RowUIView()
        apply(view, segments: [textSegment("first")])
        #expect(view.accessibilityLabel == "first")
        apply(view, segments: [textSegment("second, different text")])
        // Proves the getter reads CURRENT content — not a value cached at
        // the first `apply()` (the zero-precompute constraint: nothing
        // stores a label on the content-change path in `apply(_:)` itself).
        #expect(view.accessibilityLabel == "second, different text")
    }

    @Test func accessibilityLabelIncludesAtomFallbackTextInPlace() {
        let view = TextKit2RowUIView()
        apply(view, segments: [
            textSegment("Hi "),
            .atom(.mention(text: "@Bharath"), id: "a1"),
            textSegment(" done"),
        ])
        #expect(view.accessibilityLabel == "Hi @Bharath done")
    }

    @Test func accessibilityTraitsIncludesHeaderForHeadingStyle() {
        let view = TextKit2RowUIView()
        apply(view, segments: [textSegment("Section Title", style: .title2)])
        #expect(view.accessibilityTraits.contains(.header))
    }

    @Test func accessibilityTraitsExcludesHeaderForBodyText() {
        let view = TextKit2RowUIView()
        apply(view, segments: [textSegment("just a paragraph", style: .body)])
        #expect(!view.accessibilityTraits.contains(.header))
        #expect(view.accessibilityTraits.contains(.staticText))
    }
}
#endif
