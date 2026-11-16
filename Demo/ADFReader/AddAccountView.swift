import ADFAtlassianAuth
import SwiftUI

/// Adds an Atlassian account by hand: site, email, a scoped API token the
/// user creates on Atlassian's token page, and its expiry date. "Connect"
/// checks the token with the site's GraphQL gateway and saves it to the
/// keychain; with a prefill it replaces an existing account's token.
///
/// The token lives only in this view's `SecureField` state until it is
/// handed to `AccountStore.connect`; it is never shown, logged or put in an
/// accessibility value.
struct AddAccountView: View {
    private enum Field: Hashable {
        case site, email, token
    }

    @Environment(AccountStore.self) private var accounts
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @FocusState private var focus: Field?
    @State private var site: String
    @State private var email: String
    @State private var token = ""
    @State private var expiry: Date
    @State private var connecting = false
    @State private var errorMessage: String?
    private let replacing: Bool

    init(prefill: AccountPrefill? = nil) {
        _site = State(initialValue: prefill?.site ?? "")
        _email = State(initialValue: prefill?.email ?? "")
        let days = AtlassianTokenScopes.defaultExpiryDays
        let defaultExpiry = Calendar.current.date(byAdding: .day, value: days, to: Date())
            ?? Date().addingTimeInterval(TimeInterval(days) * 86_400)
        _expiry = State(initialValue: defaultExpiry)
        replacing = prefill != nil
    }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                siteSection
                emailSection
                tokenPageSection
                tokenSection
                connectSection
            }
            .onChange(of: errorMessage) { _, message in
                guard message != nil else { return }
                withAnimation { proxy.scrollTo(ErrorAnchor.id, anchor: .bottom) }
            }
        }
        .navigationTitle(replacing ? "Replace Token" : "Add Account")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(connecting)
        .onAppear {
            if replacing { focus = .token }
        }
    }

    private enum ErrorAnchor {
        static let id = "add-error-anchor"
    }

    // MARK: - Sections

    private var siteSection: some View {
        Section {
            TextField("Site", text: $site, prompt: Text(verbatim: "acme.atlassian.net"))
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($focus, equals: .site)
                .onSubmit { focus = .email }
                .accessibilityIdentifier("add-site")
        } header: {
            Text("Site")
        } footer: {
            if let host = normalizedHost {
                Text(verbatim: "Connects to \(host)")
                    .accessibilityIdentifier("add-site-normalized")
            } else {
                Text("Your Confluence site, for example acme or acme.atlassian.net.")
            }
        }
    }

    private var emailSection: some View {
        Section("Email") {
            TextField("Email", text: $email, prompt: Text(verbatim: "you@example.com"))
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($focus, equals: .email)
                .onSubmit { focus = .token }
                .accessibilityIdentifier("add-email")
        }
    }

    private var tokenPageSection: some View {
        Section {
            Button {
                openURL(AtlassianTokenPage.createURL())
            } label: {
                Label("Open Token Page", systemImage: "safari")
            }
            .accessibilityIdentifier("add-open-token-page")
        } header: {
            Text("API Token")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Create an API token with scopes for Confluence, named ADFReader, expiring in \(AtlassianTokenScopes.defaultExpiryDays) days. If Atlassian doesn't preselect them, tick these scopes:")
                ForEach(AtlassianTokenScopes.required, id: \.self) { scope in
                    Text(verbatim: "• \(scope)")
                        .font(.footnote.monospaced())
                }
            }
            .accessibilityIdentifier("add-scopes")
        }
    }

    private var tokenSection: some View {
        Section {
            SecureField("Paste the API token", text: $token)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .privacySensitive()
                .submitLabel(.go)
                .focused($focus, equals: .token)
                .onSubmit(connect)
                .accessibilityIdentifier("add-token")
            DatePicker("Expires", selection: $expiry, displayedComponents: .date)
                .accessibilityIdentifier("add-expiry")
        } footer: {
            Text("Use the expiry date you picked on Atlassian's token page.")
        }
    }

    private var connectSection: some View {
        Section {
            Button(action: connect) {
                HStack(spacing: 8) {
                    Text(replacing ? "Replace Token" : "Connect")
                    if connecting {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .accessibilityIdentifier("add-connect")
        } footer: {
            if let errorMessage {
                Label {
                    Text(errorMessage)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .accessibilityHidden(true)
                }
                .foregroundStyle(.red)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("add-error")
                .id(ErrorAnchor.id)
            }
        }
    }

    // MARK: - Connect

    private var normalizedHost: String? {
        guard site.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return nil }
        return try? AtlassianSite(parsing: site).host
    }

    private func connect() {
        guard connecting == false else { return }
        // Close the keyboard first so the inline error below Connect is
        // visible whatever happens next.
        focus = nil
        errorMessage = nil
        let parsedSite: AtlassianSite
        do {
            parsedSite = try AtlassianSite(parsing: site)
        } catch {
            errorMessage = error.message
            return
        }
        let credential = AtlassianCredential(
            site: parsedSite,
            email: email.trimmingCharacters(in: .whitespacesAndNewlines),
            token: token.trimmingCharacters(in: .whitespacesAndNewlines),
            expiresAt: expiry
        )
        do {
            try credential.validate()
        } catch {
            errorMessage = error.message
            return
        }
        connecting = true
        Task {
            defer { connecting = false }
            do {
                try await accounts.connect(credential)
                token = ""
                dismiss()
            } catch {
                errorMessage = AccountStore.message(for: error)
            }
        }
    }
}
