import Foundation

/// Failures talking to the Atlassian GraphQL gateway, each with a
/// user-facing ``message``.
public enum AtlassianAuthError: Error, Sendable, Equatable {
    /// HTTP 401, or a GraphQL error with status 401.
    case unauthorized
    /// HTTP 403, or a GraphQL error classified as forbidden.
    case forbidden(missingScopes: [String])
    /// The gateway refused a scoped API token for `field`. `detail` is the
    /// gateway's own message. There is no fallback.
    case scopedTokenRejected(field: String, detail: String)
    /// HTTP 404, `CloudIdNotFoundException`, or no tenant for the host.
    case siteNotFound(host: String)
    /// HTTP 429. `retryAfter` comes from the `Retry-After` header.
    case rateLimited(retryAfter: TimeInterval?)
    /// Any other non-2xx status.
    case server(status: Int)
    /// HTTP 200 with `errors` and no usable data.
    case graphQL(messages: [String])
    case invalidResponse(String)
    /// A transport failure (never includes request headers).
    case network(String)

    public var message: String {
        switch self {
        case .unauthorized:
            return "Atlassian rejected the email or token. Check both, and make sure the token was created for Confluence."
        case .forbidden(let missingScopes):
            let scopes = missingScopes.isEmpty ? AtlassianTokenScopes.required : missingScopes
            return "Atlassian refused access. The token needs these scopes: \(scopes.joined(separator: ", ")). Create a new token with them."
        case .scopedTokenRejected(let field, let detail):
            var text = "This site's GraphQL gateway does not accept scoped API tokens for \(field). ADFReader uses GraphQL only, so title lookup can't work with this token."
            if !detail.isEmpty { text += " Atlassian said: \(detail)" }
            return text
        case .siteNotFound(let host):
            return "No Atlassian Cloud site at \(host). Check the site name."
        case .rateLimited(let retryAfter):
            if let retryAfter, retryAfter > 0 {
                return "Atlassian is limiting requests. Try again in \(Int(retryAfter.rounded(.up))) seconds."
            }
            return "Atlassian is limiting requests. Try again in a minute."
        case .server(let status):
            return "Atlassian returned HTTP \(status). Try again later."
        case .graphQL(let messages):
            let joined = messages.isEmpty ? "no details" : messages.joined(separator: "; ")
            return "Atlassian's GraphQL gateway returned errors: \(joined)"
        case .invalidResponse(let detail):
            return "Unexpected response from Atlassian: \(detail)"
        case .network(let detail):
            return "Couldn't reach Atlassian: \(detail)"
        }
    }
}
