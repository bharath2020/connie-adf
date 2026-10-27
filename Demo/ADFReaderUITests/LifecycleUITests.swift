import XCTest

/// The lifecycle checks of the TextKit 2 stack plan (§3, quantitative checks
/// 2–6), driven by `Scripts/lifecycle-gate.sh`, which runs the host agent
/// (`Scripts/lifecycle_agent.py`) these tests talk to through
/// `ADF_LIFECYCLE_DIR`. Without that variable every test skips. Each test
/// records its figures and verdict through the agent; the gate turns them
/// into `lifecycle.md`. Tests run in name order, each on a fresh launch.
@MainActor
final class LifecycleUITests: XCTestCase {
    /// Per switch / per round trip tolerance (plan §3), device pixels.
    private static let maxShiftPixels: CGFloat = 2
    /// Settled memory growth limit (plan §3.5, §3.6).
    private static let maxGrowthKB = 5 * 1_024
    /// CPU must settle to <= 2 % within this many seconds (plan §3.5).
    private static let maxSettleSeconds = 5.0

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - §3.2 switch → collapse → switch → scroll back

    /// Parked near stress-5k's `Section 500:` (`-scrollToFraction 0.1`). A
    /// drag round trip does not return exactly in a lazy stack (estimated row
    /// heights are replaced as rows materialize: 1330 px of drift on pure
    /// SwiftUI over ±7200 pt), so "scroll back" is the app's non-animated
    /// re-jump to the parked block (`RejumpHook`) followed by the same 100 pt
    /// drag that parked it — the last scroll before every switch is a
    /// gesture, as for a reader, so the jump's anchor bookkeeping (a separate
    /// 26 px re-pin on a switch straight after a jump) stays out of the
    /// figure. A pure-SwiftUI away-and-back first proves that return exact
    /// (control). Then: switch ON, scroll away until the parked rows have
    /// left the render region, switch OFF, scroll back — every label within
    /// 2 px of where it was.
    func test1CollapseRoundTripKeepsRows() throws {
        let agent = try HostAgent.fromEnvironment()
        let reader = ReaderDriver(launching: [
            "-fixture", "stress-5k", "-rendererReset", "-rendererStats", "-scrollToFraction", "0.1",
        ])
        reader.waitForRenderer("SwiftUI")
        XCTAssertTrue(reader.element(labelPrefix: "Section 500:").waitForExistence(timeout: 30),
                      "stress-5k did not land on Section 500")
        try park(reader, agent)
        let scale = reader.pixelScale()
        let legs = 12, distance: CGFloat = 600
        // One away-and-back first: the first park after launch lands on
        // estimated heights for the rows above (14 px off the later parks).
        for _ in 0 ..< legs { reader.drag(by: distance) }
        try park(reader, agent)

        // Control: away and back, SwiftUI only.
        let s0 = try reader.visibleLabels()
        for _ in 0 ..< legs { reader.drag(by: distance) }
        reader.pause()
        try park(reader, agent)
        let s1 = try reader.visibleLabels()
        let control = LabelShift(from: s0, to: s1, scale: scale)

        // Switched round trip.
        reader.chooseRenderer(textKit2: true)
        reader.pause()
        let s2 = try reader.visibleLabels()
        let atSwitch = LabelShift(from: s1, to: s2, scale: scale)
        for _ in 0 ..< legs { reader.drag(by: distance) }
        reader.pause()
        // Long labels only: stress-5k's random sentences are unique at that
        // length; short ones ("Task", list markers) recur far away.
        let parkedLabels = s2.keys.filter { $0.count >= 24 }
        let stillAlive = parkedLabels.filter { reader.element(labelled: $0).exists }
        let stillMaterialised = stillAlive.count
        reader.chooseRenderer(textKit2: false)
        try park(reader, agent)
        let s3 = try reader.visibleLabels()
        let roundTrip = LabelShift(from: s1, to: s3, scale: scale)

        let limit = Self.maxShiftPixels + 0.01
        let pass = control.common > 0 && atSwitch.common > 0 && roundTrip.common > 0 && !parkedLabels.isEmpty
            && control.maxPixels <= limit && atSwitch.maxPixels <= limit && roundTrip.maxPixels <= limit
            && stillMaterialised == 0
        try agent.record("3.2 collapse round trip (stress-5k @ Section 500)", pass: pass, [
            "control_round_trip_px": Double(control.maxPixels), "control_labels": control.common,
            "switch_on_shift_px": Double(atSwitch.maxPixels), "switch_on_labels": atSwitch.common,
            "switch_on_worst": atSwitch.worstLabel,
            "switch_on_dpx": s1.compactMap { label, y in
                s2[label].map { "\(label.prefix(32))=\(Int((($0 - y) * scale).rounded()))" }
            }.sorted(),
            "round_trip_px": Double(roundTrip.maxPixels), "round_trip_labels": roundTrip.common,
            "round_trip_worst": roundTrip.worstLabel, "parked_long_labels": parkedLabels.count,
            "parked_labels_still_materialised_when_far": stillMaterialised,
            "still_materialised": stillAlive.map { String($0.prefix(48)) },
            "scroll_away_pt": Double(CGFloat(legs) * distance),
        ])
        XCTAssertGreaterThan(control.common, 0, "no label survived the control round trip")
        XCTAssertLessThanOrEqual(control.maxPixels, limit, "the re-jump itself does not return exactly")
        XCTAssertLessThanOrEqual(atSwitch.maxPixels, limit, "switch ON moved rows")
        XCTAssertFalse(parkedLabels.isEmpty, "no long label at the parked position")
        XCTAssertEqual(stillMaterialised, 0, "the parked rows never left the render region")
        XCTAssertGreaterThan(roundTrip.common, 0, "no label survived the switched round trip")
        XCTAssertLessThanOrEqual(roundTrip.maxPixels, limit,
                                 "\(roundTrip.worstLabel) returned \(roundTrip.maxPixels) px away")
    }

    /// Re-jump to the `-scrollToFraction` block, then a 100 pt drag.
    private func park(_ reader: ReaderDriver, _ agent: HostAgent) throws {
        try agent.request("rejump")
        reader.pause(1.5)
        reader.drag(by: 100)
        reader.pause()
    }

    // MARK: - §3.3 rotation round trip in each arm

    /// Portrait → landscape → portrait through the app's Darwin rotation hook
    /// (a width change), once per arm from the same parked position. The
    /// TextKit 2 arm may not drift more than the SwiftUI arm (main's path) +2 px.
    func test2RotationRoundTripDriftMatchesSwiftUI() throws {
        let agent = try HostAgent.fromEnvironment()
        var drift: [Bool: LabelShift] = [:]
        for textKit2 in [false, true] {
            var arguments = ["-fixture", "kitchen-sink", "-rendererReset", "-rendererStats"]
            if textKit2 { arguments.append("-textkit2") }
            let reader = ReaderDriver(launching: arguments)
            reader.waitForRenderer(textKit2 ? "TextKit 2" : "SwiftUI")
            XCTAssertTrue(reader.element(labelled: "ADF Kitchen Sink").waitForExistence(timeout: 15))
            for _ in 0 ..< 3 {
                reader.drag(by: 200)
            }
            reader.pause()
            let scale = reader.pixelScale()
            let before = try reader.visibleLabels()
            try agent.request("rotate")
            reader.pause(2.5)
            attach(reader.app, textKit2 ? "rotation-textkit2-landscape" : "rotation-swiftui-landscape")
            try agent.request("rotate")
            reader.pause(2.5)
            let after = try reader.visibleLabels()
            drift[textKit2] = LabelShift(from: before, to: after, scale: scale)
            reader.app.terminate()
        }
        let swiftUI = try XCTUnwrap(drift[false]), textKit2 = try XCTUnwrap(drift[true])
        let excess = textKit2.maxPixels - swiftUI.maxPixels
        let pass = swiftUI.common > 0 && textKit2.common > 0 && excess <= Self.maxShiftPixels + 0.01
        try agent.record("3.3 rotation round trip (kitchen-sink)", pass: pass, [
            "swiftui_drift_px": Double(swiftUI.maxPixels), "swiftui_worst": swiftUI.worstLabel,
            "textkit2_drift_px": Double(textKit2.maxPixels), "textkit2_worst": textKit2.worstLabel,
            "excess_px": Double(excess), "labels": [swiftUI.common, textKit2.common],
        ])
        XCTAssertGreaterThan(swiftUI.common, 0)
        XCTAssertGreaterThan(textKit2.common, 0)
        XCTAssertLessThanOrEqual(excess, Self.maxShiftPixels + 0.01,
                                 "TextKit 2 drifts \(textKit2.maxPixels) px vs SwiftUI \(swiftUI.maxPixels) px")
    }

    // MARK: - §3.4 state retained across switches

    /// `-switchDuringLoad` flips to TextKit 2 on the first streamed chunk of
    /// stress-5k; the load must still complete: the app records the block
    /// count at READY (About: load-ready-blocks == 5000) and
    /// `-scrollToFraction 0.9981` lands on block 4990, whose heading must be
    /// drawn by a TextKit 2 row.
    func test3SwitchDuringStreamingLoad() throws {
        let agent = try HostAgent.fromEnvironment()
        let reader = ReaderDriver(launching: [
            "-fixture", "stress-5k", "-rendererReset", "-rendererStats", "-switchDuringLoad",
            "-scrollToFraction", "0.9981",
        ])
        reader.waitForRenderer("TextKit 2", timeout: 30)
        let lastRow = reader.textKit2Row(labelPrefix: "Section 4990:").waitForExistence(timeout: 30)
        attach(reader.app, "switch-during-load-end")
        reader.openAbout()
        let switchField = reader.app.staticTexts[ReaderDriver.Identifier.loadSwitchBlocks]
        let readyField = reader.app.staticTexts[ReaderDriver.Identifier.loadReadyBlocks]
        let switched = switchField.waitForExistence(timeout: 5)
        let ready = readyField.waitForExistence(timeout: 5)
        let blocksAtSwitch = switched ? Int(switchField.label) ?? -1 : -1
        let blocksAtReady = ready ? Int(readyField.label) ?? -1 : -1
        reader.closeAbout()
        let pass = blocksAtSwitch > 0 && blocksAtSwitch < 5_000 && blocksAtReady == 5_000 && lastRow
        try agent.record("3.4a switch during streaming load (stress-5k)", pass: pass, [
            "blocks_loaded_at_switch": blocksAtSwitch, "blocks_at_ready": blocksAtReady,
            "total_blocks": 5_000, "last_heading_tk2_row": lastRow,
        ])
        XCTAssertGreaterThan(blocksAtSwitch, 0, "the app never switched during the load")
        XCTAssertLessThan(blocksAtSwitch, 5_000, "the switch did not happen while blocks were still streaming")
        XCTAssertEqual(blocksAtReady, 5_000, "the load did not complete after the switch")
        XCTAssertTrue(lastRow, "the last heading is not drawn by a TextKit 2 row")
    }

    /// Find-in-Page query, an opened expand and a toggled task survive a
    /// switch ON and a switch OFF.
    func test4SwitchKeepsSearchExpandAndTasks() throws {
        let agent = try HostAgent.fromEnvironment()
        let reader = ReaderDriver(launching: ["-fixture", "kitchen-sink", "-rendererReset", "-rendererStats"])
        let app = reader.app
        reader.waitForRenderer("SwiftUI")
        XCTAssertTrue(reader.element(labelled: "ADF Kitchen Sink").waitForExistence(timeout: 15))

        // Search active (first: running it scrolls to the first match).
        app.buttons["Find in Page"].tap()
        let field = app.textFields[ReaderDriver.Identifier.searchField]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "search field missing")
        field.tap()
        field.typeText("panel\n")
        let counter = app.staticTexts[ReaderDriver.Identifier.searchCounter]
        XCTAssertTrue(counter.waitForExistence(timeout: 10), "search counter missing")
        reader.pause(1.5)
        let counterBefore = counter.label
        XCTAssertNotEqual(counterBefore, "0", "the query found nothing")

        // Expand opened.
        let expand = app.buttons["Click to expand"]
        XCTAssertTrue(reveal(expand, reader), "the expand never came into view")
        expand.tap()
        XCTAssertTrue(reader.element(labelled: "Hidden detail").waitForExistence(timeout: 5), "expand did not open")

        // Task toggled ("Write the parser" starts as TODO).
        let pending = app.buttons.matching(NSPredicate(format: "label == %@", "Task")).firstMatch
        XCTAssertTrue(reveal(pending, reader), "the task list never came into view")
        let completed = app.buttons.matching(NSPredicate(format: "label == %@", "Completed task"))
        let completedBefore = completed.count
        pending.tap()
        reader.pause()
        let completedAfterToggle = completed.count
        XCTAssertEqual(completedAfterToggle, completedBefore + 1, "the task toggle did not register")

        var observations: [[String: Any]] = []
        var allKept = true
        for textKit2 in [true, false] {
            reader.chooseRenderer(textKit2: textKit2)
            reader.pause(1.5)
            let searchKept = field.exists && (field.value as? String) == "panel" && counter.label == counterBefore
            let expandKept = reveal(expand, reader) && (expand.value as? String) == "Expanded"
                && reader.element(labelled: "Hidden detail").exists
            let tasksKept = reveal(completed.firstMatch, reader) && completed.count == completedAfterToggle
            allKept = allKept && searchKept && expandKept && tasksKept
            observations.append([
                "renderer": textKit2 ? "textkit2" : "swiftui", "search_kept": searchKept,
                "counter": counter.exists ? counter.label : "missing", "expand_kept": expandKept,
                "tasks_kept": tasksKept,
            ])
            attach(app, textKit2 ? "state-after-switch-on" : "state-after-switch-off")
        }
        try agent.record("3.4b/c search, expand and task state across switches (kitchen-sink)", pass: allKept, [
            "query": "panel", "counter_before": counterBefore, "completed_tasks": completedAfterToggle,
            "observations": observations,
        ])
        XCTAssertTrue(allKept, "state lost across a switch: \(observations)")
    }

    // MARK: - §3.5 fling, scene-snapshot thrash, idle soak — both arms

    func test5FlingThrashSoakSwiftUI() throws {
        try flingThrashSoak(textKit2: false)
    }

    func test6FlingThrashSoakTextKit2() throws {
        try flingThrashSoak(textKit2: true)
    }

    private func flingThrashSoak(textKit2: Bool) throws {
        let agent = try HostAgent.fromEnvironment()
        let arm = textKit2 ? "textkit2" : "swiftui"
        var arguments = ["-fixture", "stress-5k", "-rendererReset", "-rendererStats"]
        if textKit2 { arguments.append("-textkit2") }
        let reader = ReaderDriver(launching: arguments)
        let app = reader.app
        reader.waitForRenderer(textKit2 ? "TextKit 2" : "SwiftUI")
        XCTAssertTrue(reader.element(labelPrefix: "Section 0:").waitForExistence(timeout: 30), "stress-5k missing")

        let scroll = app.scrollViews.firstMatch
        for _ in 0 ..< 3 {
            scroll.swipeUp(velocity: .fast)
        }
        let fling = try agent.cpuSettleSeconds()

        var thrashStates: [String: String] = [:]
        for cycle in 0 ..< 5 {
            let states = thrash(app, evidence: cycle == 0 ? arm : nil)
            if cycle == 0 { thrashStates = states }
        }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "app not in the foreground after thrash")
        let thrashSettle = try agent.cpuSettleSeconds()
        let rendererKept = reader.anyTextKit2Row.exists == textKit2

        let soak = try agent.request("soak", ["seconds": 60, "threshold_pct": 2.0], timeout: 180)
        let growth = soak["growth_kb"] as? Int ?? Int.max
        let cpuMean = soak["cpu_mean"] as? Double ?? .infinity

        let flingOK = (fling.seconds ?? .infinity) <= Self.maxSettleSeconds
        let thrashOK = (thrashSettle.seconds ?? .infinity) <= Self.maxSettleSeconds
        // Each stop must actually have left the foreground, or the "thrash"
        // could be five Home presses (the lock is a private selector and the
        // switcher a coordinate gesture).
        let leftForeground = ["home", "locked", "switcher"].allSatisfy {
            thrashStates[$0] != nil && thrashStates[$0] != "foreground"
        }
        let pass = flingOK && thrashOK && leftForeground && growth <= Self.maxGrowthKB && cpuMean <= 2.0
            && rendererKept
        try agent.record("3.5 fling + thrash + 60 s soak (stress-5k, \(arm))", pass: pass, [
            "fling_settle_s": fling.seconds ?? -1, "thrash_settle_s": thrashSettle.seconds ?? -1,
            "soak_growth_kb": growth, "soak_cpu_mean_pct": cpuMean, "soak_cpu_max_pct": soak["cpu_max"] ?? -1,
            "soak_start_kb": soak["start_kb"] ?? -1, "soak_end_kb": soak["end_kb"] ?? -1,
            "renderer_rows_as_expected_after_thrash": rendererKept, "thrash_cycles": 5,
            "first_cycle_app_states": thrashStates, "thrash_left_foreground": leftForeground,
        ])
        XCTAssertTrue(flingOK, "CPU did not settle within 5 s after the fling: \(fling.samples)")
        XCTAssertTrue(thrashOK, "CPU did not settle within 5 s after the thrash: \(thrashSettle.samples)")
        XCTAssertTrue(leftForeground, "a thrash stop did not background the app: \(thrashStates)")
        XCTAssertTrue(rendererKept, "renderer rows changed across the thrash")
        XCTAssertLessThanOrEqual(growth, Self.maxGrowthKB, "settled memory grew \(growth) KB over the soak")
        XCTAssertLessThanOrEqual(cpuMean, 2.0, "idle CPU averaged \(cpuMean) % over the soak")
    }

    /// One cycle: Home and back, lock and unlock, app switcher and back.
    /// With `evidence`, captures the screen and the app's state at each stop
    /// (the lock is XCUIDevice's private `pressLockButton`).
    @discardableResult
    private func thrash(_ app: XCUIApplication, evidence arm: String?) -> [String: String] {
        var states: [String: String] = [:]
        func observe(_ stop: String) {
            guard let arm else { return }
            states[stop] = Self.describe(app.state)
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "thrash-\(arm)-\(stop)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        observe("home")
        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 10)

        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        Thread.sleep(forTimeInterval: 1.5)
        observe("locked")
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        let bottom = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99))
        bottom.press(forDuration: 0.05, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
        Thread.sleep(forTimeInterval: 1)
        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 10)

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.995))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)),
                    withVelocity: .slow, thenHoldForDuration: 1.0)
        Thread.sleep(forTimeInterval: 1)
        observe("switcher")
        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 10)
        Thread.sleep(forTimeInterval: 0.5)
        observe("back")
        return states
    }

    private static func describe(_ state: XCUIApplication.State) -> String {
        switch state {
        case .notRunning: "notRunning"
        case .runningBackgroundSuspended: "backgroundSuspended"
        case .runningBackground: "background"
        case .runningForeground: "foreground"
        default: "unknown(\(state.rawValue))"
        }
    }

    // MARK: - §3.6 twenty flips

    /// Twenty switches at a parked stress-5k position: OFF → 0 live TextKit 2
    /// rows, ON → the same render-region count every time.
    ///
    /// Memory (captain's rule B, decision A, 2026-10-26): the raw settled
    /// phys_footprint growth over twenty TextKit 2 switches must be within
    /// 5,120 KB of a control's growth over twenty switches that rebuild the
    /// same rows as plain SwiftUI — median of two runs per arm, no pressure
    /// relief anywhere. The control (`-rebuildControlPicks 20`): its TextKit 2
    /// picks swap exactly the leaves a TextKit 2 pick swaps, at the same
    /// branch point, to their SwiftUI `Text` (`ADFTextRenderer.rebuildControl`),
    /// through the same menu and About sheet queries; it must show the same
    /// nonzero rebuilt-row count after every ON pick and none after every
    /// OFF pick, or it measured nothing. Each series runs in its own launch
    /// (the first series of a launch takes the allocator's high-water growth,
    /// which flattered whichever arm ran second), the arms' order alternating
    /// between the two runs. (The control was formerly twenty same-renderer
    /// picks that rebuilt no rows; the per-switch rebuild alone, without
    /// TextKit, exceeded 5,120 KB over it: `memory-phase4/`.)
    func test7TwentyFlipsReleaseRows() throws {
        let agent = try HostAgent.fromEnvironment()
        var control: [TwentyFlipSeries] = [], flips: [TwentyFlipSeries] = []
        for run in 1 ... 2 {
            for arm in run == 1 ? [true, false] : [false, true] {
                let series = twentyFlips(agent, control: arm)
                if arm { control.append(series) } else { flips.append(series) }
            }
        }
        func median(_ values: [Int]) -> Int {
            let sorted = values.sorted()
            return sorted.count % 2 == 1 ? sorted[sorted.count / 2]
                : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }
        let controlMedian = median(control.map(\.growth))
        let flipMedian = median(flips.map(\.growth))
        let excess = flipMedian - controlMedian
        let rowsOK = (control + flips).allSatisfy(\.rowsOK)
        let pass = rowsOK && excess <= Self.maxGrowthKB
        try agent.record("3.6 twenty flips (stress-5k)", pass: pass, [
            "gated_metric": "median over 2 runs of raw settled phys_footprint growth over twenty switches, "
                + "TextKit 2 minus a control that rebuilds the same rows as SwiftUI (<= 5,120 KB; no pressure relief)",
            "control_growth_median_kb": controlMedian, "flips_growth_median_kb": flipMedian,
            "flips_minus_control_kb": excess,
            "control_runs": control.map(\.figures), "flip_runs": flips.map(\.figures),
        ])
        for (index, series) in (control + flips).enumerated() {
            XCTAssertTrue(series.rowsOK, "series \(index + 1) (\(series.control ? "control" : "TextKit 2")): "
                + "ON \(series.on) / other kind \(series.onOther), OFF \(series.off)")
        }
        XCTAssertLessThanOrEqual(excess, Self.maxGrowthKB,
                                 "flips grew \(flipMedian) KB vs the control's \(controlMedian) KB (medians; excess \(excess) KB)")
    }

    private struct TwentyFlipSeries {
        let control: Bool
        var growth = 0
        /// Per ON pick the count waited for (rebuilt rows for the control,
        /// live TextKit 2 rows otherwise) and the other kind's (none may
        /// exist); per OFF pick both kinds'.
        var on: [Int] = [], onOther: [Int] = [], off: [Int] = []
        var figures: [String: Any] = [:]

        /// Every ON pick showed the same nonzero count of its kind and none
        /// of the other; every OFF pick, none of either.
        var rowsOK: Bool {
            !on.isEmpty && on.allSatisfy { $0 > 0 && $0 == on[0] }
                && onOther.allSatisfy { $0 == 0 } && off.allSatisfy { $0 == 0 }
        }
    }

    /// One launch, one series: twenty switches alternating ON/OFF through
    /// the renderer menu — rebuilding as SwiftUI (`control`) or as TextKit 2
    /// — About read after every pick, a settled footprint before the first
    /// and after every OFF (ten, the last closing the series).
    private func twentyFlips(_ agent: HostAgent, control: Bool) -> TwentyFlipSeries {
        let reader = ReaderDriver(launching: [
            "-fixture", "stress-5k", "-rendererReset", "-rendererStats", "-rebuildControlPicks", control ? "20" : "0",
        ])
        reader.waitForRenderer("SwiftUI")
        XCTAssertTrue(reader.element(labelPrefix: "Section 0:").waitForExistence(timeout: 30), "stress-5k missing")
        for _ in 0 ..< 3 {
            reader.drag(by: 300)
        }
        var series = TwentyFlipSeries(control: control)
        do {
            let start = try agent.settledFootprintKB()
            var settled: [Int] = []
            for flip in 1 ... 20 {
                let isOn = flip % 2 == 1
                reader.chooseRenderer(textKit2: isOn)
                let first = series.on.first
                let rows = reader.liveRows(control: control, until: { count in
                    isOn ? count > 0 && (first == nil || count == first) : count == 0
                }, settled: isOn)
                let waited = (control ? rows.control : rows.textKit2) ?? -1
                let other = (control ? rows.textKit2 : rows.control) ?? -1
                if isOn {
                    series.on.append(waited)
                    series.onOther.append(other)
                } else {
                    series.off.append(contentsOf: [waited, other])
                    settled.append(try agent.settledFootprintKB())
                }
            }
            series.growth = (settled.last ?? start) - start
            series.figures = [
                "arm": control ? "control (SwiftUI rebuild)" : "TextKit 2",
                "on_rows": series.on, "on_other_kind_rows": series.onOther, "off_rows_both_kinds": series.off,
                "start_kb": start, "after_each_off_kb": settled, "growth_kb": series.growth,
            ]
        } catch {
            XCTFail("twenty-flip series failed: \(error)")
        }
        reader.app.terminate()
        return series
    }

    // MARK: - Helpers

    /// Scrolls kitchen-sink until `element` is fully in view: back to the top
    /// first, then down a screen at a time.
    private func reveal(_ element: XCUIElement, _ reader: ReaderDriver) -> Bool {
        if reader.isVisible(element) { return true }
        let scroll = reader.app.scrollViews.firstMatch
        let title = reader.element(labelled: "ADF Kitchen Sink")
        var swipes = 0
        while !reader.isVisible(title), swipes < 8 {
            scroll.swipeDown(velocity: .fast)
            swipes += 1
        }
        swipes = 0
        while !reader.isVisible(element), swipes < 12 {
            reader.drag(by: 350)
            swipes += 1
        }
        return reader.isVisible(element)
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
