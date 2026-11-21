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

    /// Bumped by every `connect` and `remove`, so a cache built from
    /// `credential(for:)` (`DemoMedia`'s live fetchers) knows to load again.
    @ObservationIgnored private(set) var changeCount = 0

    /// Called after every `connect` and `remove` with the site, the email
    /// stored for it before, and the email stored now (nil when none), so
    /// caches of what an account loaded (`DemoMedia`) can be purged at once.
    @ObservationIgnored var didChange: (@MainActor (_ site: AtlassianSite, _ previousEmail: String?, _ email: String?) -> Void)?

    func summary(for site: AtlassianSite) -> AtlassianAccountSummary? {
        summaries.first { $0.site == site }
    }

    /// The stored credential for `site` (reads the token from the store),
    /// for the fetchers that need one (`EmojiResolvers`, `DemoMedia`'s live
    /// media fetch); never shown or logged. Callers keep it only as long as
    /// the fetcher they build with it.
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
        let previousEmail = storedEmail(for: checked.site)
        try store.save(checked)
        changeCount += 1
        reload()
        didChange?(checked.site, previousEmail, checked.email)
        return checked.summary
    }

    func remove(site: AtlassianSite) throws {
        let previousEmail = storedEmail(for: site)
        try store.remove(site: site)
        changeCount += 1
        reload()
        didChange?(site, previousEmail, nil)
    }

    /// The email stored for `site`, read from the store's non-secret
    /// attributes rather than `summaries`, which may not be loaded yet.
    private func storedEmail(for site: AtlassianSite) -> String? {
        (try? store.summaries())?.first { $0.site == site }?.email
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
