import Foundation
import ADFPreparation
import ADFRendering

/// The `-rendererStats` line: which text engine is active and what the
/// TextKit 2 rows actually did, so a perf run can prove the renderer it
/// claims to measure.
///
///     RENDERER_STATS renderer=<swiftui|textkit2> tk2Live=<n> tk2Layouts=<n>
///         tk2Draws=<n> eligibleRoots=<n> fallbackRoots=<n>
///
/// `renderer` is the persisted switch at print time; `tk2Live` counts live
/// TextKit 2 row views, `tk2Layouts`/`tk2Draws` are cumulative since launch;
/// the roots split `model.blocks` by TextKit 2 eligibility. Parsed by
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
                + "eligibleRoots=\(coverage.eligibleRoots) fallbackRoots=\(coverage.fallbackRoots)"
        )
        fflush(stdout)
    }
}
