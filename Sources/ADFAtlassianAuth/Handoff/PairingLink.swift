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
                return "This pairing code doesn't point to a Mac on your local network. Connect the phone and the Mac to the same Wi-Fi and run adf-auth push again."
            case .missingSession, .invalidSession, .missingKey, .invalidKey:
                return "This pairing code is incomplete or damaged. Run adf-auth push again."
            }
        }
    }

    /// Validates every part. The host must be a well-formed `a.b.c.d[:port]`
    /// IPv4 literal, but may be any range (Mac side, loopback tests). Phone
    /// side code must use ``init(url:)`` / ``init(string:)``, which also
    /// require a private local-network address.
    public init(host: String, sessionId: String, key: SymmetricKey) throws(ParseError) {
        guard Self.isValidHost(host) else { throw .invalidHost(host) }
        guard Data(base64URLEncoded: sessionId)?.count == Self.sessionIdBytes else { throw .invalidSession }
        guard key.bitCount == Self.keyBytes * 8 else { throw .invalidKey }
        self.host = host
        self.sessionId = sessionId
        self.key = key
    }

    /// Strict phone-side parse: scheme `adfreader`, host `pair`, no path,
    /// `v=1`, `h` and `s` each exactly once, fragment `k=<32-byte base64url
    /// key>`. `h` must be a private local-network IPv4 literal
    /// (``isLocalNetworkHost(_:)``: 10/8, 172.16/12, 192.168/16, 100.64/10),
    /// optionally with a port; anything else is ``ParseError/invalidHost(_:)``.
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
        guard Self.isLocalNetworkHost(host) else { throw .invalidHost(host) }
        guard let sessionId = try single("s"), !sessionId.isEmpty else { throw .missingSession }
        guard Data(base64URLEncoded: sessionId)?.count == Self.sessionIdBytes else { throw .invalidSession }

        guard let fragment = components.percentEncodedFragment, fragment.hasPrefix("k=") else { throw .missingKey }
        let encodedKey = String(fragment.dropFirst(2))
        guard !encodedKey.isEmpty else { throw .missingKey }
        guard var keyData = Data(base64URLEncoded: encodedKey) else { throw .invalidKey }
        defer { keyData.zeroize() }
        guard keyData.count == Self.keyBytes else { throw .invalidKey }

        self.host = host
        self.sessionId = sessionId
        self.key = SymmetricKey(data: keyData)
    }

    /// Parses a scanned or pasted string (surrounding whitespace is ignored).
    public init(string: String) throws(ParseError) {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw .notAPairingLink }
        try self.init(url: url)
    }

    /// Random session ID and key for `host` (`a.b.c.d:port`). Mac side.
    ///
    /// Accepts any host without checking it, so loopback links
    /// (`127.0.0.1:<port>`) can be generated for local testing — but the phone
    /// only accepts links whose host passes ``isLocalNetworkHost(_:)``, so such
    /// links won't parse there. If `host` is not a well-formed IPv4 literal,
    /// ``url`` and ``fetchURL`` are unusable placeholders (they never crash);
    /// check ``isValidHost(_:)`` first.
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
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.action
        components.percentEncodedQuery = "v=\(Self.version)&h=\(Self.strictEncode(host))&s=\(Self.strictEncode(sessionId))"
        components.percentEncodedFragment = "k=\(keyString)"
        return components.url ?? Self.unusableURL
    }

    /// `http://<host>/h/<sid>` — where the phone fetches the sealed box.
    /// Built from the parsed IPv4 octets and port, never by string pasting.
    public var fetchURL: URL {
        guard let address = Self.parseHost(host) else { return Self.unusableURL }
        var components = URLComponents()
        components.scheme = "http"
        components.host = address.octets.map(String.init).joined(separator: ".")
        components.port = address.port.map(Int.init)
        components.percentEncodedPath = "/h/" + Self.strictEncode(sessionId)
        return components.url ?? Self.unusableURL
    }

    /// The HTTP path the Mac serves: `/h/<sid>`.
    public var fetchPath: String { "/h/\(sessionId)" }

    /// Returned by ``url`` / ``fetchURL`` when the host is malformed (only
    /// possible via ``generate(host:)``). Not an HTTP URL, so fetching fails.
    static let unusableURL = URL(fileURLWithPath: "/dev/null/invalid-pairing-host")

    /// The key as base64url. The intermediate key bytes are zeroed.
    var keyString: String {
        var raw = key.withUnsafeBytes { Data($0) }
        defer { raw.zeroize() }
        return raw.base64URLEncodedString()
    }

    /// Percent-encodes everything except `A-Z a-z 0-9 - . _ ~ :`, so the
    /// result is always safe in a query, path or fragment.
    static func strictEncode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: strictAllowed) ?? ""
    }

    private static let strictAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:")

    public static func == (lhs: PairingLink, rhs: PairingLink) -> Bool {
        lhs.host == rhs.host && lhs.sessionId == rhs.sessionId && lhs.key == rhs.key
    }

    /// True for a well-formed `a.b.c.d` or `a.b.c.d:port`: exactly four
    /// ASCII-decimal octets 0...255 and an optional ASCII-decimal port
    /// 1...65535, with no signs, spaces or leading zeros (`010.0.0.1` and
    /// `:080` are rejected). Says nothing about the address range.
    public static func isValidHost(_ host: String) -> Bool {
        parseHost(host) != nil
    }

    /// True when `host` is a valid IPv4 literal (``isValidHost(_:)``) in a
    /// private local-network range: 10.0.0.0/8, 172.16.0.0/12,
    /// 192.168.0.0/16 or 100.64.0.0/10 (carrier-grade NAT / some hotspots).
    /// Loopback, link-local, multicast, `0.0.0.0/8` and public addresses are
    /// rejected.
    public static func isLocalNetworkHost(_ host: String) -> Bool {
        guard let octets = parseHost(host)?.octets else { return false }
        switch (octets[0], octets[1]) {
        case (10, _): return true
        case (172, 16...31): return true
        case (192, 168): return true
        case (100, 64...127): return true
        default: return false
        }
    }

    static func parseHost(_ host: String) -> (octets: [UInt8], port: UInt16?)? {
        let parts = host.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return nil }
        var port: UInt16?
        if parts.count == 2 {
            guard let value = strictDecimal(parts[1], max: 65_535), value >= 1 else { return nil }
            port = UInt16(value)
        }
        let octetTexts = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard octetTexts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for text in octetTexts {
            guard let value = strictDecimal(text, max: 255) else { return nil }
            octets.append(UInt8(value))
        }
        return (octets, port)
    }

    /// ASCII digits only, 1...5 of them, no leading zero (except "0"), ≤ max.
    private static func strictDecimal(_ text: Substring, max: Int) -> Int? {
        let bytes = Array(text.utf8)
        guard (1...5).contains(bytes.count), bytes.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        guard bytes.count == 1 || bytes[0] != 0x30 else { return nil }
        let value = bytes.reduce(0) { $0 * 10 + Int($1 - 0x30) }
        return value <= max ? value : nil
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
    /// Best-effort overwrite with zeros. Copies that Foundation or the
    /// network stack made elsewhere are not reached.
    mutating func zeroize() {
        guard !isEmpty else { return }
        resetBytes(in: startIndex..<endIndex)
    }

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
