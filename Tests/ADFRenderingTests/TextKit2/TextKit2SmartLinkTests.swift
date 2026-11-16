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
/// and names its link action by the title. The row visibility feed drives
/// lookups: a row far off screen never asks, and a row that leaves cancels.
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
        _ json: String, renderer: ADFTextRenderer, resolver: ScriptedSmartLinkResolver,
        feed: Bool = false, height: CGFloat = 1_200
    ) async throws -> Hosted {
        let model = ADFDocumentModel()
        model.smartLinks.timing.dwell = .zero
        model.smartLinks.hasVisibilityFeed = feed
        model.load(data: Data(json.utf8))
        try await TextKit2StableIDReplacementTests.ready(model)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: height))
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

        resolver.answer(URL(string: Self.a)!, .success(Self.page))
        try await smartLinkEventually("a resolved") { hosted.model.smartLinks.stage(for: Self.key(Self.a)) == .resolved(Self.page) }
        try await hosted.settle()
        rows = hosted.rows()
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
        resolver.answer(URL(string: Self.b)!, .failure(ADFSmartLinkError.notFound))
        try await smartLinkEventually("b failed") { hosted.model.smartLinks.stage(for: Self.key(Self.b)) == .failed(.notFound) }
        try await hosted.settle()
        rows = hosted.rows()
        #expect(rows["0.2"]?.accessibilityLabel == "Ticket \(Self.b)")
        #expect(rows["0.2"]?.attributed !== resolved["0.2"]?.string)
        for owner in ["0.0", "0.1", "0.3"] {
            #expect(rows[owner]?.attributed === resolved[owner]?.string, "\(owner): converted again for another row's link")
        }

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

        resolver.answer(URL(string: Self.a)!, .success(Self.page))
        try await smartLinkEventually("a resolved") { hosted.model.smartLinks.stage(for: Self.key(Self.a)) == .resolved(Self.page) }
        try await hosted.settle()
        let after = hosted.model.smartLinkLeafRefreshesByOwner
        let redrawn = Set(after.keys.filter { after[$0] != before[$0] })
        #expect(redrawn == ["0.0", "0.3"], "redrawn \(redrawn.sorted()); before \(before), after \(after)")
        #expect(TextKit2FallbackTests.rows(in: hosted.root).isEmpty, "SwiftUI built TextKit 2 rows")
    }

    @Test("the row visibility feed: a row far off screen never asks; a row that leaves cancels its lookup")
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
