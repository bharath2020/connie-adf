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
    /// Settled phys_footprint; `relieved` first has the app return its free
    /// malloc pages (`MemoryReliefHook`, needs `-memoryReliefHook`) —
    /// diagnostics only: no gate reads a relieved figure.
    func settledFootprintKB(relieved: Bool = false) throws -> Int {
        let answer = try request("footprint_settled", ["threshold_pct": 2.0, "relieve": relieved], timeout: 60)
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

    /// The device pasteboard's string, read on the host
    /// (`xcrun simctl pbpaste`): reading `UIPasteboard` in the test runner
    /// raises the cross-app paste prompt and blocks the run.
    func pasteboard() throws -> String {
        let answer = try request(Self.pasteboardReadKind, timeout: 30)
        guard let text = answer["text"] as? String else {
            throw Failure(description: "\(Self.pasteboardReadKind) returned no text")
        }
        return text
    }

    /// Puts `text` on the device pasteboard from the host
    /// (`xcrun simctl pbcopy`), so that a later read proves what replaced it.
    func setPasteboard(_ text: String) throws {
        try request(Self.pasteboardWriteKind, ["text": text], timeout: 30)
    }

    /// Request kinds of `Scripts/lifecycle_agent.py` for the pasteboard.
    static let pasteboardReadKind = "pasteboard"
    static let pasteboardWriteKind = "pasteboard_set"
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
        static let buildSHA256 = "build-sha256"
        static let buildRenderer = "build-renderer"
        static let buildDone = "build-info-done"
        static let liveTextKit2Rows = "tk2-live-rows"
        /// Live TextKit 2 rows of owner kind list (PR 2), nested-list rows
        /// in containers included from PR 4's step 6.
        static let liveTextKit2ListRows = "tk2-list-live-rows"
        /// Live TextKit 2 rows drawing a code block's code (a subset of
        /// `liveTextKit2Rows`; PR 3).
        static let liveTextKit2CodeRows = "tk2-code-live-rows"
        /// PR 4 (plan §6.4): live TextKit 2 rows with context container
        /// and an owner kind other than code; with context caption; and
        /// TextKit 2 row views alive off any window. Below
        /// `liveTextKit2CodeRows` on the About sheet.
        static let liveTextKit2ContainerRows = "tk2-container-live-rows"
        static let liveTextKit2CaptionRows = "tk2-caption-live-rows"
        static let offWindowTextKit2Rows = "tk2-offwindow-rows"
        static let rebuildControlRows = "rebuild-control-rows"
        static let loadSwitchBlocks = "load-switch-blocks"
        static let loadReadyBlocks = "load-ready-blocks"
        static let textKit2RowPrefix = "tk2-row:"
        /// The accessibility label of a code block's Copy button.
        static let copyCodeLabel = "Copy code"
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
        XCTAssertTrue(isRenderer(name, timeout: timeout), "active renderer never became \(name)")
    }

    /// Whether the toolbar names `name` as the active renderer within
    /// `timeout` (no assertion).
    func isRenderer(_ name: String, timeout: TimeInterval = 15) -> Bool {
        let predicate = NSPredicate(
            format: "(identifier == %@ OR identifier == %@) AND label CONTAINS %@",
            Identifier.rendererMenu, Identifier.rendererActive, name
        )
        return app.descendants(matching: .any).matching(predicate).firstMatch.waitForExistence(timeout: timeout)
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

    /// `chooseRenderer`, timed (K8's M2 flip): wall seconds from just
    /// before the tap on the menu item to the toolbar naming the new
    /// renderer and `done` existing, polled every 50 ms (as
    /// `ContainerDriver.seconds`: `waitForExistence` checks about once a
    /// second); nil when that is not reached within `timeout`. XCUITest
    /// waits for the app to idle after the tap and every poll reads the
    /// tree on the app's main thread, so the rebuild the pick causes there
    /// is inside the time.
    func chooseRendererTimed(textKit2: Bool, until done: XCUIElement, timeout: TimeInterval = 60) -> Double? {
        let (identifier, label) = textKit2
            ? (Identifier.rendererTextKit2, "TextKit 2") : (Identifier.rendererSwiftUI, "SwiftUI")
        openRendererMenu()
        let item = menuItem(identifier: identifier, label: label)
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\(label) missing from the renderer menu")
        let active = app.descendants(matching: .any).matching(NSPredicate(
            format: "(identifier == %@ OR identifier == %@) AND label CONTAINS %@",
            Identifier.rendererMenu, Identifier.rendererActive, label
        )).firstMatch
        let tapped = Date()
        item.tap()
        let deadline = tapped.addingTimeInterval(timeout)
        while Date() < deadline {
            if active.exists, done.exists { return Date().timeIntervalSince(tapped) }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return active.exists && done.exists ? Date().timeIntervalSince(tapped) : nil
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
    /// With `settled`, a value counts only once two consecutive reads 250 ms
    /// apart agree, so a read taken mid-materialisation is never accepted.
    func liveTextKit2Rows(until condition: (Int) -> Bool, settled: Bool = false, timeout: TimeInterval = 5) -> Int? {
        openAbout()
        let value = readLiveTextKit2Rows(until: condition, settled: settled, timeout: timeout)
        closeAbout()
        return value
    }

    /// The open About sheet's live TextKit 2 row count (it shows "…" until
    /// its first read and refreshes every 250 ms); waits up to `timeout` for
    /// a value satisfying `condition` and returns the last number read.
    func readLiveTextKit2Rows(until condition: (Int) -> Bool, settled: Bool = false, timeout: TimeInterval = 5) -> Int? {
        readCount(Identifier.liveTextKit2Rows, until: condition, settled: settled, timeout: timeout)
    }

    /// Opens About and reads both live row counts under `-rebuildControlPicks`
    /// — TextKit 2 rows and the memory control's SwiftUI rows — waiting on
    /// `condition` for the one `control` selects and reading the other once,
    /// so the control and the TextKit 2 switches make the same queries.
    func liveRows(control: Bool, until condition: (Int) -> Bool, settled: Bool = false, timeout: TimeInterval = 5)
        -> (textKit2: Int?, control: Int?)
    {
        openAbout()
        let (waited, other) = control
            ? (Identifier.rebuildControlRows, Identifier.liveTextKit2Rows)
            : (Identifier.liveTextKit2Rows, Identifier.rebuildControlRows)
        let value = readCount(waited, until: condition, settled: settled, timeout: timeout)
        let rest = readCount(other, until: { _ in true })
        closeAbout()
        return control ? (rest, value) : (value, rest)
    }

    /// Opens About and reads the live TextKit 2 row count, waiting on
    /// `condition` as `liveTextKit2Rows` does, then the live code-row count
    /// (`readLiveCodeRows`, two agreeing reads with `settled`); closes
    /// About. The row count is read first: it sits above the code count,
    /// and `revealAboutField` only ever scrolls toward the end.
    func liveCodeRows(until condition: (Int) -> Bool, settled: Bool = false, timeout: TimeInterval = 5)
        -> (textKit2: Int?, code: Int?)
    {
        openAbout()
        let live = readCount(Identifier.liveTextKit2Rows, until: condition, settled: settled, timeout: timeout)
        let code = readLiveCodeRows(until: { _ in true }, settled: settled)
        closeAbout()
        return (live, code)
    }

    /// `liveRows(control:until:settled:timeout:)` plus the live code-row
    /// count, read last (`readLiveCodeRows`): the same About queries for the
    /// memory control and the TextKit 2 switches of a code series.
    func liveRowsAndCode(control: Bool, until condition: (Int) -> Bool, settled: Bool = false,
                         timeout: TimeInterval = 5) -> (textKit2: Int?, control: Int?, code: Int?)
    {
        openAbout()
        let (waited, other) = control
            ? (Identifier.rebuildControlRows, Identifier.liveTextKit2Rows)
            : (Identifier.liveTextKit2Rows, Identifier.rebuildControlRows)
        let value = readCount(waited, until: condition, settled: settled, timeout: timeout)
        let rest = readCount(other, until: { _ in true })
        let code = readLiveCodeRows(until: { _ in true }, settled: settled)
        closeAbout()
        return control ? (rest, value, code) : (value, rest, code)
    }

    /// The open About sheet's live code-row count (`tk2-code-live-rows`:
    /// live TextKit 2 rows drawing a code block's code). Its section is
    /// the one PR 3 added, below the executable checksum so that no row a
    /// test reads without scrolling moved; it is scrolled into the sheet
    /// first (`revealAboutField`), so read it after every row above it.
    func readLiveCodeRows(until condition: (Int) -> Bool, settled: Bool = false, timeout: TimeInterval = 5) -> Int? {
        revealAboutField(app.staticTexts[Identifier.liveTextKit2CodeRows])
        return readCount(Identifier.liveTextKit2CodeRows, until: condition, settled: settled, timeout: timeout)
    }

    /// Opens About and reads the live counters a row census is checked
    /// against (`TextKit2RowCensus.crossCheck`, PR 4 plan §6.5), top to
    /// bottom because `revealAboutField` only scrolls toward the end:
    /// `tk2-live-rows`, `tk2-list-live-rows`, then `tk2-code-live-rows` and
    /// PR 4's `tk2-container-live-rows`, `tk2-caption-live-rows` and
    /// `tk2-offwindow-rows` below it. With `settled`, each value counts
    /// once two reads 250 ms apart agree. A field this build's About sheet
    /// lacks reads nil (a pre-PR 4 build has none of the last three), and
    /// the cross-check reports it. Closes About.
    func liveRowCounters(settled: Bool = true) -> LiveRowCounters {
        openAbout()
        var counters = LiveRowCounters()
        counters.total = readOptionalCount(Identifier.liveTextKit2Rows, settled: settled)
        counters.list = readOptionalCount(Identifier.liveTextKit2ListRows, settled: settled)
        counters.code = readOptionalCount(Identifier.liveTextKit2CodeRows, settled: settled)
        counters.container = readOptionalCount(Identifier.liveTextKit2ContainerRows, settled: settled)
        counters.caption = readOptionalCount(Identifier.liveTextKit2CaptionRows, settled: settled)
        counters.offWindow = readOptionalCount(Identifier.offWindowTextKit2Rows, settled: settled)
        closeAbout()
        return counters
    }

    /// The open About sheet's count in `identifier`, scrolled into view
    /// first; nil (no assertion) when the sheet has no such field.
    func readOptionalCount(_ identifier: String, settled: Bool = true, timeout: TimeInterval = 5) -> Int? {
        let field = app.staticTexts[identifier]
        revealAboutField(field)
        guard field.exists else { return nil }
        return readCount(identifier, until: { _ in true }, settled: settled, timeout: timeout)
    }

    /// About This Build is a list, so a row is in the accessibility tree
    /// only while it is on screen. Does nothing when `field` exists;
    /// otherwise drags the sheet's content up 160 pt at a time (rows read
    /// just before stay in view) until it does, at most `maxDrags` times.
    /// Never scrolls back: a downward drag at the top would dismiss the
    /// sheet, so read rows top to bottom.
    func revealAboutField(_ field: XCUIElement, maxDrags: Int = 6) {
        guard !field.waitForExistence(timeout: 2) else { return }
        let window = app.windows.firstMatch.frame
        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: window.midX, dy: window.minY + window.height * 0.7))
        var drags = 0
        while !field.exists, drags < maxDrags {
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -160)),
                        withVelocity: .slow, thenHoldForDuration: 0.2)
            pause(0.4)
            drags += 1
        }
    }

    /// The open About sheet's count in the field `identifier` (see
    /// `readLiveTextKit2Rows`).
    func readCount(_ identifier: String, until condition: (Int) -> Bool, settled: Bool = false,
                   timeout: TimeInterval = 5) -> Int?
    {
        let field = app.staticTexts[identifier]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "\(identifier) missing from About This Build")
        let deadline = Date().addingTimeInterval(timeout)
        var value: Int?
        var previous: Int?
        repeat {
            value = Int(field.label)
            if let value, condition(value), !settled || previous == value { break }
            previous = value
            pause(0.25)
        } while Date() < deadline
        return value
    }

    // MARK: Elements and geometry

    func element(labelled text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", text)).firstMatch
    }

    func element(labelPrefix prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    func textKit2Row(labelled text: String) -> XCUIElement {
        let predicate = NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", Identifier.textKit2RowPrefix, text
        )
        return app.descendants(matching: .any).matching(predicate).firstMatch
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
        try documentSnapshot().tops
    }

    /// The `-fixture` value this app was (re)launched with; nil for a
    /// launch without one (a fixture opened from the list).
    var launchedFixture: String? {
        let arguments = app.launchArguments
        guard let index = arguments.firstIndex(of: "-fixture"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// One accessibility snapshot of the document scroll view: every
    /// labelled element (those fully inside the viewport are `visible`),
    /// and every TextKit 2 row (`tk2-row:<owner>`) anywhere in the snapshot.
    /// An element inside a scroll view nested in the document's own is
    /// marked (`inNestedScroll`): a code block's code sits in the block's
    /// horizontal scroll view under either renderer, which is how a
    /// TextKit 2 code row is told from a root paragraph's (their owners
    /// have the same form, `0.<n>`).
    ///
    /// Its TextKit 2 rows are classified (`TextKit2RowCensus`, PR 4 plan
    /// §6.5) with the owner table of `fixture` (default: the launched
    /// fixture, `launchedFixture`; `RowOwnerTable.byFixture`).
    func documentSnapshot(fixture: String? = nil) throws -> DocumentSnapshot {
        let root = try app.scrollViews.firstMatch.snapshot()
        let viewport = viewport
        var all: [DocumentSnapshot.Node] = []
        var nestedScrolls: [CGRect] = []
        var copyButtons: [CGRect] = []
        var rows: [(owner: String, frame: CGRect, nested: Bool)] = []
        var textKit2Rows: [String: String] = [:]
        var textKit2Nodes = 0
        func walk(_ node: XCUIElementSnapshot, nested: Bool, isRoot: Bool) {
            let frame = node.frame
            let isNestedScroll = !isRoot && node.elementType == .scrollView
            if isNestedScroll {
                nestedScrolls.append(frame)
            }
            if node.elementType == .button, node.label == Identifier.copyCodeLabel {
                copyButtons.append(frame)
            }
            let owner = node.identifier.hasPrefix(Identifier.textKit2RowPrefix)
                ? String(node.identifier.dropFirst(Identifier.textKit2RowPrefix.count)) : nil
            if let owner {
                textKit2Rows[owner] = node.label
                textKit2Nodes += 1
                rows.append((owner, frame, nested))
            }
            // Scroll indicators carry a page-count label that tracks the
            // estimated content height, not a row.
            let isIndicator = node.label.hasPrefix("Vertical scroll bar") || node.label.hasPrefix("Horizontal scroll bar")
            if !node.label.isEmpty, !isIndicator, frame.height > 0 {
                all.append(DocumentSnapshot.Node(
                    label: node.label, frame: frame, owner: owner, type: node.elementType,
                    value: (node.value as? String) ?? "", inNestedScroll: nested
                ))
            }
            for child in node.children {
                walk(child, nested: nested || isNestedScroll, isRoot: false)
            }
        }
        walk(root, nested: false, isRoot: true)
        // The same answer by geometry, for two shapes the accessibility
        // tree could take instead (neither was run when this was written).
        // A nested scroll view listed beside its content, not above it: an
        // element is inside one when the scroll view's frame holds its
        // whole height (the frame is the block's viewport: full content
        // height, the visible width). No nested scroll view listed at all:
        // a code block's code starts under its own Copy button (the header
        // row, then the code's padding), nearer than any following block
        // can be (a one-line block's text and both paddings lie between).
        let noNestedScrolls = nestedScrolls.isEmpty
        func inside(_ frame: CGRect) -> Bool {
            if noNestedScrolls {
                return copyButtons.contains { $0.maxY <= frame.minY + 1 && frame.minY - $0.maxY <= 40 }
            }
            return nestedScrolls.contains {
                $0.minY <= frame.minY + 0.5 && frame.maxY <= $0.maxY + 0.5 && frame.maxX > $0.minX && frame.minX < $0.maxX
            }
        }
        for index in all.indices where !all[index].inNestedScroll && all[index].type != .button
            && inside(all[index].frame)
        {
            all[index].inNestedScroll = true
        }
        // A row inside a nested horizontal scroll view is code, whatever
        // its owner's form (PR 4 plan §6.5: nested code counts as code from
        // PR 4's step 7; PR 3 also required a root-form owner).
        let fixtureName = fixture ?? launchedFixture
        let census = TextKit2RowCensus(
            rows: rows.map { (owner: $0.owner, inNestedScroll: $0.nested || inside($0.frame)) },
            fixture: fixtureName, table: fixtureName.flatMap { RowOwnerTable.byFixture[$0] }
        )
        var snapshot = DocumentSnapshot(
            all: all, viewport: viewport, textKit2Rows: textKit2Rows, textKit2Nodes: textKit2Nodes, census: census
        )
        snapshot.nestedScrollViews = nestedScrolls.count
        snapshot.codeOwnersByTree = Set(rows.filter(\.nested).map(\.owner))
        snapshot.codeOwnersByGeometry = Set(rows.filter { !$0.nested && inside($0.frame) }.map(\.owner))
        return snapshot
    }

    /// Waits up to `timeout` for `element` to be fully inside the viewport.
    func waitUntilVisible(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if isVisible(element) { return true }
            pause(0.25)
        } while Date() < deadline
        return isVisible(element)
    }

    // MARK: Text size, fixture list, tasks

    /// Opens the toolbar's Text Size popover, taps its larger (`steps` > 0)
    /// or smaller (`steps` < 0) button `|steps|` times, reads the percent
    /// readout and dismisses the popover. Launch with `-fontSizeStep 0` so
    /// the taps never write the persisted per-document size.
    @discardableResult
    func stepTextSize(_ steps: Int) -> String? {
        let toggle = app.buttons["Text Size"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Text Size control missing")
        toggle.tap()
        let button = app.buttons[steps > 0 ? "Increase Text Size" : "Decrease Text Size"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Text Size popover did not open")
        for _ in 0 ..< abs(steps) {
            button.tap()
            pause(0.4)
        }
        let readout = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^[0-9]+%$")).firstMatch
        let value = readout.exists ? readout.label : nil
        let dismissRegion = app.otherElements["PopoverDismissRegion"]
        if dismissRegion.exists {
            dismissRegion.tap()
        } else {
            toggle.tap()
        }
        XCTAssertTrue(waitForDisappearance(of: button, timeout: 5), "Text Size popover did not close")
        pause(0.5)
        return value
    }

    /// From the fixture list (a launch without `-fixture`), opens `name`.
    func openFixture(_ name: String) {
        let candidates = [app.buttons[name], app.cells.containing(.staticText, identifier: name).firstMatch,
                          app.staticTexts[name]]
        var swipes = 0
        while swipes < 8 {
            if let link = candidates.first(where: { $0.exists && $0.isHittable }) {
                link.tap()
                return
            }
            app.swipeUp()
            swipes += 1
        }
        XCTFail("\(name) is not in the fixture list")
    }

    /// Back from a pushed reader to the fixture list ("Confluence").
    func goBack() {
        let bar = app.navigationBars.firstMatch
        let back = bar.buttons["Confluence"]
        (back.exists ? back : bar.buttons.element(boundBy: 0)).tap()
        XCTAssertTrue(app.navigationBars["Confluence"].waitForExistence(timeout: 10), "did not return to the fixture list")
        pause(0.5)
    }

    /// The task checkbox ("Task" / "Completed task") on the row whose leader
    /// is labelled `leader`: the checkbox left of the leader that overlaps
    /// its first line.
    func taskMarker(leader: String) -> XCUIElement? {
        let lead = element(labelled: leader)
        guard lead.exists else { return nil }
        let line = lead.frame
        let boxes = app.buttons.matching(
            NSPredicate(format: "label == %@ OR label == %@", "Task", "Completed task")
        ).allElementsBoundByIndex
        return boxes.filter {
            let frame = $0.frame
            return frame.maxX <= line.minX + 1 && frame.maxY > line.minY && frame.minY < line.minY + min(line.height, 40)
        }.min { abs($0.frame.midY - line.minY) < abs($1.frame.midY - line.minY) }
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

    /// A horizontal pan that starts at `point` (screen points): `points`
    /// > 0 moves the finger left (the content toward its end), < 0 right.
    /// Held at the end by default, so no fling momentum follows; a fling
    /// is `velocity: .fast, hold: 0`.
    func pan(from point: CGPoint, by points: CGFloat, velocity: XCUIGestureVelocity = .slow,
             hold: TimeInterval = 0.3)
    {
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: point.x, dy: point.y))
        let end = origin.withOffset(CGVector(dx: point.x - points, dy: point.y))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: velocity, thenHoldForDuration: hold)
    }

    /// Where a horizontal pan toward the end of the code whose text has
    /// `frame` starts: 40 pt in from the viewport's trailing edge (the
    /// finger then has the viewport's width to travel left), at the middle
    /// of the part of the text's height that is in view. The bottom 60 pt
    /// of the viewport do not count as in view: a horizontal swipe there
    /// is the home indicator's (it switches apps). nil when under 20 pt of
    /// the text's height is in view. A code block's horizontal scroll view
    /// spans the block's width, so the point is on it whether or not a
    /// line reaches that far.
    func panStart(onCodeText frame: CGRect) -> CGPoint? {
        let viewport = viewport
        let top = max(frame.minY, viewport.minY + 8)
        let bottom = min(frame.maxY, viewport.maxY - 60)
        guard bottom - top >= 20 else { return nil }
        return CGPoint(x: viewport.maxX - 40, y: (top + bottom) / 2)
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

    /// Pairs of common labels whose top-to-bottom order differs between the
    /// two snapshots (pairs within 1 pt of each other in `before`, such as a
    /// marker and its leader, are not ordered).
    static func orderInversions(from before: [String: CGFloat], to after: [String: CGFloat]) -> [String] {
        let common = before.compactMap { label, y0 in after[label].map { (label: label, y0: y0, y1: $0) } }
            .sorted { $0.y0 < $1.y0 }
        var inversions: [String] = []
        for (i, upper) in common.enumerated() {
            for lower in common[(i + 1)...] where lower.y0 - upper.y0 > 1 && lower.y1 <= upper.y1 {
                inversions.append("\(upper.label.prefix(24)) / \(lower.label.prefix(24))")
            }
        }
        return inversions
    }

    /// `tops` measured from `anchor`'s top (nil when `anchor` is absent).
    /// The anchor's own entry is 0 by construction, so a `LabelShift` over
    /// two relative snapshots counts it as a common label that cannot move
    /// (Astra R2). The code tests C2 and C3 use `AnchoredShift` instead;
    /// PR 2's L2, L3a and L4b still use this (follow-up: move them).
    static func relative(_ tops: [String: CGFloat], to anchor: String) -> [String: CGFloat]? {
        guard let origin = tops[anchor] else { return nil }
        return tops.mapValues { $0 - origin }
    }
}

/// Code text geometry of one snapshot (C2, C3): each on-screen code
/// text's top and bottom edge (points), by `CD-<iii>`, and the bottom of
/// the viewport the snapshot was read with. An accessibility frame is the
/// element's full frame, so a top above or a bottom below the viewport is
/// still a measurement.
struct CodeGeometry {
    var tops: [String: CGFloat] = [:]
    var bottoms: [String: CGFloat] = [:]
    var viewportMaxY: CGFloat = 0
}

/// Displacement between two snapshots measured from an anchor text's top
/// (C2's round trips, C3's legs; Astra R2).
///
/// The anchor's own top is zero by construction, so it is not a
/// measurement. Measured: the top of every other common text, and the
/// bottom of every common text, the anchor's included (its height).
/// Proven only when something the normalisation did not zero is compared:
/// at least one other common text, or, for an anchor that runs past the
/// viewport bottom in both snapshots (no text can follow it on screen),
/// its own bottom in both. Anything less is unproven, never a pass.
struct AnchoredShift {
    let anchor: String
    /// Common texts other than the anchor (their tops are measured).
    let otherLabels: Int
    /// Values compared: other texts' tops plus every common text's bottom.
    let measured: Int
    /// The measured landmarks, "CD-<iii> top" / "CD-<iii> bottom", sorted.
    let landmarks: [String]
    /// Largest displacement over `landmarks`, in device pixels.
    let maxPixels: CGFloat
    let worst: String
    /// The anchor runs past the viewport bottom in both snapshots.
    let anchorFillsViewport: Bool
    /// Why the comparison proves nothing (nil when it is proven).
    let unproven: String?
    var proven: Bool { unproven == nil }

    init(from before: CodeGeometry, to after: CodeGeometry, anchor: String, scale: CGFloat) {
        self.anchor = anchor
        let fills = [before, after].allSatisfy { snap in
            snap.bottoms[anchor].map { $0 >= snap.viewportMaxY } ?? false
        }
        guard let a0 = before.tops[anchor], let a1 = after.tops[anchor] else {
            otherLabels = 0
            measured = 0
            landmarks = []
            maxPixels = 0
            worst = ""
            anchorFillsViewport = false
            unproven = "anchor \(anchor) is not on screen in both snapshots"
            return
        }
        // Sorted, so that ties name the same worst landmark every run.
        var values: [(String, CGFloat)] = []
        var others = 0
        for label in before.tops.keys.sorted() where label != anchor {
            guard let top0 = before.tops[label], let top1 = after.tops[label] else { continue }
            others += 1
            values.append(("\(label) top", abs((top1 - a1) - (top0 - a0)) * scale))
        }
        for label in before.bottoms.keys.sorted() {
            guard let bottom0 = before.bottoms[label], let bottom1 = after.bottoms[label] else { continue }
            values.append(("\(label) bottom", abs((bottom1 - a1) - (bottom0 - a0)) * scale))
        }
        otherLabels = others
        measured = values.count
        landmarks = values.map { $0.0 }.sorted()
        var top: (String, CGFloat)?
        for value in values where value.1 > top?.1 ?? -1 {
            top = value
        }
        maxPixels = top?.1 ?? 0
        worst = top?.0 ?? ""
        // `fills` implies both of the anchor's bottoms are present, so its
        // height is among `values`.
        anchorFillsViewport = fills
        if others > 0 || fills {
            unproven = nil
        } else {
            unproven = "anchor-only: no other common code text, and \(anchor) does not run past the viewport "
                + "bottom in both snapshots"
        }
    }

    /// The figures a check records for this comparison.
    var figures: [String: Any] {
        ["px": Double(maxPixels), "other_labels": otherLabels, "measured": measured, "landmarks": landmarks,
         "worst": worst, "anchor_fills_viewport": anchorFillsViewport, "proven": proven,
         "unproven": unproven ?? ""]
    }
}

/// One accessibility snapshot of the document (`ReaderDriver.documentSnapshot`).
struct DocumentSnapshot {
    struct Node {
        let label: String
        let frame: CGRect
        /// The owner ID when this element is a TextKit 2 row (`tk2-row:<owner>`).
        let owner: String?
        /// Element type and value (the accessibility-tree comparisons).
        var type: XCUIElement.ElementType = .any
        var value = ""
        /// Inside a scroll view nested in the document's own. In a document
        /// whose only nested scroll views are code blocks' (code-parity,
        /// code-dense, code-tall) that is a code block's code text, drawn
        /// by either renderer: the badge and the Copy button sit above the
        /// block's scroll view, not in it.
        var inNestedScroll = false
    }

    /// Every labelled element of the snapshot, in or out of the viewport,
    /// in snapshot order (scroll indicators excluded).
    let all: [Node]
    /// The viewport the snapshot was read with (`ReaderDriver.viewport`).
    let viewport: CGRect
    /// Labelled elements fully inside the viewport, in snapshot order.
    let visible: [Node]
    /// Owner → label of every TextKit 2 row in the snapshot, in or out of
    /// the viewport.
    let textKit2Rows: [String: String]
    /// TextKit 2 row elements in the snapshot, counted without merging
    /// owners (equals `textKit2Rows.count` unless an owner appears twice).
    let textKit2Nodes: Int
    /// Every TextKit 2 row's class (PR 4 plan §6.5).
    let census: TextKit2RowCensus
    /// How a TextKit 2 row was told to be code (review F-Q4): owners whose
    /// row sits under a scroll-view node of the tree below the document's
    /// own (`codeOwnersByTree`), and owners only the geometry fallback
    /// (`inside`) placed in one (`codeOwnersByGeometry`); and the nested
    /// scroll-view nodes the tree listed.
    var codeOwnersByTree: Set<String> = []
    var codeOwnersByGeometry: Set<String> = []
    var nestedScrollViews = 0

    init(all: [Node], viewport: CGRect, textKit2Rows: [String: String], textKit2Nodes: Int,
         census: TextKit2RowCensus)
    {
        self.all = all
        self.viewport = viewport
        visible = all.filter { $0.frame.minY >= viewport.minY && $0.frame.maxY <= viewport.maxY }
        self.textKit2Rows = textKit2Rows
        self.textKit2Nodes = textKit2Nodes
        self.census = census
    }

    /// Owners of the TextKit 2 rows that draw a code block's code: rows
    /// inside a nested scroll view, the code block's horizontal viewport
    /// (PR 3; nested code too since PR 4).
    var codeRowOwners: Set<String> { Set(census.owners(.code)) }

    /// The elements inside a nested scroll view (`Node.inNestedScroll`):
    /// the code texts of a code fixture, in document order.
    var codeTexts: [Node] { all.filter { $0.inNestedScroll } }

    /// Whether any part of `node` is inside the viewport. A code block can
    /// be taller than the screen, so `visible` (fully inside) may never
    /// hold for it.
    func isOnScreen(_ node: Node) -> Bool {
        node.frame.maxY > viewport.minY && node.frame.minY < viewport.maxY
    }

    /// Top edge (points) of every uniquely labelled visible element; a label
    /// seen at two different tops is dropped (it recurs, so it cannot be
    /// tracked).
    var tops: [String: CGFloat] {
        var tops: [String: CGFloat] = [:]
        var duplicates: Set<String> = []
        for node in visible {
            if tops[node.label] != nil, tops[node.label] != node.frame.minY {
                duplicates.insert(node.label)
            } else {
                tops[node.label] = node.frame.minY
            }
        }
        for label in duplicates {
            tops[label] = nil
        }
        return tops
    }

    /// Visible label → TextKit 2 owner, for the uniquely labelled visible
    /// elements that are TextKit 2 rows.
    var owners: [String: String] {
        let tops = tops
        var owners: [String: String] = [:]
        for node in visible where tops[node.label] != nil {
            if let owner = node.owner { owners[node.label] = owner }
        }
        return owners
    }

    /// The census classes as counts (owners, one class each; PR 4 plan
    /// §6.5). Their sum plus `unclassifiedRows` is `textKit2Rows.count`.
    ///
    /// TextKit 2 rows that draw a code block's code (PR 3): a row inside a
    /// nested scroll view, whatever its owner (a top-level block's `0.<n>`,
    /// or a nested code block's node path from PR 4's step 7).
    var codeOwnedRows: Int { census.count(.code) }
    /// TextKit 2 rows owned by a root text block (`0.<n>`: a top-level
    /// paragraph or heading, the PR 1 scope) that are not code: on a
    /// document with top-level code (kitchen-sink, the stress fixtures)
    /// this counts root text only, and on one without it nothing changes.
    var rootOwnedRows: Int { census.count(.root) }
    /// TextKit 2 rows of top-level lists (list leaders, `PreparedListRow.id`,
    /// and list trailing text, its block's node path): every row not
    /// placed otherwise on a fixture without an owner table, and only the
    /// table's list rows on one with a table. Container and caption rows
    /// are never list rows here (nested-list rows in a container count in
    /// `containerOwnedRows`).
    var listOwnedRows: Int { census.count(.list) }
    /// TextKit 2 rows of text inside a container (panel, quote, expand,
    /// layout column, extension body), by the fixture's owner table; 0
    /// without one.
    var containerOwnedRows: Int { census.count(.container) }
    /// Of `containerOwnedRows`, the rows of a list nested in a container
    /// (owner kind list: they count toward `tk2-list-live-rows`).
    var containerListOwnedRows: Int { census.containerListOwners.count }
    /// TextKit 2 rows of a mediaSingle caption, by the fixture's owner
    /// table; 0 without one.
    var captionOwnedRows: Int { census.count(.caption) }
    /// TextKit 2 rows the fixture's owner table places in no class (a
    /// table that misses an owner); always 0 without a table.
    var unclassifiedRows: Int { census.unclassified.count }

    static func isRootOwner(_ owner: String) -> Bool {
        TextKit2RowCensus.isRootOwner(owner)
    }

    /// The top of the visible element labelled `marker` on `leader`'s row:
    /// left of the leader and overlapping its first line (an ordered list
    /// marker; bullets are hidden from accessibility).
    func markerTop(_ marker: String, leader: String) -> CGFloat? {
        guard let line = visible.first(where: { $0.label == leader })?.frame else { return nil }
        return visible.filter {
            $0.label == marker && $0.frame.maxX <= line.minX + 1 && $0.frame.maxY > line.minY
                && $0.frame.minY < line.minY + min(line.height, 40)
        }.min { abs($0.frame.minY - line.minY) < abs($1.frame.minY - line.minY) }?.frame.minY
    }
}

// MARK: - Row classifier (PR 4 plan §6.5)
// Foundation only, so the census logic compiles and is checked apart from
// any app (TextKit2RowClassifierTests).

/// The class of one TextKit 2 row (`tk2-row:<owner>`) in a lifecycle census
/// (PR 4 plan §6.5). The accessibility identifier carries neither the
/// row's owner kind nor its context, so a census assigns the class from
/// where the row sits and from the fixture's owner table; every row gets
/// exactly one class, or is reported as unclassified.
enum TextKit2RowClass: String, CaseIterable, Sendable {
    /// A code block's code (owner kind code, any context): a row inside a
    /// nested horizontal scroll view, the code block's viewport.
    case code
    /// A mediaSingle caption (context caption): by the owner table.
    case caption
    /// Text inside a panel, quote, expand, layout column or extension body
    /// (owner kind root or list, context container; nested-list rows
    /// included): by the owner table.
    case container
    /// A top-level list's leader or trailing text (owner kind list, no
    /// context): every remaining row on a fixture without an owner table;
    /// on one with a table, the table's top-level lists (or every
    /// remaining row when the table leaves `list` nil).
    case list
    /// A root text block's row (owner `0.<n>`, owner kind root, no context)
    /// that is not code.
    case root
}

/// A fixture's hand-reviewed owner table (PR 4 plan §6.5), generated beside
/// the fixture and reviewed with it, as PR 3 tabulates CP-25. Each entry is
/// an owner-ID prefix on node paths: `0.5` names block 0.5 and every owner
/// below it (`0.5.1`, `0.5.1.0`, `0.5.1.0#cont1`), so a container's whole
/// body is one entry.
struct RowOwnerTable: Sendable {
    /// Container text: every owner at or below one of these blocks.
    var container: [String] = []
    /// Lists nested in a container: their rows are container rows whose
    /// owner kind is list, so they also count toward `tk2-list-live-rows`
    /// (the cross-check), never toward the list class. Each entry sits
    /// inside a `container` entry (TextKit2RowClassifierTests checks every
    /// registered table); the census reads it as container either way.
    var containerList: [String] = []
    /// Caption owners (`PreparedMedia.id`).
    var caption: [String] = []
    /// The fixture's top-level lists. nil: every row the table places
    /// nowhere else is a list row, which is right only for a table that
    /// names every container and caption owner of the fixture.
    var list: [String]?
    /// Prepared top-level text blocks whose owner is not of the `0.<n>`
    /// form: the children of a transparent sync block (`0.43.0`), which the
    /// preparer emits as top-level blocks (owner kind root, no context).
    /// Exact owners (and their `#` continuations), never prefixes.
    var root: [String] = []

    /// Whether `owner` is one of `prefixes` or below one of them.
    static func covers(_ prefixes: [String], _ owner: String) -> Bool {
        prefixes.contains { owner == $0 || owner.hasPrefix($0 + ".") || owner.hasPrefix($0 + "#") }
    }

    /// Whether `owner` is one of `table.root`'s owners.
    static func isRootExtra(_ owner: String, _ table: RowOwnerTable) -> Bool {
        table.root.contains { owner == $0 || owner.hasPrefix($0 + "#") }
    }

    /// The owner tables by fixture name (`RowOwnerTables.swift`, written
    /// from each fixture's structure). A fixture without one is
    /// container-free for the census: every row that is neither code nor
    /// root is a list row (the PR 2/PR 3 meaning). PR 4's fixtures and every
    /// inherited fixture that holds container or caption text have one, so
    /// a container row never counts as a list row once its family draws on
    /// TextKit 2; list-dense, code-dense and code-tall hold neither.
    static let byFixture: [String: RowOwnerTable] = [
        "containers-parity": containersParity,
        "containers-dense": containersDense,
        "containers-expand": containersExpand,
        "captions-parity": captionsParity,
        "kitchen-sink": kitchenSink,
        "lists-parity": listsParity,
        "code-parity": codeParity,
        "media-gallery": mediaGallery,
        "stress-1k": stress1k,
        "stress-5k": stress5k,
    ]
}

/// The live counters a census is checked against (About sheet;
/// `ReaderDriver.liveRowCounters`). nil: the field could not be read.
struct LiveRowCounters: Sendable, Equatable {
    var list: Int?        // tk2-list-live-rows
    var code: Int?        // tk2-code-live-rows
    var container: Int?   // tk2-container-live-rows (PR 4)
    var caption: Int?     // tk2-caption-live-rows (PR 4)
    var offWindow: Int?   // tk2-offwindow-rows (PR 4)
    var total: Int?       // tk2-live-rows: every live TextKit 2 row
}

/// One snapshot's TextKit 2 rows by class (PR 4 plan §6.5).
struct TextKit2RowCensus: Sendable {
    /// Owner → class, for every classified row.
    let classes: [String: TextKit2RowClass]
    /// Rows the fixture's owner table places in no class, sorted. Always
    /// empty without a table.
    let unclassified: [String]
    /// Container-class owners inside a nested list (`RowOwnerTable.containerList`).
    let containerListOwners: Set<String>
    /// The fixture whose owner table classified the rows; nil: no table
    /// (a container-free fixture, or no fixture known).
    let tableFixture: String?

    /// `rows`: each TextKit 2 row's owner and whether it sits inside a
    /// nested scroll view (an owner listed twice is code when either is).
    init(rows: [(owner: String, inNestedScroll: Bool)], fixture: String?, table: RowOwnerTable?) {
        var nested: [String: Bool] = [:]
        for row in rows {
            nested[row.owner] = (nested[row.owner] ?? false) || row.inNestedScroll
        }
        var classes: [String: TextKit2RowClass] = [:]
        var unclassified: [String] = []
        var containerList: Set<String> = []
        for (owner, inNestedScroll) in nested {
            guard let rowClass = Self.classify(owner: owner, inNestedScroll: inNestedScroll, table: table) else {
                unclassified.append(owner)
                continue
            }
            classes[owner] = rowClass
            if rowClass == .container, let table, RowOwnerTable.covers(table.containerList, owner) {
                containerList.insert(owner)
            }
        }
        self.classes = classes
        self.unclassified = unclassified.sorted()
        containerListOwners = containerList
        tableFixture = table == nil ? nil : fixture
    }

    /// The class of one row (nil: the owner table places it nowhere). In
    /// order: code (inside a nested scroll view, whatever the owner's
    /// form); root (a root-form owner `0.<n>`, or one of the table's
    /// `root` owners: a top-level block's own text is never container or
    /// caption text); caption and container by
    /// the table; list (the table's lists, or every remaining row when
    /// there is no table or the table leaves `list` nil).
    static func classify(owner: String, inNestedScroll: Bool, table: RowOwnerTable?) -> TextKit2RowClass? {
        if inNestedScroll { return .code }
        if isRootOwner(owner) { return .root }
        guard let table else { return .list }
        if RowOwnerTable.isRootExtra(owner, table) { return .root }
        if RowOwnerTable.covers(table.caption, owner) { return .caption }
        if RowOwnerTable.covers(table.container, owner) || RowOwnerTable.covers(table.containerList, owner) {
            return .container
        }
        guard let lists = table.list else { return .list }
        return RowOwnerTable.covers(lists, owner) ? .list : nil
    }

    /// A top-level block's id, `0.<n>`.
    static func isRootOwner(_ owner: String) -> Bool {
        let parts = owner.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2 && parts[0] == "0" && Int(parts[1]) != nil
    }

    func count(_ rowClass: TextKit2RowClass) -> Int {
        classes.values.filter { $0 == rowClass }.count
    }

    /// The owners of one class, sorted.
    func owners(_ rowClass: TextKit2RowClass) -> [String] {
        classes.filter { $0.value == rowClass }.map(\.key).sorted()
    }

    /// The §6.5 cross-check against the live counters, census-only (call
    /// C22): rows the lazy stack keeps in its window beyond the viewport
    /// are live and have a window but are not in the census (list-dense:
    /// live / off-window / census 81 / 0 / 76), so no class is ever
    /// required to equal its counter, whatever `tk2-offwindow-rows` reads.
    /// The counters overlap the classes: code <= tk2CodeLive, caption <=
    /// tk2CaptionLive, container <= tk2ContainerLive, list rows plus the
    /// container class's nested-list rows <= tk2ListLive. And the census's
    /// rows plus the off-window rows <= tk2Live: every census row has a
    /// window, so an off-window count above the live rows outside the
    /// census over-counts (it backs up the counter the OFF checks read).
    /// Returns the failures (empty: passed); a counter that could not be
    /// read, and an unclassified row, are failures.
    func crossCheck(_ counters: LiveRowCounters) -> [String] {
        var failures = unclassified.isEmpty ? [] : ["unclassified TextKit 2 rows (owner table: "
            + "\(tableFixture ?? "none")): \(unclassified.joined(separator: ","))"]
        if counters.total == nil { failures.append("tk2-live-rows unavailable") }
        if counters.offWindow == nil { failures.append("tk2-offwindow-rows unavailable") }
        let checks: [(String, Int, Int?)] = [
            ("code", count(.code), counters.code),
            ("caption", count(.caption), counters.caption),
            ("container", count(.container), counters.container),
            ("list (with nested-list container rows)", count(.list) + containerListOwners.count, counters.list),
        ]
        for (name, census, live) in checks {
            guard let live else {
                failures.append("\(name): live counter unavailable (census \(census))")
                continue
            }
            if census > live {
                failures.append("\(name): census \(census) > live \(live)")
            }
        }
        if let total = counters.total, let offWindow = counters.offWindow, rows + offWindow > total {
            failures.append("census \(rows) + off-window \(offWindow) > live \(total)")
        }
        return failures
    }

    /// Every row the census saw, classified or not.
    var rows: Int { classes.count + unclassified.count }

    /// The figures a check records for this census.
    var figures: [String: Any] {
        var figures: [String: Any] = Dictionary(uniqueKeysWithValues: TextKit2RowClass.allCases.map {
            ("\($0.rawValue)_rows", count($0))
        })
        figures["container_list_rows"] = containerListOwners.count
        figures["unclassified_rows"] = unclassified
        figures["owner_table"] = tableFixture ?? "none"
        return figures
    }
}
