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

private struct ADFTableScrollSyncKey: EnvironmentKey {
    // Optional (not a shared default instance): the default must be
    // constructible from a nonisolated context, and a document that renders
    // outside `ADFDocumentView` (previews) should get no cross-document
    // registry. `ADFDocumentView` always injects a per-document instance.
    static let defaultValue: TableScrollSync? = nil
}

private struct ADFInTableCellKey: EnvironmentKey {
    static let defaultValue = false
}

private struct ADFRowGeometryRegistryKey: EnvironmentKey {
    // Optional, like `ADFTableScrollSyncKey` above: `nil` outside a
    // document (previews) or when the TK2 selection engine isn't wired.
    static let defaultValue: RowGeometryRegistry? = nil
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

    /// Per-document shared horizontal-offset registry for table slices,
    /// injected by `ADFDocumentView`. `nil` outside it (previews) — slices
    /// then pan independently.
    var adfTableScrollSync: TableScrollSync? {
        get { self[ADFTableScrollSyncKey.self] }
        set { self[ADFTableScrollSyncKey.self] = newValue }
    }

    /// True while rendering inside a table cell's content. The TextKit 2
    /// text-leaf toggle reads this so `-textkit2NoCells` can keep giant-table
    /// cells on the SwiftUI path (giant-table gate fallback). Set by
    /// `TableCellView` at the cell-content level.
    var adfInTableCell: Bool {
        get { self[ADFInTableCellKey.self] }
        set { self[ADFInTableCellKey.self] = newValue }
    }

    /// Per-document row-geometry registry (Task 17), injected by
    /// `ADFDocumentView` only on iOS behind `SelectionFlags.enabled` — live
    /// TK2 rows self-register here for on-demand selection-rect/caret/hit-test
    /// queries. `nil` outside a document (previews) or when selection isn't
    /// wired, same discipline as `adfTableScrollSync`.
    var adfRowGeometryRegistry: RowGeometryRegistry? {
        get { self[ADFRowGeometryRegistryKey.self] }
        set { self[ADFRowGeometryRegistryKey.self] = newValue }
    }
}
