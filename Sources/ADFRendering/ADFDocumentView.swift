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
            // The *sole* re-anchor authority: re-assert the reader's row by
            // identity whenever the content column changes width (rotation, iPad
            // Split View drag). `scrollPosition(id:)` above is tracking-only (its
            // getter is `nil`, see `anchorBinding`), so nothing else re-anchors.
            //
            // Without this, a `ScrollView` keeps the raw content *offset* across a
            // resize. At the new width the rows above have reflowed (and far-off
            // collapsed rows report estimated heights), so the same offset lands
            // on different content — and because the estimates don't round-trip
            // portrait↔landscape, the error compounds every cycle. That is the
            // progressive drift this fix removes.
            //
            // `scrollTo` re-derives the offset from the identity — summing the
            // current heights of the rows before the anchor — so it restores the
            // reader's row regardless of how those heights changed (reflow, or an
            // Expand opened above the viewport). It fires only on a width change,
            // which a plain scroll gesture never causes (the column width is
            // constant while scrolling); rotating mid-fling is the one exception,
            // and re-anchoring by identity is the intended behaviour there too.
            // So it stays off the §8 hitch path and touches no per-row geometry.
            //
            // Known residual: `scrollTo(_, anchor: .top)` aligns the row's *top*
            // edge, so the sub-row offset the reader was at is lost — a bounded,
            // non-accumulating ~one-row jitter across rotations. Fixing it needs a
            // one-shot capture/restore of the sub-row offset (deferred).
            //
            // `anchors.topRow` must be kept truthful by every code path that
            // moves the scroll view programmatically — see `ScrollTargetConsumer`
            // — otherwise this re-asserts a stale row on the next resize.
            .onChange(of: containerWidth) {
                guard let anchor = model.anchors.topRow else { return }
                // Snap, don't slide: the width change can carry the rotation's
                // animation transaction, and a re-anchor should be instantaneous.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(anchor, anchor: .top)
                }
            }
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
        .environment(\.adfDocumentSearch, model.search)
        .overlay { statusOverlay }
    }

    /// Backs `scrollPosition(id:)` as a **tracker only**: the setter records the
    /// top-visible row into the registry (once per row crossed, for the whole of
    /// every scroll), and the getter always returns `nil`.
    ///
    /// The `nil` getter is deliberate. `scrollPosition(id:)` otherwise remembers
    /// the last row it was told to hold and silently re-applies it whenever
    /// content resizes *under* the reader — an Expand opening, an image
    /// finishing — yanking them back to where that row now sits. (Reproduced on
    /// device: scroll to §30, rotate, scroll down to an Expand, tap it → snapped
    /// back to §30. It re-applies a *remembered* row, so forcing a re-read of the
    /// registry does not help — only withholding the target does.) With no
    /// target, `scrollPosition` can only track. Re-anchoring across a resize is
    /// done solely by the width-change re-pin above, which reads `anchors.topRow`
    /// and drives `scrollTo` — a one-shot, not a standing target.
    ///
    /// `Binding` rather than `@State` so the per-row setter writes into a plain
    /// reference type and invalidates no views (a `@State` write would
    /// re-evaluate this view — reconciling every materialized row — each time).
    private var anchorBinding: Binding<String?> {
        Binding(get: { nil }, set: { model.anchors.topRow = $0 })
    }

    /// Sections are maintained incrementally by the model as chunks stream in,
    /// so this only iterates a stored value — a table's header slice pins
    /// (stays visible) while its row slices scroll beneath it.
    ///
    /// THE ONE PLACE `#available` MAY GUARD THE VISIBILITY FEED. An
    /// `if #available` in any result builder compiles to
    /// `buildLimitedAvailability`, which type-erases the taken branch to
    /// `AnyView`. Erasing PER ROW — at the call site or even inside a
    /// per-row `ViewModifier`'s body — destroys the lazy stack's unary-item
    /// caching: it re-walks and re-measures the materialized rows on every
    /// frame of a scroll, a cost that grows with scroll depth (§8 stress-5k
    /// gate: 1.8 → 112–126 ms/s of hitching, in BOTH branches, with the
    /// callbacks contributing nothing). Branching HERE erases exactly one
    /// view — the whole stack — and each row keeps one stable, conditional-
    /// free type; the feed itself is free (0.65 ms/s live on all 5,000 rows).
    @ViewBuilder
    private var rows: some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            stack(reporter: { ScrollVisibilityReporter(id: $0, registry: $1) })
        } else {
            // Pre-18/15: no visibility feed exists, `VisibleRowRegistry`
            // stays empty, and search navigation always scrolls (graceful
            // degradation).
            stack(reporter: { _, _ in EmptyModifier() })
        }
    }

    private func stack<Reporter: ViewModifier>(
        reporter: @escaping (String, VisibleRowRegistry) -> Reporter
    ) -> some View {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
            ForEach(model.sections) { section in
                Section {
                    ForEach(section.blocks) { item in
                        DocumentRow(
                            item: item,
                            margin: model.theme.spacing * 2,
                            containerWidth: containerWidth,
                            visibility: model.search.visibleRows
                        )
                        .modifier(reporter(item.id, model.search.visibleRows))
                    }
                } header: {
                    if let item = section.header {
                        DocumentHeader(item: item)
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
    let item: DocumentBlockStore
    let margin: CGFloat
    /// The document's current content-column width (observed once by
    /// `ADFDocumentView`, constant during scroll).
    let containerWidth: CGFloat
    let visibility: VisibleRowRegistry

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

    private var block: RenderBlock { item.block }

    private var spacerHeight: CGFloat? {
        heights.height(at: containerWidth, scaling: block.kind.heightScaling)
    }

    var body: some View {
        Group {
            if isInRenderRegion || heights.isEmpty {
                BlockView(block: block)
                    .padding(.vertical, block.kind.defaultVerticalPadding)
                    .blockBreakout(block.breakout, margin: margin)
                    // Full width so the size measured below reports the
                    // column width even for rows whose content sits narrower
                    // (the stack proposes the column width to every row).
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Width and height must come from the same geometry read.
                    // Keying the record by the `containerWidth` property
                    // instead would file it under a stale width: the stack's
                    // width observation commits its `@State` write one update
                    // pass after layout, so during a rotation a live row
                    // would record its new-width height under the old width —
                    // overwriting the exact sample the memo exists to replay —
                    // and at first materialization the property is still zero,
                    // so the record would be dropped and the row could never
                    // collapse.
                    .onGeometryChange(for: CGSize.self) { proxy in
                        proxy.size
                    } action: { size in
                        heights.record(height: size.height, at: size.width)
                    }
            } else {
                Color.clear
                    .frame(height: spacerHeight ?? 0)
            }
        }
        .onChange(of: item.revision) { _, _ in
            // Prepared content changed under a stable logical row identity;
            // a collapsed row must discard its old spacer measurement. A
            // live row stays materialized and its geometry callback replaces
            // the sample if the rendered height actually changes.
            if !isInRenderRegion {
                heights = CollapsedRowHeight()
            }
        }
        .onAppear { isInRenderRegion = true }
        .onDisappear {
            isInRenderRegion = false
            // Render-region exit implies viewport exit; also covers removal
            // paths where the visibility callback never fires a final false.
            visibility.setVisible(item.id, false)
        }
        // The `ScrollVisibilityReporter` feed is applied by `stack(reporter:)`
        // around this row — see `rows` for why it must not attach in here.
    }
}

private struct DocumentHeader: View {
    let item: DocumentBlockStore

    var body: some View {
        BlockView(block: item.block)
            // Opaque backdrop so pinned headers cover the rows underneath.
            .background(Rectangle().fill(.background))
    }
}

/// Consumes `ADFDocumentModel.scrollTarget`: jumps the scroll view to the
/// requested logical row ID with the model's placement, then clears both. A
/// standalone leaf view so the observation (and the clearing write) never
/// invalidates the document view that hosts the lazy stack. The viewport
/// height is measured HERE — on the scroll view's frame, never inside lazy
/// rows — to turn point margins into `UnitPoint` anchors.
private struct ScrollTargetConsumer: View {
    let model: ADFDocumentModel
    let proxy: ScrollViewProxy

    @State private var viewportHeight: CGFloat = 0

    var body: some View {
        Color.clear
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                viewportHeight = height
            }
            .onChange(of: model.scrollTarget) { _, target in
                guard let target else { return }
                let anchor = model.scrollTargetPlacement.anchor(viewportHeight: viewportHeight)
                withAnimation(model.scrollTargetAnimation) {
                    proxy.scrollTo(target, anchor: anchor)
                }
                // Keep the anchor truthful. `scrollPosition(id:)` writes the
                // binding only during a scroll *gesture*, never for a
                // programmatic `scrollTo`, so without this the registry keeps
                // the pre-jump top row. The width-change re-pin above then
                // re-asserts that stale row on the next rotation and teleports
                // the reader back to where they were before the jump. The jump
                // anchors `target` at `.top`, so `target` is the new top row —
                // except when the target sits within one viewport of the
                // document end and `.top` bottom-clamps; then `target` lands
                // mid-viewport and this records it a little high. That is a
                // bounded, one-time reposition on the next resize (the same
                // whole-row `.top` limitation as the sub-row residual, fixable
                // only with a one-shot post-jump offset read — see the doc), and
                // still far better than re-asserting the pre-jump row. Search
                // navigation's `nearBottom` placement lands the target low in
                // the viewport — the same bounded, one-time class.
                // (A write to the reference type invalidates nothing — §8b.)
                model.anchors.topRow = target
                model.scrollTarget = nil
                model.scrollTargetPlacement = .top
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

/// Reports a row's genuine viewport visibility (not render-region
/// membership) into the `VisibleRowRegistry`. The 0.95 threshold ≈ "fully
/// visible": partially clipped matches still get a scroll that brings them
/// fully inside the margin.
///
/// `@available`-constrained ON THE TYPE, with a body containing NO
/// conditional, deliberately: this modifier sits on every lazy row, and any
/// `if #available` in its body (or at its call site) erases the row's
/// subgraph to `AnyView` via `buildLimitedAvailability` — the §8-measured
/// poison documented on `ADFDocumentView.rows`, which is the single place
/// allowed to make the availability decision.
@available(iOS 18.0, macOS 15.0, *)
private struct ScrollVisibilityReporter: ViewModifier {
    let id: String
    let registry: VisibleRowRegistry

    func body(content: Content) -> some View {
        content.onScrollVisibilityChange(threshold: 0.95) { visible in
            registry.setVisible(id, visible)
        }
    }
}
