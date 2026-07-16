import Foundation
import Testing
import ADFModel
import ADFPreparation

/// Claims any `blockCard` and contributes the given searchable text.
private struct SearchableCardClaimer: ADFCustomBlockPreparer {
    let rendererID = "test.searchable"
    var searchableText: String?

    func claim(for node: ADFNode) -> ADFCustomBlockClaim? {
        guard case .blockCard = node.kind else { return nil }
        return ADFCustomBlockClaim("payload", sizing: .scaledChrome, searchableText: searchableText)
    }
}

@Suite("Custom block search indexing")
struct CustomBlockSearchIndexTests {
    private func units(
        _ json: String,
        plugin: SearchableCardClaimer
    ) async throws -> [SearchTextUnit] {
        let doc = try await parseDoc(json)
        let blocks = DocumentPreparer(theme: .default, customPreparers: [plugin]).prepare(doc)
        return SearchIndexer(theme: .default, customPreparers: [plugin]).units(for: blocks)
    }

    private static let card = #"{"type":"blockCard","attrs":{"url":"https://example.com/x"}}"#

    @Test("searchable text becomes one whole-block atom unit")
    func atomUnitShape() async throws {
        let units = try await units(
            #"{"version":1,"type":"doc","content":[\#(Self.card)]}"#,
            plugin: SearchableCardClaimer(searchableText: "Video: WWDC keynote")
        )
        #expect(units.count == 1)
        let unit = try #require(units.first)
        #expect(unit.plainText == "Video: WWDC keynote")
        #expect(unit.ownerID == "0.0")
        #expect(unit.topLevelBlockID == "0.0")
        #expect(unit.parts.count == 1)
        let part = try #require(unit.parts.first)
        #expect(part.range == 0..<unit.plainText.count)
        guard case .atom(let atomID) = part.source else {
            Issue.record("expected an atom part, got \(part.source)")
            return
        }
        #expect(atomID == "0.0")
    }

    @Test("matches on a custom unit surface as whole-block atom hits, never spans")
    func matchesAreAtomOnly() async throws {
        let doc = try await parseDoc(#"{"version":1,"type":"doc","content":[\#(Self.card)]}"#)
        let plugin = SearchableCardClaimer(searchableText: "WWDC keynote")
        let blocks = DocumentPreparer(theme: .default, customPreparers: [plugin]).prepare(doc)
        let indexer = SearchIndexer(theme: .default, customPreparers: [plugin])
        let item = SearchIndexedItem(id: "0.0", topLevelBlockID: "0.0", units: indexer.units(for: blocks))
        let result = IncrementalSearchIndex.result(for: item, query: "keynote")
        #expect(result.matches.count == 1)
        #expect(result.spansByOwner.isEmpty)
        #expect(result.atomIDsByOwner["0.0"] == ["0.0"])
    }

    @Test("nil and whitespace-only searchable text contribute no unit", arguments: [nil, "   \n"])
    func emptyTextSkipped(text: String?) async throws {
        let units = try await units(
            #"{"version":1,"type":"doc","content":[\#(Self.card)]}"#,
            plugin: SearchableCardClaimer(searchableText: text)
        )
        #expect(units.isEmpty)
    }

    @Test("a claimed node inside an expand body is indexed with its expand ancestry")
    func expandBodyParity() async throws {
        let json = #"""
        {"version":1,"type":"doc","content":[
          {"type":"expand","attrs":{"title":"More"},"content":[\#(Self.card)]}
        ]}
        """#
        let plugin = SearchableCardClaimer(searchableText: "hidden video")
        let unitsWithPlugin = try await units(json, plugin: plugin)
        #expect(unitsWithPlugin.count == 1)
        let unit = try #require(unitsWithPlugin.first)
        #expect(unit.plainText == "hidden video")
        #expect(unit.topLevelBlockID == "0.0")
        #expect(unit.expandAncestorIDs == ["0.0"])
        guard case .atom = try #require(unit.parts.first).source else {
            Issue.record("expected an atom part")
            return
        }
    }

    @Test("an indexer without the plugin sees no custom unit for the same document — the drift the shared configuration prevents")
    func indexerWithoutPluginsDrifts() async throws {
        let json = #"""
        {"version":1,"type":"doc","content":[
          {"type":"expand","attrs":{"title":"More"},"content":[\#(Self.card)]}
        ]}
        """#
        let doc = try await parseDoc(json)
        let plugin = SearchableCardClaimer(searchableText: "hidden video")
        let blocks = DocumentPreparer(theme: .default, customPreparers: [plugin]).prepare(doc)
        let bareIndexer = SearchIndexer(theme: .default)
        #expect(bareIndexer.units(for: blocks).isEmpty)
    }
}
