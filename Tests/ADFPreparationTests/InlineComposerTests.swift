import Foundation
import SwiftUI
import Testing
import ADFModel
import ADFPreparation

private typealias SUI = AttributeScopes.SwiftUIAttributes

@Suite("InlineComposer")
struct InlineComposerTests {
    private let theme = ADFTheme.default
    private var composer: InlineComposer { InlineComposer(theme: theme) }

    private func inlineContent(of doc: ADFDocument) throws -> [ADFNode] {
        let first = try #require(doc.root.children.first)
        guard case .paragraph(let content, _) = first.kind else {
            throw TestFailure("first block is not a paragraph")
        }
        return content
    }

    @Test("adjacent bold + italic + link text nodes merge into one segment carrying all three attributes")
    func adjacentMarkedTextMergesIntoOneSegment() async throws {
        let doc = try await parseDoc("""
        {"version":1,"type":"doc","content":[{"type":"paragraph","content":[
          {"type":"text","text":"bold ","marks":[{"type":"strong"}]},
          {"type":"text","text":"italic ","marks":[{"type":"em"}]},
          {"type":"text","text":"link","marks":[{"type":"link","attrs":{"href":"https://example.com"}}]}
        ]}]}
        """)
        let segments = composer.compose(try inlineContent(of: doc))
        #expect(segments.count == 1)
        guard case .text(let merged) = try #require(segments.first) else {
            throw TestFailure("segment is not text")
        }
        #expect(String(merged.characters) == "bold italic link")

        var sawBold = false, sawItalic = false, sawLink = false
        for run in merged.runs {
            let font = run.attributes[SUI.FontAttribute.self]
            if font == theme.body.bold() { sawBold = true }
            if font == theme.body.italic() { sawItalic = true }
            if run.attributes[AttributeScopes.FoundationAttributes.LinkAttribute.self] == URL(string: "https://example.com") {
                sawLink = true
                #expect(run.attributes[SUI.UnderlineStyleAttribute.self] == .single)
            }
        }
        #expect(sawBold)
        #expect(sawItalic)
        #expect(sawLink)
    }

    @Test("strong + em + link on a single text node combine on one run")
    func combinedMarksApplyToOneRun() async throws {
        let doc = try await parseDoc("""
        {"version":1,"type":"doc","content":[{"type":"paragraph","content":[
          {"type":"text","text":"all three","marks":[
            {"type":"strong"},{"type":"em"},
            {"type":"link","attrs":{"href":"https://example.com/a"}}
          ]}
        ]}]}
        """)
        let segments = composer.compose(try inlineContent(of: doc))
        #expect(segments.count == 1)
        guard case .text(let text) = try #require(segments.first) else {
            throw TestFailure("segment is not text")
        }
        #expect(text[SUI.FontAttribute.self] == theme.body.bold().italic())
        #expect(text[AttributeScopes.FoundationAttributes.LinkAttribute.self] == URL(string: "https://example.com/a"))
        #expect(text[SUI.UnderlineStyleAttribute.self] == .single)
    }

    @Test("code mark gets monospaced font and a background")
    func codeMarkStyling() async throws {
        let doc = try await parseDoc("""
        {"version":1,"type":"doc","content":[{"type":"paragraph","content":[
          {"type":"text","text":"let x = 1","marks":[{"type":"code"}]}
        ]}]}
        """)
        let segments = composer.compose(try inlineContent(of: doc))
        guard case .text(let text) = try #require(segments.first) else {
            throw TestFailure("segment is not text")
        }
        #expect(text[SUI.FontAttribute.self] == theme.code)
        #expect(text[SUI.BackgroundColorAttribute.self] != nil)
    }

    @Test("hardBreak becomes a newline inside the merged text segment")
    func hardBreakMerges() async throws {
        let doc = try await parseDoc("""
        {"version":1,"type":"doc","content":[{"type":"paragraph","content":[
          {"type":"text","text":"before"},{"type":"hardBreak"},{"type":"text","text":"after"}
        ]}]}
        """)
        let segments = composer.compose(try inlineContent(of: doc))
        #expect(segments.count == 1)
        guard case .text(let text) = try #require(segments.first) else {
            throw TestFailure("segment is not text")
        }
        #expect(String(text.characters) == "before\nafter")
    }

    @Test("atoms split segments and carry stable structural IDs")
    func atomsSplitSegments() async throws {
        let doc = try await parseDoc("""
        {"version":1,"type":"doc","content":[{"type":"paragraph","content":[
          {"type":"text","text":"state "},
          {"type":"status","attrs":{"text":"ON TRACK","color":"green"}},
          {"type":"text","text":" today"}
        ]}]}
        """)
        let segments = composer.compose(try inlineContent(of: doc))
        #expect(segments.count == 3)
        guard case .atom(let atom, let id) = segments[1] else {
            throw TestFailure("middle segment is not an atom")
        }
        #expect(atom == .status(text: "ON TRACK", color: .green))
        #expect(id == "0.0.1")
    }

    @Test("subsup shifts the baseline and shrinks the font")
    func subsupBaseline() async throws {
        let doc = try await parseDoc("""
        {"version":1,"type":"doc","content":[{"type":"paragraph","content":[
          {"type":"text","text":"2","marks":[{"type":"subsup","attrs":{"type":"sup"}}]}
        ]}]}
        """)
        let segments = composer.compose(try inlineContent(of: doc))
        guard case .text(let text) = try #require(segments.first) else {
            throw TestFailure("segment is not text")
        }
        let offset = try #require(text[SUI.BaselineOffsetAttribute.self])
        #expect(offset > 0)
        #expect(text[SUI.FontAttribute.self] != theme.body)
    }

    @Test("plainAttributed renders atoms as text fallbacks")
    func plainAttributedFallbacks() async throws {
        let doc = try await parseDoc("""
        {"version":1,"type":"doc","content":[{"type":"paragraph","content":[
          {"type":"text","text":"ping "},
          {"type":"mention","attrs":{"id":"u1","text":"@maria"}}
        ]}]}
        """)
        let plain = composer.plainAttributed(try inlineContent(of: doc))
        #expect(String(plain.characters) == "ping @maria")
    }
}

/// Lightweight error for guard-else paths in tests.
struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
