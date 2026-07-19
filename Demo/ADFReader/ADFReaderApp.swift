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
/// - `-searchQuery <text>` runs a settled find-in-page query after loading.
/// - `-searchUpdates <n>` measures `n` replacements while that query is active.
/// - `-fontSizeStep <n>` opens the reader with the text-size control at
///   step `n` (ladder steps relative to the system size), bypassing the
///   persisted per-document value — so perf gates can run at large sizes.
/// - `-selectionSpike` shows `SpikeScreen`, a throwaway feasibility spike for
///   the TextKit 2 port assessment (spec §11) — not production UI.
/// - `-mutateDelay <seconds>` (Task 22 verification): once ready, waits
///   `<seconds>` then applies ONE `.replace` mutation (via `model.apply`) to
///   a mid-document paragraph — an on-demand document-epoch bump, timed so an
///   operator can hold a selection session (long-press) before it lands. See
///   `MutationAutomation`. Does not exit or navigate.
/// - `-toggleExpandDelay <seconds>` (Task 22 verification): once ready,
///   waits `<seconds>` then toggles the first `.expand` block's open/closed
///   state directly on `model.expandedBlocks` (bypassing the SwiftUI
///   `Button` — see `MutationAutomation.toggleFirstExpand`'s deviation
///   note), timed so an operator can hold a selection on text below the
///   expand before it lands. Does not exit or navigate.
/// - `-textkit2` renders text leaves (paragraphs, headings, code blocks) with
///   the TextKit 2 pipeline instead of SwiftUI `Text` (A/B assessment). Read
///   once at launch by `TextKit2Flags`, not parsed into `LaunchOptions`. The
///   reader toolbar's "TextKit 2 Renderer" toggle persists the same choice
///   to `UserDefaults` under `TextKit2Flags.defaultsKey`
///   (`"adf.textkit2.enabled"`) for device builds without launch args; the
///   launch arg still wins, and either way the change applies on relaunch.
/// - `-textkit2NoCells` (with `-textkit2`) keeps table-cell text on the
///   SwiftUI path — the giant-table gate fallback.
/// - The phase-4 read-only selection engine (v3, Task 16b) installs
///   automatically wherever TK2 rendering is on — `TextKit2Flags.enabled`,
///   whether set by `-textkit2` or the persisted in-app toggle — with no
///   separate launch arg required (Task 28b: a TestFlight build can't pass
///   launch args, so gating selection behind a literal `-selection` arg
///   made it invisible outside `-textkit2 -selection` automation runs). It
///   is a transparent, session-scoped overlay added to the introspected
///   document scroll view's content container. The overlay is itself the
///   `UITextInput` and hosts `UITextInteraction(.nonEditable)` +
///   `UITextSelectionDisplayInteraction` + `UIEditMenuInteraction`; a
///   container long-press starts a selection session over the real TK2
///   rows. Read once at launch by `SelectionFlags`, not parsed into
///   `LaunchOptions` (same pattern as `-textkit2`).
/// - `-noSelection` (with `-textkit2`) is the A/B/automation escape hatch:
///   TK2 renders, but the selection overlay above is withheld.
/// - `-selection` is still accepted for backward compatibility with
///   existing scripts but is a no-op — it is not read anywhere; selection
///   no longer needs it.
///
/// Also part of the harness: posting the Darwin notification
/// `com.connie.adfreader.rotate` (see `RotationHook`) toggles
/// portrait/landscape without the Simulator UI.
struct LaunchOptions: Sendable {
    var fixtureName: String?
    var scrollToFraction: Double?
    var autoscroll = false
    var searchQuery: String?
    var searchUpdates = 0
    var fontSizeStep: Int?
    var selectionSpike = false
    var mutateDelay: Double?
    var toggleExpandDelay: Double?

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
            case "-selectionSpike":
                selectionSpike = true
            case "-mutateDelay" where arguments.index(after: index) < arguments.endIndex:
                index = arguments.index(after: index)
                mutateDelay = Double(arguments[index])
            case "-toggleExpandDelay" where arguments.index(after: index) < arguments.endIndex:
                index = arguments.index(after: index)
                toggleExpandDelay = Double(arguments[index])
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
                if options.selectionSpike {
                    SpikeScreen().ignoresSafeArea()
                } else if let name = options.fixtureName {
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
