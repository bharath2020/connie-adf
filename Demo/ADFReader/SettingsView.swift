import SwiftUI

/// Screens inside the Settings sheet's navigation stack.
enum SettingsRoute: Hashable {
    case accounts
}

/// The Settings sheet, opened from the space list's gear button. Starts at
/// `initialPath` — `[.accounts]` under `-openAccounts`, so automation lands
/// on Atlassian Accounts without tapping through.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var path: [SettingsRoute]

    init(initialPath: [SettingsRoute] = []) {
        _path = State(initialValue: initialPath)
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section("Accounts") {
                    NavigationLink(value: SettingsRoute.accounts) {
                        Label("Atlassian Accounts", systemImage: "person.crop.circle")
                    }
                    .accessibilityIdentifier("settings-accounts")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("settings-done")
                }
            }
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .accounts:
                    AccountsView()
                }
            }
        }
    }
}
