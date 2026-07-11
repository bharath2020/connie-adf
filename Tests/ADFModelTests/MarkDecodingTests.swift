import Foundation
import Testing
@testable import ADFModel

@Suite("Mark decoding")
struct MarkDecodingTests {
    @Test("every text-level mark round-trips in order")
    func everyTextMarkRoundTrips() async throws {
        let doc = try await parseJSON(#"""
        {"version":1,"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"all the marks","marks":[
          {"type":"strong"},
          {"type":"em"},
          {"type":"underline"},
          {"type":"strike"},
          {"type":"subsup","attrs":{"type":"sub"}},
          {"type":"textColor","attrs":{"color":"#ff5630"}},
          {"type":"backgroundColor","attrs":{"color":"#fedec8"}},
          {"type":"fontSize","attrs":{"size":"small"}},
          {"type":"link","attrs":{"href":"https://example.com","title":"Example"}},
          {"type":"annotation","attrs":{"id":"anno-9","annotationType":"inlineComment"}}
        ]}]}]}
        """#)
        let text = try #require(doc.root.children.first?.children.first)
        guard case .text(let string, let marks) = text.kind else {
            Issue.record("expected .text, got \(text.kind)")
            return
        }
        #expect(string == "all the marks")
        let expected: [ADFMark] = [
            .strong, .em, .underline, .strike,
            .subsup(isSup: false),
            .textColor(hex: "#ff5630"),
            .backgroundColor(hex: "#fedec8"),
            .fontSize("small"),
            .link(href: "https://example.com", title: "Example"),
            .annotation(id: "anno-9", annotationType: "inlineComment"),
        ]
        #expect(marks == expected)
        #expect(doc.issues.isEmpty)
    }

    @Test("code mark decodes on its own run")
    func codeMark() async throws {
        let doc = try await parseJSON(
            #"{"version":1,"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"let x","marks":[{"type":"code"}]}]}]}"#
        )
        let text = try #require(doc.root.children.first?.children.first)
        guard case .text(_, let marks) = text.kind else {
            Issue.record("expected .text")
            return
        }
        #expect(marks == [.code])
    }

    @Test("subsup decodes sub and sup variants")
    func subsupVariants() async throws {
        let doc = try await parseJSON(#"""
        {"version":1,"type":"doc","content":[{"type":"paragraph","content":[
          {"type":"text","text":"2","marks":[{"type":"subsup","attrs":{"type":"sub"}}]},
          {"type":"text","text":"2","marks":[{"type":"subsup","attrs":{"type":"sup"}}]}
        ]}]}
        """#)
        let paragraph = try #require(doc.root.children.first)
        guard case .text(_, let subMarks) = paragraph.children[0].kind,
              case .text(_, let supMarks) = paragraph.children[1].kind else {
            Issue.record("expected two .text children")
            return
        }
        #expect(subMarks == [.subsup(isSup: false)])
        #expect(supMarks == [.subsup(isSup: true)])
    }

    @Test("unknown mark is dropped with an issue; known siblings survive")
    func unknownMarkDropped() async throws {
        let doc = try await parseJSON(
            #"{"version":1,"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"hi","marks":[{"type":"strong"},{"type":"glitter","attrs":{"sparkle":9}},{"type":"em"}]}]}]}"#
        )
        let text = try #require(doc.root.children.first?.children.first)
        guard case .text(let string, let marks) = text.kind else {
            Issue.record("expected .text, got \(text.kind)")
            return
        }
        #expect(string == "hi")
        #expect(marks == [.strong, .em])
        #expect(doc.issues.count == 1)
        #expect(doc.issues.first?.message.contains("glitter") == true)
        #expect(doc.issues.first?.path == "0.0.0")
    }

    @Test("block-level marks: alignment, indentation, breakout")
    func blockLevelMarks() async throws {
        let doc = try await parseJSON(#"""
        {"version":1,"type":"doc","content":[
          {"type":"paragraph","marks":[{"type":"alignment","attrs":{"align":"end"}}],"content":[{"type":"text","text":"a"}]},
          {"type":"paragraph","marks":[{"type":"indentation","attrs":{"level":3}}],"content":[{"type":"text","text":"b"}]},
          {"type":"codeBlock","attrs":{"language":"js"},"marks":[{"type":"breakout","attrs":{"mode":"full-width"}}],"content":[{"type":"text","text":"1"}]}
        ]}
        """#)
        #expect(doc.issues.isEmpty)
        #expect(doc.root.children[0].marks == [.alignment(.end)])
        #expect(doc.root.children[1].marks == [.indentation(level: 3)])
        #expect(doc.root.children[2].marks == [.breakout(mode: .fullWidth, width: nil)])
    }

    @Test("border and link marks on media")
    func mediaMarks() async throws {
        let doc = try await parseFixture("kitchen-sink.json")
        let media = try #require(allNodes(in: doc.root).first { node in
            node.type == "media" && !node.marks.isEmpty
        })
        #expect(media.marks == [
            .border(size: 2, colorHex: "#091e4224"),
            .link(href: "https://example.com/full.png", title: nil),
        ])
    }

    @Test("mark with missing required attrs is dropped with an issue")
    func malformedMarkDropped() async throws {
        let doc = try await parseJSON(
            #"{"version":1,"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"x","marks":[{"type":"textColor"}]}]}]}"#
        )
        let text = try #require(doc.root.children.first?.children.first)
        guard case .text(_, let marks) = text.kind else {
            Issue.record("expected .text")
            return
        }
        #expect(marks.isEmpty)
        #expect(doc.issues.count == 1)
    }
}
