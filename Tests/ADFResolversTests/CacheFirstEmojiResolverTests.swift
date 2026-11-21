import CoreGraphics
import Foundation
import ImageIO
import Testing
import ADFRendering
@testable import ADFResolvers

/// An emoji fetch the test drives: each call waits until the test releases
/// it with bytes or an error, and records whether it saw cancellation.
private actor EmojiFetchGate {
    private(set) var calls: [ADFEmojiReference] = []
    private(set) var cancelledCalls = 0
    private var pending: [ADFEmojiReference: [CheckedContinuation<Data, any Error>]] = [:]

    func fetch(_ reference: ADFEmojiReference) async throws -> Data {
        calls.append(reference)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[reference, default: []].append(continuation)
            }
        } onCancel: {
            Task { await self.cancel(reference) }
        }
    }

    /// Ends every waiting call for `reference` with `result`.
    func release(_ reference: ADFEmojiReference, with result: Result<Data, any Error>) {
        for continuation in pending.removeValue(forKey: reference) ?? [] {
            continuation.resume(with: result)
        }
    }

    func waitingCount(_ reference: ADFEmojiReference) -> Int {
        pending[reference]?.count ?? 0
    }

    private func cancel(_ reference: ADFEmojiReference) {
        guard let waiting = pending.removeValue(forKey: reference) else { return }
        cancelledCalls += waiting.count
        for continuation in waiting {
            continuation.resume(throwing: CancellationError())
        }
    }
}

private struct FetchFailed: Error {}

/// PNG bytes of a `width` × `height` opaque red bitmap.
private func pngData(width: Int, height: Int) -> Data {
    let context = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = context.makeImage()!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

/// Polls until `condition` holds; fails the test after about ten seconds.
private func waitUntil(_ condition: () async -> Bool,
                       sourceLocation: SourceLocation = #_sourceLocation) async {
    for _ in 0..<2_000 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("condition never held", sourceLocation: sourceLocation)
}

private let logo = ADFEmojiReference(id: "atlassian-logo", shortName: ":atlassian:")
private let custom = ADFEmojiReference(id: nil, shortName: ":ld-custom-6:")

@Suite("CacheFirstEmojiResolver")
struct CacheFirstEmojiResolverTests {
    @Test("a miss fetches, decodes and stores the image; the next request hits without a fetch")
    func missThenHit() async throws {
        let cache = MemoryCache<ADFEmojiReference, ADFResolvedImage>()
        let gate = EmojiFetchGate()
        let resolver = CacheFirstEmojiResolver(cache: cache, fetch: { try await gate.fetch($0) })

        let request = Task { try await resolver.image(for: logo) }
        await waitUntil { await gate.waitingCount(logo) == 1 }
        await gate.release(logo, with: .success(pngData(width: 60, height: 60)))

        let image = try await request.value
        #expect(image.cgImage.width == 60)
        #expect(image.cgImage.height == 60)
        #expect(image.scale == 3)
        #expect(await cache.value(for: logo) != nil)

        let again = try await resolver.image(for: logo)
        #expect(again.cgImage === image.cgImage)
        #expect(await gate.calls == [logo])
    }

    @Test("an image already in the cache returns without a fetch")
    func hit() async throws {
        let cache = MemoryCache<ADFEmojiReference, ADFResolvedImage>()
        let stored = try CacheFirstEmojiResolver.decode(pngData(width: 20, height: 20))
        await cache.store(stored, for: custom)
        let gate = EmojiFetchGate()
        let resolver = CacheFirstEmojiResolver(cache: cache, fetch: { try await gate.fetch($0) })

        let image = try await resolver.image(for: custom)

        #expect(image.cgImage === stored.cgImage)
        #expect(image.scale == 1)
        #expect(await gate.calls.isEmpty)
    }

    @Test("concurrent requests for one emoji join one fetch")
    func concurrentJoin() async throws {
        let gate = EmojiFetchGate()
        let resolver = CacheFirstEmojiResolver(fetch: { try await gate.fetch($0) })

        let first = Task { try await resolver.image(for: logo) }
        let second = Task { try await resolver.image(for: logo) }
        let other = Task { try await resolver.image(for: custom) }
        await waitUntil { await resolver.loader.waiterCount(for: logo) == 2 }
        await waitUntil { await gate.waitingCount(custom) == 1 }
        #expect(await gate.waitingCount(logo) == 1)
        await gate.release(logo, with: .success(pngData(width: 40, height: 40)))
        await gate.release(custom, with: .success(pngData(width: 20, height: 20)))

        let firstImage = try await first.value
        let secondImage = try await second.value
        #expect(firstImage.cgImage === secondImage.cgImage)
        #expect(try await other.value.cgImage.width == 20)
        #expect(await gate.calls.filter { $0 == logo }.count == 1)
        #expect(await gate.calls.count == 2)
    }

    @Test("bytes that do not decode throw and are not stored")
    func decodeFailureNotStored() async throws {
        let cache = MemoryCache<ADFEmojiReference, ADFResolvedImage>()
        let gate = EmojiFetchGate()
        let resolver = CacheFirstEmojiResolver(cache: cache, fetch: { try await gate.fetch($0) })

        let request = Task { try await resolver.image(for: logo) }
        await waitUntil { await gate.waitingCount(logo) == 1 }
        await gate.release(logo, with: .success(Data("not an image".utf8)))

        await #expect(throws: EmojiDecodingError(byteCount: 12)) { try await request.value }
        #expect(await cache.value(for: logo) == nil)

        let retry = Task { try await resolver.image(for: logo) }
        await waitUntil { await gate.waitingCount(logo) == 1 }
        await gate.release(logo, with: .success(pngData(width: 20, height: 20)))
        #expect(try await retry.value.cgImage.width == 20)
        #expect(await gate.calls == [logo, logo])
    }

    @Test("empty bytes throw a decoding error")
    func emptyData() {
        #expect(throws: EmojiDecodingError(byteCount: 0)) {
            try CacheFirstEmojiResolver.decode(Data())
        }
    }

    @Test("a fetch error reaches the caller and is not stored")
    func fetchErrorNotStored() async throws {
        let cache = MemoryCache<ADFEmojiReference, ADFResolvedImage>()
        let gate = EmojiFetchGate()
        let resolver = CacheFirstEmojiResolver(cache: cache, fetch: { try await gate.fetch($0) })

        let request = Task { try await resolver.image(for: custom) }
        await waitUntil { await gate.waitingCount(custom) == 1 }
        await gate.release(custom, with: .failure(FetchFailed()))

        await #expect(throws: FetchFailed.self) { try await request.value }
        #expect(await cache.value(for: custom) == nil)

        let retry = Task { try await resolver.image(for: custom) }
        await waitUntil { await gate.waitingCount(custom) == 1 }
        await gate.release(custom, with: .success(pngData(width: 20, height: 20)))
        #expect(try await retry.value.scale == 1)
        #expect(await gate.calls == [custom, custom])
    }

    @Test("cancelling the only request cancels the fetch, and nothing is stored")
    func onlyWaiterCancel() async throws {
        let cache = MemoryCache<ADFEmojiReference, ADFResolvedImage>()
        let gate = EmojiFetchGate()
        let resolver = CacheFirstEmojiResolver(cache: cache, fetch: { try await gate.fetch($0) })

        let request = Task { try await resolver.image(for: logo) }
        await waitUntil { await gate.waitingCount(logo) == 1 }

        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        await waitUntil { await gate.cancelledCalls == 1 }
        #expect(await resolver.loader.waiterCount(for: logo) == 0)
        #expect(await cache.value(for: logo) == nil)
    }

    @Test("large images are downsampled to maxPixelSize; scale keeps the nominal point size")
    func downsample() throws {
        let image = try CacheFirstEmojiResolver.decode(pngData(width: 512, height: 256))
        #expect(image.cgImage.width == CacheFirstEmojiResolver.maxPixelSize)
        #expect(image.cgImage.height == CacheFirstEmojiResolver.maxPixelSize / 2)
        let pointWidth = CGFloat(image.cgImage.width) / image.scale
        #expect(pointWidth == CacheFirstEmojiResolver.nominalPointSize)
    }
}
