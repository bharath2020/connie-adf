import SwiftUI
import ADFModel
import ADFPreparation

/// Public entry point: a lazy, scrollable reader over a document model's
/// prepared blocks. Rows are POD views over pre-computed values, so `body`
/// never does heavy work during scroll.
public struct ADFDocumentView: View {
    private let model: ADFDocumentModel
    private let mediaProvider: any ADFMediaProvider

    /// ID-based scroll position over `scrollTargetLayout`. The iOS 17 /
    /// macOS 14 floor predates the `ScrollPosition` struct (iOS 18+), so TOC
    /// jumps use the ID-based `scrollPosition(id:anchor:)` binding instead.
    @State private var scrolledBlockID: String?

    public init(model: ADFDocumentModel, mediaProvider: any ADFMediaProvider) {
        self.model = model
        self.mediaProvider = mediaProvider
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                // Sections are maintained incrementally by the model as
                // chunks stream in, so body only iterates a stored value —
                // a table's header slice pins (stays visible) while its row
                // slices scroll beneath it.
                ForEach(model.sections) { section in
                    Section {
                        ForEach(section.blocks) { block in
                            BlockView(block: block)
                                .padding(.vertical, block.kind.defaultVerticalPadding)
                                .blockBreakout(block.breakout, margin: model.theme.spacing * 2)
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
            .scrollTargetLayout()
            .padding(.horizontal, model.theme.spacing * 2)
        }
        .scrollPosition(id: $scrolledBlockID, anchor: .top)
        .onChange(of: model.scrollTarget) { _, target in
            guard let target else { return }
            withAnimation(.snappy) {
                scrolledBlockID = target
            }
            model.scrollTarget = nil
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
