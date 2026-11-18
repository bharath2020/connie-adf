import XCTest

/// The renderer badge and "Tint Text by Engine" (kitchen-sink, light
/// appearance).
///
/// - The toolbar badge names the active renderer on its colour: orange
///   SwiftUI, green TextKit 2. The name is the label of `renderer-active`
///   (and `renderer-menu`), the colour's name its accessibility value, and
///   the badge's pixels are that colour; both follow a live switch.
/// - `-engineTint` fills each text leaf with the colour of the engine that
///   drew it: under TextKit 2 a heading's TextKit 2 row (`tk2-row:`) is
///   green and the blockquote's text, which stays on SwiftUI, is orange.
///   Turning the switch off in the menu leaves both untinted. Read from
///   screenshot pixels: the most common colour inside each element's frame
///   is the fill behind its text.
@MainActor
final class RendererBadgeUITests: XCTestCase {
    private enum KitchenSink {
        static let title = "ADF Kitchen Sink"
        /// Plain text: a TextKit 2 row under TextKit 2.
        static let heading = "Heading two"
        /// A blockquote's paragraph: SwiftUI under either renderer.
        static let quote = "A wise quotation."
    }

    private enum Identifier {
        static let engineTintToggle = "engine-tint-toggle"
    }

    /// A fill's dominant colour, classified.
    private enum Shade: Equatable {
        case orange, green, neutral, other
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testBadgeFollowsTheRenderer() throws {
        let reader = ReaderDriver(launching: ["-fixture", "kitchen-sink", "-rendererReset"])
        reader.waitForRenderer("SwiftUI")
        XCTAssertTrue(reader.element(labelled: KitchenSink.title).waitForExistence(timeout: 15), "kitchen-sink missing")
        assertBadge(reader, name: "SwiftUI", colour: "orange", shade: .orange)
        attach(reader.app, "badge-swiftui")

        reader.chooseRenderer(textKit2: true)
        assertBadge(reader, name: "TextKit 2", colour: "green", shade: .green)
        attach(reader.app, "badge-textkit2")

        reader.chooseRenderer(textKit2: false)
        assertBadge(reader, name: "SwiftUI", colour: "orange", shade: .orange)
    }

    func testEngineTintMarksTheEngineThatDrew() throws {
        continueAfterFailure = true
        let reader = ReaderDriver(launching: ["-fixture", "kitchen-sink", "-rendererReset", "-textkit2", "-engineTint"])
        reader.waitForRenderer("TextKit 2")
        let heading = reader.textKit2Row(labelled: KitchenSink.heading)
        XCTAssertTrue(heading.waitForExistence(timeout: 15), "\(KitchenSink.heading) is not a TextKit 2 row")
        reader.pause(1)
        XCTAssertEqual(shade(of: heading, reader), .green, "the TextKit 2 row is not tinted green")
        attach(reader.app, "tint-on-top")

        let quote = reader.element(labelled: KitchenSink.quote)
        revealFully(quote, reader)
        XCTAssertFalse(quote.identifier.hasPrefix(ReaderDriver.Identifier.textKit2RowPrefix), "the quote is a TextKit 2 row")
        XCTAssertEqual(shade(of: quote, reader), .orange, "the SwiftUI-drawn quote is not tinted orange")
        let row = reader.anyTextKit2Row
        if reader.isVisible(row) {
            XCTAssertEqual(shade(of: row, reader), .green, "a TextKit 2 row beside the quote is not green: \(row.label)")
        }
        attach(reader.app, "tint-on-quote")

        // Off from the menu: the same text, untinted.
        reader.openRendererMenu()
        let toggle = reader.app.descendants(matching: .any)[Identifier.engineTintToggle]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Tint Text by Engine missing from the menu")
        toggle.tap()
        reader.pause(1)
        XCTAssertEqual(shade(of: quote, reader), .neutral, "the quote kept a tint with the switch off")
        if reader.isVisible(row) {
            XCTAssertEqual(shade(of: row, reader), .neutral, "a TextKit 2 row kept a tint with the switch off")
        }
        attach(reader.app, "tint-off-quote")
    }

    // MARK: - Helpers

    private func assertBadge(_ reader: ReaderDriver, name: String, colour: String, shade expected: Shade,
                             file: StaticString = #filePath, line: UInt = #line)
    {
        reader.waitForRenderer(name)
        let predicate = NSPredicate(
            format: "(identifier == %@ OR identifier == %@) AND label CONTAINS %@ AND value == %@",
            ReaderDriver.Identifier.rendererMenu, ReaderDriver.Identifier.rendererActive, name, colour
        )
        let badge = reader.app.descendants(matching: .any).matching(predicate).firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 5), "the badge does not read \(name), \(colour)",
                      file: file, line: line)
        let active = reader.app.descendants(matching: .any)[ReaderDriver.Identifier.rendererActive]
        let target = active.exists ? active : badge
        XCTAssertEqual(shade(of: target, reader, inset: 1, strong: true), expected,
                       "the badge's pixels are not \(colour)", file: file, line: line)
    }

    /// Drags the document up in small steps until `element` is wholly in
    /// the viewport.
    private func revealFully(_ element: XCUIElement, _ reader: ReaderDriver) {
        var drags = 0
        while !reader.isVisible(element), drags < 10 {
            reader.drag(by: 150)
            reader.pause(0.5)
            drags += 1
        }
        XCTAssertTrue(reader.isVisible(element), "\(element) never came into view")
        reader.pause(1)
    }

    /// The most common colour inside `element`'s frame (inset by `inset`
    /// points), from one screenshot, classified. A text leaf's glyph pixels
    /// are a minority, so it is the fill behind the text. `strong` judges a
    /// full-strength colour (the badge) rather than a light tint.
    private func shade(of element: XCUIElement, _ reader: ReaderDriver, inset: CGFloat = 2,
                       strong: Bool = false) -> Shade
    {
        guard element.exists, let image = XCUIScreen.main.screenshot().image.cgImage else { return .other }
        let scale = CGFloat(image.width) / reader.app.windows.firstMatch.frame.width
        let frame = element.frame.insetBy(dx: inset, dy: inset)
        let pixels = CGRect(x: frame.minX * scale, y: frame.minY * scale,
                            width: frame.width * scale, height: frame.height * scale).integral
        guard let (r, g, b) = dominantColour(in: pixels, of: image) else { return .other }
        let result: Shade
        let margin = strong ? 60 : 8
        if r > g + margin, g >= b {
            result = .orange
        } else if g > r + margin, g > b + (strong ? 20 : 4) {
            result = .green
        } else if abs(r - g) < 8, abs(g - b) < 8 {
            result = .neutral
        } else {
            result = .other
        }
        XCTContext.runActivity(named: "\(element.identifier) '\(element.label)': rgb(\(r), \(g), \(b)) → \(result)") { _ in }
        return result
    }

    private func dominantColour(in rect: CGRect, of image: CGImage) -> (Int, Int, Int)? {
        let bounds = rect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard bounds.width >= 1, bounds.height >= 1, let cropped = image.cropping(to: bounds) else { return nil }
        let width = cropped.width, height = cropped.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        // Buckets of 4 levels per channel.
        var counts: [Int: Int] = [:]
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let key = Int(bytes[index] >> 2) << 16 | Int(bytes[index + 1] >> 2) << 8 | Int(bytes[index + 2] >> 2)
            counts[key, default: 0] += 1
        }
        guard let key = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        return ((key >> 16 & 0xFF) << 2, (key >> 8 & 0xFF) << 2, (key & 0xFF) << 2)
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
