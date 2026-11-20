import ADFModel
import ADFRendering
import CoreGraphics
import Foundation
import SwiftUI

/// The memory cache key of a decoded media image: the image's source and
/// the pixel bucket it was decoded for.
public struct MediaImageKey: Hashable, Sendable {
    public let source: MediaAttrs.Source
    /// The longest side the image was decoded to, in pixels; one of
    /// `CacheFirstMediaProvider.pixelBuckets`.
    public let pixelBucket: Int

    public init(source: MediaAttrs.Source, pixelBucket: Int) {
        self.source = source
        self.pixelBucket = pixelBucket
    }
}

/// An `ADFMediaProvider` that loads cache first, in three tiers:
///
/// 1. memory: decoded images, by source and pixel bucket;
/// 2. disk (optional): the encoded bytes, by source only, so one download
///    serves every size;
/// 3. network: the `fetch` closure, whose bytes are then stored on disk.
///
/// Requests round the size they need up to a pixel bucket, so nearby sizes
/// share one decoded image instead of each decoding its own. Concurrent
/// requests for the same image share one decode, and concurrent requests
/// for the same source share one fetch. Failures are not cached.
///
/// Copies share their caches and in-flight work.
public struct CacheFirstMediaProvider: ADFMediaProvider {
    /// The longest sides, in pixels, that images are decoded to. A request
    /// gets the smallest bucket that covers it, up to the largest.
    public static let pixelBuckets = [64, 128, 256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096]

    private let scale: CGFloat
    /// An actor, so copies of this struct share it, and with it the caches
    /// and in-flight joins. Its fetch reaches the bytes loader.
    private let images: CacheFirstLoader<ImageRequest, ADFResolvedImage>

    /// - Parameters:
    ///   - memory: Decoded images. The default keeps up to 64 MB of decoded
    ///     bitmaps, costed by `decodedCost(_:)`.
    ///   - disk: Encoded bytes across launches; `nil` keeps none, so a
    ///     size the memory tier lacks is fetched again.
    ///   - scale: Pixels per point of the decoded images.
    ///   - fetch: Loads the encoded bytes of an image from the network.
    ///     It is cancelled when every request waiting on it is cancelled.
    public init(memory: MemoryCache<MediaImageKey, ADFResolvedImage>
                    = MemoryCache(totalCostLimit: 64 << 20, cost: { CacheFirstMediaProvider.decodedCost($0) }),
                disk: DiskCache? = nil,
                scale: CGFloat = 2,
                fetch: @escaping @Sendable (MediaAttrs) async throws -> Data) {
        self.scale = scale
        let bytesCache: any ResolverCache<BytesRequest, Data> = if let disk {
            KeyMappedCache(base: disk, map: { $0.diskKey })
        } else {
            NoCache()
        }
        let bytes = CacheFirstLoader<BytesRequest, Data>(cache: bytesCache,
                                                         fetch: { try await fetch($0.attrs) })
        images = CacheFirstLoader(
            cache: KeyMappedCache(base: memory, map: { $0.key }),
            fetch: { request in
                let data = try await bytes.value(for: BytesRequest(attrs: request.attrs))
                // The bytes may have arrived for other waiters; this one
                // need not decode if its own waiters are gone.
                try Task.checkCancellation()
                let cgImage = try ImageDownsampler.downsample(data, maxPixelSize: request.key.pixelBucket)
                return ADFResolvedImage(cgImage: cgImage, scale: scale)
            })
    }

    public func image(for attrs: MediaAttrs, targetSize: CGSize) async throws -> Image {
        let bucket = Self.pixelBucket(forPointSize: max(targetSize.width, targetSize.height), scale: scale)
        let request = ImageRequest(key: MediaImageKey(source: attrs.source, pixelBucket: bucket), attrs: attrs)
        let resolved = try await images.value(for: request)
        return Image(decorative: resolved.cgImage, scale: resolved.scale)
    }

    /// The memory an image's bitmap takes, in bytes: the cost to give a
    /// `MemoryCache` of decoded images.
    public static func decodedCost(_ image: ADFResolvedImage) -> Int {
        image.cgImage.bytesPerRow * image.cgImage.height
    }

    /// The smallest pixel bucket that covers `pointSize` points at `scale`,
    /// capped at the largest bucket. A size that is not positive and finite
    /// gets the smallest bucket.
    public static func pixelBucket(forPointSize pointSize: CGFloat, scale: CGFloat) -> Int {
        let pixels = pointSize * scale
        guard pixels.isFinite, pixels > 0 else { return pixelBuckets[0] }
        return pixelBuckets.first { CGFloat($0) >= pixels } ?? pixelBuckets[pixelBuckets.count - 1]
    }

    /// The disk key of a source: stable across launches and independent of
    /// size, so every bucket decodes from one stored download.
    static func diskKey(for source: MediaAttrs.Source) -> String {
        switch source {
        case let .file(id, collection): "file:\(collection)/\(id)"
        case let .external(url): "url:\(url)"
        }
    }
}

// MARK: - Loader keys

/// A memory-tier request: equal by `key` alone, carrying the attributes
/// the fetch needs.
private struct ImageRequest: Hashable, Sendable {
    let key: MediaImageKey
    let attrs: MediaAttrs

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key == rhs.key
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
    }
}

/// A bytes-tier request: equal by disk key alone, so every size of one
/// source joins one fetch, carrying the attributes the fetch needs.
private struct BytesRequest: Hashable, Sendable {
    let diskKey: String
    let attrs: MediaAttrs

    init(attrs: MediaAttrs) {
        diskKey = CacheFirstMediaProvider.diskKey(for: attrs.source)
        self.attrs = attrs
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.diskKey == rhs.diskKey
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(diskKey)
    }
}

// MARK: - Cache adapters

/// Presents a cache under another key type, so the public caches keep
/// their plain keys while the loaders key by requests.
private struct KeyMappedCache<Key: Hashable & Sendable, Base: ResolverCache>: ResolverCache {
    let base: Base
    let map: @Sendable (Key) -> Base.Key

    func value(for key: Key) async -> Base.Value? {
        await base.value(for: map(key))
    }

    func store(_ value: Base.Value, for key: Key) async {
        await base.store(value, for: map(key))
    }
}

/// Stores nothing: the bytes tier when there is no disk cache, which
/// still joins concurrent fetches of one source.
private struct NoCache<Key: Hashable & Sendable, Value: Sendable>: ResolverCache {
    func value(for key: Key) async -> Value? { nil }
    func store(_ value: Value, for key: Key) async {}
}
