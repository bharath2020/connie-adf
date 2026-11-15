#if canImport(UIKit)
import Foundation
import SwiftUI
import Testing
import UIKit
import ADFModel
import ADFPreparation
@_spi(ADFDiagnostics) @testable import ADFRendering

/// The capture-time geometry SPIs behind the demo's `CAPTURE_GEOMETRY`
/// line (`ADFTextRenderer.textKit2RowFrames(in:)`,
/// `ADFDocumentModel.fullyVisibleRowIDs`): the visual gate ties a scored
/// code box to the TextKit 2 row whose on-screen frame holds its pixels, so
/// a row's reported frame must cover what it can draw and its visible part
/// must follow every clip on the way to the window.
@Suite("TextKit 2 row frames (capture geometry)", .serialized)
@MainActor
struct TextKit2RowFramesTests {
    /// Three lines of code, the second 80 columns wide (wider than the
    /// scroll view below, so the horizontal clip is visible).
    nonisolated static let code = "func greet() {\n" + String(repeating: "x", count: 80) + "\n}"

    /// A code row as the code view's representable makes one: counted as
    /// code first, then given its inputs and its owner, then placed at its
    /// natural size (code never wraps).
    static func codeRow(ownerID: String?) -> TextKit2RowView {
        let row = TextKit2RowView()
        row.ownerKind = .code
        row.apply(TextKit2RenderInputs(text: TK2CodeLogic.stamped(code), displayScale: 3, layoutPolicy: .natural),
                  ownerID: ownerID)
        let size = row.layoutResult(forProposedWidth: 10_000).size
        row.frame = CGRect(origin: .zero, size: size)
        row.layoutIfNeeded()
        return row
    }

    static func frames(_ window: UIWindow, owner: String) -> [ADFTextKit2RowFrame] {
        ADFTextRenderer.textKit2RowFrames(in: window).filter { $0.ownerID == owner }
    }

    @Test("a row's frame is its bounds and canvas; its visible part follows scroll views, masks, hiding and the window")
    func rowFramesClipToScrollViewsAndWindow() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.isHidden = false
        defer { window.isHidden = true }
        let scroller = UIScrollView(frame: CGRect(x: 20, y: 100, width: 300, height: 200))
        #expect(scroller.clipsToBounds)
        window.addSubview(scroller)
        let row = Self.codeRow(ownerID: "0.19")
        row.frame.origin = CGPoint(x: 12, y: 12)
        scroller.addSubview(row)
        #expect(row.bounds.width > 300, "the code row is not wider than the scroll view: \(row.bounds)")

        let found = try #require(Self.frames(window, owner: "0.19").first)
        #expect(Self.frames(window, owner: "0.19").count == 1)
        #expect(found.kind == .code)
        // Bounds ∪ canvas, in window points: the row sits at (32, 112).
        let bounds = CGRect(x: 32, y: 112, width: row.bounds.width, height: row.bounds.height)
        let canvas = row.canvasFrame.offsetBy(dx: 32, dy: 112)
        #expect(found.frame == bounds.union(canvas), "\(found.frame) vs bounds \(bounds) canvas \(canvas)")
        #expect(canvas.minY <= bounds.minY && canvas.maxY >= bounds.maxY)
        // The scroll view clips it to its window rectangle.
        let scrollerRect = CGRect(x: 20, y: 100, width: 300, height: 200)
        let visible = try #require(found.visible)
        #expect(visible == found.frame.intersection(scrollerRect), "\(visible)")
        #expect(visible.maxX <= 320 && visible.minX >= 32 && visible.minY >= 100)

        // Scrolled out of the scroll view: still in the window, shown nowhere.
        scroller.contentOffset = CGPoint(x: 0, y: 300)
        let scrolled = try #require(Self.frames(window, owner: "0.19").first)
        #expect(scrolled.visible == nil)
        #expect(scrolled.frame.minY == found.frame.minY - 300)
        // Scrolled horizontally: the visible part moves with the content.
        scroller.contentOffset = CGPoint(x: 100, y: 0)
        let panned = try #require(Self.frames(window, owner: "0.19").first?.visible)
        #expect(panned == found.frame.offsetBy(dx: -100, dy: 0).intersection(scrollerRect))
        scroller.contentOffset = .zero

        // A layer mask on an ancestor clips like bounds do.
        let mask = CALayer()
        mask.frame = CGRect(x: 0, y: 0, width: 100, height: 50)
        mask.backgroundColor = UIColor.black.cgColor
        scroller.layer.mask = mask
        let masked = try #require(Self.frames(window, owner: "0.19").first?.visible)
        #expect(masked == found.frame.intersection(CGRect(x: 20, y: 100, width: 100, height: 50)))
        scroller.layer.mask = nil

        // Hidden or transparent, the row or an ancestor: nothing shown.
        row.isHidden = true
        #expect(Self.frames(window, owner: "0.19").first?.visible == nil)
        row.isHidden = false
        scroller.alpha = 0
        #expect(Self.frames(window, owner: "0.19").first?.visible == nil)
        scroller.alpha = 1
        #expect(Self.frames(window, owner: "0.19").first?.visible != nil)

        // Outside the window's bounds: clipped by the window.
        scroller.frame.origin.y = 900
        #expect(Self.frames(window, owner: "0.19").first?.visible == nil)
        scroller.frame.origin.y = 100

        // A row without an owner (a preview) is not listed; another kind is.
        let anonymous = Self.codeRow(ownerID: nil)
        scroller.addSubview(anonymous)
        let heading = TextKit2RowView()
        heading.apply(TextKit2RenderInputs(text: TK2CodeLogic.stamped("Heading"), isHeading: true), ownerID: "0.17")
        heading.frame = CGRect(x: 0, y: 0, width: 100, height: 30)
        window.addSubview(heading)
        let all = ADFTextRenderer.textKit2RowFrames(in: window)
        #expect(Set(all.map(\.ownerID)) == ["0.19", "0.17"])
        #expect(all.first { $0.ownerID == "0.17" }?.kind == .root)

        // Out of the window: not listed at all.
        row.removeFromSuperview()
        heading.removeFromSuperview()
        #expect(ADFTextRenderer.textKit2RowFrames(in: window).isEmpty)
    }

    @Test("the owner kinds map one to one")
    func kindsMap() {
        #expect(ADFTextKit2RowFrame.Kind(TextKit2OwnerKind.root) == .root)
        #expect(ADFTextKit2RowFrame.Kind(TextKit2OwnerKind.list) == .list)
        #expect(ADFTextKit2RowFrame.Kind(TextKit2OwnerKind.code) == .code)
        #expect(ADFTextKit2RowFrame.Kind.code.rawValue == "code")
    }

    struct NoMedia: ADFMediaProvider {
        func image(for attrs: MediaAttrs, targetSize: CGSize) async throws -> Image {
            throw CancellationError()
        }
    }

    static let document = """
    {"version":1,"type":"doc","content":[
      {"type":"heading","attrs":{"level":2},"content":[{"type":"text","text":"Code below"}]},
      {"type":"codeBlock","attrs":{"language":"swift"},"content":[{"type":"text","text":"let answer = 42\\nprint(answer)"}]},
      {"type":"paragraph","content":[{"type":"text","text":"After the code."}]}
    ]}
    """

    @Test("through the document view: the walk finds the code row on screen, and reads without laying out or drawing")
    func documentViewWalkIsReadOnly() async throws {
        let model = ADFDocumentModel()
        model.load(data: Data(Self.document.utf8))
        for _ in 0..<500 where model.phase != .ready {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.phase == .ready)
        let codeID = try #require(model.blocks.first { if case .codeBlock = $0.kind { return true } else { return false } }?.id)
        let headingID = try #require(model.blocks.first?.id)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let host = UIHostingController(rootView: ADFDocumentView(model: model, mediaProvider: NoMedia(), textRenderer: .textKit2))
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        for _ in 0..<5 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }

        // No suspension from here to the last counter read.
        let diagnostics = TextKit2Diagnostics.shared
        let before = [diagnostics.layoutCount, diagnostics.drawCount, diagnostics.liveRowCount, diagnostics.conversionCount]
        let frames = ADFTextRenderer.textKit2RowFrames(in: window)
        let again = ADFTextRenderer.textKit2RowFrames(in: window)
        let after = [diagnostics.layoutCount, diagnostics.drawCount, diagnostics.liveRowCount, diagnostics.conversionCount]
        #expect(before == after, "the walk laid out, drew, made or converted something: \(before) → \(after)")
        #expect(frames == again)

        let code = try #require(frames.first { $0.ownerID == codeID }, "no code row in \(frames.map(\.ownerID))")
        #expect(code.kind == .code)
        let visible = try #require(code.visible)
        #expect(window.bounds.contains(visible))
        #expect(visible.width > 0 && visible.height > 0)
        let heading = try #require(frames.first { $0.ownerID == headingID })
        #expect(heading.kind == .root)
        #expect(heading.frame.maxY <= code.frame.minY, "heading \(heading.frame) not above code \(code.frame)")
    }

    @Test("the fully visible rows: a set from iOS 18 (empty for a model never shown), nil before")
    func fullyVisibleRowIDs() {
        let model = ADFDocumentModel()
        if #available(iOS 18.0, *) {
            #expect(model.fullyVisibleRowIDs == [])
            model.search.visibleRows.setVisible("0.3", true)
            model.search.visibleRows.setVisible("0.4", true)
            model.search.visibleRows.setVisible("0.3", false)
            #expect(model.fullyVisibleRowIDs == ["0.4"])
        } else {
            #expect(model.fullyVisibleRowIDs == nil)
        }
    }
}
#endif
