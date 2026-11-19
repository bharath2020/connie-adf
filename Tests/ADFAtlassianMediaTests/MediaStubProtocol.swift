import Foundation
import os
import ADFAtlassianAuth

/// A URLProtocol stub that is safe under parallel tests: each stubbed session
/// carries its own ID header, and handlers/recorded requests are keyed by it.
/// Adapted from `AuthStubProtocol` (ADFAtlassianAuthTests), plus redirects.
///
/// A redirect response is reported with
/// `client.urlProtocol(_:wasRedirectedTo:redirectResponse:)`, which makes
/// URLSession ask the task's delegate (`willPerformHTTPRedirection`). The
/// proposed request copies every header of the current one (as CFNetwork
/// does, `Authorization` included), so the delegate is what decides whether
/// credentials travel. When the delegate accepts, URLSession starts a new
/// load of the returned request, which comes back through this stub and is
/// recorded; when it refuses, the task ends with the 3xx response (this
/// load finishes right after reporting the redirect, so it never hangs).
final class MediaStubProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        var status: Int = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body: Data = Data()
        /// When set, the response is a redirect to this URL.
        var redirectLocation: URL?

        static func json(_ text: String, status: Int = 200) -> Response {
            Response(status: status, headers: ["Content-Type": "application/json"], body: Data(text.utf8))
        }

        static func bytes(_ data: Data, mediaType: String = "image/png") -> Response {
            Response(status: 200, headers: ["Content-Type": mediaType], body: data)
        }

        static func redirect(to url: URL, status: Int = 302) -> Response {
            Response(status: status, headers: ["Location": url.absoluteString], body: Data(), redirectLocation: url)
        }
    }

    struct Recorded: Sendable {
        let url: URL?
        let method: String?
        let headers: [String: String]
    }

    typealias Handler = @Sendable (Recorded) -> Result<Response, URLError>

    static let sessionHeader = "X-Media-Stub-Session"
    private static let handlers = OSAllocatedUnfairLock<[String: Handler]>(initialState: [:])
    private static let recorded = OSAllocatedUnfairLock<[String: [Recorded]]>(initialState: [:])

    /// An ephemeral session whose requests all go to `handler`.
    static func session(_ handler: @escaping Handler) -> Stub {
        let id = UUID().uuidString
        handlers.withLock { $0[id] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaStubProtocol.self]
        configuration.httpAdditionalHeaders = [sessionHeader: id]
        return Stub(id: id, session: URLSession(configuration: configuration))
    }

    struct Stub: Sendable {
        let id: String
        let session: URLSession
        var requests: [Recorded] { MediaStubProtocol.recorded.withLock { $0[id] ?? [] } }

        func requests(path: String) -> [Recorded] {
            requests.filter { $0.url?.path() == path }
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let headers = request.allHTTPHeaderFields ?? [:]
        let id = headers[Self.sessionHeader] ?? ""
        let entry = Recorded(url: request.url, method: request.httpMethod, headers: headers)
        Self.recorded.withLock { $0[id, default: []].append(entry) }
        let handler = Self.handlers.withLock { $0[id] }
        let result = handler?(entry) ?? .failure(URLError(.unsupportedURL))
        switch result {
        case .success(let response):
            let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
            if let location = response.redirectLocation {
                var redirected = URLRequest(url: location, cachePolicy: request.cachePolicy, timeoutInterval: request.timeoutInterval)
                redirected.httpMethod = request.httpMethod
                for (name, value) in headers { redirected.setValue(value, forHTTPHeaderField: name) }
                client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: http)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// Synthetic values only — never a real token or address.
enum MediaFixture {
    static let token = "ATATT3xFfGF0-synthetic-media-test-token"
    static let email = "tester@example.com"
    static let cloudId = "0f6a3c1e-2b4d-4e8f-9a1b-3c5d7e9f1a2b"
    static let pageId = "229377"
    static let collection = "contentId-229377"

    static let acme = try! AtlassianSite(parsing: "acme")

    static var basicAuth: String {
        "Basic " + Data("\(email):\(token)".utf8).base64EncodedString()
    }

    static func credential(cloudId: String? = MediaFixture.cloudId) -> AtlassianCredential {
        AtlassianCredential(
            site: acme,
            email: email,
            token: token,
            cloudId: cloudId,
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    /// The gateway prefix for the fixture cloud ID.
    static let gateway = "https://api.atlassian.com/ex/confluence/\(cloudId)"
    static let listPath = "/ex/confluence/\(cloudId)/wiki/api/v2/pages/\(pageId)/attachments"
    static let listURL = "\(gateway)/wiki/api/v2/pages/\(pageId)/attachments?limit=250"

    static func downloadPath(attachmentId: String, pageId: String = MediaFixture.pageId) -> String {
        "/ex/confluence/\(cloudId)/wiki/rest/api/content/\(pageId)/child/attachment/\(attachmentId)/download"
    }

    /// A one-page attachment list.
    static func listJSON(_ items: [(id: String, fileId: String, title: String, mediaType: String)], next: String? = nil) -> String {
        let results = items.map { item in
            #"{"id":"\#(item.id)","status":"current","title":"\#(item.title)","pageId":"\#(pageId)","mediaType":"\#(item.mediaType)","fileId":"\#(item.fileId)","fileSize":1234,"_links":{"download":"/download/attachments/\#(pageId)/\#(item.title)"}}"#
        }.joined(separator: ",")
        let nextField = next.map { #","next":"\#($0)""# } ?? ""
        return #"{"results":[\#(results)],"_links":{"base":"https://acme.atlassian.net/wiki"\#(nextField)}}"#
    }

    static let fileA = "6a8d1f0e-1111-4c2b-9e3a-aaaaaaaaaaaa"
    static let fileB = "6a8d1f0e-2222-4c2b-9e3a-bbbbbbbbbbbb"
    static let defaultList = listJSON([
        (id: "att2001", fileId: fileA, title: "diagram.png", mediaType: "image/png"),
        (id: "att2002", fileId: fileB, title: "photo.jpg", mediaType: "image/jpeg"),
    ])

    /// Eight bytes standing in for an image; the fetcher never decodes.
    static let imageBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
}
