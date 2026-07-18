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
                  let container = scrollView.subviews.first else {
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

        /// Records the introspection outcome (which content container was the
        /// attachment target) for the assessment. Emitted only when
        /// `-selection` is set — the probe is not installed otherwise.
        static let log = Logger(subsystem: "com.connie.adfreader", category: "selection")
    }
}
#endif
