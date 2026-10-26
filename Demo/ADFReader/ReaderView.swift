import SwiftUI
import ADFModel
import ADFPreparation
import ADFRendering
import ADFYouTube

/// Reads one fixture: owns the `ADFDocumentModel`, renders it with
/// `ADFDocumentView`, and offers a table-of-contents toolbar menu that jumps
/// via the library's `scrollTarget` hook. Also implements the launch-argument
/// automation (READY line, `-scrollToFraction`, `-autoscroll`).
///
/// The text renderer (SwiftUI or TextKit 2) is a live switch: flipping it in
/// the toolbar menu re-renders the rows in place — same model, same scroll
/// position, no relaunch — so the two engines can be compared side by side
/// on the same screen of text.
struct ReaderView: View {
    let source: DocumentSource
    let options: LaunchOptions

    @State private var model = ADFDocumentModel(customRenderers: [YouTubeBlockRenderer()])
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
    @State private var buildInfoPresented = false
    /// Persisted renderer choice; `-textkit2` / `-rendererReset` seed it at
    /// launch (see `RendererPreference`). Off means the shipping SwiftUI path.
    @AppStorage(RendererPreference.key) private var textKit2Enabled = false
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

    private var activeRenderer: ADFTextRenderer {
        textKit2Enabled ? .textKit2 : .swiftUI
    }

    var body: some View {
        ADFDocumentView(model: model,
                        mediaProvider: mediaProvider,
                        interactionHandler: handle,
                        taskStates: taskStates,
                        mentionContent: { AnyView(ProfileCard(name: $0)) },
                        textRenderer: activeRenderer)
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
            .sheet(isPresented: $buildInfoPresented) {
                BuildInfoView(renderer: activeRenderer)
            }
            .task { load() }
            .onChange(of: model.blocks.count) { _, count in
                if firstChunkMilliseconds == nil, count > 0, let loadStart {
                    firstChunkMilliseconds = Self.milliseconds(since: loadStart)
                }
                if options.switchDuringLoad, LoadSwitchProbe.blocksAtSwitch == nil,
                   count > 0, model.phase != .ready {
                    LoadSwitchProbe.blocksAtSwitch = count
                    textKit2Enabled = true
                    print("SWITCH_DURING_LOAD blocks=\(count)")
                    fflush(stdout)
                }
            }
            .onChange(of: model.phase) { _, phase in
                guard phase == .ready else { return }
                documentDidBecomeReady()
            }
            .onReceive(NotificationCenter.default.publisher(for: RejumpHook.notification)) { _ in
                rejump()
            }
            .onDisappear { metrics.stop() }
    }

    // Four trailing items: the renderer menu (text label) plus three icons.
    // The Frame Rate HUD toggle lives inside the renderer menu — it is a
    // developer control like the switch itself — which keeps the bar at four
    // items so the text label fits beside an inline title on iPhone.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            rendererMenu
        }
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
                    // The -fontSizeStep bypass never writes: an automation
                    // run that taps the control must not overwrite the
                    // user's persisted per-document choice.
                    guard options.fontSizeStep == nil else { return }
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
    }

    /// The label is the active renderer's name as plain text, so a screen
    /// recording shows which engine is drawing without opening the menu.
    private var rendererMenu: some View {
        Menu {
            Section("Text Renderer") {
                ForEach(ADFTextRenderer.allCases) { renderer in
                    Button {
                        textKit2Enabled = renderer == .textKit2
                    } label: {
                        if renderer == activeRenderer {
                            Label(renderer.displayName, systemImage: "checkmark")
                        } else {
                            Text(renderer.displayName)
                        }
                    }
                    .accessibilityIdentifier(Self.choiceIdentifier(for: renderer))
                }
            }
            Section {
                Toggle(
                    "Frame Rate HUD",
                    systemImage: hudVisible ? "gauge.with.needle.fill" : "gauge.with.needle",
                    isOn: hudBinding
                )
                Button {
                    buildInfoPresented = true
                } label: {
                    Label("About This Build…", systemImage: "info.circle")
                }
                .accessibilityIdentifier("renderer-about")
            }
        } label: {
            Text(activeRenderer.displayName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
                .accessibilityIdentifier("renderer-active")
        }
        .accessibilityIdentifier("renderer-menu")
        .accessibilityHint("Chooses the text renderer")
    }

    private static func choiceIdentifier(for renderer: ADFTextRenderer) -> String {
        switch renderer {
        case .swiftUI: return "renderer-swiftui"
        case .textKit2: return "renderer-textkit2"
        }
    }

    private var hudBinding: Binding<Bool> {
        Binding(
            get: { hudVisible },
            set: { on in
                if on {
                    hudVisible = true
                    metrics.start()
                } else {
                    metrics.stop()
                    hudVisible = false
                }
            }
        )
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
        if LoadSwitchProbe.blocksAtSwitch != nil {
            LoadSwitchProbe.blocksAtReady = model.blocks.count
        }
        let totalMilliseconds = loadStart.map(Self.milliseconds(since:)) ?? 0
        let firstChunk = firstChunkMilliseconds ?? totalMilliseconds
        print(
            "READY fixture=\(source.title) blocks=\(model.blocks.count) "
                + "firstChunkMs=\(Int(firstChunk.rounded()))"
        )
        fflush(stdout)
        if options.rendererStats {
            RendererStats.print(blocks: model.blocks)
        }
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
                    await AutoScroller.run(
                        model: model,
                        metrics: metrics,
                        fixtureName: source.title,
                        rendererStats: options.rendererStats
                    )
                } else {
                    try? await Task.sleep(for: .seconds(1))
                    exit(0)
                }
            }
        }
    }

    /// The block `-scrollToFraction <fraction>` lands on.
    private func fractionTarget(_ fraction: Double) -> String? {
        let blocks = model.blocks
        guard !blocks.isEmpty else { return nil }
        let clamped = min(max(fraction, 0), 1)
        return blocks[min(blocks.count - 1, Int(clamped * Double(blocks.count)))].id
    }

    /// `RejumpHook`: lands on the `-scrollToFraction` block again, without
    /// animation — the lifecycle gate's deterministic "scroll back".
    private func rejump() {
        guard let fraction = options.scrollToFraction, let target = fractionTarget(fraction) else { return }
        // The reader scrolls on a *change* of `scrollTarget`. The library
        // clears it after every jump, so it is normally nil already; clearing
        // it here keeps the re-jump independent of that detail.
        model.scrollTarget = nil
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            print("REJUMP fraction=\(fraction)")
            fflush(stdout)
            await ScrollAutomation.jumpWithoutAnimation(model: model, to: target)
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
        // The animated jump lands imprecisely in the lazy stack: rows that
        // materialize mid-animation replace their estimated heights, so the
        // final offset varied by up to 26 px between launches of one build
        // (stress-5k at 0.5, step 3). Re-jumping without animation once it
        // has ended lands on the target row exactly, so screenshots compare.
        try? await Task.sleep(for: .milliseconds(1200))
        await ScrollAutomation.jumpWithoutAnimation(model: model, to: blocks[index].id)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: ContinuousClock.now)
        let (seconds, attoseconds) = elapsed.components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }
}
