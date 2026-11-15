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

    public init(theme: ADFTheme, customPreparers: [any ADFCustomBlockPreparer] = []) {
        self.theme = theme
        self.customPreparers = customPreparers
    }

    /// Units for a batch of TOP-LEVEL blocks, in document order.
    public func units(for blocks: [RenderBlock]) -> [SearchTextUnit] {
        var result: [SearchTextUnit] = []
        for block in blocks {
            collect(
                block,
                topLevelBlockID: block.id,
                expandAncestorIDs: [],
                clipboardContainers: [],
                into: &result
            )
        }
        return result
    }

    private func collect(
        _ block: RenderBlock,
        topLevelBlockID: String,
        expandAncestorIDs: [String],
        clipboardContainers: [ADFClipboardMetadata.Container],
        into result: inout [SearchTextUnit]
    ) {
        switch block.kind {
        case .richText(let segments, let style):
            appendUnit(ownerID: block.id, segments: segments,
                       clipboardBlock: .richText(style),
                       clipboardContainers: clipboardContainers,
                       topLevelBlockID: topLevelBlockID,
                       expandAncestorIDs: expandAncestorIDs, into: &result)
        case .codeBlock(let language, let code):
            let segments: [InlineSegment] = [.text(code)]
            appendUnit(ownerID: block.id, segments: segments,
                       clipboardBlock: .codeBlock(language: language),
                       clipboardContainers: clipboardContainers,
                       topLevelBlockID: topLevelBlockID,
                       expandAncestorIDs: expandAncestorIDs, into: &result)
        case .listRows(let rows):
            for row in rows {
                appendUnit(ownerID: row.id, segments: row.segments,
                           clipboardBlock: .listRow(marker: row.marker, depth: row.depth),
                           clipboardContainers: clipboardContainers,
                           topLevelBlockID: topLevelBlockID,
                           expandAncestorIDs: expandAncestorIDs, into: &result)
                for trailing in row.trailingBlocks {
                    collect(trailing, topLevelBlockID: topLevelBlockID,
                            expandAncestorIDs: expandAncestorIDs,
                            clipboardContainers: clipboardContainers,
                            into: &result)
                }
            }
        case .media(let media):
            appendCaption(media, topLevelBlockID: topLevelBlockID,
                          expandAncestorIDs: expandAncestorIDs,
                          clipboardContainers: clipboardContainers,
                          into: &result)
        case .mediaStrip(let items):
            for media in items {
                appendCaption(media, topLevelBlockID: topLevelBlockID,
                              expandAncestorIDs: expandAncestorIDs,
                              clipboardContainers: clipboardContainers,
                              into: &result)
            }
        case .panel(let palette, let children):
            let containers = clipboardContainers + [
                .panel(
                    id: block.id,
                    type: palette.panelType,
                    colorHex: palette.colorHex
                )
            ]
            for child in children {
                collect(child, topLevelBlockID: topLevelBlockID,
                        expandAncestorIDs: expandAncestorIDs,
                        clipboardContainers: containers,
                        into: &result)
            }
        case .quote(let children):
            let containers = clipboardContainers + [.quote(id: block.id)]
            for child in children {
                collect(child, topLevelBlockID: topLevelBlockID,
                        expandAncestorIDs: expandAncestorIDs,
                        clipboardContainers: containers,
                        into: &result)
            }
        case .extensionPlaceholder(let title, let body):
            let containers = clipboardContainers + [
                .extensionContainer(id: block.id, title: title)
            ]
            for child in body {
                collect(child, topLevelBlockID: topLevelBlockID,
                        expandAncestorIDs: expandAncestorIDs,
                        clipboardContainers: containers,
                        into: &result)
            }
        case .layoutColumns(let columns):
            let sectionContainers = clipboardContainers + [.layoutSection(id: block.id)]
            for column in columns {
                let containers = sectionContainers + [
                    .layoutColumn(id: column.id, widthPercent: column.widthPercent)
                ]
                for child in column.blocks {
                    collect(child, topLevelBlockID: topLevelBlockID,
                            expandAncestorIDs: expandAncestorIDs,
                            clipboardContainers: containers,
                            into: &result)
                }
            }
        case .tableSlice(let layout, let rows, _):
            let tableID = String(block.id.prefix(while: { $0 != "#" }))
            let tableContainers = clipboardContainers + [
                .table(id: tableID, hasNumberColumn: layout.hasNumberColumn)
            ]
            for row in rows {
                let rowContainers = tableContainers + [.tableRow(id: row.id)]
                for cell in row.cells {
                    let containers = rowContainers + [
                        .tableCell(
                            id: cell.id,
                            colspan: cell.colspan,
                            rowspan: cell.rowspan,
                            backgroundHex: cell.backgroundHex,
                            valign: cell.valign,
                            isHeader: cell.isHeader
                        )
                    ]
                    for child in cell.blocks {
                        collect(child, topLevelBlockID: topLevelBlockID,
                                expandAncestorIDs: expandAncestorIDs,
                                clipboardContainers: containers,
                                into: &result)
                    }
                }
            }
        case .expand(let title, let bodyNodes, let isNested):
            // Prepare the body EXACTLY as ExpandBlockView does on first
            // expansion (same synthetic wrapper, same theme), so inner block
            // IDs and segment shapes match what the expanded view renders.
            let root = ADFNode(id: "expand", type: "doc", kind: .doc(bodyNodes))
            let document = ADFDocument(version: 1, root: root, issues: [])
            let bodyBlocks = DocumentPreparer(theme: theme, customPreparers: customPreparers)
                .prepare(document)
            let chain = expandAncestorIDs + [block.id]
            let containers = clipboardContainers + [
                .expand(id: block.id, title: title, isNested: isNested)
            ]
            for child in bodyBlocks {
                collect(child, topLevelBlockID: topLevelBlockID,
                        expandAncestorIDs: chain,
                        clipboardContainers: containers,
                        into: &result)
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
        clipboardContainers: [ADFClipboardMetadata.Container],
        into result: inout [SearchTextUnit]
    ) {
        guard let caption = media.caption else { return }
        appendUnit(ownerID: media.id, segments: caption,
                   clipboardBlock: .caption,
                   clipboardContainers: clipboardContainers,
                   topLevelBlockID: topLevelBlockID,
                   expandAncestorIDs: expandAncestorIDs, into: &result)
    }

    /// Builds one unit from a composed segment array; skips whitespace-only
    /// content so empty paragraphs never dilute the corpus.
    private func appendUnit(
        ownerID: String,
        segments: [InlineSegment],
        clipboardBlock: ADFClipboardMetadata.Block,
        clipboardContainers: [ADFClipboardMetadata.Container],
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
            parts: parts,
            clipboard: ADFClipboardMetadata(
                block: clipboardBlock,
                segments: segments,
                containers: clipboardContainers
            )
        ))
    }
}
