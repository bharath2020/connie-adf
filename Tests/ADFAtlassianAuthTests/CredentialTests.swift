import Foundation
import Testing
@testable import ADFAtlassianAuth

@Suite("Atlassian credential")
struct CredentialTests {
    @Test("JSON round-trips with sorted keys and ISO 8601 dates")
    func jsonRoundTrip() throws {
        let credential = Fixture.credential()
        let data = try credential.encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix(#"{"cloudId":"#))
        #expect(text.contains(#""createdAt":"2026-09-21T"#))
        #expect(text.contains(#""site":"acme.atlassian.net""#))
        #expect(text.contains(#""v":1"#))
        #expect(try AtlassianCredential.decode(data) == credential)
    }

    @Test("dates are truncated to whole seconds")
    func wholeSeconds() {
        #expect(Fixture.credential().createdAt == Date(timeIntervalSince1970: 1_790_000_000))
    }

    @Test("decoding accepts fractional seconds and a missing cloudId and expiry")
    func lenientDecode() throws {
        let json = #"{"v":1,"site":"acme","email":"a@b.c","token":"t","scopes":[],"createdAt":"2026-01-02T03:04:05.678Z"}"#
        let credential = try AtlassianCredential.decode(Data(json.utf8))
        #expect(credential.site.host == "acme.atlassian.net")
        #expect(credential.cloudId == nil)
        #expect(credential.expiresAt == nil)
    }

    @Test("a valid credential passes validation")
    func valid() throws {
        try Fixture.credential().validate()
        try Fixture.credential(cloudId: nil).validate()
    }

    @Test("validation failures", arguments: [
        (CredentialTests.modified { $0.v = 2 }, AtlassianCredential.ValidationError.unsupportedVersion(2)),
        (CredentialTests.modified { $0.email = "" }, .invalidEmail),
        (CredentialTests.modified { $0.email = "not-an-email" }, .invalidEmail),
        (CredentialTests.modified { $0.token = "" }, .emptyToken),
        (CredentialTests.modified { $0.token = String(repeating: "x", count: 513) }, .tokenTooLong(bytes: 513)),
        (CredentialTests.modified { $0.token = "abc def" }, .tokenHasWhitespace),
        (CredentialTests.modified { $0.token = "abc\n" }, .tokenHasWhitespace),
        (CredentialTests.modified { $0.token = "abc\u{0}" }, .tokenHasWhitespace),
        (CredentialTests.modified { $0.cloudId = "not-a-uuid" }, .invalidCloudId),
    ])
    func invalid(credential: AtlassianCredential, expected: AtlassianCredential.ValidationError) {
        #expect(throws: expected) { try credential.validate() }
    }

    @Test("a 512-byte token is still valid")
    func maxToken() throws {
        try Self.modified { $0.token = String(repeating: "x", count: 512) }.validate()
    }

    @Test("the token never appears in descriptions, reflection or dump")
    func redaction() {
        let credential = Fixture.credential()
        var dumped = ""
        dump(credential, to: &dumped)
        var dumpedArray = ""
        dump([credential], to: &dumpedArray)
        let renderings = [
            "\(credential)",
            String(describing: credential),
            String(reflecting: credential),
            "\([credential])",
            "\(Optional(credential) as Any)",
            dumped,
            dumpedArray,
        ]
        for text in renderings {
            #expect(!text.contains(Fixture.token))
            #expect(!text.contains("synthetic-test-token"))
        }
        #expect("\(credential)".contains("<redacted:\(Fixture.token.count) chars>"))
        #expect(dumped.contains("acme.atlassian.net"))
    }

    @Test("the summary carries no token")
    func summary() throws {
        let summary = Fixture.credential().summary
        #expect(summary.site == Fixture.acme)
        #expect(summary.email == Fixture.email)
        #expect(summary.id == Fixture.acme)
        let json = String(decoding: try summary.encoded(), as: UTF8.self)
        #expect(!json.contains(Fixture.token))
        #expect(try AtlassianAccountSummary.decode(Data(json.utf8)) == summary)
    }

    @Test("Redaction.token shows only the length")
    func redactionHelper() {
        #expect(Redaction.token("abcd") == "<redacted:4 chars>")
    }

    static func modified(_ change: (inout AtlassianCredential) -> Void) -> AtlassianCredential {
        var credential = Fixture.credential()
        change(&credential)
        return credential
    }
}

@Suite("Expiry status")
struct ExpiryStatusTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func summary(expiresIn seconds: TimeInterval?) -> AtlassianAccountSummary {
        AtlassianAccountSummary(site: Fixture.acme, email: Fixture.email, cloudId: nil, scopes: [], createdAt: now, expiresAt: seconds.map { now.addingTimeInterval($0) })
    }

    static let day: TimeInterval = 86_400
    static let thresholdCases: [(TimeInterval?, ExpiryStatus)] = [
        (nil, .noExpiry),
        (90 * day, .valid(daysLeft: 90)),
        (15 * day, .valid(daysLeft: 15)),
        (14 * day + 1, .valid(daysLeft: 15)),
        (14 * day, .expiringSoon(daysLeft: 14)),
        (13.2 * day, .expiringSoon(daysLeft: 14)),
        (3_600, .expiringSoon(daysLeft: 1)),
        (1, .expiringSoon(daysLeft: 1)),
        (0, .expired),
        (-day, .expired),
    ]

    @Test("thresholds", arguments: thresholdCases)
    func thresholds(seconds: TimeInterval?, expected: ExpiryStatus) {
        #expect(summary(expiresIn: seconds).expiryStatus(now: now) == expected)
    }

    @Test("needsAttention is true only when expiring soon or expired")
    func attention() {
        #expect(ExpiryStatus.expired.needsAttention)
        #expect(ExpiryStatus.expiringSoon(daysLeft: 3).needsAttention)
        #expect(!ExpiryStatus.valid(daysLeft: 30).needsAttention)
        #expect(!ExpiryStatus.noExpiry.needsAttention)
    }
}

@Suite("Token page")
struct TokenPageTests {
    @Test("the create URL preselects Confluence, 90 days and exactly the seven read and three write scopes")
    func createURL() throws {
        let url = AtlassianTokenPage.createURL()
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "id.atlassian.com")
        #expect(components.path == "/manage-profile/security/api-tokens")
        let items = components.queryItems ?? []
        #expect(items.contains { $0.name == "autofillToken" })
        #expect(items.first { $0.name == "expiryDays" }?.value == "90")
        #expect(items.first { $0.name == "appId" }?.value == "confluence")
        let scopesJSON = try #require(items.first { $0.name == "selectedScopes" }?.value)
        let scopes = try JSONDecoder().decode([String].self, from: Data(scopesJSON.utf8))
        #expect(scopes == [
            "read:page:confluence", "read:space:confluence", "read:blogpost:confluence", "read:comment:confluence",
            "read:content.metadata:confluence", "read:attachment:confluence", "readonly:content.attachment:confluence",
            "write:comment:confluence", "write:page:confluence", "write:blogpost:confluence",
        ])
        // Only read and the three create/edit write scopes: no delete or manage scope sneaks in.
        #expect(scopes.allSatisfy { $0.hasPrefix("read:") || $0.hasPrefix("readonly:") || AtlassianTokenScopes.write.contains($0) })
        #expect(!scopes.contains { $0.contains("delete") || $0.contains("manage") })
        #expect(scopes == AtlassianTokenScopes.required)
        // The raw query is fully percent-encoded (no bare quotes or brackets).
        let rawQuery = try #require(components.percentEncodedQuery)
        #expect(!rawQuery.contains("\""))
        #expect(!rawQuery.contains("["))
    }

    @Test("expiry days are honoured and clamped", arguments: [(30, "30"), (0, "1"), (400, "365")])
    func expiryDays(days: Int, expected: String) throws {
        let components = try #require(URLComponents(url: AtlassianTokenPage.createURL(expiryDays: days), resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.first { $0.name == "expiryDays" }?.value == expected)
    }

    @Test("manual steps name the button, the app, the expiry and every scope")
    func manualSteps() {
        let text = AtlassianTokenPage.manualSteps.joined(separator: "\n")
        #expect(text.contains("Create API token with scopes"))
        #expect(text.contains("ADFReader"))
        #expect(text.contains("90 days"))
        #expect(text.contains("Confluence"))
        for scope in AtlassianTokenScopes.required { #expect(text.contains(scope)) }
        #expect(AtlassianTokenPage.manualSteps(expiryDays: 30).joined().contains("30 days"))
    }

    @Test("the manage URL is the token list")
    func manageURL() {
        #expect(AtlassianTokenPage.manageURL.absoluteString == "https://id.atlassian.com/manage-profile/security/api-tokens")
    }
}
