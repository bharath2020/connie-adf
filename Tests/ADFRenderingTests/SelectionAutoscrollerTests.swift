import CoreGraphics
import Testing
@testable import ADFRendering

/// MacOS-runnable core of the Task 20 drag-past-edge autoscroller: the pure
/// edge-distance → velocity ramp and the clamped content-offset advance
/// (`SelectionAutoscrollMath`). The `CADisplayLink` driver and the
/// `topRowProvider`/`onScrollStep` wiring that writes `model.anchors.topRow`
/// are iOS-only and exercised in the on-sim §8b acid test (and the T26 gate).
struct SelectionAutoscrollerTests {
    private let band = SelectionAutoscrollMath.defaultBand
    private let maxV = SelectionAutoscrollMath.defaultMaxVelocity
    private let h: CGFloat = 800

    // MARK: velocity ramp

    @Test func interiorTouchHasZeroVelocity() {
        #expect(SelectionAutoscrollMath.velocity(touchY: h / 2, viewportHeight: h) == 0)
        // Just inside each band boundary is still interior (== boundary is zero).
        #expect(SelectionAutoscrollMath.velocity(touchY: band, viewportHeight: h) == 0)
        #expect(SelectionAutoscrollMath.velocity(touchY: h - band, viewportHeight: h) == 0)
        #expect(SelectionAutoscrollMath.velocity(touchY: band + 1, viewportHeight: h) == 0)
        #expect(SelectionAutoscrollMath.velocity(touchY: h - band - 1, viewportHeight: h) == 0)
    }

    @Test func topBandRampsNegativeProportionalToPenetration() {
        // 20pt into the band from the top → -maxV * 20/band.
        let v = SelectionAutoscrollMath.velocity(touchY: band - 20, viewportHeight: h)
        #expect(v == -maxV * 20 / band)
        #expect(v < 0)
        // Deeper penetration ⇒ stronger (more negative) velocity.
        let deeper = SelectionAutoscrollMath.velocity(touchY: band - 60, viewportHeight: h)
        #expect(deeper < v)
    }

    @Test func bottomBandRampsPositiveProportionalToPenetration() {
        let v = SelectionAutoscrollMath.velocity(touchY: h - band + 20, viewportHeight: h)
        #expect(v == maxV * 20 / band)
        #expect(v > 0)
        let deeper = SelectionAutoscrollMath.velocity(touchY: h - band + 60, viewportHeight: h)
        #expect(deeper > v)
    }

    @Test func velocitySaturatesAtMaxPastThePhysicalEdge() {
        // At the exact edge → full velocity; past it → clamped, not overshot.
        #expect(SelectionAutoscrollMath.velocity(touchY: 0, viewportHeight: h) == -maxV)
        #expect(SelectionAutoscrollMath.velocity(touchY: -200, viewportHeight: h) == -maxV)
        #expect(SelectionAutoscrollMath.velocity(touchY: h, viewportHeight: h) == maxV)
        #expect(SelectionAutoscrollMath.velocity(touchY: h + 200, viewportHeight: h) == maxV)
    }

    @Test func degenerateViewportOrBandYieldsZero() {
        #expect(SelectionAutoscrollMath.velocity(touchY: 10, viewportHeight: 0) == 0)
        #expect(SelectionAutoscrollMath.velocity(touchY: 10, viewportHeight: h, band: 0) == 0)
    }

    // MARK: clamped offset advance

    @Test func offsetAdvancesInTheInteriorRange() {
        let y = SelectionAutoscrollMath.advancedOffsetY(
            current: 500, dy: 30, contentHeight: 10_000, viewportHeight: h)
        #expect(y == 530)
    }

    @Test func offsetClampsAtZeroScrollingUp() {
        let y = SelectionAutoscrollMath.advancedOffsetY(
            current: 20, dy: -200, contentHeight: 10_000, viewportHeight: h)
        #expect(y == 0)
    }

    @Test func offsetClampsAtMaxScrollingDown() {
        let contentHeight: CGFloat = 10_000
        let maxY = contentHeight - h
        let y = SelectionAutoscrollMath.advancedOffsetY(
            current: maxY - 10, dy: 100, contentHeight: contentHeight, viewportHeight: h)
        #expect(y == maxY)
    }

    @Test func contentShorterThanViewportPinsAtZero() {
        let y = SelectionAutoscrollMath.advancedOffsetY(
            current: 0, dy: 50, contentHeight: 200, viewportHeight: h)
        #expect(y == 0)
    }
}
