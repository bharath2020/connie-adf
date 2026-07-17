import Foundation
import SwiftUI
import Testing
import ADFModel
import ADFPreparation
@testable import ADFRendering

/// Claims every `blockCard`, declaring the sizing handed in.
private struct CardClaimer: ADFCustomBlockRenderer {
    let rendererID = "test.cards"
    var sizing: ADFCustomBlockSizing = .aspectRatio(width: 16, height: 9)
    var searchableText: String? = nil

    func claim(for node: ADFNode) -> ADFCustomBlockClaim? {
        guard case .blockCard(let url, _) = node.kind else { return nil }
        return ADFCustomBlockClaim(url ?? "", sizing: sizing, searchableText: searchableText)
    }

    @MainActor
    func content(for value: String, context: ADFCustomBlockContext) -> some View {
        Text(value)
    }
}

@MainActor
private func waitUntil(
    _ what: Comment,
    timeoutIterations: Int = 2_000,
    _ condition: () -> Bool
) async throws {
    for _ in 0..<timeoutIterations {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("timed out waiting for \(what)")
    throw CustomBlockTestFailure(what: "\(what)")
}

private struct CustomBlockTestFailure: Error { let what: String }

private let cardDocument = """
{"version":1,"type":"doc","content":[
  {"type":"paragraph","content":[{"type":"text","text":"before"}]},
  {"type":"blockCard","attrs":{"url":"https://example.com/video"}},
  {"type":"expand","attrs":{"title":"More"},"content":[
    {"type":"blockCard","attrs":{"url":"https://example.com/hidden"}}]}
]}
"""

@Suite("Custom block rendering contracts")
struct CustomBlockRenderingTests {
    /// Prepares one claimed block with the given sizing, through the public
    /// pipeline (the claim loop stamps rendererID; the internal init is not
    /// reachable from tests, by design).
    private func customKind(sizing: ADFCustomBlockSizing) async throws -> RenderBlock.Kind {
        let json = #"{"version":1,"type":"doc","content":[{"type":"blockCard","attrs":{"url":"https://example.com/v"}}]}"#
        let doc = try await ADFParser().parse(Data(json.utf8))
        let plugin = CardClaimer(sizing: sizing)
        let blocks = DocumentPreparer(theme: .default, customPreparers: [plugin]).prepare(doc)
        return blocks[0].kind
    }

    @Test("aspectRatio sizing maps to width-proportional spacers capped at maxWidth, ignoring text size")
    func aspectRatioMapping() async throws {
        let kind = try await customKind(sizing: .aspectRatio(width: 16, height: 9, maxWidth: 640))
        #expect(kind.heightScaling == .proportional(cap: 640, fixedOverhead: 16))
        #expect(kind.typeSizeRescaleFactor(bodyPointRatio: 1.3) == 1)
    }

    @Test("uncapped aspectRatio tracks the column at any width")
    func uncappedAspect() async throws {
        let kind = try await customKind(sizing: .aspectRatio(width: 16, height: 9))
        #expect(kind.heightScaling == .proportional(cap: nil, fixedOverhead: 16))
    }

    @Test("scaledChrome maps to width-invariant spacers that scale linearly with text")
    func scaledChromeMapping() async throws {
        let kind = try await customKind(sizing: .scaledChrome)
        #expect(kind.heightScaling == .invariant)
        #expect(kind.typeSizeRescaleFactor(bodyPointRatio: 1.3) == 1.3)
    }

    @Test("reflowingText maps to reflowing spacers that scale quadratically with text")
    func reflowingMapping() async throws {
        let kind = try await customKind(sizing: .reflowingText)
        #expect(kind.heightScaling == .reflowing)
        let ratio: CGFloat = 1.3
        #expect(kind.typeSizeRescaleFactor(bodyPointRatio: ratio) == ratio * ratio)
    }

    @Test("custom rows carry the COMPLETE row height affinely: the aspect box scales, the fixed padding does not")
    func spacerCarry() async throws {
        let kind = try await customKind(sizing: .aspectRatio(width: 16, height: 9))
        var heights = CollapsedRowHeight()
        // Record what DocumentRow measures: the 16:9 box PLUS the row's
        // 8 pt top + bottom vertical padding.
        heights.record(height: 360 * 9 / 16 + 16, at: 360)
        // Unseen width: only the box scales; the padding carries unchanged —
        // the affine carry is exact for an uncapped aspect box.
        #expect(heights.height(at: 720, scaling: kind.heightScaling) == CGFloat(720) * 9 / 16 + 16)
        // Type size change: a video box does not track the text.
        heights.rescale(by: kind.typeSizeRescaleFactor(bodyPointRatio: 1.5))
        #expect(heights.height(at: 360, scaling: kind.heightScaling) == CGFloat(360) * 9 / 16 + 16)
    }

    @Test("the portrait-to-landscape carry matches the real landscape row height")
    func portraitLandscapeAffineCarry() async throws {
        // The review's measured case: 361 pt portrait column → 640 pt
        // landscape column. A whole-measurement proportional carry
        // overstated the landscape row by ~12.4 pt per collapsed video row.
        let kind = try await customKind(sizing: .aspectRatio(width: 16, height: 9))
        var heights = CollapsedRowHeight()
        heights.record(height: CGFloat(361) * 9 / 16 + 16, at: 361)
        let carried = try #require(heights.height(at: 640, scaling: kind.heightScaling))
        let actualLandscapeRow = CGFloat(640) * 9 / 16 + 16
        #expect(abs(carried - actualLandscapeRow) < 0.001)
    }
}

@Suite("Custom block search integration")
@MainActor
struct CustomBlockSearchIntegrationTests {
    private func readyModel(searchableText: String?) async throws -> ADFDocumentModel {
        let model = ADFDocumentModel(
            customRenderers: [CardClaimer(searchableText: searchableText)]
        )
        model.load(data: Data(cardDocument.utf8))
        try await waitUntil("document ready") { model.phase == .ready }
        model.search.debounceInterval = .zero
        return model
    }

    @Test("a matched custom block publishes whole-block atom highlights, never spans")
    func atomHighlightPublication() async throws {
        let model = try await readyModel(searchableText: "watch the keynote video")
        model.search.run("keynote")
        try await waitUntil("scan done") { !model.search.isSearching && model.search.matchCount > 0 }
        #expect(model.search.matchCount == 2) // top-level card + card inside the expand

        let blockID = model.blocks[1].id
        let highlights = model.search.ownerHighlights(for: blockID)
        #expect(highlights.spans.isEmpty)
        #expect(highlights.atomIDs == [blockID])
        // The current match (auto-selected first) is the top-level card.
        #expect(highlights.currentAtomIDs == [blockID])
        #expect(model.scrollTarget == blockID)
    }

    @Test("navigating to a match inside a collapsed expand opens the expand")
    func expandReveal() async throws {
        let model = try await readyModel(searchableText: "watch the keynote video")
        model.search.run("keynote")
        try await waitUntil("scan done") { !model.search.isSearching && model.search.matchCount == 2 }
        #expect(model.expandedBlocks.isEmpty == false || model.search.currentIndex == 0)

        model.search.next() // into the expand's card
        let expandID = model.blocks[2].id
        #expect(model.expandedBlocks.contains(expandID))
        #expect(model.scrollTarget == expandID)
    }

    @Test("with searchableText nil the corpus is unchanged and custom blocks never match")
    func nilTextStaysOut() async throws {
        let model = try await readyModel(searchableText: nil)
        model.search.run("example.com")
        try await waitUntil("scan settled") { !model.search.isSearching }
        #expect(model.search.matchCount == 0)
    }
}
