import Foundation
import ADFAtlassianAuth

/// Fetches the image bytes behind ADF `emoji` nodes (standard, Atlassian and
/// site custom emoji) through Atlassian's **undocumented** emoji service, the
/// one Atlassian's own editor (`@atlaskit/emoji`) uses. There is no official
/// API or token scope for custom emoji (CONFCLOUD-73225), so the app keeps
/// this behind its own setting and renders the `:shortName:` text whenever
/// it is off or this fetcher throws.
///
/// ```text
/// emoji(id?, shortName)
///   -> cloudId (credential, else GET https://<site>/_edge/tenant_info, no auth)
///   -> id:        GET {api}/emoji/{cloudId}/{id}?preferredRepresentation=IMAGE      (no auth)
///      no id / 404 -> shortName in GET {api}/emoji/{cloudId}/site?preferredRepresentation=IMAGE
///                                                       (cached, one in flight, no auth)
///   -> representation.imagePath
///      public CDN (standard/Atlassian): GET imagePath, no headers added
///      media host (site emoji):         GET imagePath with
///          Authorization: Bearer <read jwt> + X-Client-Id: <clientId>
///          read token: meta.mediaApiToken or GET {api}/emoji/{cloudId}/site/token/read
///          (cached until expiresAt - 60 s, one refresh in flight, refreshed once on 401/403)
///   -> raw bytes (2xx)
/// ```
///
/// The emoji service answers without credentials and ignores Basic auth, so
/// the scoped API token is **never sent**: the credential only supplies the
/// site and cloud ID. The read token goes only to `https` media hosts
/// (`api.media.atlassian.com`, or the site's own `/media-api/`); public
/// images are fetched only from `https` Atlassian CDN hosts. A redirect to
/// another host drops `Authorization` and `X-Client-Id`.
///
/// Returns raw bytes; decoding and downsampling are the caller's job. The
/// plug point for the resolver layer is ``emojiFetch``.
///
/// Errors are ``AtlassianEmojiError``, except transport failures
/// (`URLError`) and `CancellationError`, which are rethrown unchanged.
///
/// `print`, `dump` and string interpolation show only the site and API base,
/// never a token.
public actor AtlassianEmojiFetcher {
    /// `https://api.atlassian.com`; the site's `/gateway/api` answers the
    /// same.
    public static let defaultAPIBase = URL(string: "https://api.atlassian.com")!
    /// A cached read token is reused until this long before its expiry.
    static let tokenExpiryMargin: TimeInterval = 60
    /// Used when a token response has no `expiresAt` (observed tokens last
    /// 59 minutes).
    static let fallbackTokenLifetime: TimeInterval = 5 * 60
    /// A short-name miss refetches a cached site list at most this often.
    static let siteListMinRefetchInterval: TimeInterval = 60
    /// The media host Atlassian's own media client uses.
    static let mediaHost = "api.media.atlassian.com"
    /// Host suffixes that serve the public standard/Atlassian emoji images
    /// (observed: `pf-emoji-service.prod-east.frontend.public.atl-paas.net`).
    static let publicImageHostSuffixes = [".atl-paas.net", ".atlassian.com"]
    static let userAgent = "adf-emoji/1"

    public nonisolated let site: AtlassianSite
    public nonisolated let apiBase: URL
    private let session: URLSession
    private let now: @Sendable () -> Date

    private var cachedCloudId: String?
    private var cloudIdTask: Task<String, any Error>?
    private var emojiCache: [String: EmojiImageReference] = [:]
    private var siteList: (emojis: [EmojiImageReference], fetchedAt: Date)?
    private var siteListTask: Task<[EmojiImageReference], any Error>?
    private var readToken: EmojiReadToken?
    private var tokenTask: Task<EmojiReadToken, any Error>?

    /// - Parameters:
    ///   - credential: Supplies the site and, when present, the cloud ID
    ///     (otherwise the fetcher asks the site's `/_edge/tenant_info` once).
    ///     Its email and token are not kept and never sent.
    ///   - session: Override only for stub sessions in tests.
    ///   - apiBase: Override only for stub servers in tests.
    public init(credential: AtlassianCredential, session: URLSession = .shared, apiBase: URL = AtlassianEmojiFetcher.defaultAPIBase) {
        self.init(credential: credential, session: session, apiBase: apiBase, now: { Date() })
    }

    /// Tests inject the clock.
    init(credential: AtlassianCredential, session: URLSession, apiBase: URL, now: @escaping @Sendable () -> Date) {
        self.site = credential.site
        self.apiBase = apiBase
        self.session = session
        self.now = now
        if let cloudId = credential.cloudId, !cloudId.isEmpty {
            self.cachedCloudId = cloudId
        }
    }

    // MARK: Plug point

    /// The fetch closure for the resolver layer. The resolver design's
    /// closure takes an `ADFEmojiReference { id: String?, shortName: String }`;
    /// adapt it with
    /// `{ ref in try await fetcher.emojiFetch(ref.id, ref.shortName) }`.
    public nonisolated var emojiFetch: @Sendable (_ id: String?, _ shortName: String) async throws -> Data {
        { [self] id, shortName in try await self.data(emojiId: id, shortName: shortName) }
    }

    /// The image bytes of an emoji: by `emojiId` when present (falling back
    /// to `shortName` when the service has no such ID), otherwise by
    /// `shortName` (with or without colons) among the site's custom emoji.
    public func data(emojiId: String?, shortName: String) async throws -> Data {
        let reference = try await resolve(emojiId: emojiId, shortName: shortName)
        return try await image(for: reference)
    }

    // MARK: Lookup

    private func resolve(emojiId: String?, shortName: String) async throws -> EmojiImageReference {
        let id = emojiId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !id.isEmpty {
            if let cached = emojiCache[id] { return cached }
            do {
                let reference = try await fetchEmoji(id: id)
                emojiCache[id] = reference
                return reference
            } catch AtlassianEmojiError.notFound where Self.normalizedShortName(shortName) != nil {
                // An ID from another site (copied content): try the name.
            }
        }
        guard let name = Self.normalizedShortName(shortName) else { throw AtlassianEmojiError.notFound }
        return try await siteEmoji(shortName: name)
    }

    private func fetchEmoji(id: String) async throws -> EmojiImageReference {
        let url = try await serviceURL(Self.pathSegment(id) + "?preferredRepresentation=IMAGE")
        let response = try await fetchServiceResponse(url)
        guard let emoji = response.emojis?.first else { throw AtlassianEmojiError.notFound }
        guard let reference = EmojiImageReference(emoji) else { throw AtlassianEmojiError.invalidResponse }
        return reference
    }

    /// A site emoji by `:name:`; a miss in a cached list older than
    /// ``siteListMinRefetchInterval`` refetches it once.
    private func siteEmoji(shortName: String) async throws -> EmojiImageReference {
        let cachedAt = siteList?.fetchedAt
        if let match = try await siteEmojis().first(where: { $0.shortName == shortName }) {
            return match
        }
        if let cachedAt, now().timeIntervalSince(cachedAt) >= Self.siteListMinRefetchInterval {
            siteList = nil
            if let match = try await siteEmojis().first(where: { $0.shortName == shortName }) {
                return match
            }
        }
        throw AtlassianEmojiError.notFound
    }

    /// The site's custom emoji that have an image. Cached; concurrent calls
    /// share one request.
    func siteEmojis() async throws -> [EmojiImageReference] {
        if let siteList { return siteList.emojis }
        if let siteListTask { return try await siteListTask.value }
        let task = Task { try await self.fetchSiteList() }
        siteListTask = task
        do {
            let list = try await task.value
            siteListTask = nil
            siteList = (list, now())
            return list
        } catch {
            siteListTask = nil
            throw error
        }
    }

    private func fetchSiteList() async throws -> [EmojiImageReference] {
        let url = try await serviceURL("site?preferredRepresentation=IMAGE")
        let response = try await fetchServiceResponse(url)
        return (response.emojis ?? []).compactMap(EmojiImageReference.init)
    }

    /// GETs an emoji service URL without credentials, decodes it, and keeps
    /// its `meta.mediaApiToken` when no valid read token is cached.
    private func fetchServiceResponse(_ url: URL) async throws -> EmojiServiceResponse {
        let body = try await send(plainRequest(url, accept: "application/json"))
        let response: EmojiServiceResponse
        do {
            response = try JSONDecoder().decode(EmojiServiceResponse.self, from: body)
        } catch {
            throw AtlassianEmojiError.invalidResponse
        }
        if !hasValidToken, let token = response.meta?.mediaApiToken?.readToken(defaultExpiry: now() + Self.fallbackTokenLifetime) {
            readToken = token
        }
        return response
    }

    // MARK: Images

    private func image(for reference: EmojiImageReference) async throws -> Data {
        guard let url = URL(string: reference.imagePath) else { throw AtlassianEmojiError.invalidResponse }
        switch try Self.classifyImageURL(url, siteHost: site.host) {
        case .publicImage:
            return try await send(plainRequest(url, accept: "image/*"))
        case .media:
            let token = try await validReadToken()
            do {
                return try await send(mediaRequest(url, token: token))
            } catch AtlassianEmojiError.unauthorized {
                let fresh = try await refreshedReadToken(rejecting: token)
                return try await send(mediaRequest(url, token: fresh))
            }
        }
    }

    enum ImageHostKind: Equatable {
        /// A public CDN image: fetched with no credentials.
        case publicImage
        /// A media-services image: fetched with the read token.
        case media
    }

    /// Where an image URL may be fetched from, and how. Pure; internal for
    /// tests.
    ///
    /// - not `https` → ``AtlassianEmojiError/insecureURL``
    /// - `api.media.atlassian.com`, or `<site host>/media-api/…` → `.media`
    /// - a host ending in ``publicImageHostSuffixes`` → `.publicImage`
    /// - anything else → ``AtlassianEmojiError/unsupportedHost``
    static func classifyImageURL(_ url: URL, siteHost: String) throws -> ImageHostKind {
        guard url.scheme?.lowercased() == "https" else { throw AtlassianEmojiError.insecureURL }
        guard let host = url.host()?.lowercased(), !host.isEmpty, url.user == nil, url.password == nil else {
            throw AtlassianEmojiError.unsupportedHost
        }
        if url.port != nil && url.port != 443 { throw AtlassianEmojiError.unsupportedHost }
        if host == mediaHost { return .media }
        if host == siteHost.lowercased() && url.path().hasPrefix("/media-api/") { return .media }
        if publicImageHostSuffixes.contains(where: { host.hasSuffix($0) }) {
            return .publicImage
        }
        throw AtlassianEmojiError.unsupportedHost
    }

    // MARK: Read token

    private var hasValidToken: Bool {
        guard let readToken else { return false }
        return now() < readToken.expiresAt - Self.tokenExpiryMargin
    }

    /// The cached read token while it is valid, else a fresh one (one
    /// request in flight at a time).
    func validReadToken() async throws -> EmojiReadToken {
        if hasValidToken, let readToken { return readToken }
        return try await refreshToken()
    }

    /// A token other than `rejected`: a newer cached one, the in-flight
    /// refresh, or a new request.
    private func refreshedReadToken(rejecting rejected: EmojiReadToken) async throws -> EmojiReadToken {
        if let readToken, readToken.jwt != rejected.jwt { return readToken }
        if readToken == rejected { readToken = nil }
        return try await refreshToken()
    }

    private func refreshToken() async throws -> EmojiReadToken {
        if let tokenTask { return try await tokenTask.value }
        let task = Task { try await self.fetchReadToken() }
        tokenTask = task
        do {
            let token = try await task.value
            tokenTask = nil
            readToken = token
            return token
        } catch {
            tokenTask = nil
            throw error
        }
    }

    private func fetchReadToken() async throws -> EmojiReadToken {
        let url = try await serviceURL("site/token/read")
        let body = try await send(plainRequest(url, accept: "application/json"))
        guard let wire = try? JSONDecoder().decode(MediaAPIToken.self, from: body),
              let token = wire.readToken(defaultExpiry: now() + Self.fallbackTokenLifetime) else {
            throw AtlassianEmojiError.invalidResponse
        }
        return token
    }

    // MARK: Cloud ID

    /// The site's cloud ID: the credential's, else `/_edge/tenant_info`
    /// (fetched once, without auth, then cached).
    public func resolvedCloudId() async throws -> String {
        if let cachedCloudId { return cachedCloudId }
        if let cloudIdTask { return try await cloudIdTask.value }
        let task = Task { try await self.fetchCloudId() }
        cloudIdTask = task
        do {
            let value = try await task.value
            cloudIdTask = nil
            cachedCloudId = value
            return value
        } catch {
            cloudIdTask = nil
            throw error
        }
    }

    private func fetchCloudId() async throws -> String {
        guard let url = URL(string: "https://\(site.host)/_edge/tenant_info") else { throw AtlassianEmojiError.invalidResponse }
        let body = try await send(plainRequest(url, accept: "application/json"))
        guard let info = try? JSONDecoder().decode(TenantInfoResponse.self, from: body),
              let cloudId = info.cloudId, !cloudId.isEmpty else {
            throw AtlassianEmojiError.invalidResponse
        }
        return cloudId
    }

    // MARK: Requests

    /// `{apiBase}/emoji/{cloudId}/{suffix}`.
    private func serviceURL(_ suffix: String) async throws -> URL {
        let cloudId = try await resolvedCloudId()
        let string = Self.trimmingTrailingSlashes(apiBase.absoluteString) + "/emoji/" + Self.pathSegment(cloudId) + "/" + suffix
        guard let url = URL(string: string) else { throw AtlassianEmojiError.invalidResponse }
        return url
    }

    /// A GET with no credentials.
    private func plainRequest(_ url: URL, accept: String) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// A GET with the read token, as `@atlaskit/emoji`'s `MediaImageLoader`
    /// sends it.
    private func mediaRequest(_ url: URL, token: EmojiReadToken) -> URLRequest {
        var request = plainRequest(url, accept: "image/*")
        request.setValue("Bearer \(token.jwt)", forHTTPHeaderField: "Authorization")
        request.setValue(token.clientId, forHTTPHeaderField: "X-Client-Id")
        return request
    }

    /// Runs `request` with an ``AuthRedirectGuard`` and returns the body of a
    /// 2xx response.
    private func send(_ request: URLRequest) async throws -> Data {
        let redirectGuard = AuthRedirectGuard(originalHost: request.url?.host())
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: redirectGuard)
        } catch {
            if redirectGuard.refusedInsecureRedirect { throw AtlassianEmojiError.insecureURL }
            throw error
        }
        if redirectGuard.refusedInsecureRedirect { throw AtlassianEmojiError.insecureURL }
        guard let http = response as? HTTPURLResponse else { throw AtlassianEmojiError.invalidResponse }
        if let error = AtlassianEmojiError(status: http.statusCode) { throw error }
        return data
    }

    // MARK: Pure helpers (internal for tests)

    /// `grinning`, `:grinning:` → `:grinning:`; empty or `::` → nil.
    static func normalizedShortName(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix(":") { name.removeFirst() }
        if name.hasSuffix(":") { name.removeLast() }
        guard !name.isEmpty else { return nil }
        return ":" + name + ":"
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Percent-encodes everything but unreserved characters, so an ID can
    /// never add path segments or a query.
    static func pathSegment(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static func trimmingTrailingSlashes(_ string: String) -> String {
        var result = string
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }
}

extension AtlassianEmojiFetcher: CustomStringConvertible, CustomReflectable {
    public nonisolated var description: String {
        "AtlassianEmojiFetcher(site: \(site.host), apiBase: \(apiBase.absoluteString))"
    }

    public nonisolated var customMirror: Mirror {
        Mirror(self, children: ["site": site.host, "apiBase": apiBase.absoluteString], displayStyle: .class)
    }
}
