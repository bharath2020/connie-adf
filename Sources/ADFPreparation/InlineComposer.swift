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
        compose(inline, baseFont: theme.body, baseFontSpec: theme.bodyFontSpec)
    }

    /// Composes inline nodes on top of an explicit base font. A raw `Font`
    /// cannot be described to another text engine, so unmarked runs carry
    /// no font spec and render through SwiftUI; prefer
    /// `compose(_:baseFont:baseFontSpec:)`.
    public func compose(_ inline: [ADFNode], baseFont: Font) -> [InlineSegment] {
        compose(inline, baseFont: baseFont, baseFontSpec: nil)
    }

    /// Composes inline nodes on top of an explicit base font and its
    /// semantic spec (headings pass their level font and spec so unmarked
    /// runs inherit both). A `nil` spec marks those runs undescribable.
    public func compose(_ inline: [ADFNode], baseFont: Font, baseFontSpec: ADFFontSpec?) -> [InlineSegment] {
        composeOwner(inline, baseFont: baseFont, baseFontSpec: baseFontSpec).segments
    }

    /// One text owner's composed content (a paragraph's, a heading's, a
    /// list leader's or a caption's) and the smart links in it.
    package struct ComposedInline: Sendable {
        package var segments: [InlineSegment]
        /// The keys of the smart-link runs in `segments`, de-duplicated, in
        /// document order. Empty for the overwhelming majority of owners, so
        /// every renderer gate is one `isEmpty` check.
        package var smartLinkKeys: [SmartLinkKey]
    }

    /// `compose(_:)` plus the owner's smart-link keys.
    package func composeOwner(_ inline: [ADFNode]) -> ComposedInline {
        composeOwner(inline, baseFont: theme.body, baseFontSpec: theme.bodyFontSpec)
    }

    /// `compose(_:baseFont:baseFontSpec:)` plus the owner's smart-link keys:
    /// qualifying bare links and inline cards (`SmartLinkQualification`) are
    /// composed as link text runs carrying `adfSmartLink`.
    package func composeOwner(_ inline: [ADFNode], baseFont: Font, baseFontSpec: ADFFontSpec?) -> ComposedInline {
        var segments: [InlineSegment] = []
        var pending = AttributedString()
        let smartLinks = Self.smartLinkPlacements(in: inline)

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

        for (index, node) in inline.enumerated() {
            switch node.kind {
            case .text(let string, let marks):
                var run = attributedRun(string, marks: marks, baseFont: baseFont, baseFontSpec: baseFontSpec)
                if let placement = smartLinks.placements[index] {
                    Self.mark(&run, with: placement)
                }
                pending.append(run)
            case .inlineCard(let url, let data) where smartLinks.placements[index] != nil:
                // A qualifying inline card is a smart link: link text (the
                // URL, link styling) instead of the host-only chip atom, so
                // its paragraph is not word-chunked and stays eligible for
                // TextKit 2 (design §1.4).
                if let placement = smartLinks.placements[index], let urlString = url ?? data?["url"]?.stringValue {
                    var run = attributedRun(
                        urlString, marks: [.link(href: urlString, title: nil)],
                        baseFont: baseFont, baseFontSpec: baseFontSpec
                    )
                    Self.mark(&run, with: placement)
                    pending.append(run)
                }
            case .hardBreak:
                pending.append(attributedRun("\n", marks: [], baseFont: baseFont, baseFontSpec: baseFontSpec))
            case .mention(_, let text, _):
                appendAtom(.mention(text: text), id: node.id)
            case .emoji(let shortName, let text):
                if let text, !text.isEmpty {
                    // Unicode representation exists — keep it in the text run.
                    pending.append(attributedRun(text, marks: [], baseFont: baseFont, baseFontSpec: baseFontSpec))
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
                pending.append(placeholderRun(text, baseFont: baseFont, baseFontSpec: baseFontSpec))
            default:
                // A non-inline node in inline position: surface its type
                // subtly rather than dropping content silently.
                pending.append(placeholderRun("[\(node.type)]", baseFont: baseFont, baseFontSpec: baseFontSpec))
            }
        }
        flush()

        // Atoms force the view onto the wrapping-layout path, which places
        // word-level chunks. Do that expensive split once, off-main, here.
        let containsAtom = segments.contains { segment in
            if case .atom = segment { return true }
            return false
        }
        return ComposedInline(
            segments: containsAtom ? Self.splitForWrappingLayout(segments) : segments,
            smartLinkKeys: smartLinks.keys
        )
    }

    // MARK: - Smart links

    /// Where one smart link sits in a text node: its run value and the
    /// node-local Character range it covers (`nil`: the whole node).
    struct SmartLinkPlacement {
        let run: SmartLinkRun
        let range: Range<Int>?
    }

    /// The smart links among an owner's inline nodes, by node index, and
    /// their de-duplicated keys in document order. Occurrences are numbered
    /// per owner in document order.
    ///
    /// A link may span several adjacent text nodes (part of it bold, say):
    /// the maximal run of adjacent text nodes carrying the same `link` href
    /// is one link, bare when its joined text is its href. Its attribute
    /// covers the joined text's whitespace-trimmed core, so the
    /// word-chunking of atom paragraphs (which splits only at whitespace and
    /// line feeds) never cuts a smart link in two. Links with a `code` mark
    /// are not candidates.
    ///
    /// Cost: nodes without a link mark or an inline card are passed over
    /// with one scan of their marks; no URL is parsed unless the href
    /// mentions `atlassian.net`.
    static func smartLinkPlacements(in inline: [ADFNode]) -> (placements: [Int: SmartLinkPlacement], keys: [SmartLinkKey]) {
        var placements: [Int: SmartLinkPlacement] = [:]
        var keys: [SmartLinkKey] = []
        var occurrence = 0

        func next(_ key: SmartLinkKey) -> SmartLinkRun {
            if !keys.contains(key) { keys.append(key) }
            defer { occurrence += 1 }
            return SmartLinkRun(key: key, occurrence: occurrence)
        }

        var index = 0
        while index < inline.count {
            let node = inline[index]
            switch node.kind {
            case .inlineCard(let url, let data):
                if let urlString = url ?? data?["url"]?.stringValue,
                   let key = SmartLinkQualification.key(for: urlString) {
                    placements[index] = SmartLinkPlacement(run: next(key), range: nil)
                }
                index += 1
            case .text(_, let marks):
                guard let href = candidateHref(marks) else {
                    index += 1
                    continue
                }
                // The link's extent: adjacent text nodes with the same href.
                var end = index + 1
                while end < inline.count, case .text(_, let nextMarks) = inline[end].kind,
                      candidateHref(nextMarks) == href {
                    end += 1
                }
                defer { index = end }
                let texts = inline[index..<end].map { node -> String in
                    if case .text(let string, _) = node.kind { return string }
                    return ""
                }
                let joined = texts.joined()
                guard let key = SmartLinkQualification.key(for: href),
                      SmartLinkQualification.isBare(text: joined, href: href) else { continue }
                let run = next(key)
                // Per node, so offsets agree with each node's own run even
                // where a grapheme would join across a node boundary.
                let characters = texts.flatMap { Array($0) }
                let leading = characters.prefix(while: \.isWhitespace).count
                let trailing = characters.reversed().prefix(while: \.isWhitespace).count
                let core = leading..<max(leading, characters.count - trailing)
                var start = 0
                for (offset, text) in texts.enumerated() {
                    let length = text.count
                    let lower = max(core.lowerBound, start), upper = min(core.upperBound, start + length)
                    if lower < upper {
                        let local = (lower - start)..<(upper - start)
                        placements[index + offset] = SmartLinkPlacement(
                            run: run, range: local == 0..<length ? nil : local
                        )
                    }
                    start += length
                }
            default:
                index += 1
            }
        }
        return (placements, keys)
    }

    /// The href of a text node's `link` mark when it may be a smart link: a
    /// link without a `code` mark (links inside code are not candidates).
    private static func candidateHref(_ marks: [ADFMark]) -> String? {
        var href: String?
        for mark in marks {
            switch mark {
            case .link(let value, _): href = value
            case .code: return nil
            default: break
            }
        }
        return href
    }

    /// Stamps `adfSmartLink` over the placement's range of a node's run.
    private static func mark(_ run: inout AttributedString, with placement: SmartLinkPlacement) {
        guard let range = placement.range else {
            run.adfSmartLink = placement.run
            return
        }
        let characters = run.characters
        let count = characters.count
        let lowerBound = min(range.lowerBound, count), upperBound = min(range.upperBound, count)
        guard lowerBound < upperBound else { return }
        let lower = characters.index(run.startIndex, offsetBy: lowerBound)
        let upper = characters.index(lower, offsetBy: upperBound - lowerBound)
        run[lower..<upper].adfSmartLink = placement.run
    }

    /// Splits every text segment into word chunks (a word plus its trailing
    /// whitespace, attributes preserved) and standalone `"\n"` chunks, so the
    /// wrapping layout consumes pre-computed values only. The renderer
    /// re-chunks a displayed smart-link title with it.
    package static func splitForWrappingLayout(_ segments: [InlineSegment]) -> [InlineSegment] {
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
                result.append(attributedRun(
                    Self.fallbackText(atom), marks: [], baseFont: theme.body, baseFontSpec: theme.bodyFontSpec
                ))
            }
        }
        return result
    }

    // MARK: - Mark → attribute mapping

    private typealias SwiftUIAttrs = AttributeScopes.SwiftUIAttributes

    private func attributedRun(
        _ string: String,
        marks: [ADFMark],
        baseFont: Font,
        baseFontSpec: ADFFontSpec?
    ) -> AttributedString {
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
        var backgroundMarkHex: String?
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
                backgroundMarkHex = hex
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

        // The SwiftUI `Font` and its semantic spec are chosen by the same
        // decision so the two engines can never disagree on the base font.
        // A `nil` spec (a theme font given as a raw `Font`) stays `nil`
        // through the traits: the run is undescribable.
        var font: Font
        var spec: ADFFontSpec?
        if let isSup {
            font = theme.subsupFont(monospaced: code)
            spec = theme.subsupFontSpec(monospaced: code)
            run[SwiftUIAttrs.BaselineOffsetAttribute.self] = theme.subsupBaselineOffset(isSup: isSup)
        } else if code {
            font = theme.code
            spec = theme.codeFontSpec
        } else if small {
            font = theme.smallFont
            spec = theme.smallFontSpec
        } else {
            font = baseFont
            spec = baseFontSpec
        }
        if bold {
            font = font.bold()
            spec?.bold = true
        }
        if italic {
            font = font.italic()
            spec?.italic = true
        }
        if code, background == nil { background = theme.codeBackground }
        // Author highlight fills are fixed colors (typically light pastels);
        // without a textColor mark the scheme default (white in dark mode)
        // can be illegible on them, so derive the run's foreground from the
        // fill's luminance instead.
        if foreground == nil, let backgroundMarkHex {
            foreground = ADFHexColor(backgroundMarkHex)?.contrastingForeground
        }

        run[SwiftUIAttrs.FontAttribute.self] = font
        run.adfFontSpec = spec
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
    private func placeholderRun(_ text: String, baseFont: Font, baseFontSpec: ADFFontSpec?) -> AttributedString {
        var run = AttributedString(text)
        var spec = baseFontSpec
        spec?.italic = true
        run[SwiftUIAttrs.FontAttribute.self] = baseFont.italic()
        run.adfFontSpec = spec
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
