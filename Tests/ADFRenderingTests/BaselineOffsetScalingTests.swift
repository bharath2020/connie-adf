import Foundation
import SwiftUI
import Testing
@testable import ADFRendering

/// `SegmentedTextView.scalingBaselineOffsets` scales baked sub/superscript
/// baseline offsets by the live Dynamic Type factor, so a superscript's raise
/// tracks the growing font instead of staying a fixed point value.
@Suite("Baseline offset Dynamic Type scaling")
@MainActor
struct BaselineOffsetScalingTests {
    private func run(offset: CGFloat) -> AttributedString {
        var text = AttributedString("x")
        text[AttributeScopes.SwiftUIAttributes.BaselineOffsetAttribute.self] = offset
        return text
    }

    @Test("the default size (factor 1) returns the input untouched")
    func identityAtDefaultSize() {
        let input = run(offset: 5.1)
        let output = SegmentedTextView.scalingBaselineOffsets(in: input, by: 1)
        #expect(output == input)
    }

    @Test("a larger factor scales the baked offset proportionally")
    func scalesUp() {
        let output = SegmentedTextView.scalingBaselineOffsets(in: run(offset: 5.1), by: 1.6)
        let scaled = output.runs.first?.baselineOffset
        #expect(scaled != nil)
        #expect(abs((scaled ?? 0) - 5.1 * 1.6) < 0.0001)
    }

    @Test("a negative (subscript) offset keeps its sign when scaled")
    func preservesSubscriptSign() {
        let output = SegmentedTextView.scalingBaselineOffsets(in: run(offset: -5.1), by: 2)
        #expect((output.runs.first?.baselineOffset ?? 0) < 0)
        #expect(abs((output.runs.first?.baselineOffset ?? 0) - (-10.2)) < 0.0001)
    }

    @Test("runs without a baseline offset are left alone")
    func leavesPlainRunsUntouched() {
        let plain = AttributedString("plain")
        let output = SegmentedTextView.scalingBaselineOffsets(in: plain, by: 2)
        #expect(output.runs.allSatisfy { $0.baselineOffset == nil })
    }
}
