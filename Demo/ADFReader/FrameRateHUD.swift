import QuartzCore
import SwiftUI

/// Frame pacing metrics driven by a `CADisplayLink` on the main run loop.
///
/// A frame counts as **dropped** when its measured duration (delta between
/// consecutive link callbacks) exceeds 1.5× the expected duration the link
/// reported for the previous frame (`targetTimestamp - timestamp`); the
/// excess over the expected duration accumulates as hitch time.
///
/// Raw counters live in `@ObservationIgnored` storage and are published to
/// the observable display properties at ~4 Hz, so the HUD itself doesn't
/// invalidate SwiftUI once per frame.
@MainActor @Observable
final class FrameMetrics {
    struct Snapshot: Sendable {
        var totalFrames: Int
        var droppedFrames: Int
        var hitchMilliseconds: Double
        var elapsedSeconds: Double
    }

    private(set) var currentFPS: Double = 0
    private(set) var totalFrames = 0
    private(set) var droppedFrames = 0

    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var lastTimestamp: CFTimeInterval?
    @ObservationIgnored private var lastExpectedDuration: CFTimeInterval?
    @ObservationIgnored private var firstTimestamp: CFTimeInterval?
    @ObservationIgnored private var latestTimestamp: CFTimeInterval?
    @ObservationIgnored private var frames = 0
    @ObservationIgnored private var dropped = 0
    @ObservationIgnored private var hitchMilliseconds: Double = 0
    @ObservationIgnored private var windowStart: CFTimeInterval?
    @ObservationIgnored private var windowFrames = 0

    func start() {
        guard displayLink == nil else { return }
        let target = DisplayLinkTarget { [weak self] link in
            self?.step(link)
        }
        let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.fire(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
        lastExpectedDuration = nil
        windowStart = nil
        windowFrames = 0
    }

    /// Zeroes all counters (the link, if running, keeps ticking).
    func reset() {
        lastTimestamp = nil
        lastExpectedDuration = nil
        firstTimestamp = nil
        latestTimestamp = nil
        frames = 0
        dropped = 0
        hitchMilliseconds = 0
        windowStart = nil
        windowFrames = 0
        totalFrames = 0
        droppedFrames = 0
        currentFPS = 0
    }

    func snapshot() -> Snapshot {
        var elapsed: Double = 0
        if let firstTimestamp, let latestTimestamp, latestTimestamp > firstTimestamp {
            elapsed = latestTimestamp - firstTimestamp
        }
        return Snapshot(
            totalFrames: frames,
            droppedFrames: dropped,
            hitchMilliseconds: hitchMilliseconds,
            elapsedSeconds: elapsed
        )
    }

    private func step(_ link: CADisplayLink) {
        defer {
            lastTimestamp = link.timestamp
            lastExpectedDuration = link.targetTimestamp - link.timestamp
        }
        guard let lastTimestamp, let lastExpectedDuration, lastExpectedDuration > 0 else {
            // First tick after start/reset: only baselines are recorded.
            if firstTimestamp == nil {
                firstTimestamp = link.timestamp
            }
            windowStart = link.timestamp
            windowFrames = 0
            return
        }
        latestTimestamp = link.timestamp
        let actual = link.timestamp - lastTimestamp
        frames += 1
        windowFrames += 1
        if actual > lastExpectedDuration * 1.5 {
            dropped += 1
            hitchMilliseconds += (actual - lastExpectedDuration) * 1_000
        }
        if let windowStart, link.timestamp - windowStart >= 0.25 {
            currentFPS = Double(windowFrames) / (link.timestamp - windowStart)
            totalFrames = frames
            droppedFrames = dropped
            self.windowStart = link.timestamp
            windowFrames = 0
        }
    }
}

/// `CADisplayLink` retains its target, so the metrics object hands it this
/// small forwarder that captures the metrics weakly — `stop()` breaks the
/// only strong reference by invalidating the link.
@MainActor
private final class DisplayLinkTarget: NSObject {
    private let handler: (CADisplayLink) -> Void

    init(handler: @escaping (CADisplayLink) -> Void) {
        self.handler = handler
        super.init()
    }

    @objc func fire(_ link: CADisplayLink) {
        handler(link)
    }
}

/// Compact always-on-top overlay showing live frame pacing.
struct FrameRateHUD: View {
    let metrics: FrameMetrics

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(metrics.currentFPS, format: .number.precision(.fractionLength(0))) fps")
                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
            Text("\(metrics.totalFrames) frames \u{00B7} \(metrics.droppedFrames) dropped")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
