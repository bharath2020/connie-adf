import Foundation
import SwiftUI
import Testing
import ADFPreparation
@testable import ADFRendering

@Suite("TextRowContent") @MainActor
struct TextRowContentTests {
    private func textSegment(_ s: String, spec: FontSpec = .body) -> InlineSegment {
        var t = AttributedString(s)
        t[FontSpecAttribute.self] = spec
        return .text(t)
    }

    @Test func fontsResolvePerRunSpec() {
        let content = TextRowContent.make(
            segments: [textSegment("plain"), textSegment("big", spec: FontSpec(style: .title, bold: true))],
            categoryRawValue: "UICTContentSizeCategoryL",
            alignment: .natural, baselineScale: 1, rightToLeft: false)
        var fonts: [ADFPlatformFont] = []
        content.attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: content.attributed.length)) { value, _, _ in
            if let f = value as? ADFPlatformFont { fonts.append(f) }
        }
        #expect(fonts.count == 2)
        #expect(fonts[1].pointSize > fonts[0].pointSize)
    }

    @Test func utf16StartsAccountForEmoji() {
        let content = TextRowContent.make(
            segments: [textSegment("a😄b"), textSegment("tail")],
            categoryRawValue: "UICTContentSizeCategoryL",
            alignment: .natural, baselineScale: 1, rightToLeft: false)
        #expect(content.segmentUTF16Starts == [0, 4])     // 😄 is 2 UTF-16 units
    }

    @Test func charRangeToUTF16RangeCrossesEmoji() {
        let content = TextRowContent.make(
            segments: [textSegment("a😄bc")],
            categoryRawValue: "UICTContentSizeCategoryL",
            alignment: .natural, baselineScale: 1, rightToLeft: false)
        // Characters [2..4) = "bc" → UTF-16 [3..5)
        let r = TextRowContent.utf16Range(charRange: 2..<4, inSegment: 0, of: content)
        #expect(r == NSRange(location: 3, length: 2))
    }

    @Test func charRangeToUTF16RangeIsAbsoluteAcrossSegments() {
        let content = TextRowContent.make(
            segments: [textSegment("x"), textSegment("y😄z")],
            categoryRawValue: "UICTContentSizeCategoryL",
            alignment: .natural, baselineScale: 1, rightToLeft: false)
        // Segment 1 ("y😄z") characters [1..3) = "😄z" → local UTF-16 [1..4).
        // Segment 0 ("x") contributes 1 UTF-16 unit ahead of segment 1, so the
        // absolute location must include segmentUTF16Starts[1] (== 1).
        let r = TextRowContent.utf16Range(charRange: 1..<3, inSegment: 1, of: content)
        #expect(r == NSRange(location: 2, length: 3))
    }

    @Test func underlineStrikeBaselineAndLinkConvert() throws {
        var t = AttributedString("styled")
        t[FontSpecAttribute.self] = .body
        t[AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self] = .single
        t[AttributeScopes.SwiftUIAttributes.StrikethroughStyleAttribute.self] = .single
        t[AttributeScopes.SwiftUIAttributes.BaselineOffsetAttribute.self] = 5.1
        t[AttributeScopes.FoundationAttributes.LinkAttribute.self] = URL(string: "https://x.test")!
        let content = TextRowContent.make(
            segments: [.text(t)], categoryRawValue: "UICTContentSizeCategoryL",
            alignment: .natural, baselineScale: 2, rightToLeft: false)
        let attrs = content.attributed.attributes(at: 0, effectiveRange: nil)
        #expect(attrs[.underlineStyle] as? Int == NSUnderlineStyle.single.rawValue)
        #expect(attrs[.strikethroughStyle] as? Int == NSUnderlineStyle.single.rawValue)
        #expect(attrs[.baselineOffset] as? CGFloat == 10.2)   // scaled by baselineScale
        #expect(attrs[.link] as? URL == URL(string: "https://x.test"))
    }
}
