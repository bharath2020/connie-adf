import Foundation
import Security

/// A keychain failure, with the `OSStatus` and the system's explanation.
public struct KeychainError: Error, Sendable, Equatable {
    public let status: OSStatus
    /// What the store was doing: "save", "load", "list" or "remove".
    public let operation: String
    public let message: String

    init(status: OSStatus, operation: String, detail: String? = nil) {
        self.status = status
        self.operation = operation
        let system = detail ?? (SecCopyErrorMessageString(status, nil) as String?) ?? "Unknown error"
        self.message = "Keychain \(operation) failed: \(system) (OSStatus \(status))."
    }
}

/// Stores credentials as generic-password keychain items.
///
/// One item per site: service = ``service``, account = site host, label =
/// "ADFReader – <site>", value = credential JSON, `kSecAttrGeneric` = summary
/// JSON (no token). Items are `WhenUnlockedThisDeviceOnly`, never synchronized,
/// and have no access group. On macOS the store uses the legacy login keychain
/// (no `kSecUseDataProtectionKeychain`), so an unsigned command-line tool works
/// without entitlements.
public struct KeychainCredentialStore: CredentialStore {
    /// The production service name.
    public static let defaultService = "com.connie.adfreader.atlassian"

    public let service: String

    /// - Parameter service: Override only in tests (use a unique name).
    public init(service: String = KeychainCredentialStore.defaultService) {
        self.service = service
    }

    /// `"ADFReader – <host>"`.
    public static func label(for site: AtlassianSite) -> String {
        "ADFReader – \(site.host)"
    }

    /// The non-secret identity attributes of the item for `site`: class,
    /// service, account, label, accessibility and synchronizable.
    public static func baseAttributes(site: AtlassianSite, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: site.host,
            kSecAttrLabel as String: label(for: site),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    /// The full dictionary passed to `SecItemAdd`: ``baseAttributes(site:service:)``
    /// plus the summary JSON in `kSecAttrGeneric` and the credential JSON as
    /// `kSecValueData`.
    public static func attributes(for credential: AtlassianCredential, service: String) throws -> [String: Any] {
        var attributes = baseAttributes(site: credential.site, service: service)
        attributes[kSecAttrGeneric as String] = try credential.summary.encoded()
        attributes[kSecValueData as String] = try credential.encoded()
        return attributes
    }

    private func itemQuery(site: AtlassianSite) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: site.host,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    public func save(_ credential: AtlassianCredential) throws {
        let attributes = try Self.attributes(for: credential, service: service)
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
        guard addStatus == errSecDuplicateItem else {
            throw KeychainError(status: addStatus, operation: "save")
        }
        var changes = attributes
        for key in [kSecClass, kSecAttrService, kSecAttrAccount, kSecAttrSynchronizable] {
            changes.removeValue(forKey: key as String)
        }
        let updateStatus = SecItemUpdate(itemQuery(site: credential.site) as CFDictionary, changes as CFDictionary)
        guard updateStatus == errSecSuccess else {
            throw KeychainError(status: updateStatus, operation: "save")
        }
    }

    public func load(site: AtlassianSite) throws -> AtlassianCredential? {
        var query = itemQuery(site: site)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status, operation: "load") }
        guard let data = result as? Data else {
            throw KeychainError(status: errSecDecode, operation: "load", detail: "The item for \(site.host) has no data")
        }
        do {
            return try AtlassianCredential.decode(data)
        } catch {
            throw KeychainError(status: errSecDecode, operation: "load", detail: "The item for \(site.host) is not a valid credential")
        }
    }

    public func summaries() throws -> [AtlassianAccountSummary] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError(status: status, operation: "list") }
        let items = (result as? [[String: Any]]) ?? []
        // Items whose summary can't be decoded (written by something else)
        // are skipped rather than failing the whole list.
        return items
            .compactMap { ($0[kSecAttrGeneric as String] as? Data).flatMap { try? AtlassianAccountSummary.decode($0) } }
            .sorted { $0.site < $1.site }
    }

    @discardableResult
    public func remove(site: AtlassianSite) throws -> Bool {
        let status = SecItemDelete(itemQuery(site: site) as CFDictionary)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw KeychainError(status: status, operation: "remove") }
        return true
    }
}
