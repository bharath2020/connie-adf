import Foundation
import SwiftUI
import Testing
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
}
