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

    /// Current content-column width — the readable-capped column the text
    /// actually wraps in, not the full window — observed once at the document
    /// level and passed to every row so collapsed spacers can tell when their
    /// cached height was measured at a different width (rotation, Split View).
    /// Keyed on the wrap width so a rotation that only widens the window past
    /// the readable cap (no reflow) leaves it unchanged and holds position.
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

    /// TOC jumps use `ScrollViewReader.scrollTo` rather than the
    /// `scrollPosition(id:)` binding: the binding writes the top-visible ID
    /// back continuously while scrolling, re-evaluating this view once per
    /// row crossed — a per-frame cost that grows with the number of rows the
    /// lazy stack has materialized and keeps alive (measured on the §8
    /// 5k-block hitch gate as progressively increasing frame drops).
    /// `scrollTo` costs nothing until a jump is requested.
    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    // Sections are maintained incrementally by the model as
                    // chunks stream in, so body only iterates a stored value —
                    // a table's header slice pins (stays visible) while its row
                    // slices scroll beneath it.
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
                                    // Opaque backdrop so pinned headers cover the
                                    // rows scrolling underneath.
                                    .background(Rectangle().fill(.background))
                            }
                        }
                    }
                }
                .padding(.horizontal, model.theme.spacing * 2)
                .frame(maxWidth: readableWidth)
                // Observe the readable-capped column, not the full window:
                // text wraps inside this frame, so this is the width the row
                // cache is keyed on. Reading it after the outer
                // `.frame(maxWidth: .infinity)` would report the whole screen
                // instead — and on any window wider than the cap (iPad, large
                // iPhone landscape) the text column stays pinned at
                // `readableWidth` and never reflows on rotation, yet that
                // screen-width value still changes. Collapsed rows would then
                // rescale their spacers for a reflow that never happened,
                // shifting every off-screen row's reserved height and jumping
                // the reading position on orientation change.
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    containerWidth = width
                }
                .frame(maxWidth: .infinity)
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
        .overlay { statusOverlay }
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

    /// Rendered height captured while the row is live; `nil` until first
    /// materialization (a row must never collapse before it was measured).
    /// The height is exact only for the container width it was measured at.
    /// After a window resize (rotation, iPad Split View) a collapsed row
    /// must NOT re-materialize to re-measure: mass-materializing every
    /// stale row changes hundreds of row sizes at once, the lazy stack's
    /// scroll-offset compensation shifts the render region, appear/disappear
    /// states flip, and the feedback loop livelocks layout at 100% CPU
    /// (observed on entering Split View, `makeSizeChangeTranslation` hot in
    /// every sample). Instead the spacer scales its cached height by the
    /// width ratio — text reflow is roughly inverse in width — keeping
    /// spacer height a pure function of stored state with no layout
    /// feedback. The exact height is re-measured when the row naturally
    /// re-enters the render region, like first materialization.
    @State private var measured: MeasuredSize?
    @State private var isInRenderRegion = false

    private struct MeasuredSize: Equatable {
        var containerWidth: CGFloat
        var height: CGFloat
    }

    private var spacerHeight: CGFloat? {
        guard let measured else { return nil }
        guard measured.containerWidth > 0, containerWidth > 0,
              abs(measured.containerWidth - containerWidth) > 0.5 else {
            return measured.height
        }
        return measured.height * measured.containerWidth / containerWidth
    }

    var body: some View {
        Group {
            if isInRenderRegion || measured == nil {
                BlockView(block: block)
                    .padding(.vertical, block.kind.defaultVerticalPadding)
                    .blockBreakout(block.breakout, margin: margin)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        measured = MeasuredSize(containerWidth: containerWidth, height: height)
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
