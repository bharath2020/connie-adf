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
/// moves at most 2 px per switch and 2 px in total over five round trips, and
/// back at the top of the document the title settles (stable for 2 s) within
/// 2 px of where it settled on SwiftUI. The switch back to SwiftUI happens
/// with a TextKit 2 heading row in view.
///
/// Driving helpers (renderer menu, About sheet, geometry) are the shared
/// `ReaderDriver` in LifecycleSupport.swift.
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

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLiveSwitchSwiftUIToTextKit2AndBack() throws {
        let reader = ReaderDriver(launching: ["-fixture", "kitchen-sink", "-rendererReset", "-rendererStats"])
        let app = reader.app

        try step("1. Launch on the SwiftUI renderer") {
            reader.waitForRenderer("SwiftUI")
            XCTAssertTrue(
                reader.element(labelled: KitchenSink.title).waitForExistence(timeout: 15),
                "kitchen-sink did not render its title"
            )
            XCTAssertFalse(reader.anyTextKit2Row.exists, "a TextKit 2 row exists while SwiftUI is active")
            pause()
            attach(app, "01-launch-swiftui")
        }

        try step("2. About This Build shows the executable checksum and no live TextKit 2 rows") {
            reader.openAbout()
            let sha = app.staticTexts[ReaderDriver.Identifier.buildSHA256]
            XCTAssertTrue(sha.waitForExistence(timeout: 20), "checksum never appeared")
            let observed = sha.label
            XCTAssertEqual(observed.count, 64, "expected 64 hex characters, got \(observed)")
            XCTAssertTrue(
                observed.allSatisfy { $0.isHexDigit && !$0.isUppercase },
                "checksum is not lowercase hex: \(observed)"
            )
            XCTAssertTrue(app.staticTexts[ReaderDriver.Identifier.buildVersion].exists, "version row missing")
            XCTAssertEqual(app.staticTexts[ReaderDriver.Identifier.buildRenderer].label, "SwiftUI")
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

            let live = readLiveTextKit2Rows(reader, until: { $0 == 0 })
            XCTAssertEqual(live, 0, "TextKit 2 rows are alive on the SwiftUI renderer")
            pause()
            attach(app, "02-about-this-build")
            reader.closeAbout()
        }

        var swiftUITitleTop: CGFloat = 0
        try step("3. Scroll down two screens and back to the top") {
            let scroll = app.scrollViews.firstMatch
            XCTAssertTrue(scroll.waitForExistence(timeout: 5), "document scroll view missing")
            scroll.swipeUp(velocity: .slow)
            pause()
            attach(app, "03a-swiftui-scrolled-once")
            scroll.swipeUp(velocity: .slow)
            pause()
            attach(app, "03b-swiftui-scrolled-twice")
            scrollToTop(reader)
            swiftUITitleTop = try settledTop(of: reader.element(labelled: KitchenSink.title), reader)
            XCTContext.runActivity(named: String(format: "SwiftUI title settled at %.3f pt", swiftUITitleTop)) { _ in }
            attach(app, "03c-swiftui-back-at-top")
        }

        var anchor = ""
        try step("4. Park a mid-document heading in view") {
            let title = reader.element(labelled: KitchenSink.title)
            var drags = 0
            while reader.isVisible(title), drags < 8 {
                reader.drag(by: 120)
                drags += 1
                pause(0.3)
            }
            XCTAssertFalse(reader.isVisible(title), "the document title should have scrolled off the top")
            anchor = try XCTUnwrap(
                visibleLandmark(from: KitchenSink.headings, reader),
                "no mid-document heading is in view after scrolling"
            )
            XCTContext.runActivity(named: "Anchor heading in view: \(anchor)") { _ in }
            pause()
            attach(app, "04-swiftui-anchor-\(anchor)")
        }

        try step("5. Five round trips: the anchor stays within 2 px per switch, 2 px in total") {
            let scale = reader.pixelScale()
            let anchorElement = reader.element(labelled: anchor)
            var lastY = try anchorTop(anchorElement, reader)
            var totalPixels: CGFloat = 0
            for trip in 1 ... Self.roundTrips {
                for (textKit2, name) in [(true, "TextKit 2"), (false, "SwiftUI")] {
                    reader.chooseRenderer(textKit2: textKit2)
                    pause()
                    let y = try anchorTop(anchorElement, reader)
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
            reader.chooseRenderer(textKit2: true)
            pause()
            XCTAssertTrue(
                reader.isVisible(reader.element(labelled: anchor)),
                "\(anchor) left the viewport when the renderer changed"
            )
            XCTAssertFalse(
                reader.isVisible(reader.element(labelled: KitchenSink.title)),
                "the document jumped back to the top when the renderer changed"
            )
            XCTAssertTrue(
                reader.textKit2Row(labelled: anchor).waitForExistence(timeout: 5),
                "\(anchor) is not drawn by a TextKit 2 row (no tk2-row:<id> element)"
            )
            attach(app, "06a-textkit2-anchor-retained")
            reader.openAbout()
            let live = readLiveTextKit2Rows(reader, until: { $0 > 0 })
            XCTAssertGreaterThan(live ?? 0, 0, "About This Build reports no live TextKit 2 rows")
            XCTAssertEqual(app.staticTexts[ReaderDriver.Identifier.buildRenderer].label, "TextKit 2")
            pause()
            attach(app, "06b-about-live-textkit2-rows")
            reader.closeAbout()
        }

        try step("7. TextKit 2 rows expose their text; the top settles where SwiftUI's did") {
            scrollToTop(reader)
            // Bounded convergence: the title must hold still for 2 s, then
            // sit within 2 px of the SwiftUI arm's settled top (step 3).
            let scale = reader.pixelScale()
            let textKit2TitleTop = try settledTop(of: reader.element(labelled: KitchenSink.title), reader)
            let deltaPixels = abs(textKit2TitleTop - swiftUITitleTop) * scale
            XCTContext.runActivity(
                named: String(format: "TextKit 2 title settled at %.3f pt vs SwiftUI %.3f pt: |ΔY| %.2f px",
                              textKit2TitleTop, swiftUITitleTop, deltaPixels)
            ) { _ in }
            XCTAssertLessThanOrEqual(
                deltaPixels, Self.maxShiftPixels + 0.01,
                "back at the top on TextKit 2 the title settled \(deltaPixels) px from where it settled on SwiftUI"
            )
            XCTAssertTrue(
                reader.textKit2Row(labelled: KitchenSink.proofHeading).waitForExistence(timeout: 5),
                "\(KitchenSink.proofHeading) is not drawn by a TextKit 2 row"
            )
            for paragraph in KitchenSink.plainParagraphs {
                XCTAssertTrue(
                    reader.element(labelled: paragraph).waitForExistence(timeout: 5),
                    "\(paragraph) is not exposed on the TextKit 2 path"
                )
            }
            for heading in KitchenSink.headings {
                XCTAssertTrue(reader.element(labelled: heading).exists, "\(heading) is not exposed")
            }
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

        try step("9. Switch back to SwiftUI with a TextKit 2 heading in view — every row is released") {
            // A heading (a TextKit 2 row) in view, so the switch visibly
            // changes engine: scroll back toward the top a little at a time
            // until one is, falling back to any landmark.
            var landmark = visibleLandmark(from: KitchenSink.headings, reader)
            var drags = 0
            while landmark == nil, drags < 10 {
                reader.drag(by: -200)
                pause(0.4)
                landmark = visibleLandmark(from: KitchenSink.headings, reader)
                drags += 1
            }
            if landmark == nil {
                landmark = visibleLandmark(from: KitchenSink.landmarks, reader)
            }
            let anchorBack = try XCTUnwrap(landmark, "nothing recognisable is in view before switching back")
            let headingRow = KitchenSink.headings.contains(anchorBack)
            XCTContext.runActivity(named: "Anchor in view: \(anchorBack) (TextKit 2 heading: \(headingRow))") { _ in }
            if headingRow {
                XCTAssertTrue(
                    reader.textKit2Row(labelled: anchorBack).exists,
                    "\(anchorBack) is not a TextKit 2 row before switching back"
                )
            }
            attach(app, "09-textkit2-before-switching-back")
            reader.chooseRenderer(textKit2: false)
            pause()
            XCTAssertTrue(
                reader.isVisible(reader.element(labelled: anchorBack)),
                "\(anchorBack) left the viewport when switching back"
            )
            XCTAssertTrue(
                reader.waitForDisappearance(of: reader.anyTextKit2Row, timeout: 5),
                "a TextKit 2 row is still on screen after switching back to SwiftUI"
            )
            attach(app, "09a-back-on-swiftui")
            reader.openAbout()
            let live = readLiveTextKit2Rows(reader, until: { $0 == 0 })
            XCTAssertEqual(live, 0, "TextKit 2 rows are still alive after switching back to SwiftUI")
            XCTAssertEqual(app.staticTexts[ReaderDriver.Identifier.buildRenderer].label, "SwiftUI")
            pause()
            attach(app, "09b-about-no-live-rows")
            reader.closeAbout()
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

    /// The open About sheet's live row count, logged for the recording.
    private func readLiveTextKit2Rows(_ reader: ReaderDriver, until condition: (Int) -> Bool) -> Int? {
        let value = reader.readLiveTextKit2Rows(until: condition)
        let label = reader.app.staticTexts[ReaderDriver.Identifier.liveTextKit2Rows].label
        XCTContext.runActivity(named: "Live TextKit 2 rows: \(value.map(String.init) ?? label)") { _ in }
        return value
    }

    // MARK: - Document geometry

    /// The anchor's top edge in screen points; it must be visible.
    private func anchorTop(_ anchor: XCUIElement, _ reader: ReaderDriver) throws -> CGFloat {
        XCTAssertTrue(anchor.waitForExistence(timeout: 5), "anchor element missing")
        XCTAssertTrue(reader.isVisible(anchor), "anchor left the viewport")
        return anchor.frame.minY
    }

    /// The element's top once it has held still for 2 s (three reads 1 s
    /// apart agree to 0.01 pt); fails after 12 s without converging.
    private func settledTop(of element: XCUIElement, _ reader: ReaderDriver) throws -> CGFloat {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "element to settle is missing")
        var reads: [CGFloat] = []
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            reads.append(element.frame.minY)
            if reads.count >= 3 {
                let last = reads.suffix(3)
                if let low = last.min(), let high = last.max(), high - low <= 0.01 { return reads.last ?? 0 }
            }
            pause(1)
        }
        XCTFail("top never held still for 2 s: \(reads)")
        return reads.last ?? 0
    }

    /// The candidate nearest the vertical centre of the viewport — the one
    /// most tolerant of small row-height differences between renderers.
    private func visibleLandmark(from candidates: [String], _ reader: ReaderDriver) -> String? {
        let viewport = reader.viewport
        var best: (name: String, distance: CGFloat)?
        for name in candidates {
            let candidate = reader.element(labelled: name)
            guard reader.isVisible(candidate) else { continue }
            let distance = abs(candidate.frame.midY - viewport.midY)
            if let current = best, distance >= current.distance { continue }
            best = (name, distance)
        }
        return best?.name
    }

    private func scrollToTop(_ reader: ReaderDriver) {
        let scroll = reader.app.scrollViews.firstMatch
        let title = reader.element(labelled: KitchenSink.title)
        var swipes = 0
        while !reader.isVisible(title), swipes < 8 {
            scroll.swipeDown(velocity: .fast)
            swipes += 1
            pause(0.4)
        }
        XCTAssertTrue(reader.isVisible(title), "could not scroll back to the top")
    }
}
