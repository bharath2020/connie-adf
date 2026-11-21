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
}
