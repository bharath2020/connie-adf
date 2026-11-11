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
        static let rebuildControlRows = "rebuild-control-rows"
        static let loadSwitchBlocks = "load-switch-blocks"
        static let loadReadyBlocks = "load-ready-blocks"
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

    /// One accessibility snapshot of the document scroll view: the labelled
    /// elements fully inside the viewport, and every TextKit 2 row
    /// (`tk2-row:<owner>`) anywhere in the snapshot.
    func documentSnapshot() throws -> DocumentSnapshot {
        let root = try app.scrollViews.firstMatch.snapshot()
        let viewport = viewport
        var visible: [DocumentSnapshot.Node] = []
        var textKit2Rows: [String: String] = [:]
        var textKit2Nodes = 0
        func walk(_ node: XCUIElementSnapshot) {
            let frame = node.frame
            let owner = node.identifier.hasPrefix(Identifier.textKit2RowPrefix)
                ? String(node.identifier.dropFirst(Identifier.textKit2RowPrefix.count)) : nil
            if let owner {
                textKit2Rows[owner] = node.label
                textKit2Nodes += 1
            }
            // Scroll indicators carry a page-count label that tracks the
            // estimated content height, not a row.
            let isIndicator = node.label.hasPrefix("Vertical scroll bar") || node.label.hasPrefix("Horizontal scroll bar")
            if !node.label.isEmpty, !isIndicator, frame.height > 0,
               frame.minY >= viewport.minY, frame.maxY <= viewport.maxY {
                visible.append(DocumentSnapshot.Node(label: node.label, frame: frame, owner: owner))
            }
            for child in node.children {
                walk(child)
            }
        }
        walk(root)
        return DocumentSnapshot(visible: visible, textKit2Rows: textKit2Rows, textKit2Nodes: textKit2Nodes)
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
    }

    /// Labelled elements fully inside the viewport, in snapshot order.
    let visible: [Node]
    /// Owner → label of every TextKit 2 row in the snapshot, in or out of
    /// the viewport.
    let textKit2Rows: [String: String]
    /// TextKit 2 row elements in the snapshot, counted without merging
    /// owners (equals `textKit2Rows.count` unless an owner appears twice).
    let textKit2Nodes: Int

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

    /// TextKit 2 rows owned by a root block (`0.<n>`: a top-level paragraph
    /// or heading, the PR 1 scope).
    var rootOwnedRows: Int { textKit2Rows.keys.filter(Self.isRootOwner).count }
    /// TextKit 2 rows owned below a root (list leaders, `PreparedListRow.id`,
    /// and list trailing text, its block's node path).
    var listOwnedRows: Int { textKit2Rows.count - rootOwnedRows }

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
