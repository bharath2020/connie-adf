#if canImport(UIKit)
import SwiftUI
import UIKit
import Testing
import ADFModel
import ADFPreparation
@_spi(ADFDiagnostics) @testable import ADFRendering

/// Custom emoji in the real document view (design `adf-res1` §4.3, §4.7):
/// a landed image rebuilds exactly the rows that show its key — under
/// TextKit 2 their row converts its text again in the same box, so no row
/// moves or changes height; every other row keeps its converted string. A
/// failure shows the short name. The leaf's one visibility feed serves the
/// smart-link and emoji coordinators, each only when installed.
@Suite("TextKit 2 custom emoji", .serialized)
@MainActor
struct TextKit2EmojiTests {
    typealias Hosted = TextKit2StableIDReplacementTests.Hosted

    static let e1 = EmojiKey(id: "custom-e1", shortName: ":e1:")
    static let e2 = EmojiKey(id: nil, shortName: ":e2:")

    static func text(_ text: String) -> String { TextKit2SmartLinkTests.text(text) }
    static func emoji(_ shortName: String, id: String? = nil) -> String {
        let idPart = id.map { #","id":"\#($0)""# } ?? ""
        return #"{"type":"emoji","attrs":{"shortName":"\#(shortName)"\#(idPart)}}"#
    }
    static func paragraph(_ content: String...) -> String {
        #"{"type":"paragraph","content":[\#(content.joined(separator: ","))]}"#
    }

    /// `0.0` "Hello <e1> there", `0.1` plain, `0.2` "Team <e2>", `0.3` "Again <e1>".
    static let json = TextKit2SmartLinkTests.document([
        paragraph(text("Hello "), emoji(":e1:", id: "custom-e1"), text(" there")),
        paragraph(text("Plain paragraph without emoji")),
        paragraph(text("Team "), emoji(":e2:")),
        paragraph(text("Again "), emoji(":e1:", id: "custom-e1")),
    ])

    static func image() -> ADFResolvedImage {
        EmojiCoordinatorTests.image(width: 6, height: 6)
    }

    /// Hosts `json` with `emoji` installed by the view after `load` (or, with
    /// `beforeLoad`, on the model before it), and optionally a smart-link
    /// resolver. No dwell; `feed` false counts every attached leaf visible.
    static func host(
        _ json: String, renderer: ADFTextRenderer, emoji: (any ADFEmojiResolver)?,
        smartLinks: (any ADFSmartLinkResolver)? = nil, beforeLoad: Bool = false,
        feed: Bool = false, height: CGFloat = 1_200
    ) async throws -> Hosted {
        let model = ADFDocumentModel()
        model.emoji.timing.dwell = .zero
        model.emoji.hasVisibilityFeed = feed
        model.smartLinks.timing.dwell = .zero
        model.smartLinks.timing.resolvingDelay = .zero
        model.smartLinks.hasVisibilityFeed = feed
        model.smartLinks.resolver = smartLinks
        if beforeLoad { model.emoji.resolver = emoji }
        model.load(data: Data(json.utf8))
        try await TextKit2StableIDReplacementTests.ready(model)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: height))
        window.backgroundColor = .white
        let host = UIHostingController(rootView: ADFDocumentView(
            model: model, mediaProvider: TextKit2DiagnosticsTests.NoMedia(), textRenderer: renderer,
            smartLinkResolver: smartLinks, emojiResolver: emoji
        ))
        window.rootViewController = host
        window.isHidden = false
        let hosted = Hosted(model: model, window: window, root: host.view)
        try await hosted.settle()
        return hosted
    }

    static func attachments(_ row: TextKit2RowView?) -> [NSTextAttachment] {
        guard let string = row?.attributed else { return [] }
        var found: [NSTextAttachment] = []
        string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: string.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment { found.append(attachment) }
        }
        return found
    }

    static func isResolved(_ stage: EmojiStage) -> Bool {
        if case .resolved = stage { return true }
        return false
    }

    @Test("TextKit 2: an image rebuilds only the rows that show its key, in the same box (no row moves or grows); a failure shows the short name",
          arguments: [false, true])
    func onlyAffectedRowsRebuild(beforeLoad: Bool) async throws {
        let resolver = ScriptedEmojiResolver()
        let hosted = try await Self.host(Self.json, renderer: .textKit2, emoji: resolver, beforeLoad: beforeLoad)
        defer { hosted.close() }
        // One lookup per key, though e1 shows twice.
        try await smartLinkEventually("both lookups") { resolver.waitingNames == [":e1:", ":e2:"] }
        #expect(resolver.calls.count == 2)
        try await hosted.settle()

        var rows = hosted.rows()
        #expect(Set(rows.keys) == ["0.0", "0.1", "0.2", "0.3"], "owners \(rows.keys.sorted())")
        // Pending: one blank box, not the short name.
        #expect(rows["0.0"]?.attributed.string == "Hello \u{FFFC} there")
        #expect(Self.attachments(rows["0.0"]).count == 1)
        let start = TextKit2StableIDReplacementTests.before(rows)
        let frames = rows.mapValues(TextKit2StableIDReplacementTests.windowFrame)
        let scroll = try #require(TextKit2SmartLinkTests.scrollView(in: hosted.root))
        let contentHeight = scroll.contentSize.height
        let boxBounds = try #require(Self.attachments(rows["0.0"]).first?.bounds)
        let refreshesBefore = hosted.model.emoji.leafRefreshesByOwner
        let conversions = TextKit2Diagnostics.shared.conversionCount

        resolver.answer(":e1:", .success(Self.image()))
        try await smartLinkEventually("e1 resolved") { Self.isResolved(hosted.model.emoji.stage(for: Self.e1)) }
        try await hosted.settle()
        rows = hosted.rows()
        let conversionDelta = TextKit2Diagnostics.shared.conversionCount - conversions
        #expect(Set(rows.keys) == ["0.0", "0.1", "0.2", "0.3"], "a resolved row left TextKit 2: \(rows.keys.sorted())")
        for owner in ["0.0", "0.3"] {
            guard let row = rows[owner], let was = start[owner] else {
                Issue.record("\(owner): row missing")
                continue
            }
            #expect(row === was.view, "\(owner): the row got a new view")
            #expect(row.attributed !== was.string, "\(owner): not converted again")
            #expect(row.attributed.string == was.string.string, "\(owner): text changed: \(row.attributed.string)")
            let attachment = try #require(Self.attachments(row).first, "\(owner): no image attachment")
            #expect(attachment.bounds == boxBounds, "\(owner): box \(attachment.bounds) vs \(boxBounds)")
        }
        for owner in ["0.1", "0.2"] {
            #expect(rows[owner] === start[owner]?.view, "\(owner): the row got a new view")
            #expect(rows[owner]?.attributed === start[owner]?.string, "\(owner): converted again for another row's emoji")
        }
        // Same box: nothing moved, nothing grew.
        for (owner, frame) in frames {
            guard let row = rows[owner] else { continue }
            let now = TextKit2StableIDReplacementTests.windowFrame(row)
            #expect(TextKit2StableIDReplacementTests.close(now, frame), "\(owner): \(frame) -> \(now)")
        }
        #expect(scroll.contentSize.height == contentHeight)
        let refreshed = Set(hosted.model.emoji.leafRefreshesByOwner.keys.filter {
            hosted.model.emoji.leafRefreshesByOwner[$0] != refreshesBefore[$0]
        })
        #expect(refreshed == ["0.0", "0.3"], "refreshed \(refreshed.sorted())")
        #expect(conversionDelta >= 2, "conversions Δ\(conversionDelta)")

        // e2 fails: its row shows the short name; the others are left alone.
        let resolved = TextKit2StableIDReplacementTests.before(rows)
        resolver.answer(":e2:", .failure(EmojiTestError()))
        try await smartLinkEventually("e2 failed") { hosted.model.emoji.stage(for: Self.e2) == .failed }
        try await hosted.settle()
        rows = hosted.rows()
        #expect(rows["0.2"]?.attributed.string == "Team :e2:")
        #expect(Self.attachments(rows["0.2"]).isEmpty)
        #expect(rows["0.2"]?.accessibilityLabel == "Team e2", "label \(rows["0.2"]?.accessibilityLabel ?? "nil")")
        for owner in ["0.0", "0.1", "0.3"] {
            #expect(rows[owner]?.attributed === resolved[owner]?.string, "\(owner): converted again for another row's emoji")
        }
        let stats = hosted.model.emojiStats
        #expect(stats.resolverCalls == 2 && stats.resolved == 1 && stats.failed == 1 && stats.inFlight == 0, "\(stats)")
        // Only the emoji coordinator was fed.
        #expect(hosted.model.smartLinks.attachedLeafIDs.isEmpty)
        #expect(hosted.model.emoji.attachedLeafIDs == ["0.0", "0.2", "0.3"])
        print("EMOJI tk2 rebuild (beforeLoad \(beforeLoad)): stats=\(stats) conversions Δ\(conversionDelta)")
    }

    @Test("SwiftUI: an image redraws only the leaves that show its key and changes no height")
    func swiftUIOnlyAffectedLeavesRedraw() async throws {
        let resolver = ScriptedEmojiResolver()
        let hosted = try await Self.host(Self.json, renderer: .swiftUI, emoji: resolver)
        defer { hosted.close() }
        try await smartLinkEventually("both lookups") { resolver.waitingNames == [":e1:", ":e2:"] }
        try await hosted.settle()
        let scroll = try #require(TextKit2SmartLinkTests.scrollView(in: hosted.root))
        let contentHeight = scroll.contentSize.height
        let before = hosted.model.emoji.leafRefreshesByOwner

        resolver.answer(":e1:", .success(Self.image()))
        try await smartLinkEventually("e1 resolved") { Self.isResolved(hosted.model.emoji.stage(for: Self.e1)) }
        try await hosted.settle()
        let after = hosted.model.emoji.leafRefreshesByOwner
        let redrawn = Set(after.keys.filter { after[$0] != before[$0] })
        #expect(redrawn == ["0.0", "0.3"], "redrawn \(redrawn.sorted()); before \(before), after \(after)")
        #expect(abs(scroll.contentSize.height - contentHeight) < 0.5, "\(contentHeight) -> \(scroll.contentSize.height)")
        #expect(TextKit2FallbackTests.rows(in: hosted.root).isEmpty, "SwiftUI built TextKit 2 rows")
        resolver.answer(":e2:", .success(Self.image()))
    }

    @Test("no resolver: every custom emoji shows its short name, and no leaf is fed")
    func noResolverShortNames() async throws {
        let hosted = try await Self.host(Self.json, renderer: .textKit2, emoji: nil)
        defer { hosted.close() }
        let rows = hosted.rows()
        #expect(rows["0.0"]?.attributed.string == "Hello :e1: there")
        #expect(rows["0.2"]?.attributed.string == "Team :e2:")
        #expect(hosted.model.emoji.attachedLeafIDs.isEmpty)
        #expect(hosted.model.smartLinks.attachedLeafIDs.isEmpty)
    }

    @Test("one leaf feed serves both coordinators: a leaf with a smart link and an emoji attaches to each; far off screen, neither asks",
          arguments: [ADFTextRenderer.swiftUI, .textKit2])
    func sharedFeed(renderer: ADFTextRenderer) async throws {
        let url = TextKit2SmartLinkTests.a
        let filler = (0..<60).map { Self.paragraph(Self.text("Filler paragraph \($0) with enough words to take a line or two of the column.")) }
        let json = TextKit2SmartLinkTests.document(
            [Self.paragraph(Self.text("Top "), TextKit2SmartLinkTests.link(url), Self.text(" "), Self.emoji(":e1:", id: "custom-e1"))]
                + filler
                + [Self.paragraph(Self.text("Bottom "), Self.emoji(":e2:"))]
        )
        let emoji = ScriptedEmojiResolver()
        let links = ScriptedSmartLinkResolver()
        let hosted = try await Self.host(json, renderer: renderer, emoji: emoji, smartLinks: links, feed: true, height: 800)
        defer { hosted.close() }
        try await smartLinkEventually("the top leaf asked both") {
            emoji.waitingNames == [":e1:"] && links.waitingURLs == [URL(string: url)!]
        }
        try await hosted.settle()
        #expect(emoji.calls == [":e1:"], "emoji calls \(emoji.calls)")
        #expect(hosted.model.smartLinks.knownVisibility(of: "0.0") == true)
        #expect(hosted.model.emoji.knownVisibility(of: "0.0") == true)
        // The bottom leaf may be built in the render region, never asked.
        #expect(hosted.model.emoji.demandCounts[Self.e2] == nil)

        // Scroll to the end: the bottom emoji is asked, the top lookups are
        // cancelled (both coordinators heard the top leaf leave).
        let scroll = try #require(TextKit2SmartLinkTests.scrollView(in: hosted.root))
        for _ in 0..<6 {
            scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height)), animated: false)
            try await hosted.settle()
        }
        try await smartLinkEventually("the bottom emoji asked") { emoji.calls.contains(":e2:") }
        try await smartLinkEventually("both top lookups cancelled") {
            hosted.model.emojiStats.cancellations == 1 && hosted.model.smartLinkStats.cancellations == 1
        }
        #expect(hosted.model.emoji.stage(for: Self.e1) == .pending)
        emoji.answer(":e2:", .success(Self.image()))
        try await smartLinkEventually("e2 resolved") { Self.isResolved(hosted.model.emoji.stage(for: Self.e2)) }
        print("EMOJI shared feed (\(renderer)): emoji=\(hosted.model.emojiStats) links=\(hosted.model.smartLinkStats)")
    }
}
#endif
