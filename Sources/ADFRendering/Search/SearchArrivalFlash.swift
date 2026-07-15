import SwiftUI

/// Pulses the current search match's accent highlight on arrival: two
/// accent→subtle blinks (~130 ms steps) driven off the navigation
/// generation, steady accent under Reduce Motion. The pulse phase is
/// delivered to the content via `dimmed` so the view can swap which theme
/// token it paints with — attribute colors can't animate, so the flash is
/// a discrete toggle by design.
struct SearchArrivalFlash: ViewModifier {
    let ownerID: String?
    let dimmed: Binding<Bool>

    @Environment(\.adfDocumentSearch) private var search
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Trigger: Equatable {
        let generation: Int
        let isCurrentOwner: Bool
    }

    private var trigger: Trigger {
        let current = search?.highlights.current
        return Trigger(
            generation: current?.generation ?? 0,
            isCurrentOwner: ownerID != nil && current?.ownerID == ownerID
        )
    }

    func body(content: Content) -> some View {
        content.task(id: trigger) { await runFlash() }
    }

    /// Runs when this view holds the current match after a navigation —
    /// including when the row only materializes after the scroll lands
    /// (flash on arrival).
    private func runFlash() async {
        dimmed.wrappedValue = false
        guard trigger.isCurrentOwner, trigger.generation > 0, !reduceMotion else { return }
        for _ in 0..<2 {
            try? await Task.sleep(for: .milliseconds(130))
            guard !Task.isCancelled else { return }
            dimmed.wrappedValue = true
            try? await Task.sleep(for: .milliseconds(130))
            guard !Task.isCancelled else { return }
            dimmed.wrappedValue = false
        }
    }
}

extension View {
    /// Applies the search arrival flash for the given highlight owner,
    /// writing the pulse's off-phase into `dimmed`.
    func searchArrivalFlash(ownerID: String?, dimmed: Binding<Bool>) -> some View {
        modifier(SearchArrivalFlash(ownerID: ownerID, dimmed: dimmed))
    }
}
