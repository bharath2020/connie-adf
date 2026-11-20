import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers
import os
import ADFModel
import ADFRendering
import ADFResolvers

/// Offline media bytes for the demo: the stand-in for an Atlassian media
/// download. No network. Every reference becomes a deterministic two-color
/// linear gradient: a stable FNV-1a hash of the media id / URL picks the
/// hues, so the same document always shows the same images.
///
/// This is the plug point for a real fetch. `CacheFirstMediaProvider` takes
/// any `@Sendable (MediaAttrs) async throws -> Data` closure; a real app
/// passes one that resolves Atlassian media — for `.file(id:collection:)`,
/// the media REST API with the account's credential (`ADFAtlassianAuth`);
/// for `.external(url:)`, the URL itself — and returns the encoded bytes.
/// The provider does the rest: memory and disk caching, joining concurrent
/// requests, decoding and downsampling. The real Atlassian adapter is a
/// separate task and is not merged yet.
///
/// `fetch(_:)` returns encoded JPEG bytes, not a decoded image, because the
/// provider decodes and downsamples them to the size each view needs. The
/// gradient is drawn at the media's own pixel size (`width` × `height`,
/// shrunk so the longer side is at most 1,600 px), or 1,200 × 800 when the
/// document gives no size.
///
/// Each fetch waits `configuration.delay` with `Task.sleep`, so a fetch the
/// provider cancels (every view waiting on it went away) ends at once with
/// `CancellationError`. A share of sources (`configuration.failureRate`)
/// throws; which ones is fixed by a stable hash of the source, so the same
/// images fail on every launch.
///
/// The mock counts what it sees — calls, cancellations, fetches in flight,
/// fetched, failed — for About This Build. Only the provider's misses reach
/// it: a memory or disk hit makes no call.
final class MockMediaFetch: Sendable {
    struct Configuration: Sendable, Equatable {
        var delay: Duration
        /// 0…1: the share of sources whose fetch throws.
        var failureRate: Double = 0

        static let `default` = Configuration(delay: .milliseconds(300))

        /// One line for About This Build, e.g. `Delay 0.3 s · failure rate 0 %`.
        var summary: String {
            let (wholeSeconds, attoseconds) = delay.components
            let seconds = (Double(wholeSeconds) + Double(attoseconds) / 1e18)
                .formatted(.number.precision(.fractionLength(0 ... 3)))
            let percent = (failureRate * 100).formatted(.number.precision(.fractionLength(0 ... 1)))
            return "Delay \(seconds) s · failure rate \(percent) %"
        }
    }

    /// Since launch, across every document.
    struct Counts: Sendable, Equatable {
        var calls = 0
        var cancelled = 0
        var inFlight = 0
        var fetched = 0
        var failed = 0
    }

    enum FetchError: Error {
        /// The source drew a failure (`Configuration.failureRate`).
        case unavailable
        case drawingFailed
        case encodingFailed
    }

    /// The longest side of a drawn image, in pixels.
    static let maxPixelSide: Double = 1_600
    /// The pixel size drawn when the document gives no media size.
    static let defaultPixelSize = (width: 1_200, height: 800)

    let configuration: Configuration
    private let counts = OSAllocatedUnfairLock(initialState: Counts())

    init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    /// A consistent copy of the counters (one lock acquisition).
    var snapshot: Counts {
        counts.withLock { $0 }
    }

    func fetch(_ attrs: MediaAttrs) async throws -> Data {
        counts.withLock {
            $0.calls += 1
            $0.inFlight += 1
        }
        do {
            if configuration.delay > .zero {
                try await Task.sleep(for: configuration.delay)
            }
            try Task.checkCancellation()
        } catch {
            counts.withLock {
                $0.inFlight -= 1
                $0.cancelled += 1
            }
            throw error
        }
        do {
            let data = try Self.bytes(for: attrs, failureRate: configuration.failureRate)
            counts.withLock {
                $0.inFlight -= 1
                $0.fetched += 1
            }
            return data
        } catch {
            counts.withLock {
                $0.inFlight -= 1
                $0.failed += 1
            }
            throw error
        }
    }

    // MARK: - Deterministic bytes

    /// What a fetch of `attrs` returns once its delay has passed: the
    /// gradient as JPEG, or `.unavailable` for a source that draws a
    /// failure. Pure and stable across launches.
    static func bytes(for attrs: MediaAttrs, failureRate: Double) throws -> Data {
        let hash = fnv1a(stableKey(attrs.source))
        // The high bits, so the draw does not follow the hue (low bits).
        let draw = Double((hash >> 32) % 10_000) / 10_000
        if draw < min(max(failureRate, 0), 1) {
            throw FetchError.unavailable
        }
        let size = pixelSize(for: attrs)
        let image = try gradientImage(hash: hash, width: size.width, height: size.height)
        return try jpegData(image, quality: 0.8)
    }

    /// The same key the demo's earlier placeholder provider hashed, so
    /// images keep the colors they had before.
    static func stableKey(_ source: MediaAttrs.Source) -> String {
        switch source {
        case .file(let id, let collection):
            "file:\(collection)/\(id)"
        case .external(let url):
            "url:\(url)"
        }
    }

    /// The media's own size, shrunk (keeping its aspect) so the longer side
    /// is at most `maxPixelSide`; `defaultPixelSize` when either side is
    /// missing or not a positive finite number.
    static func pixelSize(for attrs: MediaAttrs) -> (width: Int, height: Int) {
        guard let width = attrs.width, let height = attrs.height,
              width.isFinite, height.isFinite, width > 0, height > 0 else {
            return defaultPixelSize
        }
        let shrink = min(1, maxPixelSide / max(width, height))
        return (max(1, Int((width * shrink).rounded())), max(1, Int((height * shrink).rounded())))
    }

    private static func gradientImage(hash: UInt64, width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // No alpha: JPEG has none, and an opaque bitmap encodes without a
        // conversion.
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw FetchError.drawingFailed
        }

        let startHue = Double(hash & 0xFFFF) / 65_536
        let endHue = (startHue + 0.18).truncatingRemainder(dividingBy: 1)
        let components: [CGFloat] = (
            rgb(hue: startHue, saturation: 0.55, brightness: 0.9) + [1]
                + rgb(hue: endHue, saturation: 0.7, brightness: 0.6) + [1]
        ).map { CGFloat($0) }
        guard let gradient = CGGradient(
            colorSpace: colorSpace,
            colorComponents: components,
            locations: [0, 1],
            count: 2
        ) else {
            throw FetchError.drawingFailed
        }

        context.drawLinearGradient(
            gradient,
            start: .zero,
            end: CGPoint(x: width, y: height),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        guard let image = context.makeImage() else {
            throw FetchError.drawingFailed
        }
        return image
    }

    /// Encodes with ImageIO. JPEG keeps the disk cache small (a 1,600 px
    /// gradient is tens of kilobytes).
    private static func jpegData(_ image: CGImage, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw FetchError.encodingFailed
        }
        let properties = [kCGImageDestinationLossyCompressionQuality as String: quality] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw FetchError.encodingFailed
        }
        return data as Data
    }

    /// FNV-1a: stable across launches (unlike `Hashable`'s seeded hasher).
    private static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// Minimal HSB → RGB so drawing stays pure CoreGraphics (no UIKit).
    private static func rgb(hue: Double, saturation: Double, brightness: Double) -> [Double] {
        let h = (hue - hue.rounded(.down)) * 6
        let sector = min(5, max(0, Int(h)))
        let f = h - Double(sector)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * f)
        let t = brightness * (1 - saturation * (1 - f))
        switch sector {
        case 0: return [brightness, t, p]
        case 1: return [q, brightness, p]
        case 2: return [p, brightness, t]
        case 3: return [p, q, brightness]
        case 4: return [t, p, brightness]
        default: return [brightness, p, q]
        }
    }
}

// MARK: - The demo's media provider

/// The demo's media setup for this launch, built once from the process
/// arguments (`-media`, `-mediaDelay`, `-mediaCache`; see `LaunchOptions`)
/// like `MockSmartLinkResolver.shared`, so every reader shares one provider
/// — one memory cache, one disk cache, one set of in-flight fetches — and
/// About This Build's counts cover the whole launch.
///
/// - `-media mock` (or no flag): `CacheFirstMediaProvider` over a 200 MB
///   disk cache in `Caches/ADFReaderMedia`, fetching from `MockMediaFetch`.
/// - `-media off`: no provider. Media shows its placeholder box and
///   nothing loads.
/// - `-mediaCache cold`: the disk cache starts empty.
struct DemoMedia: Sendable {
    enum Mode: String, Sendable {
        case off
        case mock
    }

    let mode: Mode
    /// What `ReaderView` passes to `ADFDocumentView`; `nil` under `-media off`.
    let provider: (any ADFMediaProvider)?
    /// The fetch behind `provider`, for its counters; `nil` under `-media off`.
    let mock: MockMediaFetch?
    /// Whether this launch emptied the disk cache (`-mediaCache cold`).
    let startedCold: Bool
    /// Pixels per point the provider decodes for.
    let scale: CGFloat

    static let cacheDirectory = URL.cachesDirectory
        .appending(path: "ADFReaderMedia", directoryHint: .isDirectory)
    static let diskByteLimit = 200 << 20

    /// Main-actor isolated because it reads the display scale from the
    /// window scene; the first reader builds it.
    @MainActor static let shared = DemoMedia(options: LaunchOptions(), scale: currentDisplayScale())

    init(options: LaunchOptions, scale: CGFloat) {
        self.scale = scale
        startedCold = options.mediaCacheCold
        if options.mediaCacheCold {
            // The same as `DiskCache.removeAll()`, but done before the cache
            // exists, so it is finished before the first lookup: a
            // `DiskCache` reads its directory on first use, and here finds
            // it empty. `removeAll()` is actor-isolated and async, so a
            // call from here could run after the first lookup.
            try? FileManager.default.removeItem(at: Self.cacheDirectory)
        }
        guard options.mediaEnabled else {
            mode = .off
            provider = nil
            mock = nil
            return
        }
        let mockFetch = MockMediaFetch(configuration: MockMediaFetch.Configuration(
            delay: .milliseconds(Int((options.mediaDelay * 1_000).rounded()))
        ))
        mode = .mock
        mock = mockFetch
        provider = CacheFirstMediaProvider(
            disk: DiskCache(directory: Self.cacheDirectory, byteLimit: Self.diskByteLimit),
            scale: scale,
            fetch: { try await mockFetch.fetch($0) }
        )
    }

    /// The window scene's display scale; 3 (2 on Mac Catalyst) when no
    /// scene reports one yet.
    @MainActor static func currentDisplayScale() -> CGFloat {
        let sceneScale = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.traitCollection.displayScale }
            .first { $0 > 0 }
        let scale = sceneScale ?? UITraitCollection.current.displayScale
        if scale > 0 {
            return scale
        }
        #if targetEnvironment(macCatalyst)
        return 2
        #else
        return 3
        #endif
    }

    /// One line for About This Build, e.g. `Delay 0.3 s · failure rate 0 % ·
    /// disk 200 MB · @3x · cold start`.
    var summary: String {
        guard let mock else { return "Off (-media off)" }
        let scaleText = Double(scale).formatted(.number.precision(.fractionLength(0 ... 2)))
        var parts = [mock.configuration.summary, "disk \(Self.diskByteLimit >> 20) MB", "@\(scaleText)x"]
        if startedCold {
            parts.append("cold start")
        }
        return parts.joined(separator: " · ")
    }
}
