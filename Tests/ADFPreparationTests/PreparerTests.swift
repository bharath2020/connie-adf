import Foundation
import Testing
import ADFModel
import ADFPreparation

@Suite("DocumentPreparer")
struct PreparerTests {
    private let preparer = DocumentPreparer(theme: .default)

    @Test("ordered list honors start and uses alphabetic markers at depth 1")
    func orderedListMarkers() async throws {
        let doc = try await parseDoc("""
        {"version":1,"type":"doc","content":[
          {"type":"orderedList","attrs":{"order":4},"content":[
            {"type":"listItem","content":[
              {"type":"paragraph","content":[{"type":"text","text":"four"}]},
              {"type":"orderedList","content":[
                {"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"nested a"}]}]},
                {"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"nested b"}]}]}
              ]}
            ]},
            {"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"five"}]}]}
          ]}
        ]}
        """)
        let blocks = preparer.prepare(doc)
        #expect(blocks.count == 1)
        guard case .listRows(let rows) = try #require(blocks.first).kind else {
            throw TestFailure("block is not listRows")
        }
        #expect(rows.count == 4)
        let depth0 = rows.filter { $0.depth == 0 }.map(\.marker)
        let depth1 = rows.filter { $0.depth == 1 }.map(\.marker)
        #expect(depth0 == [.ordered("4."), .ordered("5.")])
        #expect(depth1 == [.ordered("a."), .ordered("b.")])
    }

    @Test("bullet markers carry their depth")
    func bulletMarkerDepths() async throws {
        let doc = try await parseDoc("""
        {"version":1,"type":"doc","content":[
          {"type":"bulletList","content":[
            {"type":"listItem","content":[
              {"type":"paragraph","content":[{"type":"text","text":"outer"}]},
              {"type":"bulletList","content":[
                {"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"inner"}]}]}
              ]}
            ]}
          ]}
        ]}
        """)
        let blocks = preparer.prepare(doc)
        guard case .listRows(let rows) = try #require(blocks.first).kind else {
            throw TestFailure("block is not listRows")
        }
        #expect(rows.map(\.marker) == [.bullet(depth: 0), .bullet(depth: 1)])
    }

    @Test("listItem children preserve document order: code block before its explanation paragraph")
    func listItemCodeBlockBeforeParagraphKeepsOrder() async throws {
        let doc = try await parseDoc("""
        {"version":1,"type":"doc","content":[
          {"type":"bulletList","content":[
            {"type":"listItem","content":[
              {"type":"codeBlock","attrs":{"language":"swift"},"content":[{"type":"text","text":"let x = 1"}]},
              {"type":"paragraph","content":[{"type":"text","text":"Explanation"}]}
            ]}
          ]}
        ]}
        """)
        let blocks = preparer.prepare(doc)
        guard case .listRows(let rows) = try #require(blocks.first).kind else {
            throw TestFailure("block is not listRows")
        }
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        // The paragraph is not the leading child, so it must NOT be hoisted
        // beside the marker; both children stay in authored order.
        #expect(row.segments.isEmpty)
        #expect(row.trailingBlocks.count == 2)
        guard case .codeBlock = row.trailingBlocks[0].kind else {
            throw TestFailure("first trailing block is not the code block")
        }
        guard case .richText(let segments, _) = row.trailingBlocks[1].kind,
              case .text(let text) = try #require(segments.first) else {
            throw TestFailure("second trailing block is not the paragraph")
        }
        #expect(String(text.characters) == "Explanation")
    }

    @Test("paragraph after a nested list becomes a continuation row below the nested rows")
    func paragraphAfterNestedListKeepsOrder() async throws {
        let doc = try await parseDoc("""
        {"version":1,"type":"doc","content":[
          {"type":"bulletList","content":[
            {"type":"listItem","content":[
              {"type":"paragraph","content":[{"type":"text","text":"Intro"}]},
              {"type":"bulletList","content":[
                {"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"nested"}]}]}
              ]},
              {"type":"paragraph","content":[{"type":"text","text":"Outro"}]}
            ]}
          ]}
        ]}
        """)
        let blocks = preparer.prepare(doc)
        guard case .listRows(let rows) = try #require(blocks.first).kind else {
            throw TestFailure("block is not listRows")
        }
        #expect(rows.count == 3)
        // Row 0: the item's marker row carries only the intro paragraph.
        #expect(rows[0].marker == .bullet(depth: 0))
        #expect(rows[0].trailingBlocks.isEmpty)
        // Row 1: the nested list renders between intro and outro.
        #expect(rows[1].marker == .bullet(depth: 1))
        // Row 2: "Outro" follows the nested list as a marker-less
        // continuation row at the item's own depth.
        #expect(rows[2].marker == .continuation)
        #expect(rows[2].depth == 0)
        guard case .richText(let segments, _) = try #require(rows[2].trailingBlocks.first).kind,
              case .text(let text) = try #require(segments.first) else {
            throw TestFailure("continuation row does not carry the outro paragraph")
        }
        #expect(String(text.characters) == "Outro")
        // IDs stay unique so SwiftUI identity holds.
        let ids = rows.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("breakout marks reach the prepared block for codeBlock, layoutSection, and expand")
    func breakoutReachesPreparedBlocks() async throws {
        let doc = try await parseDoc("""
        {"version":1,"type":"doc","content":[
          {"type":"codeBlock","attrs":{"language":"swift"},
           "marks":[{"type":"breakout","attrs":{"mode":"full-width"}}],
           "content":[{"type":"text","text":"let x = 1"}]},
          {"type":"layoutSection",
           "marks":[{"type":"breakout","attrs":{"mode":"wide","width":1024}}],
           "content":[
             {"type":"layoutColumn","attrs":{"width":50},"content":[{"type":"paragraph","content":[{"type":"text","text":"L"}]}]},
             {"type":"layoutColumn","attrs":{"width":50},"content":[{"type":"paragraph","content":[{"type":"text","text":"R"}]}]}
           ]},
          {"type":"expand","attrs":{"title":"Wide"},
           "marks":[{"type":"breakout","attrs":{"mode":"wide"}}],
           "content":[{"type":"paragraph","content":[{"type":"text","text":"body"}]}]},
          {"type":"paragraph","content":[{"type":"text","text":"plain"}]}
        ]}
        """)
        #expect(doc.issues.isEmpty)
        let blocks = preparer.prepare(doc)
        #expect(blocks.count == 4)
        #expect(blocks[0].breakout == BlockBreakout(mode: .fullWidth, width: nil))
        // The optional custom width survives preparation.
        #expect(blocks[1].breakout == BlockBreakout(mode: .wide, width: 1024))
        #expect(blocks[2].breakout == BlockBreakout(mode: .wide, width: nil))
        #expect(blocks[3].breakout == nil)
    }

    @Test("kitchen sink prepares with zero unknown kinds")
    func kitchenSinkZeroUnknownKinds() async throws {
        let doc = try await ADFParser().parse(fixtureData("kitchen-sink.json"))
        let blocks = preparer.prepare(doc)
        #expect(!blocks.isEmpty)
        let kinds = collectKinds(blocks)
        #expect(!containsUnknown(kinds))
    }

    @Test("kitchen sink covers expand, media with caption, and media strip")
    func kitchenSinkStructuralCoverage() async throws {
        let doc = try await ADFParser().parse(fixtureData("kitchen-sink.json"))
        let blocks = preparer.prepare(doc)

        let expands = blocks.compactMap { block -> (body: [ADFNode], isNested: Bool)? in
            guard case .expand(_, let body, let isNested) = block.kind else { return nil }
            return (body, isNested)
        }
        #expect(expands.contains { !$0.isNested && !$0.body.isEmpty })

        let media = blocks.compactMap { block -> PreparedMedia? in
            guard case .media(let prepared) = block.kind else { return nil }
            return prepared
        }
        #expect(media.contains { $0.caption?.isEmpty == false })

        let strips = blocks.compactMap { block -> [PreparedMedia]? in
            guard case .mediaStrip(let items) = block.kind else { return nil }
            return items
        }
        #expect(strips.contains { $0.count == 2 })
    }

    @Test("unknown node types surface as unknown blocks, never crash")
    func unknownNodeBecomesUnknownBlock() async throws {
        let doc = try await parseDoc("""
        {"version":1,"type":"doc","content":[
          {"type":"whiteboard","attrs":{"id":"wb-1"}},
          {"type":"paragraph","content":[{"type":"text","text":"still here"}]}
        ]}
        """)
        let blocks = preparer.prepare(doc)
        #expect(blocks.count == 2)
        guard case .unknown(let typeName) = try #require(blocks.first).kind else {
            throw TestFailure("first block is not unknown")
        }
        #expect(typeName == "whiteboard")
    }

    @Test("content-less syncBlock renders a placeholder chip, never disappears")
    func emptySyncBlockBecomesPlaceholder() async throws {
        let doc = try await parseDoc("""
        {"version":1,"type":"doc","content":[
          {"type":"syncBlock","attrs":{"resourceId":"ari:cloud:confluence:site/sync-1","localId":"s1"}},
          {"type":"bodiedSyncBlock","attrs":{"resourceId":"ari:cloud:confluence:site/sync-2","localId":"s2"},
           "content":[{"type":"paragraph","content":[{"type":"text","text":"inline copy"}]}]}
        ]}
        """)
        let blocks = preparer.prepare(doc)
        #expect(blocks.count == 2)
        guard case .extensionPlaceholder(let title, let body) = try #require(blocks.first).kind else {
            throw TestFailure("empty syncBlock is not a placeholder block")
        }
        #expect(title == "Synced block")
        #expect(body.isEmpty)
        guard case .richText = try #require(blocks.last).kind else {
            throw TestFailure("bodied syncBlock did not render its content")
        }
    }

    @Test("preparation output is stable across runs")
    func prepareIsDeterministic() async throws {
        let doc = try await ADFParser().parse(fixtureData("kitchen-sink.json"))
        let first = preparer.prepare(doc)
        let second = DocumentPreparer(theme: .default).prepare(doc)
        #expect(first == second)
        let ids = first.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("prepareStream chunks concatenate to the sync prepare output")
    func streamMatchesSyncPrepare() async throws {
        let doc = try await ADFParser().parse(fixtureData("kitchen-sink.json"))
        var streamed: [RenderBlock] = []
        for await chunk in preparer.prepareStream(doc, chunkSize: 5) {
            #expect(!chunk.isEmpty)
            streamed.append(contentsOf: chunk)
        }
        #expect(streamed == preparer.prepare(doc))
    }

    @Test("stress fixture (5k blocks) prepares in under two seconds")
    func stress5kPreparesUnderTwoSeconds() async throws {
        let doc = try await ADFParser().parse(fixtureData("stress-5k.json"))
        let clock = ContinuousClock()
        var blocks: [RenderBlock] = []
        let elapsed = clock.measure {
            blocks = preparer.prepare(doc)
        }
        #expect(blocks.count >= 5_000)
        #expect(elapsed < .seconds(2), "prepare took \(elapsed)")
    }
}
