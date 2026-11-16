import Foundation

/// An Atlassian site + email + API token, as stored in the keychain and sent
/// over the one-time handoff.
///
/// The token never appears in `description`, `debugDescription` or the
/// reflection mirror, so `print`, string interpolation and `dump` are safe.
/// JSON (``encoded()``) does contain the token; only write it to the keychain
/// or into a sealed handoff box.
public struct AtlassianCredential: Codable, Sendable, Equatable {
    /// The only supported format version.
    public static let currentVersion = 1

    /// Format version (always 1 for now).
    public var v: Int
    public var site: AtlassianSite
    /// The site's cloud ID (a UUID), filled in after the token check.
    public var cloudId: String?
    public var email: String
    /// The API token. Secret: never log or print it.
    public var token: String
    public var scopes: [String]
    public var createdAt: Date
    public var expiresAt: Date?

    /// Dates are truncated to whole seconds so the ISO 8601 JSON round-trips
    /// exactly.
    public init(
        site: AtlassianSite,
        email: String,
        token: String,
        cloudId: String? = nil,
        scopes: [String] = AtlassianTokenScopes.required,
        createdAt: Date = Date(),
        expiresAt: Date?,
        v: Int = AtlassianCredential.currentVersion
    ) {
        self.v = v
        self.site = site
        self.cloudId = cloudId
        self.email = email
        self.token = token
        self.scopes = scopes
        self.createdAt = createdAt.wholeSeconds
        self.expiresAt = expiresAt?.wholeSeconds
    }

    /// The non-secret part, safe to list and show.
    public var summary: AtlassianAccountSummary {
        AtlassianAccountSummary(site: site, email: email, cloudId: cloudId, scopes: scopes, createdAt: createdAt, expiresAt: expiresAt)
    }

    /// Why a credential failed ``validate()``.
    public enum ValidationError: Error, Sendable, Equatable {
        case unsupportedVersion(Int)
        case invalidEmail
        case emptyToken
        case tokenTooLong(bytes: Int)
        case tokenHasWhitespace
        case invalidCloudId

        public var message: String {
            switch self {
            case .unsupportedVersion(let v):
                return "This credential uses format version \(v); this build only understands version \(AtlassianCredential.currentVersion). Update ADFReader and adf-auth."
            case .invalidEmail:
                return "Enter the email address of your Atlassian account."
            case .emptyToken:
                return "The API token is empty."
            case .tokenTooLong(let bytes):
                return "The API token is \(bytes) bytes long, which is longer than any Atlassian token (512 bytes max). Copy it again."
            case .tokenHasWhitespace:
                return "The API token contains spaces or line breaks. Copy it again without extra characters."
            case .invalidCloudId:
                return "The site's cloud ID is not a valid UUID."
            }
        }
    }

    /// Maximum token size in UTF-8 bytes.
    public static let maxTokenBytes = 512

    /// Checks the version, email, token shape and cloud ID.
    public func validate() throws(ValidationError) {
        guard v == Self.currentVersion else { throw .unsupportedVersion(v) }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, trimmedEmail.contains("@") else { throw .invalidEmail }
        guard !token.isEmpty else { throw .emptyToken }
        let bytes = token.utf8.count
        guard bytes <= Self.maxTokenBytes else { throw .tokenTooLong(bytes: bytes) }
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard !token.unicodeScalars.contains(where: { forbidden.contains($0) }) else { throw .tokenHasWhitespace }
        if let cloudId, UUID(uuidString: cloudId) == nil { throw .invalidCloudId }
    }

    /// JSON with sorted keys and ISO 8601 dates. Contains the token.
    public func encoded() throws -> Data {
        try AuthJSON.makeEncoder().encode(self)
    }

    /// Decodes JSON written by ``encoded()``. Does not validate.
    public static func decode(_ data: Data) throws -> AtlassianCredential {
        try AuthJSON.makeDecoder().decode(AtlassianCredential.self, from: data)
    }
}

extension AtlassianCredential: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "AtlassianCredential(site: \(site.host), email: \(email), cloudId: \(cloudId ?? "nil"), token: \(Redaction.token(token)), scopes: \(scopes), expiresAt: \(expiresAt.map { "\($0)" } ?? "nil"))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: [
            "v": v,
            "site": site.host,
            "cloudId": cloudId as Any,
            "email": email,
            "token": Redaction.token(token),
            "scopes": scopes,
            "createdAt": createdAt,
            "expiresAt": expiresAt as Any,
        ], displayStyle: .struct)
    }
}

/// How close a token is to its expiry date.
public enum ExpiryStatus: Sendable, Hashable {
    /// No expiry date is known.
    case noExpiry
    /// More than ``AtlassianAccountSummary/expiringSoonDays`` days left.
    case valid(daysLeft: Int)
    /// At most ``AtlassianAccountSummary/expiringSoonDays`` days left.
    case expiringSoon(daysLeft: Int)
    case expired

    /// True for `.expiringSoon` and `.expired` (the app shows a banner).
    public var needsAttention: Bool {
        switch self {
        case .expiringSoon, .expired: return true
        case .noExpiry, .valid: return false
        }
    }
}

/// The non-secret part of a credential. Stored in the keychain item's
/// `kSecAttrGeneric` so listing accounts never reads a token.
public struct AtlassianAccountSummary: Codable, Sendable, Hashable, Identifiable {
    /// Days left at or below which a token counts as expiring soon.
    public static let expiringSoonDays = 14

    public var id: AtlassianSite { site }
    public var site: AtlassianSite
    public var email: String
    public var cloudId: String?
    public var scopes: [String]
    public var createdAt: Date
    public var expiresAt: Date?

    public init(site: AtlassianSite, email: String, cloudId: String?, scopes: [String], createdAt: Date, expiresAt: Date?) {
        self.site = site
        self.email = email
        self.cloudId = cloudId
        self.scopes = scopes
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    /// Days left are rounded up, so 13.2 days left reads as 14.
    public func expiryStatus(now: Date = Date()) -> ExpiryStatus {
        guard let expiresAt else { return .noExpiry }
        let remaining = expiresAt.timeIntervalSince(now)
        guard remaining > 0 else { return .expired }
        let daysLeft = Int((remaining / 86_400).rounded(.up))
        return daysLeft <= Self.expiringSoonDays ? .expiringSoon(daysLeft: daysLeft) : .valid(daysLeft: daysLeft)
    }

    public func encoded() throws -> Data {
        try AuthJSON.makeEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> AtlassianAccountSummary {
        try AuthJSON.makeDecoder().decode(AtlassianAccountSummary.self, from: data)
    }
}

/// The shared JSON configuration: sorted keys, ISO 8601 dates.
enum AuthJSON {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Accepts ISO 8601 with or without fractional seconds.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = try? Date.ISO8601FormatStyle().parse(string) { return date }
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an ISO 8601 date.")
        }
        return decoder
    }
}

extension Date {
    var wholeSeconds: Date {
        Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down))
    }
}
