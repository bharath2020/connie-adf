import Foundation
import Observation
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Owns the identity of the one active player for a renderer instance
/// (one per `ADFDocumentModel` in normal use): at most one `WKWebView`
/// exists at a time, so activated players can never accumulate processes,
/// playback, and compositor surfaces as the reader taps through a document.
///
/// Activating a new block deactivates the previous one (its view returns to
/// the facade and the web view is dismantled); a player whose block leaves
/// the visible viewport deactivates itself. Observable so only the
/// materialized video views re-evaluate on a change — which happens on taps
/// and viewport exits, never during plain scrolling.
@MainActor @Observable
final class YouTubePlaybackCoordinator {
    private(set) var activeBlockID: String?

    nonisolated init() {}

    func activate(_ blockID: String) {
        activeBlockID = blockID
    }

    /// Clears the active player only if `blockID` still owns it (a stale
    /// deactivation from a torn-down row must not kill a newer player).
    func deactivate(_ blockID: String) {
        if activeBlockID == blockID {
            activeBlockID = nil
        }
    }
}

/// Bounded cache of DECODED thumbnails keyed by video ID, so re-entering
/// rows repaint from memory instead of re-decoding `hqdefault.jpg` on every
/// viewport crossing (`URLCache` only saves the network trip, not the
/// decode). Main-actor confined — every caller is a view's `.task` — and
/// `NSCache` evicts under memory pressure.
@MainActor
enum YouTubeThumbnailCache {
    #if canImport(UIKit)
    typealias PlatformImage = UIImage
    #elseif canImport(AppKit)
    typealias PlatformImage = NSImage
    #endif

    private static let cache: NSCache<NSString, PlatformImage> = {
        let cache = NSCache<NSString, PlatformImage>()
        cache.countLimit = 48
        return cache
    }()

    static func image(for videoID: String) -> PlatformImage? {
        cache.object(forKey: videoID as NSString)
    }

    static func store(_ image: PlatformImage, for videoID: String) {
        cache.setObject(image, forKey: videoID as NSString)
    }
}
