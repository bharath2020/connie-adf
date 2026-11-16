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
        do {
            let plaintext = try credential.encoded()
            return try ChaChaPoly.seal(plaintext, using: link.key, authenticating: Data(link.sessionId.utf8)).combined
        } catch {
            throw .sealFailed(error.localizedDescription)
        }
    }

    /// Opens a `combined` box, decodes and validates the credential.
    public static func open(_ data: Data, link: PairingLink) throws(HandoffError) -> AtlassianCredential {
        let plaintext: Data
        do {
            let box = try ChaChaPoly.SealedBox(combined: data)
            plaintext = try ChaChaPoly.open(box, using: link.key, authenticating: Data(link.sessionId.utf8))
        } catch {
            throw .decryptionFailed
        }
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
    /// Fetches and opens the credential.
    ///
    /// - Parameter timeout: Seconds without progress before giving up. The
    ///   wait includes the person confirming on the Mac, so keep it generous.
    public static func fetch(_ link: PairingLink, session: URLSession = .shared, timeout: TimeInterval = 60) async throws(HandoffError) -> AtlassianCredential {
        var request = URLRequest(url: link.fetchURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw .network(error.localizedDescription)
        } catch {
            throw .network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw .http(status: 0) }
        switch http.statusCode {
        case 200:
            return try HandoffSeal.open(data, link: link)
        case 404, 410:
            throw .alreadyUsedOrExpired
        case 403:
            throw .declined
        default:
            throw .http(status: http.statusCode)
        }
    }
}
