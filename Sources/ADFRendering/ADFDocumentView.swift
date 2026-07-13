import SwiftUI
import ADFModel
import ADFPreparation

/// Public entry point: a lazy, scrollable reader over a document model's
/// prepared blocks. Rows are POD views over pre-computed values, so `body`
/// never does heavy work during scroll.
public struct ADFDocumentView: View {
    private let model: ADFDocumentModel
    private let mediaProvider: any ADFMediaProvider
    private let interactionHandler: (@MainActor (ADFInteraction) -> Void)?
    private let taskStates: [String: Bool]
    private let mentionContent: (@MainActor (String) -> AnyView)?

    /// One registry per document (per view identity), so a table's shared
    /// horizontal offset never leaks into another document and is released
    /// when this view is torn down.
    @State private var tableScrollSync = TableScrollSync()

    /// Readable measure: the column of text is capped near UIKit's readable
    /// content width and centered, so full-screen iPad and landscape layouts
    /// don't run body text to unreadable line lengths. Scaled with Dynamic
    /// Type — larger text earns a proportionally wider column.
    @ScaledMetric(relativeTo: .body) private var readableWidth: CGFloat = 672

    /// Current content-column width, observed once at the document level and
    /// passed to every row so collapsed spacers can tell when their cached
    /// height was measured at a different width (rotation, Split View).
    @State private var containerWidth = CGFloat.zero

    /// The row at the top of the viewport, which `scrollPosition(id:)` keeps
    /// anchored there when the document reflows at a new width. Held in a plain
    /// reference type so SwiftUI's per-row writes to the binding invalidate
    /// nothing — see `ScrollAnchorRegistry`.
    @State private var anchors = ScrollAnchorRegistry()

    public init(model: ADFDocumentModel,
                mediaProvider: any ADFMediaProvider,
                interactionHandler: (@MainActor (ADFInteraction) -> Void)? = nil,
                taskStates: [String: Bool] = [:],
                mentionContent: (@MainActor (String) -> AnyView)? = nil) {
        self.model = model
        self.mediaProvider = mediaProvider
        self.interactionHandler = interactionHandler
        self.taskStates = taskStates
        self.mentionContent = mentionContent
    }

    /// TOC jumps use `ScrollViewReader.scrollTo` rather than writing the
    /// `scrollPosition(id:)` binding: `scrollTo` costs nothing until a jump is
    /// requested. The binding is still *read* — see `anchorBinding` — because
    /// it is what keeps the reader's place when the document reflows at a new
    /// width (rotation, Split View), which a retained content offset does not.
    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                rows
                    // Observed on the stack itself — the width rows are
                    // actually laid out at. Reading it outside the
                    // `readableWidth` cap would report the scroll view's full
                    // width, which keeps changing (rotation, iPad) long after
                    // the capped content column has stopped, and would rescale
                    // every collapsed spacer by a ratio the rows never saw.
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.width
                    } action: { width in
                        containerWidth = width
                    }
                    .padding(.horizontal, model.theme.spacing * 2)
                    .frame(maxWidth: readableWidth)
                    .frame(maxWidth: .infinity)
            }
            .scrollPosition(id: anchorBinding, anchor: .top)
            .background {
                // The scroll-target observation lives in a leaf view so a
                // `scrollTarget` write invalidates only this empty view.
                // Observing it here would re-evaluate the whole document
                // view per jump — and reconciling every row the lazy stack
                // keeps alive is O(rows materialized so far), which the §8
                // 5k-block hitch gate measures as progressive frame drops.
                ScrollTargetConsumer(model: model, proxy: proxy)
            }
        }
        .environment(\.adfTheme, model.theme)
        .environment(\.adfMediaProvider, mediaProvider)
        .environment(\.adfTableScrollSync, tableScrollSync)
        .environment(\.adfInteractionHandler, interactionHandler)
        .environment(\.adfTaskStates, taskStates)
        .environment(\.adfMentionContent, mentionContent)
        .overlay { statusOverlay }
    }

    /// Reads and writes the top-visible row ID straight through to the
    /// registry. `Binding` rather than `@State` on purpose: SwiftUI writes this
    /// once per row crossed for the whole of every scroll, and a `@State` write
    /// would re-evaluate this view — reconciling every row the lazy stack has
    /// materialized — each time. A write to a plain reference type invalidates
    /// nothing.
    private var anchorBinding: Binding<String?> {
        Binding(get: { anchors.topRow }, set: { anchors.topRow = $0 })
    }

    /// Sections are maintained incrementally by the model as chunks stream in,
    /// so this only iterates a stored value — a table's header slice pins
    /// (stays visible) while its row slices scroll beneath it.
    private var rows: some View {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
            ForEach(model.sections) { section in
                Section {
                    ForEach(section.blocks) { block in
                        DocumentRow(
                            block: block,
                            margin: model.theme.spacing * 2,
                            containerWidth: containerWidth
                        )
                    }
                } header: {
                    if let header = section.header {
                        BlockView(block: header)
                            // Opaque backdrop so pinned headers cover the rows
                            // scrolling underneath.
                            .background(Rectangle().fill(.background))
                    }
                }
            }
        }
        .scrollTargetLayout()
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch model.phase {
        case .parsing:
            ProgressView()
        case .preparing:
            if model.blocks.isEmpty {
                ProgressView()
            }
        case .failed(let message):
            ContentUnavailableView(
                "Couldn't Load Document",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        case .idle, .ready:
            EmptyView()
        }
    }
}

/// One lazy row: the block's view while the row is inside the render
/// region, and an exact-height spacer once it has scrolled well away.
///
/// Lazy stacks keep every row they ever materialized alive; on a 5,000-block
/// document the accumulated subtrees (text layers, gesture-bearing code /
/// table scroll views) make every subsequent layout and render commit more
/// expensive — measured on the §8 hitch gate as frame drops that grow with
/// scroll depth. Collapsing exited rows extends the §6.5 rule ("off-screen
/// rows drop their decoded image state") to all block kinds: the spacer
/// preserves the row's measured height exactly, so scroll geometry and
/// position are unaffected, and re-entering rows rebuild from their prepared
/// (immutable, pre-composed) `RenderBlock` just like first materialization.
private struct DocumentRow: View {
    let block: RenderBlock
    let margin: CGFloat
    /// The document's current content-column width (observed once by
    /// `ADFDocumentView`, constant during scroll).
    let containerWidth: CGFloat

    /// Rendered heights captured while the row is live, one per container
    /// width; empty until first materialization (a row must never collapse
    /// before it was measured).
    ///
    /// After a window resize (rotation, iPad Split View) a collapsed row must
    /// NOT re-materialize to re-measure: mass-materializing every stale row
    /// changes hundreds of row sizes at once, the lazy stack's scroll-offset
    /// compensation shifts the render region, appear/disappear states flip,
    /// and the feedback loop livelocks layout at 100% CPU (observed on
    /// entering Split View, `makeSizeChangeTranslation` hot in every sample).
    /// So the spacer's height stays a pure function of stored state, with no
    /// layout feedback: `CollapsedRowHeight` replays an exact height for a
    /// width this row has already been laid out at, and only estimates one it
    /// has not — per block kind, since an image, a code block and a paragraph
    /// each answer a width change differently. The exact height is
    /// re-measured when the row naturally re-enters the render region, like
    /// first materialization.
    @State private var heights = CollapsedRowHeight()
    @State private var isInRenderRegion = false

    private var spacerHeight: CGFloat? {
        heights.height(at: containerWidth, scaling: block.kind.heightScaling)
    }

    var body: some View {
        Group {
            if isInRenderRegion || heights.isEmpty {
                BlockView(block: block)
                    .padding(.vertical, block.kind.defaultVerticalPadding)
                    .blockBreakout(block.breakout, margin: margin)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        heights.record(height: height, at: containerWidth)
                    }
            } else {
                Color.clear
                    .frame(height: spacerHeight ?? 0)
            }
        }
        .onAppear { isInRenderRegion = true }
        .onDisappear { isInRenderRegion = false }
    }
}

/// Consumes `ADFDocumentModel.scrollTarget`: jumps the scroll view to the
/// requested block ID, then clears the request. A standalone leaf view so
/// the observation of `scrollTarget` (and the clearing write) never
/// invalidates the document view that hosts the lazy stack.
private struct ScrollTargetConsumer: View {
    let model: ADFDocumentModel
    let proxy: ScrollViewProxy

    var body: some View {
        Color.clear
            .onChange(of: model.scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(model.scrollTargetAnimation) {
                    proxy.scrollTo(target, anchor: .top)
                }
                model.scrollTarget = nil
            }
    }
}

extension View {
    /// Applies a root-level block's `breakout` mark: the block widens into
    /// the document's horizontal margin (`wide` reclaims half of it,
    /// `full-width` all of it), and a custom width caps the block at that
    /// many points, centered.
    @ViewBuilder
    func blockBreakout(_ breakout: BlockBreakout?, margin: CGFloat) -> some View {
        switch breakout?.mode {
        case nil:
            self
        case .wide:
            frame(maxWidth: breakout?.width.map { CGFloat($0) })
                .padding(.horizontal, -margin / 2)
        case .fullWidth:
            frame(maxWidth: breakout?.width.map { CGFloat($0) })
                .padding(.horizontal, -margin)
        }
    }
}
