#if os(iOS)
import Foundation
import UIKit
import Testing
import ADFPreparation
@testable import ADFRendering

/// Proves the arrival-flash invariant (Task 9): a paint-only `apply` —
/// spans/currentSpans/dimCurrent/colors changing while `segments` and the
/// other content inputs stay the same — must NEVER rebuild `TextRowContent`
/// or re-set `TextRowLayout`'s attributed string. `conversionCount` is
/// incremented ONLY inside the `contentChanged` branch of `apply(_:)`, so it
/// staying flat across a paint-only `apply` is direct proof the content path
/// was skipped — not just an inference from `FontSpecResolver`'s own
/// memoization, which would stay flat either way once fonts are cached.
///
/// This suite only compiles/runs on iOS (the file it targets is
/// `#if os(iOS)`-gated) — reachable via
/// `xcodebuild test -scheme ADFRenderingTests -destination 'platform=iOS
/// Simulator,...'`, not plain `swift test` on macOS.
@Suite("TextKit2RowUIView paint/content split") @MainActor
struct TextKit2RowUIViewTests {
    private func segment(_ s: String) -> InlineSegment {
        var t = AttributedString(s)
        t[FontSpecAttribute.self] = .body
        return .text(t)
    }

    private func content(_ segments: [InlineSegment]) -> TextKit2RowUIView.Inputs.Content {
        .init(
            segments: segments,
            categoryRawValue: "UICTContentSizeCategoryL",
            alignment: .natural,
            rightToLeft: false,
            displayScale: 3
        )
    }

    private func paint(
        spans: [SearchHighlightSpan] = [],
        currentSpans: [SearchHighlightSpan] = [],
        dimCurrent: Bool = false
    ) -> TextKit2RowUIView.Inputs.Paint {
        .init(
            spans: spans,
            currentSpans: currentSpans,
            dimCurrent: dimCurrent,
            subtleColor: .yellow,
            currentColor: .orange,
            currentForeground: .black
        )
    }

    @Test func firstApplyConvertsContent() {
        let view = TextKit2RowUIView()
        view.apply(.init(content: content([segment("hello")]), paint: paint()))
        #expect(view.conversionCount == 1)
    }

    @Test func identicalInputsAreANoOp() {
        let view = TextKit2RowUIView()
        let c = content([segment("hello")])
        let p = paint()
        view.apply(.init(content: c, paint: p))
        #expect(view.conversionCount == 1)
        view.apply(.init(content: c, paint: p))
        #expect(view.conversionCount == 1)
    }

    @Test("a paint-only apply (arrival flash / navigation) never reconverts content")
    func paintOnlyChangeSkipsConversion() {
        let view = TextKit2RowUIView()
        let c = content([segment("hello world")])
        view.apply(.init(content: c, paint: paint()))
        #expect(view.conversionCount == 1)

        // Navigation: spans/currentSpans populate, same content.
        view.apply(.init(content: c, paint: paint(
            spans: [SearchHighlightSpan(segmentIndex: 0, range: 0..<5)],
            currentSpans: [SearchHighlightSpan(segmentIndex: 0, range: 6..<11)]
        )))
        #expect(view.conversionCount == 1)

        // Arrival-flash dim step: only `dimCurrent` flips.
        view.apply(.init(content: c, paint: paint(
            spans: [SearchHighlightSpan(segmentIndex: 0, range: 0..<5)],
            currentSpans: [SearchHighlightSpan(segmentIndex: 0, range: 6..<11)],
            dimCurrent: true
        )))
        #expect(view.conversionCount == 1)

        // Flash back on.
        view.apply(.init(content: c, paint: paint(
            spans: [SearchHighlightSpan(segmentIndex: 0, range: 0..<5)],
            currentSpans: [SearchHighlightSpan(segmentIndex: 0, range: 6..<11)],
            dimCurrent: false
        )))
        #expect(view.conversionCount == 1)
    }

    @Test func contentChangeReconverts() {
        let view = TextKit2RowUIView()
        view.apply(.init(content: content([segment("hello")]), paint: paint()))
        #expect(view.conversionCount == 1)
        view.apply(.init(content: content([segment("goodbye")]), paint: paint()))
        #expect(view.conversionCount == 2)
    }
}
#endif
