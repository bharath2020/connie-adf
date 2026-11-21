import Foundation
import Testing
@testable import ADFResolvers

/// A fresh directory under the temporary directory, deleted when the test
/// body returns.
private func withTemporaryDirectory(_ body: (URL) async throws -> Void) async rethrows {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DiskCacheTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory)
}

private func bytes(_ count: Int, _ fill: UInt8) -> Data {
    Data(repeating: fill, count: count)
}

@Suite("DiskCache")
struct DiskCacheTests {
    @Test("stores and reads back bytes by key")
    func roundTrip() async {
        await withTemporaryDirectory { directory in
            let cache = DiskCache(directory: directory, byteLimit: 1_000)
            #expect(await cache.value(for: "a") == nil)

            await cache.store(bytes(10, 1), for: "a")
            await cache.store(bytes(20, 2), for: "b")
            await cache.store(bytes(30, 3), for: "a")

            #expect(await cache.value(for: "a") == bytes(30, 3))
            #expect(await cache.value(for: "b") == bytes(20, 2))
            #expect(await cache.totalBytes == 50)
        }
    }

    @Test("a conditional store writes only when its check passes")
    func conditionalStore() async {
        await withTemporaryDirectory { directory in
            let cache = DiskCache(directory: directory, byteLimit: 1_000)

            await cache.store(bytes(10, 1), for: "a", if: { false })
            await cache.store(bytes(20, 2), for: "b", if: { true })

            #expect(await cache.value(for: "a") == nil)
            #expect(await cache.value(for: "b") == bytes(20, 2))
            #expect(await cache.totalBytes == 20)
        }
    }

    @Test("a new cache on the same directory finds the stored bytes")
    func survivesRelaunch() async {
        await withTemporaryDirectory { directory in
            let first = DiskCache(directory: directory, byteLimit: 1_000)
            await first.store(bytes(10, 1), for: "a")
            await first.store(bytes(20, 2), for: "b")

            let second = DiskCache(directory: directory, byteLimit: 1_000)
            #expect(await second.totalBytes == 30)
            #expect(await second.value(for: "a") == bytes(10, 1))
            #expect(await second.value(for: "b") == bytes(20, 2))
        }
    }

    @Test("going over the byte limit evicts the least recently used")
    func evictsLeastRecentlyUsed() async {
        await withTemporaryDirectory { directory in
            let cache = DiskCache(directory: directory, byteLimit: 250)
            await cache.store(bytes(100, 1), for: "a")
            await cache.store(bytes(100, 2), for: "b")
            // Reading A makes B the least recently used.
            #expect(await cache.value(for: "a") != nil)

            await cache.store(bytes(100, 3), for: "c")

            #expect(await cache.value(for: "b") == nil)
            #expect(await cache.value(for: "a") == bytes(100, 1))
            #expect(await cache.value(for: "c") == bytes(100, 3))
            #expect(await cache.totalBytes == 200)
        }
    }

    @Test("a value over the byte limit is not stored")
    func overLimitNotStored() async {
        await withTemporaryDirectory { directory in
            let cache = DiskCache(directory: directory, byteLimit: 100)
            await cache.store(bytes(50, 1), for: "a")

            await cache.store(bytes(101, 2), for: "big")

            #expect(await cache.value(for: "big") == nil)
            #expect(await cache.value(for: "a") == bytes(50, 1))
            #expect(await cache.totalBytes == 50)
        }
    }

    @Test("a file deleted behind the cache reads as a miss")
    func vanishedFile() async throws {
        try await withTemporaryDirectory { directory in
            let cache = DiskCache(directory: directory, byteLimit: 1_000)
            await cache.store(bytes(10, 1), for: "a")

            try FileManager.default.removeItem(at: directory.appendingPathComponent(DiskCache.fileName(for: "a")))

            #expect(await cache.value(for: "a") == nil)
            #expect(await cache.totalBytes == 0)
        }
    }

    @Test("removeAll deletes every stored file")
    func removeAll() async throws {
        try await withTemporaryDirectory { directory in
            let cache = DiskCache(directory: directory, byteLimit: 1_000)
            await cache.store(bytes(10, 1), for: "a")
            await cache.store(bytes(20, 2), for: "b")

            await cache.removeAll()

            #expect(await cache.value(for: "a") == nil)
            #expect(await cache.value(for: "b") == nil)
            #expect(await cache.totalBytes == 0)
            let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(files.isEmpty)
            #expect(await DiskCache(directory: directory, byteLimit: 1_000).totalBytes == 0)
        }
    }
}
