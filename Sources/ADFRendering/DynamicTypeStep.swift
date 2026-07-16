import SwiftUI

/// Ladder arithmetic for a host-driven text-size control.
///
/// A host that wants "per-view text size" applies
/// `.dynamicTypeSize(system.shifted(by: step))` to `ADFDocumentView` — the
/// override composes with the user's accessibility setting (it shifts from
/// that baseline) instead of replacing it. All library fonts are semantic
/// styles and all metrics are `@ScaledMetric`, so the override rescales the
/// whole document without re-preparation.
public extension DynamicTypeSize {
    /// This size moved `steps` rungs along the `DynamicTypeSize` ladder,
    /// clamped at `.xSmall` and `.accessibility5`.
    func shifted(by steps: Int) -> DynamicTypeSize {
        let ladder = DynamicTypeSize.allCases
        guard let index = ladder.firstIndex(of: self) else { return self }
        // Pre-clamp `steps` itself: it can arrive from unvalidated input (a
        // launch argument, a persisted value), and `index + Int.max` traps.
        let steps = min(max(steps, -ladder.count), ladder.count)
        return ladder[min(max(index + steps, 0), ladder.count - 1)]
    }

    /// Apple's default body point size at this Dynamic Type size. The ratio
    /// between two sizes approximates how much rendered text grows — used
    /// for the collapsed-spacer estimate and the control's percentage label.
    var approximateBodyPointSize: CGFloat {
        switch self {
        case .xSmall: 14
        case .small: 15
        case .medium: 16
        case .large: 17
        case .xLarge: 19
        case .xxLarge: 21
        case .xxxLarge: 23
        case .accessibility1: 28
        case .accessibility2: 33
        case .accessibility3: 40
        case .accessibility4: 47
        case .accessibility5: 53
        @unknown default: 17
        }
    }
}
