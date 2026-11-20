import Foundation

/// The frozen limits of PR 4's expand-timing lifecycle tests (plan §8.3
/// K7, §8.5 M2), each computed by the M2 formula from a **B-only pilot**
/// (switch OFF, before any switch-ON timing of the same quantity) and
/// committed before arm C is timed. A breach is FAIL and goes to firstmate
/// as `needs-decision` with the numbers; never re-tune a value here to
/// absorb a cost (builder contract rule 5).
///
/// The pilot is the test itself with `ADF_CONTAINER_LIMITS_PILOT=1`
/// (`TEST_RUNNER_ADF_CONTAINER_LIMITS_PILOT=1 Scripts/lifecycle-gate.sh
/// --only testK8 …`): it runs arm B only, records every sample through the
/// host agent, prints `M2_PILOT_…` / `K7_PILOT_…` lines and gates nothing
/// but completeness.
enum ContainerLifecycleLimits {
    /// `max(2.0 × B median, B median + 2 × (B max − B min))` (plan §8.5 M2).
    static func formula(_ samples: [Double]) -> Double? {
        guard let low = samples.min(), let high = samples.max() else { return nil }
        let middle = median(samples)
        return max(2.0 * middle, middle + 2.0 * (high - low))
    }

    static func median(_ samples: [Double]) -> Double {
        let sorted = samples.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2]
            : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    /// Whether this run is a B-only pilot (`ADF_CONTAINER_LIMITS_PILOT=1`).
    static var isPilot: Bool {
        ProcessInfo.processInfo.environment["ADF_CONTAINER_LIMITS_PILOT"] == "1"
    }

    // MARK: M2 — tall expand mount (testK8TallExpandMountAndFlip)

    /// Wall time, in seconds, from just before the tap on `CE-TALL`'s title
    /// (so it includes XCUITest's idle wait and event synthesis, about
    /// 0.35 s, in both arms) to `CE-TALL-300` existing in the accessibility
    /// tree, polled every 50 ms; arm C's median of five launches must not
    /// exceed it. Frozen 2026-11-16 (step 5) from the B-only pilot below:
    /// median 0.44574 s, range 0.01360 s, so max(2 × 0.44574,
    /// 0.44574 + 2 × 0.01360) = 0.89147 s, rounded to the millisecond.
    static let m2MountSeconds: Double? = 0.891
    /// The B-only pilot samples `m2MountSeconds` was computed from, seconds
    /// (five SwiftUI launches with `-rebuildControlPicks 1`).
    static let m2PilotSamples: [Double] = [0.454, 0.441, 0.446, 0.454, 0.444]

    /// M2 flip (review A-R7): wall time, in seconds, from just before the
    /// tap on the renderer menu's item to the toolbar naming the new
    /// renderer and CE-TALL-300 drawn by it, polled every 50 ms
    /// (`ReaderDriver.chooseRendererTimed`), with CE-TALL open: arm C's
    /// timed ON pick (after an untimed OFF) must have its median of five
    /// launches within it; arm B's sample is the rebuild control's pick
    /// (`-rebuildControlPicks 1`: the same 300 leaves rebuilt as SwiftUI,
    /// done when the toolbar names TextKit 2 and CE-TALL-300 is there).
    /// Frozen 2026-11-18 (review A-R7) from the B-only pilot below, before
    /// any arm-C timing of this metric: median 1.65283 s, range 0.01653 s,
    /// so max(2 × 1.65283, 1.65283 + 2 × 0.01653) = 3.30566 s, rounded to
    /// the millisecond.
    static let m2FlipSeconds: Double? = 3.306
    /// The B-only pilot samples `m2FlipSeconds` was computed from, seconds
    /// (five SwiftUI launches with `-rebuildControlPicks 1`, the timed pick
    /// rebuilding CE-TALL's 300 leaves as SwiftUI).
    static let m2FlipPilotSamples: [Double] = [1.655, 1.653, 1.646, 1.655, 1.639]

    // MARK: K7 — CE-OPEN open time (testK7ExpandOpenCloseCycles)

    /// Wall time, in seconds, from just before the tap on a `CE-OPEN-n`
    /// title to its last body paragraph existing, polled every 50 ms (first
    /// opens and reopens, ten per arm); arm C's median must not exceed it.
    /// Frozen 2026-11-16 (step 5) from the B-only pilot below: median
    /// 0.40011 s, range 0.88179 s, so max(2 × 0.40011, 0.40011 + 2 ×
    /// 0.88179) = 2.16370 s, rounded to the millisecond. The range term
    /// dominates: CE-OPEN-3's open and reopen take about 1.2 s on SwiftUI
    /// (as in the first pilot), the others about 0.4 s.
    static let k7OpenSeconds: Double? = 2.164
    /// The B-only pilot samples `k7OpenSeconds` was computed from, seconds,
    /// in cycle order (open, reopen for CE-OPEN-1 … 5).
    static let k7PilotSamples: [Double] = [0.381, 0.386, 0.430, 0.396, 1.263, 1.182, 0.417, 0.384, 0.392, 0.404]
    /// Per expand (review F-R11, F-Q2): CE-OPEN-n's own limit, arm C's
    /// median of its open and reopen must not exceed it, beside the pooled
    /// `k7OpenSeconds`. Each is the M2 formula over that expand's two
    /// samples in `k7PilotSamples` (the same B-only pilot, no new run, so
    /// nothing was picked), rounded to the millisecond, and never looser
    /// than the pooled limit: CE-OPEN-1 max(2 × 0.3835, 0.3835 + 2 × 0.005)
    /// = 0.767; CE-OPEN-2 0.826 (median 0.413); CE-OPEN-3 2 × 1.2225 =
    /// 2.445, held to 2.164; CE-OPEN-4 0.801 (median 0.4005); CE-OPEN-5
    /// 0.796 (median 0.398). Under the pooled median alone, half of arm
    /// C's ten samples could take any time and the rest up to 2.164 s;
    /// here the median (the mean of two) of each ~0.4 s expand must stay
    /// at or under 0.826 s. Derived 2026-11-18 from the frozen samples
    /// only, after arm C had been timed under the pooled limit
    /// (`LifecycleSupportTests` recomputes them from the samples).
    static let k7OpenSecondsPerExpand: [Double] = [0.767, 0.826, 2.164, 0.801, 0.796]

    /// How the values above were derived (recorded with every K7/K8 run).
    static let provenance = "B-only pilots, 2026-11-16, step 5: Release build-for-testing of an export of b1b829c "
        + "with the step 5 patch (expands on the container allow list; app executable sha256 fe307fda…), iPhone 17 Pro "
        + "iOS 26.3 sim cadf3-tk2-stack-04-17pro-c, Scripts/lifecycle-gate.sh --skip-build --allow-other-booted "
        + "(shared host: two other simulators booted, so provisional; load average 5.5 → 3.7 for M2, 3.3 → 4.2 "
        + "for K7). M2: --only testK8, 13:17–13:21Z, five SwiftUI launches. K7: --only testK7, 13:21–13:30Z, one "
        + "SwiftUI launch, ten opens. Each replaced the uitests helper's earlier pilot of the same test (M2 0.918 s "
        + "from 0.449, 0.461, 0.460, 0.459, 0.446; K7 2.009 s from 0.383, 0.388, 0.544, 0.396, 0.884, 1.187, "
        + "0.475, 0.391, 0.407, 0.393, load average 8.5 → 27), whatever the direction, so no run was picked. "
        + "Both limits predate any arm-C timing of the tall body and of the CE-OPEN cycles. "
        + "M2 flip (A-R7): B-only pilot 2026-11-18 04:13–04:17Z, --only testK8, five SwiftUI launches, Release "
        + "build-for-testing of an export of 103993a with fixU's test changes (app executable sha256 c9675bac…), "
        + "the same simulator (other simulators booted, so provisional; load average 7.6 / 11.7 at the end); "
        + "frozen before any arm-C timing of the flip time. K7 per expand: the pooled pilot's own samples, "
        + "two per expand (no new run), derived 2026-11-18 after arm C had been timed under the pooled limit."
}
