#if canImport(UIKit)
import SwiftUI
import UIKit
import Testing
import Darwin
import ADFModel
import ADFPreparation
@testable import ADFRendering

/// T0 work probe (rendering tier): how much work each renderer does to
/// materialise fixed fixture slices, counted rather than timed, so a busy
/// host does not move it (`Scripts/perf-probe.sh` compares two refs).
///
/// Each slice is prepared once and hosted in a non-lazy `VStack` (every row
/// materialises) inside a `UIHostingController` in a 390 pt `UIWindow`:
/// first layout, one layer render (every row draws), then 5 × 30 ms settle.
/// Each block gets the renderer the document view would give it
/// (`TextKit2Scope.inheritsRenderer`, the product's routing), so a block
/// kind not yet on TextKit 2 stays on SwiftUI in the TextKit 2 arm, as in
/// the app. Both renderers run in the same process, interleaved, after
/// `PERF_PROBE_WARMUPS` unmeasured reps each.
///
/// Per rep: `ADFTextRenderer.textKit2Stats` deltas (every Int field, read by
/// reflection, so a commit without a newer counter still compiles), UIViews,
/// CALayers and TextKit 2 row views in the hosted tree, process-wide
/// instructions retired (`proc_pid_rusage`, `ri_instructions`), main-thread
/// CPU and wall time (diagnostics only). Allocations are counted in a
/// separate rep (`PERF_PROBE_MALLOC_REPS`) so the `malloc_logger` hook does
/// not weigh on the instruction reps.
///
/// Opt-in: `PERF_PROBE=1` (simulator: `TEST_RUNNER_PERF_PROBE=1`). Output:
/// one JSON line per slice × renderer, printed after `PERF_PROBE ` and
/// appended to `PERF_PROBE_OUT` when set. Knobs: `PERF_PROBE_REPS` (5),
/// `PERF_PROBE_WARMUPS` (1), `PERF_PROBE_MALLOC_REPS` (1),
/// `PERF_PROBE_FIXTURES` (comma-separated slice names), `PERF_PROBE_LABEL`.
/// Schema: `Scripts/perf-probe.sh` header.
@Suite("T0 work probe: rendering", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["PERF_PROBE"] != nil
                    || ProcessInfo.processInfo.environment["PERF_PROBE_OUT"] != nil,
                "opt-in: PERF_PROBE=1 (simulator: TEST_RUNNER_PERF_PROBE=1)"))
@MainActor
struct PerfProbeTests {
    @Test("renderer work per fixture slice, SwiftUI and TextKit 2")
    func probe() async throws {
        let config = PerfProbeConfig()
        let renderers: [ADFTextRenderer] = [.swiftUI, .textKit2]
        var emitted = 0
        for slice in PerfProbeSlice.all where config.includes(slice.name) {
            let source = try PerfProbeFixtures.data(slice.fixture)
            let blocks = try await slice.blocks(from: source)
            try #require(!blocks.isEmpty, "\(slice.name): the slice prepared no blocks")

            for _ in 0..<config.warmups {
                for renderer in renderers {
                    _ = try await PerfProbeHost.rep(blocks, renderer: renderer, countMallocs: false)
                }
            }
            var reps: [[PerfProbeRep]] = renderers.map { _ in [] }
            for _ in 0..<config.reps {
                for (index, renderer) in renderers.enumerated() {
                    reps[index].append(try await PerfProbeHost.rep(blocks, renderer: renderer, countMallocs: false))
                }
            }
            var mallocReps: [[PerfProbeRep]] = renderers.map { _ in [] }
            for _ in 0..<config.mallocReps {
                for (index, renderer) in renderers.enumerated() {
                    mallocReps[index].append(try await PerfProbeHost.rep(blocks, renderer: renderer, countMallocs: true))
                }
            }

            for (index, renderer) in renderers.enumerated() {
                let line = PerfProbeReport.line(
                    slice: slice, source: source, blocks: blocks.count, renderer: renderer,
                    reps: reps[index], mallocReps: mallocReps[index], config: config
                )
                PerfProbeOutput.emit(line, to: config.outPath)
                emitted += 1
            }
        }
        #expect(emitted > 0, "no slice matched PERF_PROBE_FIXTURES")
    }
}

// MARK: - Configuration

struct PerfProbeConfig {
    var reps = 5
    var warmups = 1
    var mallocReps = 1
    var fixtures: Set<String>?
    var label: String?
    var outPath: String?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        func int(_ key: String, _ fallback: Int, minimum: Int) -> Int {
            environment[key].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.map { max(minimum, $0) } ?? fallback
        }
        reps = int("PERF_PROBE_REPS", 5, minimum: 1)
        warmups = int("PERF_PROBE_WARMUPS", 1, minimum: 0)
        mallocReps = int("PERF_PROBE_MALLOC_REPS", 1, minimum: 0)
        if let list = environment["PERF_PROBE_FIXTURES"], !list.isEmpty {
            fixtures = Set(list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
        label = environment["PERF_PROBE_LABEL"].flatMap { $0.isEmpty ? nil : $0 }
        outPath = environment["PERF_PROBE_OUT"].flatMap { $0.isEmpty ? nil : $0 }
    }

    func includes(_ name: String) -> Bool { fixtures?.contains(name) ?? true }
}

// MARK: - Fixture slices

/// A fixed slice of a repo fixture: which root nodes are kept. Slicing
/// happens on the ADF JSON, before parsing and preparation, so a change to
/// preparation shows up as work, not as a different slice.
struct PerfProbeSlice: Sendable {
    enum Selection: Sendable {
        case all
        case prefix(Int)
        case types([String], limit: Int)
        /// Every root kept; each root table keeps its first `n` rows.
        case tableRows(Int)
    }

    let name: String
    let fixture: String
    let detail: String
    let selection: Selection

    static let all: [PerfProbeSlice] = [
        PerfProbeSlice(name: "list-dense", fixture: "list-dense", detail: "first 100 root lists",
                       selection: .types(["bulletList", "orderedList", "taskList", "decisionList"], limit: 100)),
        PerfProbeSlice(name: "kitchen-sink", fixture: "kitchen-sink", detail: "whole document", selection: .all),
        PerfProbeSlice(name: "stress-1k", fixture: "stress-1k", detail: "first 100 roots", selection: .prefix(100)),
        PerfProbeSlice(name: "giant-table", fixture: "giant-table", detail: "heading + first 40 table rows",
                       selection: .tableRows(40)),
        PerfProbeSlice(name: "code", fixture: "code-dense", detail: "first 40 code blocks",
                       selection: .types(["codeBlock"], limit: 40)),
        PerfProbeSlice(name: "containers", fixture: "stress-1k", detail: "first 60 root panels, expands and quotes",
                       selection: .types(["panel", "expand", "blockquote"], limit: 60)),
    ]

    struct SliceError: Error, CustomStringConvertible {
        let description: String
    }

    func roots(_ roots: [Any]) -> [Any] {
        func type(_ node: Any) -> String? { (node as? [String: Any])?["type"] as? String }
        switch selection {
        case .all:
            return roots
        case .prefix(let count):
            return Array(roots.prefix(count))
        case .types(let types, let limit):
            return Array(roots.filter { node in type(node).map { types.contains($0) } ?? false }.prefix(limit))
        case .tableRows(let count):
            return roots.map { node in
                guard var table = node as? [String: Any], type(node) == "table",
                      let rows = table["content"] as? [Any] else { return node }
                table["content"] = Array(rows.prefix(count))
                return table
            }
        }
    }

    /// The slice's document, parsed and prepared with the default theme.
    func blocks(from source: Data) async throws -> [RenderBlock] {
        guard var document = try JSONSerialization.jsonObject(with: source) as? [String: Any],
              let content = document["content"] as? [Any] else {
            throw SliceError(description: "\(fixture): not an ADF document with root content")
        }
        document["content"] = roots(content)
        let sliced = try JSONSerialization.data(withJSONObject: document)
        let parsed = try await ADFParser().parse(sliced)
        return DocumentPreparer(theme: .default).prepare(parsed)
    }
}

enum PerfProbeFixtures {
    /// The repo-root `Fixtures/` directory, from this file's path
    /// (`Tests/ADFRenderingTests/Perf/`), so an exported tree reads its own.
    static var directory: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("Fixtures")
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent("\(name).json"))
    }

    /// FNV-1a 64 of the fixture bytes, so a comparison can tell a changed
    /// fixture from changed code.
    static func fnv64(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        data.withUnsafeBytes { bytes in
            for byte in bytes {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
        }
        return String(hash, radix: 16)
    }
}

// MARK: - Hosting

struct PerfProbeNoMedia: ADFMediaProvider {
    func image(for attrs: MediaAttrs, targetSize: CGSize) async throws -> Image {
        throw CancellationError()
    }
}

/// The document view's rows without its lazy stack, scroll view or row
/// lifecycle: the same per-row environment, padding and breakout
/// (`DocumentRow`), the same column margins and document environment.
struct PerfProbeDocument: View {
    let blocks: [RenderBlock]
    let renderer: ADFTextRenderer
    let theme: ADFTheme
    let columnWidth: CGFloat
    let sync: TableScrollSync

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks) { block in
                BlockView(block: block)
                    .environment(\.adfTextRenderer, TextKit2Scope.inheritsRenderer(block.kind) ? renderer : .swiftUI)
                    .environment(\.adfTextWidthBound, columnWidth > 0 ? .atLeast(columnWidth) : .pending)
                    .padding(.vertical, block.kind.defaultVerticalPadding)
                    .blockBreakout(block.breakout, margin: theme.spacing * 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, theme.spacing * 2)
        // Unbounded height, as in a scroll view: a bounded proposal would
        // squeeze (and truncate) rows.
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.adfTheme, theme)
        .environment(\.adfMediaProvider, PerfProbeNoMedia())
        .environment(\.adfTableScrollSync, sync)
    }
}

struct PerfProbeRep {
    /// Process-wide instructions retired over the whole rep, and over its
    /// synchronous part (host creation, first layout and render).
    var instructions: Double?
    var layoutInstructions: Double?
    /// Main-thread instructions over the whole rep and its synchronous
    /// part (`thread_selfcounts`): no other thread's work in them.
    var mainInstructions: Double?
    var mainLayoutInstructions: Double?
    var cpuMs: Double
    var wallMs: Double
    var counts: [String: Int]
    var mallocsMain: Int?
    var mallocsAll: Int?
}

@MainActor
enum PerfProbeHost {
    static let windowSize = CGSize(width: 390, height: 844)

    /// One materialisation, then teardown until this rep's TextKit 2 rows
    /// are released (unmeasured), so the next rep starts from the same
    /// state.
    static func rep(_ blocks: [RenderBlock], renderer: ADFTextRenderer, countMallocs: Bool) async throws -> PerfProbeRep {
        let liveBefore = ADFTextRenderer.textKit2Stats.liveRowCount
        let rep = try await measure(blocks, renderer: renderer, countMallocs: countMallocs)
        for _ in 0..<300 where ADFTextRenderer.textKit2Stats.liveRowCount > liveBefore {
            try await Task.sleep(for: .milliseconds(10))
        }
        // Let deferred teardown (hosting graph, autorelease pools) finish
        // here rather than inside the next rep.
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(20))
        }
        return rep
    }

    private static func measure(_ blocks: [RenderBlock], renderer: ADFTextRenderer, countMallocs: Bool) async throws -> PerfProbeRep {
        let theme = ADFTheme.default
        let statsBefore = PerfProbeCounters.textKit2Stats()
        let sync = TableScrollSync()
        if countMallocs { PerfProbeMalloc.start() }
        let wall0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let instructions0 = PerfProbeRusage.instructions()
        let main0 = PerfProbeThreadCounts.instructions()

        let window = UIWindow(frame: CGRect(origin: .zero, size: windowSize))
        let host = UIHostingController(rootView: PerfProbeDocument(
            blocks: blocks, renderer: renderer, theme: theme,
            columnWidth: windowSize.width - theme.spacing * 4, sync: sync
        ))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.isHidden = false
        window.layoutIfNeeded()
        render(window)
        let main1 = PerfProbeThreadCounts.instructions()
        let instructions1 = PerfProbeRusage.instructions()
        for _ in 0..<5 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        let main2 = PerfProbeThreadCounts.instructions()
        let instructions2 = PerfProbeRusage.instructions()
        let cpu2 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let wall2 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let mallocs = countMallocs ? PerfProbeMalloc.stop() : nil

        var counts: [String: Int] = [:]
        for (key, after) in PerfProbeCounters.textKit2Stats() {
            counts["tk2.\(key)"] = after - (statsBefore[key] ?? 0)
        }
        counts["uiviews"] = PerfProbeCounters.views(in: host.view)
        counts["calayers"] = PerfProbeCounters.layers(in: host.view.layer)
        counts["tk2_rows"] = PerfProbeCounters.textKit2Rows(in: host.view)

        window.isHidden = true
        window.rootViewController = nil

        func delta(_ start: UInt64?, _ end: UInt64?) -> Double? {
            guard let start, let end, end >= start else { return nil }
            return Double(end - start)
        }
        return PerfProbeRep(
            instructions: delta(instructions0, instructions2),
            layoutInstructions: delta(instructions0, instructions1),
            mainInstructions: delta(main0, main2),
            mainLayoutInstructions: delta(main0, main1),
            cpuMs: Double(cpu2 &- cpu0) / 1e6,
            wallMs: Double(wall2 &- wall0) / 1e6,
            counts: counts,
            mallocsMain: mallocs?.main,
            mallocsAll: mallocs?.all
        )
    }

    /// Renders the window's layers once, so every row view draws now (a
    /// window with no scene never displays on its own).
    static func render(_ window: UIWindow) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        _ = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { context in
            window.layer.render(in: context.cgContext)
        }
    }
}

// MARK: - Counters

@MainActor
enum PerfProbeCounters {
    /// Every `Int` field of `ADFTextRenderer.textKit2Stats` by name. Read
    /// by reflection so the probe compiles at commits that predate a
    /// counter; a counter a commit lacks is simply absent from its output.
    static func textKit2Stats() -> [String: Int] {
        var stats: [String: Int] = [:]
        for child in Mirror(reflecting: ADFTextRenderer.textKit2Stats).children {
            if let label = child.label, let value = child.value as? Int { stats[label] = value }
        }
        return stats
    }

    static func views(in view: UIView) -> Int {
        view.subviews.reduce(1) { $0 + views(in: $1) }
    }

    static func layers(in layer: CALayer) -> Int {
        (layer.sublayers ?? []).reduce(1) { $0 + layers(in: $1) }
    }

    static func textKit2Rows(in view: UIView) -> Int {
        view.subviews.reduce(view is TextKit2RowView ? 1 : 0) { $0 + textKit2Rows(in: $1) }
    }
}

/// Process-wide instructions retired, from `proc_pid_rusage`
/// (`RUSAGE_INFO_V4`), which the simulator SDK does not declare: looked up
/// at run time. Stable to about 0.1–0.3 % between reps on a busy host;
/// CPU time and cycles are not (core-type migration), so they are only
/// diagnostics.
enum PerfProbeRusage {
    typealias ProcPidRusage = @convention(c) (Int32, Int32, UnsafeMutableRawPointer?) -> Int32
    static let function: ProcPidRusage? =
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "proc_pid_rusage").map { unsafeBitCast($0, to: ProcPidRusage.self) }

    static func instructions() -> UInt64? {
        guard let function else { return nil }
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) {
            function(getpid(), Int32(RUSAGE_INFO_V4), UnsafeMutableRawPointer($0))
        }
        return status == 0 ? info.ri_instructions : nil
    }
}

/// The calling thread's instructions retired, from `thread_selfcounts`
/// (type 1: instructions, cycles), looked up at run time. Unlike the
/// process figure it leaves out every other thread (Swift Testing,
/// CoreAnimation, dispatch workers), which a loaded host schedules
/// differently from run to run.
enum PerfProbeThreadCounts {
    typealias ThreadSelfCounts = @convention(c) (Int32, UnsafeMutableRawPointer?, Int) -> Int32
    static let function: ThreadSelfCounts? =
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "thread_selfcounts").map { unsafeBitCast($0, to: ThreadSelfCounts.self) }

    static func instructions() -> UInt64? {
        guard let function else { return nil }
        var counts: (UInt64, UInt64) = (0, 0)
        let status = withUnsafeMutablePointer(to: &counts) {
            function(1, UnsafeMutableRawPointer($0), MemoryLayout<(UInt64, UInt64)>.size)
        }
        return status == 0 ? counts.0 : nil
    }
}

/// Counts allocations through `malloc_logger`, all threads and the main
/// thread apart. The callback runs inside malloc, so it only bumps
/// preallocated integers (see `MallocCounter` in TextKit2FlipMemoryTests
/// for why nothing else is safe there). Main-thread counts repeat exactly
/// between reps; all-thread counts can race.
enum PerfProbeMalloc {
    typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
    /// [all threads, main thread].
    nonisolated(unsafe) static let totals: UnsafeMutablePointer<Int> = {
        let buffer = UnsafeMutablePointer<Int>.allocate(capacity: 2)
        buffer.initialize(repeating: 0, count: 2)
        return buffer
    }()
    nonisolated(unsafe) static let slot: UnsafeMutablePointer<Logger?>? =
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger")?.assumingMemoryBound(to: Logger?.self)

    static let logger: Logger = { type, _, _, _, _, _ in
        guard type & 2 != 0 else { return }
        let totals = PerfProbeMalloc.totals
        totals[0] &+= 1
        if pthread_main_np() != 0 { totals[1] &+= 1 }
    }

    static func start() {
        _ = totals
        totals.update(repeating: 0, count: 2)
        slot?.pointee = logger
    }

    static func stop() -> (all: Int, main: Int)? {
        guard let slot else { return nil }
        slot.pointee = nil
        return (totals[0], totals[1])
    }
}

// MARK: - Output

enum PerfProbeReport {
    static func summary(_ values: [Double]) -> [String: Any]? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        let median = sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.count > 1
            ? values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1) : 0
        let cv = mean > 0 ? variance.squareRoot() / mean * 100 : 0
        return [
            "median": median, "min": sorted[0], "max": sorted[sorted.count - 1],
            "cv_pct": (cv * 1_000).rounded() / 1_000, "samples": values,
        ]
    }

    static func intMedian(_ values: [Int]) -> Int {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    static var configuration: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    @MainActor
    static func line(
        slice: PerfProbeSlice, source: Data, blocks: Int, renderer: ADFTextRenderer,
        reps: [PerfProbeRep], mallocReps: [PerfProbeRep], config: PerfProbeConfig
    ) -> [String: Any] {
        var counts: [String: Int] = [:]
        var unstable: [String] = []
        let keys = Set(reps.flatMap(\.counts.keys))
        for key in keys.sorted() {
            let values = reps.map { $0.counts[key] ?? 0 }
            counts[key] = intMedian(values)
            if Set(values).count > 1 { unstable.append(key) }
        }
        var line: [String: Any] = [
            "schema": 1,
            "tier": "render",
            "fixture": slice.name,
            "source": "\(slice.fixture).json",
            "slice": slice.detail,
            "fixture_bytes": source.count,
            "fixture_fnv64": PerfProbeFixtures.fnv64(source),
            "blocks": blocks,
            "renderer": renderer == .textKit2 ? "textKit2" : "swiftUI",
            "reps": reps.count,
            "warmups": config.warmups,
            "counts": counts,
            "counts_unstable": unstable,
            "env": [
                "os": osVersion,
                "config": configuration,
                "window": "\(Int(PerfProbeHost.windowSize.width))x\(Int(PerfProbeHost.windowSize.height))",
                "device": ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? "?",
            ] as [String: Any],
        ]
        if let label = config.label { line["label"] = label }
        let instructions = reps.compactMap(\.instructions)
        if instructions.count == reps.count, let stats = summary(instructions) { line["instructions"] = stats }
        let mainInstr = reps.compactMap(\.mainInstructions)
        if mainInstr.count == reps.count, let stats = summary(mainInstr) { line["instructions_main"] = stats }
        let mainLayout = reps.compactMap(\.mainLayoutInstructions)
        if mainLayout.count == reps.count, let stats = summary(mainLayout) { line["instructions_main_layout"] = stats }
        let layout = reps.compactMap(\.layoutInstructions)
        if layout.count == reps.count, let stats = summary(layout) { line["instructions_layout"] = stats }
        if let stats = summary(reps.map(\.cpuMs)) { line["cpu_ms"] = stats }
        if let stats = summary(reps.map(\.wallMs)) { line["wall_ms"] = stats }
        let main = mallocReps.compactMap(\.mallocsMain)
        let all = mallocReps.compactMap(\.mallocsAll)
        if !main.isEmpty, !all.isEmpty {
            line["mallocs"] = ["main": intMedian(main), "all": intMedian(all), "reps": main.count]
        }
        return line
    }
}

enum PerfProbeOutput {
    static func emit(_ object: [String: Any], to path: String?) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            Issue.record("perf probe: line is not valid JSON: \(object)")
            return
        }
        print("PERF_PROBE \(text)")
        guard let path else { return }
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            Issue.record("perf probe: cannot write \(path)")
            return
        }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(Data((text + "\n").utf8))
    }
}
#endif
