/// Render-region entries and exits of the document's lazy rows
/// (`DocumentRow`), counted since launch: the T1 scroll-counter tier's
/// "rows materialised" signal (`Demo/ADFReader/ScrollCounters.swift`,
/// `Scripts/perf-scroll-counters.sh`), for both text renderers.
///
/// A row "appears" when the lazy stack brings it into its render region
/// (`onAppear`), which builds its block view, and "disappears" when it leaves
/// (`onDisappear`), which collapses it to a spacer (ADR §4). A straight
/// scroll through a document appears each row about once; a mass
/// re-materialisation (ADR §16) or a lazy-row lifecycle regression shows up
/// as extra appearances, and a livelock as appearances that keep growing
/// after the scroll stops.
///
/// Two plain integer increments on the main actor per row lifecycle event:
/// no state, no observation, nothing a view reads (ADR §8, §16, §20).
/// Self-contained on purpose: the T1 script copies this file onto refs that
/// predate it, with the two `DocumentRow` call sites, so a base arm built
/// from an older ref reports the same counters.
@_spi(ADFDiagnostics)
@MainActor
public enum ADFRowLifecycle {
    /// Rows that entered the render region since launch.
    public private(set) static var appearances = 0
    /// Rows that left the render region since launch.
    public private(set) static var disappearances = 0

    /// Rows in the render region now.
    public static var inRenderRegion: Int {
        appearances - disappearances
    }

    static func rowAppeared() {
        appearances += 1
    }

    static func rowDisappeared() {
        disappearances += 1
    }
}
