import Foundation

/// Launch-arg toggles, read ONCE — they never flip at runtime, so a
/// constant-Bool `if/else` at a leaf keeps stable view identity (§18's
/// poison is only buildLimitedAvailability/AnyView, never plain branches
/// on launch constants).
public enum TextKit2Flags {
    /// `-textkit2`: render text leaves with TextKit 2 (assessment A/B).
    public static let enabled = ProcessInfo.processInfo.arguments.contains("-textkit2")
    /// `-textkit2NoCells`: exclude table cells (giant-table gate fallback).
    public static let cellsEnabled = !ProcessInfo.processInfo.arguments.contains("-textkit2NoCells")
}
