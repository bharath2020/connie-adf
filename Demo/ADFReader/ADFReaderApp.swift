import SwiftUI
import UIKit

/// Launch-argument protocol (consumed by the Task 7 automation harness):
/// - `-fixture <name>` opens that fixture's reader directly on launch
///   (name without the `.json` extension).
/// - `-scrollToFraction <f>` scrolls, once the document is ready, to the
///   block at fraction `f` of `model.blocks` (animated, then re-jumped
///   without animation ~1.5 s after ready so the landing is exact).
/// - `-autoscroll` waits 1s after ready, animates through the entire
///   document at ~1,200 pt/s while frame metrics run, prints one
///   `SCROLL_METRICS …` line (main's fields, then `startRow= endRow=
///   scrollMs= completed=`), then exits after 2s.
/// - `-searchQuery <text>` runs a settled find-in-page query after loading.
/// - `-searchUpdates <n>` measures `n` replacements while that query is active.
/// - `-fontSizeStep <n>` opens the reader with the text-size control at
///   step `n` (ladder steps relative to the system size), bypassing the
///   persisted per-document value — so perf gates can run at large sizes.
/// - `-textkit2` sets the persisted renderer choice (`adf.textkit2.enabled`)
///   to TextKit 2 before the first view reads it. The toolbar switch still
///   works afterwards. TextKit 2 is off unless this flag or the toolbar says
///   otherwise.
/// - `-rendererReset` removes that key first, so a UI test always starts on
///   SwiftUI regardless of what a previous run left behind. With both flags
///   the reset applies first, then `-textkit2`.
/// - `-rendererStats` prints one `RENDERER_STATS …` line (active renderer,
///   live/cumulative TextKit 2 row counters, eligible/fallback roots) right
///   after READY and again right after `SCROLL_METRICS` — the perf gate's
///   proof of which engine drew (see `RendererStats`).
/// - `-switchDuringLoad` flips the renderer to TextKit 2 when the first
///   streamed chunk arrives (the document is still loading), prints
///   `SWITCH_DURING_LOAD blocks=<n>` and shows `<n>` in About This Build —
///   the lifecycle gate's "switch during a streaming load" check.
///
/// Also part of the harness: posting the Darwin notification
/// `com.connie.adfreader.rotate` (see `RotationHook`) toggles
/// portrait/landscape without the Simulator UI, and
/// `com.connie.adfreader.rejump` (see `RejumpHook`) re-lands on the
/// `-scrollToFraction` block without animation.
struct LaunchOptions: Sendable {
    var fixtureName: String?
    var scrollToFraction: Double?
    var autoscroll = false
    var searchQuery: String?
    var searchUpdates = 0
    var fontSizeStep: Int?
    var textKit2 = false
    var rendererReset = false
    var rendererStats = false
    var switchDuringLoad = false

    static let none = LaunchOptions(arguments: [])

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        var index = arguments.startIndex
        while index < arguments.endIndex {
            switch arguments[index] {
            case "-fixture" where arguments.index(after: index) < arguments.endIndex:
                index = arguments.index(after: index)
                fixtureName = arguments[index]
            case "-scrollToFraction" where arguments.index(after: index) < arguments.endIndex:
                index = arguments.index(after: index)
                scrollToFraction = Double(arguments[index])
            case "-autoscroll":
                autoscroll = true
            case "-searchQuery" where arguments.index(after: index) < arguments.endIndex:
                index = arguments.index(after: index)
                searchQuery = arguments[index]
            case "-searchUpdates" where arguments.index(after: index) < arguments.endIndex:
                index = arguments.index(after: index)
                searchUpdates = max(Int(arguments[index]) ?? 0, 0)
            case "-fontSizeStep" where arguments.index(after: index) < arguments.endIndex:
                index = arguments.index(after: index)
                fontSizeStep = Int(arguments[index])
            case "-textkit2":
                textKit2 = true
            case "-rendererReset":
                rendererReset = true
            case "-rendererStats":
                rendererStats = true
            case "-switchDuringLoad":
                switchDuringLoad = true
            default:
                break
            }
            index = arguments.index(after: index)
        }
    }
}

@main
struct ADFReaderApp: App {
    private let options = LaunchOptions()

    init() {
        // Before the scene builds: `ReaderView` reads the renderer key through
        // `@AppStorage`, which must see the launch-argument override.
        RendererPreference.apply(options)
        RotationHook.install()
        RejumpHook.install()
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                if let name = options.fixtureName {
                    if let fixture = Fixture(named: name) {
                        ReaderView(source: .fixture(fixture), options: options)
                    } else {
                        ContentUnavailableView(
                            "Fixture Not Found",
                            systemImage: "doc.questionmark",
                            description: Text("No bundled fixture named \u{201C}\(name).json\u{201D}.")
                        )
                    }
                } else {
                    SpaceListView()
                }
            }
        }
    }
}

/// Rotates the app from the command line:
/// `xcrun simctl spawn <udid> notifyutil -p com.connie.adfreader.rotate`
/// toggles portrait/landscape through `UIWindowScene.requestGeometryUpdate` —
/// the same scene-geometry path a device rotation takes. Exists because the
/// Simulator's Device > Rotate menu needs a focused device window, which an
/// agent driving a headless simulator (or sharing the Mac with an active
/// user) cannot reliably obtain.
enum RotationHook {
    static func install() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                Task { @MainActor in RotationHook.toggle() }
            },
            "com.connie.adfreader.rotate" as CFString,
            nil,
            .deliverImmediately
        )
    }

    @MainActor
    private static func toggle() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else { return }
        let target: UIInterfaceOrientationMask =
            scene.interfaceOrientation.isLandscape ? .portrait : .landscapeRight
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: target)) { error in
            print("ROTATION failed: \(error)")
        }
        print("ROTATION requested=\(target == .portrait ? "portrait" : "landscapeRight")")
    }
}

/// Re-lands the open reader on its `-scrollToFraction` block, without
/// animation: `xcrun simctl spawn <udid> notifyutil -p com.connie.adfreader.rejump`.
/// The lifecycle gate's deterministic way back to a parked position — a
/// drag round trip does not return exactly in a lazy stack, whose estimated
/// row heights change as rows materialize.
enum RejumpHook {
    static let notification = Notification.Name("ADFReaderRejump")

    static func install() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                Task { @MainActor in NotificationCenter.default.post(name: RejumpHook.notification, object: nil) }
            },
            "com.connie.adfreader.rejump" as CFString,
            nil,
            .deliverImmediately
        )
    }
}
