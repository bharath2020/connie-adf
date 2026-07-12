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
        guard case .emoji(_, let text) = node.kind else { Issue.record("not emoji"); return }
        #expect(text == "\u{1F5D3}")
    }

    @Test("plain emoji text passes through unchanged")
    func plainTextPassesThrough() async throws {
        let node = try await emojiNode(
            attrs: #"{"shortName":":grinning:","id":"1f600","text":"😀"}"#
        )
        guard case .emoji(_, let text) = node.kind else { Issue.record("not emoji"); return }
        #expect(text == "😀")
    }

    @Test("missing text falls back to hex codepoints in id, including ZWJ sequences")
    func idFallback() async throws {
        let node = try await emojiNode(
            attrs: #"{"shortName":":man_technologist:","id":"1f468-200d-1f4bb"}"#
        )
        guard case .emoji(_, let text) = node.kind else { Issue.record("not emoji"); return }
        #expect(text == "\u{1F468}\u{200D}\u{1F4BB}")
    }

    @Test("non-hex custom emoji id yields nil text (renders as :shortName:)")
    func customEmojiIdIgnored() async throws {
        let node = try await emojiNode(
            attrs: #"{"shortName":":custom-logo:","id":"atlassian-logo"}"#
        )
        guard case .emoji(let shortName, let text) = node.kind else { Issue.record("not emoji"); return }
        #expect(shortName == ":custom-logo:")
        #expect(text == nil)
    }
}
