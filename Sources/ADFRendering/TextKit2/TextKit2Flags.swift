import Foundation

/// Launch-arg (and, for `enabled`, persisted-default) toggles, read ONCE —
/// they never flip at runtime, so a constant-Bool `if/else` at a leaf keeps
/// stable view identity (§18's poison is only buildLimitedAvailability/
/// AnyView, never plain branches on launch constants). Hosts may offer a
/// settings UI that persists the default via `UserDefaults`; such changes
/// apply on the next launch, not the current session.
public enum TextKit2Flags {
    /// The `UserDefaults` key a host's settings UI persists its choice
    /// under. Read once at launch alongside the `-textkit2` launch arg.
    public static let defaultsKey = "adf.textkit2.enabled"
    /// `-textkit2`: render text leaves with TextKit 2 (assessment A/B).
    /// The launch arg always wins over the persisted default, so perf
    /// automation is unaffected by whatever a device's settings UI has
    /// stored.
    public static let enabled = ProcessInfo.processInfo.arguments.contains("-textkit2")
        || UserDefaults.standard.bool(forKey: TextKit2Flags.defaultsKey)
    /// `-textkit2NoCells` (launch-arg only, no persisted equivalent):
    /// exclude table cells (giant-table gate fallback).
    public static let cellsEnabled = !ProcessInfo.processInfo.arguments.contains("-textkit2NoCells")
}
