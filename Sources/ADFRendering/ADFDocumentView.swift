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

    /// The settle-window re-pins `reassertAnchor` schedules after a resize,
    /// held so a user scroll gesture or this view's teardown can cancel them
    /// — see `PendingRepins` and `ScrollInteractionGuard` below.
    ///
    /// `@State` only to get one stable instance per view identity (created
    /// once, released when this view is torn down), same reason as
    /// `tableScrollSync` above: it is never reassigned, only mutated through
    /// methods, so it invalidates nothing on the scroll path.
    @State private var pendingRepins = PendingRepins()

    /// Readable measure: the column of text is capped near UIKit's readable
    /// content width and centered, so full-screen iPad and landscape layouts
    /// don't run body text to unreadable line lengths. Scaled with Dynamic
    /// Type — larger text earns a proportionally wider column.
    @ScaledMetric(relativeTo: .body) private var readableWidth: CGFloat = 672

    /// Current content-column width, observed once at the document level and
    /// passed to every row so collapsed spacers can tell when their cached
    /// height was measured at a different width (rotation, Split View).
    @State private var containerWidth = CGFloat.zero

    /// Watched so a runtime type-size change (host override or the system
    /// setting) can re-assert the scroll anchor: it reflows every row's
    /// height at an unchanged column width on iPhone, so the width-change
    /// re-pin below never fires for it.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
                reassertAnchor(proxy)
            }
            // A Dynamic Type change is the width change's sibling: every row
            // reflows to a new height while the column width usually stays
            // the same — always on iPhone, and on iPad whenever the pane
            // (Split View, Slide Over, Stage Manager) is narrower than the
            // scaled readable cap, so this re-pin is the only corrective in
            // all of those layouts. Only a full-screen-class iPad column
            // moves `readableWidth` (@ScaledMetric) and fires the width
            // re-pin above as well; double-asserting the same anchor there
            // is harmless. Same one-shot, identity-based re-pin, same
            // reasons — see the comment above.
            .onChange(of: dynamicTypeSize) {
                reassertAnchor(proxy)
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
            // Cancels `reassertAnchor`'s outstanding settle-window re-pins
            // the instant the user starts a scroll gesture — see
            // `ScrollInteractionGuard`. Applied once to the whole document
            // `ScrollView`, never per row.
            .modifier(ScrollInteractionGuard(pendingRepins: pendingRepins))
            // Teardown: cancel whatever is still pending so a re-pin never
            // fires after this view is gone. `.id(document)` hosts recreate
            // the whole view per document, so this is also what keeps a
            // stale re-pin from ever reaching a different document's scroll
            // view (the minor cross-document hazard the delayed pins had).
            .onDisappear {
                pendingRepins.cancelAll()
            }
        }
        .environment(\.adfTheme, model.theme)
        .environment(\.adfCustomRenderers, model.customRenderers)
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

    /// One-shot, identity-based scroll re-pin: re-derives the offset for the
    /// remembered top row from current row heights. Snap, don't slide: the
    /// triggering change can carry an animation transaction, and a re-anchor
    /// should be instantaneous.
    private func reassertAnchor(_ proxy: ScrollViewProxy) {
        guard let anchor = model.anchors.topRow else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        func pin() { withTransaction(transaction) { proxy.scrollTo(anchor, anchor: .top) } }

        // Pin once immediately, then again across the post-resize settle window.
        //
        // `scrollTo(_, anchor: .top)` derives the anchor's offset by summing the
        // heights of every row before it. On a programmatic jump (`-scrollToFraction`,
        // a TOC tap) the reader never scrolled through the rows above the anchor, so
        // the lazy stack never materialized or measured them — `CollapsedRowHeight`
        // holds no sample, and SwiftUI can only *estimate* that (here ~2,500-row)
        // gap. The first pin therefore lands the anchor coarsely; over the next few
        // frames SwiftUI materializes the anchor and its neighbours and corrects
        // their heights, nudging the anchor off the top. A single pin never sees
        // those corrections and settles tens-to-hundreds of rows off — a backward
        // drift that is nondeterministic and independent of the row renderer.
        //
        // Re-pinning across the settle window follows each height correction with a
        // fresh snap; once the corrections stop, the anchor is exactly at the top.
        // (When the rows above were materialized by an organic scroll their heights
        // are exact, the first pin is already precise, and the extra pins are
        // idempotent no-ops.) This fires only on a width/type-size change — never on
        // the scroll-gesture path — reads no per-row geometry, and writes no
        // observable state, so it stays clear of the §8 hitch/livelock class.
        //
        // Each delayed pin is a cancellable `DispatchWorkItem`, not a bare
        // closure: a user who starts scrolling inside the settle window must
        // win, not be yanked back to the anchor captured above (undoing their
        // gesture is exactly the "scroll view fights the user" class §8b
        // exists to prevent) — and being yanked back would also leave
        // `model.anchors.topRow` (just updated by their gesture through the
        // tracking binding) diverged from the viewport the re-pin forced it
        // to, so the NEXT rotation would re-pin to a position the user
        // already scrolled away from. `ScrollInteractionGuard` cancels these
        // on the first sign of a scroll gesture; `onDisappear` cancels them
        // on teardown so none outlives this view.
        pin()
        let items = Self.rotationSettleRepinDelays.map { delay -> DispatchWorkItem in
            let item = DispatchWorkItem { pin() }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return item
        }
        pendingRepins.replace(items)
    }

    /// Wall-clock offsets (seconds) at which `reassertAnchor` re-snaps the anchor
    /// after a resize, spanning the post-rotation layout-settle window. Wall-clock
    /// rather than run-loop hops because the height corrections land a frame at a
    /// time; the series must outlast them.
    private static let rotationSettleRepinDelays: [TimeInterval] = [0.033, 0.1, 0.2, 0.35, 0.5]

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

/// Holds the settle-window re-pins `ADFDocumentView.reassertAnchor` schedules
/// after a resize, so a user scroll gesture or the document view's teardown
/// can cancel them before they fire.
///
/// A plain class, like `ScrollAnchorRegistry`: cancelling a work item is a
/// mutation on this reference, not a state write, so it invalidates no view
/// and is safe to call from the scroll-phase path.
@MainActor
final class PendingRepins {
    private var items: [DispatchWorkItem] = []

    /// Replaces the pending items, first cancelling whatever was still
    /// outstanding from the previous resize.
    func replace(_ items: [DispatchWorkItem]) {
        cancelAll()
        self.items = items
    }

    /// Cancels every outstanding item. Idempotent — safe to call from both
    /// the scroll-phase guard and teardown, and safe to call on an item that
    /// already fired (`DispatchWorkItem.cancel()` is a no-op there).
    func cancelAll() {
        for item in items { item.cancel() }
        items.removeAll()
    }
}

/// Cancels `reassertAnchor`'s outstanding settle-window re-pins the instant
/// the user starts a scroll gesture, so a delayed re-pin never fights a
/// gesture already in flight (see the review note on
/// `rotationSettleRepinDelays`).
///
/// Applied once to the whole document `ScrollView` — never per row. The
/// `#available` branch below is therefore exempt from the §8 "no
/// `buildLimitedAvailability` at a lazy container's per-item position" rule
/// (see `rows`): this erases exactly one view, not one per lazy row.
///
/// iOS 17 has no `onScrollPhaseChange`; there the pins simply stay
/// uncancellable by a scroll gesture, matching this fix's pre-existing
/// (pre-guard) behavior.
private struct ScrollInteractionGuard: ViewModifier {
    let pendingRepins: PendingRepins

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content.onScrollPhaseChange { _, newPhase, _ in
                // Same discrimination `TableSliceView.SynchronizedTableSlice`
                // uses for user-driven vs. programmatic motion: dragging or
                // the momentum that follows it is user-driven; `.animating`
                // (which our own `disablesAnimations` pins never even enter)
                // and `.idle` must not cancel anything.
                if newPhase == .interacting || newPhase == .decelerating {
                    pendingRepins.cancelAll()
                }
            }
        } else {
            content
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

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
        .onChange(of: dynamicTypeSize) { old, new in
            // The text size changed under this row. Its remembered heights
            // must move with the text — but the row must NOT re-materialize
            // to re-measure (mass re-materialization livelocks layout, see
            // `heights`), and emptying the memo would do exactly that via
            // the `heights.isEmpty` branch above. So the samples are
            // rescaled in place: an estimate, corrected on natural re-entry.
            //
            // Live rows rescale too: their samples for OTHER widths (from
            // past rotations) would otherwise stay at the old text size and
            // replay as "exact" on the next rotation. The current width's
            // sample is re-recorded exactly by the geometry callback as soon
            // as the live row reflows, overwriting its estimate.
            let ratio = new.approximateBodyPointSize / old.approximateBodyPointSize
            heights.rescale(by: block.kind.typeSizeRescaleFactor(bodyPointRatio: ratio))
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
