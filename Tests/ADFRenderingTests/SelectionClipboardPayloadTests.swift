import Foundation
import SwiftUI
import Testing
import ADFModel
import ADFPreparation
@testable import ADFRendering

@Suite("Selection rich clipboard")
struct SelectionClipboardPayloadTests {
    private func unit(
        id: String,
        text: String,
        metadata: ADFClipboardMetadata
    ) -> SearchTextUnit {
        SearchTextUnit(
            ownerID: id,
            topLevelBlockID: id,
            expandAncestorIDs: [],
            plainText: text,
            parts: [
                .init(
                    source: .textSegment(index: 0),
                    range: 0..<text.count
                )
            ],
            clipboard: metadata
        )
    }

    private func model(_ units: [SearchTextUnit]) -> SelectionTextModel {
        SelectionTextModel.build(orderedItems: units.enumerated().map { index, unit in
            SearchIndexedItem(
                id: "item-\(index)",
                topLevelBlockID: unit.topLevelBlockID,
                units: [unit]
            )
        })
    }

    private func payload(_ model: SelectionTextModel) throws -> ADFSelectionFragment {
        try #require(ADFSelectionFragment(
            model: model,
            range: 0..<model.totalUTF16Length,
            isVisible: { _ in true }
        ))
    }

    private func json(_ payload: ADFSelectionFragment) throws -> [String: Any] {
        try #require(
            try JSONSerialization.jsonObject(with: payload.adf) as? [String: Any]
        )
    }

    @Test func codeBlockPreservesLanguageAndLiteralNewlines() throws {
        let source = "let answer = 42\nprint(answer)"
        let attributed = AttributedString(source)
        let model = model([
            unit(
                id: "code",
                text: source,
                metadata: ADFClipboardMetadata(
                    block: .codeBlock(language: "swift"),
                    segments: [.text(attributed)],
                    containers: []
                )
            )
        ])

        let payload = try payload(model)
        let root = try json(payload)
        let content = try #require(root["content"] as? [[String: Any]])
        let code = try #require(content.first)
        let attrs = try #require(code["attrs"] as? [String: Any])
        let codeContent = try #require(code["content"] as? [[String: Any]])

        #expect(payload.plainText == source)
        #expect(code["type"] as? String == "codeBlock")
        #expect(attrs["language"] as? String == "swift")
        #expect(codeContent.first?["text"] as? String == source)

        let html = try #require(String(data: payload.html, encoding: .utf8))
        #expect(html.contains("<pre><code class=\"language-swift\">"))
        #expect(html.contains(source))
        #expect(!html.contains("<br>"))
    }

    @Test func consecutiveBlocksShareOnePanelAndKeepExactMarks() throws {
        var strong = AttributedString("Strong")
        strong[ADFSourceMarksAttribute.self] = [.strong]
        var emphasis = AttributedString("Emphasis")
        emphasis[ADFSourceMarksAttribute.self] = [.em]
        let style = TextBlockStyle(
            font: .body,
            isHeading: false,
            headingLevel: nil,
            alignment: nil,
            indentation: 0,
            breakout: nil
        )
        let panel: ADFClipboardMetadata.Container = .panel(
            id: "panel",
            type: .warning,
            colorHex: "#FFF7D6"
        )
        let model = model([
            unit(
                id: "paragraph-1",
                text: "Strong",
                metadata: ADFClipboardMetadata(
                    block: .richText(style),
                    segments: [.text(strong)],
                    containers: [panel]
                )
            ),
            unit(
                id: "paragraph-2",
                text: "Emphasis",
                metadata: ADFClipboardMetadata(
                    block: .richText(style),
                    segments: [.text(emphasis)],
                    containers: [panel]
                )
            ),
        ])

        let payload = try payload(model)
        let root = try json(payload)
        let content = try #require(root["content"] as? [[String: Any]])
        let copiedPanel = try #require(content.first)
        let paragraphs = try #require(copiedPanel["content"] as? [[String: Any]])
        let firstText = try #require(
            (paragraphs[0]["content"] as? [[String: Any]])?.first
        )
        let secondText = try #require(
            (paragraphs[1]["content"] as? [[String: Any]])?.first
        )

        #expect(content.count == 1)
        #expect(copiedPanel["type"] as? String == "panel")
        #expect(paragraphs.count == 2)
        #expect(
            ((firstText["marks"] as? [[String: Any]])?.first?["type"] as? String)
                == "strong"
        )
        #expect(
            ((secondText["marks"] as? [[String: Any]])?.first?["type"] as? String)
                == "em"
        )
    }

    @Test func partialSelectionCopiesOnlyTheSelectedCharacters() throws {
        let source = "prefix suffix"
        let attributed = AttributedString(source)
        let style = TextBlockStyle(
            font: .body,
            isHeading: false,
            headingLevel: nil,
            alignment: nil,
            indentation: 0,
            breakout: nil
        )
        let model = model([
            unit(
                id: "paragraph",
                text: source,
                metadata: ADFClipboardMetadata(
                    block: .richText(style),
                    segments: [.text(attributed)],
                    containers: []
                )
            )
        ])
        let payload = try #require(ADFSelectionFragment(
            model: model,
            range: 7..<13,
            isVisible: { _ in true }
        ))
        let root = try json(payload)
        let content = try #require(root["content"] as? [[String: Any]])
        let inline = try #require(
            (content.first?["content"] as? [[String: Any]])?.first
        )

        #expect(payload.plainText == "suffix")
        #expect(inline["text"] as? String == "suffix")
    }

    @Test @MainActor
    func selectionStateExposesTheSameOnDemandFragmentToHosts() throws {
        let source = "selected"
        let attributed = AttributedString(source)
        let model = model([
            unit(
                id: "paragraph",
                text: source,
                metadata: ADFClipboardMetadata(
                    block: .caption,
                    segments: [.text(attributed)],
                    containers: []
                )
            )
        ])
        let expected = try payload(model)
        let state = SelectionState()

        #expect(state.fragment == nil)
        state.setFragmentProvider { expected }
        #expect(state.fragment == expected)
    }
}
