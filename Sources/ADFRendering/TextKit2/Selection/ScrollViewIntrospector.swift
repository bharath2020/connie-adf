#if os(iOS)
import SwiftUI
import UIKit
import os

/// Finds SwiftUI's underlying `UIScrollView` and attaches the selection
/// controller to its content container (an ANCESTOR of every rendered row),
/// so descendant gestures keep native behavior and content-space geometry
/// scrolls for free (spec §7 feasibility question #1). No `hitTest` override.
///
/// **Placement matters (Task-16 finding):** this probe MUST be hosted inside
/// the scroll *content* (a `.background` on the row stack), NOT on the
/// `ScrollView` itself. A `.background` on the `ScrollView` is hosted in a
/// separate `PlatformViewHost` whose `superview` chain never passes through
/// the underlying `UIScrollView` (it runs straight up to the `NavigationStack`
/// host and the window), so the upward walk below finds no scroll view.
/// Hosted inside the content, the probe is a genuine descendant of the
/// `HostingScrollView` and the walk reaches it on the first laid-out frame.
struct ScrollViewIntrospector: UIViewRepresentable {
    let controller: SelectionController

    func makeUIView(context: Context) -> ProbeView { ProbeView(controller: controller) }
    func updateUIView(_ view: ProbeView, context: Context) { view.controller = controller }

    final class ProbeView: UIView {
        var controller: SelectionController
        private weak var attachedContainer: UIView?
        private var attempts = 0

        init(controller: SelectionController) {
            self.controller = controller
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isHidden = true
        }
        required init?(coder: NSCoder) { fatalError("unused") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            // Defer one runloop turn: on first `didMoveToWindow` the SwiftUI
            // scroll view may not yet have laid out its content subview.
            attempts = 0
            DispatchQueue.main.async { [weak self] in self?.attachIfPossible() }
        }

        /// Walks `superview` upward to the first enclosing `UIScrollView`, then
        /// takes its first content subview as the interaction host. Retries a
        /// bounded number of times because the SwiftUI scroll view and its
        /// content container are not always laid out one runloop turn after the
        /// probe enters the window.
        private func attachIfPossible() {
            guard attachedContainer == nil else { return }
            attempts += 1
            var v: UIView? = superview
            while let current = v, !(current is UIScrollView) { v = current.superview }
            guard let scrollView = v as? UIScrollView,
                  let container = Self.contentContainer(in: scrollView) else {
                if attempts < 12 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.attachIfPossible()
                    }
                } else {
                    Self.log.log("gave up after \(self.attempts, privacy: .public) attempts — no UIScrollView ancestor / content container")
                }
                return
            }
            controller.attach(to: container, scrollView: scrollView)
            attachedContainer = container
            Self.log.log("attached on attempt \(self.attempts, privacy: .public): scrollView=\(String(describing: type(of: scrollView)), privacy: .public) container=\(String(describing: type(of: container)), privacy: .public)")
        }

        /// The scroll view's genuine **content container** — the ancestor of
        /// the laid-out rows the overlay + gesture recognizers must attach to.
        ///
        /// It is NOT reliably `subviews.first`: iOS 26's SwiftUI inserts a
        /// `_UITouchPassthroughView` shim as the first (and last) scroll subview
        /// — `subviews == [_UITouchPassthroughView, PlatformGroupContainer,
        /// _UITouchPassthroughView, _UIScrollViewScrollIndicator]` — so
        /// `subviews.first` lands on a passthrough shim that is not an ancestor
        /// of any row, and a long-press recognizer there never fires (on iOS
        /// 18 the content group WAS `subviews.first`, which is why Tasks 16b/19
        /// passed). Pick, in order: the subview that already hosts a
        /// `TextKit2RowUIView` (definitive once content is laid out); else the
        /// first subview that is neither a scroll indicator nor a touch-
        /// passthrough shim (works before rows materialize); else `subviews
        /// .first` (last-resort, preserves the pre-iOS-26 behavior).
        static func contentContainer(in scrollView: UIScrollView) -> UIView? {
            if let withRows = scrollView.subviews.first(where: hostsTK2Row) { return withRows }
            let content = scrollView.subviews.first { sv in
                let name = String(describing: type(of: sv))
                return name != "_UIScrollViewScrollIndicator" && !name.contains("TouchPassthrough")
            }
            return content ?? scrollView.subviews.first
        }

        private static func hostsTK2Row(_ view: UIView) -> Bool {
            if view is TextKit2RowUIView { return true }
            return view.subviews.contains(where: hostsTK2Row)
        }

        /// Records the introspection outcome (which content container was the
        /// attachment target) for the assessment. Emitted only when
        /// `-selection` is set — the probe is not installed otherwise.
        static let log = Logger(subsystem: "com.connie.adfreader", category: "selection")
    }
}
#endif
