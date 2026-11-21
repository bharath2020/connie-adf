import CryptoKit
import Foundation

/// A `ResolverCache` of bytes on disk: one file per key in one directory,
/// bounded by a total byte size and evicted least recently used first.
///
/// Files outlive the process, so a relaunch finds the bytes it stored
/// before. The index of files is read from the directory on first use,
/// not at init, so making a cache costs no disk access.
public actor DiskCache: ResolverCache {
    public typealias Key = String
    public typealias Value = Data

    private let directory: URL
    private let byteLimit: Int
    private let writingOptions: Data.WritingOptions

    /// File name → size and last access; `nil` until first use.
    private var index: [String: Entry]?
    private var storedBytes = 0
    /// The last access stamp given out; keeps stamps strictly increasing
    /// so two accesses in the same clock tick still order.
    private var lastStamp = Date.distantPast

    private struct Entry {
        var size: Int
        var lastAccess: Date
    }

    /// - Parameters:
    ///   - directory: Where the files live. Made on first use if missing.
    ///     The cache owns it: `removeAll()` empties it.
    ///   - byteLimit: The most total bytes kept. A value larger than this
    ///     is not stored.
    ///   - protection: The data protection class of each file. The default
    ///     keeps files readable while the device is locked after its first
    ///     unlock, so images load for a reader opened from the background.
    public init(directory: URL,
                byteLimit: Int,
                protection: FileProtectionType = .completeUntilFirstUserAuthentication) {
        self.directory = directory
        self.byteLimit = byteLimit
        self.writingOptions = [.atomic, Self.protectionOption(for: protection)]
    }

    public func value(for key: String) async -> Data? {
        let name = Self.fileName(for: key)
        guard loadIndex()[name] != nil else { return nil }
        let url = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else {
            // The file vanished (or became unreadable) behind the index.
            drop(name)
            return nil
        }
        let now = nextStamp()
        index?[name]?.lastAccess = now
        // The modification date carries the access order across relaunches.
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        return data
    }

    public func store(_ value: Data, for key: String) async {
        write(value, for: key)
    }

    /// Stores `value` for `key` only if `shouldStore` returns true. It is
    /// asked on this actor, right before the write, so the answer cannot go
    /// stale between the check and the write: a `removeAll()` either runs
    /// first and the check sees what changed, or runs after and deletes
    /// the file.
    public func store(_ value: Data, for key: String, if shouldStore: @Sendable () -> Bool) {
        guard shouldStore() else { return }
        write(value, for: key)
    }

    private func write(_ value: Data, for key: String) {
        let name = Self.fileName(for: key)
        _ = loadIndex()
        // Replacing drops the old value first, so a failed or refused write
        // never leaves stale bytes behind for this key.
        if index?[name] != nil {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            drop(name)
        }
        guard value.count <= byteLimit else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try value.write(to: directory.appendingPathComponent(name), options: writingOptions)
        } catch {
            return
        }
        index?[name] = Entry(size: value.count, lastAccess: nextStamp())
        storedBytes += value.count
        evictToLimit()
    }

    /// Deletes every stored file.
    public func removeAll() {
        for name in loadIndex().keys {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        index = [:]
        storedBytes = 0
    }

    /// The total bytes of the stored files (tests).
    var totalBytes: Int {
        _ = loadIndex()
        return storedBytes
    }

    // MARK: - Index

    /// The index, read from the directory listing on first use. Only names
    /// this cache writes (64 hex digits) count, so an atomic write's
    /// leftover temporary file is never served or evicted by mistake.
    private func loadIndex() -> [String: Entry] {
        if let index { return index }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let urls = (try? fileManager.contentsOfDirectory(at: directory,
                                                         includingPropertiesForKeys: keys)) ?? []
        var loaded: [String: Entry] = [:]
        var bytes = 0
        for url in urls {
            let name = url.lastPathComponent
            guard Self.isCacheFileName(name),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            loaded[name] = Entry(size: size, lastAccess: values.contentModificationDate ?? .distantPast)
            bytes += size
        }
        index = loaded
        storedBytes = bytes
        // A smaller limit than the last launch's applies at once.
        evictToLimit()
        return index ?? loaded
    }

    private func drop(_ name: String) {
        guard let entry = index?.removeValue(forKey: name) else { return }
        storedBytes -= entry.size
    }

    /// Deletes the least recently used files until the total fits.
    private func evictToLimit() {
        guard storedBytes > byteLimit, let index else { return }
        let oldestFirst = index.sorted { $0.value.lastAccess < $1.value.lastAccess }
        for (name, _) in oldestFirst where storedBytes > byteLimit {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            drop(name)
        }
    }

    private func nextStamp() -> Date {
        let now = Date()
        lastStamp = now > lastStamp ? now : lastStamp.addingTimeInterval(0.000_001)
        return lastStamp
    }

    // MARK: - Names and options

    /// The hex SHA-256 of the key: a fixed-length, file-system-safe name
    /// for any key, without the key's text on disk.
    static func fileName(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func isCacheFileName(_ name: String) -> Bool {
        name.utf8.count == 64 && name.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func protectionOption(for protection: FileProtectionType) -> Data.WritingOptions {
        switch protection {
        case .none: .noFileProtection
        case .complete: .completeFileProtection
        case .completeUnlessOpen: .completeFileProtectionUnlessOpen
        default: .completeFileProtectionUntilFirstUserAuthentication
        }
    }
}
