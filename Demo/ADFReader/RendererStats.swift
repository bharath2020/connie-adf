import Foundation
import ADFPreparation
@_spi(ADFDiagnostics) import ADFRendering

/// The `-rendererStats` line: which text engine is active and what the
/// TextKit 2 rows actually did, so a perf run can prove the renderer it
/// claims to measure.
///
///     RENDERER_STATS renderer=<swiftui|textkit2> tk2Live=<n> tk2Layouts=<n>
///         tk2Draws=<n> tk2NativeDraws=<n> tk1BackedRows=<n>
///         tk1BackedDraws=<n> eligibleRoots=<n> fallbackRoots=<n>
///         textFallbackRoots=<n> linkRoots=<n> tk2ListLive=<n>
///         tk2Conversions=<n> eligibleTextLeaves=<n> linkedTextLeaves=<n>
///         fallbackTextLeaves=<n> listLeaderLeaves=<n> listTrailingLeaves=<n>
///         [rebuildControlRows=<n> rebuildControlAppeared=<n>]
///
/// `renderer` is the persisted switch at print time; `tk2Live` counts live
/// TextKit 2 row views, `tk2Layouts`/`tk2Draws` are cumulative since launch.
/// `tk2NativeDraws` counts the draws in which TextKit 2 itself drew glyphs
/// (the renderer proof), `tk1BackedRows`/`tk1BackedDraws` the linked rows
/// a TextKit 1 stack lays out and draws inside the TK2 row (live / since
/// launch). `tk2ListLive` counts the live rows drawing list text (the
/// list-native proof), `tk2Conversions` the prepared-text conversions rows
/// performed since launch.
///
/// Coverage of `model.blocks` (`ADFTextKit2Coverage`, static): the root
/// richText, legacy keys `eligibleRoots`/`fallbackRoots`/
/// `textFallbackRoots`/`linkRoots` split the top-level blocks by TextKit 2
/// eligibility as in PR 1 (`fallbackRoots` counts every other top-level
/// block, lists included: not a count of SwiftUI-only blocks). The leaf
/// keys count the text in the renderer's scope (top-level paragraphs and
/// headings, list leaders, list rows' direct paragraphs and headings):
/// `eligibleTextLeaves` (root and list) with `linkedTextLeaves` of them
/// TextKit 1-backed, `fallbackTextLeaves` on SwiftUI, and the list leader /
/// trailing leaf counts. The bracketed keys appear only under
/// `-rebuildControlPicks` (`RebuildControl`). Parsed by
/// `Scripts/perf_trial.py` (one line at READY, one after `SCROLL_METRICS`).
@MainActor
enum RendererStats {
    static func print(blocks: [RenderBlock]) {
        let renderer: ADFTextRenderer =
            UserDefaults.standard.bool(forKey: RendererPreference.key) ? .textKit2 : .swiftUI
        let stats = ADFTextRenderer.textKit2Stats
        let coverage = ADFTextRenderer.textKit2Coverage(of: blocks)
        Swift.print(
            "RENDERER_STATS renderer=\(renderer.rawValue) tk2Live=\(stats.liveRowCount) "
                + "tk2Layouts=\(stats.layoutCount) tk2Draws=\(stats.drawCount) "
                + "tk2NativeDraws=\(stats.nativeDrawCount) tk1BackedRows=\(stats.textKit1BackedRowCount) "
                + "tk1BackedDraws=\(stats.textKit1BackedDrawCount) "
                + "eligibleRoots=\(coverage.eligibleRoots) fallbackRoots=\(coverage.fallbackRoots) "
                + "textFallbackRoots=\(coverage.textFallbackRoots) linkRoots=\(coverage.linkRoots) "
                + "tk2ListLive=\(stats.liveListRowCount) tk2Conversions=\(stats.conversionCount) "
                + "eligibleTextLeaves=\(coverage.eligibleTextLeaves) linkedTextLeaves=\(coverage.linkedTextLeaves) "
                + "fallbackTextLeaves=\(coverage.fallbackTextLeaves) listLeaderLeaves=\(coverage.listLeaderLeaves) "
                + "listTrailingLeaves=\(coverage.listTrailingLeaves)"
                + (RebuildControl.configured
                    ? " rebuildControlRows=\(ADFTextRenderer.rebuildControlRows.live) "
                        + "rebuildControlAppeared=\(ADFTextRenderer.rebuildControlRows.appeared)"
                    : "")
        )
        fflush(stdout)
    }
}
