#if canImport(UIKit)
import Foundation
import SwiftUI
import UIKit
import Testing
@testable import ADFRendering

// The cost of a tall eager expand body on TextKit 2 (PR 4 plan §8.5, M1 and
// M5): an open expand body is one eager stack mounted in one write, with no
// cap (planner decision P4), so its mount and its renderer flips are held
// to exact counts instead.
//
// The body is the `containers-expand` fixture's `CE-TALL` expand, alone in
// a document: exactly 300 plain paragraphs (`CE-TALL-001` … `CE-TALL-300`).
//
// The diagnostics counters are process-wide and other suites render rows in
// parallel, so a counter is compared exactly only across a span with no
// suspension in it (`TextKit2ListLayoutTests.counting`). The first open
// prepares the body off the main actor, so its conversions are read across
// suspensions (at least 300); the exact mount is the reopen, whose body is
// already prepared, and the two renderer round trips, all synchronous.
// Rows are this window's own instances; a row that converted again after a
// span would carry a new attributed string, so the same string objects
// after a settle prove there was no later conversion.

@Suite("TextKit 2 container cost", .serialized)
@MainActor
struct TextKit2ContainerCostTests {
    static let tallParagraphs = 300

    /// Layout passes per body row after a mount and a settle (`k` of M1),
    /// pinned at its first measurement (2026-11-16, iPhone 17 Pro
    /// simulator, iOS 27). k > 1 is the issue 10 signature: report it, do
    /// not relax it.
    static let pinnedK = 1

    /// `containers-expand`'s CE-TALL expand as a one-block document.
    static func tallDocument() throws -> (data: Data, expandID: String) {
        let fixture = try TextKit2FixtureSweepTests.fixtureData("containers-expand")
        let root = try #require(try JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        let content = try #require(root["content"] as? [[String: Any]])
        let tall = try #require(content.first { node in
            (node["type"] as? String) == "expand"
                && ((node["attrs"] as? [String: Any])?["title"] as? String)?.hasPrefix("CE-TALL") == true
        })
        let body = try #require(tall["content"] as? [[String: Any]])
        #expect(body.count == tallParagraphs)
        #expect(body.allSatisfy { ($0["type"] as? String) == "paragraph" })
        let document: [String: Any] = ["version": 1, "type": "doc", "content": [tall]]
        return (try JSONSerialization.data(withJSONObject: document), "0.0")
    }

    /// This window's body rows, in hierarchy order.
    static func bodyRows(_ hosted: TK2CodeLogic.Hosted, _ expandID: String) -> [TextKit2RowView] {
        hosted.rows.filter { $0.ownerID?.hasPrefix(expandID + ".") == true }
    }

    /// Lays the window out `passes` times, synchronously.
    static func layOut(_ hosted: TK2CodeLogic.Hosted, passes: Int = 3) {
        for _ in 0..<passes { hosted.window.layoutIfNeeded() }
    }

    /// The canvas backing stores of `rows` (M5): Σ(bounds area × scale² × 4
    /// bytes). Recorded, not gated.
    static func canvasBytes(_ rows: [TextKit2RowView]) -> Double {
        rows.reduce(0) { total, row in
            let canvas = row.subviews.first
            let scale = canvas?.contentScaleFactor ?? row.traitCollection.displayScale
            return total + Double(row.canvasFrame.width * row.canvasFrame.height * scale * scale * 4)
        }
    }

    /// The rows of a settled mount: 300, each body owner once, container
    /// text, each laid out `pinnedK` times; `strings` (when given) are the
    /// attributed strings the same rows held at the end of the span.
    static func checkMount(
        _ rows: [TextKit2RowView], expandID: String, _ what: String,
        strings: [ObjectIdentifier: NSAttributedString]? = nil
    ) {
        let owners = rows.compactMap(\.ownerID)
        let expected = Set((0..<tallParagraphs).map { "\(expandID).\($0)" })
        #expect(rows.count == tallParagraphs, "\(what): \(rows.count) rows")
        #expect(Set(owners) == expected && owners.count == expected.count, "\(what): owners")
        #expect(rows.allSatisfy { $0.containerContext == .container }, "\(what): container context")
        let layouts = rows.map(\.relayoutCount)
        let k = Set(layouts)
        #expect(k == [pinnedK], "\(what): layouts per row \(k.sorted()) (pinned k \(pinnedK); k > 1 is the issue 10 signature)")
        #expect(layouts.reduce(0, +) == tallParagraphs * pinnedK, "\(what): layouts \(layouts.reduce(0, +))")
        if let strings {
            let same = rows.filter { strings[ObjectIdentifier($0)] === $0.attributed }.count
            #expect(same == rows.count, "\(what): \(rows.count - same) rows converted again after the span")
        }
    }

    @Test("M1/M5: a 300-paragraph expand body mounts 300 rows with 300 conversions and 300 × k layouts; two OFF/ON round trips release every row and convert 300 per ON")
    func tallExpandBodyMount() async throws {
        let (data, expandID) = try Self.tallDocument()
        let model = try await TK2CodeLogic.loadedModel(data)
        let hosted = TK2CodeLogic.Hosted(TK2CodeLogic.documentView(model, .textKit2))
        defer { hosted.close() }
        try await hosted.settle()
        #expect(Self.bodyRows(hosted, expandID).isEmpty, "a closed expand mounts no body row")
        let diagnostics = TextKit2Diagnostics.shared

        guard TextKit2Eligibility.containerTextMatchesText else {
            // Before iOS 26 container text stays on SwiftUI: an open body
            // mounts no TextKit 2 row.
            model.expandedBlocks.insert(expandID)
            try await hosted.settle()
            try await hosted.settle()
            #expect(Self.bodyRows(hosted, expandID).isEmpty)
            return
        }

        // The first open: the expand's own task prepares the body off the
        // main actor, then the body mounts in one write.
        let conversionsBefore = diagnostics.conversionCount
        let layoutsBefore = diagnostics.layoutCount
        let opened = Date()
        model.expandedBlocks.insert(expandID)
        try await TK2ExpandBody.wait("the tall body's 300 rows", timeout: 30, in: hosted.window) {
            Self.bodyRows(hosted, expandID).count == Self.tallParagraphs
        }
        let mountSeconds = Date().timeIntervalSince(opened)
        try await hosted.settle()
        let openConversions = diagnostics.conversionCount - conversionsBefore
        let openLayouts = diagnostics.layoutCount - layoutsBefore
        var rows = Self.bodyRows(hosted, expandID)
        Self.checkMount(rows, expandID: expandID, "first open")
        #expect(openConversions >= Self.tallParagraphs, "first open: \(openConversions) conversions")
        #expect(openLayouts >= Self.tallParagraphs * Self.pinnedK, "first open: \(openLayouts) layouts")

        // Close: every row goes. Reopen: the prepared body mounts in one
        // synchronous span, exactly once per row.
        var released = rows.map { WeakRow($0) }
        rows = []
        let close = TextKit2ListLayoutTests.counting {
            model.expandedBlocks.remove(expandID)
            Self.layOut(hosted)
        }
        try await hosted.settle()
        #expect(close.conversions == 0, "close: \(close.conversions) conversions")
        #expect(Self.bodyRows(hosted, expandID).isEmpty, "close: rows left")
        #expect(released.allSatisfy { $0.row == nil }, "close: \(released.filter { $0.row != nil }.count) rows still alive")

        var strings: [ObjectIdentifier: NSAttributedString] = [:]
        let reopen = TextKit2ListLayoutTests.counting {
            model.expandedBlocks.insert(expandID)
            Self.layOut(hosted)
            for row in Self.bodyRows(hosted, expandID) { strings[ObjectIdentifier(row)] = row.attributed }
        }
        #expect(strings.count == Self.tallParagraphs, "reopen: \(strings.count) rows mounted in the span")
        #expect(reopen.conversions == Self.tallParagraphs, "reopen: \(reopen.conversions) conversions")
        #expect(reopen.layouts == Self.tallParagraphs * Self.pinnedK, "reopen: \(reopen.layouts) layouts")
        try await hosted.settle()
        Self.checkMount(Self.bodyRows(hosted, expandID), expandID: expandID, "reopen", strings: strings)

        // Two OFF/ON round trips with the body open: the switch is an
        // environment change, so the body stays prepared and open.
        var flips: [String] = []
        for trip in 1...2 {
            released = Self.bodyRows(hosted, expandID).map { WeakRow($0) }
            let off = TextKit2ListLayoutTests.counting {
                hosted.show(TK2CodeLogic.documentView(model, .swiftUI))
                Self.layOut(hosted)
            }
            try await hosted.settle()
            #expect(off.conversions == 0, "OFF \(trip): \(off.conversions) conversions")
            #expect(Self.bodyRows(hosted, expandID).isEmpty, "OFF \(trip): rows left in the window")
            #expect(released.allSatisfy { $0.row == nil }, "OFF \(trip): \(released.filter { $0.row != nil }.count) rows still alive")

            strings = [:]
            let on = TextKit2ListLayoutTests.counting {
                hosted.show(TK2CodeLogic.documentView(model, .textKit2))
                Self.layOut(hosted)
                for row in Self.bodyRows(hosted, expandID) { strings[ObjectIdentifier(row)] = row.attributed }
            }
            #expect(strings.count == Self.tallParagraphs, "ON \(trip): \(strings.count) rows mounted in the span")
            #expect(on.conversions == Self.tallParagraphs, "ON \(trip): \(on.conversions) conversions")
            #expect(on.layouts == Self.tallParagraphs * Self.pinnedK, "ON \(trip): \(on.layouts) layouts")
            try await hosted.settle()
            Self.checkMount(Self.bodyRows(hosted, expandID), expandID: expandID, "ON \(trip)", strings: strings)
            flips.append("OFF\(trip) \(off.conversions)/\(off.layouts) ON\(trip) \(on.conversions)/\(on.layouts)")
        }
        #expect(model.expandedBlocks == [expandID], "the flips closed the expand")

        rows = Self.bodyRows(hosted, expandID)
        let bytes = Self.canvasBytes(rows)
        let layouts = Set(rows.map(\.relayoutCount)).sorted()
        print(String(
            format: "EXPAND_COST rows=%d k=%@ firstOpen conversions=%d layouts=%d mount=%.3fs reopen=%d/%d %@ M5 canvasBytes=%.0f (%.2f MB)",
            rows.count, "\(layouts)", openConversions, openLayouts, mountSeconds, reopen.conversions, reopen.layouts,
            flips.joined(separator: " "), bytes, bytes / 1_048_576
        ))
    }
}

/// A row held weakly, to see it released.
@MainActor
struct WeakRow {
    weak var row: TextKit2RowView?
    init(_ row: TextKit2RowView) { self.row = row }
}
#endif
