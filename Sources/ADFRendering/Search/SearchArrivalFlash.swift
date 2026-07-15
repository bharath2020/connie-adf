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

    /// With no active session this reads ONE observable Bool (`isActive`)
    /// and skips `highlights` entirely — the leaf re-registers for
    /// `highlights.current` the moment a session starts, so navigation still
    /// re-evaluates the ownership branch below.
    private var trigger: Trigger {
        guard let search, search.isActive, let ownerID else {
            return Trigger(generation: 0, isCurrentOwner: false)
        }
        let current = search.highlights.current
        return Trigger(
            generation: current?.generation ?? 0,
            isCurrentOwner: current?.ownerID == ownerID
        )
    }

    /// The flash task attaches ONLY to the current match's owner, so the
    /// other leaves never pay a task spawn + cancel per materialization
    /// (idle-scroll hygiene; measured harmless but pure waste). The branch
    /// lives INSIDE this modifier's body on purpose — resolved in the
    /// modifier's own subgraph, it leaves the leaf's outer view type unary
    /// and stable (see `ScrollVisibilityReporter` for the trap this avoids).
    /// The `trigger` computation above reads the observable search state, so
    /// a navigation re-evaluates the branch here; the identity flip when
    /// ownership moves is fine — a fresh flash starts anyway, and `runFlash`
    /// resets the dimmed phase first.
    func body(content: Content) -> some View {
        if trigger.isCurrentOwner {
            content.task(id: trigger) { await runFlash() }
        } else {
            content
        }
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
