import Foundation
import ADFModel

/// Walks prepared blocks into `SearchTextUnit`s. Pure and `Sendable`: safe to
/// run on any executor (`ADFDocumentSearch` runs it detached, off-main).
/// The theme matters only for expand bodies, which are prepared on demand
/// with the SAME preparer configuration the view uses, so segment shapes and
/// IDs align exactly (Task 3).
public struct SearchIndexer: Sendable {
    public let theme: ADFTheme

    public init(theme: ADFTheme) {
        self.theme = theme
    }

    /// Units for a batch of TOP-LEVEL blocks, in document order.
    public func units(for blocks: [RenderBlock]) -> [SearchTextUnit] {
        var result: [SearchTextUnit] = []
        for block in blocks {
            collect(block, topLevelBlockID: block.id, expandAncestorIDs: [], into: &result)
        }
        return result
    }

    private func collect(
        _ block: RenderBlock,
        topLevelBlockID: String,
        expandAncestorIDs: [String],
        into result: inout [SearchTextUnit]
    ) {
        switch block.kind {
        case .richText(let segments, _):
            appendUnit(ownerID: block.id, segments: segments,
                       topLevelBlockID: topLevelBlockID,
                       expandAncestorIDs: expandAncestorIDs, into: &result)
        case .codeBlock(_, let code):
            appendUnit(ownerID: block.id, segments: [.text(code)],
                       topLevelBlockID: topLevelBlockID,
                       expandAncestorIDs: expandAncestorIDs, into: &result)
        case .listRows(let rows):
            for row in rows {
                appendUnit(ownerID: row.id, segments: row.segments,
                           topLevelBlockID: topLevelBlockID,
                           expandAncestorIDs: expandAncestorIDs, into: &result)
                for trailing in row.trailingBlocks {
                    collect(trailing, topLevelBlockID: topLevelBlockID,
                            expandAncestorIDs: expandAncestorIDs, into: &result)
                }
            }
        case .media(let media):
            appendCaption(media, topLevelBlockID: topLevelBlockID,
                          expandAncestorIDs: expandAncestorIDs, into: &result)
        case .mediaStrip(let items):
            for media in items {
                appendCaption(media, topLevelBlockID: topLevelBlockID,
                              expandAncestorIDs: expandAncestorIDs, into: &result)
            }
        case .panel, .quote, .tableSlice, .layoutColumns, .extensionPlaceholder:
            break // Container recursion lands in Task 2.
        case .expand:
            break // Expand bodies land in Task 3.
        case .divider, .card, .unknown:
            break // No range-highlightable text (see Global Constraints).
        }
    }

    private func appendCaption(
        _ media: PreparedMedia,
        topLevelBlockID: String,
        expandAncestorIDs: [String],
        into result: inout [SearchTextUnit]
    ) {
        guard let caption = media.caption else { return }
        appendUnit(ownerID: media.id, segments: caption,
                   topLevelBlockID: topLevelBlockID,
                   expandAncestorIDs: expandAncestorIDs, into: &result)
    }

    /// Builds one unit from a composed segment array; skips whitespace-only
    /// content so empty paragraphs never dilute the corpus.
    private func appendUnit(
        ownerID: String,
        segments: [InlineSegment],
        topLevelBlockID: String,
        expandAncestorIDs: [String],
        into result: inout [SearchTextUnit]
    ) {
        var plain = ""
        var offset = 0
        var parts: [SearchTextUnit.Part] = []
        for (index, segment) in segments.enumerated() {
            let contribution: String
            let source: SearchTextUnit.Part.Source
            switch segment {
            case .text(let text):
                contribution = String(text.characters)
                source = .textSegment(index: index)
            case .atom(let atom, let id):
                contribution = InlineComposer.fallbackText(atom)
                source = .atom(id: id)
            }
            guard !contribution.isEmpty else { continue }
            let length = contribution.count
            parts.append(.init(source: source, range: offset..<(offset + length)))
            plain += contribution
            offset += length
        }
        guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        result.append(SearchTextUnit(
            ownerID: ownerID,
            topLevelBlockID: topLevelBlockID,
            expandAncestorIDs: expandAncestorIDs,
            plainText: plain,
            parts: parts
        ))
    }
}
