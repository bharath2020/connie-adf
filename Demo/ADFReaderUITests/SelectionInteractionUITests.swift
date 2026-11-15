import XCTest

@MainActor
final class SelectionInteractionUITests: XCTestCase {
    private let codeText = """
    let greeting = "Hello, ADF!"
    print(greeting)
    """

    private func launchKitchenSink() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-fixture", "kitchen-sink", "-textkit2", "-selectionUITestProbe",
        ]
        app.launch()
        XCTAssertTrue(app.staticTexts[codeText].waitForExistence(timeout: 5))
        return app
    }

    private func selectedRange(in app: XCUIApplication) -> Range<Int>? {
        let probe = app.descendants(matching: .any)
            .matching(identifier: "adf-selection-range")
            .firstMatch
        guard probe.waitForExistence(timeout: 2),
              let value = probe.value as? String,
              value != "none"
        else {
            return nil
        }
        let bounds = value.components(separatedBy: "..<")
        guard bounds.count == 2,
              let lower = Int(bounds[0]),
              let upper = Int(bounds[1])
        else {
            XCTFail("Malformed selection probe value: \(value)")
            return nil
        }
        return lower..<upper
    }

    private func coordinate(
        in app: XCUIApplication,
        frame: CGRect,
        x: CGFloat,
        y: CGFloat
    ) -> XCUICoordinate {
        let point = CGPoint(
            x: frame.minX + frame.width * x,
            y: frame.minY + frame.height * y
        )
        return app.coordinate(withNormalizedOffset: CGVector(
            dx: point.x / app.frame.width,
            dy: point.y / app.frame.height
        ))
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testInitialLongPressCanContinueDirectlyIntoADrag() {
        let app = launchKitchenSink()
        let code = app.staticTexts[codeText]
        let info = app.staticTexts["Info panel"]
        XCTAssertTrue(info.waitForExistence(timeout: 2))
        let codeFrame = code.frame
        let infoFrame = info.frame

        // The second-line point lands inside "greeting". Keep the initiating
        // touch down after word selection and drag it into the following panel.
        let word = coordinate(in: app, frame: codeFrame, x: 0.45, y: 0.75)
        let target = coordinate(in: app, frame: infoFrame, x: 0.35, y: 0.5)
        word.press(forDuration: 0.8, thenDragTo: target)

        let range = selectedRange(in: app)
        XCTAssertNotNil(range)
        XCTAssertGreaterThan(range?.count ?? 0, "greeting".utf16.count)
        attachScreenshot(app, name: "Long press continued into drag")
    }

    func testEndHandleCanBeDraggedWhileTheEditMenuIsVisible() {
        let app = launchKitchenSink()
        let code = app.staticTexts[codeText]
        let info = app.staticTexts["Info panel"]
        XCTAssertTrue(info.waitForExistence(timeout: 2))
        let codeFrame = code.frame
        let infoFrame = info.frame

        let word = coordinate(in: app, frame: codeFrame, x: 0.45, y: 0.75)
        word.press(forDuration: 0.8)
        let initialRange = selectedRange(in: app)
        XCTAssertEqual(initialRange?.count, "greeting".utf16.count)

        // "print(greeting)" occupies roughly the first half of the row. Its
        // selected word's end handle is at the second line's trailing edge;
        // the component-relative coordinate remains stable across devices.
        let endHandle = coordinate(in: app, frame: codeFrame, x: 0.5, y: 1.0)
        let target = coordinate(in: app, frame: infoFrame, x: 0.35, y: 0.5)
        endHandle.press(forDuration: 0.1, thenDragTo: target)

        let movedRange = selectedRange(in: app)
        XCTAssertNotEqual(movedRange, initialRange)
        XCTAssertGreaterThan(movedRange?.count ?? 0, initialRange?.count ?? 0)
        attachScreenshot(app, name: "End handle dragged with menu visible")
    }
}
