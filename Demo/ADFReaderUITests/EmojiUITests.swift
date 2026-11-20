import CoreGraphics
import Vision
import XCTest

/// Custom emoji end to end on `-fixture emoji-custom`, under both
/// renderers (ADR §23).
///
/// `testBoxThenImage…` (`-emoji mock -emojiDelay 10000`): the mock fetch
/// (`MockEmojiFetch`) draws each emoji as a saturated coloured square and
/// throws for a short name containing `fail`.
/// 1. **Loading: a blank box.** While the lookups run (the probe shows
///    calls in flight and none ended, read after the captures), the
///    `EM-LOAD` paragraph shows no short-name text (text recognition finds
///    "Before" and "after" but not "custom") and no coloured pixel; so
///    does `EM-FAIL`.
/// 2. **Loaded: the image, nothing moved.** Once the probe shows every
///    lookup ended (4 resolved, 1 failed, 5 calls), `EM-LOAD` holds the
///    coloured square, and its frame, the next paragraph's (`EM-BELOW`)
///    and the recognised position of the word after the emoji are where
///    they were while loading.
/// 3. **Failed: the short name.** `EM-FAIL` shows `:fail-emoji:` as text,
///    with no doubled colons and no coloured pixel.
/// VoiceOver reads each emoji by its spoken name at every stage
/// ("ld custom 6"). Under TextKit 2 the paragraphs are `tk2-row:`
/// elements (custom emoji keep a paragraph on TextKit 2).
///
/// `testNoResolverShowsShortNames…` (`-emoji off`): no lookup is made and
/// both emoji show their short names as text, with no doubled colons.
///
/// Run (simulator `adf-res3-emoji`):
///
///     xcodebuild test -project Demo/ADFReader.xcodeproj -scheme ADFReader \
///       -destination 'platform=iOS Simulator,name=adf-res3-emoji' \
///       -only-testing:ADFReaderUITests/EmojiUITests
@MainActor
final class EmojiUITests: XCTestCase {
    /// Each mock fetch's duration: long enough to capture the loading
    /// stage after the paragraph appears, even on a loaded host (4 s was
    /// not: element queries and captures took longer at load 25).
    static let delayMilliseconds = 10_000
    /// Fewer saturated pixels than this: no image (antialiased black and
    /// grey text has none). A 60 px mock square drawn in the emoji box at
    /// scale 3 has thousands.
    static let noImagePixels = 30
    static let imagePixels = 400

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Box, then image; failure ends as the short name

    func testBoxThenImageSwiftUI() throws {
        try boxThenImage(textKit2: false)
    }

    func testBoxThenImageTextKit2() throws {
        try boxThenImage(textKit2: true)
    }

    private func boxThenImage(textKit2: Bool) throws {
        let arm = textKit2 ? "textkit2" : "swiftui"
        note("\(arm) host load \(Self.hostLoad())")
        var arguments = ["-fixture", "emoji-custom", "-rendererReset", "-smartLinkProbe",
                         "-emoji", "mock", "-emojiDelay", String(Self.delayMilliseconds)]
        if textKit2 { arguments.append("-textkit2") }
        let reader = ReaderDriver(launching: arguments)
        reader.waitForRenderer(textKit2 ? "TextKit 2" : "SwiftUI")
        let load = leaf("EM-LOAD", reader, textKit2: textKit2)
        let below = leaf("EM-BELOW", reader, textKit2: textKit2)
        let fail = leaf("EM-FAIL", reader, textKit2: textKit2)
        XCTAssertTrue(load.waitForExistence(timeout: 20), "the EM-LOAD paragraph never appeared")
        XCTAssertTrue(below.exists && fail.exists, "EM-BELOW or EM-FAIL is missing")

        // 1. Loading.
        let loadingFrames = (load.frame, below.frame)
        let loadingShot = try capture(load)
        let failLoadingShot = try capture(fail)
        let during = probe(reader)
        note("\(arm) loading probe: \(during)")
        attach(reader.app, "\(arm)-loading")
        XCTAssertGreaterThan(during["emCalls"], 0, "no lookup started: \(during)")
        XCTAssertEqual(during["emResolved"] + during["emFailed"], 0,
                       "a lookup ended before the loading captures were checked (host too slow?): \(during)")
        let loadingText = Self.recognize(loadingShot)
        note("\(arm) loading EM-LOAD text \(loadingText.map(\.text)), saturated \(Self.saturatedPixels(loadingShot))")
        XCTAssertTrue(Self.joined(loadingText).contains("Before"), "text recognition failed: \(loadingText)")
        XCTAssertFalse(Self.joined(loadingText).lowercased().contains("custom"),
                       "the short name shows while loading: \(loadingText)")
        XCTAssertLessThan(Self.saturatedPixels(loadingShot), Self.noImagePixels, "an image shows while loading")
        let failLoadingText = Self.joined(Self.recognize(failLoadingShot))
        XCTAssertFalse(failLoadingText.lowercased().contains("emoji"),
                       "the failing emoji's short name shows while loading: \(failLoadingText)")
        let afterWhileLoading = Self.wordBox("after", in: loadingText)
        XCTAssertNotNil(afterWhileLoading, "\"after\" not recognised while loading: \(loadingText)")
        XCTAssertTrue(load.label.contains("ld custom 6"), "spoken name missing while loading: \(load.label)")

        // 2. Loaded.
        let ended = waitForProbe(reader, timeout: Double(Self.delayMilliseconds) / 1_000 * 3 + 20) {
            $0["emResolved"] == 4 && $0["emFailed"] == 1 && $0["emInFlight"] == 0
        }
        note("\(arm) loaded probe: \(ended.stats)")
        XCTAssertTrue(ended.met, "the lookups never all ended (4 resolved, 1 failed): \(ended.stats)")
        XCTAssertEqual(ended.stats["emCalls"], 5, "one lookup per key: \(ended.stats)")
        reader.pause(0.5)
        attach(reader.app, "\(arm)-loaded")
        let loadedShot = try capture(load)
        let loadedText = Self.recognize(loadedShot)
        let saturated = Self.saturatedPixels(loadedShot)
        note("\(arm) loaded EM-LOAD text \(loadedText.map(\.text)), saturated \(saturated)")
        XCTAssertGreaterThan(saturated, Self.imagePixels, "the emoji image is not drawn")
        XCTAssertFalse(Self.joined(loadedText).lowercased().contains("custom"), "the short name shows: \(loadedText)")
        assertSameFrame(load.frame, loadingFrames.0, "EM-LOAD moved or resized when its emoji landed")
        assertSameFrame(below.frame, loadingFrames.1, "the paragraph below moved when the emoji landed")
        if let before = afterWhileLoading, let after = Self.wordBox("after", in: loadedText) {
            note("\(arm) word after the emoji: loading x \(before.minX), loaded x \(after.minX)")
            XCTAssertEqual(after.minX, before.minX, accuracy: 6, "the text after the emoji moved (pixels)")
        } else {
            XCTFail("\"after\" not recognised once loaded: \(loadedText)")
        }
        XCTAssertTrue(load.label.contains("ld custom 6"), "spoken name missing once loaded: \(load.label)")

        // 3. Failed.
        let failShot = try capture(fail)
        let failText = Self.joined(Self.recognize(failShot))
        note("\(arm) failed EM-FAIL text \"\(failText)\", saturated \(Self.saturatedPixels(failShot))")
        XCTAssertTrue(failText.contains(":fail-emoji:"), "the failed emoji does not show its short name: \(failText)")
        XCTAssertFalse(failText.contains("::"), "doubled colons: \(failText)")
        XCTAssertLessThan(Self.saturatedPixels(failShot), Self.noImagePixels, "the failed emoji draws an image")
        if textKit2 {
            XCTAssertTrue(reader.textKit2Row(labelPrefix: "EM-PAIR").exists, "EM-PAIR is not a TextKit 2 row")
        } else {
            XCTAssertFalse(reader.anyTextKit2Row.exists, "a TextKit 2 row exists on the SwiftUI renderer")
        }
    }

    // MARK: - No resolver

    func testNoResolverShowsShortNamesSwiftUI() throws {
        try noResolverShowsShortNames(textKit2: false)
    }

    func testNoResolverShowsShortNamesTextKit2() throws {
        try noResolverShowsShortNames(textKit2: true)
    }

    private func noResolverShowsShortNames(textKit2: Bool) throws {
        let arm = textKit2 ? "textkit2" : "swiftui"
        note("\(arm) host load \(Self.hostLoad())")
        var arguments = ["-fixture", "emoji-custom", "-rendererReset", "-smartLinkProbe", "-emoji", "off"]
        if textKit2 { arguments.append("-textkit2") }
        let reader = ReaderDriver(launching: arguments)
        reader.waitForRenderer(textKit2 ? "TextKit 2" : "SwiftUI")
        let load = leaf("EM-LOAD", reader, textKit2: textKit2)
        let fail = leaf("EM-FAIL", reader, textKit2: textKit2)
        XCTAssertTrue(load.waitForExistence(timeout: 20), "the EM-LOAD paragraph never appeared")
        // Longer than a dwell plus a default mock fetch: any lookup would
        // have started by now.
        reader.pause(2)
        let stats = probe(reader)
        note("\(arm) no resolver probe: \(stats)")
        XCTAssertEqual(stats["emCalls"], 0, "a lookup ran with no resolver: \(stats)")
        attach(reader.app, "\(arm)-no-resolver")
        // Text recognition reads the "l" of "ld" as "I"; the rest is exact.
        for (element, name) in [(load, "d-custom-6:"), (fail, ":fail-emoji:")] {
            let shot = try capture(element)
            let text = Self.joined(Self.recognize(shot))
            note("\(arm) no resolver text \"\(text)\", saturated \(Self.saturatedPixels(shot))")
            XCTAssertTrue(text.contains(name), "\(name) is not shown as text: \(text)")
            XCTAssertFalse(text.contains("::"), "doubled colons: \(text)")
            XCTAssertLessThan(Self.saturatedPixels(shot), Self.noImagePixels, "an image shows with no resolver")
        }
        XCTAssertTrue(load.label.contains("ld custom 6"), "spoken name missing: \(load.label)")
    }

    // MARK: - Helpers

    private func leaf(_ prefix: String, _ reader: ReaderDriver, textKit2: Bool) -> XCUIElement {
        textKit2 ? reader.textKit2Row(labelPrefix: prefix) : reader.element(labelPrefix: prefix)
    }

    private func capture(_ element: XCUIElement) throws -> CGImage {
        try XCTUnwrap(element.screenshot().image.cgImage, "no screenshot of \(element)")
    }

    private func assertSameFrame(_ frame: CGRect, _ reference: CGRect, _ message: String) {
        let delta = max(abs(frame.minX - reference.minX), abs(frame.minY - reference.minY),
                        abs(frame.width - reference.width), abs(frame.height - reference.height))
        XCTAssertLessThanOrEqual(delta, 0.5, "\(message): \(reference) -> \(frame)")
    }

    /// The probe's `key=value` counters (`-smartLinkProbe`, `em…` keys);
    /// -1 for a missing key.
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
            values.filter { $0.key.hasPrefix("em") }.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        }
    }

    private func probe(_ reader: ReaderDriver) -> Stats {
        let element = reader.app.staticTexts["smartlink-probe"]
        XCTAssertTrue(element.waitForExistence(timeout: 5), "smartlink-probe missing (-smartLinkProbe)")
        return Stats(probe: element.label)
    }

    private func waitForProbe(_ reader: ReaderDriver, timeout: TimeInterval,
                              until condition: (Stats) -> Bool) -> (met: Bool, stats: Stats) {
        let deadline = Date().addingTimeInterval(timeout)
        var stats = probe(reader)
        while !condition(stats), Date() < deadline {
            reader.pause(0.25)
            stats = probe(reader)
        }
        return (condition(stats), stats)
    }

    /// Recognised lines of text with their boxes, in image pixels (origin
    /// top left).
    struct Line {
        let text: String
        let candidate: VNRecognizedText
        let imageSize: CGSize
    }

    static func recognize(_ image: CGImage) -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        let size = CGSize(width: image.width, height: image.height)
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { Line(text: $0.string, candidate: $0, imageSize: size) }
        }
    }

    static func joined(_ lines: [Line]) -> String {
        lines.map(\.text).joined(separator: " ")
    }

    /// The pixel box of the first occurrence of `word` among `lines`.
    static func wordBox(_ word: String, in lines: [Line]) -> CGRect? {
        for line in lines {
            guard let range = line.text.range(of: word),
                  let box = try? line.candidate.boundingBox(for: range)?.boundingBox else { continue }
            return CGRect(x: box.minX * line.imageSize.width,
                          y: (1 - box.maxY) * line.imageSize.height,
                          width: box.width * line.imageSize.width,
                          height: box.height * line.imageSize.height)
        }
        return nil
    }

    /// Pixels whose colour is clearly not grey: the mock emoji's square
    /// (saturation 0.6, brightness 0.8). Black, grey and white text and
    /// background have none.
    static func saturatedPixels(_ image: CGImage) -> Int {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return -1 }
        var count = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = Int(pixels[index]), green = Int(pixels[index + 1]), blue = Int(pixels[index + 2])
            let high = max(red, green, blue), low = min(red, green, blue)
            if high > 80, high - low > 70 { count += 1 }
        }
        return count
    }

    /// The load averages (the simulator shares the host's kernel), logged
    /// with each run: under heavy host load XCUI queries slow down.
    static func hostLoad() -> String {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return "n/a" }
        return loads.map { String(format: "%.1f", $0) }.joined(separator: " ")
    }

    private func note(_ text: String) {
        print("EMOJI_UI \(text)")
        XCTContext.runActivity(named: text) { _ in }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
