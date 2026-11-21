import ADFModel
import ADFRendering
import CoreGraphics
import Foundation
import os
import SwiftUI

/// A `CacheFirstMediaProvider` for media behind an account, whose caches
/// hold one account's images at a time.
///
/// The caches key images by source alone, so without this the next account
/// would be served every image the last one loaded, with no fetch and so no
/// authorization check. `use(_:)` with a different account (or none) empties
/// the memory and disk caches, and every later request waits for that purge
/// before it looks in them. Loads started before the change still answer
/// the requests that made them, but never reach a later request: each
/// account gets its own memory cache and in-flight loads, and their
/// downloads are written to disk only while their account is current,
/// checked on the disk cache's actor with the write itself, so no write can
/// land after the purge.
public final class AccountMediaProvider<Account: Equatable & Sendable>: ADFMediaProvider, Sendable {
    private struct State: Sendable {
        var account: Account?
        var base: CacheFirstMediaProvider
        var purge: Task<Void, Never>?
    }

    private let disk: DiskCache?
    private let scale: CGFloat
    private let fetch: @Sendable (MediaAttrs) async throws -> Data
    /// Bumped by every account change, before its purge starts; a download
    /// made under an older value is not written to disk.
    private let generation = OSAllocatedUnfairLock(initialState: UInt64(0))
    private let state: OSAllocatedUnfairLock<State>

    /// - Parameters:
    ///   - account: The account the caches hold images for. Whatever
    ///     `disk` holds is taken to be this account's.
    ///   - disk: Encoded bytes across launches; `nil` keeps none.
    ///   - scale: Pixels per point of the decoded images.
    ///   - fetch: Loads the encoded bytes of an image for the current
    ///     account.
    public init(account: Account?,
                disk: DiskCache? = nil,
                scale: CGFloat = 2,
                fetch: @escaping @Sendable (MediaAttrs) async throws -> Data) {
        self.disk = disk
        self.scale = scale
        self.fetch = fetch
        state = OSAllocatedUnfairLock(initialState: State(
            account: account,
            base: Self.makeBase(generation: 0, current: generation, disk: disk, scale: scale, fetch: fetch)
        ))
    }

    /// Switches to `account`. A different account, or nil, empties the
    /// caches before any later request reads them.
    public func use(_ account: Account?) {
        state.withLock { state in
            guard state.account != account else { return }
            state.account = account
            let next = generation.withLock { value in
                value &+= 1
                return value
            }
            state.base = Self.makeBase(generation: next, current: generation, disk: disk, scale: scale, fetch: fetch)
            let previous = state.purge
            let disk = disk
            state.purge = Task {
                await previous?.value
                await disk?.removeAll()
            }
        }
    }

    public func image(for attrs: MediaAttrs, targetSize: CGSize) async throws -> Image {
        let (base, purge) = state.withLock { ($0.base, $0.purge) }
        await purge?.value
        return try await base.image(for: attrs, targetSize: targetSize)
    }

    /// A provider with fresh memory and in-flight loads over the shared disk
    /// cache, which writes to disk only while `current` is `generation`.
    private static func makeBase(generation: UInt64,
                                 current: OSAllocatedUnfairLock<UInt64>,
                                 disk: DiskCache?,
                                 scale: CGFloat,
                                 fetch: @escaping @Sendable (MediaAttrs) async throws -> Data) -> CacheFirstMediaProvider {
        CacheFirstMediaProvider(disk: disk,
                                storesToDisk: { current.withLock { $0 } == generation },
                                scale: scale,
                                fetch: fetch)
    }
}
