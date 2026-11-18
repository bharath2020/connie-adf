import Foundation

/// An Atlassian Cloud site, normalized to its host name (for example
/// `acme.atlassian.net`).
///
/// Only `<name>.atlassian.net` sites are supported. Encodes and decodes as a
/// single JSON string (the host); decoding runs the same normalization.
public struct AtlassianSite: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    /// The normalized host, for example `acme.atlassian.net`.
    public let host: String

    /// Why a site string was rejected.
    public enum ParseError: Error, Sendable, Equatable {
        /// The input was empty or only whitespace.
        case empty
        /// The host is not a `<name>.atlassian.net` site (custom domain or
        /// another host).
        case unsupportedHost(String)
        /// The site name has characters or a length Atlassian does not allow.
        case invalidName(String)

        /// A user-facing explanation.
        public var message: String {
            switch self {
            case .empty:
                return "Enter your Atlassian site, for example acme or acme.atlassian.net."
            case .unsupportedHost(let host):
                return "“\(host)” is not supported. Only <name>.atlassian.net sites are supported for now."
            case .invalidName(let name):
                return "“\(name)” is not a valid Atlassian site name. Use letters, digits and hyphens, for example acme or acme.atlassian.net."
            }
        }
    }

    static let cloudSuffix = ".atlassian.net"

    /// Normalizes user input into a site.
    ///
    /// Accepts a bare name (`acme`), a host (`acme.atlassian.net`), or any URL
    /// on the site (`https://acme.atlassian.net/wiki/spaces/X/pages/1/T`),
    /// with or without scheme, port, path, query or a trailing dot. Input is
    /// trimmed and lowercased.
    public init(parsing input: String) throws(ParseError) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { throw .empty }

        let urlString = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let components = URLComponents(string: urlString),
              var host = components.host?.lowercased() else {
            throw .invalidName(trimmed)
        }
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { throw .invalidName(trimmed) }

        let label: String
        if !host.contains(".") {
            label = host
        } else if host.hasSuffix(Self.cloudSuffix) {
            label = String(host.dropLast(Self.cloudSuffix.count))
            guard !label.isEmpty, !label.contains(".") else { throw .unsupportedHost(host) }
        } else {
            throw .unsupportedHost(host)
        }
        guard Self.isValidLabel(label) else { throw .invalidName(label) }
        self.host = label + Self.cloudSuffix
    }

    /// `^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$`
    static func isValidLabel(_ label: String) -> Bool {
        let bytes = Array(label.utf8)
        guard (1...63).contains(bytes.count) else { return false }
        func isAlnum(_ b: UInt8) -> Bool { (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) }
        guard isAlnum(bytes[0]), isAlnum(bytes[bytes.count - 1]) else { return false }
        return bytes.allSatisfy { isAlnum($0) || $0 == 0x2D }
    }

    /// The tenant GraphQL gateway: `https://<host>/gateway/api/graphql`.
    public var graphQLEndpoint: URL {
        URL(string: "https://\(host)/gateway/api/graphql")!
    }

    public var description: String { host }

    public static func < (lhs: AtlassianSite, rhs: AtlassianSite) -> Bool { lhs.host < rhs.host }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        do {
            try self.init(parsing: raw)
        } catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: error.message)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(host)
    }
}
