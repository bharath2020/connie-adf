/// Which top-level rows are genuinely inside the viewport, fed by per-row
/// `onScrollVisibilityChange` on iOS 18+/macOS 15+. On earlier OSes nothing
/// reports, `isVisible` is always false, and search navigation always
/// scrolls (graceful degradation).
///
/// A plain class on purpose (`ScrollAnchorRegistry` pattern): rows write on
/// every visibility crossing during scroll, and those writes must invalidate
/// nothing.
@MainActor
final class VisibleRowRegistry {
    private var visible: Set<String> = []

    func setVisible(_ id: String, _ isVisible: Bool) {
        if isVisible { visible.insert(id) } else { visible.remove(id) }
    }

    func isVisible(_ id: String) -> Bool {
        visible.contains(id)
    }
}
