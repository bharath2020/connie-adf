#if canImport(UIKit)
import SwiftUI
import UIKit
import Testing
import ADFModel
import ADFPreparation
@_spi(ADFDiagnostics) @testable import ADFRendering

/// Smart links in the real document view (design §5, §6, §8): a stage
/// change rebuilds exactly the rows that show the URL — under TextKit 2
/// their row converts its text again and keeps its view, every other row
/// keeps its converted string; under SwiftUI only those leaves redraw. A
/// resolved row stays a TextKit 2 row with an attachment icon, and speaks
/// and names its link action by the title. Each leaf's own visibility feed
/// drives lookups: a leaf far off screen (or an item of a tall list below
/// the screen) never asks, and a leaf that leaves cancels.
@Suite("TextKit 2 smart links", .serialized)
@MainActor
struct TextKit2SmartLinkTests {
    typealias Hosted = TextKit2StableIDReplacementTests.Hosted

    static let a = "https://acme.atlassian.net/wiki/spaces/DOC/pages/1"
    static let b = "https://acme.atlassian.net/browse/ADF-7"
    static let page = ADFSmartLinkMetadata(title: "Q3 Roadmap", icon: .page)

    static func text(_ text: String) -> String { #"{"type":"text","text":"\#(text)"}"# }
    static func link(_ url: String) -> String {
        #"{"type":"text","text":"\#(url)","marks":[{"type":"link","attrs":{"href":"\#(url)"}}]}"#
    }
    static func paragraph(_ content: String...) -> String {
        #"{"type":"paragraph","content":[\#(content.joined(separator: ","))]}"#
    }
    static func document(_ blocks: [String]) -> String {
        #"{"version":1,"type":"doc","content":[\#(blocks.joined(separator: ","))]}"#
    }

    /// `0.0` "See <a> now", `0.1` plain, `0.2` "Ticket <b>", `0.3` "Again <a>".
    static let json = document([
        paragraph(text("See "), link(a), text(" now")),
        paragraph(text("Plain paragraph without links")),
        paragraph(text("Ticket "), link(b)),
        paragraph(text("Again "), link(a)),
    ])

    static func host(
        _ json: String, renderer: ADFTextRenderer, resolver: (any ADFSmartLinkResolver)?,
        feed: Bool = false, height: CGFloat = 1_200
    ) async throws -> Hosted {
        let model = ADFDocumentModel()
        model.smartLinks.timing.dwell = .zero
        model.smartLinks.hasVisibilityFeed = feed
        // As a host that builds its view before loading: the resolver is
        // installed when the blocks prepare (inline cards become smart links).
        model.smartLinks.resolver = resolver
        model.load(data: Data(json.utf8))
        try await TextKit2StableIDReplacementTests.ready(model)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: height))
        window.backgroundColor = .white
        let host = UIHostingController(rootView: ADFDocumentView(
            model: model, mediaProvider: TextKit2DiagnosticsTests.NoMedia(), textRenderer: renderer,
            smartLinkResolver: resolver
        ))
        window.rootViewController = host
        window.isHidden = false
        let hosted = Hosted(model: model, window: window, root: host.view)
        try await hosted.settle()
        return hosted
    }

    static func key(_ url: String) -> SmartLinkKey { SmartLinkKey(url)! }

    static func actionNames(_ row: TextKit2RowView?) -> [String] {
        row?.accessibilityCustomActions?.map(\.name) ?? []
    }

    static func hasAttachment(_ row: TextKit2RowView?) -> Bool {
        guard let string = row?.attributed else { return false }
        var found = false
        string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: string.length)) { value, _, stop in
            if value is NSTextAttachment {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    static func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for subview in view.subviews {
            if let scroll = scrollView(in: subview) { return scroll }
        }
        return nil
    }

    @Test("a resolved URL rebuilds only the TextKit 2 rows that show it; they stay TextKit 2 rows with an icon attachment")
    func onlyAffectedRowsRebuild() async throws {
        let resolver = ScriptedSmartLinkResolver()
        let hosted = try await Self.host(Self.json, renderer: .textKit2, resolver: resolver)
        defer { hosted.close() }
        // One lookup per URL, though `a` shows twice.
        try await smartLinkEventually("both lookups") { resolver.waitingURLs.count == 2 }
        #expect(resolver.calls.count == 2)
        try await hosted.settle()

        var rows = hosted.rows()
        #expect(Set(rows.keys) == ["0.0", "0.1", "0.2", "0.3"], "owners \(rows.keys.sorted())")
        #expect(rows["0.0"]?.accessibilityLabel == "See \(Self.a), loading title now")
        #expect(rows["0.2"]?.accessibilityLabel == "Ticket \(Self.b), loading title")
        let start = TextKit2StableIDReplacementTests.before(rows)
        let coordinator = hosted.model.smartLinks
        coordinator.recordsLeafBodies = true

        resolver.answer(URL(string: Self.a)!, .success(Self.page))
        try await smartLinkEventually("a resolved") { hosted.model.smartLinks.stage(for: Self.key(Self.a)) == .resolved(Self.page) }
        try await hosted.settle()
        rows = hosted.rows()
        // Only the leaves showing `a` ran their bodies; the paragraph
        // without links and the one with `b` did not.
        #expect(Set(coordinator.engineLeafBodiesByOwner.keys) == ["0.0", "0.3"],
                "engine leaf bodies \(coordinator.engineLeafBodiesByOwner.sorted { $0.key < $1.key })")
        #expect(coordinator.leafBodiesByOwner.isEmpty, "SwiftUI text bodies \(coordinator.leafBodiesByOwner)")
        #expect(Set(rows.keys) == ["0.0", "0.1", "0.2", "0.3"], "a resolved row left TextKit 2: \(rows.keys.sorted())")

        for (owner, label) in [("0.0", "See Page, Q3 Roadmap now"), ("0.3", "Again Page, Q3 Roadmap")] {
            guard let row = rows[owner], let was = start[owner] else {
                Issue.record("\(owner): row missing")
                continue
            }
            #expect(row === was.view, "\(owner): the row got a new view")
            #expect(row.attributed !== was.string, "\(owner): not converted again")
            #expect(row.relayoutCount > was.relayouts, "\(owner): no layout after the change")
            #expect(row.attributed.string.contains("\u{FFFC}\u{00A0}Q3 Roadmap"), "\(owner): drew \(row.attributed.string)")
            #expect(!row.attributed.string.contains(Self.a), "\(owner): still shows the URL")
            #expect(Self.hasAttachment(row), "\(owner): no icon attachment")
            #expect(row.accessibilityLabel == label, "\(owner): label \(row.accessibilityLabel ?? "nil")")
            #expect(Self.actionNames(row) == ["Open link Q3 Roadmap"], "\(owner): actions \(Self.actionNames(row))")
        }
        for owner in ["0.1", "0.2"] {
            guard let row = rows[owner], let was = start[owner] else {
                Issue.record("\(owner): row missing")
                continue
            }
            #expect(row === was.view, "\(owner): the row got a new view")
            #expect(row.attributed === was.string, "\(owner): converted again for another row's link")
            #expect(row.accessibilityLabel == was.label)
        }
        #expect(Self.actionNames(rows["0.2"]) == ["Open link acme.atlassian.net"])

        // `b` fails: its row returns to the prepared text; the resolved rows
        // are left alone.
        let resolved = TextKit2StableIDReplacementTests.before(rows)
        coordinator.recordsLeafBodies = true
        resolver.answer(URL(string: Self.b)!, .failure(ADFSmartLinkError.notFound))
        try await smartLinkEventually("b failed") { hosted.model.smartLinks.stage(for: Self.key(Self.b)) == .failed(.notFound) }
        try await hosted.settle()
        rows = hosted.rows()
        #expect(rows["0.2"]?.accessibilityLabel == "Ticket \(Self.b)")
        #expect(rows["0.2"]?.attributed !== resolved["0.2"]?.string)
        for owner in ["0.0", "0.1", "0.3"] {
            #expect(rows[owner]?.attributed === resolved[owner]?.string, "\(owner): converted again for another row's link")
        }
        #expect(Set(coordinator.engineLeafBodiesByOwner.keys) == ["0.2"],
                "engine leaf bodies \(coordinator.engineLeafBodiesByOwner.sorted { $0.key < $1.key })")

        let stats = hosted.model.smartLinkStats
        #expect(stats.resolverCalls == 2 && stats.resolved == 1 && stats.failed == 1 && stats.inFlight == 0, "\(stats)")
        print("SMARTLINK tk2 rebuild: stats=\(stats) refreshes=\(hosted.model.smartLinkLeafRefreshesByOwner.sorted { $0.key < $1.key })")
    }

    @Test("under SwiftUI a resolved URL redraws only the leaves that show it")
    func swiftUIOnlyAffectedLeavesRedraw() async throws {
        let resolver = ScriptedSmartLinkResolver()
        let hosted = try await Self.host(Self.json, renderer: .swiftUI, resolver: resolver)
        defer { hosted.close() }
        try await smartLinkEventually("both lookups") { resolver.waitingURLs.count == 2 }
        try await hosted.settle()
        let before = hosted.model.smartLinkLeafRefreshesByOwner
        #expect(before["0.1"] == nil, "a paragraph without smart links read smart-link state")
        // Body evaluations of every text leaf in this document, with links
        // or not, from here on (per document, so other suites' views cannot
        // count here).
        let coordinator = hosted.model.smartLinks
        coordinator.recordsLeafBodies = true

        resolver.answer(URL(string: Self.a)!, .success(Self.page))
        try await smartLinkEventually("a resolved") { hosted.model.smartLinks.stage(for: Self.key(Self.a)) == .resolved(Self.page) }
        try await hosted.settle()
        let after = hosted.model.smartLinkLeafRefreshesByOwner
        let redrawn = Set(after.keys.filter { after[$0] != before[$0] })
        #expect(redrawn == ["0.0", "0.3"], "redrawn \(redrawn.sorted()); before \(before), after \(after)")
        // The proof that can fail: had any other leaf re-run its body (the
        // plain paragraph 0.1, or 0.2 whose link did not change), it would
        // show up here.
        let bodies = coordinator.leafBodiesByOwner
        #expect(Set(bodies.keys) == ["0.0", "0.3"], "SwiftUI text bodies \(bodies.sorted { $0.key < $1.key })")
        #expect(bodies.values.allSatisfy { $0 >= 1 })
        #expect(Set(coordinator.engineLeafBodiesByOwner.keys).isSubset(of: ["0.0", "0.3"]),
                "engine leaf bodies \(coordinator.engineLeafBodiesByOwner.sorted { $0.key < $1.key })")
        #expect(TextKit2FallbackTests.rows(in: hosted.root).isEmpty, "SwiftUI built TextKit 2 rows")
    }

    @Test("text-leaf bodies: a stage change re-evaluates exactly the leaves it redraws, on both renderers", arguments: [
        ADFTextRenderer.swiftUI, .textKit2,
    ])
    func leafBodiesMatchRefreshes(renderer: ADFTextRenderer) async throws {
        let resolver = ScriptedSmartLinkResolver()
        let hosted = try await Self.host(Self.json, renderer: renderer, resolver: resolver)
        defer { hosted.close() }
        try await smartLinkEventually("both lookups") { resolver.waitingURLs.count == 2 }
        try await hosted.settle()

        // The counters are process-wide and other suites render in
        // parallel, so they are compared only across this span with no
        // suspension: publish the stage, then lay the window out and draw.
        let leaves = ADFTextRenderer.textLeafStats
        let refreshes = hosted.model.smartLinkStats.leafRefreshes
        let conversions = TextKit2Diagnostics.shared.conversionCount
        hosted.model.smartLinks.recordsLeafBodies = true
        hosted.model.smartLinks.entry(for: Self.key(Self.a)).publish(.resolved(Self.page))
        for _ in 0..<5 {
            hosted.window.layoutIfNeeded()
        }
        TextKit2DiagnosticsTests.render(hosted.window)
        let leafDelta = ADFTextRenderer.textLeafStats.total - leaves.total
        let refreshDelta = hosted.model.smartLinkStats.leafRefreshes - refreshes
        let conversionDelta = TextKit2Diagnostics.shared.conversionCount - conversions
        print("SMARTLINK leaf bodies (\(renderer)): leaves Δ\(leafDelta) refreshes Δ\(refreshDelta) conversions Δ\(conversionDelta)")

        // `a` shows in 0.0 and 0.3: two leaves redraw, nothing else runs.
        #expect(refreshDelta == 2, "refreshes Δ\(refreshDelta)")
        #expect(leafDelta == refreshDelta, "leaf bodies Δ\(leafDelta) vs refreshes Δ\(refreshDelta)")
        #expect(conversionDelta == (renderer == .textKit2 ? 2 : 0), "conversions Δ\(conversionDelta)")
        let bodies = renderer == .textKit2
            ? hosted.model.smartLinks.engineLeafBodiesByOwner : hosted.model.smartLinks.leafBodiesByOwner
        #expect(bodies == ["0.0": 1, "0.3": 1], "leaf bodies by owner \(bodies.sorted { $0.key < $1.key })")
        if renderer == .textKit2 {
            #expect(hosted.rows()["0.0"]?.accessibilityLabel == "See Page, Q3 Roadmap now")
        }
    }

    @Test("the leaf visibility feed: a leaf far off screen never asks; a leaf that leaves cancels its lookup")
    func visibilityFeedDrivesLookups() async throws {
        let filler = (0..<60).map { Self.paragraph(Self.text("Filler paragraph \($0) with enough words to take a line or two of the column.")) }
        let json = Self.document([Self.paragraph(Self.text("Top "), Self.link(Self.a))] + filler
            + [Self.paragraph(Self.text("Bottom "), Self.link(Self.b))])
        let resolver = ScriptedSmartLinkResolver()
        let hosted = try await Self.host(json, renderer: .textKit2, resolver: resolver, feed: true, height: 800)
        defer { hosted.close() }
        try await smartLinkEventually("the top link asked") { resolver.waitingURLs == [URL(string: Self.a)!] }
        try await hosted.settle()
        #expect(resolver.calls == [URL(string: Self.a)!], "calls \(resolver.calls)")

        let scroll = try #require(Self.scrollView(in: hosted.root))
        for _ in 0..<6 {
            scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height)), animated: false)
            try await hosted.settle()
        }
        try await smartLinkEventually("the bottom link asked") { resolver.calls.contains(URL(string: Self.b)!) }
        try await smartLinkEventually("the top lookup cancelled") { hosted.model.smartLinks.stage(for: Self.key(Self.a)) == .plain }
        let stats = hosted.model.smartLinkStats
        #expect(stats.cancellations == 1, "\(stats)")
        #expect(resolver.calls.filter { $0 == URL(string: Self.a)! }.count == 1)
        print("SMARTLINK feed: calls=\(resolver.calls.map(\.path)) stats=\(stats) contentHeight=\(scroll.contentSize.height)")
    }

    @Test("a tall list row resolves only the items on screen: visibility is per leaf, not per row", arguments: [
        ADFTextRenderer.swiftUI, .textKit2,
    ])
    func tallListResolvesOnlyVisibleItems(renderer: ADFTextRenderer) async throws {
        let urls = (0..<150).map { "https://acme.atlassian.net/browse/ADF-\($0)" }
        let items = urls.map { #"{"type":"listItem","content":[\#(Self.paragraph(Self.text("Item "), Self.link($0)))]}"# }
        let json = Self.document([
            Self.paragraph(Self.text("Intro")),
            #"{"type":"bulletList","content":[\#(items.joined(separator: ","))]}"#,
        ])
        let page = Self.page
        let resolver = ScriptedSmartLinkResolver(answerEverything: { _ in .success(page) })
        let hosted = try await Self.host(json, renderer: renderer, resolver: resolver, feed: true, height: 800)
        defer { hosted.close() }
        // The whole list is one row, so every item's leaf is attached.
        #expect(hosted.model.blocks.count == 2)
        try await smartLinkEventually("on-screen items asked") { !resolver.calls.isEmpty }
        for _ in 0..<4 { try await hosted.settle() }
        try await smartLinkEventually("settled") { hosted.model.smartLinkStats.inFlight == 0 }
        let coordinator = hosted.model.smartLinks

        func askedIndices() -> [Int] {
            Set(resolver.calls.map(\.absoluteString)).compactMap { urls.firstIndex(of: $0) }.sorted()
        }
        let atTop = askedIndices()
        print("SMARTLINK tall list (\(renderer)): asked \(atTop.count) of 150 at the top: \(atTop.first ?? -1)…\(atTop.last ?? -1)")
        // Far more item leaves are attached (the list row is built whole)
        // than are asked about: attachment alone is not demand.
        print("SMARTLINK tall list (\(renderer)): \(coordinator.attachedLeafIDs.count) leaves attached")
        #expect(coordinator.attachedLeafIDs.count > atTop.count + 20, "attached \(coordinator.attachedLeafIDs.count)")
        // Only the items on screen: a run from the first item, far short of
        // the list (a per-row feed asked about all 150).
        #expect(!atTop.isEmpty && atTop.count < 60, "asked \(atTop.count) items at the top")
        #expect(atTop == Array(0..<atTop.count), "asked items are not the top run: \(atTop)")
        #expect(resolver.calls.count == atTop.count, "an item was asked twice")

        // Jump to the end of the list: its last items are asked, the middle
        // (never on screen) is not.
        let scroll = try #require(Self.scrollView(in: hosted.root))
        for _ in 0..<4 {
            scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height)), animated: false)
            try await hosted.settle()
        }
        try await smartLinkEventually("the last item asked") { resolver.calls.contains(URL(string: urls[149])!) }
        try await smartLinkEventually("settled at the end") { hosted.model.smartLinkStats.inFlight == 0 }
        let atEnd = askedIndices()
        print("SMARTLINK tall list (\(renderer)): asked \(atEnd.count) of 150 after the jump")
        #expect(!atEnd.contains(75), "an item never on screen was asked")
        #expect(atEnd.count < 120, "asked \(atEnd.count) items")
    }

    @Test("a block replaced under a new id moves its leaf's attachment and visibility; nothing stays under the old id")
    func blockIDChangeMovesAttachment() async throws {
        let resolver = ScriptedSmartLinkResolver()
        let json = Self.document([Self.paragraph(Self.text("See "), Self.link(Self.a), Self.text(" now"))])
        let hosted = try await Self.host(json, renderer: .swiftUI, resolver: resolver, feed: true, height: 800)
        defer { hosted.close() }
        let coordinator = hosted.model.smartLinks
        let a = Self.key(Self.a)
        try await smartLinkEventually("the call") { resolver.waitingURLs == [a.url] }
        #expect(coordinator.attachedLeafIDs == ["0.0"])
        let block = try #require(hosted.model.blocks.first)
        guard case .richText(_, let style) = block.kind else { throw TestFailure("not rich text") }

        // Same content and keys, new block id (`apply(.replace)` under the
        // same item): the live leaf moves to the new id, still visible, and
        // its lookup keeps running.
        try await hosted.model.apply(
            [.replace(itemID: "0.0", block: RenderBlock(id: "renamed", kind: block.kind, smartLinkKeys: block.smartLinkKeys))],
            revision: 1
        )
        try await hosted.settle()
        try await smartLinkEventually("moved to the new id") { coordinator.attachedLeafIDs == ["renamed"] }
        #expect(coordinator.knownVisibility(of: "renamed") == true)
        #expect(coordinator.knownVisibility(of: "0.0") == nil)
        #expect(coordinator.demandCounts == [a: 1])
        #expect(resolver.cancelled.isEmpty, "the move cancelled the lookup")

        // Replaced by text without links: the leaf detaches and the call is
        // cancelled, so no stale attachment keeps asking.
        let plain = RenderBlock(id: "plain", kind: .richText(segments: [.text(AttributedString("No links here"))], style: style))
        try await hosted.model.apply([.replace(itemID: "0.0", block: plain)], revision: 2)
        try await hosted.settle()
        try await smartLinkEventually("detached") { coordinator.attachedLeafIDs.isEmpty }
        #expect(coordinator.demandCounts.isEmpty)
        try await smartLinkEventually("the lookup cancelled") { resolver.cancelled == [a.url] }
    }

    @Test("VoiceOver: a SwiftUI leaf speaks every stage word for word as the TextKit 2 row does (design §6)")
    func spokenLabelsMatchAcrossRenderers() async throws {
        let json = Self.document([Self.paragraph(Self.text("See "), Self.link(Self.a), Self.text(" now"))])
        let stages: [(name: String, stage: SmartLinkStage, spoken: String)] = [
            ("plain", .plain, "See \(Self.a) now"),
            ("resolving", .resolving, "See \(Self.a), loading title now"),
            ("resolved", .resolved(Self.page), "See Page, Q3 Roadmap now"),
            ("resolved issue", .resolved(ADFSmartLinkMetadata(title: "Fix the cache", icon: .issue)), "See Issue, Fix the cache now"),
            ("failed", .failed(.unauthorized), "See \(Self.a) now"),
        ]
        // No resolver: nothing is asked, the stages are published by hand.
        let textKit2 = try await Self.host(json, renderer: .textKit2, resolver: nil)
        let swiftUI = try await Self.host(json, renderer: .swiftUI, resolver: nil)
        defer {
            textKit2.close()
            swiftUI.close()
        }
        let block = try #require(swiftUI.model.blocks.first)
        guard case .richText(let segments, _) = block.kind else { throw TestFailure("not rich text") }
        let key = Self.key(Self.a)
        for (name, stage, spoken) in stages {
            swiftUI.model.smartLinks.recordsLeafBodies = true
            for hosted in [textKit2, swiftUI] {
                hosted.model.smartLinks.entry(for: key).publish(stage)
                try await hosted.settle()
            }
            let textKit2Label = textKit2.rows()["0.0"]?.accessibilityLabel
            // The SwiftUI leaf's label, as its body composes it: the
            // displayed segments for the stage, merged, labelled by
            // `SmartLinkDisplay.text`. SwiftUI's accessibility tree cannot be
            // read in a unit test without an assistive client (the code
            // parity suite's E5 finding; switching the app's accessibility
            // runtime on did not populate it either), so the label comes
            // from the functions the body calls, and the live leaf is
            // checked to be the one composing smart links.
            let displayed = SmartLinkDisplay.apply([key: stage], to: segments, theme: swiftUI.model.theme)
            let merged = try #require(SegmentedTextView.mergedText(displayed))
            let swiftUILabel = SmartLinkDisplay.accessibilityText(of: merged)
            print("SMARTLINK spoken \(name): textKit2=\(textKit2Label ?? "nil") swiftUI=\(swiftUILabel)")
            #expect(textKit2Label == spoken, "\(name): TextKit 2 said \(textKit2Label ?? "nil")")
            #expect(swiftUILabel == spoken, "\(name): SwiftUI said \(swiftUILabel)")
            #expect(!swiftUILabel.contains("\u{FFFC}"), "\(name): SwiftUI reads the icon character")
            if stage != .plain {
                #expect(swiftUI.model.smartLinks.leafBodiesByOwner["0.0"] != nil, "\(name): the SwiftUI leaf did not redraw")
            }
            #expect(TextKit2FallbackTests.rows(in: swiftUI.root).isEmpty, "SwiftUI built TextKit 2 rows")
        }
    }

    @Test("a resolved title that wraps: TextKit 2 and SwiftUI agree on height and line breaks")
    func wrappedTitleParity() async throws {
        let title = "Q3 Roadmap planning notes for the reader app and the platform team, second draft with appendices"
        let json = Self.document([Self.paragraph(Self.text("See "), Self.link(Self.a), Self.text(" before the review on Monday"))])
        let resolver = ScriptedSmartLinkResolver(answerEverything: { _ in .success(ADFSmartLinkMetadata(title: title, icon: .page)) })
        var heights: [ADFTextRenderer: CGFloat] = [:]
        var bitmaps: [ADFTextRenderer: TK2Parity.Bitmap] = [:]
        var lines: [CGRect] = []
        for renderer in [ADFTextRenderer.swiftUI, .textKit2] {
            let hosted = try await Self.host(json, renderer: renderer, resolver: resolver, height: 600)
            defer { hosted.close() }
            try await smartLinkEventually("resolved") {
                hosted.model.smartLinks.stage(for: Self.key(Self.a)) == .resolved(ADFSmartLinkMetadata(title: title, icon: .page))
            }
            try await hosted.settle()
            let scroll = try #require(Self.scrollView(in: hosted.root))
            scroll.showsVerticalScrollIndicator = false
            scroll.showsHorizontalScrollIndicator = false
            try await hosted.settle()
            heights[renderer] = scroll.contentSize.height
            bitmaps[renderer] = try TK2Parity.bitmap(of: hosted.window, width: 390)
            if renderer == .textKit2 {
                let row = try #require(hosted.rows()["0.0"])
                #expect(Self.hasAttachment(row))
                lines = row.layoutResult(forProposedWidth: row.bounds.width).lines.map { row.convert($0.frame, to: hosted.window) }
            }
        }
        let swiftUI = try #require(bitmaps[.swiftUI]), textKit2 = try #require(bitmaps[.textKit2])
        print("SMARTLINK wrapped: heights swiftUI=\(heights[.swiftUI] ?? -1) textKit2=\(heights[.textKit2] ?? -1) lines=\(lines.count)")
        #expect(lines.count >= 3, "the title did not wrap: \(lines.count) lines")
        #expect(abs((heights[.swiftUI] ?? -1) - (heights[.textKit2] ?? -2)) <= 0.5, "heights \(heights)")
        for (index, frame) in lines.enumerated() {
            let band = Int((frame.minY * swiftUI.scale).rounded())..<Int((frame.maxY * swiftUI.scale).rounded())
            let a = TK2Parity.inkExtent(swiftUI, rows: band, dark: false)
            let b = TK2Parity.inkExtent(textKit2, rows: band, dark: false)
            print("SMARTLINK wrapped line \(index): swiftUI=\(String(describing: a)) textKit2=\(String(describing: b))")
            // A word moved across a break shifts an end by a whole word; a
            // pixel or two is antialiasing of the icon.
            let matches = a.flatMap { a in b.map { b in abs(a.lowerBound - b.lowerBound) <= 2 && abs(a.upperBound - b.upperBound) <= 2 } } ?? false
            #expect(matches, "line \(index): swiftUI=\(String(describing: a)) textKit2=\(String(describing: b))")
        }
    }

    @Test("a resolved row's height under TextKit 2 and SwiftUI (evidence)")
    func resolvedHeightParity() async throws {
        let json = Self.document([Self.paragraph(Self.text("See "), Self.link(Self.a), Self.text(" now"))])
        let resolver = ScriptedSmartLinkResolver(answerEverything: { _ in .success(ADFSmartLinkMetadata(title: "Q3 Roadmap", icon: .page)) })
        var heights: [ADFTextRenderer: CGFloat] = [:]
        for renderer in [ADFTextRenderer.swiftUI, .textKit2] {
            let hosted = try await Self.host(json, renderer: renderer, resolver: resolver)
            defer { hosted.close() }
            try await smartLinkEventually("resolved") { hosted.model.smartLinks.stage(for: Self.key(Self.a)) == .resolved(Self.page) }
            try await hosted.settle()
            heights[renderer] = try #require(Self.scrollView(in: hosted.root)).contentSize.height
            if renderer == .textKit2 {
                #expect(Self.hasAttachment(hosted.rows()["0.0"]))
            }
        }
        let swiftUI = heights[.swiftUI] ?? -1, textKit2 = heights[.textKit2] ?? -1
        print("SMARTLINK height: swiftUI=\(swiftUI) textKit2=\(textKit2) diff=\(textKit2 - swiftUI)")
        #expect(abs(swiftUI - textKit2) <= 1, "content height swiftUI=\(swiftUI) textKit2=\(textKit2)")
    }
}
#endif
