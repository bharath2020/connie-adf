import Foundation
import Testing
@testable import ADFRendering
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@Suite("RowGeometryRegistry") @MainActor
struct RowGeometryRegistryTests {
    private func view(y: CGFloat, h: CGFloat) -> ADFPlatformView {
        let v = ADFPlatformView(frame: CGRect(x: 0, y: y, width: 300, height: h)); return v
    }

    // NOTE: the registry stores views WEAKLY (by design — it never owns a
    // row's lifetime). A view passed straight into `register(...)` as a bare
    // argument expression has no other owner, so ARC releases it the instant
    // the call returns — verified empirically (a throwaway ARC probe showed
    // an unnamed temporary gone immediately after the call that registered
    // it, while a `let`-bound local in the same scope survived). Every view
    // this suite needs to stay live through its assertions is therefore
    // bound to a named local kept in scope; `evictsCollapsedRows` still uses
    // the inline/`do`-scoped form deliberately, to force early deallocation.
    @Test func keepsDocumentOrderRegardlessOfRegistrationOrder() {
        let r = RowGeometryRegistry()
        r.orderOf = { ["a": 0, "b": 1, "c": 2][$0] ?? .max }
        let cView = view(y: 200, h: 20)
        let aView = view(y: 0, h: 20)
        let bView = view(y: 100, h: 20)
        r.register(ownerID: "c", view: cView)   // registered first
        r.register(ownerID: "a", view: aView)
        r.register(ownerID: "b", view: bView)
        let live = r.liveEntries(orderRange: 0...2).map(\.ownerID)
        #expect(live == ["a", "b", "c"])
    }

    @Test func evictsCollapsedRows() {
        let r = RowGeometryRegistry()
        r.orderOf = { $0 == "a" ? 0 : 1 }
        do { let v = view(y: 0, h: 20); r.register(ownerID: "a", view: v) }  // v deallocs
        let bView = view(y: 40, h: 20)
        r.register(ownerID: "b", view: bView)
        #expect(r.liveEntries(orderRange: 0...1).map(\.ownerID) == ["b"])
    }

    @Test func nearestLiveBracketsAGap() {
        let r = RowGeometryRegistry()
        r.orderOf = { ["a": 0, "z": 9][$0] ?? .max }
        let aView = view(y: 0, h: 20)     // maxY 20
        let zView = view(y: 500, h: 20)   // minY 500
        r.register(ownerID: "a", view: aView)
        r.register(ownerID: "z", view: zView)
        let (below, above) = r.nearestLive(toY: 250) { $0.frame }
        #expect(above?.ownerID == "a")
        #expect(below?.ownerID == "z")
    }
}
