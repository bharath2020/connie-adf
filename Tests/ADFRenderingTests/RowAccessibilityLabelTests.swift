import Foundation
import Testing
import ADFPreparation
@testable import ADFRendering

/// Task 25 — pure, macOS-testable coverage for the minimal accessibility
/// exposure prototype's label/heading logic (`TextKit2RowUIView` itself is
/// `#if os(iOS)`-gated and covered by the iOS lane instead).
@Suite("RowAccessibilityLabel")
struct RowAccessibilityLabelTests {
    private func textSegment(_ s: String, style: FontSpec.Style = .body) -> InlineSegment {
        var t = AttributedString(s)
        t[FontSpecAttribute.self] = FontSpec(style: style)
        return .text(t)
    }

    // MARK: build

    @Test func plainTextRowJoinsSegmentStringsVerbatim() {
        let segments = [textSegment("hello world")]
        let label = RowAccessibilityLabel.build(segments: segments, segmentStrings: ["hello world"])
        #expect(label == "hello world")
    }

    @Test func atomInTheMiddleSubstitutesFallbackTextInPlace() {
        let segments: [InlineSegment] = [
            textSegment("Hi "),
            .atom(.mention(text: "@Bharath"), id: "a1"),
            textSegment(" done"),
        ]
        // `TextRowContent.make` stores "" for the atom segment's own string.
        let label = RowAccessibilityLabel.build(segments: segments, segmentStrings: ["Hi ", "", " done"])
        #expect(label == "Hi @Bharath done")
    }

    @Test func mentionFallbackTextAddsAtPrefixWhenMissing() {
        let segments: [InlineSegment] = [.atom(.mention(text: "Bharath"), id: "a1")]
        let label = RowAccessibilityLabel.build(segments: segments, segmentStrings: [""])
        #expect(label == "@Bharath")
    }

    @Test func pureAtomRowUsesFallbackTextAlone() {
        let segments: [InlineSegment] = [.atom(.emoji(shortName: "smile"), id: "a1")]
        let label = RowAccessibilityLabel.build(segments: segments, segmentStrings: [""])
        #expect(label == ":smile:")
    }

    @Test func multipleAtomsEachContributeTheirOwnFallbackText() {
        let segments: [InlineSegment] = [
            .atom(.status(text: "Done", color: .green), id: "a1"),
            textSegment(" — "),
            .atom(.date(timestampMS: 1_720_000_000_000), id: "a2"),
        ]
        let label = RowAccessibilityLabel.build(segments: segments, segmentStrings: ["", " — ", ""])
        #expect(label.hasPrefix("Done — "))
        #expect(!label.hasSuffix("— ")) // the date fallback appended something after the dash
    }

    @Test func mismatchedArrayLengthsFallBackToSegmentStringsAlone() {
        // Defensive path only — real callers always pass arrays built
        // together by `TextRowContent.make`, but the getter must never trap.
        let segments = [textSegment("a"), textSegment("b")]
        let label = RowAccessibilityLabel.build(segments: segments, segmentStrings: ["x"])
        #expect(label == "x")
    }

    // MARK: isHeading

    @Test func titleStyleIsDetectedAsHeading() {
        #expect(RowAccessibilityLabel.isHeading([textSegment("Big Heading", style: .title)]))
    }

    @Test func title2Title3AndHeadlineAreAllDetected() {
        #expect(RowAccessibilityLabel.isHeading([textSegment("H2", style: .title2)]))
        #expect(RowAccessibilityLabel.isHeading([textSegment("H3", style: .title3)]))
        #expect(RowAccessibilityLabel.isHeading([textSegment("H4", style: .headline)]))
    }

    @Test func bodyTextIsNotAHeading() {
        #expect(!RowAccessibilityLabel.isHeading([textSegment("just a paragraph", style: .body)]))
    }

    @Test func level5And6StylesAreNotDetected() {
        // Documented gap: subheadline/footnote are ALSO used (unbolded) for
        // small-text/superscript marks, so this pass doesn't attempt 5/6.
        #expect(!RowAccessibilityLabel.isHeading([textSegment("h5", style: .subheadline)]))
        #expect(!RowAccessibilityLabel.isHeading([textSegment("h6", style: .footnote)]))
    }

    @Test func pureAtomRowIsNeverAHeading() {
        #expect(!RowAccessibilityLabel.isHeading([.atom(.emoji(shortName: "tada"), id: "a1")]))
    }

    @Test func leadingAtomBeforeAHeadingTextRunStillDetectsTheHeading() {
        let segments: [InlineSegment] = [
            .atom(.emoji(shortName: "star"), id: "a1"),
            textSegment("Starred heading", style: .headline),
        ]
        #expect(RowAccessibilityLabel.isHeading(segments))
    }
}
