import XCTest

/// Client for `Scripts/lifecycle_agent.py`, the host-side helper that does
/// what a UI test cannot: rotate through the app's Darwin hook and measure
/// the app process (CPU via `top`, phys_footprint via `footprint`). The
/// channel is a host directory passed as `ADF_LIFECYCLE_DIR`
/// (`TEST_RUNNER_ADF_LIFECYCLE_DIR` on the xcodebuild command line).
@MainActor
struct HostAgent {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    let directory: URL

    /// Skips the calling test when the gate script is not driving it.
    static func fromEnvironment() throws -> HostAgent {
        let path = ProcessInfo.processInfo.environment["ADF_LIFECYCLE_DIR"] ?? ""
        guard !path.isEmpty else {
            throw XCTSkip("ADF_LIFECYCLE_DIR is not set; run through Scripts/lifecycle-gate.sh")
        }
        return HostAgent(directory: URL(fileURLWithPath: path))
    }

    /// Sends one request and waits for the agent's answer.
    @discardableResult
    func request(_ kind: String, _ parameters: [String: Any] = [:], timeout: TimeInterval = 60) throws
        -> [String: Any]
    {
        let name = String(format: "%.6f-%@", Date().timeIntervalSince1970, UUID().uuidString)
        let request = directory.appendingPathComponent("req-\(name).json")
        let response = directory.appendingPathComponent("resp-\(name).json")
        var body = parameters
        body["kind"] = kind
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let staging = directory.appendingPathComponent("tmp-\(name).json")
        try data.write(to: staging)
        try FileManager.default.moveItem(at: staging, to: request)

        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: response.path) {
            guard Date() < deadline else {
                throw Failure(description: "host agent did not answer '\(kind)' within \(Int(timeout)) s")
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        let answer = try JSONSerialization.jsonObject(with: Data(contentsOf: response)) as? [String: Any] ?? [:]
        guard answer["ok"] as? Bool == true else {
            throw Failure(description: "host agent '\(kind)' failed: \(answer["error"] ?? "no detail")")
        }
        return answer
    }

    /// Appends one check's verdict and figures to the gate's results.
    func record(_ check: String, pass: Bool, _ figures: [String: Any]) throws {
        var body = figures
        body["check"] = check
        body["pass"] = pass
        try request("record", body, timeout: 10)
    }

    /// The app's settled phys_footprint in KB (CPU idle first, median of 3).
    func settledFootprintKB() throws -> Int {
        let answer = try request("footprint_settled", ["threshold_pct": 2.0], timeout: 60)
        guard let value = answer["footprint_kb"] as? Int else {
            throw Failure(description: "footprint_settled returned no footprint_kb")
        }
        return value
    }

    /// Seconds until the app's CPU is <= 2 % (nil: never within the timeout).
    func cpuSettleSeconds(timeout: TimeInterval = 15) throws -> (seconds: Double?, samples: Any) {
        let answer = try request("cpu_settle", ["threshold_pct": 2.0, "timeout_s": timeout], timeout: timeout + 30)
        return (answer["settle_s"] as? Double, answer["samples"] ?? [])
    }
}

/// Drives one launched ADFReader: renderer menu, About sheet, scrolling and
/// geometry. Mirrors the helpers of `RendererSwitchUITests` (which stays
/// untouched for the video).
@MainActor
struct ReaderDriver {
    enum Identifier {
        static let rendererMenu = "renderer-menu"
        static let rendererActive = "renderer-active"
        static let rendererSwiftUI = "renderer-swiftui"
        static let rendererTextKit2 = "renderer-textkit2"
        static let about = "renderer-about"
        static let buildVersion = "build-version"
        static let buildRenderer = "build-renderer"
        static let buildDone = "build-info-done"
        static let liveTextKit2Rows = "tk2-live-rows"
        static let loadSwitchBlocks = "load-switch-blocks"
        static let textKit2RowPrefix = "tk2-row:"
        static let searchField = "search-field"
        static let searchCounter = "search-counter"
    }

    let app: XCUIApplication

    init(launching arguments: [String]) {
        app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
    }

    func pause(_ seconds: TimeInterval = 1) {
        Thread.sleep(forTimeInterval: seconds)
    }

    // MARK: Renderer

    func waitForRenderer(_ name: String, timeout: TimeInterval = 15) {
        let predicate = NSPredicate(
            format: "(identifier == %@ OR identifier == %@) AND label CONTAINS %@",
            Identifier.rendererMenu, Identifier.rendererActive, name
        )
        let match = app.descendants(matching: .any).matching(predicate).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: timeout), "active renderer never became \(name)")
    }

    func openRendererMenu() {
        let control = app.descendants(matching: .any).matching(identifier: Identifier.rendererMenu).firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 15), "renderer menu control missing")
        control.tap()
        pause(0.5)
    }

    private func menuItem(identifier: String, label: String) -> XCUIElement {
        let predicate = NSPredicate(format: "identifier == %@ OR label == %@", identifier, label)
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    func chooseRenderer(textKit2: Bool) {
        let (identifier, label) = textKit2
            ? (Identifier.rendererTextKit2, "TextKit 2") : (Identifier.rendererSwiftUI, "SwiftUI")
        openRendererMenu()
        let item = menuItem(identifier: identifier, label: label)
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\(label) missing from the renderer menu")
        item.tap()
        waitForRenderer(label)
    }

    // MARK: About This Build

    func openAbout() {
        openRendererMenu()
        let about = menuItem(identifier: Identifier.about, label: "About This Build…")
        XCTAssertTrue(about.waitForExistence(timeout: 5), "About This Build… missing from the menu")
        about.tap()
        XCTAssertTrue(
            app.staticTexts[Identifier.buildVersion].waitForExistence(timeout: 5), "About This Build did not open"
        )
    }

    func closeAbout() {
        let done = app.buttons[Identifier.buildDone]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Done button missing")
        done.tap()
        XCTAssertTrue(waitForDisappearance(of: app.staticTexts[Identifier.buildVersion], timeout: 5),
                      "About sheet did not dismiss")
        pause(0.5)
    }

    /// Opens About, waits up to `timeout` for the live TextKit 2 row count to
    /// satisfy `condition`, closes About and returns the last number read.
    func liveTextKit2Rows(until condition: (Int) -> Bool, timeout: TimeInterval = 5) -> Int? {
        openAbout()
        let field = app.staticTexts[Identifier.liveTextKit2Rows]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "tk2-live-rows missing from About This Build")
        let deadline = Date().addingTimeInterval(timeout)
        var value: Int?
        repeat {
            value = Int(field.label)
            if let value, condition(value) { break }
            pause(0.25)
        } while Date() < deadline
        closeAbout()
        return value
    }

    // MARK: Elements and geometry

    func element(labelled text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", text)).firstMatch
    }

    func element(labelPrefix prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    func textKit2Row(labelPrefix prefix: String) -> XCUIElement {
        let predicate = NSPredicate(
            format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", Identifier.textKit2RowPrefix, prefix
        )
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    var anyTextKit2Row: XCUIElement {
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", Identifier.textKit2RowPrefix)
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    /// The window below the navigation bar and above the keyboard and the
    /// Find-in-Page bar, when those are up.
    var viewport: CGRect {
        let window = app.windows.firstMatch.frame
        let navigationBar = app.navigationBars.firstMatch
        let top = navigationBar.exists ? navigationBar.frame.maxY : window.minY
        var bottom = window.maxY
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists { bottom = min(bottom, keyboard.frame.minY) }
        let searchField = app.textFields[Identifier.searchField]
        if searchField.exists { bottom = min(bottom, searchField.frame.minY - 12) }
        return CGRect(x: window.minX, y: top, width: window.width, height: max(0, bottom - top))
    }

    func isVisible(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        let viewport = viewport
        return frame.height > 0 && frame.minY >= viewport.minY && frame.maxY <= viewport.maxY
    }

    /// Device pixels per point (screenshot width over window width).
    func pixelScale() -> CGFloat {
        let pixels = CGFloat(XCUIScreen.main.screenshot().image.cgImage?.width ?? 0)
        let points = app.windows.firstMatch.frame.width
        XCTAssertGreaterThan(pixels, 0, "screenshot has no pixels")
        XCTAssertGreaterThan(points, 0, "window has no width")
        return points > 0 ? pixels / points : 1
    }

    /// Top edges (points) of every uniquely labelled element fully inside the
    /// viewport, from one accessibility snapshot of the document.
    func visibleLabels() throws -> [String: CGFloat] {
        let root = try app.scrollViews.firstMatch.snapshot()
        let viewport = viewport
        var tops: [String: CGFloat] = [:]
        var duplicates: Set<String> = []
        func walk(_ node: XCUIElementSnapshot) {
            let frame = node.frame
            if !node.label.isEmpty, frame.height > 0, frame.minY >= viewport.minY, frame.maxY <= viewport.maxY {
                if tops[node.label] != nil, tops[node.label] != frame.minY {
                    duplicates.insert(node.label)
                } else {
                    tops[node.label] = frame.minY
                }
            }
            for child in node.children {
                walk(child)
            }
        }
        walk(root)
        for label in duplicates {
            tops[label] = nil
        }
        return tops
    }

    /// A slow, held drag (no fling momentum): `points` > 0 moves the content
    /// up (scrolls toward the end), < 0 moves it down.
    /// The drag starts and ends inside `viewport` (never on the keyboard or
    /// the search bar); longer requests are clamped to what fits.
    func drag(by points: CGFloat) {
        let area = viewport.insetBy(dx: 0, dy: 30)
        let length = min(abs(points), area.height)
        let startY = points > 0 ? area.maxY : area.minY
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: area.midX, dy: startY))
        let end = origin.withOffset(CGVector(dx: area.midX, dy: points > 0 ? startY - length : startY + length))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }
}

/// Per-label vertical displacement between two `visibleLabels()` snapshots.
struct LabelShift {
    let common: Int
    /// Largest |ΔY| over the common labels, in device pixels.
    let maxPixels: CGFloat
    let worstLabel: String

    init(from before: [String: CGFloat], to after: [String: CGFloat], scale: CGFloat) {
        var worst: (label: String, pixels: CGFloat) = ("", 0)
        var count = 0
        for (label, y0) in before {
            guard let y1 = after[label] else { continue }
            count += 1
            let pixels = abs(y1 - y0) * scale
            if pixels > worst.pixels { worst = (label, pixels) }
        }
        common = count
        maxPixels = worst.pixels
        worstLabel = worst.label
    }
}
