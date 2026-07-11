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
