import XCTest

/// "Identify Renderer" (`ADFDocumentView(identifiesRenderer:)`) and the
/// toolbar badge that shows the renderer's own report (kitchen-sink, light
/// appearance).
///
/// - With identification on, each text block marks itself with the engine
///   that drew it: its accessibility value names the engine and its fill
///   is the engine's colour. Under TextKit 2 a heading's TextKit 2 row is
///   "TextKit 2" and green, the linked paragraph's row "TextKit 1" and
///   blue, and the blockquote's text, which the TextKit 2 renderer leaves
///   on SwiftUI, "SwiftUI" and orange.
/// - The badge reads the report, not the menu's setting: its label is the
///   engine that drew the text on screen, its value the counts (SwiftUI
///   blocks beside TextKit 2 rows under TextKit 2), its pixels that
///   engine's colour; it follows a live renderer switch.
/// - Turning identification off in the menu clears every mark and the
///   badge goes back to the setting's name as plain text.
///
/// Fills are read from screenshot pixels: the most common colour inside an
/// element's frame is the fill behind its text.
@MainActor
final class RendererBadgeUITests: XCTestCase {
    private enum KitchenSink {
        static let title = "ADF Kitchen Sink"
        /// Plain text: a TextKit 2 row under TextKit 2.
        static let heading = "Heading two"
        /// The first paragraph holds a link: a TextKit 1-backed row.
        static let linkedPrefix = "bold italic"
        /// A blockquote's paragraph: SwiftUI under either renderer.
        static let quote = "A wise quotation."
    }

    private enum Identifier {
        static let identifyToggle = "renderer-identify"
    }

    /// A fill's dominant colour, classified.
    private enum Shade: Equatable {
        case orange, green, blue, neutral, other
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testBadgeShowsTheRenderersReport() throws {
        let reader = ReaderDriver(launching: ["-fixture", "kitchen-sink", "-rendererReset", "-identifyRenderer"])
        XCTAssertTrue(reader.element(labelled: KitchenSink.title).waitForExistence(timeout: 15), "kitchen-sink missing")
        reader.waitForRenderer("SwiftUI")
        let swiftUI = assertBadge(reader, shows: "SwiftUI", shade: .orange)
        XCTAssertTrue(swiftUI.hasPrefix("SwiftUI ") && !swiftUI.contains("TextKit"), "SwiftUI drew something else: \(swiftUI)")
        attach(reader.app, "badge-swiftui")

        reader.chooseRenderer(textKit2: true)
        let textKit2 = assertBadge(reader, shows: "TextKit 2", shade: .green)
        XCTAssertTrue(textKit2.contains("TextKit 2 "), "no TextKit 2 row reported: \(textKit2)")
        XCTAssertGreaterThan(count(of: "SwiftUI", in: textKit2), 0, "no SwiftUI fallback reported on the first screen: \(textKit2)")
        attach(reader.app, "badge-textkit2")

        reader.chooseRenderer(textKit2: false)
        let back = assertBadge(reader, shows: "SwiftUI", shade: .orange)
        XCTAssertFalse(back.contains("TextKit"), "TextKit rows still reported on SwiftUI: \(back)")
    }

    func testIdentifyRendererMarksTheEngineThatDrew() throws {
        continueAfterFailure = true
        // `-engineTint` is the switch's old name: the alias must still work.
        let reader = ReaderDriver(launching: ["-fixture", "kitchen-sink", "-rendererReset", "-textkit2", "-engineTint"])
        reader.waitForRenderer("TextKit 2")
        let heading = reader.textKit2Row(labelled: KitchenSink.heading)
        XCTAssertTrue(heading.waitForExistence(timeout: 15), "\(KitchenSink.heading) is not a TextKit 2 row")
        reader.pause(1)
        XCTAssertEqual(heading.value as? String, "TextKit 2")
        XCTAssertEqual(shade(of: heading, reader), .green, "the TextKit 2 row is not marked green")
        let linked = reader.textKit2Row(labelPrefix: KitchenSink.linkedPrefix)
        XCTAssertTrue(linked.exists, "the linked paragraph is not a TextKit row")
        XCTAssertEqual(linked.value as? String, "TextKit 1")
        XCTAssertEqual(shade(of: linked, reader), .blue, "the TextKit 1-backed row is not marked blue")
        attach(reader.app, "identify-on-top")

        let quote = reader.element(labelled: KitchenSink.quote)
        revealFully(quote, reader)
        XCTAssertFalse(quote.identifier.hasPrefix(ReaderDriver.Identifier.textKit2RowPrefix), "the quote is a TextKit row")
        XCTAssertEqual(quote.value as? String, "SwiftUI", "the fallback quote does not report SwiftUI")
        XCTAssertEqual(shade(of: quote, reader), .orange, "the SwiftUI-drawn quote is not marked orange")
        reader.pause(0.6)
        let report = badgeValue(reader)
        XCTAssertGreaterThan(count(of: "SwiftUI", in: report), 0, "the badge does not report the SwiftUI quote: \(report)")
        attach(reader.app, "identify-on-quote")

        // Off from the menu: the same text, unmarked; the badge is the
        // setting's name again, with no report.
        reader.openRendererMenu()
        let toggle = reader.app.descendants(matching: .any)[Identifier.identifyToggle]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Identify Renderer missing from the menu")
        toggle.tap()
        reader.pause(1)
        XCTAssertEqual((quote.value as? String) ?? "", "", "the quote kept its mark")
        XCTAssertEqual(shade(of: quote, reader), .neutral, "the quote kept a fill")
        let row = reader.anyTextKit2Row
        if reader.isVisible(row) {
            XCTAssertEqual((row.value as? String) ?? "", "", "a TextKit 2 row kept its mark: \(row.label)")
            XCTAssertEqual(shade(of: row, reader), .neutral, "a TextKit 2 row kept a fill: \(row.label)")
        }
        reader.waitForRenderer("TextKit 2")
        XCTAssertEqual(badgeValue(reader), "", "the badge kept a report with identification off")
        attach(reader.app, "identify-off-quote")
    }

    // MARK: - Helpers

    private var badgePredicate: NSPredicate {
        NSPredicate(format: "identifier == %@ OR identifier == %@",
                    ReaderDriver.Identifier.rendererActive, ReaderDriver.Identifier.rendererMenu)
    }

    /// The badge's accessibility value: the report's counts, or "" without
    /// a report.
    private func badgeValue(_ reader: ReaderDriver) -> String {
        // The toolbar can expose the plain label twice; any one will do.
        for identifier in [ReaderDriver.Identifier.rendererActive, ReaderDriver.Identifier.rendererMenu] {
            let element = reader.app.descendants(matching: .any).matching(identifier: identifier).firstMatch
            if element.exists, let value = element.value as? String, !value.isEmpty { return value }
        }
        return ""
    }

    /// "SwiftUI 4" in "TextKit 2 9, SwiftUI 4" → 4.
    private func count(of engine: String, in summary: String) -> Int {
        for part in summary.components(separatedBy: ", ") where part.hasPrefix(engine + " ") {
            return Int(part.dropFirst(engine.count + 1)) ?? 0
        }
        return 0
    }

    /// Waits for the badge to name `name` from a report, checks its pixels,
    /// and returns its value.
    @discardableResult
    private func assertBadge(_ reader: ReaderDriver, shows name: String, shade expected: Shade,
                             file: StaticString = #filePath, line: UInt = #line) -> String
    {
        reader.waitForRenderer(name)
        var value = ""
        let deadline = Date().addingTimeInterval(5)
        repeat {
            value = badgeValue(reader)
            if value.contains(name + " ") { break }
            reader.pause(0.25)
        } while Date() < deadline
        XCTAssertTrue(value.contains(name + " "), "the badge reports no \(name): '\(value)'", file: file, line: line)
        let active = reader.app.descendants(matching: .any).matching(identifier: ReaderDriver.Identifier.rendererActive).firstMatch
        let target = active.exists ? active : reader.app.descendants(matching: .any).matching(badgePredicate).firstMatch
        XCTAssertEqual(shade(of: target, reader, inset: 1, strong: true), expected,
                       "the badge's pixels are not \(expected)", file: file, line: line)
        return value
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
    /// full-strength colour (the badge) rather than a light fill.
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
        } else if b > g + margin, b > r + margin {
            result = .blue
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
