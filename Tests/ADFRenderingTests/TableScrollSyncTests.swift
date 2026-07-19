import CoreGraphics
import Testing
@testable import ADFRendering

/// The registry's pure bookkeeping: offset publication, the feedback-guard
/// dedup, and reference-counted eviction. The scroll-view wiring itself is
/// covered by the on-simulator sync test.
@MainActor
struct TableScrollSyncTests {
    @Test("a published offset is readable by other slices of the same table")
    func publishAndRead() {
        let sync = TableScrollSync()
        sync.retain("t0")
        #expect(sync.sharedOffset(for: "t0") == nil)

        sync.publish(120, for: "t0")
        #expect(sync.sharedOffset(for: "t0") == 120)
    }

    @Test("offsets are keyed per table, never shared across tables")
    func perTableIsolation() {
        let sync = TableScrollSync()
        sync.retain("t0")
        sync.retain("t1")
        sync.publish(200, for: "t0")

        #expect(sync.sharedOffset(for: "t0") == 200)
        #expect(sync.sharedOffset(for: "t1") == nil)
    }

    @Test("sub-half-point moves are dropped so idle tables don't churn")
    func dedupTinyMoves() {
        let sync = TableScrollSync()
        sync.retain("t0")
        sync.publish(100, for: "t0")
        sync.publish(100.3, for: "t0")
        #expect(sync.sharedOffset(for: "t0") == 100)

        sync.publish(101, for: "t0")
        #expect(sync.sharedOffset(for: "t0") == 101)
    }

    @Test("the offset survives while any slice of the table stays live")
    func offsetSurvivesPartialRelease() {
        let sync = TableScrollSync()
        sync.retain("t0") // header slice
        sync.retain("t0") // a data slice
        sync.publish(150, for: "t0")

        sync.release("t0") // the data slice scrolls away
        #expect(sync.sharedOffset(for: "t0") == 150)
    }

    @Test("the offset is dropped once the last slice leaves memory")
    func offsetEvictedOnLastRelease() {
        let sync = TableScrollSync()
        sync.retain("t0")
        sync.retain("t0")
        sync.publish(150, for: "t0")

        sync.release("t0")
        sync.release("t0")
        #expect(sync.sharedOffset(for: "t0") == nil)
    }

    @Test("onOffsetChanged fires on a recorded publish, with the table ID and offset, but not on a deduped move")
    func onOffsetChangedFiresOnlyOnRecordedPublishes() {
        // Task 22 geometry-staleness coalescing: the selection controller
        // hooks this plain callback instead of reading `offsets` via
        // `Observation`, so h-scroll panning never grows an observable-read
        // dependency on its part.
        let sync = TableScrollSync()
        sync.retain("t0")
        var received: [(String, CGFloat)] = []
        sync.onOffsetChanged = { tableID, offset in received.append((tableID, offset)) }

        sync.publish(120, for: "t0")
        #expect(received.count == 1)
        #expect(received[0].0 == "t0")
        #expect(received[0].1 == 120)

        sync.publish(120.3, for: "t0") // sub-half-point move — deduped, no callback
        #expect(received.count == 1)

        sync.publish(121, for: "t0")
        #expect(received.count == 2)
        #expect(received[1].1 == 121)
    }

    @Test("an unbalanced release never underflows or evicts a live table")
    func unbalancedReleaseIsSafe() {
        let sync = TableScrollSync()
        sync.release("t0") // never retained — must be a no-op

        sync.retain("t0")
        sync.publish(90, for: "t0")
        sync.release("t0")
        sync.release("t0") // extra release past zero
        #expect(sync.sharedOffset(for: "t0") == nil)

        sync.retain("t0")
        #expect(sync.sharedOffset(for: "t0") == nil)
    }
}
