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
    /// Set by a first Connect that would overwrite a stored account for
    /// the same site; a second tap (now "Replace Account") goes ahead.
    @State private var replaceWarning: ReplaceWarning?
    private let replacing: Bool
    /// The site "Replace Token" opened this form for: replacing its token
    /// needs no extra confirmation.
    private let prefilledSite: AtlassianSite?

    private struct ReplaceWarning: Equatable {
        var site: AtlassianSite
        var message: String
    }

    init(prefill: AccountPrefill? = nil) {
        _site = State(initialValue: prefill?.site ?? "")
        _email = State(initialValue: prefill?.email ?? "")
        let days = AtlassianTokenScopes.defaultExpiryDays
        let defaultExpiry = Calendar.current.date(byAdding: .day, value: days, to: Date())
            ?? Date().addingTimeInterval(TimeInterval(days) * 86_400)
        _expiry = State(initialValue: defaultExpiry)
        replacing = prefill != nil
        prefilledSite = prefill.flatMap { try? AtlassianSite(parsing: $0.site) }
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
            .onChange(of: replaceWarning) { _, warning in
                guard warning != nil else { return }
                withAnimation { proxy.scrollTo(ErrorAnchor.id, anchor: .bottom) }
            }
        }
        .onChange(of: site) { replaceWarning = nil }
        .onChange(of: email) { replaceWarning = nil }
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
            DatePicker("Expires", selection: $expiry, in: Date.now..., displayedComponents: .date)
                .accessibilityIdentifier("add-expiry")
        } footer: {
            Text("Use the expiry date you picked on Atlassian's token page.")
        }
    }

    private var connectSection: some View {
        Section {
            Button(action: connect) {
                HStack(spacing: 8) {
                    Text(connectTitle)
                    if connecting {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .accessibilityIdentifier("add-connect")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                if let replaceWarning {
                    Label {
                        Text(verbatim: replaceWarning.message)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(.orange)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("add-replace-warning")
                }
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
                }
            }
            .id(ErrorAnchor.id)
        }
    }

    private var connectTitle: String {
        if replaceWarning != nil { return "Replace Account" }
        return replacing ? "Replace Token" : "Connect"
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
        // Saving overwrites a stored account for the same site, so outside
        // "Replace Token" for that site the first tap only warns.
        accounts.reload()
        if parsedSite != prefilledSite, replaceWarning?.site != parsedSite,
           let existing = accounts.summary(for: parsedSite) {
            let sameEmail = existing.email.caseInsensitiveCompare(credential.email) == .orderedSame
            replaceWarning = ReplaceWarning(
                site: parsedSite,
                message: sameEmail
                    ? "This replaces the saved token for \(parsedSite.host) (\(existing.email)). Tap Replace Account to continue."
                    : "This replaces the account for \(parsedSite.host) signed in as \(existing.email). Tap Replace Account to continue."
            )
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
