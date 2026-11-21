import Foundation
import Testing
@testable import ADFModel

/// Confluence Cloud's atlas_doc_format emits emoji `text` attrs as *literal*
/// `\uXXXX` escape text (double-escaped in the JSON), with the codepoints in
/// hex in `id`. The builder must normalize both to the real character.
@Suite("Emoji text decoding")
struct EmojiDecodingTests {
    private func emojiNode(attrs: String) async throws -> ADFNode {
        let doc = try await parseJSON(#"""
        {"version":1,"type":"doc","content":[{"type":"paragraph","content":[
          {"type":"emoji","attrs":\#(attrs)}
        ]}]}
        """#)
        return try #require(allNodes(in: doc.root).first { $0.type == "emoji" })
    }

    @Test("literal surrogate-pair escape text decodes to the emoji")
    func literalEscapesDecode() async throws {
        let node = try await emojiNode(
            attrs: #"{"shortName":":calendar_spiral:","id":"1f5d3","text":"\\uD83D\\uDDD3"}"#
        )
        guard case .emoji(_, let id, let text) = node.kind else { Issue.record("not emoji"); return }
        #expect(text == "\u{1F5D3}")
        #expect(id == "1f5d3")
    }

    @Test("plain emoji text passes through unchanged")
    func plainTextPassesThrough() async throws {
        let node = try await emojiNode(
            attrs: #"{"shortName":":grinning:","id":"1f600","text":"😀"}"#
        )
        guard case .emoji(_, let id, let text) = node.kind else { Issue.record("not emoji"); return }
        #expect(text == "😀")
        #expect(id == "1f600")
    }

    @Test("missing text falls back to hex codepoints in id, including ZWJ sequences")
    func idFallback() async throws {
        let node = try await emojiNode(
            attrs: #"{"shortName":":man_technologist:","id":"1f468-200d-1f4bb"}"#
        )
        guard case .emoji(_, let id, let text) = node.kind else { Issue.record("not emoji"); return }
        #expect(text == "\u{1F468}\u{200D}\u{1F4BB}")
        #expect(id == "1f468-200d-1f4bb")
    }

    @Test("non-hex custom emoji id yields nil text and keeps the id")
    func customEmojiIdKept() async throws {
        let node = try await emojiNode(
            attrs: #"{"shortName":":custom-logo:","id":"atlassian-logo"}"#
        )
        guard case .emoji(let shortName, let id, let text) = node.kind else { Issue.record("not emoji"); return }
        #expect(shortName == ":custom-logo:")
        #expect(id == "atlassian-logo")
        #expect(text == nil)
    }

    @Test("a non-hex id is custom even with authored text (Confluence writes the short name)")
    func customEmojiWithTextIsCustom() async throws {
        let node = try await emojiNode(
            attrs: #"{"shortName":":partyparrot:","id":"7b4d0c1e-party-parrot","text":":partyparrot:"}"#
        )
        guard case .emoji(let shortName, let id, let text) = node.kind else { Issue.record("not emoji"); return }
        #expect(shortName == ":partyparrot:")
        #expect(id == "7b4d0c1e-party-parrot")
        #expect(text == nil)
    }

    @Test("a hex id with authored text stays unicode text")
    func hexIdWithTextIsUnicode() async throws {
        let node = try await emojiNode(
            attrs: #"{"shortName":":family:","id":"1f468-200d-1f469","text":"👨‍👩"}"#
        )
        guard case .emoji(_, let id, let text) = node.kind else { Issue.record("not emoji"); return }
        #expect(id == "1f468-200d-1f469")
        #expect(text == "\u{1F468}\u{200D}\u{1F469}")
    }

    @Test("an emoji without an id keeps nil")
    func missingIdIsNil() async throws {
        let node = try await emojiNode(attrs: #"{"shortName":":ld-custom-6:"}"#)
        guard case .emoji(let shortName, let id, let text) = node.kind else { Issue.record("not emoji"); return }
        #expect(shortName == ":ld-custom-6:")
        #expect(id == nil)
        #expect(text == nil)
    }
}
