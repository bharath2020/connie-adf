import Foundation
import ADFModel

/// Preparation-time semantic spine used only when a selection is copied.
///
/// Search and selection already flatten the visible document into text
/// units. This value keeps the block kind, inline formatting source, and
/// containing ADF components alongside each unit so Copy can reconstruct a
/// valid ADF fragment and semantic HTML without walking the rendered view
/// hierarchy or guessing from pixels.
public struct ADFClipboardMetadata: Sendable, Hashable {
    public enum Block: Sendable, Hashable {
        case richText(TextBlockStyle)
        case codeBlock(language: String?)
        case listRow(marker: ListMarker, depth: Int)
        case caption
    }

    public enum Container: Sendable, Hashable {
        case panel(id: String, type: ADFPanelType, colorHex: String?)
        case quote(id: String)
        case table(id: String, hasNumberColumn: Bool)
        case tableRow(id: String)
        case tableCell(
            id: String,
            colspan: Int,
            rowspan: Int,
            backgroundHex: String?,
            valign: ADFVAlign?,
            isHeader: Bool
        )
        case expand(id: String, title: String, isNested: Bool)
        case layoutSection(id: String)
        case layoutColumn(id: String, widthPercent: Double)
        case extensionContainer(id: String, title: String)
    }

    public let block: Block
    /// Exactly the segment array indexed by `SearchTextUnit.parts`.
    public let segments: [InlineSegment]
    /// Outermost to innermost.
    public let containers: [Container]

    public init(block: Block, segments: [InlineSegment], containers: [Container]) {
        self.block = block
        self.segments = segments
        self.containers = containers
    }
}
