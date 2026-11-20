import Foundation

/// Failures fetching emoji images from Atlassian's emoji service, each with a
/// user-facing ``message``. No case ever carries a token or header; the
/// strings come from the HTTP status only.
///
/// Callers fall back to the emoji's `:shortName:` text on any of these.
/// Transport failures (`URLError`) and `CancellationError` are not wrapped:
/// ``AtlassianEmojiFetcher`` rethrows them unchanged.
public enum AtlassianEmojiError: Error, Equatable, Sendable {
    /// No emoji with that ID (HTTP 404, or an empty `emojis` array), no site
    /// emoji with that short name, or neither an ID nor a short name given.
    case notFound
    /// HTTP 401/403 from the emoji service, or from the media host after one
    /// read-token refresh.
    case unauthorized
    /// A body that could not be decoded, an emoji without an image
    /// representation, or a response that is not HTTP.
    case invalidResponse
    /// An image URL or redirect that is not HTTPS; it was not requested.
    case insecureURL
    /// An image URL on a host outside the allow-list; it was not requested.
    case unsupportedHost
    /// Any other non-2xx status.
    case http(status: Int)

    /// Maps an HTTP status. Nil for 2xx.
    init?(status: Int) {
        switch status {
        case 200..<300: return nil
        case 401, 403: self = .unauthorized
        case 404: self = .notFound
        default: self = .http(status: status)
        }
    }

    public var message: String {
        switch self {
        case .notFound:
            return "Atlassian has no image for this emoji, or this site doesn't share it."
        case .unauthorized:
            return "Atlassian refused to send this emoji's image."
        case .invalidResponse:
            return "Unexpected response from Atlassian while loading an emoji."
        case .insecureURL:
            return "Atlassian pointed this emoji at a non-HTTPS address, which was not loaded."
        case .unsupportedHost:
            return "Atlassian pointed this emoji at an unexpected host, which was not loaded."
        case .http(let status):
            return "Atlassian returned HTTP \(status) while loading an emoji. Try again later."
        }
    }
}

extension AtlassianEmojiError: CustomStringConvertible, LocalizedError {
    public var description: String { message }
    public var errorDescription: String? { message }
}
