import CoreGraphics
import Testing
import ADFPreparation
@testable import ADFRendering

/// A task checkbox's tap band grows toward Apple's 44 × 44 pt minimum
/// without overlapping a neighbouring row's band or reaching the text.
@Suite("Task checkbox tap band")
struct TaskHitAreaTests {
    private let theme = ADFTheme()
    /// `ListRowView.markerWidth` at the default text size.
    private let markerWidth: CGFloat = 28

    @Test("At the default size the band is 44 pt wide: column, gap and leading outset")
    func defaultWidthIsMinimum() {
        let outset = TaskHitArea.leadingOutset(markerWidth: markerWidth, spacing: theme.spacing)
        #expect(outset > 0)
        #expect(outset <= theme.spacing)
        #expect(markerWidth + theme.spacing + outset == TaskHitArea.minimumSide)
    }

    @Test("A wide marker column (large text) needs no leading outset")
    func wideColumnNeedsNoOutset() {
        #expect(TaskHitArea.leadingOutset(markerWidth: 44, spacing: theme.spacing) == 0)
        #expect(TaskHitArea.leadingOutset(markerWidth: 60, spacing: theme.spacing) == 0)
    }

    @Test("The leading outset never exceeds one spacing unit")
    func outsetIsBoundedBySpacing() {
        #expect(TaskHitArea.leadingOutset(markerWidth: 10, spacing: theme.spacing) == theme.spacing)
    }

    @Test("Neighbouring rows' bands meet in the middle of the row gap")
    func bandsDoNotOverlap() {
        let gap = ListBlockView.rowSpacing(theme: theme)
        let outset = TaskHitArea.verticalOutset(rowSpacing: gap)
        // Two single-line rows one gap apart: the upper band's bottom edge
        // is the lower band's top edge.
        let lineHeight: CGFloat = 22
        let upperBottom = lineHeight + outset
        let lowerTop = lineHeight + gap - outset
        #expect(upperBottom == lowerTop)
        #expect(TaskHitArea.height(rowHeight: lineHeight, verticalOutset: outset) == lineHeight + gap)
    }

    @Test("A wrapped task's band is capped at 44 pt tall")
    func tallRowCapsAtMinimumSide() {
        let outset = TaskHitArea.verticalOutset(rowSpacing: ListBlockView.rowSpacing(theme: theme))
        #expect(TaskHitArea.height(rowHeight: 120, verticalOutset: outset) == TaskHitArea.minimumSide)
    }
}
