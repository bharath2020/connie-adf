import SwiftUI
import ADFPreparation

/// Leaf host for a plugin-claimed block: resolves the renderer from the
/// environment registry, draws the declared geometry, and wraps the consumer
/// view with the library's find-in-page emphasis.
///
/// The consumer view is type-erased (`AnyView`) HERE, inside one leaf of
/// `BlockView`'s structural switch. That containment is safe because the
/// lazy item's outer type stays `DocumentRow`'s — memcmp-diffable, skipped
/// entirely during scroll — and the erased type is the renderer's fixed
/// `Content`, resolved by `rendererID` from an immutable per-document
/// registry, so its identity cannot churn between evaluations. This view
/// must remain a case of `BlockView`'s switch and must never wrap the row or
/// a per-row modifier (the §8 buildLimitedAvailability lesson).
struct CustomBlockView: View {
    let block: ADFCustomBlock
    /// The owning `RenderBlock.id` — highlight owner and arrival-flash key.
    let ownerID: String

    @Environment(\.adfCustomRenderers) private var registry
    @Environment(\.adfDocumentSearch) private var search
    @Environment(\.adfTheme) private var theme
    /// Flash off-phase: while true the current match draws with the subtle
    /// color, so alternating it blinks the accent (§ arrival flash).
    @State private var flashDimmed = false

    var body: some View {
        let emphasis = searchEmphasis
        Group {
            if let content = resolvedContent(emphasis: emphasis) {
                content.modifier(CustomBlockSizingBox(sizing: block.sizing))
            } else {
                MissingRendererView(rendererID: block.rendererID)
            }
        }
        .overlay {
            // Default whole-block match emphasis (the atom model, sized for
            // a block): a border rather than a fill so the consumer content
            // stays legible under it.
            if let color = emphasisColor(emphasis) {
                RoundedRectangle(cornerRadius: theme.containerCornerRadius)
                    .strokeBorder(color, lineWidth: 3)
            }
        }
        .searchArrivalFlash(ownerID: ownerID, dimmed: $flashDimmed)
    }

    /// The consumer view, or `nil` when the renderer is unregistered
    /// (previews, misconfiguration) or the payload type doesn't match —
    /// either way the neutral chip renders instead (§7: nothing silently
    /// disappears).
    private func resolvedContent(emphasis: ADFCustomBlockSearchEmphasis) -> AnyView? {
        registry?.renderer(for: block.rendererID)?.erasedContent(
            for: block,
            context: ADFCustomBlockContext(
                blockID: ownerID,
                theme: theme,
                searchEmphasis: emphasis
            )
        )
    }

    /// The zero-work gate, in the same order every search-participating leaf
    /// uses: one observable Bool first; the per-owner store only while a
    /// session is active. Custom blocks are atom-model participants, so the
    /// fields that matter are `currentAtomIDs`/`atomIDs` — their span
    /// collections are always empty. Reading anything else here (especially
    /// the aggregate `highlights`) would re-subscribe every materialized
    /// custom block to document-wide scan churn.
    private var searchEmphasis: ADFCustomBlockSearchEmphasis {
        guard let search, search.isActive else { return .none }
        let highlights = search.ownerHighlights(for: ownerID)
        if highlights.currentAtomIDs.contains(ownerID) {
            return .current(dimmed: flashDimmed)
        }
        return highlights.atomIDs.contains(ownerID) ? .matched : .none
    }

    private func emphasisColor(_ emphasis: ADFCustomBlockSearchEmphasis) -> Color? {
        switch emphasis {
        case .none:
            nil
        case .matched, .current(dimmed: true):
            theme.searchHighlight
        case .current(dimmed: false):
            theme.searchCurrentHighlight
        }
    }
}

/// Draws the geometry the block DECLARED, so the sizing profile the spacer
/// estimator uses and the rendered box agree by construction (the way
/// `MediaBlockView` derives both from one `PreparedMedia`). `.aspectRatio`
/// gets its box and width cap here; the other profiles let the consumer view
/// answer the column proposal itself.
private struct CustomBlockSizingBox: ViewModifier {
    let sizing: ADFCustomBlockSizing

    func body(content: Content) -> some View {
        switch sizing {
        case .aspectRatio(let width, let height, let maxWidth):
            content
                .aspectRatio(CGFloat(width / height), contentMode: .fit)
                .frame(maxWidth: maxWidth.map { CGFloat($0) })
        case .scaledChrome, .reflowingText:
            content
        }
    }
}

/// Neutral fallback when a prepared block references a renderer the view
/// hierarchy doesn't know (previews, host misconfiguration) — §7: nothing
/// silently disappears.
private struct MissingRendererView: View {
    let rendererID: String

    @Environment(\.adfTheme) private var theme

    var body: some View {
        HStack(spacing: theme.spacing * 0.75) {
            Image(systemName: "puzzlepiece")
                .imageScale(.small)
                .accessibilityHidden(true)
            Text(rendererID)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(theme.spacing * 1.5)
        .background(
            RoundedRectangle(cornerRadius: theme.containerCornerRadius)
                .strokeBorder(
                    Color.gray.opacity(0.3),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        )
        .accessibilityLabel("Custom block: \(rendererID)")
    }
}
