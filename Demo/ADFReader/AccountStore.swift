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
    #if DEBUG
    /// Where token checks go instead of each site's own gateway — a stub
    /// server under the Debug-only `-authGateway` launch argument, `nil`
    /// otherwise. Release builds have no override: checks always go to
    /// `https://<site>/gateway/api/graphql`.
    let gatewayOverride: URL?
    #endif

    @ObservationIgnored private let store: any CredentialStore
    /// Ephemeral: no cookies, cache or credentials are written to disk for
    /// the token check or the pairing fetch.
    @ObservationIgnored let session: URLSession

    #if DEBUG
    init(store: any CredentialStore, gatewayOverride: URL? = nil) {
        self.store = store
        self.gatewayOverride = gatewayOverride
        session = URLSession(configuration: .ephemeral)
    }
    #else
    init(store: any CredentialStore) {
        self.store = store
        session = URLSession(configuration: .ephemeral)
    }
    #endif

    /// The app's store for this launch: the keychain, or memory under the
    /// Debug-only `-accountsInMemory`; token checks go to `-authGateway`'s
    /// stub in Debug builds that pass it.
    static func live(options: LaunchOptions) -> AccountStore {
        #if DEBUG
        let store: any CredentialStore = options.accountsInMemory
            ? InMemoryCredentialStore() : KeychainCredentialStore()
        if let gateway = options.authGateway {
            print("AUTH_GATEWAY override=\(gateway.absoluteString)")
        }
        return AccountStore(store: store, gatewayOverride: options.authGateway)
        #else
        return AccountStore(store: KeychainCredentialStore())
        #endif
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

    /// Checks the token with the site's GraphQL gateway (one harmless
    /// `AdfAuthCheck` query), fills in the cloud ID it returns, and saves
    /// the credential — replacing any stored one for the same site (that is
    /// how a token is rotated). Nothing is saved when the check fails.
    @discardableResult
    func connect(_ credential: AtlassianCredential) async throws -> AtlassianAccountSummary {
        try credential.validate()
        #if DEBUG
        let endpoint = gatewayOverride
        #else
        let endpoint: URL? = nil
        #endif
        let client = AtlassianGraphQLClient(credential: credential, endpoint: endpoint, session: session)
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
        case let error as KeychainError:
            return error.message
        default:
            return error.localizedDescription
        }
    }
}
