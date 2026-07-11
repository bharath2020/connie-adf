import Foundation

/// A lightweight, `Sendable` representation of arbitrary JSON.
///
/// Used to preserve the raw payload of unknown ADF nodes and to feed the
/// node builder without round-tripping through `Codable`.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue {
    /// Thrown when `init(jsonObject:)` meets a value that is not part of the
    /// JSON object model produced by `JSONSerialization`.
    public struct UnsupportedTypeError: Error, Sendable {
        public let typeDescription: String
        public init(typeDescription: String) {
            self.typeDescription = typeDescription
        }
    }

    /// Bridges a `JSONSerialization.jsonObject(with:)` result into `JSONValue`.
    public init(jsonObject: Any) throws {
        switch jsonObject {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(try array.map { try JSONValue(jsonObject: $0) })
        case let object as [String: Any]:
            self = .object(try object.mapValues { try JSONValue(jsonObject: $0) })
        default:
            throw UnsupportedTypeError(typeDescription: String(describing: type(of: jsonObject)))
        }
    }

    /// Object member lookup; `nil` when the value is not an object or the key
    /// is absent.
    public subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members[key]
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var doubleValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    /// The exact integer for integral numbers; `nil` for fractional values.
    public var intValue: Int? {
        guard case .number(let value) = self else { return nil }
        return Int(exactly: value)
    }

    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    public var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }
}
