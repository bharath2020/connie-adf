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
            RichTextBlockView(segments: segments, style: style)
        case .codeBlock(let language, let code):
            CodeBlockView(language: language, code: code)
        case .panel(let palette, let blocks):
            PanelBlockView(palette: palette, blocks: blocks)
        case .quote(let blocks):
            QuoteBlockView(blocks: blocks)
        case .divider:
            Divider()
        case .unknown(let typeName):
            UnknownBlockView(typeName: typeName)

        // MARK: Task 5 kinds — temporary stubs (see Blocks/Task5Stubs.swift)
        case .listRows(let rows):
            Task5StubView(label: "List · \(rows.count) row(s)")
        case .tableSlice(_, let rows, let isHeaderSlice):
            Task5StubView(label: isHeaderSlice ? "Table header" : "Table · \(rows.count) row(s)")
        case .media:
            Task5StubView(label: "Media")
        case .mediaStrip(let items):
            Task5StubView(label: "Media strip · \(items.count) item(s)")
        case .expand(let title, _, _):
            Task5StubView(label: "Expand · \(title.isEmpty ? "untitled" : title)")
        case .layoutColumns(let columns):
            Task5StubView(label: "Layout · \(columns.count) column(s)")
        case .card(let url, _, _):
            Task5StubView(label: "Card · \(url ?? "no URL")")
        case .extensionPlaceholder(let title, _):
            Task5StubView(label: "Extension · \(title)")
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
        case .codeBlock, .panel, .quote, .tableSlice, .media, .mediaStrip,
             .expand, .layoutColumns, .card, .extensionPlaceholder:
            return 8
        }
    }
}
