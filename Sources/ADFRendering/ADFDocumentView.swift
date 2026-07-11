import SwiftUI
import ADFModel
import ADFPreparation

/// Public entry point: a lazy, scrollable reader over a document model's
/// prepared blocks. Rows are POD views over pre-computed values, so `body`
/// never does heavy work during scroll.
public struct ADFDocumentView: View {
    private let model: ADFDocumentModel
    private let mediaProvider: any ADFMediaProvider

    public init(model: ADFDocumentModel, mediaProvider: any ADFMediaProvider) {
        self.model = model
        self.mediaProvider = mediaProvider
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
                                DocumentRow(block: block, margin: model.theme.spacing * 2)
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

    /// Rendered height captured while the row is live; `nil` until first
    /// materialization (a row must never collapse before it was measured).
    @State private var measuredHeight: CGFloat?
    @State private var isInRenderRegion = false

    var body: some View {
        Group {
            if isInRenderRegion || measuredHeight == nil {
                BlockView(block: block)
                    .padding(.vertical, block.kind.defaultVerticalPadding)
                    .blockBreakout(block.breakout, margin: margin)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        measuredHeight = height
                    }
            } else {
                Color.clear
                    .frame(height: measuredHeight ?? 0)
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
