import Testing
@testable import ADFResolvers

/// A fetch the test drives: each call waits until the test releases it with
/// a value or an error, and records whether it saw cancellation.
private actor FetchGate {
    private(set) var calls: [String] = []
    private(set) var cancelledCalls = 0
    private var pending: [String: [CheckedContinuation<Int, any Error>]] = [:]

    func fetch(_ key: String) async throws -> Int {
        calls.append(key)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[key, default: []].append(continuation)
            }
        } onCancel: {
            Task { await self.cancel(key) }
        }
    }

    /// Ends every waiting call for `key` with `result`.
    func release(_ key: String, with result: Result<Int, any Error>) {
        for continuation in pending.removeValue(forKey: key) ?? [] {
            continuation.resume(with: result)
        }
    }

    func waitingCount(_ key: String) -> Int {
        pending[key]?.count ?? 0
    }

    private func cancel(_ key: String) {
        guard let waiting = pending.removeValue(forKey: key) else { return }
        cancelledCalls += waiting.count
        for continuation in waiting {
            continuation.resume(throwing: CancellationError())
        }
    }
}

private struct FetchFailed: Error {}

/// Polls until `condition` holds; fails the test after about ten seconds.
private func waitUntil(_ condition: () async -> Bool,
                       sourceLocation: SourceLocation = #_sourceLocation) async {
    for _ in 0..<2_000 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("condition never held", sourceLocation: sourceLocation)
}

@Suite("CacheFirstLoader")
struct CacheFirstLoaderTests {
    @Test("a cache hit returns the stored value without a fetch")
    func hit() async throws {
        let cache = MemoryCache<String, Int>()
        await cache.store(7, for: "a")
        let gate = FetchGate()
        let loader = CacheFirstLoader(cache: cache, fetch: { try await gate.fetch($0) })

        let value = try await loader.value(for: "a")

        #expect(value == 7)
        #expect(await gate.calls.isEmpty)
    }

    @Test("a miss fetches once, stores the value, and the next request hits")
    func miss() async throws {
        let cache = MemoryCache<String, Int>()
        let gate = FetchGate()
        let loader = CacheFirstLoader(cache: cache, fetch: { try await gate.fetch($0) })

        let request = Task { try await loader.value(for: "a") }
        await waitUntil { await gate.waitingCount("a") == 1 }
        await gate.release("a", with: .success(42))

        #expect(try await request.value == 42)
        #expect(await cache.value(for: "a") == 42)
        #expect(try await loader.value(for: "a") == 42)
        #expect(await gate.calls == ["a"])
    }

    @Test("concurrent misses for one key join the fetch in flight")
    func inFlightJoin() async throws {
        let gate = FetchGate()
        let loader = CacheFirstLoader(cache: MemoryCache<String, Int>(),
                                      fetch: { try await gate.fetch($0) })

        let first = Task { try await loader.value(for: "a") }
        let second = Task { try await loader.value(for: "a") }
        let other = Task { try await loader.value(for: "b") }
        await waitUntil { await loader.waiterCount(for: "a") == 2 }
        await waitUntil { await loader.waiterCount(for: "b") == 1 }
        #expect(await gate.waitingCount("a") == 1)
        await gate.release("a", with: .success(1))
        await gate.release("b", with: .success(2))

        #expect(try await first.value == 1)
        #expect(try await second.value == 1)
        #expect(try await other.value == 2)
        #expect(await gate.calls.sorted() == ["a", "b"])
    }

    @Test("cancelling one waiter keeps the fetch; cancelling the last cancels it")
    func lastWaiterCancel() async throws {
        let cache = MemoryCache<String, Int>()
        let gate = FetchGate()
        let loader = CacheFirstLoader(cache: cache, fetch: { try await gate.fetch($0) })

        let first = Task { try await loader.value(for: "a") }
        let second = Task { try await loader.value(for: "a") }
        await waitUntil { await loader.waiterCount(for: "a") == 2 }
        await waitUntil { await gate.waitingCount("a") == 1 }

        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await loader.waiterCount(for: "a") == 1)
        #expect(await gate.cancelledCalls == 0)
        #expect(await gate.waitingCount("a") == 1)

        second.cancel()
        await #expect(throws: CancellationError.self) { try await second.value }
        await waitUntil { await gate.cancelledCalls == 1 }
        #expect(await cache.value(for: "a") == nil)

        // The key is asked again on its next request.
        let third = Task { try await loader.value(for: "a") }
        await waitUntil { await gate.waitingCount("a") == 1 }
        await gate.release("a", with: .success(3))
        #expect(try await third.value == 3)
        #expect(await gate.calls == ["a", "a"])
    }

    @Test("a failed fetch reaches every waiter and is not stored")
    func failureNotStored() async throws {
        let cache = MemoryCache<String, Int>()
        let gate = FetchGate()
        let loader = CacheFirstLoader(cache: cache, fetch: { try await gate.fetch($0) })

        let first = Task { try await loader.value(for: "a") }
        let second = Task { try await loader.value(for: "a") }
        await waitUntil { await loader.waiterCount(for: "a") == 2 }
        await waitUntil { await gate.waitingCount("a") == 1 }
        await gate.release("a", with: .failure(FetchFailed()))

        await #expect(throws: FetchFailed.self) { try await first.value }
        await #expect(throws: FetchFailed.self) { try await second.value }
        #expect(await cache.value(for: "a") == nil)

        let retry = Task { try await loader.value(for: "a") }
        await waitUntil { await gate.waitingCount("a") == 1 }
        await gate.release("a", with: .success(5))
        #expect(try await retry.value == 5)
        #expect(await gate.calls == ["a", "a"])
    }
}

@Suite("MemoryCache")
struct MemoryCacheTests {
    @Test("stores and returns values by key")
    func storeAndRead() async {
        let cache = MemoryCache<String, Int>()
        #expect(await cache.value(for: "a") == nil)
        await cache.store(1, for: "a")
        await cache.store(2, for: "b")
        await cache.store(3, for: "a")
        #expect(await cache.value(for: "a") == 3)
        #expect(await cache.value(for: "b") == 2)
    }
}
