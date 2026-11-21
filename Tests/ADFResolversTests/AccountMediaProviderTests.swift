import ADFModel
import CoreGraphics
import Foundation
import ImageIO
import Testing
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

private struct SignedOut: Error {}

/// A network that serves each account its own bytes, as an authorized
/// fetch would: it records which account every call was made for. The
/// signed-in account can change while a fetch is in flight.
private actor AccountNetwork {
    private(set) var calls: [String] = []
    private var account: String?
    private let bytes: [String: Data]
    private var delays: [String: Duration] = [:]

    init(account: String?, bytes: [String: Data]) {
        self.account = account
        self.bytes = bytes
    }

    func signIn(_ account: String?) {
        self.account = account
    }

    func delay(_ account: String, by delay: Duration) {
        delays[account] = delay
    }

    func fetch(_ attrs: MediaAttrs) async throws -> Data {
        guard let account else { throw SignedOut() }
        calls.append(account)
        guard let data = bytes[account] else { throw SignedOut() }
        if let delay = delays[account] {
            try await Task.sleep(for: delay)
        }
        return data
    }
}

private let attrs = MediaAttrs(source: .file(id: "img", collection: "pages"),
                               width: 800, height: 600, alt: nil, mediaType: "image")
private let size = CGSize(width: 100, height: 80)

/// A fresh directory under the temporary directory, deleted when the test
/// body returns.
private func withTemporaryDirectory(_ body: (URL) async throws -> Void) async rethrows {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AccountMediaProviderTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory)
}

/// What a relaunch would find on disk for `attrs`.
private func storedBytes(in directory: URL) async -> Data? {
    await DiskCache(directory: directory, byteLimit: 10 << 20)
        .value(for: CacheFirstMediaProvider.diskKey(for: attrs.source))
}

@Suite("AccountMediaProvider")
struct AccountMediaProviderTests {
    @Test("the same account keeps its cached images")
    func sameAccountKeepsCache() async throws {
        try await withTemporaryDirectory { directory in
            let network = AccountNetwork(account: "a", bytes: ["a": try pngData(width: 800, height: 600)])
            let provider = AccountMediaProvider(account: "a",
                                                disk: DiskCache(directory: directory, byteLimit: 10 << 20),
                                                fetch: { try await network.fetch($0) })

            _ = try await provider.image(for: attrs, targetSize: size)
            provider.use("a")
            _ = try await provider.image(for: attrs, targetSize: size)

            #expect(await network.calls == ["a"])
        }
    }

    @Test("a replaced account fetches afresh and is never served the previous account's bytes")
    func replacedAccountPurges() async throws {
        try await withTemporaryDirectory { directory in
            let bytesA = try pngData(width: 800, height: 600)
            let bytesB = try pngData(width: 400, height: 300)
            let network = AccountNetwork(account: "a", bytes: ["a": bytesA, "b": bytesB])
            let provider = AccountMediaProvider(account: "a",
                                                disk: DiskCache(directory: directory, byteLimit: 10 << 20),
                                                fetch: { try await network.fetch($0) })

            _ = try await provider.image(for: attrs, targetSize: size)
            _ = try await provider.image(for: attrs, targetSize: size)
            #expect(await network.calls == ["a"])
            #expect(await storedBytes(in: directory) == bytesA)

            await network.signIn("b")
            provider.use("b")
            _ = try await provider.image(for: attrs, targetSize: size)

            #expect(await network.calls == ["a", "b"])
            #expect(await storedBytes(in: directory) == bytesB)
        }
    }

    @Test("a removed account's images are purged and never served from cache")
    func removedAccountPurges() async throws {
        try await withTemporaryDirectory { directory in
            let network = AccountNetwork(account: "a", bytes: ["a": try pngData(width: 800, height: 600)])
            let provider = AccountMediaProvider(account: "a",
                                                disk: DiskCache(directory: directory, byteLimit: 10 << 20),
                                                fetch: { try await network.fetch($0) })
            _ = try await provider.image(for: attrs, targetSize: size)
            #expect(await storedBytes(in: directory) != nil)

            await network.signIn(nil)
            provider.use(nil)

            // A cache hit would succeed; only a fetch can fail.
            await #expect(throws: SignedOut.self) {
                _ = try await provider.image(for: attrs, targetSize: size)
            }
            #expect(await network.calls == ["a"])
            #expect(await storedBytes(in: directory) == nil)
        }
    }

    @Test("a download the previous account was still loading is never written to disk")
    func inFlightLoadDropped() async throws {
        try await withTemporaryDirectory { directory in
            let bytesB = try pngData(width: 400, height: 300)
            let network = AccountNetwork(account: "a",
                                         bytes: ["a": try pngData(width: 800, height: 600), "b": bytesB])
            await network.delay("a", by: .milliseconds(300))
            let provider = AccountMediaProvider(account: "a",
                                                disk: DiskCache(directory: directory, byteLimit: 10 << 20),
                                                fetch: { try await network.fetch($0) })

            let loadA = Task { try await provider.image(for: attrs, targetSize: size) }
            while await network.calls.isEmpty {
                await Task.yield()
            }
            await network.signIn("b")
            provider.use("b")

            // A's download lands after the purge: it answers its own request
            // but is not stored.
            _ = try await loadA.value
            #expect(await storedBytes(in: directory) == nil)

            _ = try await provider.image(for: attrs, targetSize: size)
            #expect(await network.calls == ["a", "b"])
            #expect(await storedBytes(in: directory) == bytesB)
        }
    }
}
