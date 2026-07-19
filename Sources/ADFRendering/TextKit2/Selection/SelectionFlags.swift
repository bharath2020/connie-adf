import Foundation

/// Selection ships wherever TextKit 2 rendering does — gated on
/// `TextKit2Flags.enabled` (launch arg OR the persisted in-app toggle), not
/// a separate launch arg. TestFlight users can't pass launch args, so a
/// selection gate that additionally required the literal `-selection`
/// argument was invisible to every device build: flipping the in-app "TK2
/// Renderer" toggle turned on TK2 rendering with zero selection, the entire
/// phase 4-5 deliverable silently absent. Every Task 26/27 measurement gate
/// exercised `-textkit2 -selection` together anyway, so this is also the
/// configuration that was actually validated — "TK2 without selection" was
/// the un-gated, unvalidated one.
///
/// `-noSelection` is the escape hatch for A/B and perf automation that wants
/// TK2 rendering with the selection overlay withheld (e.g. to isolate render
/// cost from selection-overlay cost). `-selection` is still accepted on the
/// command line for backward compatibility with existing scripts, but is a
/// no-op — it is not read anywhere.
///
/// Read ONCE (constant, never flips at runtime), same discipline as
/// `TextKit2Flags`.
public enum SelectionFlags {
    public static let enabled: Bool =
        TextKit2Flags.enabled
        && !ProcessInfo.processInfo.arguments.contains("-noSelection")
}
