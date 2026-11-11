import XCTest

/// The lifecycle checks of the TextKit 2 stack plan (§3, quantitative checks
/// 2–6), driven by `Scripts/lifecycle-gate.sh`, which runs the host agent
/// (`Scripts/lifecycle_agent.py`) these tests talk to through
/// `ADF_LIFECYCLE_DIR`. Without that variable every test skips. Each test
/// records its figures and verdict through the agent; the gate turns them
/// into `lifecycle.md`. Tests run in name order, each on a fresh launch.
///
/// `testL1`…`testL6` are PR 2's list additions (Astra §6 items 1–6, with
/// Fable F14 and F16), on the list fixtures `lists-parity` and
/// `list-dense`; tests 1–8 stay as they were. A list row drawn by TextKit 2
/// is a `tk2-row:<owner>` element whose owner is `PreparedListRow.id` for a
/// leader and the block's node path for trailing text, so an owner below
/// root level (`0.<n>.…`) proves a list leaf flipped. Limits are the
/// foundation's (F16): a no-switch control drift over 2 px is the known
/// lifecycle flake (PR 1 test1), recorded as `failure_class` and not a
/// renderer verdict — rerun, never re-tune.
@MainActor
final class LifecycleUITests: XCTestCase {
    /// Per switch / per round trip tolerance (plan §3), device pixels.
    private static let maxShiftPixels: CGFloat = 2
    /// `maxShiftPixels` with the comparison slack every check uses.
    private static let shiftLimit = maxShiftPixels + 0.01
    /// F16's classification of a failure whose only cause is the no-switch
    /// control's own drift.
    private static let controlDriftClass = "control drift: known lifecycle flake (F16, PR 1 test1); rerun, limits unchanged"
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
            "failure_class": !pass && control.maxPixels > limit ? Self.controlDriftClass : "",
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

    /// stress-5k by default (tests 5 and 6, unchanged); `testL5a`/`testL5b`
    /// run it on list-dense with `listProof`: after the thrash the TextKit 2
    /// arm must still draw list-owned TextKit 2 rows, the SwiftUI arm none.
    private func flingThrashSoak(textKit2: Bool, fixture: String = "stress-5k", landmark: String = "Section 0:",
                                 listProof: Bool = false) throws
    {
        let agent = try HostAgent.fromEnvironment()
        let arm = textKit2 ? "textkit2" : "swiftui"
        var arguments = ["-fixture", fixture, "-rendererReset", "-rendererStats", "-scenePhaseProbe"]
        if textKit2 { arguments.append("-textkit2") }
        let reader = ReaderDriver(launching: arguments)
        let app = reader.app
        reader.waitForRenderer(textKit2 ? "TextKit 2" : "SwiftUI")
        XCTAssertTrue(reader.element(labelPrefix: landmark).waitForExistence(timeout: 30), "\(fixture) missing")
        XCTAssertNotNil(Self.scenePhases(app), "scene-phase-probe missing (-scenePhaseProbe)")

        let scroll = app.scrollViews.firstMatch
        for _ in 0 ..< 3 {
            scroll.swipeUp(velocity: .fast)
        }
        let fling = try agent.cpuSettleSeconds()

        var firstCycle: [String: String] = [:]
        var unconfirmed: [String] = []
        for cycle in 0 ..< 5 {
            let stops = thrash(app, evidence: cycle == 0 ? arm : nil)
            if cycle == 0 { firstCycle = stops.evidence }
            unconfirmed += Self.stops.filter { stops.confirmed[$0] != true }.map { "\(cycle):\($0)" }
        }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "app not in the foreground after thrash")
        let thrashSettle = try agent.cpuSettleSeconds()
        var rendererKept = reader.anyTextKit2Row.exists == textKit2
        var listRows: [String: Any] = [:]
        if listProof {
            let census = try reader.documentSnapshot()
            rendererKept = rendererKept
                && (textKit2 ? census.listOwnedRows > 0 : census.textKit2Rows.isEmpty)
            listRows = ["list_owned_tk2_rows_after_thrash": census.listOwnedRows,
                        "root_owned_tk2_rows_after_thrash": census.rootOwnedRows]
        }

        let soak = try agent.request("soak", ["seconds": 60, "threshold_pct": 2.0], timeout: 180)
        let growth = soak["growth_kb"] as? Int ?? Int.max
        let cpuMean = soak["cpu_mean"] as? Double ?? .infinity

        let flingOK = (fling.seconds ?? .infinity) <= Self.maxSettleSeconds
        let thrashOK = (thrashSettle.seconds ?? .infinity) <= Self.maxSettleSeconds
        // Each stop must actually have left the foreground, or the "thrash"
        // could be five Home presses (the lock is a private selector and the
        // switcher a coordinate gesture) — proven by the app's own scene
        // phases (`-scenePhaseProbe`), not `XCUIApplication.state`, which
        // reads runningForeground at every stop on the simulator.
        let leftForeground = unconfirmed.isEmpty
        let pass = flingOK && thrashOK && leftForeground && growth <= Self.maxGrowthKB && cpuMean <= 2.0
            && rendererKept
        let check = fixture == "stress-5k" ? "3.5" : "6.5"
        var figures: [String: Any] = [
            "fling_settle_s": fling.seconds ?? -1, "thrash_settle_s": thrashSettle.seconds ?? -1,
            "fling_samples": fling.samples, "thrash_samples": thrashSettle.samples,
            "soak_growth_kb": growth, "soak_cpu_mean_pct": cpuMean, "soak_cpu_max_pct": soak["cpu_max"] ?? -1,
            "soak_start_kb": soak["start_kb"] ?? -1, "soak_end_kb": soak["end_kb"] ?? -1,
            "renderer_rows_as_expected_after_thrash": rendererKept, "thrash_cycles": 5,
            "first_cycle_stops": firstCycle, "thrash_left_foreground": leftForeground,
            "unconfirmed_stops": unconfirmed,
        ]
        figures.merge(listRows) { first, _ in first }
        try agent.record("\(check) fling + thrash + 60 s soak (\(fixture), \(arm))", pass: pass, figures)
        XCTAssertTrue(flingOK, "CPU did not settle within 5 s after the fling: \(fling.samples)")
        XCTAssertTrue(thrashOK, "CPU did not settle within 5 s after the thrash: \(thrashSettle.samples)")
        XCTAssertTrue(leftForeground, "thrash stops the app's scene phases did not confirm: \(unconfirmed); "
            + "first cycle: \(firstCycle)")
        XCTAssertTrue(rendererKept, "renderer rows changed across the thrash")
        XCTAssertLessThanOrEqual(growth, Self.maxGrowthKB, "settled memory grew \(growth) KB over the soak")
        XCTAssertLessThanOrEqual(cpuMean, 2.0, "idle CPU averaged \(cpuMean) % over the soak")
    }

    /// The thrash stops, in cycle order.
    private static let stops = ["home", "locked", "switcher", "back"]

    /// One cycle: Home and back, lock and unlock, app switcher and back.
    /// Each stop is confirmed by the app's own scene phases once it is back
    /// (`-scenePhaseProbe`; polled up to 5 s): Home and lock each add a
    /// `background`; the switcher adds a `background` or an `inactive` (a
    /// scene shown as a card in the switcher is deactivated, and need not be
    /// backgrounded); `back` ends `active`. With `evidence`, also records at
    /// each stop — while the app is away — `XCUIApplication.state` and
    /// SpringBoard's state as a cross-check, plus a screenshot (the lock is
    /// XCUIDevice's private `pressLockButton`).
    private func thrash(_ app: XCUIApplication, evidence arm: String?)
        -> (confirmed: [String: Bool], evidence: [String: String])
    {
        var confirmed: [String: Bool] = [:]
        var evidence: [String: String] = [:]
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func observe(_ stop: String) {
            guard let arm else { return }
            evidence[stop] = "app=\(Self.describe(app.state)) springboard=\(Self.describe(springboard.state))"
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "thrash-\(arm)-\(stop)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        func confirm(_ stop: String, _ left: (ScenePhases) -> Bool) {
            let phases = Self.waitForScenePhases(app, until: left)
            confirmed[stop] = phases.map(left) ?? false
            if arm != nil {
                evidence[stop, default: ""] += " phases=\(phases?.label ?? "missing")"
            }
        }

        // Each baseline is read once the app is active again, so a
        // transition still arriving from the previous return cannot count
        // for the next stop.
        func settledBaseline() -> ScenePhases? {
            Self.waitForScenePhases(app) { $0.last == "active" }
        }
        var before = settledBaseline()
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        observe("home")
        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 10)
        confirm("home") { [before] now in before.map { now.background > $0.background } ?? false }

        before = settledBaseline()
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
        confirm("locked") { [before] now in before.map { now.background > $0.background } ?? false }

        before = settledBaseline()
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.995))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)),
                    withVelocity: .slow, thenHoldForDuration: 1.0)
        Thread.sleep(forTimeInterval: 1)
        observe("switcher")
        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 10)
        confirm("switcher") { [before] now in
            before.map { now.background > $0.background || now.inactive > $0.inactive } ?? false
        }
        Thread.sleep(forTimeInterval: 0.5)
        observe("back")
        confirm("back") { $0.last == "active" }
        return (confirmed, evidence)
    }

    /// The `-scenePhaseProbe` overlay's counts
    /// (`background=<n> inactive=<n> active=<n> last=<phase>`).
    private struct ScenePhases {
        var background: Int
        var inactive: Int
        var active: Int
        var last: String
        var label: String

        init?(_ label: String) {
            var fields: [String: String] = [:]
            for pair in label.split(separator: " ") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
            }
            guard let background = fields["background"].flatMap({ Int($0) }),
                  let inactive = fields["inactive"].flatMap({ Int($0) }),
                  let active = fields["active"].flatMap({ Int($0) }),
                  let last = fields["last"] else { return nil }
            self.background = background
            self.inactive = inactive
            self.active = active
            self.last = last
            self.label = label
        }
    }

    /// The probe's current counts; `nil` when it is missing or unreadable
    /// (the app is not in the foreground, or `-scenePhaseProbe` is absent).
    private static func scenePhases(_ app: XCUIApplication) -> ScenePhases? {
        let probe = app.staticTexts["scene-phase-probe"]
        guard probe.exists else { return nil }
        return ScenePhases(probe.label)
    }

    /// Polls the probe until `condition` holds or `timeout` passes; returns
    /// the last reading.
    private static func waitForScenePhases(_ app: XCUIApplication, timeout: TimeInterval = 5,
                                           until condition: (ScenePhases) -> Bool) -> ScenePhases?
    {
        let deadline = Date().addingTimeInterval(timeout)
        var phases: ScenePhases?
        repeat {
            phases = scenePhases(app)
            if let phases, condition(phases) { break }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return phases
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
    /// branch point, to their SwiftUI `Text` (`View.adfRebuildControl`),
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
        let (control, flips) = twentyFlipDesign(agent)
        let controlMedian = Self.median(control.map(\.growth))
        let flipMedian = Self.median(flips.map(\.growth))
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

    /// Rule B's four launches — control and TextKit 2 twice, the arms'
    /// order alternating — each a `twentyFlips` series.
    private func twentyFlipDesign(_ agent: HostAgent, fixture: String = "stress-5k", landmark: String = "Section 0:",
                                  census: Bool = false) -> (control: [TwentyFlipSeries], flips: [TwentyFlipSeries])
    {
        var control: [TwentyFlipSeries] = [], flips: [TwentyFlipSeries] = []
        for run in 1 ... 2 {
            for arm in run == 1 ? [true, false] : [false, true] {
                let series = twentyFlips(agent, control: arm, fixture: fixture, landmark: landmark, census: census)
                if arm { control.append(series) } else { flips.append(series) }
            }
        }
        return (control, flips)
    }

    private static func median(_ values: [Int]) -> Int {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2]
            : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    private struct TwentyFlipSeries {
        let control: Bool
        var growth = 0
        /// Per ON pick the count waited for (rebuilt rows for the control,
        /// live TextKit 2 rows otherwise) and the other kind's (none may
        /// exist); per OFF pick both kinds'.
        var on: [Int] = [], onOther: [Int] = [], off: [Int] = []
        var figures: [String: Any] = [:]
        /// With `census`, one more ON pick after the measured series: the
        /// count waited for, and the TextKit 2 rows in an accessibility
        /// snapshot split by owner level (F14). Taken after the last
        /// footprint, so the snapshot never touches the gated growth.
        var censusRows = -1, censusRootOwned = -1, censusListOwned = -1

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
    private func twentyFlips(_ agent: HostAgent, control: Bool, fixture: String, landmark: String,
                             census: Bool) -> TwentyFlipSeries
    {
        let reader = ReaderDriver(launching: [
            "-fixture", fixture, "-rendererReset", "-rendererStats", "-rebuildControlPicks", control ? "20" : "0",
        ])
        reader.waitForRenderer("SwiftUI")
        XCTAssertTrue(reader.element(labelPrefix: landmark).waitForExistence(timeout: 30), "\(fixture) missing")
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
            if census {
                // `-rebuildControlPicks 20` covers this eleventh ON pick too
                // (only TextKit 2 picks consume it), so the control census
                // sees its rebuilt rows and no TextKit 2 row.
                reader.chooseRenderer(textKit2: true)
                let first = series.on.first
                let rows = reader.liveRows(control: control, until: { $0 > 0 && (first == nil || $0 == first) },
                                           settled: true)
                let snapshot = try reader.documentSnapshot()
                series.censusRows = (control ? rows.control : rows.textKit2) ?? -1
                series.censusRootOwned = snapshot.rootOwnedRows
                series.censusListOwned = snapshot.listOwnedRows
                series.figures["census_after_series"] = [
                    "rows": series.censusRows, "tk2_rows_root_owned": series.censusRootOwned,
                    "tk2_rows_list_owned": series.censusListOwned,
                    "tk2_list_owners_sample": snapshot.textKit2Rows.keys.filter { !DocumentSnapshot.isRootOwner($0) }
                        .sorted().prefix(8).map { $0 },
                ]
            }
        } catch {
            XCTFail("twenty-flip series failed: \(error)")
        }
        reader.app.terminate()
        return series
    }

    // MARK: - Renderer launch flags (Fable S16 regression)

    /// `-textkit2` starts the launch on TextKit 2 even over a persisted
    /// SwiftUI choice (a toolbar pick of SwiftUI, the way earlier UI tests
    /// leave the device), the next launch without the flag is back on
    /// SwiftUI, and a toolbar pick of TextKit 2 persists across a plain
    /// relaunch. Each launch's renderer is read from the toolbar label and
    /// the About sheet's live TextKit 2 row count.
    func test8RendererLaunchFlagsAndPersistence() throws {
        let agent = try HostAgent.fromEnvironment()
        let fixture = ["-fixture", "kitchen-sink"]
        var steps: [[String: Any]] = []
        func observe(_ reader: ReaderDriver, _ step: String, textKit2: Bool) -> Bool {
            let label = textKit2 ? "TextKit 2" : "SwiftUI"
            let labelOK = reader.isRenderer(label)
            let rows = reader.liveTextKit2Rows(until: { textKit2 ? $0 > 0 : $0 == 0 }, settled: true, timeout: 10)
            let ok = labelOK && rows.map { textKit2 ? $0 > 0 : $0 == 0 } == true
            steps.append(["step": step, "want": label, "label_ok": labelOK, "live_tk2_rows": rows ?? -1, "pass": ok])
            return ok
        }

        // A persisted SwiftUI choice, made in the toolbar.
        let setup = ReaderDriver(launching: fixture + ["-rendererReset"])
        setup.waitForRenderer("SwiftUI")
        setup.chooseRenderer(textKit2: true)
        setup.chooseRenderer(textKit2: false)

        var pass = observe(ReaderDriver(launching: fixture + ["-textkit2"]), "-textkit2 over a persisted SwiftUI",
                           textKit2: true)
        pass = observe(ReaderDriver(launching: fixture), "plain relaunch after -textkit2", textKit2: false) && pass
        let picker = ReaderDriver(launching: fixture)
        picker.chooseRenderer(textKit2: true)
        pass = observe(ReaderDriver(launching: fixture), "plain relaunch after a toolbar pick of TextKit 2",
                       textKit2: true) && pass
        ReaderDriver(launching: fixture + ["-rendererReset"]).waitForRenderer("SwiftUI")

        try agent.record("S16 renderer launch flags (kitchen-sink)", pass: pass, ["steps": steps])
        for step in steps {
            XCTAssertEqual(step["pass"] as? Bool, true, "\(step)")
        }
    }

    // MARK: - PR 2 lists (Astra §6 items 1–6; Fable F14, F16)

    /// 6.1 — five round trips (ON, OFF) at a parked list position in each
    /// list fixture (`parityPosition`, `densePosition`). Gated per position:
    /// every switch moves every common label ≤ 2 px; no accumulation (each
    /// OFF within 2 px of the start, each ON within 2 px of the first ON);
    /// the ordered marker stays on its leader's line (offset change ≤ 2 px);
    /// every landmark row visible, in order, drawn by its pinned owner under
    /// TextKit 2 and by no TextKit 2 row under SwiftUI. Then one more ON pick
    /// (F14: About's live count exceeds the root-owned TextKit 2 rows of an
    /// accessibility snapshot, and list-owned rows exist) and an OFF pick
    /// that must release every row. The leader's summed travel (the
    /// foundation's "2 px in total" figure) is recorded.
    func testL1ListFiveRoundTripsAtParkedPositions() throws {
        let agent = try HostAgent.fromEnvironment()
        var failures: [String] = []
        for position in [Self.parityPosition, Self.densePosition] {
            failures += try fiveRoundTrips(at: position, agent)
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
    }

    /// One position of `testL1…` in its own launch; records, then returns
    /// its failures.
    private func fiveRoundTrips(at position: ListPosition, _ agent: HostAgent) throws -> [String] {
        let reader = try launch(at: position, agent)
        let scale = reader.pixelScale()
        let limit = Self.shiftLimit
        let start = try reader.documentSnapshot()
        let startLandmarks = landmarks(position, start, textKit2: false)
        var previous = start.tops
        var firstOn: [String: CGFloat]?
        var perSwitch: [Double] = [], net: [Double] = [], markerDrift: [Double] = []
        var worst = (label: "", pixels: CGFloat(0))
        var leaderTravel: CGFloat = 0
        var minCommon = Int.max
        var landmarkFailures: [String] = []
        for trip in 1 ... 5 {
            for textKit2 in [true, false] {
                reader.chooseRenderer(textKit2: textKit2)
                reader.pause()
                let snapshot = try reader.documentSnapshot()
                let tops = snapshot.tops
                let step = LabelShift(from: previous, to: tops, scale: scale)
                perSwitch.append(Double(step.maxPixels))
                minCommon = min(minCommon, step.common)
                if step.maxPixels > worst.pixels { worst = (step.worstLabel, step.maxPixels) }
                if textKit2, firstOn == nil { firstOn = tops }
                let reference = textKit2 ? firstOn ?? tops : start.tops
                net.append(Double(LabelShift(from: reference, to: tops, scale: scale).maxPixels))
                if let y0 = previous[position.leader], let y1 = tops[position.leader] {
                    leaderTravel += abs(y1 - y0) * scale
                }
                let found = landmarks(position, snapshot, textKit2: textKit2)
                if let offset = found.markerOffset, let offset0 = startLandmarks.markerOffset {
                    markerDrift.append(Double(abs(offset - offset0) * scale))
                }
                if !found.ok {
                    landmarkFailures.append("trip \(trip) \(textKit2 ? "ON" : "OFF"): \(found.figures)")
                }
                previous = tops
            }
        }
        attach(reader.app, "list-round-trips-\(position.fixture)")
        reader.chooseRenderer(textKit2: true)
        let live = reader.liveTextKit2Rows(until: { $0 > 0 }, settled: true) ?? -1
        let census = try reader.documentSnapshot()
        reader.chooseRenderer(textKit2: false)
        let released = reader.liveTextKit2Rows(until: { $0 == 0 }, settled: true) ?? -1
        reader.app.terminate()

        var failures: [String] = []
        if !startLandmarks.ok { failures.append("landmarks at the start: \(startLandmarks.figures)") }
        if minCommon == 0 { failures.append("a switch left no common label") }
        if (perSwitch.max() ?? .infinity) > Double(limit) {
            failures.append("a switch moved \(worst.label.prefix(32)) \(worst.pixels) px")
        }
        if (net.max() ?? .infinity) > Double(limit) { failures.append("displacement accumulated: \(net) px") }
        if markerDrift.count != perSwitch.count || (markerDrift.max() ?? 0) > Double(limit) {
            failures.append("the \(position.marker) marker left its leader's line: \(markerDrift) px")
        }
        failures += landmarkFailures
        if !(live > census.rootOwnedRows && census.listOwnedRows > 0) {
            failures.append("F14: live \(live) vs root-owned \(census.rootOwnedRows), list-owned \(census.listOwnedRows)")
        }
        if released != 0 { failures.append("\(released) TextKit 2 rows alive after OFF") }
        try agent.record("6.1 five round trips (\(position.name))", pass: failures.isEmpty, [
            "gated": "per switch <= 2.01 px and net vs start / first ON <= 2.01 px over all common labels; "
                + "marker offset change <= 2.01 px; landmarks; F14; release",
            "per_switch_px": perSwitch, "net_px": net, "worst_label": String(worst.label.prefix(48)),
            "worst_px": Double(worst.pixels), "leader_travel_sum_px": Double(leaderTravel),
            "marker_offset_change_px": markerDrift, "min_common_labels": minCommon == .max ? 0 : minCommon,
            "start_landmarks": startLandmarks.figures, "landmark_failures": landmarkFailures,
            "f14_live_tk2_rows": live, "f14_root_owned_tk2_rows": census.rootOwnedRows,
            "f14_list_owned_tk2_rows": census.listOwnedRows, "live_tk2_rows_after_off": released,
            "failures": failures,
        ])
        return failures.map { "\(position.name): \($0)" }
    }

    /// 6.2 — test1's method on list-dense (`densePosition`, ~63,000 pt
    /// down): a no-switch control away-and-back first; forward — ON at the
    /// park, twelve 600 pt drags away until the parked list's rows have left
    /// the render region, OFF there, back; reverse — ON then OFF at the park,
    /// away, ON there, back, so the parked list rematerialises naturally as
    /// TextKit 2 rows. Forward returns within 2 px of the control's park,
    /// reverse within 2 px of the ON park; every switch moves labels ≤ 2 px;
    /// no label pair changes order across either trip; landmarks (leader,
    /// marker, nested row, continuation paragraph, trailing heading) keep
    /// their order and pinned owners. A control drift over 2 px alone is
    /// F16's known flake (`failure_class`).
    func testL2ListCollapseRoundTripBothDirections() throws {
        let agent = try HostAgent.fromEnvironment()
        let position = Self.densePosition
        let reader = try launch(at: position, agent)
        let scale = reader.pixelScale()
        let limit = Self.shiftLimit
        // As test1: the first park after launch lands on estimated heights.
        try awayAndBack(reader, agent)

        // Control: away and back, SwiftUI only.
        let s0 = try reader.documentSnapshot()
        try awayAndBack(reader, agent)
        let s1 = try reader.documentSnapshot()
        let control = LabelShift(from: s0.tops, to: s1.tops, scale: scale)

        // Forward: ON at the park, OFF far away, back.
        reader.chooseRenderer(textKit2: true)
        reader.pause()
        let s2 = try reader.documentSnapshot()
        let forwardOn = LabelShift(from: s1.tops, to: s2.tops, scale: scale)
        let forwardParked = Self.trackable(s2.tops)
        try away(reader)
        let forwardAlive = forwardParked.filter { reader.element(labelled: $0).exists }
        reader.chooseRenderer(textKit2: false)
        try park(reader, agent)
        let s3 = try reader.documentSnapshot()
        let forward = LabelShift(from: s1.tops, to: s3.tops, scale: scale)

        // Reverse: TextKit 2 at the park, OFF there, ON far away, back.
        reader.chooseRenderer(textKit2: true)
        reader.pause()
        let s4 = try reader.documentSnapshot()
        let reverseOn = LabelShift(from: s3.tops, to: s4.tops, scale: scale)
        reader.chooseRenderer(textKit2: false)
        reader.pause()
        let s5 = try reader.documentSnapshot()
        let reverseOff = LabelShift(from: s4.tops, to: s5.tops, scale: scale)
        let reverseParked = Self.trackable(s5.tops)
        try away(reader)
        let reverseAlive = reverseParked.filter { reader.element(labelled: $0).exists }
        reader.chooseRenderer(textKit2: true)
        try park(reader, agent)
        let s6 = try reader.documentSnapshot()
        let reverse = LabelShift(from: s4.tops, to: s6.tops, scale: scale)
        attach(reader.app, "list-collapse-reverse-back")
        reader.app.terminate()

        let states: [(String, DocumentSnapshot, Bool)] = [
            ("control_start", s0, false), ("control_back", s1, false), ("forward_on", s2, true),
            ("forward_back", s3, false), ("reverse_on", s4, true), ("reverse_off", s5, false),
            ("reverse_back", s6, true),
        ]
        let badLandmarks = states.compactMap { state -> String? in
            let found = landmarks(position, state.1, textKit2: state.2)
            return found.ok ? nil : "\(state.0): \(found.figures)"
        }
        let inversions = LabelShift.orderInversions(from: s1.tops, to: s3.tops)
            + LabelShift.orderInversions(from: s4.tops, to: s6.tops)
        let switched = [forwardOn, forward, reverseOn, reverseOff, reverse]
        let rendererOK = control.common > 0 && switched.allSatisfy { $0.common > 0 && $0.maxPixels <= limit }
            && !forwardParked.isEmpty && !reverseParked.isEmpty && forwardAlive.isEmpty && reverseAlive.isEmpty
            && badLandmarks.isEmpty && inversions.isEmpty
        let pass = rendererOK && control.maxPixels <= limit
        try agent.record("6.2 list collapse round trip, both directions (\(position.name))", pass: pass, [
            "failure_class": !pass && rendererOK ? Self.controlDriftClass : "",
            "control_round_trip_px": Double(control.maxPixels), "control_labels": control.common,
            "forward_switch_on_px": Double(forwardOn.maxPixels), "forward_round_trip_px": Double(forward.maxPixels),
            "forward_worst": forward.worstLabel, "forward_labels": forward.common,
            "reverse_switch_on_px": Double(reverseOn.maxPixels), "reverse_switch_off_px": Double(reverseOff.maxPixels),
            "reverse_round_trip_px": Double(reverse.maxPixels), "reverse_worst": reverse.worstLabel,
            "reverse_labels": reverse.common,
            "forward_parked_labels": forwardParked.count, "forward_still_materialised_when_far": forwardAlive.count,
            "reverse_parked_labels": reverseParked.count, "reverse_still_materialised_when_far": reverseAlive.count,
            "order_inversions": inversions, "landmark_failures": badLandmarks,
            "scroll_away_pt": Double(CGFloat(Self.awayLegs) * Self.awayDistance),
        ])
        XCTAssertGreaterThan(control.common, 0, "no label survived the control round trip")
        XCTAssertLessThanOrEqual(control.maxPixels, limit, "the re-jump itself does not return exactly (F16 flake)")
        for (name, shift) in zip(["forward ON", "forward round trip", "reverse ON", "reverse OFF", "reverse round trip"],
                                 switched)
        {
            XCTAssertGreaterThan(shift.common, 0, "\(name): no common label")
            XCTAssertLessThanOrEqual(shift.maxPixels, limit, "\(name): \(shift.worstLabel) moved \(shift.maxPixels) px")
        }
        XCTAssertFalse(forwardParked.isEmpty || reverseParked.isEmpty, "no trackable label at the parked position")
        XCTAssertTrue(forwardAlive.isEmpty && reverseAlive.isEmpty,
                      "the parked list never left the render region: \(forwardAlive + reverseAlive)")
        XCTAssertTrue(inversions.isEmpty, "rows changed order: \(inversions)")
        XCTAssertTrue(badLandmarks.isEmpty, "landmarks: \(badLandmarks)")
    }

    /// 6.3 — rotation and Text Size on list-dense (`densePosition`), each
    /// arm in its own launch with `-fontSizeStep 0` (the popover never
    /// writes the persisted size). An away-and-back first gives distant
    /// lists (7,200 pt away) and nearby ones cached heights; then from the
    /// park: rotation round trip, return trip, Text Size 0→3 and a return
    /// trip at size 3, 3→0, return trip. Every drift's TextKit 2 excess over
    /// the SwiftUI arm ≤ 2 px; CPU settles ≤ 2 % within 5 s after the
    /// rotation, the size round trip and the last return; the size readout
    /// moved and came back to 100 %; landmarks hold at the final park.
    func testL3aListRotateAndSizeDriftMatchesSwiftUI() throws {
        let agent = try HostAgent.fromEnvironment()
        let position = Self.densePosition
        let legs = ["rotation", "rotation_return", "size3_return", "size_round_trip", "size_return"]
        var drift: [Bool: [String: LabelShift]] = [:]
        var arms: [String: Any] = [:]
        var settleOK = true, sizeOK = true, landmarksOK = true
        for textKit2 in [false, true] {
            let arm = textKit2 ? "textkit2" : "swiftui"
            let reader = try launch(at: position, agent, textKit2: textKit2, extra: ["-fontSizeStep", "0"])
            let scale = reader.pixelScale()
            try awayAndBack(reader, agent)
            let start = try reader.visibleLabels()

            try agent.request("rotate")
            reader.pause(2.5)
            try agent.request("rotate")
            reader.pause(2.5)
            let rotationSettle = try agent.cpuSettleSeconds()
            let rotated = try reader.visibleLabels()
            try awayAndBack(reader, agent)
            let rotatedReturn = try reader.visibleLabels()

            let larger = reader.stepTextSize(3)
            reader.pause(1.5)
            try park(reader, agent)
            let large = try reader.visibleLabels()
            try awayAndBack(reader, agent)
            let largeReturn = try reader.visibleLabels()
            let restored = reader.stepTextSize(-3)
            reader.pause(1.5)
            let sizeSettle = try agent.cpuSettleSeconds()
            let sized = try reader.visibleLabels()
            try awayAndBack(reader, agent)
            let final = try reader.documentSnapshot()
            let finalSettle = try agent.cpuSettleSeconds()
            attach(reader.app, "list-rotate-size-\(arm)")
            reader.app.terminate()

            let shifts = [
                "rotation": LabelShift(from: start, to: rotated, scale: scale),
                "rotation_return": LabelShift(from: start, to: rotatedReturn, scale: scale),
                "size3_return": LabelShift(from: large, to: largeReturn, scale: scale),
                "size_round_trip": LabelShift(from: start, to: sized, scale: scale),
                "size_return": LabelShift(from: start, to: final.tops, scale: scale),
            ]
            drift[textKit2] = shifts
            let found = landmarks(position, final, textKit2: textKit2)
            let settles = [rotationSettle, sizeSettle, finalSettle].map { $0.seconds ?? -1 }
            settleOK = settleOK && settles.allSatisfy { $0 >= 0 && $0 <= Self.maxSettleSeconds }
            sizeOK = sizeOK && larger != nil && larger != "100%" && restored == "100%"
            landmarksOK = landmarksOK && found.ok
            arms[arm] = [
                "drift_px": shifts.mapValues { Double($0.maxPixels) }, "labels": shifts.mapValues(\.common),
                "worst": shifts.mapValues { String($0.worstLabel.prefix(32)) },
                "cpu_settle_s": ["rotation": settles[0], "size": settles[1], "final": settles[2]],
                "cpu_samples": ["rotation": rotationSettle.samples, "size": sizeSettle.samples,
                                "final": finalSettle.samples],
                "size_readouts": [larger ?? "missing", restored ?? "missing"], "final_landmarks": found.figures,
            ]
        }
        let swiftUI = try XCTUnwrap(drift[false]), textKit2 = try XCTUnwrap(drift[true])
        var excess: [String: Double] = [:]
        var driftOK = true
        for leg in legs {
            guard let base = swiftUI[leg], let candidate = textKit2[leg] else {
                driftOK = false
                continue
            }
            let value = candidate.maxPixels - base.maxPixels
            excess[leg] = Double(value)
            driftOK = driftOK && base.common > 0 && candidate.common > 0 && value <= Self.shiftLimit
        }
        let pass = driftOK && settleOK && sizeOK && landmarksOK
        try agent.record("6.3 rotation + Text Size 0→3→0 with cached lists (\(position.name))", pass: pass, [
            "gated": "per leg TextKit 2 drift minus SwiftUI drift <= 2.01 px; CPU <= 2 % within 5 s; size restored; "
                + "final landmarks",
            "excess_px": excess, "arms": arms,
        ])
        XCTAssertTrue(driftOK, "TextKit 2 drifts beyond SwiftUI + 2 px: \(excess)")
        XCTAssertTrue(settleOK, "CPU did not settle within 5 s: \(arms)")
        XCTAssertTrue(sizeOK, "Text Size did not step and return to 100 %: \(arms)")
        XCTAssertTrue(landmarksOK, "landmarks at the final park: \(arms)")
    }

    /// 6.3 (state) — on lists-parity, which has no media, so this check is
    /// not exposed to kitchen-sink's pre-existing lazy-stack livelock that
    /// fails test4: a Find-in-Page query over list text (`LP-CONT`: a
    /// leader, nested leaders, continuation paragraphs, a trailing heading),
    /// an expand inside a list item and a root expand opened, and a task
    /// toggled (another left as the control); then ON, rotation round trip,
    /// Text Size 0→3→0, OFF, rotation round trip, Text Size 0→3→0 — search,
    /// expands, tasks and renderer checked after each step.
    func testL3bListStateSurvivesRotateSizeAndSwitch() throws {
        let agent = try HostAgent.fromEnvironment()
        let top = Self.parityTitle
        let reader = ReaderDriver(launching: [
            "-fixture", "lists-parity", "-rendererReset", "-rendererStats", "-fontSizeStep", "0",
        ])
        let app = reader.app
        reader.waitForRenderer("SwiftUI")
        XCTAssertTrue(reader.element(labelled: top).waitForExistence(timeout: 15), "lists-parity missing")

        // Search first: running it scrolls to the first match.
        let query = "LP-CONT"
        app.buttons["Find in Page"].tap()
        let field = app.textFields[ReaderDriver.Identifier.searchField]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "search field missing")
        field.tap()
        field.typeText(query + "\n")
        let counter = app.staticTexts[ReaderDriver.Identifier.searchCounter]
        XCTAssertTrue(counter.waitForExistence(timeout: 10), "search counter missing")
        reader.pause(1.5)
        let counterBefore = counter.label
        XCTAssertNotEqual(counterBefore, "0", "the query found nothing")

        // Expands: one is a trailing block of list item 0.10.2, one a root (0.17).
        let expands = [
            ("LP-EMBED-EXPAND expand inside a list item", "LP-EMBED-EXPAND-BODY"),
            ("LP-EXPAND lists inside an expand", "LP-IN-EXPAND-BULLET"),
        ]
        for (title, body) in expands {
            let button = app.buttons[title]
            XCTAssertTrue(reveal(button, reader, top: top), "\(title) never came into view")
            if (button.value as? String) != "Expanded" { button.tap() }
            XCTAssertTrue(reader.element(labelled: body).waitForExistence(timeout: 5), "\(title) did not open")
        }

        // Tasks: LP-TASK-A toggled, LP-TASK-C untouched (states persist per
        // document, so the wanted states are read, not assumed).
        let toggledTask = "LP-TASK-A undone task", otherTask = "LP-TASK-C nested undone task"
        XCTAssertTrue(reveal(reader.element(labelled: toggledTask), reader, top: top), "the task list never came into view")
        let box = try XCTUnwrap(reader.taskMarker(leader: toggledTask), "no checkbox on \(toggledTask)")
        let wantToggled = box.label == "Completed task" ? "Task" : "Completed task"
        box.tap()
        reader.pause()
        XCTAssertEqual(reader.taskMarker(leader: toggledTask)?.label, wantToggled, "the task toggle did not register")
        let wantOther = try XCTUnwrap(reader.taskMarker(leader: otherTask)?.label, "no checkbox on \(otherTask)")

        func observe(_ step: String, textKit2: Bool) -> [String: Any] {
            let searchKept = field.exists && (field.value as? String) == query && counter.label == counterBefore
            let expandsKept = expands.allSatisfy { title, body in
                let button = app.buttons[title]
                return reveal(button, reader, top: top) && (button.value as? String) == "Expanded"
                    && reader.element(labelled: body).exists
            }
            let tasksKept = reveal(reader.element(labelled: toggledTask), reader, top: top)
                && reader.taskMarker(leader: toggledTask)?.label == wantToggled
                && reader.taskMarker(leader: otherTask)?.label == wantOther
            let rendererKept = reader.isRenderer(textKit2 ? "TextKit 2" : "SwiftUI", timeout: 2)
            attach(app, "list-state-\(step)")
            return [
                "step": step, "search_kept": searchKept, "counter": counter.exists ? counter.label : "missing",
                "expands_kept": expandsKept, "tasks_kept": tasksKept, "renderer_kept": rendererKept,
                "pass": searchKept && expandsKept && tasksKept && rendererKept,
            ]
        }

        var observations: [[String: Any]] = []
        let steps = [("switch-on", true), ("rotation", true), ("size", true),
                     ("switch-off", false), ("rotation", false), ("size", false)]
        for (step, textKit2) in steps {
            switch step {
            case "switch-on", "switch-off":
                reader.chooseRenderer(textKit2: textKit2)
            case "rotation":
                try agent.request("rotate")
                reader.pause(2.5)
                try agent.request("rotate")
                reader.pause(2.5)
            default:
                reader.stepTextSize(3)
                reader.pause()
                reader.stepTextSize(-3)
            }
            reader.pause(1.5)
            observations.append(observe("\(step)-\(textKit2 ? "textkit2" : "swiftui")", textKit2: textKit2))
        }
        let pass = observations.allSatisfy { $0["pass"] as? Bool == true }
        try agent.record("6.3 search, expand and task state across switch, rotation and size (lists-parity)",
                         pass: pass, [
                             "query": query, "counter_before": counterBefore, "toggled_task_state": wantToggled,
                             "control_task_state": wantOther, "observations": observations,
                         ])
        XCTAssertTrue(pass, "state lost: \(observations)")
    }

    /// 6.4 — switch during a streamed list-heavy load: `-switchDuringLoad`
    /// flips to TextKit 2 on list-dense's first streamed chunk (chunks of 50
    /// of 600 blocks); after READY About shows 600 blocks and live TextKit 2
    /// rows, and `-scrollToFraction 0.9992` lands on the last root (`LD-599`,
    /// a decision list) whose four leaders are TextKit 2 rows owned by
    /// their own `PreparedListRow.id`; no root-owned TextKit 2 row exists
    /// (list-dense has no root text).
    func testL4aListSwitchDuringStreamingLoad() throws {
        let agent = try HostAgent.fromEnvironment()
        let reader = ReaderDriver(launching: [
            "-fixture", "list-dense", "-rendererReset", "-rendererStats", "-switchDuringLoad",
            "-scrollToFraction", "0.9992",
        ])
        reader.waitForRenderer("TextKit 2", timeout: 30)
        let tail = [
            ("LD-599 chunk spline schema spline batch", "0.599.0"), ("token expand ledger corpus spline", "0.599.1"),
            ("stream block token", "0.599.2"), ("render inline panel signal matrix", "0.599.3"),
        ]
        let landed = reader.textKit2Row(labelPrefix: "token expand ledger").waitForExistence(timeout: 30)
        reader.pause()
        let snapshot = try reader.documentSnapshot()
        let tailDrawn = tail.map { _, owner in "\(owner)=\(snapshot.textKit2Rows[owner] ?? "none")" }
        let tailOK = tail.allSatisfy { label, owner in snapshot.textKit2Rows[owner] == label }
        attach(reader.app, "list-switch-during-load-end")
        reader.openAbout()
        let switchField = reader.app.staticTexts[ReaderDriver.Identifier.loadSwitchBlocks]
        let readyField = reader.app.staticTexts[ReaderDriver.Identifier.loadReadyBlocks]
        let switched = switchField.waitForExistence(timeout: 5)
        let ready = readyField.waitForExistence(timeout: 5)
        let blocksAtSwitch = switched ? Int(switchField.label) ?? -1 : -1
        let blocksAtReady = ready ? Int(readyField.label) ?? -1 : -1
        let live = reader.readLiveTextKit2Rows(until: { $0 > 0 }, settled: true) ?? -1
        reader.closeAbout()
        let pass = landed && tailOK && blocksAtSwitch > 0 && blocksAtSwitch < 600 && blocksAtReady == 600
            && live > 0 && snapshot.rootOwnedRows == 0 && snapshot.listOwnedRows > 0
        try agent.record("6.4 switch during streaming list load (list-dense)", pass: pass, [
            "blocks_loaded_at_switch": blocksAtSwitch, "blocks_at_ready": blocksAtReady, "total_blocks": 600,
            "tail_rows": tailDrawn, "tail_rows_ok": tailOK, "live_tk2_rows": live,
            "root_owned_tk2_rows": snapshot.rootOwnedRows, "list_owned_tk2_rows": snapshot.listOwnedRows,
        ])
        XCTAssertTrue(landed, "the last root is not drawn by TextKit 2 rows")
        XCTAssertGreaterThan(blocksAtSwitch, 0, "the app never switched during the load")
        XCTAssertLessThan(blocksAtSwitch, 600, "the switch did not happen while blocks were still streaming")
        XCTAssertEqual(blocksAtReady, 600, "the load did not complete after the switch")
        XCTAssertTrue(tailOK, "tail rows: \(tailDrawn)")
        XCTAssertGreaterThan(live, 0, "no live TextKit 2 row after READY")
        XCTAssertEqual(snapshot.rootOwnedRows, 0, "root-owned TextKit 2 rows in a document with no root text")
        XCTAssertGreaterThan(snapshot.listOwnedRows, 0, "no list-owned TextKit 2 row")
    }

    /// 6.4 (replacement) — a replacement document with colliding structural
    /// IDs: list-dense and lists-parity share list row owners (`0.1.0`,
    /// `0.1.1`, …). One TextKit 2 launch on the fixture list opens
    /// list-dense, goes back, opens lists-parity, goes back and reopens
    /// list-dense. Gated: owners seen in both documents exist and show the
    /// current document's text; neither shows the other's sentinels (`LD-`,
    /// `LP-`); list-dense's owners show their first-visit labels again; and
    /// lists-parity's top screen lies within 2 px, measured from its title,
    /// of a direct `-fixture lists-parity -textkit2` launch (no cached
    /// height leaked through a colliding owner). In-document stable-ID
    /// replacement has no UI trigger in the demo (`-searchUpdates` replaces
    /// a root paragraph, then the app exits), so it is not exercised here.
    func testL4bListCollidingIDsReplacementDocument() throws {
        let agent = try HostAgent.fromEnvironment()
        let title = Self.parityTitle
        let direct = ReaderDriver(launching: ["-fixture", "lists-parity", "-rendererReset", "-rendererStats", "-textkit2"])
        direct.waitForRenderer("TextKit 2")
        XCTAssertTrue(direct.element(labelled: title).waitForExistence(timeout: 15), "lists-parity missing")
        direct.pause()
        let reference = try direct.documentSnapshot()
        let scale = direct.pixelScale()
        direct.app.terminate()

        let reader = ReaderDriver(launching: ["-rendererReset", "-rendererStats", "-textkit2"])
        func open(_ fixture: String, until proof: XCUIElement) throws -> DocumentSnapshot {
            reader.openFixture(fixture)
            reader.waitForRenderer("TextKit 2")
            XCTAssertTrue(proof.waitForExistence(timeout: 30), "\(fixture) did not open on TextKit 2")
            reader.pause()
            return try reader.documentSnapshot()
        }
        let dense = try open("list-dense", until: reader.textKit2Row(labelPrefix: "LD-000"))
        reader.goBack()
        let parity = try open("lists-parity", until: reader.element(labelled: title))
        attach(reader.app, "colliding-ids-lists-parity")
        reader.goBack()
        let denseAgain = try open("list-dense", until: reader.textKit2Row(labelPrefix: "LD-000"))
        reader.app.terminate()

        /// Owners in both snapshots, and those drawing `old`'s text in `new`.
        func reused(_ old: DocumentSnapshot, _ new: DocumentSnapshot) -> (shared: [String], stale: [String]) {
            let shared = Set(old.textKit2Rows.keys).intersection(new.textKit2Rows.keys).sorted()
            return (shared, shared.filter { old.textKit2Rows[$0] == new.textKit2Rows[$0] })
        }
        func labels(_ snapshot: DocumentSnapshot, prefix: String) -> [String] {
            (Array(snapshot.textKit2Rows.values) + snapshot.visible.map(\.label)).filter { $0.contains(prefix) }
        }
        let intoParity = reused(dense, parity), intoDense = reused(parity, denseAgain)
        let foreignInParity = labels(parity, prefix: "LD-"), foreignInDense = labels(denseAgain, prefix: "LP-")
        let revisited = Set(dense.textKit2Rows.keys).intersection(denseAgain.textKit2Rows.keys)
        let changedOnReturn = revisited.filter { dense.textKit2Rows[$0] != denseAgain.textKit2Rows[$0] }.sorted()
        let geometry = LabelShift(from: LabelShift.relative(reference.tops, to: title) ?? [:],
                                  to: LabelShift.relative(parity.tops, to: title) ?? [:], scale: scale)
        let pass = !intoParity.shared.isEmpty && intoParity.stale.isEmpty && !intoDense.shared.isEmpty
            && intoDense.stale.isEmpty && foreignInParity.isEmpty && foreignInDense.isEmpty && !revisited.isEmpty
            && changedOnReturn.isEmpty && geometry.common > 0 && geometry.maxPixels <= Self.shiftLimit
        try agent.record("6.4 replacement document with colliding IDs (list-dense ↔ lists-parity)", pass: pass, [
            "shared_owners_dense_to_parity": intoParity.shared.prefix(12).map { $0 },
            "stale_in_parity": intoParity.stale, "shared_owners_parity_to_dense": intoDense.shared.count,
            "stale_in_dense": intoDense.stale, "foreign_labels_in_parity": foreignInParity.prefix(8).map { $0 },
            "foreign_labels_in_dense": foreignInDense.prefix(8).map { $0 }, "dense_owners_revisited": revisited.count,
            "dense_owners_changed_on_return": changedOnReturn,
            "parity_vs_direct_launch_px": Double(geometry.maxPixels), "parity_vs_direct_labels": geometry.common,
            "parity_vs_direct_worst": geometry.worstLabel,
            "in_document_stable_id_replacement": "not exercised: no UI trigger in the demo",
        ])
        XCTAssertFalse(intoParity.shared.isEmpty || intoDense.shared.isEmpty, "no colliding owner was drawn twice")
        XCTAssertTrue(intoParity.stale.isEmpty && intoDense.stale.isEmpty,
                      "owners kept the other document's text: \(intoParity.stale + intoDense.stale)")
        XCTAssertTrue(foreignInParity.isEmpty && foreignInDense.isEmpty,
                      "labels leaked across documents: \(foreignInParity + foreignInDense)")
        XCTAssertTrue(changedOnReturn.isEmpty, "list-dense owners changed text on return: \(changedOnReturn)")
        XCTAssertGreaterThan(geometry.common, 0, "no common label with the direct launch")
        XCTAssertLessThanOrEqual(geometry.maxPixels, Self.shiftLimit,
                                 "\(geometry.worstLabel) sits \(geometry.maxPixels) px off the direct launch")
    }

    /// 6.5 — test5/test6's fling, Home/lock/switcher ×5 and 60 s soak on
    /// list-dense, with list-owned TextKit 2 rows after the thrash.
    func testL5aFlingThrashSoakListDenseSwiftUI() throws {
        try flingThrashSoak(textKit2: false, fixture: "list-dense", landmark: "LD-000", listProof: true)
    }

    func testL5bFlingThrashSoakListDenseTextKit2() throws {
        try flingThrashSoak(textKit2: true, fixture: "list-dense", landmark: "LD-000", listProof: true)
    }

    /// 6.6 — test7's rule-B design (four launches, alternating, medians of
    /// two; test7 itself stays on stress-5k) at list-dense three 300 pt
    /// drags down, where every root is a list. Also gated: all four series
    /// show the same ON count (the control rebuilds exactly the leaves
    /// TextKit 2 draws, list leaders and trailing text included), and F14 —
    /// after each TextKit 2 series one more ON pick's count exceeds the
    /// root-owned TextKit 2 rows of an accessibility snapshot (the
    /// root-only eligible count; zero here) with list-owned rows present,
    /// while the control's extra pick shows its rebuilt rows and no
    /// TextKit 2 row.
    func testL6TwentyFlipsListDense() throws {
        let agent = try HostAgent.fromEnvironment()
        let (control, flips) = twentyFlipDesign(agent, fixture: "list-dense", landmark: "LD-000", census: true)
        let controlMedian = Self.median(control.map(\.growth))
        let flipMedian = Self.median(flips.map(\.growth))
        let excess = flipMedian - controlMedian
        let rowsOK = (control + flips).allSatisfy(\.rowsOK)
        let onCounts = (control + flips).map { $0.on.first ?? -1 }
        let matched = Set(onCounts).count == 1
        let listProof = flips.allSatisfy {
            $0.censusListOwned > 0 && ($0.on.first ?? 0) > $0.censusRootOwned && $0.censusRows == $0.on.first
        }
        let controlCensus = control.allSatisfy {
            $0.censusRootOwned == 0 && $0.censusListOwned == 0 && $0.censusRows == $0.on.first
        }
        let pass = rowsOK && matched && listProof && controlCensus && excess <= Self.maxGrowthKB
        try agent.record("6.6 twenty flips (list-dense)", pass: pass, [
            "gated_metric": "median over 2 runs of raw settled phys_footprint growth over twenty switches, "
                + "TextKit 2 minus a control that rebuilds the same rows as SwiftUI (<= 5,120 KB; no pressure relief); "
                + "equal ON counts across arms; F14 census",
            "control_growth_median_kb": controlMedian, "flips_growth_median_kb": flipMedian,
            "flips_minus_control_kb": excess, "first_on_counts": onCounts,
            "control_runs": control.map(\.figures), "flip_runs": flips.map(\.figures),
        ])
        for (index, series) in (control + flips).enumerated() {
            XCTAssertTrue(series.rowsOK, "series \(index + 1) (\(series.control ? "control" : "TextKit 2")): "
                + "ON \(series.on) / other kind \(series.onOther), OFF \(series.off)")
        }
        XCTAssertTrue(matched, "control and TextKit 2 ON counts differ: \(onCounts)")
        XCTAssertTrue(listProof, "F14: TextKit 2 census \(flips.map(\.figures))")
        XCTAssertTrue(controlCensus, "control census: \(control.map(\.figures))")
        XCTAssertLessThanOrEqual(excess, Self.maxGrowthKB,
                                 "flips grew \(flipMedian) KB vs the control's \(controlMedian) KB (medians; excess \(excess) KB)")
    }

    // MARK: - List positions and landmarks

    /// A parked list position: `-scrollToFraction <fraction>` lands on the
    /// block before the measured list (`arrival` proves it), and `park`'s
    /// 100 pt drag brings the list into view. `rows` are labels top to
    /// bottom with their TextKit 2 owners (`PreparedListRow.id` for a
    /// leader, the node path for trailing text; nil: not pinned); `marker`
    /// is the accessible ordered marker on the first row's line; `heading`
    /// (one of `rows`) is a trailing heading below a multiline nested list.
    private struct ListPosition {
        let name: String
        let fixture: String
        let fraction: String
        let arrival: String
        let marker: String
        let heading: String
        let rows: [(label: String, owner: String?)]
        var leader: String { rows[0].label }
    }

    /// lists-parity block 9 (`LP-S5`, ≈ 1,600 pt down) → ordered list
    /// `0.10`, item 2: leader (`2.`), two nested bullets, a continuation
    /// paragraph, a nested bullet, a second continuation paragraph and a
    /// trailing heading; root headings nearby (a mixed viewport for F14).
    private static let parityPosition = ListPosition(
        name: "lists-parity @ LP-CONT-LEADER", fixture: "lists-parity", fraction: "0.452", arrival: "LP-S5",
        marker: "2.", heading: "LP-CONT-HEADING trailing heading after a nested list",
        rows: [
            ("LP-CONT-LEADER item with nested lists and continuations", "0.10.1"),
            ("LP-CONT-NESTED-1A", "0.10.1.1.0"),
            ("LP-CONT-NESTED-1B", "0.10.1.1.1"),
            ("LP-CONT-PARA-1 continuation paragraph after the first nested list", "0.10.1.2"),
            ("LP-CONT-NESTED-2A", "0.10.1.3.0"),
            ("LP-CONT-PARA-2 second continuation paragraph", "0.10.1.4"),
            ("LP-CONT-HEADING trailing heading after a nested list", "0.10.1.5"),
        ]
    )

    /// list-dense block 288 (`LD-288`) → root 289 (≈ 63,000 pt down): the
    /// ordered leader `1.` (with a run background), a nested bullet, a
    /// continuation paragraph, a trailing level-5 heading, and a linked
    /// second leader (TextKit 1-backed; its owner is not pinned).
    private static let densePosition = ListPosition(
        name: "list-dense @ LD-289", fixture: "list-dense", fraction: "0.4808", arrival: "LD-288",
        marker: "1.", heading: "scroll chunk media",
        rows: [
            ("LD-289 ledger atlas buffer expand buffer corpus", "0.289.0"),
            ("media table swift", "0.289.0.1.0"),
            ("kernel glyph vector atlas block", "0.289.0.2"),
            ("scroll chunk media", "0.289.0.3"),
            ("signal vector render", nil),
        ]
    )

    private static let parityTitle = "LP-S1 Nesting: alternating bullet and ordered ancestry"
    private static let awayLegs = 12
    private static let awayDistance: CGFloat = 600

    /// Launches `position.fixture` (SwiftUI unless `textKit2`) and parks at
    /// `position` with its leader in view.
    private func launch(at position: ListPosition, _ agent: HostAgent, textKit2: Bool = false,
                        extra: [String] = []) throws -> ReaderDriver
    {
        var arguments = ["-fixture", position.fixture, "-rendererReset", "-rendererStats",
                         "-scrollToFraction", position.fraction] + extra
        if textKit2 { arguments.append("-textkit2") }
        let reader = ReaderDriver(launching: arguments)
        reader.waitForRenderer(textKit2 ? "TextKit 2" : "SwiftUI")
        XCTAssertTrue(reader.element(labelPrefix: position.arrival).waitForExistence(timeout: 30),
                      "\(position.fixture) did not land on \(position.arrival)")
        try park(reader, agent)
        XCTAssertTrue(reader.waitUntilVisible(reader.element(labelled: position.leader)),
                      "\(position.leader) is not in view at the parked position")
        return reader
    }

    /// Twelve 600 pt drags toward the end (7,200 pt: far past the render
    /// region).
    private func away(_ reader: ReaderDriver) throws {
        for _ in 0 ..< Self.awayLegs {
            reader.drag(by: Self.awayDistance)
        }
        reader.pause()
    }

    private func awayAndBack(_ reader: ReaderDriver, _ agent: HostAgent) throws {
        try away(reader)
        try park(reader, agent)
    }

    /// Labels distinctive enough to prove a row is gone 7,200 pt away:
    /// list-dense's `LD-` leaders and test1's long-label rule.
    private static func trackable(_ tops: [String: CGFloat]) -> [String] {
        tops.keys.filter { $0.hasPrefix("LD-") || $0.count >= 24 }
    }

    /// A position's landmarks in one snapshot.
    private struct Landmarks {
        /// Expected rows not uniquely visible.
        var missing: [String] = []
        /// Rows drawn by the wrong row: under TextKit 2 a pinned owner must
        /// draw its row; under SwiftUI no row is a TextKit 2 row.
        var wrongOwners: [String] = []
        /// Visible rows out of the expected top-to-bottom order.
        var outOfOrder = false
        /// Marker top minus leader top, points (nil: marker not found).
        var markerOffset: CGFloat?

        var ok: Bool { missing.isEmpty && wrongOwners.isEmpty && !outOfOrder && markerOffset != nil }
        var figures: [String: Any] {
            ["missing": missing.map { String($0.prefix(32)) }, "wrong_owners": wrongOwners,
             "out_of_order": outOfOrder, "marker_offset_pt": markerOffset.map { Double($0) } ?? -999]
        }
    }

    private func landmarks(_ position: ListPosition, _ snapshot: DocumentSnapshot, textKit2: Bool) -> Landmarks {
        let tops = snapshot.tops, owners = snapshot.owners
        var result = Landmarks()
        var lastTop = -CGFloat.infinity
        for (label, owner) in position.rows {
            guard let top = tops[label] else {
                result.missing.append(label)
                continue
            }
            if top <= lastTop { result.outOfOrder = true }
            lastTop = top
            let drawnBy = owners[label]
            if textKit2 ? owner != nil && drawnBy != owner : drawnBy != nil {
                result.wrongOwners.append("\(label.prefix(24))=\(drawnBy ?? "none")")
            }
        }
        if let marker = snapshot.markerTop(position.marker, leader: position.leader),
           let leader = tops[position.leader]
        {
            result.markerOffset = marker - leader
        }
        return result
    }

    // MARK: - Helpers

    /// Scrolls the document until `element` is fully in view: back to the
    /// top (`top`, the document's first label: kitchen-sink's title by
    /// default) first, then down a screen at a time.
    private func reveal(_ element: XCUIElement, _ reader: ReaderDriver, top: String = "ADF Kitchen Sink") -> Bool {
        if reader.isVisible(element) { return true }
        let scroll = reader.app.scrollViews.firstMatch
        let title = reader.element(labelled: top)
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
