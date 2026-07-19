import Foundation
import ADFPreparation
import ADFRendering

/// Task 22 on-sim verification harness (spec §7's named gate — a live-edit
/// while a selection session is held): after `afterSeconds`, applies ONE
/// `.replace` mutation to a mid-document paragraph — a real document-epoch
/// bump via the production `apply(_:revision:)` path, timed to land while a
/// manually-driven selection (long-press, no drag — `axe` cannot synthesize
/// touch-move events on this simulator, the same documented Task 19
/// limitation) is held. Deliberately does not exit or navigate afterward;
/// the operator screenshots before and after by hand. Mirrors
/// `SearchAutomation`'s `apply` usage, minus the metrics/search machinery
/// this run doesn't need.
@MainActor
enum MutationAutomation {
    static func run(model: ADFDocumentModel, afterSeconds: Double) async {
        try? await Task.sleep(for: .seconds(afterSeconds))
        guard model.blocks.count > 1 else {
            print("MUTATION_SKIPPED reason=too-few-blocks")
            fflush(stdout)
            return
        }
        // A MID-document item, per the brief — not the first block (which is
        // likely still in the initial viewport a long-press already landed
        // on, and this deliberately exercises a row NOT necessarily under
        // the finger, matching "mutate somewhere else while a session is
        // held" as much as a stationary long-press can).
        let midIndex = model.blocks.count / 2
        guard let targetIndex = ((0..<model.blocks.count).sorted {
            abs($0 - midIndex) < abs($1 - midIndex)
        }).first(where: {
            if case .richText(_, let style) = model.blocks[$0].kind { return !style.isHeading }
            return false
        }), case .richText(let segments, let style) = model.blocks[targetIndex].kind else {
            print("MUTATION_SKIPPED reason=no-richtext-target")
            fflush(stdout)
            return
        }

        var changed = segments
        changed.append(.text(AttributedString(" [edited by Task 22 mutation harness]")))
        let itemID = model.blocks[targetIndex].id
        let replacement = RenderBlock(
            id: itemID,
            kind: .richText(segments: changed, style: style),
            breakout: model.blocks[targetIndex].breakout
        )
        do {
            try await model.apply(
                [.replace(itemID: itemID, block: replacement)],
                revision: model.documentRevision + 1
            )
            print("MUTATION_APPLIED itemID=\(itemID) blockIndex=\(targetIndex) epoch=\(model.documentEpoch)")
        } catch {
            print("MUTATION_ERROR error=\(error)")
        }
        fflush(stdout)
    }

    /// Task 22 sim verification (a): toggles the first `.expand` block's
    /// open/closed state directly on `model.expandedBlocks` — the identical
    /// mutation `ExpandBlockView.toggle()` performs on a real tap, but
    /// reached programmatically instead of via the SwiftUI `Button`.
    ///
    /// Deviation note: a real on-device tap on the expand's disclosure
    /// control cannot be used to test "a selection held ELSEWHERE survives
    /// an expand toggle above it," because (a) the disclosure is a plain
    /// SwiftUI `Button`, not a `UIControl`, so `SelectionController`'s
    /// tap-to-clear treats it as an outside tap and ends the session
    /// (existing, pre-Task-22 behavior — `touchHitsDescendantControl` only
    /// recognizes real `UIControl`s / nested scroll views), and (b) opening
    /// Find in Page to drive the auto-expand path instead focuses its
    /// `TextField`, which resigns the overlay's first-responder status and
    /// also ends the session (`SelectionOverlayView.onResign`, "session
    /// ends... from any path", also pre-existing). Both are legitimate,
    /// unrelated-to-Task-22 UX behaviors with no tap-free equivalent in this
    /// app today — the same class of gap Task 19 hit with handle-drag
    /// automation (`axe` cannot synthesize touch-move events on this
    /// simulator). This hook isolates the ACTUAL Task 22 mechanism
    /// (`model.expandedBlocks` mutation → `SelectionController.
    /// observeExpandedBlocksIfActive` → `selectionGeometryDidGoStale()`) from
    /// those confounds, verifying it directly.
    static func toggleFirstExpand(model: ADFDocumentModel, afterSeconds: Double) async {
        try? await Task.sleep(for: .seconds(afterSeconds))
        guard let expandID = model.blocks.first(where: {
            if case .expand = $0.kind { return true }
            return false
        })?.id else {
            print("EXPAND_TOGGLE_SKIPPED reason=no-expand-block")
            fflush(stdout)
            return
        }
        if model.expandedBlocks.contains(expandID) {
            model.expandedBlocks.remove(expandID)
        } else {
            model.expandedBlocks.insert(expandID)
        }
        print("EXPAND_TOGGLED id=\(expandID) open=\(model.expandedBlocks.contains(expandID))")
        fflush(stdout)
    }
}
