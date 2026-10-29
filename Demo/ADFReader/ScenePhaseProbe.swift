import SwiftUI

/// The `-scenePhaseProbe` overlay (lifecycle gate only): counts the scene's
/// own phase transitions and shows them as
///
///     background=<n> inactive=<n> active=<n> last=<background|inactive|active>
///
/// under the accessibility identifier `scene-phase-probe`. The thrash check
/// reads it after each stop to prove Home, lock and the app switcher took the
/// app out of the foreground: `XCUIApplication.state` keeps reporting
/// `runningForeground` through all three on the simulator, even while the
/// screenshot shows the Home screen. Counts only grow, so a reading taken
/// after the app is back still shows that it left. Never touches the
/// document view, and is absent without the flag.
struct ScenePhaseProbe: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var counts = Counts()

    var body: some View {
        Text(verbatim: counts.label)
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(4)
            .allowsHitTesting(false)
            .accessibilityIdentifier("scene-phase-probe")
            .onChange(of: scenePhase, initial: true) { _, phase in
                counts.record(phase)
            }
    }

    struct Counts {
        var background = 0
        var inactive = 0
        var active = 0
        var last = "none"

        mutating func record(_ phase: ScenePhase) {
            switch phase {
            case .background:
                background += 1
                last = "background"
            case .inactive:
                inactive += 1
                last = "inactive"
            case .active:
                active += 1
                last = "active"
            @unknown default:
                last = "unknown"
            }
        }

        var label: String {
            "background=\(background) inactive=\(inactive) active=\(active) last=\(last)"
        }
    }
}
