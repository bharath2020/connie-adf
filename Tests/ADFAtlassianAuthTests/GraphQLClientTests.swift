import Foundation
import Testing
@testable import ADFAtlassianAuth

@Suite("Atlassian GraphQL client")
struct GraphQLClientTests {
    static let checkOK = #"{"data":{"tenantContexts":[{"cloudId":"0f6a3c1e-2b4d-4e8f-9a1b-3c5d7e9f1a2b","hostName":"acme.atlassian.net"}]}}"#

    func client(_ stub: AuthStubProtocol.Stub, endpoint: URL? = nil) -> AtlassianGraphQLClient {
        AtlassianGraphQLClient(site: Fixture.acme, email: Fixture.email, token: Fixture.token, endpoint: endpoint, session: stub.session)
    }

    func check(responding response: AuthStubProtocol.Response) async throws(AtlassianAuthError) -> TokenCheckResult {
        try await client(AuthStubProtocol.session(responding: response)).checkToken()
    }

    // MARK: Request shape

    @Test("checkToken POSTs a named operation to the gateway with Basic auth")
    func requestShape() async throws {
        let stub = AuthStubProtocol.session(responding: .json(Self.checkOK))
        let result = try await client(stub).checkToken()
        #expect(result == TokenCheckResult(cloudId: Fixture.cloudId, hostName: "acme.atlassian.net"))

        let request = try #require(stub.requests.first)
        #expect(stub.requests.count == 1)
        #expect(request.method == "POST")
        #expect(request.url?.absoluteString == "https://acme.atlassian.net/gateway/api/graphql")
        let expectedAuth = "Basic " + Data("\(Fixture.email):\(Fixture.token)".utf8).base64EncodedString()
        #expect(request.headers["Authorization"] == expectedAuth)
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.headers["Accept"] == "application/json")
        #expect(request.headers["User-Agent"] == "adf-auth/1")

        let body = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(body["operationName"] as? String == "AdfAuthCheck")
        #expect((body["query"] as? String)?.contains("query AdfAuthCheck($hostNames: [String!]!)") == true)
        #expect((body["query"] as? String)?.contains("tenantContexts(hostNames: $hostNames) { cloudId hostName }") == true)
        let variables = try #require(body["variables"] as? [String: Any])
        #expect(variables["hostNames"] as? [String] == ["acme.atlassian.net"])
        #expect(!String(decoding: request.body, as: UTF8.self).contains(Fixture.token))
    }

    @Test("the endpoint override is honoured")
    func endpointOverride() async throws {
        let stub = AuthStubProtocol.session(responding: .json(Self.checkOK))
        let override = URL(string: "http://127.0.0.1:9999/stub/graphql")!
        let client = client(stub, endpoint: override)
        #expect(client.endpoint == override)
        _ = try await client.checkToken()
        #expect(stub.requests.first?.url == override)
    }

    @Test("the client description and dump never show the token")
    func clientRedaction() {
        let client = AtlassianGraphQLClient(site: Fixture.acme, email: Fixture.email, token: Fixture.token)
        var dumped = ""
        dump(client, to: &dumped)
        for text in ["\(client)", String(reflecting: client), dumped] {
            #expect(!text.contains(Fixture.token))
        }
    }

    @Test("the dry-run preview redacts the Authorization header")
    func preview() {
        let preview = AtlassianGraphQLClient.requestPreview(.authCheck(site: Fixture.acme), endpoint: Fixture.acme.graphQLEndpoint)
        #expect(preview.contains("Authorization: Basic <redacted>"))
        #expect(preview.contains("\"operationName\" : \"AdfAuthCheck\""))
        #expect(preview.contains("acme.atlassian.net"))
    }

    // MARK: Token check mapping

    @Test("the tenant whose hostName matches wins")
    func prefersMatchingHost() async throws {
        let body = #"{"data":{"tenantContexts":[null,{"cloudId":null},{"cloudId":"11111111-1111-1111-1111-111111111111","hostName":"other.atlassian.net"},{"cloudId":"22222222-2222-2222-2222-222222222222","hostName":"ACME.atlassian.net"}]}}"#
        #expect(try await check(responding: .json(body)).cloudId == "22222222-2222-2222-2222-222222222222")
    }

    @Test("HTTP statuses map to errors", arguments: [
        (401, AtlassianAuthError.unauthorized),
        (403, .forbidden(missingScopes: AtlassianTokenScopes.required)),
        (404, .siteNotFound(host: "acme.atlassian.net")),
        (500, .server(status: 500)),
        (503, .server(status: 503)),
    ])
    func httpStatus(status: Int, expected: AtlassianAuthError) async {
        await #expect(throws: expected) {
            try await check(responding: .json(#"{"message":"nope"}"#, status: status))
        }
    }

    @Test("429 reads Retry-After seconds")
    func rateLimited() async {
        await #expect(throws: AtlassianAuthError.rateLimited(retryAfter: 17)) {
            try await check(responding: .json("{}", status: 429, headers: ["Retry-After": "17"]))
        }
        await #expect(throws: AtlassianAuthError.rateLimited(retryAfter: nil)) {
            try await check(responding: .json("{}", status: 429))
        }
    }

    @Test("Retry-After also accepts an HTTP date")
    func retryAfterDate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000) // Fri, 15 Jan 2027 08:00:00 GMT
        #expect(AtlassianGraphQLClient.parseRetryAfter("Fri, 15 Jan 2027 08:00:30 GMT", now: now) == 30)
        #expect(AtlassianGraphQLClient.parseRetryAfter("garbage", now: now) == nil)
    }

    @Test("an empty tenant list means the site does not exist")
    func emptyTenants() async {
        await #expect(throws: AtlassianAuthError.siteNotFound(host: "acme.atlassian.net")) {
            try await check(responding: .json(#"{"data":{"tenantContexts":[]}}"#))
        }
        await #expect(throws: AtlassianAuthError.siteNotFound(host: "acme.atlassian.net")) {
            try await check(responding: .json(#"{"data":{"tenantContexts":null}}"#))
        }
    }

    @Test("200 with errors and no data maps by classification", arguments: [
        (#"{"errors":[{"message":"Field 'x' is undefined","extensions":{"classification":"ValidationError","statusCode":400}}]}"#,
         AtlassianAuthError.graphQL(messages: ["Field 'x' is undefined"])),
        (#"{"data":null,"errors":[{"message":"a"},{"message":"b"}]}"#,
         .graphQL(messages: ["a", "b"])),
        (#"{"data":{"tenantContexts":null},"errors":[{"message":"Unauthorized","extensions":{"statusCode":401}}]}"#,
         .unauthorized),
        (#"{"data":{"tenantContexts":null},"errors":[{"message":"Invalid API token","extensions":{"statusCode":401}}]}"#,
         .unauthorized),
        (#"{"data":{"tenantContexts":null},"errors":[{"message":"Permission denied","extensions":{"statusCode":403,"classification":"Forbidden"}}]}"#,
         .forbidden(missingScopes: AtlassianTokenScopes.required)),
        (#"{"errors":[{"message":"Cloud id not found","extensions":{"classification":"CloudIdNotFoundException","statusCode":404}}]}"#,
         .siteNotFound(host: "acme.atlassian.net")),
    ])
    func graphQLErrors(body: String, expected: AtlassianAuthError) async {
        await #expect(throws: expected) { try await check(responding: .json(body)) }
    }

    @Test("a scoped-token rejection is reported plainly, with no fallback", arguments: [
        #"{"data":{"tenantContexts":null},"errors":[{"message":"Scoped API tokens are not supported for this field","path":["tenantContexts"],"extensions":{"statusCode":403,"classification":"Forbidden"}}]}"#,
        #"{"errors":[{"message":"This request is not allowed with an API token","path":["tenantContexts"],"extensions":{"statusCode":403}}]}"#,
        #"{"errors":[{"message":"Forbidden","path":["tenantContexts"],"extensions":{"statusCode":403,"errorType":"ScopedApiTokenUnavailable"}}]}"#,
        #"{"errors":[{"message":"Container tokens can't be used here","path":["tenantContexts"],"extensions":{"statusCode":403}}]}"#,
    ])
    func scopedRejection(body: String) async throws {
        let stub = AuthStubProtocol.session(responding: .json(body))
        await #expect {
            try await client(stub).checkToken()
        } throws: { error in
            guard case .scopedTokenRejected(let field, let detail) = error as? AtlassianAuthError else { return false }
            return field == "tenantContexts" && !detail.isEmpty
        }
        #expect(stub.requests.count == 1, "no fallback request is sent")
    }

    @Test("an HTTP 403 that mentions scoped tokens is a scoped-token rejection")
    func scopedHTTP403() async {
        await #expect(throws: AtlassianAuthError.scopedTokenRejected(field: "tenantContexts", detail: "Scoped tokens are not allowed")) {
            try await check(responding: .json(#"{"message":"Scoped tokens are not allowed"}"#, status: 403))
        }
    }

    @Test("the scoped-token message says GraphQL only and names the field")
    func scopedMessage() {
        let message = AtlassianAuthError.scopedTokenRejected(field: "confluence.pages", detail: "x").message
        #expect(message.contains("does not accept scoped API tokens for confluence.pages"))
        #expect(message.contains("ADFReader uses GraphQL only"))
    }

    @Test("non-JSON bodies and transport failures map cleanly")
    func invalidAndNetwork() async {
        await #expect {
            try await check(responding: AuthStubProtocol.Response(status: 200, headers: [:], body: Data("<html>".utf8)))
        } throws: { error in
            if case .invalidResponse = error as? AtlassianAuthError { return true }
            return false
        }
        let offline = AuthStubProtocol.session { _ in .failure(URLError(.notConnectedToInternet)) }
        await #expect {
            try await client(offline).checkToken()
        } throws: { error in
            guard case .network(let detail) = error as? AtlassianAuthError else { return false }
            return !detail.contains(Fixture.token) && !detail.contains("Basic")
        }
    }

    // MARK: Probe

    static let probeOK = #"""
    {"data":{"confluence":{"pages":[
      {"id":"ari:cloud:confluence:0f6a3c1e-2b4d-4e8f-9a1b-3c5d7e9f1a2b:page/123","pageId":"123","title":"Hello",
       "links":{"base":"https://acme.atlassian.net/wiki","webUi":"/spaces/ENG/pages/123/Hello"},
       "space":{"id":"9","key":"ENG","name":"Engineering","icon":{"path":"/i.png"}},
       "metadata":{"titleEmojiPublished":{"id":"1f44b","key":"emoji-title-published","value":"1f44b"}}},
      null
    ]}}}
    """#

    @Test("probePages builds page ARIs and parses pages")
    func probeRequestAndParse() async throws {
        let stub = AuthStubProtocol.session(responding: .json(Self.probeOK))
        let result = try await client(stub).probePages(pageIds: ["123", "456"], cloudId: Fixture.cloudId)

        let request = try #require(stub.requests.first)
        let body = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(body["operationName"] as? String == "AdfProbePages")
        #expect((body["query"] as? String)?.contains("query AdfProbePages($ids: [ID!]!)") == true)
        let variables = try #require(body["variables"] as? [String: Any])
        #expect(variables["ids"] as? [String] == [
            "ari:cloud:confluence:\(Fixture.cloudId):page/123",
            "ari:cloud:confluence:\(Fixture.cloudId):page/456",
        ])

        #expect(result.pages == [PageProbeResult.Page(
            id: "ari:cloud:confluence:\(Fixture.cloudId):page/123", pageId: "123", title: "Hello",
            spaceId: "9", spaceKey: "ENG", spaceName: "Engineering", emoji: "1f44b",
            webURL: URL(string: "https://acme.atlassian.net/wiki/spaces/ENG/pages/123/Hello"))])
        #expect(result.errorMessages.isEmpty)
        #expect(!result.emojiNeedsMetadataScope)
        #expect(result.rawJSON.contains("\"title\" : \"Hello\""))
        #expect(!result.rawJSON.contains(Fixture.token))
    }

    @Test("a metadata scope error is partial success, not a throw")
    func probePartial() async throws {
        let body = #"""
        {"data":{"confluence":{"pages":[{"id":"ari:x","pageId":"123","title":"Hello","space":{"key":"ENG","name":"Engineering"},"metadata":null}]}},
         "errors":[{"message":"This request requires the scope read:content.metadata:confluence","path":["confluence","pages",0,"metadata"],"extensions":{"statusCode":403,"classification":"Forbidden"}}]}
        """#
        let result = try await client(AuthStubProtocol.session(responding: .json(body))).probePages(pageIds: ["123"], cloudId: Fixture.cloudId)
        #expect(result.pages.map(\.title) == ["Hello"])
        #expect(result.pages.first?.emoji == nil)
        #expect(result.errorMessages == ["This request requires the scope read:content.metadata:confluence"])
        #expect(result.emojiNeedsMetadataScope)
        #expect(PageProbeResult.metadataScopeNote.contains("read:content.metadata:confluence"))
    }

    @Test("pages that are all null come back as an empty result with the errors")
    func probeNotFound() async throws {
        let body = #"{"data":{"confluence":{"pages":[null]}},"errors":[{"message":"Page not found","path":["confluence","pages",0],"extensions":{"statusCode":404}}]}"#
        let result = try await client(AuthStubProtocol.session(responding: .json(body))).probePages(pageIds: ["1"], cloudId: Fixture.cloudId)
        #expect(result.pages.isEmpty)
        #expect(result.errorMessages == ["Page not found"])
    }

    @Test("a scoped-token rejection of confluence.pages throws")
    func probeScoped() async {
        let body = #"{"data":{"confluence":{"pages":null}},"errors":[{"message":"Scoped API tokens are not supported","path":["confluence","pages"],"extensions":{"statusCode":403}}]}"#
        await #expect(throws: AtlassianAuthError.scopedTokenRejected(field: "confluence.pages", detail: "Scoped API tokens are not supported")) {
            try await client(AuthStubProtocol.session(responding: .json(body))).probePages(pageIds: ["1"], cloudId: Fixture.cloudId)
        }
    }

    @Test("probe errors with no data throw graphQL messages")
    func probeNoData() async {
        await #expect(throws: AtlassianAuthError.graphQL(messages: ["boom"])) {
            try await client(AuthStubProtocol.session(responding: .json(#"{"data":null,"errors":[{"message":"boom"}]}"#))).probePages(pageIds: ["1"], cloudId: Fixture.cloudId)
        }
    }

    @Test("every error has a user-facing message")
    func messages() {
        let errors: [AtlassianAuthError] = [
            .unauthorized, .forbidden(missingScopes: []), .scopedTokenRejected(field: "f", detail: ""),
            .siteNotFound(host: "acme.atlassian.net"), .rateLimited(retryAfter: 5), .rateLimited(retryAfter: nil),
            .server(status: 502), .graphQL(messages: []), .invalidResponse("x"), .network("y"),
        ]
        for error in errors { #expect(!error.message.isEmpty) }
        #expect(AtlassianAuthError.unauthorized.message == "Atlassian rejected the email or token. Check both, and make sure the token was created for Confluence.")
        #expect(AtlassianAuthError.siteNotFound(host: "acme.atlassian.net").message.contains("No Atlassian Cloud site at acme.atlassian.net"))
        #expect(AtlassianAuthError.forbidden(missingScopes: []).message.contains("read:blogpost:confluence"))
    }
}
