import CryptoKit
import Foundation

/// The one-time code ADFReader shows for a "Mac connects to phone" handoff:
/// 80 random bits as 16 Crockford base32 symbols in four groups,
/// `XXXX-XXXX-XXXX-XXXX`.
///
/// The person types it into `adf-auth push --to`. It is never sent over
/// the network: both sides only use it as the key of the handshake MAC and
/// as the HKDF salt of the sealing key (see `docs/Atlassian-Auth.md`).
/// `description`, `debugDescription` and the mirror redact it; show it
/// with ``formatted``.
public struct PhonePairingCode: Sendable, Equatable {
    /// 80 bits.
    public static let byteCount = 10
    /// 16 symbols of 5 bits.
    public static let symbolCount = 16
    /// Crockford base32: digits and letters without I, L, O and U.
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)

    /// The 10 secret bytes. `SymmetricKey` compares in constant time.
    let key: SymmetricKey

    /// Why typed code text was rejected. The messages never repeat the input.
    public enum ParseError: Error, Sendable, Equatable {
        case empty
        /// A character that is not a Crockford base32 symbol (U, punctuation…).
        case invalidCharacter
        /// The number of symbols, when it isn't 16.
        case wrongLength(Int)

        public var message: String {
            switch self {
            case .empty:
                return "Enter the code shown on your phone (XXXX-XXXX-XXXX-XXXX)."
            case .invalidCharacter:
                return "That code has a character ADFReader codes never use. Codes have digits and letters (no U); type it exactly as shown on the phone."
            case .wrongLength(let count):
                return "That code has \(count) characters; the code on your phone has 16 (XXXX-XXXX-XXXX-XXXX)."
            }
        }
    }

    /// A fresh random code from the system CSPRNG.
    public static func generate() -> PhonePairingCode {
        PhonePairingCode(key: SymmetricKey(size: SymmetricKeySize(bitCount: byteCount * 8)))
    }

    /// Exactly ``byteCount`` bytes (tests and known-answer vectors).
    init?(bytes: Data) {
        guard bytes.count == Self.byteCount else { return nil }
        self.key = SymmetricKey(data: bytes)
    }

    private init(key: SymmetricKey) {
        self.key = key
    }

    /// Parses typed text: case-insensitive; `-` and whitespace are ignored;
    /// Crockford aliases `I`/`L` → `1` and `O` → `0`; anything else outside
    /// the alphabet (including `U`) is rejected; exactly 16 symbols.
    public init(parsing text: String) throws(ParseError) {
        var values: [UInt8] = []
        values.reserveCapacity(Self.symbolCount)
        for scalar in text.unicodeScalars {
            if scalar == "-" || CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            guard let value = Self.symbolValue(scalar) else { throw .invalidCharacter }
            values.append(value)
        }
        guard !values.isEmpty else { throw .empty }
        guard values.count == Self.symbolCount else { throw .wrongLength(values.count) }

        var bytes = Data(count: Self.byteCount)
        defer { bytes.zeroize() }
        // 16 × 5 bits = 80 bits = 10 bytes, most significant bit first.
        var accumulator: UInt32 = 0
        var bits = 0
        var index = bytes.startIndex
        for value in values {
            accumulator = (accumulator << 5) | UInt32(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes[index] = UInt8(truncatingIfNeeded: accumulator >> UInt32(bits))
                index += 1
            }
        }
        values.withUnsafeMutableBufferPointer { buffer in
            for position in buffer.indices { buffer[position] = 0 }
        }
        self.key = SymmetricKey(data: bytes)
    }

    /// `XXXX-XXXX-XXXX-XXXX`. Secret: show it on screen, never log it.
    public var formatted: String {
        var symbols: [UInt8] = []
        symbols.reserveCapacity(Self.symbolCount + 3)
        key.withUnsafeBytes { raw in
            var accumulator: UInt32 = 0
            var bits = 0
            for byte in raw {
                accumulator = (accumulator << 8) | UInt32(byte)
                bits += 8
                while bits >= 5 {
                    bits -= 5
                    if !symbols.isEmpty, (symbols.count + 1) % 5 == 0 { symbols.append(0x2D) }
                    symbols.append(Self.alphabet[Int((accumulator >> UInt32(bits)) & 0x1F)])
                }
            }
        }
        return String(decoding: symbols, as: UTF8.self)
    }

    /// The raw secret bytes, for the HKDF salt. Zeroize the copy after use.
    var bytes: Data {
        key.withUnsafeBytes { Data($0) }
    }

    private static func symbolValue(_ scalar: Unicode.Scalar) -> UInt8? {
        guard scalar.isASCII else { return nil }
        var byte = UInt8(scalar.value)
        if byte >= 0x61, byte <= 0x7A { byte -= 0x20 } // a-z → A-Z
        switch byte {
        case 0x49, 0x4C: byte = 0x31 // I, L → 1
        case 0x4F: byte = 0x30 // O → 0
        default: break
        }
        guard let index = alphabet.firstIndex(of: byte) else { return nil }
        return UInt8(index)
    }
}

extension PhonePairingCode: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "PhonePairingCode(\(Redaction.placeholder))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["code": Redaction.placeholder], displayStyle: .struct)
    }
}

/// Where the phone listens: a private local-network IPv4 address and port,
/// typed as `a.b.c.d:port` (`adf-auth push --to 192.168.1.23:53211`).
public struct PhoneHandoffAddress: Sendable, Equatable, CustomStringConvertible {
    /// `a.b.c.d`.
    public let host: String
    public let port: UInt16

    /// Why an address was rejected.
    public enum ParseError: Error, Sendable, Equatable {
        case malformed
        case missingPort
        /// Loopback, link-local, public, … — not a phone on this network.
        case notLocalNetwork

        public var message: String {
            switch self {
            case .malformed:
                return "That isn't an address like 192.168.1.23:53211. Type it exactly as the phone shows it."
            case .missingPort:
                return "The address needs the port the phone shows, for example 192.168.1.23:53211."
            case .notLocalNetwork:
                return "That address isn't on a local network (10/8, 172.16/12, 192.168/16, 100.64/10). Type the address the phone shows, with the phone and the Mac on the same Wi-Fi."
            }
        }
    }

    /// Strict parse of `a.b.c.d:port`: an IPv4 literal (no leading zeros)
    /// in a private local-network range (``PairingLink/isLocalNetworkHost(_:)``)
    /// and a port 1...65535. Surrounding whitespace is ignored. IPv6, host
    /// names, loopback and public addresses are rejected.
    public init(parsing text: String) throws(ParseError) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = PairingLink.parseHost(trimmed) else { throw .malformed }
        guard let port = parsed.port else { throw .missingPort }
        guard PairingLink.isLocalNetworkHost(trimmed) else { throw .notLocalNetwork }
        self.host = parsed.octets.map(String.init).joined(separator: ".")
        self.port = port
    }

    /// A private local-network `host` and a port 1...65535, or nil.
    public init?(host: String, port: UInt16) {
        guard port != 0, !host.contains(":"), PairingLink.isLocalNetworkHost(host) else { return nil }
        self.host = host
        self.port = port
    }

    #if DEBUG
    /// Test-only: `127.0.0.1:<port>`. Never reachable from parsing, and not
    /// compiled into release builds.
    init(loopbackForTestingPort port: UInt16) {
        self.host = "127.0.0.1"
        self.port = port
    }
    #endif

    /// `a.b.c.d:port`.
    public var description: String { "\(host):\(port)" }

    /// The Mac command to show on the phone: `adf-auth push --to a.b.c.d:port`.
    public var pushCommand: String { "adf-auth push --to \(description)" }

    /// True for the interfaces the handoff uses: Wi-Fi and wired Ethernet
    /// (`en*`) and bridges such as the Personal Hotspot (`bridge*`). Not
    /// cellular (`pdp_ip*`), VPN tunnels (`utun*`, `ipsec*`), AWDL or loopback.
    static func isLANInterfaceName(_ name: String) -> Bool {
        name.hasPrefix("en") || name.hasPrefix("bridge")
    }

    /// The private IPv4 addresses of this device's Wi-Fi, wired and bridge
    /// interfaces (``isLANInterfaceName(_:)``), in `getifaddrs` order.
    static func lanAddresses() -> [String] {
        LANAddress.ipv4Interfaces()
            .filter { isLANInterfaceName($0.name) && PairingLink.isLocalNetworkHost($0.address) }
            .map(\.address)
    }

    /// This device's private local-network IPv4 addresses with `port`, best
    /// first: `en0` (Wi-Fi), other `en*`, then `bridge*` (for example the
    /// Personal Hotspot). Cellular and VPN addresses are never offered.
    /// Empty when there is no usable network.
    public static func localCandidates(port: UInt16) -> [PhoneHandoffAddress] {
        let interfaces = LANAddress.ipv4Interfaces().filter { isLANInterfaceName($0.name) }
        func rank(_ name: String) -> Int {
            if name == "en0" { return 0 }
            if name.hasPrefix("en") { return 1 }
            return 2
        }
        return interfaces
            .enumerated()
            .sorted { (rank($0.element.name), $0.offset) < (rank($1.element.name), $1.offset) }
            .compactMap { PhoneHandoffAddress(host: $0.element.address, port: port) }
    }

    /// The first of ``localCandidates(port:)``, or nil.
    public static func local(port: UInt16) -> PhoneHandoffAddress? {
        localCandidates(port: port).first
    }
}
