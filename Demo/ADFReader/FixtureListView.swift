import SwiftUI

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

/// Root screen: the bundled fixture documents, each linking to a reader.
struct FixtureListView: View {
    private let fixtures = Fixture.all

    var body: some View {
        List {
            NavigationLink {
                ScanView()
            } label: {
                Label("Scan", systemImage: "qrcode.viewfinder")
                    .font(.headline)
            }
            Section("Fixtures") {
                ForEach(fixtures) { fixture in
                    NavigationLink(value: fixture) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fixture.name)
                                .font(.headline)
                            Text(sizeDescription(of: fixture.url))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("ADF Fixtures")
        .navigationDestination(for: Fixture.self) { fixture in
            ReaderView(source: .fixture(fixture), options: .none)
        }
        .overlay {
            if fixtures.isEmpty {
                ContentUnavailableView(
                    "No Fixtures Bundled",
                    systemImage: "doc.questionmark"
                )
            }
        }
    }

    private func sizeDescription(of url: URL) -> String {
        guard let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return "unknown size"
        }
        return ByteCountFormatStyle().format(Int64(bytes))
    }
}
