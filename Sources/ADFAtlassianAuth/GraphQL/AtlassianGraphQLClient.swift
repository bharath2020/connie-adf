import Foundation

/// The result of ``AtlassianGraphQLClient/checkToken()``.
public struct TokenCheckResult: Sendable, Equatable {
    /// The site's cloud ID (a UUID).
    public let cloudId: String
    /// The host name the gateway reported for the tenant, if any.
    public let hostName: String?

    public init(cloudId: String, hostName: String? = nil) {
        self.cloudId = cloudId
        self.hostName = hostName
    }
}

/// The result of ``AtlassianGraphQLClient/probePages(pageIds:cloudId:)``.
/// Partial data plus errors is a normal result.
public struct PageProbeResult: Sendable, Equatable {
    public struct Page: Sendable, Equatable {
        /// The page ARI.
        public let id: String?
        public let pageId: String
        public let title: String?
        public let spaceId: String?
        public let spaceKey: String?
        public let spaceName: String?
        /// The published title emoji (`metadata.titleEmojiPublished.value`).
        public let emoji: String?
        /// `links.base + links.webUi`, when both are present.
        public let webURL: URL?

        public init(id: String?, pageId: String, title: String?, spaceId: String?, spaceKey: String?, spaceName: String?, emoji: String?, webURL: URL?) {
            self.id = id
            self.pageId = pageId
            self.title = title
            self.spaceId = spaceId
            self.spaceKey = spaceKey
            self.spaceName = spaceName
            self.emoji = emoji
            self.webURL = webURL
        }
    }

    /// The non-null pages, in response order.
    public let pages: [Page]
    /// Every `errors[].message`, verbatim.
    public let errorMessages: [String]
    /// True when an error shows that `metadata` (title emoji) needs
    /// `read:content.metadata:confluence` and this token was created without it.
    public let emojiNeedsMetadataScope: Bool
    /// The response JSON, pretty-printed with sorted keys. Never contains
    /// the token (it is the server's response, not the request).
    public let rawJSON: String

    /// Plain-language note for ``emojiNeedsMetadataScope``.
    public static let metadataScopeNote = "Title emoji needs the \(AtlassianTokenScopes.contentMetadata) scope, which this token doesn't have. Create a new token with it (adf-auth rotate)."
}

/// Talks to the tenant GraphQL gateway (`https://<site>/gateway/api/graphql`)
/// with Basic `email:token` auth. GraphQL only; there is no REST fallback.
public struct AtlassianGraphQLClient: Sendable {
    public static let userAgent = "adf-auth/1"

    public let site: AtlassianSite
    public let email: String
    public let endpoint: URL
    private let token: String
    private let session: URLSession

    /// - Parameter endpoint: Overrides `site.graphQLEndpoint`. Only for stub
    ///   servers in tests.
    public init(site: AtlassianSite, email: String, token: String, endpoint: URL? = nil, session: URLSession = .shared) {
        self.site = site
        self.email = email
        self.token = token
        self.endpoint = endpoint ?? site.graphQLEndpoint
        self.session = session
    }

    public init(credential: AtlassianCredential, endpoint: URL? = nil, session: URLSession = .shared) {
        self.init(site: credential.site, email: credential.email, token: credential.token, endpoint: endpoint, session: session)
    }

    // MARK: Operations

    /// Runs `AdfAuthCheck` and returns the site's cloud ID.
    public func checkToken() async throws(AtlassianAuthError) -> TokenCheckResult {
        let operation = GraphQLOperation.authCheck(site: site)
        let (response, body) = try await send(operation)
        return try Self.parseTokenCheck(status: response.statusCode, headers: response.headerFields, body: body, operation: operation, host: site.host)
    }

    /// Runs `AdfProbePages` for page IDs on the site with `cloudId`.
    public func probePages(pageIds: [String], cloudId: String) async throws(AtlassianAuthError) -> PageProbeResult {
        let operation = GraphQLOperation.probePages(pageIds: pageIds, cloudId: cloudId)
        let (response, body) = try await send(operation)
        return try Self.parsePageProbe(status: response.statusCode, headers: response.headerFields, body: body, operation: operation, host: site.host)
    }

    // MARK: Requests

    /// The POST request for `operation`, with the Authorization header.
    func makeRequest(_ operation: GraphQLOperation, extraHeaders: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpBody = operation.body
        let basic = Data("\(email):\(token)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in extraHeaders.sorted(by: { $0.key < $1.key }) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    struct HTTPResult: Sendable {
        let statusCode: Int
        let headerFields: [String: String]
    }

    func send(_ operation: GraphQLOperation, extraHeaders: [String: String] = [:]) async throws(AtlassianAuthError) -> (HTTPResult, Data) {
        let request = makeRequest(operation, extraHeaders: extraHeaders)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw .network(error.code == .cancelled ? "The request was cancelled." : error.localizedDescription)
        } catch is CancellationError {
            throw .network("The request was cancelled.")
        } catch {
            throw .network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw .invalidResponse("not an HTTP response")
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key.lowercased()] = value }
        }
        return (HTTPResult(statusCode: http.statusCode, headerFields: headers), data)
    }

    // MARK: Parsing (pure, internal for tests)

    struct GatewayError: Equatable {
        let message: String
        let path: [String]
        let classification: String?
        let statusCode: Int?
        /// Message + classification + extensions, lowercased, for matching.
        let searchText: String
    }

    struct GatewayResponse {
        let data: [String: Any]?
        let errors: [GatewayError]
        let rawObject: [String: Any]
    }

    static func decodeGatewayBody(_ body: Data) -> GatewayResponse? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        let errors = (object["errors"] as? [Any] ?? []).compactMap { item -> GatewayError? in
            guard let dict = item as? [String: Any] else { return nil }
            let message = dict["message"] as? String ?? "Unknown error"
            let path = (dict["path"] as? [Any] ?? []).map { "\($0)" }
            let extensions = dict["extensions"] as? [String: Any] ?? [:]
            let classification = extensions["classification"] as? String ?? extensions["errorType"] as? String
            let statusCode = (extensions["statusCode"] as? Int) ?? (extensions["statusCode"] as? String).flatMap(Int.init)
            let extensionsText = (try? JSONSerialization.data(withJSONObject: extensions, options: [.sortedKeys]))
                .map { String(decoding: $0, as: UTF8.self) } ?? ""
            let searchText = "\(message) \(classification ?? "") \(extensionsText)".lowercased()
            return GatewayError(message: message, path: path, classification: classification, statusCode: statusCode, searchText: searchText)
        }
        return GatewayResponse(data: object["data"] as? [String: Any], errors: errors, rawObject: object)
    }

    /// True when the text says scoped / API / container tokens are not accepted.
    static func mentionsScopedToken(_ lowercasedText: String) -> Bool {
        lowercasedText.contains("scoped") || lowercasedText.contains("api token") || lowercasedText.contains("api_token")
            || lowercasedText.contains("apitoken") || lowercasedText.contains("container token")
    }

    static func isScopedRejection(_ error: GatewayError) -> Bool {
        // "scoped" is decisive; generic "API token" wording on a 401 is a bad
        // credential, not a scoped-token rejection.
        if error.searchText.contains("scoped") { return true }
        return error.statusCode != 401 && mentionsScopedToken(error.searchText)
    }

    static func isMetadataScopeError(_ error: GatewayError) -> Bool {
        error.path.contains("metadata") || error.searchText.contains(AtlassianTokenScopes.contentMetadata)
    }

    /// Maps errors that came with no usable data.
    static func classify(_ errors: [GatewayError], field: String, host: String, notFoundMeansSite: Bool) -> AtlassianAuthError {
        if let scoped = errors.first(where: isScopedRejection) {
            let path = scoped.path.filter { Int($0) == nil }.joined(separator: ".")
            return .scopedTokenRejected(field: path.isEmpty ? field : path, detail: scoped.message)
        }
        if errors.contains(where: { $0.statusCode == 401 || ($0.classification?.lowercased().contains("unauthor") ?? false) || ($0.classification?.lowercased().contains("unauthenticated") ?? false) }) {
            return .unauthorized
        }
        if errors.contains(where: { $0.statusCode == 403 || ($0.classification?.lowercased().contains("forbidden") ?? false) || ($0.classification?.lowercased().contains("permission") ?? false) }) {
            return .forbidden(missingScopes: AtlassianTokenScopes.required)
        }
        if errors.contains(where: { $0.classification == "CloudIdNotFoundException" || (notFoundMeansSite && $0.statusCode == 404) }) {
            return .siteNotFound(host: host)
        }
        return .graphQL(messages: errors.map(\.message))
    }

    /// Maps a non-2xx HTTP status. Returns nil for 2xx.
    static func httpError(status: Int, headers: [String: String], body: Data, field: String, host: String) -> AtlassianAuthError? {
        guard !(200..<300).contains(status) else { return nil }
        let gateway = decodeGatewayBody(body)
        let bodyText = String(decoding: body.prefix(4096), as: UTF8.self).lowercased()
        let detail = gateway?.errors.first?.message
            ?? (gateway?.rawObject["message"] as? String)
            ?? ""
        switch status {
        case 401:
            if bodyText.contains("scoped") { return .scopedTokenRejected(field: field, detail: detail) }
            return .unauthorized
        case 403:
            if mentionsScopedToken(bodyText) { return .scopedTokenRejected(field: field, detail: detail) }
            return .forbidden(missingScopes: AtlassianTokenScopes.required)
        case 404:
            return .siteNotFound(host: host)
        case 429:
            return .rateLimited(retryAfter: parseRetryAfter(headers["retry-after"]))
        case 400..<500:
            if let errors = gateway?.errors, !errors.isEmpty { return .graphQL(messages: errors.map(\.message)) }
            return .server(status: status)
        default:
            return .server(status: status)
        }
    }

    /// `Retry-After` as delta-seconds or an HTTP date.
    static func parseRetryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    static func parseTokenCheck(status: Int, headers: [String: String], body: Data, operation: GraphQLOperation, host: String) throws(AtlassianAuthError) -> TokenCheckResult {
        if let error = httpError(status: status, headers: headers, body: body, field: operation.field, host: host) { throw error }
        guard let response = decodeGatewayBody(body) else { throw .invalidResponse("the body is not a JSON object") }
        let contexts = response.data?["tenantContexts"] as? [Any]
        let entries = (contexts ?? []).compactMap { $0 as? [String: Any] }
        let candidates = entries.compactMap { context -> TokenCheckResult? in
            guard let cloudId = context["cloudId"] as? String, !cloudId.isEmpty else { return nil }
            return TokenCheckResult(cloudId: cloudId, hostName: context["hostName"] as? String)
        }
        // Only a tenant for this exact host counts. A tenant without a
        // hostName is accepted only when it is the sole entry.
        if let match = candidates.first(where: { $0.hostName?.lowercased() == host }) {
            return match
        }
        if entries.count == 1, let only = candidates.first, only.hostName == nil {
            return only
        }
        if !response.errors.isEmpty {
            throw classify(response.errors, field: operation.field, host: host, notFoundMeansSite: true)
        }
        if response.data == nil { throw .invalidResponse("no data and no errors") }
        throw .siteNotFound(host: host)
    }

    static func parsePageProbe(status: Int, headers: [String: String], body: Data, operation: GraphQLOperation, host: String) throws(AtlassianAuthError) -> PageProbeResult {
        if let error = httpError(status: status, headers: headers, body: body, field: operation.field, host: host) { throw error }
        guard let response = decodeGatewayBody(body) else { throw .invalidResponse("the body is not a JSON object") }

        let pagesValue = (response.data?["confluence"] as? [String: Any])?["pages"] as? [Any]
        let pages = (pagesValue ?? []).compactMap { $0 as? [String: Any] }.compactMap(parsePage)
        let pageErrors = response.errors.filter { !isMetadataScopeError($0) }

        if pagesValue == nil || pages.isEmpty {
            if pageErrors.contains(where: isScopedRejection) || (pagesValue == nil && !pageErrors.isEmpty) {
                throw classify(pageErrors, field: operation.field, host: host, notFoundMeansSite: false)
            }
            if pagesValue == nil && response.errors.isEmpty {
                throw .invalidResponse("no confluence.pages in the response")
            }
        }

        let pretty = (try? JSONSerialization.data(withJSONObject: response.rawObject, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? String(decoding: body, as: UTF8.self)
        return PageProbeResult(
            pages: pages,
            errorMessages: response.errors.map(\.message),
            emojiNeedsMetadataScope: response.errors.contains(where: isMetadataScopeError),
            rawJSON: pretty
        )
    }

    static func parsePage(_ page: [String: Any]) -> PageProbeResult.Page? {
        let pageId = (page["pageId"] as? String) ?? (page["pageId"] as? Int).map(String.init)
        guard let pageId else { return nil }
        let space = page["space"] as? [String: Any]
        let links = page["links"] as? [String: Any]
        let metadata = page["metadata"] as? [String: Any]
        let emoji = (metadata?["titleEmojiPublished"] as? [String: Any])?["value"] as? String
        var webURL: URL?
        if let base = links?["base"] as? String, let webUi = links?["webUi"] as? String {
            webURL = URL(string: base + webUi)
        }
        return PageProbeResult.Page(
            id: page["id"] as? String,
            pageId: pageId,
            title: page["title"] as? String,
            spaceId: space?["id"] as? String,
            spaceKey: space?["key"] as? String,
            spaceName: space?["name"] as? String,
            emoji: emoji,
            webURL: webURL
        )
    }
}

extension AtlassianGraphQLClient: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "AtlassianGraphQLClient(site: \(site.host), email: \(email), endpoint: \(endpoint.absoluteString), token: \(Redaction.token(token)))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: [
            "site": site.host,
            "email": email,
            "endpoint": endpoint.absoluteString,
            "token": Redaction.token(token),
        ], displayStyle: .struct)
    }
}
