import CoreGraphics
import CoreText
import Foundation
import ImageIO
import ADFRendering

/// The demo's custom-emoji launch flags (`EmojiResolvers` applies them):
///
/// - `-emoji off|mock`: `mock` gives readers a `CacheFirstEmojiResolver`
///   over `MockEmojiFetch`, so custom emoji draw as images with no network.
///   `off` passes no resolver: custom emoji show their short name as text
///   and the library does no lookup work. Any other value is ignored (as
///   if the flag were absent).
/// - `-emojiDelay <ms>` (default 400, clamped to 0…3_600_000): how long each
///   mock fetch takes. A non-number is ignored.
///
/// Without `-emoji` the mode is `mock` but not `isExplicit`: fixtures still
/// get the mock, while Confluence pages follow the Atlassian emoji setting
/// (see `EmojiResolvers.resolver(for:accounts:)`).
struct MockEmojiOptions: Sendable, Equatable {
    enum Mode: String, Sendable {
        /// No resolver: custom emoji show their short name.
        case off
        /// `CacheFirstEmojiResolver` over `MockEmojiFetch`.
        case mock
    }

    var mode: Mode = .mock
    /// Whether `-emoji` named the mode. An explicit mode applies to every
    /// reader; without it Confluence pages follow the reader setting.
    var isExplicit = false
    /// How long each mock fetch waits before it returns.
    var delay: Duration = .milliseconds(400)

    static let `default` = MockEmojiOptions(arguments: [])

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let next = arguments.index(after: index)
            switch arguments[index] {
            case "-emoji" where next < arguments.endIndex:
                index = next
                if let mode = Mode(rawValue: arguments[index]) {
                    self.mode = mode
                    isExplicit = true
                }
            case "-emojiDelay" where next < arguments.endIndex:
                index = next
                if let milliseconds = Int(arguments[index]) {
                    delay = .milliseconds(min(max(milliseconds, 0), 3_600_000))
                }
            default:
                break
            }
            index = arguments.index(after: index)
        }
    }

    /// One line for About This Build, e.g. `Mock · delay 400 ms`.
    var summary: String {
        switch mode {
        case .off:
            return "Off"
        case .mock:
            let milliseconds = delay.components.seconds * 1_000
                + delay.components.attoseconds / 1_000_000_000_000_000
            return "Mock · delay \(milliseconds) ms"
        }
    }
}

/// Offline custom-emoji images for the demo: the stand-in for the Atlassian
/// emoji service. No network.
///
/// Each fetch waits `options.delay` with `Task.sleep`, so a fetch the
/// library cancels (its emoji left the screen) ends at once with
/// `CancellationError`. It then returns PNG bytes of a 60 × 60 px rounded
/// square (20 pt at scale 3, `CacheFirstEmojiResolver.nominalPointSize`)
/// whose colour comes from a stable hash of the emoji's id (or short name
/// when it has no id), with one white character on it: the first character
/// of the short name's last `-`/`_` part, so `:ld-custom-6:` shows "6" and
/// `:partyparrot:` shows "P". The same emoji gives the same bytes on every
/// launch.
///
/// Failure hook: a short name that contains `fail` (any case), for example
/// `:fail-emoji:`, throws `MockEmojiFetch.Failure` after the delay, so UI
/// tests can show the short-name fallback.
///
/// Plug point for a real fetch: `CacheFirstEmojiResolver(fetch:)` takes any
/// `@Sendable (ADFEmojiReference) async throws -> Data` that returns image
/// bytes. `EmojiResolvers` passes `AtlassianEmojiFetcher.emojiFetch` there
/// for Confluence pages when the reader setting is on, in place of
/// `MockEmojiFetch.make(_:)`.
enum MockEmojiFetch {
    struct Failure: Error, Equatable {
        let shortName: String
    }

    /// The image's side in pixels.
    static let pixelSize = 60

    static func make(_ options: MockEmojiOptions) -> @Sendable (ADFEmojiReference) async throws -> Data {
        let delay = options.delay
        return { reference in
            try await Task.sleep(for: delay)
            if reference.shortName.lowercased().contains("fail") {
                throw Failure(shortName: reference.shortName)
            }
            return try pngData(for: reference)
        }
    }

    /// The deterministic PNG for `reference`.
    static func pngData(for reference: ADFEmojiReference) throws -> Data {
        let size = pixelSize
        guard let context = CGContext(data: nil, width: size, height: size,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure(shortName: reference.shortName)
        }
        let bounds = CGRect(x: 0, y: 0, width: size, height: size)
        let hue = Double(stableHash(reference.id ?? reference.shortName) % 360) / 360
        context.setFillColor(color(hue: hue, saturation: 0.6, brightness: 0.8))
        let corner = CGFloat(size) * 0.22
        context.addPath(CGPath(roundedRect: bounds.insetBy(dx: 2, dy: 2),
                               cornerWidth: corner, cornerHeight: corner, transform: nil))
        context.fillPath()

        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, CGFloat(size) * 0.55, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, CGFloat(size) * 0.55, nil)
        let text = NSAttributedString(string: glyph(for: reference.shortName), attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(text)
        let glyphBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.textPosition = CGPoint(x: bounds.midX - glyphBounds.midX,
                                       y: bounds.midY - glyphBounds.midY)
        CTLineDraw(line, context)

        guard let image = context.makeImage() else {
            throw Failure(shortName: reference.shortName)
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData,
                                                                 "public.png" as CFString, 1, nil) else {
            throw Failure(shortName: reference.shortName)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw Failure(shortName: reference.shortName)
        }
        return data as Data
    }

    /// The character drawn on the square: the first character of the short
    /// name's last `-`/`_` part, uppercased; `?` when there is none.
    static func glyph(for shortName: String) -> String {
        let name = shortName.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        let part = name.split(whereSeparator: { $0 == "-" || $0 == "_" }).last
        return part?.first.map { String($0).uppercased() } ?? "?"
    }

    /// FNV-1a over the UTF-8 bytes: unlike `hashValue`, the same on every
    /// launch.
    static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    private static func color(hue: Double, saturation: Double, brightness: Double) -> CGColor {
        let sector = hue * 6
        let index = Int(sector) % 6
        let fraction = sector - Double(Int(sector))
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * fraction)
        let t = brightness * (1 - saturation * (1 - fraction))
        let (red, green, blue): (Double, Double, Double) = switch index {
        case 0: (brightness, t, p)
        case 1: (q, brightness, p)
        case 2: (p, brightness, t)
        case 3: (p, q, brightness)
        case 4: (t, p, brightness)
        default: (brightness, p, q)
        }
        return CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}
