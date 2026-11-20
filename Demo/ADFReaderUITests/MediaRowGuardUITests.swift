import XCTest

/// PR 4 plan §8.6 (f19): the media-row guard. kitchen-sink's blocks 23–24
/// are percentage-width `mediaSingle` rows (one captioned), where issue #8's
/// lazy-stack livelock reproduces on main; this counts hangs there per arm.
///
/// Written only against what main's `LifecycleSupport.swift` already has
/// (`HostAgent`: `fromEnvironment`, `cpuSettleSeconds`, `record`;
/// `ReaderDriver`: `init(launching:)`, `isRenderer`, `viewport`, `drag`,
/// `Identifier`) and with its own `maxSettleSeconds`, so this one file
/// compiles on main (the arm-A instrumentation control: main + PR 4's
/// fixtures + this file + PR 4's lifecycle host scripts) and on the
/// candidate. Not in `Scripts/lifecycle-gate.sh`'s
/// `ALL_TESTS`/`CONTAINER_TESTS` (the two-way pin covers
/// `LifecycleUITests` only); every arm runs it as
/// `Scripts/lifecycle-gate.sh --only MediaRowGuardUITests/testK9MediaRowScrollBackSettles`.
/// The arm's renderer: `ADF_K9_RENDERER=textkit2`
/// (`TEST_RUNNER_ADF_K9_RENDERER=textkit2` in the gate's environment)
/// launches with `-textkit2`; anything else launches on SwiftUI; the
/// toolbar must then name that renderer. Without `ADF_LIFECYCLE_DIR` the
/// test skips.
@MainActor
final class MediaRowGuardUITests: XCTestCase {
    /// CPU must settle to <= 2 % within this many seconds (plan §8.1).
    private static let maxSettleSeconds = 5.0
    private static let rounds = 5
    /// Block 23's caption ("A captioned sunset"): its owner, the
    /// `PreparedMedia` id of the risky row.
    private static let captionOwner = "0.23.0"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The toolbar names the arm's renderer first. Then five times: fling
    /// to the end of kitchen-sink until its last block ("Synced content
    /// body") intersects the viewport, and back until the expand above
    /// blocks 23–24 ("Click to expand", block 22) does while the end does
    /// not; each leg must take at least one swipe and at most 20, and
    /// whenever the caption of block 23 is in the tree it must lie between
    /// the two (so every leg's viewport swept blocks 23–24). Then CPU must
    /// settle ≤ 2 % within 5 s. A hang shows as a settle failure or a
    /// UI-query timeout (XCTest fails the test at the query; the gate
    /// records the failure). Last, slow drags bring the caption into the
    /// viewport: it must be its owner's `tk2-row` under TextKit 2 and have
    /// none under SwiftUI.
    func testK9MediaRowScrollBackSettles() throws {
        let agent = try HostAgent.fromEnvironment()
        let textKit2 = ProcessInfo.processInfo.environment["ADF_K9_RENDERER"] == "textkit2"
        let arm = textKit2 ? "textkit2" : "swiftui"
        let reader = ReaderDriver(launching: ["-fixture", "kitchen-sink", "-rendererReset", "-rendererStats"]
            + (textKit2 ? ["-textkit2"] : []))
        let app = reader.app
        let rendererName = textKit2 ? "TextKit 2" : "SwiftUI"
        XCTAssertTrue(reader.isRenderer(rendererName, timeout: 30), "the toolbar never named \(rendererName)")
        func labelled(_ text: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", text)).firstMatch
        }
        /// In the tree and intersecting the viewport.
        func shown(_ element: XCUIElement) -> Bool {
            guard element.exists else { return false }
            let frame = element.frame
            return frame.height > 0 && frame.intersects(reader.viewport)
        }
        XCTAssertTrue(labelled("ADF Kitchen Sink").waitForExistence(timeout: 30), "kitchen-sink missing")
        let scroll = app.scrollViews.firstMatch
        let end = labelled("Synced content body")
        let above = app.buttons.matching(NSPredicate(format: "label == %@", "Click to expand")).firstMatch
        let caption = labelled("A captioned sunset")
        let captionRow = app.descendants(matching: .any)
            .matching(identifier: ReaderDriver.Identifier.textKit2RowPrefix + Self.captionOwner).firstMatch
        /// Whether the caption, when in the tree, lies below the expand
        /// (`above`) or above the last block (`end`): nil when it is not in
        /// the tree.
        func captionOrdered(below top: XCUIElement?, above bottom: XCUIElement?) -> Bool? {
            guard caption.exists else { return nil }
            let frame = caption.frame
            if let top, top.exists, frame.minY < top.frame.maxY { return false }
            if let bottom, bottom.exists, frame.maxY > bottom.frame.minY { return false }
            return true
        }
        var swipes: [[Int]] = []
        var ordered: [[String]] = []
        var failures: [String] = []
        for round in 1 ... Self.rounds {
            var down = 0, up = 0
            while !shown(end), down < 20 {
                scroll.swipeUp()
                down += 1
            }
            let reachedEnd = shown(end)
            let orderAtEnd = captionOrdered(below: above, above: end)
            while !(shown(above) && !shown(end)), up < 20 {
                scroll.swipeDown()
                up += 1
            }
            let reachedAbove = shown(above) && !shown(end)
            let orderAtTop = captionOrdered(below: above, above: end)
            if !reachedEnd { failures.append("round \(round): the last block never entered the viewport in 20 swipes") }
            if reachedEnd, down == 0 { failures.append("round \(round): the last block was in view before any swipe") }
            if !reachedAbove {
                failures.append("round \(round): never back to the expand above blocks 23–24 (without the last block) "
                    + "in 20 swipes")
            }
            if reachedAbove, up == 0 { failures.append("round \(round): back above blocks 23–24 before any swipe") }
            if orderAtEnd == false || orderAtTop == false {
                failures.append("round \(round): the media caption is not between the expand and the last block")
            }
            swipes.append([down, up])
            ordered.append([orderAtEnd.map { "\($0)" } ?? "not in the tree", orderAtTop.map { "\($0)" } ?? "not in the tree"])
        }
        let roundsOK = failures.isEmpty
        let settle = try agent.cpuSettleSeconds()
        let settled = (settle.seconds ?? .infinity) <= Self.maxSettleSeconds
        // The risky row's engine, once it is in view (slow drags, no fling).
        var drags = 0
        while !shown(caption), drags < 8 {
            reader.drag(by: 200)
            drags += 1
        }
        let captionShown = shown(caption)
        let captionTextKit2 = captionRow.waitForExistence(timeout: textKit2 ? 10 : 2)
        if !captionShown { failures.append("the caption of block 23 never came into view") }
        if captionShown, captionTextKit2 != textKit2 {
            failures.append(textKit2 ? "the caption of block 23 is not a TextKit 2 row (tk2-row:\(Self.captionOwner))"
                : "the caption of block 23 is a TextKit 2 row on SwiftUI")
        }
        let pass = settled && failures.isEmpty
        try agent.record("K9 media-row scroll-back settle (kitchen-sink blocks 23–24, \(arm))", pass: pass, [
            "arm": arm, "rounds": Self.rounds, "swipes_down_up": swipes, "reached_both_ends": roundsOK,
            "caption_between_end_top": ordered, "caption_shown": captionShown,
            "caption_textkit2_row": captionTextKit2, "caption_owner": Self.captionOwner,
            "settle_s": settle.seconds ?? -1, "settle_samples": settle.samples, "failures": failures,
        ])
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; ") + " (swipes \(swipes))")
        XCTAssertTrue(settled, "CPU did not settle within 5 s after the scroll-backs: \(settle.samples)")
    }
}
