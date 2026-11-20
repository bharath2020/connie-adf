import Foundation
import Testing
import ADFModel
import ADFPreparation

// Pins for PR 4's fixtures: containers-parity, containers-dense,
// containers-expand and captions-parity (Tools/make-fixtures.swift).
//
// The expected values were counted from the fixtures' JSON with standalone
// scripts (a walk of `content`; a table's prepared slices are `#header` and
// `#rows<k>` of two body rows each; a bodied sync block is transparent) and
// from the generator's owner tables (`swift Tools/make-fixtures.swift
// --landmarks`), never read back from the preparer or the indexer. A failure
// means the fixture bytes, preparation, block ids or the search corpus moved;
// PR 4 must not change the last three.

// MARK: - Helpers

private struct PreparedFixture {
    let raw: Data
    let document: ADFDocument
    let blocks: [RenderBlock]
    /// The whole corpus: every expand body is prepared and indexed, as
    /// `ADFDocumentSearch` does.
    let units: [SearchTextUnit]
}

private func preparedFixture(_ name: String) async throws -> PreparedFixture {
    let raw = try fixtureData("\(name).json")
    let document = try await ADFParser().parse(raw)
    let blocks = DocumentPreparer(theme: .default).prepare(document)
    let units = SearchIndexer(theme: .default).units(for: blocks)
    return PreparedFixture(raw: raw, document: document, blocks: blocks, units: units)
}

/// Every node of the parsed tree, depth first, expand bodies included.
private func allNodes(_ node: ADFNode) -> [ADFNode] {
    [node] + node.children.flatMap(allNodes)
}

/// The fixture sentinel in `text`: the earliest occurrence of `prefix`
/// extended over `[A-Z0-9-]`, trailing hyphens dropped (the generator's
/// `sentinelToken`).
private func sentinel(in text: String, prefix: String) -> String? {
    guard let range = text.range(of: prefix) else { return nil }
    var end = range.lowerBound
    while end < text.endIndex, let ascii = text[end].asciiValue,
          (65 ... 90).contains(ascii) || (48 ... 57).contains(ascii) || ascii == 45 {
        end = text.index(after: end)
    }
    var token = String(text[range.lowerBound ..< end])
    while token.hasSuffix("-") { token.removeLast() }
    return token
}

/// One search unit as the pin tables spell it:
/// `<owner> <sentinel> <top-level block> <expand ancestors, comma-joined, or ->`.
private func pinLine(_ unit: SearchTextUnit, prefix: String) -> String {
    let token = sentinel(in: unit.plainText, prefix: prefix) ?? "(no sentinel: \(unit.plainText.prefix(40)))"
    let chain = unit.expandAncestorIDs.isEmpty ? "-" : unit.expandAncestorIDs.joined(separator: ",")
    return "\(unit.ownerID) \(token) \(unit.topLevelBlockID) \(chain)"
}

private func pinLines(_ table: String) -> [String] {
    table.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

/// A paragraph of unmarked text only: no mark, no link, no inline atom
/// (hard breaks allowed when `allowingBreaks`).
private func isPlainParagraph(_ node: ADFNode, allowingBreaks: Bool) -> Bool {
    guard case .paragraph(let content, let marks) = node.kind, marks.isEmpty, !content.isEmpty else { return false }
    return content.allSatisfy { child in
        switch child.kind {
        case .text(_, let marks): marks.isEmpty
        case .hardBreak: allowingBreaks
        default: false
        }
    }
}

@Suite("Container fixture preparation")
struct ContainersFixturePreparationTests {
    static let fixtures = ["containers-parity", "containers-dense", "containers-expand", "captions-parity"]

    /// The token search opens block 0's chain with.
    static let sentinel = "CXOPENSENTINEL"

    // MARK: Parse and prepare

    @Test("each fixture parses with no issue and no unknown node, and prepares no unknown block",
          arguments: fixtures)
    func parsesCleanly(fixture: String) async throws {
        let prepared = try await preparedFixture(fixture)
        #expect(prepared.document.issues.isEmpty, "\(prepared.document.issues)")
        let unknown = allNodes(prepared.document.root).filter { if case .unknown = $0.kind { true } else { false } }
        #expect(unknown.isEmpty, "unknown nodes: \(unknown.map(\.id))")
        #expect(!containsUnknown(collectKinds(prepared.blocks)))
    }

    /// containers-parity: 86 top-level nodes, 87 prepared roots. Node 43 is
    /// a bodied sync block of one paragraph (transparent); node 81 is a
    /// table of a header row and one body row (a header slice and one rows
    /// slice). The other three fixtures prepare one root per node.
    static let containersParityIDs: [String] = {
        var ids = (0...42).map { "0.\($0)" }
        ids.append("0.43.0")
        ids += (44...80).map { "0.\($0)" }
        ids += ["0.81#header", "0.81#rows0"]
        ids += (82...85).map { "0.\($0)" }
        return ids
    }()

    @Test("prepared root ids")
    func preparedRootIDs() async throws {
        let parity = try await preparedFixture("containers-parity")
        #expect(parity.document.root.children.count == 86)
        #expect(parity.blocks.map(\.id) == Self.containersParityIDs)

        let expand = try await preparedFixture("containers-expand")
        #expect(expand.blocks.map(\.id) == (0..<554).map { "0.\($0)" })

        let captions = try await preparedFixture("captions-parity")
        #expect(captions.blocks.map(\.id) == (0..<25).map { "0.\($0)" })

        let dense = try await preparedFixture("containers-dense")
        let count = dense.document.root.children.count
        #expect(dense.blocks.map(\.id) == (0..<count).map { "0.\($0)" })
    }

    // MARK: containers-expand

    @Test("the search sentinel occurs exactly once, alone in its paragraph")
    func sentinelOccursOnce() async throws {
        let prepared = try await preparedFixture("containers-expand")
        let raw = try #require(String(data: prepared.raw, encoding: .utf8)).lowercased()
        #expect(raw.components(separatedBy: Self.sentinel.lowercased()).count - 1 == 1)

        let matching = prepared.units.filter { $0.plainText.lowercased().contains(Self.sentinel.lowercased()) }
        #expect(matching.count == 1)
        #expect(matching.first?.plainText == Self.sentinel)

        // No other fixture carries it.
        for fixture in Self.fixtures where fixture != "containers-expand" {
            let other = try #require(String(data: try fixtureData("\(fixture).json"), encoding: .utf8))
            #expect(!other.lowercased().contains(Self.sentinel.lowercased()), "\(fixture)")
        }
    }

    /// Block 0's search units in order: the outer body (0.0), the nested
    /// body (0.0.2, with a code block) and the deepest body (0.0.2.2, the
    /// sentinel between two eligible paragraphs).
    static let chainUnits = """
        0.0.0 CE-CHAIN-L1-A 0.0 0.0
        0.0.1.0 CE-CHAIN-TASK-A 0.0 0.0
        0.0.1.1 CE-CHAIN-TASK-B 0.0 0.0
        0.0.2.0 CE-CHAIN-L2-A 0.0 0.0,0.0.2
        0.0.2.1 CE-CHAIN-CODE 0.0 0.0,0.0.2
        0.0.2.2.0 CE-CHAIN-L3-A 0.0 0.0,0.0.2,0.0.2.2
        0.0.2.2.1 CXOPENSENTINEL 0.0 0.0,0.0.2,0.0.2.2
        0.0.2.2.2 CE-CHAIN-L3-B 0.0 0.0,0.0.2,0.0.2.2
        0.0.2.3 CE-CHAIN-L2-B 0.0 0.0,0.0.2
        0.0.3 CE-CHAIN-L1-B 0.0 0.0
        """

    @Test("the sentinel's unit names the full expand chain, outermost first")
    func sentinelAncestorsAreTheFullChain() async throws {
        let prepared = try await preparedFixture("containers-expand")
        let unit = try #require(prepared.units.first { $0.plainText == Self.sentinel })
        #expect(unit.ownerID == "0.0.2.2.1")
        #expect(unit.topLevelBlockID == "0.0")
        #expect(unit.expandAncestorIDs == ["0.0", "0.0.2", "0.0.2.2"])

        // Block 0 is a closed expand at the root; the whole chain's units.
        guard case .expand = prepared.blocks.first?.kind else {
            Issue.record("block 0 is not an expand")
            return
        }
        let chain = prepared.units.filter { $0.topLevelBlockID == "0.0" }
        let lines = chain.map { unit in
            unit.plainText == Self.sentinel
                ? "\(unit.ownerID) \(Self.sentinel) \(unit.topLevelBlockID) \(unit.expandAncestorIDs.joined(separator: ","))"
                : pinLine(unit, prefix: "CE-CHAIN")
        }
        #expect(lines == pinLines(Self.chainUnits))
    }

    @Test("CE-TALL's body is exactly 300 plain paragraphs CE-TALL-001 … CE-TALL-300")
    func tallExpandBody() async throws {
        let prepared = try await preparedFixture("containers-expand")
        let root = prepared.document.root.children[305]
        guard case .expand(let title, let body, let isNested, _) = root.kind else {
            Issue.record("0.305 is not an expand")
            return
        }
        #expect(!isNested)
        #expect(title.hasPrefix("CE-TALL "))
        #expect(body.count == 300)
        #expect(body.allSatisfy { isPlainParagraph($0, allowingBreaks: false) })

        let units = prepared.units.filter { $0.topLevelBlockID == "0.305" }
        #expect(units.map(\.ownerID) == (0..<300).map { "0.305.\($0)" })
        #expect(units.allSatisfy { $0.expandAncestorIDs == ["0.305"] })
        let labels = (1...300).map { "CE-TALL-" + String(repeating: "0", count: 3 - String($0).count) + String($0) + " " }
        #expect(zip(units, labels).allSatisfy { $0.plainText.hasPrefix($1) })
    }

    /// CE-OPEN-1 … 5: root index and eligible leaves in the outer body
    /// (paragraphs, headings, list and task leaders).
    static let openExpands: [(index: Int, leaves: Int)] = [(346, 30), (386, 33), (427, 35), (470, 37), (513, 40)]

    @Test("each CE-OPEN body holds 30–40 eligible leaves, one code block and one nested expand of four paragraphs")
    func openExpandBodies() async throws {
        let prepared = try await preparedFixture("containers-expand")
        for (k, open) in Self.openExpands.enumerated() {
            let id = "0.\(open.index)"
            let root = prepared.document.root.children[open.index]
            guard case .expand(let title, let body, false, _) = root.kind else {
                Issue.record("\(id) is not a root expand")
                continue
            }
            #expect(title.hasPrefix("CE-OPEN-\(k + 1) "), "\(id)")

            var leaves = 0
            var code: [String] = []
            var nested: [ADFNode] = []
            for child in body {
                switch child.kind {
                case .paragraph, .heading: leaves += 1
                case .bulletList(let items, _), .orderedList(_, let items, _), .taskList(let items): leaves += items.count
                case .codeBlock: code.append(child.id)
                case .expand(_, _, true, _): nested.append(child)
                default: Issue.record("\(id): unexpected child \(child.type) at \(child.id)")
                }
            }
            #expect(leaves == open.leaves, "\(id)")
            #expect(code.count == 1, "\(id)")
            #expect(nested.count == 1, "\(id)")
            let nestedChildren = nested.first?.children ?? []
            #expect(nestedChildren.count == 4 && nestedChildren.allSatisfy { isPlainParagraph($0, allowingBreaks: false) }, "\(id)")

            // The corpus agrees: one unit per leaf plus the code block in the
            // outer body, four in the nested body.
            let units = prepared.units.filter { $0.topLevelBlockID == id }
            let nestedID = nested.first?.id ?? "?"
            #expect(units.filter { $0.expandAncestorIDs == [id] }.count == open.leaves + 1, "\(id)")
            #expect(units.filter { $0.expandAncestorIDs == [id, nestedID] }.count == 4, "\(id)")
            #expect(units.count == open.leaves + 5, "\(id)")
            #expect(units.contains { $0.ownerID == code.first && $0.plainText.hasPrefix("// CE-OPEN-\(k + 1)-CODE ") },
                    "\(id)")
        }
    }

    // MARK: Family census

    static let forbiddenInDenseAndExpand: Set<String> = ["table", "mediaSingle", "mediaGroup", "media", "mediaInline"]

    @Test("containers-dense and containers-expand hold no table and no media", arguments: ["containers-dense", "containers-expand"])
    func noTableNoMedia(fixture: String) async throws {
        let prepared = try await preparedFixture(fixture)
        let forbidden = allNodes(prepared.document.root).filter { Self.forbiddenInDenseAndExpand.contains($0.type) }
        #expect(forbidden.isEmpty, "\(forbidden.map { "\($0.type) \($0.id)" })")
    }

    /// The three declared versions of the lighten ladder
    /// (`ContainersDenseSpec.version`): top-level panels, quotes, column
    /// sections, bodied extensions and closed expands. Version 1 is the
    /// default; 2 and 3 add containers only to keep 100–150 s of autoscroll.
    static let denseVersions: [Int: [String: Int]] = [
        840: ["panel": 240, "blockquote": 200, "layoutSection": 200, "bodiedExtension": 160, "expand": 40],
        1_092: ["panel": 312, "blockquote": 260, "layoutSection": 260, "bodiedExtension": 208, "expand": 52],
        1_260: ["panel": 360, "blockquote": 300, "layoutSection": 300, "bodiedExtension": 240, "expand": 60],
    ]

    @Test("containers-dense: one declared version, KD labels in order, 12 nested code blocks, plain first and last screens")
    func denseComposition() async throws {
        let prepared = try await preparedFixture("containers-dense")
        let roots = prepared.document.root.children
        let expected = try #require(Self.denseVersions[roots.count], "\(roots.count) roots is not a declared version")
        #expect(Dictionary(grouping: roots, by: \.type).mapValues(\.count) == expected)

        // A closed expand after every 20 containers, at offset 10 of each 21.
        let expandIndices = roots.indices.filter { roots[$0].type == "expand" }
        #expect(expandIndices == (0..<expected["expand", default: 0]).map { 21 * $0 + 10 })

        // Every container's first unit starts with its KD-<iiii> label.
        let containers = roots.filter { $0.type != "expand" }
        var firstUnit: [String: SearchTextUnit] = [:]
        for unit in prepared.units where firstUnit[unit.topLevelBlockID] == nil {
            firstUnit[unit.topLevelBlockID] = unit
        }
        for (k, container) in containers.enumerated() {
            let label = "KD-" + String(repeating: "0", count: 4 - String(k).count) + String(k) + " "
            #expect(firstUnit[container.id]?.plainText.hasPrefix(label) == true, "\(container.id) should open with \(label)")
        }

        // Twelve code blocks, all nested in containers, none at the root.
        let code = allNodes(prepared.document.root).filter { $0.type == "codeBlock" }
        #expect(code.count == 12)
        #expect(code.allSatisfy { $0.id.split(separator: ".").count >= 3 })
        #expect(!roots.contains { $0.type == "codeBlock" })

        // The first and last three containers open with a plain prose
        // paragraph (unmarked text; a hard break is plain prose).
        for container in containers.prefix(3) + containers.suffix(3) {
            var node = container
            while ["panel", "blockquote", "bodiedExtension"].contains(node.type), let first = node.children.first {
                node = first
            }
            #expect(isPlainParagraph(node, allowingBreaks: true), "\(container.id) opens with \(node.type) \(node.id)")
        }
    }

    // MARK: Owner pins

    /// containers-parity: every search unit, in document order (expand
    /// bodies included): owner id, sentinel, top-level block id, expand
    /// ancestors. A list row's owner is its item; a table cell's text sits
    /// under the table's slice id.
    static let containersParityOwners = """
        0.0 KP-S1 0.0 -
        0.1.0 KP-PANEL-INFO 0.1 -
        0.2.0 KP-PANEL-NOTE 0.2 -
        0.3.0 KP-PANEL-TIP 0.3 -
        0.4.0 KP-PANEL-WARNING 0.4 -
        0.5.0 KP-PANEL-ERROR 0.5 -
        0.6.0 KP-PANEL-SUCCESS 0.6 -
        0.7.0 KP-PANEL-CUSTOM 0.7 -
        0.8.0 KP-PANEL-CUSTOM-GREY 0.8 -
        0.9 KP-PANEL-EMPTY-BEFORE 0.9 -
        0.11.0 KP-PANEL-MULTI-H2 0.11 -
        0.11.1 KP-PANEL-MULTI-P1 0.11 -
        0.11.2 KP-PANEL-MULTI-P2 0.11 -
        0.11.3 KP-PANEL-MULTI-H5 0.11 -
        0.11.4 KP-PANEL-MULTI-P3 0.11 -
        0.12.0 KP-PANEL-H1 0.12 -
        0.13 KP-AFTER-PANELS 0.13 -
        0.14 KP-S2 0.14 -
        0.15.0 KP-MARKS-PANEL 0.15 -
        0.15.1 KP-MARKS-PANEL-NEXT 0.15 -
        0.16.0 KP-LINK-PANEL 0.16 -
        0.17.0 KP-BREAK-PANEL 0.17 -
        0.18.0 KP-LINK-BLANK-PANEL 0.18 -
        0.19.0 KP-UNICODE-QUOTE 0.19 -
        0.20.0 KP-RTL-QUOTE 0.20 -
        0.20.1 KP-RTL-MIXED-QUOTE 0.20 -
        0.21.0 KP-RTL-PANEL 0.21 -
        0.22.0 KP-MARKS-EXT 0.22 -
        0.22.1 KP-LINK-EXT 0.22 -
        0.22.2 KP-BREAK-EXT 0.22 -
        0.23.0 KP-ATOM-PANEL 0.23 -
        0.24.0 KP-ATOM-QUOTE 0.24 -
        0.25 KP-AFTER-SHAPES 0.25 -
        0.26 KP-S3 0.26 -
        0.27.0 KP-QUOTE-ONE 0.27 -
        0.28.0 KP-QUOTE-MULTI-P1 0.28 -
        0.28.1 KP-QUOTE-MULTI-H3 0.28 -
        0.28.2 KP-QUOTE-MULTI-P2 0.28 -
        0.29.0 KP-QUOTE-OUTER 0.29 -
        0.29.1.0 KP-QUOTE-INNER 0.29 -
        0.29.1.1.0 KP-QUOTE-INNERMOST 0.29 -
        0.29.2 KP-QUOTE-OUTER-AFTER 0.29 -
        0.30 KP-AFTER-QUOTES 0.30 -
        0.31 KP-S4 0.31 -
        0.32.0 KP-NEST-QP-OUTER 0.32 -
        0.32.1.0 KP-NEST-QP-INNER 0.32 -
        0.33.0 KP-NEST-PQ-OUTER 0.33 -
        0.33.1.0 KP-NEST-PQ-INNER 0.33 -
        0.34.0 KP-NEST-EP-OUTER 0.34 -
        0.34.1.0 KP-NEST-EP-INNER 0.34 -
        0.35.0.0 KP-NEST-EQ-INNER 0.35 -
        0.36.0.0.0 KP-NEST-DEEP 0.36 -
        0.37 KP-AFTER-NESTED 0.37 -
        0.38 KP-S5 0.38 -
        0.39.0 KP-EXT-P1 0.39 -
        0.39.1 KP-EXT-H4 0.39 -
        0.39.2 KP-EXT-P2 0.39 -
        0.43.0 KP-SYNC-BODY 0.43.0 -
        0.44 KP-AFTER-EXTENSIONS 0.44 -
        0.45 KP-S6 0.45 -
        0.46.0.0 KP-COL25-A 0.46 -
        0.46.0.1 KP-COL25-B 0.46 -
        0.46.1.0 KP-COL75-A 0.46 -
        0.46.1.1 KP-COL75-H4 0.46 -
        0.46.1.2 KP-COL75-B 0.46 -
        0.47.0.0 KP-COL33-A 0.47 -
        0.47.1.0 KP-COL67-A 0.47 -
        0.47.1.1 KP-LINK-COL67 0.47 -
        0.48.0.0.0 KP-COL50-PANEL 0.48 -
        0.48.1.0.0 KP-COL50-QUOTE 0.48 -
        0.49.0.0 KP-COL3-A 0.49 -
        0.49.1.0 KP-COL3-B 0.49 -
        0.49.2.0 KP-COL3-C 0.49 -
        0.50 KP-AFTER-COLUMNS 0.50 -
        0.51 KP-S7 0.51 -
        0.52.0.0 KP-COL0-ZERO 0.52 -
        0.52.0.1 KP-CODE-COL0 0.52 -
        0.52.1.0 KP-COL0-POSITIVE 0.52 -
        0.53.0.0 KP-COLNEG-NEGATIVE 0.53 -
        0.53.1.0 KP-COLNEG-POSITIVE 0.53 -
        0.54.0.0 KP-INDENT6 0.54 -
        0.54.1.0 KP-INDENT6-BESIDE 0.54 -
        0.55.0.0 KP-COLALL0-A 0.55 -
        0.55.1.0 KP-COLALL0-B 0.55 -
        0.56 KP-AFTER-COLUMN-EDGES 0.56 -
        0.57 KP-S8 0.57 -
        0.58.0 KP-EXPAND-P1 0.58 0.58
        0.58.1 KP-EXPAND-H3 0.58 0.58
        0.58.2 KP-EXPAND-MARKS 0.58 0.58
        0.58.3.0 KP-EXPAND-NESTED-P1 0.58 0.58,0.58.3
        0.58.3.1 KP-EXPAND-NESTED-P2 0.58 0.58,0.58.3
        0.58.4 KP-EXPAND-P2 0.58 0.58
        0.59.0.0 KP-EXPAND-PANEL 0.59 0.59
        0.59.1.0 KP-EXPAND-QUOTE 0.59 0.59
        0.60.0.0 KP-COL-EXPAND-A 0.60 -
        0.60.0.1.0 KP-COL-NESTED-EXPAND-P 0.60 0.60.0.1
        0.60.1.0 KP-COL-EXPAND-B 0.60 -
        0.61 KP-AFTER-EXPANDS 0.61 -
        0.62 KP-S9 0.62 -
        0.63.0 KP-LIST-PANEL-INTRO 0.63 -
        0.63.1.0 KP-LIST-PANEL-A 0.63 -
        0.63.1.0.1.0 KP-LIST-PANEL-A1 0.63 -
        0.63.1.1 KP-LIST-PANEL-B 0.63 -
        0.64.0.0 KP-LIST-QUOTE-3 0.64 -
        0.64.0.1 KP-LIST-QUOTE-4 0.64 -
        0.64.1.0 KP-LIST-QUOTE-REJECT-A 0.64 -
        0.64.1.0.1.0 KP-LIST-QUOTE-REJECT-PANEL 0.64 -
        0.64.1.1 KP-LIST-QUOTE-AFTER-REJECT 0.64 -
        0.64.2.0 KP-LIST-QUOTE-TASK-A 0.64 -
        0.64.2.1 KP-LIST-QUOTE-TASK-B 0.64 -
        0.65.0.0 KP-LIST-RTL-A 0.65 -
        0.65.0.1 KP-LIST-RTL-B 0.65 -
        0.66.0.0 KP-LIST-EXPAND-A 0.66 0.66
        0.66.0.1 KP-LIST-EXPAND-B 0.66 0.66
        0.66.1.0 KP-LIST-EXPAND-TASK 0.66 0.66
        0.66.2.0 KP-LIST-EXPAND-DECISION 0.66 0.66
        0.67.0.0 KP-LIST-EXT-1 0.67 -
        0.67.0.1 KP-LIST-EXT-2 0.67 -
        0.67.0.1.1.0 KP-LIST-EXT-2A 0.67 -
        0.68.0.0.0 KP-LIST-COL25-L1 0.68 -
        0.68.0.0.0.1.0 KP-LIST-COL25-L2 0.68 -
        0.68.0.0.0.1.0.1.0 KP-LIST-COL25-L3 0.68 -
        0.68.1.0.0 KP-LIST-COL75-1 0.68 -
        0.68.1.0.1 KP-LIST-COL75-2 0.68 -
        0.68.1.1.0 KP-LIST-COL75-DECISION 0.68 -
        0.69 KP-AFTER-LISTS 0.69 -
        0.70 KP-S10 0.70 -
        0.71.0 KP-CODE-PANEL-INTRO 0.71 -
        0.71.1 KP-CODE-PANEL 0.71 -
        0.72.0 KP-CODE-QUOTE 0.72 -
        0.73.0.0 KP-CODE-PANEL-QUOTE 0.73 -
        0.74.0 KP-CODE-EXPAND-P 0.74 0.74
        0.74.1 KP-CODE-EXPAND-BODY 0.74 0.74
        0.75.0 KP-CODE-EXT-BODY 0.75 -
        0.76.0.0 KP-CODE-COL-LEFT 0.76 -
        0.76.1.0 KP-CODE-COL-RIGHT-P 0.76 -
        0.76.1.1 KP-CODE-COL-RIGHT 0.76 -
        0.77.0 KP-CODE-MULTI-1 0.77 -
        0.77.1 KP-CODE-MULTI-P 0.77 -
        0.77.2 KP-CODE-MULTI-2 0.77 -
        0.77.3 KP-CODE-MULTI-3 0.77 -
        0.78.0 KP-CODE-OVER-INTRO 0.78 -
        0.78.1 KP-CODE-OVER 0.78 -
        0.79 KP-AFTER-CODE 0.79 -
        0.80 KP-S11 0.80 -
        0.81.0.0.0 KP-NEG-TH-1 0.81#header -
        0.81.0.1.0 KP-NEG-TH-2 0.81#header -
        0.81.1.0.0.0 KP-NEG-TABLE-PANEL 0.81#rows0 -
        0.81.1.1.0 KP-NEG-TABLE-TD 0.81#rows0 -
        0.81.1.1.1 KP-NEG-TABLE-CODE 0.81#rows0 -
        0.82.0 KP-NEG-EXPAND-P 0.82 0.82
        0.82.1.0.0.0 KP-NEG-EXPAND-TH 0.82 0.82
        0.82.1.1.0.0 KP-NEG-EXPAND-TD 0.82 0.82
        0.83.0 KP-NEG-PLUGIN-P 0.83 -
        0.84.0 KP-NEG-LISTITEM-LEADER 0.84 -
        0.84.0.1.0 KP-NEG-LISTITEM-PANEL 0.84 -
        0.84.0.2.0 KP-NEG-LISTITEM-QUOTE 0.84 -
        0.85 KP-END 0.85 -
        """

    /// captions-parity: a caption's owner is its media node. CAP-01 (no
    /// caption node) and CAP-02 (an empty caption) have no unit.
    static let captionsParityOwners = """
        0.0 CAP-S1 0.0 -
        0.3.0 CAP-03 0.3 -
        0.4.0 CAP-04 0.4 -
        0.5.0 CAP-05 0.5 -
        0.6.0 CAP-06 0.6 -
        0.7.0 CAP-07 0.7 -
        0.8.0 CAP-08 0.8 -
        0.9.0 CAP-09 0.9 -
        0.10.0 CAP-10 0.10 -
        0.11.0 CAP-11 0.11 -
        0.12 CAP-S2 0.12 -
        0.13.0 CAP-PANEL-P 0.13 -
        0.13.1.0 CAP-12 0.13 -
        0.14.0.0.0 CAP-13 0.14 -
        0.14.1.0 CAP-COLUMN-P 0.14 -
        0.15.0 CAP-EXPAND-P 0.15 0.15
        0.15.1.0 CAP-14 0.15 0.15
        0.16 CAP-S3 0.16 -
        0.17.0 CAP-L-CENTER 0.17 -
        0.18.0 CAP-L-WRAP-LEFT 0.18 -
        0.19.0 CAP-L-WRAP-RIGHT 0.19 -
        0.20.0 CAP-L-ALIGN-START 0.20 -
        0.21.0 CAP-L-ALIGN-END 0.21 -
        0.22.0 CAP-L-WIDE 0.22 -
        0.23.0 CAP-L-FULL-WIDTH 0.23 -
        0.24 CAP-END 0.24 -
        """

    @Test("containers-parity: every unit's owner, sentinel, top-level block and expand chain")
    func containersParityOwnerPins() async throws {
        let prepared = try await preparedFixture("containers-parity")
        let expected = pinLines(Self.containersParityOwners)
        #expect(expected.count == 158)
        let tokens = expected.map { $0.split(separator: " ")[1] }
        #expect(Set(tokens).count == tokens.count, "KP- sentinels must be unique")
        let actual = prepared.units.map { pinLine($0, prefix: "KP-") }
        #expect(actual == expected)
        for (a, e) in zip(actual, expected) where a != e {
            Issue.record("unit \(a) != pin \(e)")
        }
    }

    @Test("captions-parity: every unit's owner, sentinel, top-level block and expand chain")
    func captionsParityOwnerPins() async throws {
        let prepared = try await preparedFixture("captions-parity")
        let expected = pinLines(Self.captionsParityOwners)
        #expect(expected.count == 26)
        let tokens = expected.map { $0.split(separator: " ")[1] }
        #expect(Set(tokens).count == tokens.count, "CAP- sentinels must be unique")
        let actual = prepared.units.map { pinLine($0, prefix: "CAP-") }
        #expect(actual == expected)
        for (a, e) in zip(actual, expected) where a != e {
            Issue.record("unit \(a) != pin \(e)")
        }
    }
}
