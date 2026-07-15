import SwiftUI
import Testing
@testable import ADFRendering

@Suite("Scroll target placement")
struct ScrollTargetPlacementTests {
    @Test(".top is the plain top anchor")
    func topAnchor() {
        #expect(ADFScrollTargetPlacement.top.anchor(viewportHeight: 800) == .top)
    }

    @Test("nearTop insets the anchor by margin/height from the top")
    func nearTopAnchor() {
        let anchor = ADFScrollTargetPlacement.nearTop(margin: 40).anchor(viewportHeight: 800)
        #expect(abs(anchor.y - 0.05) < 0.0001)
    }

    @Test("nearBottom insets the anchor by margin/height from the bottom")
    func nearBottomAnchor() {
        let anchor = ADFScrollTargetPlacement.nearBottom(margin: 40).anchor(viewportHeight: 800)
        #expect(abs(anchor.y - 0.95) < 0.0001)
    }

    @Test("margins clamp to at most 40% of the viewport, and never negative")
    func marginClamps() {
        #expect(ADFScrollTargetPlacement.nearTop(margin: 900).anchor(viewportHeight: 800).y == 0.4)
        #expect(ADFScrollTargetPlacement.nearTop(margin: -10).anchor(viewportHeight: 800).y == 0)
        #expect(ADFScrollTargetPlacement.nearBottom(margin: 900).anchor(viewportHeight: 800).y == 0.6)
    }

    @Test("a zero-height viewport degrades to the plain edge")
    func zeroHeight() {
        #expect(ADFScrollTargetPlacement.nearTop(margin: 40).anchor(viewportHeight: 0).y == 0)
        #expect(ADFScrollTargetPlacement.nearBottom(margin: 40).anchor(viewportHeight: 0).y == 1)
    }
}
