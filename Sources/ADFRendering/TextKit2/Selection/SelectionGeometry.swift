import Foundation
import CoreGraphics
import ADFPreparation

/// One resolved selection region in the overlay's coordinate space, with the
/// endpoint-handle flags UIKit reads. Plain data (not a `UITextSelectionRect`)
/// so the rect/interpolation MATH is platform-agnostic and `swift test`-able on
/// macOS; the iOS overlay wraps each into an `ADFSelectionRect`.
struct ResolvedSelectionRect: Equatable {
    var rect: CGRect
    var containsStart: Bool
    var containsEnd: Bool
}

/// The geometry the selection resolver depends on, abstracted so the offset
/// arithmetic, per-owner rect splitting, and collapsed-row interpolation are
/// exercised on macOS with an injected fixed-rect stub (spec §8; Task 19 Step
/// 3). The production impl (`RowGeometrySource`, iOS) is backed by the live
/// `RowGeometryRegistry` + `TextKit2RowUIView` layout queries.
///
/// Rects/points are in the overlay's coordinate space (the `UITextInput`'s own
/// space). "Live" means the owner's `TextKit2RowUIView` is currently
/// materialized in a window; a not-live owner is a collapsed spacer whose rect
/// must be interpolated from its live neighbors.
@MainActor
protocol SelectionGeometrySource: AnyObject {
    func isLive(ownerID: String) -> Bool
    /// Overlay-space rects for one corpus part slice of a LIVE owner. Empty if
    /// the owner is not live or the slice has no drawn glyphs.
    func rects(ownerID: String, slice: SelectionTextModel.PartSlice) -> [CGRect]
    /// Overlay-space caret rect for a caret anchor in a LIVE owner, or nil.
    func caretRect(ownerID: String, anchor: SelectionTextModel.CaretAnchor) -> CGRect?
    /// Nearest live-row hit to an overlay-space point: the owner, the corpus
    /// part the row-local UTF-16 hit maps back to, and the `Character` offset
    /// within it. nil if no live row is reachable.
    func closestRowAnchor(
        toContainerPoint point: CGPoint
    ) -> (ownerID: String, source: SearchTextUnit.Part.Source, localCharOffset: Int)?
    /// The live-row frames bracketing a document-order position (the live row
    /// just above / just below a collapsed owner), for interpolation.
    func bracketingLiveFrames(order: Int) -> (above: CGRect?, below: CGRect?)
}

/// The platform-agnostic selection geometry math: routes a global UTF-16 range
/// through `SelectionTextModel.partSlices` → per-owner live-row queries, and
/// synthesizes interpolated rects for collapsed owners. `containsStart` /
/// `containsEnd` are computed from RANGE MEMBERSHIP against each owner's global
/// unit range — never array/registration position (spec §7).
@MainActor
struct SelectionGeometryResolver {
    let model: SelectionTextModel
    let source: SelectionGeometrySource
    /// Expand-edge visibility predicate: a hidden unit contributes no rects,
    /// no caret, and no closest-position candidate (spec §7 expand edges).
    let isVisible: (SelectionTextModel.Unit) -> Bool

    private func unitStart(_ unit: Int) -> Int { model.unitUTF16Starts[unit] }
    private func unitEnd(_ unit: Int) -> Int {
        model.unitUTF16Starts[unit] + model.units[unit].utf16Length
    }
    private func order(of ownerID: String, fallback: Int) -> Int {
        model.ownerOrder[ownerID] ?? fallback
    }

    // MARK: Selection rects

    func selectionRects(forUTF16 range: Range<Int>) -> [ResolvedSelectionRect] {
        let lower = max(0, min(range.lowerBound, model.totalUTF16Length))
        let upper = max(0, min(range.upperBound, model.totalUTF16Length))
        guard lower < upper else { return [] }

        let slices = model.partSlices(forUTF16: lower..<upper, isVisible: isVisible)
        guard !slices.isEmpty else { return [] }

        // Group consecutive slices by unit (partSlices emits in unit/part order,
        // so a unit's slices are contiguous), resolving live rects per slice and
        // deferring collapsed owners to interpolation.
        struct OwnerRun { let unit: Int; let ownerID: String; var live: Bool; var rects: [CGRect] }
        var runs: [OwnerRun] = []
        for slice in slices {
            let ownerID = model.units[slice.unit].ownerID
            if runs.last?.unit != slice.unit {
                runs.append(OwnerRun(unit: slice.unit, ownerID: ownerID,
                                     live: source.isLive(ownerID: ownerID), rects: []))
            }
            if runs[runs.count - 1].live {
                runs[runs.count - 1].rects.append(contentsOf: source.rects(ownerID: ownerID, slice: slice))
            }
        }
        for index in runs.indices where !runs[index].live {
            let interpolated = interpolatedRect(order: order(of: runs[index].ownerID, fallback: runs[index].unit))
            runs[index].rects = interpolated.map { [$0] } ?? []
        }

        var fragments: [(rect: CGRect, unit: Int)] = []
        for run in runs {
            for rect in run.rects { fragments.append((rect, run.unit)) }
        }
        guard !fragments.isEmpty else { return [] }

        // containsStart / containsEnd from range membership: the unit whose
        // global range contains the range's lower / upper bound owns the
        // respective handle. Falls back to the first / last fragment for a
        // bound that lands in a hidden or collapsed gap.
        let startUnit = runs.first { unitStart($0.unit) <= lower && lower < unitEnd($0.unit) }?.unit
            ?? fragments.first!.unit
        let endUnit = runs.last { unitStart($0.unit) < upper && upper <= unitEnd($0.unit) }?.unit
            ?? fragments.last!.unit
        let startIndex = fragments.firstIndex { $0.unit == startUnit } ?? 0
        let endIndex = fragments.lastIndex { $0.unit == endUnit } ?? (fragments.count - 1)

        return fragments.enumerated().map { index, fragment in
            ResolvedSelectionRect(rect: fragment.rect,
                                  containsStart: index == startIndex,
                                  containsEnd: index == endIndex)
        }
    }

    // MARK: Caret

    /// Never `.null` (spec §7): a live row's real caret, else a 2pt caret
    /// interpolated at the collapsed owner's leading edge, else a small default.
    func caretRect(forUTF16 offset: Int) -> CGRect {
        let fallback = CGRect(x: 0, y: 0, width: 2, height: 16)
        guard let anchor = model.caretAnchor(forUTF16: offset) else { return fallback }
        let ownerID = model.units[anchor.unit].ownerID
        if source.isLive(ownerID: ownerID), let rect = source.caretRect(ownerID: ownerID, anchor: anchor) {
            return rect
        }
        let (above, below) = source.bracketingLiveFrames(order: order(of: ownerID, fallback: anchor.unit))
        if let above { return CGRect(x: above.minX, y: above.maxY, width: 2, height: 16) }
        if let below { return CGRect(x: below.minX, y: below.minY - 16, width: 2, height: 16) }
        return fallback
    }

    // MARK: Closest position

    /// Global UTF-16 offset nearest an overlay-space point, snapped to a
    /// grapheme boundary and then out of any atom (the caret never lands
    /// strictly inside a pill). The single gesture-offset ingestion guard.
    func closestGlobalOffset(toContainerPoint point: CGPoint) -> Int? {
        guard let anchor = source.closestRowAnchor(toContainerPoint: point),
              let unit = model.ownerOrder[anchor.ownerID],
              let global = model.globalOffset(unit: unit, partSource: anchor.source, charOffset: anchor.localCharOffset)
        else { return nil }
        return snapIngested(global)
    }

    /// Grapheme-snap, then atom-snap, then expand-visibility-snap (each to the
    /// nearer edge) — the one place every gesture-derived offset is aligned
    /// before entering the model. Expand visibility is snapped LAST, after the
    /// atom snap, so an atom that itself sits inside a closed expand body
    /// (its edge lies past the atom snap but still inside the hidden run) is
    /// still pushed all the way out (spec §7 endpoint policy).
    func snapIngested(_ global: Int) -> Int {
        let grapheme = model.snapToGraphemeBoundary(global)
        let atomForward = model.snapAcrossAtoms(grapheme, forward: true)
        let atomBackward = model.snapAcrossAtoms(grapheme, forward: false)
        let forward = snapAcrossHiddenUnits(atomForward, forward: true)
        let backward = snapAcrossHiddenUnits(atomBackward, forward: false)
        return (grapheme - backward) <= (forward - grapheme) ? backward : forward
    }

    /// Snaps `offset` out of a hidden (closed-expand) unit — or a contiguous
    /// RUN of them — in the requested direction: never let an endpoint land
    /// inside invisible text (spec §7, "endpoints snap across closed ranges,
    /// like selecting over an image"), generalizing
    /// `SelectionTextModel.snapAcrossAtoms`'s single-span atomicity to expand
    /// visibility, which the corpus model itself can't see (it depends on
    /// `isVisible`, the caller-injected closure over `model.expandedBlocks`).
    /// An offset already in a visible unit, or exactly on a hidden unit's
    /// edge, passes through unchanged. Consecutive units under the same (or a
    /// nested) closed expand are walked as ONE hidden span, so the caret
    /// clears the whole run, not just the one unit it started in.
    private func snapAcrossHiddenUnits(_ offset: Int, forward: Bool) -> Int {
        let clamped = max(0, min(offset, model.totalUTF16Length))
        guard let unitIndex = model.units.indices.first(where: { index in
            unitStart(index) < clamped && clamped < unitEnd(index)
        }), !isVisible(model.units[unitIndex]) else { return clamped }

        var edge = unitIndex
        if forward {
            while edge + 1 < model.units.count, !isVisible(model.units[edge + 1]) { edge += 1 }
            return unitEnd(edge)
        } else {
            while edge > 0, !isVisible(model.units[edge - 1]) { edge -= 1 }
            return unitStart(edge)
        }
    }

    /// Whether the unit an atom's global range falls within is visible — the
    /// `snapIngestedRange` whole-atom short-circuit must not resurrect a
    /// hidden-expand atom's un-snapped range (spec §7 endpoint policy applies
    /// to atoms too: never land inside hidden text).
    private func isAtomVisible(_ atomRange: Range<Int>) -> Bool {
        guard let (unitIndex, _) = model.locate(utf16: atomRange.lowerBound) else { return true }
        return isVisible(model.units[unitIndex])
    }

    /// Grapheme-snap then atom-aware-snap a RANGE as a whole — the
    /// endpoint-resolution path `writeSelection` uses (Task 19 review fix
    /// round 1). If the range falls WHOLLY inside a single atom's span —
    /// e.g. a tokenizer word-seed ("Jul", "2024") or a drag-derived range
    /// landing inside the "Jul 9, 2024" date pill's `fallbackText` — expand
    /// to that atom's WHOLE range (spec §5 atomicity: "the tokenizer treats
    /// an atom's range as a single word"), rather than calling `snapIngested`
    /// on each endpoint independently. Independent per-endpoint snapping can
    /// drive BOTH ends to the SAME nearer edge and collapse to an empty
    /// range — an empty selection that still presents an edit menu over
    /// nothing (the finding this fixes). A range not wholly inside one atom
    /// snaps each endpoint independently via `snapIngested`, unchanged from
    /// before.
    func snapIngestedRange(_ range: Range<Int>) -> Range<Int> {
        let lowerRaw = min(range.lowerBound, range.upperBound)
        let upperRaw = max(range.lowerBound, range.upperBound)
        let gLower = model.snapToGraphemeBoundary(lowerRaw)
        let gUpper = model.snapToGraphemeBoundary(upperRaw)
        let grapheme = min(gLower, gUpper)..<max(gLower, gUpper)
        if !grapheme.isEmpty, let atom = model.atomRange(containing: grapheme), isAtomVisible(atom) {
            return atom
        }
        let snappedLower = snapIngested(lowerRaw)
        let snappedUpper = snapIngested(upperRaw)
        return snappedLower..<max(snappedLower, snappedUpper)
    }

    // MARK: Interpolation

    /// One whole-owner rect for a collapsed owner, spanning the vertical gap
    /// between its live neighbors (a thin band when they abut). Non-empty
    /// whenever at least one neighbor is live.
    private func interpolatedRect(order: Int) -> CGRect? {
        let (above, below) = source.bracketingLiveFrames(order: order)
        switch (above, below) {
        case let (above?, below?):
            let top = above.maxY
            let bottom = below.minY
            let x = min(above.minX, below.minX)
            let width = max(above.width, below.width)
            return CGRect(x: x, y: top, width: width, height: max(bottom - top, 2))
        case let (above?, nil):
            return CGRect(x: above.minX, y: above.maxY, width: above.width, height: 2)
        case let (nil, below?):
            return CGRect(x: below.minX, y: below.minY - 2, width: below.width, height: 2)
        case (nil, nil):
            return nil
        }
    }
}
