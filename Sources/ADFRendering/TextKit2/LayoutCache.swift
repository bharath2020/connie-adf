#if canImport(UIKit)
import UIKit

/// Bounded width → layout memo (least recently used evicted first).
struct LayoutCache {
    static let capacity = 4
    private var entries: [(width: CGFloat, result: TextKit2LayoutResult)] = []

    var keys: [CGFloat] { entries.map(\.width) }

    /// The most recently used result matching `predicate`.
    func mostRecent(where predicate: (TextKit2LayoutResult) -> Bool) -> TextKit2LayoutResult? {
        entries.last { predicate($0.result) }?.result
    }

    mutating func value(for width: CGFloat) -> TextKit2LayoutResult? {
        guard let index = entries.firstIndex(where: { $0.width == width }) else { return nil }
        let entry = entries.remove(at: index)
        entries.append(entry)
        return entry.result
    }

    mutating func insert(_ result: TextKit2LayoutResult, for width: CGFloat) {
        entries.removeAll { $0.width == width }
        entries.append((width, result))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: true)
    }
}
#endif
