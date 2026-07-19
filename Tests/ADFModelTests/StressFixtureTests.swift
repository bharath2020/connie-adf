import Foundation
import Testing
@testable import ADFModel

/// Validates the generated stress fixtures (`Tools/make-fixtures.swift`):
/// every fixture must parse with zero issues and zero `.unknown` nodes,
/// and honor the generator's structural contract.
@Suite("Stress fixtures")
struct StressFixtureTests {
    @Test("generated fixtures parse with zero issues and zero unknown nodes",
          arguments: ["stress-5k.json", "giant-table.json", "media-gallery.json", "atom-stress.json"])
    func parsesCleanly(name: String) async throws {
        let doc = try await parseFixture(name)
        #expect(doc.issues.isEmpty, "issues in \(name): \(doc.issues.prefix(5))")
        #expect(unknownNodes(in: doc.root).isEmpty, "unknown nodes in \(name)")
        #expect(doc.version == 1)
    }

    /// Task 24 — atom-stress.json: 2,000 paragraphs, each carrying all 7
    /// `InlineAtom` kinds (mention/emoji/date/status/inlineCard/mediaInline/
    /// inlineExtension), for the pill-draw-path stress phase-3 gap #6 named.
    @Test("atom-stress has 2,000 atom-dense paragraphs covering every pill kind")
    func atomStressShape() async throws {
        let doc = try await parseFixture("atom-stress.json")
        let paragraphs = doc.root.children.filter { $0.type == "paragraph" }
        #expect(paragraphs.count == 2000)

        let atomTypes: Set<String> = ["mention", "emoji", "date", "status", "inlineCard", "mediaInline", "inlineExtension"]
        for (index, para) in paragraphs.enumerated() {
            let present = Set(para.children.map(\.type)).intersection(atomTypes)
            #expect(present == atomTypes, "paragraph \(index) missing: \(atomTypes.subtracting(present))")
        }
    }

    @Test("stress-5k has 5,000 mixed top-level blocks")
    func stress5KShape() async throws {
        let doc = try await parseFixture("stress-5k.json")
        #expect(doc.root.children.count == 5000)

        let topLevelTypes = Set(doc.root.children.map(\.type))
        let expected: Set<String> = ["paragraph", "heading", "bulletList", "orderedList", "codeBlock", "panel", "blockquote", "expand"]
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

    @Test("stress-5k expands arrive in groups and cover every node family")
    func stress5KExpands() async throws {
        let doc = try await parseFixture("stress-5k.json")
        let children = doc.root.children

        let expands = children.filter { $0.type == "expand" }
        #expect(expands.count == 500)

        // Expands come in runs of 5 consecutive top-level blocks.
        var runs: [Int] = []
        var run = 0
        for child in children {
            if child.type == "expand" {
                run += 1
            } else if run > 0 {
                runs.append(run)
                run = 0
            }
        }
        if run > 0 { runs.append(run) }
        #expect(runs.count == 100)
        #expect(Set(runs) == [5], "expected runs of 5 expands, got \(Set(runs).sorted())")

        // Union of everything nested inside expands must cover every family.
        var inside: Set<String> = []
        for expand in expands {
            for node in allNodes(in: expand) where node.id != expand.id {
                inside.insert(node.type)
            }
        }
        let expected: Set<String> = [
            "paragraph", "heading", "text", "hardBreak", "rule", "blockquote",
            "bulletList", "orderedList", "listItem", "codeBlock", "panel",
            "taskList", "taskItem", "decisionList", "decisionItem",
            "table", "tableRow", "tableCell", "tableHeader", "nestedExpand",
            "layoutSection", "layoutColumn",
            "mediaSingle", "mediaGroup", "media", "mediaInline", "caption",
            "blockCard", "embedCard", "inlineCard",
            "mention", "emoji", "date", "status", "placeholder",
            "extension", "bodiedExtension", "inlineExtension",
            "syncBlock", "bodiedSyncBlock",
        ]
        #expect(expected.subtracting(inside).isEmpty,
                "node families missing from expands: \(expected.subtracting(inside).sorted())")
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
