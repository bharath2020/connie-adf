import Foundation

/// Automation-only record of `-switchDuringLoad`: how many top-level blocks
/// had streamed in when the renderer flipped to TextKit 2, and how many the
/// document held when it became ready afterwards (`nil` until then).
@MainActor
enum LoadSwitchProbe {
    static var blocksAtSwitch: Int?
    static var blocksAtReady: Int?
}

/// The persisted text-renderer choice shared by `ReaderView`'s `@AppStorage`
/// toggle and the launch-argument overrides. TextKit 2 is opt-in: a missing
/// key means SwiftUI.
enum RendererPreference {
    static let key = "adf.textkit2.enabled"
    /// Set while `key` holds a value automation wrote (`-textkit2`,
    /// `-switchDuringLoad`) rather than a toolbar pick.
    static let automationKey = "adf.textkit2.setByAutomation"

    /// Applies `-rendererReset` and then `-textkit2` to the standard defaults.
    /// Runs from `ADFReaderApp.init`, before any view reads the key.
    ///
    /// `-textkit2` writes `true` to the persistent domain, so it wins over
    /// any value a previous run left there (a registered default would not:
    /// a persisted `false` from an earlier SwiftUI pick outranks it). The
    /// write is marked as automation's, and the next launch without the
    /// flag removes it, so a manual launch after a `-textkit2` run starts on
    /// SwiftUI instead of inheriting the automation's choice. A toolbar pick
    /// clears the mark (`userChose()`) and persists as it always did.
    ///
    /// The flags are deliberately *not* spelled like the defaults key: iOS
    /// mirrors every `-key value` launch argument into `NSArgumentDomain`,
    /// which shadows the persistent domain for the life of the process — a
    /// key seeded that way could never be flipped from inside the app.
    static func apply(_ options: LaunchOptions, to defaults: UserDefaults = .standard) {
        if options.rendererReset || (!options.textKit2 && defaults.bool(forKey: automationKey)) {
            defaults.removeObject(forKey: key)
            defaults.removeObject(forKey: automationKey)
        }
        if options.textKit2 {
            defaults.set(true, forKey: key)
            defaults.set(true, forKey: automationKey)
        }
    }

    /// Marks the current value as automation's (`-switchDuringLoad`), so the
    /// next launch without a renderer flag starts on SwiftUI.
    static func markSetByAutomation(_ defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: automationKey)
    }

    /// A toolbar pick: the choice is the user's and persists.
    static func userChose(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: automationKey)
    }
}

/// `-rebuildControlPicks <n>` (the lifecycle gate's memory control): the
/// first `n` picks of TextKit 2 in the renderer menu rebuild the rows a
/// TextKit 2 switch would swap as plain SwiftUI instead
/// (`View.adfRebuildControl`); later picks are real TextKit 2. The
/// control so goes through the same menu, About sheet and accessibility
/// traffic as the switches it is compared with. With the flag (any `n`)
/// About This Build and `RENDERER_STATS` show the control's row counts.
@MainActor
enum RebuildControl {
    static var configured = false
    static var picksLeft = 0

    /// Called as the menu picks TextKit 2: whether this pick is a control
    /// pick.
    static func takePick() -> Bool {
        defer { picksLeft = max(picksLeft - 1, 0) }
        return picksLeft > 0
    }
}
