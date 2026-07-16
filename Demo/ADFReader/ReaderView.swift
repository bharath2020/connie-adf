import SwiftUI
import ADFModel
import ADFPreparation
import ADFRendering

/// Reads one fixture: owns the `ADFDocumentModel`, renders it with
/// `ADFDocumentView`, and offers a table-of-contents toolbar menu that jumps
/// via the library's `scrollTarget` hook. Also implements the launch-argument
/// automation (READY line, `-scrollToFraction`, `-autoscroll`).
struct ReaderView: View {
    let source: DocumentSource
    let options: LaunchOptions

    @State private var model = ADFDocumentModel()
    @State private var metrics = FrameMetrics()
    @State private var hudVisible: Bool
    @State private var loadStart: ContinuousClock.Instant?
    @State private var firstChunkMilliseconds: Double?
    @State private var loadFailure: String?
    @State private var taskStates: [String: Bool] = [:]
    @State private var searchPresented = false
    @State private var automationStarted = false
    @State private var fontSizeStep = 0
    @State private var textSizePresented = false
    /// The un-overridden size — the override is applied deeper, on
    /// `ADFDocumentView` only, so this reads the system/app baseline.
    @Environment(\.dynamicTypeSize) private var systemTypeSize

    private let mediaProvider = PlaceholderMediaProvider()
    private let taskStore = TaskStateStore()
    private let fontSizeStore = FontSizeStore()

    init(source: DocumentSource, options: LaunchOptions) {
        self.source = source
        self.options = options
        // The HUD stays hidden during `-autoscroll` measurement runs: its
        // material-blur backdrop re-renders over the scrolling content and
        // would perturb the very frame pacing being measured. `FrameMetrics`
        // is display-link driven and needs no visible HUD.
        _hudVisible = State(initialValue: false)
    }

    var body: some View {
        ADFDocumentView(model: model,
                        mediaProvider: mediaProvider,
                        interactionHandler: handle,
                        taskStates: taskStates,
                        mentionContent: { AnyView(ProfileCard(name: $0)) })
            .dynamicTypeSize(systemTypeSize.shifted(by: fontSizeStep))
            .navigationTitle(source.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if searchPresented {
                    SearchBar(search: model.search, isPresented: $searchPresented)
                }
            }
            .overlay(alignment: .topTrailing) {
                if hudVisible {
                    FrameRateHUD(metrics: metrics)
                        .padding(8)
                }
            }
            .overlay {
                if let loadFailure {
                    ContentUnavailableView(
                        "Couldn't Read Fixture",
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadFailure)
                    )
                }
            }
            .task { load() }
            .onChange(of: model.blocks.count) { _, count in
                if firstChunkMilliseconds == nil, count > 0, let loadStart {
                    firstChunkMilliseconds = Self.milliseconds(since: loadStart)
                }
            }
            .onChange(of: model.phase) { _, phase in
                guard phase == .ready else { return }
                documentDidBecomeReady()
            }
            .onDisappear { metrics.stop() }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                withAnimation(.snappy) {
                    searchPresented.toggle()
                    if !searchPresented { model.search.clear() }
                }
            } label: {
                Label("Find in Page", systemImage: "magnifyingglass")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                textSizePresented.toggle()
            } label: {
                Label("Text Size", systemImage: "textformat.size")
            }
            .popover(isPresented: $textSizePresented) {
                TextSizeControl(
                    step: $fontSizeStep,
                    systemTypeSize: systemTypeSize
                ) { newStep in
                    fontSizeStore.setStep(newStep, docKey: source.storageKey)
                }
                .presentationCompactAdaptation(.popover)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                ForEach(model.headings, id: \.id) { heading in
                    Button {
                        model.scrollTarget = heading.id
                    } label: {
                        Text(String(repeating: "\u{2003}", count: max(0, heading.level - 1))
                            + heading.title)
                    }
                }
            } label: {
                Label("Table of Contents", systemImage: "list.bullet")
            }
            .disabled(model.headings.isEmpty)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                if hudVisible {
                    metrics.stop()
                    hudVisible = false
                } else {
                    hudVisible = true
                    metrics.start()
                }
            } label: {
                Label(
                    "Frame Rate HUD",
                    systemImage: hudVisible ? "gauge.with.needle.fill" : "gauge.with.needle"
                )
            }
        }
    }

    private func handle(_ interaction: ADFInteraction) {
        switch interaction {
        case .taskToggled(let id, let isDone):
            taskStore.setState(isDone, taskId: id, docKey: source.storageKey)
            taskStates[id] = isDone
        }
    }

    private func load() {
        guard model.phase == .idle else { return }
        taskStates = taskStore.states(for: source.storageKey)
        // A launch-argument step bypasses (and never writes) the persisted
        // value, so automation runs don't disturb the user's choice.
        fontSizeStep = options.fontSizeStep ?? fontSizeStore.step(for: source.storageKey)
        if hudVisible {
            metrics.start()
        }
        Task {
            do {
                let data = try await source.loadData()
                loadStart = ContinuousClock.now
                model.load(data: data)
            } catch {
                loadFailure = String(describing: error)
            }
        }
    }

    private func documentDidBecomeReady() {
        guard !automationStarted else { return }
        automationStarted = true
        let totalMilliseconds = loadStart.map(Self.milliseconds(since:)) ?? 0
        let firstChunk = firstChunkMilliseconds ?? totalMilliseconds
        print(
            "READY fixture=\(source.title) blocks=\(model.blocks.count) "
                + "firstChunkMs=\(Int(firstChunk.rounded()))"
        )
        fflush(stdout)
        if let fraction = options.scrollToFraction {
            Task { await scrollToFraction(fraction) }
        }
        if options.searchQuery != nil || options.autoscroll {
            Task {
                if let query = options.searchQuery {
                    await SearchAutomation.run(
                        model: model,
                        query: query,
                        updateCount: options.searchUpdates,
                        fixtureName: source.title
                    )
                }
                if options.autoscroll {
                    await AutoScroller.run(model: model, metrics: metrics, fixtureName: source.title)
                } else {
                    try? await Task.sleep(for: .seconds(1))
                    exit(0)
                }
            }
        }
    }

    private func scrollToFraction(_ fraction: Double) async {
        // Give the first layout pass a beat so the jump lands reliably.
        try? await Task.sleep(for: .milliseconds(300))
        let blocks = model.blocks
        guard !blocks.isEmpty else { return }
        let clamped = min(max(fraction, 0), 1)
        let index = min(blocks.count - 1, Int(clamped * Double(blocks.count)))
        withAnimation(.snappy) {
            model.scrollTarget = blocks[index].id
        }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: ContinuousClock.now)
        let (seconds, attoseconds) = elapsed.components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }
}
