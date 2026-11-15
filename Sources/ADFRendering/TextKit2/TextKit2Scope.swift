import SwiftUI
import ADFPreparation

/// Where the host's text engine choice applies. `DocumentRow` passes it to
/// top-level paragraphs and headings (`.richText`) and top-level lists
/// (`.listRows`) unless a row holds both a panel and an expand
/// (`listKeepsRenderer`). A list row passes it to its text when its text
/// column holds one text block, or only body-styled paragraphs
/// (`rowKeepsRenderer`, `ListRowView`), laid out left to right
/// (`listDirectionKeepsRenderer`); any other row draws all its text on
/// SwiftUI. Before iOS 26 the leaf itself keeps list text on SwiftUI
/// (`TextKit2Eligibility.listsMatchText`, a `.osGatedList` fallback the
/// coverage counts). Every other top-level kind
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

    /// Whether a top-level list may hand its text to TextKit 2: unless a
    /// row holds both a panel and an expand. SwiftUI draws such a row on
    /// either engine, and the list's other rows then land differently on
    /// the two arms: lists-parity's embedded-blocks item (0.10.2: code,
    /// panel, quote, expand, table, rule) left the list's TextKit 2 rows
    /// drawn apart from `Text`'s at AX5 on a 402 pt phone (3x; the same
    /// height, different pixels from 1,000 pt down). Without its panel, or
    /// without its expand, the list matched; without its code block,
    /// quote, table or rule it did not. A list with one row holding any
    /// one of those kinds (code, panel, quote, expand, table, rule, a sync
    /// block, an item that starts with a code block) matched at six sizes
    /// and four widths, 3x and 2x. Every row of such a list keeps its text
    /// on SwiftUI; a row holding any other non-text block keeps only its
    /// own text there (`rowKeepsRenderer`).
    static func listKeepsRenderer(_ rows: [PreparedListRow]) -> Bool {
        !rows.contains { row in
            row.trailingBlocks.contains { if case .panel = $0.kind { return true }; return false }
                && row.trailingBlocks.contains { if case .expand = $0.kind { return true }; return false }
        }
    }

    /// Whether a list row's text may use TextKit 2: when its text column
    /// holds one text block (its leader, or a lone paragraph or heading),
    /// or only paragraphs, leader included, every run of them set in the
    /// body text style (`isBodyText`).
    ///
    /// A row's `HStack` lays its text column out a second time at the
    /// row's own height, and the column's `VStack` shares that height out
    /// among its blocks. A column of one block has the height to itself
    /// and matched in every shape measured. Columns of body paragraphs
    /// matched too, in height and first and last baselines, links, emoji,
    /// bold, italic and inline code included: every multi-paragraph row of
    /// list-dense and lists-parity at Large to AX5 on 375 and 320 pt
    /// documents, and synthetic shapes at xSmall to AX5 and Bold Text on
    /// four widths, at 3x and 2x. A column with a superscript, subscript or
    /// small-text run beside another block kept its height but put its
    /// last baseline up to 62 pt apart (list-dense 0.410.2 at AX5, 375 pt:
    /// 308.67 against 370.67). Such a column, a column with a heading
    /// beside other text, and a row holding any other block (a trailing
    /// list, a container, code, a table, media) keep all their text, and
    /// everything in their trailing blocks, on SwiftUI.
    static func rowKeepsRenderer(_ row: PreparedListRow) -> Bool {
        if row.trailingBlocks.isEmpty { return !row.segments.isEmpty }
        if row.segments.isEmpty, row.trailingBlocks.count == 1, case .richText = row.trailingBlocks[0].kind { return true }
        guard isBodyText(row.segments) else { return false }
        return row.trailingBlocks.allSatisfy { block in
            guard case .richText(let segments, let style) = block.kind, !style.isHeading else { return false }
            return isBodyText(segments)
        }
    }

    /// Whether every text run of `segments` is set in the body text style
    /// (`ADFFontSpec.textStyle`): no superscript, subscript or small text.
    static func isBodyText(_ segments: [InlineSegment]) -> Bool {
        segments.allSatisfy { segment in
            guard case .text(let text) = segment else { return true }
            return text.runs.allSatisfy { ($0.adfFontSpec?.textStyle ?? .body) == .body }
        }
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
