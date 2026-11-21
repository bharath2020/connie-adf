import Foundation
import Testing
@testable import ADFAtlassianAuth

/// Synthetic values only: never a real token, email, account or page body.
enum WriteFixture {
    static let token = "test-token-not-real"
    static let email = "someone@example.com"
    static let cloudId = "5d1e7a2c-8b3f-4c6d-9e0a-1f2b3c4d5e6f"
    static let site = try! AtlassianSite(parsing: "acme")
    static let host = "acme.atlassian.net"
    static let adf = #"{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"Hello from a test"}]}]}"#
    static let base = "https://acme.atlassian.net/wiki"

    /// The six read scopes tokens had before write support.
    static let legacyReadScopes = [
        "read:page:confluence", "read:space:confluence", "read:blogpost:confluence",
        "read:content.metadata:confluence", "read:attachment:confluence", "readonly:content.attachment:confluence",
    ]

    static func credential(scopes: [String] = AtlassianTokenScopes.required, cloudId: String? = WriteFixture.cloudId) -> AtlassianCredential {
        AtlassianCredential(
            site: site,
            email: email,
            token: token,
            cloudId: cloudId,
            scopes: scopes,
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    static func client(_ stub: AuthStubProtocol.Stub, scopes: [String] = AtlassianTokenScopes.required) throws -> ConfluenceWriteClient {
        try ConfluenceWriteClient(credential: credential(scopes: scopes), session: stub.session)
    }

    static func ari(_ kind: String, _ id: String) -> String {
        "ari:cloud:confluence:\(cloudId):\(kind)/\(id)"
    }

    static func json(_ object: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    /// `{"data":{"confluence":{<key>: payload}}}`.
    static func payloadBody(_ key: String, _ payload: [String: Any]) -> String {
        json(["data": ["confluence": [key: payload]]])
    }

    static func payloadError(_ key: String, message: String, statusCode: Int?, errorType: String? = nil) -> String {
        var extensions: [String: Any] = [:]
        if let statusCode { extensions["statusCode"] = statusCode }
        if let errorType { extensions["errorType"] = errorType }
        return payloadBody(key, ["success": false, "errors": [["message": message, "extensions": extensions]]])
    }

    static func versionBody(_ number: Int, pageId: String = "123", title: String = "Old title") -> String {
        json(["data": ["confluence": ["page": [
            "id": ari("page", pageId), "pageId": pageId, "title": title, "status": "CURRENT",
            "latestVersion": ["number": number],
        ]]]])
    }

    static func operationName(_ request: AuthStubProtocol.Recorded) -> String? {
        (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any])?["operationName"] as? String
    }

    static func variables(_ request: AuthStubProtocol.Recorded) throws -> [String: Any] {
        let body = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        return try #require(body["variables"] as? [String: Any])
    }

    static func input(_ request: AuthStubProtocol.Recorded) throws -> [String: Any] {
        try #require(try variables(request)["input"] as? [String: Any])
    }
}

/// The five writes, for parameterized tests.
enum WriteKind: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case footerComment, reply, createPage, updatePage, blogPost

    var testDescription: String { rawValue }

    var operationName: String {
        switch self {
        case .footerComment: return "AdfCreateFooterComment"
        case .reply: return "AdfReplyToComment"
        case .createPage: return "AdfCreatePage"
        case .updatePage: return "AdfUpdatePage"
        case .blogPost: return "AdfCreateBlogPost"
        }
    }

    var payloadKey: String {
        switch self {
        case .footerComment: return "createFooterCommentOnPage"
        case .reply: return "replyToComment"
        case .createPage: return "createPage"
        case .updatePage: return "updateCurrentPage"
        case .blogPost: return "createBlogPost"
        }
    }

    var field: String { "confluence.\(payloadKey)" }

    var scope: String {
        switch self {
        case .footerComment, .reply: return AtlassianTokenScopes.writeComment
        case .createPage, .updatePage: return AtlassianTokenScopes.writePage
        case .blogPost: return AtlassianTokenScopes.writeBlogPost
        }
    }

    /// What `notFound` names.
    var subject: String {
        switch self {
        case .footerComment, .updatePage: return "page 123"
        case .reply: return "comment 9001"
        case .createPage, .blogPost: return "space 98765"
        }
    }

    func successBody() -> String {
        let links = ["base": WriteFixture.base, "webUi": "/spaces/~tester/pages/555"]
        switch self {
        case .footerComment, .reply:
            let id = self == .footerComment ? "9001" : "9002"
            return WriteFixture.payloadBody(payloadKey, ["success": true, "errors": [], "comment": [
                "id": WriteFixture.ari("comment", id), "commentId": id, "links": links,
            ]])
        case .createPage:
            return WriteFixture.payloadBody(payloadKey, ["success": true, "errors": [], "page": [
                "id": WriteFixture.ari("page", "555"), "pageId": "555", "title": "Scratch",
                "latestVersion": ["number": 1], "links": links,
            ]])
        case .updatePage:
            return WriteFixture.payloadBody(payloadKey, ["success": true, "errors": [], "page": [
                "id": WriteFixture.ari("page", "123"), "pageId": "123", "title": "Old title",
                "latestVersion": ["number": 7], "links": links,
            ]])
        case .blogPost:
            return WriteFixture.payloadBody(payloadKey, ["success": true, "errors": [], "blogPost": [
                "id": WriteFixture.ari("blogpost", "777"), "blogPostId": "777", "title": "Scratch",
                "latestVersion": ["number": 1], "links": links,
            ]])
        }
    }

    func run(_ client: ConfluenceWriteClient, adf: String = WriteFixture.adf) async throws(ConfluenceWriteError) {
        switch self {
        case .footerComment: _ = try await client.createFooterComment(pageId: "123", adf: adf)
        case .reply: _ = try await client.replyToComment(commentId: "9001", adf: adf)
        case .createPage: _ = try await client.createPage(spaceId: "98765", title: "Scratch", adf: adf)
        case .updatePage: _ = try await client.updatePageBody(pageId: "123", adf: adf, expectedVersion: 6)
        case .blogPost: _ = try await client.createBlogPost(spaceId: "98765", title: "Scratch", adf: adf)
        }
    }

    /// A stub that answers `AdfPageVersion` with version 6 (so updates get
    /// past the pre-read) and every other request with `mutation`.
    func stub(_ mutation: @escaping @Sendable (AuthStubProtocol.Recorded) -> Result<AuthStubProtocol.Response, URLError>) -> AuthStubProtocol.Stub {
        AuthStubProtocol.session { request in
            if WriteFixture.operationName(request) == "AdfPageVersion" { return .success(.json(WriteFixture.versionBody(6))) }
            return mutation(request)
        }
    }

    func successStub() -> AuthStubProtocol.Stub {
        let body = successBody()
        return stub { _ in .success(.json(body)) }
    }

    /// The mutation requests a stub saw (the pre-read excluded).
    func mutations(_ stub: AuthStubProtocol.Stub) -> [AuthStubProtocol.Recorded] {
        stub.requests.filter { WriteFixture.operationName($0) == operationName }
    }
}

/// One failure response and the error every write should map it to.
struct WriteErrorCase: Sendable, CustomTestStringConvertible {
    enum Expected: Sendable {
        case exact(@Sendable (WriteKind) -> ConfluenceWriteError)
        case invalidResponse
        case network
    }

    let name: String
    let respond: @Sendable (WriteKind) -> Result<AuthStubProtocol.Response, URLError>
    let expected: Expected

    var testDescription: String { name }

    static let all: [WriteErrorCase] = [
        WriteErrorCase(name: "HTTP 401", respond: { _ in .success(.json(#"{"message":"Unauthorized"}"#, status: 401)) },
                       expected: .exact { _ in .unauthorized }),
        WriteErrorCase(name: "GraphQL statusCode 401", respond: { _ in
            .success(.json(#"{"data":{"confluence":null},"errors":[{"message":"Unauthorized","extensions":{"statusCode":401}}]}"#))
        }, expected: .exact { _ in .unauthorized }),
        WriteErrorCase(name: "HTTP 403", respond: { _ in .success(.json(#"{"message":"Forbidden"}"#, status: 403)) },
                       expected: .exact { .missingScope(scopes: [$0.scope], detail: "") }),
        WriteErrorCase(name: "payload statusCode 403", respond: { kind in
            .success(.json(WriteFixture.payloadError(kind.payloadKey, message: "You can't edit this content", statusCode: 403, errorType: "FORBIDDEN")))
        }, expected: .exact { .missingScope(scopes: [$0.scope], detail: "You can't edit this content") }),
        WriteErrorCase(name: "scoped token message", respond: { kind in
            .success(.json(WriteFixture.payloadError(kind.payloadKey, message: "Scoped API tokens are not supported for this field", statusCode: 403)))
        }, expected: .exact { .scopedTokenRejected(field: $0.field, detail: "Scoped API tokens are not supported for this field") }),
        WriteErrorCase(name: "HTTP 404", respond: { _ in .success(.json(#"{"message":"Not Found"}"#, status: 404)) },
                       expected: .exact { .notFound($0.subject) }),
        WriteErrorCase(name: "payload statusCode 404", respond: { kind in
            .success(.json(WriteFixture.payloadError(kind.payloadKey, message: "Content not found", statusCode: 404)))
        }, expected: .exact { .notFound($0.subject) }),
        WriteErrorCase(name: "HTTP 429 Retry-After 17", respond: { _ in .success(.json("{}", status: 429, headers: ["Retry-After": "17"])) },
                       expected: .exact { _ in .rateLimited(retryAfter: 17) }),
        WriteErrorCase(name: "payload statusCode 429", respond: { kind in
            .success(.json(WriteFixture.payloadError(kind.payloadKey, message: "Too many requests", statusCode: 429)))
        }, expected: .exact { _ in .rateLimited(retryAfter: nil) }),
        WriteErrorCase(name: "HTTP 500", respond: { _ in .success(.json("{}", status: 500)) },
                       expected: .exact { _ in .server(status: 500) }),
        WriteErrorCase(name: "success false, no errors", respond: { kind in
            .success(.json(WriteFixture.payloadBody(kind.payloadKey, ["success": false, "errors": []])))
        }, expected: .exact { .mutationFailed(field: $0.field, messages: []) }),
        WriteErrorCase(name: "missing beta header (BetaHeaderOptInException)", respond: { _ in
            .success(.json(#"{"data":null,"errors":[{"message":"This field is in beta: opt in with the header","extensions":{"classification":"BetaHeaderOptInException"}}]}"#))
        }, expected: .exact { .mutationFailed(field: $0.field, messages: ["This field is in beta: opt in with the header"]) }),
        WriteErrorCase(name: "non-JSON body", respond: { _ in
            .success(AuthStubProtocol.Response(status: 200, headers: [:], body: Data("<html>".utf8)))
        }, expected: .invalidResponse),
        WriteErrorCase(name: "success true, no object", respond: { kind in
            .success(.json(WriteFixture.payloadBody(kind.payloadKey, ["success": true, "errors": []])))
        }, expected: .invalidResponse),
        WriteErrorCase(name: "no payload, no errors", respond: { _ in .success(.json(#"{"data":{"confluence":{}}}"#)) },
                       expected: .invalidResponse),
        WriteErrorCase(name: "URLError", respond: { _ in .failure(URLError(.notConnectedToInternet)) },
                       expected: .network),
    ]
}

@Suite("Confluence write client")
struct ConfluenceWriteClientTests {
    // MARK: Success and request shape

    @Test("every write POSTs a named operation with the beta header and Basic auth", arguments: WriteKind.allCases)
    func requestShape(kind: WriteKind) async throws {
        let stub = kind.successStub()
        let client = try WriteFixture.client(stub)
        try await kind.run(client)

        let mutations = kind.mutations(stub)
        #expect(mutations.count == 1)
        let request = try #require(mutations.first)
        #expect(request.method == "POST")
        #expect(request.url?.absoluteString == "https://acme.atlassian.net/gateway/api/graphql")
        #expect(request.headers["X-ExperimentalApi"] == "confluence-agg-beta")
        let expectedAuth = "Basic " + Data("\(WriteFixture.email):\(WriteFixture.token)".utf8).base64EncodedString()
        #expect(request.headers["Authorization"] == expectedAuth)
        #expect(request.headers["Content-Type"] == "application/json")

        let body = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(body["operationName"] as? String == kind.operationName)
        let query = try #require(body["query"] as? String)
        #expect(query.contains("mutation \(kind.operationName)("))
        #expect(query.contains("confluence(cloudId: $cloudId)"))
        #expect(query.contains("\(kind.payloadKey)(input: $input)"))
        let variables = try WriteFixture.variables(request)
        #expect(variables["cloudId"] as? String == WriteFixture.cloudId)
        let input = try WriteFixture.input(request)
        let adfBody = try #require(input["body"] as? [String: Any])
        #expect(adfBody["representation"] as? String == "ATLAS_DOC_FORMAT")
        #expect(adfBody["value"] as? String == WriteFixture.adf)
        #expect(!String(decoding: request.body, as: UTF8.self).contains(WriteFixture.token))
    }

    @Test("the client's description, debug description and dump never show the token")
    func redaction() throws {
        let client = try WriteFixture.client(AuthStubProtocol.session { _ in .failure(URLError(.cancelled)) })
        var dumped = ""
        dump(client, to: &dumped)
        let basic = Data("\(WriteFixture.email):\(WriteFixture.token)".utf8).base64EncodedString()
        for text in [String(describing: client), String(reflecting: client), dumped, "\(Mirror(reflecting: client).children.map { "\($0.value)" })"] {
            #expect(!text.contains(WriteFixture.token))
            #expect(!text.contains(basic))
            #expect(text.contains(WriteFixture.cloudId))
        }
    }

    @Test("createFooterComment builds the page ARI and parses the comment")
    func createFooterComment() async throws {
        let stub = WriteKind.footerComment.successStub()
        let comment = try await WriteFixture.client(stub).createFooterComment(pageId: "123", adf: WriteFixture.adf)
        #expect(comment == ConfluenceWrittenComment(
            id: WriteFixture.ari("comment", "9001"), commentId: "9001",
            webURL: URL(string: "https://acme.atlassian.net/wiki/spaces/~tester/pages/555")))
        let input = try WriteFixture.input(try #require(stub.requests.first))
        #expect(input["pageId"] as? String == WriteFixture.ari("page", "123"))
        #expect(Set(input.keys) == ["pageId", "body"])
    }

    @Test("ARIs are passed through unchanged")
    func ariPassThrough() async throws {
        let pageARI = WriteFixture.ari("page", "4242")
        let commentARI = WriteFixture.ari("comment", "8484")
        let commentStub = WriteKind.footerComment.successStub()
        _ = try await WriteFixture.client(commentStub).createFooterComment(pageId: pageARI, adf: WriteFixture.adf)
        #expect(try WriteFixture.input(try #require(commentStub.requests.first))["pageId"] as? String == pageARI)

        let replyStub = WriteKind.reply.successStub()
        _ = try await WriteFixture.client(replyStub).replyToComment(commentId: commentARI, adf: WriteFixture.adf)
        #expect(try WriteFixture.input(try #require(replyStub.requests.first))["parentCommentId"] as? String == commentARI)

        let updateStub = WriteKind.updatePage.successStub()
        _ = try await WriteFixture.client(updateStub).updatePageBody(pageId: pageARI, adf: WriteFixture.adf, expectedVersion: 6)
        #expect(try WriteFixture.variables(try #require(updateStub.requests.first))["id"] as? String == pageARI)
        #expect(try WriteFixture.input(try #require(WriteKind.updatePage.mutations(updateStub).first))["id"] as? String == pageARI)
    }

    @Test("replyToComment builds the parent comment ARI and parses the reply")
    func replyToComment() async throws {
        let stub = WriteKind.reply.successStub()
        let reply = try await WriteFixture.client(stub).replyToComment(commentId: "9001", adf: WriteFixture.adf)
        #expect(reply.id == WriteFixture.ari("comment", "9002"))
        #expect(reply.commentId == "9002")
        let input = try WriteFixture.input(try #require(stub.requests.first))
        #expect(input["parentCommentId"] as? String == WriteFixture.ari("comment", "9001"))
        #expect(Set(input.keys) == ["parentCommentId", "body"])
    }

    @Test("createPage sends the space ID verbatim, the title and status CURRENT")
    func createPage() async throws {
        let stub = WriteKind.createPage.successStub()
        let page = try await WriteFixture.client(stub).createPage(spaceId: "98765", title: "Scratch", adf: WriteFixture.adf)
        #expect(page == ConfluenceWrittenContent(
            id: WriteFixture.ari("page", "555"), contentId: "555", title: "Scratch", version: 1,
            webURL: URL(string: "https://acme.atlassian.net/wiki/spaces/~tester/pages/555")))
        let input = try WriteFixture.input(try #require(stub.requests.first))
        #expect(input["spaceId"] as? String == "98765")
        #expect(input["title"] as? String == "Scratch")
        #expect(input["status"] as? String == "CURRENT")
    }

    @Test("createBlogPost sends the space ID verbatim and parses the blog post")
    func createBlogPost() async throws {
        let stub = WriteKind.blogPost.successStub()
        let post = try await WriteFixture.client(stub).createBlogPost(spaceId: "98765", title: "Scratch", adf: WriteFixture.adf)
        #expect(post.id == WriteFixture.ari("blogpost", "777"))
        #expect(post.contentId == "777")
        #expect(post.version == 1)
        let input = try WriteFixture.input(try #require(stub.requests.first))
        #expect(input["spaceId"] as? String == "98765")
        #expect(input["title"] as? String == "Scratch")
        #expect(input["status"] as? String == "CURRENT")
    }

    @Test("pageVersion reads the page's title and version under confluence")
    func pageVersion() async throws {
        let stub = AuthStubProtocol.session(responding: .json(WriteFixture.versionBody(6)))
        let version = try await WriteFixture.client(stub).pageVersion(pageId: "123")
        #expect(version == ConfluencePageVersion(pageId: "123", title: "Old title", number: 6))
        let request = try #require(stub.requests.first)
        #expect(stub.requests.count == 1)
        #expect(WriteFixture.operationName(request) == "AdfPageVersion")
        #expect(request.headers["X-ExperimentalApi"] == "confluence-agg-beta")
        let variables = try WriteFixture.variables(request)
        #expect(variables["id"] as? String == WriteFixture.ari("page", "123"))
        #expect(variables["cloudId"] == nil)
    }

    @Test("updatePageBody reads the version, then updates, keeping the current title")
    func updatePageBody() async throws {
        let stub = WriteKind.updatePage.successStub()
        let page = try await WriteFixture.client(stub).updatePageBody(pageId: "123", adf: WriteFixture.adf, expectedVersion: 6)
        #expect(page.version == 7)
        #expect(page.contentId == "123")
        #expect(stub.requests.map { WriteFixture.operationName($0) } == ["AdfPageVersion", "AdfUpdatePage"])
        let input = try WriteFixture.input(stub.requests[1])
        #expect(input["id"] as? String == WriteFixture.ari("page", "123"))
        #expect(input["title"] as? String == "Old title")
        #expect((input["body"] as? [String: Any])?["value"] as? String == WriteFixture.adf)
    }

    @Test("updatePageBody sends a new title when given one")
    func updatePageTitle() async throws {
        let stub = WriteKind.updatePage.successStub()
        _ = try await WriteFixture.client(stub).updatePageBody(pageId: "123", adf: WriteFixture.adf, title: "New title", expectedVersion: 6)
        #expect(try WriteFixture.input(stub.requests[1])["title"] as? String == "New title")
    }

    // MARK: Scopes, cloud ID, document

    @Test("a token with only the read scopes fails every write before sending anything", arguments: WriteKind.allCases)
    func readOnlyToken(kind: WriteKind) async throws {
        let stub = kind.successStub()
        let client = try WriteFixture.client(stub, scopes: AtlassianTokenScopes.read)
        await #expect(throws: ConfluenceWriteError.readOnlyToken(host: WriteFixture.host, missingScopes: AtlassianTokenScopes.write)) {
            try await kind.run(client)
        }
        #expect(stub.requests.isEmpty)
    }

    @Test("a token from before write support also lacks read:comment", arguments: WriteKind.allCases)
    func legacyToken(kind: WriteKind) async throws {
        let stub = kind.successStub()
        let client = try WriteFixture.client(stub, scopes: WriteFixture.legacyReadScopes)
        await #expect(throws: ConfluenceWriteError.readOnlyToken(host: WriteFixture.host, missingScopes: AtlassianTokenScopes.write + [AtlassianTokenScopes.readComment])) {
            try await kind.run(client)
        }
        #expect(stub.requests.isEmpty)
    }

    @Test("a token without write:blogpost can comment but not create a blog post")
    func missingBlogPostScope() async throws {
        let scopes = AtlassianTokenScopes.required.filter { $0 != AtlassianTokenScopes.writeBlogPost }
        let commentStub = WriteKind.footerComment.successStub()
        _ = try await WriteFixture.client(commentStub, scopes: scopes).createFooterComment(pageId: "123", adf: WriteFixture.adf)
        #expect(commentStub.requests.count == 1)

        let blogStub = WriteKind.blogPost.successStub()
        await #expect(throws: ConfluenceWriteError.readOnlyToken(host: WriteFixture.host, missingScopes: [AtlassianTokenScopes.writeBlogPost])) {
            try await WriteKind.blogPost.run(try WriteFixture.client(blogStub, scopes: scopes))
        }
        #expect(blogStub.requests.isEmpty)
    }

    @Test("comment writes also need read:comment, which guards the returned comment", arguments: [WriteKind.footerComment, .reply])
    func commentNeedsReadComment(kind: WriteKind) async throws {
        let scopes = AtlassianTokenScopes.required.filter { $0 != AtlassianTokenScopes.readComment }
        let stub = kind.successStub()
        await #expect(throws: ConfluenceWriteError.readOnlyToken(host: WriteFixture.host, missingScopes: [AtlassianTokenScopes.readComment])) {
            try await kind.run(try WriteFixture.client(stub, scopes: scopes))
        }
        #expect(stub.requests.isEmpty)
        // Page writes don't need it.
        let pageStub = WriteKind.createPage.successStub()
        try await WriteKind.createPage.run(try WriteFixture.client(pageStub, scopes: scopes))
        #expect(pageStub.requests.count == 1)
    }

    @Test("a credential without a cloud ID can't make a client")
    func missingCloudId() throws {
        let session = AuthStubProtocol.session { _ in .failure(URLError(.cancelled)) }.session
        #expect(throws: ConfluenceWriteError.missingCloudId(host: WriteFixture.host)) {
            try ConfluenceWriteClient(credential: WriteFixture.credential(cloudId: nil), session: session)
        }
        #expect(throws: ConfluenceWriteError.missingCloudId(host: WriteFixture.host)) {
            try ConfluenceWriteClient(credential: WriteFixture.credential(cloudId: ""), session: session)
        }
        let override = try ConfluenceWriteClient(credential: WriteFixture.credential(cloudId: nil), cloudId: WriteFixture.cloudId, session: session)
        #expect(override.cloudId == WriteFixture.cloudId)
    }

    @Test("a body that isn't an ADF doc is refused before sending", arguments: WriteKind.allCases, [
        "not json", "", "[1, 2]", #"{"type":"paragraph","content":[]}"#, #"{"version":1,"content":[]}"#,
    ])
    func invalidDocument(kind: WriteKind, adf: String) async throws {
        let stub = kind.successStub()
        let client = try WriteFixture.client(stub)
        await #expect {
            try await kind.run(client, adf: adf)
        } throws: { error in
            if case .invalidDocument = error as? ConfluenceWriteError { return true }
            return false
        }
        #expect(stub.requests.isEmpty)
    }

    // MARK: Error mapping

    @Test("every failure maps to the right error for every write", arguments: WriteKind.allCases, WriteErrorCase.all)
    func errorMapping(kind: WriteKind, errorCase: WriteErrorCase) async throws {
        let stub = kind.stub { _ in errorCase.respond(kind) }
        let client = try WriteFixture.client(stub)
        switch errorCase.expected {
        case .exact(let make):
            await #expect(throws: make(kind)) { try await kind.run(client) }
        case .invalidResponse:
            await #expect {
                try await kind.run(client)
            } throws: { error in
                if case .invalidResponse = error as? ConfluenceWriteError { return true }
                return false
            }
        case .network:
            await #expect {
                try await kind.run(client)
            } throws: { error in
                guard case .network(let detail) = error as? ConfluenceWriteError else { return false }
                return !detail.contains(WriteFixture.token) && !detail.contains("Basic")
            }
        }
        #expect(kind.mutations(stub).count == 1, "exactly one mutation, no retry or fallback")
    }

    // MARK: Version conflicts

    @Test("a newer version on the pre-read is a conflict and no mutation is sent")
    func staleBeforeWrite() async throws {
        let stub = AuthStubProtocol.session { request in
            if WriteFixture.operationName(request) == "AdfPageVersion" { return .success(.json(WriteFixture.versionBody(7))) }
            return .success(.json(WriteKind.updatePage.successBody()))
        }
        await #expect(throws: ConfluenceWriteError.versionConflict(pageId: "123", expected: 6, current: 7)) {
            try await WriteKind.updatePage.run(try WriteFixture.client(stub))
        }
        #expect(stub.requests.map { WriteFixture.operationName($0) } == ["AdfPageVersion"])
    }

    @Test("a conflict reported by the mutation is a version conflict", arguments: [
        WriteFixture.payloadError("updateCurrentPage", message: "Request failed", statusCode: 409),
        WriteFixture.payloadError("updateCurrentPage", message: "Version conflict: the page was edited", statusCode: 400),
        WriteFixture.payloadError("updateCurrentPage", message: "Stale page version", statusCode: nil),
        WriteFixture.payloadError("updateCurrentPage", message: "Version mismatch with the latest version", statusCode: 400),
        #"{"data":{"confluence":{"updateCurrentPage":null}},"errors":[{"message":"Conflict","extensions":{"statusCode":409}}]}"#,
    ])
    func conflictFromMutation(body: String) async throws {
        let stub = WriteKind.updatePage.stub { _ in .success(.json(body)) }
        await #expect(throws: ConfluenceWriteError.versionConflict(pageId: "123", expected: 6, current: nil)) {
            try await WriteKind.updatePage.run(try WriteFixture.client(stub))
        }
        #expect(stub.requests.count == 2)
    }

    @Test("HTTP 409 on the mutation is a version conflict")
    func conflictHTTP409() async throws {
        let stub = WriteKind.updatePage.stub { _ in .success(.json("{}", status: 409)) }
        await #expect(throws: ConfluenceWriteError.versionConflict(pageId: "123", expected: 6, current: nil)) {
            try await WriteKind.updatePage.run(try WriteFixture.client(stub))
        }
    }

    @Test("conflict wording is only a conflict for page updates")
    func conflictWordingOnCreate() async throws {
        let body = WriteFixture.payloadError("createPage", message: "Conflict: a page with this title already exists", statusCode: 400)
        let stub = WriteKind.createPage.stub { _ in .success(.json(body)) }
        await #expect(throws: ConfluenceWriteError.mutationFailed(field: "confluence.createPage", messages: ["Conflict: a page with this title already exists"])) {
            try await WriteKind.createPage.run(try WriteFixture.client(stub))
        }
    }

    @Test("pageVersion maps a missing page and bad responses", arguments: [
        (#"{"data":{"confluence":{"page":null}}}"#, 200, ConfluenceWriteError.notFound("page 123")),
        (#"{"data":{"confluence":{"page":null}},"errors":[{"message":"Not found","extensions":{"statusCode":404}}]}"#, 200, .notFound("page 123")),
        (#"{"data":{"confluence":{"page":null}},"errors":[{"message":"Unauthorized","extensions":{"statusCode":401}}]}"#, 200, .unauthorized),
        (#"{"message":"nope"}"#, 404, .notFound("page 123")),
        (#"{"message":"nope"}"#, 401, .unauthorized),
        (#"{"message":"nope"}"#, 403, .missingScope(scopes: ["read:page:confluence"], detail: "")),
        (#"{"data":{"confluence":{"page":{"pageId":"123","title":"T"}}}}"#, 200, .invalidResponse("page 123 has no latestVersion.number")),
    ])
    func pageVersionErrors(body: String, status: Int, expected: ConfluenceWriteError) async throws {
        let stub = AuthStubProtocol.session(responding: .json(body, status: status))
        await #expect(throws: expected) {
            try await WriteFixture.client(stub).pageVersion(pageId: "123")
        }
    }

    @Test("updatePageBody on a missing page sends no mutation")
    func updateMissingPage() async throws {
        let stub = AuthStubProtocol.session { request in
            if WriteFixture.operationName(request) == "AdfPageVersion" { return .success(.json(#"{"data":{"confluence":{"page":null}}}"#)) }
            return .success(.json(WriteKind.updatePage.successBody()))
        }
        await #expect(throws: ConfluenceWriteError.notFound("page 123")) {
            try await WriteKind.updatePage.run(try WriteFixture.client(stub))
        }
        #expect(stub.requests.count == 1)
    }

    // MARK: Messages

    @Test("every error has a user-facing message")
    func messages() {
        let errors: [ConfluenceWriteError] = [
            .readOnlyToken(host: WriteFixture.host, missingScopes: AtlassianTokenScopes.write),
            .missingCloudId(host: WriteFixture.host), .invalidDocument("x"), .unauthorized,
            .missingScope(scopes: [AtlassianTokenScopes.writePage], detail: ""), .missingScope(scopes: [], detail: "d"),
            .scopedTokenRejected(field: "f", detail: ""), .scopedTokenRejected(field: "f", detail: "d"),
            .notFound("page 1"), .versionConflict(pageId: "1", expected: 2, current: 3), .versionConflict(pageId: "1", expected: 2, current: nil),
            .rateLimited(retryAfter: 5), .rateLimited(retryAfter: nil), .mutationFailed(field: "f", messages: []),
            .mutationFailed(field: "f", messages: ["a", "b"]), .server(status: 502), .invalidResponse("x"), .network("y"),
        ]
        for error in errors {
            #expect(!error.message.isEmpty)
            #expect(!error.message.contains(WriteFixture.token))
        }
        let readOnly = ConfluenceWriteError.readOnlyToken(host: WriteFixture.host, missingScopes: AtlassianTokenScopes.write).message
        #expect(readOnly.contains("adf-auth rotate \(WriteFixture.host)"))
        for scope in AtlassianTokenScopes.write { #expect(readOnly.contains(scope)) }
        #expect(ConfluenceWriteError.versionConflict(pageId: "1", expected: 2, current: 3).message.contains("version 3"))
        #expect(ConfluenceWriteError.rateLimited(retryAfter: 17).message.contains("17 seconds"))
    }
}

@Suite("Token scopes for writing")
struct WriteScopeTests {
    @Test("required is the read scopes followed by the three write scopes")
    func requiredScopes() {
        #expect(AtlassianTokenScopes.required == AtlassianTokenScopes.read + AtlassianTokenScopes.write)
        #expect(AtlassianTokenScopes.required.count == 10)
        #expect(AtlassianTokenScopes.write == ["write:comment:confluence", "write:page:confluence", "write:blogpost:confluence"])
        for scope in ["write:comment:confluence", "write:page:confluence", "write:blogpost:confluence", "read:comment:confluence"] {
            #expect(AtlassianTokenScopes.required.contains(scope))
        }
        #expect(AtlassianTokenScopes.read.contains(AtlassianTokenScopes.readComment))
        #expect(Set(AtlassianTokenScopes.required).count == AtlassianTokenScopes.required.count)
        // No delete or admin scope sneaks in.
        #expect(!AtlassianTokenScopes.required.contains { $0.contains("delete") || $0.contains("manage") || $0.contains("admin") })
    }

    @Test("missingWriteScopes lists write scopes and read:comment in order")
    func missingWriteScopes() {
        #expect(AtlassianTokenScopes.missingWriteScopes(in: AtlassianTokenScopes.required).isEmpty)
        #expect(AtlassianTokenScopes.missingWriteScopes(in: AtlassianTokenScopes.read) == AtlassianTokenScopes.write)
        #expect(AtlassianTokenScopes.missingWriteScopes(in: WriteFixture.legacyReadScopes) == AtlassianTokenScopes.write + [AtlassianTokenScopes.readComment])
        #expect(AtlassianTokenScopes.missingWriteScopes(in: []) == AtlassianTokenScopes.write + [AtlassianTokenScopes.readComment])
        let noBlog = AtlassianTokenScopes.required.filter { $0 != AtlassianTokenScopes.writeBlogPost }
        #expect(AtlassianTokenScopes.missingWriteScopes(in: noBlog) == [AtlassianTokenScopes.writeBlogPost])
    }

    @Test("credentials and summaries report whether they can write")
    func canWrite() {
        #expect(WriteFixture.credential().canWrite)
        #expect(!WriteFixture.credential(scopes: WriteFixture.legacyReadScopes).canWrite)
        #expect(WriteFixture.credential(scopes: AtlassianTokenScopes.read).missingWriteScopes == AtlassianTokenScopes.write)
    }

    @Test("the read-only note is nil for a full token and names rotate for a read-only one")
    func readOnlyNote() {
        func summary(_ scopes: [String]) -> AtlassianAccountSummary {
            AtlassianAccountSummary(site: WriteFixture.site, email: WriteFixture.email, cloudId: WriteFixture.cloudId, scopes: scopes,
                                    createdAt: Date(timeIntervalSince1970: 1_790_000_000), expiresAt: nil)
        }
        #expect(summary(AtlassianTokenScopes.required).readOnlyNote == nil)
        #expect(summary(AtlassianTokenScopes.required).canWrite)
        let note = try? #require(summary(WriteFixture.legacyReadScopes).readOnlyNote)
        #expect(note?.contains("read-only") == true)
        #expect(note?.contains("adf-auth rotate \(WriteFixture.host)") == true)
        #expect(note?.contains(AtlassianTokenScopes.writePage) == true)
        #expect(note?.contains(WriteFixture.email) == false)
    }
}
