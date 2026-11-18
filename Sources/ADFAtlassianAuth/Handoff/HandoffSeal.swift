import CryptoKit
import Foundation

/// Failures during the Mac → phone handoff, each with a user-facing ``message``.
public enum HandoffError: Error, Sendable, Equatable {
    case invalidLink(PairingLink.ParseError)
    /// 404 / 410 from the Mac: the code was already used or has expired.
    case alreadyUsedOrExpired
    /// 403 from the Mac: the person at the Mac said no.
    case declined
    case http(status: Int)
    case network(String)
    /// The sealed box could not be opened with this link's key and session.
    case decryptionFailed
    case invalidCredential(String)
    case sealFailed(String)
    /// macOS listener failures.
    case listenerFailed(String)
    /// The Mac's response was larger than ``HandoffClient/maxResponseBytes``.
    case responseTooLarge(limit: Int)

    public var message: String {
        switch self {
        case .invalidLink(let error):
            return error.message
        case .alreadyUsedOrExpired:
            return "This pairing code was already used or expired. Run `adf-auth push` again."
        case .declined:
            return "The Mac declined the request. Run `adf-auth push` again and answer yes on the Mac."
        case .http(let status):
            return "The Mac answered with HTTP \(status). Run `adf-auth push` again."
        case .network(let detail):
            return "Couldn't reach the Mac: \(detail) Make sure the phone and the Mac are on the same network."
        case .decryptionFailed:
            return "The pairing data could not be decrypted. Run `adf-auth push` again and scan the new code."
        case .invalidCredential(let detail):
            return "The Mac sent an unusable credential: \(detail)"
        case .sealFailed(let detail):
            return "Couldn't encrypt the credential: \(detail)"
        case .listenerFailed(let detail):
            return "Couldn't start the local handoff listener: \(detail)"
        case .responseTooLarge(let limit):
            return "The Mac sent more than \(limit / 1024) KiB, which is not a pairing response. Run `adf-auth push` again."
        }
    }
}

/// Seals a credential for the handoff with ChaChaPoly (RFC 8439). The key
/// and session ID come from the ``PairingLink``; the session ID is the
/// authenticated data, so a box only opens for its own link.
public enum HandoffSeal {
    /// Validates, encodes and seals. Returns the `combined` box
    /// (nonce + ciphertext + tag).
    public static func seal(_ credential: AtlassianCredential, link: PairingLink) throws(HandoffError) -> Data {
        do {
            try credential.validate()
        } catch {
            throw .invalidCredential(error.message)
        }
        var plaintext: Data
        do {
            plaintext = try credential.encoded()
        } catch {
            throw .sealFailed(error.localizedDescription)
        }
        defer { plaintext.zeroize() }
        do {
            return try ChaChaPoly.seal(plaintext, using: link.key, authenticating: Data(link.sessionId.utf8)).combined
        } catch {
            throw .sealFailed(error.localizedDescription)
        }
    }

    /// Opens a `combined` box, decodes and validates the credential.
    public static func open(_ data: Data, link: PairingLink) throws(HandoffError) -> AtlassianCredential {
        var plaintext: Data
        do {
            let box = try ChaChaPoly.SealedBox(combined: data)
            plaintext = try ChaChaPoly.open(box, using: link.key, authenticating: Data(link.sessionId.utf8))
        } catch {
            throw .decryptionFailed
        }
        defer { plaintext.zeroize() }
        let credential: AtlassianCredential
        do {
            credential = try AtlassianCredential.decode(plaintext)
        } catch {
            throw .invalidCredential("the data is not a credential")
        }
        do {
            try credential.validate()
        } catch {
            throw .invalidCredential(error.message)
        }
        return credential
    }
}

/// Phone side of the handoff: one GET to the Mac, then open the box.
public enum HandoffClient {
    /// The largest response body accepted (a sealed credential is ~1 KiB).
    public static let maxResponseBytes = 64 * 1024

    /// The default wait. Longer than the Mac's default 120 s listener timeout,
    /// because the wait includes the person confirming on the Mac.
    public static let defaultTimeout: TimeInterval = 130

    /// Fetches and opens the credential.
    ///
    /// Redirects are refused (a 3xx is reported as ``HandoffError/http(status:)``)
    /// and the body is capped at ``maxResponseBytes``. The link's host must be
    /// a well-formed IPv4 literal; links parsed with ``PairingLink/init(string:)``
    /// are additionally limited to private local-network addresses.
    ///
    /// - Parameter timeout: Seconds without progress before giving up.
    public static func fetch(_ link: PairingLink, session: URLSession = .shared, timeout: TimeInterval = defaultTimeout) async throws(HandoffError) -> AtlassianCredential {
        guard PairingLink.isValidHost(link.host) else { throw .invalidLink(.invalidHost(link.host)) }
        var request = URLRequest(url: link.fetchURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request, delegate: RedirectRefusal())
        } catch {
            throw .network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw .http(status: 0)
        }
        switch http.statusCode {
        case 200:
            var body = Data()
            defer { body.zeroize() }
            do {
                for try await byte in bytes {
                    guard body.count < maxResponseBytes else {
                        bytes.task.cancel()
                        throw HandoffError.responseTooLarge(limit: maxResponseBytes)
                    }
                    body.append(byte)
                }
            } catch let error as HandoffError {
                throw error
            } catch {
                throw .network(error.localizedDescription)
            }
            return try HandoffSeal.open(body, link: link)
        case 404, 410:
            bytes.task.cancel()
            throw .alreadyUsedOrExpired
        case 403:
            bytes.task.cancel()
            throw .declined
        default:
            bytes.task.cancel()
            throw .http(status: http.statusCode)
        }
    }

    /// Refuses every redirect, so the 3xx response itself is returned.
    final class RedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
            nil
        }
    }
}
