import Foundation
import Security
import Testing
import ADFAtlassianAuth

/// Opt-in check that writes REAL content to Confluence. Skipped unless
/// `ADF_LIVE_WRITE=1` AND `ADF_LIVE_SITE` is set AND the standard adf-auth
/// Keychain item for that site exists. Run it with
/// `Scripts/live-confluence-write.sh`.
///
/// It creates a scratch page (with a comment, a reply and one edit) and a
/// scratch blog post in the personal space that holds the anchor page
/// `ADF_LIVE_PAGE` (default `229377`). It refuses to write unless that space
/// is a personal space (key starts with `~`, and equals `ADF_LIVE_SPACE_KEY`
/// when set), and it never writes to the anchor page itself. Delete the
/// scratch content by hand afterwards.
///
/// Prints step names, IDs, versions and links only (the personal space key
/// in links is masked, since it can be an account ID) — never the token, the
/// email, account IDs or an Authorization header.
@Suite(
    "Live Confluence write",
    .serialized,
    .enabled(if: LiveWriteEnvironment.credential != nil),
    .timeLimit(.minutes(5))
)
struct LiveConfluenceWriteTests {
    @Test("create a page, comment, reply, edit (and refuse a stale edit), create a blog post")
    func writeEverything() async throws {
        let credential = try #require(LiveWriteEnvironment.credential)
        let env = LiveWriteEnvironment.current
        let anchor = env.pageId
        try #require(credential.canWrite, Comment(rawValue: credential.summary.readOnlyNote ?? "the saved token is read-only"))
        let cloudId = try #require(credential.cloudId, "the saved account has no cloud ID; run adf-auth login again")

        // 1. Find the anchor page's space (read-only).
        let probe: PageProbeResult
        do {
            // The saved adf-auth credential reads; with ADF_LIVE_TOKEN_SERVICE
            // the write token may lack read scopes such as read:space.
            let reader = LiveWriteEnvironment.savedCredential ?? credential
            probe = try await AtlassianGraphQLClient(credential: reader).probePages(pageIds: [anchor], cloudId: cloudId)
        } catch {
            Self.report("probe anchor", error)
            throw error
        }
        for message in probe.errorMessages { print("live: probe anchor gateway error: \(message)") }
        let anchorPage = try #require(probe.pages.first { $0.pageId == anchor }, "anchor page \(anchor) not found")
        let spaceId = try #require(anchorPage.spaceId, "anchor page has no space ID")
        let spaceKey = try #require(anchorPage.spaceKey, "anchor page has no space key")
        // SAFETY: only ever write to a personal space.
        try #require(spaceKey.hasPrefix("~"), "the anchor page is not in a personal space; refusing to write")
        if let expected = env.spaceKey {
            try #require(spaceKey == expected, "the anchor page's space is not ADF_LIVE_SPACE_KEY; refusing to write")
        }
        print("live: anchor page \(anchor) is in personal space id \(spaceId)")

        let redact: (URL?) -> String = { url in
            guard let url else { return "-" }
            return url.absoluteString.replacingOccurrences(of: spaceKey, with: "~<personal>")
        }
        let client = try ConfluenceWriteClient(credential: credential)

        // 2. Scratch page.
        let page = try await Self.step("createPage") {
            try await client.createPage(spaceId: spaceId, title: Self.scratchTitle, adf: Self.doc([Self.scratchText]))
        }
        print("live: createPage: id \(page.contentId), version \(page.version.map(String.init) ?? "-"), \(redact(page.webURL))")
        try #require(page.contentId != anchor && !page.id.hasSuffix("/\(anchor)"), "the new page must not be the anchor page")

        // 3. Footer comment on the new page.
        let comment = try await Self.step("createFooterComment") {
            try await client.createFooterComment(pageId: page.contentId, adf: Self.doc(["Comment from the ADFReader write client test."]))
        }
        print("live: createFooterComment: id \(comment.commentId ?? comment.id), \(redact(comment.webURL))")

        // 4. Reply to that comment.
        let reply = try await Self.step("replyToComment") {
            try await client.replyToComment(commentId: comment.commentId ?? comment.id, adf: Self.doc(["Reply from the ADFReader write client test."]))
        }
        print("live: replyToComment: id \(reply.commentId ?? reply.id), \(redact(reply.webURL))")

        // 5. Edit at the current version.
        let before = try await Self.step("pageVersion") { try await client.pageVersion(pageId: page.contentId) }
        print("live: pageVersion: page \(before.pageId) at version \(before.number)")
        #expect(before.pageId != anchor)
        let updated = try await Self.step("updatePageBody") {
            try await client.updatePageBody(pageId: page.contentId, adf: Self.doc([Self.scratchText, "Edited once by the ADFReader write client test."]), expectedVersion: before.number)
        }
        print("live: updatePageBody: page \(updated.contentId), version \(updated.version.map(String.init) ?? "-"), \(redact(updated.webURL))")
        #expect(updated.contentId == page.contentId)
        #expect(updated.version == before.number + 1)

        // 6. A stale edit must be refused and change nothing.
        do {
            let stale = try await client.updatePageBody(pageId: page.contentId, adf: Self.doc(["This edit must be rejected as stale."]), expectedVersion: before.number)
            print("live: staleUpdate failed: the stale edit was applied (version \(stale.version.map(String.init) ?? "-"))")
            Issue.record("a stale-version update was not refused")
        } catch {
            guard case .versionConflict(_, let expected, let current) = error else {
                Self.report("staleUpdate", error)
                throw error
            }
            print("live: staleUpdate: refused (expected \(expected), current \(current.map(String.init) ?? "-"))")
        }
        let after = try await Self.step("pageVersion after stale") { try await client.pageVersion(pageId: page.contentId) }
        print("live: pageVersion after stale: version \(after.number)")
        #expect(after.number == before.number + 1, "the stale edit changed the page")

        // 7. Scratch blog post.
        let post = try await Self.step("createBlogPost") {
            try await client.createBlogPost(spaceId: spaceId, title: Self.scratchTitle, adf: Self.doc(["Scratch blog post created by the ADFReader write client test. Safe to delete."]))
        }
        print("live: createBlogPost: id \(post.contentId), version \(post.version.map(String.init) ?? "-"), \(redact(post.webURL))")
        #expect(post.contentId != anchor)
        print("live: done. Delete the scratch page \(page.contentId) and blog post \(post.contentId) when finished.")
    }

    static let scratchText = "Scratch page created by the ADFReader write client test. Safe to delete."

    /// Runs one write step; on failure prints the step, the message and the
    /// raw error case, then rethrows (failing the test).
    static func step<T>(_ name: String, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            report(name, error)
            throw error
        }
    }

    static func report(_ name: String, _ error: any Error) {
        let message = (error as? ConfluenceWriteError)?.message ?? (error as? AtlassianAuthError)?.message ?? "\(type(of: error))"
        print("live: \(name) failed: \(message)")
        print("live: \(name) error case: \(error)")
    }

    /// An ADF doc with one paragraph per string.
    static func doc(_ paragraphs: [String]) -> String {
        let content: [[String: Any]] = paragraphs.map { ["type": "paragraph", "content": [["type": "text", "text": $0]]] }
        let data = try! JSONSerialization.data(withJSONObject: ["type": "doc", "version": 1, "content": content], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// The exact scratch title. Page titles are unique in a space, so a
    /// second run fails at createPage instead of adding another page: delete
    /// (or rename) the earlier scratch page first.
    static let scratchTitle = "ADFReader write test"
}

/// The live-write settings, read from the environment, and the saved adf-auth
/// credential for that site. The Keychain is only touched once
/// `ADF_LIVE_WRITE=1` and `ADF_LIVE_SITE` are both set.
struct LiveWriteEnvironment: Sendable {
    let enabled: Bool
    let site: String?
    let pageId: String
    /// `ADF_LIVE_SPACE_KEY`: when set, the anchor page's space key must equal it.
    let spaceKey: String?

    static let current: LiveWriteEnvironment = {
        let environment = ProcessInfo.processInfo.environment
        func value(_ name: String) -> String? {
            guard let raw = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            return raw
        }
        return LiveWriteEnvironment(
            enabled: value("ADF_LIVE_WRITE") == "1",
            site: value("ADF_LIVE_SITE"),
            pageId: value("ADF_LIVE_PAGE") ?? "229377",
            spaceKey: value("ADF_LIVE_SPACE_KEY")
        )
    }()

    /// `nil` (suite skipped) unless opted in and a credential is saved.
    ///
    /// With `ADF_LIVE_TOKEN_SERVICE` set, the token comes from that login
    /// Keychain generic password instead (account = the saved account's
    /// email), keeping the saved account's site, email and cloud ID. Its
    /// scopes are taken to be ``AtlassianTokenScopes/required``: the gateway
    /// is the judge. Lets a separately stored test token be tried without
    /// replacing the adf-auth item.
    static let credential: AtlassianCredential? = {
        guard let saved = savedCredential else { return nil }
        let environment = ProcessInfo.processInfo.environment
        guard let service = environment["ADF_LIVE_TOKEN_SERVICE"], !service.isEmpty else { return saved }
        guard let token = genericPassword(service: service, account: saved.email) else { return nil }
        return AtlassianCredential(site: saved.site, email: saved.email, token: token, cloudId: saved.cloudId, createdAt: Date(), expiresAt: nil)
    }()

    /// The adf-auth Keychain credential for `ADF_LIVE_SITE`, when opted in.
    static let savedCredential: AtlassianCredential? = {
        guard current.enabled, let raw = current.site, let site = try? AtlassianSite(parsing: raw) else { return nil }
        return (try? KeychainCredentialStore().load(site: site)) ?? nil
    }()

    /// The secret of a login Keychain generic password, or nil. Never printed.
    static func genericPassword(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}
