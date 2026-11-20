/// Loads values cache first: a cache hit returns at once; a miss joins the
/// fetch already running for the key, or starts one, and stores the value
/// it returns. Failures are not stored, so the next request fetches again.
///
/// Composed loaders chain: a memory loader whose fetch is a disk loader,
/// whose fetch is the network, gives memory → disk → network with one type.
public actor CacheFirstLoader<Key: Hashable & Sendable, Value: Sendable> {
    private let cache: any ResolverCache<Key, Value>
    private let fetch: @Sendable (Key) async throws -> Value

    /// One running fetch per key, with the requests waiting on it.
    private var flights: [Key: Flight] = [:]
    private var nextFlightID: UInt64 = 0

    private struct Flight {
        let id: UInt64
        var task: Task<Void, Never>?
        var waiters: [UInt64: CheckedContinuation<Value, any Error>] = [:]
    }

    private var nextWaiterID: UInt64 = 0

    /// - Parameters:
    ///   - cache: Checked before each fetch, and given each fetched value.
    ///   - fetch: Loads the value for a key that is not in `cache`. Called
    ///     at most once at a time per key, off this actor. It is cancelled
    ///     when every request waiting on it is cancelled, so it should
    ///     honour task cancellation.
    public init(cache: any ResolverCache<Key, Value>,
                fetch: @escaping @Sendable (Key) async throws -> Value) {
        self.cache = cache
        self.fetch = fetch
    }

    /// The value for `key`. Cache hit: returns at once. Miss: joins the
    /// in-flight fetch for the key, or starts one, then stores the value.
    /// Cancelling this request ends it at once with `CancellationError`;
    /// the fetch is cancelled only when its last waiting request cancels.
    public func value(for key: Key) async throws -> Value {
        if let cached = await cache.value(for: key) {
            return cached
        }
        nextWaiterID &+= 1
        let waiterID = nextWaiterID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                join(key: key, waiterID: waiterID, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(key: key, waiterID: waiterID) }
        }
    }

    /// Adds a request to the key's flight, starting the flight if none is
    /// running. Runs on the actor with no suspension between the cache miss
    /// check's return and here, so concurrent misses share one flight.
    private func join(key: Key,
                      waiterID: UInt64,
                      continuation: CheckedContinuation<Value, any Error>) {
        // Cancelled before it could wait (the cancellation handler then
        // finds no waiter and does nothing).
        if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
            return
        }
        var flight = flights[key] ?? startFlight(for: key)
        flight.waiters[waiterID] = continuation
        flights[key] = flight
    }

    private func startFlight(for key: Key) -> Flight {
        nextFlightID &+= 1
        let flightID = nextFlightID
        let cache = cache
        let fetch = fetch
        let task = Task {
            let result: Result<Value, any Error>
            do {
                let value = try await fetch(key)
                // Stored before any waiter resumes, so a request made once
                // this one returns is a cache hit.
                await cache.store(value, for: key)
                result = .success(value)
            } catch {
                result = .failure(error)
            }
            // The task inherits this actor, so it finishes the flight here.
            self.finish(key: key, flightID: flightID, result: result)
        }
        return Flight(id: flightID, task: task)
    }

    private func finish(key: Key, flightID: UInt64, result: Result<Value, any Error>) {
        // A flight whose waiters all cancelled was removed already; a newer
        // flight for the same key may be running and is left alone.
        guard let flight = flights[key], flight.id == flightID else { return }
        flights[key] = nil
        for continuation in flight.waiters.values {
            continuation.resume(with: result)
        }
    }

    /// The requests waiting on the key's running fetch (tests).
    func waiterCount(for key: Key) -> Int {
        flights[key]?.waiters.count ?? 0
    }

    private func cancelWaiter(key: Key, waiterID: UInt64) {
        guard var flight = flights[key],
              let continuation = flight.waiters.removeValue(forKey: waiterID) else { return }
        continuation.resume(throwing: CancellationError())
        if flight.waiters.isEmpty {
            flight.task?.cancel()
            flights[key] = nil
        } else {
            flights[key] = flight
        }
    }
}
