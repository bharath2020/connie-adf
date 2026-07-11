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
                ForEach(model.blocks) { block in
                    BlockView(block: block)
                        .padding(.vertical, block.kind.defaultVerticalPadding)
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
