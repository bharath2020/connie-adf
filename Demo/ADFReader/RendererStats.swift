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
///         tk2ContainerLive=<n> tk2ContainerNativeDraws=<n>
///         tk2ContainerTK1Draws=<n> tk2CaptionLive=<n>
///         tk2CaptionNativeDraws=<n> tk2OffWindow=<n>
///         eligibleContainerLeaves=<n> linkedContainerLeaves=<n>
///         fallbackContainerLeaves=<n> containerListLeaves=<n>
///         eligibleCaptionLeaves=<n> fallbackCaptionLeaves=<n>
///         eligibleNestedCode=<n> fallbackNestedCode=<n>
///         unpreparedExpands=<n> nestedCodeAdmitted=<n> nestedCodeGated=<n>
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
/// natively proves nothing about code). `tk2ContainerLive` counts the live
/// rows drawing text below a container's boundary that is not code
/// (paragraphs, headings and list text in a panel, quote, expand body,
/// extension body or layout column), `tk2ContainerNativeDraws` and
/// `tk2ContainerTK1Draws` their native and TextKit 1-backed (linked) draw
/// passes since launch (the container-native proof: a code row in a
/// container is counted as code only); `tk2CaptionLive` and
/// `tk2CaptionNativeDraws` the same for media captions; `tk2OffWindow` the
/// live row views outside any window (built by the lazy stack ahead of the
/// viewport, or kept after showing).
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
/// eligibleCodeRoots` (`ADFTextRenderer.textKit2CodeAdmission`). Text below
/// containers and in captions joins none of those keys: the container keys
/// count it apart (static, stacked and left to right):
/// `eligibleContainerLeaves`/`fallbackContainerLeaves` its paragraphs,
/// headings and list text, `linkedContainerLeaves` the linked eligible
/// ones, `containerListLeaves` the list text among them;
/// `eligibleCaptionLeaves`/`fallbackCaptionLeaves` captions;
/// `eligibleNestedCode`/`fallbackNestedCode` code in containers, with
/// `nestedCodeAdmitted`/`nestedCodeGated` measured as `codeAdmitted`/
/// `codeGated` are, in the same walk
/// (`ADFTextRenderer.textKit2CodeAdmissionIncludingNested`);
/// `unpreparedExpands` the expands in scope whose bodies, prepared only
/// when opened, the count could not enter. Every container key is 0 while
/// no container family is enabled; `tk2OffWindow` is not a container key:
/// it counts every live row kind outside a window. The
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
///     TK2_CONTAINER_ROWS live=<n> owners=<id>:<draws>[,<id>:<draws>…]
///     TK2_CAPTION_ROWS live=<n> owners=<id>:<draws>[,<id>:<draws>…]
///
/// `SCROLL_LANDED` names the block the jump went to (`block=`, the
/// `RenderBlock.id` at `index=` of `blocks=`: the jump's target, not a
/// measured position) and is printed with or without `-rendererStats`; the
/// others only with it. `TK2_CODE_ROWS` is the per-owner code proof
/// (`printCodeRows`): a total cannot say which block drew, and a count
/// says a row drew, not that it is on screen. `TK2_CONTAINER_ROWS` and
/// `TK2_CAPTION_ROWS` are the same proof for container text that is not
/// code and for captions (`printContainerRows`, `printCaptionRows`).
///
/// Under `-captureGeometryHook`, each `com.connie.adfreader.geometry` post
/// prints what is on screen at that moment (`printCaptureGeometry`), which
/// `Scripts/visual-parity.sh` requests right before and right after its
/// screenshot:
///
///     CAPTURE_GEOMETRY seq=<n> scale=<s> screen=<w>x<h> window=<x0>,<y0>,<x1>,<y1>
///         visibleRows=<id>[,<id>…]|-|unavailable
///         rows=<owner>|<root|list|code>|<frame>|<visible or ->|<draws or ->[;…]|-
///     CAPTURE_GEOMETRY seq=<n> error=no-key-window
///
/// One line, points with 4 decimals, rectangles as `x0,y0,x1,y1` in the
/// key window's coordinates. `seq` counts the posts from 1. `scale` and
/// `screen` are the window's screen (pixels = points × scale), `window`
/// the window on that screen. `visibleRows` is the top-level rows the
/// reader reports at least 95 % inside the viewport
/// (`ADFDocumentModel.fullyVisibleRowIDs`, sorted by id; `-` none;
/// `unavailable` before iOS 18, where no feed exists). `rows` is every
/// TextKit 2 row in the window (`ADFTextRenderer.textKit2RowFrames(in:)`,
/// sorted by owner id, then top): its owner, kind, the frame it can draw
/// in (bounds and canvas), that frame clipped by its clipping ancestors and
/// the window (`-` when nothing of it shows) and its owner's native draws
/// at this moment: always for a code row (`TK2_CODE_ROWS`), for a
/// container or caption row when its owner is live there
/// (`TK2_CONTAINER_ROWS`, `TK2_CAPTION_ROWS`), else `-` (a top-level
/// row); `rows=-` when there is none. Ids are node paths, which hold none
/// of ` ,;|` (any would print as `_`).
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
        printOwnerRows("TK2_CODE_ROWS", ADFTextRenderer.textKit2CodeRowDraws)
    }

    /// The `TK2_CONTAINER_ROWS` line: every live TextKit 2 row drawing
    /// text below a container's boundary that is not code
    /// (`ADFTextRenderer.textKit2ContainerRowDraws`), in `TK2_CODE_ROWS`'s
    /// format. `<id>` is the text leaf's owner: a paragraph's or heading's
    /// `RenderBlock.id`, or a nested list row's `PreparedListRow.id`. A
    /// linked row draws through TextKit 1 and lists zero native draws.
    ///
    ///     TK2_CONTAINER_ROWS live=<n> owners=<id>:<draws>[,<id>:<draws>…]
    ///     TK2_CONTAINER_ROWS live=0 owners=-
    static func printContainerRows() {
        printOwnerRows("TK2_CONTAINER_ROWS", ADFTextRenderer.textKit2ContainerRowDraws)
    }

    /// The `TK2_CAPTION_ROWS` line: every live TextKit 2 row drawing a
    /// media caption (`ADFTextRenderer.textKit2CaptionRowDraws`, by
    /// `PreparedMedia.id`), in `TK2_CODE_ROWS`'s format.
    static func printCaptionRows() {
        printOwnerRows("TK2_CAPTION_ROWS", ADFTextRenderer.textKit2CaptionRowDraws)
    }

    /// `<marker> live=<n> owners=<id>:<draws>[,…]|-`: owners sorted by id
    /// (numbers in it by value), `live=` counting them.
    private static func printOwnerRows(_ marker: String, _ rows: [String: Int]) {
        let owners = rows.keys.sorted { first, second in
            let order = first.compare(second, options: .numeric)
            return order == .orderedSame ? first < second : order == .orderedAscending
        }
        let list = owners.isEmpty ? "-" : owners.map { "\($0):\(rows[$0] ?? 0)" }.joined(separator: ",")
        Swift.print("\(marker) live=\(owners.count) owners=\(list)")
        fflush(stdout)
    }

    /// Posts answered so far (`CAPTURE_GEOMETRY seq=`).
    private static var geometrySequence = 0

    /// One `CAPTURE_GEOMETRY` line (format in the type's comment): the key
    /// window's TextKit 2 rows and the fully visible top-level rows, now.
    /// One read of the window per call: nothing is laid out, kept or
    /// observed.
    static func printCaptureGeometry(model: ADFDocumentModel) {
        geometrySequence += 1
        var line = "CAPTURE_GEOMETRY seq=\(geometrySequence)"
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else {
            Swift.print(line + " error=no-key-window")
            fflush(stdout)
            return
        }
        let screen = window.screen
        let draws = ADFTextRenderer.textKit2CodeRowDraws
        let textDraws = ADFTextRenderer.textKit2ContainerRowDraws
            .merging(ADFTextRenderer.textKit2CaptionRowDraws) { container, _ in container }
        let rows = ADFTextRenderer.textKit2RowFrames(in: window).sorted { first, second in
            let order = first.ownerID.compare(second.ownerID, options: .numeric)
            if order != .orderedSame { return order == .orderedAscending }
            if first.ownerID != second.ownerID { return first.ownerID < second.ownerID }
            return first.frame.minY < second.frame.minY
        }
        line += " scale=\(geometryNumber(screen.scale))"
        line += " screen=\(geometryNumber(screen.bounds.width))x\(geometryNumber(screen.bounds.height))"
        line += " window=\(geometryRect(window.convert(window.bounds, to: screen.coordinateSpace)))"
        let visibleRows: String
        if let ids = model.fullyVisibleRowIDs {
            visibleRows = ids.isEmpty ? "-" : ids.sorted { first, second in
                let order = first.compare(second, options: .numeric)
                return order == .orderedSame ? first < second : order == .orderedAscending
            }.map(geometryID).joined(separator: ",")
        } else {
            visibleRows = "unavailable"
        }
        line += " visibleRows=\(visibleRows)"
        let rowList = rows.map { row in
            let visible = row.visible.map(geometryRect) ?? "-"
            let rowDraws = row.kind == .code
                ? String(draws[row.ownerID] ?? 0) : textDraws[row.ownerID].map(String.init) ?? "-"
            return "\(geometryID(row.ownerID))|\(row.kind.rawValue)|\(geometryRect(row.frame))|\(visible)|\(rowDraws)"
        }
        line += " rows=\(rowList.isEmpty ? "-" : rowList.joined(separator: ";"))"
        Swift.print(line)
        fflush(stdout)
    }

    private static func geometryNumber(_ value: CGFloat) -> String {
        String(format: "%.4f", Double(value))
    }

    /// `x0,y0,x1,y1` (minX, minY, maxX, maxY).
    private static func geometryRect(_ rect: CGRect) -> String {
        [rect.minX, rect.minY, rect.maxX, rect.maxY].map(geometryNumber).joined(separator: ",")
    }

    /// An id with any of the line's separators replaced (node paths have
    /// none).
    private static func geometryID(_ id: String) -> String {
        String(id.map { " ,;|".contains($0) ? "_" : $0 })
    }

    /// `environment`: the environment the document is drawn in, when the
    /// caller has it; `nil` uses `launchEnvironment()`.
    static func print(blocks: [RenderBlock], environment: TextEnvironment? = nil) {
        let renderer: ADFTextRenderer =
            UserDefaults.standard.bool(forKey: RendererPreference.key) ? .textKit2 : .swiftUI
        let stats = ADFTextRenderer.textKit2Stats
        let coverage = ADFTextRenderer.textKit2Coverage(of: blocks)
        let environment = environment ?? launchEnvironment()
        let code = ADFTextRenderer.textKit2CodeAdmissionIncludingNested(
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
        line += " tk2ContainerLive=\(stats.liveContainerRowCount) tk2ContainerNativeDraws=\(stats.containerNativeDrawCount)"
        line += " tk2ContainerTK1Draws=\(stats.containerTextKit1DrawCount)"
        line += " tk2CaptionLive=\(stats.liveCaptionRowCount) tk2CaptionNativeDraws=\(stats.captionNativeDrawCount)"
        line += " tk2OffWindow=\(stats.liveOffWindowRowCount)"
        line += " eligibleContainerLeaves=\(coverage.eligibleContainerLeaves) linkedContainerLeaves=\(coverage.linkedContainerLeaves)"
        line += " fallbackContainerLeaves=\(coverage.fallbackContainerLeaves) containerListLeaves=\(coverage.containerListLeaves)"
        line += " eligibleCaptionLeaves=\(coverage.eligibleCaptionLeaves) fallbackCaptionLeaves=\(coverage.fallbackCaptionLeaves)"
        line += " eligibleNestedCode=\(coverage.eligibleNestedCode) fallbackNestedCode=\(coverage.fallbackNestedCode)"
        line += " unpreparedExpands=\(coverage.unpreparedExpands)"
        line += " nestedCodeAdmitted=\(code.nestedCodeAdmitted) nestedCodeGated=\(code.nestedCodeGated)"
        if RebuildControl.configured {
            line += " rebuildControlRows=\(ADFTextRenderer.rebuildControlRows.live)"
            line += " rebuildControlAppeared=\(ADFTextRenderer.rebuildControlRows.appeared)"
        }
        Swift.print(line)
        fflush(stdout)
    }
}
