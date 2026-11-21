import Foundation
import SwiftUI
import Testing
import ADFModel
import ADFPreparation

private typealias EmojiAttribute = AttributeScopes.ADFAttributes.EmojiAttribute

/// Custom emoji preparation (design §4.7): an emoji with no unicode text is
/// one U+FFFC in its owner's text run carrying its key (`adfEmoji`), never an
/// atom, and every owner records its de-duplicated emoji keys. Unicode emoji
/// stay plain characters.
@Suite("Emoji preparation")
struct EmojiPreparationTests {
    private let composer = InlineComposer(theme: .default)

    private func paragraph(_ inline: String) async throws -> [ADFNode] {
        let doc = try await parseDoc(#"""
        {"version":1,"type":"doc","content":[{"type":"paragraph","content":[\#(inline)]}]}
        """#)
        guard case .doc(let children) = doc.root.kind, case .paragraph(let content, _) = children.first?.kind else {
            throw TestFailure("no paragraph")
        }
        return content
    }

    private func text(_ segments: [InlineSegment]) -> AttributedString {
        segments.reduce(into: AttributedString()) { result, segment in
            if case .text(let text) = segment { result.append(text) }
        }
    }

    /// The (key, character) of every character carrying `adfEmoji`.
    private func emojiCharacters(_ text: AttributedString) -> [(EmojiKey, String)] {
        text.runs[EmojiAttribute.self].flatMap { key, range -> [(EmojiKey, String)] in
            guard let key else { return [] }
            return text[range].characters.map { (key, String($0)) }
        }
    }

    @Test("a custom emoji is one U+FFFC carrying its key, in the text run, not an atom")
    func customEmojiIsObjectReplacementRun() async throws {
        let inline = try await paragraph(#"""
        {"type":"text","text":"Ship "},{"type":"emoji","attrs":{"shortName":":custom-logo:","id":"atlassian-logo"}},{"type":"text","text":" now"}
        """#)
        let composed = composer.composeOwner(inline)
        #expect(composed.segments.count == 1)
        #expect(!composed.segments.contains { if case .atom = $0 { true } else { false } })
        let text = text(composed.segments)
        #expect(String(text.characters) == "Ship \u{FFFC} now")
        let key = EmojiKey(id: "atlassian-logo", shortName: ":custom-logo:")
        let marked = emojiCharacters(text)
        #expect(marked.count == 1)
        #expect(marked.first?.0 == key)
        #expect(marked.first?.1 == "\u{FFFC}")
        #expect(composed.emojiKeys == [key])
        // The emoji character carries the body font and its spec, so the
        // paragraph stays describable (TextKit 2 eligible).
        #expect(text.runs.allSatisfy { $0.adfFontSpec != nil })
    }

    @Test("emoji keys are per owner, de-duplicated, in document order; the id is part of the key")
    func keysPerOwner() async throws {
        let inline = try await paragraph(#"""
        {"type":"emoji","attrs":{"shortName":":b:"}},
        {"type":"emoji","attrs":{"shortName":":a:","id":"logo-one"}},
        {"type":"emoji","attrs":{"shortName":":b:"}},
        {"type":"emoji","attrs":{"shortName":":a:","id":"logo-two"}},
        {"type":"emoji","attrs":{"shortName":":a:","id":"logo-one"}}
        """#)
        let composed = composer.composeOwner(inline)
        #expect(composed.emojiKeys == [
            EmojiKey(id: nil, shortName: ":b:"),
            EmojiKey(id: "logo-one", shortName: ":a:"),
            EmojiKey(id: "logo-two", shortName: ":a:"),
        ])
        let text = text(composed.segments)
        #expect(String(text.characters) == String(repeating: "\u{FFFC}", count: 5))
        #expect(emojiCharacters(text).map(\.0.shortName) == [":b:", ":a:", ":b:", ":a:", ":a:"])
    }

    @Test("unicode emoji stay plain characters with no key")
    func unicodeEmojiUnchanged() async throws {
        let inline = try await paragraph(#"""
        {"type":"text","text":"go "},{"type":"emoji","attrs":{"shortName":":rocket:","id":"1f680","text":"🚀"}},
        {"type":"emoji","attrs":{"shortName":":smile:","id":"1f604"}}
        """#)
        let composed = composer.composeOwner(inline)
        #expect(composed.emojiKeys.isEmpty)
        let text = text(composed.segments)
        #expect(String(text.characters) == "go 🚀😄")
        #expect(emojiCharacters(text).isEmpty)
    }

    @Test("prepared owners carry their emoji keys: paragraph, heading, list leader")
    func ownersCarryKeys() async throws {
        let emoji = #"{"type":"emoji","attrs":{"shortName":":ld-custom-6:"}}"#
        let doc = try await parseDoc(#"""
        {"version":1,"type":"doc","content":[
          {"type":"paragraph","content":[\#(emoji)]},
          {"type":"heading","attrs":{"level":2},"content":[{"type":"text","text":"H "},\#(emoji)]},
          {"type":"bulletList","content":[{"type":"listItem","content":[{"type":"paragraph","content":[\#(emoji)]}]}]},
          {"type":"mediaSingle","attrs":{"layout":"center"},"content":[
            {"type":"media","attrs":{"id":"m1","type":"file","collection":"c"}},
            {"type":"caption","content":[\#(emoji)]}
          ]},
          {"type":"paragraph","content":[{"type":"text","text":"none"}]}
        ]}
        """#)
        let blocks = DocumentPreparer(theme: .default).prepare(doc)
        let key = EmojiKey(id: nil, shortName: ":ld-custom-6:")
        #expect(blocks.count == 5)
        #expect(blocks[0].emojiKeys == [key])
        #expect(blocks[1].emojiKeys == [key])
        guard case .listRows(let rows) = blocks[2].kind else { throw TestFailure("no list") }
        #expect(rows.first?.emojiKeys == [key])
        guard case .media = blocks[3].kind else { throw TestFailure("no media") }
        #expect(blocks[4].emojiKeys.isEmpty)
    }

    @Test("plain text spells a custom emoji as its short name, as authored")
    func plainTextSpellsShortName() async throws {
        let inline = try await paragraph(#"""
        {"type":"text","text":"a "},{"type":"emoji","attrs":{"shortName":":ld-custom-6:"}},
        {"type":"emoji","attrs":{"shortName":":ld-custom-6:"}},{"type":"text","text":" b"}
        """#)
        let plain = composer.plainAttributed(inline)
        #expect(String(plain.characters) == "a :ld-custom-6::ld-custom-6: b")
        #expect(emojiCharacters(plain).isEmpty)
        let prepared = text(composer.compose(inline))
        #expect(InlineComposer.plainText(of: prepared) == "a :ld-custom-6::ld-custom-6: b")
    }

    @Test("list-dense: every custom emoji is keyed on its owner and none is an atom")
    func listDenseEmoji() async throws {
        let doc = try await ADFParser().parse(try fixtureData("list-dense.json"))
        let blocks = DocumentPreparer(theme: .default).prepare(doc)
        var emojiCharacterCount = 0
        var ownersWithKeys = 0
        func visit(segments: [InlineSegment], keys: [EmojiKey]) {
            let marked = emojiCharacters(text(segments))
            emojiCharacterCount += marked.count
            if !keys.isEmpty { ownersWithKeys += 1 }
            var seen: [EmojiKey] = []
            for (key, _) in marked where !seen.contains(key) { seen.append(key) }
            #expect(seen == keys)
        }
        func walk(_ blocks: [RenderBlock]) {
            for block in blocks {
                switch block.kind {
                case .richText(let segments, _): visit(segments: segments, keys: block.emojiKeys)
                case .listRows(let rows):
                    for row in rows {
                        visit(segments: row.segments, keys: row.emojiKeys)
                        walk(row.trailingBlocks)
                    }
                default: break
                }
            }
        }
        walk(blocks)
        #expect(emojiCharacterCount == 80)
        #expect(ownersWithKeys > 0)
    }
}
