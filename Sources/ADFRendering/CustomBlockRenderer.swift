import SwiftUI
import ADFModel
import ADFPreparation

/// A complete block plugin: claims nodes at preparation time (the inherited
/// `ADFCustomBlockPreparer` facet, which runs off-main) and renders the
/// claimed blocks with a consumer-provided view over the plugin's own typed
/// payload.
///
/// The view contract ("the viewport"):
/// - For `.aspectRatio` sizing the LIBRARY draws the box (aspect ratio +
///   `maxWidth` cap) and proposes it to the view — fill the proposal. For the
///   other sizings the view is proposed the current content-column width
///   (nested containers propose their inner width). Size against proposals —
///   never with `GeometryReader`, never by reading named-coordinate-space
///   geometry (both are documented scroll-perf hazards in lazy rows).
/// - Height must be a deterministic function of the proposed width and the
///   environment — independent of view-local state, including interaction
///   state (a facade and the player it swaps in must occupy the identical
///   box). Content that genuinely changes goes through
///   `ADFDocumentModel.apply(_:revision:)`.
/// - Use semantic fonts / `@ScaledMetric` so Dynamic Type flows through with
///   zero re-preparation.
/// - Keep `body` cheap; defer heavy machinery (web views, players) behind an
///   explicit user interaction, and gate network work on scroll visibility.
///   An embedded web view must not capture the document's scroll gestures.
/// - The view is destroyed when its row leaves the render region; state that
///   must survive belongs to the host, keyed by `context.blockID`.
public protocol ADFCustomBlockRenderer: ADFCustomBlockPreparer {
    /// The payload type this plugin's claims carry.
    associatedtype Value: Hashable & Sendable
    associatedtype Content: View

    /// The view for one claimed block. Called on the main actor from inside
    /// the document's lazy rows, with the typed payload the matcher prepared.
    @MainActor @ViewBuilder
    func content(for value: Value, context: ADFCustomBlockContext) -> Content
}

/// Per-evaluation context handed to a custom block's view factory.
public struct ADFCustomBlockContext {
    /// The claimed node's stable structural-path ID — the row's identity,
    /// scroll anchor, and the key for any host-side state.
    public let blockID: String
    /// Design tokens the document was prepared with.
    public let theme: ADFTheme
    /// Find-in-page emphasis for this block. The library already draws a
    /// default whole-block emphasis; read this only to add custom treatment.
    public let searchEmphasis: ADFCustomBlockSearchEmphasis
}

/// Whole-block search state (custom blocks participate in find-in-page via
/// the atom model: matches emphasize the block as a unit).
public enum ADFCustomBlockSearchEmphasis: Equatable, Sendable {
    /// No active search, or no match in this block.
    case none
    /// This block matches the query.
    case matched
    /// This block holds the currently selected match. `dimmed` alternates
    /// during the arrival flash's discrete blink.
    case current(dimmed: Bool)
}

extension ADFCustomBlockRenderer {
    /// Unboxes the typed payload and erases the consumer view, inside a
    /// protocol extension where `Self` (and so `Value`/`Content`) is
    /// concrete. `nil` on a payload type mismatch — possible only for a
    /// hand-built block, since the claim loop stamps IDs. The erasure lives
    /// inside the `CustomBlockView` leaf — never at the lazy row's own
    /// position, so the row's outer type stays unary and memcmp-diffable.
    @MainActor
    func erasedContent(for block: ADFCustomBlock, context: ADFCustomBlockContext) -> AnyView? {
        guard let value = block.value.value(as: Value.self) else { return nil }
        return AnyView(content(for: value, context: context))
    }
}

/// Immutable lookup for the document's registered renderers. A reference
/// type created once per `ADFDocumentModel`, so re-evaluations of
/// `ADFDocumentView.body` re-inject a pointer-equal value and never
/// invalidate custom leaves.
final class ADFCustomRendererRegistry: Sendable {
    /// Registration order — the claim precedence during preparation
    /// (earlier renderers win ties).
    let preparers: [any ADFCustomBlockPreparer]
    private let byID: [String: any ADFCustomBlockRenderer]

    init(_ renderers: [any ADFCustomBlockRenderer]) {
        self.preparers = renderers
        var byID: [String: any ADFCustomBlockRenderer] = [:]
        for renderer in renderers {
            assert(
                byID[renderer.rendererID] == nil,
                "Duplicate rendererID \"\(renderer.rendererID)\": blocks claimed by one plugin would render with another's view."
            )
            if byID[renderer.rendererID] == nil {
                byID[renderer.rendererID] = renderer
            }
        }
        self.byID = byID
    }

    func renderer(for id: String) -> (any ADFCustomBlockRenderer)? {
        byID[id]
    }
}

private struct ADFCustomRenderersKey: EnvironmentKey {
    // Optional-nil default (the TableScrollSync pattern): the default must be
    // constructible nonisolated, and blocks rendered outside ADFDocumentView
    // (previews) fall back to the neutral chip.
    static let defaultValue: ADFCustomRendererRegistry? = nil
}

extension EnvironmentValues {
    /// Renderer registry injected by `ADFDocumentView` from its model.
    /// Overriding it below `ADFDocumentView` is unsupported — preparation
    /// and search index against the model's registry.
    var adfCustomRenderers: ADFCustomRendererRegistry? {
        get { self[ADFCustomRenderersKey.self] }
        set { self[ADFCustomRenderersKey.self] = newValue }
    }
}
