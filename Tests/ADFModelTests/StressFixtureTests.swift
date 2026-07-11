import Foundation
import Testing
@testable import ADFModel

/// Validates the generated stress fixtures (`Tools/make-fixtures.swift`):
/// every fixture must parse with zero issues and zero `.unknown` nodes,
/// and honor the generator's structural contract.
@Suite("Stress fixtures")
struct StressFixtureTests {
    @Test("generated fixtures parse with zero issues and zero unknown nodes",
          arguments: ["stress-5k.json", "giant-table.json", "media-gallery.json"])
    func parsesCleanly(name: String) async throws {
        let doc = try await parseFixture(name)
        #expect(doc.issues.isEmpty, "issues in \(name): \(doc.issues.prefix(5))")
        #expect(unknownNodes(in: doc.root).isEmpty, "unknown nodes in \(name)")
        #expect(doc.version == 1)
    }

    @Test("stress-5k has 5,000 mixed top-level blocks")
    func stress5KShape() async throws {
        let doc = try await parseFixture("stress-5k.json")
        #expect(doc.root.children.count == 5000)

        let topLevelTypes = Set(doc.root.children.map(\.type))
        let expected: Set<String> = ["paragraph", "heading", "bulletList", "orderedList", "codeBlock", "panel", "blockquote"]
        #expect(expected.subtracting(topLevelTypes).isEmpty,
                "missing block families: \(expected.subtracting(topLevelTypes).sorted())")

        // Lists nest 4 deep: bulletList -> listItem -> ... -> list, 4 list levels.
        func maxListDepth(_ node: ADFNode) -> Int {
            let isList = node.type == "bulletList" || node.type == "orderedList"
            let childMax = node.children.map(maxListDepth).max() ?? 0
            return childMax + (isList ? 1 : 0)
        }
        let deepest = doc.root.children.map(maxListDepth).max() ?? 0
        #expect(deepest >= 4, "expected 4-deep nested lists, got \(deepest)")
    }

    @Test("giant-table has a header row plus 800 data rows of 6 columns with sprinkled colspans and backgrounds")
    func giantTableShape() async throws {
        let doc = try await parseFixture("giant-table.json")
        let table = try #require(allNodes(in: doc.root).first { $0.type == "table" })
        guard case .table(_, let rows) = table.kind else {
            Issue.record("expected .table, got \(table.kind)")
            return
        }
        #expect(rows.count == 801)

        var sawHeaderRow = false
        var sawColspan = false
        var sawBackground = false
        for (index, row) in rows.enumerated() {
            guard case .tableRow(let cells) = row.kind else {
                Issue.record("expected .tableRow at index \(index)")
                return
            }
            var columns = 0
            for cell in cells {
                guard case .tableCell(let attrs, _, let isHeader) = cell.kind else {
                    Issue.record("expected .tableCell in row \(index)")
                    return
                }
                columns += attrs.colspan
                if attrs.colspan > 1 { sawColspan = true }
                if attrs.backgroundHex != nil { sawBackground = true }
                if index == 0 { sawHeaderRow = isHeader }
            }
            #expect(columns == 6, "row \(index) spans \(columns) columns, expected 6")
        }
        #expect(sawHeaderRow)
        #expect(sawColspan)
        #expect(sawBackground)
    }

    @Test("media-gallery has 300 external mediaSingles with dimensions and every layout")
    func mediaGalleryShape() async throws {
        let doc = try await parseFixture("media-gallery.json")
        let singles = allNodes(in: doc.root).filter { $0.type == "mediaSingle" }
        #expect(singles.count == 300)

        var layouts: Set<ADFMediaLayout> = []
        for single in singles {
            guard case .mediaSingle(let layout, _, _, let content) = single.kind else {
                Issue.record("expected .mediaSingle, got \(single.kind)")
                return
            }
            layouts.insert(layout)

            let media = try #require(content.first { $0.type == "media" })
            guard case .media(let attrs, _) = media.kind else {
                Issue.record("expected .media, got \(media.kind)")
                return
            }
            guard case .external(let url) = attrs.source else {
                Issue.record("expected external media source, got \(attrs.source)")
                return
            }
            #expect(url.hasPrefix("placeholder://"))
            #expect(attrs.width != nil && attrs.height != nil)
        }
        let allLayouts: Set<ADFMediaLayout> = [.center, .wrapLeft, .wrapRight, .alignStart, .alignEnd, .wide, .fullWidth]
        #expect(layouts == allLayouts, "missing layouts: \(allLayouts.subtracting(layouts))")
    }
}
