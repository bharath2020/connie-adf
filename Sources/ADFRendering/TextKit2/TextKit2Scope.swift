import ADFPreparation

/// Where the host's text engine choice applies. `DocumentRow` passes it to
/// top-level paragraphs and headings (`.richText`) and top-level lists
/// (`.listRows`); a list row passes it to its leader and to its direct
/// `.richText` and `.listRows` trailing blocks only (`ListRowView`). Every
/// other kind (panel, quote, table, code, media, expand, layout columns,
/// card, extension, plugin, unknown) gets `.swiftUI` at that boundary, and
/// so does everything inside it, lists and paragraphs included. Those two
/// views are the only places that set `adfTextRenderer`. The coverage walk
/// (`forEachLeaf`) follows the same rule, so the diagnostics count exactly
/// the leaves the views may hand to TextKit 2.
enum TextKit2Scope {
    /// Whether a block in a scoped position keeps the renderer choice
    /// (`.richText`, `.listRows`) rather than resetting it to `.swiftUI`.
    static func inheritsRenderer(_ kind: RenderBlock.Kind) -> Bool {
        switch kind {
        case .richText, .listRows: return true
        default: return false
        }
    }

    /// Where a text leaf sits in the scope.
    enum Position: Sendable, Hashable {
        /// A top-level paragraph or heading.
        case root
        /// A list row's leading paragraph, owned by `PreparedListRow.id`.
        case listLeader
        /// A paragraph or heading among a list row's trailing blocks, owned
        /// by its own `RenderBlock.id`.
        case listTrailing
    }

    /// One text-bearing leaf in the scope: what a `TextEngineLeaf` draws.
    struct Leaf {
        let ownerID: String
        let segments: [InlineSegment]
        /// The block's style; `nil` for a leader, which the list row styles
        /// as body text (`ListRowView.leaderStyle(theme:)`).
        let style: TextBlockStyle?
        let position: Position
    }

    /// Visits every text leaf of the document's top-level blocks in the
    /// scope, in prepared (depth-first) order. A row with empty segments
    /// has no leader view, so it is not a leaf.
    static func forEachLeaf(in blocks: [RenderBlock], _ visit: (Leaf) -> Void) {
        for block in blocks {
            switch block.kind {
            case .richText(let segments, let style):
                visit(Leaf(ownerID: block.id, segments: segments, style: style, position: .root))
            case .listRows(let rows):
                forEachLeaf(inList: rows, visit)
            default:
                continue
            }
        }
    }

    private static func forEachLeaf(inList rows: [PreparedListRow], _ visit: (Leaf) -> Void) {
        for row in rows {
            if !row.segments.isEmpty {
                visit(Leaf(ownerID: row.id, segments: row.segments, style: nil, position: .listLeader))
            }
            for block in row.trailingBlocks {
                switch block.kind {
                case .richText(let segments, let style):
                    visit(Leaf(ownerID: block.id, segments: segments, style: style, position: .listTrailing))
                case .listRows(let nested):
                    forEachLeaf(inList: nested, visit)
                default:
                    continue
                }
            }
        }
    }
}
