import Foundation
import SwiftUI
import Testing
import ADFModel
import ADFPreparation
@testable import ADFRendering

private typealias SUI = AttributeScopes.SwiftUIAttributes
private typealias SmartLinkAttribute = AttributeScopes.ADFAttributes.SmartLinkAttribute

/// The shared stage → displayed-text function (design §5) and the spoken
/// text derived from it (§6): what both renderers draw and speak.
@Suite("Smart link display")
struct SmartLinkDisplayTests {
    private let theme = ADFTheme.default
    private static let url = "https://acme.atlassian.net/wiki/spaces/DOC/pages/1"
    private static let key = SmartLinkKey(url)!
    private static let page = ADFSmartLinkMetadata(title: "Q3 Roadmap", icon: .page)

    /// The prepared segments of one paragraph's inline JSON.
    private func prepared(_ content: String) async throws -> [InlineSegment] {
        let json = #"{"version":1,"type":"doc","content":[{"type":"paragraph","content":[\#(content)]}]}"#
        let doc = try await ADFParser().parse(Data(json.utf8))
        guard case .paragraph(let inline, _) = try #require(doc.root.children.first).kind else {
            throw TestFailure("not a paragraph")
        }
        return InlineComposer(theme: theme).composeOwner(inline).segments
    }

    private static func link(_ text: String, _ href: String = url) -> String {
        #"{"type":"text","text":"\#(text)","marks":[{"type":"link","attrs":{"href":"\#(href)"}}]}"#
    }

    private static func plain(_ text: String) -> String { #"{"type":"text","text":"\#(text)"}"# }

    /// "See <bare smart link> now".
    private func sentence() async throws -> [InlineSegment] {
        try await prepared(Self.plain("See ") + "," + Self.link(Self.url) + "," + Self.plain(" now"))
    }

    private static func onlyText(_ segments: [InlineSegment]) throws -> AttributedString {
        guard segments.count == 1, case .text(let text) = segments[0] else {
            throw TestFailure("expected one text segment, got \(segments.count)")
        }
        return text
    }

    private static func slice(_ text: AttributedString, _ characters: String) throws -> AttributedSubstring {
        guard let range = text.range(of: characters) else { throw TestFailure("no \(characters) in \(String(text.characters))") }
        return text[range]
    }

    @Test("plain and failed stages leave the segments untouched")
    func plainAndFailedAreIdentity() async throws {
        let segments = try await sentence()
        #expect(SmartLinkDisplay.apply([:], to: segments, theme: theme) == segments)
        #expect(SmartLinkDisplay.apply([Self.key: .plain], to: segments, theme: theme) == segments)
        #expect(SmartLinkDisplay.apply([Self.key: .failed(.notFound)], to: segments, theme: theme) == segments)
        #expect(SmartLinkStage.failed(.unauthorized).displayed == .plain)
        #expect(SmartLinkStage.resolving.displayed == .resolving)
    }

    @Test("resolving keeps the URL text and link, dimming only the link's colour")
    func resolvingDims() async throws {
        let segments = try await sentence()
        let text = try Self.onlyText(SmartLinkDisplay.apply([Self.key: .resolving], to: segments, theme: theme))
        #expect(String(text.characters) == "See \(Self.url) now")
        let link = try Self.slice(text, Self.url)
        #expect(link.runs.count == 1)
        let run = try #require(link.runs.first)
        #expect(run[SUI.ForegroundColorAttribute.self] == Color.accentColor.opacity(SmartLinkDisplay.resolvingOpacity))
        #expect(run.link == URL(string: Self.url))
        #expect(run[SmartLinkShownAttribute.self]?.kind == .resolving)
        let see = try Self.slice(text, "See ")
        #expect(see.runs.first?[SUI.ForegroundColorAttribute.self] == nil)
        #expect(see.runs.first?[SmartLinkShownAttribute.self] == nil)
    }

    @Test("resolved replaces the URL text with icon, no-break space and title, keeping the link")
    func resolvedSubstitutes() async throws {
        let segments = try await sentence()
        let text = try Self.onlyText(SmartLinkDisplay.apply([Self.key: .resolved(Self.page)], to: segments, theme: theme))
        #expect(String(text.characters) == "See \u{FFFC}\u{00A0}Q3 Roadmap now")
        let piece = try Self.slice(text, "\u{FFFC}\u{00A0}Q3 Roadmap")
        for run in piece.runs {
            #expect(run.link == URL(string: Self.url))
            #expect(run[SmartLinkShownAttribute.self]?.kind == .resolved(icon: .page, title: "Q3 Roadmap"))
            #expect(run[SmartLinkAttribute.self]?.key == Self.key)
        }
        let icon = try Self.slice(text, "\u{FFFC}")
        #expect(icon.runs.first?[SmartLinkIconAttribute.self] == .page)
        #expect(icon.runs.first?[SUI.UnderlineStyleAttribute.self] == nil)
        #expect(try Self.slice(text, "\u{00A0}").runs.first?[SUI.UnderlineStyleAttribute.self] == nil)
        let title = try Self.slice(text, "Q3 Roadmap")
        #expect(title.runs.first?[SUI.UnderlineStyleAttribute.self] == .single)
        #expect(title.runs.first?[SmartLinkIconAttribute.self] == nil)
        // Text around the link is untouched.
        #expect(try Self.slice(text, " now").runs.first?.link == nil)
    }

    @Test("every occurrence of a key is substituted; other keys keep their own stage")
    func multipleOccurrences() async throws {
        let other = "https://acme.atlassian.net/browse/ADF-7"
        let segments = try await prepared(
            Self.link(Self.url) + "," + Self.plain(" and ") + "," + Self.link(other, other) + "," + Self.plain(" and ") + "," + Self.link(Self.url)
        )
        let text = try Self.onlyText(SmartLinkDisplay.apply([Self.key: .resolved(Self.page)], to: segments, theme: theme))
        #expect(String(text.characters) == "\u{FFFC}\u{00A0}Q3 Roadmap and \(other) and \u{FFFC}\u{00A0}Q3 Roadmap")
        let occurrences = Set(text.runs[SmartLinkShownAttribute.self].compactMap { $0.0?.run.occurrence })
        #expect(occurrences.count == 2)
    }

    @Test("a search match inside the link highlights the whole title; the current match's style wins")
    func highlightInheritance() async throws {
        let segments = try await sentence()
        // Search paints first, on the prepared URL text: "atlassian" sits
        // inside the link at characters 12..<21 of "See https://acme.atlassian…".
        let start = 4 + "https://acme.".count
        let span = SearchHighlightSpan(segmentIndex: 0, range: start..<(start + "atlassian".count))
        let subtle = SearchHighlightPainter.paint(segments: segments, spans: [span], currentSpans: [], theme: theme, dimCurrent: false)
        let subtleText = try Self.onlyText(SmartLinkDisplay.apply([Self.key: .resolved(Self.page)], to: subtle, theme: theme))
        for run in try Self.slice(subtleText, "\u{FFFC}\u{00A0}Q3 Roadmap").runs {
            #expect(run[SUI.BackgroundColorAttribute.self] == theme.searchHighlight)
        }
        #expect(try Self.slice(subtleText, "See ").runs.first?[SUI.BackgroundColorAttribute.self] == nil)

        let current = SearchHighlightPainter.paint(segments: segments, spans: [span], currentSpans: [span], theme: theme, dimCurrent: false)
        let currentText = try Self.onlyText(SmartLinkDisplay.apply([Self.key: .resolved(Self.page)], to: current, theme: theme))
        for run in try Self.slice(currentText, "\u{FFFC}\u{00A0}Q3 Roadmap").runs {
            #expect(run[SUI.BackgroundColorAttribute.self] == theme.searchCurrentHighlight)
            #expect(run[SUI.ForegroundColorAttribute.self] == theme.searchCurrentForeground)
        }

        // While resolving, the painted range keeps its own highlight.
        let resolving = try Self.onlyText(SmartLinkDisplay.apply([Self.key: .resolving], to: subtle, theme: theme))
        #expect(try Self.slice(resolving, "atlassian").runs.first?[SUI.BackgroundColorAttribute.self] == theme.searchHighlight)
    }

    @Test("a match outside the link does not spread onto the title")
    func highlightOutsideLink() async throws {
        let segments = try await sentence()
        let span = SearchHighlightSpan(segmentIndex: 0, range: 0..<3)
        let painted = SearchHighlightPainter.paint(segments: segments, spans: [span], currentSpans: [], theme: theme, dimCurrent: false)
        let text = try Self.onlyText(SmartLinkDisplay.apply([Self.key: .resolved(Self.page)], to: painted, theme: theme))
        #expect(try Self.slice(text, "See").runs.first?[SUI.BackgroundColorAttribute.self] == theme.searchHighlight)
        #expect(try Self.slice(text, "Q3 Roadmap").runs.first?[SUI.BackgroundColorAttribute.self] == nil)
    }

    @Test("an empty title shows the prepared text after the icon")
    func emptyTitleFallsBack() async throws {
        let segments = try await sentence()
        let blank = ADFSmartLinkMetadata(title: " \n ", icon: .issue)
        let text = try Self.onlyText(SmartLinkDisplay.apply([Self.key: .resolved(blank)], to: segments, theme: theme))
        #expect(String(text.characters) == "See \u{FFFC}\u{00A0}\(Self.url) now")
        let multiline = ADFSmartLinkMetadata(title: "Line one\nline two", icon: .issue)
        let joined = try Self.onlyText(SmartLinkDisplay.apply([Self.key: .resolved(multiline)], to: segments, theme: theme))
        #expect(String(joined.characters) == "See \u{FFFC}\u{00A0}Line one line two now")
    }

    @Test("in a word-chunked (atom) paragraph the title is chunked again so it wraps")
    func atomParagraphRechunks() async throws {
        let segments = try await prepared(
            Self.plain("Ping ") + #",{"type":"mention","attrs":{"id":"1","text":"@sam"}},"# + Self.plain(" see ") + "," + Self.link(Self.url)
        )
        let long = ADFSmartLinkMetadata(title: "Q3 Roadmap planning notes", icon: .page)
        let displayed = SmartLinkDisplay.apply([Self.key: .resolved(long)], to: segments, theme: theme)
        let texts = displayed.compactMap { segment -> String? in
            if case .text(let text) = segment { return String(text.characters) }
            return nil
        }
        #expect(texts.joined().contains("\u{FFFC}\u{00A0}Q3 Roadmap planning notes"))
        // More than one chunk carries the title.
        let titleChunks = displayed.filter { segment in
            guard case .text(let text) = segment else { return false }
            return text.runs[SmartLinkShownAttribute.self].contains { $0.0 != nil }
        }
        #expect(titleChunks.count > 1)
        // The atom survives in place.
        #expect(displayed.contains { if case .atom = $0 { return true } else { return false } })
    }

    // MARK: Spoken text and actions

    @Test("spoken text: resolving says it is loading, resolved speaks kind then title, never the symbol")
    func spokenText() {
        #expect(SmartLinkDisplay.spokenText(.resolving, visibleText: Self.url) == "\(Self.url), loading title")
        #expect(SmartLinkDisplay.spokenText(.resolved(icon: .page, title: "Q3 Roadmap"),
                                            visibleText: "\u{FFFC}\u{00A0}Q3 Roadmap") == "Page, Q3 Roadmap")
        #expect(SmartLinkDisplay.spokenText(.resolved(icon: .blogPost, title: "News"), visibleText: "News") == "Blog post, News")
        #expect(SmartLinkDisplay.spokenText(.resolved(icon: .issue, title: "ADF-7"), visibleText: "ADF-7") == "Issue, ADF-7")
        #expect(SmartLinkDisplay.spokenText(.resolved(icon: .generic, title: "x"), visibleText: "x") == "Link, x")
    }

    @Test("the row's spoken text replaces each displayed smart link and keeps the rest")
    func accessibilityText() async throws {
        let segments = try await sentence()
        let resolved = try Self.onlyText(SmartLinkDisplay.apply([Self.key: .resolved(Self.page)], to: segments, theme: theme))
        #expect(SmartLinkDisplay.accessibilityText(of: resolved) == "See Page, Q3 Roadmap now")
        let resolving = try Self.onlyText(SmartLinkDisplay.apply([Self.key: .resolving], to: segments, theme: theme))
        #expect(SmartLinkDisplay.accessibilityText(of: resolving) == "See \(Self.url), loading title now")
        let plain = try Self.onlyText(segments)
        #expect(SmartLinkDisplay.accessibilityText(of: plain) == "See \(Self.url) now")
    }

    @Test("link action names use the resolved title, else the host")
    func actionNames() throws {
        let url = try #require(URL(string: Self.url))
        #expect(SmartLinkDisplay.linkActionName(url) == "Open link acme.atlassian.net")
        #expect(SmartLinkDisplay.linkActionName(url, title: "Q3 Roadmap") == "Open link Q3 Roadmap")
    }

    @Test("each kind has a symbol and a spoken name")
    func kinds() {
        let kinds: [ADFSmartLinkMetadata.Icon] = [.page, .blogPost, .issue, .generic]
        #expect(kinds.map(SmartLinkDisplay.symbolName) == ["doc.text", "quote.bubble", "checkmark.square", "link"])
        #expect(kinds.map(SmartLinkDisplay.spokenName) == ["Page", "Blog post", "Issue", "Link"])
        #expect(ADFSmartLinkMetadata(title: "t").icon == .page)
    }
}
