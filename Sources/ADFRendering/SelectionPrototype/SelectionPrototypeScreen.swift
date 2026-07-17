// PROTOTYPE — THROWAWAY CODE. Not production. Delete or absorb after verdict.
//
// Public entry point for the cross-block selection prototype. Renders a
// fixture through the REAL preparation pipeline and the REAL block views,
// but in a deliberately simple non-lazy stack: the question here is whether
// a UITextInput container + UITextInteraction gives native selection over
// SwiftUI-rendered blocks at all (gesture arbitration, geometry fidelity,
// handles/menu/loupe) — production integration with the lazy/collapse
// machinery is assessed separately, not prototyped here.

#if os(iOS)
import SwiftUI
import ADFModel
import ADFPreparation

public struct ADFSelectionPrototypeScreen: View {
    private let fixtureData: Data
    private let mediaProvider: any ADFMediaProvider

    private enum Phase {
        case loading
        case failed(String)
        case ready(Loaded)
    }

    private struct Loaded {
        let blocks: [RenderBlock]
        let docText: PrototypeDocumentText
        let geometry: PrototypeGeometryService
    }

    @State private var phase: Phase = .loading
    @State private var selectedText: String?
    @State private var showDebugRects = false

    private let theme = ADFTheme.default

    public init(fixtureData: Data, mediaProvider: any ADFMediaProvider) {
        self.fixtureData = fixtureData
        self.mediaProvider = mediaProvider
    }

    public var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView()
            case .failed(let message):
                ContentUnavailableView(
                    "Prototype Failed to Load",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            case .ready(let loaded):
                document(loaded)
            }
        }
        .task { await load() }
        .navigationTitle("Selection PROTOTYPE")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { statusBar }
        .environment(\.adfTheme, theme)
        .environment(\.adfMediaProvider, mediaProvider)
    }

    private func document(_ loaded: Loaded) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(loaded.blocks) { block in
                    BlockView(block: block)
                        // Beacon sits directly behind the block content so
                        // its UIKit frame matches the text's layout box.
                        .background(PrototypeRowBeacon(
                            blockID: block.id,
                            registry: loaded.geometry.registry
                        ))
                        .padding(.vertical, block.kind.defaultVerticalPadding)
                }
            }
            .overlay {
                PrototypeSelectionOverlay(
                    docText: loaded.docText,
                    geometry: loaded.geometry,
                    showDebugRects: showDebugRects
                ) { text in
                    selectedText = text
                }
            }
            .padding(.horizontal, theme.spacing * 2)
        }
    }

    /// Surfaces the selection state after every change (prototype rule:
    /// always show the full relevant state).
    private var statusBar: some View {
        HStack(spacing: 12) {
            if let selectedText {
                Text("\(selectedText.count) chars: \(selectedText.prefix(60))")
                    .lineLimit(2)
                    .font(.caption.monospaced())
            } else {
                Text("No selection — long-press text to start")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Rects", isOn: $showDebugRects)
                .font(.caption)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func load() async {
        do {
            let document = try await ADFParser().parse(fixtureData)
            let preparer = DocumentPreparer(theme: theme)
            let blocks = preparer.prepare(document)
            let units = SearchIndexer(theme: theme).units(for: blocks)
            let docText = PrototypeDocumentText(units: units)
            let geometry = PrototypeGeometryService(text: docText, blocks: blocks)
            phase = .ready(Loaded(blocks: blocks, docText: docText, geometry: geometry))
        } catch {
            phase = .failed(String(describing: error))
        }
    }
}
#endif
