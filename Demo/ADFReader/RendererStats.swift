import Foundation
import SwiftUI
import UIKit
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
///         tk2CodeLive=<n> tk2CodeDraws=<n> eligibleCodeRoots=<n>
///         fallbackCodeRoots=<n> codeAdmitted=<n> codeGated=<n>
///         [rebuildControlRows=<n> rebuildControlAppeared=<n>]
///
/// `renderer` is the persisted switch at print time; `tk2Live` counts live
/// TextKit 2 row views, `tk2Layouts`/`tk2Draws` are cumulative since launch.
/// `tk2NativeDraws` counts the draws in which TextKit 2 itself drew glyphs
/// (the renderer proof), `tk1BackedRows`/`tk1BackedDraws` the linked rows
/// a TextKit 1 stack lays out and draws inside the TK2 row (live / since
/// launch). `tk2ListLive` counts the live rows drawing list text (the
/// list-native proof), `tk2Conversions` the prepared-text conversions rows
/// performed since launch. `tk2CodeLive` counts the live rows drawing a
/// code block's code and `tk2CodeDraws` the native draw passes of such rows
/// since launch (the code-native proof: a paragraph or list row drawing
/// natively proves nothing about code).
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
/// trailing leaf counts. The leaf keys are the prose and list set: code is
/// counted apart. `eligibleCodeRoots`/`fallbackCodeRoots` split the
/// top-level code blocks by content (static, like the keys above).
/// `codeAdmitted`/`codeGated` are measured, not static: of the eligible
/// code roots, how many TextKit 2 would really draw at this run's text
/// size, legibility weight, display scale and layout direction, and how
/// many a view-time rule keeps on SwiftUI there (right-to-left layout, a
/// canvas over the admission caps, or before iOS 26 an interior empty line
/// at AX4 and AX5); `codeAdmitted + codeGated ==
/// eligibleCodeRoots` (`ADFTextRenderer.textKit2CodeAdmission`). The
/// bracketed keys appear only under
/// `-rebuildControlPicks` (`RebuildControl`). Parsed by
/// `Scripts/perf_trial.py` (one line at READY, one after `SCROLL_METRICS`).
///
/// After a `-scrollToFraction` jump the reader prints the line once more,
/// between two others (`ReaderView.scrollToFraction`), for
/// `Scripts/visual_diff.py`:
///
///     SCROLL_LANDED fixture=<name> fraction=<f> index=<i> block=<id> blocks=<n>
///     RENDERER_STATS …
///     TK2_CODE_ROWS live=<n> owners=<id>:<draws>[,<id>:<draws>…]
///
/// `SCROLL_LANDED` names the block the jump went to (`block=`, the
/// `RenderBlock.id` at `index=` of `blocks=`: the jump's target, not a
/// measured position) and is printed with or without `-rendererStats`; the
/// other two only with it. `TK2_CODE_ROWS` is the per-owner code proof
/// (`printCodeRows`): a total cannot say which block drew.
@MainActor
enum RendererStats {
    /// The environment the reader draws a document in, for the measured
    /// code counts.
    struct TextEnvironment {
        var dynamicTypeSize: DynamicTypeSize
        var legibilityWeight: LegibilityWeight?
        var displayScale: CGFloat
        var layoutDirection: LayoutDirection
    }

    /// The reader's environment as this launch sets it up, for a caller
    /// that has no view environment at hand (`AutoScroller`): the window's
    /// traits, with the system text size moved by the reader's text-size
    /// step the way `ReaderView` moves it (`-fontSizeStep` when given, else
    /// the step persisted for the launch's `-fixture`). It follows
    /// `ReaderView.load()`; a step changed in the text-size control after
    /// loading under `-fontSizeStep`, which is never persisted, is not
    /// seen.
    static func launchEnvironment() -> TextEnvironment {
        let traits = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.traitCollection }
            .first ?? UITraitCollection.current
        let options = LaunchOptions()
        let persisted = options.fixtureName.map { FontSizeStore().step(for: "fixture:\($0)") } ?? 0
        let system = DynamicTypeSize(traits.preferredContentSizeCategory) ?? .large
        let legibility: LegibilityWeight?
        switch traits.legibilityWeight {
        case .bold: legibility = .bold
        case .regular: legibility = .regular
        default: legibility = nil
        }
        return TextEnvironment(
            dynamicTypeSize: system.shifted(by: options.fontSizeStep ?? persisted),
            legibilityWeight: legibility,
            displayScale: traits.displayScale > 0 ? traits.displayScale : 1,
            layoutDirection: traits.layoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
        )
    }

    /// The `TK2_CODE_ROWS` line: every live TextKit 2 row drawing a code
    /// block's code, by owner (`ADFTextRenderer.textKit2CodeRowDraws`).
    ///
    ///     TK2_CODE_ROWS live=<n> owners=<id>:<draws>[,<id>:<draws>…]
    ///     TK2_CODE_ROWS live=0 owners=-
    ///
    /// `<id>` is the code block's `RenderBlock.id` (a node path: no space,
    /// comma or colon) and `<draws>` the native TextKit 2 draw passes its
    /// live row has dispatched: above zero, TextKit 2 itself drew that
    /// block's code; zero, the row is alive but has not drawn. A block
    /// whose code is on SwiftUI is absent. Owners are sorted by id (numbers
    /// in it by value), `live=` counts them, and `owners=-` means no live
    /// code row, as with the switch off.
    static func printCodeRows() {
        let rows = ADFTextRenderer.textKit2CodeRowDraws
        let owners = rows.keys.sorted { first, second in
            let order = first.compare(second, options: .numeric)
            return order == .orderedSame ? first < second : order == .orderedAscending
        }
        let list = owners.isEmpty ? "-" : owners.map { "\($0):\(rows[$0] ?? 0)" }.joined(separator: ",")
        Swift.print("TK2_CODE_ROWS live=\(owners.count) owners=\(list)")
        fflush(stdout)
    }

    /// `environment`: the environment the document is drawn in, when the
    /// caller has it; `nil` uses `launchEnvironment()`.
    static func print(blocks: [RenderBlock], environment: TextEnvironment? = nil) {
        let renderer: ADFTextRenderer =
            UserDefaults.standard.bool(forKey: RendererPreference.key) ? .textKit2 : .swiftUI
        let stats = ADFTextRenderer.textKit2Stats
        let coverage = ADFTextRenderer.textKit2Coverage(of: blocks)
        let environment = environment ?? launchEnvironment()
        let code = ADFTextRenderer.textKit2CodeAdmission(
            of: blocks, dynamicTypeSize: environment.dynamicTypeSize, legibilityWeight: environment.legibilityWeight,
            displayScale: environment.displayScale, layoutDirection: environment.layoutDirection
        )
        var line =
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
        // Appended keys, each statement on its own: one long chain of
        // interpolated literals is slow to type-check.
        line += " tk2CodeLive=\(stats.liveCodeRowCount) tk2CodeDraws=\(stats.codeNativeDrawCount)"
        line += " eligibleCodeRoots=\(coverage.eligibleCodeRoots) fallbackCodeRoots=\(coverage.fallbackCodeRoots)"
        line += " codeAdmitted=\(code.admittedCodeRoots) codeGated=\(code.gatedCodeRoots)"
        if RebuildControl.configured {
            line += " rebuildControlRows=\(ADFTextRenderer.rebuildControlRows.live)"
            line += " rebuildControlAppeared=\(ADFTextRenderer.rebuildControlRows.appeared)"
        }
        Swift.print(line)
        fflush(stdout)
    }
}
