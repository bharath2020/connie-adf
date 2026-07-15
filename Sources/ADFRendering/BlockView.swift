import SwiftUI
import ADFPreparation

/// One concrete row view that switches on `RenderBlock.Kind` — no `AnyView`,
/// so SwiftUI resolves a conditional structural type and per-case identity
/// stays stable across updates.
struct BlockView: View {
    let block: RenderBlock

    var body: some View {
        switch block.kind {
        case .richText(let segments, let style):
            RichTextBlockView(segments: segments, style: style, ownerID: block.id)
        case .codeBlock(let language, let code):
            CodeBlockView(language: language, code: code, ownerID: block.id)
        case .panel(let palette, let blocks):
            PanelBlockView(palette: palette, blocks: blocks)
        case .quote(let blocks):
            QuoteBlockView(blocks: blocks)
        case .divider:
            Divider()
        case .unknown(let typeName):
            UnknownBlockView(typeName: typeName)

        case .listRows(let rows):
            ListBlockView(rows: rows)
        case .tableSlice(let layout, let rows, let isHeaderSlice):
            // Slices of one table share a table-ID prefix ("<tableID>#…"), the
            // key their horizontal offset syncs on.
            TableSliceView(
                tableID: String(block.id.prefix { $0 != "#" }),
                layout: layout,
                rows: rows,
                isHeaderSlice: isHeaderSlice
            )
        case .media(let media):
            MediaBlockView(media: media)
        case .mediaStrip(let items):
            MediaStripView(items: items)
        case .expand(let title, let bodyNodes, let isNested):
            ExpandBlockView(id: block.id, title: title, bodyNodes: bodyNodes, isNested: isNested)
        case .layoutColumns(let columns):
            LayoutColumnsView(columns: columns)
        case .card(let url, let title, let isEmbed):
            CardBlockView(url: url, title: title, isEmbed: isEmbed)
        case .extensionPlaceholder(let title, let body):
            ExtensionPlaceholderBlockView(title: title, blocks: body)
        }
    }
}

extension RenderBlock.Kind {
    /// Vertical padding applied by the document container (the lazy stack
    /// itself uses spacing 0 so each kind controls its own rhythm).
    var defaultVerticalPadding: CGFloat {
        switch self {
        case .richText(_, let style):
            return style.isHeading ? 10 : 4
        case .listRows:
            return 4
        case .unknown:
            return 6
        case .divider:
            return 8
        case .tableSlice:
            // Slices of one table must abut seamlessly (a batched table is
            // one visual unit), so slices carry no vertical padding.
            return 0
        case .codeBlock, .panel, .quote, .media, .mediaStrip,
             .expand, .layoutColumns, .card, .extensionPlaceholder:
            return 8
        }
    }
}
