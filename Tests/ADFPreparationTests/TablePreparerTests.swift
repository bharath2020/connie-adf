import Foundation
import Testing
import ADFModel
import ADFPreparation

@Suite("TablePreparer")
struct TablePreparerTests {
    private let preparer = DocumentPreparer(theme: .default)

    private func slices(in blocks: [RenderBlock]) -> [(id: String, layout: PreparedTableLayout, rows: [PreparedTableRow], isHeader: Bool)] {
        blocks.compactMap { block in
            guard case .tableSlice(let layout, let rows, let isHeader) = block.kind else { return nil }
            return (block.id, layout, rows, isHeader)
        }
    }

    @Test("800-row table slices into 1 header slice + 40 row slices with stable ids")
    func giantTableSlicing() async throws {
        let doc = try await ADFParser().parse(fixtureData("giant-table.json"))
        let blocks = preparer.prepare(doc)
        let tableSlices = slices(in: blocks)

        let headerSlices = tableSlices.filter(\.isHeader)
        let rowSlices = tableSlices.filter { !$0.isHeader }
        #expect(headerSlices.count == 1)
        #expect(rowSlices.count == 40)
        #expect(rowSlices.allSatisfy { $0.rows.count == 20 })
        #expect(rowSlices.flatMap(\.rows).count == 800)

        let header = try #require(headerSlices.first)
        #expect(header.rows.count == 1)
        #expect(header.rows.first?.cells.allSatisfy(\.isHeader) == true)

        // Shared layout metadata.
        let layout = try #require(tableSlices.first).layout
        #expect(layout.columnCount == 6)
        #expect(layout.columnWidths == Array(repeating: 160, count: 6))
        #expect(tableSlices.allSatisfy { $0.layout == layout })

        // Stable + unique IDs across re-preparation.
        let ids = blocks.map(\.id)
        #expect(Set(ids).count == ids.count)
        let again = DocumentPreparer(theme: .default).prepare(doc)
        #expect(again == blocks)
    }

    @Test("headerless table emits only row slices")
    func headerlessTable() async throws {
        let doc = try await parseDoc("""
        {"version":1,"type":"doc","content":[
          {"type":"table","content":[
            {"type":"tableRow","content":[{"type":"tableCell","content":[{"type":"paragraph","content":[{"type":"text","text":"a"}]}]}]},
            {"type":"tableRow","content":[{"type":"tableCell","content":[{"type":"paragraph","content":[{"type":"text","text":"b"}]}]}]}
          ]}
        ]}
        """)
        let tableSlices = slices(in: preparer.prepare(doc))
        #expect(tableSlices.count == 1)
        let slice = try #require(tableSlices.first)
        #expect(!slice.isHeader)
        #expect(slice.rows.count == 2)
        #expect(slice.layout.columnCount == 1)
        #expect(slice.layout.columnWidths == nil)
    }

    @Test("colspan widens the column count")
    func colspanColumnCount() async throws {
        let doc = try await parseDoc("""
        {"version":1,"type":"doc","content":[
          {"type":"table","content":[
            {"type":"tableRow","content":[
              {"type":"tableCell","attrs":{"colspan":2},"content":[{"type":"paragraph","content":[{"type":"text","text":"wide"}]}]},
              {"type":"tableCell","content":[{"type":"paragraph","content":[{"type":"text","text":"one"}]}]}
            ]}
          ]}
        ]}
        """)
        let tableSlices = slices(in: preparer.prepare(doc))
        let slice = try #require(tableSlices.first)
        #expect(slice.layout.columnCount == 3)
        #expect(slice.rows.first?.cells.first?.colspan == 2)
    }
}
