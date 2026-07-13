import Foundation

/// One bundled ADF JSON document.
struct Fixture: Identifiable, Hashable {
    let name: String
    let url: URL

    var id: String { name }

    init?(named name: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json") else {
            return nil
        }
        self.name = name
        self.url = url
    }

    init(url: URL) {
        self.name = url.deletingPathExtension().lastPathComponent
        self.url = url
    }

    /// Every `.json` resource in the app bundle, sorted by name.
    static var all: [Fixture] {
        let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        return urls.map(Fixture.init(url:)).sorted { $0.name < $1.name }
    }
}
