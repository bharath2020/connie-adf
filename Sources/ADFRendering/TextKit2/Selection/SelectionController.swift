#if os(iOS)
import UIKit
import UniformTypeIdentifiers
import Observation
import ADFPreparation

/// Owns endpoint movement and edge autoscroll. UIKit's private selection
/// recognizer can draw our custom `UITextInput` handles but does not reliably
/// update a virtual, multi-view text range. This recognizer wins only when its
/// delegate confirms the touch began in an endpoint halo; all other document
/// pans fail it before recognition.
private final class SelectionHandleDragRecognizer: UIPanGestureRecognizer {
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }
}

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

    /// Live semantic container surfaces. SwiftUI registers weak anchor views;
    /// the selection overlay reads them only while painting a live selection.
    /// This stays separate from `geometryRegistry`: text rects and component
    /// outlines have different lifetimes and one component can own many rows.
    let componentGeometryRegistry = SelectionComponentGeometryRegistry()

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
    /// Endpoint drag recognizer on the overlay. It begins only inside a native
    /// handle's 44-point halo, updates the virtual range directly, and feeds
    /// touch Y to the edge autoscroller.
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

    /// The initiating long press starts on the idle content container, before
    /// the overlay participates in hit-testing. UIKit's native text
    /// interaction therefore cannot inherit that same touch when the user
    /// keeps holding and drags. Track that one gesture explicitly and extend
    /// its tokenizer seed through the overlay's ordinary range-write path.
    private var longPressDragActive = false
    private var longPressDragWindowPoint: CGPoint?
    private var handleDragActive = false
    private var handleDragWindowPoint: CGPoint?

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
        let overlay = SelectionOverlayView(
            model: model,
            geometrySource: geometrySource,
            componentGeometryRegistry: componentGeometryRegistry
        )
        self.overlay = overlay
        self.editMenu = UIEditMenuInteraction(delegate: overlay)
        super.init()
        overlay.addInteraction(editMenu)
        overlay.onResign = { [weak self] in self?.endSession() }
        model.selection.setFragmentProvider { [weak overlay] in
            overlay?.selectionFragment()
        }
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
        componentGeometryRegistry.onGeometryChange = { [weak self] in
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
        // A1 (register #18): a find-navigation / TOC scrollTarget jump is a
        // STRUCTURAL navigation — the reader teleports to a new region, so any
        // active selection's rects would desync from the post-jump layout
        // (Task 27 saw a huge stale highlight while Copy returned a small
        // stale range). End the session cleanly on the jump. Same non-observed
        // callback wiring, and same `attached`-guard reasoning, as
        // `onDocumentEpochChanged` above (a throwaway `SelectionController`
        // from a later `ADFDocumentView` re-init must not overwrite the real,
        // attached instance's closure). Zero scroll-path cost: fires only on
        // an actual jump, and is a guarded no-op when no session is active.
        model?.onScrollTargetChanged = { [weak self] in self?.endSessionOnStructuralScroll() }

        rebuildTextModel()

        overlay.isUserInteractionEnabled = false
        overlay.frame = container.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(overlay)
        overlay.installSelectionRangeProbe(in: container.window ?? container)

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
        // A2 (register #17) — tap-to-clear must NEVER fire on the RELEASE of a
        // reseed long-press. A plain `UITapGestureRecognizer` has no maximum
        // hold duration, so a held-then-released touch also satisfies it
        // (the same fact `TextKit2RowView.tapDurationSentinel` exists to gate);
        // without this requirement, every long-press-inside-a-selection ended
        // with `handleTap` firing on touch-up, and it cleared the session
        // whenever the release point fell outside the freshly-reseeded rect —
        // e.g. a press in inter-word whitespace reseeds a 1-char fallback whose
        // rect doesn't cover the release point (live-traced: `reseed OK
        // range=245..<246` immediately followed by `handleTap contains=false ->
        // endSession`). That is exactly the intermittent 3/4-clear of register
        // #17. Requiring `lp` to fail means a deliberate long-press (which
        // recognizes, i.e. does NOT fail) suppresses tap-clear entirely, so a
        // held press is always a reseed and never a clear; a genuine quick tap
        // still fails `lp` fast and clears normally when outside the selection.
        tap.require(toFail: lp)
        container.addGestureRecognizer(tap)
        tapClear = tap

        // Drag-past-edge autoscroll. The provider maps the row now at the
        // viewport top to its top-level block ID; the step closure writes it
        // into the plain `anchors` box (§8b — invalidates no view). The pan
        // observer on the overlay feeds touch-moves during a native handle drag.
        let scroller = SelectionAutoscroller(scrollView: scrollView)
        scroller.topRowProvider = { [weak self] _ in self?.topLevelBlockIDAtViewportTop() }
        scroller.onScrollStep = { [weak self] rowID in
            guard let self else { return }
            if let rowID {
                self.model?.anchors.topRow = rowID
            }
            // During the initiating long-press drag, the finger is stationary
            // in window space while autoscroll moves document content beneath
            // it. Re-resolve that stable point after every scroll step so the
            // endpoint continues growing without requiring another touch-move.
            if self.longPressDragActive,
               let windowPoint = self.longPressDragWindowPoint,
               let window = self.overlay.window,
               let container = self.container {
                let containerPoint = container.convert(windowPoint, from: window)
                self.overlay.extendLongPressSelection(
                    toContainerPoint: containerPoint
                )
            }
            if self.handleDragActive,
               let windowPoint = self.handleDragWindowPoint,
               let window = self.overlay.window,
               let container = self.container {
                let containerPoint = container.convert(windowPoint, from: window)
                self.overlay.updateHandleDrag(toContainerPoint: containerPoint)
            }
        }
        autoscroller = scroller

        let pan = SelectionHandleDragRecognizer(
            target: self,
            action: #selector(handleAutoscrollPan(_:))
        )
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        pan.delegate = self
        // UIKit hosts the visible endpoint knobs in a managed window-level
        // view. A pan installed only on `overlay` never sees a touch whose
        // hit view is that knob. Window installation observes the same touch;
        // `gestureRecognizerShouldBegin` still rejects everything outside the
        // active endpoint halo, so document and navigation gestures are
        // unaffected.
        (container.window ?? container).addGestureRecognizer(pan)
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
        guard let container else { return }
        let point = g.location(in: container)

        switch g.state {
        case .began:
            longPressDragActive = false
            longPressDragWindowPoint = nil

            // Long-press DURING a live session → restart a fresh word session
            // at the press point. Endpoint touches are excluded by the gesture
            // delegate below so UIKit's native handle recognizer owns them.
            // `tk2Row(at:)` cannot be used here because the enabled overlay is
            // frontmost; the resolver uses the live row registry directly.
            if sessionActive {
                if overlay.beginSession(atContainerPoint: point),
                   overlay.selectedTextRange != nil {
                    longPressDragActive = true
                    longPressDragWindowPoint = overlay.window.map { g.location(in: $0) }
                    editMenu.dismissMenu()
                }
                return
            }

            guard let model, tk2Row(at: point) != nil else { return }

            // Rebuild the corpus model from the CURRENT index: the
            // introspector attaches before streaming indexing finishes, so
            // the attach-time model can be empty/stale. Cheap and off the
            // scroll path (session start only).
            rebuildTextModel()

            overlay.frame = container.bounds
            container.bringSubviewToFront(overlay)
            overlay.isUserInteractionEnabled = true

            // The active session only commits once a seed resolves. A miss
            // undoes the tentative interaction enablement.
            guard overlay.beginSession(atContainerPoint: point) else {
                overlay.isUserInteractionEnabled = false
                return
            }

            sessionActive = true
            longPressDragActive = true
            longPressDragWindowPoint = overlay.window.map { g.location(in: $0) }
            // The ONE observed flip at session start (first non-empty
            // selection).
            model.setSelectionSessionActive(true)
            observeExpandedBlocksIfActive()
            // Match native text selection: reveal the edit menu after the
            // initiating gesture ends, not underneath the finger while it may
            // still become a drag.
            editMenu.dismissMenu()

        case .changed:
            guard sessionActive, longPressDragActive else { return }
            longPressDragWindowPoint = overlay.window.map { g.location(in: $0) }
            overlay.extendLongPressSelection(toContainerPoint: point)
            updateAutoscroll(atContainerPoint: point)

        case .ended:
            guard longPressDragActive else { return }
            longPressDragActive = false
            longPressDragWindowPoint = nil
            autoscroller?.stop()
            overlay.finishLongPressSelection()
            scheduleMenuPresentation(near: point)

        case .cancelled, .failed:
            longPressDragActive = false
            longPressDragWindowPoint = nil
            autoscroller?.stop()
            overlay.finishLongPressSelection()

        default:
            break
        }
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard sessionActive, let container else { return }
        let point = g.location(in: container)
        if overlay.selectionHitRegionContains(point) { return }
        endSession()
    }

    /// A1 (register #18) — reached from `ADFDocumentModel.onScrollTargetChanged`
    /// when a find-navigation / TOC jump is requested mid-session. A structural
    /// navigation ends the session via the ONE standard teardown; the fired
    /// closure already runs on the main actor synchronously with the
    /// `scrollTarget` write, so the session is gone before the scroll animates.
    /// Guarded so a jump with no active session is a no-op.
    func endSessionOnStructuralScroll() {
        guard sessionActive else { return }
        endSession()
    }

    /// Single idempotent teardown, reached from the tap-clear recognizer AND
    /// `SelectionOverlayView.resignFirstResponder`. `sessionActive` is cleared
    /// first so the re-entrant resign call is a guarded no-op.
    private func endSession() {
        guard sessionActive else { return }
        sessionActive = false
        longPressDragActive = false
        longPressDragWindowPoint = nil
        handleDragActive = false
        handleDragWindowPoint = nil
        autoscroller?.stop()
        editMenu.dismissMenu()
        overlay.finishLongPressSelection()
        overlay.finishHandleDrag()
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

    /// Defers until UIKit has committed the native handle/long-press range
    /// write for this touch. Presenting synchronously on gesture end can query
    /// the previous endpoint geometry and put the menu back over a handle.
    private func scheduleMenuPresentation(near point: CGPoint) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sessionActive else { return }
            self.presentMenu(near: point)
        }
    }

    // MARK: - Autoscroll

    /// Feeds the autoscroller the touch's Y-in-viewport during a native handle
    /// drag. `.began`/`.changed` engage/adjust the ramp; end/cancel tears the
    /// display link down. Passive — it never affects the drag it observes.
    @objc private func handleAutoscrollPan(_ g: UIPanGestureRecognizer) {
        guard sessionActive, let autoscroller else { return }
        let point = g.location(in: overlay)
        switch g.state {
        case .began:
            // Resolve the touch-down point (the pan begins only after a few
            // points of motion) so a fast initial move still grabs the handle.
            let translation = g.translation(in: overlay)
            let touchDown = CGPoint(
                x: point.x - translation.x,
                y: point.y - translation.y
            )
            handleDragActive = overlay.beginHandleDrag(
                atContainerPoint: touchDown
            )
            guard handleDragActive else { return }
            handleDragWindowPoint = overlay.window.map { g.location(in: $0) }
            editMenu.dismissMenu()
            overlay.updateHandleDrag(toContainerPoint: point)
            updateAutoscroll(atContainerPoint: point)
        case .changed:
            guard handleDragActive else { return }
            handleDragWindowPoint = overlay.window.map { g.location(in: $0) }
            overlay.updateHandleDrag(toContainerPoint: point)
            updateAutoscroll(atContainerPoint: point)
        case .ended, .cancelled, .failed:
            let didDragHandle = handleDragActive
            handleDragActive = false
            handleDragWindowPoint = nil
            autoscroller.stop()
            overlay.finishHandleDrag()
            if g.state == .ended, didDragHandle {
                scheduleMenuPresentation(near: point)
            }
        default:
            break
        }
    }

    /// Converts a content-space touch into the document scroll view's visible
    /// bounds and feeds the edge ramp. The overlay and content container share
    /// bounds, so this works for both the initiating container long press and
    /// later native handle drags on the overlay.
    private func updateAutoscroll(atContainerPoint point: CGPoint) {
        guard let container, let scrollView, let autoscroller else { return }
        let pointInScrollView = container.convert(point, to: scrollView)
        let viewportY = pointInScrollView.y - scrollView.contentOffset.y
        autoscroller.update(
            touchYInBounds: viewportY,
            viewportHeight: scrollView.bounds.height
        )
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
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === autoscrollPan,
              let pan = gestureRecognizer as? UIPanGestureRecognizer
        else {
            return true
        }
        let point = pan.location(in: overlay)
        let translation = pan.translation(in: overlay)
        let touchDown = CGPoint(
            x: point.x - translation.x,
            y: point.y - translation.y
        )
        let shouldBegin = sessionActive
            && overlay.selectionEndpointHitRegionContains(touchDown)
        return shouldBegin
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        // Endpoint movement has one owner. Allowing UIKit's private recognizer
        // simultaneously lets it write its stale pre-drag range after our
        // virtual-document update.
        gestureRecognizer !== autoscrollPan && other !== autoscrollPan
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        // Once selection is live, endpoint affordances belong exclusively to
        // UIKit's `UITextInteraction`. Letting the ancestor long press track
        // those touches makes a deliberate hold on a handle re-seed a word
        // after 0.5s, exactly when the user expects to begin dragging it.
        if gestureRecognizer === longPress, sessionActive {
            let point = touch.location(in: overlay)
            if overlay.selectionEndpointHitRegionContains(point) {
                return false
            }
        }

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
        let converted = row.selectionRects(forUTF16: nsRange).map { row.convert($0, to: reference) }
        return SelectionRectClipper.clip(
            converted,
            through: clippingAncestorRects(for: row, in: reference)
        )
    }

    /// Selection is drawn by a sibling overlay, so UIKit does not inherit the
    /// row's ancestor clipping automatically. Reapply every real clipping
    /// boundary in overlay coordinates. This is generic across horizontal
    /// code/table scrollers and any future container implemented with a
    /// clipping UIKit/SwiftUI viewport.
    private func clippingAncestorRects(
        for row: TextKit2RowUIView,
        in reference: UIView
    ) -> [CGRect] {
        var result = [reference.bounds]
        var ancestor = row.superview
        while let view = ancestor {
            if view.clipsToBounds {
                result.append(view.convert(view.bounds, to: reference))
            }
            ancestor = view.superview
        }
        return result
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

private struct ResolvedComponentSelection {
    let rect: CGRect
    let clippingRect: CGRect
    let cornerRadius: CGFloat
}

/// The transparent selection surface: a `UIView` that is also the read-only
/// `UITextInput`. Arithmetic delegates to `SelectionTextModel` in UTF-16;
/// geometry to `SelectionGeometryResolver` over live TK2 layouts. Selection
/// state lives in `model.selection` (non-observed).
@MainActor
final class SelectionOverlayView:
    UIView,
    UITextInput,
    UITextSelectionDisplayInteractionDelegate,
    @MainActor UIEditMenuInteractionDelegate
{
    private weak var model: ADFDocumentModel?
    private let geometrySource: SelectionGeometrySource
    private let componentGeometryRegistry: SelectionComponentGeometryRegistry
    private let interaction = UITextInteraction(for: .nonEditable)
    /// Small, viewport-clipped layers — never one drawable surface as tall as
    /// the document. The overlay itself can exceed 500k points in stress-5k;
    /// giving it (or a full-size child) a backing store makes Core Animation
    /// attempt a multi-million-pixel bitmap even while selection is idle.
    private var componentHighlightLayers: [CAShapeLayer] = []
    private var longPressSeedRange: Range<Int>?
    private var handleDragFixedOffset: Int?
    private let selectionRangeProbeEnabled =
        ProcessInfo.processInfo.arguments.contains("-selectionUITestProbe")
    private let selectionRangeProbe = UILabel()

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

    init(
        model: ADFDocumentModel,
        geometrySource: SelectionGeometrySource,
        componentGeometryRegistry: SelectionComponentGeometryRegistry
    ) {
        self.model = model
        self.geometrySource = geometrySource
        self.componentGeometryRegistry = componentGeometryRegistry
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        // Nonvisual UI-test probe. Selection gestures need an observable
        // result without reading another process's pasteboard, which triggers
        // iOS's paste-permission alert. It is exposed only while selection is
        // active and only when the UI-test launch environment requests it.
        if selectionRangeProbeEnabled {
            selectionRangeProbe.isAccessibilityElement = true
            selectionRangeProbe.accessibilityIdentifier = "adf-selection-range"
            selectionRangeProbe.accessibilityLabel = "Selection range"
            selectionRangeProbe.accessibilityValue = "none"
            selectionRangeProbe.isUserInteractionEnabled = false
            selectionRangeProbe.backgroundColor = .clear
            selectionRangeProbe.frame = CGRect(x: 1, y: 100, width: 1, height: 1)
        }
        interaction.textInput = self
        addInteraction(interaction)
        let display = UITextSelectionDisplayInteraction(textInput: self, delegate: self)
        display.isActivated = false
        addInteraction(display)
        selectionDisplay = display
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    func installSelectionRangeProbe(in container: UIView) {
        guard selectionRangeProbeEnabled else { return }
        container.addSubview(selectionRangeProbe)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateComponentHighlights()
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        updateComponentHighlightColors()
    }

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
        longPressSeedRange = word.range
        writeSelection(word.range)
        inputDelegate?.selectionDidChange(self)
        selectionDisplay?.isActivated = true
        selectionDisplay?.setNeedsSelectionUpdate()
        selectionDisplay?.layoutManagedSubviews()
        return true
    }

    /// Extends the word selected at long-press recognition while the same
    /// initiating touch remains down. That touch began on the idle content
    /// container, so UIKit's overlay-hosted native interaction cannot adopt
    /// it mid-stream; this method supplies the missing continuation.
    func extendLongPressSelection(toContainerPoint point: CGPoint) {
        guard let seed = longPressSeedRange,
              let offset = resolver.closestGlobalOffset(toContainerPoint: point)
        else { return }
        let extended = SelectionDragRange.extending(seed, toward: offset)
        guard extended != currentRange else { return }
        inputDelegate?.selectionWillChange(self)
        writeSelection(extended)
        inputDelegate?.selectionDidChange(self)
        selectionDisplay?.layoutManagedSubviews()
    }

    func finishLongPressSelection() {
        longPressSeedRange = nil
    }

    /// Captures which native endpoint the pan began on and fixes the opposite
    /// UTF-16 offset for the duration of the drag. Returns `false` for pans
    /// that start in selected text but not on either handle.
    func beginHandleDrag(atContainerPoint point: CGPoint) -> Bool {
        guard let range = currentRange else { return false }
        let grab: CGFloat = 44
        let candidates = endpointCandidates().compactMap {
            candidate -> (isStart: Bool, distance: CGFloat)? in
            let dx = candidate.point.x - point.x
            let dy = candidate.point.y - point.y
            let distance = dx * dx + dy * dy
            return distance <= grab * grab
                ? (candidate.isStart, distance)
                : nil
        }
        guard let nearest = candidates.min(by: { $0.distance < $1.distance })
        else {
            return false
        }
        handleDragFixedOffset = nearest.isStart
            ? range.upperBound
            : range.lowerBound
        return true
    }

    func updateHandleDrag(toContainerPoint point: CGPoint) {
        guard let fixedOffset = handleDragFixedOffset,
              let current = currentRange,
              let offset = resolver.closestGlobalOffset(toContainerPoint: point)
        else { return }
        let moved = SelectionDragRange.movingEndpoint(
            fixedOffset: fixedOffset,
            toward: offset,
            preserving: current
        )
        guard moved != current else { return }
        inputDelegate?.selectionWillChange(self)
        writeSelection(moved)
        inputDelegate?.selectionDidChange(self)
        selectionDisplay?.layoutManagedSubviews()
    }

    func finishHandleDrag() {
        handleDragFixedOffset = nil
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
        longPressSeedRange = nil
        handleDragFixedOffset = nil
        let hadSelection = model?.selection.utf16Range != nil
        if hadSelection {
            inputDelegate?.selectionWillChange(self)
            model?.selection.utf16Range = nil
            inputDelegate?.selectionDidChange(self)
        }
        if selectionRangeProbeEnabled {
            selectionRangeProbe.accessibilityValue = "none"
        }
        selectionDisplay?.isActivated = false
        selectionDisplay?.setNeedsSelectionUpdate()
        updateComponentHighlights()
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
        updateComponentHighlights()
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

    /// The native endpoint views are visually small but conventionally offer
    /// a roughly finger-sized hit target. The overlay must accept that whole
    /// halo or the touch falls through to the document before
    /// `UITextInteraction` can see it.
    func selectionHitRegionContains(_ point: CGPoint) -> Bool {
        guard let range = currentRange else { return false }
        let grab: CGFloat = 44
        return resolver.selectionRects(forUTF16: range).contains {
            $0.rect.insetBy(dx: -grab, dy: -grab).contains(point)
        }
    }

    /// Endpoint-only variant used to keep the controller's ancestor
    /// long-press recognizer from competing with native handle drags.
    func selectionEndpointHitRegionContains(_ point: CGPoint) -> Bool {
        let grab: CGFloat = 44
        return endpointCandidates().contains { candidate in
            let dx = candidate.point.x - point.x
            let dy = candidate.point.y - point.y
            return dx * dx + dy * dy <= grab * grab
        }
    }

    private func endpointCandidates() -> [(isStart: Bool, point: CGPoint)] {
        guard let range = currentRange else { return [] }
        return resolver.selectionRects(forUTF16: range).flatMap { resolved in
            var candidates: [(isStart: Bool, point: CGPoint)] = []
            if resolved.containsStart {
                candidates.append((
                    true,
                    CGPoint(x: resolved.rect.minX, y: resolved.rect.minY)
                ))
            }
            if resolved.containsEnd {
                candidates.append((
                    false,
                    CGPoint(x: resolved.rect.maxX, y: resolved.rect.maxY)
                ))
            }
            return candidates
        }
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
            if selectionRangeProbeEnabled {
                selectionRangeProbe.accessibilityValue = "none"
            }
            selectionDisplay?.setNeedsSelectionUpdate()
            updateComponentHighlights()
            return
        }
        model.selection.utf16Range = snapped
        model.selection.epoch = model.documentEpoch // Task 22: the real document epoch
        if selectionRangeProbeEnabled {
            selectionRangeProbe.accessibilityValue =
                "\(snapped.lowerBound)..<\(snapped.upperBound)"
            let rect = resolver.selectionRects(forUTF16: snapped).first?.rect
                ?? CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1)
            if let probeContainer = selectionRangeProbe.superview {
                selectionRangeProbe.frame = convert(rect, to: probeContainer)
            }
        }
        selectionDisplay?.setNeedsSelectionUpdate()
        updateComponentHighlights()
    }

    /// Resolves semantic full-coverage IDs through live component anchors.
    /// Called only on selection writes/geometry refreshes/layout, never from
    /// SwiftUI row bodies or the document's scroll-position observation.
    private func updateComponentHighlights() {
        guard let range = currentRange, !range.isEmpty else {
            applyComponentHighlights([])
            return
        }
        let selectedIDs = textModel.fullySelectedComponentIDs(
            inUTF16: range,
            isVisible: { [weak self] in self?.isUnitVisible($0) ?? true }
        )
        guard !selectedIDs.isEmpty else {
            applyComponentHighlights([])
            return
        }

        let liveEntries = componentGeometryRegistry.liveEntries(for: selectedIDs)
        let selections: [ResolvedComponentSelection] = liveEntries
            .compactMap { entry -> ResolvedComponentSelection? in
                let view = entry.view
                guard view.window != nil else {
                    return nil
                }
                let componentRect = view.convert(view.bounds, to: self)
                guard !componentRect.isEmpty, !componentRect.isNull else {
                    return nil
                }
                var clippingRect = bounds
                var ancestor = view.superview
                while let current = ancestor {
                    if current.clipsToBounds {
                        clippingRect = clippingRect.intersection(
                            current.convert(current.bounds, to: self)
                        )
                    }
                    ancestor = current.superview
                }
                guard !clippingRect.isEmpty, !clippingRect.isNull else {
                    return nil
                }
                switch entry.shape {
                case .roundedRectangle(let cornerRadius):
                    return ResolvedComponentSelection(
                        rect: componentRect,
                        clippingRect: clippingRect,
                        cornerRadius: cornerRadius
                    )
                }
            }
        applyComponentHighlights(selections)
    }

    /// Paints the "whole component" cue underneath UIKit's native glyph
    /// selection and handles. Each shape layer is bounded to the component's
    /// currently visible viewport intersection, so even a 5k-row document
    /// allocates only a few screen-sized layers during an active selection
    /// and no drawable backing store while idle.
    private func applyComponentHighlights(
        _ unsortedSelections: [ResolvedComponentSelection]
    ) {
        let selections = unsortedSelections
            .compactMap { selection -> (selection: ResolvedComponentSelection, visibleRect: CGRect)? in
                let visibleRect = selection.rect.intersection(selection.clippingRect)
                guard !visibleRect.isEmpty, !visibleRect.isNull else { return nil }
                return (selection, visibleRect)
            }
            .sorted {
                $0.selection.rect.width * $0.selection.rect.height
                    < $1.selection.rect.width * $1.selection.rect.height
            }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while componentHighlightLayers.count < selections.count {
            let highlightLayer = CAShapeLayer()
            highlightLayer.masksToBounds = true
            layer.insertSublayer(highlightLayer, at: 0)
            componentHighlightLayers.append(highlightLayer)
        }
        while componentHighlightLayers.count > selections.count {
            componentHighlightLayers.removeLast().removeFromSuperlayer()
        }

        for (index, resolved) in selections.enumerated() {
            let highlightLayer = componentHighlightLayers[index]
            let selection = resolved.selection
            let visibleRect = resolved.visibleRect
            let componentRectInLayer = selection.rect.offsetBy(
                dx: -visibleRect.minX,
                dy: -visibleRect.minY
            )
            let strokeInset: CGFloat = 1
            let pathRect = componentRectInLayer.insetBy(
                dx: strokeInset,
                dy: strokeInset
            )

            highlightLayer.frame = visibleRect
            highlightLayer.contentsScale = traitCollection.displayScale
            highlightLayer.path = UIBezierPath(
                roundedRect: pathRect,
                cornerRadius: max(0, selection.cornerRadius - strokeInset)
            ).cgPath
            highlightLayer.lineWidth = strokeInset * 2
        }
        updateComponentHighlightColors()
        CATransaction.commit()
    }

    private func updateComponentHighlightColors() {
        let fill = tintColor.withAlphaComponent(0.075).cgColor
        let stroke = tintColor.withAlphaComponent(0.82).cgColor
        for highlightLayer in componentHighlightLayers {
            highlightLayer.fillColor = fill
            highlightLayer.strokeColor = stroke
        }
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
                updateComponentHighlights()
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
        selectionHitRegionContains(point)
    }

    // MARK: Edit-menu placement

    /// Gives `UIEditMenuInteraction` the selected line's real target rectangle
    /// plus enough vertical clearance for both endpoint knobs. With only a
    /// source point UIKit treats the target as zero-sized; in the kitchen-sink
    /// code row that put the menu's bottom at y=704 for a selection beginning
    /// at y=710, directly covering the upper handle.
    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        targetRectFor configuration: UIEditMenuConfiguration
    ) -> CGRect {
        guard let range = currentRange else { return .null }
        let rects = resolver.selectionRects(forUTF16: range)
            .map(\.rect)
            .filter { !$0.isNull && !$0.isEmpty }
        guard let nearest = rects.min(by: {
            squaredDistance(from: configuration.sourcePoint, to: $0)
                < squaredDistance(from: configuration.sourcePoint, to: $1)
        }) else {
            return .null
        }

        // Horizontal padding clears the endpoint knob; larger vertical
        // padding accounts for its stem and leaves a comfortable re-grab gap.
        return nearest.insetBy(dx: -16, dy: -52)
    }

    private func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(max(rect.minX - point.x, 0), point.x - rect.maxX)
        let dy = max(max(rect.minY - point.y, 0), point.y - rect.maxY)
        return dx * dx + dy * dy
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
    /// Writes three representations for the current selection in one
    /// pasteboard item: byte-exact plain text, semantic HTML, and a version-1
    /// ADF document fragment. Plain-text consumers keep the original behavior;
    /// rich editors can retain inline marks and component structure.
    ///
    /// **Invariant — Copy inherits atom text from the corpus.** There is no
    /// atom-specific formatting here: an atom's `InlineComposer.fallbackText`
    /// (e.g. a date pill's "Jul 9, 2024", a mention's "@Bharath") is already
    /// embedded in each unit's `plainText`, so a slice that overlaps an atom
    /// reproduces its fallback text verbatim — whole-or-nothing, because the
    /// endpoint snapping guarantees a range never bisects an atom.
    override func copy(_ sender: Any?) {
        guard let payload = selectionFragment() else { return }
        UIPasteboard.general.setItems([[
            UTType.utf8PlainText.identifier: payload.plainText,
            UTType.html.identifier: payload.html,
            ADFSelectionFragment.pasteboardType: payload.adf,
        ]])
    }

    /// Shared by Copy and `SelectionState.fragment` ("Add selected"). Building
    /// the payload is intentionally on-demand, never on per-touch range writes.
    func selectionFragment() -> ADFSelectionFragment? {
        guard let range = currentRange, !range.isEmpty else { return nil }
        return ADFSelectionFragment(
            model: textModel,
            range: range,
            isVisible: { [weak self] in self?.isUnitVisible($0) ?? true }
        )
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
