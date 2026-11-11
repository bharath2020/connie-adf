import SwiftUI
import ADFPreparation

/// Where the host's text engine choice applies. `DocumentRow` passes it to
/// top-level paragraphs and headings (`.richText`) and top-level lists
/// (`.listRows`) whose rows hold only text (`listKeepsRenderer`). A list
/// row passes it to its text when its text column holds one block, its
/// leader or a single paragraph or heading (`rowKeepsRenderer`,
/// `ListRowView`), laid out left to right (`listDirectionKeepsRenderer`);
/// any other row draws all its text on SwiftUI. Before iOS 26 the leaf
/// itself keeps list text on SwiftUI (`TextKit2Eligibility.listsMatchText`,
/// a `.osGatedList` fallback the coverage counts). Every other top-level kind
/// (panel, quote, table, code, media, expand, layout columns, card,
/// extension, plugin, unknown) gets `.swiftUI`, and so does everything
/// inside it, lists and paragraphs included. Those two views are the only
/// places that set `adfTextRenderer`. The coverage walk (`forEachLeaf`)
/// follows the same rule, so the diagnostics count exactly the leaves the
/// views may hand to TextKit 2 (left to right).
enum TextKit2Scope {
    /// Whether a top-level block keeps the renderer choice (`.richText`, a
    /// `.listRows` that `listKeepsRenderer`) rather than resetting it to
    /// `.swiftUI`.
    static func inheritsRenderer(_ kind: RenderBlock.Kind) -> Bool {
        switch kind {
        case .richText: return true
        case .listRows(let rows): return listKeepsRenderer(rows)
        default: return false
        }
    }

    /// Whether a top-level list may hand its text to TextKit 2: when no row
    /// holds a block other than a paragraph or heading (a code block, a
    /// container, a table, media, a list under another node). Such a row is
    /// drawn by SwiftUI on either engine and does not settle: lists-parity's
    /// embedded-blocks item measured 2,127 pt tall and then 2,003 pt at
    /// AX5 in its list, and reported a width a pixel wider than proposed,
    /// so the list re-proposed its other rows and the document placed them
    /// by whichever pass came last — its continuation paragraph drew
    /// 31 pt lower on TextKit 2 (a 402 pt document); without the item the
    /// document matched. Every row of such a list keeps its text on
    /// SwiftUI.
    static func listKeepsRenderer(_ rows: [PreparedListRow]) -> Bool {
        rows.allSatisfy { row in
            row.trailingBlocks.allSatisfy { block in
                if case .richText = block.kind { return true }
                return false
            }
        }
    }

    /// Whether a list row's text may use TextKit 2: when its text column
    /// holds one text block, its leader or a single trailing paragraph or
    /// heading.
    ///
    /// A row's `HStack` lays its text column out a second time at the
    /// row's own height, and the column's `VStack` shares that height out
    /// among its blocks, least flexible first. `Text` gives up whole lines
    /// (it truncates) when its share is short; a TextKit 2 row keeps its
    /// height. With two or more blocks a share can come up short wherever
    /// the blocks' lines differ in height, and the engines then size and
    /// place the column differently: lists-parity's embedded-blocks item
    /// drew its text 14.5 pt lower in the document at xxxLarge on a 402 pt
    /// phone. On hosted rows at three sizes and two widths, columns with a
    /// heading or a superscript line beside other text mismatched, as did
    /// columns with a trailing list or a container; a column of one block
    /// has the height to itself and matched in every shape measured. A row
    /// with more than one block keeps all its text, and everything in its
    /// trailing blocks, on SwiftUI.
    static func rowKeepsRenderer(_ row: PreparedListRow) -> Bool {
        if row.trailingBlocks.isEmpty { return !row.segments.isEmpty }
        guard row.segments.isEmpty, row.trailingBlocks.count == 1, case .richText = row.trailingBlocks[0].kind else { return false }
        return true
    }

    /// Whether list text laid out in `direction` may use TextKit 2: left
    /// to right only. Right to left, `Text` measures a line that fills its
    /// column differently from left to right and from TextKit — at the
    /// 291.67 pt column of a 375 pt document at AX1 it reports 292 (a pixel
    /// wider than proposed), and at 292 a height a point short of
    /// TextKit's and its own left to right — so a list that grows
    /// to a row's reported width re-proposes every row, and the engines
    /// size them apart: lists-parity drew rows 2 px apart there, and `Text`
    /// truncated a line it had measured as fitting. Coverage counts
    /// (`forEachLeaf`) assume left to right.
    static func listDirectionKeepsRenderer(_ direction: LayoutDirection) -> Bool {
        direction == .leftToRight
    }

    /// The narrowest list text column TextKit 2 draws in. A list row's
    /// `HStack` proposes its text a zero width once the depth padding and
    /// marker column use up the list's width (deep nesting at accessibility
    /// sizes: `lists-parity`'s depth-4 row at AX3 on an iPhone SE, AX2 in a
    /// 320 pt Split View column). `Text` then sets one character per line,
    /// overflowing its zero-width frame; the TextKit 2 row answers a zero
    /// proposal with no layout (the stack also probes every list text with
    /// one, so laying it out would cost each leaf a character-wrapped
    /// layout, measured 4.9 times a column-width one). Measured on
    /// iOS 26.3, the arms agree at every positive width down to one pixel,
    /// so the threshold
    /// only absorbs rounding: a column narrower than this stays on SwiftUI.
    static let minimumListTextWidth: CGFloat = 1

    /// Whether list text in a column `width` wide (`nil`: unknown) may use
    /// TextKit 2.
    static func listTextFits(_ width: CGFloat?) -> Bool {
        guard let width else { return true }
        return width >= minimumListTextWidth
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

        /// The engine verdict for this leaf where it sits
        /// (`TextKit2Eligibility.verdict(_:owner:)`): what `TextEngineLeaf`
        /// decides for it.
        var verdict: TextKit2Eligibility.Verdict {
            TextKit2Eligibility.verdict(segments, owner: position == .root ? .root : .list)
        }
    }

    /// Visits every text leaf of the document's top-level blocks in the
    /// scope, in prepared (depth-first) order. A row with empty segments
    /// has no leader view, so it is not a leaf.
    static func forEachLeaf(in blocks: [RenderBlock], _ visit: (Leaf) -> Void) {
        for block in blocks {
            switch block.kind {
            case .richText(let segments, let style):
                visit(Leaf(ownerID: block.id, segments: segments, style: style, position: .root))
            case .listRows(let rows) where listKeepsRenderer(rows):
                forEachLeaf(inList: rows, visit)
            default:
                continue
            }
        }
    }

    private static func forEachLeaf(inList rows: [PreparedListRow], _ visit: (Leaf) -> Void) {
        for row in rows where rowKeepsRenderer(row) {
            if !row.segments.isEmpty {
                visit(Leaf(ownerID: row.id, segments: row.segments, style: nil, position: .listLeader))
            }
            for block in row.trailingBlocks {
                if case .richText(let segments, let style) = block.kind {
                    visit(Leaf(ownerID: block.id, segments: segments, style: style, position: .listTrailing))
                }
            }
        }
    }
}
