import Foundation

/// Launch-arg toggle for the selection engine, read ONCE (constant, never
/// flips at runtime). Requires `-textkit2` — selection is served by the same
/// per-row TK2 layouts, so it is meaningless on the SwiftUI arm.
public enum SelectionFlags {
    public static let enabled: Bool =
        ProcessInfo.processInfo.arguments.contains("-selection")
        && ProcessInfo.processInfo.arguments.contains("-textkit2")
}
