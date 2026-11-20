import Foundation
import os
import Testing
import ADFAtlassianAuth
@testable import ADFAtlassianMedia

/// Synthetic emoji-service values only — never a real token.
enum EmojiFixture {
    static let cloudId = MediaFixture.cloudId
    static let servicePrefix = "/emoji/\(cloudId)"
    static let serviceBase = "https://api.atlassian.com/emoji/\(cloudId)"
    static let tokenPath = "\(servicePrefix)/site/token/read"
    static let sitePath = "\(servicePrefix)/site"

    static let standardId = "1f600"
    static let standardImage = "https://pf-emoji-service.prod-east.frontend.public.atl-paas.net/assets/standard/ef8b0642/32x32/1f600.png"
    static let siteId = "0b885b7f-2b42-41b1-8a5e-f0dc5e91cb27"
    static let siteShortName = ":Growth_purple:"
    static let siteFileId = "83a820a3-9482-49a7-bf54-cab3f70d2c80"
    static let siteImagePath = "/media-api/file/\(siteFileId)/image"
    static let siteImage = "https://acme.atlassian.net\(siteImagePath)?collection=emoji-site-\(cloudId)&width=32&height=32&max-age=31536000"
    static let otherSiteId = "badcbb2a-8ffa-446f-a0bc-34b54c0f25af"
    static let otherSiteImage = "https://api.media.atlassian.com/file/1d8fe768/image?collection=emoji-site-\(cloudId)"

    static let clientId = "be1b72b3-synthetic-client"
    /// Not a real JWT; the fetcher never decodes it.
    static func jwt(_ generation: Int) -> String { "synthetic-read-jwt-\(generation)" }

    /// Epoch seconds the test clock starts at.
    static let start: TimeInterval = 1_795_147_318
    /// Observed lifetime: 59 minutes.
    static let lifetime: TimeInterval = 3_540

    static func tokenJSON(generation: Int, expiresAt: TimeInterval = start + lifetime) -> String {
        #"{"clientId":"\#(clientId)","collectionName":"emoji-site-\#(cloudId)","expiresAt":\#(Int(expiresAt)),"expiresIn":3540000,"jwt":"\#(jwt(generation))","maxFileSizeInBytes":1048576,"url":"https://acme.atlassian.net/media-api"}"#
    }

    static func emojiJSON(id: String, shortName: String, type: String, imagePath: String?, mediaFileId: String? = nil) -> String {
        var representation = #""width":32,"height":32"#
        if let imagePath { representation += #","imagePath":"\#(imagePath)""# }
        if let mediaFileId { representation += #","mediaFileId":"\#(mediaFileId)""# }
        return #"{"id":"\#(id)","shortName":"\#(shortName)","name":"n","type":"\#(type)","category":"CUSTOM","representation":{\#(representation)},"searchable":true}"#
    }

    static let standardEmoji = emojiJSON(id: standardId, shortName: ":grinning:", type: "STANDARD", imagePath: standardImage)
    static let siteEmoji = emojiJSON(id: siteId, shortName: siteShortName, type: "SITE", imagePath: siteImage, mediaFileId: siteFileId)
    static let otherSiteEmoji = emojiJSON(id: otherSiteId, shortName: ":goal:", type: "SITE", imagePath: otherSiteImage, mediaFileId: "1d8fe768")

    static func response(_ emojis: [String], meta: String = #"{"spriteSheets":{}}"#) -> String {
        #"{"emojis":[\#(emojis.joined(separator: ","))],"meta":\#(meta)}"#
    }

    static let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])
    static let cdnBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x02])
}

/// A settable clock for token expiry.
final class EmojiTestClock: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: EmojiFixture.start))
    var now: Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 += seconds } }
}

@Suite("Atlassian emoji fetcher", .timeLimit(.minutes(1)))
struct AtlassianEmojiFetcherTests {
    typealias Response = MediaStubProtocol.Response

    /// The current token generation the stub hands out and the media host
    /// accepts.
    final class TokenState: Sendable {
        let generation = OSAllocatedUnfairLock(initialState: 0)
        /// When true the media host rejects every token.
        let rejectAll = OSAllocatedUnfairLock(initialState: false)
    }

    /// A stub serving tenant_info, the token, the site list, by-ID lookups
    /// and both image hosts; `route` gets the first say.
    func makeStub(tokens: TokenState = TokenState(), _ route: (@Sendable (MediaStubProtocol.Recorded) -> Response?)? = nil) -> MediaStubProtocol.Stub {
        MediaStubProtocol.session { request in
            if let response = route?(request) { return .success(response) }
            let host = request.url?.host() ?? ""
            let path = request.url?.path() ?? ""
            switch (host, path) {
            case ("acme.atlassian.net", "/_edge/tenant_info"):
                return .success(.json(#"{"cloudId":"\#(EmojiFixture.cloudId)"}"#))
            case ("api.atlassian.com", EmojiFixture.tokenPath):
                let generation = tokens.generation.withLock { $0 += 1; return $0 }
                return .success(.json(EmojiFixture.tokenJSON(generation: generation)))
            case ("api.atlassian.com", EmojiFixture.sitePath):
                return .success(.json(EmojiFixture.response([EmojiFixture.siteEmoji, EmojiFixture.otherSiteEmoji])))
            case ("api.atlassian.com", "\(EmojiFixture.servicePrefix)/\(EmojiFixture.standardId)"):
                return .success(.json(EmojiFixture.response([EmojiFixture.standardEmoji])))
            case ("api.atlassian.com", "\(EmojiFixture.servicePrefix)/\(EmojiFixture.siteId)"):
                return .success(.json(EmojiFixture.response([EmojiFixture.siteEmoji])))
            case ("api.atlassian.com", "\(EmojiFixture.servicePrefix)/\(EmojiFixture.otherSiteId)"):
                return .success(.json(EmojiFixture.response([EmojiFixture.otherSiteEmoji])))
            case ("pf-emoji-service.prod-east.frontend.public.atl-paas.net", _):
                return .success(.bytes(EmojiFixture.cdnBytes))
            case ("acme.atlassian.net", _) where path.hasPrefix("/media-api/"),
                 ("api.media.atlassian.com", _):
                let current = tokens.generation.withLock { $0 }
                let ok = !tokens.rejectAll.withLock { $0 }
                    && request.headers["Authorization"] == "Bearer \(EmojiFixture.jwt(current))"
                    && request.headers["X-Client-Id"] == EmojiFixture.clientId
                return .success(ok ? .bytes(EmojiFixture.pngBytes) : .json(#"{"error":{"code":"Unauthorized"}}"#, status: 401))
            case ("api.atlassian.com", _) where path.hasPrefix(EmojiFixture.servicePrefix + "/"):
                return .success(Response(status: 404, headers: [:], body: Data()))
            default:
                return .success(.json(#"{"message":"no stub"}"#, status: 599))
            }
        }
    }

    func makeFetcher(_ stub: MediaStubProtocol.Stub, cloudId: String? = EmojiFixture.cloudId, clock: EmojiTestClock = EmojiTestClock()) -> AtlassianEmojiFetcher {
        AtlassianEmojiFetcher(credential: MediaFixture.credential(cloudId: cloudId), session: stub.session,
                              apiBase: AtlassianEmojiFetcher.defaultAPIBase, now: { clock.now })
    }

    /// No request may carry Basic auth, the email or the API token.
    func expectNoAPICredential(_ stub: MediaStubProtocol.Stub, sourceLocation: SourceLocation = #_sourceLocation) {
        for request in stub.requests {
            #expect(request.headers["Authorization"]?.hasPrefix("Basic") != true, sourceLocation: sourceLocation)
            for value in request.headers.values {
                #expect(!value.contains(MediaFixture.token), sourceLocation: sourceLocation)
                #expect(!value.contains(MediaFixture.email), sourceLocation: sourceLocation)
            }
            #expect(request.url?.absoluteString.contains(MediaFixture.token) != true, sourceLocation: sourceLocation)
        }
    }

    // MARK: Request shape

    @Test("an emoji is looked up by ID with a credential-free GET")
    func lookupRequestShape() async throws {
        let stub = makeStub()
        _ = try await makeFetcher(stub).data(emojiId: EmojiFixture.standardId, shortName: ":grinning:")
        let lookup = try #require(stub.requests.first)
        #expect(lookup.method == "GET")
        #expect(lookup.url?.absoluteString == "\(EmojiFixture.serviceBase)/1f600?preferredRepresentation=IMAGE")
        #expect(lookup.headers["Authorization"] == nil)
        #expect(lookup.headers["Accept"] == "application/json")
        #expect(lookup.headers["User-Agent"] == "adf-emoji/1")
    }

    @Test("an ID can never add path segments or a query")
    func idIsEncoded() async {
        let stub = makeStub()
        await #expect(throws: AtlassianEmojiError.notFound) {
            try await makeFetcher(stub).data(emojiId: "../site/token/read?x=1", shortName: "")
        }
        #expect(stub.requests.first?.url?.absoluteString == "\(EmojiFixture.serviceBase)/..%2Fsite%2Ftoken%2Fread%3Fx%3D1?preferredRepresentation=IMAGE")
        #expect(stub.requests(path: EmojiFixture.tokenPath).isEmpty)
    }

    // MARK: Standard vs site

    @Test("a standard emoji loads from the public CDN with no credentials and no token")
    func standardEmoji() async throws {
        let stub = makeStub()
        let data = try await makeFetcher(stub).data(emojiId: EmojiFixture.standardId, shortName: ":grinning:")
        #expect(data == EmojiFixture.cdnBytes)
        #expect(stub.requests.count == 2)
        let image = try #require(stub.requests.last)
        #expect(image.url?.absoluteString == EmojiFixture.standardImage)
        #expect(image.headers["Authorization"] == nil)
        #expect(image.headers["X-Client-Id"] == nil)
        #expect(image.headers["Accept"] == "image/*")
        #expect(stub.requests(path: EmojiFixture.tokenPath).isEmpty)
        expectNoAPICredential(stub)
    }

    @Test("a site emoji loads from the site's media API with the read token")
    func siteEmojiById() async throws {
        let stub = makeStub()
        let data = try await makeFetcher(stub).data(emojiId: EmojiFixture.siteId, shortName: EmojiFixture.siteShortName)
        #expect(data == EmojiFixture.pngBytes)
        #expect(stub.requests.map { $0.url?.path() ?? "" } == [
            "\(EmojiFixture.servicePrefix)/\(EmojiFixture.siteId)", EmojiFixture.tokenPath, EmojiFixture.siteImagePath,
        ])
        let token = try #require(stub.requests(path: EmojiFixture.tokenPath).first)
        #expect(token.url?.absoluteString == "\(EmojiFixture.serviceBase)/site/token/read")
        #expect(token.headers["Authorization"] == nil)
        let image = try #require(stub.requests.last)
        #expect(image.url?.absoluteString == EmojiFixture.siteImage)
        #expect(image.headers["Authorization"] == "Bearer \(EmojiFixture.jwt(1))")
        #expect(image.headers["X-Client-Id"] == EmojiFixture.clientId)
        expectNoAPICredential(stub)
    }

    @Test("a site emoji on api.media.atlassian.com gets the read token too")
    func siteEmojiOnMediaHost() async throws {
        let stub = makeStub()
        let data = try await makeFetcher(stub).data(emojiId: EmojiFixture.otherSiteId, shortName: ":goal:")
        #expect(data == EmojiFixture.pngBytes)
        let image = try #require(stub.requests.last)
        #expect(image.url?.host() == "api.media.atlassian.com")
        #expect(image.headers["Authorization"] == "Bearer \(EmojiFixture.jwt(1))")
    }

    @Test("a by-ID lookup is cached")
    func lookupIsCached() async throws {
        let stub = makeStub()
        let fetcher = makeFetcher(stub)
        _ = try await fetcher.data(emojiId: EmojiFixture.siteId, shortName: "")
        _ = try await fetcher.data(emojiId: EmojiFixture.siteId, shortName: "")
        #expect(stub.requests(path: "\(EmojiFixture.servicePrefix)/\(EmojiFixture.siteId)").count == 1)
        #expect(stub.requests(path: EmojiFixture.siteImagePath).count == 2)
    }

    // MARK: Read token

    @Test("the read token is cached across site emoji")
    func tokenIsCached() async throws {
        let stub = makeStub()
        let fetcher = makeFetcher(stub)
        _ = try await fetcher.data(emojiId: EmojiFixture.siteId, shortName: "")
        _ = try await fetcher.data(emojiId: EmojiFixture.otherSiteId, shortName: "")
        #expect(stub.requests(path: EmojiFixture.tokenPath).count == 1)
    }

    @Test("a token in the service response's meta is used without asking token/read")
    func tokenFromMeta() async throws {
        let meta = #"{"spriteSheets":{},"mediaApiToken":\#(EmojiFixture.tokenJSON(generation: 0))}"#
        let stub = makeStub { request in
            request.url?.path() == "\(EmojiFixture.servicePrefix)/\(EmojiFixture.siteId)"
                ? .json(EmojiFixture.response([EmojiFixture.siteEmoji], meta: meta)) : nil
        }
        let data = try await makeFetcher(stub).data(emojiId: EmojiFixture.siteId, shortName: "")
        #expect(data == EmojiFixture.pngBytes)
        #expect(stub.requests(path: EmojiFixture.tokenPath).isEmpty)
        #expect(stub.requests.last?.headers["Authorization"] == "Bearer \(EmojiFixture.jwt(0))")
    }

    @Test("the token is refreshed once it is within 60 s of expiry")
    func tokenExpiryMargin() async throws {
        let clock = EmojiTestClock()
        let stub = makeStub()
        let fetcher = makeFetcher(stub, clock: clock)
        _ = try await fetcher.data(emojiId: EmojiFixture.siteId, shortName: "")
        clock.advance(EmojiFixture.lifetime - 61)
        _ = try await fetcher.data(emojiId: EmojiFixture.siteId, shortName: "")
        #expect(stub.requests(path: EmojiFixture.tokenPath).count == 1)
        clock.advance(2)
        _ = try await fetcher.data(emojiId: EmojiFixture.siteId, shortName: "")
        #expect(stub.requests(path: EmojiFixture.tokenPath).count == 2)
        #expect(stub.requests.last?.headers["Authorization"] == "Bearer \(EmojiFixture.jwt(2))")
    }

    @Test("concurrent site emoji share one token request")
    func tokenRefreshCoalesces() async throws {
        let tokens = TokenState()
        let stub = makeStub(tokens: tokens) { request in
            guard request.url?.path() == EmojiFixture.tokenPath else { return nil }
            usleep(150_000) // keep the token in flight while the others arrive
            let generation = tokens.generation.withLock { $0 += 1; return $0 }
            return .json(EmojiFixture.tokenJSON(generation: generation))
        }
        let fetcher = makeFetcher(stub)
        let results = try await withThrowingTaskGroup(of: Data.self) { group in
            for index in 0..<8 {
                let id = index.isMultiple(of: 2) ? EmojiFixture.siteId : EmojiFixture.otherSiteId
                group.addTask { try await fetcher.data(emojiId: id, shortName: "") }
            }
            var all: [Data] = []
            for try await data in group { all.append(data) }
            return all
        }
        #expect(results.count == 8)
        #expect(results.allSatisfy { $0 == EmojiFixture.pngBytes })
        #expect(stub.requests(path: EmojiFixture.tokenPath).count == 1)
    }

    @Test("a rejected token is refreshed once and the image retried", arguments: [401, 403])
    func refreshOnRejection(status: Int) async throws {
        let tokens = TokenState()
        let rejectedOnce = OSAllocatedUnfairLock(initialState: false)
        let stub = makeStub(tokens: tokens) { request in
            guard request.url?.path() == EmojiFixture.siteImagePath else { return nil }
            let first = rejectedOnce.withLock { done in defer { done = true }; return !done }
            return first ? .json("{}", status: status) : nil
        }
        let data = try await makeFetcher(stub).data(emojiId: EmojiFixture.siteId, shortName: "")
        #expect(data == EmojiFixture.pngBytes)
        #expect(stub.requests(path: EmojiFixture.tokenPath).count == 2)
        let images = stub.requests(path: EmojiFixture.siteImagePath)
        try #require(images.count == 2)
        #expect(images[0].headers["Authorization"] == "Bearer \(EmojiFixture.jwt(1))")
        #expect(images[1].headers["Authorization"] == "Bearer \(EmojiFixture.jwt(2))")
    }

    @Test("a token rejected twice is unauthorized, after exactly one refresh")
    func persistentRejection() async {
        let tokens = TokenState()
        tokens.rejectAll.withLock { $0 = true }
        let stub = makeStub(tokens: tokens)
        await #expect(throws: AtlassianEmojiError.unauthorized) {
            try await makeFetcher(stub).data(emojiId: EmojiFixture.siteId, shortName: "")
        }
        #expect(stub.requests(path: EmojiFixture.tokenPath).count == 2)
        #expect(stub.requests(path: EmojiFixture.siteImagePath).count == 2)
    }

    @Test("an undecodable token is an invalid response", arguments: ["not json", #"{"clientId":"c"}"#, #"{"jwt":"j"}"#])
    func invalidToken(body: String) async {
        let stub = makeStub { $0.url?.path() == EmojiFixture.tokenPath ? .json(body) : nil }
        await #expect(throws: AtlassianEmojiError.invalidResponse) {
            try await makeFetcher(stub).data(emojiId: EmojiFixture.siteId, shortName: "")
        }
        #expect(stub.requests(path: EmojiFixture.siteImagePath).isEmpty)
    }

    // MARK: Short names

    @Test("without an ID the short name is looked up in the cached site list", arguments: ["Growth_purple", ":Growth_purple:", " :Growth_purple: "])
    func shortNameLookup(shortName: String) async throws {
        let stub = makeStub()
        let fetcher = makeFetcher(stub)
        #expect(try await fetcher.data(emojiId: nil, shortName: shortName) == EmojiFixture.pngBytes)
        #expect(try await fetcher.data(emojiId: "", shortName: ":goal:") == EmojiFixture.pngBytes)
        let lists = stub.requests(path: EmojiFixture.sitePath)
        #expect(lists.count == 1)
        #expect(lists.first?.url?.absoluteString == "\(EmojiFixture.serviceBase)/site?preferredRepresentation=IMAGE")
        #expect(lists.first?.headers["Authorization"] == nil)
        expectNoAPICredential(stub)
    }

    @Test("an unknown short name is not found; a stale cached list is refetched once")
    func shortNameMiss() async throws {
        let clock = EmojiTestClock()
        let stub = makeStub()
        let fetcher = makeFetcher(stub, clock: clock)
        await #expect(throws: AtlassianEmojiError.notFound) {
            try await fetcher.data(emojiId: nil, shortName: ":nope:")
        }
        await #expect(throws: AtlassianEmojiError.notFound) {
            try await fetcher.data(emojiId: nil, shortName: ":nope:")
        }
        #expect(stub.requests(path: EmojiFixture.sitePath).count == 1)
        clock.advance(61)
        await #expect(throws: AtlassianEmojiError.notFound) {
            try await fetcher.data(emojiId: nil, shortName: ":nope:")
        }
        #expect(stub.requests(path: EmojiFixture.sitePath).count == 2)
    }

    @Test("an ID the service doesn't know falls back to the short name")
    func unknownIdFallsBackToShortName() async throws {
        let stub = makeStub()
        let data = try await makeFetcher(stub).data(emojiId: "from-another-site", shortName: EmojiFixture.siteShortName)
        #expect(data == EmojiFixture.pngBytes)
        #expect(stub.requests(path: "\(EmojiFixture.servicePrefix)/from-another-site").count == 1)
        #expect(stub.requests(path: EmojiFixture.sitePath).count == 1)
    }

    @Test("no ID and no short name is not found, before any request", arguments: [nil, "", "  "] as [String?])
    func nothingToLookUp(id: String?) async {
        let stub = makeStub()
        await #expect(throws: AtlassianEmojiError.notFound) {
            try await makeFetcher(stub).data(emojiId: id, shortName: "::")
        }
        #expect(stub.requests.isEmpty)
    }

    @Test("short names normalize to :name:")
    func shortNameNormalization() {
        #expect(AtlassianEmojiFetcher.normalizedShortName("grinning") == ":grinning:")
        #expect(AtlassianEmojiFetcher.normalizedShortName(":grinning:") == ":grinning:")
        #expect(AtlassianEmojiFetcher.normalizedShortName(" :x ") == ":x:")
        #expect(AtlassianEmojiFetcher.normalizedShortName("") == nil)
        #expect(AtlassianEmojiFetcher.normalizedShortName("::") == nil)
        #expect(AtlassianEmojiFetcher.normalizedShortName(":") == nil)
    }

    // MARK: Errors

    @Test("lookup statuses map to emoji errors", arguments: [
        (401, AtlassianEmojiError.unauthorized),
        (403, AtlassianEmojiError.unauthorized),
        (404, AtlassianEmojiError.notFound),
        (429, AtlassianEmojiError.http(status: 429)),
        (500, AtlassianEmojiError.http(status: 500)),
    ])
    func lookupStatusMapping(status: Int, expected: AtlassianEmojiError) async {
        let stub = makeStub { ($0.url?.path() ?? "").hasPrefix(EmojiFixture.servicePrefix) ? .json("{}", status: status) : nil }
        await #expect(throws: expected) {
            try await makeFetcher(stub).data(emojiId: EmojiFixture.standardId, shortName: "")
        }
    }

    @Test("lookup bodies without a usable emoji are mapped", arguments: [
        ("not json", AtlassianEmojiError.invalidResponse),
        (#"{"emojis":[]}"#, AtlassianEmojiError.notFound),
        (#"{}"#, AtlassianEmojiError.notFound),
        (EmojiFixture.response([EmojiFixture.emojiJSON(id: "1f600", shortName: ":grinning:", type: "STANDARD", imagePath: nil)]), AtlassianEmojiError.invalidResponse),
    ])
    func lookupBodyMapping(body: String, expected: AtlassianEmojiError) async {
        let stub = makeStub { $0.url?.path() == "\(EmojiFixture.servicePrefix)/1f600" ? .json(body) : nil }
        await #expect(throws: expected) {
            try await makeFetcher(stub).data(emojiId: EmojiFixture.standardId, shortName: "")
        }
    }

    @Test("image statuses map to emoji errors", arguments: [
        (404, AtlassianEmojiError.notFound),
        (500, AtlassianEmojiError.http(status: 500)),
    ])
    func imageStatusMapping(status: Int, expected: AtlassianEmojiError) async {
        let stub = makeStub { $0.url?.host() == "pf-emoji-service.prod-east.frontend.public.atl-paas.net" ? .json("{}", status: status) : nil }
        await #expect(throws: expected) {
            try await makeFetcher(stub).data(emojiId: EmojiFixture.standardId, shortName: "")
        }
    }

    // MARK: Host allow-list

    @Test("image URLs are classified by scheme and host", arguments: [
        ("https://api.media.atlassian.com/file/f/image", Result<AtlassianEmojiFetcher.ImageHostKind, AtlassianEmojiError>.success(.media)),
        ("https://acme.atlassian.net/media-api/file/f/image?collection=c", .success(.media)),
        ("https://ACME.atlassian.net/media-api/file/f/image", .success(.media)),
        ("https://pf-emoji-service.prod-east.frontend.public.atl-paas.net/assets/standard/x.png", .success(.publicImage)),
        ("https://acme.atlassian.net/wiki/x.png", .failure(.unsupportedHost)),
        ("https://other.atlassian.net/media-api/file/f/image", .failure(.unsupportedHost)),
        ("https://evil.example.test/media-api/file/f/image", .failure(.unsupportedHost)),
        ("https://atl-paas.net.evil.example.test/x.png", .failure(.unsupportedHost)),
        ("https://api.media.atlassian.com:8443/file/f/image", .failure(.unsupportedHost)),
        ("https://user@api.media.atlassian.com/file/f/image", .failure(.unsupportedHost)),
        ("http://api.media.atlassian.com/file/f/image", .failure(.insecureURL)),
        ("http://pf-emoji-service.prod-east.frontend.public.atl-paas.net/x.png", .failure(.insecureURL)),
    ])
    func hostClassification(url: String, expected: Result<AtlassianEmojiFetcher.ImageHostKind, AtlassianEmojiError>) throws {
        let actual = Result { try AtlassianEmojiFetcher.classifyImageURL(URL(string: url)!, siteHost: "acme.atlassian.net") }
            .mapError { $0 as! AtlassianEmojiError }
        #expect(actual == expected)
    }

    @Test("a site emoji pointing at another host is refused before any token is sent", arguments: [
        ("https://evil.example.test/media-api/file/f/image", AtlassianEmojiError.unsupportedHost),
        ("http://acme.atlassian.net/media-api/file/f/image", AtlassianEmojiError.insecureURL),
    ])
    func untrustedImageRefused(imagePath: String, expected: AtlassianEmojiError) async {
        let emoji = EmojiFixture.emojiJSON(id: EmojiFixture.siteId, shortName: EmojiFixture.siteShortName, type: "SITE", imagePath: imagePath, mediaFileId: "f")
        let stub = makeStub { $0.url?.path() == "\(EmojiFixture.servicePrefix)/\(EmojiFixture.siteId)" ? .json(EmojiFixture.response([emoji])) : nil }
        await #expect(throws: expected) {
            try await makeFetcher(stub).data(emojiId: EmojiFixture.siteId, shortName: "")
        }
        #expect(stub.requests.count == 1)
        #expect(stub.requests(path: EmojiFixture.tokenPath).isEmpty)
    }

    @Test("a media redirect to another host drops Authorization and X-Client-Id")
    func crossHostRedirectStripsToken() async throws {
        let cdn = URL(string: "https://media-cdn.atlassian.com/file/f/binary?signed=synthetic")!
        let stub = makeStub { request in
            if request.url?.host() == "media-cdn.atlassian.com" { return .bytes(EmojiFixture.pngBytes) }
            if request.url?.path() == EmojiFixture.siteImagePath { return .redirect(to: cdn) }
            return nil
        }
        let data = try await makeFetcher(stub).data(emojiId: EmojiFixture.siteId, shortName: "")
        #expect(data == EmojiFixture.pngBytes)
        let image = try #require(stub.requests(path: EmojiFixture.siteImagePath).first)
        #expect(image.headers["Authorization"] == "Bearer \(EmojiFixture.jwt(1))")
        let followed = try #require(stub.requests.first { $0.url?.host() == "media-cdn.atlassian.com" })
        #expect(followed.headers["Authorization"] == nil)
        #expect(followed.headers["X-Client-Id"] == nil)
    }

    @Test("a redirect to plain http is refused")
    func insecureRedirectRefused() async {
        let insecure = URL(string: "http://media.example.test/x.png")!
        let stub = makeStub { request in
            if request.url?.host() == "media.example.test" { return .bytes(EmojiFixture.pngBytes) }
            if request.url?.host() == "pf-emoji-service.prod-east.frontend.public.atl-paas.net" { return .redirect(to: insecure) }
            return nil
        }
        await #expect(throws: AtlassianEmojiError.insecureURL) {
            try await makeFetcher(stub).data(emojiId: EmojiFixture.standardId, shortName: "")
        }
        #expect(!stub.requests.contains { $0.url?.host() == "media.example.test" })
    }

    // MARK: Cloud ID and plug point

    @Test("without a cloud ID, tenant_info is fetched once, without credentials")
    func cloudIdFromTenantInfo() async throws {
        let stub = makeStub()
        let fetcher = makeFetcher(stub, cloudId: nil)
        _ = try await fetcher.data(emojiId: EmojiFixture.standardId, shortName: "")
        _ = try await fetcher.data(emojiId: EmojiFixture.siteId, shortName: "")
        let tenant = stub.requests(path: "/_edge/tenant_info")
        #expect(tenant.count == 1)
        #expect(tenant.first?.url?.absoluteString == "https://acme.atlassian.net/_edge/tenant_info")
        #expect(tenant.first?.headers["Authorization"] == nil)
        #expect(try await fetcher.resolvedCloudId() == EmojiFixture.cloudId)
        expectNoAPICredential(stub)
    }

    @Test("emojiFetch loads by ID, and by short name without one")
    func emojiFetchClosure() async throws {
        let stub = makeStub()
        let fetch: @Sendable (String?, String) async throws -> Data = makeFetcher(stub).emojiFetch
        #expect(try await fetch(EmojiFixture.standardId, ":grinning:") == EmojiFixture.cdnBytes)
        #expect(try await fetch(nil, EmojiFixture.siteShortName) == EmojiFixture.pngBytes)
        await #expect(throws: AtlassianEmojiError.notFound) { try await fetch(nil, ":nope:") }
        expectNoAPICredential(stub)
    }

    // MARK: Redaction

    @Test("errors, the fetcher and the cached token never show a token")
    func redaction() async throws {
        let errors: [AtlassianEmojiError] = [.notFound, .unauthorized, .invalidResponse, .insecureURL, .unsupportedHost, .http(status: 500)]
        for error in errors {
            for text in [error.message, "\(error)", error.localizedDescription] {
                #expect(!text.isEmpty)
                #expect(!text.contains(MediaFixture.token))
                #expect(!text.contains(EmojiFixture.jwt(1)))
            }
        }

        let stub = makeStub()
        let fetcher = makeFetcher(stub)
        _ = try await fetcher.data(emojiId: EmojiFixture.siteId, shortName: "")
        let token = try await fetcher.validReadToken()
        #expect(token.jwt == EmojiFixture.jwt(1))
        var dumped = ""
        dump(fetcher, to: &dumped)
        dump(token, to: &dumped)
        for text in ["\(fetcher)", String(reflecting: fetcher), "\(token)", String(reflecting: token), dumped] {
            #expect(!text.contains(EmojiFixture.jwt(1)))
            #expect(!text.contains(MediaFixture.token))
            #expect(!text.contains(MediaFixture.email))
        }
    }
}
