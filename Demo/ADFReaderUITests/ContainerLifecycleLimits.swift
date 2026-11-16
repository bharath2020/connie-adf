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
    /// exceed it. Frozen 2026-11-16 from the B-only pilot below:
    /// median 0.45888 s, range 0.01516 s, so max(2 × 0.45888,
    /// 0.45888 + 2 × 0.01516) = 0.91777 s, rounded to the millisecond.
    static let m2MountSeconds: Double? = 0.918
    /// The B-only pilot samples `m2MountSeconds` was computed from, seconds
    /// (five SwiftUI launches with `-rebuildControlPicks 1`).
    static let m2PilotSamples: [Double] = [0.449, 0.461, 0.460, 0.459, 0.446]

    // MARK: K7 — CE-OPEN open time (testK7ExpandOpenCloseCycles)

    /// Wall time, in seconds, from just before the tap on a `CE-OPEN-n`
    /// title to its last body paragraph existing, polled every 50 ms (first
    /// opens and reopens, ten per arm); arm C's median must not exceed it.
    /// Frozen 2026-11-16 from the B-only pilot below: median 0.4015 s,
    /// range 0.804 s, so max(2 × 0.4015, 0.4015 + 2 × 0.804) = 2.00889 s,
    /// rounded to the millisecond. The range term dominates: the host was
    /// shared (load average 8.5 at the start, 27 at the end).
    static let k7OpenSeconds: Double? = 2.009
    /// The B-only pilot samples `k7OpenSeconds` was computed from, seconds,
    /// in cycle order (open, reopen for CE-OPEN-1 … 5).
    static let k7PilotSamples: [Double] = [0.383, 0.388, 0.544, 0.396, 0.884, 1.187, 0.475, 0.391, 0.407, 0.393]

    /// How the values above were derived (recorded with every K7/K8 run).
    static let provenance = "B-only pilots, 2026-11-16, Release build-for-testing of the worktree at e69ef0f with "
        + "step 2's then-uncommitted edits and the PR 4 UI tests (app executable sha256 d98b65fa…, no container "
        + "family enabled), iPhone 17 Pro iOS 26.3 sim cadf3-tk2-stack-04-17pro-c, Scripts/lifecycle-gate.sh "
        + "--allow-other-booted (shared host: other simulators booted, so provisional). M2: --only testK8, "
        + "02:00–02:04Z, five SwiftUI launches (a first run, timed with waitForExistence, was killed by an "
        + "outside SIGTERM in launch 2 and is not used). "
        + "K7: --only testK7, 02:34–02:44Z, one SwiftUI launch, ten opens; an earlier complete K7 pilot "
        + "(02:16–02:32Z, load average 15–17; samples 0.385, 0.386, 0.434, 0.394, 3.494, 2.095, 0.789, 0.712, "
        + "0.910, 0.418, formula 6.791 s) was superseded because the test changed after it (cycles now end "
        + "closed, footprint read as C minus B). Both limits predate any arm-C timing."
}
