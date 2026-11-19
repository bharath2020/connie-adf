import ADFAtlassianAuth
import SwiftUI

/// The "Add <site> as <email>?" step shared by both Mac handoffs (Scan from
/// Mac and Mac connects to phone). Nothing is saved until Add; Cancel
/// discards the credential. The token is never shown.
struct CredentialConfirmation: View {
    let credential: AtlassianCredential
    /// The stored account's email when one exists for the same site under a
    /// different email (``AccountStore/replacedEmail(by:)``).
    let replacingEmail: String?
    /// Accessibility identifier prefix, for example `pair` → `pair-confirm-add`.
    let identifierPrefix: String
    let onCancel: () -> Void
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(verbatim: "Add \(credential.site.host) as \(credential.email)?")
                .font(.headline)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("\(identifierPrefix)-confirm-title")
            if let expiresAt = credential.expiresAt {
                Text(verbatim: "Token expires \(expiresAt.formatted(date: .abbreviated, time: .omitted)).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let replacingEmail {
                Label {
                    Text(verbatim: "This replaces the account for \(credential.site.host) signed in as \(replacingEmail).")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .accessibilityHidden(true)
                }
                .font(.callout)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("\(identifierPrefix)-confirm-replace-warning")
            }
            HStack(spacing: 12) {
                Button("Cancel", role: .cancel, action: onCancel)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("\(identifierPrefix)-confirm-cancel")
                Button("Add", action: onAdd)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("\(identifierPrefix)-confirm-add")
            }
        }
    }
}
