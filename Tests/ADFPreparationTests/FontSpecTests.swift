import Foundation
import SwiftUI
import Testing
import ADFModel
import ADFPreparation

private typealias SUI = AttributeScopes.SwiftUIAttributes

/// The semantic font spec baked on every text run at preparation time, next
/// to the SwiftUI `Font`. A non-SwiftUI text engine (TextKit 2) resolves
/// platform fonts from it; the SwiftUI arm keeps reading `Font` and must be
/// unaffected by the extra attribute.
@Suite("Semantic font spec")
struct FontSpecTests {
    private let theme = ADFTheme.default
    private var composer: InlineComposer { InlineComposer(theme: theme) }
    private var preparer: DocumentPreparer { DocumentPreparer(theme: theme) }

    private func paragraphContent(of doc: ADFDocument) throws -> [ADFNode] {
        let first = try #require(doc.root.children.first)
        guard case .paragraph(let content, _) = first.kind else {
            throw TestFailure("first block is not a paragraph")
        }
        return content
    }

    private func mergedText(_ segments: [InlineSegment]) throws -> AttributedString {
        var merged = AttributedString()
        for segment in segments {
            guard case .text(let text) = segment else { throw TestFailure("segment is not text") }
            merged.append(text)
        }
        return merged
    }

    /// The spec of the run containing `substring` (first match).
    private func spec(of substring: String, in text: AttributedString) throws -> ADFFontSpec {
        let range = try #require(text.range(of: substring))
        return try #require(text[range].runs.first?.adfFontSpec)
    }

    // MARK: Theme

    @Test("theme exposes semantic specs matching its SwiftUI fonts")
    func themeSpecs() {
        #expect(theme.bodyFontSpec == ADFFontSpec(textStyle: .body))
        #expect(theme.codeFontSpec == ADFFontSpec(textStyle: .body, monospaced: true))
        #expect(theme.headingFontSpec(1) == ADFFontSpec(textStyle: .title, bold: true))
        #expect(theme.headingFontSpec(2) == ADFFontSpec(textStyle: .title2, bold: true))
        #expect(theme.headingFontSpec(3) == ADFFontSpec(textStyle: .title3, bold: true))
        // `.headline` is already semibold; SwiftUI's `.headline` carries no
        // extra bold, so neither does the spec.
        #expect(theme.headingFontSpec(4) == ADFFontSpec(textStyle: .headline))
        #expect(theme.headingFontSpec(5) == ADFFontSpec(textStyle: .subheadline, bold: true))
        #expect(theme.headingFontSpec(6) == ADFFontSpec(textStyle: .footnote, bold: true))
        // Clamped like `headingFont`.
        #expect(theme.headingFontSpec(0) == theme.headingFontSpec(1))
        #expect(theme.headingFontSpec(9) == theme.headingFontSpec(6))
    }

    @Test("spec round-trips through Codable and is a plain value")
    func specCodable() throws {
        let spec = ADFFontSpec(textStyle: .footnote, bold: true, italic: true, monospaced: true)
        let data = try JSONEncoder().encode(spec)
        let decoded = try JSONDecoder().decode(ADFFontSpec.self, from: data)
        #expect(decoded == spec)
        #expect(Set([spec, spec]).count == 1)
    }

    // MARK: Composer

    @Test("every text run of a paragraph carries a spec, with traits per mark")
    func paragraphRunsCarrySpecs() async throws {
        let doc = try await parseDoc("""
        {"version":1,"type":"doc","content":[{"type":"paragraph","content":[
          {"type":"text","text":"plain "},
          {"type":"text","text":"bold ","marks":[{"type":"strong"}]},
          {"type":"text","text":"italic ","marks":[{"type":"em"}]},
          {"type":"text","text":"both ","marks":[{"type":"strong"},{"type":"em"}]},
          {"type":"text","text":"code ","marks":[{"type":"code"}]},
          {"type":"text","text":"boldcode ","marks":[{"type":"code"},{"type":"strong"}]},
          {"type":"text","text":"small ","marks":[{"type":"subsup","attrs":{"type":"sub"}}]},
          {"type":"text","text":"sup ","marks":[{"type":"subsup","attrs":{"type":"sup"}}]},
          {"type":"text","text":"supcode ","marks":[{"type":"subsup","attrs":{"type":"sup"}},{"type":"code"}]},
          {"type":"text","text":"tiny ","marks":[{"type":"fontSize","attrs":{"size":"small"}}]},
          {"type":"text","text":"link ","marks":[{"type":"link","attrs":{"href":"https://example.com"}}]},
          {"type":"hardBreak"},
          {"type":"text","text":"colored","marks":[{"type":"textColor","attrs":{"color":"#ff5630"}}]}
        ]}]}
        """)
        let text = try mergedText(composer.compose(try paragraphContent(of: doc)))

        // No run is left without a spec — the TextKit arm must never fall
        // back to a guessed font.
        for run in text.runs {
            #expect(run.adfFontSpec != nil, "run without spec: \(text[run.range])")
        }
        #expect(try spec(of: "plain", in: text) == ADFFontSpec(textStyle: .body))
        #expect(try spec(of: "bold ", in: text) == ADFFontSpec(textStyle: .body, bold: true))
        #expect(try spec(of: "italic", in: text) == ADFFontSpec(textStyle: .body, italic: true))
        #expect(try spec(of: "both", in: text) == ADFFontSpec(textStyle: .body, bold: true, italic: true))
        #expect(try spec(of: "code ", in: text) == ADFFontSpec(textStyle: .body, monospaced: true))
        #expect(try spec(of: "boldcode", in: text) == ADFFontSpec(textStyle: .body, bold: true, monospaced: true))
        #expect(try spec(of: "small", in: text) == ADFFontSpec(textStyle: .footnote))
        #expect(try spec(of: "sup ", in: text) == ADFFontSpec(textStyle: .footnote))
        #expect(try spec(of: "supcode", in: text) == ADFFontSpec(textStyle: .footnote, monospaced: true))
        #expect(try spec(of: "tiny", in: text) == ADFFontSpec(textStyle: .subheadline))
        #expect(try spec(of: "link", in: text) == ADFFontSpec(textStyle: .body))
        #expect(try spec(of: "\n", in: text) == ADFFontSpec(textStyle: .body))
        #expect(try spec(of: "colored", in: text) == ADFFontSpec(textStyle: .body))
    }

    @Test("the SwiftUI font attribute is unchanged by the spec (SwiftUI arm stays identical)")
    func swiftUIFontUnchanged() async throws {
        let doc = try await parseDoc("""
        {"version":1,"type":"doc","content":[{"type":"paragraph","content":[
          {"type":"text","text":"bold","marks":[{"type":"strong"}]},
          {"type":"text","text":"code","marks":[{"type":"code"}]}
        ]}]}
        """)
        let text = try mergedText(composer.compose(try paragraphContent(of: doc)))
        let bold = try #require(text.range(of: "bold"))
        let code = try #require(text.range(of: "code"))
        #expect(text[bold].runs.first?.attributes[SUI.FontAttribute.self] == theme.body.bold())
        #expect(text[code].runs.first?.attributes[SUI.FontAttribute.self] == theme.code)
    }

    @Test("placeholder runs carry an italic base spec")
    func placeholderSpec() async throws {
        let doc = try await parseDoc("""
        {"version":1,"type":"doc","content":[{"type":"paragraph","content":[
          {"type":"placeholder","attrs":{"text":"type here"}}
        ]}]}
        """)
        let text = try mergedText(composer.compose(try paragraphContent(of: doc)))
        #expect(try spec(of: "type here", in: text) == ADFFontSpec(textStyle: .body, italic: true))
    }

    @Test("atom fallbacks in plainAttributed carry the body spec")
    func plainAttributedFallbackSpec() async throws {
        let doc = try await parseDoc("""
        {"version":1,"type":"doc","content":[{"type":"paragraph","content":[
          {"type":"text","text":"hi "},
          {"type":"mention","attrs":{"id":"1","text":"@sam"}}
        ]}]}
        """)
        let text = composer.plainAttributed(try paragraphContent(of: doc))
        #expect(try spec(of: "@sam", in: text) == ADFFontSpec(textStyle: .body))
    }

    // MARK: Preparer

    @Test("headings bake their level spec on unmarked runs and combine it with marks")
    func headingSpecs() async throws {
        let doc = try await parseDoc("""
        {"version":1,"type":"doc","content":[
          {"type":"heading","attrs":{"level":2},"content":[
            {"type":"text","text":"Title "},
            {"type":"text","text":"em","marks":[{"type":"em"}]},
            {"type":"text","text":" code","marks":[{"type":"code"}]}
          ]},
          {"type":"heading","attrs":{"level":4},"content":[{"type":"text","text":"Four"}]},
          {"type":"paragraph","content":[{"type":"text","text":"Body"}]}
        ]}
        """)
        let blocks = preparer.prepare(doc)
        #expect(blocks.count == 3)

        guard case .richText(let h2Segments, let h2Style) = blocks[0].kind else {
            throw TestFailure("block 0 is not richText")
        }
        #expect(h2Style.isHeading)
        let h2 = try mergedText(h2Segments)
        #expect(try spec(of: "Title", in: h2) == ADFFontSpec(textStyle: .title2, bold: true))
        #expect(try spec(of: "em", in: h2) == ADFFontSpec(textStyle: .title2, bold: true, italic: true))
        // Inline code inside a heading uses the theme's code font (body
        // mono), exactly as the SwiftUI `Font` attribute does.
        #expect(try spec(of: "code", in: h2) == ADFFontSpec(textStyle: .body, monospaced: true))

        guard case .richText(let h4Segments, _) = blocks[1].kind else {
            throw TestFailure("block 1 is not richText")
        }
        #expect(try spec(of: "Four", in: try mergedText(h4Segments)) == ADFFontSpec(textStyle: .headline))

        guard case .richText(let pSegments, _) = blocks[2].kind else {
            throw TestFailure("block 2 is not richText")
        }
        #expect(try spec(of: "Body", in: try mergedText(pSegments)) == ADFFontSpec(textStyle: .body))
    }

    @Test("list-item paragraphs and table-cell paragraphs carry the body spec")
    func nestedParagraphSpecs() async throws {
        let doc = try await parseDoc("""
        {"version":1,"type":"doc","content":[
          {"type":"bulletList","content":[{"type":"listItem","content":[
            {"type":"paragraph","content":[{"type":"text","text":"item","marks":[{"type":"strong"}]}]}
          ]}]}
        ]}
        """)
        let blocks = preparer.prepare(doc)
        guard case .listRows(let rows) = try #require(blocks.first).kind else {
            throw TestFailure("block is not listRows")
        }
        let text = try mergedText(try #require(rows.first).segments)
        #expect(try spec(of: "item", in: text) == ADFFontSpec(textStyle: .body, bold: true))
    }
}
