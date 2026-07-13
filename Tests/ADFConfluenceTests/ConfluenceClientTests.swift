import Foundation
import Testing
@testable import ADFConfluence

final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var routes: [String: String] = [:]   // path -> JSON body
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override func startLoading() {
        let path = request.url!.path
        let body = Self.routes[path] ?? "{}"
        let resp = HTTPURLResponse(url: request.url!, statusCode: Self.routes[path] == nil ? 404 : 200,
                                   httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func stubbedClient() -> HTTPConfluenceClient {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [StubProtocol.self]
    return HTTPConfluenceClient(baseURL: URL(string: "https://example.test")!, session: URLSession(configuration: cfg))
}

@Suite("Confluence client", .serialized)
struct ConfluenceClientTests {
    @Test("fetches and decodes a page's ADF")
    func fetchesPage() async throws {
        let adf = #"{"version":1,"type":"doc","content":[]}"#
        let page = "{\"id\":\"7\",\"title\":\"Hello\",\"spaceId\":\"1\",\"parentId\":null,\"body\":{\"atlas_doc_format\":{\"value\":\(String(reflecting: adf)),\"representation\":\"atlas_doc_format\"}}}"
        StubProtocol.routes = ["/api/v2/pages/7.json": page]
        let p = try await stubbedClient().page(id: "7")
        #expect(p.title == "Hello")
        let obj = try JSONSerialization.jsonObject(with: p.adf) as! [String: Any]
        #expect(obj["type"] as? String == "doc")
    }

    @Test("lists spaces")
    func listsSpaces() async throws {
        StubProtocol.routes = ["/api/v2/spaces.json": #"{"results":[{"id":"1","key":"ADFTB","name":"Test Bed"}]}"#]
        let spaces = try await stubbedClient().spaces()
        #expect(spaces.map(\.key) == ["ADFTB"])
    }
}
