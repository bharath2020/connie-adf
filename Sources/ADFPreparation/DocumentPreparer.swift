import Foundation
import SwiftUI
import ADFModel

/// Flattens a parsed `ADFDocument` into an immutable `[RenderBlock]`.
///
/// `prepare` is synchronous (tests, expand bodies); `prepareStream` runs the
/// same walk on a detached task and yields chunks so the first screenful is
/// available in tens of milliseconds.
public struct DocumentPreparer: Sendable {
    public let theme: ADFTheme
    private let engine: BlockPreparer

    /// `customPreparers` are consulted for every block-level node before the
    /// built-in mapping, in registration order (first claim wins). The SAME
    /// list must configure every preparer built for one document — initial
    /// load, expand bodies, and search indexing — or a claimed node inside an
    /// expand renders differently from how it was indexed.
    public init(theme: ADFTheme, customPreparers: [any ADFCustomBlockPreparer] = []) {
        self.theme = theme
        self.engine = BlockPreparer(
            theme: theme,
            composer: InlineComposer(theme: theme),
            customPreparers: customPreparers
        )
    }

    public func prepare(_ doc: ADFDocument) -> [RenderBlock] {
        doc.root.children.flatMap(engine.blocks(for:))
    }

    public func prepareStream(_ doc: ADFDocument, chunkSize: Int) -> AsyncStream<[RenderBlock]> {
        let engine = self.engine
        let minimumChunk = max(chunkSize, 1)
        return AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                var chunk: [RenderBlock] = []
                chunk.reserveCapacity(minimumChunk)
                for node in doc.root.children {
                    if Task.isCancelled { break }
                    chunk.append(contentsOf: engine.blocks(for: node))
                    if chunk.count >= minimumChunk {
                        continuation.yield(chunk)
                        chunk.removeAll(keepingCapacity: true)
                    }
                }
                if !chunk.isEmpty {
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Internal engine shared by `DocumentPreparer`, `ListPreparer` (list
/// flattening extension), and `TablePreparer` (table slicing extension).
struct BlockPreparer: Sendable {
    let theme: ADFTheme
    let composer: InlineComposer
    var customPreparers: [any ADFCustomBlockPreparer] = []

    /// Maps one node to zero or more prepared blocks (tables emit several
    /// slices; transparent containers emit their children's blocks).
    ///
    /// Custom-block plugins are consulted first (except for the `doc` root),
    /// so a claim intercepts the node everywhere this walk reaches: top
    /// level, panels, quotes, table cells, list trailing blocks, layout
    /// columns, bodied extensions, and lazily prepared expand bodies.
    func blocks(for node: ADFNode) -> [RenderBlock] {
        if case .doc = node.kind {} else {
            for preparer in customPreparers {
                if let claim = preparer.claim(for: node) {
                    // The library stamps the claiming preparer's rendererID,
                    // so a claim can never reference the wrong renderer.
                    return [RenderBlock(
                        id: node.id,
                        kind: .custom(ADFCustomBlock(rendererID: preparer.rendererID, claim: claim)),
                        breakout: blockBreakout(of: node.marks)
                    )]
                }
            }
        }
        switch node.kind {
        case .doc(let children):
            return children.flatMap(blocks(for:))

        case .paragraph(let content, let marks):
            return [RenderBlock(
                id: node.id,
                kind: .richText(
                    segments: composer.compose(content),
                    style: textStyle(font: theme.body, isHeading: false, level: nil, marks: marks)
                ),
                breakout: blockBreakout(of: marks)
            )]

        case .heading(let level, let content, let marks):
            let font = theme.headingFont(level)
            return [RenderBlock(
                id: node.id,
                kind: .richText(
                    segments: composer.compose(content, baseFont: font, baseSpec: theme.headingSpec(level)),
                    style: textStyle(font: font, isHeading: true, level: level, marks: marks)
                ),
                breakout: blockBreakout(of: marks)
            )]

        case .blockquote(let children):
            return [RenderBlock(id: node.id, kind: .quote(children.flatMap(blocks(for:))))]

        case .bulletList, .orderedList, .taskList, .decisionList:
            return [RenderBlock(id: node.id, kind: .listRows(listRows(for: node, depth: 0)))]

        case .codeBlock(let language, let text, let marks):
            var code = AttributedString(text)
            code[AttributeScopes.SwiftUIAttributes.FontAttribute.self] = theme.code
            code[FontSpecAttribute.self] = FontSpec(monospaced: true)
            return [RenderBlock(
                id: node.id,
                kind: .codeBlock(language: language, code: code),
                breakout: blockBreakout(of: marks)
            )]

        case .rule:
            return [RenderBlock(id: node.id, kind: .divider)]

        case .panel(let type, _, let colorHex, let children):
            return [RenderBlock(
                id: node.id,
                kind: .panel(theme.panelPalette(type, colorHex: colorHex), children.flatMap(blocks(for:)))
            )]

        case .table(let attrs, let rows):
            return tableSlices(for: node, attrs: attrs, rows: rows)

        case .expand(let title, let body, let isNested, let marks):
            // Body deliberately unprepared: prepared on first expansion.
            return [RenderBlock(
                id: node.id,
                kind: .expand(title: title, body: body, isNested: isNested),
                breakout: blockBreakout(of: marks)
            )]

        case .mediaSingle(let layout, let width, let widthType, let children):
            return mediaSingleBlocks(for: node, layout: layout, width: width, widthType: widthType, children: children)

        case .mediaGroup(let children):
            let items = children.compactMap(preparedMedia(from:))
            return [RenderBlock(id: node.id, kind: .mediaStrip(items))]

        case .media:
            // Stray media outside mediaSingle/mediaGroup: centered block.
            guard let prepared = preparedMedia(from: node) else { return [] }
            return [RenderBlock(id: node.id, kind: .media(prepared))]

        case .layoutSection(let columns, let marks):
            let prepared = columns.compactMap { column -> PreparedColumn? in
                guard case .layoutColumn(let width, let children) = column.kind else { return nil }
                return PreparedColumn(id: column.id, widthPercent: width, blocks: children.flatMap(blocks(for:)))
            }
            return [RenderBlock(
                id: node.id,
                kind: .layoutColumns(prepared),
                breakout: blockBreakout(of: marks)
            )]

        case .blockCard(let url, let data):
            return [RenderBlock(id: node.id, kind: .card(url: url ?? data?["url"]?.stringValue, title: nil, isEmbed: false))]

        case .embedCard(let url, _, _):
            return [RenderBlock(id: node.id, kind: .card(url: url, title: nil, isEmbed: true))]

        case .adfExtension(let attrs, _):
            return [RenderBlock(id: node.id, kind: .extensionPlaceholder(title: InlineComposer.extensionName(attrs), body: []))]

        case .bodiedExtension(let attrs, let children, _):
            return [RenderBlock(
                id: node.id,
                kind: .extensionPlaceholder(title: InlineComposer.extensionName(attrs), body: children.flatMap(blocks(for:)))
            )]

        case .syncBlock(_, let children):
            // Transparent container: render its content in place. A
            // reference-only sync block (no inline copy of the remote
            // content) renders a placeholder chip — §7: nothing silently
            // disappears.
            guard !children.isEmpty else {
                return [RenderBlock(
                    id: node.id,
                    kind: .extensionPlaceholder(title: "Synced block", body: [])
                )]
            }
            return children.flatMap(blocks(for:))

        case .caption(let content):
            // Stray caption outside a mediaSingle: render as plain text.
            return richTextBlock(for: node, inline: content)

        case .text, .hardBreak, .mention, .emoji, .date, .status, .placeholder,
             .inlineCard, .mediaInline, .inlineExtension:
            // Inline node at block level: wrap in a paragraph-style block.
            return richTextBlock(for: node, inline: [node])

        case .listItem, .taskItem, .decisionItem, .tableRow, .tableCell, .layoutColumn:
            // Structural child outside its container: render its content.
            return node.children.flatMap(blocks(for:))

        case .unknown:
            return [RenderBlock(id: node.id, kind: .unknown(typeName: node.type.isEmpty ? "unknown" : node.type))]
        }
    }

    // MARK: - Shared helpers

    var bodyStyle: TextBlockStyle {
        TextBlockStyle(font: theme.body, isHeading: false, headingLevel: nil, alignment: nil, indentation: 0, breakout: nil)
    }

    private func richTextBlock(for node: ADFNode, inline: [ADFNode]) -> [RenderBlock] {
        let segments = composer.compose(inline)
        guard !segments.isEmpty else { return [] }
        return [RenderBlock(id: node.id, kind: .richText(segments: segments, style: bodyStyle))]
    }

    private func textStyle(font: Font, isHeading: Bool, level: Int?, marks: [ADFMark]) -> TextBlockStyle {
        var alignment: ADFAlignment?
        var indentation = 0
        var breakout: ADFBreakoutMode?
        for mark in marks {
            switch mark {
            case .alignment(let value): alignment = value
            case .indentation(let level): indentation = level
            case .breakout(let mode, _): breakout = mode
            default: break
            }
        }
        return TextBlockStyle(
            font: font,
            isHeading: isHeading,
            headingLevel: level,
            alignment: alignment,
            indentation: indentation,
            breakout: breakout
        )
    }

    private func mediaSingleBlocks(
        for node: ADFNode,
        layout: ADFMediaLayout,
        width: Double?,
        widthType: ADFWidthType?,
        children: [ADFNode]
    ) -> [RenderBlock] {
        var mediaNode: ADFNode?
        var caption: [InlineSegment]?
        for child in children {
            switch child.kind {
            case .media where mediaNode == nil:
                mediaNode = child
            case .caption(let inline):
                caption = composer.compose(inline)
            default:
                break
            }
        }
        guard let mediaNode, case .media(let attrs, let marks) = mediaNode.kind else {
            // Defensive: a mediaSingle without media renders its children.
            return children.flatMap(blocks(for:))
        }

        var widthFraction: Double?
        var pixelWidth: Double?
        if let width {
            if widthType == .pixel {
                pixelWidth = width
            } else {
                // Legacy/percentage widths are 0–100.
                widthFraction = min(max(width / 100, 0), 1)
            }
        }
        let prepared = PreparedMedia(
            id: mediaNode.id,
            attrs: attrs,
            layout: layout,
            widthFraction: widthFraction,
            pixelWidth: pixelWidth,
            caption: caption,
            borderHex: borderHex(of: marks),
            linkHref: linkHref(of: marks)
        )
        return [RenderBlock(id: node.id, kind: .media(prepared))]
    }

    private func preparedMedia(from node: ADFNode) -> PreparedMedia? {
        guard case .media(let attrs, let marks) = node.kind else { return nil }
        return PreparedMedia(
            id: node.id,
            attrs: attrs,
            layout: .center,
            widthFraction: nil,
            pixelWidth: nil,
            caption: nil,
            borderHex: borderHex(of: marks),
            linkHref: linkHref(of: marks)
        )
    }

    /// First `breakout` mark, with its optional custom width preserved.
    private func blockBreakout(of marks: [ADFMark]) -> BlockBreakout? {
        for mark in marks {
            if case .breakout(let mode, let width) = mark {
                return BlockBreakout(mode: mode, width: width)
            }
        }
        return nil
    }

    private func borderHex(of marks: [ADFMark]) -> String? {
        for mark in marks {
            if case .border(_, let colorHex) = mark { return colorHex }
        }
        return nil
    }

    private func linkHref(of marks: [ADFMark]) -> String? {
        for mark in marks {
            if case .link(let href, _) = mark { return href }
        }
        return nil
    }
}
