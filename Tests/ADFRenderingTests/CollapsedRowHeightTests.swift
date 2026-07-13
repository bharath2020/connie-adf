import Foundation
import Testing
import ADFModel
import ADFPreparation
@testable import ADFRendering

/// A collapsed row states a height without laying its block out. Getting that
/// height wrong resizes the scroll view's content on every rotation, which is
/// what threw the reader's place in the document.
@Suite("Collapsed row height")
struct CollapsedRowHeightTests {
    @Test("A row that has never been measured has no height to report")
    func unmeasuredReportsNothing() {
        let heights = CollapsedRowHeight()
        #expect(heights.isEmpty)
        #expect(heights.height(at: 400, scaling: .reflowing) == nil)
    }

    @Test("A width the row was measured at replays that exact height")
    func exactWidthReplaysMeasuredHeight() {
        var heights = CollapsedRowHeight()
        heights.record(height: 120, at: 400)
        #expect(heights.height(at: 400, scaling: .reflowing) == 120)
    }

    /// The rotation round trip: portrait, then landscape, then back. The
    /// portrait height must come back exactly, not as an estimate derived from
    /// the landscape measurement — otherwise every off-screen row above the
    /// reader changes size and the scroll offset lands on different content.
    @Test("Rotating away and back restores the original height exactly")
    func rotationRoundTripIsLossless() {
        var heights = CollapsedRowHeight()
        heights.record(height: 120, at: 398)
        heights.record(height: 64, at: 609)
        #expect(heights.height(at: 398, scaling: .reflowing) == 120)
        #expect(heights.height(at: 609, scaling: .reflowing) == 64)
    }

    @Test("Sub-point layout jitter still counts as the same width")
    func widthKeyToleratesJitter() {
        var heights = CollapsedRowHeight()
        heights.record(height: 120, at: 398)
        #expect(heights.height(at: 398.2, scaling: .reflowing) == 120)
    }

    @Test("Reflowing text trades width for height at an unseen width")
    func reflowingTextShrinksAsItWidens() {
        var heights = CollapsedRowHeight()
        heights.record(height: 100, at: 400)
        #expect(heights.height(at: 800, scaling: .reflowing) == 50)
    }

    /// The sign error that made rotation worst for image-heavy documents: an
    /// aspect-ratio-bound image grows *taller* as its column widens, and the
    /// old universal inverse rule shrank it instead.
    @Test("Media grows taller as the column widens")
    func mediaScalesWithWidth() {
        var heights = CollapsedRowHeight()
        heights.record(height: 100, at: 400)
        #expect(heights.height(at: 800, scaling: .proportional) == 200)
    }

    /// Code blocks and table slices scroll horizontally rather than wrap, so a
    /// wider column leaves their height alone.
    @Test("Horizontally scrolling blocks keep their height at any width")
    func invariantBlocksKeepHeight() {
        var heights = CollapsedRowHeight()
        heights.record(height: 100, at: 400)
        #expect(heights.height(at: 800, scaling: .invariant) == 100)
        #expect(heights.height(at: 200, scaling: .invariant) == 100)
    }

    /// Dragging an iPad Split View divider lays the document out at a
    /// continuum of widths; a row must not accumulate one sample per frame.
    @Test("The memo stays bounded across many widths")
    func memoIsBounded() {
        var heights = CollapsedRowHeight()
        for width in stride(from: CGFloat(300), through: 900, by: 5) {
            heights.record(height: width / 4, at: width)
        }
        // The newest width is still exact; a width evicted long ago is not.
        #expect(heights.height(at: 900, scaling: .invariant) == 225)
        #expect(heights.height(at: 300, scaling: .invariant) != 75)
    }

    @Test("Every block kind declares how its height answers a width change")
    func kindsMapToScaling() {
        #expect(RenderBlock.Kind.media(.stub).heightScaling == .proportional)
        #expect(RenderBlock.Kind.divider.heightScaling == .invariant)
        #expect(RenderBlock.Kind.codeBlock(language: nil, code: "").heightScaling == .invariant)
        #expect(RenderBlock.Kind.listRows([]).heightScaling == .reflowing)
    }
}

private extension PreparedMedia {
    static let stub = PreparedMedia(
        id: "m",
        attrs: MediaAttrs(
            source: .external(url: "https://example.com/a.png"),
            width: 100,
            height: 50,
            alt: nil,
            mediaType: nil
        ),
        layout: .center,
        widthFraction: nil,
        pixelWidth: nil,
        caption: nil,
        borderHex: nil,
        linkHref: nil
    )
}
