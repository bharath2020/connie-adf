import Darwin
import Foundation
import UIKit
@_spi(ADFDiagnostics) import ADFRendering

/// The T1 scroll-counter tier's in-app half (`Scripts/perf-scroll-counters.sh`):
/// the `-autoscroll` speed, and with `-scrollCounters` the work a scroll and
/// the idle time after it cost, as one `SCROLL_COUNTERS` line.
///
/// T1 counts work, not frames, so it scrolls much faster than the frame gate
/// and needs no quiet host. Its launch arguments:
///
/// - `-autoscrollSpeed <pt/s>`: the `-autoscroll` speed. Default 1,200 pt/s,
///   the frame gate's speed, with one animation leg per block as before.
///   With the flag, adjacent short blocks merge into one leg until the leg
///   lasts at least `minimumLegSeconds` (never past `maximumLegPoints`, so
///   the leg's target stays inside the materialised region; a block taller
///   than that is still one leg). Leg ends are a pure function of the block
///   heights and the speed, so two builds scroll the same path.
/// - `-scrollCounters`: measure and print `SCROLL_COUNTERS` (below). Without
///   it nothing here runs and `-autoscroll` behaves exactly as before.
/// - `-idleSeconds <s>`: the idle window after the scroll (default 5).
///
/// With `-scrollCounters`, `AutoScroller` prints, after `SCROLL_METRICS` and
/// its `RENDERER_STATS`, the frame metrics' display link stopped, and the
/// idle window over, exactly one line:
///
///     SCROLL_COUNTERS fixture=<name> speed=<pt/s> legs=<n>
///         rowAppears=<n> rowDisappears=<n> rowsInRegion=<n>
///         tk2Live=<n> tk2InWindow=<n> tk2OffWindow=<n>
///         scrollInstructions=<n> scrollCpuMs=<n> idleMs=<n>
///         idleInstructions=<n> idleCpuMs=<n> idleRowAppears=<n>
///         idleRowDisappears=<n> idleTk2Layouts=<n>
///         scrollTk2SizeThatFits=<n> scrollTk2InfiniteWidth=<n>
///         idleTk2SizeThatFits=<n>
///
/// - `legs` counts the scroll's animation legs; `rowAppears` /
///   `rowDisappears` the lazy rows that entered / left the render region
///   during the scroll (`ADFRowLifecycle`), `rowsInRegion` the rows in it
///   when the scroll ended.
/// - `tk2Live` is the live TextKit 2 row views at the scroll's end,
///   `tk2InWindow` those attached to the key window and `tk2OffWindow` the
///   rest: rows the lazy stack built but keeps off the window (prefetched or
///   never shown). All three are 0 on SwiftUI.
/// - `scrollInstructions` is the CPU instructions the whole process retired
///   from the first leg to the end of the post-scroll settle
///   (`proc_pid_rusage`, `RUSAGE_INFO_V4`, `ri_instructions`); `scrollCpuMs`
///   its user + system CPU time (a diagnostic: CPU time moves with host
///   load and core type, instructions much less).
/// - The `idle…` keys cover the idle window (`idleMs` measured): a settled
///   reader does almost nothing, a livelock spins (ADR §16), so idle
///   instructions, row churn and TextKit 2 layouts must stay near zero.
/// - `scrollTk2SizeThatFits` / `scrollTk2InfiniteWidth` / `idleTk2SizeThatFits`:
///   TextKit 2 row size queries (all, and those proposing an infinite width)
///   during the scroll and the idle window, from `ADFTextKit2Stats`.
///
/// A value that cannot be read prints as `-` (`Scripts/perf_trial.py` leaves
/// its column empty).
@MainActor
enum ScrollCounters {
    struct Options {
        /// `-autoscrollSpeed`; nil keeps the default speed and leg rule.
        var pointsPerSecond: Double?
        /// `-scrollCounters`.
        var enabled = false
        /// `-idleSeconds`.
        var idleSeconds: Double = 5

        init(arguments: [String] = ProcessInfo.processInfo.arguments) {
            var index = arguments.startIndex
            while index < arguments.endIndex {
                let hasValue = arguments.index(after: index) < arguments.endIndex
                switch arguments[index] {
                case "-autoscrollSpeed" where hasValue:
                    index = arguments.index(after: index)
                    if let speed = Double(arguments[index]), speed.isFinite, speed > 0 {
                        pointsPerSecond = speed
                    }
                case "-scrollCounters":
                    enabled = true
                case "-idleSeconds" where hasValue:
                    index = arguments.index(after: index)
                    if let seconds = Double(arguments[index]), seconds.isFinite, seconds >= 0 {
                        idleSeconds = seconds
                    }
                default:
                    break
                }
                index = arguments.index(after: index)
            }
        }
    }

    static let options = Options()

    /// The frame gate's speed (`Scripts/perf-gate.sh` never passes
    /// `-autoscrollSpeed`).
    static let defaultPointsPerSecond: Double = 1_200

    static var pointsPerSecond: Double {
        options.pointsPerSecond ?? defaultPointsPerSecond
    }

    /// Shortest leg at a raised speed: two 60 Hz frames, so each leg's
    /// animation gets frames to run in. Zero at the default speed (one leg
    /// per block, unchanged).
    static var minimumLegSeconds: Double {
        options.pointsPerSecond == nil ? 0 : 2.0 / 60
    }

    /// Longest merged leg: well under a phone viewport, so the target block
    /// is already materialised when `scrollTo` resolves it (far targets
    /// stall; see `AutoScroller`).
    static let maximumLegPoints: Double = 400

    static var isEnabled: Bool { options.enabled }

    // MARK: - Measurement

    private struct Usage {
        var instructions: UInt64
        /// User + system CPU time, in mach absolute time units.
        var cpuTicks: UInt64
    }

    private struct Snapshot {
        var usage: Usage?
        var appearances: Int
        var disappearances: Int
        var textKit2Layouts: Int
        var textKit2SizeThatFits: Int
        var textKit2InfiniteWidth: Int
        var instant: ContinuousClock.Instant
    }

    private static func snapshot() -> Snapshot {
        let stats = ADFTextRenderer.textKit2Stats
        return Snapshot(
            usage: usage(),
            appearances: ADFRowLifecycle.appearances,
            disappearances: ADFRowLifecycle.disappearances,
            textKit2Layouts: stats.layoutCount,
            textKit2SizeThatFits: stats.sizeThatFitsCount,
            textKit2InfiniteWidth: stats.infiniteWidthProposalCount,
            instant: .now
        )
    }

    private static var scrollStart: Snapshot?
    private static var scrollEnd: Snapshot?
    private static var legs = 0
    private static var textKit2Live: Int?
    private static var textKit2InWindow: Int?

    /// Right before the first leg.
    static func scrollWillBegin() {
        guard isEnabled else { return }
        scrollStart = snapshot()
    }

    /// After the post-scroll settle, before the frame metrics are read.
    static func scrollDidEnd(legs count: Int) {
        guard isEnabled else { return }
        scrollEnd = snapshot()
        legs = count
        textKit2Live = ADFTextRenderer.textKit2Stats.liveRowCount
        textKit2InWindow = textKit2RowsInKeyWindow()
    }

    /// Waits out the idle window, then prints `SCROLL_COUNTERS`. The caller
    /// has stopped the frame metrics' display link: the window measures the
    /// reader's own leftover work.
    static func measureIdleAndPrint(fixtureName: String) async {
        guard isEnabled else { return }
        let idleStart = snapshot()
        try? await Task.sleep(for: .seconds(options.idleSeconds))
        let idleEnd = snapshot()

        var fields: [(String, String)] = [
            ("fixture", fixtureName),
            ("speed", number(pointsPerSecond)),
            ("legs", String(legs)),
        ]
        if let start = scrollStart, let end = scrollEnd {
            fields.append(("rowAppears", String(end.appearances - start.appearances)))
            fields.append(("rowDisappears", String(end.disappearances - start.disappearances)))
            fields.append(("rowsInRegion", String(end.appearances - end.disappearances)))
        } else {
            fields.append(contentsOf: [("rowAppears", "-"), ("rowDisappears", "-"), ("rowsInRegion", "-")])
        }
        fields.append(("tk2Live", textKit2Live.map(String.init) ?? "-"))
        fields.append(("tk2InWindow", textKit2InWindow.map(String.init) ?? "-"))
        if let live = textKit2Live, let inWindow = textKit2InWindow {
            fields.append(("tk2OffWindow", String(max(live - inWindow, 0))))
        } else {
            fields.append(("tk2OffWindow", "-"))
        }
        let scroll = delta(from: scrollStart?.usage, to: scrollEnd?.usage)
        fields.append(("scrollInstructions", scroll.map { String($0.instructions) } ?? "-"))
        fields.append(("scrollCpuMs", scroll.map { milliseconds(ticks: $0.cpuTicks) } ?? "-"))
        fields.append(("idleMs", number(milliseconds(from: idleStart.instant, to: idleEnd.instant))))
        let idle = delta(from: idleStart.usage, to: idleEnd.usage)
        fields.append(("idleInstructions", idle.map { String($0.instructions) } ?? "-"))
        fields.append(("idleCpuMs", idle.map { milliseconds(ticks: $0.cpuTicks) } ?? "-"))
        fields.append(("idleRowAppears", String(idleEnd.appearances - idleStart.appearances)))
        fields.append(("idleRowDisappears", String(idleEnd.disappearances - idleStart.disappearances)))
        fields.append(("idleTk2Layouts", String(idleEnd.textKit2Layouts - idleStart.textKit2Layouts)))
        fields.append(("scrollTk2SizeThatFits", difference(scrollStart?.textKit2SizeThatFits, scrollEnd?.textKit2SizeThatFits)))
        fields.append(("scrollTk2InfiniteWidth", difference(scrollStart?.textKit2InfiniteWidth, scrollEnd?.textKit2InfiniteWidth)))
        fields.append(("idleTk2SizeThatFits", difference(idleStart.textKit2SizeThatFits, idleEnd.textKit2SizeThatFits)))

        // One token per value: a fixture name with a space prints with `_`.
        let line = fields.map { field in
            let value = field.1.isEmpty ? "-" : field.1.replacingOccurrences(of: " ", with: "_")
            return "\(field.0)=\(value)"
        }.joined(separator: " ")
        print("SCROLL_COUNTERS " + line)
        fflush(stdout)
    }

    // MARK: - Helpers

    private typealias ProcPidRusage = @convention(c) (Int32, Int32, UnsafeMutableRawPointer?) -> Int32

    /// `proc_pid_rusage` is not declared in the iOS SDK (no `libproc.h`) but
    /// is exported by libSystem; `RTLD_DEFAULT` is `(void *)-2`.
    private static let procPidRusage: ProcPidRusage? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "proc_pid_rusage") else {
            return nil
        }
        return unsafeBitCast(symbol, to: ProcPidRusage.self)
    }()

    /// `RUSAGE_INFO_V4` (`sys/resource.h`).
    private static let rusageInfoV4: Int32 = 4

    private static func usage() -> Usage? {
        guard let procPidRusage else { return nil }
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            procPidRusage(getpid(), rusageInfoV4, UnsafeMutableRawPointer(pointer))
        }
        guard status == 0 else { return nil }
        return Usage(instructions: info.ri_instructions, cpuTicks: info.ri_user_time &+ info.ri_system_time)
    }

    private static func delta(from start: Usage?, to end: Usage?) -> Usage? {
        guard let start, let end,
              end.instructions >= start.instructions, end.cpuTicks >= start.cpuTicks else { return nil }
        return Usage(instructions: end.instructions - start.instructions, cpuTicks: end.cpuTicks - start.cpuTicks)
    }

    private static func difference(_ start: Int?, _ end: Int?) -> String {
        guard let start, let end else { return "-" }
        return String(end - start)
    }

    private static func milliseconds(ticks: UInt64) -> String {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom > 0 else { return "-" }
        let nanoseconds = Double(ticks) * Double(timebase.numer) / Double(timebase.denom)
        return number(nanoseconds / 1e6)
    }

    private static func milliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let (seconds, attoseconds) = start.duration(to: end).components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    /// TextKit 2 row views attached to the key window, found by class name so
    /// this file builds against any ref with TextKit 2 rows (the row view
    /// type is internal to `ADFRendering`). One walk of the window, at the
    /// scroll's end only.
    private static func textKit2RowsInKeyWindow() -> Int? {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return nil }
        var count = 0
        var stack: [UIView] = [window]
        while let view = stack.popLast() {
            if String(describing: type(of: view)) == "TextKit2RowView" {
                count += 1
            }
            stack.append(contentsOf: view.subviews)
        }
        return count
    }
}
