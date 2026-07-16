import Foundation
import SwiftUI
import Testing
import ADFModel
import ADFPreparation
@testable import ADFRendering

private typealias SUI = AttributeScopes.SwiftUIAttributes

@Suite("SearchHighlightPainter")
struct SearchHighlightPainterTests {
    private let theme = ADFTheme.default

    private func backgrounds(of text: AttributedString) -> [(String, Color?)] {
        text.runs.map { run in
            (String(text[run.range].characters), run[SUI.BackgroundColorAttribute.self])
        }
    }

    @Test("no spans returns the identical segments — zero-work fast path")
    func noSpansIsIdentity() {
        let segments: [InlineSegment] = [.text(AttributedString("hello world"))]
        let painted = SearchHighlightPainter.paint(
            segments: segments, spans: [], currentSpans: [], theme: theme, dimCurrent: false
        )
        #expect(painted == segments)
    }

    @Test("a span paints the subtle background over exactly its range")
    func subtleSpanPaints() throws {
        let segments: [InlineSegment] = [.text(AttributedString("hello world"))]
        let painted = SearchHighlightPainter.paint(
            segments: segments,
            spans: [SearchHighlightSpan(segmentIndex: 0, range: 6..<11)],
            currentSpans: [], theme: theme, dimCurrent: false
        )
        guard case .text(let text) = painted[0] else { throw TestFailure("expected text") }
        let runs = backgrounds(of: text)
        #expect(runs.contains { $0.0 == "world" && $0.1 == theme.searchHighlight })
        #expect(runs.contains { $0.0 == "hello " && $0.1 == nil })
    }

    @Test("current spans win over subtle spans and set the contrast foreground")
    func currentSpanWins() throws {
        let segments: [InlineSegment] = [.text(AttributedString("aaaa"))]
        let painted = SearchHighlightPainter.paint(
            segments: segments,
            spans: [SearchHighlightSpan(segmentIndex: 0, range: 0..<4)],
            currentSpans: [SearchHighlightSpan(segmentIndex: 0, range: 0..<2)],
            theme: theme, dimCurrent: false
        )
        guard case .text(let text) = painted[0] else { throw TestFailure("expected text") }
        let runs = backgrounds(of: text)
        #expect(runs.contains { $0.0 == "aa" && $0.1 == theme.searchCurrentHighlight })
        let currentRun = try #require(text.runs.first)
        #expect(currentRun[SUI.ForegroundColorAttribute.self] == theme.searchCurrentForeground)
    }

    @Test("dimCurrent paints the current span with the subtle color (flash off-phase)")
    func dimmedCurrentUsesSubtle() throws {
        let segments: [InlineSegment] = [.text(AttributedString("abcd"))]
        let painted = SearchHighlightPainter.paint(
            segments: segments, spans: [],
            currentSpans: [SearchHighlightSpan(segmentIndex: 0, range: 0..<4)],
            theme: theme, dimCurrent: true
        )
        guard case .text(let text) = painted[0] else { throw TestFailure("expected text") }
        #expect(backgrounds(of: text).contains { $0.0 == "abcd" && $0.1 == theme.searchHighlight })
    }

    @Test("out-of-bounds ranges clamp instead of trapping")
    func rangesClamp() throws {
        let segments: [InlineSegment] = [.text(AttributedString("ab"))]
        let painted = SearchHighlightPainter.paint(
            segments: segments,
            spans: [SearchHighlightSpan(segmentIndex: 0, range: 1..<99),
                    SearchHighlightSpan(segmentIndex: 5, range: 0..<1)],
            currentSpans: [], theme: theme, dimCurrent: false
        )
        guard case .text(let text) = painted[0] else { throw TestFailure("expected text") }
        #expect(backgrounds(of: text).contains { $0.0 == "b" && $0.1 == theme.searchHighlight })
    }

    @Test("atom segments are left untouched by text spans")
    func atomSegmentsUntouched() {
        let segments: [InlineSegment] = [
            .atom(.mention(text: "@bob"), id: "n1"),
            .text(AttributedString("hi")),
        ]
        let painted = SearchHighlightPainter.paint(
            segments: segments,
            spans: [SearchHighlightSpan(segmentIndex: 0, range: 0..<2)],
            currentSpans: [], theme: theme, dimCurrent: false
        )
        #expect(painted[0] == segments[0])
    }

    @Test("many edits use the forward offset path and paint every range")
    func manyEditsPaintEveryRange() {
        let text = AttributedString("a0a1a2a3a4a5")
        let spans = stride(from: 0, through: 10, by: 2).map {
            SearchHighlightSpan(segmentIndex: 0, range: $0..<($0 + 1))
        }
        let painted = SearchHighlightPainter.paint(
            text: text,
            spans: spans,
            currentSpans: [],
            theme: theme,
            dimCurrent: false
        )
        let highlighted = backgrounds(of: painted).filter {
            $0.0 == "a" && $0.1 == theme.searchHighlight
        }
        #expect(highlighted.count == 6)
    }
}

struct TestFailure: Error { let message: String; init(_ message: String) { self.message = message } }
