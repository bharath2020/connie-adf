import Foundation
import Testing
import ADFModel
import ADFPreparation

/// Claims any `blockCard` whose URL contains a marker substring.
private struct CardClaimer: ADFCustomBlockPreparer {
    let rendererID: String
    var marker = "claim-me"
    var searchableText: String?

    func claim(for node: ADFNode) -> ADFCustomBlockClaim? {
        guard case .blockCard(let url, _) = node.kind, url?.contains(marker) == true else {
            return nil
        }
        return ADFCustomBlockClaim(
            url ?? "",
            sizing: .aspectRatio(width: 16, height: 9),
            searchableText: searchableText
        )
    }
}

/// Claims nothing — for non-interference checks.
private struct NeverClaimer: ADFCustomBlockPreparer {
    let rendererID = "test.never"
    func claim(for node: ADFNode) -> ADFCustomBlockClaim? { nil }
}

@Suite("Custom block preparation")
struct CustomBlockTests {
    private let claimer = CardClaimer(rendererID: "test.cards")

    private func prepare(_ json: String, plugins: [any ADFCustomBlockPreparer]) async throws -> [RenderBlock] {
        let doc = try await parseDoc(json)
        return DocumentPreparer(theme: .default, customPreparers: plugins).prepare(doc)
    }

    private static let claimableCard = #"{"type":"blockCard","attrs":{"url":"https://example.com/claim-me/1"}}"#

    @Test("a claimed node becomes one custom block with the claimer's rendererID stamped")
    func claimStampsRendererID() async throws {
        let blocks = try await prepare(
            #"{"version":1,"type":"doc","content":[\#(Self.claimableCard)]}"#,
            plugins: [claimer]
        )
        #expect(blocks.count == 1)
        guard case .custom(let custom) = blocks[0].kind else {
            Issue.record("expected .custom, got \(blocks[0].kind)")
            return
        }
        #expect(custom.rendererID == "test.cards")
        #expect(custom.value.value(as: String.self) == "https://example.com/claim-me/1")
        #expect(custom.sizing == .aspectRatio(width: 16, height: 9, maxWidth: nil))
        #expect(blocks[0].id == "0.0")
    }

    @Test("a declined node keeps its built-in rendering")
    func declineFallsThrough() async throws {
        let blocks = try await prepare(
            #"{"version":1,"type":"doc","content":[{"type":"blockCard","attrs":{"url":"https://example.com/other"}}]}"#,
            plugins: [claimer]
        )
        guard case .card = blocks[0].kind else {
            Issue.record("expected .card, got \(blocks[0].kind)")
            return
        }
    }

    @Test("first registered claimer wins ties")
    func firstClaimWins() async throws {
        let second = CardClaimer(rendererID: "test.second")
        let blocks = try await prepare(
            #"{"version":1,"type":"doc","content":[\#(Self.claimableCard)]}"#,
            plugins: [claimer, second]
        )
        guard case .custom(let custom) = blocks[0].kind else {
            Issue.record("expected .custom")
            return
        }
        #expect(custom.rendererID == "test.cards")
    }

    @Test("claims are intercepted inside panels, quotes, table cells, layout columns, and list trailing blocks")
    func nestedInterception() async throws {
        let json = #"""
        {"version":1,"type":"doc","content":[
          {"type":"panel","attrs":{"panelType":"info"},"content":[\#(Self.claimableCard)]},
          {"type":"blockquote","content":[\#(Self.claimableCard)]},
          {"type":"table","content":[{"type":"tableRow","content":[
            {"type":"tableCell","content":[\#(Self.claimableCard)]}]}]},
          {"type":"layoutSection","content":[
            {"type":"layoutColumn","attrs":{"width":100},"content":[\#(Self.claimableCard)]}]},
          {"type":"bulletList","content":[{"type":"listItem","content":[
            {"type":"paragraph","content":[{"type":"text","text":"item"}]},
            \#(Self.claimableCard)]}]}
        ]}
        """#
        let kinds = collectKinds(try await prepare(json, plugins: [claimer]))
        let customCount = kinds.count { kind in
            if case .custom = kind { return true }
            return false
        }
        #expect(customCount == 5)
    }

    /// Claims paragraphs containing a marker string (paragraphs, unlike
    /// cards, can carry block-level marks such as `breakout`).
    private struct ParagraphClaimer: ADFCustomBlockPreparer {
        let rendererID = "test.paragraphs"
        func claim(for node: ADFNode) -> ADFCustomBlockClaim? {
            guard case .paragraph = node.kind else { return nil }
            return ADFCustomBlockClaim("p", sizing: .reflowingText)
        }
    }

    @Test("block-level breakout marks carry onto claimed blocks")
    func breakoutCarries() async throws {
        let json = #"""
        {"version":1,"type":"doc","content":[
          {"type":"paragraph","content":[{"type":"text","text":"wide one"}],
           "marks":[{"type":"breakout","attrs":{"mode":"wide"}}]}
        ]}
        """#
        let blocks = try await prepare(json, plugins: [ParagraphClaimer()])
        guard case .custom = blocks[0].kind else {
            Issue.record("expected .custom, got \(blocks[0].kind)")
            return
        }
        #expect(blocks[0].breakout?.mode == .wide)
    }

    @Test("preparation with plugins is deterministic")
    func deterministic() async throws {
        let json = #"{"version":1,"type":"doc","content":[\#(Self.claimableCard)]}"#
        let first = try await prepare(json, plugins: [claimer])
        let second = try await prepare(json, plugins: [claimer])
        #expect(first == second)
    }

    @Test("a never-claiming plugin changes nothing on the kitchen-sink fixture")
    func nonInterference() async throws {
        let data = try fixtureData("kitchen-sink.json")
        let doc = try await ADFParser().parse(data)
        let bare = DocumentPreparer(theme: .default).prepare(doc)
        let withPlugin = DocumentPreparer(theme: .default, customPreparers: [NeverClaimer()]).prepare(doc)
        #expect(bare == withPlugin)
    }

    @Test("payload box equality follows the boxed value")
    func valueBoxEquality() {
        #expect(ADFCustomBlockValue("a") == ADFCustomBlockValue("a"))
        #expect(ADFCustomBlockValue("a") != ADFCustomBlockValue("b"))
        #expect(ADFCustomBlockValue("a") != ADFCustomBlockValue(1))
        #expect(ADFCustomBlockValue(1).value(as: String.self) == nil)
        #expect(ADFCustomBlockValue(1).value(as: Int.self) == 1)
        var hashes = Set<ADFCustomBlockValue>()
        hashes.insert(ADFCustomBlockValue("a"))
        hashes.insert(ADFCustomBlockValue("a"))
        #expect(hashes.count == 1)
    }
}
