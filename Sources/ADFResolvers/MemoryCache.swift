import Foundation

/// An in-memory `ResolverCache` backed by `NSCache`: bounded by a count
/// and a total cost, and emptied by the system under memory pressure.
public final class MemoryCache<Key: Hashable & Sendable, Value: Sendable>: ResolverCache, @unchecked Sendable {
    // `@unchecked`: the only state is the `NSCache`, which is thread-safe,
    // and the `let` cost function, which is `@Sendable`.

    private let storage = NSCache<KeyBox, ValueBox>()
    private let cost: @Sendable (Value) -> Int

    /// - Parameters:
    ///   - countLimit: The most values kept; `0` means no count limit.
    ///   - totalCostLimit: The most total cost kept, by `cost`; `0` means
    ///     no cost limit.
    ///   - cost: The cost of one value, for example its decoded byte size.
    ///     Each value costs `1` by default.
    public init(countLimit: Int = 0,
                totalCostLimit: Int = 0,
                cost: @escaping @Sendable (Value) -> Int = { _ in 1 }) {
        storage.countLimit = countLimit
        storage.totalCostLimit = totalCostLimit
        self.cost = cost
    }

    public func value(for key: Key) async -> Value? {
        storage.object(forKey: KeyBox(key))?.value
    }

    public func store(_ value: Value, for key: Key) async {
        storage.setObject(ValueBox(value), forKey: KeyBox(key), cost: cost(value))
    }

    /// Wraps a `Hashable` key for `NSCache`, which compares keys with
    /// `isEqual(_:)` and `hash`.
    private final class KeyBox: NSObject {
        let key: Key

        init(_ key: Key) {
            self.key = key
        }

        override var hash: Int {
            key.hashValue
        }

        override func isEqual(_ object: Any?) -> Bool {
            (object as? KeyBox)?.key == key
        }
    }

    private final class ValueBox {
        let value: Value

        init(_ value: Value) {
            self.value = value
        }
    }
}
