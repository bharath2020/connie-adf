import SwiftUI

/// Launch-argument protocol (consumed by the Task 7 automation harness):
/// - `-fixture <name>` opens that fixture's reader directly on launch
///   (name without the `.json` extension).
/// - `-scrollToFraction <f>` scrolls, once the document is ready, to the
///   block at fraction `f` of `model.blocks`.
/// - `-autoscroll` waits 1s after ready, animates through the entire
///   document at ~1,200 pt/s while frame metrics run, prints one
///   `SCROLL_METRICS …` line, then exits after 2s.
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

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                if let name = options.fixtureName {
                    if let fixture = Fixture(named: name) {
                        ReaderView(fixture: fixture, options: options)
                    } else {
                        ContentUnavailableView(
                            "Fixture Not Found",
                            systemImage: "doc.questionmark",
                            description: Text("No bundled fixture named \u{201C}\(name).json\u{201D}.")
                        )
                    }
                } else {
                    FixtureListView()
                }
            }
        }
    }
}
