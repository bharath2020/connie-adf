import Foundation

/// The first line of an HTTP/1.x request: `GET /h/abc HTTP/1.1`. Pure parsing
/// used by the handoff listener.
public struct HTTPRequestLine: Sendable, Equatable {
    /// The most the listener reads before giving up on a request head.
    public static let maxHeadBytes = 8 * 1024

    public let method: String
    public let target: String
    public let version: String

    public init(method: String, target: String, version: String) {
        self.method = method
        self.target = target
        self.version = version
    }

    /// The byte count up to and including the first `\r\n\r\n`, or nil when
    /// the head is not complete yet.
    public static func headLength(in buffer: Data) -> Int? {
        let terminator = Data("\r\n\r\n".utf8)
        guard let range = buffer.range(of: terminator) else { return nil }
        return buffer.distance(from: buffer.startIndex, to: range.upperBound)
    }

    /// Parses the request line from a request head (or any bytes that start
    /// with it). Strict: `METHOD SP origin-form-target SP HTTP/1.0|1.1 CRLF`,
    /// printable ASCII only. Returns nil for anything else.
    public static func parse(_ head: Data) -> HTTPRequestLine? {
        guard let lineEnd = head.range(of: Data("\r\n".utf8)) else { return nil }
        let lineBytes = head[head.startIndex..<lineEnd.lowerBound]
        guard !lineBytes.isEmpty, lineBytes.count <= maxHeadBytes,
              lineBytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else { return nil }
        let parts = String(decoding: lineBytes, as: UTF8.self).split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let method = String(parts[0])
        let target = String(parts[1])
        let version = String(parts[2])
        guard !method.isEmpty, method.utf8.allSatisfy({ $0 >= 0x41 && $0 <= 0x5A }) else { return nil }
        guard target.hasPrefix("/") else { return nil }
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else { return nil }
        return HTTPRequestLine(method: method, target: target, version: version)
    }
}
