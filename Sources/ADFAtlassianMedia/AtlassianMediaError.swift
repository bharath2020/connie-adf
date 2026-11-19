import Foundation
import ADFAtlassianAuth

/// Failures fetching Confluence attachment bytes, each with a user-facing
/// ``message``. No case ever carries the email, token or Authorization
/// header; the strings come from the document (file ID, collection) or the
/// HTTP status.
///
/// Transport failures (`URLError`) and `CancellationError` are not wrapped:
/// ``AtlassianMediaFetcher`` rethrows them unchanged.
public enum AtlassianMediaError: Error, Equatable, Sendable {
    /// The media node's collection is not `contentId-<digits>` and no page ID
    /// was given, so there is no page to list attachments for.
    case missingPageId(collection: String?)
    /// The page has no attachment whose `fileId` matches (after one refetch
    /// of a cached list).
    case attachmentNotFound(fileId: String)
    /// HTTP 401: the email or token is wrong, revoked or expired.
    case unauthorized
    /// HTTP 403: most likely the token lacks the attachment scopes.
    case forbidden
    /// HTTP 404: no such page or attachment, or the account can't see it.
    case notFound
    /// Any other non-2xx status.
    case http(status: Int)
    /// A body that could not be decoded, or a response that is not HTTP.
    case invalidResponse
    /// The media source is not an Atlassian file (for example `.external`).
    case unsupportedSource
    /// A redirect pointed to a non-HTTPS URL; it was not followed.
    case insecureRedirect

    /// Maps an HTTP status. Nil for 2xx.
    init?(status: Int) {
        switch status {
        case 200..<300: return nil
        case 401: self = .unauthorized
        case 403: self = .forbidden
        case 404: self = .notFound
        default: self = .http(status: status)
        }
    }

    /// The scopes a 403 most likely means are missing.
    public static let attachmentScopes = [AtlassianTokenScopes.attachment, AtlassianTokenScopes.attachmentDownload]

    public var message: String {
        switch self {
        case .missingPageId(let collection):
            let shown = collection.flatMap { $0.isEmpty ? nil : "“\($0)”" } ?? "none"
            return "This image has no Confluence page ID (collection: \(shown)), so its attachment can't be looked up."
        case .attachmentNotFound(let fileId):
            return "The page has no attachment with file ID \(fileId)."
        case .unauthorized:
            return "Atlassian rejected the email or token while loading an image. Check the account, or create a new token."
        case .forbidden:
            return "Atlassian refused to send the image. The token likely lacks the \(Self.attachmentScopes.joined(separator: " and ")) scopes (tokens created before images were supported don't have them). Create a new token with them."
        case .notFound:
            return "The page or attachment was not found, or this account can't see it."
        case .http(let status):
            return "Atlassian returned HTTP \(status) while loading an image. Try again later."
        case .invalidResponse:
            return "Unexpected response from Atlassian while loading an image."
        case .unsupportedSource:
            return "This image is not a Confluence attachment, so the Atlassian media fetcher does not load it."
        case .insecureRedirect:
            return "Atlassian redirected the image download to a non-HTTPS address, which was not followed."
        }
    }
}

extension AtlassianMediaError: CustomStringConvertible, LocalizedError {
    public var description: String { message }
    public var errorDescription: String? { message }
}
