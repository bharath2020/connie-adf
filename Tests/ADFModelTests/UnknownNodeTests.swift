import Foundation
import Testing
@testable import ADFModel

@Suite("Unknown node handling")
struct UnknownNodeTests {
    @Test("unknown node type decodes to .unknown with an issue; siblings intact")
    func unknownNodeAmongSiblings() async throws {
        let doc = try await parseJSON(#"""
        {"version":1,"type":"doc","content":[
          {"type":"paragraph","content":[{"type":"text","text":"before"}]},
          {"type":"whiteboard","attrs":{"boardId":"wb-1"},"content":[]},
          {"type":"paragraph","content":[{"type":"text","text":"after"}]}
        ]}
        """#)
        let children = doc.root.children
        #expect(children.count == 3)
        #expect(children[0].type == "paragraph")
        #expect(children[2].type == "paragraph")

        let unknown = children[1]
        #expect(unknown.type == "whiteboard")
        #expect(unknown.id == "0.1")
        guard case .unknown(let raw) = unknown.kind else {
            Issue.record("expected .unknown, got \(unknown.kind)")
            return
        }
        #expect(raw["type"]?.stringValue == "whiteboard")
        #expect(raw["attrs"]?["boardId"]?.stringValue == "wb-1")

        #expect(doc.issues.count == 1)
        #expect(doc.issues.first?.path == "0.1")
        #expect(doc.issues.first?.message.contains("whiteboard") == true)
    }

    @Test("unknown node nested inside a known container never fails the parse")
    func unknownNodeNested() async throws {
        let doc = try await parseJSON(#"""
        {"version":1,"type":"doc","content":[
          {"type":"panel","attrs":{"panelType":"info"},"content":[
            {"type":"hologram","attrs":{"dimension":4}},
            {"type":"paragraph","content":[{"type":"text","text":"still here"}]}
          ]}
        ]}
        """#)
        let panel = try #require(doc.root.children.first)
        guard case .panel(_, _, _, let content) = panel.kind else {
            Issue.record("expected .panel, got \(panel.kind)")
            return
        }
        #expect(content.count == 2)
        guard case .unknown(let raw) = content[0].kind else {
            Issue.record("expected .unknown, got \(content[0].kind)")
            return
        }
        #expect(raw["type"]?.stringValue == "hologram")
        #expect(content[1].type == "paragraph")
        #expect(doc.issues.count == 1)
    }

    @Test("node with no type field decodes to .unknown, keeps raw JSON")
    func missingTypeField() async throws {
        let doc = try await parseJSON(
            #"{"version":1,"type":"doc","content":[{"attrs":{"oops":true}}]}"#
        )
        let node = try #require(doc.root.children.first)
        guard case .unknown(let raw) = node.kind else {
            Issue.record("expected .unknown, got \(node.kind)")
            return
        }
        #expect(raw["attrs"]?["oops"]?.boolValue == true)
        #expect(doc.issues.count == 1)
    }

    @Test("unknown raw JSON preserves the full subtree")
    func rawPreservesSubtree() async throws {
        let doc = try await parseJSON(#"""
        {"version":1,"type":"doc","content":[
          {"type":"multiBodiedExtension","attrs":{"extensionKey":"k"},"content":[
            {"type":"extensionFrame","content":[{"type":"paragraph","content":[{"type":"text","text":"inner"}]}]}
          ]}
        ]}
        """#)
        let node = try #require(doc.root.children.first)
        guard case .unknown(let raw) = node.kind else {
            Issue.record("expected .unknown, got \(node.kind)")
            return
        }
        let frame = try #require(raw["content"]?.arrayValue?.first)
        #expect(frame["type"]?.stringValue == "extensionFrame")
        let inner = frame["content"]?.arrayValue?.first?["content"]?.arrayValue?.first
        #expect(inner?["text"]?.stringValue == "inner")
    }
}
