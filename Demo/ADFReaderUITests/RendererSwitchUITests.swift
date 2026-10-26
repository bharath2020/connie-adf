import XCTest

/// End-to-end proof that the reader's text-renderer switch is live: the same
/// document stays on screen, at the same place, while its rows change engine
/// — no relaunch. Paced for a screen recording (`Scripts/e2e-video.sh`):
/// every step pauses briefly and attaches a screenshot.
///
/// Launch arguments: `-fixture kitchen-sink` opens the fixture directly,
/// `-rendererReset` clears the persisted choice so the run always starts on
/// SwiftUI, and `-rendererStats` keeps the diagnostics line in the app log.
/// `ADF_EXPECTED_BUILD_SHA256` must be set in the runner's environment
/// (`TEST_RUNNER_ADF_EXPECTED_BUILD_SHA256=…` on the xcodebuild command line):
/// the test fails without it, and fails when the checksum About This Build
/// shows differs from it.
///
/// Renderer proof (not the toolbar label): with TextKit 2 on, the anchor
/// heading and "Heading two" are `tk2-row:<block id>` elements and About This
/// Build counts live TextKit 2 rows > 0; back on SwiftUI no `tk2-row:` element
/// remains and the count is 0. Scroll preservation: a parked heading's top
/// moves at most 2 px per switch and 2 px in total over five round trips.
///
/// Fixture strings come from `Fixtures/kitchen-sink.json` and must match the
/// rendered accessibility labels exactly.
@MainActor
final class RendererSwitchUITests: XCTestCase {
    private enum KitchenSink {
        static let title = "ADF Kitchen Sink"
        /// Levels 2–6, in document order; all plain text, so TextKit 2 draws
        /// them when it is on.
        static let headings = [
            "Heading two", "Heading three", "Heading four", "Heading five", "Heading six",
        ]
        /// The heading whose TextKit 2 row is asserted at the top of the document.
        static let proofHeading = "Heading two"
        /// Top-level paragraphs without inline atoms — the TextKit 2 path.
        static let plainParagraphs = ["Centered paragraph", "Indented paragraph"]
        /// Anything stable that can anchor a scroll position further down.
        static let landmarks = headings + [
            "A wise quotation.", "First bullet", "Second bullet", "Fourth item", "Fifth item",
            "Info panel", "Note panel", "Tip panel", "Success panel", "Warning panel",
            "Error panel", "Custom panel", "Name", "Role", "Status", "A captioned sunset",
            "Write the parser", "Design the schema", "Left column", "Right column",
            "Bodied extension content", "Synced content body",
        ]
    }

    private enum Identifier {
        static let rendererMenu = "renderer-menu"
        static let rendererActive = "renderer-active"
        static let rendererSwiftUI = "renderer-swiftui"
        static let rendererTextKit2 = "renderer-textkit2"
        static let about = "renderer-about"
        static let buildSHA256 = "build-sha256"
        static let buildVersion = "build-version"
        static let buildRenderer = "build-renderer"
        static let buildDone = "build-info-done"
        static let liveTextKit2Rows = "tk2-live-rows"
        static let textKit2RowPrefix = "tk2-row:"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLiveSwitchSwiftUIToTextKit2AndBack() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-fixture", "kitchen-sink", "-rendererReset", "-rendererStats"]
        app.launch()

        try step("1. Launch on the SwiftUI renderer") {
            waitForRenderer("SwiftUI", in: app)
            XCTAssertTrue(
                element(labelled: KitchenSink.title, in: app).waitForExistence(timeout: 15),
                "kitchen-sink did not render its title"
            )
            XCTAssertFalse(anyTextKit2Row(in: app).exists, "a TextKit 2 row exists while SwiftUI is active")
            pause()
            attach(app, "01-launch-swiftui")
        }

        try step("2. About This Build shows the executable checksum and no live TextKit 2 rows") {
            openAbout(app)
            let sha = app.staticTexts[Identifier.buildSHA256]
            XCTAssertTrue(sha.waitForExistence(timeout: 20), "checksum never appeared")
            let observed = sha.label
            XCTAssertEqual(observed.count, 64, "expected 64 hex characters, got \(observed)")
            XCTAssertTrue(
                observed.allSatisfy { $0.isHexDigit && !$0.isUppercase },
                "checksum is not lowercase hex: \(observed)"
            )
            XCTAssertTrue(app.staticTexts[Identifier.buildVersion].exists, "version row missing")
            XCTAssertEqual(app.staticTexts[Identifier.buildRenderer].label, "SwiftUI")
            // Picked up by Scripts/e2e-video.sh from the xcodebuild log.
            print("OBSERVED_BUILD_SHA256=\(observed)")
            XCTContext.runActivity(named: "OBSERVED_BUILD_SHA256=\(observed)") { _ in }

            let expected = (ProcessInfo.processInfo.environment["ADF_EXPECTED_BUILD_SHA256"] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            XCTAssertFalse(
                expected.isEmpty,
                "ADF_EXPECTED_BUILD_SHA256 is not set; pass TEST_RUNNER_ADF_EXPECTED_BUILD_SHA256 to xcodebuild"
            )
            XCTAssertEqual(observed, expected, "on-screen checksum differs from the built binary")

            let live = readLiveTextKit2Rows(in: app, until: { $0 == 0 })
            XCTAssertEqual(live, 0, "TextKit 2 rows are alive on the SwiftUI renderer")
            pause()
            attach(app, "02-about-this-build")
            closeAbout(app)
        }

        try step("3. Scroll down two screens and back to the top") {
            let scroll = app.scrollViews.firstMatch
            XCTAssertTrue(scroll.waitForExistence(timeout: 5), "document scroll view missing")
            scroll.swipeUp(velocity: .slow)
            pause()
            attach(app, "03a-swiftui-scrolled-once")
            scroll.swipeUp(velocity: .slow)
            pause()
            attach(app, "03b-swiftui-scrolled-twice")
            scrollToTop(app)
            pause()
            attach(app, "03c-swiftui-back-at-top")
        }

        var anchor = ""
        try step("4. Park a mid-document heading in view") {
            let title = element(labelled: KitchenSink.title, in: app)
            var drags = 0
            while isVisible(title, within: viewport(of: app)), drags < 8 {
                dragUp(app, by: 120)
                drags += 1
                pause(0.3)
            }
            XCTAssertFalse(
                isVisible(title, within: viewport(of: app)),
                "the document title should have scrolled off the top"
            )
            anchor = try XCTUnwrap(
                visibleLandmark(from: KitchenSink.headings, in: app),
                "no mid-document heading is in view after scrolling"
            )
            XCTContext.runActivity(named: "Anchor heading in view: \(anchor)") { _ in }
            pause()
            attach(app, "04-swiftui-anchor-\(anchor)")
        }

        try step("5. Five round trips: the anchor stays within 2 px per switch, 2 px in total") {
            let scale = pixelScale(of: app)
            let anchorElement = element(labelled: anchor, in: app)
            var lastY = try anchorTop(anchorElement, in: app)
            var totalPixels: CGFloat = 0
            for trip in 1 ... Self.roundTrips {
                for (identifier, name) in [
                    (Identifier.rendererTextKit2, "TextKit 2"), (Identifier.rendererSwiftUI, "SwiftUI"),
                ] {
                    chooseRenderer(identifier: identifier, label: name, in: app)
                    waitForRenderer(name, in: app)
                    pause()
                    let y = try anchorTop(anchorElement, in: app)
                    let deltaPixels = abs(y - lastY) * scale
                    totalPixels += deltaPixels
                    XCTContext.runActivity(
                        named: String(format: "Trip %ld → %@: %@ top %.3f pt, |ΔY| %.2f px (total %.2f px)",
                                      trip, name, anchor, y, deltaPixels, totalPixels)
                    ) { _ in }
                    XCTAssertLessThanOrEqual(
                        deltaPixels, Self.maxShiftPixels + 0.01,
                        "\(anchor) moved \(deltaPixels) px when switching to \(name) (trip \(trip))"
                    )
                    lastY = y
                }
            }
            XCTAssertLessThanOrEqual(
                totalPixels, Self.maxShiftPixels + 0.01,
                "\(anchor) drifted \(totalPixels) px in total over \(Self.roundTrips) round trips"
            )
            attach(app, "05-round-trips-done")
        }

        try step("6. Switch to TextKit 2 — live, in place, drawn by TextKit 2 rows") {
            chooseRenderer(identifier: Identifier.rendererTextKit2, label: "TextKit 2", in: app)
            waitForRenderer("TextKit 2", in: app)
            pause()
            let viewport = viewport(of: app)
            XCTAssertTrue(
                isVisible(element(labelled: anchor, in: app), within: viewport),
                "\(anchor) left the viewport when the renderer changed"
            )
            XCTAssertFalse(
                isVisible(element(labelled: KitchenSink.title, in: app), within: viewport),
                "the document jumped back to the top when the renderer changed"
            )
            XCTAssertTrue(
                textKit2Row(labelled: anchor, in: app).waitForExistence(timeout: 5),
                "\(anchor) is not drawn by a TextKit 2 row (no tk2-row:<id> element)"
            )
            attach(app, "06a-textkit2-anchor-retained")
            openAbout(app)
            let live = readLiveTextKit2Rows(in: app, until: { $0 > 0 })
            XCTAssertGreaterThan(live ?? 0, 0, "About This Build reports no live TextKit 2 rows")
            XCTAssertEqual(app.staticTexts[Identifier.buildRenderer].label, "TextKit 2")
            pause()
            attach(app, "06b-about-live-textkit2-rows")
            closeAbout(app)
        }

        try step("7. TextKit 2 rows expose their text") {
            scrollToTop(app)
            XCTAssertTrue(
                textKit2Row(labelled: KitchenSink.proofHeading, in: app).waitForExistence(timeout: 5),
                "\(KitchenSink.proofHeading) is not drawn by a TextKit 2 row"
            )
            for paragraph in KitchenSink.plainParagraphs {
                XCTAssertTrue(
                    element(labelled: paragraph, in: app).waitForExistence(timeout: 5),
                    "\(paragraph) is not exposed on the TextKit 2 path"
                )
            }
            for heading in KitchenSink.headings {
                XCTAssertTrue(element(labelled: heading, in: app).exists, "\(heading) is not exposed")
            }
            pause()
            attach(app, "07-textkit2-top")
        }

        try step("8. Scroll through the document on TextKit 2") {
            let scroll = app.scrollViews.firstMatch
            scroll.swipeUp(velocity: .slow)
            pause()
            attach(app, "08a-textkit2-scrolled-once")
            scroll.swipeUp(velocity: .slow)
            pause()
            attach(app, "08b-textkit2-scrolled-twice")
        }

        try step("9. Switch back to SwiftUI — every TextKit 2 row is released") {
            var landmark = visibleLandmark(from: KitchenSink.landmarks, in: app)
            if landmark == nil {
                scrollToTop(app)
                landmark = visibleLandmark(from: KitchenSink.headings, in: app)
            }
            let anchorBack = try XCTUnwrap(landmark, "nothing recognisable is in view before switching back")
            XCTContext.runActivity(named: "Anchor in view: \(anchorBack)") { _ in }
            chooseRenderer(identifier: Identifier.rendererSwiftUI, label: "SwiftUI", in: app)
            waitForRenderer("SwiftUI", in: app)
            pause()
            XCTAssertTrue(
                isVisible(element(labelled: anchorBack, in: app), within: viewport(of: app)),
                "\(anchorBack) left the viewport when switching back"
            )
            XCTAssertTrue(
                waitForDisappearance(of: anyTextKit2Row(in: app), timeout: 5),
                "a TextKit 2 row is still on screen after switching back to SwiftUI"
            )
            attach(app, "09a-back-on-swiftui")
            openAbout(app)
            let live = readLiveTextKit2Rows(in: app, until: { $0 == 0 })
            XCTAssertEqual(live, 0, "TextKit 2 rows are still alive after switching back to SwiftUI")
            XCTAssertEqual(app.staticTexts[Identifier.buildRenderer].label, "SwiftUI")
            pause()
            attach(app, "09b-about-no-live-rows")
            closeAbout(app)
        }
    }

    /// §3 of the stack plan: per switch and in total over five round trips.
    private static let roundTrips = 5
    private static let maxShiftPixels: CGFloat = 2

    // MARK: - Steps and pacing

    private func step(_ name: String, _ body: () throws -> Void) throws {
        try XCTContext.runActivity(named: name) { _ in try body() }
    }

    /// Short pauses make the recording readable; the whole test runs in about
    /// two minutes.
    private func pause(_ seconds: TimeInterval = 1) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Renderer control

    /// The toolbar control's label is the active renderer's name; the inner
    /// text carries its own identifier in case the hierarchy keeps it as a
    /// separate element.
    private func waitForRenderer(_ name: String, in app: XCUIApplication, timeout: TimeInterval = 10) {
        let predicate = NSPredicate(
            format: "(identifier == %@ OR identifier == %@) AND label CONTAINS %@",
            Identifier.rendererMenu, Identifier.rendererActive, name
        )
        let match = app.descendants(matching: .any).matching(predicate).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: timeout), "active renderer never became \(name)")
    }

    private func openRendererMenu(_ app: XCUIApplication) {
        let control = app.descendants(matching: .any).matching(identifier: Identifier.rendererMenu).firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 10), "renderer menu control missing")
        control.tap()
        pause(0.5)
    }

    private func chooseRenderer(identifier: String, label: String, in app: XCUIApplication) {
        openRendererMenu(app)
        let item = menuItem(identifier: identifier, label: label, in: app)
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\(label) missing from the renderer menu")
        item.tap()
    }

    /// Menu rows match by identifier first, by their visible label second.
    private func menuItem(identifier: String, label: String, in app: XCUIApplication) -> XCUIElement {
        let predicate = NSPredicate(format: "identifier == %@ OR label == %@", identifier, label)
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    // MARK: - About This Build

    private func openAbout(_ app: XCUIApplication) {
        openRendererMenu(app)
        let about = menuItem(identifier: Identifier.about, label: "About This Build…", in: app)
        XCTAssertTrue(about.waitForExistence(timeout: 5), "About This Build… missing from the menu")
        about.tap()
        XCTAssertTrue(
            app.staticTexts[Identifier.buildVersion].waitForExistence(timeout: 5),
            "About This Build did not open"
        )
    }

    private func closeAbout(_ app: XCUIApplication) {
        let done = app.buttons[Identifier.buildDone]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Done button missing")
        done.tap()
        XCTAssertTrue(
            waitForDisappearance(of: app.staticTexts[Identifier.buildVersion], timeout: 5),
            "About sheet did not dismiss"
        )
        pause(0.5)
    }

    /// The sheet's live TextKit 2 row count (it shows "…" until its first
    /// read and refreshes every 250 ms); waits up to `timeout` for a value
    /// satisfying `condition` and returns the last number read.
    private func readLiveTextKit2Rows(
        in app: XCUIApplication,
        until condition: (Int) -> Bool,
        timeout: TimeInterval = 5
    ) -> Int? {
        let field = app.staticTexts[Identifier.liveTextKit2Rows]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "tk2-live-rows missing from About This Build")
        let deadline = Date().addingTimeInterval(timeout)
        var value: Int?
        repeat {
            value = Int(field.label)
            if let value, condition(value) { break }
            pause(0.25)
        } while Date() < deadline
        XCTContext.runActivity(named: "Live TextKit 2 rows: \(value.map(String.init) ?? field.label)") { _ in }
        return value
    }

    // MARK: - TextKit 2 rows

    private func textKit2Row(labelled text: String, in app: XCUIApplication) -> XCUIElement {
        let predicate = NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", Identifier.textKit2RowPrefix, text
        )
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    private func anyTextKit2Row(in app: XCUIApplication) -> XCUIElement {
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", Identifier.textKit2RowPrefix)
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    // MARK: - Document geometry

    /// Device pixels per point, from a screenshot of the current screen.
    private func pixelScale(of app: XCUIApplication) -> CGFloat {
        let pixels = CGFloat(XCUIScreen.main.screenshot().image.cgImage?.width ?? 0)
        let points = app.windows.firstMatch.frame.width
        XCTAssertGreaterThan(pixels, 0, "screenshot has no pixels")
        XCTAssertGreaterThan(points, 0, "window has no width")
        return points > 0 ? pixels / points : 1
    }

    /// The anchor's top edge in screen points; it must be visible.
    private func anchorTop(_ anchor: XCUIElement, in app: XCUIApplication) throws -> CGFloat {
        XCTAssertTrue(anchor.waitForExistence(timeout: 5), "anchor element missing")
        XCTAssertTrue(isVisible(anchor, within: viewport(of: app)), "anchor left the viewport")
        return anchor.frame.minY
    }

    private func element(labelled text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", text)).firstMatch
    }

    /// The part of the window below the navigation bar.
    private func viewport(of app: XCUIApplication) -> CGRect {
        let window = app.windows.firstMatch.frame
        let navigationBar = app.navigationBars.firstMatch
        let top = navigationBar.exists ? navigationBar.frame.maxY : window.minY
        return CGRect(x: window.minX, y: top, width: window.width, height: window.maxY - top)
    }

    private func isVisible(_ element: XCUIElement, within viewport: CGRect) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        guard frame.height > 0 else { return false }
        return frame.minY >= viewport.minY && frame.maxY <= viewport.maxY
    }

    /// The candidate nearest the vertical centre of the viewport — the one
    /// most tolerant of small row-height differences between renderers.
    private func visibleLandmark(from candidates: [String], in app: XCUIApplication) -> String? {
        let viewport = viewport(of: app)
        var best: (name: String, distance: CGFloat)?
        for name in candidates {
            let candidate = element(labelled: name, in: app)
            guard isVisible(candidate, within: viewport) else { continue }
            let distance = abs(candidate.frame.midY - viewport.midY)
            if let current = best, distance >= current.distance { continue }
            best = (name, distance)
        }
        return best?.name
    }

    /// A slow, held drag: no fling momentum, so the resulting offset is
    /// predictable.
    private func dragUp(_ app: XCUIApplication, by points: CGFloat) {
        let scroll = app.scrollViews.firstMatch
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let end = start.withOffset(CGVector(dx: 0, dy: -points))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
    }

    private func scrollToTop(_ app: XCUIApplication) {
        let scroll = app.scrollViews.firstMatch
        let title = element(labelled: KitchenSink.title, in: app)
        var swipes = 0
        while !isVisible(title, within: viewport(of: app)), swipes < 8 {
            scroll.swipeDown(velocity: .fast)
            swipes += 1
            pause(0.4)
        }
        XCTAssertTrue(isVisible(title, within: viewport(of: app)), "could not scroll back to the top")
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }
}
