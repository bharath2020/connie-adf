import Foundation
import os

/// Stores one credential per site. Saving a site that already exists
/// overwrites it (that is how token rotation works).
public protocol CredentialStore: Sendable {
    /// Adds the credential, or replaces the one stored for the same site.
    func save(_ credential: AtlassianCredential) throws
    /// The stored credential for `site`, or nil. Reads the secret.
    func load(site: AtlassianSite) throws -> AtlassianCredential?
    /// Non-secret summaries of every stored account, sorted by site. Never
    /// reads a token.
    func summaries() throws -> [AtlassianAccountSummary]
    /// Deletes the credential for `site`. Returns false when nothing was
    /// stored (not an error).
    @discardableResult
    func remove(site: AtlassianSite) throws -> Bool
}

/// A thread-safe store that keeps credentials in memory. For tests and
/// SwiftUI previews.
public final class InMemoryCredentialStore: CredentialStore {
    private let storage: OSAllocatedUnfairLock<[AtlassianSite: AtlassianCredential]>

    public init(_ credentials: [AtlassianCredential] = []) {
        var initial: [AtlassianSite: AtlassianCredential] = [:]
        for credential in credentials { initial[credential.site] = credential }
        storage = OSAllocatedUnfairLock(initialState: initial)
    }

    public func save(_ credential: AtlassianCredential) throws {
        storage.withLock { $0[credential.site] = credential }
    }

    public func load(site: AtlassianSite) throws -> AtlassianCredential? {
        storage.withLock { $0[site] }
    }

    public func summaries() throws -> [AtlassianAccountSummary] {
        storage.withLock { $0.values.map(\.summary) }.sorted { $0.site < $1.site }
    }

    @discardableResult
    public func remove(site: AtlassianSite) throws -> Bool {
        storage.withLock { $0.removeValue(forKey: site) != nil }
    }
}
