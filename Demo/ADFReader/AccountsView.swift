import ADFAtlassianAuth
import SwiftUI

/// Where Atlassian Accounts pushes to.
enum AccountsDestination: Hashable {
    /// The manual form; `prefill` replaces the token of an existing account.
    case addManually(prefill: AccountPrefill?)
    case scanFromMac
}

/// Site and email carried into the manual form by "Replace Token".
struct AccountPrefill: Hashable {
    var site: String
    var email: String
}

/// Settings → Atlassian Accounts: the stored accounts (non-secret summaries
/// only), an expiry banner, removal, and the two ways to add one.
struct AccountsView: View {
    @Environment(AccountStore.self) private var accounts
    @State private var destination: AccountsDestination?
    @State private var pendingRemoval: AtlassianAccountSummary?
    @State private var removeError: String?

    var body: some View {
        let now = Date()
        List {
            if let loadError = accounts.loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("accounts-load-error")
                }
            }
            ForEach(accounts.summaries.filter { $0.expiryStatus(now: now).needsAttention }) { summary in
                Section {
                    expiryBanner(summary, now: now)
                }
            }
            if accounts.summaries.isEmpty {
                Section {
                    emptyState
                }
            } else {
                accountsSection(now: now)
            }
            Section {
                Button {
                    destination = .addManually(prefill: nil)
                } label: {
                    Label("Add Manually", systemImage: "key")
                }
                .accessibilityIdentifier("accounts-add-manual")
                Button {
                    destination = .scanFromMac
                } label: {
                    Label("Scan from Mac", systemImage: "qrcode.viewfinder")
                }
                .accessibilityIdentifier("accounts-scan-mac")
            }
        }
        .navigationTitle("Atlassian Accounts")
        .navigationBarTitleDisplayMode(.inline)
        .task { accounts.reload() }
        .navigationDestination(item: $destination) { destination in
            switch destination {
            case .addManually(let prefill):
                AddAccountView(prefill: prefill)
            case .scanFromMac:
                PairScanView()
            }
        }
        .confirmationDialog(
            pendingRemoval.map { "Remove \($0.site.host)?" } ?? "Remove Account?",
            isPresented: removalPresented,
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { summary in
            Button("Remove Account", role: .destructive) { remove(summary) }
                .accessibilityIdentifier("accounts-remove-confirm")
            Button("Cancel", role: .cancel) {}
        } message: { summary in
            Text(verbatim: "This deletes the token for \(summary.email) from this device. Also revoke the token at Atlassian.")
        }
        .alert("Couldn't Remove the Account", isPresented: removeErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(removeError ?? "")
        }
    }

    // MARK: - Sections

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Atlassian Accounts", systemImage: "person.crop.circle.badge.plus")
        } description: {
            Text("""
            Connect a Confluence site with a read-only API token.
            Add Manually: create the token at Atlassian, then paste it here.
            Scan from Mac: run adf-auth push on your Mac and scan its code.
            """)
        }
        .accessibilityIdentifier("accounts-empty")
    }

    private func accountsSection(now: Date) -> some View {
        Section {
            ForEach(accounts.summaries) { summary in
                accountRow(summary, now: now)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            pendingRemoval = summary
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                    .contextMenu {
                        Button("Replace Token", systemImage: "arrow.triangle.2.circlepath") {
                            destination = .addManually(prefill: AccountPrefill(site: summary.site.host, email: summary.email))
                        }
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            pendingRemoval = summary
                        }
                    }
            }
        } header: {
            Text("Accounts")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Removing an account deletes its token from this device. Also revoke the token at Atlassian.")
                Link("Manage API Tokens", destination: AtlassianTokenPage.manageURL)
                    .accessibilityIdentifier("accounts-manage-tokens")
            }
        }
    }

    private func accountRow(_ summary: AtlassianAccountSummary, now: Date) -> some View {
        let status = summary.expiryStatus(now: now)
        return VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: summary.site.host)
                .font(.headline)
            Text(verbatim: summary.email)
                .foregroundStyle(.secondary)
            Text(expiryText(summary, status: status))
                .font(.footnote)
                .foregroundStyle(status.needsAttention ? Color.orange : Color.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("account-row-\(summary.site.host)")
    }

    private func expiryBanner(_ summary: AtlassianAccountSummary, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(bannerText(summary, status: summary.expiryStatus(now: now)))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Button("Replace Token") {
                destination = .addManually(prefill: AccountPrefill(site: summary.site.host, email: summary.email))
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("accounts-replace-\(summary.site.host)")
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("accounts-expiry-banner-\(summary.site.host)")
    }

    // MARK: - Text

    private func expiryText(_ summary: AtlassianAccountSummary, status: ExpiryStatus) -> String {
        switch status {
        case .expired:
            return "Expired"
        case .noExpiry:
            return "No expiry date"
        case .valid, .expiringSoon:
            guard let expiresAt = summary.expiresAt else { return "No expiry date" }
            return "Expires \(expiresAt.formatted(date: .abbreviated, time: .omitted))"
        }
    }

    private func bannerText(_ summary: AtlassianAccountSummary, status: ExpiryStatus) -> String {
        let site = summary.site.host
        switch status {
        case .expired:
            return "The token for \(site) has expired."
        case .expiringSoon(let daysLeft) where daysLeft <= 0:
            return "The token for \(site) expires today."
        case .expiringSoon(let daysLeft):
            return "The token for \(site) expires in \(daysLeft) \(daysLeft == 1 ? "day" : "days")."
        case .valid, .noExpiry:
            return ""
        }
    }

    // MARK: - Removal

    private var removalPresented: Binding<Bool> {
        Binding(
            get: { pendingRemoval != nil },
            set: { if $0 == false { pendingRemoval = nil } }
        )
    }

    private var removeErrorPresented: Binding<Bool> {
        Binding(
            get: { removeError != nil },
            set: { if $0 == false { removeError = nil } }
        )
    }

    private func remove(_ summary: AtlassianAccountSummary) {
        do {
            try accounts.remove(site: summary.site)
        } catch {
            removeError = AccountStore.message(for: error)
        }
    }
}
