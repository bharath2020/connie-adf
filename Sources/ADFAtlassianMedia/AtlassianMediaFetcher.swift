import Foundation
import ADFAtlassianAuth
import ADFModel

/// Fetches the raw bytes of Confluence attachments referenced by ADF `media`
/// nodes, with a scoped API token (Basic `email:token`) through
/// `https://api.atlassian.com/ex/confluence/{cloudId}`.
///
/// ```text
/// media(file id, collection "contentId-<page>")
///   -> cloudId (credential, else GET https://<site>/_edge/tenant_info, no auth)
///   -> GET  /wiki/api/v2/pages/<page>/attachments?limit=250   (cached per page,
///                                                              follows _links.next)
///   -> match attachment.fileId == media id
///   -> GET  /wiki/rest/api/content/<page>/child/attachment/<att id>/download
///      302 -> media host (Authorization stripped on any other host)
/// ```
///
/// Returns raw bytes; decoding and downsampling are the caller's job. The
/// plug point for the resolver layer is ``mediaFetch``.
///
/// Errors are ``AtlassianMediaError``, except transport failures (`URLError`)
/// and `CancellationError`, which are rethrown unchanged.
///
/// `print`, `dump` and string interpolation show only the site and API base,
/// never the email or token.
public actor AtlassianMediaFetcher {
    /// `https://api.atlassian.com`, the only base a scoped API token works on.
    public static let defaultAPIBase = URL(string: "https://api.atlassian.com")!
    /// The largest `limit` `getPageAttachments` accepts.
    static let listPageSize = 250
    /// At most this many list pages are read for one page (250 × 40 = 10 000
    /// attachments); the rest are ignored.
    static let maxListPages = 40
    static let userAgent = "adf-media/1"

    public nonisolated let site: AtlassianSite
    public nonisolated let apiBase: URL
    private let credential: AtlassianCredential
    private let session: URLSession

    private var cachedCloudId: String?
    private var cloudIdTask: Task<String, any Error>?
    private var attachmentCache: [String: [AtlassianAttachment]] = [:]
    private var listTasks: [String: Task<[AtlassianAttachment], any Error>] = [:]

    /// - Parameters:
    ///   - credential: Its `cloudId` is used when present; otherwise the
    ///     fetcher asks the site's `/_edge/tenant_info` once.
    ///   - session: Override only for stub sessions in tests.
    ///   - apiBase: Override only for stub servers in tests.
    public init(credential: AtlassianCredential, session: URLSession = .shared, apiBase: URL = AtlassianMediaFetcher.defaultAPIBase) {
        self.site = credential.site
        self.apiBase = apiBase
        self.credential = credential
        self.session = session
        if let cloudId = credential.cloudId, !cloudId.isEmpty {
            self.cachedCloudId = cloudId
        }
    }

    // MARK: Plug point

    /// The fetch closure for the resolver layer (`CacheFirstMediaProvider(fetch:)`
    /// in the resolver design): `.file` sources load through this fetcher,
    /// `.external` ones throw ``AtlassianMediaError/unsupportedSource``.
    public nonisolated var mediaFetch: @Sendable (MediaAttrs) async throws -> Data {
        { [self] attrs in try await self.data(for: attrs) }
    }

    /// The bytes of the attachment behind `attrs`.
    public func data(for attrs: MediaAttrs) async throws -> Data {
        switch attrs.source {
        case .file(let id, let collection):
            guard !id.isEmpty else { throw AtlassianMediaError.attachmentNotFound(fileId: id) }
            return try await data(fileId: id, collection: collection.isEmpty ? nil : collection, pageId: nil)
        case .external:
            throw AtlassianMediaError.unsupportedSource
        }
    }

    /// The bytes of the attachment with media file ID `fileId`.
    ///
    /// - Parameters:
    ///   - collection: The ADF media collection, `contentId-<page id>`.
    ///   - pageId: Wins over `collection` when given.
    public func data(fileId: String, collection: String? = nil, pageId: String? = nil) async throws -> Data {
        guard let page = Self.resolvePageId(explicit: pageId, collection: collection) else {
            throw AtlassianMediaError.missingPageId(collection: collection)
        }
        let match = try await findAttachment(fileId: fileId, pageId: page)
        let cloudId = try await resolvedCloudId()
        let path = "/wiki/rest/api/content/\(Self.pathSegment(page))/child/attachment/\(Self.pathSegment(match.id))/download"
        let url = try Self.makeURL(gatewayBase(cloudId: cloudId) + path)
        return try await send(authorizedRequest(url, accept: "*/*", timeout: 60))
    }

    // MARK: Attachments

    /// Every attachment of the page, across all list pages. Cached per page;
    /// concurrent calls for the same page share one request chain.
    public func attachments(pageId: String) async throws -> [AtlassianAttachment] {
        if let cached = attachmentCache[pageId] { return cached }
        if let running = listTasks[pageId] { return try await running.value }
        let task = Task { try await self.fetchAttachmentList(pageId: pageId) }
        listTasks[pageId] = task
        do {
            let list = try await task.value
            listTasks[pageId] = nil
            attachmentCache[pageId] = list
            return list
        } catch {
            listTasks[pageId] = nil
            throw error
        }
    }

    /// Looks `fileId` up in the page's list; a miss in a list that was already
    /// cached refetches it once (the page may have gained the attachment).
    private func findAttachment(fileId: String, pageId: String) async throws -> AtlassianAttachment {
        let wasCached = attachmentCache[pageId] != nil
        if let match = try await attachments(pageId: pageId).first(where: { $0.fileId == fileId }) {
            return match
        }
        if wasCached {
            attachmentCache[pageId] = nil
            if let match = try await attachments(pageId: pageId).first(where: { $0.fileId == fileId }) {
                return match
            }
        }
        throw AtlassianMediaError.attachmentNotFound(fileId: fileId)
    }

    private func fetchAttachmentList(pageId: String) async throws -> [AtlassianAttachment] {
        let cloudId = try await resolvedCloudId()
        let base = gatewayBase(cloudId: cloudId)
        var nextURL: URL? = try Self.makeURL(base + "/wiki/api/v2/pages/\(Self.pathSegment(pageId))/attachments?limit=\(Self.listPageSize)")
        var seen: Set<URL> = []
        var pagesRead = 0
        var all: [AtlassianAttachment] = []
        while let url = nextURL, pagesRead < Self.maxListPages, seen.insert(url).inserted {
            pagesRead += 1
            let body = try await send(authorizedRequest(url, accept: "application/json", timeout: 30))
            let page: AttachmentListResponse
            do {
                page = try JSONDecoder().decode(AttachmentListResponse.self, from: body)
            } catch {
                throw AtlassianMediaError.invalidResponse
            }
            all.append(contentsOf: page.attachments)
            nextURL = page.links?.next.flatMap { Self.resolveNextLink($0, gatewayBase: base, apiBase: apiBase) }
        }
        return all
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
        let url = try Self.makeURL("https://\(site.host)/_edge/tenant_info")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let body = try await send(request)
        guard let info = try? JSONDecoder().decode(TenantInfoResponse.self, from: body),
              let cloudId = info.cloudId, !cloudId.isEmpty else {
            throw AtlassianMediaError.invalidResponse
        }
        return cloudId
    }

    // MARK: Requests

    /// `{apiBase}/ex/confluence/{cloudId}`, without a trailing slash.
    private func gatewayBase(cloudId: String) -> String {
        Self.trimmingTrailingSlashes(apiBase.absoluteString) + "/ex/confluence/" + Self.pathSegment(cloudId)
    }

    /// A GET with Basic `email:token`, built like `AtlassianGraphQLClient`'s.
    private func authorizedRequest(_ url: URL, accept: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        let basic = Data("\(credential.email):\(credential.token)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
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
            if redirectGuard.refusedInsecureRedirect { throw AtlassianMediaError.insecureRedirect }
            throw error
        }
        if redirectGuard.refusedInsecureRedirect { throw AtlassianMediaError.insecureRedirect }
        guard let http = response as? HTTPURLResponse else { throw AtlassianMediaError.invalidResponse }
        if let error = AtlassianMediaError(status: http.statusCode) { throw error }
        return data
    }

    // MARK: Pure helpers (internal for tests)

    /// The page ID from an explicit value, else from a `contentId-<digits>`
    /// collection.
    static func resolvePageId(explicit: String?, collection: String?) -> String? {
        if let explicit = explicit?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return explicit
        }
        return collection.flatMap(pageId(fromCollection:))
    }

    /// `contentId-229377` → `229377`; anything else → nil.
    static func pageId(fromCollection collection: String) -> String? {
        let prefix = "contentId-"
        guard collection.hasPrefix(prefix) else { return nil }
        let digits = collection.dropFirst(prefix.count)
        guard !digits.isEmpty, digits.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return String(digits)
    }

    /// Resolves `_links.next` against the gateway, never against another
    /// host: only the path and query are used.
    ///
    /// - `/wiki/api/v2/…?cursor=…` (the documented shape) → `{gatewayBase}/wiki/api/v2/…`
    /// - `/ex/confluence/{cloudId}/wiki/…` (already gateway-relative) → `{apiBase}/ex/…`
    /// - `/api/v2/…` (relative to `_links.base`, `<site>/wiki`) → `{gatewayBase}/wiki/api/v2/…`
    /// - an absolute URL → its path and query, as above
    static func resolveNextLink(_ next: String, gatewayBase: String, apiBase: URL) -> URL? {
        let trimmed = next.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let components = URLComponents(string: trimmed) else { return nil }
        let path = components.percentEncodedPath
        guard path.hasPrefix("/") else { return nil }
        let query = components.percentEncodedQuery.map { "?" + $0 } ?? ""
        let prefix: String
        if path.hasPrefix("/ex/confluence/") {
            prefix = trimmingTrailingSlashes(apiBase.absoluteString)
        } else if path.hasPrefix("/wiki/") {
            prefix = gatewayBase
        } else {
            prefix = gatewayBase + "/wiki"
        }
        return URL(string: prefix + path + query)
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

    private static func makeURL(_ string: String) throws -> URL {
        guard let url = URL(string: string) else { throw AtlassianMediaError.invalidResponse }
        return url
    }
}

extension AtlassianMediaFetcher: CustomStringConvertible, CustomReflectable {
    public nonisolated var description: String {
        "AtlassianMediaFetcher(site: \(site.host), apiBase: \(apiBase.absoluteString))"
    }

    public nonisolated var customMirror: Mirror {
        Mirror(self, children: ["site": site.host, "apiBase": apiBase.absoluteString], displayStyle: .class)
    }
}
