import SwiftUI

/// Screens inside the Settings sheet's navigation stack.
enum SettingsRoute: Hashable {
    case accounts
}

/// The Settings sheet, opened from the space list's gear button: Atlassian
/// accounts, the reader's Atlassian custom-emoji setting and the Images
/// setting. Starts at
/// `initialPath` — `[.accounts]` under `-openAccounts`, so automation lands
/// on Atlassian Accounts without tapping through.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var path: [SettingsRoute]
    /// "Load Custom Emoji from Atlassian" (`AtlassianEmojiPreference`).
    @AppStorage(AtlassianEmojiPreference.key) private var atlassianEmoji = false
    /// The Images setting, shared with the reader menu (`MediaModePreference`).
    @AppStorage(MediaModePreference.key) private var mediaMode: DemoMedia.Mode = .live

    init(initialPath: [SettingsRoute] = []) {
        _path = State(initialValue: initialPath)
    }

    /// A pick is the user's: it clears `-media`'s automation mark.
    private var mediaModeBinding: Binding<DemoMedia.Mode> {
        Binding(
            get: { mediaMode },
            set: { mode in
                MediaModePreference.userChose()
                mediaMode = mode
            }
        )
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
                Section {
                    Toggle("Load Custom Emoji from Atlassian", isOn: $atlassianEmoji)
                        .accessibilityIdentifier("settings-atlassian-emoji")
                } header: {
                    Text("Reader")
                } footer: {
                    Text("Shows site and Atlassian emoji on Confluence pages as images, through the "
                        + "emoji service Atlassian's own editor uses (not a documented API; it may "
                        + "stop working). Uses the first saved account's site. Off: they show their "
                        + ":short-name:. Applies to the next page you open.")
                }
                Section {
                    Picker("Images", selection: mediaModeBinding) {
                        ForEach(DemoMedia.Mode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .accessibilityIdentifier("settings-images-mode")
                } header: {
                    Text("Reading")
                } footer: {
                    Text("\(mediaMode.detail) Applies to the next page you open.")
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
