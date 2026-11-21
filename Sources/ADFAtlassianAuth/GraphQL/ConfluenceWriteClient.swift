import Foundation

/// Failures writing to Confluence, each with a user-facing ``message``.
public enum ConfluenceWriteError: Error, Sendable, Equatable {
    /// The stored token was created without the write scopes. Found before
    /// any request is sent. A new token is needed (`adf-auth rotate`).
    case readOnlyToken(host: String, missingScopes: [String])
    /// The credential has no cloud ID. `adf-auth login` saves one.
    case missingCloudId(host: String)
    /// The ADF body is not a JSON object with `"type": "doc"`.
    case invalidDocument(String)
    /// HTTP 401, or a GraphQL / mutation error with status 401.
    case unauthorized
    /// HTTP 403, or a 403 / forbidden error: the token lacks `scopes` or the
    /// account lacks permission on the content.
    case missingScope(scopes: [String], detail: String)
    /// The gateway refused a scoped API token for `field`. No fallback.
    case scopedTokenRejected(field: String, detail: String)
    /// The page, comment, space or site does not exist or is not visible.
    case notFound(String)
    /// The page is no longer at `expected`. `current` is the version the
    /// gateway reported, when known.
    case versionConflict(pageId: String, expected: Int, current: Int?)
    /// HTTP 429 or a 429 error. `retryAfter` comes from `Retry-After`.
    case rateLimited(retryAfter: TimeInterval?)
    /// The mutation returned `success: false` or GraphQL errors with no
    /// more specific meaning. `messages` are the gateway's, verbatim.
    case mutationFailed(field: String, messages: [String])
    /// Any other non-2xx status.
    case server(status: Int)
    case invalidResponse(String)
    /// A transport failure (never includes request headers).
    case network(String)

    public var message: String {
        switch self {
        case .readOnlyToken(let host, let missingScopes):
            return "The saved token for \(host) is read-only (no \(missingScopes.joined(separator: ", "))). Atlassian can't add scopes to a token: create a new one with adf-auth rotate \(host)."
        case .missingCloudId(let host):
            return "The saved account for \(host) has no cloud ID. Run adf-auth login again."
        case .invalidDocument(let detail):
            return "The page body is not an ADF document: \(detail)"
        case .unauthorized:
            return "Atlassian rejected the email or token. Check both, or create a new token with adf-auth rotate."
        case .missingScope(let scopes, let detail):
            var text = "Atlassian refused the write. The token needs \(scopes.joined(separator: ", ")) and your account needs permission on this content."
            if !detail.isEmpty { text += " Atlassian said: \(detail)" }
            return text
        case .scopedTokenRejected(let field, let detail):
            var text = "This site's GraphQL gateway does not accept scoped API tokens for \(field). ADFReader writes through GraphQL only."
            if !detail.isEmpty { text += " Atlassian said: \(detail)" }
            return text
        case .notFound(let what):
            return "Not found: \(what). It may have been deleted, or your account can't see it."
        case .versionConflict(let pageId, let expected, let current):
            let now = current.map { "is now at version \($0)" } ?? "has changed"
            return "Page \(pageId) \(now), not version \(expected). Someone else edited it: reload it and apply the change again."
        case .rateLimited(let retryAfter):
            if let retryAfter, retryAfter > 0 {
                return "Atlassian is limiting requests. Try again in \(Int(retryAfter.rounded(.up))) seconds."
            }
            return "Atlassian is limiting requests. Try again in a minute."
        case .mutationFailed(let field, let messages):
            let joined = messages.isEmpty ? "no details" : messages.joined(separator: "; ")
            return "Atlassian did not apply \(field): \(joined)"
        case .server(let status):
            return "Atlassian returned HTTP \(status). Try again later."
        case .invalidResponse(let detail):
            return "Unexpected response from Atlassian: \(detail)"
        case .network(let detail):
            return "Couldn't reach Atlassian: \(detail)"
        }
    }
}

/// A page or blog post the gateway created or updated.
public struct ConfluenceWrittenContent: Sendable, Equatable {
    /// The content ARI.
    public let id: String
    /// The plain page or blog post ID.
    public let contentId: String
    public let title: String?
    /// `latestVersion.number` after the write.
    public let version: Int?
    /// `links.base + links.webUi`, when both are present.
    public let webURL: URL?

    public init(id: String, contentId: String, title: String?, version: Int?, webURL: URL?) {
        self.id = id
        self.contentId = contentId
        self.title = title
        self.version = version
        self.webURL = webURL
    }
}

/// A footer comment or reply the gateway created.
public struct ConfluenceWrittenComment: Sendable, Equatable {
    /// The comment ARI.
    public let id: String
    /// The plain comment ID, when the gateway returns it.
    public let commentId: String?
    public let webURL: URL?

    public init(id: String, commentId: String?, webURL: URL?) {
        self.id = id
        self.commentId = commentId
        self.webURL = webURL
    }
}

/// A page's current title and version, read before an update.
public struct ConfluencePageVersion: Sendable, Equatable {
    public let pageId: String
    public let title: String?
    public let number: Int

    public init(pageId: String, title: String?, number: Int) {
        self.pageId = pageId
        self.title = title
        self.number = number
    }
}

/// Writes to Confluence through the tenant GraphQL gateway's
/// `confluence(cloudId:)` mutations. GraphQL only; no REST fallback.
///
/// Every write first checks that the stored credential was created with the
/// write scope it needs, and fails with ``ConfluenceWriteError/readOnlyToken(host:missingScopes:)``
/// without sending anything when it was not.
///
/// IDs may be plain IDs (`"229377"`) or ARIs; plain IDs are sent as
/// `ari:cloud:confluence:<cloudId>:<kind>/<id>`. Space IDs are sent exactly
/// as given (use the `space.id` the gateway returns).
public struct ConfluenceWriteClient: Sendable {
    public let cloudId: String
    let graphQL: AtlassianGraphQLClient
    let scopes: [String]

    /// - Parameters:
    ///   - cloudId: Overrides `credential.cloudId`.
    ///   - endpoint: Overrides the site's GraphQL endpoint. Only for stub
    ///     servers in tests.
    public init(credential: AtlassianCredential, cloudId: String? = nil, endpoint: URL? = nil, session: URLSession = .shared) throws(ConfluenceWriteError) {
        guard let resolved = cloudId ?? credential.cloudId, !resolved.isEmpty else {
            throw .missingCloudId(host: credential.site.host)
        }
        self.cloudId = resolved
        self.scopes = credential.scopes
        self.graphQL = AtlassianGraphQLClient(credential: credential, endpoint: endpoint, session: session)
    }

    var host: String { graphQL.site.host }

    // MARK: Comments

    /// Adds a footer comment to a published page.
    public func createFooterComment(pageId: String, adf: String) async throws(ConfluenceWriteError) -> ConfluenceWrittenComment {
        try requireScope(AtlassianTokenScopes.writeComment)
        try Self.validateDocument(adf)
        let operation = GraphQLOperation.createFooterComment(cloudId: cloudId, pageARI: ari("page", pageId), adf: adf)
        let payload = try await mutate(operation, payloadKey: "createFooterCommentOnPage", scope: AtlassianTokenScopes.writeComment, subject: "page \(pageId)")
        return try Self.parseComment(payload, field: operation.field)
    }

    /// Replies to a footer comment.
    public func replyToComment(commentId: String, adf: String) async throws(ConfluenceWriteError) -> ConfluenceWrittenComment {
        try requireScope(AtlassianTokenScopes.writeComment)
        try Self.validateDocument(adf)
        let operation = GraphQLOperation.replyToComment(cloudId: cloudId, parentCommentARI: ari("comment", commentId), adf: adf)
        let payload = try await mutate(operation, payloadKey: "replyToComment", scope: AtlassianTokenScopes.writeComment, subject: "comment \(commentId)")
        return try Self.parseComment(payload, field: operation.field)
    }

    // MARK: Pages and blog posts

    /// Creates and publishes a page at the top level of a space.
    public func createPage(spaceId: String, title: String, adf: String) async throws(ConfluenceWriteError) -> ConfluenceWrittenContent {
        try requireScope(AtlassianTokenScopes.writePage)
        try Self.validateDocument(adf)
        let operation = GraphQLOperation.createPage(cloudId: cloudId, spaceId: spaceId, title: title, adf: adf)
        let payload = try await mutate(operation, payloadKey: "createPage", scope: AtlassianTokenScopes.writePage, subject: "space \(spaceId)")
        return try Self.parseContent(payload, objectKey: "page", idKey: "pageId", field: operation.field)
    }

    /// Creates and publishes a blog post in a space.
    public func createBlogPost(spaceId: String, title: String, adf: String) async throws(ConfluenceWriteError) -> ConfluenceWrittenContent {
        try requireScope(AtlassianTokenScopes.writeBlogPost)
        try Self.validateDocument(adf)
        let operation = GraphQLOperation.createBlogPost(cloudId: cloudId, spaceId: spaceId, title: title, adf: adf)
        let payload = try await mutate(operation, payloadKey: "createBlogPost", scope: AtlassianTokenScopes.writeBlogPost, subject: "space \(spaceId)")
        return try Self.parseContent(payload, objectKey: "blogPost", idKey: "blogPostId", field: operation.field)
    }

    /// The page's current title and version number.
    public func pageVersion(pageId: String) async throws(ConfluenceWriteError) -> ConfluencePageVersion {
        let operation = GraphQLOperation.pageVersion(pageARI: ari("page", pageId))
        let (status, headers, body) = try await send(operation)
        return try Self.parsePageVersion(status: status, headers: headers, body: body, pageId: pageId, field: operation.field, host: host)
    }

    /// Replaces a published page's body with `adf`, making version
    /// `expectedVersion + 1`.
    ///
    /// `updateCurrentPage` takes no version number, so the client reads the
    /// current version first and throws ``ConfluenceWriteError/versionConflict(pageId:expected:current:)``
    /// when it is not `expectedVersion`. A conflict error from the mutation
    /// itself is reported the same way.
    ///
    /// - Parameter title: The new title; nil keeps the current one.
    /// - Important: The read and the write are two requests. An edit that
    ///   lands between them is not detected beforehand; the returned
    ///   `version` is then higher than `expectedVersion + 1`.
    public func updatePageBody(pageId: String, adf: String, title: String? = nil, expectedVersion: Int) async throws(ConfluenceWriteError) -> ConfluenceWrittenContent {
        try requireScope(AtlassianTokenScopes.writePage)
        try Self.validateDocument(adf)
        let current = try await pageVersion(pageId: pageId)
        guard current.number == expectedVersion else {
            throw .versionConflict(pageId: pageId, expected: expectedVersion, current: current.number)
        }
        let operation = GraphQLOperation.updatePage(cloudId: cloudId, pageARI: ari("page", pageId), title: title ?? current.title ?? "", adf: adf)
        let conflict = (pageId: pageId, expected: expectedVersion)
        let payload = try await mutate(operation, payloadKey: "updateCurrentPage", scope: AtlassianTokenScopes.writePage, subject: "page \(pageId)", conflict: conflict)
        return try Self.parseContent(payload, objectKey: "page", idKey: "pageId", field: operation.field)
    }

    // MARK: Plumbing

    private func ari(_ kind: String, _ id: String) -> String {
        GraphQLOperation.confluenceARI(cloudId: cloudId, kind: kind, id: id)
    }

    /// Comment writes also need ``AtlassianTokenScopes/readComment`` to read
    /// back the comment they create.
    private func requireScope(_ scope: String) throws(ConfluenceWriteError) {
        let needed = scope == AtlassianTokenScopes.writeComment ? [scope, AtlassianTokenScopes.readComment] : [scope]
        guard needed.allSatisfy(scopes.contains) else {
            throw .readOnlyToken(host: host, missingScopes: AtlassianTokenScopes.missingWriteScopes(in: scopes))
        }
    }

    private func send(_ operation: GraphQLOperation) async throws(ConfluenceWriteError) -> (Int, [String: String], Data) {
        do {
            let (response, body) = try await graphQL.send(operation, extraHeaders: [ConfluenceWriteDocuments.betaHeader.name: ConfluenceWriteDocuments.betaHeader.value])
            return (response.statusCode, response.headerFields, body)
        } catch {
            throw Self.map(error, scope: nil, subject: operation.field)
        }
    }

    /// Sends a mutation and returns its payload object (`data.confluence.<payloadKey>`)
    /// once `success` is true.
    private func mutate(_ operation: GraphQLOperation, payloadKey: String, scope: String, subject: String, conflict: (pageId: String, expected: Int)? = nil) async throws(ConfluenceWriteError) -> [String: Any] {
        let (status, headers, body) = try await send(operation)
        return try Self.parseMutation(status: status, headers: headers, body: body, payloadKey: payloadKey, field: operation.field, scope: scope, subject: subject, host: host, conflict: conflict)
    }

    // MARK: Parsing (pure, internal for tests)

    static func validateDocument(_ adf: String) throws(ConfluenceWriteError) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(adf.utf8))) as? [String: Any] else {
            throw .invalidDocument("not a JSON object")
        }
        guard object["type"] as? String == "doc" else {
            throw .invalidDocument("the root node is not \"type\": \"doc\"")
        }
    }

    static func mentionsConflict(_ messages: [String]) -> Bool {
        messages.contains { message in
            let text = message.lowercased()
            return text.contains("conflict") || text.contains("stale") || (text.contains("version") && (text.contains("mismatch") || text.contains("outdated") || text.contains("latest")))
        }
    }

    /// Maps a transport / HTTP-level error from the shared GraphQL client.
    static func map(_ error: AtlassianAuthError, scope: String?, subject: String) -> ConfluenceWriteError {
        switch error {
        case .unauthorized: return .unauthorized
        case .forbidden: return .missingScope(scopes: scope.map { [$0] } ?? AtlassianTokenScopes.write, detail: "")
        case .scopedTokenRejected(let field, let detail): return .scopedTokenRejected(field: field, detail: detail)
        case .siteNotFound(let host): return .notFound("the site \(host)")
        case .rateLimited(let retryAfter): return .rateLimited(retryAfter: retryAfter)
        case .server(let status): return .server(status: status)
        case .graphQL(let messages): return .mutationFailed(field: subject, messages: messages)
        case .invalidResponse(let detail): return .invalidResponse(detail)
        case .network(let detail): return .network(detail)
        }
    }

    /// One error from either `errors[]` (top level) or a payload's `errors[]`.
    struct WriteError {
        let message: String
        let statusCode: Int?
        /// `classification` or `errorType`.
        let kind: String?
        /// Message + kind, lowercased, for matching.
        let searchText: String
    }

    static func writeErrors(_ list: Any?) -> [WriteError] {
        (list as? [Any] ?? []).compactMap { item -> WriteError? in
            guard let dict = item as? [String: Any] else { return nil }
            let message = dict["message"] as? String ?? "Unknown error"
            let extensions = dict["extensions"] as? [String: Any] ?? [:]
            let kind = extensions["errorType"] as? String ?? extensions["classification"] as? String
            let statusCode = (extensions["statusCode"] as? Int) ?? (extensions["statusCode"] as? String).flatMap(Int.init)
            return WriteError(message: message, statusCode: statusCode, kind: kind, searchText: "\(message) \(kind ?? "")".lowercased())
        }
    }

    /// Classifies errors that came with no usable result.
    static func classify(_ errors: [WriteError], field: String, scope: String?, subject: String) -> ConfluenceWriteError {
        let kinds = errors.map { ($0.kind ?? "").lowercased() }
        if let scoped = errors.first(where: { $0.searchText.contains("scoped") }) {
            return .scopedTokenRejected(field: field, detail: scoped.message)
        }
        if errors.contains(where: { $0.statusCode == 429 || ($0.kind ?? "").lowercased().contains("ratelimit") }) {
            return .rateLimited(retryAfter: nil)
        }
        if errors.contains(where: { $0.statusCode == 401 }) || kinds.contains(where: { $0.contains("unauthor") || $0.contains("unauthenticated") }) {
            return .unauthorized
        }
        if let forbidden = errors.first(where: { $0.statusCode == 403 || ($0.kind ?? "").lowercased().contains("forbidden") || ($0.kind ?? "").lowercased().contains("permission") || $0.searchText.contains("scope") }) {
            return .missingScope(scopes: scope.map { [$0] } ?? AtlassianTokenScopes.write, detail: forbidden.message)
        }
        if errors.contains(where: { $0.statusCode == 404 || ($0.kind ?? "").lowercased().contains("notfound") || ($0.kind ?? "").lowercased().contains("not_found") }) {
            return .notFound(subject)
        }
        return .mutationFailed(field: field, messages: errors.map(\.message))
    }

    /// - Parameter conflict: For a page update: a 409 or a conflict / stale
    ///   version message becomes ``ConfluenceWriteError/versionConflict(pageId:expected:current:)``.
    static func parseMutation(status: Int, headers: [String: String], body: Data, payloadKey: String, field: String, scope: String, subject: String, host: String, conflict: (pageId: String, expected: Int)? = nil) throws(ConfluenceWriteError) -> [String: Any] {
        if status == 409, let conflict { throw .versionConflict(pageId: conflict.pageId, expected: conflict.expected, current: nil) }
        if let error = AtlassianGraphQLClient.httpError(status: status, headers: headers, body: body, field: field, host: host) {
            if case .siteNotFound = error { throw .notFound(subject) }
            throw map(error, scope: scope, subject: field)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            throw .invalidResponse("the body is not a JSON object")
        }
        let topErrors = writeErrors(object["errors"])
        let payload = ((object["data"] as? [String: Any])?["confluence"] as? [String: Any])?[payloadKey] as? [String: Any]
        if let payload, payload["success"] as? Bool == true { return payload }
        let errors = writeErrors(payload?["errors"]) + topErrors
        if errors.isEmpty {
            if payload == nil { throw .invalidResponse("no \(field) in the response") }
            throw .mutationFailed(field: field, messages: [])
        }
        if let conflict, errors.contains(where: { $0.statusCode == 409 }) || mentionsConflict(errors.map(\.message)) {
            throw .versionConflict(pageId: conflict.pageId, expected: conflict.expected, current: nil)
        }
        throw classify(errors, field: field, scope: scope, subject: subject)
    }

    static func webURL(_ object: [String: Any]) -> URL? {
        let links = object["links"] as? [String: Any]
        guard let base = links?["base"] as? String, let webUi = links?["webUi"] as? String else { return nil }
        return URL(string: base + webUi)
    }

    static func string(_ value: Any?) -> String? {
        (value as? String) ?? (value as? Int).map(String.init)
    }

    static func parseComment(_ payload: [String: Any], field: String) throws(ConfluenceWriteError) -> ConfluenceWrittenComment {
        guard let comment = payload["comment"] as? [String: Any], let id = string(comment["id"]) else {
            throw .invalidResponse("\(field) succeeded but returned no comment id")
        }
        return ConfluenceWrittenComment(id: id, commentId: string(comment["commentId"]), webURL: webURL(comment))
    }

    static func parseContent(_ payload: [String: Any], objectKey: String, idKey: String, field: String) throws(ConfluenceWriteError) -> ConfluenceWrittenContent {
        guard let content = payload[objectKey] as? [String: Any], let id = string(content["id"]) else {
            throw .invalidResponse("\(field) succeeded but returned no \(objectKey) id")
        }
        let contentId = string(content[idKey]) ?? id.split(separator: "/").last.map(String.init) ?? id
        let version = (content["latestVersion"] as? [String: Any])?["number"] as? Int
        return ConfluenceWrittenContent(id: id, contentId: contentId, title: content["title"] as? String, version: version, webURL: webURL(content))
    }

    static func parsePageVersion(status: Int, headers: [String: String], body: Data, pageId: String, field: String, host: String) throws(ConfluenceWriteError) -> ConfluencePageVersion {
        if let error = AtlassianGraphQLClient.httpError(status: status, headers: headers, body: body, field: field, host: host) {
            if case .siteNotFound = error { throw .notFound("page \(pageId)") }
            throw map(error, scope: "read:page:confluence", subject: field)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            throw .invalidResponse("the body is not a JSON object")
        }
        let errors = writeErrors(object["errors"])
        let page = ((object["data"] as? [String: Any])?["confluence"] as? [String: Any])?["page"] as? [String: Any]
        guard let page else {
            if !errors.isEmpty { throw classify(errors, field: field, scope: "read:page:confluence", subject: "page \(pageId)") }
            throw .notFound("page \(pageId)")
        }
        guard let number = (page["latestVersion"] as? [String: Any])?["number"] as? Int else {
            if !errors.isEmpty { throw classify(errors, field: field, scope: "read:page:confluence", subject: "page \(pageId)") }
            throw .invalidResponse("page \(pageId) has no latestVersion.number")
        }
        return ConfluencePageVersion(pageId: string(page["pageId"]) ?? pageId, title: page["title"] as? String, number: number)
    }
}

extension ConfluenceWriteClient: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "ConfluenceWriteClient(cloudId: \(cloudId), graphQL: \(graphQL.description))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["cloudId": cloudId, "graphQL": graphQL.description], displayStyle: .struct)
    }
}
