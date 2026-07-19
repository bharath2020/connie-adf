import CoreGraphics

/// Drag-past-edge autoscroll for the TextKit 2 selection engine (spec §7,
/// Task 20). Split in two:
///
/// - `SelectionAutoscrollMath` — the pure, platform-agnostic core (edge
///   penetration → velocity ramp, and a clamped content-offset advance). It
///   carries no UIKit and no state, so the whole thing is exercised on the
///   macOS test lane (`SelectionAutoscrollerTests`).
/// - `SelectionAutoscroller` (iOS only, below) — the thin `CADisplayLink`
///   driver that reads the touch, computes velocity via the math, advances
///   `UIScrollView.contentOffset`, and — critically — writes
///   `model.anchors.topRow` on every step so the §8b anchors-truthfulness
///   contract holds (a programmatic scroll that forgets this reintroduces the
///   rotation teleport, `docs/Rotation-Scroll-Retention.md`).
enum SelectionAutoscrollMath {
    /// Edge band (points): how far in from the top/bottom edge autoscroll
    /// engages. ~80pt matches UIKit's own text-view autoscroll feel.
    static let defaultBand: CGFloat = 80
    /// Peak scroll velocity (points/second) at full edge penetration.
    static let defaultMaxVelocity: CGFloat = 900

    /// Signed autoscroll velocity (points/second) for a touch at `y` within a
    /// viewport of height `h`. Zero in the interior; ramps linearly toward
    /// `-maxV` as the touch penetrates the top `band` and toward `+maxV` in the
    /// bottom `band`. Penetration is clamped to `band`, so a touch dragged past
    /// the physical edge (`y < 0` or `y > h`) saturates at `±maxV` rather than
    /// overshooting. Negative = scroll toward the document start (up).
    static func velocity(
        touchY y: CGFloat,
        viewportHeight h: CGFloat,
        band: CGFloat = defaultBand,
        maxV: CGFloat = defaultMaxVelocity
    ) -> CGFloat {
        guard band > 0, h > 0 else { return 0 }
        if y < band {
            let penetration = min(band, band - y)   // clamp: y<0 saturates at maxV
            return -maxV * penetration / band
        }
        if y > h - band {
            let penetration = min(band, y - (h - band))
            return maxV * penetration / band
        }
        return 0
    }

    /// Advance `current` content-offset-Y by `dy`, clamped to the scrollable
    /// range `[0, max(0, contentHeight - viewportHeight)]`. A content shorter
    /// than the viewport pins at 0 (nothing to scroll).
    static func advancedOffsetY(
        current: CGFloat,
        dy: CGFloat,
        contentHeight: CGFloat,
        viewportHeight: CGFloat
    ) -> CGFloat {
        let maxY = max(0, contentHeight - viewportHeight)
        return min(max(0, current + dy), maxY)
    }
}

#if os(iOS)
import UIKit

/// The `CADisplayLink` driver. A link is **alive only during an active
/// edge-drag** (created lazily by `update` when velocity becomes non-zero, torn
/// down the instant the touch leaves the edge band or the drag ends) — zero
/// per-frame work otherwise. Its owner (`SelectionController`) feeds it the
/// touch's Y-in-viewport on every handle-drag move and supplies the two
/// injected closures that bridge it to the document: `topRowProvider` (which
/// top-level row now sits at the viewport top) and `onScrollStep` (the
/// `model.anchors.topRow` write, §8b).
@MainActor
final class SelectionAutoscroller {
    private weak var scrollView: UIScrollView?
    private var link: CADisplayLink?
    private var velocity: CGFloat = 0

    /// `contentOffsetY` → the top-level block ID whose row now sits at the
    /// viewport top (or nil). Injected by the controller; a bounded binary
    /// search over the live-row registry, never an all-registered scan.
    var topRowProvider: (CGFloat) -> String? = { _ in nil }
    /// Writes `model.anchors.topRow` (§8b). Injected by the controller; a plain
    /// reference-box write that invalidates no view.
    var onScrollStep: (String?) -> Void = { _ in }

    init(scrollView: UIScrollView) { self.scrollView = scrollView }

    /// True while the display link is alive — used by tests/self-check only.
    var isRunning: Bool { link != nil }

    /// Fed on every handle-drag touch-move with the touch's Y in the scroll
    /// view's *viewport* (0 = visible top, `h` = visible bottom). Starts the
    /// link when the touch enters an edge band, stops it when it returns to the
    /// interior.
    func update(touchYInBounds y: CGFloat, viewportHeight h: CGFloat) {
        velocity = SelectionAutoscrollMath.velocity(touchY: y, viewportHeight: h)
        if velocity == 0 { stop() } else { start() }
    }

    /// Tears the link down and zeroes velocity. Idempotent; called when the
    /// touch leaves the band, when the drag ends, and on session teardown.
    ///
    /// If a scroll actually happened, it re-asserts `anchors.topRow` across a
    /// short settle window: the SwiftUI lazy stack does not materialize the
    /// newly-visible rows *during* a direct-`contentOffset` burst (the geometry
    /// registry only catches up once the run loop is free after the link is
    /// gone), so the mid-burst per-step writes can lag the true top row. Re-
    /// reading once the registry has settled makes the anchor truthful AFTER
    /// the drag (§8b), which is the contract the next rotation depends on.
    /// These are plain reference-box writes (no scroll, no observable state),
    /// so they neither fight `reassertAnchor`/`PendingRepins` nor a user scroll
    /// that may have started in the window — each reads the live offset.
    func stop() {
        let wasScrolling = link != nil && didScroll
        link?.invalidate()
        link = nil
        velocity = 0
        didScroll = false
        guard wasScrolling else { return }
        for delay in Self.settleAnchorDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let sv = self.scrollView else { return }
                self.onScrollStep(self.topRowProvider(sv.contentOffset.y))
            }
        }
    }

    /// Whether `step` moved the content offset at least once since the link
    /// started — gates the post-drag settle re-assertion.
    private var didScroll = false
    private static let settleAnchorDelays: [TimeInterval] = [0, 0.12, 0.3]

    private func start() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(step))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let sv = scrollView, velocity != 0 else { stop(); return }
        let dy = velocity * CGFloat(link.targetTimestamp - link.timestamp)
        let newY = SelectionAutoscrollMath.advancedOffsetY(
            current: sv.contentOffset.y,
            dy: dy,
            contentHeight: sv.contentSize.height,
            viewportHeight: sv.bounds.height
        )
        // Fully clamped at an edge: the content isn't moving, so the top row is
        // unchanged — skip the redundant offset set and the anchor write. (The
        // link stays alive so a subsequent finger move back into range resumes
        // immediately; it does no observable work here.)
        guard newY != sv.contentOffset.y else { return }
        sv.contentOffset.y = newY
        didScroll = true
        onScrollStep(topRowProvider(newY))   // §8b: keep anchors.topRow truthful
    }
}
#endif
