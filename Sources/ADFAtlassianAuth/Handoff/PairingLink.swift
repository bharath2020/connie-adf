import CryptoKit
import Foundation

/// The QR payload for a one-time Mac → phone handoff:
/// `adfreader://pair?v=1&h=<ipv4:port>&s=<sid>#k=<key>`.
///
/// It never contains the token: `s` names the sealed box on the Mac's
/// listener and `k` is the one-time key that opens it. `description`,
/// `debugDescription` and the mirror redact both.
public struct PairingLink: Sendable, Equatable {
    public static let scheme = "adfreader"
    public static let action = "pair"
    public static let version = "1"
    static let sessionIdBytes = 16
    static let keyBytes = 32

    /// `a.b.c.d` or `a.b.c.d:port`.
    public let host: String
    /// 16 random bytes, base64url without padding.
    public let sessionId: String
    /// 32 random bytes.
    public let key: SymmetricKey

    /// Why a pairing link was rejected.
    public enum ParseError: Error, Sendable, Equatable {
        case notAPairingLink
        case unsupportedVersion(String?)
        case missingHost
        case invalidHost(String)
        case missingSession
        case invalidSession
        case missingKey
        case invalidKey

        public var message: String {
            switch self {
            case .notAPairingLink:
                return "This isn't an ADFReader pairing code. On your Mac run: adf-auth push"
            case .unsupportedVersion:
                return "This pairing code comes from a different version of adf-auth. Update ADFReader and adf-auth."
            case .missingHost, .invalidHost:
                return "This pairing code has no valid Mac address. Run adf-auth push again."
            case .missingSession, .invalidSession, .missingKey, .invalidKey:
                return "This pairing code is incomplete or damaged. Run adf-auth push again."
            }
        }
    }

    /// Validates every part.
    public init(host: String, sessionId: String, key: SymmetricKey) throws(ParseError) {
        guard Self.isValidHost(host) else { throw .invalidHost(host) }
        guard Data(base64URLEncoded: sessionId)?.count == Self.sessionIdBytes else { throw .invalidSession }
        guard key.bitCount == Self.keyBytes * 8 else { throw .invalidKey }
        self.host = host
        self.sessionId = sessionId
        self.key = key
    }

    /// Strict parse: scheme `adfreader`, host `pair`, no path, `v=1`, `h` and
    /// `s` each exactly once, fragment `k=<32-byte base64url key>`.
    public init(url: URL) throws(ParseError) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == Self.scheme,
              components.host?.lowercased() == Self.action,
              components.path.isEmpty || components.path == "/",
              components.user == nil, components.password == nil, components.port == nil
        else { throw .notAPairingLink }

        let items = components.queryItems ?? []
        func single(_ name: String) throws(ParseError) -> String? {
            let matches = items.filter { $0.name == name }
            guard matches.count <= 1 else { throw .notAPairingLink }
            return matches.first?.value
        }
        let version = try single("v")
        guard version == Self.version else { throw .unsupportedVersion(version) }
        guard let host = try single("h"), !host.isEmpty else { throw .missingHost }
        guard Self.isValidHost(host) else { throw .invalidHost(host) }
        guard let sessionId = try single("s"), !sessionId.isEmpty else { throw .missingSession }
        guard Data(base64URLEncoded: sessionId)?.count == Self.sessionIdBytes else { throw .invalidSession }

        guard let fragment = components.percentEncodedFragment, fragment.hasPrefix("k=") else { throw .missingKey }
        let encodedKey = String(fragment.dropFirst(2))
        guard !encodedKey.isEmpty else { throw .missingKey }
        guard let keyData = Data(base64URLEncoded: encodedKey), keyData.count == Self.keyBytes else { throw .invalidKey }

        self.host = host
        self.sessionId = sessionId
        self.key = SymmetricKey(data: keyData)
    }

    /// Parses a scanned or pasted string (surrounding whitespace is ignored).
    public init(string: String) throws(ParseError) {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw .notAPairingLink }
        try self.init(url: url)
    }

    /// Random session ID and key for `host` (`a.b.c.d:port`).
    public static func generate(host: String) -> PairingLink {
        var generator = SystemRandomNumberGenerator()
        let sid = Data((0..<sessionIdBytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        return PairingLink(uncheckedHost: host, sessionId: sid.base64URLEncodedString(), key: SymmetricKey(size: .bits256))
    }

    private init(uncheckedHost: String, sessionId: String, key: SymmetricKey) {
        self.host = uncheckedHost
        self.sessionId = sessionId
        self.key = key
    }

    /// The QR payload. Secret: do not log it.
    public var url: URL {
        URL(string: "\(Self.scheme)://\(Self.action)?v=\(Self.version)&h=\(host)&s=\(sessionId)#k=\(keyString)")!
    }

    /// `http://<host>/h/<sid>` — where the phone fetches the sealed box.
    public var fetchURL: URL {
        URL(string: "http://\(host)/h/\(sessionId)")!
    }

    /// The HTTP path the Mac serves: `/h/<sid>`.
    public var fetchPath: String { "/h/\(sessionId)" }

    var keyString: String {
        key.withUnsafeBytes { Data($0) }.base64URLEncodedString()
    }

    public static func == (lhs: PairingLink, rhs: PairingLink) -> Bool {
        lhs.host == rhs.host && lhs.sessionId == rhs.sessionId && lhs.key == rhs.key
    }

    /// `a.b.c.d` or `a.b.c.d:port` with decimal octets 0...255 and port 1...65535.
    static func isValidHost(_ host: String) -> Bool {
        let parts = host.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return false }
        if parts.count == 2 {
            guard let port = Int(parts[1]), (1...65_535).contains(port), parts[1].allSatisfy(\.isASCII) else { return false }
        }
        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { octet in
            guard (1...3).contains(octet.count), octet.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(octet) else { return false }
            return value <= 255
        }
    }
}

extension PairingLink: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "PairingLink(host: \(host), sessionId: \(Redaction.placeholder), key: \(Redaction.placeholder))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["host": host, "sessionId": Redaction.placeholder, "key": Redaction.placeholder], displayStyle: .struct)
    }
}

extension Data {
    /// Base64url without padding (RFC 4648 §5).
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Strict base64url: only `A-Z a-z 0-9 - _`, no padding.
    init?(base64URLEncoded string: String) {
        guard !string.isEmpty, string.utf8.allSatisfy({ byte in
            (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39) || byte == 0x2D || byte == 0x5F
        }) else { return nil }
        guard string.count % 4 != 1 else { return nil }
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
