import Foundation
import os
import Testing
import ADFAtlassianAuth
import ADFModel
@testable import ADFAtlassianMedia

@Suite("Atlassian media fetcher", .timeLimit(.minutes(1)))
struct AtlassianMediaFetcherTests {
    typealias Response = MediaStubProtocol.Response

    /// A stub serving tenant_info, the default list and image bytes for any
    /// download; `route` gets the first say.
    func makeStub(_ route: (@Sendable (MediaStubProtocol.Recorded) -> Response?)? = nil) -> MediaStubProtocol.Stub {
        MediaStubProtocol.session { request in
            if let response = route?(request) { return .success(response) }
            let path = request.url?.path() ?? ""
            if path == "/_edge/tenant_info" {
                return .success(.json(#"{"cloudId":"\#(MediaFixture.cloudId)"}"#))
            }
            if path.hasSuffix("/attachments") {
                return .success(.json(MediaFixture.defaultList))
            }
            if path.hasSuffix("/download") {
                return .success(.bytes(MediaFixture.imageBytes))
            }
            return .success(.json(#"{"message":"no stub"}"#, status: 599))
        }
    }

    func makeFetcher(_ stub: MediaStubProtocol.Stub, cloudId: String? = MediaFixture.cloudId, clock: EmojiTestClock = EmojiTestClock()) -> AtlassianMediaFetcher {
        AtlassianMediaFetcher(credential: MediaFixture.credential(cloudId: cloudId), session: stub.session,
                              apiBase: AtlassianMediaFetcher.defaultAPIBase, now: { clock.now })
    }

    func media(_ fileId: String, collection: String = MediaFixture.collection) -> MediaAttrs {
        MediaAttrs(source: .file(id: fileId, collection: collection), width: 640, height: 480, alt: nil, mediaType: "file")
    }

    // MARK: Request shape

    @Test("the attachment list is a GET on the gateway with Basic auth and JSON Accept")
    func listRequestShape() async throws {
        let stub = makeStub()
        let list = try await makeFetcher(stub).attachments(pageId: MediaFixture.pageId)
        #expect(list == [
            AtlassianAttachment(id: "att2001", title: "diagram.png", fileId: MediaFixture.fileA, mediaType: "image/png", fileSize: 1234),
            AtlassianAttachment(id: "att2002", title: "photo.jpg", fileId: MediaFixture.fileB, mediaType: "image/jpeg", fileSize: 1234),
        ])
        #expect(stub.requests.count == 1)
        let request = try #require(stub.requests.first)
        #expect(request.method == "GET")
        #expect(request.url?.absoluteString == MediaFixture.listURL)
        #expect(request.headers["Authorization"] == MediaFixture.basicAuth)
        #expect(request.headers["Accept"] == "application/json")
        #expect(request.headers["User-Agent"] == "adf-media/1")
    }

    @Test("a file is matched by fileId and downloaded through the v1 attachment endpoint")
    func downloadRequestShape() async throws {
        let stub = makeStub()
        let data = try await makeFetcher(stub).data(fileId: MediaFixture.fileB, collection: MediaFixture.collection)
        #expect(data == MediaFixture.imageBytes)
        #expect(stub.requests.count == 2)
        let download = try #require(stub.requests.last)
        #expect(download.method == "GET")
        #expect(download.url?.absoluteString == "https://api.atlassian.com" + MediaFixture.downloadPath(attachmentId: "att2002"))
        #expect(download.headers["Authorization"] == MediaFixture.basicAuth)
        #expect(download.headers["Accept"] == "*/*")
    }

    @Test("the list is cached per page")
    func listIsCached() async throws {
        let stub = makeStub()
        let fetcher = makeFetcher(stub)
        _ = try await fetcher.data(fileId: MediaFixture.fileA, collection: MediaFixture.collection)
        _ = try await fetcher.data(fileId: MediaFixture.fileB, collection: MediaFixture.collection)
        #expect(stub.requests(path: MediaFixture.listPath).count == 1)
        #expect(stub.requests.count == 3)
    }

    @Test("a non-image attachment is refused before any download request")
    func nonImageNotDownloaded() async {
        let video = "6a8d1f0e-4444-4c2b-9e3a-dddddddddddd"
        let stub = makeStub { request in
            guard request.url?.path() == MediaFixture.listPath else { return nil }
            return .json(MediaFixture.listJSON([(id: "att2004", fileId: video, title: "clip.mp4", mediaType: "video/mp4")]))
        }
        await #expect(throws: AtlassianMediaError.unsupportedMediaType("video/mp4")) {
            try await makeFetcher(stub).data(fileId: video, collection: MediaFixture.collection)
        }
        #expect(stub.requests(path: MediaFixture.listPath).count == 1)
        #expect(stub.requests(path: MediaFixture.downloadPath(attachmentId: "att2004")).isEmpty)
        #expect(stub.requests.count == 1)
    }

    // MARK: Cloud ID

    @Test("the credential's cloud ID is used without asking tenant_info")
    func cloudIdFromCredential() async throws {
        let stub = makeStub()
        let fetcher = makeFetcher(stub)
        #expect(try await fetcher.resolvedCloudId() == MediaFixture.cloudId)
        _ = try await fetcher.attachments(pageId: MediaFixture.pageId)
        #expect(stub.requests(path: "/_edge/tenant_info").isEmpty)
    }

    @Test("without a cloud ID, tenant_info is fetched once, without credentials")
    func cloudIdFromTenantInfo() async throws {
        let stub = makeStub()
        let fetcher = makeFetcher(stub, cloudId: nil)
        _ = try await fetcher.attachments(pageId: MediaFixture.pageId)
        _ = try await fetcher.attachments(pageId: "4242")

        let tenant = stub.requests(path: "/_edge/tenant_info")
        #expect(tenant.count == 1)
        let request = try #require(tenant.first)
        #expect(request.url?.absoluteString == "https://acme.atlassian.net/_edge/tenant_info")
        #expect(request.method == "GET")
        #expect(request.headers["Authorization"] == nil)
        try #require(stub.requests.count == 3)
        #expect(stub.requests.first?.url?.path() == "/_edge/tenant_info")
        #expect(stub.requests[1].url?.absoluteString == MediaFixture.listURL)
        #expect(try await fetcher.resolvedCloudId() == MediaFixture.cloudId)
    }

    @Test("a tenant_info body without a cloud ID is an invalid response")
    func tenantInfoWithoutCloudId() async {
        let stub = makeStub { $0.url?.path() == "/_edge/tenant_info" ? .json(#"{"cloudId":""}"#) : nil }
        await #expect(throws: AtlassianMediaError.invalidResponse) {
            try await makeFetcher(stub, cloudId: nil).attachments(pageId: MediaFixture.pageId)
        }
    }

    // MARK: Matching and page IDs

    @Test("page IDs come from contentId-<digits> collections only", arguments: [
        ("contentId-229377", "229377" as String?),
        ("contentId-1", "1"),
        ("contentId-", nil),
        ("contentId-12a", nil),
        ("229377", nil),
        ("", nil),
        ("MediaServicesSample", nil),
    ])
    func pageIdParsing(collection: String, expected: String?) {
        #expect(AtlassianMediaFetcher.pageId(fromCollection: collection) == expected)
    }

    @Test("a missing page ID is reported before any request", arguments: [nil, "", "MediaServicesSample"] as [String?])
    func missingPageId(collection: String?) async {
        let stub = makeStub()
        await #expect(throws: AtlassianMediaError.missingPageId(collection: collection)) {
            try await makeFetcher(stub).data(fileId: MediaFixture.fileA, collection: collection)
        }
        #expect(stub.requests.isEmpty)
    }

    @Test("a media node with an empty collection reports a missing page ID")
    func mediaWithoutCollection() async {
        let stub = makeStub()
        await #expect(throws: AtlassianMediaError.missingPageId(collection: nil)) {
            try await makeFetcher(stub).data(for: media(MediaFixture.fileA, collection: ""))
        }
        #expect(stub.requests.isEmpty)
    }

    @Test("a file ID missing from a fresh list is not found, with one list call")
    func attachmentNotFound() async {
        let stub = makeStub()
        await #expect(throws: AtlassianMediaError.attachmentNotFound(fileId: "nope")) {
            try await makeFetcher(stub).data(fileId: "nope", collection: MediaFixture.collection)
        }
        #expect(stub.requests(path: MediaFixture.listPath).count == 1)
    }

    @Test("a file ID missing from a cached list refetches it once, only when the list is older than a minute")
    func refetchOnMiss() async throws {
        let clock = EmojiTestClock()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let newFile = "6a8d1f0e-3333-4c2b-9e3a-cccccccccccc"
        let stub = makeStub { request in
            guard request.url?.path() == MediaFixture.listPath else { return nil }
            if calls.withLock({ $0 += 1; return $0 }) == 1 { return .json(MediaFixture.defaultList) }
            return .json(MediaFixture.listJSON([(id: "att2003", fileId: newFile, title: "new.png", mediaType: "image/png")]))
        }
        let fetcher = makeFetcher(stub, clock: clock)
        _ = try await fetcher.attachments(pageId: MediaFixture.pageId)
        for _ in 0..<3 {
            await #expect(throws: AtlassianMediaError.attachmentNotFound(fileId: newFile)) {
                try await fetcher.data(fileId: newFile, collection: MediaFixture.collection)
            }
        }
        #expect(stub.requests(path: MediaFixture.listPath).count == 1)

        clock.advance(61)
        let data = try await fetcher.data(fileId: newFile, collection: MediaFixture.collection)
        #expect(data == MediaFixture.imageBytes)
        #expect(stub.requests(path: MediaFixture.listPath).count == 2)
        #expect(stub.requests.last?.url?.path() == MediaFixture.downloadPath(attachmentId: "att2003"))

        await #expect(throws: AtlassianMediaError.attachmentNotFound(fileId: "still-missing")) {
            try await fetcher.data(fileId: "still-missing", collection: MediaFixture.collection)
        }
        #expect(stub.requests(path: MediaFixture.listPath).count == 2)

        clock.advance(61)
        await #expect(throws: AtlassianMediaError.attachmentNotFound(fileId: "still-missing")) {
            try await fetcher.data(fileId: "still-missing", collection: MediaFixture.collection)
        }
        #expect(stub.requests(path: MediaFixture.listPath).count == 3)
    }

    // MARK: Pagination

    @Test("pagination follows _links.next relative to the gateway")
    func pagination() async throws {
        let next = "/wiki/api/v2/pages/229377/attachments?cursor=abc%3D%3D&limit=250"
        let stub = makeStub { request in
            guard request.url?.path() == MediaFixture.listPath else { return nil }
            if request.url?.query()?.contains("cursor=") == true {
                return .json(MediaFixture.listJSON([(id: "att2002", fileId: MediaFixture.fileB, title: "photo.jpg", mediaType: "image/jpeg")]))
            }
            return .json(MediaFixture.listJSON([(id: "att2001", fileId: MediaFixture.fileA, title: "diagram.png", mediaType: "image/png")], next: next))
        }
        let list = try await makeFetcher(stub).attachments(pageId: MediaFixture.pageId)
        #expect(list.map(\.id) == ["att2001", "att2002"])
        try #require(stub.requests.count == 2)
        #expect(stub.requests[1].url?.absoluteString == MediaFixture.gateway + next)
        #expect(stub.requests[1].headers["Authorization"] == MediaFixture.basicAuth)
    }

    @Test("a next link that repeats stops the loop")
    func paginationLoopGuard() async throws {
        let stub = makeStub { request in
            guard request.url?.path() == MediaFixture.listPath else { return nil }
            return .json(MediaFixture.listJSON([(id: "att2001", fileId: MediaFixture.fileA, title: "a.png", mediaType: "image/png")],
                                               next: "/wiki/api/v2/pages/229377/attachments?cursor=same"))
        }
        let list = try await makeFetcher(stub).attachments(pageId: MediaFixture.pageId)
        #expect(stub.requests.count == 2)
        #expect(list.count == 2)
    }

    @Test("next links resolve onto the gateway, never onto another host")
    func nextLinkResolution() {
        let gateway = MediaFixture.gateway
        let api = AtlassianMediaFetcher.defaultAPIBase
        func resolve(_ next: String) -> String? {
            AtlassianMediaFetcher.resolveNextLink(next, gatewayBase: gateway, apiBase: api)?.absoluteString
        }
        #expect(resolve("/wiki/api/v2/pages/1/attachments?cursor=x") == gateway + "/wiki/api/v2/pages/1/attachments?cursor=x")
        #expect(resolve("/ex/confluence/\(MediaFixture.cloudId)/wiki/api/v2/pages/1/attachments?cursor=x") == gateway + "/wiki/api/v2/pages/1/attachments?cursor=x")
        #expect(resolve("/api/v2/pages/1/attachments?cursor=x") == gateway + "/wiki/api/v2/pages/1/attachments?cursor=x")
        #expect(resolve("https://evil.example.test/wiki/api/v2/pages/1/attachments?cursor=x") == gateway + "/wiki/api/v2/pages/1/attachments?cursor=x")
        #expect(resolve("") == nil)
        #expect(resolve("relative/path") == nil)
    }

    // MARK: Status mapping

    @Test("list statuses map to media errors", arguments: [
        (401, AtlassianMediaError.unauthorized),
        (403, AtlassianMediaError.forbidden),
        (404, AtlassianMediaError.notFound),
        (429, AtlassianMediaError.http(status: 429)),
        (500, AtlassianMediaError.http(status: 500)),
    ])
    func listStatusMapping(status: Int, expected: AtlassianMediaError) async {
        let stub = makeStub { $0.url?.path() == MediaFixture.listPath ? .json(#"{"errors":[]}"#, status: status) : nil }
        await #expect(throws: expected) {
            try await makeFetcher(stub).data(fileId: MediaFixture.fileA, collection: MediaFixture.collection)
        }
    }

    @Test("download statuses map to media errors", arguments: [
        (401, AtlassianMediaError.unauthorized),
        (403, AtlassianMediaError.forbidden),
        (404, AtlassianMediaError.notFound),
    ])
    func downloadStatusMapping(status: Int, expected: AtlassianMediaError) async {
        let stub = makeStub { ($0.url?.path() ?? "").hasSuffix("/download") ? .json("{}", status: status) : nil }
        await #expect(throws: expected) {
            try await makeFetcher(stub).data(fileId: MediaFixture.fileA, collection: MediaFixture.collection)
        }
    }

    @Test("an undecodable list body is an invalid response")
    func invalidListBody() async {
        let stub = makeStub { $0.url?.path() == MediaFixture.listPath ? .json("not json") : nil }
        await #expect(throws: AtlassianMediaError.invalidResponse) {
            try await makeFetcher(stub).attachments(pageId: MediaFixture.pageId)
        }
    }

    // MARK: Redirects

    @Test("a redirect to another host drops the Authorization header")
    func crossHostRedirectStripsAuth() async throws {
        let mediaURL = URL(string: "https://api.media.atlassian.com/file/\(MediaFixture.fileA)/binary?token=signed-synthetic&client=c1")!
        let stub = makeStub { request in
            if request.url?.host() == "api.media.atlassian.com" { return .bytes(MediaFixture.imageBytes) }
            if (request.url?.path() ?? "").hasSuffix("/download") { return .redirect(to: mediaURL) }
            return nil
        }
        let data = try await makeFetcher(stub).data(fileId: MediaFixture.fileA, collection: MediaFixture.collection)
        #expect(data == MediaFixture.imageBytes)

        let download = try #require(stub.requests(path: MediaFixture.downloadPath(attachmentId: "att2001")).first)
        #expect(download.headers["Authorization"] == MediaFixture.basicAuth)
        let followed = try #require(stub.requests.first { $0.url?.host() == "api.media.atlassian.com" })
        #expect(followed.url == mediaURL)
        #expect(followed.headers["Authorization"] == nil)
        #expect(followed.headers.values.allSatisfy { !$0.contains(MediaFixture.basicAuth) })
    }

    @Test("a redirect on the same host keeps the Authorization header")
    func sameHostRedirectKeepsAuth() async throws {
        let sameHost = URL(string: MediaFixture.gateway + "/wiki/rest/api/content/229377/child/attachment/att2001/download/v2")!
        let stub = makeStub { request in
            if request.url == sameHost { return .bytes(MediaFixture.imageBytes) }
            if (request.url?.path() ?? "").hasSuffix("/download") { return .redirect(to: sameHost) }
            return nil
        }
        let data = try await makeFetcher(stub).data(fileId: MediaFixture.fileA, collection: MediaFixture.collection)
        #expect(data == MediaFixture.imageBytes)
        let followed = try #require(stub.requests.first { $0.url == sameHost })
        #expect(followed.headers["Authorization"] == MediaFixture.basicAuth)
    }

    @Test("a redirect to plain http is refused")
    func insecureRedirectRefused() async {
        let insecure = URL(string: "http://media.example.test/file/\(MediaFixture.fileA)")!
        let stub = makeStub { request in
            if request.url?.host() == "media.example.test" { return .bytes(MediaFixture.imageBytes) }
            if (request.url?.path() ?? "").hasSuffix("/download") { return .redirect(to: insecure) }
            return nil
        }
        await #expect(throws: AtlassianMediaError.insecureRedirect) {
            try await makeFetcher(stub).data(fileId: MediaFixture.fileA, collection: MediaFixture.collection)
        }
        #expect(!stub.requests.contains { $0.url?.host() == "media.example.test" })
    }

    @Test("the redirect policy: https only, Authorization only on the original host")
    func redirectPolicy() throws {
        func proposed(_ url: String) -> URLRequest {
            var request = URLRequest(url: URL(string: url)!)
            request.setValue(MediaFixture.basicAuth, forHTTPHeaderField: "Authorization")
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            return request
        }
        let other = try #require(AuthRedirectGuard.redirectedRequest(proposed("https://api.media.atlassian.com/file/x"), originalHost: "api.atlassian.com"))
        #expect(other.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(other.value(forHTTPHeaderField: "Accept") == "*/*")

        let same = try #require(AuthRedirectGuard.redirectedRequest(proposed("https://API.atlassian.com/other"), originalHost: "api.atlassian.com"))
        #expect(same.value(forHTTPHeaderField: "Authorization") == MediaFixture.basicAuth)

        let unknownOrigin = try #require(AuthRedirectGuard.redirectedRequest(proposed("https://api.atlassian.com/other"), originalHost: nil))
        #expect(unknownOrigin.value(forHTTPHeaderField: "Authorization") == nil)

        #expect(AuthRedirectGuard.redirectedRequest(proposed("http://api.atlassian.com/other"), originalHost: "api.atlassian.com") == nil)
        #expect(AuthRedirectGuard.redirectedRequest(proposed("ftp://api.atlassian.com/other"), originalHost: "api.atlassian.com") == nil)
    }

    // MARK: Concurrency

    @Test("concurrent fetches for one page share a single list call")
    func concurrentFetchesCoalesce() async throws {
        let stub = makeStub { request in
            guard request.url?.path() == MediaFixture.listPath else { return nil }
            usleep(150_000) // keep the list in flight while the others arrive
            return .json(MediaFixture.defaultList)
        }
        let fetcher = makeFetcher(stub)
        let results = try await withThrowingTaskGroup(of: Data.self) { group in
            for index in 0..<8 {
                let fileId = index.isMultiple(of: 2) ? MediaFixture.fileA : MediaFixture.fileB
                group.addTask { try await fetcher.data(fileId: fileId, collection: MediaFixture.collection) }
            }
            var all: [Data] = []
            for try await data in group { all.append(data) }
            return all
        }
        #expect(results.count == 8)
        #expect(results.allSatisfy { $0 == MediaFixture.imageBytes })
        #expect(stub.requests(path: MediaFixture.listPath).count == 1)
    }

    @Test("concurrent fetches without a cloud ID share a single tenant_info call")
    func concurrentCloudIdCoalesces() async throws {
        let stub = makeStub { request in
            guard request.url?.path() == "/_edge/tenant_info" else { return nil }
            usleep(150_000)
            return .json(#"{"cloudId":"\#(MediaFixture.cloudId)"}"#)
        }
        let fetcher = makeFetcher(stub, cloudId: nil)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for page in ["1", "2", "3", "4"] {
                group.addTask { _ = try await fetcher.attachments(pageId: page) }
            }
            try await group.waitForAll()
        }
        #expect(stub.requests(path: "/_edge/tenant_info").count == 1)
    }

    // MARK: Sources and plug point

    @Test("external sources are not Atlassian's job")
    func externalUnsupported() async {
        let stub = makeStub()
        let attrs = MediaAttrs(source: .external(url: "https://images.example.test/a.png"), width: nil, height: nil, alt: nil, mediaType: nil)
        await #expect(throws: AtlassianMediaError.unsupportedSource) {
            try await makeFetcher(stub).data(for: attrs)
        }
        await #expect(throws: AtlassianMediaError.unsupportedSource) {
            try await makeFetcher(stub).mediaFetch(attrs)
        }
        #expect(stub.requests.isEmpty)
    }

    @Test("mediaFetch loads a file source")
    func mediaFetchClosure() async throws {
        let stub = makeStub()
        let fetch: @Sendable (MediaAttrs) async throws -> Data = makeFetcher(stub).mediaFetch
        let data = try await fetch(media(MediaFixture.fileA))
        #expect(data == MediaFixture.imageBytes)
        #expect(stub.requests.last?.url?.path() == MediaFixture.downloadPath(attachmentId: "att2001"))
    }

    // MARK: Redaction

    @Test("errors and the fetcher's description never show the email or token")
    func redaction() {
        let errors: [AtlassianMediaError] = [
            .missingPageId(collection: "x"), .missingPageId(collection: nil), .attachmentNotFound(fileId: "f"),
            .unauthorized, .forbidden, .notFound, .http(status: 500), .invalidResponse, .unsupportedSource, .insecureRedirect,
        ]
        for error in errors {
            for text in [error.message, "\(error)", error.localizedDescription] {
                #expect(!text.contains(MediaFixture.token))
                #expect(!text.contains(MediaFixture.email))
            }
        }
        #expect(AtlassianMediaError.forbidden.message.contains("read:attachment:confluence"))
        #expect(AtlassianMediaError.forbidden.message.contains("readonly:content.attachment:confluence"))

        let fetcher = AtlassianMediaFetcher(credential: MediaFixture.credential())
        var dumped = ""
        dump(fetcher, to: &dumped)
        for text in ["\(fetcher)", String(reflecting: fetcher), dumped] {
            #expect(!text.contains(MediaFixture.token))
            #expect(!text.contains(MediaFixture.email))
            #expect(!text.contains(MediaFixture.basicAuth))
        }
    }
}
