import Foundation
import Testing
import ADFModel
import ADFPreparation
@testable import ADFYouTube

@Suite("YouTubeBlockRenderer claims")
struct YouTubeBlockRendererTests {
    private let renderer = YouTubeBlockRenderer()

    private func prepare(_ json: String) async throws -> [RenderBlock] {
        let doc = try await ADFParser().parse(Data(json.utf8))
        return DocumentPreparer(theme: .default, customPreparers: [renderer]).prepare(doc)
    }

    private func firstVideo(_ blocks: [RenderBlock]) -> YouTubeVideo? {
        guard case .custom(let custom) = blocks.first?.kind else { return nil }
        return custom.value.value(as: YouTubeVideo.self)
    }

    @Test("claims an embedCard with a watchable URL as a 16:9 video block")
    func embedCard() async throws {
        let blocks = try await prepare(#"""
        {"version":1,"type":"doc","content":[
          {"type":"embedCard","attrs":{"url":"https://www.youtube.com/watch?v=dQw4w9WgXcQ","layout":"center","width":100}}
        ]}
        """#)
        #expect(firstVideo(blocks)?.videoID == "dQw4w9WgXcQ")
        guard case .custom(let custom) = blocks[0].kind else { return }
        #expect(custom.rendererID == "adfkit.youtube")
        #expect(custom.sizing == .aspectRatio(width: 16, height: 9, maxWidth: nil))
        #expect(custom.searchableText == nil)
    }

    @Test("claims a blockCard via youtu.be")
    func blockCard() async throws {
        let blocks = try await prepare(#"""
        {"version":1,"type":"doc","content":[
          {"type":"blockCard","attrs":{"url":"https://youtu.be/9bZkp7q19f0"}}
        ]}
        """#)
        #expect(firstVideo(blocks)?.videoID == "9bZkp7q19f0")
    }

    @Test("claims a paragraph that is exactly one smart link")
    func soloInlineCardParagraph() async throws {
        let blocks = try await prepare(#"""
        {"version":1,"type":"doc","content":[
          {"type":"paragraph","content":[
            {"type":"inlineCard","attrs":{"url":"https://www.youtube.com/shorts/aqz-KE-bpKQ"}}
          ]}
        ]}
        """#)
        #expect(firstVideo(blocks)?.videoID == "aqz-KE-bpKQ")
    }

    @Test("whitespace siblings around the smart link do not block the claim")
    func whitespaceTolerated() async throws {
        let blocks = try await prepare(#"""
        {"version":1,"type":"doc","content":[
          {"type":"paragraph","content":[
            {"type":"text","text":"  "},
            {"type":"inlineCard","attrs":{"url":"https://youtu.be/9bZkp7q19f0"}},
            {"type":"text","text":" "}
          ]}
        ]}
        """#)
        #expect(firstVideo(blocks)?.videoID == "9bZkp7q19f0")
    }

    @Test("claims a bare link-marked text paragraph")
    func bareLinkParagraph() async throws {
        let blocks = try await prepare(#"""
        {"version":1,"type":"doc","content":[
          {"type":"paragraph","content":[
            {"type":"text","text":"https://www.youtube.com/watch?v=jNQXAC9IVRw",
             "marks":[{"type":"link","attrs":{"href":"https://www.youtube.com/watch?v=jNQXAC9IVRw"}}]}
          ]}
        ]}
        """#)
        #expect(firstVideo(blocks)?.videoID == "jNQXAC9IVRw")
    }

    @Test("declines links mid-sentence, non-video YouTube pages, and other hosts")
    func declines() async throws {
        let blocks = try await prepare(#"""
        {"version":1,"type":"doc","content":[
          {"type":"paragraph","content":[
            {"type":"text","text":"watch "},
            {"type":"inlineCard","attrs":{"url":"https://www.youtube.com/watch?v=dQw4w9WgXcQ"}},
            {"type":"text","text":" later"}
          ]},
          {"type":"blockCard","attrs":{"url":"https://vimeo.com/76979871"}},
          {"type":"blockCard","attrs":{"url":"https://www.youtube.com/playlist?list=PLBCF2DAC6FFB574DE"}},
          {"type":"embedCard","attrs":{"url":"https://example.atlassian.net/wiki/x","layout":"center"}}
        ]}
        """#)
        let hasCustom = blocks.contains { block in
            if case .custom = block.kind { return true }
            return false
        }
        #expect(!hasCustom)
        #expect(blocks.count == 4)
    }

    @Test("the youtube fixture prepares to exactly the expected video blocks")
    func fixtureShape() async throws {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        url.appendPathComponent("Fixtures/youtube.json")
        let doc = try await ADFParser().parse(Data(contentsOf: url))
        let blocks = DocumentPreparer(theme: .default, customPreparers: [renderer]).prepare(doc)

        var claimedIDs: [String] = []
        var stack = blocks
        while let block = stack.popLast() {
            switch block.kind {
            case .custom(let custom):
                let video = custom.value.value(as: YouTubeVideo.self)
                claimedIDs.append(video?.videoID ?? "?")
            case .panel(_, let children), .quote(let children):
                stack.append(contentsOf: children)
            case .tableSlice(_, let rows, _):
                stack.append(contentsOf: rows.flatMap { $0.cells.flatMap(\.blocks) })
            case .listRows(let rows):
                stack.append(contentsOf: rows.flatMap(\.trailingBlocks))
            default:
                break
            }
        }
        // Top-level embed + block cards, solo-inlineCard paragraph, bare-link
        // paragraph, the panel's solo link, and the table cell's embed. The
        // expand body stays unprepared until opened; the controls section
        // claims nothing.
        #expect(claimedIDs.sorted() == [
            "5qap5aO4i9A", "9bZkp7q19f0", "M7lc1UVf-VE",
            "aqz-KE-bpKQ", "dQw4w9WgXcQ", "jNQXAC9IVRw",
        ])
    }
}
