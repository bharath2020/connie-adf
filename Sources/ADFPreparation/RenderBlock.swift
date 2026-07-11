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

    public init(id: String, kind: Kind) {
        self.id = id
        self.kind = kind
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
        case unknown(typeName: String)
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

    public init(id: String, depth: Int, marker: ListMarker, segments: [InlineSegment], trailingBlocks: [RenderBlock]) {
        self.id = id
        self.depth = depth
        self.marker = marker
        self.segments = segments
        self.trailingBlocks = trailingBlocks
    }
}

/// Pre-formatted list row marker.
public enum ListMarker: Sendable, Hashable {
    case bullet(depth: Int)
    /// Fully formatted ordered marker, e.g. `"4."`, `"a."`, `"iv."`.
    case ordered(String)
    case task(done: Bool)
    case decision
}

/// Column metadata shared by all slices of one table.
public struct PreparedTableLayout: Sendable, Hashable {
    /// Exact column widths from `colwidth` attrs when every column has one.
    public let columnWidths: [Double]?
    public let columnCount: Int
    public let hasNumberColumn: Bool

    public init(columnWidths: [Double]?, columnCount: Int, hasNumberColumn: Bool) {
        self.columnWidths = columnWidths
        self.columnCount = columnCount
        self.hasNumberColumn = hasNumberColumn
    }
}

public struct PreparedTableRow: Sendable, Hashable {
    public let id: String
    public let cells: [PreparedTableCell]

    public init(id: String, cells: [PreparedTableCell]) {
        self.id = id
        self.cells = cells
    }
}

public struct PreparedTableCell: Sendable, Hashable {
    public let id: String
    public let colspan: Int
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
        self.id = id
        self.attrs = attrs
        self.layout = layout
        self.widthFraction = widthFraction
        self.pixelWidth = pixelWidth
        self.caption = caption
        self.borderHex = borderHex
        self.linkHref = linkHref
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
