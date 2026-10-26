import XCTest

/// End-to-end proof that the reader's text-renderer switch is live: the same
/// document stays on screen, at the same place, while its rows change engine
/// — no relaunch. Paced for a screen recording (`Scripts/e2e-video.sh`):
/// every step pauses briefly and attaches a screenshot.
///
/// Launch arguments: `-fixture kitchen-sink` opens the fixture directly and
/// `-rendererReset` clears the persisted choice so the run always starts on
/// SwiftUI. Set `ADF_EXPECTED_BUILD_SHA256` in the runner's environment
/// (`TEST_RUNNER_ADF_EXPECTED_BUILD_SHA256=…` on the xcodebuild command line)
/// to also assert the checksum shown in About This Build; without it that
/// one assertion is skipped and noted in the result.
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
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLiveSwitchSwiftUIToTextKit2AndBack() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-fixture", "kitchen-sink", "-rendererReset"]
        app.launch()

        try step("1. Launch on the SwiftUI renderer") {
            waitForRenderer("SwiftUI", in: app)
            XCTAssertTrue(
                element(labelled: KitchenSink.title, in: app).waitForExistence(timeout: 15),
                "kitchen-sink did not render its title"
            )
            pause()
            attach(app, "01-launch-swiftui")
        }

        try step("2. About This Build shows the executable checksum") {
            openRendererMenu(app)
            let about = menuItem(identifier: Identifier.about, label: "About This Build…", in: app)
            XCTAssertTrue(about.waitForExistence(timeout: 5), "About This Build… missing from the menu")
            about.tap()

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

            let environment = ProcessInfo.processInfo.environment
            if let expected = environment["ADF_EXPECTED_BUILD_SHA256"]?.lowercased(), !expected.isEmpty {
                XCTAssertEqual(observed, expected, "on-screen checksum differs from the built binary")
            } else {
                XCTContext.runActivity(
                    named: "ADF_EXPECTED_BUILD_SHA256 not set — checksum equality not asserted"
                ) { _ in }
            }
            pause()
            attach(app, "02-about-this-build")

            let done = app.buttons[Identifier.buildDone]
            XCTAssertTrue(done.waitForExistence(timeout: 5), "Done button missing")
            done.tap()
            XCTAssertTrue(waitForDisappearance(of: sha, timeout: 5), "About sheet did not dismiss")
            pause(0.5)
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

        try step("5. Switch to TextKit 2 — live, in place") {
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
            attach(app, "05-textkit2-anchor-retained")
        }

        try step("6. TextKit 2 rows expose their text") {
            scrollToTop(app)
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
            attach(app, "06-textkit2-top")
        }

        try step("7. Scroll through the document on TextKit 2") {
            let scroll = app.scrollViews.firstMatch
            scroll.swipeUp(velocity: .slow)
            pause()
            attach(app, "07a-textkit2-scrolled-once")
            scroll.swipeUp(velocity: .slow)
            pause()
            attach(app, "07b-textkit2-scrolled-twice")
        }

        try step("8. Switch back to SwiftUI") {
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
            attach(app, "08-back-on-swiftui")
        }
    }

    // MARK: - Steps and pacing

    private func step(_ name: String, _ body: () throws -> Void) throws {
        try XCTContext.runActivity(named: name) { _ in try body() }
    }

    /// Short pauses make the recording readable; the whole test stays well
    /// under 90 seconds.
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

    // MARK: - Document geometry

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
