import Foundation
import ADFAtlassianAuth
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

    /// Stable key for persisting per-document state (task toggles).
    var storageKey: String {
        switch self {
        case .fixture(let fixture): return "fixture:\(fixture.name)"
        case .remotePage(let id, _): return "page:\(id)"
        }
    }

    /// The Atlassian site the document's media belongs to: the bundle's
    /// site for a remote page, none for a bundled fixture (its file IDs
    /// resolve nowhere). `DemoMedia` loads real images only with a site.
    var atlassianSite: AtlassianSite? {
        switch self {
        case .fixture: return nil
        case .remotePage: return AppConfig.confluenceSite
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
