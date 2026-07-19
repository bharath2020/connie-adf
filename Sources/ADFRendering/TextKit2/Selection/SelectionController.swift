#if os(iOS)
import UIKit
import Observation
import ADFPreparation

/// Read-only selection engine for the TextKit 2 arm — **v3, session-scoped
/// overlay** (spec §7, phase 4; Tasks 16b/17/18/19).
///
/// Task 16 killed the v2 *ancestor-interaction* design: `UITextInteraction`
/// declines a long-press whose touch hit-tests to an interactive descendant
/// row rather than to `interaction.view`. A plain `UILongPressGestureRecognizer`
/// on the introspected content container DOES fire over those descendants. v3
/// is built on both facts:
///
/// - A transparent `SelectionOverlayView` is added to the introspected content
///   container, spanning content bounds. It conforms to `UITextInput` and hosts
///   `UITextInteraction(.nonEditable)` + `UITextSelectionDisplayInteraction` +
///   `UIEditMenuInteraction` **on itself**, so `interaction.view ==
///   interaction.textInput == overlay` — the exact condition Task 16 proved
///   necessary for the interaction to drive selection.
/// - **Idle:** the overlay is hit-test transparent (`isUserInteractionEnabled
///   = false`). Links, checkboxes, the video facade, code/table pans behave
///   natively; per-frame cost is zero.
/// - **Session start:** our long-press recognizer on the *container* begins a
///   session when the press lands over a TK2 row: word-select at the point via
///   the tokenizer over the REAL corpus (`SelectionTextModel`, Task 18), enable
///   the overlay, make it first responder, seed `selectedTextRange`, activate
///   the display interaction, present the edit menu.
/// - **Session active:** touches over the selection UI hit-test TO the overlay,
///   so `UITextInteraction` drives handles / drags / menu natively. A tap
///   outside ends the session; so does first-responder resignation from any
///   path.
///
/// **Task 19 productionization.** The crude 16b stand-ins are gone: the text
/// model is the real UTF-16 prefix-sum `SelectionTextModel`; geometry comes
/// from live per-row TK2 layouts via `RowGeometryRegistry` (`SelectionGeometry`
/// resolver + `RowGeometrySource`), with collapsed rows interpolated from live
/// neighbors; selection state lives in `model.selection` (a non-observed box),
/// with `model.selectionSessionActive` the one coarse Bool SwiftUI observes.
@MainActor
final class SelectionController: NSObject {
    weak var model: ADFDocumentModel?

    /// Per-document row-geometry registry (Task 17): live TK2 rows self-register
    /// here so a session can query real per-row layout on demand. Its `orderOf`
    /// is wired to the text model's document order in `rebuildTextModel`.
    let geometryRegistry = RowGeometryRegistry()

    private weak var container: UIView?
    private weak var scrollView: UIScrollView?
    private var attached = false

    /// The real corpus text model (Task 18), rebuilt on attach (and, in Task
    /// 22, on epoch bump). Owned here; handed to the overlay so its `UITextInput`
    /// arithmetic and the geometry resolver both read one source of truth.
    private var textModel = SelectionTextModel.build(orderedItems: [])

    /// The selection surface. Strong-held: it is our view, inserted into the
    /// (foreign, SwiftUI-owned) container, and must outlive a container
    /// re-layout that could otherwise drop an unreferenced subview.
    private let overlay: SelectionOverlayView
    private let geometrySource: RowGeometrySource
    private let editMenu: UIEditMenuInteraction

    private var longPress: UILongPressGestureRecognizer?
    private var tapClear: UITapGestureRecognizer?
    /// Passive observer of handle-drag touch-moves on the overlay: it never
    /// steals touches (`cancelsTouchesInView = false`, simultaneous with the
    /// `UITextInteraction` drag) — its only job is to feed the touch's
    /// Y-in-viewport to `autoscroller` on `.changed` and stop it on end.
    private var autoscrollPan: UIPanGestureRecognizer?

    /// Drag-past-edge autoscroll (Task 20). Constructed in `attach` once the
    /// scroll view is known; drives a `CADisplayLink` only during an active
    /// edge-drag and writes `model.anchors.topRow` on each step (§8b).
    private var autoscroller: SelectionAutoscroller?

    /// `ownerID` → `topLevelBlockID`, rebuilt with the text model. The
    /// autoscroll top-row lookup maps the live row at the viewport top to the
    /// top-level block ID that `anchors.topRow` / `scrollTo` speak (a nested
    /// row's owner is a sub-block; the scroll anchor is always its top-level
    /// block).
    private var ownerToTopLevel: [String: String] = [:]

    /// True from session start until teardown. Gates the recognizers on the
    /// gesture path without reading the observed `model.selectionSessionActive`.
    private var sessionActive = false

    /// The document's shared table h-scroll registry (Task 22 geometry
    /// staleness). Wired by `ScrollViewIntrospector` from the environment's
    /// `TableScrollSync` — decoupled from `attach(to:scrollView:)`'s
    /// container discovery so the hook is live as soon as SwiftUI hands it
    /// over, independent of when (or whether) the introspector finds its
    /// container. A plain callback registration (`onOffsetChanged`), not an
    /// `Observation` read — see `TableScrollSync`'s doc comment.
    var tableScrollSync: TableScrollSync? {
        didSet {
            // `ScrollViewIntrospector.updateUIView` assigns this every
            // SwiftUI update pass (the environment value has no other
            // natural injection point); skip re-wiring when it's the SAME
            // stable `@State` instance so a hot update loop never churns the
            // closure.
            guard tableScrollSync !== oldValue else { return }
            tableScrollSync?.onOffsetChanged = { [weak self] _, _ in
                guard let self, self.sessionActive else { return }
                self.selectionGeometryDidGoStale()
            }
        }
    }

    /// One-runloop-turn coalescing flag for `selectionGeometryDidGoStale()`
    /// (Task 22 deliverable 4 — see the "Geometry staleness" section below).
    private var geometryStaleQueued = false

    init(model: ADFDocumentModel) {
        self.model = model
        self.geometrySource = RowGeometrySource(registry: geometryRegistry)
        self.overlay = SelectionOverlayView(model: model, geometrySource: geometrySource)
        self.editMenu = UIEditMenuInteraction(delegate: nil)
        super.init()
        overlay.addInteraction(editMenu)
        overlay.onResign = { [weak self] in self?.endSession() }
        geometrySource.referenceView = overlay
        // Collapsed-height corrections on row re-entry (Task 22): ANY live
        // row (re)materializing can mean a formerly-interpolated rect was
        // just superseded by the row's real geometry. A plain callback, not
        // `Observation` — `RowGeometryRegistry` is the selection-only
        // registry already, so this never adds a scroll-path read of its
        // own; the `sessionActive` check keeps idle cost to that one guard.
        geometryRegistry.onRegister = { [weak self] _ in
            guard let self, self.sessionActive else { return }
            self.selectionGeometryDidGoStale()
        }
    }

    /// Installs the overlay + gesture recognizers on the introspected content
    /// container. Called once by `ScrollViewIntrospector`. Idempotent.
    func attach(to container: UIView, scrollView: UIScrollView) {
        guard !attached else { return }
        attached = true
        self.container = container
        self.scrollView = scrollView

        // Mid-gesture cancel / clamp (Task 22) — wired here, not in `init`:
        // `ADFDocumentView.init()` constructs a `SelectionController(model:)`
        // on EVERY SwiftUI re-init of the view struct (only the FIRST such
        // construction's result ever becomes the persistent `@State`
        // instance; every later one is a throwaway that this method's
        // `attached` guard ensures never reaches here). Wiring the model
        // callback in `init` would have the LATEST throwaway instance's
        // closure silently overwrite the real, attached instance's — every
        // subsequent epoch bump would then call `documentDidChange()` on a
        // controller that was never attached (`sessionActive` permanently
        // false, no overlay ever shown), leaving a REAL active session's
        // native selection UI stuck on screen after a mutation, even though
        // `model.selection.utf16Range` itself was correctly cleared. Setting
        // it here, guarded by `attached`, ties the callback to the ONE
        // instance that ever calls `attach` successfully.
        model?.onDocumentEpochChanged = { [weak self] in self?.documentDidChange() }

        rebuildTextModel()

        overlay.isUserInteractionEnabled = false
        overlay.frame = container.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(overlay)

        let lp = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        lp.cancelsTouchesInView = false
        lp.delaysTouchesBegan = false
        lp.delaysTouchesEnded = false
        lp.delegate = self
        container.addGestureRecognizer(lp)
        longPress = lp

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        container.addGestureRecognizer(tap)
        tapClear = tap

        // Drag-past-edge autoscroll. The provider maps the row now at the
        // viewport top to its top-level block ID; the step closure writes it
        // into the plain `anchors` box (§8b — invalidates no view). The pan
        // observer on the overlay feeds touch-moves during a native handle drag.
        let scroller = SelectionAutoscroller(scrollView: scrollView)
        scroller.topRowProvider = { [weak self] _ in self?.topLevelBlockIDAtViewportTop() }
        scroller.onScrollStep = { [weak self] rowID in
            guard let rowID, let self else { return }
            self.model?.anchors.topRow = rowID
        }
        autoscroller = scroller

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleAutoscrollPan(_:)))
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        pan.delegate = self
        overlay.addGestureRecognizer(pan)
        autoscrollPan = pan
    }

    /// Rebuilds the corpus text model from the search index's document-order
    /// items and wires the geometry registry's `orderOf` to the model's real
    /// document order (replacing Task 17's `.max` stub). Called on attach; in
    /// Task 22 also on an epoch bump.
    func rebuildTextModel() {
        guard let model else { return }
        textModel = SelectionTextModel.build(orderedItems: model.search.orderedIndexItems)
        overlay.textModel = textModel
        geometryRegistry.orderOf = { [textModel] ownerID in textModel.ownerOrder[ownerID] ?? .max }
        ownerToTopLevel = Dictionary(
            textModel.units.map { ($0.ownerID, $0.topLevelBlockID) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    // MARK: - Document epoch (Task 22 — mid-gesture cancel / clamp)

    /// Reacts to `ADFDocumentModel.onDocumentEpochChanged` (an epoch bump
    /// from `load()` or a non-tail-append `apply()`, spec §7): rebuilds the
    /// text model against the new document, then re-validates any live
    /// selection through the pure `SelectionState.clampedRange` guard. A
    /// mismatched or now-out-of-range range is cleared/clamped through
    /// `inputDelegate` BEFORE the caller's next query, so no stale offset
    /// ever reaches `text(in:)` / `selectionRects(for:)`. If a gesture is
    /// mid-flight, the native interaction's own recognizers are cancelled
    /// FIRST — there is no public "cancel" API, so this uses UIKit's
    /// documented technique of disabling then re-enabling each one, which
    /// drops whatever touch it is mid-tracking — so no further touch-move
    /// can re-derive a position against the OLD layout. The session then
    /// ends cleanly if the range didn't survive, or continues with the
    /// clamped range (and a fresh rect re-query) if it did.
    func documentDidChange() {
        rebuildTextModel()
        guard let model, let previous = model.selection.utf16Range else { return }

        let clamped = SelectionState.clampedRange(
            previous,
            stampEpoch: model.selection.epoch,
            currentEpoch: model.documentEpoch,
            documentUTF16Length: textModel.totalUTF16Length
        )
        guard clamped != previous else { return } // fully unaffected — nothing to guard

        if sessionActive { overlay.cancelActiveInteractionGesture() }

        overlay.inputDelegate?.selectionWillChange(overlay)
        model.selection.utf16Range = clamped
        model.selection.epoch = model.documentEpoch
        overlay.inputDelegate?.selectionDidChange(overlay)

        if clamped == nil {
            if sessionActive { endSession() }
        } else {
            overlay.nudgeSelectionDisplay()
        }
    }

    // MARK: - Geometry staleness (Task 22 deliverable 4)

    /// Coalesced-per-runloop geometry re-query: collapsed-height corrections
    /// on row re-entry (`RowGeometryRegistry.onRegister`), expand toggles
    /// (`observeExpandedBlocksIfActive`), and table h-scroll
    /// (`TableScrollSync.onOffsetChanged`) all route here. Multiple signals
    /// within one run-loop turn collapse into ONE
    /// `selectionWillChange`/`DidChange` pair (via `SelectionOverlayView.
    /// refreshGeometry()`), so UIKit re-queries `selectionRects`/`caretRect`
    /// exactly once, not once per underlying signal. The range itself is
    /// untouched — this is pure rect invalidation. Only meaningful while a
    /// session is active; idle cost is the guard alone (no dispatch, no
    /// work) — every caller already checks `sessionActive` before calling
    /// this, and it checks again defensively.
    func selectionGeometryDidGoStale() {
        guard sessionActive, !geometryStaleQueued else { return }
        geometryStaleQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.geometryStaleQueued = false
            guard self.sessionActive else { return }
            self.overlay.refreshGeometry()
        }
    }

    /// Observes `model.expandedBlocks` (an `@Observable` property, so
    /// `Observation` — not a plain callback — is the only mechanism
    /// available) ONLY while a session is active: an expand toggle is a rect
    /// invalidation, never a text-model change (offsets stay in the offset
    /// space regardless of visibility — the offset-space-stability
    /// decision), so this never touches `model.selection`. Re-arms itself on
    /// every change; the `onChange` callback checks `sessionActive` before
    /// re-registering, so the tracking chain — and its cost — ends the
    /// instant a session ends, matching the zero-idle-cost discipline the
    /// other two staleness signals get via plain callbacks.
    private func observeExpandedBlocksIfActive() {
        guard let model, sessionActive else { return }
        withObservationTracking {
            _ = model.expandedBlocks
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.selectionGeometryDidGoStale()
                self.observeExpandedBlocksIfActive()
            }
        }
    }

    // MARK: - Session lifecycle

    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let container, let model else { return }
        let point = g.location(in: container)

        // Long-press DURING a live session → restart a fresh word session at
        // the press point (spec §7 "long-press-inside-selection → new word
        // session"). We re-seed only — the overlay stays first responder and
        // the session stays active — so a press inside the current selection
        // reselects the word under the finger rather than being swallowed by
        // the interaction's own long-press. `tk2Row(at:)` can't be used here
        // (the enabled overlay is frontmost and hit-tests to itself over the
        // selection); `beginSession` resolves geometry via the registry, not
        // hit-testing, and returns `false` on a miss without disturbing the
        // existing selection.
        if sessionActive {
            if overlay.beginSession(atContainerPoint: point), overlay.selectedTextRange != nil {
                presentMenu(near: point)
            }
            return
        }

        guard tk2Row(at: point) != nil else { return }

        // Rebuild the corpus model from the CURRENT index: the introspector
        // attaches before streaming indexing finishes, so the attach-time model
        // can be empty/stale. Cheap and off the scroll path (session start only).
        rebuildTextModel()

        overlay.frame = container.bounds
        container.bringSubviewToFront(overlay)
        overlay.isUserInteractionEnabled = true

        // `sessionActive` / `selectionSessionActive` / the presented menu only
        // commit once a seed offset actually resolves — a seed miss undoes the
        // tentative "enable interaction" instead of leaving an
        // interaction-enabled empty session behind (review fix round 1, minor #3).
        guard overlay.beginSession(atContainerPoint: point) else {
            overlay.isUserInteractionEnabled = false
            return
        }

        sessionActive = true
        // The ONE observed flip at session start (first non-empty selection).
        model.setSelectionSessionActive(true)
        observeExpandedBlocksIfActive()
        presentMenu(near: point)
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard sessionActive, let container else { return }
        let point = g.location(in: container)
        if overlay.selectionContains(point) { return }
        endSession()
    }

    /// Single idempotent teardown, reached from the tap-clear recognizer AND
    /// `SelectionOverlayView.resignFirstResponder`. `sessionActive` is cleared
    /// first so the re-entrant resign call is a guarded no-op.
    private func endSession() {
        guard sessionActive else { return }
        sessionActive = false
        autoscroller?.stop()
        editMenu.dismissMenu()
        overlay.clearSelection()
        if overlay.isFirstResponder { _ = overlay.resignFirstResponder() }
        overlay.isUserInteractionEnabled = false
        // The ONE observed flip at session end.
        model?.setSelectionSessionActive(false)
    }

    private func presentMenu(near point: CGPoint) {
        guard let range = overlay.selectedTextRange else { return }
        let rect = overlay.firstRect(for: range)
        let source = rect.isNull || rect.isEmpty
            ? point
            : CGPoint(x: rect.midX, y: rect.minY)
        let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: source)
        editMenu.presentEditMenu(with: config)
    }

    // MARK: - Autoscroll

    /// Feeds the autoscroller the touch's Y-in-viewport during a native handle
    /// drag. `.began`/`.changed` engage/adjust the ramp; end/cancel tears the
    /// display link down. Passive — it never affects the drag it observes.
    @objc private func handleAutoscrollPan(_ g: UIPanGestureRecognizer) {
        guard sessionActive, let scrollView, let autoscroller else { return }
        switch g.state {
        case .began, .changed:
            // `location(in: scrollView)` is in content coordinates (bounds
            // origin == contentOffset); subtracting the offset yields a
            // viewport Y that stays stable under a stationary finger as the
            // content autoscrolls beneath it.
            let contentY = g.location(in: scrollView).y
            let viewportY = contentY - scrollView.contentOffset.y
            autoscroller.update(touchYInBounds: viewportY, viewportHeight: scrollView.bounds.height)
        case .ended, .cancelled, .failed:
            autoscroller.stop()
        default:
            break
        }
    }

    /// The top-level block ID whose row currently sits at the viewport top —
    /// the value `anchors.topRow` / `scrollTo` speak. Binary search over the
    /// registry's LIVE, document-ordered rows (bounded to materialized rows;
    /// never an all-registered scan): row bottoms are monotonic in document
    /// order, so the first live row whose bottom is below the viewport-top line
    /// is the top row. Runs per autoscroll step (an active edge-drag only).
    private func topLevelBlockIDAtViewportTop() -> String? {
        guard let scrollView else { return nil }
        let topY = scrollView.contentOffset.y
        let entries = geometryRegistry.liveEntriesInDocumentOrder()
        guard !entries.isEmpty else { return nil }
        func bottomInScrollView(_ i: Int) -> CGFloat {
            let v = entries[i].view
            return v.convert(v.bounds, to: scrollView).maxY
        }
        var lo = 0, hi = entries.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if bottomInScrollView(mid) <= topY { lo = mid + 1 } else { hi = mid }
        }
        let index = lo < entries.count ? lo : entries.count - 1
        return ownerToTopLevel[entries[index].ownerID]
    }

    // MARK: - Helpers

    /// Deepest `TextKit2RowUIView` under `point` (container coordinates), or
    /// nil. Runs while the overlay is still idle (disabled), so `hitTest`
    /// passes straight through it to the real rows underneath.
    private func tk2Row(at point: CGPoint) -> TextKit2RowUIView? {
        guard let hit = container?.hitTest(point, with: nil) else { return nil }
        var view: UIView? = hit
        while let current = view {
            if let row = current as? TextKit2RowUIView { return row }
            view = current.superview
        }
        return nil
    }
}

extension SelectionController: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        // Tap-to-clear fires only during a session, and NOT when the touch
        // hit-tests into an interactive descendant — a `UIControl` (checkbox /
        // button facade) or a NESTED `UIScrollView` (code/table horizontal
        // pan). Those own the tap so it must not be read as a blank-space
        // clear; text links keep working through `cancelsTouchesInView =
        // false` regardless. Spec §7: failure by delegate, never a `hitTest`
        // override.
        if gestureRecognizer === tapClear {
            return sessionActive && !touchHitsDescendantControl(touch)
        }
        return true
    }

    /// Walks up from the touch's hit view; true if a `UIControl` or a nested
    /// scroll view (i.e. one that is not the document's own scroll view) is
    /// encountered before the container.
    private func touchHitsDescendantControl(_ touch: UITouch) -> Bool {
        var view: UIView? = touch.view
        while let current = view, current !== container {
            if current is UIControl { return true }
            if let sv = current as? UIScrollView, sv !== scrollView { return true }
            view = current.superview
        }
        return false
    }
}

// MARK: - Live-row geometry source

/// The production `SelectionGeometrySource`: resolves per-owner selection
/// geometry from live `TextKit2RowUIView`s in the `RowGeometryRegistry`, and
/// brackets collapsed owners with their live neighbors. All rects/points are in
/// the overlay's coordinate space (`referenceView`).
@MainActor
final class RowGeometrySource: SelectionGeometrySource {
    private let registry: RowGeometryRegistry
    /// The overlay — the `UITextInput`'s own coordinate space, which row rects
    /// convert into and container points convert from.
    weak var referenceView: UIView?

    init(registry: RowGeometryRegistry) { self.registry = registry }

    private func row(_ ownerID: String) -> TextKit2RowUIView? {
        registry.liveView(for: ownerID) as? TextKit2RowUIView
    }

    func isLive(ownerID: String) -> Bool {
        guard let row = row(ownerID) else { return false }
        return row.window != nil
    }

    func rects(ownerID: String, slice: SelectionTextModel.PartSlice) -> [CGRect] {
        guard let row = row(ownerID), let content = row.content, let reference = referenceView else {
            return []
        }
        let nsRange: NSRange
        switch slice.source {
        case .textSegment(let index):
            guard content.segmentStrings.indices.contains(index) else { return [] }
            nsRange = TextRowContent.utf16Range(charRange: slice.localCharRange, inSegment: index, of: content)
        case .atom(let id):
            // The whole 1-char U+FFFC attachment — a partial hit selects the
            // whole pill (atomicity), so the atom's own `localCharRange` is
            // ignored in favor of the single attachment char (Task 10).
            guard let segIndex = row.segmentIndex(forAtomID: id),
                  content.segmentUTF16Starts.indices.contains(segIndex) else { return [] }
            nsRange = NSRange(location: content.segmentUTF16Starts[segIndex], length: 1)
        }
        return row.selectionRects(forUTF16: nsRange).map { row.convert($0, to: reference) }
    }

    func caretRect(ownerID: String, anchor: SelectionTextModel.CaretAnchor) -> CGRect? {
        guard let row = row(ownerID), let content = row.content, let reference = referenceView else {
            return nil
        }
        let location: Int
        switch anchor.source {
        case .textSegment(let index):
            guard content.segmentStrings.indices.contains(index) else { return nil }
            location = TextRowContent.utf16Range(
                charRange: anchor.localCharOffset..<anchor.localCharOffset, inSegment: index, of: content
            ).location
        case .atom(let id):
            guard let segIndex = row.segmentIndex(forAtomID: id),
                  content.segmentUTF16Starts.indices.contains(segIndex) else { return nil }
            location = content.segmentUTF16Starts[segIndex] + (anchor.localCharOffset > 0 ? 1 : 0)
        }
        return row.caretRect(atUTF16: location).map { row.convert($0, to: reference) }
    }

    func closestRowAnchor(
        toContainerPoint point: CGPoint
    ) -> (ownerID: String, source: SearchTextUnit.Part.Source, localCharOffset: Int)? {
        guard let reference = referenceView else { return nil }
        // Nearest live row by vertical distance (the containing row when the
        // point is over text). A scan of live rows — selection-path only.
        var best: (ownerID: String, row: TextKit2RowUIView, distance: CGFloat)?
        for entry in registry.liveEntriesInDocumentOrder() {
            guard let row = entry.view as? TextKit2RowUIView else { continue }
            let frame = row.convert(row.bounds, to: reference)
            let distance = (point.y >= frame.minY && point.y <= frame.maxY)
                ? 0 : min(abs(point.y - frame.minY), abs(point.y - frame.maxY))
            if best == nil || distance < best!.distance { best = (entry.ownerID, row, distance) }
        }
        guard let best else { return nil }
        // Clamp into the row's bounds so `closestUTF16Offset` finds a fragment
        // even when the point is above/below the row's text.
        let inRow = reference.convert(point, to: best.row)
        let clamped = CGPoint(
            x: inRow.x,
            y: min(max(inRow.y, best.row.bounds.minY), max(best.row.bounds.minY, best.row.bounds.maxY - 0.5))
        )
        guard let rowOffset = best.row.closestUTF16Offset(to: clamped),
              let anchor = best.row.rowAnchor(atRowUTF16: rowOffset) else { return nil }
        return (best.ownerID, anchor.source, anchor.localCharOffset)
    }

    func bracketingLiveFrames(order: Int) -> (above: CGRect?, below: CGRect?) {
        guard let reference = referenceView else { return (nil, nil) }
        return registry.liveFrames(bracketingOrder: order) { $0.convert($0.bounds, to: reference) }
    }
}

// MARK: - UITextInput value types

/// A position in the virtual document — a global UTF-16 offset (the tokenizer's
/// currency; `UITextInputStringTokenizer` computes word boundaries in UTF-16).
final class SelectionTextPosition: UITextPosition {
    let offset: Int
    init(_ offset: Int) { self.offset = offset }
}

/// A half-open global UTF-16 range `[lowerBound, upperBound)`.
final class SelectionTextRange: UITextRange {
    let range: Range<Int>
    init(_ range: Range<Int>) { self.range = range }
    override var start: UITextPosition { SelectionTextPosition(range.lowerBound) }
    override var end: UITextPosition { SelectionTextPosition(range.upperBound) }
    override var isEmpty: Bool { range.isEmpty }
}

/// One resolved selection region wrapped for UIKit. `containsStart`/`containsEnd`
/// come from range membership (computed in `SelectionGeometryResolver`), never
/// array position.
final class ADFSelectionRect: UITextSelectionRect {
    private let _rect: CGRect
    private let _containsStart: Bool
    private let _containsEnd: Bool
    init(_ resolved: ResolvedSelectionRect) {
        _rect = resolved.rect
        _containsStart = resolved.containsStart
        _containsEnd = resolved.containsEnd
    }
    override var rect: CGRect { _rect }
    override var writingDirection: NSWritingDirection { .leftToRight }
    override var containsStart: Bool { _containsStart }
    override var containsEnd: Bool { _containsEnd }
    override var isVertical: Bool { false }
}

// MARK: - The selection surface

/// The transparent selection surface: a `UIView` that is also the read-only
/// `UITextInput`. Arithmetic delegates to `SelectionTextModel` in UTF-16;
/// geometry to `SelectionGeometryResolver` over live TK2 layouts. Selection
/// state lives in `model.selection` (non-observed).
final class SelectionOverlayView: UIView, UITextInput, UITextSelectionDisplayInteractionDelegate {
    private weak var model: ADFDocumentModel?
    private let geometrySource: SelectionGeometrySource
    private let interaction = UITextInteraction(for: .nonEditable)

    /// The real corpus text model, set by the controller on attach/rebuild.
    var textModel = SelectionTextModel.build(orderedItems: [])

    /// Draws the native selection affordances from the same `UITextInput`
    /// geometry. **Task-16b discovery:** `UITextInteraction` alone does not
    /// render a programmatically-seeded selection; the display interaction is
    /// mandatory (activated per session, `setNeedsSelectionUpdate()` on every
    /// `selectedTextRange` mutation).
    private var selectionDisplay: UITextSelectionDisplayInteraction?

    /// Ends the session when this view resigns first responder from ANY path.
    var onResign: (() -> Void)?

    init(model: ADFDocumentModel, geometrySource: SelectionGeometrySource) {
        self.model = model
        self.geometrySource = geometrySource
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        interaction.textInput = self
        addInteraction(interaction)
        let display = UITextSelectionDisplayInteraction(textInput: self, delegate: self)
        display.isActivated = false
        addInteraction(display)
        selectionDisplay = display
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    // MARK: Geometry resolver + visibility

    /// A unit is visible iff every expand ancestor is open — the expand-edge
    /// predicate (spec §7). Hidden units contribute no rects, no copy text, no
    /// closest-position candidate.
    private func isUnitVisible(_ unit: SelectionTextModel.Unit) -> Bool {
        guard let model else { return true }
        return unit.expandAncestorIDs.allSatisfy(model.expandedBlocks.contains)
    }

    private var resolver: SelectionGeometryResolver {
        SelectionGeometryResolver(model: textModel, source: geometrySource, isVisible: { [weak self] unit in
            self?.isUnitVisible(unit) ?? true
        })
    }

    // MARK: Session driving

    /// Word-select at the press point via the tokenizer over the real corpus,
    /// and push the selection to UIKit. The overlay must already be
    /// first-responder-eligible and enabled (the controller does that first).
    /// Returns `false` on a seed miss (no resolvable geometry under the
    /// point) WITHOUT touching first-responder/selection-display state, so
    /// the caller can undo its tentative "enable interaction" and never mark
    /// the session active (Task 19 review fix round 1, minor #3 — a failed
    /// seed used to leave an interaction-enabled empty session behind).
    @discardableResult
    func beginSession(atContainerPoint point: CGPoint) -> Bool {
        guard let seed = resolver.closestGlobalOffset(toContainerPoint: point) else { return false }
        _ = becomeFirstResponder()
        inputDelegate?.selectionWillChange(self)
        let seedPosition = SelectionTextPosition(seed)
        let word = wordRange(around: seedPosition) ?? fallbackRange(around: seed)
        writeSelection(word.range)
        inputDelegate?.selectionDidChange(self)
        selectionDisplay?.isActivated = true
        selectionDisplay?.setNeedsSelectionUpdate()
        selectionDisplay?.layoutManagedSubviews()
        return true
    }

    /// The tokenizer's enclosing word at a position, tried in both storage
    /// directions (a position at a word's trailing edge encloses in the
    /// backward direction only). UTF-16 boundaries are the tokenizer's own.
    private func wordRange(around position: SelectionTextPosition) -> SelectionTextRange? {
        for direction in [UITextDirection.storage(.forward), UITextDirection.storage(.backward)] {
            if let range = tokenizer.rangeEnclosingPosition(position, with: .word, inDirection: direction)
                as? SelectionTextRange, !range.range.isEmpty {
                return range
            }
        }
        return nil
    }

    /// A single-grapheme fallback when the tokenizer finds no word (whitespace,
    /// punctuation runs) — never an empty seed.
    private func fallbackRange(around offset: Int) -> SelectionTextRange {
        let total = textModel.totalUTF16Length
        if offset < total {
            let upper = resolver.snapIngested(min(offset + 1, total))
            return SelectionTextRange(offset..<max(offset + 1, upper))
        }
        let lower = resolver.snapIngested(max(offset - 1, 0))
        return SelectionTextRange(min(lower, offset)..<offset)
    }

    func clearSelection() {
        let hadSelection = model?.selection.utf16Range != nil
        if hadSelection {
            inputDelegate?.selectionWillChange(self)
            model?.selection.utf16Range = nil
            inputDelegate?.selectionDidChange(self)
        }
        selectionDisplay?.isActivated = false
        selectionDisplay?.setNeedsSelectionUpdate()
    }

    // MARK: Task 22 — mid-gesture cancel / geometry staleness

    /// Force-cancels any touch the native `UITextInteraction`'s own
    /// recognizers are mid-tracking, WITHOUT touching the range — there is no
    /// public "cancel" API; UIKit's documented technique is disabling then
    /// re-enabling a gesture recognizer, which drops whatever touch it is
    /// tracking. Called by `SelectionController.documentDidChange()` BEFORE
    /// the range itself is clamped/cleared, so no further touch-move can
    /// re-derive a position against the OLD document layout. Safe to call
    /// when nothing is in flight (a no-op recognizer state either way).
    func cancelActiveInteractionGesture() {
        for gesture in interaction.gesturesForFailureRequirements {
            gesture.isEnabled = false
            gesture.isEnabled = true
        }
    }

    /// Nudges the display interaction to re-derive handle/rect geometry from
    /// the CURRENT range, without bracketing `inputDelegate` — for callers
    /// that already manage their own bracket around a range write
    /// (`SelectionController.documentDidChange()`'s clamp path), so the
    /// signal isn't doubled.
    func nudgeSelectionDisplay() {
        selectionDisplay?.setNeedsSelectionUpdate()
        selectionDisplay?.layoutManagedSubviews()
    }

    /// Re-queries selection rects/carets from UIKit WITHOUT touching the
    /// range itself (Task 22 geometry-staleness coalescing: expand toggles,
    /// collapsed-height corrections on row re-entry, table h-scroll).
    /// Brackets with `inputDelegate.selectionWillChange`/`DidChange` (the
    /// spec's named re-query signal) and nudges the display interaction
    /// directly, mirroring `beginSession`'s own pattern — the display
    /// interaction's handle geometry only refreshes for certain on an
    /// explicit `setNeedsSelectionUpdate()`. A no-op when there is no live
    /// selection to refresh.
    func refreshGeometry() {
        guard currentRange != nil else { return }
        inputDelegate?.selectionWillChange(self)
        inputDelegate?.selectionDidChange(self)
        nudgeSelectionDisplay()
    }

    /// Is `point` (overlay coordinates) inside the current selection? Used to
    /// distinguish a native tap (inside) from a session-ending tap (outside).
    func selectionContains(_ point: CGPoint) -> Bool {
        guard let range = currentRange else { return false }
        return resolver.selectionRects(forUTF16: range).contains { $0.rect.contains(point) }
    }

    // MARK: Selection state (the non-observed model box)

    /// The live range from `model.selection`, epoch-guarded and clamped to the
    /// current document length via `SelectionState.clampedRange` (Task 22's
    /// pure, `swift test`-able core) — a stale epoch (a document generation
    /// that no longer exists) or an out-of-range tail reports no selection,
    /// not a degenerate zero-length caret that could still present a menu
    /// (Task 19 review fix round 1, minor #1).
    private var currentRange: Range<Int>? {
        guard let model else { return nil }
        return SelectionState.clampedRange(
            model.selection.utf16Range,
            stampEpoch: model.selection.epoch,
            currentEpoch: model.documentEpoch,
            documentUTF16Length: textModel.totalUTF16Length
        )
    }

    /// Writes a range into the model box (a non-observed write) via the
    /// resolver's single ingestion guard, `snapIngestedRange`: whole-atom
    /// expansion when the range lands entirely inside one atom (spec §5
    /// atomicity), else grapheme-then-nearer-edge snapping of each endpoint
    /// independently (spec §7 "endpoints snap to the nearer pill edge"). Rect
    /// atomicity — a range that overlaps a pill draws the whole pill — is
    /// handled separately by `partSlices`. If snapping collapses the range to
    /// empty, no selection is written (empty-range hygiene, review fix round
    /// 1) rather than persisting a degenerate range.
    private func writeSelection(_ range: Range<Int>) {
        guard let model else { return }
        let snapped = resolver.snapIngestedRange(range)
        guard !snapped.isEmpty else {
            model.selection.utf16Range = nil
            selectionDisplay?.setNeedsSelectionUpdate()
            return
        }
        model.selection.utf16Range = snapped
        model.selection.epoch = model.documentEpoch // Task 22: the real document epoch
        selectionDisplay?.setNeedsSelectionUpdate()
    }

    // MARK: UITextInput (read-only)

    private func clamp(_ offset: Int) -> Int { max(0, min(offset, textModel.totalUTF16Length)) }

    func text(in range: UITextRange) -> String? {
        guard let range = range as? SelectionTextRange else { return nil }
        // Explicit clamp guard (Task 22): a `SelectionTextRange` UIKit is
        // still holding could, in principle, span past `textModel`'s bounds
        // right after an epoch bump shrank the document (`documentDidChange`
        // rebuilds `textModel` synchronously, but a `UITextRange` object
        // captured by UIKit before that point is just inert data — clamping
        // here, at the one `text(in:)` entry point, is defense-in-depth
        // alongside `SelectionTextModel.text(inUTF16:)`'s own internal clamp.
        let lower = clamp(range.range.lowerBound)
        let upper = max(lower, clamp(range.range.upperBound))
        return textModel.text(inUTF16: lower..<upper, isVisible: { [weak self] in self?.isUnitVisible($0) ?? true })
    }
    func replace(_ range: UITextRange, withText text: String) {}
    var selectedTextRange: UITextRange? {
        get { currentRange.map { SelectionTextRange($0) } }
        set {
            if let range = (newValue as? SelectionTextRange)?.range {
                writeSelection(range)
            } else {
                model?.selection.utf16Range = nil
                selectionDisplay?.setNeedsSelectionUpdate()
            }
        }
    }
    var markedTextRange: UITextRange? { nil }
    var markedTextStyle: [NSAttributedString.Key: Any]? { get { nil } set {} }
    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {}
    func unmarkText() {}
    var beginningOfDocument: UITextPosition { SelectionTextPosition(0) }
    var endOfDocument: UITextPosition { SelectionTextPosition(textModel.totalUTF16Length) }
    func textRange(from f: UITextPosition, to t: UITextPosition) -> UITextRange? {
        guard let f = f as? SelectionTextPosition, let t = t as? SelectionTextPosition else { return nil }
        let lower = min(f.offset, t.offset)
        let upper = max(f.offset, t.offset)
        return SelectionTextRange(clamp(lower)..<clamp(upper))
    }
    func position(from p: UITextPosition, offset: Int) -> UITextPosition? {
        guard let p = p as? SelectionTextPosition else { return nil }
        return SelectionTextPosition(clamp(p.offset + offset))
    }
    func position(from p: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        position(from: p, offset: direction == .left || direction == .up ? -offset : offset)
    }
    func compare(_ a: UITextPosition, to b: UITextPosition) -> ComparisonResult {
        guard let a = a as? SelectionTextPosition, let b = b as? SelectionTextPosition else { return .orderedSame }
        return a.offset < b.offset ? .orderedAscending : a.offset > b.offset ? .orderedDescending : .orderedSame
    }
    func offset(from f: UITextPosition, to t: UITextPosition) -> Int {
        ((t as? SelectionTextPosition)?.offset ?? 0) - ((f as? SelectionTextPosition)?.offset ?? 0)
    }
    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        direction == .left || direction == .up ? range.start : range.end
    }
    func characterRange(byExtending p: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        guard let p = p as? SelectionTextPosition else { return nil }
        switch direction {
        case .left, .up: return SelectionTextRange(clamp(p.offset - 1)..<p.offset)
        default: return SelectionTextRange(p.offset..<clamp(p.offset + 1))
        }
    }
    func baseWritingDirection(for p: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection { .leftToRight }
    func setBaseWritingDirection(_ w: NSWritingDirection, for range: UITextRange) {}

    func caretRect(for p: UITextPosition) -> CGRect {
        guard let p = p as? SelectionTextPosition else { return CGRect(x: 0, y: 0, width: 2, height: 16) }
        return resolver.caretRect(forUTF16: p.offset)
    }
    func firstRect(for range: UITextRange) -> CGRect {
        selectionRects(for: range).first?.rect ?? .null
    }
    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        guard let range = range as? SelectionTextRange else { return [] }
        return resolver.selectionRects(forUTF16: range.range).map(ADFSelectionRect.init)
    }
    func closestPosition(to point: CGPoint) -> UITextPosition? {
        guard let offset = resolver.closestGlobalOffset(toContainerPoint: point) else {
            return SelectionTextPosition(clamp(0))
        }
        return SelectionTextPosition(offset)
    }
    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        guard let range = range as? SelectionTextRange,
              let position = closestPosition(to: point) as? SelectionTextPosition else { return nil }
        let clamped = min(max(position.offset, range.range.lowerBound), range.range.upperBound)
        return SelectionTextPosition(clamped)
    }
    func characterRange(at point: CGPoint) -> UITextRange? {
        guard let position = closestPosition(to: point) as? SelectionTextPosition else { return nil }
        return SelectionTextRange(position.offset..<clamp(position.offset + 1))
    }
    var hasText: Bool { textModel.totalUTF16Length > 0 }
    func insertText(_ text: String) {}
    func deleteBackward() {}

    weak var inputDelegate: UITextInputDelegate?
    lazy var tokenizer: UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)

    // MARK: Hit-testing (the ONE sanctioned override, spec §7)

    /// During a session the overlay spans the whole content; a naive full-bounds
    /// hit region would swallow every vertical pan and starve the scroll view.
    /// The overlay owns ONLY touches on or near the current selection (its
    /// rects, expanded by a handle-grab margin); every other point falls through
    /// to the content beneath so the scroll view's pan wins.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard let range = currentRange else { return false }
        let grab: CGFloat = 28
        return resolver.selectionRects(forUTF16: range).contains {
            $0.rect.insetBy(dx: -grab, dy: -grab).contains(point)
        }
    }

    // MARK: Responder / editing

    override var canBecomeFirstResponder: Bool { true }
    /// Read-only container: no software keyboard.
    private let emptyInputView = UIView(frame: .zero)
    override var inputView: UIView? { emptyInputView }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        onResign?()
        return result
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(UIResponderStandardEditActions.copy(_:)) {
            return currentRange.map { !$0.isEmpty } ?? false
        }
        if action == #selector(UIResponderStandardEditActions.selectAll(_:)) {
            let total = textModel.totalUTF16Length
            return total > 0 && currentRange != 0..<total
        }
        return super.canPerformAction(action, withSender: sender)
    }
    /// Writes the document-order corpus slice for the current selection to the
    /// general pasteboard. The text is byte-identical to the search corpus
    /// (`SelectionTextModel.text(inUTF16:isVisible:)`): `"\n"`-joined between
    /// visible units, hidden expand units excluded by `isUnitVisible`.
    ///
    /// **Invariant — Copy inherits atom text from the corpus.** There is no
    /// atom-specific formatting here: an atom's `InlineComposer.fallbackText`
    /// (e.g. a date pill's "Jul 9, 2024", a mention's "@Bharath") is already
    /// embedded in each unit's `plainText`, so a slice that overlaps an atom
    /// reproduces its fallback text verbatim — whole-or-nothing, because the
    /// endpoint snapping guarantees a range never bisects an atom.
    override func copy(_ sender: Any?) {
        guard let range = currentRange, !range.isEmpty,
              let text = text(in: SelectionTextRange(range)) else { return }
        UIPasteboard.general.string = text
    }
    override func selectAll(_ sender: Any?) {
        let total = textModel.totalUTF16Length
        guard total > 0 else { return }
        inputDelegate?.selectionWillChange(self)
        writeSelection(0..<total)
        inputDelegate?.selectionDidChange(self)
        selectionDisplay?.setNeedsSelectionUpdate()
    }
}
#endif
