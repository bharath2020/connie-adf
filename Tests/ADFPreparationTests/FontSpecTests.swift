import Foundation
import SwiftUI
import Testing
import ADFModel
import ADFPreparation

@Suite("FontSpec attribute")
struct FontSpecTests {
    @Test func attributeRoundTripsThroughAttributedString() {
        var text = AttributedString("hello")
        let spec = FontSpec(style: .title2, bold: true, italic: false, monospaced: false)
        text[FontSpecAttribute.self] = spec
        #expect(text.runs.count == 1)
        #expect(text.runs.first?[FontSpecAttribute.self] == spec)  // explicit subscript — reliable regardless of dynamic-lookup wiring
    }

    @Test func specIsCodableForAttributeArchiving() throws {
        let spec = FontSpec(style: .footnote, bold: false, italic: true, monospaced: true)
        let data = try JSONEncoder().encode(spec)
        #expect(try JSONDecoder().decode(FontSpec.self, from: data) == spec)
    }

    @Test func composerBakesSpecsMirroringFonts() async throws {
        let theme = ADFTheme.default
        let composer = InlineComposer(theme: theme)
        let nodes = try await inlineNodes(json: """
        [{"type":"text","text":"plain "},
         {"type":"text","text":"bold","marks":[{"type":"strong"}]},
         {"type":"text","text":"code","marks":[{"type":"code"}]},
         {"type":"text","text":"small","marks":[{"type":"fontSize","attrs":{"size":"small"}}]},
         {"type":"text","text":"sup","marks":[{"type":"subsup","attrs":{"type":"sup"}}]}]
        """)
        let segments = composer.compose(nodes)
        guard case .text(let text) = try #require(segments.first) else {
            Issue.record("expected one merged text segment"); return
        }
        let specs = text.runs.map { $0[FontSpecAttribute.self] }
        #expect(specs[0] == FontSpec.body)
        #expect(specs[1] == FontSpec(style: .body, bold: true))
        #expect(specs[2] == FontSpec(style: .body, monospaced: true))
        #expect(specs[3] == FontSpec(style: .subheadline))
        #expect(specs[4] == FontSpec(style: .footnote))
    }

    @Test func headingSpecsMatchHeadingFonts() {
        let theme = ADFTheme.default
        #expect(theme.headingSpec(1) == FontSpec(style: .title, bold: true))
        #expect(theme.headingSpec(4) == FontSpec(style: .headline))
        #expect(theme.headingSpec(9) == FontSpec(style: .footnote, bold: true))
    }
}
