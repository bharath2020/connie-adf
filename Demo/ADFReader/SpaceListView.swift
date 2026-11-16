import SwiftUI
import ADFConfluence

struct SpaceListView: View {
    @Environment(AccountStore.self) private var accounts
    @State private var spaces: [Space] = []
    @State private var failure: String?
    /// The Settings sheet's starting path while it is shown, `nil` while it
    /// is not. `-openAccounts` starts it at Atlassian Accounts; the gear
    /// button always opens it at the top.
    @State private var settingsPath: [SettingsRoute]?
    private let client = HTTPConfluenceClient(baseURL: AppConfig.confluenceBaseURL)
    private let fixtures = Fixture.all

    init(openAccounts: Bool = false) {
        _settingsPath = State(initialValue: openAccounts ? [.accounts] : nil)
    }

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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Settings", systemImage: "gearshape") {
                    settingsPath = []
                }
                .accessibilityIdentifier("settings-button")
            }
        }
        .sheet(isPresented: settingsPresented) {
            SettingsView(initialPath: settingsPath ?? [])
                .environment(accounts)
        }
        .task { await loadSpaces() }
        .navigationDestination(for: Space.self) { PageTreeView(space: $0) }
        .navigationDestination(for: DocumentSource.self) { ReaderView(source: $0, options: .none) }
    }

    private var settingsPresented: Binding<Bool> {
        Binding(
            get: { settingsPath != nil },
            set: { if $0 == false { settingsPath = nil } }
        )
    }

    private func loadSpaces() async {
        do { spaces = try await client.spaces() }
        catch { failure = error.localizedDescription }
    }
}
