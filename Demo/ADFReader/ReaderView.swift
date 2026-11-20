import SwiftUI
import ADFModel
import ADFPreparation
@_spi(ADFDiagnostics) import ADFRendering
import ADFYouTube

/// Reads one fixture: owns the `ADFDocumentModel`, renders it with
/// `ADFDocumentView`, and offers a table-of-contents toolbar menu that jumps
/// via the library's `scrollTarget` hook. Also implements the launch-argument
/// automation (READY line, `-scrollToFraction` and its `SCROLL_LANDED` line,
/// `-autoscroll`).
///
/// The text renderer (SwiftUI or TextKit 2) is a live switch: flipping it in
/// the toolbar menu re-renders the rows in place — same model, same scroll
/// position, no relaunch — so the two engines can be compared side by side
/// on the same screen of text. The same menu picks when smart links are
/// looked up (`ADFSmartLinkResolution`), also live: the document's
/// coordinator takes the new mode with no row invalidated.
///
/// The menu's "Identify Renderer" switch makes the renderer identify itself
/// (`ADFDocumentView(identifiesRenderer:)`): every text block shows the
/// engine that drew it, so SwiftUI fallbacks under TextKit 2 show, and the
/// toolbar badge shows the renderer's own report of the text on screen
/// (`RendererBadge`), never the menu's setting.
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
    /// Persisted smart-link resolution mode; `-smartLinkResolution` /
    /// `-rendererReset` seed it at launch (see
    /// `SmartLinkResolutionPreference`).
    @AppStorage(SmartLinkResolutionPreference.key)
    private var smartLinkResolution: ADFSmartLinkResolution = .whileScrolling
    /// Persisted "Identify Renderer" switch; `-identifyRenderer` /
    /// `-rendererReset` seed it at launch (see `RendererIdentityPreference`).
    @AppStorage(RendererIdentityPreference.key) private var identifiesRenderer = false
    /// Whether the last TextKit 2 pick was a memory-control pick
    /// (`-rebuildControlPicks`, `RebuildControl`).
    @State private var rebuildControl = false
    /// The un-overridden size — the override is applied deeper, on
    /// `ADFDocumentView` only, so this reads the system/app baseline.
    @Environment(\.dynamicTypeSize) private var systemTypeSize

    /// Shared by every reader this launch (see `DemoMedia.shared`):
    /// `CacheFirstMediaProvider` over `MockMediaFetch`, the demo's stand-in
    /// for an Atlassian media download; `nil` under `-media off`, so media
    /// shows its placeholder box and nothing loads. A real app passes its
    /// own fetch closure to `CacheFirstMediaProvider`.
    private let mediaProvider: (any ADFMediaProvider)?
    /// Shared by every reader this launch, remote pages included; `nil`
    /// under `-smartLinks off` (see `MockSmartLinkResolver.shared`).
    /// ADFReader is a sample app, so its titles are mock data on purpose:
    /// `ADFDocumentView` does not know how titles are loaded, and a real app
    /// installs its own resolver.
    private let smartLinkResolver = MockSmartLinkResolver.shared
    /// Custom emoji images (see `ADFEmojiResolver`) and how About This
    /// Build names their source: the session's shared mock, the Atlassian
    /// fetch or none (short names), by `EmojiResolvers`' rule. A Confluence
    /// page under no `-emoji` flag may upgrade it once, in `load()`, before
    /// its data loads.
    @State private var emoji: EmojiResolvers.Choice
    /// For the Atlassian emoji fetch's credential.
    @Environment(AccountStore.self) private var accounts
    private let taskStore = TaskStateStore()
    private let fontSizeStore = FontSizeStore()

    init(source: DocumentSource, options: LaunchOptions) {
        self.source = source
        self.options = options
        _emoji = State(initialValue: EmojiResolvers.initialChoice(for: source))
        mediaProvider = DemoMedia.shared.provider
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
                        textRenderer: activeRenderer,
                        smartLinkResolver: smartLinkResolver,
                        smartLinkResolution: smartLinkResolution,
                        emojiResolver: emoji.resolver,
                        identifiesRenderer: identifiesRenderer)
            .modifier(InteractionProbe.Capture(enabled: InteractionProbe.enabled))
            .adfRebuildControl(rebuildControl)
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
            .overlay(alignment: .bottomTrailing) {
                if options.smartLinkProbe {
                    SmartLinkProbe(model: model)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if options.mediaProbe {
                    MediaProbe(model: model)
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
                BuildInfoView(renderer: activeRenderer, model: model, smartLinkResolution: smartLinkResolution,
                              emojiSource: emoji.summary)
            }
            .task { load() }
            .onChange(of: model.blocks.count) { _, count in
                if firstChunkMilliseconds == nil, count > 0, let loadStart {
                    firstChunkMilliseconds = Self.milliseconds(since: loadStart)
                }
                if options.switchDuringLoad, LoadSwitchProbe.blocksAtSwitch == nil,
                   count > 0, model.phase != .ready {
                    LoadSwitchProbe.blocksAtSwitch = count
                    RendererPreference.markSetByAutomation()
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
            // Posted only under -captureGeometryHook: one read of the key
            // window per post, here on the host (never in a lazy row).
            .onReceive(NotificationCenter.default.publisher(for: CaptureGeometryHook.notification)) { _ in
                RendererStats.printCaptureGeometry(model: model)
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

    /// The label is `RendererBadge`: with "Identify Renderer" on, the
    /// renderer's own report of the text on screen, on the reporting
    /// engine's colour, so a screen recording shows which engine is drawing
    /// without opening the menu; off, the setting's name as plain text.
    private var rendererMenu: some View {
        Menu {
            Section("Text Renderer") {
                ForEach(ADFTextRenderer.allCases) { renderer in
                    Button {
                        if renderer == .textKit2 { rebuildControl = RebuildControl.takePick() }
                        RendererPreference.userChose()
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
                // The legend is the toggle's subtitle.
                Toggle(isOn: identifiesRendererBinding) {
                    Text("Identify Renderer")
                    Text(Self.identifyLegend)
                }
                .accessibilityIdentifier("renderer-identify")
            }
            // Each option is labelled with the API's own name
            // (`ADFSmartLinkResolution.displayName`).
            Section("Smart Link Resolution") {
                ForEach(ADFSmartLinkResolution.allCases) { mode in
                    Button {
                        SmartLinkResolutionPreference.userChose()
                        smartLinkResolution = mode
                    } label: {
                        if mode == smartLinkResolution {
                            Label(mode.displayName, systemImage: "checkmark")
                        } else {
                            Text(mode.displayName)
                        }
                    }
                    .accessibilityIdentifier("smartlink-resolution-\(mode.rawValue)")
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
            RendererBadge(report: model.rendererReport, setting: activeRenderer)
        }
        .accessibilityIdentifier("renderer-menu")
        .accessibilityHint("Chooses the text renderer")
    }

    /// "Each text block shows the engine that drew it: orange SwiftUI ·
    /// green TextKit 2 · blue TextKit 1 (a TextKit 2 row with links)".
    private static let identifyLegend = "Each text block shows the engine that drew it: "
        + ADFTextEngine.allCases.map { "\(RendererBadge.colorName($0)) \($0.displayName)" }.joined(separator: " · ")
        + " (a TextKit 2 row with links)"

    private var identifiesRendererBinding: Binding<Bool> {
        Binding(
            get: { identifiesRenderer },
            set: { on in
                RendererIdentityPreference.userChose()
                identifiesRenderer = on
            }
        )
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
            InteractionProbe.recordTask(id: id, isDone: isDone)
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
        if EmojiResolvers.usesAtlassianSetting(source),
           let choice = EmojiResolvers.confluenceChoice(accounts: accounts) {
            // Before the data loads, so the first prepared rows already
            // draw boxes instead of short names (no rebuild).
            emoji = choice
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
        // The proof of what this position shows (`Scripts/visual_diff.py`):
        // the stats printed at READY predate the jump, so once the rows the
        // jump brought in have laid out and drawn, name the block the jump
        // went to and print the counters again, with the code rows, the
        // container rows and the caption rows by owner. The five lines are
        // printed together, in this order.
        try? await Task.sleep(for: Self.landedSettle)
        print(
            "SCROLL_LANDED fixture=\(source.title) fraction=\(fraction) index=\(index) "
                + "block=\(blocks[index].id) blocks=\(blocks.count)"
        )
        fflush(stdout)
        if options.rendererStats {
            RendererStats.print(blocks: model.blocks)
            RendererStats.printCodeRows()
            RendererStats.printContainerRows()
            RendererStats.printCaptionRows()
        }
    }

    /// How long after the exact re-jump `SCROLL_LANDED` is printed: time for
    /// the rows at the new position to materialize, lay out and draw, so
    /// the counters printed with it describe the screen a capture takes.
    /// A capture must wait for the line (about 2.6 s after READY).
    private static let landedSettle: Duration = .milliseconds(1_000)

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: ContinuousClock.now)
        let (seconds, attoseconds) = elapsed.components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }
}

/// The renderer menu's label. With "Identify Renderer" on it reads only the
/// renderer's own report (`ADFDocumentModel.rendererReport`), never the
/// menu's setting: the engine that drew the text on screen, white on that
/// engine's colour ("TextKit 2" while any TextKit row is on screen, else
/// "SwiftUI"), and beside "TextKit 2" an orange count of the SwiftUI-drawn
/// blocks on screen. Off, or before the first report, there is no report:
/// the label is the setting's name as plain text, as it always was.
///
/// `renderer-active`'s label is the name shown (so `ReaderDriver`
/// still finds the renderer by it); with a report, its value is the counts
/// ("TextKit 2 9, TextKit 1 1, SwiftUI 4"). It is the only view that
/// observes the report: a change re-evaluates this label, nothing else.
struct RendererBadge: View {
    let report: ADFRendererReport
    let setting: ADFTextRenderer

    static func colorName(_ engine: ADFTextEngine) -> String {
        switch engine {
        case .swiftUI: return "orange"
        case .textKit2: return "green"
        case .textKit1: return "blue"
        }
    }

    /// The engine the badge names: TextKit 2 while any TextKit row (native
    /// or TextKit 1-backed) is on screen, else SwiftUI; nil with no report.
    static func shown(_ report: ADFRendererReport) -> ADFTextEngine? {
        guard report.isIdentifying else { return nil }
        if report.count(.textKit2) + report.count(.textKit1) > 0 { return .textKit2 }
        return report.count(.swiftUI) > 0 ? .swiftUI : nil
    }

    static func summary(_ report: ADFRendererReport) -> String {
        ADFTextEngine.allCases.filter { report.count($0) > 0 }
            .map { "\($0.displayName) \(report.count($0))" }
            .joined(separator: ", ")
    }

    var body: some View {
        if let shown = Self.shown(report) {
            let fallbacks = shown == .swiftUI ? 0 : report.count(.swiftUI)
            HStack(spacing: 4) {
                Self.capsule(shown.displayName, colour: shown.color, font: .subheadline.weight(.semibold))
                if fallbacks > 0 {
                    Self.capsule("\(fallbacks)", colour: ADFTextEngine.swiftUI.color, font: .caption.weight(.bold))
                }
            }
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(shown.displayName)
            .accessibilityValue(Self.summary(report))
            .accessibilityIdentifier("renderer-active")
        } else {
            Text(setting.displayName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
                .accessibilityIdentifier("renderer-active")
        }
    }

    private static func capsule(_ text: String, colour: Color, font: Font) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(colour, in: Capsule())
    }
}

/// `-interactionProbe` (UI tests only): counts what the document asks the
/// host to do, so a test can prove a task checkbox dispatched one id and
/// state exactly once and a link routed its exact URL. `ReaderView.handle`
/// records each `.taskToggled`; `Capture` installs an `openURL` action that
/// records each URL and handles it in place (no Safari hand-off). About This
/// Build shows the figures. Without the flag `enabled` stays false: nothing
/// is recorded and `Capture` returns the content untouched, so links open
/// as they always do.
@MainActor
enum InteractionProbe {
    static var enabled = false
    private(set) static var taskDispatches = 0
    /// `<id> <true|false>` of the last dispatch.
    private(set) static var lastTask: String?
    private(set) static var urlOpens = 0
    private(set) static var lastURL: String?

    static func recordTask(id: String, isDone: Bool) {
        guard enabled else { return }
        taskDispatches += 1
        lastTask = "\(id) \(isDone)"
        print("PROBE task id=\(id) isDone=\(isDone) dispatches=\(taskDispatches)")
        fflush(stdout)
    }

    static func recordURL(_ url: URL) {
        guard enabled else { return }
        urlOpens += 1
        lastURL = url.absoluteString
        print("PROBE openURL url=\(url.absoluteString) opens=\(urlOpens)")
        fflush(stdout)
    }

    /// The capturing `openURL` action when enabled; otherwise the content
    /// as it is (the flag is fixed for the process, so the branch never
    /// flips).
    struct Capture: ViewModifier {
        let enabled: Bool

        @ViewBuilder
        func body(content: Content) -> some View {
            if enabled {
                content.environment(\.openURL, OpenURLAction { url in
                    InteractionProbe.recordURL(url)
                    return .handled
                })
            } else {
                content
            }
        }
    }
}
