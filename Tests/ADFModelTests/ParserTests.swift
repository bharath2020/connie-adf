import Foundation
import Testing
@testable import ADFModel

// MARK: - Shared helpers

func parseFixture(_ name: String) async throws -> ADFDocument {
    try await ADFParser().parse(fixtureData(name))
}

func parseJSON(_ json: String) async throws -> ADFDocument {
    try await ADFParser().parse(Data(json.utf8))
}

/// Depth-first collection of a node and all its descendants.
func allNodes(in node: ADFNode) -> [ADFNode] {
    [node] + node.children.flatMap { allNodes(in: $0) }
}

func allMarks(in node: ADFNode) -> [ADFMark] {
    allNodes(in: node).flatMap(\.marks)
}

func markLabel(_ mark: ADFMark) -> String {
    switch mark {
    case .strong: "strong"
    case .em: "em"
    case .underline: "underline"
    case .strike: "strike"
    case .code: "code"
    case .subsup(let isSup): isSup ? "sup" : "sub"
    case .textColor: "textColor"
    case .backgroundColor: "backgroundColor"
    case .fontSize: "fontSize"
    case .link: "link"
    case .alignment: "alignment"
    case .indentation: "indentation"
    case .breakout: "breakout"
    case .border: "border"
    case .annotation: "annotation"
    case .dataConsumer: "dataConsumer"
    case .fragment: "fragment"
    }
}

func unknownNodes(in root: ADFNode) -> [ADFNode] {
    allNodes(in: root).filter { node in
        if case .unknown = node.kind { return true }
        return false
    }
}

// MARK: - Kitchen sink

@Suite("ADFParser kitchen sink")
struct ParserTests {
    @Test("kitchen-sink decodes with zero unknowns and zero issues")
    func kitchenSinkDecodesCleanly() async throws {
        let doc = try await parseFixture("kitchen-sink.json")
        #expect(doc.issues.isEmpty)
        #expect(unknownNodes(in: doc.root).isEmpty)
        #expect(doc.version == 1)
    }

    @Test("kitchen-sink contains every ADF node type")
    func kitchenSinkCoversAllNodeTypes() async throws {
        let doc = try await parseFixture("kitchen-sink.json")
        let found = Set(allNodes(in: doc.root).map(\.type))
        let expected: Set<String> = [
            "doc", "paragraph", "heading", "text", "hardBreak", "blockquote",
            "bulletList", "orderedList", "listItem", "codeBlock", "rule", "panel",
            "table", "tableRow", "tableHeader", "tableCell", "expand", "nestedExpand",
            "mediaSingle", "mediaGroup", "media", "mediaInline", "caption",
            "taskList", "taskItem", "decisionList", "decisionItem",
            "layoutSection", "layoutColumn", "blockCard", "embedCard", "inlineCard",
            "mention", "emoji", "date", "status", "placeholder",
            "extension", "bodiedExtension", "inlineExtension",
            "syncBlock", "bodiedSyncBlock",
        ]
        #expect(expected.subtracting(found).isEmpty, "missing node types: \(expected.subtracting(found).sorted())")
    }

    @Test("kitchen-sink contains every heading level, panel type, status color, task state")
    func kitchenSinkCoversAttributeVariants() async throws {
        let doc = try await parseFixture("kitchen-sink.json")
        let nodes = allNodes(in: doc.root)

        var headingLevels: Set<Int> = []
        var panelTypes: Set<ADFPanelType> = []
        var statusColors: Set<ADFStatusColor> = []
        var taskStates: Set<ADFTaskState> = []
        var widthTypes: Set<ADFWidthType> = []
        var sawFileMedia = false
        var sawExternalMedia = false

        for node in nodes {
            switch node.kind {
            case .heading(let level, _, _): headingLevels.insert(level)
            case .panel(let type, _, _, _): panelTypes.insert(type)
            case .status(_, let color): statusColors.insert(color)
            case .taskItem(let state, _): taskStates.insert(state)
            case .mediaSingle(_, _, let widthType, _):
                if let widthType { widthTypes.insert(widthType) }
            case .media(let attrs, _):
                switch attrs.source {
                case .file: sawFileMedia = true
                case .external: sawExternalMedia = true
                }
            default: break
            }
        }

        #expect(headingLevels == [1, 2, 3, 4, 5, 6])
        #expect(panelTypes == [.info, .note, .tip, .warning, .error, .success, .custom])
        #expect(statusColors == [.neutral, .purple, .blue, .red, .yellow, .green])
        #expect(taskStates == [.todo, .done])
        #expect(widthTypes == [.percentage, .pixel])
        #expect(sawFileMedia && sawExternalMedia)
    }

    @Test("kitchen-sink contains every mark")
    func kitchenSinkCoversAllMarks() async throws {
        let doc = try await parseFixture("kitchen-sink.json")
        let found = Set(allMarks(in: doc.root).map(markLabel))
        let expected: Set<String> = [
            "strong", "em", "underline", "strike", "code", "sub", "sup",
            "textColor", "backgroundColor", "fontSize", "link",
            "alignment", "indentation", "breakout", "border", "annotation",
            "dataConsumer", "fragment",
        ]
        #expect(expected.subtracting(found).isEmpty, "missing marks: \(expected.subtracting(found).sorted())")
    }

    @Test("structural path IDs are assigned from the root")
    func structuralIDs() async throws {
        let doc = try await parseFixture("kitchen-sink.json")
        #expect(doc.root.id == "0")
        let first = try #require(doc.root.children.first)
        #expect(first.id == "0.0")
        let grandchild = try #require(first.children.first)
        #expect(grandchild.id == "0.0.0")
        #expect(doc.root.children[1].id == "0.1")
        #expect(doc.root.children[1].children[1].id == "0.1.1")
    }

    // MARK: Node-specific decoding

    @Test("date timestamp decodes from a STRING of epoch milliseconds")
    func dateTimestampString() async throws {
        let doc = try await parseJSON(
            #"{"version":1,"type":"doc","content":[{"type":"paragraph","content":[{"type":"date","attrs":{"timestamp":"1720569600000"}}]}]}"#
        )
        let date = try #require(allNodes(in: doc.root).first { $0.type == "date" })
        #expect(date.kind == .date(timestampMS: 1_720_569_600_000))
        #expect(doc.issues.isEmpty)
    }

    @Test("unparseable date timestamp defaults to 0 with an issue")
    func dateTimestampGarbage() async throws {
        let doc = try await parseJSON(
            #"{"version":1,"type":"doc","content":[{"type":"paragraph","content":[{"type":"date","attrs":{"timestamp":"not-a-number"}}]}]}"#
        )
        let date = try #require(allNodes(in: doc.root).first { $0.type == "date" })
        #expect(date.kind == .date(timestampMS: 0))
        #expect(!doc.issues.isEmpty)
    }

    @Test("heading missing level defaults to 1 with an issue")
    func headingMissingLevel() async throws {
        let doc = try await parseJSON(
            #"{"version":1,"type":"doc","content":[{"type":"heading","content":[{"type":"text","text":"h"}]}]}"#
        )
        let heading = try #require(doc.root.children.first)
        guard case .heading(let level, _, _) = heading.kind else {
            Issue.record("expected .heading, got \(heading.kind)")
            return
        }
        #expect(level == 1)
        #expect(doc.issues.count == 1)
    }

    @Test("panel with unrecognized panelType defaults to info with an issue")
    func panelBadType() async throws {
        let doc = try await parseJSON(
            #"{"version":1,"type":"doc","content":[{"type":"panel","attrs":{"panelType":"sparkly"},"content":[]}]}"#
        )
        let panel = try #require(doc.root.children.first)
        guard case .panel(let type, _, _, _) = panel.kind else {
            Issue.record("expected .panel, got \(panel.kind)")
            return
        }
        #expect(type == .info)
        #expect(doc.issues.count == 1)
    }

    @Test("codeBlock flattens child text and keeps language")
    func codeBlockFlattens() async throws {
        let doc = try await parseFixture("kitchen-sink.json")
        let code = try #require(allNodes(in: doc.root).first { $0.type == "codeBlock" })
        guard case .codeBlock(let language, let text, let marks) = code.kind else {
            Issue.record("expected .codeBlock, got \(code.kind)")
            return
        }
        #expect(language == "swift")
        #expect(text == "let greeting = \"Hello, ADF!\"\nprint(greeting)")
        #expect(marks == [.breakout(mode: .wide, width: 1200)])
    }

    @Test("tableHeader collapses to .tableCell(isHeader: true)")
    func tableHeaderCollapses() async throws {
        let doc = try await parseFixture("kitchen-sink.json")
        let header = try #require(allNodes(in: doc.root).first { $0.type == "tableHeader" })
        guard case .tableCell(let attrs, _, let isHeader) = header.kind else {
            Issue.record("expected .tableCell, got \(header.kind)")
            return
        }
        #expect(isHeader)
        #expect(attrs.colwidth == [200])
        #expect(attrs.backgroundHex == "#f4f5f7")

        let cell = try #require(allNodes(in: doc.root).first { node in
            guard node.type == "tableCell" else { return false }
            guard case .tableCell(let attrs, _, _) = node.kind else { return false }
            return attrs.colspan == 2
        })
        guard case .tableCell(let cellAttrs, _, let cellIsHeader) = cell.kind else { return }
        #expect(!cellIsHeader)
        #expect(cellAttrs.backgroundHex == "#deebff")
        #expect(cellAttrs.valign == .top)
    }

    @Test("nestedExpand collapses to .expand(isNested: true)")
    func nestedExpandCollapses() async throws {
        let doc = try await parseFixture("kitchen-sink.json")
        let nested = try #require(allNodes(in: doc.root).first { $0.type == "nestedExpand" })
        guard case .expand(let title, _, let isNested) = nested.kind else {
            Issue.record("expected .expand, got \(nested.kind)")
            return
        }
        #expect(title == "Nested details")
        #expect(isNested)
    }

    @Test("bodiedSyncBlock collapses to .syncBlock keeping content")
    func bodiedSyncBlockCollapses() async throws {
        let doc = try await parseFixture("kitchen-sink.json")
        let bodied = try #require(allNodes(in: doc.root).first { $0.type == "bodiedSyncBlock" })
        guard case .syncBlock(let resourceId, let content) = bodied.kind else {
            Issue.record("expected .syncBlock, got \(bodied.kind)")
            return
        }
        #expect(resourceId == "ari:cloud:confluence:site/sync-2")
        #expect(!content.isEmpty)

        let plain = try #require(allNodes(in: doc.root).first { $0.type == "syncBlock" })
        guard case .syncBlock(let plainResourceId, let plainContent) = plain.kind else {
            Issue.record("expected .syncBlock, got \(plain.kind)")
            return
        }
        #expect(plainResourceId == "ari:cloud:confluence:site/sync-1")
        #expect(plainContent.isEmpty)
    }

    @Test("orderedList honors the order attr as start")
    func orderedListStart() async throws {
        let doc = try await parseFixture("kitchen-sink.json")
        let list = try #require(allNodes(in: doc.root).first { $0.type == "orderedList" })
        guard case .orderedList(let start, let items, _) = list.kind else {
            Issue.record("expected .orderedList, got \(list.kind)")
            return
        }
        #expect(start == 4)
        #expect(items.count == 2)
    }

    @Test("mediaSingle keeps width, widthType and layout")
    func mediaSingleAttrs() async throws {
        let doc = try await parseFixture("kitchen-sink.json")
        let singles = allNodes(in: doc.root).filter { $0.type == "mediaSingle" }
        #expect(singles.count == 2)

        guard case .mediaSingle(let layout1, let width1, let widthType1, let content1) = singles[0].kind else {
            Issue.record("expected .mediaSingle")
            return
        }
        #expect(layout1 == .center)
        #expect(width1 == 66.66)
        #expect(widthType1 == .percentage)
        #expect(content1.contains { $0.type == "caption" })

        guard case .mediaSingle(let layout2, let width2, let widthType2, _) = singles[1].kind else {
            Issue.record("expected .mediaSingle")
            return
        }
        #expect(layout2 == .wide)
        #expect(width2 == 400)
        #expect(widthType2 == .pixel)
    }
}

// MARK: - JSONValue

@Suite("JSONValue")
struct JSONValueTests {
    @Test("bridges every JSON scalar and container from JSONSerialization")
    func bridging() throws {
        let data = Data(#"{"s":"hi","n":4.5,"i":7,"b":true,"nil":null,"a":[1,"two"],"o":{"k":"v"}}"#.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        let json = try JSONValue(jsonObject: object)
        #expect(json["s"]?.stringValue == "hi")
        #expect(json["n"]?.doubleValue == 4.5)
        #expect(json["n"]?.intValue == nil)
        #expect(json["i"]?.intValue == 7)
        #expect(json["b"]?.boolValue == true)
        #expect(json["nil"] == JSONValue.null)
        #expect(json["a"]?.arrayValue?.count == 2)
        #expect(json["o"]?["k"]?.stringValue == "v")
        #expect(json["missing"] == nil)
    }

    @Test("accessors return nil for mismatched cases")
    func mismatchedAccessors() {
        #expect(JSONValue.string("x").doubleValue == nil)
        #expect(JSONValue.number(1).stringValue == nil)
        #expect(JSONValue.bool(true).intValue == nil)
        #expect(JSONValue.array([]).boolValue == nil)
        #expect(JSONValue.null.arrayValue == nil)
        #expect(JSONValue.string("x")["key"] == nil)
    }
}
