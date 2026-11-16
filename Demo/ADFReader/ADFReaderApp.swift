import SwiftUI
import UIKit

/// Launch-argument protocol (consumed by the Task 7 automation harness):
/// - `-fixture <name>` opens that fixture's reader directly on launch
///   (name without the `.json` extension).
/// - `-scrollToFraction <f>` scrolls, once the document is ready, to the
///   block at fraction `f` of `model.blocks` (animated, then re-jumped
///   without animation ~1.5 s after ready so the landing is exact). About
///   1 s after the re-jump (about 2.6 s after READY), once per launch, it
///   prints these lines together, in this order:
///
///       SCROLL_LANDED fixture=<name> fraction=<f> index=<i> block=<id> blocks=<n>
///       RENDERER_STATS …
///       TK2_CODE_ROWS live=<n> owners=<id>:<draws>[,<id>:<draws>…]
///
///   `SCROLL_LANDED` names the block the jump went to (`block=`, the
///   `RenderBlock.id` at `index=` of `blocks=`: the jump's target, not a
///   measured position; `-captureGeometryHook` measures it) and is printed
///   with or without `-rendererStats`; the other two only with it. `RENDERER_STATS` is the READY line's keys
///   with fresh values (the stats printed at READY predate the jump).
///   `TK2_CODE_ROWS` lists each live TextKit 2 row drawing a code block's
///   code by owner, with its native draw passes; with none it is
///   `TK2_CODE_ROWS live=0 owners=-`. `Scripts/visual_diff.py` reads the
///   three as a capture's engine proof, so a capture must wait for them
///   (see `RendererStats` and `ReaderView.scrollToFraction`).
/// - `-autoscroll` waits 3s after ready, animates through the entire
///   document at ~1,200 pt/s while frame metrics run, prints one
///   `SCROLL_METRICS …` line (main's fields, then `startRow= endRow=
///   scrollMs= completed=`), then exits after 2s.
/// - `-searchQuery <text>` runs a settled find-in-page query after loading.
/// - `-searchUpdates <n>` measures `n` replacements while that query is active.
/// - `-fontSizeStep <n>` opens the reader with the text-size control at
///   step `n` (ladder steps relative to the system size), bypassing the
///   persisted per-document value — so perf gates can run at large sizes.
/// - `-textkit2` starts this launch on TextKit 2, whatever a previous run
///   persisted: it writes the renderer choice (`adf.textkit2.enabled`)
///   before the first view reads it, marked as automation's, and the next
///   launch without the flag removes it again, so that launch starts on
///   SwiftUI. The toolbar switch still works (and persists, as it always
///   does).
/// - `-rendererReset` removes that key first, so a UI test always starts on
///   SwiftUI regardless of what a previous run left behind. With both flags
///   the reset applies first, then `-textkit2`.
/// - `-rendererStats` prints one `RENDERER_STATS …` line (active renderer,
///   live/cumulative TextKit 2 row counters, coverage counts) right
///   after READY and again right after `SCROLL_METRICS` — the perf gate's
///   proof of which engine drew (see `RendererStats`) — and, after a
///   `-scrollToFraction` jump, once more between `SCROLL_LANDED` and
///   `TK2_CODE_ROWS` (above). Since the code-block stage the line carries
///   six code keys, after `listTrailingLeaves=` and before the optional
///   rebuild-control keys, on both arms:
///
///       tk2CodeLive=<n> tk2CodeDraws=<n> eligibleCodeRoots=<n>
///       fallbackCodeRoots=<n> codeAdmitted=<n> codeGated=<n>
///
///   `tk2CodeLive` counts the live TextKit 2 rows drawing a code block's
///   code and `tk2CodeDraws` their native draw passes since launch (the
///   code-native proof). `eligibleCodeRoots` / `fallbackCodeRoots` split
///   the top-level code blocks by content (static). `codeAdmitted` /
///   `codeGated` are measured: of the eligible ones, how many TextKit 2
///   would draw, and how many a view-time rule keeps on SwiftUI, at this
///   launch's text size, legibility weight, display scale and layout
///   direction; the two sum to `eligibleCodeRoots`.
/// - `-switchDuringLoad` flips the renderer to TextKit 2 when the first
///   streamed chunk arrives (the document is still loading) the way the
///   toolbar does, marked as automation's like `-textkit2` (the next launch
///   without a flag starts on SwiftUI); prints
///   `SWITCH_DURING_LOAD blocks=<n>` and shows `<n>` in About This Build —
///   the lifecycle gate's "switch during a streaming load" check.
/// - `-memoryReliefHook` installs `MemoryReliefHook` (lifecycle gate only).
/// - `-rebuildControlPicks <n>`: the first `n` menu picks of TextKit 2
///   rebuild the rows TextKit 2 would swap as plain SwiftUI — the twenty-flip
///   memory control (see `RebuildControl`; lifecycle gate only). With any
///   `n`, 0 included, About This Build shows the control's row count.
/// - `-scenePhaseProbe` shows the scene's own phase transitions in a small
///   overlay (see `ScenePhaseProbe`; lifecycle gate only) — the thrash
///   check's proof that Home, lock and the app switcher left the foreground.
/// - `-interactionProbe` (UI tests only) records what the document asks the
///   host to do: every `.taskToggled` the reader's interaction handler
///   receives, and every URL the document opens — caught by an `openURL`
///   action, so a link tap stays in the app instead of opening Safari.
///   About This Build shows the counts and the last of each
///   (`probe-task-dispatches`, `probe-task-last` = `<id> <true|false>`,
///   `probe-url-opens`, `probe-url-last`) and each prints a `PROBE …` line.
///   Without the flag nothing is recorded, no About rows appear and links
///   open as usual (see `InteractionProbe`).
/// - `-captureGeometryHook` (the visual gate, arms B and C) installs
///   `CaptureGeometryHook`: each post of the Darwin notification
///   `com.connie.adfreader.geometry` prints one line describing the screen
///   at that moment, from a one-shot read of the key window
///   (`RendererStats.printCaptureGeometry`):
///
///       CAPTURE_GEOMETRY seq=<n> scale=<s> screen=<w>x<h> window=<x0>,<y0>,<x1>,<y1>
///           visibleRows=<id>[,<id>…]|-|unavailable
///           rows=<owner>|<root|list|code>|<frame>|<visible or ->|<draws or ->[;…]|-
///
///   `Scripts/visual-parity.sh` posts it right before and right after its
///   screenshot, and `Scripts/visual_diff.py` ties each scored code box to
///   the TextKit 2 row whose frame holds its pixels, and measures the
///   landing from `visibleRows`. Without the flag no observer exists and
///   nothing is read or printed.
/// - `-openAccounts` starts with the Settings sheet open and already pushed
///   to Atlassian Accounts (`AccountsView`), for UI tests and demo
///   recordings. Ignored with `-fixture` (the space list, which owns the
///   gear button, is not shown then).
/// - `-authGateway <url>` (Debug builds only; compiled out of Release)
///   sends every Atlassian token check to `<url>` instead of the site's
///   `https://<site>/gateway/api/graphql` — a local stub GraphQL server for
///   demos. It prints `AUTH_GATEWAY override=<url>` once at launch, and
///   Atlassian Accounts says the override is active.
/// - `-accountsInMemory` (Debug builds only; compiled out of Release) keeps
///   Atlassian accounts in memory instead of the keychain, so a UI test
///   starts from an empty account list whatever a previous run saved, and
///   never writes the simulator's keychain.
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
    var memoryReliefHook = false
    var rebuildControlPicks: Int?
    var scenePhaseProbe = false
    var interactionProbe = false
    var captureGeometryHook = false
    var openAccounts = false
    #if DEBUG
    var authGateway: URL?
    var accountsInMemory = false
    #endif

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
            case "-memoryReliefHook":
                memoryReliefHook = true
            case "-rebuildControlPicks" where arguments.index(after: index) < arguments.endIndex:
                index = arguments.index(after: index)
                rebuildControlPicks = max(Int(arguments[index]) ?? 0, 0)
            case "-scenePhaseProbe":
                scenePhaseProbe = true
            case "-interactionProbe":
                interactionProbe = true
            case "-captureGeometryHook":
                captureGeometryHook = true
            case "-openAccounts":
                openAccounts = true
            #if DEBUG
            case "-authGateway" where arguments.index(after: index) < arguments.endIndex:
                index = arguments.index(after: index)
                authGateway = URL(string: arguments[index])
            case "-accountsInMemory":
                accountsInMemory = true
            #endif
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
    @State private var accountStore: AccountStore

    init() {
        _accountStore = State(initialValue: AccountStore.live(options: options))
        // Before the scene builds: `ReaderView` reads the renderer key through
        // `@AppStorage`, which must see the launch-argument override.
        RendererPreference.apply(options)
        RebuildControl.picksLeft = options.rebuildControlPicks ?? 0
        RebuildControl.configured = options.rebuildControlPicks != nil
        InteractionProbe.enabled = options.interactionProbe
        RotationHook.install()
        RejumpHook.install()
        if options.memoryReliefHook {
            MemoryReliefHook.install()
        }
        if options.captureGeometryHook {
            CaptureGeometryHook.install()
        }
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
                    SpaceListView(openAccounts: options.openAccounts)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if options.scenePhaseProbe {
                    ScenePhaseProbe()
                }
            }
            .environment(accountStore)
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

/// Prints the screen's geometry on request:
/// `xcrun simctl spawn <udid> notifyutil -p com.connie.adfreader.geometry`
/// makes the open reader print one `CAPTURE_GEOMETRY` line
/// (`RendererStats.printCaptureGeometry`): every TextKit 2 row in the key
/// window with its window frame and visible part, and the top-level rows the
/// reader reports fully visible. The visual gate posts it right before and
/// right after each screenshot of arms B and C, so the scorer can tie each
/// scored code box to the row that drew it. Installed only with
/// `-captureGeometryHook`; each post is one read of the window, no state
/// and no observer on any row (ADR §8, §16, §20).
enum CaptureGeometryHook {
    static let notification = Notification.Name("ADFReaderCaptureGeometry")

    static func install() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                Task { @MainActor in NotificationCenter.default.post(name: CaptureGeometryHook.notification, object: nil) }
            },
            "com.connie.adfreader.geometry" as CFString,
            nil,
            .deliverImmediately
        )
    }
}

/// Returns free malloc pages to the system on request:
/// `xcrun simctl spawn <udid> notifyutil -p com.connie.adfreader.relief`
/// calls `malloc_zone_pressure_relief(nil, 0)` — what the OS does under
/// memory pressure. Installed only with `-memoryReliefHook`. The lifecycle
/// gate's flip check measures settled phys_footprint after it, because the
/// raw footprint also counts free-but-dirty pages the allocator keeps as a
/// high-water mark (live malloc stayed flat over the flips; see the
/// lifecycle gate's report).
enum MemoryReliefHook {
    static func install() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                Task { @MainActor in
                    let released = malloc_zone_pressure_relief(nil, 0)
                    print("RELIEF released=\(released)")
                    fflush(stdout)
                }
            },
            "com.connie.adfreader.relief" as CFString,
            nil,
            .deliverImmediately
        )
    }
}
