import CoreGraphics
import Foundation
import ImageIO
import ADFRendering

/// An `ADFEmojiResolver` that keeps decoded custom emoji in a cache and
/// fetches the ones it lacks: the host supplies only a closure that returns
/// an emoji's image bytes (PNG, GIF, JPEG, or any format ImageIO reads).
///
/// ```swift
/// let resolver = CacheFirstEmojiResolver(fetch: { reference in
///     try await myEmojiService.imageData(for: reference)
/// })
/// ADFDocumentView(model: model, emojiResolver: resolver)
/// ```
///
/// Behaviour, from `CacheFirstLoader`:
/// - A cached emoji returns at once, with no fetch.
/// - Concurrent requests for one emoji share one fetch.
/// - The fetched bytes are decoded off the main thread; the decoded image
///   is stored, then returned.
/// - A fetch error, or bytes that do not decode, reach the caller and are
///   not stored, so the next request fetches again.
/// - When every request waiting on a fetch is cancelled, the fetch is
///   cancelled.
///
/// Emoji use a memory cache only (no disk cache in v1). Share one resolver
/// across documents so the cache serves them all.
public struct CacheFirstEmojiResolver: ADFEmojiResolver {
    /// The nominal display size of a custom emoji, in points: the size of
    /// an Atlassian emoji in body text. A decoded image's `scale` makes its
    /// longest side this many points (a 60 px image gets scale 3, a 20 px
    /// image scale 1). Renderers fit the image into a square box of the
    /// font's ascent anyway; the scale keeps the image's own point size
    /// meaningful and independent of the source's pixel size.
    public static let nominalPointSize: CGFloat = 20

    /// Images larger than this, on their longest side, are downsampled to
    /// it when decoded: three times `nominalPointSize` with headroom for
    /// large text sizes, so a big upload does not stay in memory at full
    /// size. Smaller images are not enlarged.
    public static let maxPixelSize = 128

    let loader: CacheFirstLoader<ADFEmojiReference, ADFResolvedImage>

    /// - Parameters:
    ///   - cache: Holds decoded emoji. The default keeps up to 512 in
    ///     memory and is emptied by the system under memory pressure.
    ///   - fetch: Returns the image bytes for an emoji that is not in
    ///     `cache`. Called off the main actor; honour task cancellation.
    ///     This is where a host plugs in its network call.
    public init(cache: some ResolverCache<ADFEmojiReference, ADFResolvedImage> = MemoryCache(countLimit: 512),
                fetch: @escaping @Sendable (ADFEmojiReference) async throws -> Data) {
        loader = CacheFirstLoader(cache: cache) { reference in
            let data = try await fetch(reference)
            try Task.checkCancellation()
            return try Self.decode(data)
        }
    }

    public func image(for emoji: ADFEmojiReference) async throws -> ADFResolvedImage {
        try await loader.value(for: emoji)
    }

    /// Decodes `data` into a bitmap that is fully decoded now (not on first
    /// draw), downsampled to `maxPixelSize`, with the orientation applied.
    /// An animated image gives its first frame.
    static func decode(_ data: Data) throws -> ADFResolvedImage {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0 else {
            throw EmojiDecodingError(byteCount: data.count)
        }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions),
              image.width > 0, image.height > 0 else {
            throw EmojiDecodingError(byteCount: data.count)
        }
        let longestSide = CGFloat(max(image.width, image.height))
        return ADFResolvedImage(cgImage: image, scale: longestSide / nominalPointSize)
    }
}

/// The fetched bytes of a custom emoji are not an image ImageIO can read.
public struct EmojiDecodingError: Error, Sendable, Equatable {
    /// How many bytes the fetch returned.
    public let byteCount: Int

    public init(byteCount: Int) {
        self.byteCount = byteCount
    }
}
