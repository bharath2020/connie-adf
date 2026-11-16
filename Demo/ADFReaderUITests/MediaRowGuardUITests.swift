import XCTest

/// PR 4 plan §8.6 (f19): the media-row guard. kitchen-sink's blocks 23–24
/// are percentage-width `mediaSingle` rows (one captioned), where issue #8's
/// lazy-stack livelock reproduces on main; this counts hangs there per arm.
///
/// Written only against what main's `LifecycleSupport.swift` already has
/// (`HostAgent`: `fromEnvironment`, `cpuSettleSeconds`, `record`) and with
/// its own `maxSettleSeconds`, so this one file compiles on main (the
/// arm-A instrumentation control: main + PR 4's fixtures + this file + PR
/// 4's lifecycle host scripts) and on the candidate. Not in
/// `Scripts/lifecycle-gate.sh`'s `ALL_TESTS`/`CONTAINER_TESTS` (the
/// two-way pin covers `LifecycleUITests` only); every arm runs it as
/// `Scripts/lifecycle-gate.sh --only MediaRowGuardUITests/testK9MediaRowScrollBackSettles`.
/// The arm's renderer: `ADF_K9_RENDERER=textkit2`
/// (`TEST_RUNNER_ADF_K9_RENDERER=textkit2` in the gate's environment)
/// launches with `-textkit2`; anything else launches on SwiftUI. Without
/// `ADF_LIFECYCLE_DIR` the test skips.
@MainActor
final class MediaRowGuardUITests: XCTestCase {
    /// CPU must settle to <= 2 % within this many seconds (plan §8.1).
    private static let maxSettleSeconds = 5.0
    private static let rounds = 5

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Five times: scroll to the end of kitchen-sink (its last block,
    /// "Synced content body") and back above blocks 23–24 (the expand
    /// "Click to expand", block 22); then CPU must settle ≤ 2 % within
    /// 5 s. A hang shows as a settle failure or a UI-query timeout (XCTest
    /// fails the test at the query; the gate records the failure).
    func testK9MediaRowScrollBackSettles() throws {
        let agent = try HostAgent.fromEnvironment()
        let textKit2 = ProcessInfo.processInfo.environment["ADF_K9_RENDERER"] == "textkit2"
        let arm = textKit2 ? "textkit2" : "swiftui"
        let app = XCUIApplication()
        app.launchArguments = ["-fixture", "kitchen-sink", "-rendererReset", "-rendererStats"]
            + (textKit2 ? ["-textkit2"] : [])
        app.launch()
        func labelled(_ text: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", text)).firstMatch
        }
        XCTAssertTrue(labelled("ADF Kitchen Sink").waitForExistence(timeout: 30), "kitchen-sink missing")
        let scroll = app.scrollViews.firstMatch
        let end = labelled("Synced content body")
        let above = app.buttons.matching(NSPredicate(format: "label == %@", "Click to expand")).firstMatch
        var swipes: [[Int]] = []
        var reached = true
        for _ in 0 ..< Self.rounds {
            var down = 0, up = 0
            while !end.exists, down < 20 {
                scroll.swipeUp()
                down += 1
            }
            while !(above.exists && above.frame.minY > app.windows.firstMatch.frame.minY), up < 20 {
                scroll.swipeDown()
                up += 1
            }
            reached = reached && down < 20 && up < 20
            swipes.append([down, up])
        }
        let settle = try agent.cpuSettleSeconds()
        let settled = (settle.seconds ?? .infinity) <= Self.maxSettleSeconds
        let pass = settled && reached
        try agent.record("K9 media-row scroll-back settle (kitchen-sink blocks 23–24, \(arm))", pass: pass, [
            "arm": arm, "rounds": Self.rounds, "swipes_down_up": swipes, "reached_both_ends": reached,
            "settle_s": settle.seconds ?? -1, "settle_samples": settle.samples,
        ])
        XCTAssertTrue(reached, "a round never reached the end or came back above blocks 23–24: \(swipes)")
        XCTAssertTrue(settled, "CPU did not settle within 5 s after the scroll-backs: \(settle.samples)")
    }
}
