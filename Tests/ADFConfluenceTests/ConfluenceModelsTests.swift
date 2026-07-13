import Foundation
import Testing
@testable import ADFConfluence

@Suite("Confluence models")
struct ConfluenceModelsTests {
    @Test("decodes a spaces payload")
    func decodesSpaces() throws {
        let json = #"{ "results": [ { "id": "1", "key": "ADFTB", "name": "Test Bed" } ] }"#
        let wrap = try JSONDecoder().decode(ResultsEnvelope<Space>.self, from: Data(json.utf8))
        #expect(wrap.results.count == 1)
        #expect(wrap.results[0].key == "ADFTB")
    }

    @Test("builds an ordered parent/child tree")
    func buildsTree() {
        let s = [
            PageSummary(id: "a", title: "Root A", parentId: nil, position: 1),
            PageSummary(id: "b", title: "Root B", parentId: nil, position: 0),
            PageSummary(id: "b1", title: "Child B1", parentId: "b", position: 0),
        ]
        let roots = PageTree.build(from: s)
        #expect(roots.map(\.id) == ["b", "a"])            // sorted by position
        #expect(roots[0].children.map(\.id) == ["b1"])    // child nested under b
    }
}
