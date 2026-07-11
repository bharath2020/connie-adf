/// One node of a parsed ADF document.
///
/// `id` is a structural path assigned during decode (`"0"`, `"0.2"`,
/// `"0.2.1"` — child indexes from the root). It is stable across re-parses of
/// the same JSON, so it serves as the SwiftUI identity, scroll anchor, and
/// cache key downstream.
public struct ADFNode: Sendable, Hashable, Identifiable {
    /// Structural path, e.g. `"0.2.1"`.
    public let id: String
    /// The raw ADF `type` string (`"tableHeader"` stays `"tableHeader"` even
    /// though its kind collapses to `.tableCell(isHeader: true)`).
    public let type: String
    public let kind: Kind

    public init(id: String, type: String, kind: Kind) {
        self.id = id
        self.type = type
        self.kind = kind
    }

    public indirect enum Kind: Sendable, Hashable {
        case doc([ADFNode])
        case paragraph(content: [ADFNode], marks: [ADFMark])
        case heading(level: Int, content: [ADFNode], marks: [ADFMark])
        case text(String, marks: [ADFMark])
        case hardBreak
        case blockquote([ADFNode])
        case bulletList([ADFNode], marks: [ADFMark])
        case orderedList(start: Int, [ADFNode], marks: [ADFMark])
        case listItem([ADFNode])
        case codeBlock(language: String?, text: String, marks: [ADFMark])
        case rule
        case panel(type: ADFPanelType, icon: String?, colorHex: String?, [ADFNode])
        case table(attrs: TableAttrs, rows: [ADFNode])
        case tableRow([ADFNode])
        case tableCell(attrs: CellAttrs, [ADFNode], isHeader: Bool)
        case expand(title: String, [ADFNode], isNested: Bool)
        case mediaSingle(layout: ADFMediaLayout, width: Double?, widthType: ADFWidthType?, [ADFNode])
        case mediaGroup([ADFNode])
        case media(MediaAttrs, marks: [ADFMark])
        case mediaInline(MediaAttrs, marks: [ADFMark])
        case caption([ADFNode])
        case taskList([ADFNode])
        case taskItem(state: ADFTaskState, [ADFNode])
        case decisionList([ADFNode])
        case decisionItem([ADFNode])
        case layoutSection(columns: [ADFNode], marks: [ADFMark])
        case layoutColumn(width: Double, [ADFNode])
        case blockCard(url: String?, data: JSONValue?)
        case embedCard(url: String, layout: ADFMediaLayout, width: Double?)
        case inlineCard(url: String?, data: JSONValue?)
        case mention(id: String, text: String, accessLevel: String?)
        case emoji(shortName: String, text: String?)
        /// Parsed from the schema's STRING attr of epoch milliseconds.
        case date(timestampMS: Double)
        case status(text: String, color: ADFStatusColor)
        case placeholder(text: String)
        case adfExtension(ExtensionAttrs, marks: [ADFMark])
        case bodiedExtension(ExtensionAttrs, [ADFNode], marks: [ADFMark])
        case inlineExtension(ExtensionAttrs, marks: [ADFMark])
        /// `bodiedSyncBlock` collapses into this case (content non-empty).
        case syncBlock(resourceId: String?, [ADFNode])
        /// Forward compatibility: unknown node types carry their raw JSON and
        /// never fail the parse.
        case unknown(raw: JSONValue)
    }
}

extension ADFNode {
    /// Child nodes, regardless of kind. Convenience for tree walks.
    public var children: [ADFNode] {
        switch kind {
        case .doc(let content),
             .paragraph(let content, _),
             .heading(_, let content, _),
             .blockquote(let content),
             .bulletList(let content, _),
             .orderedList(_, let content, _),
             .listItem(let content),
             .panel(_, _, _, let content),
             .table(_, let content),
             .tableRow(let content),
             .tableCell(_, let content, _),
             .expand(_, let content, _),
             .mediaSingle(_, _, _, let content),
             .mediaGroup(let content),
             .caption(let content),
             .taskList(let content),
             .taskItem(_, let content),
             .decisionList(let content),
             .decisionItem(let content),
             .layoutSection(let content, _),
             .layoutColumn(_, let content),
             .bodiedExtension(_, let content, _),
             .syncBlock(_, let content):
            return content
        case .text, .hardBreak, .codeBlock, .rule, .media, .mediaInline,
             .blockCard, .embedCard, .inlineCard, .mention, .emoji, .date,
             .status, .placeholder, .adfExtension, .inlineExtension, .unknown:
            return []
        }
    }

    /// Marks attached to this node, regardless of kind.
    public var marks: [ADFMark] {
        switch kind {
        case .paragraph(_, let marks),
             .heading(_, _, let marks),
             .text(_, let marks),
             .bulletList(_, let marks),
             .orderedList(_, _, let marks),
             .codeBlock(_, _, let marks),
             .media(_, let marks),
             .mediaInline(_, let marks),
             .layoutSection(_, let marks),
             .adfExtension(_, let marks),
             .bodiedExtension(_, _, let marks),
             .inlineExtension(_, let marks):
            return marks
        case .doc, .hardBreak, .blockquote, .listItem, .rule, .panel, .table,
             .tableRow, .tableCell, .expand, .mediaSingle, .mediaGroup,
             .caption, .taskList, .taskItem, .decisionList, .decisionItem,
             .layoutColumn, .blockCard, .embedCard, .inlineCard, .mention,
             .emoji, .date, .status, .placeholder, .syncBlock, .unknown:
            return []
        }
    }
}

// MARK: - Supporting value types

public struct TableAttrs: Sendable, Hashable {
    public let isNumberColumnEnabled: Bool
    public let layout: String?
    public let displayMode: String?

    public init(isNumberColumnEnabled: Bool, layout: String?, displayMode: String?) {
        self.isNumberColumnEnabled = isNumberColumnEnabled
        self.layout = layout
        self.displayMode = displayMode
    }
}

public struct CellAttrs: Sendable, Hashable {
    public let colspan: Int
    public let rowspan: Int
    public let colwidth: [Double]?
    public let backgroundHex: String?
    public let valign: ADFVAlign?

    public init(colspan: Int, rowspan: Int, colwidth: [Double]?, backgroundHex: String?, valign: ADFVAlign?) {
        self.colspan = colspan
        self.rowspan = rowspan
        self.colwidth = colwidth
        self.backgroundHex = backgroundHex
        self.valign = valign
    }
}

public struct MediaAttrs: Sendable, Hashable {
    public enum Source: Sendable, Hashable {
        /// Atlassian-hosted media that needs authenticated resolution.
        case file(id: String, collection: String)
        /// Plain URL, fetched directly.
        case external(url: String)
    }

    public let source: Source
    public let width: Double?
    public let height: Double?
    public let alt: String?
    public let mediaType: String?

    public init(source: Source, width: Double?, height: Double?, alt: String?, mediaType: String?) {
        self.source = source
        self.width = width
        self.height = height
        self.alt = alt
        self.mediaType = mediaType
    }
}

public struct ExtensionAttrs: Sendable, Hashable {
    public let extensionType: String
    public let extensionKey: String
    public let text: String?
    public let parameters: JSONValue?

    public init(extensionType: String, extensionKey: String, text: String?, parameters: JSONValue?) {
        self.extensionType = extensionType
        self.extensionKey = extensionKey
        self.text = text
        self.parameters = parameters
    }
}

public enum ADFPanelType: String, Sendable {
    case info, note, tip, warning, error, success, custom
}

public enum ADFStatusColor: String, Sendable {
    case neutral, purple, blue, red, yellow, green
}

public enum ADFMediaLayout: String, Sendable {
    case wide
    case fullWidth = "full-width"
    case center
    case wrapRight = "wrap-right"
    case wrapLeft = "wrap-left"
    case alignEnd = "align-end"
    case alignStart = "align-start"
}

public enum ADFWidthType: String, Sendable {
    case percentage, pixel
}

public enum ADFTaskState: String, Sendable {
    case todo = "TODO"
    case done = "DONE"
}

public enum ADFVAlign: String, Sendable {
    case top, middle, bottom
}

public enum ADFAlignment: String, Sendable {
    case center, end
}

public enum ADFBreakoutMode: String, Sendable {
    case wide
    case fullWidth = "full-width"
}
