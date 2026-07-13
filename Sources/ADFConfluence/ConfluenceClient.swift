import Foundation

public struct RemotePage: Sendable {
    public let id: String
    public let title: String
    public let adf: Data
}

public protocol ConfluenceClient: Sendable {
    func spaces() async throws -> [Space]
    func pages(inSpace id: String) async throws -> [PageSummary]
    func page(id: String) async throws -> RemotePage
}

public struct HTTPConfluenceClient: ConfluenceClient {
    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func spaces() async throws -> [Space] {
        try await get("api/v2/spaces.json", as: ResultsEnvelope<Space>.self).results
    }

    public func pages(inSpace id: String) async throws -> [PageSummary] {
        try await get("api/v2/spaces/\(id)/pages.json", as: ResultsEnvelope<PageSummary>.self).results
    }

    public func page(id: String) async throws -> RemotePage {
        let dto = try await get("api/v2/pages/\(id).json", as: PageDTO.self)
        return RemotePage(id: dto.id, title: dto.title,
                          adf: Data(dto.body.atlas_doc_format.value.utf8))
    }

    private func get<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        let url = baseURL.appending(path: path)
        let (data, resp) = try await session.data(from: url)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ConfluenceError.http((resp as? HTTPURLResponse)?.statusCode ?? -1, url)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private struct PageDTO: Decodable {
        struct Body: Decodable { let atlas_doc_format: ADFBody }
        struct ADFBody: Decodable { let value: String }
        let id: String; let title: String; let body: Body
    }
}

public enum ConfluenceError: Error, Sendable {
    case http(Int, URL)
}
