#if canImport(UIKit)
import SwiftUI
import UIKit
import Testing
import ADFModel
import ADFPreparation
@_spi(ADFDiagnostics) @testable import ADFRendering

/// The renderer proof of plan §2.6, through the real document view: under
/// `.textKit2` an eligible top-level paragraph and heading are drawn by live
/// TextKit 2 rows (identified `tk2-row:<block id>`) that TextKit 2 itself
/// draws; a linked paragraph gets a row its TextKit 1 stack draws, counted
/// apart and never as a native draw; an atom-bearing paragraph, a
/// paragraph inside a container, a list item and a media caption get no
/// row; switching back to `.swiftUI` releases every row.
@Suite("TextKit 2 diagnostics", .serialized)
@MainActor
struct TextKit2DiagnosticsTests {
    struct NoMedia: ADFMediaProvider {
        func image(for attrs: MediaAttrs, targetSize: CGSize) async throws -> Image {
            throw CancellationError()
        }
    }

    static let document = """
    {"version":1,"type":"doc","content":[
      {"type":"paragraph","content":[{"type":"text","text":"An eligible paragraph."}]},
      {"type":"heading","attrs":{"level":2},"content":[{"type":"text","text":"Heading two"}]},
      {"type":"paragraph","content":[{"type":"text","text":"Ping "},{"type":"mention","attrs":{"id":"1","text":"@sam"}}]},
      {"type":"paragraph","content":[{"type":"text","text":"Read "},{"type":"text","text":"the notes","marks":[{"type":"link","attrs":{"href":"https://example.com"}}]}]},
      {"type":"panel","attrs":{"panelType":"info"},"content":[{"type":"paragraph","content":[{"type":"text","text":"Inside a panel."}]}]},
      {"type":"bulletList","content":[{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"A list item."}]}]}]},
      {"type":"mediaSingle","content":[{"type":"media","attrs":{"type":"external","url":"https://example.com/a.png","width":100,"height":50}},{"type":"caption","content":[{"type":"text","text":"A caption."}]}]}
    ]}
    """

    static func loadedModel() async throws -> ADFDocumentModel {
        let model = ADFDocumentModel()
        model.load(data: Data(document.utf8))
        for _ in 0..<500 where model.phase != .ready {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.phase == .ready)
        return model
    }

    /// Lets SwiftUI materialize (or release) rows after a root change.
    static func settle(_ window: UIWindow) async throws {
        for _ in 0..<5 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    static func identifiers(in view: UIView) -> Set<String> {
        var found: Set<String> = []
        if let id = view.accessibilityIdentifier, id.hasPrefix("tk2-row:") { found.insert(id) }
        for subview in view.subviews { found.formUnion(identifiers(in: subview)) }
        return found
    }

    /// Renders the window's layers, so every row view draws now.
    static func render(_ window: UIWindow) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        _ = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { context in
            window.layer.render(in: context.cgContext)
        }
    }

    @Test("eligible roots get TextKit 2 rows; fallbacks do not; switching back releases them")
    func rowsFollowTheSwitch() async throws {
        // The counters are process-wide and other suites render rows in
        // parallel (some from this same document, so block ids collide too):
        // rows are checked as this window's own instances, and a counter is
        // only compared across a span with no suspension in it.
        let diagnostics = TextKit2Diagnostics.shared
        let model = try await Self.loadedModel()
        let blocks = model.blocks
        let paragraph = try #require(blocks.first { if case .richText(_, let style) = $0.kind { return !style.isHeading } else { return false } })
        let heading = try #require(blocks.first { if case .richText(_, let style) = $0.kind { return style.isHeading } else { return false } })
        let linked = try #require(blocks.first {
            if case .richText(let segments, _) = $0.kind, case .text(let text) = segments.first {
                return text.runs.contains { $0.link != nil }
            }
            return false
        })

        #expect(ADFTextRenderer.textKit2Coverage(of: blocks) == ADFTextKit2Coverage(
            eligibleRoots: 3, fallbackRoots: blocks.count - 3, textFallbackRoots: 1, linkRoots: 1
        ))

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 1_600))
        let host = UIHostingController(rootView: ADFDocumentView(model: model, mediaProvider: NoMedia(), textRenderer: .textKit2))
        window.rootViewController = host
        window.isHidden = false
        try await Self.settle(window)

        // Every other block (atom paragraph, panel, list, caption) stays on SwiftUI.
        #expect(Self.identifiers(in: host.view) == ["tk2-row:\(paragraph.id)", "tk2-row:\(heading.id)", "tk2-row:\(linked.id)"])
        var rows = TextKit2FallbackTests.rows(in: host.view)
        #expect(rows.count == 3)
        #expect(rows.filter(\.isTextKit1Backed).map(\.ownerID) == [linked.id])
        for row in rows {
            #expect(row.relayoutCount >= 1, "\(row.ownerID ?? "?") never laid out")
        }
        #expect(ADFTextRenderer.textKit2Stats == diagnostics.snapshot)

        // No suspension from here to the last read: only these rows draw,
        // each once, now.
        let nativeDrawsBefore = diagnostics.nativeDrawCount
        let backedDrawsBefore = diagnostics.textKit1BackedDrawCount
        let drawsBefore = diagnostics.drawCount
        for canvas in rows.flatMap(\.subviews) {
            canvas.setNeedsDisplay()
            canvas.layer.displayIfNeeded()
        }
        let native = diagnostics.nativeDrawCount - nativeDrawsBefore
        let backed = diagnostics.textKit1BackedDrawCount - backedDrawsBefore
        #expect(native == 2, "native draws: \(native)")
        #expect(backed == 1, "TextKit 1 draws: \(backed)")
        // Every draw is one or the other, never both.
        #expect(diagnostics.drawCount - drawsBefore == native + backed)

        host.rootView = ADFDocumentView(model: model, mediaProvider: NoMedia(), textRenderer: .swiftUI)
        try await Self.settle(window)
        #expect(Self.identifiers(in: host.view).isEmpty)
        for row in rows {
            #expect(row.window == nil, "\(row.ownerID ?? "?") still on screen")
        }
        // SwiftUI let go of them: dropping this test's references releases
        // all three rows now, and the live counters drop with them.
        let live = diagnostics.liveRowCount
        let backedRows = diagnostics.textKit1BackedRowCount
        rows.removeAll()
        #expect(live - diagnostics.liveRowCount == 3, "rows released: \(live - diagnostics.liveRowCount)")
        #expect(backedRows - diagnostics.textKit1BackedRowCount == 1)

        window.isHidden = true
        window.rootViewController = nil
    }

    @Test("the rebuild control swaps the same leaves to SwiftUI Text and counts them")
    func rebuildControl() async throws {
        let before = ADFTextRenderer.rebuildControlRows
        let model = try await Self.loadedModel()
        func document(_ renderer: ADFTextRenderer, control: Bool) -> some View {
            ADFDocumentView(model: model, mediaProvider: NoMedia(), textRenderer: renderer).adfRebuildControl(control)
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 1_600))
        let host = UIHostingController(rootView: document(.swiftUI, control: true))
        window.rootViewController = host
        window.isHidden = false
        try await Self.settle(window)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        // Each switch to `.textKit2` under the control rebuilds the three
        // eligible leaves (paragraph, heading, linked paragraph) as `Text`.
        // (Other suites' rows can come and go across a suspension: only
        // this window's rows and the control's own counters are checked.)
        for round in 1...2 {
            host.rootView = document(.textKit2, control: true)
            try await Self.settle(window)
            #expect(ADFTextRenderer.rebuildControlRows.live - before.live == 3, "round \(round)")
            #expect(ADFTextRenderer.rebuildControlRows.appeared - before.appeared == 3 * round, "round \(round)")
            #expect(Self.identifiers(in: host.view).isEmpty, "no TextKit 2 row under the control")
            host.rootView = document(.swiftUI, control: true)
            try await Self.settle(window)
            #expect(ADFTextRenderer.rebuildControlRows.live == before.live, "round \(round)")
        }

        // Without the control the same switch builds TextKit 2 rows.
        host.rootView = document(.textKit2, control: false)
        try await Self.settle(window)
        #expect(Self.identifiers(in: host.view).count == 3)
        #expect(ADFTextRenderer.rebuildControlRows.live == before.live)
        host.rootView = document(.swiftUI, control: false)
        try await Self.settle(window)
    }

    @Test("a theme whose body font is a raw SwiftUI Font stays on SwiftUI")
    func undescribableThemeFallsBack() async throws {
        let theme = ADFTheme(body: .custom("Georgia", size: 17))
        #expect(theme.bodyFontSpec == nil)
        let json = "{\"version\":1,\"type\":\"doc\",\"content\":[{\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"Serif body\"}]}]}"
        let doc = try await ADFParser().parse(Data(json.utf8))
        let blocks = DocumentPreparer(theme: theme).prepare(doc)
        guard case .richText(let segments, _) = try #require(blocks.first).kind else {
            Issue.record("not rich text")
            return
        }
        #expect(TextKit2Eligibility.describableText(segments) == nil)
        #expect(ADFTextRenderer.textKit2Coverage(of: blocks) == ADFTextKit2Coverage(eligibleRoots: 0, fallbackRoots: 1, textFallbackRoots: 1))
        // The default (spec-first) theme stays eligible.
        let defaultBlocks = DocumentPreparer(theme: .default).prepare(doc)
        #expect(ADFTextRenderer.textKit2Coverage(of: defaultBlocks) == ADFTextKit2Coverage(eligibleRoots: 1, fallbackRoots: 0))
    }
}
#endif
