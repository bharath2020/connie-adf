import Foundation
import SwiftUI
import Testing
import ADFModel
import ADFPreparation

private typealias SmartLinkAttribute = AttributeScopes.ADFAttributes.SmartLinkAttribute

/// Smart-link qualification and preparation (design §1): which links
/// qualify, their canonical keys, and how qualifying links and inline cards
/// are prepared as smart-link runs with per-owner key lists.
@Suite("Smart link preparation")
struct SmartLinkPreparationTests {
    /// A composer for a document loaded with a resolver installed: inline
    /// cards become smart links too.
    private let composer = InlineComposer(theme: .default, inlineCardsAsSmartLinks: true)

    // MARK: Qualification

    @Test("http(s) URLs on *.atlassian.net hosts qualify; lookalikes and other schemes do not",
          arguments: [
              ("https://acme.atlassian.net/wiki/spaces/DOC/pages/1", true),
              ("http://acme.atlassian.net/browse/ADF-1", true),
              ("HTTPS://ACME.Atlassian.NET/wiki/x", true),
              ("https://acme.atlassian.net./wiki/x", true),
              ("https://a.b.atlassian.net/x", true),
              ("https://atlassian.net/wiki/x", false),
              ("https://.atlassian.net/x", false),
              ("https://evilatlassian.net/wiki/x", false),
              ("https://acme.atlassian.net.evil.com/wiki/x", false),
              ("https://acme.atlassian.network/x", false),
              ("https://example.com/acme.atlassian.net", false),
              ("ftp://acme.atlassian.net/x", false),
              ("mailto:someone@acme.atlassian.net", false),
              ("acme.atlassian.net/wiki/x", false),
              ("not a url atlassian.net", false),
              ("https://user:pw@acme.atlassian.net/wiki/x", false),
              ("https://user@acme.atlassian.net/wiki/x", false),
              ("https://:pw@acme.atlassian.net/wiki/x", false),
              ("https://evil.com@acme.atlassian.net/wiki/x", false),
              ("https://acme.atlassian.net:443/wiki/x", true),
              ("https://acme.atlassian.net:8443/wiki/x", true),
          ])
    func qualification(url: String, qualifies: Bool) {
        #expect((SmartLinkQualification.key(for: url) != nil) == qualifies, "\(url)")
    }

    @Test("the key is canonical: scheme and host lowercased, fragment removed, the rest kept")
    func canonicalKey() throws {
        let key = try #require(SmartLinkKey("HTTPS://Acme.ATLASSIAN.net/wiki/Spaces/DOC/pages/1/Q3+Roadmap?focusedCommentId=7#comment-7"))
        #expect(key.url.absoluteString == "https://acme.atlassian.net/wiki/Spaces/DOC/pages/1/Q3+Roadmap?focusedCommentId=7")
        #expect(SmartLinkKey("https://acme.atlassian.net/wiki/x#a") == SmartLinkKey("https://ACME.atlassian.net/wiki/x#b"))
        #expect(SmartLinkKey("https://acme.atlassian.net/wiki/X") != SmartLinkKey("https://acme.atlassian.net/wiki/x"))
    }

    @Test("the key drops a trailing host dot and the scheme's default port; other ports are kept")
    func keyNormalisesHostAndPort() throws {
        let plain = try #require(SmartLinkKey("https://acme.atlassian.net/wiki/x"))
        #expect(try #require(SmartLinkKey("https://ACME.atlassian.net./wiki/x")) == plain)
        #expect(SmartLinkKey("https://acme.atlassian.net./wiki/x")?.url.host == "acme.atlassian.net")
        #expect(try #require(SmartLinkKey("https://acme.atlassian.net:443/wiki/x")) == plain)
        #expect(try #require(SmartLinkKey("https://acme.atlassian.net.:443/wiki/x#f")) == plain)
        #expect(SmartLinkKey("http://acme.atlassian.net:80/wiki/x")?.url.absoluteString == "http://acme.atlassian.net/wiki/x")
        // Another port is part of the resource, and http's default is not https's.
        #expect(SmartLinkKey("https://acme.atlassian.net:8443/wiki/x")?.url.absoluteString == "https://acme.atlassian.net:8443/wiki/x")
        #expect(SmartLinkKey("https://acme.atlassian.net:80/wiki/x")?.url.absoluteString == "https://acme.atlassian.net:80/wiki/x")
        #expect(SmartLinkKey("http://acme.atlassian.net:443/wiki/x")?.url.absoluteString == "http://acme.atlassian.net:443/wiki/x")
    }

    @Test("a bare link carrying user info stays an ordinary link")
    func userInfoStaysPlain() async throws {
        let url = "https://user:secret@acme.atlassian.net/wiki/x"
        let composed = composer.composeOwner(try await paragraph(Self.link(url, url)))
        #expect(composed.smartLinkKeys.isEmpty)
        let text = try Self.onlyText(composed.segments)
        #expect(Self.smartRuns(text).isEmpty)
        #expect(text.runs.first?.link == URL(string: url))
    }

    @Test("a link is bare when its text is its href after normalising both",
          arguments: [
              ("https://acme.atlassian.net/wiki/x", "https://acme.atlassian.net/wiki/x", true),
              ("acme.atlassian.net/wiki/x", "https://acme.atlassian.net/wiki/x", true),
              ("  https://acme.atlassian.net/wiki/x/ ", "https://acme.atlassian.net/wiki/x", true),
              ("http://ACME.atlassian.net/wiki/x", "https://acme.atlassian.net/wiki/x/", true),
              ("https://acme.atlassian.net/wiki/X", "https://acme.atlassian.net/wiki/x", false),
              ("see the design doc", "https://acme.atlassian.net/wiki/x", false),
              ("https://acme.atlassian.net/wiki/x and more", "https://acme.atlassian.net/wiki/x", false),
          ])
    func bareness(text: String, href: String, bare: Bool) {
        #expect(SmartLinkQualification.isBare(text: text, href: href) == bare, "\(text) vs \(href)")
    }

    // MARK: Composition

    private func paragraph(_ content: String) async throws -> [ADFNode] {
        let doc = try await parseDoc(#"{"version":1,"type":"doc","content":[{"type":"paragraph","content":[\#(content)]}]}"#)
        guard case .paragraph(let inline, _) = try #require(doc.root.children.first).kind else {
            throw TestFailure("not a paragraph")
        }
        return inline
    }

    private static func link(_ text: String, _ href: String, extraMarks: String = "") -> String {
        #"{"type":"text","text":"\#(text)","marks":[\#(extraMarks)\#(extraMarks.isEmpty ? "" : ",")"#
            + #"{"type":"link","attrs":{"href":"\#(href)"}}]}"#
    }

    /// (characters, run value) for every smart-link run of a text segment.
    private static func smartRuns(_ text: AttributedString) -> [(String, SmartLinkRun)] {
        text.runs[SmartLinkAttribute.self].compactMap { value, range in
            value.map { (String(text[range].characters), $0) }
        }
    }

    private static func onlyText(_ segments: [InlineSegment]) throws -> AttributedString {
        guard segments.count == 1, case .text(let text) = segments[0] else {
            throw TestFailure("expected one text segment, got \(segments.count)")
        }
        return text
    }

    @Test("a bare Atlassian link becomes a smart-link run and keeps its link styling; a labelled one does not")
    func bareVersusLabelled() async throws {
        let url = "https://acme.atlassian.net/wiki/spaces/DOC/pages/1"
        let composed = composer.composeOwner(try await paragraph(
            #"{"type":"text","text":"See "},"# + Self.link(url, url) + #",{"type":"text","text":" and "},"#
                + Self.link("the design doc", "https://acme.atlassian.net/wiki/spaces/DOC/pages/2")
        ))
        let text = try Self.onlyText(composed.segments)
        let runs = Self.smartRuns(text)
        #expect(runs.map(\.0) == [url])
        #expect(runs.map(\.1.occurrence) == [0])
        #expect(composed.smartLinkKeys == [try #require(SmartLinkKey(url))])
        for run in text.runs where run[SmartLinkAttribute.self] != nil {
            #expect(run.link == URL(string: url))
            #expect(run.underlineStyle == .single)
            #expect(run.adfFontSpec != nil)
        }
        // The labelled link is an ordinary link.
        let labelled = text.runs.first { String(text[$0.range].characters) == "the design doc" }
        #expect(labelled?.link != nil)
        #expect(labelled?[SmartLinkAttribute.self] == nil)
    }

    @Test("non-Atlassian and lookalike bare links are not smart links; a link with a code mark is not either")
    func negatives() async throws {
        let composed = composer.composeOwner(try await paragraph([
            Self.link("https://example.com/wiki/x", "https://example.com/wiki/x"),
            #"{"type":"text","text":" "}"#,
            Self.link("https://evilatlassian.net/wiki/x", "https://evilatlassian.net/wiki/x"),
            #"{"type":"text","text":" "}"#,
            Self.link("https://acme.atlassian.net/wiki/c", "https://acme.atlassian.net/wiki/c", extraMarks: #"{"type":"code"}"#),
        ].joined(separator: ",")))
        #expect(composed.smartLinkKeys.isEmpty)
        #expect(Self.smartRuns(try Self.onlyText(composed.segments)).isEmpty)
    }

    @Test("repeated URLs share one key; each occurrence stays a distinct run, even back to back")
    func dedupAndOccurrences() async throws {
        let a = "https://acme.atlassian.net/wiki/a", b = "https://acme.atlassian.net/browse/ADF-1"
        let composed = composer.composeOwner(try await paragraph([
            #"{"type":"inlineCard","attrs":{"url":"\#(a)"}}"#,
            #"{"type":"inlineCard","attrs":{"url":"\#(a)"}}"#,
            #"{"type":"text","text":" then "}"#,
            Self.link(b, b),
            #"{"type":"text","text":" and "}"#,
            Self.link(a + "#frag", a + "#frag"),
        ].joined(separator: ",")))
        let keyA = try #require(SmartLinkKey(a)), keyB = try #require(SmartLinkKey(b))
        #expect(composed.smartLinkKeys == [keyA, keyB])
        let runs = Self.smartRuns(try Self.onlyText(composed.segments))
        // The two cards show their host.
        #expect(runs.map(\.0) == ["acme.atlassian.net", "acme.atlassian.net", b, a + "#frag"])
        #expect(runs.map(\.1.occurrence) == [0, 1, 2, 3])
        #expect(runs.map(\.1.key) == [keyA, keyA, keyB, keyA])
    }

    @Test("with a resolver, a qualifying inline card is a smart-link text run showing its host, not a chip atom")
    func inlineCardBecomesText() async throws {
        let url = "https://acme.atlassian.net/wiki/spaces/DOC/pages/1"
        let composed = composer.composeOwner(try await paragraph(
            #"{"type":"text","text":"see "},{"type":"inlineCard","attrs":{"url":"\#(url)"}},{"type":"text","text":" now"}"#
        ))
        // One merged text segment: no atom, so no word chunking.
        let text = try Self.onlyText(composed.segments)
        #expect(String(text.characters) == "see acme.atlassian.net now")
        let runs = Self.smartRuns(text)
        #expect(runs.map(\.0) == ["acme.atlassian.net"])
        let run = try #require(text.runs.first { $0[SmartLinkAttribute.self] != nil })
        #expect(run.link == URL(string: url))
        #expect(run.underlineStyle == .single)
        #expect(run.adfFontSpec == ADFTheme.default.bodyFontSpec)
        #expect(composed.smartLinkKeys == [try #require(SmartLinkKey(url))])
    }

    @Test("an inline card taking its URL from data qualifies too; a non-qualifying card keeps its chip")
    func inlineCardFallbacks() async throws {
        let url = "https://acme.atlassian.net/browse/ADF-9"
        let fromData = composer.composeOwner(try await paragraph(
            #"{"type":"inlineCard","attrs":{"data":{"url":"\#(url)"}}}"#
        ))
        #expect(Self.smartRuns(try Self.onlyText(fromData.segments)).map(\.0) == ["acme.atlassian.net"])

        let other = composer.composeOwner(try await paragraph(
            #"{"type":"text","text":"see "},{"type":"inlineCard","attrs":{"url":"https://example.com/x"}}"#
        ))
        #expect(other.smartLinkKeys.isEmpty)
        #expect(other.segments.contains { if case .atom(.inlineCard("https://example.com/x"), _) = $0 { return true }; return false })
    }

    @Test("without a resolver an inline card keeps its chip exactly as before, and is not a smart link")
    func inlineCardWithoutResolverKeepsChip() async throws {
        let url = "https://acme.atlassian.net/wiki/spaces/DOC/pages/1"
        let inline = try await paragraph(
            #"{"type":"text","text":"see "},{"type":"inlineCard","attrs":{"url":"\#(url)"}},{"type":"text","text":" now"}"#
        )
        for composer in [InlineComposer(theme: .default), InlineComposer(theme: .default, inlineCardsAsSmartLinks: false)] {
            let composed = composer.composeOwner(inline)
            #expect(composed.smartLinkKeys.isEmpty)
            #expect(composed.segments.contains { if case .atom(.inlineCard(url), _) = $0 { return true }; return false })
            #expect(composed.segments == composer.compose(inline))
        }
        // The public preparer keeps the chip; the model's, with a resolver, does not.
        let json = #"{"version":1,"type":"doc","content":[{"type":"paragraph","content":[{"type":"inlineCard","attrs":{"url":"\#(url)"}}]}]}"#
        let doc = try await parseDoc(json)
        #expect(DocumentPreparer(theme: .default).prepare(doc).first?.smartLinkKeys == [])
        let smart = DocumentPreparer(theme: .default, inlineCardsAsSmartLinks: true).prepare(doc)
        #expect(smart.first?.smartLinkKeys == [try #require(SmartLinkKey(url))])
    }

    @Test("a link split over adjacent text nodes is one smart link over its whitespace-trimmed text")
    func multiNodeAndPaddedLinks() async throws {
        let url = "https://acme.atlassian.net/wiki/spaces/DOC/pages/7"
        let split = composer.composeOwner(try await paragraph([
            Self.link("https://acme.atlassian.net/wiki/", url, extraMarks: #"{"type":"strong"}"#),
            Self.link("spaces/DOC/pages/7", url),
        ].joined(separator: ",")))
        let splitRuns = Self.smartRuns(try Self.onlyText(split.segments))
        // Two attribute runs (bold, then plain) with one value: one link.
        #expect(Set(splitRuns.map(\.1)).count == 1)
        #expect(splitRuns.map(\.0).joined() == url)

        let padded = composer.composeOwner(try await paragraph(
            #"{"type":"text","text":"x "},"# + Self.link("  \(url) ", url)
        ))
        let text = try Self.onlyText(padded.segments)
        #expect(Self.smartRuns(text).map(\.0) == [url])
        // The padding keeps the link (its href) but is not the smart link.
        #expect(text.runs.filter { $0.link != nil }.map { String(text[$0.range].characters) }.joined() == "  \(url) ")
    }

    @Test("in an atom paragraph a smart link stays whole inside one word chunk")
    func atomParagraphChunking() async throws {
        let url = "https://acme.atlassian.net/wiki/x"
        let composed = composer.composeOwner(try await paragraph(
            #"{"type":"text","text":"Ping "},{"type":"mention","attrs":{"id":"1","text":"@sam"}},{"type":"text","text":" see "},"#
                + Self.link(url, url) + #",{"type":"text","text":" ok"}"#
        ))
        let chunks = composed.segments.compactMap { segment -> AttributedString? in
            if case .text(let text) = segment { return text }
            return nil
        }
        let withLink = chunks.filter { !Self.smartRuns($0).isEmpty }
        #expect(withLink.count == 1)
        #expect(withLink.first.map { Self.smartRuns($0).map(\.0) } == [url])
        #expect(composed.smartLinkKeys.count == 1)
    }

    // MARK: Owners

    @Test("every text owner records its own smart-link keys: paragraph, heading, list leader, table cell, caption")
    func ownersRecordKeys() async throws {
        let p = "https://acme.atlassian.net/wiki/p", h = "https://acme.atlassian.net/wiki/h"
        let l = "https://acme.atlassian.net/wiki/l", c = "https://acme.atlassian.net/wiki/c"
        let cap = "https://acme.atlassian.net/wiki/cap"
        func para(_ url: String) -> String { #"{"type":"paragraph","content":[\#(Self.link(url, url))]}"# }
        let json = #"{"version":1,"type":"doc","content":["#
            + para(p) + ","
            + #"{"type":"heading","attrs":{"level":2},"content":[\#(Self.link(h, h))]},"#
            + #"{"type":"bulletList","content":[{"type":"listItem","content":[\#(para(l))]}]},"#
            + #"{"type":"table","content":[{"type":"tableRow","content":[{"type":"tableCell","content":[\#(para(c))]}]}]},"#
            + #"{"type":"mediaSingle","content":[{"type":"media","attrs":{"type":"external","url":"https://example.com/a.png","width":10,"height":10}},"#
            + #"{"type":"caption","content":[\#(Self.link(cap, cap))]}]},"#
            + #"{"type":"paragraph","content":[{"type":"text","text":"plain"}]}"#
            + "]}"
        let blocks = DocumentPreparer(theme: .default).prepare(try await parseDoc(json))
        func key(_ url: String) throws -> SmartLinkKey { try #require(SmartLinkKey(url)) }

        #expect(blocks[0].smartLinkKeys == [try key(p)])
        #expect(blocks[1].smartLinkKeys == [try key(h)])
        guard case .listRows(let rows) = blocks[2].kind else { throw TestFailure("not a list") }
        #expect(rows.first?.smartLinkKeys == [try key(l)])
        #expect(blocks[2].smartLinkKeys.isEmpty)
        let cellBlocks = blocks.compactMap { block -> [RenderBlock]? in
            guard case .tableSlice(_, let rows, _) = block.kind else { return nil }
            return rows.flatMap { $0.cells.flatMap(\.blocks) }
        }.flatMap { $0 }
        #expect(cellBlocks.flatMap(\.smartLinkKeys) == [try key(c)])
        let media = blocks.compactMap { block -> PreparedMedia? in
            if case .media(let media) = block.kind { return media }
            return nil
        }.first
        #expect(media?.captionSmartLinkKeys == [try key(cap)])
        #expect(blocks.last?.smartLinkKeys == [])
    }

    @Test("public initialisers leave the keys empty, so host-built blocks never resolve")
    func publicInitsHaveNoKeys() {
        let block = RenderBlock(id: "x", kind: .divider)
        #expect(block.smartLinkKeys.isEmpty)
        let row = PreparedListRow(id: "r", depth: 0, marker: .bullet(depth: 0), segments: [], trailingBlocks: [])
        #expect(row.smartLinkKeys.isEmpty)
    }
}
