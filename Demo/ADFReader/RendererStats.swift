import Foundation
import ADFPreparation
import ADFRendering

/// The `-rendererStats` line: which text engine is active and what the
/// TextKit 2 rows actually did, so a perf run can prove the renderer it
/// claims to measure.
///
///     RENDERER_STATS renderer=<swiftui|textkit2> tk2Live=<n> tk2Layouts=<n>
///         tk2Draws=<n> tk2NativeDraws=<n> tk1BackedRows=<n>
///         tk1BackedDraws=<n> eligibleRoots=<n> fallbackRoots=<n>
///         textFallbackRoots=<n> linkRoots=<n>
///
/// `renderer` is the persisted switch at print time; `tk2Live` counts live
/// TextKit 2 row views, `tk2Layouts`/`tk2Draws` are cumulative since launch.
/// `tk2NativeDraws` counts the draws in which TextKit 2 itself drew glyphs
/// (the renderer proof), `tk1BackedRows`/`tk1BackedDraws` the linked rows
/// a TextKit 1 stack lays out and draws inside the TK2 row (live / since
/// launch). The roots split `model.blocks` by TextKit 2 eligibility;
/// `linkRoots` are the eligible ones with a link, `textFallbackRoots` the
/// paragraphs and headings that stay on SwiftUI. Parsed by
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
                + "textFallbackRoots=\(coverage.textFallbackRoots) linkRoots=\(coverage.linkRoots)"
        )
        fflush(stdout)
    }
}
