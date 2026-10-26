import Foundation
import ADFRendering

@MainActor
enum ScrollAutomation {
    /// Lands on `target` without animation: the jump runs with a
    /// zero-duration animation, which is restored once the jump has been
    /// issued. Used by `-scrollToFraction` and `RejumpHook`, where an animated
    /// jump through the lazy stack lands imprecisely (rows that materialize
    /// mid-animation replace their estimated heights).
    static func jumpWithoutAnimation(model: ADFDocumentModel, to target: String) async {
        let animation = model.scrollTargetAnimation
        model.scrollTargetAnimation = .linear(duration: 0)
        model.scrollTarget = target
        try? await Task.sleep(for: .milliseconds(100))
        model.scrollTargetAnimation = animation
    }
}
