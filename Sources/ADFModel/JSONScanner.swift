import Foundation

/// A minimal, fast UTF-8 JSON scanner producing `JSONValue` directly.
///
/// `JSONSerialization` plus the `JSONValue(jsonObject:)` bridge walks every
/// value twice and pays Objective-C boxing/bridging costs on each — ~100 ms
/// for a 2 MB document in Release. Scanning the raw bytes once is ~4× faster,
/// which is what keeps `ADFDocumentModel`'s first-chunk latency inside the
/// §8 budget on large documents. `ADFParser` falls back to the
/// `JSONSerialization` path whenever this scanner throws, so a scanner
/// limitation can never regress document acceptance.
enum JSONScanner {
    struct SyntaxError: Error, Sendable {
        let offset: Int
        let message: String
    }

    /// Nesting guard: deeper documents fall back to `JSONSerialization`
    /// rather than risking recursion past the stack.
    private static let maximumDepth = 512

    static func scan(_ data: Data) throws -> JSONValue {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> JSONValue in
            var parser = Parser(bytes: buffer.bindMemory(to: UInt8.self))
            parser.skipWhitespace()
            let value = try parser.parseValue(depth: 0)
            parser.skipWhitespace()
            guard parser.isAtEnd else {
                throw parser.error("unexpected trailing content")
            }
            return value
        }
    }

    private struct Parser {
        let bytes: UnsafeBufferPointer<UInt8>
        var index = 0

        var isAtEnd: Bool { index >= bytes.count }

        func error(_ message: String) -> SyntaxError {
            SyntaxError(offset: index, message: message)
        }

        mutating func skipWhitespace() {
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0A, 0x0D:
                    index += 1
                default:
                    return
                }
            }
        }

        mutating func parseValue(depth: Int) throws -> JSONValue {
            guard depth < JSONScanner.maximumDepth else {
                throw error("nesting too deep")
            }
            guard index < bytes.count else {
                throw error("unexpected end of input")
            }
            switch bytes[index] {
            case UInt8(ascii: "{"):
                return try parseObject(depth: depth)
            case UInt8(ascii: "["):
                return try parseArray(depth: depth)
            case UInt8(ascii: "\""):
                return .string(try parseString())
            case UInt8(ascii: "t"):
                try expectLiteral("true")
                return .bool(true)
            case UInt8(ascii: "f"):
                try expectLiteral("false")
                return .bool(false)
            case UInt8(ascii: "n"):
                try expectLiteral("null")
                return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                return .number(try parseNumber())
            default:
                throw error("unexpected character")
            }
        }

        mutating func expectLiteral(_ literal: StaticString) throws {
            let count = literal.utf8CodeUnitCount
            guard index + count <= bytes.count else {
                throw error("unexpected end of input")
            }
            let matches = literal.withUTF8Buffer { expected in
                for offset in 0..<count where bytes[index + offset] != expected[offset] {
                    return false
                }
                return true
            }
            guard matches else {
                throw error("malformed literal")
            }
            index += count
        }

        mutating func parseObject(depth: Int) throws -> JSONValue {
            index += 1 // consume "{"
            var members: [String: JSONValue] = [:]
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(members)
            }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
                    throw error("expected object key")
                }
                let key = try parseString()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else {
                    throw error("expected ':' after object key")
                }
                index += 1
                skipWhitespace()
                members[key] = try parseValue(depth: depth + 1)
                skipWhitespace()
                guard index < bytes.count else {
                    throw error("unterminated object")
                }
                switch bytes[index] {
                case UInt8(ascii: ","):
                    index += 1
                case UInt8(ascii: "}"):
                    index += 1
                    return .object(members)
                default:
                    throw error("expected ',' or '}' in object")
                }
            }
        }

        mutating func parseArray(depth: Int) throws -> JSONValue {
            index += 1 // consume "["
            var values: [JSONValue] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(values)
            }
            while true {
                skipWhitespace()
                values.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                guard index < bytes.count else {
                    throw error("unterminated array")
                }
                switch bytes[index] {
                case UInt8(ascii: ","):
                    index += 1
                case UInt8(ascii: "]"):
                    index += 1
                    return .array(values)
                default:
                    throw error("expected ',' or ']' in array")
                }
            }
        }

        mutating func parseString() throws -> String {
            index += 1 // consume opening quote
            let start = index
            // Fast path: no escapes — decode the byte run directly.
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    let slice = UnsafeBufferPointer(rebasing: bytes[start..<index])
                    index += 1
                    return String(decoding: slice, as: UTF8.self)
                }
                if byte == UInt8(ascii: "\\") || byte < 0x20 {
                    break
                }
                index += 1
            }
            guard index < bytes.count, bytes[index] != UInt8(ascii: "\"") else {
                throw error("unterminated string")
            }
            // Slow path: copy what we have, then decode escapes.
            var utf8: [UInt8] = Array(bytes[start..<index])
            utf8.reserveCapacity((index - start) + 16)
            while index < bytes.count {
                let byte = bytes[index]
                switch byte {
                case UInt8(ascii: "\""):
                    index += 1
                    return String(decoding: utf8, as: UTF8.self)
                case UInt8(ascii: "\\"):
                    index += 1
                    try appendEscape(to: &utf8)
                case 0..<0x20:
                    throw error("unescaped control character in string")
                default:
                    utf8.append(byte)
                    index += 1
                }
            }
            throw error("unterminated string")
        }

        private mutating func appendEscape(to utf8: inout [UInt8]) throws {
            guard index < bytes.count else {
                throw error("unterminated escape")
            }
            let byte = bytes[index]
            index += 1
            switch byte {
            case UInt8(ascii: "\""): utf8.append(UInt8(ascii: "\""))
            case UInt8(ascii: "\\"): utf8.append(UInt8(ascii: "\\"))
            case UInt8(ascii: "/"): utf8.append(UInt8(ascii: "/"))
            case UInt8(ascii: "b"): utf8.append(0x08)
            case UInt8(ascii: "f"): utf8.append(0x0C)
            case UInt8(ascii: "n"): utf8.append(0x0A)
            case UInt8(ascii: "r"): utf8.append(0x0D)
            case UInt8(ascii: "t"): utf8.append(0x09)
            case UInt8(ascii: "u"):
                let unit = try parseHexUnit()
                var scalarValue = UInt32(unit)
                if unit >= 0xD800, unit <= 0xDBFF {
                    // High surrogate: a low surrogate escape must follow.
                    guard index + 1 < bytes.count,
                          bytes[index] == UInt8(ascii: "\\"),
                          bytes[index + 1] == UInt8(ascii: "u") else {
                        throw error("unpaired surrogate")
                    }
                    index += 2
                    let low = try parseHexUnit()
                    guard low >= 0xDC00, low <= 0xDFFF else {
                        throw error("invalid low surrogate")
                    }
                    scalarValue = 0x10000
                        + (UInt32(unit) - 0xD800) << 10
                        + (UInt32(low) - 0xDC00)
                } else if unit >= 0xDC00, unit <= 0xDFFF {
                    throw error("unpaired surrogate")
                }
                guard let scalar = Unicode.Scalar(scalarValue),
                      let encoded = UTF8.encode(scalar) else {
                    throw error("invalid unicode escape")
                }
                utf8.append(contentsOf: encoded)
            default:
                throw error("invalid escape character")
            }
        }

        private mutating func parseHexUnit() throws -> UInt16 {
            guard index + 4 <= bytes.count else {
                throw error("truncated unicode escape")
            }
            var unit: UInt16 = 0
            for _ in 0..<4 {
                let byte = bytes[index]
                let digit: UInt16
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"):
                    digit = UInt16(byte - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"):
                    digit = UInt16(byte - UInt8(ascii: "a") + 10)
                case UInt8(ascii: "A")...UInt8(ascii: "F"):
                    digit = UInt16(byte - UInt8(ascii: "A") + 10)
                default:
                    throw error("invalid hex digit in unicode escape")
                }
                unit = unit << 4 | digit
                index += 1
            }
            return unit
        }

        mutating func parseNumber() throws -> Double {
            let start = index
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") {
                index += 1
            }
            var integerDigits = 0
            while index < bytes.count, isDigit(bytes[index]) {
                index += 1
                integerDigits += 1
            }
            guard integerDigits > 0 else {
                throw error("malformed number")
            }
            // JSON forbids leading zeros ("01"); keep strictness so the
            // fallback path stays authoritative for malformed input.
            if integerDigits > 1, bytes[start] == UInt8(ascii: "0")
                || (bytes[start] == UInt8(ascii: "-") && bytes[start + 1] == UInt8(ascii: "0")) {
                throw error("leading zero in number")
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                var fractionDigits = 0
                while index < bytes.count, isDigit(bytes[index]) {
                    index += 1
                    fractionDigits += 1
                }
                guard fractionDigits > 0 else {
                    throw error("malformed number fraction")
                }
            }
            if index < bytes.count,
               bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count,
                   bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                    index += 1
                }
                var exponentDigits = 0
                while index < bytes.count, isDigit(bytes[index]) {
                    index += 1
                    exponentDigits += 1
                }
                guard exponentDigits > 0 else {
                    throw error("malformed number exponent")
                }
            }
            let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self)
            guard let value = Double(text) else {
                throw error("unrepresentable number")
            }
            return value
        }

        private func isDigit(_ byte: UInt8) -> Bool {
            byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
        }
    }
}
