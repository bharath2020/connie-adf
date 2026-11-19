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
    /// `testK10a`/`testK10b` run it on containers-dense with
    /// `containerProof`: after the thrash the TextKit 2 arm must draw
    /// container rows (the §6.5 classifier, no unclassified row), the
    /// SwiftUI arm no TextKit 2 row. `testK5a`/`testK5b` run it on
    /// containers-expand with `openExpands` (`kOpenAll`, real buttons,
    /// from `fraction`): the fling becomes three end-to-end flings across
    /// the open expands (`kFlingEndToEnd`), and after its CPU check every
    /// title must still read "Expanded" with its body sentinels back within
    /// 5 s of arriving (`kWalkOpenExpands`).
    private func flingThrashSoak(textKit2: Bool, fixture: String = "stress-5k", landmark: String = "Section 0:",
                                 listProof: Bool = false, codeProof: Bool = false, containerProof: Bool = false,
                                 fraction: String? = nil, openExpands: [ContainerExpand] = []) throws
    {
        let agent = try HostAgent.fromEnvironment()
        let arm = textKit2 ? "textkit2" : "swiftui"
        var arguments = ["-fixture", fixture, "-rendererReset", "-rendererStats", "-scenePhaseProbe"]
        if let fraction { arguments += ["-scrollToFraction", fraction] }
        if textKit2 { arguments.append("-textkit2") }
        let reader = ReaderDriver(launching: arguments)
        let app = reader.app
        reader.waitForRenderer(textKit2 ? "TextKit 2" : "SwiftUI")
        XCTAssertTrue(reader.element(labelPrefix: landmark).waitForExistence(timeout: 30), "\(fixture) missing")
        XCTAssertNotNil(Self.scenePhases(app), "scene-phase-probe missing (-scenePhaseProbe)")
        var expands: KOpenExpands?
        if !openExpands.isEmpty {
            expands = try kOpenAll(openExpands, reader, agent, textKit2: textKit2)
        }

        let scroll = app.scrollViews.firstMatch
        var flings: KFlings?
        if let expands {
            flings = kFlingEndToEnd(reader, end: ContainersExpand.end, start: expands.startLabel, rounds: 3)
        } else {
            for _ in 0 ..< 3 {
                scroll.swipeUp(velocity: .fast)
            }
        }
        let fling = try agent.cpuSettleSeconds()
        var horizontal: CodeFling?
        if codeProof {
            horizontal = try codeHorizontalFling(reader, agent, textKit2: textKit2)
        }
        var walk: KWalk?
        if !openExpands.isEmpty {
            walk = kWalkOpenExpands(openExpands, reader, textKit2: textKit2)
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
        if containerProof {
            let census = try reader.documentSnapshot()
            rendererKept = rendererKept && (textKit2
                ? census.containerOwnedRows > 0 && census.unclassifiedRows == 0
                : census.textKit2Rows.isEmpty)
            listRows = ["container_owned_tk2_rows_after_thrash": census.containerOwnedRows,
                        "census_after_thrash": census.census.figures]
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
        let expandsOK = (expands?.ok ?? true) && (walk?.ok ?? true) && (flings?.ok ?? true)
        let pass = flingOK && thrashOK && leftForeground && growth <= Self.maxGrowthKB && cpuMean <= 2.0
            && rendererKept && horizontalOK && expandsOK
        let check = codeProof ? "C5" : containerProof ? "K10" : !openExpands.isEmpty ? "K5"
            : fixture == "stress-5k" ? "3.5" : "6.5"
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
        if let expands {
            figures["open_expands"] = expands.figures
            figures["end_to_end_flings"] = flings?.figures ?? [:]
            figures["end_to_end_fling_failures"] = flings?.failures ?? []
            figures["walk_after_fling"] = walk?.figures ?? [:]
        }
        try agent.record("\(check) fling + thrash + 60 s soak (\(fixture), \(arm))", pass: pass, figures)
        XCTAssertTrue(expands?.ok ?? true, "opening the expands: \(expands?.failures ?? [])")
        XCTAssertTrue(flings?.ok ?? true, "the end-to-end flings: \(flings?.failures ?? [])")
        XCTAssertTrue(walk?.ok ?? true, "after the fling: \(walk?.failures ?? [])")
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
    /// top edge is in view, at least 40 pt below the viewport's top, at the
    /// parked position), and a return trip is
    /// measured from that text (`AnchoredShift`: every other code text's
    /// top and every common code text's bottom, minus the anchor's top).
    /// A return trip is proven only with another common code text, or an
    /// anchor that runs past the viewport bottom in both snapshots (its
    /// height measured); an anchor-only trip is unproven, a FAIL with its
    /// own `failure_class` (Astra R2).
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
        func anchored(_ from: CodeScreen, _ to: CodeScreen) -> AnchoredShift {
            AnchoredShift(from: from.geometry, to: to.geometry, anchor: anchor.key, scale: scale)
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
        // Round trips: anchored, proven only by something the anchor's
        // normalisation did not zero (Astra R2). Switches in place: absolute
        // tops, where the anchor's top is itself a measurement.
        let anchoredLegs: [(String, AnchoredShift)] = [("control", control), ("forward", forward), ("reverse", reverse)]
        let unproven = anchoredLegs.compactMap { name, shift in shift.unproven.map { "\(name): \($0)" } }
        let inPlace: [(String, LabelShift)] = [("forward ON", forwardOn), ("reverse ON", reverseOn),
                                               ("reverse OFF", reverseOff)]
        let rendererOK = returns.count == 4 && unproven.isEmpty
            && forward.maxPixels <= limit && reverse.maxPixels <= limit
            && inPlace.allSatisfy { $0.1.common > 0 && $0.1.maxPixels <= limit }
            && !s2.tops.isEmpty && !s5.tops.isEmpty && forwardAlive.isEmpty && reverseAlive.isEmpty
            && badProofs.isEmpty && inversions.isEmpty
        let pass = rendererOK && control.maxPixels <= limit
        var figures: [String: Any] = [
            // An unproven leg first: it is not F16's flake.
            "failure_class": !unproven.isEmpty ? "unproven geometry: \(unproven.joined(separator: "; "))"
                : (!pass && rendererOK ? Self.controlDriftClass : ""),
            "unproven_legs": unproven,
            "control_round_trip_px": Double(control.maxPixels),
            "forward_switch_on_px": Double(forwardOn.maxPixels), "forward_switch_on_labels": forwardOn.common,
            "forward_round_trip_px": Double(forward.maxPixels),
            "reverse_switch_on_px": Double(reverseOn.maxPixels), "reverse_switch_on_labels": reverseOn.common,
            "reverse_switch_off_px": Double(reverseOff.maxPixels), "reverse_switch_off_labels": reverseOff.common,
            "reverse_round_trip_px": Double(reverse.maxPixels),
            "forward_parked_blocks": s2.tops.keys.sorted(), "forward_still_materialised_when_far": forwardAlive,
            "forward_tk2_blocks_parked": s2.drawnByTextKit2,
            "reverse_parked_blocks": s5.tops.keys.sorted(), "reverse_still_materialised_when_far": reverseAlive,
            "reverse_tk2_blocks_back": s6.drawnByTextKit2,
            "order_inversions": inversions, "proof_failures": badProofs,
            "scroll_away_pt": Double(CGFloat(Self.awayLegs) * Self.awayDistance),
            "measure": "round trips: other code texts' tops and every common code text's bottom, relative to the "
                + "anchor's top, after a label-anchored return; proven only with another common code text or an "
                + "anchor that runs past the viewport bottom in both snapshots; switches in place: absolute tops",
            "anchor": anchor.key, "anchor_top_pt": Double(anchor.top), "return_anchor_offsets_pt": returns,
        ]
        for (name, shift) in anchoredLegs {
            figures["\(name)_other_labels"] = shift.otherLabels
            figures["\(name)_measured"] = shift.measured
            figures["\(name)_landmarks"] = shift.landmarks
            figures["\(name)_worst"] = shift.worst
            figures["\(name)_anchor_fills_viewport"] = shift.anchorFillsViewport
        }
        try agent.record("C2 code collapse round trip, both directions (code-dense @ \(anchor.key))", pass: pass,
                         figures)
        for (name, shift) in anchoredLegs {
            XCTAssertTrue(shift.proven, "\(name) round trip: \(shift.unproven ?? "")")
        }
        XCTAssertLessThanOrEqual(control.maxPixels, limit, "the return itself is not exact (F16 flake)")
        for (name, shift) in [("forward round trip", forward), ("reverse round trip", reverse)] {
            XCTAssertLessThanOrEqual(shift.maxPixels, limit, "\(name): \(shift.worst) moved \(shift.maxPixels) px")
        }
        for (name, shift) in inPlace {
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
    /// anchor, as is the in-place size round trip (`AnchoredShift`: other
    /// code texts' tops and every common code text's bottom, so a height
    /// change is seen). Every leg of both arms must be proven (another
    /// common code text, or an anchor running past the viewport bottom in
    /// both snapshots); an anchor-only leg is unproven, a FAIL with its own
    /// `failure_class` (Astra R2). Every leg's TextKit 2
    /// excess over the SwiftUI arm ≤ 2 px; CPU settles ≤ 2 % within 5 s
    /// after each size change and the last return; the size readout moved
    /// and came back to 100 %; the code proof holds at the end. Last, a
    /// rotation round trip, recorded per arm and not gated (PR 2's call
    /// C11: the viewport re-anchors after the width change in both arms).
    func testC3CodeTextSizeDriftMatchesSwiftUI() throws {
        let agent = try HostAgent.fromEnvironment()
        let legs = ["size3_return", "size_round_trip", "size_return"]
        var drift: [Bool: [String: AnchoredShift]] = [:]
        var arms: [String: Any] = [:]
        var settleOK = true, sizeOK = true, proofOK = true, returnsOK = true
        for textKit2 in [false, true] {
            let arm = textKit2 ? "textkit2" : "swiftui"
            let reader = try launchCodeDense(agent, textKit2: textKit2, extra: ["-fontSizeStep", "0"])
            let scale = reader.pixelScale()
            let anchor = try codeAnchor(reader)
            var returned: [Bool] = []
            func geometry() throws -> CodeGeometry {
                Self.codeScreen(try reader.documentSnapshot()).geometry
            }
            func trip() throws {
                try away(reader)
                returned.append(try codeReturn(anchor, reader))
            }
            func anchored(_ from: CodeGeometry, _ to: CodeGeometry) -> AnchoredShift {
                AnchoredShift(from: from, to: to, anchor: anchor.key, scale: scale)
            }
            try trip()
            let start = try geometry()

            let larger = reader.stepTextSize(3)
            reader.pause(1.5)
            let largerSettle = try agent.cpuSettleSeconds()
            returned.append(try alignCode(anchor, reader))
            let large = try geometry()
            try trip()
            let largeReturn = try geometry()
            let restored = reader.stepTextSize(-3)
            reader.pause(1.5)
            let sizeSettle = try agent.cpuSettleSeconds()
            returned.append(try alignCode(anchor, reader))
            let sized = try geometry()
            try trip()
            let final = Self.codeScreen(try reader.documentSnapshot())
            let finalSettle = try agent.cpuSettleSeconds()
            attach(reader.app, "code-size-\(arm)")

            // Recorded only: rotation round trip, then the anchor aligned back.
            try agent.request("rotate")
            reader.pause(2.5)
            try agent.request("rotate")
            reader.pause(2.5)
            let rotated = try geometry()
            let rotatedBack = try alignCode(anchor, reader)
            let rotatedAligned = try geometry()
            reader.app.terminate()

            let shifts = [
                "size3_return": anchored(large, largeReturn),
                "size_round_trip": anchored(start, sized),
                "size_return": anchored(start, final.geometry),
            ]
            drift[textKit2] = shifts
            let displacement = LabelShift(from: final.tops, to: rotated.tops, scale: scale)
            let rotationLayout = anchored(final.geometry, rotatedAligned)
            let settles = [largerSettle, sizeSettle, finalSettle].map { $0.seconds ?? -1 }
            settleOK = settleOK && settles.allSatisfy { $0 >= 0 && $0 <= Self.maxSettleSeconds }
            sizeOK = sizeOK && larger != nil && larger != "100%" && restored == "100%"
            proofOK = proofOK && final.ok(textKit2: textKit2)
            returnsOK = returnsOK && returned.count == 5 && returned.allSatisfy { $0 }
            arms[arm] = [
                "anchor": anchor.key, "anchor_top_pt": Double(anchor.top),
                "drift_px": shifts.mapValues { Double($0.maxPixels) },
                "legs": shifts.mapValues(\.figures),
                "cpu_settle_s": ["size3": settles[0], "size": settles[1], "final": settles[2]],
                "cpu_samples": ["size3": largerSettle.samples, "size": sizeSettle.samples,
                                "final": finalSettle.samples],
                "size_readouts": [larger ?? "missing", restored ?? "missing"], "final_code_proof": final.figures,
                "anchor_back_in_view": returned,
                "rotation_recorded_not_gated": [
                    "displacement_px": Double(displacement.maxPixels), "displacement_labels": displacement.common,
                    "layout_anchor_aligned": rotationLayout.figures,
                    "anchor_back_in_view": rotatedBack,
                ] as [String: Any],
            ] as [String: Any]
        }
        let swiftUI = try XCTUnwrap(drift[false]), textKit2 = try XCTUnwrap(drift[true])
        // Every leg of both arms must compare something the anchor's
        // normalisation did not zero (Astra R2); unproven is a FAIL.
        var unproven: [String] = []
        for (arm, shifts) in [("swiftui", swiftUI), ("textkit2", textKit2)] {
            for leg in legs {
                guard let shift = shifts[leg] else {
                    unproven.append("\(arm) \(leg): not measured")
                    continue
                }
                if let reason = shift.unproven {
                    unproven.append("\(arm) \(leg): \(reason)")
                }
            }
        }
        var excess: [String: Double] = [:]
        var driftOK = true
        for leg in legs {
            guard let base = swiftUI[leg], let candidate = textKit2[leg] else {
                driftOK = false
                continue
            }
            let value = candidate.maxPixels - base.maxPixels
            excess[leg] = Double(value)
            driftOK = driftOK && base.proven && candidate.proven && value <= Self.shiftLimit
        }
        let pass = driftOK && settleOK && sizeOK && proofOK && returnsOK
        try agent.record("C3 code Text Size 0→3→0 with cached heights (code-dense @ \(Self.codeKey(Self.codeArrival)))",
                         pass: pass, [
            "gated": "every leg of both arms proven; per leg TextKit 2 drift minus SwiftUI drift <= 2.01 px; "
                + "CPU <= 2 % within 5 s; size restored; final code proof; anchor back in view after every return",
            "measure": "other code texts' tops and every common code text's bottom, relative to the anchor's top "
                + "(returns are label-anchored); proven only with another common code text or an anchor that "
                + "runs past the viewport bottom in both snapshots; rotation per arm: recorded, not gated",
            "failure_class": unproven.isEmpty ? "" : "unproven geometry: \(unproven.joined(separator: "; "))",
            "unproven_legs": unproven,
            "excess_px": excess, "arms": arms,
        ])
        XCTAssertTrue(unproven.isEmpty, "unproven geometry: \(unproven)")
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
    /// The least distance (points) from the viewport's top to the top of
    /// the code text C2 and C3 anchor on (`codeAnchor`).
    private static let codeAnchorTopMargin: CGFloat = 40
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
        /// `CD-<iii>` → bottom edge (points) of the same element as `tops`
        /// (its full frame: below the viewport for a text that runs past
        /// it), and the viewport's bottom (C2, C3: `AnchoredShift`).
        var bottoms: [String: CGFloat] = [:]
        var viewportMaxY: CGFloat = 0
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

        var geometry: CodeGeometry {
            CodeGeometry(tops: tops, bottoms: bottoms, viewportMaxY: viewportMaxY)
        }

        var figures: [String: Any] {
            ["blocks_on_screen": tops.keys.sorted(), "tk2_blocks_on_screen": drawnByTextKit2,
             "wrong_owners": wrongOwners, "tk2_rows": rows, "code_owned": codeOwned, "root_owned": rootOwned,
             "list_owned": listOwned]
        }
    }

    private static func codeScreen(_ snapshot: DocumentSnapshot) -> CodeScreen {
        var screen = CodeScreen()
        screen.viewportMaxY = snapshot.viewport.maxY
        for node in snapshot.all where snapshot.isOnScreen(node) {
            guard let block = codeBlock(node.label) else { continue }
            let key = codeKey(block)
            // The first element with the text gives its place (SwiftUI may
            // list a selectable text more than once).
            if screen.tops[key] == nil {
                screen.tops[key] = node.frame.minY
                screen.lefts[key] = node.frame.minX
                screen.bottoms[key] = node.frame.maxY
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

    /// The first code text whose top edge is in view, at least
    /// `codeAnchorTopMargin` below the viewport's top and 60 pt above its
    /// bottom, top to bottom. The top margin keeps a return's few points of
    /// alignment error from pushing the anchor's top out of view
    /// (`codeTopInView`): at code-dense's parked position CD-288's top sits
    /// at the viewport's top edge in some launches.
    private func codeAnchor(_ reader: ReaderDriver) throws -> CodeAnchor {
        let snapshot = try reader.documentSnapshot()
        let viewport = snapshot.viewport
        var first: (block: Int, top: CGFloat)?
        for node in snapshot.all {
            let top = node.frame.minY
            guard let block = Self.codeBlock(node.label), top >= viewport.minY + Self.codeAnchorTopMargin,
                  top <= viewport.maxY - 60, top < first?.top ?? .infinity else { continue }
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

// MARK: - PR 4 containers (testK…, plan §8.2–§8.5)

/// PR 4's container additions (plan §8.2): `testK1`…`testK8` and
/// `testK10a`/`testK10b`, on `containers-parity`, `containers-expand`,
/// `captions-parity` and `containers-dense` (`ContainerUISupport.swift`
/// holds their landmarks). `testK9` is `MediaRowGuardUITests` (§8.6), not
/// here. A container leaf drawn by TextKit 2 is `tk2-row:<owner>` with the
/// owner of `fixtures/landmarks.md`; the census classifies rows through
/// the fixture's owner table (§6.5). Limits are tests 1–8's
/// (`maxShiftPixels`, `maxGrowthKB`, `maxSettleSeconds`,
/// `unshownRowAllowance`) and, for K7 and K8, the frozen values of
/// `ContainerLifecycleLimits`. Until a family is enabled its text stays
/// SwiftUI in both arms, so a test's TextKit 2 assertions fail before the
/// step that enables it (K1: step 8 with its caption landmark; K2, K4, K5,
/// K6, K7, K8: step 5, K2's code child step 7 and K4's caption case step
/// 8; K3: step 4; K10b: step 3).
extension LifecycleUITests {
    // MARK: Shared K helpers

    /// Top edge (points) of every leaf in `leaves` in the snapshot, by
    /// sentinel: the first element whose label starts with the leaf's
    /// prefix. Read from every element, not only those fully inside the
    /// viewport: K2's park leaves the outer title (its anchor) under the
    /// navigation bar, and an accessibility frame is the element's full
    /// frame there too (as `CodeGeometry` reads it).
    private static func kTops(_ snapshot: DocumentSnapshot, _ leaves: [ContainerLeaf]) -> [String: CGFloat] {
        var tops: [String: CGFloat] = [:]
        for leaf in leaves {
            if let node = snapshot.all.first(where: { $0.label.hasPrefix(leaf.prefix) }) {
                tops[leaf.sentinel] = node.frame.minY
            }
        }
        return tops
    }

    /// The TextKit 2 owner drawing `leaf`'s text in `snapshot` (nil: no
    /// TextKit 2 row carries its text).
    private static func kOwner(_ snapshot: DocumentSnapshot, _ leaf: ContainerLeaf) -> String? {
        snapshot.textKit2Rows.first { $0.value.hasPrefix(leaf.prefix) }?.key
    }

    /// The leaves of `leaves` (those with an owner) whose engine in
    /// `snapshot` is not the arm's: under TextKit 2 a row owned by the
    /// leaf's own owner, under SwiftUI none.
    private static func kWrongEngine(_ snapshot: DocumentSnapshot, _ leaves: [ContainerLeaf], textKit2: Bool)
        -> [String]
    {
        leaves.filter { !$0.owner.isEmpty }.compactMap { leaf in
            let owner = kOwner(snapshot, leaf)
            if textKit2 { return owner == leaf.owner ? nil : "\(leaf.sentinel): owner \(owner ?? "none")" }
            return owner == nil ? nil : "\(leaf.sentinel): TextKit 2 row \(owner ?? "") on SwiftUI"
        }
    }

    /// Waits up to 10 s for every leaf (with an owner) to have the arm's
    /// engine, so a snapshot is not taken mid-switch.
    private func kWaitForEngine(_ driver: ContainerDriver, _ leaves: [ContainerLeaf], textKit2: Bool) {
        for leaf in leaves where !leaf.owner.isEmpty {
            _ = textKit2 ? driver.isTextKit2(leaf, timeout: 10) : driver.isSwiftUI(leaf, timeout: 10)
        }
        driver.pause(0.5)
    }

    /// Twelve 600 pt drags toward the top (`toward` < 0) or the end.
    private func kAway(_ reader: ReaderDriver, toward direction: CGFloat = -1) {
        for _ in 0 ..< 12 {
            reader.drag(by: direction < 0 ? -600 : 600)
        }
        reader.pause()
    }

    /// The live counters (About, one visit) and the census of one
    /// snapshot, with the census-only §6.5 cross-check (`cross_check`:
    /// its failures, gated by the callers) and §8.4's on-window identity
    /// `tk2Live − tk2OffWindow == census rows`, recorded only: call C22
    /// disproved it (rows the lazy stack keeps beyond the viewport have a
    /// window but are not in the census).
    private func kCounters(_ reader: ReaderDriver) throws -> [String: Any] {
        let counters = reader.liveRowCounters()
        let snapshot = try reader.documentSnapshot()
        let live = counters.total ?? -1
        let offWindow = counters.offWindow ?? -1
        return [
            "tk2_live": live, "list_live": counters.list ?? -1, "code_live": counters.code ?? -1,
            "container_live": counters.container ?? -1, "caption_live": counters.caption ?? -1,
            "offwindow": offWindow, "census_rows": snapshot.textKit2Rows.count,
            "on_window_identity": offWindow >= 0 && live - offWindow == snapshot.textKit2Rows.count,
            "census": snapshot.census.figures, "cross_check": snapshot.census.crossCheck(counters),
        ]
    }

    // MARK: K1 — five switch round trips at container landmarks

    /// One K1 landmark: navigate there (`reach`), then `leaves` (the
    /// container text that flips) and `follower` (the row after the
    /// container) are measured over five round trips.
    private struct KLandmark {
        let name: String
        let leaves: [ContainerLeaf]
        let follower: ContainerLeaf
        /// For a layout section: two leaves in its first and a later
        /// column. Its text is TextKit 2 under the switch only while the
        /// columns stack (`ContainerDriver.columnTextKit2`).
        var columns: (left: ContainerLeaf, right: ContainerLeaf)? = nil
        let reach: @MainActor (ContainerDriver) -> Bool
    }

    /// K1 (plan §8.3): one launch on containers-parity, five ON/OFF round
    /// trips at each of the first four palette panels (0.1–0.4; the plan's
    /// multi-child panel 0.11 holds headings, so its whole body stays on
    /// SwiftUI in both arms, call C18's `panelKeepsRenderer`, and has no
    /// engine to swap), a three-level
    /// quote (0.29), the 25/75 columns (0.46) and an open outer expand with
    /// its nested expand open (0.58); then one launch on captions-parity at
    /// a caption (0.3.0). At every switch: the landmark's leaves are drawn
    /// by their own owners under TextKit 2 and by none under SwiftUI; each
    /// switch moves the leaves and the row after the container ≤ 2 px; the
    /// five trips do not accumulate (end vs start ≤ 2 px). Positions are
    /// absolute (no scroll between switches). Passes once step 8 has
    /// enabled captions (panel and quote from step 3, columns step 4, the
    /// open expand step 5).
    func testK1SwitchRoundTripsAtContainerLandmarks() throws {
        let agent = try HostAgent.fromEnvironment()
        typealias KP = ContainersParity
        let outer = KP.expandOuter
        let parity: [KLandmark] = [
            KLandmark(name: "panels 0.1-0.4",
                      leaves: [ContainerLeaf("KP-PANEL-INFO", "0.1.0"), ContainerLeaf("KP-PANEL-NOTE", "0.2.0"),
                               ContainerLeaf("KP-PANEL-TIP", "0.3.0"), ContainerLeaf("KP-PANEL-WARNING", "0.4.0")],
                      follower: ContainerLeaf("KP-PANEL-ERROR", "0.5.0")) { driver in
                driver.jump(toHeading: KP.s1, settleDrag: 0)
                return driver.scroll(by: 300, until: driver.element(ContainerLeaf("KP-PANEL-ERROR", "0.5.0")))
            },
            KLandmark(name: "quote 0.29", leaves: [KP.quoteOuter, KP.quoteInner, KP.quoteInnermost, KP.quoteOuterAfter],
                      follower: KP.afterQuotes) { driver in
                driver.jump(toHeading: KP.s3, settleDrag: 0)
                return driver.scroll(by: 300, until: driver.element(KP.afterQuotes))
            },
            KLandmark(name: "columns 0.46", leaves: [KP.col25A, KP.col25B, KP.col75A, KP.col75B],
                      follower: ContainerLeaf("KP-COL33-A", "0.47.0.0"), columns: (KP.col25A, KP.col75A)) { driver in
                driver.jump(toHeading: KP.s6, settleDrag: 0)
                return driver.scroll(by: 300, until: driver.element(ContainerLeaf("KP-COL33-A", "0.47.0.0")))
            },
            KLandmark(name: "open expand 0.58", leaves: [outer.first, KP.expandH3] + [outer.nestedFirst, outer.nestedLast]
                .compactMap { $0 }, follower: ContainerLeaf("KP-EXPAND-CONTAINERS", "")) { driver in
                driver.jump(toHeading: KP.s8, settleDrag: 0)
                guard driver.setExpand(outer.title, open: true, step: 300),
                      let nested = outer.nestedTitle, driver.setExpand(nested, open: true, step: 300) else { return false }
                return driver.scroll(by: 300, until: driver.element(ContainerLeaf("KP-EXPAND-CONTAINERS", "")))
            },
        ]
        var figures: [[String: Any]] = []
        var failures: [String] = []
        let containers = ContainerDriver(fixture: KP.fixture)
        containers.reader.waitForRenderer("SwiftUI")
        XCTAssertTrue(containers.reader.element(labelled: KP.s1).waitForExistence(timeout: 30), "containers-parity missing")
        for landmark in parity {
            let result = try kFiveRoundTrips(containers, landmark)
            figures.append(result.figures)
            failures += result.failures
        }
        containers.app.terminate()

        let caption = KLandmark(name: "caption 0.3.0", leaves: [CaptionsParity.plain],
                                follower: ContainerLeaf("CAP-04 image", "", alone: true)) { driver in
            driver.scroll(by: 200, until: driver.reader.element(labelled: "CAP-04 image"))
        }
        let captions = ContainerDriver(fixture: CaptionsParity.fixture)
        captions.reader.waitForRenderer("SwiftUI")
        XCTAssertTrue(captions.reader.element(labelled: CaptionsParity.s1).waitForExistence(timeout: 30),
                      "captions-parity missing")
        let result = try kFiveRoundTrips(captions, caption)
        figures.append(result.figures)
        failures += result.failures
        captions.app.terminate()

        try agent.record("K1 five switch round trips at container landmarks (containers-parity, captions-parity)",
                         pass: failures.isEmpty, ["landmarks": figures, "failures": failures])
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
    }

    private func kFiveRoundTrips(_ driver: ContainerDriver, _ landmark: KLandmark) throws
        -> (figures: [String: Any], failures: [String])
    {
        let reader = driver.reader
        var failures: [String] = []
        guard landmark.reach(driver) else {
            return (["landmark": landmark.name, "reached": false], ["\(landmark.name): never reached"])
        }
        reader.drag(by: 40)
        reader.pause()
        let scale = reader.pixelScale()
        // Side-by-side columns keep their text on SwiftUI in both arms.
        let sideBySide = landmark.columns.flatMap { driver.columnsSideBySide($0.left, $0.right) } ?? false
        let tracked = landmark.leaves + [landmark.follower]
        let start = try reader.documentSnapshot()
        let base = Self.kTops(start, tracked)
        let measured = tracked.filter { base[$0.sentinel] != nil }.map(\.sentinel)
        if base[landmark.follower.sentinel] == nil || !landmark.leaves.contains(where: { base[$0.sentinel] != nil }) {
            failures.append("\(landmark.name): leaf or follower not fully in view (\(measured))")
        }
        failures += Self.kWrongEngine(start, landmark.leaves, textKit2: false).map { "\(landmark.name) start: \($0)" }
        var last = base
        var switches: [[String: Any]] = []
        for trip in 1 ... 5 {
            for textKit2 in [true, false] {
                reader.chooseRenderer(textKit2: textKit2)
                let engine = ContainerDriver.columnTextKit2(textKit2, sideBySide: sideBySide)
                kWaitForEngine(driver, landmark.leaves, textKit2: engine)
                let snapshot = try reader.documentSnapshot()
                let tops = Self.kTops(snapshot, tracked)
                let shift = LabelShift(from: last, to: tops, scale: scale)
                let wrong = Self.kWrongEngine(snapshot, landmark.leaves, textKit2: engine)
                let lost = measured.filter { tops[$0] == nil }
                let name = "\(landmark.name) trip \(trip) \(textKit2 ? "ON" : "OFF")"
                if shift.maxPixels > Self.shiftLimit { failures.append("\(name): \(shift.worstLabel) moved \(shift.maxPixels) px") }
                failures += wrong.map { "\(name): \($0)" }
                if !lost.isEmpty { failures.append("\(name): left the viewport: \(lost)") }
                switches.append(["trip": trip, "on": textKit2, "px": Double(shift.maxPixels), "worst": shift.worstLabel,
                                 "common": shift.common, "wrong_engine": wrong])
                last = tops
            }
        }
        let drift = LabelShift(from: base, to: last, scale: scale)
        if drift.maxPixels > Self.shiftLimit {
            failures.append("\(landmark.name): \(drift.worstLabel) drifted \(drift.maxPixels) px over five round trips")
        }
        attach(reader.app, "k1-\(landmark.name.replacingOccurrences(of: " ", with: "-"))")
        return ([
            "landmark": landmark.name, "measured": measured, "owners": landmark.leaves.map(\.owner),
            "layout": landmark.columns == nil ? "-" : (sideBySide ? "side-by-side" : "stacked"),
            "switches": switches, "accumulated_px": Double(drift.maxPixels), "accumulated_worst": drift.worstLabel,
        ], failures)
    }

    // MARK: K2 — open expand, collapse by scrolling, switch, return

    /// K2 (plan §8.3, f36), containers-parity parked at the outer expand
    /// (0.58, `-scrollToFraction`; `park` re-jumps there and drags 100 pt).
    /// The outer and nested expands are opened with the real buttons. A
    /// no-switch SwiftUI control trip (twelve 600 pt drags toward the top,
    /// far past the render region, and back); forward: ON in place, away,
    /// OFF there, back; reverse: OFF in place, away, ON there, back. At
    /// each far point the expand's leaves have left the tree (the open row
    /// collapsed) and the census passes its census-only cross-check
    /// (`TextKit2RowCensus.crossCheck`: each class within its counter, the
    /// census plus the off-window rows within tk2Live); the identity
    /// `tk2Live − tk2OffWindow == census` is recorded, not gated (call
    /// C22). Back: both titles
    /// still read "Expanded" (the model's open state), every body leaf is
    /// drawn by the arm's engine (its own owner under TextKit 2), and the
    /// leaves' tops, measured from the outer title, are within 2 px of the
    /// control's. Then the code child (0.74.1, in KP-CODE-EXPAND): panned
    /// 230 pt on TextKit 2, its offset holds ≤ 2 px over OFF and ON, Copy
    /// writes the exact code (host agent pasteboard), and after a collapse
    /// and return the expand is open and the code a TextKit 2 row again
    /// (its offset recorded). Passes after step 5 (the code child step 7).
    func testK2OpenExpandRoundTripAcrossSwitch() throws {
        let agent = try HostAgent.fromEnvironment()
        typealias KP = ContainersParity
        let expand = KP.expandOuter
        let nestedTitle = try XCTUnwrap(expand.nestedTitle)
        let titleLeaf = ContainerLeaf("KP-EXPAND-OUTER", "")
        let leaves = [expand.first, KP.expandH3] + [expand.nestedFirst, expand.nestedLast].compactMap { $0 } + [expand.last]
        let driver = ContainerDriver(fixture: KP.fixture, fraction: KP.fraction(KP.expandIndex))
        let reader = driver.reader
        reader.waitForRenderer("SwiftUI")
        XCTAssertTrue(driver.expandButton(expand.title).waitForExistence(timeout: 30), "did not land on \(expand.id)")
        XCTAssertTrue(driver.setExpand(expand.title, open: true, step: 200), "the outer expand did not open")
        XCTAssertTrue(driver.setExpand(nestedTitle, open: true, step: 200), "the nested expand did not open")
        try park(reader, agent)
        let scale = reader.pixelScale()
        var failures: [String] = []
        func anchored(_ snapshot: DocumentSnapshot) -> [String: CGFloat] {
            LabelShift.relative(Self.kTops(snapshot, leaves + [titleLeaf]), to: titleLeaf.sentinel) ?? [:]
        }
        func far(_ name: String) throws -> [String: Any] {
            kAway(reader)
            let alive = leaves.filter { driver.element($0).exists }.map(\.sentinel)
            if !alive.isEmpty { failures.append("\(name): still in the tree far away: \(alive)") }
            let counters = try kCounters(reader)
            if let check = counters["cross_check"] as? [String], !check.isEmpty {
                failures.append("\(name): the census far away: \(check) (\(counters))")
            }
            return ["alive_far": alive, "counters_far": counters]
        }
        func back(_ name: String, textKit2: Bool) throws -> DocumentSnapshot {
            try park(reader, agent)
            kWaitForEngine(driver, leaves, textKit2: textKit2)
            let snapshot = try reader.documentSnapshot()
            for title in [expand.title, nestedTitle] where driver.expandValue(title) != "Expanded" {
                failures.append("\(name): \(title) reads \(driver.expandValue(title) ?? "missing")")
            }
            failures += Self.kWrongEngine(snapshot, leaves, textKit2: textKit2).map { "\(name): \($0)" }
            return snapshot
        }
        // One trip first, as test 1: it measures the rows on the way.
        kAway(reader)
        try park(reader, agent)

        let c0 = try reader.documentSnapshot()
        let controlFar = try far("control")
        let c1 = try back("control back", textKit2: false)
        let control = LabelShift(from: anchored(c0), to: anchored(c1), scale: scale)

        reader.chooseRenderer(textKit2: true)
        kWaitForEngine(driver, leaves, textKit2: true)
        let f0 = try reader.documentSnapshot()
        failures += Self.kWrongEngine(f0, leaves, textKit2: true).map { "forward ON in place: \($0)" }
        let liveAtLandmark = reader.liveTextKit2Rows(until: { $0 > 0 }, settled: true) ?? -1
        let forwardFar = try far("forward")
        reader.chooseRenderer(textKit2: false)
        let f1 = try back("forward back", textKit2: false)
        let forward = LabelShift(from: anchored(c1), to: anchored(f1), scale: scale)

        let reverseFar = try far("reverse")
        reader.chooseRenderer(textKit2: true)
        let r1 = try back("reverse back", textKit2: true)
        let reverse = LabelShift(from: anchored(c1), to: anchored(r1), scale: scale)
        let liveBack = reader.liveTextKit2Rows(until: { $0 > 0 }, settled: true) ?? -1
        attach(reader.app, "k2-reverse-back")
        for (name, shift) in [("forward", forward), ("reverse", reverse)] {
            if shift.common < 2 { failures.append("\(name): only \(shift.common) landmarks compared") }
            if shift.maxPixels > Self.shiftLimit {
                failures.append("\(name): \(shift.worstLabel) is \(shift.maxPixels) px from the control's return")
            }
        }

        // The code child.
        let code = try kCodeChild(driver, agent, failures: &failures)
        reader.app.terminate()

        let rendererOK = failures.isEmpty
        let pass = rendererOK && control.maxPixels <= Self.shiftLimit
        try agent.record("K2 open expand round trip across the switch (containers-parity 0.58)", pass: pass, [
            "failure_class": !pass && rendererOK ? Self.controlDriftClass : "",
            "ids": ["outer": expand.id, "nested": "0.58.3", "leaves": leaves.map(\.owner)],
            "control_px": Double(control.maxPixels), "forward_px": Double(forward.maxPixels),
            "forward_worst": forward.worstLabel, "reverse_px": Double(reverse.maxPixels),
            "reverse_worst": reverse.worstLabel, "measure": "body leaf tops relative to the outer title after the park",
            "control_far": controlFar, "forward_far": forwardFar, "reverse_far": reverseFar,
            "live_at_landmark_on": liveAtLandmark, "live_back_on": liveBack, "code_child": code,
            "failures": failures,
        ])
        XCTAssertLessThanOrEqual(control.maxPixels, Self.shiftLimit, "the control return moved \(control.worstLabel)")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
    }

    /// K2's code child: KP-CODE-EXPAND (0.74) opened, its code 0.74.1 panned
    /// on TextKit 2, two switches, Copy, a collapse and a return.
    private func kCodeChild(_ driver: ContainerDriver, _ agent: HostAgent, failures: inout [String]) throws
        -> [String: Any]
    {
        typealias KP = ContainersParity
        let reader = driver.reader
        let expand = KP.codeExpand
        let code = expand.last
        let expected = """
            // KP-CODE-EXPAND-BODY code inside an expand body
            // .:...10....:...20....:...30....:...40....:...50....:...60....:...70....:...80....:...90....:..100
            let token920 = swift.stream(920)
            if inline.render > 847 { return quartz }
            let stream = 31 // batch token anchor
            theme.scroll = anchor[717] // corpus batch document glyph raster ledger scroll atlas inline
            """
        driver.jump(toHeading: KP.s10, settleDrag: 0)
        guard driver.setExpand(expand.title, open: true, step: 300) else {
            failures.append("code child: KP-CODE-EXPAND did not open")
            return [:]
        }
        let text = driver.element(code)
        guard driver.scroll(by: 200, until: text, maxDrags: 8) else {
            failures.append("code child: \(code) never came into view")
            return [:]
        }
        reader.chooseRenderer(textKit2: true)
        if !driver.isTextKit2(code) { failures.append("code child: \(code) is not a TextKit 2 row") }
        let scale = reader.pixelScale()
        let rest = text.frame.minX
        guard let start = reader.panStart(onCodeText: text.frame) else {
            failures.append("code child: no pan start on \(code)")
            return [:]
        }
        reader.pan(from: start, by: 230)
        reader.pause()
        let panned = rest - text.frame.minX
        if panned < 200 { failures.append("code child: the pan moved the code \(panned) pt") }
        var offsets: [Double] = [Double(panned)]
        for textKit2 in [false, true] {
            reader.chooseRenderer(textKit2: textKit2)
            reader.pause()
            let now = rest - text.frame.minX
            offsets.append(Double(now))
            if abs(now - panned) * scale > Self.shiftLimit {
                failures.append("code child: the offset moved to \(now) pt on switching \(textKit2 ? "ON" : "OFF")")
            }
        }
        // Copy: a sentinel first, so a stale pasteboard cannot pass.
        UIPasteboard.general.string = "ADF-K2-COPY-SENTINEL"
        let copy = reader.app.buttons.matching(NSPredicate(format: "label == %@", ReaderDriver.Identifier.copyCodeLabel))
            .allElementsBoundByIndex.filter { $0.frame.maxY <= text.frame.minY + 4 }
            .min { text.frame.minY - $0.frame.maxY < text.frame.minY - $1.frame.maxY }
        var exact = false
        if let copy {
            copy.tap()
            reader.pause()
            let pasted = try agent.pasteboard()
            exact = pasted == expected
            if !exact { failures.append("code child: Copy wrote \(pasted.debugDescription.prefix(120))") }
        } else {
            failures.append("code child: no Copy button above \(code)")
        }
        // Collapse by scrolling (toward the top) and return.
        kAway(reader)
        let alive = text.exists
        if alive { failures.append("code child: \(code) never left the tree") }
        driver.jump(toHeading: KP.s10, settleDrag: 0)
        _ = driver.scroll(by: 200, until: text, maxDrags: 8)
        if driver.expandValue(expand.title) != "Expanded" { failures.append("code child: KP-CODE-EXPAND closed") }
        if !driver.isTextKit2(code) { failures.append("code child: \(code) is not a TextKit 2 row after the return") }
        let returned = rest - text.frame.minX
        reader.chooseRenderer(textKit2: false)
        return ["owner": code.owner, "offsets_pt": offsets, "copy_exact": exact, "alive_far": alive,
                "offset_after_return_pt": Double(returned)]
    }

    // MARK: K3 — width and type-size changes

    /// K3 (plan §8.3, f21), per arm in its own launch at containers-parity's
    /// 25/75 columns (0.46; `-fontSizeStep 0`). An excursion to the top
    /// and back first caches the distant container roots as spacers. Then a
    /// no-change control (the same pause and re-anchor without a change),
    /// a rotation round trip, Text Size 0 → 3 → 0 and the column boundary
    /// leg, Text Size 0 → the cut-off pair → accessibility1 → 0. The pair
    /// is `ContainerDriver.containerSizeCutoff` (lead call C55,
    /// `TextKit2Scope.containerSizeKeepsRenderer`): xxLarge, the last size
    /// at which a container body keeps TextKit 2, then xxxLarge, from which
    /// every container body keeps SwiftUI. `LayoutColumnsView` stacks at
    /// every width only at the accessibility sizes, so a pair below
    /// accessibility1 goes on to accessibility1 (the crossing needs a
    /// stacked stage). Each round
    /// trip is measured from KP-COL25-A after re-aligning it (the rotation
    /// can re-anchor the viewport in both arms, as on list-dense): drift ≤
    /// the arm's control drift + 2 px. The column text is TextKit 2 under
    /// the switch only while the columns stack (no family keeps the
    /// renderer side by side, PR 4 step 4) and the text size is below the
    /// cut-off, so the engine every tracked leaf in the tree must have
    /// follows the layout and size of the moment
    /// (`ContainerDriver.columnTextKit2(_:sideBySide:size:)`); it is
    /// asserted at every stage (parked, control, rotated, back, at
    /// xxxLarge, after the size steps, at each size of the boundary leg and
    /// back; at least one tracked leaf in the tree at each), the anchor in
    /// the tree at each but the rotated one and xxxLarge. On TextKit 2,
    /// where the columns stack (a phone), the column text is TextKit 2 at
    /// the pair's first size and SwiftUI at its second: the size rule's
    /// engine flip is gated at the cut-off, not tolerated. The columns must stack at
    /// every accessibility size. The layout at size 0 is expected from the
    /// destination, never read from the layout drawn
    /// (`ContainerDriver.regularWidthDestination`, Astra delta R5): on an
    /// iPad (regular width) the columns must sit side by side at size 0
    /// and the boundary leg must cross it both ways (side by side →
    /// stacked → side by side, gated `crossed_boundary`). Under C55 the
    /// iPad's column text is SwiftUI at every stage on both arms (side by
    /// side below the accessibility sizes, past the cut-off at them), so
    /// there the leg proves the layout crossing and the engines, not a
    /// TextKit 2 flip; a phone (compact width in portrait) must stack them
    /// at size 0, records the boundary as not crossable, and gates the
    /// flip. Live
    /// TextKit 2 rows: after Text Size 3 and back at most the count before
    /// + `unshownRowAllowance` (no mass re-materialisation, ADR §16); after
    /// the boundary leg back at most its own starting count + the same
    /// allowance (the rows the stacked columns made are released; the counts
    /// at the leg's sizes are recorded). CPU settles ≤ 2 % within 5 s after
    /// each change. Passes after step 4. A run with K3 passes
    /// `lifecycle-gate.sh` only beside a K3 record with `regular_width`
    /// and `crossed_boundary` true on both arms, its own or an iPad run's
    /// (`--k3-crossing`, review D-R5, Astra delta R5).
    func testK3WidthAndTypeSizeChangesInContainers() throws {
        let agent = try HostAgent.fromEnvironment()
        typealias KP = ContainersParity
        let anchor = KP.col25A
        let tracked = [KP.col25A, KP.col25B, KP.col75A, KP.col75H4, KP.col75B, ContainerLeaf("KP-COL33-A", "0.47.0.0")]
        var arms: [[String: Any]] = []
        var failures: [String] = []
        for textKit2 in [false, true] {
            let arm = textKit2 ? "textkit2" : "swiftui"
            let driver = ContainerDriver(fixture: KP.fixture, textKit2: textKit2, fraction: KP.fraction(KP.columnsIndex))
            let reader = driver.reader
            reader.waitForRenderer(textKit2 ? "TextKit 2" : "SwiftUI")
            XCTAssertTrue(driver.element(anchor).waitForExistence(timeout: 30), "\(arm): did not land on the columns")
            kAway(reader)
            try park(reader, agent)
            let scale = reader.pixelScale()
            var armFailures: [String] = []
            var stages: [[String: Any]] = []
            /// The Text Size of the moment (launched at `-fontSizeStep 0`).
            var size = TextSizeStep.large
            /// Steps the Text Size control to `target`; the readout.
            func step(to target: TextSizeStep) -> String? {
                defer { size = target }
                return reader.stepTextSize(target.rawValue - size.rawValue)
            }
            /// Side by side, the right column shares the left's row, so it
            /// is in the tree whenever the left one is: a left column
            /// without the right one beside it is stacked.
            func layout() -> String {
                guard driver.element(KP.col25A).exists else { return "unknown" }
                guard driver.element(KP.col75A).exists else { return "stacked" }
                return driver.columnsSideBySide(KP.col25A, KP.col75A) == true ? "side-by-side" : "stacked"
            }
            /// The engine the column leaves have now: TextKit 2 under the
            /// switch while the columns stack below the cut-off.
            func engine() -> Bool {
                ContainerDriver.columnTextKit2(textKit2, sideBySide: layout() == "side-by-side", size: size)
            }
            func aligned() throws -> [String: CGFloat] {
                _ = driver.scroll(by: 300, until: driver.element(anchor), maxDrags: 10)
                kWaitForEngine(driver, tracked.filter { driver.element($0).exists }, textKit2: engine())
                return LabelShift.relative(Self.kTops(try reader.documentSnapshot(), tracked), to: anchor.sentinel) ?? [:]
            }
            /// Every tracked leaf in the tree has the engine of the layout
            /// and text size of the moment; the anchor must be in the tree
            /// (`anchored`).
            func engines(_ stage: String, anchored: Bool = true) throws {
                let current = layout()
                let snapshot = try reader.documentSnapshot()
                let present = tracked.filter { leaf in snapshot.all.contains { $0.label.hasPrefix(leaf.prefix) } }
                if present.isEmpty { armFailures.append("\(stage): no tracked leaf is in the tree") }
                if anchored, !present.contains(where: { $0.sentinel == anchor.sentinel }) {
                    armFailures.append("\(stage): \(anchor.sentinel) is not in the tree")
                }
                let expected = ContainerDriver.columnTextKit2(textKit2, sideBySide: current == "side-by-side", size: size)
                let wrong = Self.kWrongEngine(snapshot, present, textKit2: expected)
                armFailures += wrong.map { "\(stage) (\(current)): \($0)" }
                stages.append(["stage": stage, "layout": current, "text_size": "\(size)",
                               "expected_textkit2": expected,
                               "leaves_in_tree": present.map(\.sentinel), "wrong_engine": wrong])
            }
            func live() -> Int {
                textKit2 ? reader.liveTextKit2Rows(until: { _ in true }, settled: true) ?? -1 : 0
            }
            try engines("parked")

            let c0 = try aligned()
            reader.pause(5)
            let c1 = try aligned()
            let control = LabelShift(from: c0, to: c1, scale: scale)
            try engines("control")

            let layoutBefore = layout()
            let r0 = try aligned()
            try agent.request("rotate")
            reader.pause(2.5)
            let layoutRotated = layout()
            attach(reader.app, "k3-\(arm)-rotated")
            let rotatedSettle = try agent.cpuSettleSeconds()
            try engines("rotated", anchored: false)
            try agent.request("rotate")
            reader.pause(2.5)
            let rotationSettle = try agent.cpuSettleSeconds()
            let r1 = try aligned()
            let rotation = LabelShift(from: r0, to: r1, scale: scale)
            let layoutAfter = layout()
            try engines("rotated back")

            let s0 = try aligned()
            let live0 = live()
            let up = step(to: .xxxLarge)
            let upSettle = try agent.cpuSettleSeconds()
            let live3 = live()
            try engines("xxxLarge", anchored: false)
            let down = step(to: .large)
            let downSettle = try agent.cpuSettleSeconds()
            let liveBack = live()
            let s1 = try aligned()
            let sizeShift = LabelShift(from: s0, to: s1, scale: scale)
            try engines("xxxLarge and back")

            // The column boundary leg: the cut-off pair (C55: xxLarge, the
            // last size whose container bodies keep TextKit 2, then
            // xxxLarge, from which they keep SwiftUI), so the engine flip is
            // gated exactly there; then accessibility1 when the pair lies
            // below it (it does under C55), because the columns stack at
            // every width only at the accessibility sizes.
            let cutoff = ContainerDriver.containerSizeCutoff
            if cutoff.firstSwiftUI.rawValue != cutoff.lastTextKit2.rawValue + 1 {
                armFailures.append("the cut-off pair is not two adjacent sizes: \(cutoff)")
            }
            let legSizes: [TextSizeStep] = [cutoff.lastTextKit2, cutoff.firstSwiftUI]
                + (cutoff.firstSwiftUI < .accessibility1 ? [.accessibility1] : [])
            let b0 = try aligned()
            let layoutB0 = layout()
            let liveB0 = live()
            var leg: [(size: TextSizeStep, readout: String?, settle: Double?, layout: String, live: Int)] = []
            for target in legSizes {
                let readout = step(to: target)
                let settle = try agent.cpuSettleSeconds()
                _ = try aligned()
                let stageLayout = layout()
                try engines("\(target)")
                attach(reader.app, "k3-\(arm)-\(target)")
                leg.append((target, readout, settle.seconds, stageLayout, live()))
            }
            let axDown = step(to: .large)
            let axDownSettle = try agent.cpuSettleSeconds()
            let b1 = try aligned()
            let layoutB1 = layout()
            let liveB1 = live()
            let boundaryShift = LabelShift(from: b0, to: b1, scale: scale)
            try engines("boundary leg and back")
            reader.app.terminate()

            // Whether the boundary must be crossed comes from the destination
            // (an iPad: regular width), never from the layout drawn: columns
            // wrongly stacked at size 0 fail here instead of making the
            // crossing optional (Astra delta R5).
            let crossable = ContainerDriver.regularWidthDestination
            let expectedLayout = crossable ? "side-by-side" : "stacked"
            let crossed = layoutB0 == "side-by-side" && leg.last?.layout == "stacked" && layoutB1 == "side-by-side"
            let settles = [rotatedSettle, rotationSettle, upSettle, downSettle].map { $0.seconds ?? .infinity }
                + leg.map { $0.settle ?? .infinity } + [axDownSettle.seconds ?? .infinity]
            let legLayouts = [layoutB0] + leg.map { $0.layout } + [layoutB1]
            let legLive = [liveB0] + leg.map { $0.live } + [liveB1]
            let legReadouts = leg.map { $0.readout ?? "nil" } + [axDown ?? "nil"]
            for (name, shift) in [("rotation", rotation), ("text size", sizeShift), ("boundary", boundaryShift)] {
                if shift.common < 2 { armFailures.append("\(name): only \(shift.common) landmarks compared") }
                if shift.maxPixels - control.maxPixels > Self.shiftLimit {
                    armFailures.append("\(name): \(shift.worstLabel) drifted \(shift.maxPixels) px "
                        + "(control \(control.maxPixels) px)")
                }
            }
            for (name, value) in [("parked", layoutBefore), ("rotated back", layoutAfter), ("before the boundary leg", layoutB0),
                                  ("back from the boundary leg", layoutB1)] where value == "unknown" {
                armFailures.append("column layout unknown \(name)")
            }
            if layoutBefore != expectedLayout {
                armFailures.append("the columns are \(layoutBefore) at Text Size 0, expected \(expectedLayout) on this "
                    + "\(crossable ? "regular" : "compact")-width destination")
            }
            for stage in leg where stage.size.isAccessibility && stage.layout != "stacked" {
                armFailures.append("the columns did not stack at \(stage.size) (\(stage.layout))")
            }
            if crossable, !crossed {
                armFailures.append("the boundary was not crossed both ways: \(legLayouts.joined(separator: " → "))")
            }
            if settles.contains(where: { $0 > Self.maxSettleSeconds }) { armFailures.append("CPU settle \(settles) s") }
            if textKit2, live3 > live0 + Self.unshownRowAllowance || liveBack > live0 + Self.unshownRowAllowance {
                armFailures.append("live rows jumped across the size steps: \(live0) → \(live3) → \(liveBack)")
            }
            if textKit2, liveB1 > liveB0 + Self.unshownRowAllowance {
                armFailures.append("live rows after the boundary leg: \(legLive.map(String.init).joined(separator: " → "))")
            }
            if up == nil || down != "100%" { armFailures.append("size readout \(up ?? "nil") → \(down ?? "nil")") }
            let repeated = zip(legReadouts, legReadouts.dropFirst()).contains { $0.0 == $0.1 }
            if leg.contains(where: { $0.readout == nil }) || repeated || axDown != "100%" {
                armFailures.append("boundary leg readouts \(legReadouts.joined(separator: " → "))")
            }
            failures += armFailures.map { "\(arm): \($0)" }
            arms.append([
                "arm": arm, "control_px": Double(control.maxPixels), "rotation_px": Double(rotation.maxPixels),
                "rotation_worst": rotation.worstLabel, "size_px": Double(sizeShift.maxPixels),
                "size_worst": sizeShift.worstLabel,
                "boundary_px": Double(boundaryShift.maxPixels), "boundary_worst": boundaryShift.worstLabel,
                "layout": [layoutBefore, layoutRotated, layoutAfter],
                "size_cutoff": ["last_textkit2": "\(cutoff.lastTextKit2)", "first_swiftui": "\(cutoff.firstSwiftUI)"],
                "boundary_leg_sizes": ["large"] + leg.map { "\($0.size)" } + ["large"],
                "layout_boundary_leg": legLayouts,
                "crossed_boundary_rotation": layoutBefore != layoutRotated,
                "regular_width": crossable, "expected_layout_size_0": expectedLayout,
                "crossed_boundary": crossed,
                "boundary_gate": crossable ? "gated: an iPad destination, side by side at size 0 (regular width)"
                    : "not crossable here: a phone stacks the columns at size 0 (compact width), recorded",
                "settle_s": settles, "live_rows_size_0_3_0": [live0, live3, liveBack],
                "live_rows_boundary_leg": legLive,
                "size_readouts": [up ?? "nil", down ?? "nil"],
                "boundary_leg_readouts": legReadouts,
                "stages": stages, "failures": armFailures,
            ])
        }
        try agent.record("K3 width and type-size changes in containers (containers-parity 0.46)", pass: failures.isEmpty, [
            "arms": arms, "measure": "tops relative to KP-COL25-A after re-aligning it; limit: the arm's control + 2 px",
            "failures": failures,
        ])
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
    }

    // MARK: K4 — load and search

    /// K4 (plan §8.3). First the switch before the last chunk, on
    /// containers-dense, as test 3 on stress-5k: `-switchDuringLoad` flips
    /// to TextKit 2 on the first block-count change the reader sees while
    /// the document still loads, and its 840 blocks stream in seventeen
    /// 50-block chunks, so once streaming has finished `load-ready-blocks`
    /// is 840 and `load-switch-blocks` is between 1 and 839 (gated: the
    /// switch came before the last chunk) and at most 838, the landing
    /// block: the warning panel at index 838 (KD-0798, owner 0.838.0, in
    /// the last chunk) arrived after the switch and must be a TextKit 2
    /// row. Then one launch on containers-parity, which streams in two
    /// chunks, so its switch may see every block (call E9): `load-ready-
    /// blocks` is 87 and `load-switch-blocks` between 1 and 87 (whether it
    /// came before the last chunk is recorded), landing on the panel at
    /// KP-NEG-PLUGIN-P (0.83.0), which must be a TextKit 2 row. A task
    /// inside a quote (0.64.2.0) is toggled on TextKit 2 and
    /// keeps its state over OFF and ON. A search for
    /// `KP-EXPAND-NESTED-P1` opens the chain (0.58 and 0.58.3 read
    /// "Expanded"); the matching owner 0.58.3.0 draws on SwiftUI while the
    /// search is active (its text shown, no TextKit 2 row) and its
    /// neighbour 0.58.3.1, brought into view, on TextKit 2; clearing
    /// returns 0.58.3.0 to TextKit 2. Then the caption case on
    /// captions-parity: a search matching CAP-03's caption only (0.3.0)
    /// falls back that owner (shown, no TextKit 2 row) while CAP-05
    /// (0.5.0; CAP-04 between them stays SwiftUI, a run background), brought
    /// into view, stays a TextKit 2 row; clearing returns
    /// it. Passes after step 8 (the expand part step 5,
    /// the task step 6).
    func testK4SwitchDuringLoadAndSearchInContainers() throws {
        let agent = try HostAgent.fromEnvironment()
        typealias KP = ContainersParity
        typealias KD = ContainersDense
        var failures: [String] = []

        // The switch before the last chunk (containers-dense).
        let dense = ContainerDriver(fixture: KD.fixture, fraction: KD.fraction(KD.lastPanelIndex),
                                    extra: ["-switchDuringLoad"])
        dense.reader.waitForRenderer("TextKit 2", timeout: 30)
        let denseLanded = dense.element(KD.lastPanel).waitForExistence(timeout: 60)
        if !denseLanded { failures.append("containers-dense: did not land on \(KD.lastPanel)") }
        let denseLastTextKit2 = dense.isTextKit2(KD.lastPanel)
        if !denseLastTextKit2 { failures.append("containers-dense: \(KD.lastPanel) is not a TextKit 2 row after the load") }
        let (denseAtSwitch, denseAtReady) = Self.kLoadSwitchCounts(dense.reader)
        dense.app.terminate()
        if denseAtReady != KD.preparedBlocks {
            failures.append("containers-dense: blocks at READY \(denseAtReady), expected \(KD.preparedBlocks)")
        }
        if !(denseAtSwitch > 0 && denseAtSwitch < denseAtReady && denseAtSwitch <= KD.lastPanelIndex) {
            failures.append("containers-dense: blocks at the switch \(denseAtSwitch), expected 1…\(KD.lastPanelIndex) "
                + "(before the last chunk and the landing block)")
        }

        let plugin = ContainerLeaf("KP-NEG-PLUGIN-P", "0.83.0")
        let driver = ContainerDriver(fixture: KP.fixture, fraction: KP.fraction(84), extra: ["-switchDuringLoad"])
        let reader = driver.reader
        reader.waitForRenderer("TextKit 2", timeout: 30)
        let landed = driver.element(plugin).waitForExistence(timeout: 30)
        if !landed { failures.append("did not land on \(plugin)") }
        if !driver.isTextKit2(plugin) { failures.append("\(plugin) is not a TextKit 2 row after the load") }
        // The switch during the load (call E9). `-switchDuringLoad` flips on
        // the first block-count change the reader observes before READY, so
        // it is a switch during the load by construction. How many blocks
        // that first observation sees is harness timing, not the renderer:
        // containers-parity streams in two chunks, and both can be appended
        // before SwiftUI delivers the count change, so the switch may see
        // every block. So the counts are read once streaming has finished
        // (the ready count is recorded at READY; the reader waits for it
        // below) and the switch's count is compared against the document's
        // full count: at least one block, at most all of them. Whether the
        // switch came before the last chunk is recorded, not gated.
        let (atSwitch, atReady) = Self.kLoadSwitchCounts(reader)
        if atReady != KP.preparedBlocks { failures.append("blocks at READY: \(atReady), expected \(KP.preparedBlocks)") }
        if !(atSwitch > 0 && atSwitch <= atReady) {
            failures.append("blocks at the switch: \(atSwitch), expected 1…\(atReady) (the full count once streamed)")
        }

        // Task state across switches.
        driver.jump(toHeading: KP.s9, settleDrag: 0)
        let task = driver.element(KP.taskOpen)
        _ = driver.scroll(by: 250, until: task, maxDrags: 10)
        if !driver.isTextKit2(KP.taskOpen) { failures.append("\(KP.taskOpen) is not a TextKit 2 row") }
        var taskStates: [String] = []
        if let box = reader.taskMarker(leader: task.label) {
            let before = box.label
            box.tap()
            reader.pause()
            for textKit2 in [false, true] {
                reader.chooseRenderer(textKit2: textKit2)
                reader.pause()
                taskStates.append(reader.taskMarker(leader: task.label)?.label ?? "missing")
            }
            let toggled = before == "Task" ? "Completed task" : "Task"
            if taskStates.contains(where: { $0 != toggled }) {
                failures.append("task state \(before) → \(taskStates), expected \(toggled) throughout")
            }
            // Task states persist per document: restore it.
            reader.taskMarker(leader: task.label)?.tap()
            reader.pause()
        } else {
            failures.append("no checkbox on \(KP.taskOpen)")
        }

        // Search inside the nested expand.
        let expand = KP.expandOuter
        let match = try XCTUnwrap(expand.nestedFirst), neighbour = try XCTUnwrap(expand.nestedLast)
        let counter = driver.search(match.sentinel)
        if !counter.hasPrefix("1 /") { failures.append("search \(match.sentinel): counter \(counter)") }
        let chain = [expand.title, expand.nestedTitle ?? ""].map { driver.expandValue($0) ?? "missing" }
        if chain != ["Expanded", "Expanded"] { failures.append("search did not open the chain: \(chain)") }
        if let problem = driver.searchFallbackProblem(match) { failures.append("highlighted: \(problem)") }
        attach(reader.app, "k4-search-nested-expand")
        if let problem = driver.searchNeighbourProblem(neighbour, step: 200) { failures.append(problem) }
        _ = driver.scroll(by: -200, until: driver.element(match), maxDrags: 6)
        driver.clearSearch()
        if !driver.isTextKit2(match) { failures.append("\(match) did not return to TextKit 2 after clearing") }
        reader.app.terminate()

        // The caption case (captions-parity).
        let captions = ContainerDriver(fixture: CaptionsParity.fixture, textKit2: true)
        captions.reader.waitForRenderer("TextKit 2")
        let caption = CaptionsParity.plain, next = CaptionsParity.linked
        XCTAssertTrue(captions.element(caption).waitForExistence(timeout: 30), "captions-parity missing")
        let captionCounter = captions.search("plain caption under")
        if !captionCounter.hasPrefix("1 /") { failures.append("caption search: counter \(captionCounter)") }
        if let problem = captions.searchFallbackProblem(caption) { failures.append("highlighted caption: \(problem)") }
        attach(captions.app, "k4-search-caption")
        if let problem = captions.searchNeighbourProblem(next, step: 200) { failures.append("caption search: \(problem)") }
        _ = captions.scroll(by: -200, until: captions.element(caption), maxDrags: 6)
        captions.clearSearch()
        if !captions.isTextKit2(caption) { failures.append("\(caption) did not return to TextKit 2 after clearing") }
        captions.app.terminate()

        try agent.record("K4 switch during load, task state and search in containers", pass: failures.isEmpty, [
            "dense_blocks_at_switch": denseAtSwitch, "dense_blocks_at_ready": denseAtReady,
            "dense_total_blocks": KD.preparedBlocks, "dense_landed_owner": KD.lastPanel.owner,
            "dense_landed_index": KD.lastPanelIndex, "dense_landed_textkit2": denseLastTextKit2,
            "dense_switch_before_last_chunk": denseAtSwitch > 0 && denseAtSwitch < denseAtReady,
            "blocks_at_switch": atSwitch, "blocks_at_ready": atReady, "total_blocks": KP.preparedBlocks,
            "switch_before_last_chunk": atSwitch > 0 && atSwitch < atReady,
            "landed_owner": plugin.owner, "task_owner": KP.taskOpen.owner, "task_states_off_on": taskStates,
            "search_owner": match.owner, "search_neighbour": neighbour.owner, "chain_values": chain,
            "caption_owner": caption.owner, "caption_neighbour": next.owner, "failures": failures,
        ])
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
    }

    /// `load-switch-blocks` and `load-ready-blocks` from About, once
    /// streaming has finished (the ready count appears at READY); -1 for a
    /// field that never appeared.
    private static func kLoadSwitchCounts(_ reader: ReaderDriver) -> (atSwitch: Int, atReady: Int) {
        reader.openAbout()
        let switchField = reader.app.staticTexts[ReaderDriver.Identifier.loadSwitchBlocks]
        let readyField = reader.app.staticTexts[ReaderDriver.Identifier.loadReadyBlocks]
        let atReady = readyField.waitForExistence(timeout: 30) ? Int(readyField.label) ?? -1 : -1
        let atSwitch = switchField.waitForExistence(timeout: 5) ? Int(switchField.label) ?? -1 : -1
        reader.closeAbout()
        return (atSwitch, atReady)
    }

    // MARK: K5 — fling across open expands

    func testK5aFlingOpenExpandsSwiftUI() throws {
        try kFlingOpenExpands(textKit2: false)
    }

    /// K5b passes after step 5.
    func testK5bFlingOpenExpandsTextKit2() throws {
        try kFlingOpenExpands(textKit2: true)
    }

    /// K5 (plan §8.3, f25): test 5/6's fling, thrash and soak on
    /// containers-expand with CE-OPEN-1 … 5 and their nested expands open.
    private func kFlingOpenExpands(textKit2: Bool) throws {
        try flingThrashSoak(
            textKit2: textKit2, fixture: ContainersExpand.fixture, landmark: ContainersExpand.openHeading(1),
            fraction: ContainersExpand.fraction(ContainersExpand.openHeadingIndex[0]),
            openExpands: (1 ... 5).map(ContainersExpand.open)
        )
    }

    /// What `kOpenAll` saw.
    private struct KOpenExpands {
        var failures: [String] = []
        var figures: [String: Any] = [:]
        /// The first expand's section heading: where the end-to-end flings
        /// turn back.
        var startLabel = ""
        var ok: Bool { failures.isEmpty }
    }

    /// Opens every expand of `expands` and its nested expand with the real
    /// buttons, top to bottom from the current position; under TextKit 2
    /// each opened body's first leaf must be its own TextKit 2 row, under
    /// SwiftUI none. Proves once that the open rows collapse: at the last
    /// expand, the first expand's body has left the tree, and (TextKit 2)
    /// the live row count is below the opened bodies' leaf count.
    private func kOpenAll(_ expands: [ContainerExpand], _ reader: ReaderDriver, _ agent: HostAgent,
                          textKit2: Bool) throws -> KOpenExpands
    {
        let driver = ContainerDriver(wrapping: reader)
        var result = KOpenExpands()
        result.startLabel = ContainersExpand.openHeading(1)
        var opened: [String] = []
        var live: [Int] = []
        for expand in expands {
            guard driver.setExpand(expand.title, open: true, step: 600, maxDrags: 40),
                  driver.element(expand.first).waitForExistence(timeout: 10) else {
                result.failures.append("\(expand.id) did not open")
                continue
            }
            if let nested = expand.nestedTitle,
               !(driver.setExpand(nested, open: true, step: 400) && driver.element(expand.nestedFirst ?? expand.first)
                   .waitForExistence(timeout: 10))
            {
                result.failures.append("\(expand.id)'s nested expand did not open")
            }
            opened.append(expand.id)
            if textKit2 {
                live.append(reader.liveTextKit2Rows(until: { $0 > 0 }, settled: true) ?? -1)
            }
        }
        let first = expands[0]
        let firstAlive = driver.element(first.first).exists || driver.element(first.last).exists
        if firstAlive { result.failures.append("\(first.id)'s body is still in the tree at the last expand") }
        let leafCount = [30, 33, 35, 37, 40].prefix(expands.count).reduce(0, +)
        if textKit2, let last = live.last, !(last > 0 && last < leafCount) {
            result.failures.append("live rows \(last) at the last expand (opened bodies hold \(leafCount) leaves)")
        }
        result.figures = ["opened": opened, "live_rows_after_each_open": live, "first_body_alive_at_last": firstAlive,
                          "opened_body_leaves": leafCount]
        return result
    }

    /// The most fast swipes `kFlingEndToEnd` spends on one leg: a loop
    /// guard, not a measured limit. From open expand 1's heading (CE-S3) to
    /// CE-END takes 28 to 42 fast swipes on either arm, scrolling down
    /// (2026-11-18, iPhone 17 Pro: SwiftUI 32 and 37, TextKit 2 42 and 28;
    /// an earlier TextKit 2 run ran out of the old guard of 40 in round 2
    /// and reached CE-END on the 40th in round 3); back up it takes 19 to
    /// 25 (SwiftUI's lazy stack jumps scrolling up past open expands). 80
    /// is about twice the longest down leg on either arm, so a leg that
    /// runs out has stalled or keeps jumping back (code review F-R12), not
    /// merely flung short.
    static let kFlingSwipeCap = 80

    /// The most drags `kFlingEndToEnd` spends on one leg steering an
    /// endpoint that is in the tree but outside the viewport (a row the
    /// lazy stack prefetched, or one the last fling carried past) into it:
    /// a loop guard. Each drag is at most 300 pt and aims at the element's
    /// frame, so 10 cover about four screens.
    static let kFlingSteerCap = 10

    /// What `kFlingEndToEnd` saw.
    private struct KFlings {
        var failures: [String] = []
        var figures: [String: Any] = [:]
        var ok: Bool { failures.isEmpty }
    }

    /// `rounds` end-to-end flings: toward the end until `end` intersects the
    /// viewport, then back until the label `start` does (Astra delta R7: an
    /// endpoint is reached by its frame, as K9's are, not by being in the
    /// tree, where prefetched rows sit outside the viewport). Each leg flings
    /// with fast swipes while its endpoint is not in the tree (at most
    /// `kFlingSwipeCap`), then steers it into the viewport with drags aimed
    /// at its frame (at most `kFlingSteerCap`). Each leg must reach its
    /// endpoint after at least one fast swipe: a leg that ran out, or never
    /// had to fling, fails.
    private func kFlingEndToEnd(_ reader: ReaderDriver, end: ContainerLeaf, start: String, rounds: Int) -> KFlings {
        let cap = Self.kFlingSwipeCap, steerCap = Self.kFlingSteerCap
        let driver = ContainerDriver(wrapping: reader)
        let scroll = reader.app.scrollViews.firstMatch
        let endElement = reader.element(labelPrefix: end.prefix)
        let startElement = reader.element(labelled: start)
        /// One leg: (fast swipes, steering drags, whether `element` ended
        /// intersecting the viewport).
        func leg(to element: XCUIElement, towardEnd: Bool) -> (swipes: Int, steers: Int, reached: Bool) {
            var swipes = 0, steers = 0
            while !driver.isPartlyShown(element) {
                if element.exists {
                    guard steers < steerCap else { break }
                    let frame = element.frame, viewport = reader.viewport
                    reader.drag(by: frame.minY >= viewport.maxY ? min(300, frame.minY - viewport.maxY + 40)
                        : -min(300, max(viewport.minY - frame.maxY, 0) + 40))
                    reader.pause(0.4)
                    steers += 1
                } else {
                    guard swipes < cap else { break }
                    if towardEnd { scroll.swipeUp(velocity: .fast) } else { scroll.swipeDown(velocity: .fast) }
                    swipes += 1
                }
            }
            return (swipes, steers, driver.isPartlyShown(element))
        }
        var result = KFlings()
        var swipes: [[Int]] = []
        var steers: [[Int]] = []
        var reached: [[Bool]] = []
        for round in 1 ... rounds {
            let down = leg(to: endElement, towardEnd: true)
            let up = leg(to: startElement, towardEnd: false)
            if !down.reached {
                result.failures.append("fling round \(round): \(end.sentinel) never intersected the viewport "
                    + "(\(down.swipes) swipes, \(down.steers) steering drags)")
            }
            if down.reached, down.swipes == 0 {
                result.failures.append("fling round \(round): \(end.sentinel) reached before any fast swipe")
            }
            if !up.reached {
                result.failures.append("fling round \(round): '\(start)' never intersected the viewport on the way back "
                    + "(\(up.swipes) swipes, \(up.steers) steering drags)")
            }
            if up.reached, up.swipes == 0 {
                result.failures.append("fling round \(round): '\(start)' reached before any fast swipe back")
            }
            swipes.append([down.swipes, up.swipes])
            steers.append([down.steers, up.steers])
            reached.append([down.reached, up.reached])
        }
        result.figures = ["rounds": rounds, "swipes_down_up": swipes, "steer_drags_down_up": steers,
                          "reached_end_start": reached, "reached_by": "frame intersects the viewport (as K9)",
                          "end": end.sentinel, "start": start, "swipe_cap": cap, "steer_cap": steerCap]
        return result
    }

    /// What `kWalkOpenExpands` saw.
    private struct KWalk {
        var failures: [String] = []
        var figures: [String: Any] = [:]
        var ok: Bool { failures.isEmpty }
    }

    /// After the flings, from the first expand's section: each expand in
    /// turn is brought into view; its title and its nested title must read
    /// "Expanded" and each body sentinel (the first leaf, the nested first
    /// leaf) must exist within 5 s of arriving, drawn by its own TextKit 2
    /// row under TextKit 2 and by none under SwiftUI.
    private func kWalkOpenExpands(_ expands: [ContainerExpand], _ reader: ReaderDriver, textKit2: Bool) -> KWalk {
        let driver = ContainerDriver(wrapping: reader)
        var walk = KWalk()
        var returns: [[String: Any]] = []
        for expand in expands {
            // The expand's top-level index ("0.346" → 346); the nested title
            // sits inside the body, half a block below it.
            let index = Double(expand.id.split(separator: ".").last.flatMap { Int($0) } ?? 0)
            var stops: [(title: String, sentinel: ContainerLeaf, at: Double)] = [(expand.title, expand.first, index)]
            if let nested = expand.nestedTitle, let first = expand.nestedFirst { stops.append((nested, first, index + 0.5)) }
            for stop in stops {
                let button = driver.expandButton(stop.title)
                let arrival = driver.seek(button, at: stop.at)
                guard arrival.shown else {
                    walk.failures.append("\(stop.title) never came into view (\(arrival.figures))")
                    continue
                }
                let seconds = ContainerDriver.seconds(until: driver.element(stop.sentinel), since: Date(),
                                                      timeout: Self.maxSettleSeconds)
                let value = driver.expandValue(stop.title) ?? "missing"
                let engineOK = textKit2 ? driver.isTextKit2(stop.sentinel, timeout: 5)
                    : !driver.textKit2Row(owner: stop.sentinel.owner).exists
                if value != "Expanded" { walk.failures.append("\(stop.title) reads \(value)") }
                if seconds == nil { walk.failures.append("\(stop.sentinel) not back within 5 s") }
                if !engineOK { walk.failures.append("\(stop.sentinel): wrong engine (\(textKit2 ? "TextKit 2" : "SwiftUI"))") }
                returns.append(["sentinel": stop.sentinel.owner, "value": value, "back_s": seconds ?? -1,
                                "engine_ok": engineOK, "arrival": arrival.figures])
            }
        }
        walk.figures = ["stops": returns]
        return walk
    }

    // MARK: K6 — twenty flips with open expands

    /// K6 (plan §8.4): test 7's design on containers-expand, parked at
    /// CE-OPEN-1 with it and its nested expand opened by the real buttons
    /// before the first footprint. Four launches, control and TextKit 2
    /// alternating (`kContainerFlips`); the median TextKit 2 growth may
    /// exceed the control's by at most 5,120 KB. Every series: both titles
    /// read "Expanded" after every pick; every ON pick shows the same
    /// nonzero count of its kind and none of the other, and (TextKit 2)
    /// live container rows > 0 (heading and filler rows alone never pass),
    /// none under the control; every OFF pick leaves no `tk2-row` in the
    /// tree (read from the accessibility tree, not from any counter) and,
    /// under TextKit 2, `tk2Live − tk2OffWindow == 0` within 5 s; the
    /// census after the series (one more ON) has container rows > 0
    /// (classifier, §6.5) and passes the census-only cross-check against
    /// the live counters (call C22), whose census + off-window <= tk2Live
    /// backs up the off-window count the OFF picks read; the identity
    /// `tk2Live − tk2OffWindow == census` is recorded only; and after the
    /// closing OFF and a retrace the live count is 0, which no counter of
    /// rows off the window can satisfy for rows still alive. Passes after
    /// step 5.
    func testK6TwentyFlipsContainers() throws {
        let agent = try HostAgent.fromEnvironment()
        var control: [KFlipSeries] = [], flips: [KFlipSeries] = []
        for run in 1 ... 2 {
            for arm in run == 1 ? [true, false] : [false, true] {
                let series = kContainerFlips(agent, control: arm)
                if arm { control.append(series) } else { flips.append(series) }
            }
        }
        let controlMedian = Self.median(control.map(\.growth))
        let flipMedian = Self.median(flips.map(\.growth))
        let excess = flipMedian - controlMedian
        let problems = (control + flips).flatMap(\.failures)
        let pass = problems.isEmpty && excess <= Self.maxGrowthKB
        try agent.record("K6 twenty flips with open expands (containers-expand @ CE-OPEN-1)", pass: pass, [
            "gated_metric": "median over 2 runs of raw settled phys_footprint growth over twenty switches, "
                + "TextKit 2 minus a control that rebuilds the same rows as SwiftUI (<= 5,120 KB; no pressure relief)",
            "control_growth_median_kb": controlMedian, "flips_growth_median_kb": flipMedian,
            "flips_minus_control_kb": excess, "control_runs": control.map(\.figures), "flip_runs": flips.map(\.figures),
            "failures": problems,
        ])
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "; "))
        XCTAssertLessThanOrEqual(excess, Self.maxGrowthKB,
                                 "flips grew \(flipMedian) KB vs the control's \(controlMedian) KB (medians; excess \(excess) KB)")
    }

    private struct KFlipSeries {
        let control: Bool
        var growth = 0
        var failures: [String] = []
        var figures: [String: Any] = [:]
    }

    /// One K6 launch and series (`control`: `-rebuildControlPicks 20`,
    /// which covers the census's eleventh ON pick too: only TextKit 2 picks
    /// consume it, as in test 7).
    private func kContainerFlips(_ agent: HostAgent, control: Bool) -> KFlipSeries {
        typealias CE = ContainersExpand
        let arm = control ? "control" : "TextKit 2"
        var series = KFlipSeries(control: control)
        let expand = CE.open(1)
        let titles = [expand.title, expand.nestedTitle ?? ""]
        let driver = ContainerDriver(fixture: CE.fixture, fraction: CE.fraction(CE.openHeadingIndex[0]),
                                     extra: ["-rebuildControlPicks", control ? "20" : "0"])
        let reader = driver.reader
        reader.waitForRenderer("SwiftUI")
        XCTAssertTrue(reader.element(labelled: CE.openHeading(1)).waitForExistence(timeout: 30), "containers-expand missing")
        // prepare: the real buttons, before the first footprint.
        let prepared = driver.setExpand(expand.title, open: true, step: 300)
            && driver.element(expand.first).waitForExistence(timeout: 10)
            && driver.setExpand(titles[1], open: true, step: 300)
        if !prepared { series.failures.append("\(arm): the expands did not open") }
        _ = driver.scroll(by: -300, until: driver.element(expand.nestedFirst ?? expand.first), maxDrags: 6)
        reader.drag(by: 100)
        reader.pause()
        /// One About visit (or more), the same queries in both arms, top to
        /// bottom (`revealAboutField` never scrolls back): the arm's count
        /// (waited for; the control's rebuilt rows wait for 0 after OFF),
        /// the other kind's, then the container and off-window counts. An
        /// OFF under TextKit 2 re-reads, closing and reopening About, until
        /// `tk2Live − tk2OffWindow == 0`, for up to 5 s from the pick.
        func about(on: Bool, first: Int?) -> (waited: Int, other: Int, offWindow: Int, container: Int) {
            let (waitedID, otherID) = control
                ? (ReaderDriver.Identifier.rebuildControlRows, ReaderDriver.Identifier.liveTextKit2Rows)
                : (ReaderDriver.Identifier.liveTextKit2Rows, ReaderDriver.Identifier.rebuildControlRows)
            var waited = -1, other = -1, offWindow = -1, container = -1
            let deadline = Date().addingTimeInterval(5)
            repeat {
                reader.openAbout()
                waited = reader.readCount(waitedID, until: { count in
                    on ? count > 0 && (first == nil || count == first) : (control ? count == 0 : true)
                }, settled: true) ?? -1
                other = reader.readCount(otherID, until: { _ in true }) ?? -1
                container = reader.readOptionalCount(ReaderDriver.Identifier.liveTextKit2ContainerRows) ?? -1
                offWindow = reader.readOptionalCount(ReaderDriver.Identifier.offWindowTextKit2Rows) ?? -1
                reader.closeAbout()
                let live = control ? other : waited
                if on || live - offWindow == 0 { break }
            } while Date() < deadline
            return (waited, other, offWindow, container)
        }
        var on: [Int] = [], onOther: [Int] = [], onContainer: [Int] = [], offLive: [Int] = [], offWindows: [Int] = []
        var offInTree: [Int] = []
        var values: [[String]] = []
        do {
            let start = try agent.settledFootprintKB()
            var settled: [Int] = []
            for flip in 1 ... 20 {
                let isOn = flip % 2 == 1
                reader.chooseRenderer(textKit2: isOn)
                let pickValues = titles.map { driver.expandValue($0) ?? "missing" }
                values.append(pickValues)
                if pickValues != ["Expanded", "Expanded"] {
                    series.failures.append("\(arm) pick \(flip): titles read \(pickValues)")
                }
                if !isOn {
                    offInTree.append(reader.waitForDisappearance(of: reader.anyTextKit2Row, timeout: 5) ? 0 : 1)
                }
                let rows = about(on: isOn, first: on.first)
                if isOn {
                    on.append(rows.waited)
                    onOther.append(rows.other)
                    onContainer.append(rows.container)
                    if control ? rows.container != 0 : rows.container <= 0 {
                        series.failures.append("\(arm) ON pick \(flip): \(rows.container) live container rows")
                    }
                } else {
                    let live = control ? rows.other : rows.waited
                    offLive.append(live)
                    offWindows.append(rows.offWindow)
                    if control ? rows.waited != 0 : live - rows.offWindow != 0 {
                        series.failures.append("\(arm) OFF pick \(flip): live \(live), off-window \(rows.offWindow)"
                            + (control ? ", rebuilt \(rows.waited)" : ""))
                    }
                    settled.append(try agent.settledFootprintKB())
                }
            }
            series.growth = (settled.last ?? start) - start
            if !(on.allSatisfy { $0 > 0 && $0 == on.first } && onOther.allSatisfy { $0 == 0 }) {
                series.failures.append("\(arm): ON counts \(on), other kind \(onOther)")
            }
            if offInTree.contains(1) { series.failures.append("\(arm): a tk2-row stayed in the tree after an OFF pick") }
            // The census after the series: one more ON pick.
            reader.chooseRenderer(textKit2: true)
            let census = try reader.documentSnapshot()
            let counters = reader.liveRowCounters()
            if control {
                if !census.textKit2Rows.isEmpty { series.failures.append("control: TextKit 2 rows in the census") }
            } else {
                if census.containerOwnedRows == 0 { series.failures.append("TextKit 2: no container rows in the census") }
                let check = census.census.crossCheck(counters)
                if !check.isEmpty { series.failures.append("TextKit 2 census: \(check)") }
                if (counters.container ?? 0) <= 0 { series.failures.append("TextKit 2 census: no live container rows") }
            }
            // Closing OFF, then a retrace of the materialised region.
            reader.chooseRenderer(textKit2: false)
            let immediate = reader.liveRowCounters()
            let immediateLive = reader.liveTextKit2Rows(until: { _ in true }, settled: true) ?? -1
            for distance: CGFloat in [600, 600, -600, -600, -600, -600, 600, 600] {
                reader.drag(by: distance)
                reader.pause(0.5)
            }
            let retraced = reader.liveTextKit2Rows(until: { $0 == 0 }, settled: true) ?? -1
            if retraced != 0 { series.failures.append("\(arm): \(retraced) live rows after the retrace") }
            series.figures = [
                "arm": arm, "on_rows": on, "on_other_kind_rows": onOther, "on_container_rows": onContainer,
                "off_live_rows": offLive,
                "off_window_rows": offWindows, "off_tk2_rows_in_tree": offInTree, "titles_after_each_pick": values,
                "start_kb": start, "after_each_off_kb": settled, "growth_kb": series.growth,
                "census_after_series": census.census.figures,
                "census_counters": ["live": counters.total ?? -1, "list": counters.list ?? -1, "code": counters.code ?? -1,
                                    "container": counters.container ?? -1, "caption": counters.caption ?? -1,
                                    "offwindow": counters.offWindow ?? -1],
                "census_rows": census.census.rows,
                "census_code_owners_by_tree": census.codeOwnersByTree.sorted(),
                "census_code_owners_by_geometry": census.codeOwnersByGeometry.sorted(),
                "census_identity_recorded": (counters.total ?? -1) - (counters.offWindow ?? 0) == census.census.rows,
                "closing_off": ["live": immediateLive, "offwindow": immediate.offWindow ?? -1, "retraced_live": retraced],
            ]
        } catch {
            series.failures.append("\(arm): series failed: \(error)")
        }
        reader.app.terminate()
        return series
    }

    // MARK: K7 — open and close cycles

    /// One K7 arm (one launch).
    private struct K7Arm {
        var openSeconds: [Double] = []
        var nestedSeconds: [Double] = []
        var returnSeconds: [Double] = []
        var settleSeconds: [Double] = []
        var cycles = 0
        var growthKB = Int.max
        var failures: [String] = []
        var figures: [String: Any] = [:]
    }

    /// K7 (plan §8.3, f26): real buttons on CE-OPEN-1 … 5, arm B (SwiftUI)
    /// then arm C (TextKit 2), each in its own launch. Per expand a fixed
    /// cycle: open (timed from before the tap to its last body paragraph
    /// existing), close, reopen (timed), nested open (timed to N4),
    /// re-entry (away until the body has left the tree, back by
    /// `ContainerDriver.seek`: the first leaf within 5 s of the title
    /// arriving), CPU settle, close (so the footprint after the five cycles
    /// is taken with every body closed, as the one before them). Recorded:
    /// requested and observed open ids, completed cycles, owners, About's
    /// counters before and after, time and raw settled footprint. Limits:
    /// every cycle completes; CPU settles ≤ 5 s and every return ≤ 5 s;
    /// footprint growth within `maxGrowthKB`, read as B against C: arm C's
    /// growth minus arm B's (as K6 and M4 compare TextKit 2 with its
    /// SwiftUI control; the B-only pilot grew 20,512 KB on SwiftUI alone);
    /// arm C's median open time ≤
    /// `ContainerLifecycleLimits.k7OpenSeconds`, and per expand the median
    /// of its open and reopen ≤ its own
    /// `ContainerLifecycleLimits.k7OpenSecondsPerExpand` (both frozen from
    /// the same B-only pilot: `ADF_CONTAINER_LIMITS_PILOT=1` runs arm B
    /// alone and gates only completeness). Passes after step 5.
    func testK7ExpandOpenCloseCycles() throws {
        let agent = try HostAgent.fromEnvironment()
        let pilot = ContainerLifecycleLimits.isPilot
        var arms: [Bool: K7Arm] = [:]
        for textKit2 in pilot ? [false] : [false, true] {
            arms[textKit2] = try k7Cycles(agent, textKit2: textKit2)
        }
        let b = arms[false] ?? K7Arm()
        var failures = (arms.values.flatMap(\.failures))
        var figures: [String: Any] = [
            "arms": arms.map { entry -> [String: Any] in
                ["arm": entry.key ? "textkit2" : "swiftui", "figures": entry.value.figures]
            },
            "provenance": ContainerLifecycleLimits.provenance, "pilot": pilot,
        ]
        if pilot {
            let limit = ContainerLifecycleLimits.formula(b.openSeconds) ?? -1
            figures["pilot_open_samples_s"] = b.openSeconds
            figures["pilot_limit_s"] = limit
            figures["pilot_growth_kb"] = b.growthKB
            let samples = b.openSeconds.map { String(format: "%.3f", $0) }.joined(separator: ",")
            print("K7_PILOT_SAMPLES=\(samples)")
            print(String(format: "K7_PILOT_LIMIT=%.3f", limit))
        } else if let c = arms[true] {
            let cMedian = ContainerLifecycleLimits.median(c.openSeconds)
            figures["c_open_median_s"] = cMedian
            figures["b_open_median_s"] = ContainerLifecycleLimits.median(b.openSeconds)
            let excess = c.growthKB - b.growthKB
            figures["growth_kb"] = ["b": b.growthKB, "c": c.growthKB, "c_minus_b": excess, "limit": Self.maxGrowthKB]
            if excess > Self.maxGrowthKB {
                failures.append("footprint: arm C grew \(c.growthKB) KB, \(excess) KB more than arm B's \(b.growthKB) KB")
            }
            if let limit = ContainerLifecycleLimits.k7OpenSeconds {
                figures["limit_s"] = limit
                if cMedian > limit { failures.append("arm C median open \(cMedian) s > frozen limit \(limit) s") }
            } else {
                failures.append("ContainerLifecycleLimits.k7OpenSeconds is not frozen")
            }
            // Per expand: the cycles store (open, reopen) for CE-OPEN-1 … 5
            // in order.
            let perExpand = ContainerLifecycleLimits.k7OpenSecondsPerExpand
            var expandFigures: [[String: Any]] = []
            for (index, limit) in perExpand.enumerated() {
                let pair = Array(c.openSeconds.dropFirst(2 * index).prefix(2))
                let b2 = Array(b.openSeconds.dropFirst(2 * index).prefix(2))
                let median = pair.count == 2 ? ContainerLifecycleLimits.median(pair) : .infinity
                expandFigures.append(["expand": "CE-OPEN-\(index + 1)", "c_open_reopen_s": pair,
                                      "b_open_reopen_s": b2, "c_median_s": pair.count == 2 ? median : -1,
                                      "limit_s": limit])
                if pair.count != 2 {
                    failures.append("CE-OPEN-\(index + 1): arm C has \(pair.count) of 2 open samples")
                } else if median > limit {
                    failures.append("CE-OPEN-\(index + 1): arm C median open \(median) s > its frozen limit \(limit) s")
                }
            }
            figures["per_expand"] = expandFigures
        }
        try agent.record("K7 expand open/close cycles (containers-expand CE-OPEN-1…5)\(pilot ? " — B-only pilot" : "")",
                         pass: failures.isEmpty, figures.merging(["failures": failures]) { first, _ in first })
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
    }

    private func k7Cycles(_ agent: HostAgent, textKit2: Bool) throws -> K7Arm {
        typealias CE = ContainersExpand
        let arm = textKit2 ? "textkit2" : "swiftui"
        var result = K7Arm()
        let driver = ContainerDriver(fixture: CE.fixture, textKit2: textKit2, fraction: CE.fraction(CE.openHeadingIndex[0]))
        let reader = driver.reader
        reader.waitForRenderer(textKit2 ? "TextKit 2" : "SwiftUI")
        XCTAssertTrue(reader.element(labelled: CE.openHeading(1)).waitForExistence(timeout: 30), "containers-expand missing")
        reader.drag(by: 100)
        reader.pause()
        let start = try agent.settledFootprintKB()
        let countersBefore = reader.liveRowCounters()
        var cycles: [[String: Any]] = []
        /// Wall time from before the tap (`tap()` waits for the app to idle)
        /// to `target` existing, polled every 50 ms; nil when it never did
        /// within 30 s.
        func timedTap(_ button: XCUIElement, until target: XCUIElement) -> Double? {
            let tapped = Date()
            button.tap()
            return ContainerDriver.seconds(until: target, since: tapped, timeout: 30)
        }
        for n in 1 ... 5 {
            let expand = CE.open(n)
            let name = "\(arm) \(expand.id)"
            let button = driver.expandButton(expand.title)
            let index = Double(CE.openHeadingIndex[n - 1] + 1)
            let arrival = driver.seek(button, at: index)
            guard arrival.shown else {
                result.failures.append("\(name): the title never came into view (\(arrival.figures))")
                break
            }
            var observed: [String] = []
            guard let open = timedTap(button, until: driver.element(expand.last)) else {
                result.failures.append("\(name): the body never mounted")
                break
            }
            observed.append(driver.expandValue(expand.title) ?? "missing")
            button.tap()
            let closed = reader.waitForDisappearance(of: driver.element(expand.first), timeout: 10)
            observed.append(driver.expandValue(expand.title) ?? "missing")
            guard closed, let reopen = timedTap(button, until: driver.element(expand.last)) else {
                result.failures.append("\(name): close/reopen failed (closed: \(closed))")
                break
            }
            observed.append(driver.expandValue(expand.title) ?? "missing")
            let engineOK = textKit2 ? driver.isTextKit2(expand.first, timeout: 10) : driver.isSwiftUI(expand.first, timeout: 2)
            if !engineOK { result.failures.append("\(name): \(expand.first) has the wrong engine") }
            let nestedButton = driver.expandButton(expand.nestedTitle ?? "")
            guard driver.scroll(by: 300, until: nestedButton, maxDrags: 10), let nestedLast = expand.nestedLast,
                  let nested = timedTap(nestedButton, until: driver.element(nestedLast)) else {
                result.failures.append("\(name): the nested expand did not open")
                break
            }
            observed.append(driver.expandValue(expand.nestedTitle ?? "") ?? "missing")
            // Re-entry: away until the body has left the tree, then back.
            var drags = 0
            while driver.element(expand.first).exists || driver.element(expand.last).exists, drags < 15 {
                reader.drag(by: 600)
                drags += 1
            }
            let released = !driver.element(expand.first).exists
            let reentry = released ? driver.seek(button, at: index) : ContainerDriver.Seek()
            guard released, reentry.shown else {
                result.failures.append("\(name): re-entry failed (released: \(released), \(reentry.figures))")
                break
            }
            let arrived = Date()
            let returned = ContainerDriver.seconds(until: driver.element(expand.first), since: arrived,
                                                   timeout: Self.maxSettleSeconds)
            if returned == nil { result.failures.append("\(name): \(expand.first) not back within 5 s") }
            if driver.expandValue(expand.title) != "Expanded" { result.failures.append("\(name): closed after re-entry") }
            let settle = try agent.cpuSettleSeconds().seconds ?? .infinity
            if settle > Self.maxSettleSeconds { result.failures.append("\(name): CPU settled in \(settle) s") }
            // Close it again, so the footprint after the five cycles is taken
            // in the state the one before them was (every body closed).
            button.tap()
            let reclosed = reader.waitForDisappearance(of: driver.element(expand.first), timeout: 10)
            observed.append(driver.expandValue(expand.title) ?? "missing")
            if !reclosed { result.failures.append("\(name): the body did not close after the cycle") }
            result.openSeconds += [open, reopen]
            result.nestedSeconds.append(nested)
            result.returnSeconds.append(returned ?? .infinity)
            result.settleSeconds.append(settle)
            result.cycles += 1
            cycles.append(["requested": [expand.id, expand.id, expand.id, "\(expand.id).22", expand.id],
                           "observed_values": observed, "open_s": open, "reopen_s": reopen, "nested_s": nested,
                           "arrival": arrival.figures, "away_drags": drags, "reentry": reentry.figures,
                           "return_s": returned ?? -1, "settle_s": settle])
        }
        let countersAfter = reader.liveRowCounters()
        let end = try agent.settledFootprintKB()
        result.growthKB = end - start
        reader.app.terminate()
        if result.cycles != 5 { result.failures.append("\(arm): \(result.cycles) of 5 cycles completed") }
        func counters(_ value: LiveRowCounters) -> [String: Int] {
            ["list": value.list ?? -1, "code": value.code ?? -1, "container": value.container ?? -1,
             "caption": value.caption ?? -1, "offwindow": value.offWindow ?? -1]
        }
        result.figures = [
            "cycles": cycles, "completed": result.cycles, "start_kb": start, "end_kb": end, "growth_kb": result.growthKB,
            "counters_before": counters(countersBefore), "counters_after": counters(countersAfter),
            "open_s": result.openSeconds, "nested_s": result.nestedSeconds, "return_s": result.returnSeconds,
        ]
        return result
    }

    // MARK: K8 — tall expand mount and flip

    /// One K8 launch.
    private struct K8Run {
        let textKit2: Bool
        var mount: Double?
        var mountSettle: Double?
        var footprintKB: Int?
        var flip: Double?
        var flipSettle: Double?
        var failures: [String] = []
        var figures: [String: Any] = [:]
    }

    /// K8 (plan §8.5, f24): CE-TALL (300 plain paragraphs) on
    /// containers-expand, five launches per arm alternating B (SwiftUI with
    /// `-rebuildControlPicks 1`, the matched rebuild control) and C
    /// (`-textkit2`). Per launch: M2 mount time (from before the tap on the
    /// title to CE-TALL-300 existing), M3 CPU settle after the mount, M4
    /// settled footprint with the body open, then a flip with the body
    /// open — B: a TextKit 2 pick the control rebuilds as SwiftUI; C: OFF,
    /// then the timed ON — timed from just before the menu item's tap to
    /// the toolbar naming the new renderer and CE-TALL-300 drawn by it (C:
    /// its `tk2-row`; B: its rebuilt SwiftUI text), so the switch's work is
    /// inside the time (`ReaderDriver.chooseRendererTimed`), and M3 after
    /// it. Limits: C's median mount ≤
    /// `ContainerLifecycleLimits.m2MountSeconds` and C's median flip time ≤
    /// `ContainerLifecycleLimits.m2FlipSeconds` (each frozen from a B-only
    /// pilot); every settle ≤ 2 % within 5 s (the post-flip one is the
    /// livelock check); median footprint C − B ≤ 15 % of B's; C's median
    /// flip settle ≤ the M2 formula over this run's B flip settles.
    /// `ADF_CONTAINER_LIMITS_PILOT=1` runs B alone (the pilot of both
    /// times). Passes after step 5.
    func testK8TallExpandMountAndFlip() throws {
        let agent = try HostAgent.fromEnvironment()
        let pilot = ContainerLifecycleLimits.isPilot
        var runs: [K8Run] = []
        for launch in 1 ... 5 {
            for textKit2 in pilot ? [false] : (launch % 2 == 1 ? [false, true] : [true, false]) {
                runs.append(try k8Launch(agent, textKit2: textKit2))
            }
        }
        let b = runs.filter { !$0.textKit2 }, c = runs.filter(\.textKit2)
        var failures = runs.flatMap(\.failures)
        let settles = runs.flatMap { [$0.mountSettle, $0.flipSettle] }.map { $0 ?? .infinity }
        if settles.contains(where: { $0 > Self.maxSettleSeconds }) { failures.append("M3: CPU settle \(settles) s") }
        let bMounts = b.compactMap(\.mount), cMounts = c.compactMap(\.mount)
        var figures: [String: Any] = [
            "runs": runs.map(\.figures), "pilot": pilot, "provenance": ContainerLifecycleLimits.provenance,
            "b_mount_s": bMounts, "c_mount_s": cMounts,
        ]
        let bFlipTimes = b.compactMap(\.flip), cFlipTimes = c.compactMap(\.flip)
        figures["b_flip_s"] = bFlipTimes
        figures["c_flip_s"] = cFlipTimes
        if pilot {
            let limit = ContainerLifecycleLimits.formula(bMounts) ?? -1
            figures["pilot_limit_s"] = limit
            print("M2_PILOT_SAMPLES=" + bMounts.map { String(format: "%.3f", $0) }.joined(separator: ","))
            print(String(format: "M2_PILOT_LIMIT=%.3f", limit))
            if bMounts.count != 5 { failures.append("pilot: \(bMounts.count) of 5 mounts measured") }
            let flipLimit = ContainerLifecycleLimits.formula(bFlipTimes) ?? -1
            figures["pilot_flip_limit_s"] = flipLimit
            print("M2_FLIP_PILOT_SAMPLES=" + bFlipTimes.map { String(format: "%.3f", $0) }.joined(separator: ","))
            print(String(format: "M2_FLIP_PILOT_LIMIT=%.3f", flipLimit))
            if bFlipTimes.count != 5 { failures.append("pilot: \(bFlipTimes.count) of 5 flips timed") }
        } else {
            let cMedian = ContainerLifecycleLimits.median(cMounts)
            figures["c_mount_median_s"] = cMedian
            if let limit = ContainerLifecycleLimits.m2MountSeconds {
                figures["m2_limit_s"] = limit
                if cMedian > limit { failures.append("M2: arm C median mount \(cMedian) s > frozen \(limit) s") }
            } else {
                failures.append("ContainerLifecycleLimits.m2MountSeconds is not frozen")
            }
            let bFoot = ContainerLifecycleLimits.median(b.compactMap(\.footprintKB).map(Double.init))
            let cFoot = ContainerLifecycleLimits.median(c.compactMap(\.footprintKB).map(Double.init))
            figures["m4_footprint_median_kb"] = ["b": bFoot, "c": cFoot]
            if cFoot - bFoot > 0.15 * bFoot { failures.append("M4: C − B = \(cFoot - bFoot) KB > 15 % of \(bFoot) KB") }
            let bFlips = b.compactMap(\.flipSettle), cFlips = c.compactMap(\.flipSettle)
            let flipLimit = ContainerLifecycleLimits.formula(bFlips) ?? -1
            let cFlip = ContainerLifecycleLimits.median(cFlips)
            figures["flip_settle_s"] = ["b": bFlips, "c": cFlips, "limit": flipLimit]
            if cFlip > flipLimit { failures.append("M2 flip: C median settle \(cFlip) s > \(flipLimit) s (B formula)") }
            let cFlipTime = ContainerLifecycleLimits.median(cFlipTimes)
            figures["c_flip_median_s"] = cFlipTime
            if cFlipTimes.count != c.count { failures.append("M2 flip: \(cFlipTimes.count) of \(c.count) arm C flips timed") }
            if let limit = ContainerLifecycleLimits.m2FlipSeconds {
                figures["m2_flip_limit_s"] = limit
                if cFlipTime > limit { failures.append("M2 flip: arm C median flip \(cFlipTime) s > frozen \(limit) s") }
            } else {
                failures.append("ContainerLifecycleLimits.m2FlipSeconds is not frozen")
            }
        }
        try agent.record("K8 tall expand mount and flip (containers-expand CE-TALL)\(pilot ? " — B-only pilot" : "")",
                         pass: failures.isEmpty, figures.merging(["failures": failures]) { first, _ in first })
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
    }

    private func k8Launch(_ agent: HostAgent, textKit2: Bool) throws -> K8Run {
        typealias CE = ContainersExpand
        let arm = textKit2 ? "textkit2" : "swiftui"
        var run = K8Run(textKit2: textKit2)
        let driver = ContainerDriver(fixture: CE.fixture, textKit2: textKit2, fraction: CE.fraction(CE.s2Index),
                                     extra: ["-rebuildControlPicks", textKit2 ? "0" : "1"])
        let reader = driver.reader
        reader.waitForRenderer(textKit2 ? "TextKit 2" : "SwiftUI")
        XCTAssertTrue(reader.element(labelled: CE.s2).waitForExistence(timeout: 30), "containers-expand missing")
        reader.drag(by: 100)
        reader.pause()
        let button = driver.expandButton(CE.tall.title)
        guard driver.scroll(by: 300, until: button, maxDrags: 5) else {
            run.failures.append("\(arm): CE-TALL's title is not in view")
            reader.app.terminate()
            return run
        }
        _ = try agent.cpuSettleSeconds()
        let tapped = Date()
        button.tap()
        run.mount = ContainerDriver.seconds(until: driver.element(CE.tall.last), since: tapped, timeout: 60)
        if run.mount == nil { run.failures.append("\(arm): CE-TALL-300 never existed") }
        run.mountSettle = try agent.cpuSettleSeconds().seconds
        let engineOK = textKit2 ? driver.isTextKit2(CE.tall.first, timeout: 10)
            : driver.isSwiftUI(CE.tall.first, timeout: 2)
        if !engineOK { run.failures.append("\(arm): \(CE.tall.first) has the wrong engine") }
        run.footprintKB = try agent.settledFootprintKB()
        var rebuilt = -1
        if textKit2 {
            reader.chooseRenderer(textKit2: false)
            if !reader.waitForDisappearance(of: driver.textKit2Row(owner: CE.tall.last.owner), timeout: 10) {
                run.failures.append("\(arm): CE-TALL-300's TextKit 2 row outlived the OFF pick")
            }
            _ = try agent.cpuSettleSeconds()
            run.flip = reader.chooseRendererTimed(textKit2: true, until: driver.textKit2Row(owner: CE.tall.last.owner))
            run.flipSettle = try agent.cpuSettleSeconds().seconds
        } else {
            run.flip = reader.chooseRendererTimed(textKit2: true, until: driver.element(CE.tall.last))
            run.flipSettle = try agent.cpuSettleSeconds().seconds
            rebuilt = reader.liveRows(control: true, until: { $0 > 0 }, settled: true).control ?? -1
            if rebuilt <= 0 { run.failures.append("\(arm): the rebuild control rebuilt no rows") }
            reader.chooseRenderer(textKit2: false)
        }
        if run.flip == nil { run.failures.append("\(arm): the flip never completed within 60 s") }
        if driver.expandValue(CE.tall.title) != "Expanded" { run.failures.append("\(arm): CE-TALL closed on the flip") }
        reader.app.terminate()
        run.figures = ["arm": arm, "mount_s": run.mount ?? -1, "mount_settle_s": run.mountSettle ?? -1,
                       "footprint_kb": run.footprintKB ?? -1, "flip_s": run.flip ?? -1, "flip_settle_s": run.flipSettle ?? -1,
                       "control_rebuilt_rows": rebuilt, "engine_ok": engineOK]
        return run
    }

    // MARK: K10 — fling, thrash and soak on containers-dense

    func testK10aFlingThrashSoakContainersSwiftUI() throws {
        try flingThrashSoak(textKit2: false, fixture: ContainersDense.fixture, landmark: ContainersDense.first,
                            containerProof: true)
    }

    /// K10b passes after step 3.
    func testK10bFlingThrashSoakContainersTextKit2() throws {
        try flingThrashSoak(textKit2: true, fixture: ContainersDense.fixture, landmark: ContainersDense.first,
                            containerProof: true)
    }
}
