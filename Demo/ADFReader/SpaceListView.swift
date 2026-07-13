import SwiftUI
import ADFConfluence

struct SpaceListView: View {
    @State private var spaces: [Space] = []
    @State private var failure: String?
    private let client = HTTPConfluenceClient(baseURL: AppConfig.confluenceBaseURL)
    private let fixtures = Fixture.all

    var body: some View {
        List {
            Section("Spaces") {
                if let failure {
                    ContentUnavailableView("Spaces Unavailable", systemImage: "wifi.slash", description: Text(failure))
                } else {
                    ForEach(spaces) { space in
                        NavigationLink(value: space) {
                            Label(space.name, systemImage: "square.grid.2x2")
                        }
                    }
                }
            }
            Section("Local") {
                NavigationLink { ScanView() } label: { Label("Scan", systemImage: "qrcode.viewfinder") }
                ForEach(fixtures) { fixture in
                    NavigationLink(value: DocumentSource.fixture(fixture)) {
                        Text(fixture.name)
                    }
                }
            }
        }
        .navigationTitle("Confluence")
        .task { await loadSpaces() }
        .navigationDestination(for: Space.self) { PageTreeView(space: $0) }
        .navigationDestination(for: DocumentSource.self) { ReaderView(source: $0, options: .none) }
    }

    private func loadSpaces() async {
        do { spaces = try await client.spaces() }
        catch { failure = error.localizedDescription }
    }
}
