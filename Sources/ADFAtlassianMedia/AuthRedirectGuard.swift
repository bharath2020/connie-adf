import Foundation
import os

/// A per-task delegate (`URLSession.data(for:delegate:)`) that decides each
/// redirect of an authenticated request:
///
/// - a non-HTTPS target is refused (the task then ends with the 3xx response
///   and ``refusedInsecureRedirect`` is true);
/// - a target on another host than the original request's gets its
///   `Authorization` and `X-Client-Id` headers removed, so Basic
///   `email:token` (media fetch) or an emoji read token never leaves the
///   host it was sent to (the attachment download 302s to the media host,
///   which authorizes with a signed token in the URL);
/// - a same-host target keeps every header.
final class AuthRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    /// The lowercased host of the request this task started with.
    let originalHost: String?
    private let refused = OSAllocatedUnfairLock(initialState: false)

    init(originalHost: String?) {
        self.originalHost = originalHost?.lowercased()
    }

    /// True once a redirect was refused for not being HTTPS.
    var refusedInsecureRedirect: Bool { refused.withLock { $0 } }

    /// Headers removed on a redirect to another host.
    static let credentialHeaders = ["Authorization", "X-Client-Id"]

    /// The request to follow, or nil to refuse. Pure; internal for tests.
    static func redirectedRequest(_ request: URLRequest, originalHost: String?) -> URLRequest? {
        guard let url = request.url, url.scheme?.lowercased() == "https" else { return nil }
        var next = request
        let host = url.host()?.lowercased()
        if originalHost == nil || host != originalHost?.lowercased() {
            for name in credentialHeaders { next.setValue(nil, forHTTPHeaderField: name) }
        }
        return next
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let next = Self.redirectedRequest(request, originalHost: originalHost) else {
            refused.withLock { $0 = true }
            return nil
        }
        return next
    }
}
