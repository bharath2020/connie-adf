#if canImport(UIKit)
import Foundation
import SwiftUI
import UIKit
import Testing
import ADFModel
import ADFPreparation
@testable import ADFRendering

// Open expand bodies on both renderers (PR 4 plan §4.5): the body is
// prepared on demand by the expand's own `.task` (driven by the body being
// shown, never by the renderer), cancelled without a partial publish, and
// prepared again after a real collapse; a replacement document closes the
// expand; and whatever body a same-ID replacement leaves on screen, the two
// renderers draw the same one.
//
// Body preparations are counted by a plugin installed on the model
// (`ExpandBodyMarker`): each body holds two `blockCard` markers that it
// claims, so every preparation of the body (the view's, and the search
// indexer's, which prepares every expand body once when its item is
// indexed) calls the claim once per marker. The test lets the indexer
// finish first and counts from there. The first marker can hold its claim
// (`ExpandBodyProbe.hold`), which keeps a preparation pending at a known
// point, after the body's first paragraph; the second marker's view
// reports when it is on screen, so a body counts as published once its
// last marker appears. A publish needs a finished preparation, so one
// preparation started and the body on screen is exactly one publish.
//
// Every case runs on both arms (SwiftUI first, then TextKit 2, each in its
// own window and model). Before iOS 26 container text stays on SwiftUI
// (`TextKit2Eligibility.containerTextMatchesText`): the TextKit 2 arm then
// expects no body row.

/// What the expand-body markers saw: claims per marker (one per
/// preparation of the body holding it), claims held at the marker, and
/// which markers' views are on screen.
final class ExpandBodyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed: [String: Int] = [:]
    private var returned: [String: Int] = [:]
    private var held: Set<String> = []
    private var waiting: [String: Int] = [:]
    private var shown: [String: Int] = [:]

    /// Called from the claim, off the main actor: counts it and, while the
    /// marker is held, blocks the preparation there (at most 20 s, so a
    /// failing test cannot hang the runner).
    func claim(_ key: String) {
        lock.withLock { claimed[key, default: 0] += 1 }
        let deadline = Date().addingTimeInterval(20)
        var counted = false
        while lock.withLock({ held.contains(key) }), Date() < deadline {
            if !counted {
                lock.withLock { waiting[key, default: 0] += 1 }
                counted = true
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
        lock.withLock {
            if counted { waiting[key, default: 0] -= 1 }
            returned[key, default: 0] += 1
        }
    }

    func hold(_ key: String) { lock.withLock { _ = held.insert(key) } }
    func release(_ key: String) { lock.withLock { _ = held.remove(key) } }
    func claims(_ key: String) -> Int { lock.withLock { claimed[key, default: 0] } }
    func returns(_ key: String) -> Int { lock.withLock { returned[key, default: 0] } }
    /// Preparations blocked at `key` right now.
    func pending(_ key: String) -> Int { lock.withLock { waiting[key, default: 0] } }

    func appeared(_ key: String) { lock.withLock { shown[key, default: 0] += 1 } }
    func disappeared(_ key: String) { lock.withLock { shown[key, default: 0] -= 1 } }
    func isShown(_ key: String) -> Bool { lock.withLock { shown[key, default: 0] > 0 } }
}

/// The counting plugin: claims a `blockCard` whose URL starts
/// `expand-probe:` (the rest is the marker's key) and draws the key as
/// plain SwiftUI text that reports when it is on screen.
struct ExpandBodyMarker: ADFCustomBlockRenderer {
    let rendererID = "test.expand-body.marker"
    let probe: ExpandBodyProbe

    func claim(for node: ADFNode) -> ADFCustomBlockClaim? {
        guard case .blockCard(let url, _) = node.kind, let url, url.hasPrefix("expand-probe:") else { return nil }
        let key = String(url.dropFirst("expand-probe:".count))
        probe.claim(key)
        return ADFCustomBlockClaim(key, sizing: .reflowingText)
    }

    @MainActor
    func content(for value: String, context: ADFCustomBlockContext) -> some View {
        let probe = probe
        return Text("Marker \(value)")
            .onAppear { probe.appeared(value) }
            .onDisappear { probe.disappeared(value) }
    }
}

/// Documents, hosting and waiting for the expand-body suites. Not a suite.
@MainActor
enum TK2ExpandBody {
    /// The expand's id and its body's text owners.
    static let expandID = "0.1"
    static let bodyOwners = ["0.1.0", "0.1.2"]

    static func paragraph(_ text: String) -> String {
        "{\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"\(text)\"}]}"
    }

    static func marker(_ key: String) -> String {
        "{\"type\":\"blockCard\",\"attrs\":{\"url\":\"expand-probe:\(key)\"}}"
    }

    /// The first body paragraph of `version`'s expand.
    static func first(_ version: String) -> String {
        "\(version)-FIRST body paragraph, long enough to wrap onto a second line at phone width in the open expand."
    }

    static func second(_ version: String) -> String { "\(version)-SECOND body paragraph." }

    /// A root paragraph (`0.0`), the expand (`0.1`: paragraph `0.1.0`, the
    /// held marker `<version>-hold` `0.1.1`, paragraph `0.1.2`, the end
    /// marker `<version>-end` `0.1.3`) and a root paragraph (`0.2`). Two
    /// versions share every id and differ in their body text and markers.
    static func json(_ version: String) -> Data {
        let body = [paragraph(first(version)), marker("\(version)-hold"), paragraph(second(version)), marker("\(version)-end")]
        let expand = "{\"type\":\"expand\",\"attrs\":{\"title\":\"Probe expand\"},\"content\":[\(body.joined(separator: ","))]}"
        let content = [paragraph("Root paragraph before the expand."), expand, paragraph("Root paragraph after the expand.")]
        return Data("{\"version\":1,\"type\":\"doc\",\"content\":[\(content.joined(separator: ","))]}".utf8)
    }

    /// The body text the SwiftUI path draws for `version`, by owner: the
    /// plain text of each prepared body paragraph.
    static func expectedTexts(_ version: String) -> [String: String] {
        ["0.1.0": first(version), "0.1.2": second(version)]
    }

    static func document(_ model: ADFDocumentModel, _ arm: ADFTextRenderer) -> some View {
        ADFDocumentView(model: model, mediaProvider: TextKit2DiagnosticsTests.NoMedia(), textRenderer: arm)
    }

    /// Polls `condition` every 10 ms with a layout pass, up to `timeout`.
    static func wait(_ what: String, timeout: Double = 10, in window: UIWindow? = nil, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw TestFailure("timed out after \(timeout) s waiting for \(what)") }
            window?.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A loaded model with the counting plugin whose search index has
    /// prepared `version`'s body (once per marker).
    static func loaded(_ version: String, probe: ExpandBodyProbe) async throws -> ADFDocumentModel {
        let model = ADFDocumentModel(customRenderers: [ExpandBodyMarker(probe: probe)])
        model.load(data: json(version))
        try await wait("READY") { model.phase == .ready }
        try await indexed(version, probe: probe, model: model)
        return model
    }

    /// Waits for the search indexer's preparation of `version`'s body.
    static func indexed(_ version: String, probe: ExpandBodyProbe, model: ADFDocumentModel) async throws {
        try await wait("the indexer's preparation of the \(version) body") {
            probe.claims("\(version)-hold") >= 1 && probe.claims("\(version)-end") >= 1
        }
        #expect(probe.claims("\(version)-hold") == 1 && probe.claims("\(version)-end") == 1, "one index preparation of \(version)")
    }

    /// The hosted document view.
    static func host(_ model: ADFDocumentModel, _ arm: ADFTextRenderer) async throws -> TK2CodeLogic.Hosted {
        let hosted = TK2CodeLogic.Hosted(document(model, arm), size: CGSize(width: 390, height: 1_600))
        try await hosted.settle()
        return hosted
    }

    /// The body owners this window draws on TextKit 2, with their labels;
    /// `checking` also expects each owner once and in container context.
    static func bodyRows(_ hosted: TK2CodeLogic.Hosted, checking: Bool = true) -> [String: String] {
        var rows: [String: String] = [:]
        for row in hosted.rows {
            guard let owner = row.ownerID, owner.hasPrefix(expandID + ".") else { continue }
            if checking {
                #expect(rows[owner] == nil, "\(owner) drawn twice")
                #expect(row.containerContext == .container, "\(owner): an expand body row is container text")
            }
            rows[owner] = row.accessibilityLabel ?? ""
        }
        return rows
    }

    /// The body rows `arm` must show for `version`'s body on screen.
    static func expectedRows(_ version: String, _ arm: ADFTextRenderer) -> [String: String] {
        arm == .textKit2 && TextKit2Eligibility.containerTextMatchesText ? expectedTexts(version) : [:]
    }

    /// Waits until `version`'s body is published and drawn by `arm`.
    static func waitForBody(_ version: String, _ hosted: TK2CodeLogic.Hosted, _ arm: ADFTextRenderer, probe: ExpandBodyProbe) async throws {
        try await wait("the \(version) body on screen", in: hosted.window) {
            probe.isShown("\(version)-end") && bodyRows(hosted, checking: false).count == expectedRows(version, arm).count
        }
        try await hosted.settle()
    }

    /// The version whose body is on screen ("OLD", "NEW", "both" or "none").
    static func shownVersion(_ probe: ExpandBodyProbe) -> String {
        switch (probe.isShown("OLD-end"), probe.isShown("NEW-end")) {
        case (true, false): return "OLD"
        case (false, true): return "NEW"
        case (true, true): return "both"
        case (false, false): return "none"
        }
    }

    nonisolated static let arms: [ADFTextRenderer] = [.swiftUI, .textKit2]
}

@Suite("TextKit 2 expand bodies", .serialized)
@MainActor
struct TextKit2ExpandBodyTests {
    typealias X = TK2ExpandBody

    @Test("1: a renderer flip while the body's preparation is pending starts no preparation: one preparation, one publish, drawn by the new arm",
          arguments: X.arms)
    func flipWhilePending(start: ADFTextRenderer) async throws {
        let probe = ExpandBodyProbe()
        let model = try await X.loaded("OLD", probe: probe)
        let hosted = try await X.host(model, start)
        defer { hosted.close() }
        let other: ADFTextRenderer = start == .swiftUI ? .textKit2 : .swiftUI

        probe.hold("OLD-hold")
        defer { probe.release("OLD-hold") }
        model.expandedBlocks.insert(X.expandID)
        try await X.wait("the view's preparation to reach the held marker", in: hosted.window) { probe.pending("OLD-hold") == 1 }
        #expect(probe.claims("OLD-hold") == 2, "the index's preparation and the view's")

        // The flip: an environment change on the same views.
        hosted.show(X.document(model, other))
        try await hosted.settle()
        try await hosted.settle()
        #expect(probe.claims("OLD-hold") == 2, "the flip started a preparation")
        #expect(probe.pending("OLD-hold") == 1, "the pending preparation is still the only one")
        #expect(!probe.isShown("OLD-end"), "nothing published while pending")
        #expect(X.bodyRows(hosted).isEmpty, "no body row while pending")

        probe.release("OLD-hold")
        try await X.waitForBody("OLD", hosted, other, probe: probe)
        #expect(probe.claims("OLD-hold") == 2 && probe.claims("OLD-end") == 2, "one view preparation in all")
        #expect(X.bodyRows(hosted) == X.expectedRows("OLD", other), "\(other): \(X.bodyRows(hosted))")

        // A flip back with the body open re-renders the leaves only.
        hosted.show(X.document(model, start))
        try await hosted.settle()
        try await hosted.settle()
        #expect(probe.claims("OLD-hold") == 2 && probe.claims("OLD-end") == 2, "a flip with the body open started a preparation")
        #expect(probe.isShown("OLD-end"))
        #expect(X.bodyRows(hosted) == X.expectedRows("OLD", start), "\(start): \(X.bodyRows(hosted))")
        #expect(model.expandedBlocks == [X.expandID])
    }

    @Test("2: closing, or the row being released, while the preparation is pending publishes nothing; the next open prepares again and shows the whole body",
          arguments: X.arms)
    func collapseWhilePending(arm: ADFTextRenderer) async throws {
        for path in ["close and reopen", "row released and rebuilt"] {
            let probe = ExpandBodyProbe()
            let model = try await X.loaded("OLD", probe: probe)
            let hosted = try await X.host(model, arm)
            defer { hosted.close() }

            probe.hold("OLD-hold")
            defer { probe.release("OLD-hold") }
            model.expandedBlocks.insert(X.expandID)
            try await X.wait("\(path): the view's preparation to reach the held marker", in: hosted.window) { probe.pending("OLD-hold") == 1 }

            if path == "close and reopen" {
                model.expandedBlocks.remove(X.expandID)
            } else {
                // The lazy stack releasing the row: its views go, the model
                // keeps the expand open.
                hosted.show(EmptyView())
            }
            try await hosted.settle()
            // The cancelled preparation finishes its held claim and stops.
            probe.release("OLD-hold")
            try await X.wait("\(path): the cancelled preparation to return", in: hosted.window) { probe.returns("OLD-hold") == 2 }
            try await hosted.settle()
            try await hosted.settle()
            #expect(!probe.isShown("OLD-end"), "\(path): nothing published")
            #expect(probe.claims("OLD-end") == 1, "\(path): the cancelled preparation stopped before the end marker")

            if path == "close and reopen" {
                model.expandedBlocks.insert(X.expandID)
            } else {
                #expect(model.expandedBlocks == [X.expandID], "the open state lives on the model")
                hosted.show(X.document(model, arm))
            }
            try await X.waitForBody("OLD", hosted, arm, probe: probe)
            // A third preparation: the cancelled one left no body behind
            // (a cached partial body would have skipped it).
            #expect(probe.claims("OLD-hold") == 3 && probe.claims("OLD-end") == 2, "\(path): \(probe.claims("OLD-hold")) / \(probe.claims("OLD-end"))")
            #expect(X.bodyRows(hosted) == X.expectedRows("OLD", arm), "\(path) \(arm): \(X.bodyRows(hosted))")
        }
    }

    @Test("3: a replacement document reusing every id (load) closes the expand; reopening prepares and shows the new body",
          arguments: X.arms)
    func replacementDocumentClosesTheExpand(arm: ADFTextRenderer) async throws {
        let probe = ExpandBodyProbe()
        let model = try await X.loaded("OLD", probe: probe)
        let hosted = try await X.host(model, arm)
        defer { hosted.close() }
        model.expandedBlocks.insert(X.expandID)
        try await X.waitForBody("OLD", hosted, arm, probe: probe)
        #expect(X.bodyRows(hosted) == X.expectedRows("OLD", arm))

        model.load(data: X.json("NEW"))
        try await X.wait("READY") { model.phase == .ready }
        try await X.indexed("NEW", probe: probe, model: model)
        try await hosted.settle()
        try await hosted.settle()
        #expect(model.expandedBlocks.isEmpty, "load closes every expand")
        #expect(X.shownVersion(probe) == "none", "a closed expand shows no body: \(X.shownVersion(probe))")
        #expect(X.bodyRows(hosted).isEmpty, "\(X.bodyRows(hosted))")

        model.expandedBlocks.insert(X.expandID)
        try await X.waitForBody("NEW", hosted, arm, probe: probe)
        #expect(X.shownVersion(probe) == "NEW")
        #expect(probe.claims("NEW-end") == 2, "the index's and the view's preparation of the new body")
        #expect(X.bodyRows(hosted) == X.expectedRows("NEW", arm), "\(arm): \(X.bodyRows(hosted))")
    }

    /// A same-id replacement (`apply(.replace)`) of the open expand, after
    /// its body was published (`pending` false) or while its preparation
    /// is held (`pending` true). Returns the window, its probe and model.
    static func sameIDReplace(_ arm: ADFTextRenderer, pending: Bool) async throws -> (TK2CodeLogic.Hosted, ExpandBodyProbe, ADFDocumentModel) {
        let probe = ExpandBodyProbe()
        let model = try await X.loaded("OLD", probe: probe)
        let hosted = try await X.host(model, arm)
        if pending { probe.hold("OLD-hold") }
        model.expandedBlocks.insert(X.expandID)
        if pending {
            try await X.wait("the view's preparation to reach the held marker", in: hosted.window) { probe.pending("OLD-hold") == 1 }
        } else {
            try await X.waitForBody("OLD", hosted, arm, probe: probe)
        }
        let prepared = try await TK2CodeLogic.prepared(X.json("NEW"))
        let replacement = try #require(prepared.first(where: { $0.id == X.expandID }))
        try await model.apply([.replace(itemID: X.expandID, block: replacement)], revision: 1)
        try await X.indexed("NEW", probe: probe, model: model)
        if pending {
            probe.release("OLD-hold")
            try await X.wait("the held preparation to finish", in: hosted.window) { probe.returns("OLD-hold") == 2 }
        }
        try await X.wait("a body on screen", in: hosted.window) { X.shownVersion(probe) != "none" }
        try await hosted.settle()
        try await hosted.settle()
        #expect(model.expandedBlocks == [X.expandID], "a same-id replacement keeps the expand open")
        return (hosted, probe, model)
    }

    /// The baseline defect of plan §4.5 (f23): the prepared body is view
    /// state filled once by a task with no identity, so a same-id
    /// replacement of an open expand keeps the old body on screen, on main
    /// and on both renderers. PR 4 does not fix it: the stale-body defect
    /// is a follow-up listed in the PR 4 description (lead call C31). A fix
    /// makes this known issue pass and the test fail, on purpose.
    @Test("4 (known issue): a same-id replacement of an open, prepared expand, or of one whose preparation is pending, shows the new body",
          arguments: X.arms)
    func sameIDReplacementShowsTheNewBody(arm: ADFTextRenderer) async throws {
        for pending in [false, true] {
            let (hosted, probe, _) = try await Self.sameIDReplace(arm, pending: pending)
            defer { hosted.close() }
            let shown = X.shownVersion(probe)
            let rows = X.bodyRows(hosted)
            withKnownIssue("stale expand body after a same-id replacement: a baseline defect, a follow-up in the PR 4 description (lead call C31)") {
                #expect(shown == "NEW", "\(arm) pending=\(pending): the \(shown) body is on screen")
                #expect(rows == X.expectedRows("NEW", arm), "\(arm) pending=\(pending): \(rows)")
            }
        }
    }

    @Test("5: after a same-id replacement the two renderers draw the same body, stale or fresh: TextKit 2's body rows are the SwiftUI arm's text, owner by owner")
    func renderersAgreeAfterSameIDReplacement() async throws {
        for pending in [false, true] {
            var shown: [ADFTextRenderer: String] = [:]
            var rows: [ADFTextRenderer: [String: String]] = [:]
            for arm in X.arms {
                let (hosted, probe, _) = try await Self.sameIDReplace(arm, pending: pending)
                shown[arm] = X.shownVersion(probe)
                rows[arm] = X.bodyRows(hosted)
                hosted.close()
            }
            let swiftUI = try #require(shown[.swiftUI]), textKit2 = try #require(shown[.textKit2])
            #expect(["OLD", "NEW"].contains(swiftUI), "pending=\(pending): SwiftUI shows \(swiftUI)")
            #expect(textKit2 == swiftUI, "pending=\(pending): TextKit 2 shows the \(textKit2) body, SwiftUI the \(swiftUI) one")
            #expect(rows[.swiftUI]?.isEmpty == true, "pending=\(pending): a TextKit 2 row on the SwiftUI arm")
            // Each `tk2-row:<id>` label is the text SwiftUI draws for that
            // block in the body both arms show.
            #expect(rows[.textKit2] == X.expectedRows(swiftUI, .textKit2), "pending=\(pending): \(rows[.textKit2] ?? [:]) against the \(swiftUI) body")
            print("EXPAND_SAME_ID pending=\(pending) swiftUI=\(swiftUI) textKit2=\(textKit2) rows=\((rows[.textKit2] ?? [:]).keys.sorted())")
        }
    }
}
#endif
