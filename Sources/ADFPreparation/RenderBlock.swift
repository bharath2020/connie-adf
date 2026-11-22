import Foundation
import SwiftUI
import ADFModel

/// One flattened, fully prepared block of a document.
///
/// The lazy scroll container iterates `[RenderBlock]`; everything inside
/// `Kind` is an immutable value (no closures, no references), so rows diff
/// cheaply and `body` implementations only assemble pre-computed values.
public struct RenderBlock: Identifiable, Hashable, Sendable {
    /// Structural path ID of the source node (table slices append a
    /// `#header` / `#rows<n>` suffix so every block stays unique and stable).
    public let id: String
    public let kind: Kind
    /// Block-level `breakout` mark (§3: breakout applies to the block).
    /// Carried on the block itself so every kind that can legally hold the
    /// mark (codeBlock, layoutSection, expand, …) widens uniformly.
    public let breakout: BlockBreakout?
    /// The smart links in this block's own inline text (a paragraph's or a
    /// heading's), de-duplicated in document order: empty for every other
    /// kind (a container's children, list rows and captions carry their
    /// own) and for nearly every paragraph, so a text leaf's smart-link gate
    /// is one `isEmpty` check. Package-internal (`SmartLinkKey`).
    package let smartLinkKeys: [SmartLinkKey]
    /// The custom emoji in this block's own inline text (a paragraph's or a
    /// heading's), de-duplicated in document order: empty for every other
    /// kind and for nearly every paragraph, so a text leaf's emoji gate is
    /// one `isEmpty` check (as `smartLinkKeys`). Package-internal
    /// (`EmojiKey`).
    package let emojiKeys: [EmojiKey]

    public init(id: String, kind: Kind, breakout: BlockBreakout? = nil) {
        self.init(id: id, kind: kind, breakout: breakout, smartLinkKeys: [])
    }

    package init(
        id: String, kind: Kind, breakout: BlockBreakout? = nil, smartLinkKeys: [SmartLinkKey],
        emojiKeys: [EmojiKey] = []
    ) {
        self.id = id
        self.kind = kind
        self.breakout = breakout
        self.smartLinkKeys = smartLinkKeys
        self.emojiKeys = emojiKeys
    }

    public indirect enum Kind: Hashable, Sendable {
        case richText(segments: [InlineSegment], style: TextBlockStyle)
        case codeBlock(language: String?, code: AttributedString)
        case listRows([PreparedListRow])
        case panel(PanelPalette, [RenderBlock])
        case quote([RenderBlock])
        case divider
        case tableSlice(PreparedTableLayout, rows: [PreparedTableRow], isHeaderSlice: Bool)
        case media(PreparedMedia)
        case mediaStrip([PreparedMedia])
        /// Body stays unprepared until first expansion (prepared on demand,
        /// off-main, by wrapping `body` in a synthetic doc).
        case expand(title: String, body: [ADFNode], isNested: Bool)
        case layoutColumns([PreparedColumn])
        case card(url: String?, title: String?, isEmbed: Bool)
        case extensionPlaceholder(title: String, body: [RenderBlock])
        /// A node claimed by a registered `ADFCustomBlockPreparer`; drawn by
        /// the consumer-provided renderer with the matching `rendererID`.
        case custom(ADFCustomBlock)
        case unknown(typeName: String)
    }
}

/// Prepared payload of a block-level `breakout` mark: the mode plus the
/// optional custom pixel width some producers attach.
public struct BlockBreakout: Sendable, Hashable {
    public let mode: ADFBreakoutMode
    /// Custom breakout width in points, when the mark carries one.
    public let width: Double?

    public init(mode: ADFBreakoutMode, width: Double?) {
        self.mode = mode
        self.width = width
    }
}

/// Block-level text styling resolved from the node kind and its marks.
public struct TextBlockStyle: Sendable, Hashable {
    public let font: Font
    public let isHeading: Bool
    public let headingLevel: Int?
    public let alignment: ADFAlignment?
    public let indentation: Int
    public let breakout: ADFBreakoutMode?

    public init(
        font: Font,
        isHeading: Bool,
        headingLevel: Int?,
        alignment: ADFAlignment?,
        indentation: Int,
        breakout: ADFBreakoutMode?
    ) {
        self.font = font
        self.isHeading = isHeading
        self.headingLevel = headingLevel
        self.alignment = alignment
        self.indentation = indentation
        self.breakout = breakout
    }
}

/// One flattened list row: pre-computed marker, depth, composed inline
/// content, and any non-inline children rendered below the row content.
public struct PreparedListRow: Sendable, Hashable {
    public let id: String
    public let depth: Int
    public let marker: ListMarker
    public let segments: [InlineSegment]
    public let trailingBlocks: [RenderBlock]
    /// The smart links in the row's leader (`segments`), de-duplicated in
    /// document order (see `RenderBlock.smartLinkKeys`).
    package let smartLinkKeys: [SmartLinkKey]
    /// The custom emoji in the row's leader (`segments`), de-duplicated in
    /// document order (see `RenderBlock.emojiKeys`).
    package let emojiKeys: [EmojiKey]

    public init(id: String, depth: Int, marker: ListMarker, segments: [InlineSegment], trailingBlocks: [RenderBlock]) {
        self.init(id: id, depth: depth, marker: marker, segments: segments, trailingBlocks: trailingBlocks, smartLinkKeys: [])
    }

    package init(
        id: String, depth: Int, marker: ListMarker, segments: [InlineSegment], trailingBlocks: [RenderBlock],
        smartLinkKeys: [SmartLinkKey], emojiKeys: [EmojiKey] = []
    ) {
        self.id = id
        self.depth = depth
        self.marker = marker
        self.segments = segments
        self.trailingBlocks = trailingBlocks
        self.smartLinkKeys = smartLinkKeys
        self.emojiKeys = emojiKeys
    }
}

/// Pre-formatted list row marker.
public enum ListMarker: Sendable, Hashable {
    case bullet(depth: Int)
    /// Fully formatted ordered marker, e.g. `"4."`, `"a."`, `"iv."`.
    case ordered(String)
    case task(id: String, done: Bool)
    case decision
    /// Continuation of an item whose content resumes after a nested list:
    /// renders an empty marker column so the content stays aligned under the
    /// item's first line, preserving document order.
    case continuation
}

/// Column metadata shared by all slices of one table.
///
/// Everything here is per table, never per slice: every slice of a table
/// carries an equal layout, so the widths each slice resolves from it (a
/// pure function of this value, the container width and the type size —
/// `TableColumnSizing`) are identical and the slices line up as one table.
public struct PreparedTableLayout: Sendable, Hashable {
    /// Exact column widths from `colwidth` attrs when every column has one.
    public let columnWidths: [Double]?
    public let columnCount: Int
    public let hasNumberColumn: Bool
    /// Natural single-line width of each column at the theme's body size:
    /// its widest single-column cell's plain text (header cells measured
    /// semibold) plus the cell's horizontal padding, unclamped. Resolved to
    /// on-screen widths by `TableColumnSizing.columnWidths`. Empty for a
    /// layout built without measurement (every column then sits at the
    /// minimum width before spare width is shared out).
    public let naturalColumnWidths: [Double]
    /// Per column, the few widest lines behind `naturalColumnWidths`, so a
    /// slice at another Dynamic Type size re-measures just these (system
    /// font tracking is size-dependent, so widths do not scale linearly).
    public let columnSamples: [[PreparedTableColumnSample]]
    /// Per column: every non-empty single-column body cell reads as a
    /// number or percentage (`TableColumnAnalysis.isNumeric`), so the
    /// column is trailing-aligned with monospaced digits. Empty means none.
    public let numericColumns: [Bool]
    /// The first row is all header cells and renders as the pinned header
    /// slice.
    public let hasHeaderRow: Bool
    /// Every body row's column-0 cell is a header cell (and no row spans
    /// column 0 across columns): the table has a header column, drawn with
    /// a 1 pt separator to its right and pinned while the table scrolls
    /// (`TableColumnSizing.pinsHeaderColumn`).
    public let hasHeaderColumn: Bool
    /// Rows in the whole table, so a slice can tell whether it holds the
    /// table's last row (page spacing below the table).
    public let rowCount: Int

    public init(
        columnWidths: [Double]?,
        columnCount: Int,
        hasNumberColumn: Bool,
        naturalColumnWidths: [Double] = [],
        columnSamples: [[PreparedTableColumnSample]] = [],
        numericColumns: [Bool] = [],
        hasHeaderRow: Bool = false,
        hasHeaderColumn: Bool = false,
        rowCount: Int = 0
    ) {
        self.columnWidths = columnWidths
        self.columnCount = columnCount
        self.hasNumberColumn = hasNumberColumn
        self.naturalColumnWidths = naturalColumnWidths
        self.columnSamples = columnSamples
        self.numericColumns = numericColumns
        self.hasHeaderRow = hasHeaderRow
        self.hasHeaderColumn = hasHeaderColumn
        self.rowCount = rowCount
    }

    /// Whether column `index` is a numeric (trailing-aligned) column.
    public func isNumericColumn(_ index: Int) -> Bool {
        index >= 0 && index < numericColumns.count && numericColumns[index]
    }
}

public struct PreparedTableRow: Sendable, Hashable {
    public let id: String
    public let cells: [PreparedTableCell]
    /// The row's index in its table (0 is the first row, header or not).
    public let index: Int
    /// Grid column each cell starts at, parallel to `cells`. Columns held
    /// by a rowspan from an earlier row are skipped, so later cells land
    /// under their own headers.
    public let cellColumns: [Int]
    /// Grid positions in this row covered by a cell from an earlier row
    /// (rowspan), in column order. Drawn as empty cells with the spanning
    /// cell's fill and no divider above them.
    public let continuations: [PreparedTableContinuation]

    public init(id: String, cells: [PreparedTableCell]) {
        var columns: [Int] = []
        columns.reserveCapacity(cells.count)
        var column = 0
        for cell in cells {
            columns.append(column)
            column += max(cell.colspan, 1)
        }
        self.init(id: id, cells: cells, index: 0, cellColumns: columns, continuations: [])
    }

    public init(
        id: String,
        cells: [PreparedTableCell],
        index: Int,
        cellColumns: [Int],
        continuations: [PreparedTableContinuation]
    ) {
        self.id = id
        self.cells = cells
        self.index = index
        self.cellColumns = cellColumns
        self.continuations = continuations
    }
}

/// One line of cell text that sets (or nearly sets) a column's natural
/// width, with what it draws beside its characters.
public struct PreparedTableColumnSample: Sendable, Hashable {
    public let text: String
    /// Measured semibold (a header cell).
    public let isSemibold: Bool
    /// Has a bold run: measured bold.
    public let isBold: Bool
    /// Has an inline-code run: measured monospaced.
    public let isMonospaced: Bool
    /// The line's largest text style relative to body text (a heading's
    /// title sizes): measured at the body size × this factor.
    public let sizeFactor: Double
    /// Width beside the text that scales with Dynamic Type, in points at
    /// the default size: list marker columns and inline chip padding.
    public let scaledInset: Double
    /// Width beside the text that does not scale: list spacing.
    public let fixedInset: Double

    public init(
        text: String,
        isSemibold: Bool,
        isBold: Bool = false,
        isMonospaced: Bool = false,
        sizeFactor: Double = 1,
        scaledInset: Double = 0,
        fixedInset: Double = 0
    ) {
        self.text = text
        self.isSemibold = isSemibold
        self.isBold = isBold
        self.isMonospaced = isMonospaced
        self.sizeFactor = sizeFactor
        self.scaledInset = scaledInset
        self.fixedInset = fixedInset
    }
}

/// A grid position covered by a rowspanning cell from an earlier row.
public struct PreparedTableContinuation: Sendable, Hashable {
    /// Index of the row the spanning cell starts in.
    public let originRow: Int
    public let column: Int
    public let colspan: Int
    public let backgroundHex: String?
    public let isHeader: Bool
    /// The span carries on into the next row too.
    public let continuesBelow: Bool

    public init(
        originRow: Int, column: Int, colspan: Int, backgroundHex: String?, isHeader: Bool, continuesBelow: Bool
    ) {
        self.originRow = originRow
        self.column = column
        self.colspan = colspan
        self.backgroundHex = backgroundHex
        self.isHeader = isHeader
        self.continuesBelow = continuesBelow
    }
}

public struct PreparedTableCell: Sendable, Hashable {
    public let id: String
    public let colspan: Int
    /// Rows this cell covers, clamped by preparation to the rows left in
    /// the table (a value above 1 means the rows below draw continuations).
    public let rowspan: Int
    public let backgroundHex: String?
    public let valign: ADFVAlign?
    public let isHeader: Bool
    public let blocks: [RenderBlock]

    public init(
        id: String,
        colspan: Int,
        rowspan: Int,
        backgroundHex: String?,
        valign: ADFVAlign?,
        isHeader: Bool,
        blocks: [RenderBlock]
    ) {
        self.id = id
        self.colspan = colspan
        self.rowspan = rowspan
        self.backgroundHex = backgroundHex
        self.valign = valign
        self.isHeader = isHeader
        self.blocks = blocks
    }
}

/// A media item with everything the view needs before any bytes load:
/// source, intrinsic dimensions, layout, caption, and container marks.
public struct PreparedMedia: Sendable, Hashable {
    public let id: String
    public let attrs: MediaAttrs
    public let layout: ADFMediaLayout
    /// Width as a fraction of the container (from percentage `width` attrs).
    public let widthFraction: Double?
    /// Exact pixel width (when `widthType == .pixel`).
    public let pixelWidth: Double?
    public let caption: [InlineSegment]?
    public let borderHex: String?
    public let linkHref: String?
    /// The smart links in `caption`, de-duplicated in document order (see
    /// `RenderBlock.smartLinkKeys`).
    package let captionSmartLinkKeys: [SmartLinkKey]

    public init(
        id: String,
        attrs: MediaAttrs,
        layout: ADFMediaLayout,
        widthFraction: Double?,
        pixelWidth: Double?,
        caption: [InlineSegment]?,
        borderHex: String?,
        linkHref: String?
    ) {
        self.init(
            id: id, attrs: attrs, layout: layout, widthFraction: widthFraction, pixelWidth: pixelWidth,
            caption: caption, borderHex: borderHex, linkHref: linkHref, captionSmartLinkKeys: []
        )
    }

    package init(
        id: String,
        attrs: MediaAttrs,
        layout: ADFMediaLayout,
        widthFraction: Double?,
        pixelWidth: Double?,
        caption: [InlineSegment]?,
        borderHex: String?,
        linkHref: String?,
        captionSmartLinkKeys: [SmartLinkKey]
    ) {
        self.id = id
        self.attrs = attrs
        self.layout = layout
        self.widthFraction = widthFraction
        self.pixelWidth = pixelWidth
        self.caption = caption
        self.borderHex = borderHex
        self.linkHref = linkHref
        self.captionSmartLinkKeys = captionSmartLinkKeys
    }
}

/// One column of a layout section with its prepared content.
public struct PreparedColumn: Sendable, Hashable {
    public let id: String
    public let widthPercent: Double
    public let blocks: [RenderBlock]

    public init(id: String, widthPercent: Double, blocks: [RenderBlock]) {
        self.id = id
        self.widthPercent = widthPercent
        self.blocks = blocks
    }
}
