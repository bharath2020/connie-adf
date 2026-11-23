import CoreGraphics
import Testing
@testable import ADFRendering

/// The render-time math behind the table's pinned header column, its
/// shadow and the trailing overflow fade (`visualEffect` closures).
struct TableScrollGeometryTests {
    @Test("a pinned part shifts by the scroll offset and never left of its resting place")
    func stickyShift() {
        // Resting x 44 (after a number gutter), not scrolled.
        #expect(TableScrollGeometry.stickyShift(restingX: 44, minXInScrollView: 44) == 0)
        // Scrolled 30 pt: the part would sit at 14, so it shifts back by 30.
        #expect(TableScrollGeometry.stickyShift(restingX: 44, minXInScrollView: 14) == 30)
        // Leading bounce (negative offset): moves with the content.
        #expect(TableScrollGeometry.stickyShift(restingX: 0, minXInScrollView: 12) == 0)
    }

    @Test("the pinned column's shadow appears only once the table is scrolled")
    func shadowOpacity() {
        #expect(TableScrollGeometry.shadowOpacity(shift: 0) == 0)
        #expect(TableScrollGeometry.shadowOpacity(shift: 4) == 0.5)
        #expect(TableScrollGeometry.shadowOpacity(shift: 40) == 1)
    }

    @Test("the trailing fade shows while columns remain to the right and hides at the end")
    func overflowFade() {
        // 100 pt of content beyond the visible edge (strip-local maxX = 28 − 100).
        let remaining = TableScrollGeometry.trailingOverflow(visibleMaxX: -72, width: 28)
        #expect(remaining == 100)
        #expect(TableScrollGeometry.fadeOpacity(remaining: remaining, fadeWidth: 28) == 1)
        // Half the fade width left: half opacity.
        #expect(TableScrollGeometry.fadeOpacity(remaining: 14, fadeWidth: 28) == 0.5)
        // Scrolled to the end, or a table that fits: hidden.
        #expect(TableScrollGeometry.trailingOverflow(visibleMaxX: 28, width: 28) == 0)
        #expect(TableScrollGeometry.fadeOpacity(remaining: 0, fadeWidth: 28) == 0)
        #expect(TableScrollGeometry.fadeOpacity(remaining: -40, fadeWidth: 28) == 0)
        // Outside a scroll view: nothing to fade.
        #expect(TableScrollGeometry.trailingOverflow(visibleMaxX: nil, width: 28) == 0)
    }

    // A follower slice is positioned programmatically, and a programmatic
    // scroll position cannot leave the content bounds. So a follower scrolls
    // as far as it can and draws the rest of the shared offset as a content
    // shift; otherwise only the dragged slice rubber-bands at a table edge.

    @Test("a follower inside the scroll range scrolls to the shared offset with no shift")
    func followerPlacementInRange() {
        for shared: CGFloat in [0, 120.5, 291] {
            let placement = TableScrollGeometry.followerPlacement(sharedOffset: shared, maxOffset: 291)
            #expect(placement == TableFollowerPlacement(scrollX: shared, contentShift: 0))
        }
    }

    @Test("a follower draws a leading overscroll as a content shift, not as a scroll offset")
    func followerPlacementLeadingOverscroll() {
        let placement = TableScrollGeometry.followerPlacement(sharedOffset: -44, maxOffset: 291)
        #expect(placement.scrollX == 0)
        #expect(placement.contentShift == -44)
        #expect(placement.scrollX + placement.contentShift == -44)
    }

    @Test("a follower draws a trailing overscroll as a content shift past its last offset")
    func followerPlacementTrailingOverscroll() {
        let placement = TableScrollGeometry.followerPlacement(sharedOffset: 291 + 18, maxOffset: 291)
        #expect(placement.scrollX == 291)
        #expect(placement.contentShift == 18)
        #expect(placement.scrollX + placement.contentShift == 309)
    }

    @Test("a follower's scroll offset stays in range and the shift carries the remainder", arguments: [
        (-44.0, 291.0), (-0.25, 291.0), (0.0, 291.0), (145.5, 291.0), (291.0, 291.0), (291.25, 291.0), (309.0, 291.0),
        (-44.0, 0.0), (0.0, 0.0), (18.0, 0.0), (-44.0, -30.0), (18.0, -30.0),
    ])
    func followerPlacementInvariant(shared: Double, maxOffset: Double) {
        let placement = TableScrollGeometry.followerPlacement(sharedOffset: CGFloat(shared), maxOffset: CGFloat(maxOffset))
        // A table narrower than its viewport has no scroll range at all.
        let range: ClosedRange<CGFloat> = 0...CGFloat(max(maxOffset, 0))
        #expect(range.contains(placement.scrollX))
        #expect(abs(placement.scrollX + placement.contentShift - CGFloat(shared)) < 0.0001)
    }

    @Test("a table that fits its viewport never scrolls a follower")
    func followerPlacementWithoutRange() {
        #expect(TableScrollGeometry.followerPlacement(sharedOffset: 18, maxOffset: 0)
            == TableFollowerPlacement(scrollX: 0, contentShift: 18))
        // Content narrower than the viewport reports a negative range.
        #expect(TableScrollGeometry.followerPlacement(sharedOffset: -44, maxOffset: -30)
            == TableFollowerPlacement(scrollX: 0, contentShift: -44))
    }
}
