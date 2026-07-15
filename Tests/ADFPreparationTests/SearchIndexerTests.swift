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
}
