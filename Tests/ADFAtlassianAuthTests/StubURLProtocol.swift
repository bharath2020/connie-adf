import Foundation
import os
@testable import ADFAtlassianAuth

/// A URLProtocol stub that is safe under parallel tests: each stubbed session
/// carries its own ID header, and handlers/recorded requests are keyed by it.
final class AuthStubProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        var status: Int = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body: Data = Data()

        static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> Response {
            var all = ["Content-Type": "application/json"]
            all.merge(headers) { $1 }
            return Response(status: status, headers: all, body: Data(text.utf8))
        }
    }

    struct Recorded: Sendable {
        let url: URL?
        let method: String?
        let headers: [String: String]
        let body: Data
    }

    typealias Handler = @Sendable (Recorded) -> Result<Response, URLError>

    static let sessionHeader = "X-Auth-Stub-Session"
    private static let handlers = OSAllocatedUnfairLock<[String: Handler]>(initialState: [:])
    private static let recorded = OSAllocatedUnfairLock<[String: [Recorded]]>(initialState: [:])

    /// An ephemeral session whose requests all go to `handler`.
    static func session(_ handler: @escaping Handler) -> Stub {
        let id = UUID().uuidString
        handlers.withLock { $0[id] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthStubProtocol.self]
        configuration.httpAdditionalHeaders = [sessionHeader: id]
        return Stub(id: id, session: URLSession(configuration: configuration))
    }

    static func session(responding response: Response) -> Stub {
        session { _ in .success(response) }
    }

    struct Stub: Sendable {
        let id: String
        let session: URLSession
        var requests: [Recorded] { AuthStubProtocol.recorded.withLock { $0[id] ?? [] } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let headers = request.allHTTPHeaderFields ?? [:]
        let id = headers[Self.sessionHeader] ?? ""
        let entry = Recorded(url: request.url, method: request.httpMethod, headers: headers, body: Self.body(of: request))
        Self.recorded.withLock { $0[id, default: []].append(entry) }
        let handler = Self.handlers.withLock { $0[id] }
        let result = handler?(entry) ?? .failure(URLError(.unsupportedURL))
        switch result {
        case .success(let response):
            let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// Synthetic values only — never a real token.
enum Fixture {
    static let token = "ATATT3xFfGF0-synthetic-test-token"
    static let email = "tester@example.com"
    static let cloudId = "0f6a3c1e-2b4d-4e8f-9a1b-3c5d7e9f1a2b"

    static let acme = try! AtlassianSite(parsing: "acme")

    static func credential(
        site: AtlassianSite = Fixture.acme,
        token: String = Fixture.token,
        cloudId: String? = Fixture.cloudId,
        expiresAt: Date? = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> AtlassianCredential {
        AtlassianCredential(
            site: site,
            email: email,
            token: token,
            cloudId: cloudId,
            createdAt: Date(timeIntervalSince1970: 1_790_000_000.75),
            expiresAt: expiresAt
        )
    }
}
