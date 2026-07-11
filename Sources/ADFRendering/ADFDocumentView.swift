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
                // Blocks group into sections so a table's header slice pins
                // (stays visible) while its row slices scroll beneath it.
                ForEach(Self.sections(from: model.blocks)) { section in
                    Section {
                        ForEach(section.blocks) { block in
                            BlockView(block: block)
                                .padding(.vertical, block.kind.defaultVerticalPadding)
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

    /// Groups the flat block list into lazy-stack sections: a table header
    /// slice starts a section (as its pinned header) that contains the row
    /// slices of the same table; every other run of blocks is a headerless
    /// section. Section IDs are stable as chunks stream in, because blocks
    /// only ever append at the end.
    static func sections(from blocks: [RenderBlock]) -> [BlockSection] {
        var sections: [BlockSection] = []
        var plain: [RenderBlock] = []

        func flushPlain() {
            guard !plain.isEmpty else { return }
            sections.append(BlockSection(id: "plain-\(plain[0].id)", header: nil, blocks: plain))
            plain.removeAll()
        }

        var index = 0
        while index < blocks.count {
            let block = blocks[index]
            guard case .tableSlice(_, _, isHeaderSlice: true) = block.kind else {
                plain.append(block)
                index += 1
                continue
            }
            flushPlain()
            // Header slice IDs are "<tableID>#header"; its row slices are
            // "<tableID>#rows<n>" and follow contiguously.
            let tablePrefix = String(block.id.prefix(while: { $0 != "#" })) + "#"
            var rows: [RenderBlock] = []
            var next = index + 1
            while next < blocks.count {
                let candidate = blocks[next]
                guard case .tableSlice(_, _, isHeaderSlice: false) = candidate.kind,
                      candidate.id.hasPrefix(tablePrefix) else { break }
                rows.append(candidate)
                next += 1
            }
            sections.append(BlockSection(id: block.id, header: block, blocks: rows))
            index = next
        }
        flushPlain()
        return sections
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

/// One lazy-stack section: an optional pinned header (a table's header
/// slice) plus its content blocks.
struct BlockSection: Identifiable {
    let id: String
    let header: RenderBlock?
    let blocks: [RenderBlock]
}
