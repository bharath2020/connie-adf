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

    /// Applies `-rendererReset` and then `-textkit2` to the standard defaults.
    /// Runs from `ADFReaderApp.init`, before any view reads the key.
    ///
    /// `-textkit2` clears any persisted choice and registers `true` in the
    /// registration domain, which lives only as long as the process: the
    /// toolbar switch still flips it (its write lands in the persistent
    /// domain, which wins), and a later launch without the flag starts on
    /// SwiftUI again instead of inheriting the automation's choice.
    ///
    /// The flags are deliberately *not* spelled like the defaults key: iOS
    /// mirrors every `-key value` launch argument into `NSArgumentDomain`,
    /// which shadows the persistent domain for the life of the process — a
    /// key seeded that way could never be flipped from inside the app.
    static func apply(_ options: LaunchOptions, to defaults: UserDefaults = .standard) {
        if options.rendererReset {
            defaults.removeObject(forKey: key)
        }
        if options.textKit2 {
            defaults.removeObject(forKey: key)
            defaults.register(defaults: [key: true])
        }
    }
}
