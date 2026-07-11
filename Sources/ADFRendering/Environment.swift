import CoreGraphics
import SwiftUI
import ADFModel
import ADFPreparation

/// Confluence media requires authenticated URL resolution, so media loading
/// is a protocol the host injects into `ADFDocumentView`. Implementations
/// resolve the reference, fetch, and decode downsampled to `targetSize`
/// (in points) — never full resolution into memory.
public protocol ADFMediaProvider: Sendable {
    func image(for attrs: MediaAttrs, targetSize: CGSize) async throws -> Image
}

private struct ADFMediaProviderKey: EnvironmentKey {
    static let defaultValue: (any ADFMediaProvider)? = nil
}

private struct ADFThemeKey: EnvironmentKey {
    static let defaultValue: ADFTheme = .default
}

extension EnvironmentValues {
    /// Media provider injected by `ADFDocumentView`; consumed by the media
    /// block views (Task 5).
    var adfMediaProvider: (any ADFMediaProvider)? {
        get { self[ADFMediaProviderKey.self] }
        set { self[ADFMediaProviderKey.self] = newValue }
    }

    /// Design tokens used by block views for spacing and margins. Must match
    /// the theme the document was prepared with (`ADFDocumentView` injects
    /// its model's theme).
    var adfTheme: ADFTheme {
        get { self[ADFThemeKey.self] }
        set { self[ADFThemeKey.self] = newValue }
    }
}
