/// A formatting mark applied to an ADF node (schema `@atlaskit/adf-schema@56.1.3`).
///
/// Unknown marks parse to `nil` and are dropped by the builder (with an
/// `ADFParseIssue`) — a mark that cannot be rendered is safer to ignore than
/// a node.
public enum ADFMark: Sendable, Hashable {
    case strong, em, underline, strike, code
    case subsup(isSup: Bool)
    case textColor(hex: String)
    case backgroundColor(hex: String)
    /// The only schema-legal value is `"small"`.
    case fontSize(String)
    case link(href: String, title: String?)
    case alignment(ADFAlignment)
    /// Level is clamped to the schema range `1...6`.
    case indentation(level: Int)
    case breakout(mode: ADFBreakoutMode, width: Double?)
    case border(size: Double, colorHex: String)
    case annotation(id: String, annotationType: String)
    case dataConsumer, fragment

    /// Parses one mark object; `nil` means unknown/malformed → caller drops it
    /// and records an issue.
    static func parse(_ json: JSONValue) -> ADFMark? {
        guard let type = json["type"]?.stringValue else { return nil }
        let attrs = json["attrs"]
        switch type {
        case "strong": return .strong
        case "em": return .em
        case "underline": return .underline
        case "strike": return .strike
        case "code": return .code
        case "subsup":
            guard let variant = attrs?["type"]?.stringValue, variant == "sub" || variant == "sup" else { return nil }
            return .subsup(isSup: variant == "sup")
        case "textColor":
            guard let color = attrs?["color"]?.stringValue else { return nil }
            return .textColor(hex: color)
        case "backgroundColor":
            guard let color = attrs?["color"]?.stringValue else { return nil }
            return .backgroundColor(hex: color)
        case "fontSize":
            guard let size = attrs?["size"]?.stringValue else { return nil }
            return .fontSize(size)
        case "link":
            guard let href = attrs?["href"]?.stringValue else { return nil }
            return .link(href: href, title: attrs?["title"]?.stringValue)
        case "alignment":
            guard let align = attrs?["align"]?.stringValue,
                  let alignment = ADFAlignment(rawValue: align) else { return nil }
            return .alignment(alignment)
        case "indentation":
            guard let level = attrs?["level"]?.intValue else { return nil }
            return .indentation(level: min(max(level, 1), 6))
        case "breakout":
            guard let modeString = attrs?["mode"]?.stringValue,
                  let mode = ADFBreakoutMode(rawValue: modeString) else { return nil }
            return .breakout(mode: mode, width: attrs?["width"]?.doubleValue)
        case "border":
            guard let size = attrs?["size"]?.doubleValue,
                  let color = attrs?["color"]?.stringValue else { return nil }
            return .border(size: size, colorHex: color)
        case "annotation":
            guard let id = attrs?["id"]?.stringValue else { return nil }
            return .annotation(id: id, annotationType: attrs?["annotationType"]?.stringValue ?? "inlineComment")
        case "dataConsumer": return .dataConsumer
        case "fragment": return .fragment
        default: return nil
        }
    }
}
