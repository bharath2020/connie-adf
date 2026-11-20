import Foundation
import Testing
import ADFModel
import ADFPreparation

// Pins for the list fixtures (lists-parity, list-dense, list-tall,
// lists-links) and for
// the three ways a list item's trailing blocks can hold a `.listRows`.
//
// Every expected value here was derived by hand from the fixture structure
// documented in `Tools/make-fixtures.swift` (node paths are `0.<root>.<child>…`)
// and from the documented list rules (markers keyed to same-type nesting,
// continuation rows `<itemID>#cont<N>` after a nested list, trailing lists
// prepared as fresh roots) — not read back from the preparer. A failure means
// list preparation, IDs or block counts moved, which the TextKit 2 list stage
// must not do (the perf gate compares READY block counts across arms).

// MARK: - Helpers

private func listRows(_ block: RenderBlock?) throws -> [PreparedListRow] {
    guard let block, case .listRows(let rows) = block.kind else {
        throw TestFailure("block \(block?.id ?? "nil") is not listRows")
    }
    return rows
}

/// The row's text with atoms dropped (fixture sentinels are plain text).
private func leaderText(_ segments: [InlineSegment]) -> String {
    segments.reduce(into: "") { result, segment in
        if case .text(let text) = segment { result += String(text.characters) }
    }
}

private func hasAtom(_ segments: [InlineSegment]) -> Bool {
    segments.contains { if case .atom = $0 { true } else { false } }
}

private func hasLink(_ segments: [InlineSegment]) -> Bool {
    segments.contains { segment in
        guard case .text(let text) = segment else { return false }
        return text.runs.contains { $0.link != nil }
    }
}

/// Link URLs in reading order (a link split over adjacent runs counts once).
private func linkURLs(_ segments: [InlineSegment]) -> [String] {
    var urls: [String] = []
    var previous: URL?
    for segment in segments {
        guard case .text(let text) = segment else {
            previous = nil
            continue
        }
        for run in text.runs {
            if let link = run.link, link != previous { urls.append(link.absoluteString) }
            previous = run.link
        }
    }
    return urls
}

private func kindName(_ kind: RenderBlock.Kind) -> String {
    switch kind {
    case .richText: "richText"
    case .codeBlock: "codeBlock"
    case .listRows: "listRows"
    case .panel: "panel"
    case .quote: "quote"
    case .divider: "divider"
    case .tableSlice: "tableSlice"
    case .media: "media"
    case .mediaStrip: "mediaStrip"
    case .expand: "expand"
    case .layoutColumns: "layoutColumns"
    case .card: "card"
    case .custom: "custom"
    case .extensionPlaceholder: "extensionPlaceholder"
    case .unknown: "unknown"
    }
}

private func preparedFixture(_ name: String) async throws -> (ADFDocument, [RenderBlock]) {
    let document = try await ADFParser().parse(try fixtureData(name))
    return (document, DocumentPreparer(theme: .default).prepare(document))
}

// MARK: - Trailing `.listRows` origins (Fable F4)

/// A list item's direct nested list is always flattened into deeper rows.
/// A `.listRows` reaches an item's `trailingBlocks` only through a node the
/// item walk hands to the block preparer whole: a sync block (transparent),
/// a structural node outside its container (renders its children), or a
/// non-item child of a task/decision list (walked as an item). The trailing
/// list is prepared as a fresh root: depth restarts at 0 and same-type
/// marker levels restart.
@Suite("Trailing listRows origins")
struct TrailingListRowsOriginTests {
    private let preparer = DocumentPreparer(theme: .default)

    @Test("a direct nested list is flattened, never trailing")
    func directNestedListFlattens() async throws {
        let doc = try await parseDoc("""
        {"version":1,"type":"doc","content":[
          {"type":"bulletList","content":[{"type":"listItem","content":[
            {"type":"paragraph","content":[{"type":"text","text":"leader"}]},
            {"type":"orderedList","content":[{"type":"listItem","content":[
              {"type":"paragraph","content":[{"type":"text","text":"nested"}]}
            ]}]}
          ]}]}
        ]}
        """)
        let rows = try listRows(preparer.prepare(doc).first)
        #expect(rows.map(\.id) == ["0.0.0", "0.0.0.1.0"])
        #expect(rows.map(\.depth) == [0, 1])
        #expect(rows.allSatisfy { $0.trailingBlocks.isEmpty })
    }

    @Test("a list inside a sync block in a list item is a trailing listRows", arguments: ["bodiedSyncBlock", "syncBlock"])
    func syncBlockOrigin(syncType: String) async throws {
        let doc = try await parseDoc("""
        {"version":1,"type":"doc","content":[
          {"type":"bulletList","content":[{"type":"listItem","content":[
            {"type":"paragraph","content":[{"type":"text","text":"leader"}]},
            {"type":"\(syncType)","attrs":{"resourceId":"ari:cloud:confluence:site/s","localId":"s"},"content":[
              {"type":"orderedList","content":[{"type":"listItem","content":[
                {"type":"paragraph","content":[{"type":"text","text":"synced"}]}
              ]}]}
            ]}
          ]}]}
        ]}
        """)
        let blocks = preparer.prepare(doc)
        #expect(blocks.count == 1)
        let rows = try listRows(blocks.first)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.id == "0.0.0")
        #expect(leaderText(row.segments) == "leader")
        #expect(row.trailingBlocks.map(\.id) == ["0.0.0.1.0"])
        let nested = try listRows(row.trailingBlocks.first)
        #expect(nested.map(\.id) == ["0.0.0.1.0.0"])
        #expect(nested.map(\.depth) == [0])
        #expect(nested.map(\.marker) == [.ordered("1.")])
    }

    @Test(
        "a list under a structural node outside its container is a trailing listRows",
        arguments: [
            ("listItem", ""),
            ("taskItem", #","attrs":{"localId":"t","state":"TODO"}"#),
            ("decisionItem", #","attrs":{"localId":"d","state":"DECIDED"}"#),
            ("tableRow", ""),
            ("tableCell", ""),
            ("layoutColumn", #","attrs":{"width":50}"#),
        ]
    )
    func malformedItemChildOrigin(wrapper: String, attrs: String) async throws {
        let doc = try await parseDoc("""
        {"version":1,"type":"doc","content":[
          {"type":"bulletList","content":[{"type":"listItem","content":[
            {"type":"paragraph","content":[{"type":"text","text":"leader"}]},
            {"type":"\(wrapper)"\(attrs),"content":[
              {"type":"bulletList","content":[{"type":"listItem","content":[
                {"type":"paragraph","content":[{"type":"text","text":"stray"}]}
              ]}]}
            ]}
          ]}]}
        ]}
        """)
        #expect(doc.issues.isEmpty)
        let rows = try listRows(preparer.prepare(doc).first)
        #expect(rows.map(\.id) == ["0.0.0"])
        let row = try #require(rows.first)
        #expect(row.trailingBlocks.map(\.id) == ["0.0.0.1.0"])
        let nested = try listRows(row.trailingBlocks.first)
        #expect(nested.map(\.id) == ["0.0.0.1.0.0"])
        #expect(nested.map(\.depth) == [0])
        // A fresh root: bullet level 0 again, though the host is a bullet.
        #expect(nested.map(\.marker) == [.bullet(depth: 0)])
    }

    @Test("a non-taskItem inside a taskList walks as an item and can hold a trailing listRows")
    func nonTaskItemOrigin() async throws {
        let doc = try await parseDoc("""
        {"version":1,"type":"doc","content":[
          {"type":"taskList","attrs":{"localId":"tl"},"content":[
            {"type":"taskItem","attrs":{"localId":"t1","state":"DONE"},"content":[{"type":"text","text":"real task"}]},
            {"type":"bulletList","content":[{"type":"listItem","content":[
              {"type":"paragraph","content":[{"type":"text","text":"stray leader"}]},
              {"type":"bulletList","content":[{"type":"listItem","content":[
                {"type":"paragraph","content":[{"type":"text","text":"stray nested"}]}
              ]}]}
            ]}]}
          ]}
        ]}
        """)
        let rows = try listRows(preparer.prepare(doc).first)
        #expect(rows.map(\.id) == ["0.0.0", "0.0.1"])
        #expect(rows.map(\.marker) == [.task(id: "0.0.0", done: true), .task(id: "0.0.1", done: false)])
        #expect(rows.map(\.depth) == [0, 0])
        #expect(rows[0].trailingBlocks.isEmpty)
        // The stray bulletList's listItem is a structural child: its
        // paragraph and its nested list both become trailing blocks.
        let stray = rows[1]
        #expect(stray.segments.isEmpty)
        #expect(stray.trailingBlocks.map(\.id) == ["0.0.1.0.0", "0.0.1.0.1"])
        #expect(stray.trailingBlocks.map { kindName($0.kind) } == ["richText", "listRows"])
        let nested = try listRows(stray.trailingBlocks.last)
        #expect(nested.map(\.id) == ["0.0.1.0.1.0"])
        #expect(nested.map(\.depth) == [0])
        #expect(nested.map(\.marker) == [.bullet(depth: 0)])
    }

    @Test("a non-decisionItem inside a decisionList walks as an item and can hold a trailing listRows")
    func nonDecisionItemOrigin() async throws {
        let doc = try await parseDoc("""
        {"version":1,"type":"doc","content":[
          {"type":"decisionList","attrs":{"localId":"dl"},"content":[
            {"type":"decisionItem","attrs":{"localId":"d1","state":"DECIDED"},"content":[{"type":"text","text":"real decision"}]},
            {"type":"orderedList","content":[{"type":"listItem","content":[
              {"type":"paragraph","content":[{"type":"text","text":"stray leader"}]},
              {"type":"orderedList","attrs":{"order":5},"content":[{"type":"listItem","content":[
                {"type":"paragraph","content":[{"type":"text","text":"stray nested"}]}
              ]}]}
            ]}]}
          ]}
        ]}
        """)
        let rows = try listRows(preparer.prepare(doc).first)
        #expect(rows.map(\.id) == ["0.0.0", "0.0.1"])
        #expect(rows.map(\.marker) == [.decision, .decision])
        let stray = rows[1]
        #expect(stray.segments.isEmpty)
        #expect(stray.trailingBlocks.map(\.id) == ["0.0.1.0.0", "0.0.1.0.1"])
        #expect(stray.trailingBlocks.map { kindName($0.kind) } == ["richText", "listRows"])
        let nested = try listRows(stray.trailingBlocks.last)
        #expect(nested.map(\.id) == ["0.0.1.0.1.0"])
        #expect(nested.map(\.depth) == [0])
        #expect(nested.map(\.marker) == [.ordered("5.")])
    }
}

// MARK: - lists-parity

@Suite("lists-parity preparation")
struct ListsParityPreparationTests {
    @Test("root blocks: 21 prepared roots, 7 of them lists, in fixture order")
    func rootBlocks() async throws {
        let (document, blocks) = try await preparedFixture("lists-parity.json")
        #expect(document.issues.isEmpty)
        #expect(blocks.map(\.id) == [
            "0.0", "0.1", "0.2", "0.3", "0.4", "0.5", "0.6", "0.7", "0.8", "0.9",
            "0.10", "0.11", "0.12", "0.13", "0.14", "0.15", "0.16#header", "0.16#rows0",
            "0.17", "0.18", "0.19",
        ])
        #expect(blocks.map { kindName($0.kind) } == [
            "richText", "listRows", "richText", "listRows", "richText", "listRows", "listRows",
            "richText", "listRows", "richText", "listRows", "richText", "listRows", "richText",
            "panel", "quote", "tableSlice", "tableSlice", "expand", "layoutColumns", "richText",
        ])
        let rowCounts = try blocks.filter { kindName($0.kind) == "listRows" }
            .map { "\($0.id)=\(try listRows($0).count)" }
        #expect(rowCounts == ["0.1=12", "0.3=12", "0.5=8", "0.6=4", "0.8=13", "0.10=9", "0.12=2"])
    }

    @Test("nesting chain: depth 0–4, markers keyed to same-type nesting")
    func nestingChain() async throws {
        let (_, blocks) = try await preparedFixture("lists-parity.json")
        let rows = try listRows(blocks.first { $0.id == "0.1" })
        #expect(rows.map(\.id) == [
            "0.1.0", "0.1.0.1.0", "0.1.0.1.0.1.0", "0.1.0.1.0.1.0.1.0", "0.1.0.1.0.1.0.1.0.1.0",
            "0.1.0.1.0.1.0.1.1", "0.1.0.1.0.1.1", "0.1.0.1.1",
            "0.1.1", "0.1.1.1.0", "0.1.1.1.0.1.0", "0.1.1.1.0.1.0.1.0",
        ])
        #expect(rows.map(\.depth) == [0, 1, 2, 3, 4, 3, 2, 1, 0, 1, 2, 3])
        #expect(rows.map(\.marker) == [
            .bullet(depth: 0), .ordered("1."), .bullet(depth: 1), .ordered("a."), .bullet(depth: 2),
            .ordered("b."), .bullet(depth: 1), .ordered("2."),
            .bullet(depth: 0), .bullet(depth: 1), .bullet(depth: 2), .bullet(depth: 3),
        ])
        #expect(rows.map { leaderText($0.segments).prefix { $0 != " " } } == [
            "LP-BULLET-L1-A", "LP-ORDERED-L2-A", "LP-BULLET-L3-A", "LP-ORDERED-L4-A", "LP-BULLET-L5-A",
            "LP-ORDERED-L4-B", "LP-BULLET-L3-B", "LP-ORDERED-L2-B",
            "LP-BULLET-L1-B", "LP-BULLET-SAME-L2", "LP-BULLET-SAME-L3", "LP-BULLET-SAME-L4",
        ])
        #expect(rows.allSatisfy { $0.trailingBlocks.isEmpty })
    }

    @Test("ordered starts and marker boundaries: 9→10, z→aa, viii→ix→x, 99→100")
    func orderedBoundaries() async throws {
        let (_, blocks) = try await preparedFixture("lists-parity.json")
        let rows = try listRows(blocks.first { $0.id == "0.3" })
        #expect(rows.map(\.id) == [
            "0.3.0", "0.3.1", "0.3.1.1.0", "0.3.1.1.1", "0.3.1.1.1.1.0", "0.3.1.1.1.1.1",
            "0.3.1.1.1.1.1.1.0", "0.3.1.1.1.1.1.1.1", "0.3.1.1.1.1.2", "0.3.1.1.2", "0.3.2", "0.3.3",
        ])
        #expect(rows.map(\.depth) == [0, 0, 1, 1, 2, 2, 3, 3, 2, 1, 0, 0])
        #expect(rows.map(\.marker) == [
            "8.", "9.", "y.", "z.", "viii.", "ix.", "99.", "100.", "x.", "aa.", "10.", "11.",
        ].map(ListMarker.ordered))
    }

    @Test("task and decision rows: done flags, sibling-nested task lists, empty task")
    func taskAndDecisionRows() async throws {
        let (_, blocks) = try await preparedFixture("lists-parity.json")
        let tasks = try listRows(blocks.first { $0.id == "0.5" })
        #expect(tasks.map(\.id) == ["0.5.0", "0.5.1", "0.5.2.0", "0.5.2.1", "0.5.2.2.0", "0.5.3", "0.5.4", "0.5.5"])
        #expect(tasks.map(\.depth) == [0, 0, 1, 1, 2, 0, 0, 0])
        #expect(tasks.map(\.marker) == [
            .task(id: "0.5.0", done: false), .task(id: "0.5.1", done: true),
            .task(id: "0.5.2.0", done: false), .task(id: "0.5.2.1", done: true),
            .task(id: "0.5.2.2.0", done: false), .task(id: "0.5.3", done: false),
            .task(id: "0.5.4", done: true), .task(id: "0.5.5", done: false),
        ])
        #expect(tasks.filter { hasAtom($0.segments) }.map(\.id) == ["0.5.3"])
        #expect(tasks.filter { hasLink($0.segments) }.map(\.id) == ["0.5.4"])
        #expect(tasks.filter { $0.segments.isEmpty }.map(\.id) == ["0.5.5"])
        #expect(tasks.allSatisfy { $0.trailingBlocks.isEmpty })

        let decisions = try listRows(blocks.first { $0.id == "0.6" })
        #expect(decisions.map(\.id) == ["0.6.0", "0.6.1", "0.6.2", "0.6.3"])
        #expect(decisions.allSatisfy { $0.marker == .decision && $0.depth == 0 && $0.trailingBlocks.isEmpty })
        #expect(decisions.filter { hasAtom($0.segments) }.map(\.id) == ["0.6.1"])
        #expect(decisions.filter { hasLink($0.segments) }.map(\.id) == ["0.6.2"])
    }

    @Test("leader content: atom, link, empty and code-first rows")
    func leaderContentRows() async throws {
        let (_, blocks) = try await preparedFixture("lists-parity.json")
        let rows = try listRows(blocks.first { $0.id == "0.8" })
        #expect(rows.map(\.id) == (0 ... 12).map { "0.8.\($0)" })
        #expect(rows.allSatisfy { $0.depth == 0 && $0.marker == .bullet(depth: 0) })
        // Mention, status and date are atoms; the Unicode row's emoji node
        // has a text form and stays text, and the text-less (custom) emoji
        // is one U+FFFC in the text run, keyed on its row.
        #expect(rows.filter { hasAtom($0.segments) }.map(\.id) == ["0.8.7", "0.8.8", "0.8.9"])
        #expect(rows.filter { !$0.emojiKeys.isEmpty }.map(\.id) == ["0.8.10"])
        #expect(rows[10].emojiKeys == [EmojiKey(id: nil, shortName: ":lp-custom:")])
        #expect(leaderText(rows[10].segments) == "LP-ATOM-EMOJI custom \u{FFFC}")
        #expect(rows.filter { hasLink($0.segments) }.map(\.id) == ["0.8.2"])
        #expect(rows.filter { $0.segments.isEmpty }.map(\.id) == ["0.8.11", "0.8.12"])
        #expect(leaderText(rows[4].segments).hasSuffix("🚀 text emoji"))
        #expect(leaderText(rows[3].segments) == "LP-BREAK-A first line\nsecond line after a hard break\nthird line")
        // Code-block first child: the marker row is empty and both children
        // are trailing blocks, in order.
        #expect(rows[12].trailingBlocks.map(\.id) == ["0.8.12.0", "0.8.12.1"])
        #expect(rows[12].trailingBlocks.map { kindName($0.kind) } == ["codeBlock", "richText"])
        #expect(rows[0 ... 11].allSatisfy { $0.trailingBlocks.isEmpty })
    }

    @Test("item structure: multi-paragraph, continuations `<itemID>#cont<N>`, trailing heading, embedded blocks")
    func itemStructureRows() async throws {
        let (_, blocks) = try await preparedFixture("lists-parity.json")
        let rows = try listRows(blocks.first { $0.id == "0.10" })
        #expect(rows.map(\.id) == [
            "0.10.0", "0.10.1", "0.10.1.1.0", "0.10.1.1.1", "0.10.1#cont1",
            "0.10.1.3.0", "0.10.1#cont2", "0.10.2", "0.10.3",
        ])
        #expect(rows.map(\.depth) == [0, 0, 1, 1, 0, 1, 0, 0, 0])
        #expect(rows.map(\.marker) == [
            .ordered("1."), .ordered("2."), .bullet(depth: 0), .bullet(depth: 0), .continuation,
            .bullet(depth: 0), .continuation, .ordered("3."), .ordered("4."),
        ])
        #expect(rows.map(\.trailingBlocks).map { $0.map(\.id) } == [
            ["0.10.0.1", "0.10.0.2"],
            [], [], [],
            ["0.10.1.2"],
            [],
            ["0.10.1.4", "0.10.1.5"],
            ["0.10.2.1", "0.10.2.2", "0.10.2.3", "0.10.2.4", "0.10.2.5#header", "0.10.2.5#rows0", "0.10.2.6"],
            [],
        ])
        #expect(rows[7].trailingBlocks.map { kindName($0.kind) } == [
            "codeBlock", "panel", "quote", "expand", "tableSlice", "tableSlice", "divider",
        ])
        // Continuation rows carry no leader text of their own.
        #expect(rows[4].segments.isEmpty && rows[6].segments.isEmpty)
        guard case .richText(let headingSegments, let headingStyle) = try #require(rows[6].trailingBlocks.last).kind else {
            throw TestFailure("0.10.1.5 is not richText")
        }
        #expect(headingStyle.isHeading)
        #expect(headingStyle.headingLevel == 3)
        #expect(leaderText(headingSegments) == "LP-CONT-HEADING trailing heading after a nested list")
    }

    @Test("trailing listRows in the fixture: sync block and malformed item child")
    func fixtureTrailingLists() async throws {
        let (_, blocks) = try await preparedFixture("lists-parity.json")
        let rows = try listRows(blocks.first { $0.id == "0.12" })
        #expect(rows.map(\.id) == ["0.12.0", "0.12.1"])
        #expect(rows.map { $0.trailingBlocks.map(\.id) } == [["0.12.0.1.0"], ["0.12.1.1.0"]])
        let synced = try listRows(rows[0].trailingBlocks.first)
        #expect(synced.map(\.id) == ["0.12.0.1.0.0", "0.12.0.1.0.1"])
        #expect(synced.map(\.depth) == [0, 0])
        #expect(synced.map(\.marker) == [.bullet(depth: 0), .bullet(depth: 0)])
        let malformed = try listRows(rows[1].trailingBlocks.first)
        #expect(malformed.map(\.id) == ["0.12.1.1.0.0"])
        #expect(malformed.map(\.marker) == [.ordered("1.")])
        #expect(leaderText(malformed[0].segments) == "LP-MALFORMED-NESTED-A")
    }

    @Test("search units: one per non-empty leader and trailing text owner, none for continuation rows")
    func searchUnits() async throws {
        let (_, blocks) = try await preparedFixture("lists-parity.json")
        let units = SearchIndexer(theme: .default).units(for: blocks)
        #expect(units.count == 96)
        #expect(!units.contains { $0.ownerID.contains("#cont") })

        // Every unit carries exactly one distinct LP- sentinel first.
        let sentinel = try Regex("LP-[A-Z0-9-]*[A-Z0-9]")
        let firstSentinels = units.compactMap { unit in
            unit.plainText.firstMatch(of: sentinel).map { String(unit.plainText[$0.range]) }
        }
        #expect(firstSentinels.count == units.count)
        #expect(Set(firstSentinels).count == units.count)

        let structure = units.filter { $0.topLevelBlockID == "0.10" }
        #expect(structure.map(\.ownerID) == [
            "0.10.0", "0.10.0.1", "0.10.0.2",
            "0.10.1", "0.10.1.1.0", "0.10.1.1.1", "0.10.1.2", "0.10.1.3.0", "0.10.1.4", "0.10.1.5",
            "0.10.2", "0.10.2.1", "0.10.2.2.0", "0.10.2.3.0", "0.10.2.4.0", "0.10.2.5.0.0.0", "0.10.2.5.1.0.0",
            "0.10.3",
        ])
        let continuation = try #require(structure.first { $0.ownerID == "0.10.1.2" })
        #expect(continuation.plainText == "LP-CONT-PARA-1 continuation paragraph after the first nested list")
        #expect(structure.filter { !$0.expandAncestorIDs.isEmpty }.map(\.ownerID) == ["0.10.2.4.0"])
        #expect(structure.first { $0.ownerID == "0.10.2.4.0" }?.expandAncestorIDs == ["0.10.2.4"])

        let leaders = units.filter { $0.topLevelBlockID == "0.8" }
        #expect(leaders.map(\.ownerID) == (0 ... 10).map { "0.8.\($0)" } + ["0.8.12.0", "0.8.12.1"])
        let mention = try #require(leaders.first { $0.ownerID == "0.8.7" })
        #expect(mention.plainText == "LP-ATOM-MENTION ping @LP Reviewer today")
        #expect(mention.parts.contains { $0.source == .atom(id: "0.8.7.0.1") })

        #expect(units.filter { $0.topLevelBlockID == "0.12" }.map(\.ownerID) == [
            "0.12.0", "0.12.0.1.0.0", "0.12.0.1.0.1", "0.12.1", "0.12.1.1.0.0",
        ])
        #expect(units.filter { $0.topLevelBlockID == "0.5" }.map(\.ownerID) == [
            "0.5.0", "0.5.1", "0.5.2.0", "0.5.2.1", "0.5.2.2.0", "0.5.3", "0.5.4",
        ])
        let inExpand = units.filter { $0.topLevelBlockID == "0.17" }
        #expect(inExpand.map(\.ownerID) == ["0.17.0.0", "0.17.1.0", "0.17.2.0"])
        #expect(inExpand.allSatisfy { $0.expandAncestorIDs == ["0.17"] })
        #expect(units.filter { $0.topLevelBlockID == "0.16#rows0" }.map(\.ownerID) == [
            "0.16.1.0.0.0", "0.16.1.0.0.1", "0.16.1.1.0.0",
        ])
        #expect(units.filter { $0.topLevelBlockID == "0.18" }.map(\.ownerID) == [
            "0.18.0.0.0", "0.18.1.0.0", "0.18.1.1.0",
        ])
    }
}

// MARK: - list-tall and list-dense

@Suite("list-tall and list-dense preparation")
struct ListPerfFixturePreparationTests {
    @Test("list-tall: one 316-row ordered root plus a 1-row closing list")
    func listTall() async throws {
        let (document, blocks) = try await preparedFixture("list-tall.json")
        #expect(document.issues.isEmpty)
        #expect(blocks.map(\.id) == ["0.0", "0.1"])
        let rows = try listRows(blocks.first)
        // 200 items + 50 nested 2-item bullet lists (i % 4 == 1) + 16
        // continuations (i ≡ 9 mod 12).
        #expect(rows.count == 316)
        let items = rows.filter { $0.depth == 0 && $0.marker != .continuation }
        #expect(items.map(\.marker) == (1 ... 200).map { ListMarker.ordered("\($0).") })
        #expect(items.map(\.id) == (0 ..< 200).map { "0.0.\($0)" })
        let nested = rows.filter { $0.depth == 1 }
        #expect(nested.count == 100)
        #expect(nested.allSatisfy { $0.marker == .bullet(depth: 0) })
        let continuations = rows.filter { $0.marker == .continuation }
        #expect(continuations.map(\.id) == stride(from: 9, to: 200, by: 12).map { "0.0.\($0)#cont1" })
        #expect(continuations.allSatisfy { $0.depth == 0 && $0.segments.isEmpty && $0.trailingBlocks.count == 1 })
        #expect(rows.allSatisfy { !hasAtom($0.segments) && !hasLink($0.segments) })
        #expect(try listRows(blocks.last).count == 1)
    }

    @Test("list-dense: 600 list roots split 210/180/120/90 by family")
    func listDense() async throws {
        let (document, blocks) = try await preparedFixture("list-dense.json")
        #expect(document.issues.isEmpty)
        #expect(blocks.count == 600)
        var families: [String: Int] = [:]
        var rowCount = 0
        var continuationRows = 0
        for (index, block) in blocks.enumerated() {
            #expect(block.id == "0.\(index)")
            let rows = try listRows(block)
            rowCount += rows.count
            continuationRows += rows.filter { $0.marker == .continuation }.count
            let first = try #require(rows.first)
            let family = switch first.marker {
            case .bullet: "bullet"
            case .ordered: "ordered"
            case .task: "task"
            case .decision: "decision"
            default: "other"
            }
            families[family, default: 0] += 1
            #expect(leaderText(first.segments).hasPrefix("LD-" + String(repeating: "0", count: 3 - String(index).count) + String(index)))
        }
        #expect(families == ["bullet": 210, "ordered": 180, "task": 120, "decision": 90])
        // Generator emission tally (Tools/make-fixtures.swift prints it):
        // 3,396 items + 302 continuation rows.
        #expect(rowCount == 3_698)
        #expect(continuationRows == 302)
    }
}

// MARK: - lists-links

/// The linked list text the interaction UI tests tap (exact-URL routing):
/// every link owner, its URLs in order, and the row structure around them.
@Suite("lists-links preparation")
struct ListsLinksPreparationTests {
    private static func url(_ slug: String) -> String { "https://example.com/lists-links/" + slug }

    @Test("root blocks: 6 prepared roots, 3 of them lists")
    func rootBlocks() async throws {
        let (document, blocks) = try await preparedFixture("lists-links.json")
        #expect(document.issues.isEmpty)
        #expect(blocks.map(\.id) == ["0.0", "0.1", "0.2", "0.3", "0.4", "0.5"])
        #expect(blocks.map { kindName($0.kind) } == ["richText", "listRows", "richText", "listRows", "listRows", "richText"])
    }

    @Test("leaders: ten bullet items, a nested bullet, one continuation row; no atoms")
    func leaderRows() async throws {
        let (_, blocks) = try await preparedFixture("lists-links.json")
        let rows = try listRows(blocks.first { $0.id == "0.1" })
        #expect(rows.map(\.id) == (0 ... 8).map { "0.1.\($0)" } + ["0.1.8.1.0", "0.1.8#cont1", "0.1.9"])
        #expect(rows.map(\.depth) == [0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0])
        #expect(rows.map(\.marker) == Array(repeating: ListMarker.bullet(depth: 0), count: 9)
            + [.bullet(depth: 1), .continuation, .bullet(depth: 0)])
        #expect(rows.map { $0.trailingBlocks.map(\.id) } == Array(repeating: [], count: 10) + [["0.1.8.2"], ["0.1.9.1"]])
        #expect(!rows.contains { hasAtom($0.segments) })
        #expect(leaderText(rows[2].segments) == "LL-EMOJI-LINK rocket 🚀launch notes✅ shipped")
        #expect(leaderText(rows[4].segments) == "שלום קישור מימין לשמאל עולם LL-RTL-LINK-B")
        #expect(leaderText(rows[6].segments) == "LL-LATER-LINK first line\nsecond line with a later-line link 🚀")
    }

    @Test("every link owner routes its own URLs, in order; controls have none")
    func linkOwners() async throws {
        let (_, blocks) = try await preparedFixture("lists-links.json")
        var urls: [String: [String]] = [:]
        for block in blocks {
            guard case .listRows(let rows) = block.kind else { continue }
            for row in rows {
                urls[row.id] = linkURLs(row.segments)
                for trailing in row.trailingBlocks {
                    if case .richText(let segments, _) = trailing.kind { urls[trailing.id] = linkURLs(segments) }
                }
            }
        }
        let expected: [String: [String]] = [
            "0.1.0": [Self.url("wrap")], "0.1.1": [Self.url("colour")], "0.1.2": [Self.url("emoji")],
            "0.1.3": [Self.url("rtl-hebrew")], "0.1.4": [Self.url("rtl-paragraph")], "0.1.5": [Self.url("rtl-ltr-link")],
            "0.1.6": [Self.url("later-line")], "0.1.7": [Self.url("first"), Self.url("second")],
            "0.1.8": [], "0.1.8.1.0": [], "0.1.8#cont1": [], "0.1.8.2": [Self.url("continuation")],
            "0.1.9": [], "0.1.9.1": [Self.url("trailing-paragraph")],
            "0.3.0": [Self.url("task")], "0.3.1": [], "0.4.0": [Self.url("decision")], "0.4.1": [],
        ]
        #expect(urls == expected)
    }

    @Test("task and decision rows: one linked, one plain control each")
    func taskAndDecisionRows() async throws {
        let (_, blocks) = try await preparedFixture("lists-links.json")
        let tasks = try listRows(blocks.first { $0.id == "0.3" })
        #expect(tasks.map(\.marker) == [.task(id: "0.3.0", done: false), .task(id: "0.3.1", done: true)])
        #expect(tasks.map { leaderText($0.segments) } == [
            "LL-TASK-LINK task with a linked task spec", "LL-TASK-PLAIN plain control task",
        ])
        let decisions = try listRows(blocks.first { $0.id == "0.4" })
        #expect(decisions.map(\.id) == ["0.4.0", "0.4.1"])
        #expect(decisions.allSatisfy { $0.marker == .decision && $0.depth == 0 && $0.trailingBlocks.isEmpty })
        #expect(decisions.map { leaderText($0.segments) } == [
            "LL-DECISION-LINK see the linked decision record", "LL-DECISION-PLAIN plain control decision",
        ])
    }
}
