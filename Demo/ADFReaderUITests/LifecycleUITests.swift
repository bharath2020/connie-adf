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
///
/// Known baseline (not a list verdict): on the SwiftUI arm, scrolling
/// lists-parity's block 0.10 (an ordered list whose item 0.10.2 holds a code
/// block, panel, quote, expand and table) spins SwiftUI's lazy-stack layout
/// and then blocks accessibility, so XCTest reports "App event loop idle
/// notification not received" / "Timed out while evaluating UI query". It
/// reproduces on main + fixtures (arm A, 2026-11-11) — issue #8's class. A
/// `testL1`/`testL3b` failure with only that symptom is classified
/// baseline; `testL1b` and `testL3c` carry the same assertions on the
/// table-free `list-dense`, so a run still produces list evidence.
///
/// `testC1`…`testC6` are PR 3's code-block additions (PR 3 plan §6), on
/// `code-dense`: 600 top-level code blocks and nothing else, so no table
/// and no media. Block `i` has id `0.<i>` and its code starts with the
/// line `// CD-<iii>`, so a code text's accessibility label names its
/// block, and a TextKit 2 row drawing it must be `tk2-row:0.<i>` (the
/// owner of a code row has the root form; `DocumentSnapshot.codeOwnedRows`
/// tells code rows from root text by the block's horizontal scroll view).
/// Which blocks TextKit 2 draws is decided at view time (the canvas
/// admission caps keep the largest on SwiftUI), so these tests pin no
/// block: they require a TextKit 2 code row on screen, every TextKit 2 row
/// to be a code row drawing its own block, and none on SwiftUI. Limits,
/// the no-switch SwiftUI controls and `failure_class` are tests 1–8's and
/// L1–L6's. OFF is checked in two steps (stack doc §6.7): no `tk2-row`
/// right after the switch with at most `unshownRowAllowance` rows still
/// counted, then none counted once the lazy stack has come back past them.
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
    /// Rows SwiftUI's lazy stack builds but never shows (prefetch below the
    /// viewport, the document's last row), which About's live TextKit 2
    /// count includes and the rows on screen do not (p7-retain-diag).
    private static let unshownRowAllowance = 3

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
    /// `testC5a`/`testC5b` run it on code-dense with `codeProof`: after the
    /// vertical fling's CPU check, a horizontal fling inside a wide code
    /// block and the same CPU check (`codeHorizontalFling`); after the
    /// thrash the TextKit 2 arm must still draw code rows and nothing but
    /// code rows, the SwiftUI arm no TextKit 2 row.
    private func flingThrashSoak(textKit2: Bool, fixture: String = "stress-5k", landmark: String = "Section 0:",
                                 listProof: Bool = false, codeProof: Bool = false) throws
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
        var horizontal: CodeFling?
        if codeProof {
            horizontal = try codeHorizontalFling(reader, agent, textKit2: textKit2)
        }

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
        if codeProof {
            let census = try reader.documentSnapshot()
            rendererKept = rendererKept && (textKit2
                ? census.codeOwnedRows > 0 && census.rootOwnedRows == 0 && census.listOwnedRows == 0
                : census.textKit2Rows.isEmpty)
            listRows = ["code_owned_tk2_rows_after_thrash": census.codeOwnedRows,
                        "root_owned_tk2_rows_after_thrash": census.rootOwnedRows,
                        "list_owned_tk2_rows_after_thrash": census.listOwnedRows]
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
        let horizontalOK = horizontal.map { $0.ok(textKit2: textKit2, maxSettle: Self.maxSettleSeconds) } ?? true
        let pass = flingOK && thrashOK && leftForeground && growth <= Self.maxGrowthKB && cpuMean <= 2.0
            && rendererKept && horizontalOK
        let check = codeProof ? "C5" : fixture == "stress-5k" ? "3.5" : "6.5"
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
        if let horizontal {
            figures.merge(horizontal.figures) { first, _ in first }
        }
        try agent.record("\(check) fling + thrash + 60 s soak (\(fixture), \(arm))", pass: pass, figures)
        XCTAssertTrue(flingOK, "CPU did not settle within 5 s after the fling: \(fling.samples)")
        XCTAssertTrue(horizontalOK, "horizontal fling inside a wide code block: \(horizontal?.figures ?? [:])")
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
                                  census: Bool = false, code: Bool = false)
        -> (control: [TwentyFlipSeries], flips: [TwentyFlipSeries])
    {
        var control: [TwentyFlipSeries] = [], flips: [TwentyFlipSeries] = []
        for run in 1 ... 2 {
            for arm in run == 1 ? [true, false] : [false, true] {
                let series = twentyFlips(agent, control: arm, fixture: fixture, landmark: landmark, census: census,
                                         code: code)
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
        /// With `census`, one more ON pick after the measured series: About's
        /// count for the arm (`censusRows`: rebuilt rows, or `tk2Live`), and
        /// the TextKit 2 row elements of an accessibility snapshot
        /// (`censusAXRows`, owners merged) split by owner level (F14).
        /// Taken after the last footprint, so it never touches the gated
        /// growth.
        var censusRows = -1, censusAXRows = -1, censusRootOwned = -1, censusListOwned = -1
        /// Live rows an OFF pick may still count (0 unless the series is a
        /// TextKit 2 code series: step 1 of the two-step OFF check, stack
        /// doc §6.7 — rows the lazy stack built and never showed).
        var offAllowance = 0
        /// A code series (`code`) only. About's live code-row count after
        /// each ON pick and each OFF pick; whether a `tk2-row` was still in
        /// the accessibility tree after each OFF pick (1) or not (0); the
        /// code-owned rows of the census and About's code count there; and
        /// the two-step OFF check that ends the series, after the last
        /// footprint (`codeOffCheck`).
        var onCode: [Int] = [], offCode: [Int] = [], offInTree: [Int] = []
        var censusCodeOwned = -1, censusCodeRows = -1
        var offCheck: CodeOffCheck?

        /// Every ON pick showed the same nonzero count of its kind and none
        /// of the other; every OFF pick, none of either (at most
        /// `offAllowance`, when that is set).
        var rowsOK: Bool {
            !on.isEmpty && on.allSatisfy { $0 > 0 && $0 == on[0] }
                && onOther.allSatisfy { $0 == 0 } && off.allSatisfy { $0 >= 0 && $0 <= offAllowance }
        }

        /// A code series: under TextKit 2 every ON pick counted code rows,
        /// no more than its live rows, and every OFF pick at most
        /// `offAllowance`; the control never counted one. No OFF pick left
        /// a `tk2-row` in the tree, and the closing OFF check passed.
        var codeRowsOK: Bool {
            let counted = control
                ? (onCode + offCode).allSatisfy { $0 == 0 }
                : onCode.count == on.count && zip(onCode, on).allSatisfy { $0 > 0 && $0 <= $1 }
                    && offCode.allSatisfy { $0 >= 0 && $0 <= offAllowance }
            return counted && !onCode.isEmpty && !offInTree.isEmpty && offInTree.allSatisfy { $0 == 0 }
                && offCheck?.ok == true
        }
    }

    /// One launch, one series: twenty switches alternating ON/OFF through
    /// the renderer menu — rebuilding as SwiftUI (`control`) or as TextKit 2
    /// — About read after every pick, a settled footprint before the first
    /// and after every OFF (ten, the last closing the series). With `code`
    /// (C6) each About read also takes the live code-row count, each OFF
    /// pick is checked for a `tk2-row` left in the tree and may still count
    /// `unshownRowAllowance` live rows under TextKit 2, and the series ends
    /// with the retraced OFF check — the control makes the same queries.
    private func twentyFlips(_ agent: HostAgent, control: Bool, fixture: String, landmark: String,
                             census: Bool, code: Bool = false) -> TwentyFlipSeries
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
        series.offAllowance = code && !control ? Self.unshownRowAllowance : 0
        let offAllowance = series.offAllowance
        /// One About visit: the arm's count waited for, the other kind's,
        /// and with `code` the live code-row count.
        func aboutRows(until condition: (Int) -> Bool, settled: Bool) -> (textKit2: Int?, control: Int?, code: Int?) {
            if code {
                return reader.liveRowsAndCode(control: control, until: condition, settled: settled)
            }
            let rows = reader.liveRows(control: control, until: condition, settled: settled)
            return (rows.textKit2, rows.control, nil)
        }
        do {
            let start = try agent.settledFootprintKB()
            var settled: [Int] = []
            for flip in 1 ... 20 {
                let isOn = flip % 2 == 1
                reader.chooseRenderer(textKit2: isOn)
                if code, !isOn {
                    series.offInTree.append(reader.waitForDisappearance(of: reader.anyTextKit2Row, timeout: 5) ? 0 : 1)
                }
                let first = series.on.first
                let rows = aboutRows(until: { count in
                    isOn ? count > 0 && (first == nil || count == first) : count <= offAllowance
                }, settled: isOn)
                let waited = (control ? rows.control : rows.textKit2) ?? -1
                let other = (control ? rows.textKit2 : rows.control) ?? -1
                if isOn {
                    series.on.append(waited)
                    series.onOther.append(other)
                    if code { series.onCode.append(rows.code ?? -1) }
                } else {
                    series.off.append(contentsOf: [waited, other])
                    if code { series.offCode.append(rows.code ?? -1) }
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
                var points: [[String: Any]] = []
                // At the series viewport, then 600 pt further and back: About's
                // live count against the accessibility census at each.
                for (step, drag) in [("series viewport", 0), ("600 pt on", 600), ("back", -600)] {
                    if drag != 0 {
                        reader.drag(by: CGFloat(drag))
                        reader.pause(1.5)
                    }
                    let rows = aboutRows(until: {
                        $0 > 0 && (drag != 0 || first == nil || $0 == first)
                    }, settled: true)
                    let snapshot = try reader.documentSnapshot()
                    let count = (control ? rows.control : rows.textKit2) ?? -1
                    if drag == 0 {
                        series.censusRows = count
                        series.censusAXRows = snapshot.textKit2Nodes
                        series.censusRootOwned = snapshot.rootOwnedRows
                        series.censusListOwned = snapshot.listOwnedRows
                        if code {
                            series.censusCodeOwned = snapshot.codeOwnedRows
                            series.censusCodeRows = rows.code ?? -1
                        }
                    }
                    let byRoot = Dictionary(grouping: snapshot.textKit2Rows.keys) {
                        $0.split(separator: ".").dropFirst().first.map(String.init) ?? $0
                    }.mapValues(\.count)
                    var point: [String: Any] = [
                        "step": step, "about_rows": count, "about_tk2_live": rows.textKit2 ?? -1,
                        "ax_tk2_elements": snapshot.textKit2Nodes, "ax_tk2_owners": snapshot.textKit2Rows.count,
                        "ax_root_owned": snapshot.rootOwnedRows, "ax_list_owned": snapshot.listOwnedRows,
                        "ax_owners_per_root": byRoot,
                    ]
                    if code {
                        point["about_tk2_code_live"] = rows.code ?? -1
                        point["ax_code_owned"] = snapshot.codeOwnedRows
                    }
                    points.append(point)
                }
                series.figures["census_after_series"] = points
            }
            if code {
                // Step 2 of the OFF check, after the last footprint (it
                // never touches the gated growth): OFF from a TextKit 2
                // viewport, then 600 pt on and back, so the lazy stack
                // comes back past the rows it built and never showed.
                if !census { reader.chooseRenderer(textKit2: true) }
                let offCheck = try codeOffCheck(reader, allowance: offAllowance)
                series.offCheck = offCheck
                series.figures["code_rows"] = [
                    "on_code_rows": series.onCode, "off_code_rows": series.offCode,
                    "off_tk2_rows_in_tree": series.offInTree, "off_allowance": offAllowance,
                    "closing_off_check": offCheck.figures,
                ] as [String: Any]
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

    /// 6.1 — five round trips (ON, OFF) at a parked list position:
    /// `parityPosition` here (lists-parity; a stall is the class baseline,
    /// see the type comment), `densePosition` in `testL1b`. Gated:
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
        let failures = try fiveRoundTrips(at: Self.parityPosition, HostAgent.fromEnvironment())
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
    }

    /// 6.1 on the table-free list-dense (`densePosition`): `testL1`'s gates.
    func testL1bListFiveRoundTripsListDense() throws {
        let failures = try fiveRoundTrips(at: Self.densePosition, HostAgent.fromEnvironment())
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
    /// down), with a label-anchored return: the re-jump park does not land
    /// repeatably there (the 1e778df shakedown's SwiftUI-only control came
    /// back 1,372 px off), so "back" is `returnTo` and a return trip is
    /// measured from the leader (every label's top minus the leader's).
    /// A no-switch control trip first; forward — ON at the start, twelve
    /// 600 pt drags away until the list's rows have left the render region,
    /// OFF there, back; reverse — ON then OFF at the start, away, ON there,
    /// back, so the list rematerialises naturally as TextKit 2 rows. Each
    /// return ≤ 2 px from its start (control and forward: the SwiftUI start;
    /// reverse: the TextKit 2 start); every in-place switch moves labels
    /// ≤ 2 px; no label pair changes order across either trip; landmarks
    /// (leader, marker, nested row, continuation paragraph, trailing
    /// heading) keep their order and pinned owners. A control drift over
    /// 2 px alone is F16's known flake (`failure_class`).
    func testL2ListCollapseRoundTripBothDirections() throws {
        let agent = try HostAgent.fromEnvironment()
        let position = Self.densePosition
        let reader = try launch(at: position, agent)
        let scale = reader.pixelScale()
        let limit = Self.shiftLimit
        let top = reader.element(labelled: position.leader).frame.minY
        var returns: [Double] = []
        func back() throws {
            XCTAssertTrue(try returnTo(position, top: top, reader), "the leader is not back in view")
            returns.append(Double(reader.element(labelled: position.leader).frame.minY - top))
        }
        func anchored(_ from: DocumentSnapshot, _ to: DocumentSnapshot) -> LabelShift {
            LabelShift(from: LabelShift.relative(from.tops, to: position.leader) ?? [:],
                       to: LabelShift.relative(to.tops, to: position.leader) ?? [:], scale: scale)
        }
        // One trip first, as test1: it measures the rows on the way.
        try away(reader)
        try back()

        // Control: away and back, SwiftUI only.
        let s0 = try reader.documentSnapshot()
        try away(reader)
        try back()
        let s1 = try reader.documentSnapshot()
        let control = anchored(s0, s1)

        // Forward: ON in place, OFF far away, back.
        reader.chooseRenderer(textKit2: true)
        reader.pause()
        let s2 = try reader.documentSnapshot()
        let forwardOn = LabelShift(from: s1.tops, to: s2.tops, scale: scale)
        let forwardParked = Self.trackable(s2.tops)
        try away(reader)
        let forwardAlive = forwardParked.filter { reader.element(labelled: $0).exists }
        reader.chooseRenderer(textKit2: false)
        try back()
        let s3 = try reader.documentSnapshot()
        let forward = anchored(s1, s3)

        // Reverse: TextKit 2 in place, OFF there, ON far away, back.
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
        try back()
        let s6 = try reader.documentSnapshot()
        let reverse = anchored(s4, s6)
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
        let rendererOK = returns.count == 4 && control.common > 0
            && switched.allSatisfy { $0.common > 0 && $0.maxPixels <= limit }
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
            "measure": "round trips: label tops relative to the leader after a label-anchored return; "
                + "switches in place: absolute tops",
            "return_leader_offsets_pt": returns,
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
    /// writes the persisted size). A trip away first gives distant lists
    /// (7,200 pt away) and nearby ones cached heights; then: rotation round
    /// trip, return trip, Text Size 0→3 and a return trip at size 3, 3→0,
    /// return trip. Returns are label-anchored (`returnTo`, see 6.2) and
    /// measured from the leader, as is the in-place size round trip. The
    /// rotation round trip moves list-dense's viewport ~1,800–2,000 px in
    /// both arms (the leader leaves the screen: a renderer-agnostic
    /// re-anchor after the width change), so test2's absolute in-place
    /// drift is recorded per arm (`rotation_displacement_px`) but not
    /// gated; `rotation_layout` aligns the leader back first and is gated.
    /// Every gated leg's TextKit 2 excess over the SwiftUI arm ≤ 2 px; CPU settles
    /// ≤ 2 % within 5 s after the rotation, the size round trip and the last
    /// return; the size readout moved and came back to 100 %; landmarks hold
    /// at the end.
    func testL3aListRotateAndSizeDriftMatchesSwiftUI() throws {
        let agent = try HostAgent.fromEnvironment()
        let position = Self.densePosition
        let legs = ["rotation_layout", "rotation_return", "size3_return", "size_round_trip", "size_return"]
        var drift: [Bool: [String: LabelShift]] = [:]
        var arms: [String: Any] = [:]
        var settleOK = true, sizeOK = true, landmarksOK = true, returnsOK = true
        for textKit2 in [false, true] {
            let arm = textKit2 ? "textkit2" : "swiftui"
            let reader = try launch(at: position, agent, textKit2: textKit2, extra: ["-fontSizeStep", "0"])
            let scale = reader.pixelScale()
            let top = reader.element(labelled: position.leader).frame.minY
            var returned: [Bool] = []
            func trip() throws {
                try away(reader)
                returned.append(try returnTo(position, top: top, reader))
            }
            func anchored(_ from: [String: CGFloat], _ to: [String: CGFloat]) -> LabelShift {
                LabelShift(from: LabelShift.relative(from, to: position.leader) ?? [:],
                           to: LabelShift.relative(to, to: position.leader) ?? [:], scale: scale)
            }
            try trip()
            let start = try reader.visibleLabels()

            try agent.request("rotate")
            reader.pause(2.5)
            try agent.request("rotate")
            reader.pause(2.5)
            let rotationSettle = try agent.cpuSettleSeconds()
            let rotated = try reader.visibleLabels()
            returned.append(try align(position, top: top, reader))
            let rotatedAligned = try reader.visibleLabels()
            try trip()
            let rotatedReturn = try reader.visibleLabels()

            let larger = reader.stepTextSize(3)
            reader.pause(1.5)
            returned.append(try align(position, top: top, reader))
            let large = try reader.visibleLabels()
            try trip()
            let largeReturn = try reader.visibleLabels()
            let restored = reader.stepTextSize(-3)
            reader.pause(1.5)
            let sizeSettle = try agent.cpuSettleSeconds()
            returned.append(try align(position, top: top, reader))
            let sized = try reader.visibleLabels()
            try trip()
            let final = try reader.documentSnapshot()
            let finalSettle = try agent.cpuSettleSeconds()
            attach(reader.app, "list-rotate-size-\(arm)")
            reader.app.terminate()

            let displacement = LabelShift(from: start, to: rotated, scale: scale)
            let shifts = [
                "rotation_layout": anchored(start, rotatedAligned),
                "rotation_return": anchored(start, rotatedReturn),
                "size3_return": anchored(large, largeReturn),
                "size_round_trip": anchored(start, sized),
                "size_return": anchored(start, final.tops),
            ]
            drift[textKit2] = shifts
            let found = landmarks(position, final, textKit2: textKit2)
            let settles = [rotationSettle, sizeSettle, finalSettle].map { $0.seconds ?? -1 }
            settleOK = settleOK && settles.allSatisfy { $0 >= 0 && $0 <= Self.maxSettleSeconds }
            sizeOK = sizeOK && larger != nil && larger != "100%" && restored == "100%"
            landmarksOK = landmarksOK && found.ok
            returnsOK = returnsOK && returned.count == 7 && returned.allSatisfy { $0 }
            arms[arm] = [
                "rotation_displacement_px": Double(displacement.maxPixels),
                "rotation_displacement_labels": displacement.common,
                "drift_px": shifts.mapValues { Double($0.maxPixels) }, "labels": shifts.mapValues(\.common),
                "worst": shifts.mapValues { String($0.worstLabel.prefix(32)) },
                "cpu_settle_s": ["rotation": settles[0], "size": settles[1], "final": settles[2]],
                "cpu_samples": ["rotation": rotationSettle.samples, "size": sizeSettle.samples,
                                "final": finalSettle.samples],
                "size_readouts": [larger ?? "missing", restored ?? "missing"], "final_landmarks": found.figures,
                "leader_back_in_view": returned,
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
        let pass = driftOK && settleOK && sizeOK && landmarksOK && returnsOK
        try agent.record("6.3 rotation + Text Size 0→3→0 with cached lists (\(position.name))", pass: pass, [
            "gated": "per leg TextKit 2 drift minus SwiftUI drift <= 2.01 px; CPU <= 2 % within 5 s; size restored; "
                + "final landmarks; leader back in view after every return",
            "measure": "label tops relative to the leader (returns and the rotation leg are label-anchored); "
                + "rotation_displacement_px per arm: absolute in-place move, recorded, not gated",
            "excess_px": excess, "arms": arms,
        ])
        XCTAssertTrue(driftOK, "TextKit 2 drifts beyond SwiftUI + 2 px: \(excess)")
        XCTAssertTrue(settleOK, "CPU did not settle within 5 s: \(arms)")
        XCTAssertTrue(sizeOK, "Text Size did not step and return to 100 %: \(arms)")
        XCTAssertTrue(landmarksOK, "landmarks at the end: \(arms)")
        XCTAssertTrue(returnsOK, "a label-anchored return lost the leader: \(arms)")
    }

    /// 6.3 (state) — on lists-parity, which has no media, so this check is
    /// not exposed to kitchen-sink's pre-existing lazy-stack livelock that
    /// fails test4 (lists-parity's block 0.10 has the same class: see the
    /// type comment; `testL3c` is the table-free variant): a Find-in-Page
    /// query over list text (`LP-CONT`: a leader, nested leaders,
    /// continuation paragraphs, a trailing heading), an expand inside a list
    /// item and a root expand opened, and a task toggled (another left as
    /// the control); then ON, rotation round trip, Text Size 0→3→0, OFF,
    /// rotation round trip, Text Size 0→3→0 — search, expands, tasks and
    /// renderer checked after each step.
    func testL3bListStateSurvivesRotateSizeAndSwitch() throws {
        try listState(ListStateCase(
            fixture: "lists-parity", top: Self.parityTitle, query: "LP-CONT",
            // One is a trailing block of list item 0.10.2, one a root (0.17).
            expands: [
                ("LP-EMBED-EXPAND expand inside a list item", "LP-EMBED-EXPAND-BODY"),
                ("LP-EXPAND lists inside an expand", "LP-IN-EXPAND-BULLET"),
            ],
            toggledTask: "LP-TASK-A undone task", otherTask: "LP-TASK-C nested undone task", listRows: [],
            searchMatch: nil
        ))
    }

    /// 6.3 (state) on the table-free list-dense: `testL3b`'s steps and
    /// gates without expands (the fixture has none), with a query that
    /// lands on root 5 (`LD-005`: a leader with a nested list and a trailing
    /// heading below it) and root 13's tasks; plus list proof after every
    /// step: under TextKit 2 the trailing heading, the next leader and the
    /// toggled task are `tk2-row`s drawn by their pinned list owners, and
    /// the leader holding the search match is not one (`TextKit2TextRow`
    /// keeps an owner with search highlights on SwiftUI); under SwiftUI no
    /// `tk2-row` exists.
    func testL3cListStateSurvivesRotateSizeAndSwitchListDense() throws {
        try listState(ListStateCase(
            fixture: "list-dense", top: "LD-000 kernel batch inline render lazy", query: "LD-005", expands: [],
            toggledTask: "schema inline kernel", otherTask: "swift block confluence matrix",
            listRows: [
                ("mark kernel expand", "0.5.0.2"), ("kernel render inline panel", "0.5.1"),
                ("schema inline kernel", "0.13.1"),
            ],
            searchMatch: ("LD-005 ledger actor mark lazy", "0.5.0")
        ))
    }

    private struct ListStateCase {
        let fixture: String
        /// The document's first label (`reveal` starts from it).
        let top: String
        let query: String
        let expands: [(title: String, body: String)]
        let toggledTask: String, otherTask: String
        /// Rows a TextKit 2 step must show drawn by these owners.
        let listRows: [(label: String, owner: String)]
        /// A row holding the search match: never a `tk2-row` while the
        /// search is active.
        let searchMatch: (label: String, owner: String)?
    }

    private func listState(_ test: ListStateCase) throws {
        let agent = try HostAgent.fromEnvironment()
        let top = test.top
        let reader = ReaderDriver(launching: [
            "-fixture", test.fixture, "-rendererReset", "-rendererStats", "-fontSizeStep", "0",
        ])
        let app = reader.app
        reader.waitForRenderer("SwiftUI")
        XCTAssertTrue(reader.element(labelled: top).waitForExistence(timeout: 15), "\(test.fixture) missing")

        // Search first: running it scrolls to the first match.
        let query = test.query
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

        let expands = test.expands
        for (title, body) in expands {
            let button = app.buttons[title]
            XCTAssertTrue(reveal(button, reader, top: top), "\(title) never came into view")
            if (button.value as? String) != "Expanded" { button.tap() }
            XCTAssertTrue(reader.element(labelled: body).waitForExistence(timeout: 5), "\(title) did not open")
        }

        // Tasks: one toggled, one untouched (states persist per document,
        // so the wanted states are read, not assumed).
        let toggledTask = test.toggledTask, otherTask = test.otherTask
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
            // List proof: each row brought into view, every tk2-row seen.
            var drawn: [String: String] = [:]
            var unseen: [String] = []
            for row in test.listRows + (test.searchMatch.map { [$0] } ?? []) {
                guard reveal(reader.element(labelled: row.label), reader, top: top),
                      let snapshot = try? reader.documentSnapshot()
                else { unseen.append(row.label); continue }
                drawn.merge(snapshot.textKit2Rows) { first, _ in first }
            }
            let listKept = unseen.isEmpty && (textKit2
                ? test.listRows.allSatisfy { drawn[$0.owner] == $0.label }
                    && test.searchMatch.map { drawn[$0.owner] == nil } ?? true
                : drawn.isEmpty)
            let rendererKept = reader.isRenderer(textKit2 ? "TextKit 2" : "SwiftUI", timeout: 2)
            attach(app, "list-state-\(step)")
            var figures: [String: Any] = [
                "step": step, "search_kept": searchKept, "counter": counter.exists ? counter.label : "missing",
                "expands_kept": expandsKept, "tasks_kept": tasksKept, "renderer_kept": rendererKept,
                "pass": searchKept && expandsKept && tasksKept && rendererKept && listKept,
            ]
            if !test.listRows.isEmpty {
                figures["list_rows_kept"] = listKept
                figures["list_rows_drawn"] = Dictionary(uniqueKeysWithValues: test.listRows.map {
                    ($0.owner, drawn[$0.owner] ?? "none")
                })
                figures["tk2_rows_seen"] = drawn.count
                figures["list_rows_unseen"] = unseen
                if let match = test.searchMatch {
                    figures["search_match_row_drawn"] = "\(match.owner)=\(drawn[match.owner] ?? "none")"
                }
            }
            return figures
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
        let what = test.expands.isEmpty ? "search, task and list-row state" : "search, expand and task state"
        try agent.record("6.3 \(what) across switch, rotation and size (\(test.fixture))", pass: pass, [
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
    /// drags down, where every root is a list. Also gated, like for like:
    /// the control's rebuilt-row count (its `onAppear`s: rows shown) equals
    /// the TextKit 2 rows on screen (the accessibility census) in all four
    /// series. About's TextKit 2 count (`tk2Live`, live row views) is
    /// gated separately: ≥ the rows shown and at most
    /// `unshownRowAllowance` above them. SwiftUI's lazy stack builds rows it
    /// never shows (prefetch below the viewport, the document's last row)
    /// and keeps them off the window with the renderer they were built
    /// with, at main too (p7-retain-diag); here 56 live for 53 shown at the
    /// series viewport, 79 for 71 after 600 pt more and 61 for 53 back
    /// (recorded, not gated), every row released at OFF. Five such 600 pt
    /// round trips (the copy-only plateau probe,
    /// `p6a-stableid/plateau/gate/lifecycle.md`) plateau by the third: live
    /// back at the viewport 56, 61, 61, 58, 58, 58 and an off-screen gap of
    /// 8 after the first trip, identical at every point to an init/deinit
    /// count of the rebuild control's own rows, so the gap is the lazy
    /// stack's render-region buffer, not TextKit 2 growth. After those five
    /// trips OFF leaves the same 8 cached rows alive in both arms (the p7
    /// mechanism, bounded), and the probe's +5.9 MB TextKit 2-over-control
    /// footprint is one shared-host run, provisional until the F9 ON-vs-OFF
    /// footprint. F14 — after each
    /// TextKit 2 series one more ON pick's count exceeds the root-owned
    /// TextKit 2 rows of that census (the root-only eligible count; zero
    /// here) with list-owned rows present, while the control's extra pick
    /// shows its rebuilt rows and no TextKit 2 row.
    func testL6TwentyFlipsListDense() throws {
        let agent = try HostAgent.fromEnvironment()
        let (control, flips) = twentyFlipDesign(agent, fixture: "list-dense", landmark: "LD-000", census: true)
        let controlMedian = Self.median(control.map(\.growth))
        let flipMedian = Self.median(flips.map(\.growth))
        let excess = flipMedian - controlMedian
        let rowsOK = (control + flips).allSatisfy(\.rowsOK)
        // Like for like: the control's About count (rebuilt rows on screen,
        // onAppear-counted) against TextKit 2's on-screen rows (the
        // accessibility census). About's tk2Live counts live row views,
        // reported separately (`tk2_live_*`).
        let controlCounts = control.map { $0.on.first ?? -1 }
        let textKit2OnScreen = flips.map(\.censusAXRows)
        let matched = Set(controlCounts + textKit2OnScreen).count == 1
        let listProof = flips.allSatisfy {
            $0.censusListOwned > 0 && ($0.on.first ?? 0) > $0.censusRootOwned && $0.censusRows == $0.on.first
        }
        let controlCensus = control.allSatisfy {
            $0.censusRootOwned == 0 && $0.censusListOwned == 0 && $0.censusAXRows == 0 && $0.censusRows == $0.on.first
        }
        let liveOK = flips.allSatisfy {
            $0.censusRows >= $0.censusAXRows && $0.censusRows - $0.censusAXRows <= Self.unshownRowAllowance
        }
        let pass = rowsOK && matched && liveOK && listProof && controlCensus && excess <= Self.maxGrowthKB
        try agent.record("6.6 twenty flips (list-dense)", pass: pass, [
            "gated_metric": "median over 2 runs of raw settled phys_footprint growth over twenty switches, "
                + "TextKit 2 minus a control that rebuilds the same rows as SwiftUI (<= 5,120 KB; no pressure relief); "
                + "control rebuilt rows == TextKit 2 rows on screen; tk2Live allowance; F14 census",
            "control_growth_median_kb": controlMedian, "flips_growth_median_kb": flipMedian,
            "flips_minus_control_kb": excess, "control_rebuilt_rows": controlCounts,
            "tk2_on_screen_rows_ax": textKit2OnScreen, "tk2_live_row_views": flips.map { $0.on.first ?? -1 },
            "tk2_live_minus_on_screen": flips.map { $0.censusRows - $0.censusAXRows },
            "tk2_live_gate": "tk2Live >= rows on screen and tk2Live - rows on screen <= \(Self.unshownRowAllowance) "
                + "(lazy-stack rows built but never shown)",
            "control_runs": control.map(\.figures), "flip_runs": flips.map(\.figures),
        ])
        for (index, series) in (control + flips).enumerated() {
            XCTAssertTrue(series.rowsOK, "series \(index + 1) (\(series.control ? "control" : "TextKit 2")): "
                + "ON \(series.on) / other kind \(series.onOther), OFF \(series.off)")
        }
        XCTAssertTrue(matched, "control rebuilt rows \(controlCounts) vs TextKit 2 on-screen rows \(textKit2OnScreen)")
        XCTAssertTrue(liveOK, "tk2Live vs rows on screen: \(flips.map { ($0.censusRows, $0.censusAXRows) })")
        XCTAssertTrue(listProof, "F14: TextKit 2 census \(flips.map(\.figures))")
        XCTAssertTrue(controlCensus, "control census: \(control.map(\.figures))")
        XCTAssertLessThanOrEqual(excess, Self.maxGrowthKB,
                                 "flips grew \(flipMedian) KB vs the control's \(controlMedian) KB (medians; excess \(excess) KB)")
    }

    // MARK: - PR 3 code blocks (PR 3 plan §6, C1–C6)

    /// C1 — five round trips (ON, OFF) parked deep in code-dense
    /// (`codeFraction`: block 288 of 600, the arrival proved by its
    /// `// CD-288` line). Gated: every switch moves every code text on
    /// screen ≤ 2 px; no accumulation (each OFF within 2 px of the start,
    /// each ON within 2 px of the first ON); the code proof of every state
    /// (`CodeScreen.ok`). Then one more ON pick — About counts live code
    /// rows, no more than its live rows, and the accessibility snapshot
    /// holds code-owned rows and no root- or list-owned one — and the
    /// two-step OFF check (`codeOffCheck`).
    func testC1CodeFiveRoundTripsCodeDense() throws {
        let failures = try codeFiveRoundTrips(panned: false, HostAgent.fromEnvironment())
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
    }

    /// C1b — C1 with one wide block panned first. The block is the first
    /// one TextKit 2 draws, from the parked position on, whose text is at
    /// least `codeWideMargin` wider than the window (`wideCode`; found with
    /// the switch on, because the canvas admission is decided at view
    /// time), panned on SwiftUI by a `codePanPoints` finger travel, which
    /// must move it at least `codePanHeld` (200 pt). Also gated: the
    /// block's leading edge moves ≤ 2 px per switch and does not
    /// accumulate, and it is a TextKit 2 row with its own id at every ON.
    func testC1bCodeFiveRoundTripsPannedWideBlock() throws {
        let failures = try codeFiveRoundTrips(panned: true, HostAgent.fromEnvironment())
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
    }

    /// `testC1…` in one launch; records, then returns its failures.
    private func codeFiveRoundTrips(panned: Bool, _ agent: HostAgent) throws -> [String] {
        let name = (panned ? "C1b code five round trips, wide block panned" : "C1 code five round trips")
            + " (code-dense @ \(Self.codeKey(Self.codeArrival)))"
        let reader = try launchCodeDense(agent)
        let scale = reader.pixelScale()
        let limit = Double(Self.shiftLimit)
        var failures: [String] = []
        var wideKey: String?
        var panOffset: CGFloat = 0
        if panned {
            reader.chooseRenderer(textKit2: true)
            reader.pause()
            let wide = try wideCode(reader, textKit2: true)
            reader.chooseRenderer(textKit2: false)
            reader.pause()
            if let wide {
                let text = reader.element(labelPrefix: Self.codeLabel(wide.block))
                let rest = text.frame.minX
                if let start = reader.panStart(onCodeText: text.frame) {
                    reader.pan(from: start, by: Self.codePanPoints)
                    reader.pause()
                }
                panOffset = rest - text.frame.minX
                wideKey = Self.codeKey(wide.block)
                if panOffset < Self.codePanHeld {
                    failures.append("the pan moved \(Self.codeKey(wide.block)) \(panOffset) pt, under \(Self.codePanHeld) pt")
                }
            } else {
                failures.append("no wide code block drawn by TextKit 2 within \(Self.codeWideSearchDrags) drags")
            }
        }

        let start = Self.codeScreen(try reader.documentSnapshot())
        var previous = start
        var firstOn: CodeScreen?
        var perSwitch: [Double] = [], net: [Double] = [], panShift: [Double] = [], panNet: [Double] = []
        var worst = (label: "", pixels: CGFloat(0))
        var minCommon = Int.max
        var proofFailures: [String] = []
        if !start.ok(textKit2: false) { proofFailures.append("start: \(start.figures)") }
        for trip in 1 ... 5 {
            for textKit2 in [true, false] {
                reader.chooseRenderer(textKit2: textKit2)
                reader.pause()
                let screen = Self.codeScreen(try reader.documentSnapshot())
                let step = LabelShift(from: previous.tops, to: screen.tops, scale: scale)
                perSwitch.append(Double(step.maxPixels))
                minCommon = min(minCommon, step.common)
                if step.maxPixels > worst.pixels { worst = (step.worstLabel, step.maxPixels) }
                if textKit2, firstOn == nil { firstOn = screen }
                let reference = textKit2 ? firstOn ?? screen : start
                net.append(Double(LabelShift(from: reference.tops, to: screen.tops, scale: scale).maxPixels))
                var proof = screen.ok(textKit2: textKit2)
                if let wideKey {
                    if let x = screen.lefts[wideKey], let x0 = previous.lefts[wideKey], let xNet = reference.lefts[wideKey] {
                        panShift.append(Double(abs(x - x0) * scale))
                        panNet.append(Double(abs(x - xNet) * scale))
                    }
                    if textKit2 { proof = proof && screen.drawnByTextKit2.contains(wideKey) }
                }
                if !proof { proofFailures.append("trip \(trip) \(textKit2 ? "ON" : "OFF"): \(screen.figures)") }
                previous = screen
            }
        }
        attach(reader.app, panned ? "code-round-trips-panned" : "code-round-trips")
        reader.chooseRenderer(textKit2: true)
        let on = reader.liveCodeRows(until: { $0 > 0 }, settled: true)
        let census = try reader.documentSnapshot()
        let off = try codeOffCheck(reader, allowance: Self.unshownRowAllowance)
        reader.app.terminate()

        let live = on.textKit2 ?? -1, code = on.code ?? -1
        if minCommon == 0 { failures.append("a switch left no common code text") }
        if (perSwitch.max() ?? .infinity) > limit {
            failures.append("a switch moved \(worst.label) \(worst.pixels) px")
        }
        if (net.max() ?? .infinity) > limit { failures.append("displacement accumulated: \(net) px") }
        if wideKey != nil {
            if panShift.count != perSwitch.count { failures.append("the panned block was not on screen at every switch") }
            if (panShift.max() ?? .infinity) > limit {
                failures.append("a switch moved the panned block sideways: \(panShift) px")
            }
            if (panNet.max() ?? .infinity) > limit {
                failures.append("the horizontal offset accumulated: \(panNet) px")
            }
        }
        failures += proofFailures
        if !(live > 0 && code > 0 && code <= live && census.codeOwnedRows > 0 && census.rootOwnedRows == 0
            && census.listOwnedRows == 0)
        {
            failures.append("code rows under TextKit 2: live \(live), of which code \(code); snapshot code-owned "
                + "\(census.codeOwnedRows), root-owned \(census.rootOwnedRows), list-owned \(census.listOwnedRows)")
        }
        if !off.ok { failures.append("OFF check: \(off.figures)") }
        var figures: [String: Any] = [
            "gated": "per switch <= 2.01 px and net vs start / first ON <= 2.01 px over the code texts on screen; "
                + "code proof per state; live code rows; two-step OFF check",
            "per_switch_px": perSwitch, "net_px": net, "worst_label": worst.label, "worst_px": Double(worst.pixels),
            "min_common_labels": minCommon == .max ? 0 : minCommon, "start": start.figures,
            "proof_failures": proofFailures, "live_tk2_rows": live, "live_tk2_code_rows": code,
            "ax_code_owned_tk2_rows": census.codeOwnedRows, "ax_root_owned_tk2_rows": census.rootOwnedRows,
            "ax_list_owned_tk2_rows": census.listOwnedRows, "off_check": off.figures, "failures": failures,
        ]
        if panned {
            figures["panned_block"] = wideKey ?? "none"
            figures["pan_finger_travel_pt"] = Double(Self.codePanPoints)
            figures["pan_offset_pt"] = Double(panOffset)
            figures["pan_per_switch_px"] = panShift
            figures["pan_net_px"] = panNet
        }
        try agent.record(name, pass: failures.isEmpty, figures)
        return failures.map { "\(name): \($0)" }
    }

    /// C2 — test1's method on code-dense with L2's label-anchored return
    /// (a re-jump park does not land repeatably this deep): "back" is
    /// `codeReturn` to the anchor (`codeAnchor`: the first code text whose
    /// top edge is in view at the parked position), and a return trip is
    /// measured from that text (every code text's top minus the anchor's).
    /// A no-switch control trip first; forward — ON at the start, twelve
    /// 600 pt drags away until the parked code rows have left the render
    /// region (none of them is in the tree), OFF there, back; reverse — ON
    /// then OFF at the start, away, ON there, back, so the code
    /// rematerialises naturally as TextKit 2 rows. Each return ≤ 2 px from
    /// its start (control and forward: the SwiftUI start; reverse: the
    /// TextKit 2 start); every in-place switch moves code texts ≤ 2 px; no
    /// pair changes order across either trip; the code proof holds in
    /// every state. A control drift over 2 px alone is F16's known flake
    /// (`failure_class`).
    func testC2CodeCollapseRoundTripBothDirections() throws {
        let agent = try HostAgent.fromEnvironment()
        let reader = try launchCodeDense(agent)
        let scale = reader.pixelScale()
        let limit = Self.shiftLimit
        let anchor = try codeAnchor(reader)
        var returns: [Double] = []
        func back() throws {
            XCTAssertTrue(try codeReturn(anchor, reader), "\(anchor.key) is not back in view")
            returns.append(Double(reader.element(labelPrefix: anchor.label).frame.minY - anchor.top))
        }
        func screen() throws -> CodeScreen {
            Self.codeScreen(try reader.documentSnapshot())
        }
        func anchored(_ from: CodeScreen, _ to: CodeScreen) -> LabelShift {
            LabelShift(from: LabelShift.relative(from.tops, to: anchor.key) ?? [:],
                       to: LabelShift.relative(to.tops, to: anchor.key) ?? [:], scale: scale)
        }
        /// The parked blocks still in the accessibility tree.
        func alive(_ parked: CodeScreen) -> [String] {
            parked.tops.keys.sorted().filter { reader.element(labelPrefix: "// " + $0).exists }
        }
        // One trip first, as test1: it measures the rows on the way.
        try away(reader)
        try back()

        // Control: away and back, SwiftUI only.
        let s0 = try screen()
        try away(reader)
        try back()
        let s1 = try screen()
        let control = anchored(s0, s1)

        // Forward: ON in place, OFF far away, back.
        reader.chooseRenderer(textKit2: true)
        reader.pause()
        let s2 = try screen()
        let forwardOn = LabelShift(from: s1.tops, to: s2.tops, scale: scale)
        try away(reader)
        let forwardAlive = alive(s2)
        reader.chooseRenderer(textKit2: false)
        try back()
        let s3 = try screen()
        let forward = anchored(s1, s3)

        // Reverse: TextKit 2 in place, OFF there, ON far away, back.
        reader.chooseRenderer(textKit2: true)
        reader.pause()
        let s4 = try screen()
        let reverseOn = LabelShift(from: s3.tops, to: s4.tops, scale: scale)
        reader.chooseRenderer(textKit2: false)
        reader.pause()
        let s5 = try screen()
        let reverseOff = LabelShift(from: s4.tops, to: s5.tops, scale: scale)
        try away(reader)
        let reverseAlive = alive(s5)
        reader.chooseRenderer(textKit2: true)
        try back()
        let s6 = try screen()
        let reverse = anchored(s4, s6)
        attach(reader.app, "code-collapse-reverse-back")
        reader.app.terminate()

        let states: [(String, CodeScreen, Bool)] = [
            ("control_start", s0, false), ("control_back", s1, false), ("forward_on", s2, true),
            ("forward_back", s3, false), ("reverse_on", s4, true), ("reverse_off", s5, false),
            ("reverse_back", s6, true),
        ]
        let badProofs = states.compactMap { state -> String? in
            state.1.ok(textKit2: state.2) ? nil : "\(state.0): \(state.1.figures)"
        }
        let inversions = LabelShift.orderInversions(from: s1.tops, to: s3.tops)
            + LabelShift.orderInversions(from: s4.tops, to: s6.tops)
        let switched = [forwardOn, forward, reverseOn, reverseOff, reverse]
        let rendererOK = returns.count == 4 && control.common > 0
            && switched.allSatisfy { $0.common > 0 && $0.maxPixels <= limit }
            && !s2.tops.isEmpty && !s5.tops.isEmpty && forwardAlive.isEmpty && reverseAlive.isEmpty
            && badProofs.isEmpty && inversions.isEmpty
        let pass = rendererOK && control.maxPixels <= limit
        try agent.record("C2 code collapse round trip, both directions (code-dense @ \(anchor.key))", pass: pass, [
            "failure_class": !pass && rendererOK ? Self.controlDriftClass : "",
            "control_round_trip_px": Double(control.maxPixels), "control_labels": control.common,
            "forward_switch_on_px": Double(forwardOn.maxPixels), "forward_round_trip_px": Double(forward.maxPixels),
            "forward_worst": forward.worstLabel, "forward_labels": forward.common,
            "reverse_switch_on_px": Double(reverseOn.maxPixels), "reverse_switch_off_px": Double(reverseOff.maxPixels),
            "reverse_round_trip_px": Double(reverse.maxPixels), "reverse_worst": reverse.worstLabel,
            "reverse_labels": reverse.common,
            "forward_parked_blocks": s2.tops.keys.sorted(), "forward_still_materialised_when_far": forwardAlive,
            "forward_tk2_blocks_parked": s2.drawnByTextKit2,
            "reverse_parked_blocks": s5.tops.keys.sorted(), "reverse_still_materialised_when_far": reverseAlive,
            "reverse_tk2_blocks_back": s6.drawnByTextKit2,
            "order_inversions": inversions, "proof_failures": badProofs,
            "scroll_away_pt": Double(CGFloat(Self.awayLegs) * Self.awayDistance),
            "measure": "round trips: code text tops relative to the anchor after a label-anchored return; "
                + "switches in place: absolute tops",
            "anchor": anchor.key, "return_anchor_offsets_pt": returns,
        ])
        XCTAssertGreaterThan(control.common, 0, "no code text survived the control round trip")
        XCTAssertLessThanOrEqual(control.maxPixels, limit, "the return itself is not exact (F16 flake)")
        for (name, shift) in zip(["forward ON", "forward round trip", "reverse ON", "reverse OFF", "reverse round trip"],
                                 switched)
        {
            XCTAssertGreaterThan(shift.common, 0, "\(name): no common code text")
            XCTAssertLessThanOrEqual(shift.maxPixels, limit, "\(name): \(shift.worstLabel) moved \(shift.maxPixels) px")
        }
        XCTAssertTrue(forwardAlive.isEmpty && reverseAlive.isEmpty,
                      "the parked code never left the render region: \(forwardAlive + reverseAlive)")
        XCTAssertTrue(inversions.isEmpty, "code blocks changed order: \(inversions)")
        XCTAssertTrue(badProofs.isEmpty, "code proof: \(badProofs)")
        XCTAssertEqual(returns.count, 4, "a return trip did not complete")
    }

    /// C3 — Text Size on code-dense, each arm in its own launch with
    /// `-fontSizeStep 0` (the popover never writes the persisted size). A
    /// trip away first gives distant code blocks (7,200 pt away) and nearby
    /// ones cached heights (code rescales them by the size ratio); then
    /// Text Size 0→3 and a return trip at size 3, 3→0, return trip.
    /// Returns are label-anchored (`codeReturn`) and measured from the
    /// anchor, as is the in-place size round trip. Every leg's TextKit 2
    /// excess over the SwiftUI arm ≤ 2 px; CPU settles ≤ 2 % within 5 s
    /// after each size change and the last return; the size readout moved
    /// and came back to 100 %; the code proof holds at the end. Last, a
    /// rotation round trip, recorded per arm and not gated (PR 2's call
    /// C11: the viewport re-anchors after the width change in both arms).
    func testC3CodeTextSizeDriftMatchesSwiftUI() throws {
        let agent = try HostAgent.fromEnvironment()
        let legs = ["size3_return", "size_round_trip", "size_return"]
        var drift: [Bool: [String: LabelShift]] = [:]
        var arms: [String: Any] = [:]
        var settleOK = true, sizeOK = true, proofOK = true, returnsOK = true
        for textKit2 in [false, true] {
            let arm = textKit2 ? "textkit2" : "swiftui"
            let reader = try launchCodeDense(agent, textKit2: textKit2, extra: ["-fontSizeStep", "0"])
            let scale = reader.pixelScale()
            let anchor = try codeAnchor(reader)
            var returned: [Bool] = []
            func tops() throws -> [String: CGFloat] {
                Self.codeScreen(try reader.documentSnapshot()).tops
            }
            func trip() throws {
                try away(reader)
                returned.append(try codeReturn(anchor, reader))
            }
            func anchored(_ from: [String: CGFloat], _ to: [String: CGFloat]) -> LabelShift {
                LabelShift(from: LabelShift.relative(from, to: anchor.key) ?? [:],
                           to: LabelShift.relative(to, to: anchor.key) ?? [:], scale: scale)
            }
            try trip()
            let start = try tops()

            let larger = reader.stepTextSize(3)
            reader.pause(1.5)
            let largerSettle = try agent.cpuSettleSeconds()
            returned.append(try alignCode(anchor, reader))
            let large = try tops()
            try trip()
            let largeReturn = try tops()
            let restored = reader.stepTextSize(-3)
            reader.pause(1.5)
            let sizeSettle = try agent.cpuSettleSeconds()
            returned.append(try alignCode(anchor, reader))
            let sized = try tops()
            try trip()
            let final = Self.codeScreen(try reader.documentSnapshot())
            let finalSettle = try agent.cpuSettleSeconds()
            attach(reader.app, "code-size-\(arm)")

            // Recorded only: rotation round trip, then the anchor aligned back.
            try agent.request("rotate")
            reader.pause(2.5)
            try agent.request("rotate")
            reader.pause(2.5)
            let rotated = try tops()
            let rotatedBack = try alignCode(anchor, reader)
            let rotatedAligned = try tops()
            reader.app.terminate()

            let shifts = [
                "size3_return": anchored(large, largeReturn),
                "size_round_trip": anchored(start, sized),
                "size_return": anchored(start, final.tops),
            ]
            drift[textKit2] = shifts
            let displacement = LabelShift(from: final.tops, to: rotated, scale: scale)
            let rotationLayout = anchored(final.tops, rotatedAligned)
            let settles = [largerSettle, sizeSettle, finalSettle].map { $0.seconds ?? -1 }
            settleOK = settleOK && settles.allSatisfy { $0 >= 0 && $0 <= Self.maxSettleSeconds }
            sizeOK = sizeOK && larger != nil && larger != "100%" && restored == "100%"
            proofOK = proofOK && final.ok(textKit2: textKit2)
            returnsOK = returnsOK && returned.count == 5 && returned.allSatisfy { $0 }
            arms[arm] = [
                "anchor": anchor.key,
                "drift_px": shifts.mapValues { Double($0.maxPixels) }, "labels": shifts.mapValues(\.common),
                "worst": shifts.mapValues(\.worstLabel),
                "cpu_settle_s": ["size3": settles[0], "size": settles[1], "final": settles[2]],
                "cpu_samples": ["size3": largerSettle.samples, "size": sizeSettle.samples,
                                "final": finalSettle.samples],
                "size_readouts": [larger ?? "missing", restored ?? "missing"], "final_code_proof": final.figures,
                "anchor_back_in_view": returned,
                "rotation_recorded_not_gated": [
                    "displacement_px": Double(displacement.maxPixels), "displacement_labels": displacement.common,
                    "layout_px_anchor_aligned": Double(rotationLayout.maxPixels), "layout_labels": rotationLayout.common,
                    "anchor_back_in_view": rotatedBack,
                ] as [String: Any],
            ] as [String: Any]
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
        let pass = driftOK && settleOK && sizeOK && proofOK && returnsOK
        try agent.record("C3 code Text Size 0→3→0 with cached heights (code-dense @ \(Self.codeKey(Self.codeArrival)))",
                         pass: pass, [
            "gated": "per leg TextKit 2 drift minus SwiftUI drift <= 2.01 px; CPU <= 2 % within 5 s; size restored; "
                + "final code proof; anchor back in view after every return",
            "measure": "code text tops relative to the anchor (returns are label-anchored); "
                + "rotation per arm: recorded, not gated",
            "excess_px": excess, "arms": arms,
        ])
        XCTAssertTrue(driftOK, "TextKit 2 drifts beyond SwiftUI + 2 px: \(excess)")
        XCTAssertTrue(settleOK, "CPU did not settle within 5 s: \(arms)")
        XCTAssertTrue(sizeOK, "Text Size did not step and return to 100 %: \(arms)")
        XCTAssertTrue(proofOK, "code proof at the end: \(arms)")
        XCTAssertTrue(returnsOK, "a label-anchored return lost the anchor: \(arms)")
    }

    /// C4 — switch during a streamed code-heavy load: `-switchDuringLoad`
    /// flips to TextKit 2 on code-dense's first streamed chunk; after READY
    /// About shows 600 blocks, live TextKit 2 rows and live code rows, and
    /// `-scrollToFraction 0.9992` lands on the last block (`// CD-599`),
    /// where a code row is on screen, every TextKit 2 row draws its own
    /// block and none is a root or list row (code-dense has neither).
    /// Replacement of a document with colliding ids is a hosted suite
    /// (`TextKit2StableIDReplacementTests`), not exercised here.
    func testC4CodeSwitchDuringStreamingLoad() throws {
        let agent = try HostAgent.fromEnvironment()
        let total = Self.codeBlocks
        let reader = ReaderDriver(launching: [
            "-fixture", Self.codeFixture, "-rendererReset", "-rendererStats", "-switchDuringLoad",
            "-scrollToFraction", "0.9992",
        ])
        reader.waitForRenderer("TextKit 2", timeout: 30)
        let last = Self.codeLabel(total - 1)
        let landed = reader.element(labelPrefix: last).waitForExistence(timeout: 30)
        reader.pause()
        let screen = Self.codeScreen(try reader.documentSnapshot())
        attach(reader.app, "code-switch-during-load-end")
        reader.openAbout()
        let switchField = reader.app.staticTexts[ReaderDriver.Identifier.loadSwitchBlocks]
        let readyField = reader.app.staticTexts[ReaderDriver.Identifier.loadReadyBlocks]
        let switched = switchField.waitForExistence(timeout: 5)
        let ready = readyField.waitForExistence(timeout: 5)
        let blocksAtSwitch = switched ? Int(switchField.label) ?? -1 : -1
        let blocksAtReady = ready ? Int(readyField.label) ?? -1 : -1
        let live = reader.readLiveTextKit2Rows(until: { $0 > 0 }, settled: true) ?? -1
        let code = reader.readLiveCodeRows(until: { $0 > 0 }, settled: true) ?? -1
        reader.closeAbout()
        let proof = screen.ok(textKit2: true)
        let pass = landed && proof && blocksAtSwitch > 0 && blocksAtSwitch < total && blocksAtReady == total
            && live > 0 && code > 0 && code <= live
        try agent.record("C4 switch during streaming code load (code-dense)", pass: pass, [
            "blocks_loaded_at_switch": blocksAtSwitch, "blocks_at_ready": blocksAtReady, "total_blocks": total,
            "landed_on": landed ? last : "not landed", "code_proof": screen.figures, "code_proof_ok": proof,
            "live_tk2_rows": live, "live_tk2_code_rows": code,
        ])
        XCTAssertTrue(landed, "code-dense did not land on \(last)")
        XCTAssertGreaterThan(blocksAtSwitch, 0, "the app never switched during the load")
        XCTAssertLessThan(blocksAtSwitch, total, "the switch did not happen while blocks were still streaming")
        XCTAssertEqual(blocksAtReady, total, "the load did not complete after the switch")
        XCTAssertTrue(proof, "code rows at the end of the document: \(screen.figures)")
        XCTAssertGreaterThan(live, 0, "no live TextKit 2 row after READY")
        XCTAssertGreaterThan(code, 0, "no live TextKit 2 code row after READY")
        XCTAssertLessThanOrEqual(code, live, "more live code rows than live rows")
    }

    /// C5 — test5/test6's fling, Home/lock/switcher ×5 and 60 s soak on
    /// code-dense, plus a horizontal fling inside a wide code block with
    /// the same instantaneous CPU check (the autoscroll gate scrolls
    /// vertically only), and code rows after the thrash.
    func testC5aFlingThrashSoakCodeDenseSwiftUI() throws {
        try flingThrashSoak(textKit2: false, fixture: Self.codeFixture, landmark: Self.codeLabel(0), codeProof: true)
    }

    func testC5bFlingThrashSoakCodeDenseTextKit2() throws {
        try flingThrashSoak(textKit2: true, fixture: Self.codeFixture, landmark: Self.codeLabel(0), codeProof: true)
    }

    /// C6 — test7's rule-B design (four launches, alternating, medians of
    /// two; test7 itself stays on stress-5k) at code-dense three 300 pt
    /// drags down, where every block is code. Gated as L6, like for like:
    /// the control's rebuilt-row count equals the TextKit 2 rows on screen
    /// (the accessibility census) in all four series; About's TextKit 2
    /// count is ≥ the rows shown and at most `unshownRowAllowance` above
    /// them; TextKit 2 growth ≤ 5,120 KB over the control's (medians, no
    /// pressure relief). Code: every ON pick counts live code rows, the
    /// census holds code-owned rows only, and the control never counts a
    /// code row. OFF is the two-step check (`TwentyFlipSeries.codeRowsOK`):
    /// after every OFF pick no `tk2-row` is in the tree and About counts at
    /// most `unshownRowAllowance` live rows (rows the lazy stack built and
    /// never showed keep their engine until it comes back to them); after
    /// the series, once it has (`codeOffCheck`), the counts are 0.
    func testC6TwentyFlipsCodeDense() throws {
        let agent = try HostAgent.fromEnvironment()
        let (control, flips) = twentyFlipDesign(agent, fixture: Self.codeFixture, landmark: Self.codeLabel(0),
                                                census: true, code: true)
        let controlMedian = Self.median(control.map(\.growth))
        let flipMedian = Self.median(flips.map(\.growth))
        let excess = flipMedian - controlMedian
        let rowsOK = (control + flips).allSatisfy(\.rowsOK)
        let codeRowsOK = (control + flips).allSatisfy(\.codeRowsOK)
        let controlCounts = control.map { $0.on.first ?? -1 }
        let textKit2OnScreen = flips.map(\.censusAXRows)
        let matched = Set(controlCounts + textKit2OnScreen).count == 1
        let codeProof = flips.allSatisfy {
            $0.censusCodeOwned > 0 && $0.censusRootOwned == 0 && $0.censusListOwned == 0
                && $0.censusCodeRows > 0 && $0.censusRows == $0.on.first
        }
        let controlCensus = control.allSatisfy {
            $0.censusRootOwned == 0 && $0.censusListOwned == 0 && $0.censusCodeOwned == 0 && $0.censusAXRows == 0
                && $0.censusCodeRows == 0 && $0.censusRows == $0.on.first
        }
        let liveOK = flips.allSatisfy {
            $0.censusRows >= $0.censusAXRows && $0.censusRows - $0.censusAXRows <= Self.unshownRowAllowance
        }
        let pass = rowsOK && codeRowsOK && matched && liveOK && codeProof && controlCensus
            && excess <= Self.maxGrowthKB
        try agent.record("C6 twenty flips (code-dense)", pass: pass, [
            "gated_metric": "median over 2 runs of raw settled phys_footprint growth over twenty switches, "
                + "TextKit 2 minus a control that rebuilds the same rows as SwiftUI (<= 5,120 KB; no pressure relief); "
                + "control rebuilt rows == TextKit 2 rows on screen; tk2Live allowance; code census; "
                + "two-step OFF check (<= \(Self.unshownRowAllowance) unshown cached rows at an OFF pick, 0 after the retrace)",
            "control_growth_median_kb": controlMedian, "flips_growth_median_kb": flipMedian,
            "flips_minus_control_kb": excess, "control_rebuilt_rows": controlCounts,
            "tk2_on_screen_rows_ax": textKit2OnScreen, "tk2_live_row_views": flips.map { $0.on.first ?? -1 },
            "tk2_live_minus_on_screen": flips.map { $0.censusRows - $0.censusAXRows },
            "tk2_code_owned_rows_ax": flips.map(\.censusCodeOwned), "tk2_live_code_rows": flips.map(\.censusCodeRows),
            "control_runs": control.map(\.figures), "flip_runs": flips.map(\.figures),
        ])
        for (index, series) in (control + flips).enumerated() {
            let arm = series.control ? "control" : "TextKit 2"
            XCTAssertTrue(series.rowsOK, "series \(index + 1) (\(arm)): "
                + "ON \(series.on) / other kind \(series.onOther), OFF \(series.off)")
            XCTAssertTrue(series.codeRowsOK, "series \(index + 1) (\(arm)): code rows ON \(series.onCode), "
                + "OFF \(series.offCode), tk2-rows in the tree after OFF \(series.offInTree), "
                + "closing OFF check \(series.offCheck?.figures ?? [:])")
        }
        XCTAssertTrue(matched, "control rebuilt rows \(controlCounts) vs TextKit 2 on-screen rows \(textKit2OnScreen)")
        XCTAssertTrue(liveOK, "tk2Live vs rows on screen: \(flips.map { ($0.censusRows, $0.censusAXRows) })")
        XCTAssertTrue(codeProof, "TextKit 2 code census \(flips.map(\.figures))")
        XCTAssertTrue(controlCensus, "control census: \(control.map(\.figures))")
        XCTAssertLessThanOrEqual(excess, Self.maxGrowthKB,
                                 "flips grew \(flipMedian) KB vs the control's \(controlMedian) KB (medians; excess \(excess) KB)")
    }

    // MARK: - Code positions and proof (code-dense)

    private static let codeFixture = "code-dense"
    /// code-dense's top-level code blocks: block `i` has id `0.<i>`.
    private static let codeBlocks = 600
    /// `-scrollToFraction` for the parked position: `Int(0.4808 × 600)` is
    /// block `codeArrival`, deep in the document.
    private static let codeFraction = "0.4808"
    private static let codeArrival = 288
    /// A wide block's text is at least this much wider than the window, so
    /// that it scrolls further than `codePanPoints`.
    private static let codeWideMargin: CGFloat = 240
    /// 300 pt drags `wideCode` makes looking for a wide block (code-dense
    /// has one every few blocks).
    private static let codeWideSearchDrags = 20
    /// C1b's pan: the finger travels `codePanPoints`; a scroll view starts
    /// moving after a few points of travel, and the block must end at least
    /// `codePanHeld` from rest (plan: panned 200 pt).
    private static let codePanPoints: CGFloat = 230
    private static let codePanHeld: CGFloat = 200
    /// C5's horizontal fling: finger travel, and the least the block must
    /// have moved for the fling to count.
    private static let codeFlingPoints: CGFloat = 250
    private static let codeFlingMoved: CGFloat = 40
    /// Step 2 of the OFF check: 600 pt on and back, past the rows the lazy
    /// stack prefetched below the viewport.
    private static let codeRetrace: [CGFloat] = [600, -600]

    /// The block number of a code-dense code text: its first line is
    /// `// CD-<iii>`.
    private static func codeBlock(_ label: String) -> Int? {
        label.hasPrefix("// CD-") ? Int(label.dropFirst(6).prefix(3)) : nil
    }

    /// The start of block `block`'s code, through its number.
    private static func codeLabel(_ block: Int) -> String {
        String(format: "// CD-%03ld", block)
    }

    /// The name a check records block `block` under (`CD-<iii>`).
    private static func codeKey(_ block: Int) -> String {
        String(format: "CD-%03ld", block)
    }

    /// The code of one code-dense snapshot.
    private struct CodeScreen {
        /// `CD-<iii>` → top edge and leading edge (points) of each code
        /// text with any part on screen. A code block can be taller than
        /// the screen, so "fully in view" is not required.
        var tops: [String: CGFloat] = [:]
        var lefts: [String: CGFloat] = [:]
        /// The blocks on screen drawn by a TextKit 2 row.
        var drawnByTextKit2: [String] = []
        /// TextKit 2 rows, anywhere in the snapshot, whose text is not the
        /// code of the block their owner names (`0.<i>` ↔ `// CD-<iii>`).
        var wrongOwners: [String] = []
        /// The snapshot's TextKit 2 rows by kind, on screen or not.
        var rows = 0, codeOwned = 0, rootOwned = 0, listOwned = 0

        /// The code proof. Under TextKit 2: a code row is on screen, every
        /// TextKit 2 row draws its own block and none is a root or list
        /// row. Under SwiftUI: the snapshot holds no TextKit 2 row.
        func ok(textKit2: Bool) -> Bool {
            textKit2
                ? !drawnByTextKit2.isEmpty && wrongOwners.isEmpty && codeOwned > 0 && rootOwned == 0 && listOwned == 0
                : rows == 0
        }

        var figures: [String: Any] {
            ["blocks_on_screen": tops.keys.sorted(), "tk2_blocks_on_screen": drawnByTextKit2,
             "wrong_owners": wrongOwners, "tk2_rows": rows, "code_owned": codeOwned, "root_owned": rootOwned,
             "list_owned": listOwned]
        }
    }

    private static func codeScreen(_ snapshot: DocumentSnapshot) -> CodeScreen {
        var screen = CodeScreen()
        for node in snapshot.all where snapshot.isOnScreen(node) {
            guard let block = codeBlock(node.label) else { continue }
            let key = codeKey(block)
            // The first element with the text gives its place (SwiftUI may
            // list a selectable text more than once).
            if screen.tops[key] == nil {
                screen.tops[key] = node.frame.minY
                screen.lefts[key] = node.frame.minX
            }
            if node.owner != nil, !screen.drawnByTextKit2.contains(key) {
                screen.drawnByTextKit2.append(key)
            }
        }
        for (owner, label) in snapshot.textKit2Rows {
            let named = codeBlock(label).map { "0.\($0)" }
            if named != owner {
                screen.wrongOwners.append("\(owner)=\(label.prefix(12))")
            }
        }
        screen.wrongOwners.sort()
        screen.rows = snapshot.textKit2Rows.count
        screen.codeOwned = snapshot.codeOwnedRows
        screen.rootOwned = snapshot.rootOwnedRows
        screen.listOwned = snapshot.listOwnedRows
        return screen
    }

    /// Launches code-dense (SwiftUI unless `textKit2`) parked at block
    /// `codeArrival`, with code on screen.
    private func launchCodeDense(_ agent: HostAgent, textKit2: Bool = false, extra: [String] = []) throws
        -> ReaderDriver
    {
        var arguments = ["-fixture", Self.codeFixture, "-rendererReset", "-rendererStats",
                         "-scrollToFraction", Self.codeFraction] + extra
        if textKit2 { arguments.append("-textkit2") }
        let reader = ReaderDriver(launching: arguments)
        reader.waitForRenderer(textKit2 ? "TextKit 2" : "SwiftUI")
        let arrival = Self.codeLabel(Self.codeArrival)
        XCTAssertTrue(reader.element(labelPrefix: arrival).waitForExistence(timeout: 30),
                      "code-dense did not land on \(arrival)")
        try park(reader, agent)
        let parked = Self.codeScreen(try reader.documentSnapshot())
        XCTAssertFalse(parked.tops.isEmpty, "no code text on screen at the parked position")
        return reader
    }

    /// The code text C2 and C3 return to.
    private struct CodeAnchor {
        let block: Int
        /// `CD-<iii>`, and the start of the block's code.
        let key: String
        let label: String
        /// Where its top edge was when it was chosen (points).
        let top: CGFloat
    }

    /// The first code text whose top edge is in view (and at least 60 pt
    /// above the viewport's bottom), top to bottom.
    private func codeAnchor(_ reader: ReaderDriver) throws -> CodeAnchor {
        let snapshot = try reader.documentSnapshot()
        let viewport = snapshot.viewport
        var first: (block: Int, top: CGFloat)?
        for node in snapshot.all {
            let top = node.frame.minY
            guard let block = Self.codeBlock(node.label), top >= viewport.minY, top <= viewport.maxY - 60,
                  top < first?.top ?? .infinity else { continue }
            first = (block, top)
        }
        let found = try XCTUnwrap(first, "no code text starts in view at the parked position")
        return CodeAnchor(block: found.block, key: Self.codeKey(found.block), label: Self.codeLabel(found.block),
                          top: found.top)
    }

    /// Whether `element`'s top edge is inside the viewport (a code block
    /// can be taller than the screen, so `ReaderDriver.isVisible` may never
    /// hold for it).
    private func codeTopInView(_ element: XCUIElement, _ reader: ReaderDriver) -> Bool {
        guard element.exists else { return false }
        let viewport = reader.viewport
        let top = element.frame.minY
        return top >= viewport.minY && top <= viewport.maxY - 20
    }

    /// Label-anchored return from `away`: twelve 600 pt drags back, then
    /// `alignCode` (see `returnTo`).
    private func codeReturn(_ anchor: CodeAnchor, _ reader: ReaderDriver) throws -> Bool {
        for _ in 0 ..< Self.awayLegs {
            reader.drag(by: -Self.awayDistance)
        }
        reader.pause()
        return try alignCode(anchor, reader)
    }

    /// `align` for code-dense: drags until the anchor's top edge is in
    /// view — toward it by the `CD-<iii>` blocks on screen while it is not
    /// materialised, by its distance from `anchor.top` once it is — then up
    /// to three corrective drags toward `anchor.top`.
    @discardableResult
    private func alignCode(_ anchor: CodeAnchor, _ reader: ReaderDriver) throws -> Bool {
        let text = reader.element(labelPrefix: anchor.label)
        var steps = 0
        while !codeTopInView(text, reader), steps < 40 {
            steps += 1
            if text.exists {
                reader.drag(by: text.frame.minY - anchor.top)
            } else {
                let blocks = Self.codeScreen(try reader.documentSnapshot()).tops.keys.compactMap { Int($0.dropFirst(3)) }
                if let low = blocks.min(), let high = blocks.max() {
                    reader.drag(by: high < anchor.block ? 300 : low > anchor.block ? -300 : 120)
                } else {
                    reader.drag(by: -300)
                }
            }
            reader.pause(0.5)
        }
        for _ in 0 ..< 3 where text.exists && abs(text.frame.minY - anchor.top) > 3 {
            reader.drag(by: text.frame.minY - anchor.top)
            reader.pause(0.5)
        }
        reader.pause()
        return codeTopInView(text, reader)
    }

    /// A code text at least `codeWideMargin` wider than the window with a
    /// pan start on screen (`ReaderDriver.panStart`), drawn by a TextKit 2
    /// row with its own id when `textKit2`: the first one from the current
    /// viewport on, 300 pt at a time. nil when `codeWideSearchDrags` drags
    /// show none.
    private func wideCode(_ reader: ReaderDriver, textKit2: Bool) throws -> (block: Int, frame: CGRect)? {
        let width = reader.app.windows.firstMatch.frame.width + Self.codeWideMargin
        for attempt in 0 ... Self.codeWideSearchDrags {
            if attempt > 0 {
                reader.drag(by: 300)
                reader.pause(0.5)
            }
            let snapshot = try reader.documentSnapshot()
            for node in snapshot.all where node.frame.width >= width {
                guard let block = Self.codeBlock(node.label), !textKit2 || node.owner == "0.\(block)",
                      reader.panStart(onCodeText: node.frame) != nil else { continue }
                return (block, node.frame)
            }
        }
        return nil
    }

    /// C5's horizontal fling inside a wide code block.
    private struct CodeFling {
        /// `CD-<iii>`; empty when no wide block was found.
        var block = ""
        var drawnByTextKit2 = false
        var movedPoints: CGFloat = 0
        var leastMoved: CGFloat = 0
        var settleSeconds: Double?
        var samples: Any = [Any]()

        /// A wide block was flung (drawn by a TextKit 2 row in that arm, by
        /// SwiftUI in the other), it moved, and CPU settled in time.
        func ok(textKit2: Bool, maxSettle: Double) -> Bool {
            !block.isEmpty && drawnByTextKit2 == textKit2 && movedPoints >= leastMoved
                && (settleSeconds ?? .infinity) <= maxSettle
        }

        var figures: [String: Any] {
            ["horizontal_fling_block": block.isEmpty ? "none found" : block,
             "horizontal_fling_block_is_tk2_row": drawnByTextKit2, "horizontal_fling_moved_pt": Double(movedPoints),
             "horizontal_fling_settle_s": settleSeconds ?? -1, "horizontal_fling_samples": samples]
        }
    }

    /// Finds a wide code block (`wideCode`; one TextKit 2 draws in that
    /// arm), flings it sideways and takes the CPU check at once.
    private func codeHorizontalFling(_ reader: ReaderDriver, _ agent: HostAgent, textKit2: Bool) throws -> CodeFling {
        var fling = CodeFling(leastMoved: Self.codeFlingMoved)
        guard let wide = try wideCode(reader, textKit2: textKit2),
              let start = reader.panStart(onCodeText: wide.frame) else { return fling }
        let label = Self.codeLabel(wide.block)
        fling.block = Self.codeKey(wide.block)
        fling.drawnByTextKit2 = reader.textKit2Row(labelPrefix: label).exists
        reader.pan(from: start, by: Self.codeFlingPoints, velocity: .fast, hold: 0)
        let settle = try agent.cpuSettleSeconds()
        fling.settleSeconds = settle.seconds
        fling.samples = settle.samples
        let text = reader.element(labelPrefix: label)
        fling.movedPoints = text.exists ? wide.frame.minX - text.frame.minX : 0
        return fling
    }

    /// The two-step OFF check (stack doc §6.7).
    private struct CodeOffCheck {
        /// Step 1, right after the pick: `tk2-row`s in an accessibility
        /// snapshot (none may remain), and About's live rows and live code
        /// rows, each at most `allowance` (rows the lazy stack built and
        /// never showed keep the engine they were built with).
        var rowsInTree = -1, live = -1, code = -1
        var allowance = 0
        /// Step 2, once the stack has come back past those rows: both 0.
        var retracedLive = -1, retracedCode = -1

        var ok: Bool {
            rowsInTree == 0 && live >= 0 && live <= allowance && code >= 0 && code <= allowance
                && retracedLive == 0 && retracedCode == 0
        }

        var figures: [String: Any] {
            ["tk2_rows_in_tree_after_off": rowsInTree, "live_tk2_rows_after_off": live,
             "live_tk2_code_rows_after_off": code, "unshown_row_allowance": allowance,
             "live_tk2_rows_after_retrace": retracedLive, "live_tk2_code_rows_after_retrace": retracedCode]
        }
    }

    /// From a viewport TextKit 2 is drawing: picks SwiftUI and runs the
    /// two-step OFF check, retracing with `codeRetrace` (the viewport ends
    /// where it was).
    private func codeOffCheck(_ reader: ReaderDriver, allowance: Int) throws -> CodeOffCheck {
        var check = CodeOffCheck(allowance: allowance)
        reader.chooseRenderer(textKit2: false)
        reader.pause()
        check.rowsInTree = try reader.documentSnapshot().textKit2Rows.count
        let atSwitch = reader.liveCodeRows(until: { $0 <= allowance }, settled: true)
        check.live = atSwitch.textKit2 ?? -1
        check.code = atSwitch.code ?? -1
        for distance in Self.codeRetrace {
            reader.drag(by: distance)
            reader.pause(0.5)
        }
        reader.pause()
        let retraced = reader.liveCodeRows(until: { $0 == 0 }, settled: true)
        check.retracedLive = retraced.textKit2 ?? -1
        check.retracedCode = retraced.code ?? -1
        return check
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
        /// list-dense: the `LD-<n>` root holding the leader (`align`).
        var anchorRoot: Int?
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
    /// second leader (TextKit 1-backed; its owner is not pinned). The
    /// paragraph and heading share one continuation row, which the list
    /// scope may keep on SwiftUI (a row with more than one text block does,
    /// as of `TextKit2Scope.rowKeepsRenderer`), so they are order landmarks
    /// with no pinned owner; the leader and the nested leader (rows with
    /// one text block) are pinned.
    private static let densePosition = ListPosition(
        name: "list-dense @ LD-289", fixture: "list-dense", fraction: "0.4808", arrival: "LD-288",
        marker: "1.", heading: "scroll chunk media",
        rows: [
            ("LD-289 ledger atlas buffer expand buffer corpus", "0.289.0"),
            ("media table swift", "0.289.0.1.0"),
            ("kernel glyph vector atlas block", nil),
            ("scroll chunk media", nil),
            ("signal vector render", nil),
        ],
        anchorRoot: 289
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

    /// Label-anchored return from `away`: twelve 600 pt drags back, then
    /// `align`. The re-jump park does not land repeatably on list-dense
    /// (the 1e778df shakedown's SwiftUI-only control came back 1,372 px
    /// off, its SwiftUI rotation/size arm 504 px), so trips there are
    /// measured from the leader, not from the screen.
    private func returnTo(_ position: ListPosition, top: CGFloat, _ reader: ReaderDriver) throws -> Bool {
        for _ in 0 ..< Self.awayLegs {
            reader.drag(by: -Self.awayDistance)
        }
        reader.pause()
        return try align(position, top: top, reader)
    }

    /// Drags until `position`'s leader is in view: toward it by the
    /// `LD-<n>` roots in view while it is not materialised, by its distance
    /// from `top` once it is; then up to three corrective drags toward
    /// `top`. Short drags barely scroll, so the leader can settle tens of
    /// points off `top` (6.2 records it: ~46 pt); drift after a return is
    /// measured relative to the leader, so that offset is not in the figure.
    @discardableResult
    private func align(_ position: ListPosition, top: CGFloat, _ reader: ReaderDriver) throws -> Bool {
        let leader = reader.element(labelled: position.leader)
        var steps = 0
        while !reader.isVisible(leader), steps < 40 {
            steps += 1
            if leader.exists {
                reader.drag(by: leader.frame.minY - top)
            } else {
                let roots = try reader.visibleLabels().keys.compactMap(Self.denseRoot)
                if let target = position.anchorRoot, let low = roots.min(), let high = roots.max() {
                    reader.drag(by: high < target ? 300 : low > target ? -300 : 120)
                } else {
                    reader.drag(by: -300)
                }
            }
            reader.pause(0.5)
        }
        for _ in 0 ..< 3 where leader.exists && abs(leader.frame.minY - top) > 3 {
            reader.drag(by: leader.frame.minY - top)
            reader.pause(0.5)
        }
        reader.pause()
        return reader.isVisible(leader)
    }

    /// The root number of a list-dense first leader (`LD-<nnn> …`).
    private static func denseRoot(_ label: String) -> Int? {
        label.hasPrefix("LD-") ? Int(label.dropFirst(3).prefix(3)) : nil
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
