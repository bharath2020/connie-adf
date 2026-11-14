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
        /// Live TextKit 2 rows drawing a code block's code (a subset of
        /// `liveTextKit2Rows`; PR 3).
        static let liveTextKit2CodeRows = "tk2-code-live-rows"
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

    /// One accessibility snapshot of the document scroll view: every
    /// labelled element (those fully inside the viewport are `visible`),
    /// and every TextKit 2 row (`tk2-row:<owner>`) anywhere in the snapshot.
    /// An element inside a scroll view nested in the document's own is
    /// marked (`inNestedScroll`): a code block's code sits in the block's
    /// horizontal scroll view under either renderer, which is how a
    /// TextKit 2 code row is told from a root paragraph's (their owners
    /// have the same form, `0.<n>`).
    func documentSnapshot() throws -> DocumentSnapshot {
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
        let codeRowOwners = Set(rows.filter {
            DocumentSnapshot.isRootOwner($0.owner) && ($0.nested || inside($0.frame))
        }.map { $0.owner })
        return DocumentSnapshot(
            all: all, viewport: viewport, textKit2Rows: textKit2Rows, textKit2Nodes: textKit2Nodes,
            codeRowOwners: codeRowOwners
        )
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
    static func relative(_ tops: [String: CGFloat], to anchor: String) -> [String: CGFloat]? {
        guard let origin = tops[anchor] else { return nil }
        return tops.mapValues { $0 - origin }
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
    /// Owners of the TextKit 2 rows that draw a top-level code block's
    /// code: root-form owners (`0.<n>`) whose row is inside a nested
    /// scroll view, the code block's horizontal viewport (PR 3).
    let codeRowOwners: Set<String>

    init(all: [Node], viewport: CGRect, textKit2Rows: [String: String], textKit2Nodes: Int,
         codeRowOwners: Set<String>)
    {
        self.all = all
        self.viewport = viewport
        visible = all.filter { $0.frame.minY >= viewport.minY && $0.frame.maxY <= viewport.maxY }
        self.textKit2Rows = textKit2Rows
        self.textKit2Nodes = textKit2Nodes
        self.codeRowOwners = codeRowOwners
    }

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

    /// TextKit 2 rows that draw a top-level code block's code (PR 3). Their
    /// owner is the block's id, which has the root form `0.<n>`.
    var codeOwnedRows: Int { codeRowOwners.count }
    /// TextKit 2 rows owned by a root text block (`0.<n>`: a top-level
    /// paragraph or heading, the PR 1 scope). A code row's owner has the
    /// same form, so code rows are taken out: on a document with top-level
    /// code (kitchen-sink, the stress fixtures) this still counts root text
    /// only, and on one without it nothing changes.
    var rootOwnedRows: Int { textKit2Rows.keys.filter(Self.isRootOwner).count - codeOwnedRows }
    /// TextKit 2 rows owned below a root (list leaders, `PreparedListRow.id`,
    /// and list trailing text, its block's node path).
    var listOwnedRows: Int { textKit2Rows.count - rootOwnedRows - codeOwnedRows }

    static func isRootOwner(_ owner: String) -> Bool {
        let parts = owner.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2 && parts[0] == "0" && Int(parts[1]) != nil
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
