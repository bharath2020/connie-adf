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

    /// How the values above were derived (recorded with every K7/K8 run).
    static let provenance = "B-only pilots, 2026-11-16, step 5: Release build-for-testing of an export of b1b829c "
        + "with the step 5 patch (expands on the container allow list; app executable sha256 fe307fda…), iPhone 17 Pro "
        + "iOS 26.3 sim cadf3-tk2-stack-04-17pro-c, Scripts/lifecycle-gate.sh --skip-build --allow-other-booted "
        + "(shared host: two other simulators booted, so provisional; load average 5.5 → 3.7 for M2, 3.3 → 4.2 "
        + "for K7). M2: --only testK8, 13:17–13:21Z, five SwiftUI launches. K7: --only testK7, 13:21–13:30Z, one "
        + "SwiftUI launch, ten opens. Each replaced the uitests helper's earlier pilot of the same test (M2 0.918 s "
        + "from 0.449, 0.461, 0.460, 0.459, 0.446; K7 2.009 s from 0.383, 0.388, 0.544, 0.396, 0.884, 1.187, "
        + "0.475, 0.391, 0.407, 0.393, load average 8.5 → 27), whatever the direction, so no run was picked. "
        + "Both limits predate any arm-C timing of the tall body and of the CE-OPEN cycles."
}
