import SwiftUI
import UIKit

/// Launch-argument protocol (consumed by the Task 7 automation harness):
/// - `-fixture <name>` opens that fixture's reader directly on launch
///   (name without the `.json` extension).
/// - `-scrollToFraction <f>` scrolls, once the document is ready, to the
///   block at fraction `f` of `model.blocks`.
/// - `-autoscroll` waits 1s after ready, animates through the entire
///   document at ~1,200 pt/s while frame metrics run, prints one
///   `SCROLL_METRICS …` line, then exits after 2s.
///
/// Also part of the harness: posting the Darwin notification
/// `com.connie.adfreader.rotate` (see `RotationHook`) toggles
/// portrait/landscape without the Simulator UI.
struct LaunchOptions: Sendable {
    var fixtureName: String?
    var scrollToFraction: Double?
    var autoscroll = false

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
        RotationHook.install()
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
