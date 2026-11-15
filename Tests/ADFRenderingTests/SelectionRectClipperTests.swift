import CoreGraphics
import Testing
@testable import ADFRendering

@Suite("Selection rectangle clipping")
struct SelectionRectClipperTests {
    @Test func clipsThroughEveryContainerViewport() {
        let glyph = CGRect(x: -20, y: 5, width: 180, height: 24)
        let codeViewport = CGRect(x: 0, y: 0, width: 120, height: 40)
        let panelViewport = CGRect(x: 8, y: 4, width: 96, height: 28)

        #expect(
            SelectionRectClipper.clip(
                [glyph],
                through: [codeViewport, panelViewport]
            ) == [CGRect(x: 8, y: 5, width: 96, height: 24)]
        )
    }

    @Test func dropsFragmentsOutsideAContainer() {
        let glyphs = [
            CGRect(x: 10, y: 10, width: 20, height: 10),
            CGRect(x: 200, y: 10, width: 20, height: 10),
        ]

        #expect(
            SelectionRectClipper.clip(
                glyphs,
                through: [CGRect(x: 0, y: 0, width: 100, height: 100)]
            ) == [glyphs[0]]
        )
    }
}
