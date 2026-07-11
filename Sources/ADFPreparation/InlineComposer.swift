import Foundation
import SwiftUI
import ADFModel

/// An inline element that cannot be expressed as attributed text and is
/// rendered by the view layer as an inline pill/chip.
public enum InlineAtom: Sendable, Hashable {
    case mention(text: String)
    case status(text: String, color: ADFStatusColor)
    case date(timestampMS: Double)
    case emoji(shortName: String)
    case inlineCard(url: String?)
    case mediaInline(MediaAttrs)
    case inlineExtension(name: String)
}

/// One piece of a composed inline sequence: either a run of attributed text
/// (adjacent text nodes merged) or an atom with its structural node ID.
public enum InlineSegment: Sendable, Hashable {
    case text(AttributedString)
    case atom(InlineAtom, id: String)
}

/// Converts an ADF inline node sequence plus theme into `InlineSegment`s.
///
/// This is where every mark → attribute mapping happens — `AttributedString`
/// building is the single most expensive per-block operation and must never
/// run inside a SwiftUI `body`.
public struct InlineComposer: Sendable {
    public let theme: ADFTheme

    public init(theme: ADFTheme) {
        self.theme = theme
    }

    /// Composes inline nodes using the theme body font as the base.
    /// Adjacent text runs (including hard breaks and text-representable
    /// emoji) merge into a single `AttributedString` segment. When the
    /// sequence contains atoms, text runs are pre-split into word-level
    /// chunks here — at preparation time — so the view layer's wrapping
    /// layout never scans or slices attributed strings inside `body` (§5.3).
    public func compose(_ inline: [ADFNode]) -> [InlineSegment] {
        compose(inline, baseFont: theme.body)
    }

    /// Composes inline nodes on top of an explicit base font (headings pass
    /// their level font so unmarked runs inherit it).
    public func compose(_ inline: [ADFNode], baseFont: Font) -> [InlineSegment] {
        var segments: [InlineSegment] = []
        var pending = AttributedString()

        func flush() {
            if !pending.characters.isEmpty {
                segments.append(.text(pending))
                pending = AttributedString()
            }
        }
        func appendAtom(_ atom: InlineAtom, id: String) {
            flush()
            segments.append(.atom(atom, id: id))
        }

        for node in inline {
            switch node.kind {
            case .text(let string, let marks):
                pending.append(attributedRun(string, marks: marks, baseFont: baseFont))
            case .hardBreak:
                pending.append(attributedRun("\n", marks: [], baseFont: baseFont))
            case .mention(_, let text, _):
                appendAtom(.mention(text: text), id: node.id)
            case .emoji(let shortName, let text):
                if let text, !text.isEmpty {
                    // Unicode representation exists — keep it in the text run.
                    pending.append(attributedRun(text, marks: [], baseFont: baseFont))
                } else {
                    appendAtom(.emoji(shortName: shortName), id: node.id)
                }
            case .date(let timestampMS):
                appendAtom(.date(timestampMS: timestampMS), id: node.id)
            case .status(let text, let color):
                appendAtom(.status(text: text, color: color), id: node.id)
            case .inlineCard(let url, let data):
                appendAtom(.inlineCard(url: url ?? data?["url"]?.stringValue), id: node.id)
            case .mediaInline(let attrs, _):
                appendAtom(.mediaInline(attrs), id: node.id)
            case .inlineExtension(let attrs, _):
                appendAtom(.inlineExtension(name: Self.extensionName(attrs)), id: node.id)
            case .placeholder(let text):
                pending.append(placeholderRun(text, baseFont: baseFont))
            default:
                // A non-inline node in inline position: surface its type
                // subtly rather than dropping content silently.
                pending.append(placeholderRun("[\(node.type)]", baseFont: baseFont))
            }
        }
        flush()

        // Atoms force the view onto the wrapping-layout path, which places
        // word-level chunks. Do that expensive split once, off-main, here.
        let containsAtom = segments.contains { segment in
            if case .atom = segment { return true }
            return false
        }
        return containsAtom ? Self.splitForWrappingLayout(segments) : segments
    }

    /// Splits every text segment into word chunks (a word plus its trailing
    /// whitespace, attributes preserved) and standalone `"\n"` chunks, so the
    /// wrapping layout consumes pre-computed values only.
    static func splitForWrappingLayout(_ segments: [InlineSegment]) -> [InlineSegment] {
        var result: [InlineSegment] = []
        result.reserveCapacity(segments.count)
        for segment in segments {
            switch segment {
            case .atom:
                result.append(segment)
            case .text(let text):
                appendWordChunks(of: text, to: &result)
            }
        }
        return result
    }

    private static func appendWordChunks(of text: AttributedString, to result: inout [InlineSegment]) {
        let characters = text.characters
        var chunkStart = text.startIndex
        var previousWasSpace = false
        var index = text.startIndex

        func flush(upTo end: AttributedString.Index) {
            guard chunkStart < end else { return }
            result.append(.text(AttributedString(text[chunkStart..<end])))
        }

        while index < text.endIndex {
            let character = characters[index]
            let next = characters.index(after: index)
            if character == "\n" {
                flush(upTo: index)
                result.append(.text(AttributedString(text[index..<next])))
                chunkStart = next
                previousWasSpace = false
            } else if previousWasSpace, !character.isWhitespace {
                flush(upTo: index)
                chunkStart = index
                previousWasSpace = false
            } else {
                previousWasSpace = character.isWhitespace
            }
            index = next
        }
        flush(upTo: text.endIndex)
    }

    /// Fully text-only composition: atoms are replaced by plain-text
    /// fallbacks. Used for accessibility labels and simple contexts.
    public func plainAttributed(_ inline: [ADFNode]) -> AttributedString {
        var result = AttributedString()
        for segment in compose(inline) {
            switch segment {
            case .text(let text):
                result.append(text)
            case .atom(let atom, _):
                result.append(attributedRun(Self.fallbackText(atom), marks: [], baseFont: theme.body))
            }
        }
        return result
    }

    // MARK: - Mark → attribute mapping

    private typealias SwiftUIAttrs = AttributeScopes.SwiftUIAttributes

    private func attributedRun(_ string: String, marks: [ADFMark], baseFont: Font) -> AttributedString {
        var run = AttributedString(string)

        var bold = false
        var italic = false
        var code = false
        var small = false
        var isSup: Bool?
        var underline = false
        var strike = false
        var foreground: Color?
        var background: Color?
        var linkURL: URL?

        for mark in marks {
            switch mark {
            case .strong:
                bold = true
            case .em:
                italic = true
            case .code:
                code = true
            case .fontSize(let size):
                small = size == "small"
            case .subsup(let sup):
                isSup = sup
            case .underline:
                underline = true
            case .strike:
                strike = true
            case .textColor(let hex):
                foreground = Color(adfHex: hex)
            case .backgroundColor(let hex):
                background = Color(adfHex: hex)
            case .link(let href, _):
                linkURL = URL(string: href)
                underline = true
            case .annotation:
                // Rendered as an underline decoration in v1 (no comment UI).
                underline = true
            case .alignment, .indentation, .breakout, .border, .dataConsumer, .fragment:
                break // Block/media-level marks: no inline visual.
            }
        }

        var font: Font
        if let isSup {
            font = theme.subsupFont(monospaced: code)
            run[SwiftUIAttrs.BaselineOffsetAttribute.self] = theme.subsupBaselineOffset(isSup: isSup)
        } else if code {
            font = theme.code
        } else if small {
            font = theme.smallFont
        } else {
            font = baseFont
        }
        if bold { font = font.bold() }
        if italic { font = font.italic() }
        if code, background == nil { background = theme.codeBackground }

        run[SwiftUIAttrs.FontAttribute.self] = font
        if let foreground {
            run[SwiftUIAttrs.ForegroundColorAttribute.self] = foreground
        }
        if let background {
            run[SwiftUIAttrs.BackgroundColorAttribute.self] = background
        }
        if underline {
            run[SwiftUIAttrs.UnderlineStyleAttribute.self] = .single
        }
        if strike {
            run[SwiftUIAttrs.StrikethroughStyleAttribute.self] = .single
        }
        if let linkURL {
            run[AttributeScopes.FoundationAttributes.LinkAttribute.self] = linkURL
        }
        return run
    }

    /// Grey italic run for `placeholder` nodes and non-inline strays.
    private func placeholderRun(_ text: String, baseFont: Font) -> AttributedString {
        var run = AttributedString(text)
        run[SwiftUIAttrs.FontAttribute.self] = baseFont.italic()
        run[SwiftUIAttrs.ForegroundColorAttribute.self] = Color.secondary
        return run
    }

    // MARK: - Atom fallbacks

    static func extensionName(_ attrs: ExtensionAttrs) -> String {
        if let text = attrs.text, !text.isEmpty { return text }
        if !attrs.extensionKey.isEmpty { return attrs.extensionKey }
        if !attrs.extensionType.isEmpty { return attrs.extensionType }
        return "extension"
    }

    static func fallbackText(_ atom: InlineAtom) -> String {
        switch atom {
        case .mention(let text):
            return text.hasPrefix("@") ? text : "@\(text)"
        case .status(let text, _):
            return text
        case .date(let timestampMS):
            let date = Date(timeIntervalSince1970: timestampMS / 1000)
            return date.formatted(date: .abbreviated, time: .omitted)
        case .emoji(let shortName):
            return ":\(shortName):"
        case .inlineCard(let url):
            return url ?? "link"
        case .mediaInline(let attrs):
            return attrs.alt ?? "attachment"
        case .inlineExtension(let name):
            return name
        }
    }
}
