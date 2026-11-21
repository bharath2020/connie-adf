import Foundation
import ADFModel

/// Walks prepared blocks into `SearchTextUnit`s. Pure and `Sendable`: safe to
/// run on any executor (`ADFDocumentSearch` runs it detached, off-main).
/// The theme matters only for expand bodies, which are prepared on demand
/// with the SAME preparer configuration the view uses, so segment shapes and
/// IDs align exactly (Task 3).
public struct SearchIndexer: Sendable {
    public let theme: ADFTheme
    /// Must match the preparer configuration the document was prepared with:
    /// expand bodies are re-prepared here for indexing, and a plugin claim
    /// that fires at render time but not at index time (or vice versa)
    /// desynchronizes block IDs from the corpus.
    public let customPreparers: [any ADFCustomBlockPreparer]
    /// Must match the document's preparer too, for the same reason: whether
    /// inline cards were prepared as smart-link runs or chips
    /// (`DocumentPreparer.init(theme:customPreparers:inlineCardsAsSmartLinks:)`).
    package let inlineCardsAsSmartLinks: Bool

    public init(theme: ADFTheme, customPreparers: [any ADFCustomBlockPreparer] = []) {
        self.init(theme: theme, customPreparers: customPreparers, inlineCardsAsSmartLinks: false)
    }

    package init(theme: ADFTheme, customPreparers: [any ADFCustomBlockPreparer] = [], inlineCardsAsSmartLinks: Bool) {
        self.theme = theme
        self.customPreparers = customPreparers
        self.inlineCardsAsSmartLinks = inlineCardsAsSmartLinks
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
        case .panel(_, let children):
            for child in children {
                collect(child, topLevelBlockID: topLevelBlockID,
                        expandAncestorIDs: expandAncestorIDs, into: &result)
            }
        case .quote(let children):
            for child in children {
                collect(child, topLevelBlockID: topLevelBlockID,
                        expandAncestorIDs: expandAncestorIDs, into: &result)
            }
        case .extensionPlaceholder(_, let body):
            for child in body {
                collect(child, topLevelBlockID: topLevelBlockID,
                        expandAncestorIDs: expandAncestorIDs, into: &result)
            }
        case .layoutColumns(let columns):
            for column in columns {
                for child in column.blocks {
                    collect(child, topLevelBlockID: topLevelBlockID,
                            expandAncestorIDs: expandAncestorIDs, into: &result)
                }
            }
        case .tableSlice(_, let rows, _):
            for row in rows {
                for cell in row.cells {
                    for child in cell.blocks {
                        collect(child, topLevelBlockID: topLevelBlockID,
                                expandAncestorIDs: expandAncestorIDs, into: &result)
                    }
                }
            }
        case .expand(_, let bodyNodes, _):
            // Prepare the body EXACTLY as ExpandBlockView does on first
            // expansion (same synthetic wrapper, same theme), so inner block
            // IDs and segment shapes match what the expanded view renders.
            let root = ADFNode(id: "expand", type: "doc", kind: .doc(bodyNodes))
            let document = ADFDocument(version: 1, root: root, issues: [])
            let bodyBlocks = DocumentPreparer(
                theme: theme, customPreparers: customPreparers, inlineCardsAsSmartLinks: inlineCardsAsSmartLinks
            )
                .prepare(document)
            let chain = expandAncestorIDs + [block.id]
            for child in bodyBlocks {
                collect(child, topLevelBlockID: topLevelBlockID,
                        expandAncestorIDs: chain, into: &result)
            }
        case .custom(let custom):
            appendCustomUnit(custom, ownerID: block.id,
                             topLevelBlockID: topLevelBlockID,
                             expandAncestorIDs: expandAncestorIDs, into: &result)
        case .divider, .card, .unknown:
            break // No range-highlightable text (see Global Constraints).
        }
    }

    /// A custom block's searchable text as one whole-block unit. The single
    /// part is an ATOM covering the entire text, so matches surface through
    /// the whole-view tint path (like mention pills) rather than range
    /// painting — a plugin view may render its text truncated or not at all,
    /// so character ranges could not be trusted to land anywhere visible.
    private func appendCustomUnit(
        _ custom: ADFCustomBlock,
        ownerID: String,
        topLevelBlockID: String,
        expandAncestorIDs: [String],
        into result: inout [SearchTextUnit]
    ) {
        guard let text = custom.searchableText,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        result.append(SearchTextUnit(
            ownerID: ownerID,
            topLevelBlockID: topLevelBlockID,
            expandAncestorIDs: expandAncestorIDs,
            plainText: text,
            parts: [.init(source: .atom(id: ownerID), range: 0..<text.count)]
        ))
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
                if Self.holdsEmoji(text) {
                    appendEmojiParts(text, segmentIndex: index, plain: &plain, offset: &offset, parts: &parts)
                    continue
                }
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

    private typealias EmojiAttribute = AttributeScopes.ADFAttributes.EmojiAttribute

    /// Whether a text segment holds a custom emoji (one U+FFFC carrying
    /// `adfEmoji`).
    private static func holdsEmoji(_ text: AttributedString) -> Bool {
        text.runs[EmojiAttribute.self].contains { $0.0 != nil }
    }

    /// A text segment with custom emoji: each emoji is spelled by its short
    /// name in the plain text (so it is found by name, as before it was a
    /// text run) with a part standing for its one segment character; the
    /// text around it maps Character for Character from its place in the
    /// segment.
    private func appendEmojiParts(
        _ text: AttributedString, segmentIndex: Int,
        plain: inout String, offset: inout Int, parts: inout [SearchTextUnit.Part]
    ) {
        var segmentOffset = 0
        for (key, range) in text.runs[EmojiAttribute.self] {
            let characters = text[range].characters
            guard let key else {
                let contribution = String(characters)
                let length = contribution.count
                guard length > 0 else { continue }
                parts.append(.init(
                    source: .textSegment(index: segmentIndex), range: offset..<(offset + length),
                    segmentOffset: segmentOffset
                ))
                plain += contribution
                offset += length
                segmentOffset += length
                continue
            }
            // Adjacent emoji with the same key share one run.
            for _ in characters {
                let length = key.shortName.count
                if length > 0 {
                    parts.append(.init(
                        source: .textSegment(index: segmentIndex), range: offset..<(offset + length),
                        segmentOffset: segmentOffset, segmentLength: 1
                    ))
                    plain += key.shortName
                    offset += length
                }
                segmentOffset += 1
            }
        }
    }
}
