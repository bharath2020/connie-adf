import Foundation
import ADFConfluence

enum DocumentSource: Hashable {
    case fixture(Fixture)
    case remotePage(id: String, title: String)

    var title: String {
        switch self {
        case .fixture(let f): return f.name
        case .remotePage(_, let title): return title
        }
    }

    func loadData() async throws -> Data {
        switch self {
        case .fixture(let f):
            return try Data(contentsOf: f.url)
        case .remotePage(let id, _):
            let client = HTTPConfluenceClient(baseURL: AppConfig.confluenceBaseURL)
            return try await client.page(id: id).adf
        }
    }
}
