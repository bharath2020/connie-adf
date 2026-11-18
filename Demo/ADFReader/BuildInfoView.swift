import CryptoKit
import SwiftUI
@_spi(ADFDiagnostics) import ADFRendering

/// "About This Build": version/build, the SHA-256 of the running executable,
/// the active text renderer and how many TextKit 2 rows are alive (the
/// renderer proof: > 0 while TextKit 2 draws rows on screen, 0 after a
/// switch back to SwiftUI), of which how many are TextKit 1-backed (linked
/// text, laid out and drawn by a TextKit 1 stack inside the row), how
/// many draw list text and how many draw a code block's code, and under
/// `-rebuildControlPicks` the memory control's live rows, and under
/// `-interactionProbe` the task dispatches and URL opens it recorded
/// (`InteractionProbe`), and last the open document's smart-link
/// counters (`ADFDocumentModel.smartLinkStats`), the mock resolver's
/// own counts (`MockSmartLinkResolver`) and the text-leaf body and TextKit 2
/// conversion and layout totals, and last of all the smart-link resolution
/// mode with its scroll and nearby counters. The checksum lets a screen recording be
/// tied to one exact binary — `Scripts/e2e-video.sh` compares what the test
/// saw on screen against the `.app` it built and the one it installed.
struct BuildInfoView: View {
    let renderer: ADFTextRenderer
    /// The open reader's model, for its smart-link counters; read only in
    /// the polling task (never in `body`), so the sheet observes nothing on
    /// it. `nil` hides the per-document smart-link section.
    var model: ADFDocumentModel? = nil
    /// The reader's smart-link resolution mode (the menu's choice).
    var smartLinkResolution: ADFSmartLinkResolution = .whileScrolling

    @Environment(\.dismiss) private var dismiss
    @State private var executableSHA256: String?
    @State private var checksumUnavailable = false
    /// Polled from the diagnostics counter while the sheet is open — never
    /// bound to row visibility, so reading it cannot feed back into layout.
    /// `nil` until the first read, shown as "…" so a UI test never mistakes
    /// the placeholder for a count.
    @State private var liveTextKit2Rows: Int?
    @State private var liveTextKit1BackedRows: Int?
    /// Live TextKit 2 rows drawing list text (leaders and list-owned
    /// trailing text) — the proof that lists, not only root paragraphs,
    /// are on the TextKit 2 engine.
    @State private var liveTextKit2ListRows: Int?
    /// Live TextKit 2 rows drawing a code block's code text: the proof
    /// that code, not only paragraphs and lists, is on the TextKit 2
    /// engine.
    @State private var liveTextKit2CodeRows: Int?
    @State private var rebuildControlRows: Int?
    /// `InteractionProbe` figures, read when the sheet is built and on each
    /// poll (they change only while the sheet is closed).
    @State private var probeTaskDispatches = InteractionProbe.taskDispatches
    @State private var probeLastTask = InteractionProbe.lastTask
    @State private var probeURLOpens = InteractionProbe.urlOpens
    @State private var probeLastURL = InteractionProbe.lastURL
    /// The library's smart-link counters for this document
    /// (`model.smartLinkStats`) and how many text owners a smart link
    /// redrew (`model.smartLinkLeafRefreshesByOwner.count`), polled like
    /// the counters above; `nil` until the first read.
    @State private var smartLinkStats: ADFSmartLinkStats?
    @State private var smartLinkRefreshedOwners: Int?
    /// The demo mock resolver's own counts (`MockSmartLinkResolver.shared`),
    /// polled likewise.
    @State private var smartLinkCounts: MockSmartLinkResolver.Counts?
    /// Text-leaf body evaluations since launch
    /// (`ADFTextRenderer.textLeafStats`) and the TextKit 2 conversion and
    /// layout totals, polled likewise: the smart-link UI test's proof that
    /// a resolution re-evaluated no other leaf and rebuilt no other row.
    @State private var textLeafStats: ADFTextLeafStats?
    @State private var textKit2Conversions: Int?
    @State private var textKit2Layouts: Int?

    var body: some View {
        NavigationStack {
            List {
                Section("Version") {
                    Text(BuildIdentity.versionString)
                        .accessibilityIdentifier("build-version")
                }
                Section("Text Renderer") {
                    Text(renderer.displayName)
                        .accessibilityIdentifier("build-renderer")
                }
                Section("Live TextKit 2 Rows") {
                    Text(liveTextKit2Rows.map(String.init) ?? "…")
                        .monospacedDigit()
                        .accessibilityIdentifier("tk2-live-rows")
                }
                Section("Of Which TextKit 1-Backed (Links)") {
                    Text(liveTextKit1BackedRows.map(String.init) ?? "…")
                        .monospacedDigit()
                        .accessibilityIdentifier("tk1-backed-rows")
                }
                Section("Of Which List Text") {
                    Text(liveTextKit2ListRows.map(String.init) ?? "…")
                        .monospacedDigit()
                        .accessibilityIdentifier("tk2-list-live-rows")
                }
                if RebuildControl.configured {
                    Section("Rebuild-Control Rows (SwiftUI)") {
                        Text(rebuildControlRows.map(String.init) ?? "…")
                            .monospacedDigit()
                            .accessibilityIdentifier("rebuild-control-rows")
                    }
                }
                if let blocks = LoadSwitchProbe.blocksAtSwitch {
                    Section("Switched During Load (Blocks Loaded)") {
                        Text(verbatim: String(blocks))
                            .monospacedDigit()
                            .accessibilityIdentifier("load-switch-blocks")
                    }
                }
                if let blocks = LoadSwitchProbe.blocksAtReady {
                    Section("Ready After the Switch (Blocks Loaded)") {
                        Text(verbatim: String(blocks))
                            .monospacedDigit()
                            .accessibilityIdentifier("load-ready-blocks")
                    }
                }
                Section {
                    checksumRow
                } header: {
                    Text("Executable SHA-256")
                } footer: {
                    Text(BuildIdentity.executableDescription)
                }
                // Below the checksum, not beside the other row counts: a row
                // of this list is in the accessibility tree only while it is
                // on screen, and UI tests read the rows above without
                // scrolling, so a section added above them would move them.
                Section("Live TextKit 2 Rows Drawing Code") {
                    Text(liveTextKit2CodeRows.map(String.init) ?? "…")
                        .monospacedDigit()
                        .accessibilityIdentifier("tk2-code-live-rows")
                }
                if InteractionProbe.enabled {
                    interactionProbeSection
                }
                // Last, so they move none of the rows above (UI tests read
                // them without scrolling, and the probe section's reader
                // expects it below the code row; see the note above it).
                if model != nil {
                    smartLinkStatsSection
                }
                smartLinksSection
                // Below the smart-link counters it is read with.
                leafDiagnosticsSection
                // Last of all, so it moves none of the rows above (UI tests
                // read them top to bottom).
                if model != nil {
                    smartLinkResolutionSection
                }
            }
            .navigationTitle("About This Build")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("build-info-done")
                }
            }
            .task {
                if let sha = await BuildIdentity.executableSHA256() {
                    executableSHA256 = sha
                } else {
                    checksumUnavailable = true
                }
            }
            .task {
                while !Task.isCancelled {
                    let stats = ADFTextRenderer.textKit2Stats
                    liveTextKit2Rows = stats.liveRowCount
                    liveTextKit1BackedRows = stats.textKit1BackedRowCount
                    liveTextKit2ListRows = stats.liveListRowCount
                    liveTextKit2CodeRows = stats.liveCodeRowCount
                    rebuildControlRows = ADFTextRenderer.rebuildControlRows.live
                    probeTaskDispatches = InteractionProbe.taskDispatches
                    probeLastTask = InteractionProbe.lastTask
                    probeURLOpens = InteractionProbe.urlOpens
                    probeLastURL = InteractionProbe.lastURL
                    if let model {
                        smartLinkStats = model.smartLinkStats
                        smartLinkRefreshedOwners = model.smartLinkLeafRefreshesByOwner.count
                    }
                    smartLinkCounts = MockSmartLinkResolver.shared?.snapshot
                    textLeafStats = ADFTextRenderer.textLeafStats
                    textKit2Conversions = stats.conversionCount
                    textKit2Layouts = stats.layoutCount
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
    }

    /// `-interactionProbe`: one row per kind — the count, then the last
    /// value — each value its own element for a UI test to read. Placed
    /// after the checksum so the checksum keeps its place on screen.
    private var interactionProbeSection: some View {
        Section("Interaction Probe") {
            HStack(spacing: 8) {
                Text("Tasks")
                    .foregroundStyle(.secondary)
                Text(verbatim: String(probeTaskDispatches))
                    .monospacedDigit()
                    .accessibilityIdentifier("probe-task-dispatches")
                Spacer(minLength: 8)
                Text(verbatim: probeLastTask ?? "none")
                    .font(.footnote.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("probe-task-last")
            }
            HStack(spacing: 8) {
                Text("URLs")
                    .foregroundStyle(.secondary)
                Text(verbatim: String(probeURLOpens))
                    .monospacedDigit()
                    .accessibilityIdentifier("probe-url-opens")
                Spacer(minLength: 8)
                Text(verbatim: probeLastURL ?? "none")
                    .font(.footnote.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("probe-url-last")
            }
        }
    }

    /// The library's smart-link counters for the open document
    /// (`ADFSmartLinkStats`: cumulative across its loads, except calls in
    /// flight), plus how many text owners a smart-link stage change
    /// redrew. Each value is its own element, `smartlink-stat-<field>`
    /// (`resolverCalls`, `cancellations`, `inFlight`, `resolved`, `failed`,
    /// `leafRefreshes`, `refreshedOwners`), for a UI test to read.
    private var smartLinkStatsSection: some View {
        Section("Smart Links (This Document)") {
            countRow("Resolver Calls", smartLinkStats?.resolverCalls, id: "smartlink-stat-resolverCalls")
            countRow("Cancellations", smartLinkStats?.cancellations, id: "smartlink-stat-cancellations")
            countRow("In Flight", smartLinkStats?.inFlight, id: "smartlink-stat-inFlight")
            countRow("Resolved", smartLinkStats?.resolved, id: "smartlink-stat-resolved")
            countRow("Failed", smartLinkStats?.failed, id: "smartlink-stat-failed")
            countRow("Leaf Refreshes", smartLinkStats?.leafRefreshes, id: "smartlink-stat-leafRefreshes")
            countRow("Owners Refreshed", smartLinkRefreshedOwners, id: "smartlink-stat-refreshedOwners")
        }
    }

    /// The resolution mode the reader passes (`ADFSmartLinkResolution`) and
    /// the counters it drives (`ADFSmartLinkStats`, design §8): scroll ends,
    /// calls started while scrolling (zero unless While Scrolling), visible
    /// lookups held back by a scroll, links on screen still waiting, and the
    /// nearby batches (After Scrolling + Nearby). Each value is its own
    /// element: `smartlink-resolution` (the mode's raw value), then
    /// `smartlink-mode-<field>`.
    private var smartLinkResolutionSection: some View {
        Section {
            HStack(spacing: 8) {
                Text("Mode")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(verbatim: smartLinkResolution.displayName)
                    .accessibilityIdentifier("smartlink-resolution-name")
                Text(verbatim: smartLinkStats?.resolution.rawValue ?? "…")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("smartlink-resolution")
            }
            countRow("Scroll Ends", smartLinkStats?.scrollEnds, id: "smartlink-mode-scrollEnds")
            countRow("Calls While Scrolling", smartLinkStats?.scrollingCalls, id: "smartlink-mode-scrollingCalls")
            countRow("Held by Scrolling", smartLinkStats?.deferred, id: "smartlink-mode-deferred")
            countRow("Waiting On Screen", smartLinkStats?.waiting, id: "smartlink-mode-waiting")
            countRow("Nearby Batches", smartLinkStats?.prefetchBatches, id: "smartlink-mode-prefetchBatches")
            countRow("Nearby Calls", smartLinkStats?.prefetchCalls, id: "smartlink-mode-prefetchCalls")
            countRow("Nearby In Flight", smartLinkStats?.prefetchInFlight, id: "smartlink-mode-prefetchInFlight")
            countRow("Nearby Cancelled", smartLinkStats?.prefetchCancellations, id: "smartlink-mode-prefetchCancellations")
            countRow("Nearby Hits", smartLinkStats?.prefetchHits, id: "smartlink-mode-prefetchHits")
            countRow("Largest Batch", smartLinkStats?.largestPrefetchBatch, id: "smartlink-mode-largestPrefetchBatch")
            countRow("Farthest (Positions)", smartLinkStats?.farthestPrefetch, id: "smartlink-mode-farthestPrefetch")
        } header: {
            Text("Smart Link Resolution")
        } footer: {
            if let limits = model?.smartLinkNearbyLimits {
                Text(verbatim: "Nearby: batches of ≤ \(limits.batch), within \(limits.distance) positions "
                    + "(a top-level row, or a row of a top-level list), only at rest.")
            }
        }
    }

    /// The mock resolver's view of smart-link lookups since launch: every
    /// call the library made, how many it cancelled (a row left the screen
    /// before the delay ran out), how many are waiting now, and how many
    /// answered with a title or threw. Each value is its own element
    /// (`smartlink-calls`, `-cancelled`, `-in-flight`, `-resolved`,
    /// `-failed`) for a UI test to read; `smartlink-off` under
    /// `-smartLinks off`.
    @ViewBuilder
    private var smartLinksSection: some View {
        if let resolver = MockSmartLinkResolver.shared {
            Section {
                countRow("Calls", smartLinkCounts?.calls, id: "smartlink-calls")
                countRow("Cancelled", smartLinkCounts?.cancelled, id: "smartlink-cancelled")
                countRow("In Flight", smartLinkCounts?.inFlight, id: "smartlink-in-flight")
                countRow("Resolved", smartLinkCounts?.resolved, id: "smartlink-resolved")
                countRow("Failed", smartLinkCounts?.failed, id: "smartlink-failed")
            } header: {
                Text("Smart Links (Mock Resolver)")
            } footer: {
                Text(verbatim: resolver.configuration.summary)
            }
        } else {
            Section("Smart Links") {
                Text("Off (-smartLinks off)")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("smartlink-off")
            }
        }
    }

    /// Process-wide work counters since launch: text-leaf body evaluations
    /// (`ADFTextRenderer.textLeafStats`: SwiftUI `Text` leaves and engine
    /// leaves) and TextKit 2 text conversions and layouts. Each value is its
    /// own element (`leaf-stat-total`, `-segmented`, `-engine`,
    /// `tk2-stat-conversions`, `tk2-stat-layouts`) for a UI test to read;
    /// the smart-link test compares them across a resolution with the
    /// leaf refreshes above.
    private var leafDiagnosticsSection: some View {
        Section("Text Leaves (Since Launch)") {
            countRow("Leaf Bodies", textLeafStats?.total, id: "leaf-stat-total")
            countRow("Of Which SwiftUI Text", textLeafStats?.segmentedTextBodies, id: "leaf-stat-segmented")
            countRow("Of Which Engine Leaf", textLeafStats?.engineLeafBodies, id: "leaf-stat-engine")
            countRow("TextKit 2 Conversions", textKit2Conversions, id: "tk2-stat-conversions")
            countRow("TextKit 2 Layouts", textKit2Layouts, id: "tk2-stat-layouts")
        }
    }

    /// A titled count; "…" until the first poll. The value is its own
    /// element, identified by `id`.
    private func countRow(_ title: String, _ value: Int?, id: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(verbatim: value.map(String.init) ?? "…")
                .monospacedDigit()
                .accessibilityIdentifier(id)
        }
    }

    @ViewBuilder
    private var checksumRow: some View {
        if let executableSHA256 {
            Text(executableSHA256)
                .font(.system(.footnote, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier("build-sha256")
        } else if checksumUnavailable {
            Text("Unavailable")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("build-sha256-unavailable")
        } else {
            HStack(spacing: 8) {
                ProgressView()
                Text("Computing…")
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("build-sha256-pending")
        }
    }
}

/// Identity of the running binary. The checksum is computed once per process,
/// off the main thread, the first time it is requested — the executable is a
/// few megabytes, which is too much to hash during a sheet presentation.
enum BuildIdentity {
    /// `CFBundleShortVersionString (CFBundleVersion)`, e.g. `1.0 (18)`.
    static var versionString: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    static var executableDescription: String {
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown bundle"
        let executable = Bundle.main.executableURL?.lastPathComponent ?? "unknown executable"
        return "\(bundleID) · \(executable)"
    }

    /// Lowercase hex SHA-256 of `Bundle.main.executableURL`, or `nil` when
    /// the file cannot be read. Matches a simulator or development install
    /// of the built binary; App Store Connect re-signs TestFlight builds, so
    /// there the digest differs from the local archive's.
    static func executableSHA256() async -> String? {
        await checksumTask.value
    }

    private static let checksumTask: Task<String?, Never> = {
        let url = Bundle.main.executableURL
        return Task.detached(priority: .utility) {
            guard let url else { return nil }
            return try? sha256Hex(ofFileAt: url)
        }
    }()

    private static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
