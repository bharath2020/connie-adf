import ADFAtlassianAuth
import Foundation
import Observation

/// The app's Atlassian accounts: the non-secret summaries for the list, and
/// the connect / remove operations. Tokens stay inside the credential store
/// (the keychain in the app); this type never keeps one past `connect`.
@MainActor @Observable
final class AccountStore {
    /// Sorted by site. Read from the store's non-secret attributes, so
    /// listing never reads a token.
    private(set) var summaries: [AtlassianAccountSummary] = []
    /// Why the last `reload()` failed (a keychain error), if it did.
    private(set) var loadError: String?

    @ObservationIgnored private let store: any CredentialStore
    /// Ephemeral: no cookies, cache or credentials are written to disk for
    /// the token check or the pairing fetch.
    @ObservationIgnored let session: URLSession

    init(store: any CredentialStore) {
        self.store = store
        session = URLSession(configuration: .ephemeral)
    }

    /// The app's store: the keychain.
    static func live() -> AccountStore {
        AccountStore(store: KeychainCredentialStore())
    }

    func reload() {
        do {
            summaries = try store.summaries()
            loadError = nil
        } catch {
            loadError = Self.message(for: error)
        }
    }

    func summary(for site: AtlassianSite) -> AtlassianAccountSummary? {
        summaries.first { $0.site == site }
    }

    /// The stored credential for `site` (reads the secret), for the
    /// fetchers that need one (`EmojiResolvers`). Callers keep it only as
    /// long as the fetcher they build with it.
    func credential(for site: AtlassianSite) throws -> AtlassianCredential? {
        try store.load(site: site)
    }

    /// For a handed-off credential's confirmation: reloads, then returns the
    /// stored account's email when the same site is stored under a
    /// different email (saving would replace it), else nil.
    func replacedEmail(by credential: AtlassianCredential) -> String? {
        reload()
        return summary(for: credential.site).flatMap {
            $0.email.caseInsensitiveCompare(credential.email) == .orderedSame ? nil : $0.email
        }
    }

    /// Checks the token with the site's GraphQL gateway (one harmless
    /// `AdfAuthCheck` query), fills in the cloud ID it returns, and saves
    /// the credential — replacing any stored one for the same site (that is
    /// how a token is rotated). Nothing is saved when the check fails.
    @discardableResult
    func connect(_ credential: AtlassianCredential) async throws -> AtlassianAccountSummary {
        try credential.validate()
        let client = AtlassianGraphQLClient(credential: credential, session: session)
        let result = try await client.checkToken()
        var checked = credential
        checked.cloudId = result.cloudId
        try checked.validate()
        try store.save(checked)
        reload()
        return checked.summary
    }

    func remove(site: AtlassianSite) throws {
        try store.remove(site: site)
        reload()
    }

    /// A user-facing sentence for any error the account flows can throw.
    /// Never includes a token: every case below carries only site, status
    /// and server-message text.
    static func message(for error: any Error) -> String {
        switch error {
        case let error as AtlassianAuthError:
            return error.message
        case let error as AtlassianSite.ParseError:
            return error.message
        case let error as AtlassianCredential.ValidationError:
            return error.message
        case let error as HandoffError:
            return error.message
        case let error as PairingLink.ParseError:
            return error.message
        case let error as PhoneHandoffError:
            return error.message
        case let error as KeychainError:
            return error.message
        default:
            return error.localizedDescription
        }
    }
}
