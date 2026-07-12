/// Builds the typed `ADFNode` tree from raw `JSONValue`, assigning structural
/// path IDs and accumulating non-fatal `ADFParseIssue`s.
///
/// Recovery rules:
/// - Unknown node types → `.unknown(raw:)` + issue; the parse never fails.
/// - Unknown/malformed marks → dropped + issue.
/// - Missing required attrs → documented default + issue (heading level → 1,
///   panel type → info, unparseable date timestamp → 0, …).
/// - `bodiedSyncBlock` collapses into `.syncBlock`, `tableHeader` into
///   `.tableCell(isHeader: true)`, `nestedExpand` into `.expand(isNested: true)`.
struct ADFNodeBuilder {
    private(set) var issues: [ADFParseIssue] = []

    static func buildDocument(_ json: JSONValue) -> ADFDocument {
        var builder = ADFNodeBuilder()

        let version: Int
        if let value = json["version"]?.intValue {
            version = value
        } else {
            version = 1
            builder.issues.append(ADFParseIssue(path: "0", message: "Missing document 'version'; defaulting to 1"))
        }
        if json["type"]?.stringValue != "doc" {
            builder.issues.append(ADFParseIssue(path: "0", message: "Root node type is not 'doc'"))
        }

        let content = builder.children(json["content"], parentPath: "0")
        let root = ADFNode(id: "0", type: "doc", kind: .doc(content))
        return ADFDocument(version: version, root: root, issues: builder.issues)
    }

    // MARK: - Recursion

    private mutating func children(_ json: JSONValue?, parentPath: String) -> [ADFNode] {
        guard let items = json?.arrayValue else { return [] }
        return items.enumerated().map { index, item in
            node(item, path: "\(parentPath).\(index)")
        }
    }

    private mutating func node(_ json: JSONValue, path: String) -> ADFNode {
        guard let type = json["type"]?.stringValue else {
            issues.append(ADFParseIssue(path: path, message: "Node missing 'type'; captured as unknown"))
            return ADFNode(id: path, type: "", kind: .unknown(raw: json))
        }

        let attrs = json["attrs"]
        let kind: ADFNode.Kind

        switch type {
        case "doc":
            kind = .doc(children(json["content"], parentPath: path))

        case "paragraph":
            kind = .paragraph(content: children(json["content"], parentPath: path),
                              marks: marks(json["marks"], path: path))

        case "heading":
            let level: Int
            if let value = attrs?["level"]?.intValue {
                if (1...6).contains(value) {
                    level = value
                } else {
                    level = min(max(value, 1), 6)
                    issues.append(ADFParseIssue(path: path, message: "Heading level \(value) out of range 1...6; clamped to \(level)"))
                }
            } else {
                level = 1
                issues.append(ADFParseIssue(path: path, message: "Heading missing 'level'; defaulting to 1"))
            }
            kind = .heading(level: level,
                            content: children(json["content"], parentPath: path),
                            marks: marks(json["marks"], path: path))

        case "text":
            let text: String
            if let value = json["text"]?.stringValue {
                text = value
            } else {
                text = ""
                issues.append(ADFParseIssue(path: path, message: "Text node missing 'text'; defaulting to empty string"))
            }
            kind = .text(text, marks: marks(json["marks"], path: path))

        case "hardBreak":
            kind = .hardBreak

        case "blockquote":
            kind = .blockquote(children(json["content"], parentPath: path))

        case "bulletList":
            kind = .bulletList(children(json["content"], parentPath: path),
                               marks: marks(json["marks"], path: path))

        case "orderedList":
            kind = .orderedList(start: attrs?["order"]?.intValue ?? 1,
                                children(json["content"], parentPath: path),
                                marks: marks(json["marks"], path: path))

        case "listItem":
            kind = .listItem(children(json["content"], parentPath: path))

        case "codeBlock":
            let text = (json["content"]?.arrayValue ?? [])
                .compactMap { $0["text"]?.stringValue }
                .joined()
            kind = .codeBlock(language: attrs?["language"]?.stringValue,
                              text: text,
                              marks: marks(json["marks"], path: path))

        case "rule":
            kind = .rule

        case "panel":
            let panelType: ADFPanelType
            if let value = attrs?["panelType"]?.stringValue {
                if let parsed = ADFPanelType(rawValue: value) {
                    panelType = parsed
                } else {
                    panelType = .info
                    issues.append(ADFParseIssue(path: path, message: "Unrecognized panelType '\(value)'; defaulting to info"))
                }
            } else {
                panelType = .info
                issues.append(ADFParseIssue(path: path, message: "Panel missing 'panelType'; defaulting to info"))
            }
            kind = .panel(type: panelType,
                          icon: attrs?["panelIcon"]?.stringValue,
                          colorHex: attrs?["panelColor"]?.stringValue,
                          children(json["content"], parentPath: path))

        case "table":
            let tableAttrs = TableAttrs(isNumberColumnEnabled: attrs?["isNumberColumnEnabled"]?.boolValue ?? false,
                                        layout: attrs?["layout"]?.stringValue,
                                        displayMode: attrs?["displayMode"]?.stringValue)
            kind = .table(attrs: tableAttrs, rows: children(json["content"], parentPath: path))

        case "tableRow":
            kind = .tableRow(children(json["content"], parentPath: path))

        case "tableCell", "tableHeader":
            let cellAttrs = CellAttrs(colspan: attrs?["colspan"]?.intValue ?? 1,
                                      rowspan: attrs?["rowspan"]?.intValue ?? 1,
                                      colwidth: attrs?["colwidth"]?.arrayValue.map { $0.compactMap(\.doubleValue) },
                                      backgroundHex: attrs?["background"]?.stringValue,
                                      valign: attrs?["valign"]?.stringValue.flatMap(ADFVAlign.init(rawValue:)))
            kind = .tableCell(attrs: cellAttrs,
                              children(json["content"], parentPath: path),
                              isHeader: type == "tableHeader")

        case "expand", "nestedExpand":
            kind = .expand(title: attrs?["title"]?.stringValue ?? "",
                           children(json["content"], parentPath: path),
                           isNested: type == "nestedExpand",
                           marks: marks(json["marks"], path: path))

        case "mediaSingle":
            let layout: ADFMediaLayout
            if let value = attrs?["layout"]?.stringValue {
                if let parsed = ADFMediaLayout(rawValue: value) {
                    layout = parsed
                } else {
                    layout = .center
                    issues.append(ADFParseIssue(path: path, message: "Unrecognized mediaSingle layout '\(value)'; defaulting to center"))
                }
            } else {
                layout = .center
            }
            kind = .mediaSingle(layout: layout,
                                width: attrs?["width"]?.doubleValue,
                                widthType: attrs?["widthType"]?.stringValue.flatMap(ADFWidthType.init(rawValue:)),
                                children(json["content"], parentPath: path))

        case "mediaGroup":
            kind = .mediaGroup(children(json["content"], parentPath: path))

        case "media":
            kind = .media(mediaAttrs(attrs, path: path), marks: marks(json["marks"], path: path))

        case "mediaInline":
            kind = .mediaInline(mediaAttrs(attrs, path: path), marks: marks(json["marks"], path: path))

        case "caption":
            kind = .caption(children(json["content"], parentPath: path))

        case "taskList":
            kind = .taskList(children(json["content"], parentPath: path))

        case "taskItem":
            let state: ADFTaskState
            if let value = attrs?["state"]?.stringValue, let parsed = ADFTaskState(rawValue: value) {
                state = parsed
            } else {
                state = .todo
                issues.append(ADFParseIssue(path: path, message: "Task item missing or unrecognized 'state'; defaulting to TODO"))
            }
            kind = .taskItem(state: state, children(json["content"], parentPath: path))

        case "decisionList":
            kind = .decisionList(children(json["content"], parentPath: path))

        case "decisionItem":
            kind = .decisionItem(children(json["content"], parentPath: path))

        case "layoutSection":
            kind = .layoutSection(columns: children(json["content"], parentPath: path),
                                  marks: marks(json["marks"], path: path))

        case "layoutColumn":
            let width: Double
            if let value = attrs?["width"]?.doubleValue {
                width = value
            } else {
                width = 100
                issues.append(ADFParseIssue(path: path, message: "Layout column missing 'width'; defaulting to 100"))
            }
            kind = .layoutColumn(width: width, children(json["content"], parentPath: path))

        case "blockCard":
            kind = .blockCard(url: attrs?["url"]?.stringValue, data: attrs?["data"])

        case "embedCard":
            let url: String
            if let value = attrs?["url"]?.stringValue {
                url = value
            } else {
                url = ""
                issues.append(ADFParseIssue(path: path, message: "Embed card missing 'url'"))
            }
            let layout = attrs?["layout"]?.stringValue.flatMap(ADFMediaLayout.init(rawValue:)) ?? .center
            kind = .embedCard(url: url, layout: layout, width: attrs?["width"]?.doubleValue)

        case "inlineCard":
            kind = .inlineCard(url: attrs?["url"]?.stringValue, data: attrs?["data"])

        case "mention":
            let id: String
            if let value = attrs?["id"]?.stringValue {
                id = value
            } else {
                id = ""
                issues.append(ADFParseIssue(path: path, message: "Mention missing 'id'"))
            }
            kind = .mention(id: id,
                            text: attrs?["text"]?.stringValue ?? "",
                            accessLevel: attrs?["accessLevel"]?.stringValue)

        case "emoji":
            let shortName: String
            if let value = attrs?["shortName"]?.stringValue {
                shortName = value
            } else {
                shortName = ""
                issues.append(ADFParseIssue(path: path, message: "Emoji missing 'shortName'"))
            }
            kind = .emoji(
                shortName: shortName,
                text: Self.normalizedEmojiText(
                    text: attrs?["text"]?.stringValue,
                    id: attrs?["id"]?.stringValue
                )
            )

        case "date":
            // Schema: `timestamp` is a STRING of epoch milliseconds.
            let timestampMS: Double
            if let string = attrs?["timestamp"]?.stringValue {
                if let parsed = Double(string) {
                    timestampMS = parsed
                } else {
                    timestampMS = 0
                    issues.append(ADFParseIssue(path: path, message: "Unparseable date timestamp '\(string)'; defaulting to 0"))
                }
            } else if let number = attrs?["timestamp"]?.doubleValue {
                // Lenient: some producers emit a JSON number.
                timestampMS = number
            } else {
                timestampMS = 0
                issues.append(ADFParseIssue(path: path, message: "Date missing 'timestamp'; defaulting to 0"))
            }
            kind = .date(timestampMS: timestampMS)

        case "status":
            let text: String
            if let value = attrs?["text"]?.stringValue {
                text = value
            } else {
                text = ""
                issues.append(ADFParseIssue(path: path, message: "Status missing 'text'"))
            }
            let color: ADFStatusColor
            if let value = attrs?["color"]?.stringValue, let parsed = ADFStatusColor(rawValue: value) {
                color = parsed
            } else {
                color = .neutral
                issues.append(ADFParseIssue(path: path, message: "Status missing or unrecognized 'color'; defaulting to neutral"))
            }
            kind = .status(text: text, color: color)

        case "placeholder":
            let text: String
            if let value = attrs?["text"]?.stringValue {
                text = value
            } else {
                text = ""
                issues.append(ADFParseIssue(path: path, message: "Placeholder missing 'text'"))
            }
            kind = .placeholder(text: text)

        case "extension":
            kind = .adfExtension(extensionAttrs(attrs, path: path), marks: marks(json["marks"], path: path))

        case "bodiedExtension":
            kind = .bodiedExtension(extensionAttrs(attrs, path: path),
                                    children(json["content"], parentPath: path),
                                    marks: marks(json["marks"], path: path))

        case "inlineExtension":
            kind = .inlineExtension(extensionAttrs(attrs, path: path), marks: marks(json["marks"], path: path))

        case "syncBlock", "bodiedSyncBlock":
            kind = .syncBlock(resourceId: attrs?["resourceId"]?.stringValue,
                              children(json["content"], parentPath: path))

        default:
            issues.append(ADFParseIssue(path: path, message: "Unknown node type '\(type)'; captured as unknown"))
            kind = .unknown(raw: json)
        }

        return ADFNode(id: path, type: type, kind: kind)
    }

    // MARK: - Shared attribute parsing

    private mutating func marks(_ json: JSONValue?, path: String) -> [ADFMark] {
        guard let items = json?.arrayValue else { return [] }
        var result: [ADFMark] = []
        result.reserveCapacity(items.count)
        for item in items {
            if let mark = ADFMark.parse(item) {
                result.append(mark)
            } else {
                let name = item["type"]?.stringValue ?? "<missing type>"
                issues.append(ADFParseIssue(path: path, message: "Dropped unsupported or malformed mark '\(name)'"))
            }
        }
        return result
    }

    private mutating func mediaAttrs(_ attrs: JSONValue?, path: String) -> MediaAttrs {
        let typeString = attrs?["type"]?.stringValue
        let source: MediaAttrs.Source
        if typeString == "external" || (typeString == nil && attrs?["url"] != nil) {
            if let url = attrs?["url"]?.stringValue {
                source = .external(url: url)
            } else {
                source = .external(url: "")
                issues.append(ADFParseIssue(path: path, message: "External media missing 'url'"))
            }
        } else {
            if let id = attrs?["id"]?.stringValue {
                source = .file(id: id, collection: attrs?["collection"]?.stringValue ?? "")
            } else {
                source = .file(id: "", collection: "")
                issues.append(ADFParseIssue(path: path, message: "File media missing 'id'"))
            }
        }
        return MediaAttrs(source: source,
                          width: attrs?["width"]?.doubleValue,
                          height: attrs?["height"]?.doubleValue,
                          alt: attrs?["alt"]?.stringValue,
                          mediaType: typeString)
    }

    private mutating func extensionAttrs(_ attrs: JSONValue?, path: String) -> ExtensionAttrs {
        let extensionType: String
        if let value = attrs?["extensionType"]?.stringValue {
            extensionType = value
        } else {
            extensionType = ""
            issues.append(ADFParseIssue(path: path, message: "Extension missing 'extensionType'"))
        }
        let extensionKey: String
        if let value = attrs?["extensionKey"]?.stringValue {
            extensionKey = value
        } else {
            extensionKey = ""
            issues.append(ADFParseIssue(path: path, message: "Extension missing 'extensionKey'"))
        }
        return ExtensionAttrs(extensionType: extensionType,
                              extensionKey: extensionKey,
                              text: attrs?["text"]?.stringValue,
                              parameters: attrs?["parameters"])
    }

    // MARK: - Emoji text normalization

    /// Confluence Cloud's atlas_doc_format delivers emoji `text` as literal
    /// `\uXXXX` escape text (the backslash survives JSON decoding), with the
    /// character's hex codepoints in `id` (dash-separated for ZWJ sequences).
    private static func normalizedEmojiText(text: String?, id: String?) -> String? {
        if let text, text.isEmpty == false {
            return decodingUnicodeEscapes(text)
        }
        if let id, let fromId = emojiString(hexCodepoints: id) {
            return fromId
        }
        return nil
    }

    /// Decodes literal `\uXXXX` sequences, pairing UTF-16 surrogates.
    private static func decodingUnicodeEscapes(_ string: String) -> String {
        guard string.contains("\\u") else { return string }
        var units: [UInt16] = []
        var result = ""
        var index = string.startIndex
        func flushUnits() {
            guard units.isEmpty == false else { return }
            result += String(decoding: units, as: UTF16.self)
            units.removeAll()
        }
        while index < string.endIndex {
            if string[index] == "\\",
               let end = string.index(index, offsetBy: 6, limitedBy: string.endIndex),
               string[string.index(after: index)] == "u",
               let unit = UInt16(string[string.index(index, offsetBy: 2)..<end], radix: 16) {
                units.append(unit)
                index = end
            } else {
                flushUnits()
                result.append(string[index])
                index = string.index(after: index)
            }
        }
        flushUnits()
        return result
    }

    /// "1f5d3" or "1f468-200d-1f4bb" → the character; nil for non-hex ids
    /// (custom workspace emojis), which fall back to the `:shortName:` atom.
    private static func emojiString(hexCodepoints id: String) -> String? {
        let parts = id.split(separator: "-")
        let scalars = parts.compactMap { UInt32($0, radix: 16).flatMap(Unicode.Scalar.init) }
        guard parts.isEmpty == false, scalars.count == parts.count else { return nil }
        return String(String.UnicodeScalarView(scalars))
    }
}
