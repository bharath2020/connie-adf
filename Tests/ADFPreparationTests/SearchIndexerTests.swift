import Foundation
import Testing
import ADFModel
@testable import ADFPreparation

@Suite("SearchIndexer")
struct SearchIndexerTests {
    private let theme = ADFTheme.default
    private var indexer: SearchIndexer { SearchIndexer(theme: theme) }

    private func prepared(_ json: String) async throws -> [RenderBlock] {
        DocumentPreparer(theme: theme).prepare(try await parseDoc(json))
    }

    @Test("a paragraph yields one unit whose plain text and part map cover the whole text")
    func paragraphUnit() async throws {
        let blocks = try await prepared("""
        {"version":1,"type":"doc","content":[{"type":"paragraph","content":[
          {"type":"text","text":"Hello "},
          {"type":"text","text":"world","marks":[{"type":"strong"}]}
        ]}]}
        """)
        let units = indexer.units(for: blocks)
        let unit = try #require(units.first)
        #expect(units.count == 1)
        #expect(unit.plainText == "Hello world")
        #expect(unit.ownerID == blocks[0].id)
        #expect(unit.topLevelBlockID == blocks[0].id)
        #expect(unit.expandAncestorIDs.isEmpty)
        // Adjacent text runs merge into ONE segment at preparation time.
        #expect(unit.parts == [
            SearchTextUnit.Part(source: .textSegment(index: 0), range: 0..<11)
        ])
    }

    @Test("atoms contribute fallback text and their own part with the node ID")
    func atomUnit() async throws {
        let blocks = try await prepared("""
        {"version":1,"type":"doc","content":[{"type":"paragraph","content":[
          {"type":"text","text":"ask "},
          {"type":"mention","attrs":{"id":"u1","text":"@bob"}},
          {"type":"text","text":" now"}
        ]}]}
        """)
        let unit = try #require(indexer.units(for: blocks).first)
        #expect(unit.plainText == "ask @bob now")
        // Word-chunk splitting (atoms present) makes "ask " chunk 0, the atom
        // segment 1, then " now" is split at the leading space boundary.
        let atomPart = try #require(unit.parts.first { part in
            if case .atom = part.source { return true }
            return false
        })
        #expect(atomPart.range == 4..<8)
        guard case .atom(let id) = atomPart.source else {
            Issue.record("expected atom part"); return
        }
        #expect(id.isEmpty == false)
        // Every character of plainText is covered by exactly one part, in order.
        var covered = 0
        for part in unit.parts {
            #expect(part.range.lowerBound == covered)
            covered = part.range.upperBound
        }
        #expect(covered == unit.plainText.count)
    }

    @Test("code blocks yield a unit from the raw code text")
    func codeBlockUnit() async throws {
        let blocks = try await prepared("""
        {"version":1,"type":"doc","content":[{"type":"codeBlock","attrs":{"language":"swift"},"content":[
          {"type":"text","text":"let x = 1"}
        ]}]}
        """)
        let unit = try #require(indexer.units(for: blocks).first)
        #expect(unit.plainText == "let x = 1")
        #expect(unit.ownerID == blocks[0].id)
        #expect(unit.parts == [SearchTextUnit.Part(source: .textSegment(index: 0), range: 0..<9)])
    }

    @Test("list rows yield one unit per row, owned by the row ID")
    func listRowUnits() async throws {
        let blocks = try await prepared("""
        {"version":1,"type":"doc","content":[{"type":"bulletList","content":[
          {"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"first"}]}]},
          {"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"second"}]}]}
        ]}]}
        """)
        guard case .listRows(let rows) = blocks[0].kind else {
            Issue.record("expected listRows"); return
        }
        let units = indexer.units(for: blocks)
        #expect(units.map(\.plainText) == ["first", "second"])
        #expect(units.map(\.ownerID) == rows.map(\.id))
        #expect(units.allSatisfy { $0.topLevelBlockID == blocks[0].id })
    }

    @Test("empty and whitespace-only text yields no unit")
    func emptyTextSkipped() async throws {
        let blocks = try await prepared("""
        {"version":1,"type":"doc","content":[{"type":"paragraph","content":[]}]}
        """)
        #expect(indexer.units(for: blocks).isEmpty)
    }

    @Test("panel and quote children yield units addressed to the top-level container")
    func containerRecursion() async throws {
        let blocks = try await prepared("""
        {"version":1,"type":"doc","content":[
          {"type":"panel","attrs":{"panelType":"info"},"content":[
            {"type":"paragraph","content":[{"type":"text","text":"inside panel"}]}
          ]},
          {"type":"blockquote","content":[
            {"type":"paragraph","content":[{"type":"text","text":"inside quote"}]}
          ]}
        ]}
        """)
        let units = indexer.units(for: blocks)
        #expect(units.map(\.plainText) == ["inside panel", "inside quote"])
        #expect(units[0].topLevelBlockID == blocks[0].id)
        #expect(units[1].topLevelBlockID == blocks[1].id)
        // The owner is the INNER paragraph block (what the view keys on),
        // not the container.
        #expect(units[0].ownerID != blocks[0].id)
    }

    @Test("table cell text maps to the enclosing slice for scrolling")
    func tableCellUnits() async throws {
        let blocks = try await prepared("""
        {"version":1,"type":"doc","content":[{"type":"table","content":[
          {"type":"tableRow","content":[
            {"type":"tableHeader","content":[{"type":"paragraph","content":[{"type":"text","text":"head"}]}]}
          ]},
          {"type":"tableRow","content":[
            {"type":"tableCell","content":[{"type":"paragraph","content":[{"type":"text","text":"body cell"}]}]}
          ]}
        ]}]}
        """)
        // Preparer slices: [<id>#header, <id>#rows0].
        #expect(blocks.count == 2)
        let units = indexer.units(for: blocks)
        #expect(units.map(\.plainText) == ["head", "body cell"])
        #expect(units[0].topLevelBlockID == blocks[0].id)
        #expect(units[0].topLevelBlockID.hasSuffix("#header"))
        #expect(units[1].topLevelBlockID == blocks[1].id)
        #expect(units[1].topLevelBlockID.hasSuffix("#rows0"))
    }

    @Test("layout columns and extension bodies recurse")
    func layoutAndExtensionRecursion() async throws {
        let blocks = try await prepared("""
        {"version":1,"type":"doc","content":[
          {"type":"layoutSection","content":[
            {"type":"layoutColumn","attrs":{"width":50},"content":[
              {"type":"paragraph","content":[{"type":"text","text":"left col"}]}
            ]},
            {"type":"layoutColumn","attrs":{"width":50},"content":[
              {"type":"paragraph","content":[{"type":"text","text":"right col"}]}
            ]}
          ]}
        ]}
        """)
        let units = indexer.units(for: blocks)
        #expect(units.map(\.plainText) == ["left col", "right col"])
        #expect(units.allSatisfy { $0.topLevelBlockID == blocks[0].id })
    }

    @Test("kitchen-sink fixture indexes without gaps in any unit's part map")
    func fixtureIndexesGapFree() async throws {
        let doc = try await ADFParser().parse(fixtureData("kitchen-sink.json"))
        let blocks = DocumentPreparer(theme: theme).prepare(doc)
        let units = indexer.units(for: blocks)
        #expect(units.count > 10)
        for unit in units {
            var covered = 0
            for part in unit.parts {
                #expect(part.range.lowerBound == covered, "gap in \(unit.ownerID)")
                covered = part.range.upperBound
            }
            #expect(covered == unit.plainText.count, "short map in \(unit.ownerID)")
        }
    }

    @Test("collapsed expand bodies are indexed with the expand as ancestor")
    func expandBodyIndexed() async throws {
        let blocks = try await prepared("""
        {"version":1,"type":"doc","content":[{"type":"expand","attrs":{"title":"More"},"content":[
          {"type":"paragraph","content":[{"type":"text","text":"hidden treasure"}]}
        ]}]}
        """)
        let unit = try #require(indexer.units(for: blocks).first)
        #expect(unit.plainText == "hidden treasure")
        #expect(unit.expandAncestorIDs == [blocks[0].id])
        #expect(unit.topLevelBlockID == blocks[0].id)
        // Owner is the INNER paragraph's block id — the id the expanded view
        // will render it under.
        #expect(unit.ownerID != blocks[0].id)
    }

    @Test("nested expands accumulate the ancestor chain outermost-first")
    func nestedExpandChain() async throws {
        let blocks = try await prepared("""
        {"version":1,"type":"doc","content":[{"type":"expand","attrs":{"title":"Outer"},"content":[
          {"type":"nestedExpand","attrs":{"title":"Inner"},"content":[
            {"type":"paragraph","content":[{"type":"text","text":"deep"}]}
          ]}
        ]}]}
        """)
        let unit = try #require(indexer.units(for: blocks).first { $0.plainText == "deep" })
        #expect(unit.expandAncestorIDs.count == 2)
        #expect(unit.expandAncestorIDs.first == blocks[0].id)
        #expect(unit.topLevelBlockID == blocks[0].id)
    }
}
