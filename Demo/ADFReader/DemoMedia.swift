import Foundation
import UIKit
import os
import ADFAtlassianAuth
import ADFAtlassianMedia
import ADFModel
import ADFRendering
import ADFResolvers

// MARK: - The demo's media providers

/// The demo's media setup for this launch: one `CacheFirstMediaProvider`
/// per fetch — the mock, and one per Atlassian account — each with its own
/// memory cache, disk cache and in-flight fetches, shared by every reader
/// this launch, so About This Build's counts cover the whole launch.
///
/// `resolve(for:)` picks a document's provider when it opens, from the
/// persisted Images setting (`MediaModePreference`; `-media` sets it for a
/// launch):
///
/// | Setting   | Remote page, account for its site | Remote page, no account | Bundled fixture |
/// |-----------|-----------------------------------|-------------------------|-----------------|
/// | Atlassian | live (`LiveMediaFetch`)           | mock                    | mock            |
/// | Mock      | mock                              | mock                    | mock            |
/// | Off       | none                              | none                    | none            |
///
/// Fixtures always get the mock (their file IDs resolve on no site). Live
/// providers keep their encoded bytes in `Caches/ADFReaderMedia/<site
/// host>`, the mock in `Caches/ADFReaderMedia/mock`; 200 MB each. A site's
/// caches hold one account's images: removing the account, or replacing it
/// with another email, empties them (`accountChanged`).
/// `-mediaCache cold` empties the whole `ADFReaderMedia` folder at launch,
/// so no mode starts with disk hits. Everything is built lazily: under Off
/// nothing is, so `mock` stays nil (`MediaProbe` reports -1).
///
/// A document keeps the provider it opened with; a new pick applies to the
/// next document opened.
@MainActor
final class DemoMedia {
    /// The Images setting. Raw values are the `-media` flag's values.
    enum Mode: String, CaseIterable, Identifiable, Sendable {
        case off
        case mock
        case live

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .off: "Off"
            case .mock: "Mock"
            case .live: "Atlassian"
            }
        }

        /// One line under the choice in the reader menu and Settings.
        var detail: String {
            switch self {
            case .off: "No images load."
            case .mock: "Generated images, no network."
            case .live: "Real images on remote pages whose site has an account; mock images elsewhere."
            }
        }
    }

    /// What one document got.
    struct Resolution {
        enum Fetch: Equatable {
            case none
            case mock
            case live(AtlassianSite)
        }

        /// The Images setting when the document opened.
        let setting: Mode
        let fetch: Fetch
        /// Why the fetch is the mock under the Atlassian setting.
        let fallbackReason: String?
        /// What `ReaderView` passes to `ADFDocumentView`; nil when off.
        let provider: (any ADFMediaProvider)?

        /// For About This Build: "Atlassian · acme.atlassian.net",
        /// "Mock (bundled document)", "Off (-media off)".
        var summary: String {
            switch fetch {
            case .none:
                return MediaModePreference.setByAutomation() ? "Off (-media off)" : "Off (Images setting)"
            case .mock:
                return fallbackReason.map { "Mock (\($0))" } ?? "Mock"
            case .live(let site):
                return "Atlassian · \(site.host)"
            }
        }
    }

    /// The app's accounts, set by `ADFReaderApp.init`; nil keeps every
    /// document off the live fetch.
    static var accountStore: AccountStore?

    /// Built by the first reader, which reads the display scale from the
    /// window scene.
    static var shared: DemoMedia {
        if let instance {
            return instance
        }
        let media = DemoMedia(options: LaunchOptions(), scale: currentDisplayScale())
        instance = media
        return media
    }

    private static var instance: DemoMedia?

    static let rootDirectory = URL.cachesDirectory
        .appending(path: "ADFReaderMedia", directoryHint: .isDirectory)
    static let mockDirectory = rootDirectory.appending(path: "mock", directoryHint: .isDirectory)
    static let diskByteLimit = 200 << 20

    static func directory(for site: AtlassianSite) -> URL {
        rootDirectory.appending(path: site.host, directoryHint: .isDirectory)
    }

    /// Pixels per point the providers decode for.
    let scale: CGFloat
    /// Whether this launch emptied the disk caches (`-mediaCache cold`).
    let startedCold: Bool
    let mockConfiguration: MockMediaFetch.Configuration
    /// The mock fetch, for its counters; nil until a document first gets it.
    private(set) var mock: MockMediaFetch?
    private var mockProvider: CacheFirstMediaProvider?

    private struct LiveAccount {
        let fetch: LiveMediaFetch
        let provider: AccountMediaProvider<String>
        var hasCredential: Bool
    }

    private var live: [AtlassianSite: LiveAccount] = [:]
    /// `AccountStore.changeCount` at each site's last credential load: a
    /// connect or remove since makes the next document load it again.
    private var checkedAt: [AtlassianSite: Int] = [:]

    init(options: LaunchOptions, scale: CGFloat) {
        self.scale = scale
        startedCold = options.mediaCacheCold
        mockConfiguration = MockMediaFetch.Configuration(
            delay: .milliseconds(Int((options.mediaDelay * 1_000).rounded()))
        )
        if options.mediaCacheCold {
            // The same as `DiskCache.removeAll()` on every cache, but done
            // before any cache exists, so it is finished before the first
            // lookup: a `DiskCache` reads its directory on first use, and
            // here finds it empty.
            try? FileManager.default.removeItem(at: Self.rootDirectory)
        }
    }

    /// After `AccountStore` connects or removes `site`'s account. A site
    /// with a provider this launch reloads its credential now, which empties
    /// its caches if the account went or changed; one without empties its
    /// disk folder when the account went or changed, so no later provider
    /// finds the previous account's bytes.
    static func accountChanged(site: AtlassianSite, previousEmail: String?, email: String?) {
        if let media = instance, media.live[site] != nil {
            _ = media.liveAccount(for: site)
        } else if identity(previousEmail) != identity(email) {
            try? FileManager.default.removeItem(at: directory(for: site))
        }
    }

    /// Who a site's cached media belongs to: the account's email, which
    /// the app compares without case.
    private static func identity(_ email: String?) -> String? {
        email?.lowercased()
    }

    /// The provider for `source` under the current Images setting.
    func resolve(for source: DocumentSource) -> Resolution {
        let setting = MediaModePreference.current()
        switch setting {
        case .off:
            return Resolution(setting: setting, fetch: .none, fallbackReason: nil, provider: nil)
        case .mock:
            return Resolution(setting: setting, fetch: .mock, fallbackReason: nil, provider: mockMediaProvider())
        case .live:
            guard let site = source.atlassianSite else {
                return Resolution(setting: setting, fetch: .mock, fallbackReason: "bundled document",
                                  provider: mockMediaProvider())
            }
            guard let account = liveAccount(for: site) else {
                return Resolution(setting: setting, fetch: .mock, fallbackReason: "no account for \(site.host)",
                                  provider: mockMediaProvider())
            }
            return Resolution(setting: setting, fetch: .live(site), fallbackReason: nil, provider: account.provider)
        }
    }

    /// The live fetch for `site`, for its counters; nil before a document
    /// of that site loaded live.
    func liveFetch(for site: AtlassianSite) -> LiveMediaFetch? {
        live[site]?.fetch
    }

    /// One line for About This Build, e.g. `Delay 0.3 s · failure rate 0 %
    /// · disk 200 MB · @3x · cold start` (the delay only for the mock).
    func configSummary(for fetch: Resolution.Fetch) -> String {
        let scaleText = Double(scale).formatted(.number.precision(.fractionLength(0 ... 2)))
        var parts: [String] = []
        if fetch == .mock {
            parts.append(mockConfiguration.summary)
        }
        parts += ["disk \(Self.diskByteLimit >> 20) MB", "@\(scaleText)x"]
        if startedCold {
            parts.append("cold start")
        }
        return parts.joined(separator: " · ")
    }

    private func mockMediaProvider() -> CacheFirstMediaProvider {
        if let mockProvider {
            return mockProvider
        }
        let fetch = MockMediaFetch(configuration: mockConfiguration)
        let provider = CacheFirstMediaProvider(
            disk: DiskCache(directory: Self.mockDirectory, byteLimit: Self.diskByteLimit),
            scale: scale,
            fetch: { try await fetch.fetch($0) }
        )
        mock = fetch
        mockProvider = provider
        return provider
    }

    /// One fetcher and provider per site for the launch. The credential is
    /// loaded on the first request and again after any account change: a
    /// rotated token gets a new fetcher, a removed account stops the live
    /// fetch (open documents' `.file` loads fail; new ones get the mock), and
    /// a removed or different account empties the site's caches.
    private func liveAccount(for site: AtlassianSite) -> LiveAccount? {
        guard let accounts = Self.accountStore else { return nil }
        if checkedAt[site] != accounts.changeCount {
            checkedAt[site] = accounts.changeCount
            let credential = try? accounts.credential(for: site)
            if let existing = live[site] {
                existing.provider.use(Self.identity(credential?.email))
                existing.fetch.use(credential)
                live[site]?.hasCredential = credential != nil
            } else if let credential {
                let fetch = LiveMediaFetch(credential: credential)
                let provider = AccountMediaProvider(
                    account: Self.identity(credential.email),
                    disk: DiskCache(directory: Self.directory(for: site), byteLimit: Self.diskByteLimit),
                    scale: scale,
                    fetch: { try await fetch.fetch($0) }
                )
                live[site] = LiveAccount(fetch: fetch, provider: provider, hasCredential: true)
            }
        }
        guard let account = live[site], account.hasCredential else { return nil }
        return account
    }

    /// The window scene's display scale; 3 (2 on Mac Catalyst) when no
    /// scene reports one yet.
    static func currentDisplayScale() -> CGFloat {
        let sceneScale = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.traitCollection.displayScale }
            .first { $0 > 0 }
        let scale = sceneScale ?? UITraitCollection.current.displayScale
        if scale > 0 {
            return scale
        }
        #if targetEnvironment(macCatalyst)
        return 2
        #else
        return 3
        #endif
    }
}

// MARK: - Live fetch

/// Real image bytes for one Atlassian account: `.file` media through
/// `AtlassianMediaFetcher` (the account's scoped token, Basic auth to
/// `api.atlassian.com` only; see docs/Atlassian-Media-Fetch.md), `.external`
/// media with a plain HTTPS GET that sends no credentials. Wrapped in
/// counters for About This Build, like `MockMediaFetch`; only the
/// provider's memory and disk misses reach it.
///
/// A failure (`AtlassianMediaError`, a transport error) is thrown on, so the
/// box shows its failure chip; its message is kept for About This Build.
final class LiveMediaFetch: Sendable {
    /// Since launch, across every document of the site.
    struct Counts: Sendable, Equatable {
        var calls = 0
        var cancelled = 0
        var inFlight = 0
        var fetched = 0
        var failed = 0
        /// Failures that were 401 or 403: a rejected token, or one made
        /// before the attachment scopes were required.
        var refused = 0
        /// The last failure's user-facing message; never the email or token.
        var lastFailure: String?
    }

    enum ExternalError: Error, LocalizedError {
        case unsupportedURL
        case invalidResponse
        case http(status: Int)

        var errorDescription: String? {
            switch self {
            case .unsupportedURL: "This image's URL is not HTTPS, so it is not loaded."
            case .invalidResponse: "Unexpected response while loading an image."
            case .http(let status): "The image's server returned HTTP \(status)."
            }
        }
    }

    private struct Account: Sendable {
        let credential: AtlassianCredential
        let fetcher: AtlassianMediaFetcher
    }

    let site: AtlassianSite
    private let account: OSAllocatedUnfairLock<Account?>
    private let counts = OSAllocatedUnfairLock(initialState: Counts())
    /// Ephemeral: an image host's cookies are never kept.
    private static let externalSession = URLSession(configuration: .ephemeral)

    init(credential: AtlassianCredential) {
        site = credential.site
        account = OSAllocatedUnfairLock(initialState: Account(
            credential: credential,
            fetcher: AtlassianMediaFetcher(credential: credential)
        ))
    }

    /// A consistent copy of the counters (one lock acquisition).
    var snapshot: Counts {
        counts.withLock { $0 }
    }

    /// After an account change: a new credential gets a new fetcher (the old
    /// one's cloud ID and attachment lists belong to the old token); nil,
    /// the account was removed, makes every `.file` fetch fail.
    func use(_ credential: AtlassianCredential?) {
        account.withLock { current in
            guard let credential else {
                current = nil
                return
            }
            if current?.credential != credential {
                current = Account(credential: credential, fetcher: AtlassianMediaFetcher(credential: credential))
            }
        }
    }

    func fetch(_ attrs: MediaAttrs) async throws -> Data {
        counts.withLock {
            $0.calls += 1
            $0.inFlight += 1
        }
        do {
            let data = try await load(attrs)
            counts.withLock {
                $0.inFlight -= 1
                $0.fetched += 1
            }
            return data
        } catch {
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            let refused = error as? AtlassianMediaError == .unauthorized || error as? AtlassianMediaError == .forbidden
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            counts.withLock {
                $0.inFlight -= 1
                if cancelled {
                    $0.cancelled += 1
                } else {
                    $0.failed += 1
                    $0.refused += refused ? 1 : 0
                    $0.lastFailure = message
                }
            }
            throw error
        }
    }

    private func load(_ attrs: MediaAttrs) async throws -> Data {
        switch attrs.source {
        case .file:
            guard let fetcher = account.withLock({ $0?.fetcher }) else {
                throw AtlassianMediaError.unauthorized
            }
            return try await fetcher.data(for: attrs)
        case .external(let string):
            guard let url = URL(string: string), url.scheme?.lowercased() == "https",
                  let host = url.host(), !host.isEmpty else {
                throw ExternalError.unsupportedURL
            }
            var request = URLRequest(url: url, timeoutInterval: 60)
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            let (data, response) = try await Self.externalSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ExternalError.invalidResponse
            }
            guard (200 ..< 300).contains(http.statusCode) else {
                throw ExternalError.http(status: http.statusCode)
            }
            return data
        }
    }
}
