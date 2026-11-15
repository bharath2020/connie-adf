import Foundation
import ADFModel
import ADFPreparation

/// Clipboard representations emitted together for one document selection.
///
/// - Plain text keeps the existing byte-exact corpus contract.
/// - HTML is the interoperable rich-paste path used by web/native editors.
/// - ADF is a valid version-1 document fragment for an ADF-aware editor.
/// A semantic snapshot of the current reader selection.
///
/// Hosts can use the same fragment for an "Add selected" / comment workflow
/// that the built-in Copy action publishes to the pasteboard, so those two
/// paths cannot drift into different formatting behavior.
public struct ADFSelectionFragment: Sendable, Hashable {
    /// Public contract an ADF editor embedded by the same host can consume.
    /// HTML remains the cross-application fallback.
    public static let pasteboardType = "com.connie.adf.document-fragment"

    public let plainText: String
    public let html: Data
    public let adf: Data

    init?(
        model: SelectionTextModel,
        range: Range<Int>,
        isVisible: (SelectionTextModel.Unit) -> Bool
    ) {
        let plainText = model.text(inUTF16: range, isVisible: isVisible)
        guard !plainText.isEmpty else { return nil }

        let selected = Self.selectedUnits(model: model, range: range, isVisible: isVisible)
        let content = Self.nodes(from: selected, containerDepth: 0)
        let document: JSONValue = .object([
            "version": .number(1),
            "type": .string("doc"),
            "content": .array(content.isEmpty ? [Self.paragraph(plainText)] : content),
        ])
        guard
            JSONSerialization.isValidJSONObject(Self.foundationObject(document)),
            let adf = try? JSONSerialization.data(
                withJSONObject: Self.foundationObject(document),
                options: [.sortedKeys]
            )
        else { return nil }

        self.plainText = plainText
        self.adf = adf
        self.html = Data(Self.htmlDocument(for: document).utf8)
    }

    // MARK: Selection slicing

    private enum SelectedInline {
        case text(AttributedString)
        case atom(InlineAtom, fallback: String)
    }

    private struct SelectedUnit {
        let block: ADFClipboardMetadata.Block?
        let containers: [ADFClipboardMetadata.Container]
        let inlines: [SelectedInline]
        let fallbackText: String
    }

    private static func selectedUnits(
        model: SelectionTextModel,
        range: Range<Int>,
        isVisible: (SelectionTextModel.Unit) -> Bool
    ) -> [SelectedUnit] {
        let slices = model.partSlices(forUTF16: range, isVisible: isVisible)
        let grouped = Dictionary(grouping: slices, by: \.unit)
        var result: [SelectedUnit] = []

        for unitIndex in model.units.indices {
            let unit = model.units[unitIndex]
            guard isVisible(unit) else { continue }
            let unitStart = model.unitUTF16Starts[unitIndex]
            let unitEnd = unitStart + unit.utf16Length
            let lower = max(range.lowerBound, unitStart) - unitStart
            let upper = min(range.upperBound, unitEnd) - unitStart
            guard lower < upper else { continue }
            let fallback = utf16Substring(unit.plainText, lower..<upper)

            guard let metadata = unit.clipboard, let unitSlices = grouped[unitIndex] else {
                result.append(SelectedUnit(
                    block: nil,
                    containers: [],
                    inlines: [],
                    fallbackText: fallback
                ))
                continue
            }

            var selectedInlines: [SelectedInline] = []
            for slice in unitSlices {
                switch slice.source {
                case .textSegment(let index):
                    guard metadata.segments.indices.contains(index),
                          case .text(let attributed) = metadata.segments[index],
                          let selected = attributedSubstring(
                            attributed,
                            characterRange: slice.localCharRange
                          ),
                          !selected.characters.isEmpty
                    else { continue }
                    selectedInlines.append(.text(selected))

                case .atom(let id):
                    guard let atom = metadata.segments.compactMap({ segment -> InlineAtom? in
                        guard case .atom(let atom, let atomID) = segment, atomID == id else {
                            return nil
                        }
                        return atom
                    }).first else { continue }
                    let atomFallback = unit.parts.compactMap { part -> String? in
                        guard case .atom(let atomID) = part.source, atomID == id else { return nil }
                        return characterSubstring(unit.plainText, part.range)
                    }.first ?? fallback
                    selectedInlines.append(.atom(atom, fallback: atomFallback))
                }
            }

            result.append(SelectedUnit(
                block: metadata.block,
                containers: metadata.containers,
                inlines: selectedInlines,
                fallbackText: fallback
            ))
        }
        return result
    }

    private static func attributedSubstring(
        _ text: AttributedString,
        characterRange: Range<Int>
    ) -> AttributedString? {
        let characters = text.characters
        guard
            let lower = characters.index(
                characters.startIndex,
                offsetBy: characterRange.lowerBound,
                limitedBy: characters.endIndex
            ),
            let upper = characters.index(
                characters.startIndex,
                offsetBy: characterRange.upperBound,
                limitedBy: characters.endIndex
            ),
            lower < upper
        else { return nil }
        return AttributedString(text[lower..<upper])
    }

    // MARK: ADF tree construction

    /// Groups consecutive units by their semantic container path. A panel
    /// containing three paragraphs therefore produces one panel with three
    /// children, not three duplicated panels; table → row → cell nesting uses
    /// the same general prefix grouping.
    private static func nodes(
        from units: [SelectedUnit],
        containerDepth: Int
    ) -> [JSONValue] {
        var result: [JSONValue] = []
        var index = 0
        while index < units.count {
            let unit = units[index]
            guard unit.containers.indices.contains(containerDepth) else {
                result.append(leafNode(for: unit))
                index += 1
                continue
            }

            let container = unit.containers[containerDepth]
            var end = index + 1
            while end < units.count,
                  units[end].containers.indices.contains(containerDepth),
                  units[end].containers[containerDepth] == container {
                end += 1
            }
            let children = nodes(
                from: Array(units[index..<end]),
                containerDepth: containerDepth + 1
            )
            result.append(wrap(children, in: container))
            index = end
        }
        return result
    }

    private static func leafNode(for unit: SelectedUnit) -> JSONValue {
        let inline = inlineNodes(unit.inlines)
        switch unit.block {
        case .richText(let style):
            var object: [String: JSONValue] = [
                "type": .string(style.isHeading ? "heading" : "paragraph"),
                "content": .array(inline.isEmpty ? textNodes(unit.fallbackText) : inline),
            ]
            if style.isHeading {
                object["attrs"] = .object([
                    "level": .number(Double(style.headingLevel ?? 1))
                ])
            }
            let marks = blockMarks(style)
            if !marks.isEmpty { object["marks"] = .array(marks) }
            return .object(object)

        case .codeBlock(let language):
            var object: [String: JSONValue] = [
                "type": .string("codeBlock"),
                // Newlines are literal text in an ADF code block. Encoding
                // them as hardBreak nodes would change both the ADF meaning
                // and the HTML representation.
                "content": .array(unit.fallbackText.isEmpty ? [] : [
                    .object([
                        "type": .string("text"),
                        "text": .string(unit.fallbackText),
                    ])
                ]),
            ]
            if let language, !language.isEmpty {
                object["attrs"] = .object(["language": .string(language)])
            }
            return .object(object)

        case .listRow(let marker, _):
            let paragraph = JSONValue.object([
                "type": .string("paragraph"),
                "content": .array(inline.isEmpty ? textNodes(unit.fallbackText) : inline),
            ])
            switch marker {
            case .bullet:
                return .object([
                    "type": .string("bulletList"),
                    "content": .array([.object([
                        "type": .string("listItem"),
                        "content": .array([paragraph]),
                    ])]),
                ])
            case .ordered(let label):
                let order = Int(label.prefix(while: \.isNumber)) ?? 1
                return .object([
                    "type": .string("orderedList"),
                    "attrs": .object(["order": .number(Double(order))]),
                    "content": .array([.object([
                        "type": .string("listItem"),
                        "content": .array([paragraph]),
                    ])]),
                ])
            case .task(_, let done):
                return .object([
                    "type": .string("taskList"),
                    "content": .array([.object([
                        "type": .string("taskItem"),
                        "attrs": .object(["state": .string(done ? "DONE" : "TODO")]),
                        "content": .array(inline.isEmpty ? textNodes(unit.fallbackText) : inline),
                    ])]),
                ])
            case .decision:
                return .object([
                    "type": .string("decisionList"),
                    "content": .array([.object([
                        "type": .string("decisionItem"),
                        "content": .array(inline.isEmpty ? textNodes(unit.fallbackText) : inline),
                    ])]),
                ])
            case .continuation:
                return paragraph
            }

        case .caption:
            return .object([
                "type": .string("paragraph"),
                "content": .array(inline.isEmpty ? textNodes(unit.fallbackText) : inline),
            ])

        case nil:
            return paragraph(unit.fallbackText)
        }
    }

    private static func wrap(
        _ children: [JSONValue],
        in container: ADFClipboardMetadata.Container
    ) -> JSONValue {
        switch container {
        case .panel(_, let type, let colorHex):
            var attrs: [String: JSONValue] = ["panelType": .string(type.rawValue)]
            if let colorHex { attrs["panelColor"] = .string(colorHex) }
            return .object([
                "type": .string("panel"),
                "attrs": .object(attrs),
                "content": .array(children),
            ])

        case .quote:
            return .object([
                "type": .string("blockquote"),
                "content": .array(children),
            ])

        case .table(_, let hasNumberColumn):
            return .object([
                "type": .string("table"),
                "attrs": .object(["isNumberColumnEnabled": .bool(hasNumberColumn)]),
                "content": .array(children),
            ])

        case .tableRow:
            return .object([
                "type": .string("tableRow"),
                "content": .array(children),
            ])

        case .tableCell(
            _, let colspan, let rowspan, let backgroundHex, let valign, let isHeader
        ):
            var attrs: [String: JSONValue] = [
                "colspan": .number(Double(colspan)),
                "rowspan": .number(Double(rowspan)),
            ]
            if let backgroundHex { attrs["background"] = .string(backgroundHex) }
            if let valign { attrs["valign"] = .string(valign.rawValue) }
            return .object([
                "type": .string(isHeader ? "tableHeader" : "tableCell"),
                "attrs": .object(attrs),
                "content": .array(children),
            ])

        case .expand(_, let title, let isNested):
            return .object([
                "type": .string(isNested ? "nestedExpand" : "expand"),
                "attrs": .object(["title": .string(title)]),
                "content": .array(children),
            ])

        case .layoutSection:
            return .object([
                "type": .string("layoutSection"),
                "content": .array(children),
            ])

        case .layoutColumn(_, let widthPercent):
            return .object([
                "type": .string("layoutColumn"),
                "attrs": .object(["width": .number(widthPercent)]),
                "content": .array(children),
            ])

        case .extensionContainer(_, let title):
            return .object([
                "type": .string("bodiedExtension"),
                "attrs": .object([
                    "extensionType": .string("com.connie.adf.clipboard"),
                    "extensionKey": .string("copied-extension"),
                    "text": .string(title),
                ]),
                "content": .array(children),
            ])
        }
    }

    private static func inlineNodes(_ inlines: [SelectedInline]) -> [JSONValue] {
        var result: [JSONValue] = []
        for inline in inlines {
            switch inline {
            case .text(let text):
                for run in text.runs {
                    let string = String(text[run.range].characters)
                    let marks = run[ADFSourceMarksAttribute.self] ?? inferredMarks(from: run)
                    let pieces = string.split(separator: "\n", omittingEmptySubsequences: false)
                    for (index, piece) in pieces.enumerated() {
                        if !piece.isEmpty {
                            var object: [String: JSONValue] = [
                                "type": .string("text"),
                                "text": .string(String(piece)),
                            ]
                            let encoded = marks.map(markNode)
                            if !encoded.isEmpty { object["marks"] = .array(encoded) }
                            result.append(.object(object))
                        }
                        if index < pieces.count - 1 {
                            result.append(.object(["type": .string("hardBreak")]))
                        }
                    }
                }

            case .atom(let atom, let fallback):
                result.append(atomNode(atom, fallback: fallback))
            }
        }
        return result
    }

    private static func inferredMarks(
        from run: AttributedString.Runs.Run
    ) -> [ADFMark] {
        var result: [ADFMark] = []
        if let spec = run[FontSpecAttribute.self] {
            if spec.bold { result.append(.strong) }
            if spec.italic { result.append(.em) }
            if spec.monospaced { result.append(.code) }
        }
        if run[AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self] != nil {
            result.append(.underline)
        }
        if run[AttributeScopes.SwiftUIAttributes.StrikethroughStyleAttribute.self] != nil {
            result.append(.strike)
        }
        if let link = run[AttributeScopes.FoundationAttributes.LinkAttribute.self] {
            result.append(.link(href: link.absoluteString, title: nil))
        }
        return result
    }

    private static func blockMarks(_ style: TextBlockStyle) -> [JSONValue] {
        var marks: [ADFMark] = []
        if let alignment = style.alignment { marks.append(.alignment(alignment)) }
        if style.indentation > 0 { marks.append(.indentation(level: style.indentation)) }
        if let breakout = style.breakout { marks.append(.breakout(mode: breakout, width: nil)) }
        return marks.map(markNode)
    }

    private static func markNode(_ mark: ADFMark) -> JSONValue {
        func makeMark(_ type: String, attrs: [String: JSONValue]? = nil) -> JSONValue {
            var object: [String: JSONValue] = ["type": .string(type)]
            if let attrs { object["attrs"] = .object(attrs) }
            return .object(object)
        }
        switch mark {
        case .strong: return makeMark("strong")
        case .em: return makeMark("em")
        case .underline: return makeMark("underline")
        case .strike: return makeMark("strike")
        case .code: return makeMark("code")
        case .subsup(let isSup):
            return makeMark("subsup", attrs: ["type": .string(isSup ? "sup" : "sub")])
        case .textColor(let hex):
            return makeMark("textColor", attrs: ["color": .string(hex)])
        case .backgroundColor(let hex):
            return makeMark("backgroundColor", attrs: ["color": .string(hex)])
        case .fontSize(let size):
            return makeMark("fontSize", attrs: ["size": .string(size)])
        case .link(let href, let title):
            var attrs: [String: JSONValue] = ["href": .string(href)]
            if let title { attrs["title"] = .string(title) }
            return makeMark("link", attrs: attrs)
        case .alignment(let alignment):
            return makeMark("alignment", attrs: ["align": .string(alignment.rawValue)])
        case .indentation(let level):
            return makeMark("indentation", attrs: ["level": .number(Double(level))])
        case .breakout(let mode, let width):
            var attrs: [String: JSONValue] = ["mode": .string(mode.rawValue)]
            if let width { attrs["width"] = .number(width) }
            return makeMark("breakout", attrs: attrs)
        case .border(let size, let colorHex):
            return makeMark("border", attrs: [
                "size": .number(size),
                "color": .string(colorHex),
            ])
        case .annotation(let id, let annotationType):
            return makeMark("annotation", attrs: [
                "id": .string(id),
                "annotationType": .string(annotationType),
            ])
        case .dataConsumer: return makeMark("dataConsumer")
        case .fragment: return makeMark("fragment")
        }
    }

    private static func atomNode(_ atom: InlineAtom, fallback: String) -> JSONValue {
        switch atom {
        case .mention(let text):
            // Prepared mention pills intentionally retain display text but not
            // the account id. Emit text rather than forge an invalid mention.
            return .object(["type": .string("text"), "text": .string(text)])
        case .status(let text, let color):
            return .object([
                "type": .string("status"),
                "attrs": .object([
                    "text": .string(text),
                    "color": .string(color.rawValue),
                ]),
            ])
        case .date(let timestampMS):
            return .object([
                "type": .string("date"),
                "attrs": .object(["timestamp": .string(String(Int64(timestampMS)))]),
            ])
        case .emoji(let shortName):
            return .object([
                "type": .string("emoji"),
                "attrs": .object(["shortName": .string(shortName)]),
            ])
        case .inlineCard(let url):
            if let url {
                return .object([
                    "type": .string("inlineCard"),
                    "attrs": .object(["url": .string(url)]),
                ])
            }
            return .object(["type": .string("text"), "text": .string(fallback)])
        case .mediaInline(let attrs):
            return .object([
                "type": .string("mediaInline"),
                "attrs": .object(mediaAttributes(attrs)),
            ])
        case .inlineExtension:
            return .object(["type": .string("text"), "text": .string(fallback)])
        }
    }

    private static func mediaAttributes(_ media: MediaAttrs) -> [String: JSONValue] {
        var attrs: [String: JSONValue] = [:]
        switch media.source {
        case .file(let id, let collection):
            attrs["type"] = .string("file")
            attrs["id"] = .string(id)
            attrs["collection"] = .string(collection)
        case .external(let url):
            attrs["type"] = .string("external")
            attrs["url"] = .string(url)
        }
        if let width = media.width { attrs["width"] = .number(width) }
        if let height = media.height { attrs["height"] = .number(height) }
        if let alt = media.alt { attrs["alt"] = .string(alt) }
        if let mediaType = media.mediaType { attrs["mediaType"] = .string(mediaType) }
        return attrs
    }

    private static func paragraph(_ text: String) -> JSONValue {
        .object([
            "type": .string("paragraph"),
            "content": .array(textNodes(text)),
        ])
    }

    private static func textNodes(_ text: String) -> [JSONValue] {
        let pieces = text.split(separator: "\n", omittingEmptySubsequences: false)
        var result: [JSONValue] = []
        for (index, piece) in pieces.enumerated() {
            if !piece.isEmpty {
                result.append(.object([
                    "type": .string("text"),
                    "text": .string(String(piece)),
                ]))
            }
            if index < pieces.count - 1 {
                result.append(.object(["type": .string("hardBreak")]))
            }
        }
        return result
    }

    // MARK: Semantic HTML

    private static func htmlDocument(for document: JSONValue) -> String {
        guard case .object(let root) = document,
              case .array(let content)? = root["content"] else {
            return ""
        }
        return "<div data-pm-slice=\"1 1 []\">\(content.map(htmlNode).joined())</div>"
    }

    private static func htmlNode(_ node: JSONValue) -> String {
        guard case .object(let object) = node,
              case .string(let type)? = object["type"] else { return "" }
        let content = childHTML(object)
        switch type {
        case "text":
            guard case .string(let text)? = object["text"] else { return "" }
            return applyHTMLMarks(escapeHTML(text), marks: object["marks"])
        case "hardBreak": return "<br>"
        case "paragraph": return "<p>\(content)</p>"
        case "heading":
            let level = intAttribute(object, "level", default: 1)
            return "<h\(level)>\(content)</h\(level)>"
        case "codeBlock":
            let language = stringAttribute(object, "language")
            let className = language.map { " class=\"language-\(escapeHTMLAttribute($0))\"" } ?? ""
            return "<pre><code\(className)>\(content)</code></pre>"
        case "blockquote": return "<blockquote>\(content)</blockquote>"
        case "bulletList": return "<ul>\(content)</ul>"
        case "orderedList":
            let order = intAttribute(object, "order", default: 1)
            let start = order == 1 ? "" : " start=\"\(order)\""
            return "<ol\(start)>\(content)</ol>"
        case "listItem": return "<li>\(content)</li>"
        case "taskList": return "<ul data-task-list=\"true\">\(content)</ul>"
        case "taskItem":
            let state = stringAttribute(object, "state") ?? "TODO"
            return "<li data-task-state=\"\(state)\">\(content)</li>"
        case "decisionList": return "<ul data-decision-list=\"true\">\(content)</ul>"
        case "decisionItem": return "<li data-decision-item=\"true\">\(content)</li>"
        case "panel":
            let type = stringAttribute(object, "panelType") ?? "info"
            return "<div data-panel-type=\"\(escapeHTMLAttribute(type))\">\(content)</div>"
        case "table": return "<table><tbody>\(content)</tbody></table>"
        case "tableRow": return "<tr>\(content)</tr>"
        case "tableCell": return "<td>\(content)</td>"
        case "tableHeader": return "<th>\(content)</th>"
        case "expand", "nestedExpand":
            let title = stringAttribute(object, "title") ?? ""
            return "<details open><summary>\(escapeHTML(title))</summary>\(content)</details>"
        case "layoutSection": return "<section data-layout-section=\"true\">\(content)</section>"
        case "layoutColumn": return "<div data-layout-column=\"true\">\(content)</div>"
        case "bodiedExtension": return "<section data-adf-extension=\"true\">\(content)</section>"
        case "status":
            let text = stringAttribute(object, "text") ?? ""
            let color = stringAttribute(object, "color") ?? "neutral"
            return "<span data-status-color=\"\(escapeHTMLAttribute(color))\">\(escapeHTML(text))</span>"
        case "date":
            let timestamp = Double(stringAttribute(object, "timestamp") ?? "") ?? 0
            let date = Date(timeIntervalSince1970: timestamp / 1000)
            return "<time datetime=\"\(date.ISO8601Format())\">\(escapeHTML(date.formatted(date: .abbreviated, time: .omitted)))</time>"
        case "emoji":
            let shortName = stringAttribute(object, "shortName") ?? ""
            return "<span data-emoji-short-name=\"\(escapeHTMLAttribute(shortName))\">:\(escapeHTML(shortName)):</span>"
        case "inlineCard":
            let url = stringAttribute(object, "url") ?? ""
            return "<a href=\"\(escapeHTMLAttribute(url))\">\(escapeHTML(url))</a>"
        case "mediaInline":
            let alt = stringAttribute(object, "alt") ?? "attachment"
            return "<span data-media-inline=\"true\">\(escapeHTML(alt))</span>"
        default:
            return content
        }
    }

    private static func childHTML(_ object: [String: JSONValue]) -> String {
        guard case .array(let children)? = object["content"] else { return "" }
        return children.map(htmlNode).joined()
    }

    private static func applyHTMLMarks(_ text: String, marks: JSONValue?) -> String {
        guard case .array(let values)? = marks else { return text }
        return values.reversed().reduce(text) { result, value in
            guard case .object(let mark) = value,
                  case .string(let type)? = mark["type"] else { return result }
            switch type {
            case "strong": return "<strong>\(result)</strong>"
            case "em": return "<em>\(result)</em>"
            case "underline": return "<u>\(result)</u>"
            case "strike": return "<s>\(result)</s>"
            case "code": return "<code>\(result)</code>"
            case "subsup":
                let tag = stringAttribute(mark, "type") == "sup" ? "sup" : "sub"
                return "<\(tag)>\(result)</\(tag)>"
            case "link":
                let href = stringAttribute(mark, "href") ?? ""
                return "<a href=\"\(escapeHTMLAttribute(href))\">\(result)</a>"
            case "textColor":
                let color = stringAttribute(mark, "color") ?? "inherit"
                return "<span style=\"color:\(escapeHTMLAttribute(color))\">\(result)</span>"
            case "backgroundColor":
                let color = stringAttribute(mark, "color") ?? "transparent"
                return "<span style=\"background-color:\(escapeHTMLAttribute(color))\">\(result)</span>"
            case "fontSize":
                return "<small>\(result)</small>"
            case "annotation":
                let id = stringAttribute(mark, "id") ?? ""
                return "<span data-annotation-id=\"\(escapeHTMLAttribute(id))\">\(result)</span>"
            default:
                return result
            }
        }
    }

    private static func stringAttribute(
        _ object: [String: JSONValue],
        _ key: String
    ) -> String? {
        guard case .object(let attrs)? = object["attrs"],
              case .string(let value)? = attrs[key] else { return nil }
        return value
    }

    private static func intAttribute(
        _ object: [String: JSONValue],
        _ key: String,
        default fallback: Int
    ) -> Int {
        guard case .object(let attrs)? = object["attrs"],
              case .number(let value)? = attrs[key] else { return fallback }
        return Int(value)
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeHTMLAttribute(_ value: String) -> String {
        escapeHTML(value)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    // MARK: JSON bridges / string slicing

    private static func foundationObject(_ value: JSONValue) -> Any {
        switch value {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value
        case .string(let value): value
        case .array(let values): values.map(foundationObject)
        case .object(let values): values.mapValues(foundationObject)
        }
    }

    private static func characterSubstring(_ text: String, _ range: Range<Int>) -> String {
        guard
            let lower = text.index(text.startIndex, offsetBy: range.lowerBound, limitedBy: text.endIndex),
            let upper = text.index(text.startIndex, offsetBy: range.upperBound, limitedBy: text.endIndex)
        else { return "" }
        return String(text[lower..<upper])
    }

    private static func utf16Substring(_ text: String, _ range: Range<Int>) -> String {
        let value = text as NSString
        let lower = max(0, min(range.lowerBound, value.length))
        let upper = max(lower, min(range.upperBound, value.length))
        return value.substring(with: NSRange(location: lower, length: upper - lower))
    }
}
