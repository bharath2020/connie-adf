import XCTest

/// PR 4 plan §10.1: the container storyboard, paced for a screen recording
/// by `Scripts/e2e-video.sh --test containers` from the same build as the
/// switch, list and code storyboards. Like them it reads the running
/// executable's SHA-256 off About This Build, prints
/// `OBSERVED_BUILD_SHA256=…`, and fails with "on-screen checksum differs
/// from the built binary" unless it equals `ADF_EXPECTED_BUILD_SHA256`
/// (`TEST_RUNNER_ADF_EXPECTED_BUILD_SHA256`), so the script's wrong-digest
/// negative control works for it too.
///
/// It walks every family's landmark with the switch ON and shows live
/// flips: panels and nested quotes (five position-checked round trips), an
/// open outer and nested expand, a task child and a code child (panned,
/// Copy tapped, flipped with the body open, collapsed and reopened, away and
/// back), columns, an extension body, a search inside a nested expand, then
/// captions-parity (a plain, a linked and an atom caption; a caption
/// search), and finishes with the switch OFF, a retrace and no live rows.
/// The exact Copy bytes are asserted by the lifecycle-gate run of
/// `ContainerRendererUITests` (§7.5); `e2e-video.sh` starts no pasteboard
/// agent.
///
/// `ADF_CONTAINER_NAVIGATION_ONLY=1` (a dry run before every family is
/// enabled; never set for a recording) turns the engine assertions into
/// notes so the walk itself can be checked; the checksum assertion stays.
@MainActor
final class ContainerStoryboardUITests: XCTestCase {
    private typealias KP = ContainersParity
    private static let shiftLimit: CGFloat = 2.01
    private static let roundTrips = 5
    private static let navigationOnly = ProcessInfo.processInfo.environment["ADF_CONTAINER_NAVIGATION_ONLY"] == "1"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Recording pace.
    private func pause(_ seconds: TimeInterval = 1) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// The engine `leaf` must have; a note instead of an assertion in a
    /// navigation-only dry run.
    private func engine(_ driver: ContainerDriver, _ leaf: ContainerLeaf, textKit2: Bool, _ context: String) {
        if Self.navigationOnly {
            let actual = driver.textKit2Row(owner: leaf.owner).waitForExistence(timeout: textKit2 ? 5 : 1)
            containerUINote("NAVIGATION_ONLY \(context): \(leaf) wanted \(textKit2 ? "TextKit 2" : "SwiftUI"), "
                + "is \(actual ? "TextKit 2" : "SwiftUI")")
        } else {
            driver.expectEngine(leaf, textKit2: textKit2, context)
        }
    }

    private func check(_ condition: Bool, _ message: String) {
        if Self.navigationOnly {
            if !condition { containerUINote("NAVIGATION_ONLY: \(message)") }
        } else {
            XCTAssertTrue(condition, message)
        }
    }

    func testContainerStoryboard() throws {
        if Self.navigationOnly { print("ADF_CONTAINER_NAVIGATION_ONLY=1: engine assertions are notes") }
        var driver = ContainerDriver(fixture: KP.fixture)
        var reader = driver.reader
        var app = driver.app
        let scale = reader.pixelScale()

        try containerUIStep("1. Open containers-parity on SwiftUI; About shows the executable checksum") {
            reader.waitForRenderer("SwiftUI")
            XCTAssertTrue(reader.element(labelled: KP.s1).waitForExistence(timeout: 30), "containers-parity did not render")
            XCTAssertFalse(reader.anyTextKit2Row.exists && driver.textKit2Row(owner: KP.panelP1.owner).exists,
                           "a container TextKit 2 row exists while SwiftUI is active")
            pause()
            containerUIAttach(app, "01-containers-parity-swiftui")
            driver.openAbout()
            XCTAssertEqual(app.staticTexts[ReaderDriver.Identifier.buildRenderer].label, "SwiftUI")
            let live = reader.readLiveTextKit2Rows(until: { $0 == 0 })
            XCTAssertEqual(live, 0, "TextKit 2 rows are alive on the SwiftUI renderer")
            reader.revealAboutField(app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH %@", ReaderDriver.Identifier.buildSHA256)
            ).firstMatch)
            let sha = app.staticTexts[ReaderDriver.Identifier.buildSHA256]
            XCTAssertTrue(sha.waitForExistence(timeout: 20), "checksum never appeared")
            let observed = sha.label
            XCTAssertEqual(observed.count, 64, "expected 64 hex characters, got \(observed)")
            XCTAssertTrue(observed.allSatisfy { $0.isHexDigit && !$0.isUppercase },
                          "checksum is not lowercase hex: \(observed)")
            // Picked up by Scripts/e2e-video.sh from the xcodebuild log.
            print("OBSERVED_BUILD_SHA256=\(observed)")
            containerUINote("OBSERVED_BUILD_SHA256=\(observed)")
            let expected = (ProcessInfo.processInfo.environment["ADF_EXPECTED_BUILD_SHA256"] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            XCTAssertFalse(expected.isEmpty,
                           "ADF_EXPECTED_BUILD_SHA256 is not set; pass TEST_RUNNER_ADF_EXPECTED_BUILD_SHA256 to xcodebuild")
            XCTAssertEqual(observed, expected, "on-screen checksum differs from the built binary")
            pause()
            containerUIAttach(app, "01b-about-this-build")
            driver.closeAbout()
        }

        let nested = [ContainerLeaf("KP-NEST-QP-OUTER", "0.32.0"), ContainerLeaf("KP-NEST-QP-INNER", "0.32.1.0"),
                      ContainerLeaf("KP-NEST-PQ-OUTER", "0.33.0"), ContainerLeaf("KP-NEST-PQ-INNER", "0.33.1.0")]
        try containerUIStep("2. A panel and a nested quote: switch ON, named owners draw natively; five round trips") {
            driver.jump(toHeading: KP.s4, settleDrag: 0)
            XCTAssertTrue(driver.scroll(by: 200, until: driver.element(nested[3]), maxDrags: 8), "KP-S4 is not in view")
            reader.drag(by: 40)
            pause()
            containerUIAttach(app, "02a-nested-containers-swiftui")
            reader.chooseRenderer(textKit2: true)
            pause(1.5)
            for leaf in nested { engine(driver, leaf, textKit2: true, "switch ON") }
            containerUIAttach(app, "02b-nested-containers-textkit2")
            let container = driver.aboutCount(ReaderDriver.Identifier.liveTextKit2ContainerRows) ?? -1
            check(container > 0, "About counts \(container) live container rows after switching ON")
            let origin = try reader.documentSnapshot()
            var last = origin.tops
            for trip in 1 ... Self.roundTrips {
                for textKit2 in [false, true] {
                    reader.chooseRenderer(textKit2: textKit2)
                    pause()
                    for leaf in nested { engine(driver, leaf, textKit2: textKit2, "trip \(trip)") }
                    let now = try reader.documentSnapshot().tops
                    let shift = LabelShift(from: last, to: now, scale: scale)
                    containerUINote(String(format: "Trip %ld → %@: %ld labels, worst %.2f px (%@)", trip,
                                           textKit2 ? "TextKit 2" : "SwiftUI", shift.common, shift.maxPixels,
                                           shift.worstLabel))
                    XCTAssertGreaterThan(shift.common, 0, "no label in common (trip \(trip))")
                    XCTAssertLessThanOrEqual(shift.maxPixels, Self.shiftLimit,
                                             "\(shift.worstLabel) moved \(shift.maxPixels) px (trip \(trip))")
                    last = now
                }
            }
            let drift = LabelShift(from: origin.tops, to: last, scale: scale)
            XCTAssertLessThanOrEqual(drift.maxPixels, Self.shiftLimit, "the labels drifted over \(Self.roundTrips) round trips")
            containerUIAttach(app, "02c-round-trips-done")
        }

        let outer = KP.expandOuter
        try containerUIStep("3a. Open the outer and the nested expand; the body draws on TextKit 2") {
            driver.jump(toHeading: KP.s8, settleDrag: 0)
            XCTAssertTrue(driver.setExpand(outer.title, open: true, step: 200), "the outer expand did not open")
            XCTAssertTrue(driver.setExpand(outer.nestedTitle ?? "", open: true, step: 200), "the nested expand did not open")
            pause()
            for leaf in [outer.first, outer.nestedFirst, outer.nestedLast].compactMap({ $0 }) {
                engine(driver, leaf, textKit2: true, "open expand")
            }
            containerUIAttach(app, "03a-open-expands-textkit2")
            let list = ContainerExpand(title: "KP-LIST-EXPAND lists inside an expand", id: "0.66",
                                       first: ContainerLeaf("KP-LIST-EXPAND-A", "0.66.0.0"),
                                       last: ContainerLeaf("KP-LIST-EXPAND-TASK", "0.66.1.0"))
            driver.jump(toHeading: KP.s9, settleDrag: 0)
            XCTAssertTrue(driver.setExpand(list.title, open: true, step: 250), "KP-LIST-EXPAND did not open")
            XCTAssertTrue(driver.scroll(by: 200, until: driver.element(list.last), maxDrags: 6), "the task child is not in view")
            engine(driver, list.first, textKit2: true, "list child")
            engine(driver, list.last, textKit2: true, "task child")
            pause()
            containerUIAttach(app, "03b-list-and-task-children")
        }

        let codeExpand = KP.codeExpand
        let code = codeExpand.last
        try containerUIStep("3b. A code child: pan it, tap Copy, flip with the body open, collapse and reopen, away and back") {
            driver.jump(toHeading: KP.s10, settleDrag: 0)
            XCTAssertTrue(driver.setExpand(codeExpand.title, open: true, step: 250), "KP-CODE-EXPAND did not open")
            let text = driver.element(code)
            XCTAssertTrue(driver.scroll(by: 200, until: text, maxDrags: 8), "the code child is not in view")
            engine(driver, code, textKit2: true, "code child")
            let rest = text.frame.minX
            let start = try XCTUnwrap(reader.panStart(onCodeText: text.frame), "no pan start on the code child")
            reader.pan(from: start, by: 230)
            pause()
            let offset = rest - text.frame.minX
            XCTAssertGreaterThanOrEqual(offset, 200, "the pan moved the code \(offset) pt")
            containerUIAttach(app, "03c-code-child-panned")
            let copy = app.buttons.matching(NSPredicate(format: "label == %@", ReaderDriver.Identifier.copyCodeLabel))
                .allElementsBoundByIndex.filter { $0.frame.maxY <= text.frame.minY + 4 }
                .min { text.frame.minY - $0.frame.maxY < text.frame.minY - $1.frame.maxY }
            try XCTUnwrap(copy, "no Copy button above the code child").tap()
            print("CONTAINER_CODE_COPY owner=\(code.owner) arm=textkit2 utf8_base64="
                + Data(text.label.utf8).base64EncodedString())
            pause()
            containerUIAttach(app, "03d-copy-tapped")
            for textKit2 in [false, true] {
                reader.chooseRenderer(textKit2: textKit2)
                pause()
                engine(driver, code, textKit2: textKit2, "flip with the body open")
                let now = rest - text.frame.minX
                XCTAssertLessThanOrEqual(abs(now - offset) * scale, Self.shiftLimit, "the flip moved the offset to \(now) pt")
                XCTAssertEqual(driver.expandValue(codeExpand.title), "Expanded", "the flip closed the expand")
            }
            containerUIAttach(app, "03e-flipped-with-body-open")
            XCTAssertTrue(driver.setExpand(codeExpand.title, open: false, step: -200), "the expand did not close")
            pause()
            XCTAssertTrue(driver.setExpand(codeExpand.title, open: true, step: -200), "the expand did not reopen")
            XCTAssertTrue(text.waitForExistence(timeout: 10), "the reopened body has no code")
            containerUIAttach(app, "03f-closed-and-reopened")
            for _ in 0 ..< 12 { reader.drag(by: -600) }
            pause()
            XCTAssertFalse(text.exists, "the code child never left the tree")
            containerUIAttach(app, "03g-away")
            driver.jump(toHeading: KP.s10, settleDrag: 0)
            XCTAssertTrue(driver.scroll(by: 200, until: text, maxDrags: 8), "the code child did not come back")
            XCTAssertEqual(driver.expandValue(codeExpand.title), "Expanded", "the expand lost its open state")
            engine(driver, code, textKit2: true, "after the return")
            pause()
            containerUIAttach(app, "03h-back-state-intact")
        }

        try containerUIStep("4. Columns and an extension body on TextKit 2") {
            driver.jump(toHeading: KP.s6, settleDrag: 0)
            XCTAssertTrue(driver.scroll(by: 200, until: driver.element(KP.col75B), maxDrags: 8), "the columns are not in view")
            for leaf in [KP.col25A, KP.col25B, KP.col75A, KP.col75H4, KP.col75B] {
                engine(driver, leaf, textKit2: true, "columns")
            }
            pause()
            containerUIAttach(app, "04a-columns-textkit2")
            driver.jump(toHeading: KP.s5, settleDrag: 0)
            XCTAssertTrue(driver.scroll(by: 200, until: driver.element(KP.extensionP2), maxDrags: 8),
                          "the extension body is not in view")
            XCTAssertTrue(driver.reader.element(labelled: KP.extensionLabel).exists, "the extension group lost its label")
            for leaf in [KP.extensionP1, KP.extensionH4, KP.extensionP2] {
                engine(driver, leaf, textKit2: true, "extension body")
            }
            pause()
            containerUIAttach(app, "04b-extension-body-textkit2")
        }

        try containerUIStep("5. Search inside the nested expand: the match falls back to SwiftUI and returns") {
            let match = try XCTUnwrap(outer.nestedFirst), neighbour = try XCTUnwrap(outer.nestedLast)
            let counter = driver.search(match.sentinel)
            XCTAssertTrue(counter.hasPrefix("1 /"), "counter \(counter)")
            engine(driver, match, textKit2: false, "highlighted")
            if driver.isPartlyShown(driver.element(neighbour)) { engine(driver, neighbour, textKit2: true, "neighbour") }
            pause()
            containerUIAttach(app, "05a-search-nested-expand")
            driver.clearSearch()
            engine(driver, match, textKit2: true, "search cleared")
            pause()
            containerUIAttach(app, "05b-search-cleared")
        }

        try containerUIStep("6. captions-parity on TextKit 2: a plain, a linked and an atom caption; a caption search") {
            app.terminate()
            // No -rendererReset: the toolbar's TextKit 2 pick persists.
            reader = ReaderDriver(launching: ["-fixture", CaptionsParity.fixture, "-rendererStats", "-fontSizeStep", "0",
                                              "-interactionProbe"])
            driver = ContainerDriver(wrapping: reader)
            app = reader.app
            reader.waitForRenderer("TextKit 2")
            XCTAssertTrue(driver.element(CaptionsParity.plain).waitForExistence(timeout: 30), "captions-parity missing")
            engine(driver, CaptionsParity.plain, textKit2: true, "plain caption")
            XCTAssertTrue(driver.scroll(by: 250, until: driver.element(CaptionsParity.linked), maxDrags: 6), "CAP-05 not in view")
            engine(driver, CaptionsParity.linked, textKit2: true, "linked caption")
            pause()
            containerUIAttach(app, "06a-captions-textkit2")
            XCTAssertTrue(driver.scroll(by: 250, until: driver.element(CaptionsParity.atoms), maxDrags: 10), "CAP-09 not in view")
            XCTAssertTrue(driver.isSwiftUI(CaptionsParity.atoms, timeout: 5), "the atom caption is a TextKit 2 row")
            pause()
            containerUIAttach(app, "06b-atom-caption-swiftui")
            let counter = driver.search("plain caption under")
            XCTAssertTrue(counter.hasPrefix("1 /"), "counter \(counter)")
            engine(driver, CaptionsParity.plain, textKit2: false, "highlighted caption")
            pause()
            containerUIAttach(app, "06c-caption-search")
            driver.clearSearch()
            engine(driver, CaptionsParity.plain, textKit2: true, "caption search cleared")
            pause()
            containerUIAttach(app, "06d-caption-search-cleared")
        }

        try containerUIStep("7. Finish on SwiftUI: no tk2-row on screen; none alive once the TextKit 2 path is retraced") {
            reader.chooseRenderer(textKit2: false)
            pause()
            XCTAssertTrue(reader.waitForDisappearance(of: reader.anyTextKit2Row, timeout: ContainerDriver.engineTimeout),
                          "a TextKit 2 row is still on screen")
            containerUIAttach(app, "07a-swiftui")
            let noRow = { XCTAssertFalse(reader.anyTextKit2Row.exists, "a TextKit 2 row appeared on SwiftUI while retracing") }
            XCTAssertTrue(driver.scroll(by: 400, until: driver.element(CaptionsParity.end), maxDrags: 20, afterEachDrag: noRow),
                          "the retrace never reached the end")
            XCTAssertTrue(driver.scroll(by: -400, until: reader.element(labelled: CaptionsParity.s1), maxDrags: 30,
                                        afterEachDrag: noRow), "the retrace never came back to the top")
            driver.openAbout()
            XCTAssertEqual(app.staticTexts[ReaderDriver.Identifier.buildRenderer].label, "SwiftUI")
            let live = reader.readLiveTextKit2Rows(until: { $0 == 0 })
            XCTAssertEqual(live, 0, "TextKit 2 rows are still alive after retracing on SwiftUI")
            pause()
            containerUIAttach(app, "07b-about-no-live-rows")
            driver.closeAbout()
        }
    }
}
