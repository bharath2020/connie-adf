import XCTest

/// Offline checks of the lifecycle helpers' predicates (Astra R2): no app
/// launch and no host agent, so they run in the UI-test runner in about a
/// minute. `AnchoredShift` is what C2 and C3 gate their anchored
/// comparisons on.
final class LifecycleSupportTests: XCTestCase {
    private func geometry(_ texts: [String: (top: CGFloat, bottom: CGFloat)],
                          viewportMaxY: CGFloat = 800) -> CodeGeometry
    {
        CodeGeometry(tops: texts.mapValues { $0.top }, bottoms: texts.mapValues { $0.bottom },
                     viewportMaxY: viewportMaxY)
    }

    /// The review's case: a block alone on screen, its top 100 pt and then
    /// 160 pt. The old predicate (`LabelShift` over anchor-relative tops)
    /// passed it with one common label at 0 px; the new one must not.
    func testAnchorOnlySnapshotIsUnproven() {
        let before = geometry(["CD-289": (100, 500)]), after = geometry(["CD-289": (160, 560)])
        let old = LabelShift(from: LabelShift.relative(before.tops, to: "CD-289") ?? [:],
                             to: LabelShift.relative(after.tops, to: "CD-289") ?? [:], scale: 3)
        // What C2 and C3 accepted before the fix.
        XCTAssertEqual(old.common, 1)
        XCTAssertEqual(old.maxPixels, 0)
        let shift = AnchoredShift(from: before, to: after, anchor: "CD-289", scale: 3)
        XCTAssertFalse(shift.proven)
        XCTAssertEqual(shift.otherLabels, 0)
        XCTAssertEqual(shift.landmarks, ["CD-289 bottom"])
        XCTAssertFalse(shift.anchorFillsViewport)
        XCTAssertNotNil(shift.unproven)
    }

    /// An anchor-only snapshot whose anchor fills the viewport in only one
    /// of the two snapshots is still unproven.
    func testAnchorFillingOneSnapshotOnlyIsUnproven() {
        let shift = AnchoredShift(from: geometry(["CD-291": (120, 980)]), to: geometry(["CD-291": (120, 700)]),
                                  anchor: "CD-291", scale: 3)
        XCTAssertFalse(shift.proven)
        XCTAssertFalse(shift.anchorFillsViewport)
    }

    /// A block taller than the rest of the viewport in both snapshots: no
    /// text can follow it on screen, so its height (its bottom relative to
    /// its top) is the measurement.
    func testViewportFillingAnchorIsMeasuredByItsHeight() {
        let before = geometry(["CD-291": (120, 980)])
        let moved = AnchoredShift(from: before, to: geometry(["CD-291": (300, 1160)]), anchor: "CD-291", scale: 3)
        XCTAssertTrue(moved.proven)
        XCTAssertTrue(moved.anchorFillsViewport)
        XCTAssertEqual(moved.maxPixels, 0, accuracy: 0.001)
        let taller = AnchoredShift(from: before, to: geometry(["CD-291": (120, 981)]), anchor: "CD-291", scale: 3)
        XCTAssertTrue(taller.proven)
        XCTAssertEqual(taller.maxPixels, 3, accuracy: 0.001)
        XCTAssertEqual(taller.worst, "CD-291 bottom")
    }

    /// Another common text proves the comparison, and its displacement
    /// relative to the anchor is measured.
    func testAnotherCommonTextProvesAndMeasures() {
        let shift = AnchoredShift(from: geometry(["CD-289": (100, 400), "CD-290": (460, 700)]),
                                  to: geometry(["CD-289": (160, 460), "CD-290": (521, 761)]),
                                  anchor: "CD-289", scale: 3)
        XCTAssertTrue(shift.proven)
        XCTAssertEqual(shift.otherLabels, 1)
        XCTAssertEqual(shift.measured, 3)
        XCTAssertEqual(shift.landmarks, ["CD-289 bottom", "CD-290 bottom", "CD-290 top"])
        XCTAssertEqual(shift.maxPixels, 3, accuracy: 0.001)
    }

    /// A height change whose tops all stay put (the text's bottom is below
    /// the viewport) is seen through the bottoms, which tops alone missed.
    func testHeightChangeBelowTheViewportIsMeasured() {
        let shift = AnchoredShift(from: geometry(["CD-288": (-200, 60), "CD-289": (90, 1200)]),
                                  to: geometry(["CD-288": (-200, 60), "CD-289": (90, 1210)]),
                                  anchor: "CD-289", scale: 3)
        XCTAssertTrue(shift.proven)
        XCTAssertEqual(shift.maxPixels, 30, accuracy: 0.001)
        XCTAssertEqual(shift.worst, "CD-289 bottom")
    }

    func testMissingAnchorIsUnproven() {
        let shift = AnchoredShift(from: geometry(["CD-289": (100, 400)]), to: geometry(["CD-290": (100, 400)]),
                                  anchor: "CD-289", scale: 3)
        XCTAssertFalse(shift.proven)
        XCTAssertEqual(shift.measured, 0)
    }
}
