import Foundation
import Security
import Testing
@testable import ADFAtlassianAuth

@Suite("Keychain attributes")
struct KeychainAttributesTests {
    @Test("the add dictionary is device-only, unsynchronized and labelled")
    func attributes() throws {
        let credential = Fixture.credential()
        let attributes = try KeychainCredentialStore.attributes(for: credential, service: "com.example.test")
        #expect(attributes[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(attributes[kSecAttrService as String] as? String == "com.example.test")
        #expect(attributes[kSecAttrAccount as String] as? String == "acme.atlassian.net")
        #expect(attributes[kSecAttrLabel as String] as? String == "ADFReader – acme.atlassian.net")
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(attributes[kSecAttrAccessGroup as String] == nil)
        #expect(attributes[kSecUseDataProtectionKeychain as String] == nil)

        let value = try #require(attributes[kSecValueData as String] as? Data)
        #expect(try AtlassianCredential.decode(value) == credential)

        let generic = try #require(attributes[kSecAttrGeneric as String] as? Data)
        #expect(!String(decoding: generic, as: UTF8.self).contains(Fixture.token))
        #expect(try AtlassianAccountSummary.decode(generic) == credential.summary)
    }

    @Test("the default service is the app's")
    func defaultService() {
        #expect(KeychainCredentialStore().service == "com.connie.adfreader.atlassian")
        #expect(KeychainCredentialStore.baseAttributes(site: Fixture.acme, service: "s")[kSecValueData as String] == nil)
    }

    static let keychainTestsEnabled = ProcessInfo.processInfo.environment["ADF_AUTH_KEYCHAIN_TESTS"] == "1"

    @Test("real keychain round-trip: save, load, list, overwrite, remove",
          .enabled(if: keychainTestsEnabled, "Set ADF_AUTH_KEYCHAIN_TESTS=1 to touch the real keychain"))
    func realKeychainRoundTrip() throws {
        let store = KeychainCredentialStore(service: "com.connie.adfreader.atlassian.tests.\(UUID().uuidString)")
        let acme = Fixture.credential()
        let other = Fixture.credential(site: try AtlassianSite(parsing: "beta-team"), cloudId: nil, expiresAt: nil)
        defer {
            _ = try? store.remove(site: acme.site)
            _ = try? store.remove(site: other.site)
        }

        #expect(try store.summaries().isEmpty)
        #expect(try store.load(site: acme.site) == nil)

        try store.save(other)
        try store.save(acme)
        #expect(try store.load(site: acme.site) == acme)
        #expect(try store.summaries() == [acme.summary, other.summary])

        var rotated = acme
        rotated.token = "ATATT3xFfGF0-synthetic-rotated-token"
        rotated.expiresAt = Date(timeIntervalSince1970: 1_900_000_000)
        try store.save(rotated)
        #expect(try store.load(site: acme.site) == rotated)
        #expect(try store.summaries().map(\.site) == [acme.site, other.site])
        #expect(try store.summaries().first?.expiresAt == rotated.expiresAt)

        #expect(try store.remove(site: acme.site))
        #expect(try store.remove(site: acme.site) == false)
        #expect(try store.load(site: acme.site) == nil)
        #expect(try store.summaries() == [other.summary])
        #expect(try store.remove(site: other.site))
        #expect(try store.summaries().isEmpty)
    }
}

@Suite("In-memory credential store")
struct InMemoryCredentialStoreTests {
    @Test("save, load, list sorted by site, overwrite, remove")
    func behaviour() throws {
        let zeta = Fixture.credential(site: try AtlassianSite(parsing: "zeta"))
        let acme = Fixture.credential()
        let store = InMemoryCredentialStore([zeta])
        try store.save(acme)
        #expect(try store.load(site: acme.site) == acme)
        #expect(try store.summaries().map(\.site.host) == ["acme.atlassian.net", "zeta.atlassian.net"])

        var rotated = acme
        rotated.token = "ATATT3xFfGF0-synthetic-rotated-token"
        try store.save(rotated)
        #expect(try store.load(site: acme.site)?.token == rotated.token)
        #expect(try store.summaries().count == 2)

        #expect(try store.remove(site: acme.site))
        #expect(try store.remove(site: acme.site) == false)
        #expect(try store.load(site: acme.site) == nil)
        #expect(try store.summaries().map(\.site) == [zeta.site])
    }

    @Test("concurrent saves are all kept")
    func concurrent() async throws {
        let store = InMemoryCredentialStore()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask {
                    try store.save(Fixture.credential(site: try AtlassianSite(parsing: "site\(index)")))
                }
            }
            try await group.waitForAll()
        }
        #expect(try store.summaries().count == 50)
    }

    @Test("works through the protocol existential")
    func existential() throws {
        let store: any CredentialStore = InMemoryCredentialStore()
        try store.save(Fixture.credential())
        #expect(try store.summaries().count == 1)
    }
}
