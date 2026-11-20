import ADFModel
import CoreGraphics
import Foundation
import ImageIO
import Testing
import ADFRendering
@testable import ADFResolvers

/// PNG bytes of a solid `width` × `height` image, made in memory.
private func pngData(width: Int, height: Int) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height,
                                         bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

/// A network fetch the test scripts: it counts calls and returns each
/// queued result in turn, then the default, after an optional delay.
private actor ScriptedFetch {
    private(set) var calls = 0
    private var queued: [Result<Data, any Error>]
    private let fallback: Result<Data, any Error>
    private let delay: Duration

    init(_ fallback: Result<Data, any Error>,
         queued: [Result<Data, any Error>] = [],
         delay: Duration = .zero) {
        self.fallback = fallback
        self.queued = queued
        self.delay = delay
    }

    func fetch(_ attrs: MediaAttrs) async throws -> Data {
        calls += 1
        let result = queued.isEmpty ? fallback : queued.removeFirst()
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        return try result.get()
    }
}

private struct NetworkDown: Error {}

private let attrs = MediaAttrs(source: .file(id: "img", collection: "pages"),
                               width: 800, height: 600, alt: nil, mediaType: "image")

/// A fresh directory under the temporary directory, deleted when the test
/// body returns.
private func withTemporaryDirectory(_ body: (URL) async throws -> Void) async rethrows {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MediaProviderTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory)
}

/// The decoded image the memory tier holds for `bucket`.
private func decoded(in memory: MemoryCache<MediaImageKey, ADFResolvedImage>,
                     bucket: Int) async -> CGImage? {
    await memory.value(for: MediaImageKey(source: attrs.source, pixelBucket: bucket))?.cgImage
}

@Suite("CacheFirstMediaProvider")
struct CacheFirstMediaProviderTests {
    @Test("a miss fetches once and decodes no larger than the bucket")
    func networkMiss() async throws {
        let network = ScriptedFetch(.success(try pngData(width: 800, height: 600)))
        let memory = MemoryCache<MediaImageKey, ADFResolvedImage>()
        let provider = CacheFirstMediaProvider(memory: memory, scale: 2,
                                               fetch: { try await network.fetch($0) })

        // 100 pt × 2 = 200 px → the 256 bucket.
        _ = try await provider.image(for: attrs, targetSize: CGSize(width: 100, height: 80))

        #expect(await network.calls == 1)
        let image = try #require(await decoded(in: memory, bucket: 256))
        #expect(max(image.width, image.height) <= 256)
        #expect(image.width == 256)
        #expect(image.height == 192)
    }

    @Test("a second request for the same size is a memory hit")
    func memoryHit() async throws {
        let network = ScriptedFetch(.success(try pngData(width: 800, height: 600)))
        let provider = CacheFirstMediaProvider(fetch: { try await network.fetch($0) })

        _ = try await provider.image(for: attrs, targetSize: CGSize(width: 100, height: 80))
        _ = try await provider.image(for: attrs, targetSize: CGSize(width: 100, height: 80))

        #expect(await network.calls == 1)
    }

    @Test("a new provider on the same disk cache needs no fetch")
    func diskHit() async throws {
        try await withTemporaryDirectory { directory in
            let network = ScriptedFetch(.success(try pngData(width: 800, height: 600)))
            let first = CacheFirstMediaProvider(disk: DiskCache(directory: directory, byteLimit: 10 << 20),
                                                fetch: { try await network.fetch($0) })
            _ = try await first.image(for: attrs, targetSize: CGSize(width: 100, height: 80))

            // A relaunch: fresh memory, a new disk cache on the same files.
            let memory = MemoryCache<MediaImageKey, ADFResolvedImage>()
            let second = CacheFirstMediaProvider(memory: memory,
                                                 disk: DiskCache(directory: directory, byteLimit: 10 << 20),
                                                 fetch: { try await network.fetch($0) })
            _ = try await second.image(for: attrs, targetSize: CGSize(width: 100, height: 80))

            #expect(await network.calls == 1)
            #expect(await decoded(in: memory, bucket: 256) != nil)
        }
    }

    @Test("sizes in one bucket share a decode; another bucket decodes from disk")
    func sizeBuckets() async throws {
        try await withTemporaryDirectory { directory in
            let network = ScriptedFetch(.success(try pngData(width: 800, height: 600)))
            let memory = MemoryCache<MediaImageKey, ADFResolvedImage>()
            let provider = CacheFirstMediaProvider(memory: memory,
                                                   disk: DiskCache(directory: directory, byteLimit: 10 << 20),
                                                   scale: 2,
                                                   fetch: { try await network.fetch($0) })

            _ = try await provider.image(for: attrs, targetSize: CGSize(width: 100, height: 80))
            let small = try #require(await decoded(in: memory, bucket: 256))
            // 110 pt → 220 px: still the 256 bucket, the same decoded image.
            _ = try await provider.image(for: attrs, targetSize: CGSize(width: 50, height: 110))
            let again = await decoded(in: memory, bucket: 256)
            #expect(again === small)
            #expect(await network.calls == 1)

            // 300 pt → 600 px: the 768 bucket, decoded from the disk bytes.
            _ = try await provider.image(for: attrs, targetSize: CGSize(width: 300, height: 200))
            let large = try #require(await decoded(in: memory, bucket: 768))
            #expect(large.width == 768)
            #expect(large.height == 576)
            #expect(await network.calls == 1)

            // 1000 pt → the 2048 bucket: larger than the image, which keeps
            // its own size.
            _ = try await provider.image(for: attrs, targetSize: CGSize(width: 1_000, height: 750))
            let full = try #require(await decoded(in: memory, bucket: 2048))
            #expect(full.width == 800)
            #expect(full.height == 600)
            #expect(await network.calls == 1)
        }
    }

    @Test("pixel buckets round up, cap at 4096, and give bad sizes the smallest",
          arguments: [
              (CGFloat(0), CGFloat(2), 64),
              (-10, 2, 64),
              (.nan, 2, 64),
              (.infinity, 2, 64),
              (10, 0, 64),
              (1, 1, 64),
              (32, 2, 64),
              (32.5, 2, 128),
              (64, 2, 128),
              (64.5, 2, 256),
              (128, 2, 256),
              (192, 2, 384),
              (256, 2, 512),
              (384, 2, 768),
              (512, 2, 1024),
              (768, 2, 1536),
              (1024, 2, 2048),
              (1536, 2, 3072),
              (2048, 2, 4096),
              (2049, 2, 4096),
              (100_000, 3, 4096),
          ])
    func pixelBucket(pointSize: CGFloat, scale: CGFloat, bucket: Int) {
        #expect(CacheFirstMediaProvider.pixelBucket(forPointSize: pointSize, scale: scale) == bucket)
    }

    @Test("concurrent requests share one fetch")
    func concurrentRequestsJoin() async throws {
        let network = ScriptedFetch(.success(try pngData(width: 800, height: 600)),
                                    delay: .milliseconds(200))
        let provider = CacheFirstMediaProvider(fetch: { try await network.fetch($0) })

        // Same bucket: one decode, one fetch. Different buckets with no
        // disk cache: separate decodes that still join one fetch.
        let sizes = [CGSize(width: 100, height: 80), CGSize(width: 100, height: 80),
                     CGSize(width: 120, height: 80), CGSize(width: 300, height: 200),
                     CGSize(width: 600, height: 400)]
        try await withThrowingTaskGroup(of: Void.self) { group in
            for size in sizes {
                group.addTask { _ = try await provider.image(for: attrs, targetSize: size) }
            }
            try await group.waitForAll()
        }

        #expect(await network.calls == 1)
    }

    @Test("a failed fetch is not cached; the next request fetches again")
    func failureNotCached() async throws {
        let network = ScriptedFetch(.success(try pngData(width: 800, height: 600)),
                                    queued: [.failure(NetworkDown())])
        let memory = MemoryCache<MediaImageKey, ADFResolvedImage>()
        let provider = CacheFirstMediaProvider(memory: memory, fetch: { try await network.fetch($0) })

        await #expect(throws: NetworkDown.self) {
            _ = try await provider.image(for: attrs, targetSize: CGSize(width: 100, height: 80))
        }
        #expect(await decoded(in: memory, bucket: 256) == nil)

        _ = try await provider.image(for: attrs, targetSize: CGSize(width: 100, height: 80))
        #expect(await network.calls == 2)
        #expect(await decoded(in: memory, bucket: 256) != nil)
    }

    @Test("bytes that are not an image throw and are not cached in memory")
    func undecodable() async throws {
        let network = ScriptedFetch(.success(Data("not an image".utf8)))
        let memory = MemoryCache<MediaImageKey, ADFResolvedImage>()
        let provider = CacheFirstMediaProvider(memory: memory, fetch: { try await network.fetch($0) })

        await #expect(throws: ImageDownsampler.Error.undecodable) {
            _ = try await provider.image(for: attrs, targetSize: CGSize(width: 100, height: 80))
        }
        #expect(await decoded(in: memory, bucket: 256) == nil)
    }

    @Test("disk keys depend on the source only")
    func diskKeys() {
        #expect(CacheFirstMediaProvider.diskKey(for: .file(id: "i", collection: "c")) == "file:c/i")
        #expect(CacheFirstMediaProvider.diskKey(for: .external(url: "https://x/y.png")) == "url:https://x/y.png")
    }

    @Test("the decoded cost is the bitmap's byte size")
    func decodedCost() throws {
        let image = try ImageDownsampler.downsample(try pngData(width: 800, height: 600), maxPixelSize: 256)
        let resolved = ADFResolvedImage(cgImage: image, scale: 2)
        #expect(CacheFirstMediaProvider.decodedCost(resolved) == image.bytesPerRow * image.height)
        #expect(CacheFirstMediaProvider.decodedCost(resolved) >= 256 * 192 * 4)
    }
}
