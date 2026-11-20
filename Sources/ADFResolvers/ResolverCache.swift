/// A store of resolved values by key, consulted before a fetch
/// (`CacheFirstLoader`). Implementations must be safe to call from any
/// task. A cache may drop values at any time (a memory limit or memory
/// pressure); a dropped value is fetched again on its next request.
public protocol ResolverCache<Key, Value>: Sendable {
    associatedtype Key: Hashable & Sendable
    associatedtype Value: Sendable

    /// The stored value for `key`, or `nil` when there is none.
    func value(for key: Key) async -> Value?

    /// Stores `value` for `key`, replacing any value already there.
    func store(_ value: Value, for key: Key) async
}
