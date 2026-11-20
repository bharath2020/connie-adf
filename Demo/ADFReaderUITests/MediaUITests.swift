import XCTest

/// Media loading end to end (ADR §24): `MediaCoordinator` in the library,
/// `CacheFirstMediaProvider` over the demo's `MockMediaFetch`
/// (`-media mock -mediaDelay 0.2 -mediaCache cold`). Counters are read from
/// `MediaProbe` (`-mediaProbe`): one element, one consistent snapshot of the
/// document's coordinator counters and the mock's.
///
/// - `testGalleryLoadsLazilyAndReusesTheCache`, `-fixture media-gallery`
///   (300 external images): images on the first screen load (four at most
///   at once, none fails); a run of fast swipes down starts far fewer than
///   300 loads (a fling past media starts nothing or cancels it) and never
///   runs more than four; back at the top the first images load again from
///   the provider's memory or disk cache, so the provider is called again
///   but the mock is not (fewer new mock calls than new provider calls).
/// - `testStressDocumentLoadsMediaInAnExpand`, `-fixture stress-5k`: the
///   first media sits in block 95's expand; opening it there loads media
///   (four at most, none fails), and the app still answers afterwards.
/// - `testMediaOffLoadsNothing`: `-media off` passes no provider: nothing
///   starts and there is no mock.
@MainActor
final class MediaUITests: XCTestCase {
    /// `MediaProbe`'s element (`-mediaProbe`).
    static let probeID = "media-probe"
    /// The coordinator's cap on provider calls at once (`MediaTiming`).
    static let maxConcurrent = 4
    /// The media-gallery heading: the top sentinel.
    static let galleryTitle = "Media gallery: 300 external images"
    static let galleryImages = 300
    /// The accessibility label prefix of a gallery image (its alt text).
    static let galleryImagePrefix = "Placeholder image "
    /// stress-5k's first block with media: an expand holding a
    /// `mediaSingle`, a `mediaGroup` and a `mediaInline`.
    /// `-scrollToFraction 0.0191` lands on it (index 95 of 5,000).
    static let stressExpandTitle = "Expand 95 [5]: kernel inline stress"
    static let stressFraction = "0.0191"
    /// A fling's speed (points per second; `.fast` is far slower).
    static let flingVelocity = XCUIGestureVelocity(rawValue: 6_000)
    static let mockArguments = ["-media", "mock", "-mediaDelay", "0.2", "-mediaCache", "cold", "-mediaProbe"]

    /// The probe's `key=value` fields; `-1` for a missing field.
    struct Stats: CustomStringConvertible {
        var values: [String: Int] = [:]
        subscript(_ field: String) -> Int { values[field] ?? -1 }

        init(probe line: String) {
            for pair in line.split(separator: " ") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2, let value = Int(parts[1]) { values[String(parts[0])] = value }
            }
        }

        var description: String {
            values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        }

        /// `started == finished + failed + cancelled + running`.
        var isConsistent: Bool {
            self["started"] == self["finished"] + self["failed"] + self["cancelled"] + self["running"]
        }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - media-gallery: near the top, fling, back to the top

    func testGalleryLoadsLazilyAndReusesTheCache() throws {
        continueAfterFailure = true
        let reader = launch(fixture: "media-gallery")
        let title = reader.element(labelled: Self.galleryTitle)
        guard title.waitForExistence(timeout: 20) else {
            XCTFail("the media-gallery heading never appeared")
            return
        }

        // 1. Near the top: the first screen's images load, at most four at
        // once, none fails.
        let top = waitForProbe(reader, "A (top, loaded)", timeout: 15, settle: 0.5) {
            $0["finished"] >= 1 && $0["running"] == 0
        }
        XCTAssertTrue(top.met, "no image loaded near the top: \(top.stats)")
        let a = top.stats
        XCTAssertGreaterThanOrEqual(a["finished"], 1, a.description)
        XCTAssertEqual(a["failed"], 0, "an image failed: \(a)")
        XCTAssertLessThanOrEqual(a["running"], Self.maxConcurrent, a.description)
        XCTAssertLessThanOrEqual(a["maxRunning"], Self.maxConcurrent, "more than four loads ran at once: \(a)")
        XCTAssertLessThanOrEqual(a["started"], 20, "loads started for images far off screen: \(a)")
        XCTAssertEqual(a["mockCalls"], a["started"], "a cold cache served an image without the mock: \(a)")
        XCTAssertTrue(a.isConsistent, "counters do not add up: \(a)")
        let firstShown = visibleImageIndices(reader)
        note("images on the first screen: \(firstShown.sorted())")
        attach(reader.app, "gallery-top")

        // 2. A run of flings down: lazy (far fewer than 300 starts, fewer
        // than the images passed), never more than four at once. A `.fast`
        // swipe moves about two gallery images, slowly enough that each
        // dwells and loads; a fling at `flingVelocity` passes images in well
        // under the 150 ms dwell.
        let scroll = reader.app.scrollViews.firstMatch
        let swipeStart = Date()
        for _ in 0 ..< 6 {
            scroll.swipeUp(velocity: Self.flingVelocity)
        }
        note(String(format: "6 flings took %.1f s", Date().timeIntervalSince(swipeStart)))
        let passed = visibleImageIndices(reader)
        let farthest = passed.max() ?? 0
        note("images on screen after the swipes: \(passed.sorted())")
        let flung = waitForProbe(reader, "B (after the swipes, at rest)", timeout: 10, settle: 1.5) {
            $0["running"] == 0
        }
        let b = flung.stats
        attach(reader.app, "gallery-after-swipes")
        XCTAssertGreaterThan(farthest, 20, "the swipes did not move far into the gallery: \(passed.sorted())")
        XCTAssertLessThanOrEqual(b["maxRunning"], Self.maxConcurrent, "more than four loads ran at once: \(b)")
        XCTAssertEqual(b["failed"], 0, "an image failed: \(b)")
        XCTAssertLessThan(b["started"], Self.galleryImages / 2, "not lazy: \(b)")
        // Every image from the top to the farthest one on screen was passed;
        // fewer starts than that (plus those on screen now) means the fling
        // skipped some, and a cancelled call is the other way to skip.
        XCTAssertTrue(b["started"] < farthest + 1 || b["cancelled"] >= 1,
                      "every image passed was loaded (farthest \(farthest)): \(b)")
        XCTAssertGreaterThanOrEqual(b["released"], 1, "no decoded image was released after leaving the screen: \(b)")
        XCTAssertTrue(b.isConsistent, "counters do not add up: \(b)")

        // 3. Back to the top (steer by the heading): the first images load
        // again, served by the provider's caches, not the mock.
        // The heading counts once any of it is in the visible region: it is
        // the first block, so then the document is at its top. (A fully
        // visible check, `isVisible`, failed 40 swipes in a row in one
        // run although the heading element existed: steer by "on screen",
        // not by an exact frame.)
        let atTop = {
            title.exists && title.frame.height > 0 && title.frame.intersects(reader.viewport)
        }
        var swipes = 0
        while !atTop(), swipes < 40 {
            scroll.swipeDown(velocity: Self.flingVelocity)
            swipes += 1
        }
        guard atTop() else {
            XCTFail("could not scroll back to the top in \(swipes) swipes")
            return
        }
        note("back at the top after \(swipes) swipes")
        let back = waitForProbe(reader, "C (back at the top, loaded)", timeout: 15, settle: 1) {
            $0["finished"] > b["finished"] && $0["running"] == 0
        }
        let c = back.stats
        attach(reader.app, "gallery-back-at-top")
        let shownAgain = visibleImageIndices(reader)
        note("images on screen back at the top: \(shownAgain.sorted())")
        XCTAssertTrue(back.met, "no image loaded again back at the top: \(c)")
        XCTAssertGreaterThan(c["finished"], b["finished"], "the first images did not load again: \(c)")
        XCTAssertFalse(shownAgain.isDisjoint(with: firstShown),
                       "none of the first screen's images is on screen again: \(shownAgain.sorted())")
        let newStarts = c["started"] - b["started"]
        let newMockCalls = c["mockCalls"] - b["mockCalls"]
        note("return: \(newStarts) new provider calls, \(newMockCalls) new mock calls")
        XCTAssertLessThan(newMockCalls, newStarts,
                          "every reload went to the mock: the caches served nothing (\(b) → \(c))")
        XCTAssertLessThanOrEqual(c["maxRunning"], Self.maxConcurrent, c.description)
        XCTAssertEqual(c["failed"], 0, "an image failed: \(c)")
        XCTAssertTrue(c.isConsistent, "counters do not add up: \(c)")
    }

    // MARK: - stress-5k: the first media, in an expand

    func testStressDocumentLoadsMediaInAnExpand() throws {
        continueAfterFailure = true
        let reader = launch(fixture: "stress-5k", extra: ["-scrollToFraction", Self.stressFraction])
        let expand = reader.app.buttons.matching(NSPredicate(format: "label == %@", Self.stressExpandTitle)).firstMatch
        guard expand.waitForExistence(timeout: 30) else {
            XCTFail("block 95's expand never appeared after -scrollToFraction \(Self.stressFraction)")
            return
        }
        // The re-jump lands ~1.5 s after ready; let it finish first.
        reader.pause(2.5)
        var drags = 0
        while !reader.isVisible(expand), drags < 6 {
            reader.drag(by: expand.exists && expand.frame.minY < reader.viewport.minY ? -200 : 200)
            drags += 1
        }
        XCTAssertTrue(reader.isVisible(expand), "block 95's expand is not on screen")
        let before = probe(reader, "A (expand closed)")
        XCTAssertEqual(before["started"], 0, "media loaded before any media was on screen: \(before)")
        expand.tap()
        let loaded = waitForProbe(reader, "B (expand open, loaded)", timeout: 15, settle: 0.5) {
            $0["finished"] >= 1 && $0["running"] == 0
        }
        let b = loaded.stats
        attach(reader.app, "stress-expand-open")
        XCTAssertTrue(loaded.met, "no media loaded in the open expand: \(b)")
        XCTAssertGreaterThanOrEqual(b["finished"], 1, b.description)
        XCTAssertLessThanOrEqual(b["maxRunning"], Self.maxConcurrent, "more than four loads ran at once: \(b)")
        XCTAssertEqual(b["failed"], 0, "a media load failed: \(b)")
        XCTAssertTrue(b.isConsistent, "counters do not add up: \(b)")

        // Still responsive: a scroll and a later probe read go through.
        let started = Date()
        reader.drag(by: 300)
        reader.drag(by: -300)
        let after = probe(reader, "C (after two drags)")
        let seconds = Date().timeIntervalSince(started)
        note(String(format: "two drags and a probe read took %.1f s", seconds))
        XCTAssertGreaterThanOrEqual(after["finished"], b["finished"], after.description)
        XCTAssertLessThanOrEqual(after["maxRunning"], Self.maxConcurrent, after.description)
        XCTAssertEqual(after["failed"], 0, after.description)
        XCTAssertLessThan(seconds, 30, "the app answered slowly after loading media")
        XCTAssertEqual(reader.app.state, .runningForeground, "the app is no longer in the foreground")
    }

    // MARK: - -media off

    func testMediaOffLoadsNothing() throws {
        continueAfterFailure = true
        let reader = start(["-fixture", "media-gallery", "-rendererReset", "-media", "off", "-mediaProbe"])
        XCTAssertTrue(reader.element(labelled: Self.galleryTitle).waitForExistence(timeout: 20),
                      "the media-gallery heading never appeared")
        // Longer than a dwell (150 ms) plus a default mock fetch (0.3 s).
        reader.pause(2)
        let stats = probe(reader, "media off (2 s after the heading)")
        XCTAssertEqual(stats["started"], 0, "a media load started with no provider: \(stats)")
        XCTAssertEqual(stats["finished"], 0, stats.description)
        XCTAssertEqual(stats["running"], 0, stats.description)
        XCTAssertEqual(stats["mockCalls"], -1, "a mock fetch exists under -media off: \(stats)")
        XCTAssertFalse(visibleImageIndices(reader).isEmpty, "no media placeholder box is on screen")
        attach(reader.app, "media-off")
    }

    // MARK: - Launch, probe

    private func launch(fixture: String, extra: [String] = []) -> ReaderDriver {
        start(["-fixture", fixture, "-rendererReset"] + Self.mockArguments + extra)
    }

    /// Launches and waits for the SwiftUI renderer. On a loaded host a
    /// launch can sit in dyld for minutes (seen at load average 80), and a
    /// renderer query before the app has a window fails the test
    /// (`kAXErrorServerNotFound`), so first wait for the foreground.
    private func start(_ arguments: [String]) -> ReaderDriver {
        let launched = Date()
        let reader = ReaderDriver(launching: arguments)
        let foreground = reader.app.wait(for: .runningForeground, timeout: 180)
        XCTAssertTrue(foreground, "the app never reached the foreground")
        reader.waitForRenderer("SwiftUI", timeout: 60)
        note(String(format: "launched in %.1f s", Date().timeIntervalSince(launched)))
        return reader
    }

    /// One consistent read of every counter (`MediaProbe`), taken once two
    /// reads 300 ms apart agree.
    private func probe(_ reader: ReaderDriver, _ name: String) -> Stats {
        let element = reader.app.staticTexts[Self.probeID]
        XCTAssertTrue(element.exists || element.waitForExistence(timeout: 5), "media-probe missing (-mediaProbe)")
        var previous = Stats(probe: element.label)
        var stats = previous
        for _ in 0 ..< 10 {
            reader.pause(0.3)
            stats = Stats(probe: element.label)
            if stats.values == previous.values { break }
            previous = stats
        }
        note("PROBE \(name): \(stats)")
        return stats
    }

    /// Polls the probe every 200 ms until `condition` holds or `timeout`
    /// passes (`waitForExistence` first checks after about a second, so it
    /// is skipped when the probe is already there); with `settle`, waits
    /// that long once it holds and takes a consistent read.
    private func waitForProbe(_ reader: ReaderDriver, _ name: String, timeout: TimeInterval, settle: TimeInterval = 0,
                              until condition: (Stats) -> Bool) -> (met: Bool, stats: Stats)
    {
        let element = reader.app.staticTexts[Self.probeID]
        XCTAssertTrue(element.exists || element.waitForExistence(timeout: 5), "media-probe missing (-mediaProbe)")
        let deadline = Date().addingTimeInterval(timeout)
        var stats = Stats(probe: element.label)
        var met = condition(stats)
        while !met, Date() < deadline {
            reader.pause(0.2)
            stats = Stats(probe: element.label)
            met = condition(stats)
        }
        if met, settle > 0 {
            reader.pause(settle)
            stats = probe(reader, name)
            met = condition(stats)
        } else {
            note("PROBE \(name): \(stats)\(met ? "" : " (condition not met)")")
        }
        return (met, stats)
    }

    /// The gallery indices of the images on screen (alt text "Placeholder
    /// image <n>"), from one accessibility snapshot.
    private func visibleImageIndices(_ reader: ReaderDriver) -> Set<Int> {
        guard let root = try? reader.app.scrollViews.firstMatch.snapshot() else { return [] }
        let viewport = reader.viewport
        var indices: Set<Int> = []
        func walk(_ node: XCUIElementSnapshot) {
            if node.label.hasPrefix(Self.galleryImagePrefix),
               let index = Int(node.label.dropFirst(Self.galleryImagePrefix.count)),
               node.frame.intersects(viewport)
            {
                indices.insert(index)
            }
            for child in node.children { walk(child) }
        }
        walk(root)
        return indices
    }

    /// Logged for the result bundle and printed for the xcodebuild log
    /// (`MEDIA_UI …`).
    private func note(_ text: String) {
        print("MEDIA_UI \(text)")
        XCTContext.runActivity(named: text) { _ in }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
