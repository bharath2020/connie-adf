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
        #expect(heights.height(at: 800, scaling: .proportional(cap: nil)) == 200)
    }

    /// Media never upscales past its explicit or intrinsic pixel width, so
    /// the estimate must stop growing at the cap rather than track the column
    /// forever — otherwise every collapsed image overstates its height as
    /// soon as the column outgrows the image.
    @Test("Media stops growing at its width cap")
    func mediaStopsGrowingAtCap() {
        var heights = CollapsedRowHeight()
        heights.record(height: 100, at: 400)
        // Growth is honoured up to the cap (600), then the height holds.
        #expect(heights.height(at: 800, scaling: .proportional(cap: 600)) == 150)
        #expect(heights.height(at: 1200, scaling: .proportional(cap: 600)) == 150)
        // An image already clamped when measured does not change at all.
        #expect(heights.height(at: 800, scaling: .proportional(cap: 300)) == 100)
    }

    /// Measured on a column wider than the cap, then estimated for a narrower
    /// one: only the width below the cap participates in the ratio.
    @Test("A capped measurement scales down from the cap, not the column")
    func cappedMeasurementScalesFromCap() {
        var heights = CollapsedRowHeight()
        heights.record(height: 90, at: 900)
        #expect(heights.height(at: 300, scaling: .proportional(cap: 600)) == 45)
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
        // Media caps its estimate at the width the box stops growing at:
        // the intrinsic width by default, an explicit pixel width when set,
        // and no cap for fraction-width media (the box tracks the column).
        #expect(RenderBlock.Kind.media(.stub()).heightScaling == .proportional(cap: 100))
        #expect(RenderBlock.Kind.media(.stub(pixelWidth: 340)).heightScaling == .proportional(cap: 340))
        #expect(RenderBlock.Kind.media(.stub(widthFraction: 0.5)).heightScaling == .proportional(cap: nil))
        // A media strip scrolls horizontally at a fixed height, like code.
        #expect(RenderBlock.Kind.mediaStrip([]).heightScaling == .invariant)
        #expect(RenderBlock.Kind.divider.heightScaling == .invariant)
        #expect(RenderBlock.Kind.codeBlock(language: nil, code: "").heightScaling == .invariant)
        #expect(RenderBlock.Kind.listRows([]).heightScaling == .reflowing)
    }

    /// A Dynamic Type change resizes every collapsed row at an unchanged
    /// width. Samples must NOT be dropped — an empty memo re-materializes
    /// the row, and re-materializing thousands at once livelocks layout
    /// (§16). Instead the remembered heights are carried across as scaled
    /// estimates, corrected when the row naturally re-enters.
    @Test("A type-size change rescales remembered heights in place")
    func rescaleScalesEverySample() {
        var heights = CollapsedRowHeight()
        heights.record(height: 100, at: 400)
        heights.record(height: 60, at: 800)
        heights.rescale(by: 28.0 / 17.0)
        #expect(!heights.isEmpty)
        #expect(heights.height(at: 400, scaling: .reflowing) == 100 * (28.0 / 17.0))
        #expect(heights.height(at: 800, scaling: .reflowing) == 60 * (28.0 / 17.0))
    }

    @Test("Rescaling by 1 or on an empty memo is a no-op")
    func rescaleDegenerateCases() {
        var empty = CollapsedRowHeight()
        empty.rescale(by: 2)
        #expect(empty.isEmpty)

        var heights = CollapsedRowHeight()
        heights.record(height: 100, at: 400)
        heights.rescale(by: 1)
        #expect(heights.height(at: 400, scaling: .reflowing) == 100)
    }

    /// Media boxes are sized from pixel attributes or column fractions —
    /// text size does not move them, so their spacers must not rescale.
    @Test("Every block kind declares whether its height tracks the type size")
    func kindsDeclareTypeSizeResponse() {
        #expect(!RenderBlock.Kind.media(.stub()).scalesWithTypeSize)
        #expect(RenderBlock.Kind.codeBlock(language: nil, code: "").scalesWithTypeSize)
        #expect(RenderBlock.Kind.listRows([]).scalesWithTypeSize)
        #expect(RenderBlock.Kind.divider.scalesWithTypeSize)
        #expect(RenderBlock.Kind.mediaStrip([]).scalesWithTypeSize)
    }
}

private extension PreparedMedia {
    static func stub(widthFraction: Double? = nil, pixelWidth: Double? = nil) -> PreparedMedia {
        PreparedMedia(
            id: "m",
            attrs: MediaAttrs(
                source: .external(url: "https://example.com/a.png"),
                width: 100,
                height: 50,
                alt: nil,
                mediaType: nil
            ),
            layout: .center,
            widthFraction: widthFraction,
            pixelWidth: pixelWidth,
            caption: nil,
            borderHex: nil,
            linkHref: nil
        )
    }
}
