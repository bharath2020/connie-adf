import Foundation
import Testing
import ADFModel
import ADFPreparation

/// Parses an ADF JSON string into a document.
func parseDoc(_ json: String) async throws -> ADFDocument {
    try await ADFParser().parse(Data(json.utf8))
}

/// Parses a bracketed inline-node JSON array (e.g. `[{"type":"text",...}]`)
/// by wrapping it in a minimal doc/paragraph shell and returning the
/// paragraph's children. Mirrors `InlineComposerTests.inlineContent(of:)`.
func inlineNodes(json: String) async throws -> [ADFNode] {
    let doc = try await parseDoc("""
    {"type":"doc","version":1,"content":[{"type":"paragraph","content":\(json)}]}
    """)
    let first = try #require(doc.root.children.first)
    guard case .paragraph(let content, _) = first.kind else {
        throw TestFailure("first block is not a paragraph")
    }
    return content
}

/// Recursively collects every `RenderBlock.Kind` in a prepared block tree,
/// descending into panels, quotes, table cells, list trailing blocks,
/// layout columns, and extension bodies.
func collectKinds(_ blocks: [RenderBlock]) -> [RenderBlock.Kind] {
    var kinds: [RenderBlock.Kind] = []
    var stack = blocks
    while let block = stack.popLast() {
        kinds.append(block.kind)
        switch block.kind {
        case .panel(_, let children), .quote(let children), .extensionPlaceholder(_, let children):
            stack.append(contentsOf: children)
        case .tableSlice(_, let rows, _):
            stack.append(contentsOf: rows.flatMap { $0.cells.flatMap(\.blocks) })
        case .listRows(let rows):
            stack.append(contentsOf: rows.flatMap(\.trailingBlocks))
        case .layoutColumns(let columns):
            stack.append(contentsOf: columns.flatMap(\.blocks))
        case .richText, .codeBlock, .divider, .media, .mediaStrip, .expand, .card, .custom,
             .unknown:
            break
        }
    }
    return kinds
}

/// True when any collected kind is `.unknown`.
func containsUnknown(_ kinds: [RenderBlock.Kind]) -> Bool {
    kinds.contains { kind in
        if case .unknown = kind { return true }
        return false
    }
}
