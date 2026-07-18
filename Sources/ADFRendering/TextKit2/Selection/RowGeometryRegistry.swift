import Foundation
#if canImport(UIKit)
import UIKit
public typealias ADFPlatformView = UIView
#elseif canImport(AppKit)
import AppKit
public typealias ADFPlatformView = NSView
#endif

/// Live TK2 rows, keyed by ownerID, kept in DOCUMENT ORDER for binary search.
/// A plain non-observed class (the `ScrollAnchorRegistry`/`VisibleRowRegistry`
/// pattern): rows register at `didMoveToWindow` and evict on collapse; writes
/// invalidate nothing. Queried ONLY during selection interactions — never on
/// the scroll path (spec §7).
@MainActor
public final class RowGeometryRegistry {
    /// Document order is supplied by the text model (built from
    /// `index.itemOrder`), NOT by registration order — a lazily-materialized
    /// row can register long after a later row. `orderOf` maps ownerID → its
    /// index in document order; the registry re-sorts its live entries by it.
    public var orderOf: (String) -> Int = { _ in .max }

    private struct Entry { let ownerID: String; weak var view: ADFPlatformView? }
    private var entries: [Entry] = []               // sorted by orderOf(ownerID)

    public init() {}

    public func register(ownerID: String, view: ADFPlatformView) {
        evictDead()
        entries.removeAll { $0.ownerID == ownerID }
        let entry = Entry(ownerID: ownerID, view: view)
        let idx = insertionIndex(forOrder: orderOf(ownerID))
        entries.insert(entry, at: idx)
    }

    public func unregister(ownerID: String) {
        entries.removeAll { $0.ownerID == ownerID || $0.view == nil }
    }

    public func liveView(for ownerID: String) -> ADFPlatformView? {
        entries.first { $0.ownerID == ownerID }?.view
    }

    /// Live rows whose ownerID sorts within `[lowerOrder, upperOrder]`, in
    /// document order — the candidate set for a selection range's rects. O(log
    /// n + k), never a scan of all-ever-registered entries.
    public func liveEntries(orderRange: ClosedRange<Int>) -> [(ownerID: String, view: ADFPlatformView)] {
        evictDead()
        return entries.compactMap { e in
            guard let v = e.view else { return nil }
            let o = orderOf(e.ownerID)
            return orderRange.contains(o) ? (e.ownerID, v) : nil
        }
    }

    /// The live row nearest (vertically) to a content-space point, plus the
    /// two live neighbors bracketing a gap — the inputs collapsed-row
    /// interpolation needs. `frameInContainer` converts each row to the
    /// container's coordinate space (the ancestor the controller attaches to).
    public func nearestLive(
        toY y: CGFloat, frameInContainer: (ADFPlatformView) -> CGRect
    ) -> (below: (ownerID: String, frame: CGRect)?, above: (ownerID: String, frame: CGRect)?) {
        evictDead()
        var above: (String, CGRect)?
        var below: (String, CGRect)?
        for e in entries {
            guard let v = e.view else { continue }
            let f = frameInContainer(v)
            if f.maxY <= y { above = (e.ownerID, f) }
            else if f.minY >= y, below == nil { below = (e.ownerID, f) }
        }
        return (below.map { ($0.0, $0.1) }, above.map { ($0.0, $0.1) })
    }

    private func insertionIndex(forOrder order: Int) -> Int {
        var lo = 0, hi = entries.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if orderOf(entries[mid].ownerID) < order { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func evictDead() { entries.removeAll { $0.view == nil } }
}
