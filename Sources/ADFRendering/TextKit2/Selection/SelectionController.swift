#if os(iOS)
import UIKit

/// Read-only selection engine for the TextKit 2 arm — **v3, session-scoped
/// overlay** (spec §7, phase 4; Task 16b).
///
/// Task 16 killed the v2 *ancestor-interaction* design: `UITextInteraction`
/// declines a long-press whose touch hit-tests to an interactive descendant
/// row rather than to `interaction.view`. The same experiment proved a plain
/// `UILongPressGestureRecognizer` on the introspected content container DOES
/// fire over those interactive descendants. v3 is built on both facts:
///
/// - A transparent `SelectionOverlayView` is added to the introspected content
///   container, spanning content bounds. It conforms to `UITextInput` and hosts
///   `UITextInteraction(.nonEditable)` + `UIEditMenuInteraction` **on itself**,
///   so `interaction.view == interaction.textInput == overlay` — the exact
///   condition Task 16 proved necessary for the interaction to drive selection.
/// - **Idle:** the overlay is hit-test transparent (`isUserInteractionEnabled
///   = false`). Links, checkboxes, the video facade, code/table pans behave
///   natively; per-frame cost is zero.
/// - **Session start:** our own long-press recognizer on the *container*
///   (the ancestor — proven to fire over interactive descendants) begins a
///   session when the press lands over a TK2 row: word-select at the point via
///   the crude stand-in model, enable the overlay, make it first responder,
///   set `selectedTextRange`, notify `inputDelegate`, present the edit menu.
/// - **Session active:** touches over the selection UI now hit-test TO the
///   overlay (`interaction.view`), so `UITextInteraction` drives handles /
///   drags / menu natively. A tap outside the selection ends the session; so
///   does first-responder resignation from any path.
///
/// **Task-16b fidelity: crude, deliberately.** The text model is the search
/// corpus joined plain-text; geometry is a linear stand-in over the overlay's
/// bounds (Task 17 is the real per-row geometry oracle). Rect fidelity is not
/// under test — the arbitration/interaction model on the real hierarchy is.
/// `copy(_:)` is wired minimally so the edit menu is provably non-empty;
/// corpus-exact copy semantics are Task 20.
@MainActor
final class SelectionController: NSObject {
    weak var model: ADFDocumentModel?

    private weak var container: UIView?
    private weak var scrollView: UIScrollView?
    private var attached = false

    /// The selection surface. Strong-held: it is our view, inserted into the
    /// (foreign, SwiftUI-owned) container, and must outlive a container
    /// re-layout that could otherwise drop an unreferenced subview.
    private let overlay: SelectionOverlayView
    private let editMenu: UIEditMenuInteraction

    private var longPress: UILongPressGestureRecognizer?
    private var tapClear: UITapGestureRecognizer?

    /// True from session start until teardown. Non-observed — flips no SwiftUI
    /// state (spec §7 coarse session Bool lives in the model in production;
    /// here it just gates the recognizers).
    private var sessionActive = false

    init(model: ADFDocumentModel) {
        self.model = model
        self.overlay = SelectionOverlayView(model: model)
        self.editMenu = UIEditMenuInteraction(delegate: nil)
        super.init()
        overlay.addInteraction(editMenu)
        overlay.onResign = { [weak self] in self?.endSession() }
    }

    /// Installs the overlay + gesture recognizers on the introspected content
    /// container. Called once by `ScrollViewIntrospector` after the SwiftUI
    /// scroll view lays out its content subview. Idempotent.
    func attach(to container: UIView, scrollView: UIScrollView) {
        guard !attached else { return }
        attached = true
        self.container = container
        self.scrollView = scrollView

        overlay.isUserInteractionEnabled = false
        overlay.frame = container.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(overlay)

        // Session-start recognizer on the ANCESTOR (Task 16 finding: a plain
        // long-press here fires over interactive descendants). Never eats a
        // descendant's touch — `cancelsTouchesInView = false` keeps taps on
        // checkboxes / links / the facade native.
        let lp = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        lp.cancelsTouchesInView = false
        lp.delaysTouchesBegan = false
        lp.delaysTouchesEnded = false
        lp.delegate = self
        container.addGestureRecognizer(lp)
        longPress = lp

        // Tap-to-clear, gated to an active session (see the delegate). Also
        // non-cancelling, so it never disturbs idle descendant taps.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        container.addGestureRecognizer(tap)
        tapClear = tap
    }

    // MARK: - Session lifecycle

    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, !sessionActive, let container else { return }
        let point = g.location(in: container)
        // Only start a session over an actual TK2 row — never over a checkbox,
        // image, plugin, or empty margin (their native long-press, if any, is
        // left untouched because we take no action here).
        guard tk2Row(at: point) != nil else { return }

        // Refresh geometry and bring the overlay above whatever SwiftUI may
        // have layered in since attach, then start the session.
        overlay.frame = container.bounds
        container.bringSubviewToFront(overlay)
        overlay.isUserInteractionEnabled = true

        sessionActive = true
        overlay.beginSession(atContainerPoint: point)
        presentMenu(near: point)
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard sessionActive, let container else { return }
        let point = g.location(in: container)
        // A tap inside the selection belongs to the native interaction (menu /
        // handle). Only a tap OUTSIDE the selection ends the session.
        if overlay.selectionContains(point) { return }
        endSession()
    }

    /// Single idempotent teardown, reached from both the tap-clear recognizer
    /// and `SelectionOverlayView.resignFirstResponder` (the "resign from any
    /// path" contract). `sessionActive` is cleared first so the re-entrant call
    /// triggered by resigning the responder is a guarded no-op.
    private func endSession() {
        guard sessionActive else { return }
        sessionActive = false
        editMenu.dismissMenu()
        overlay.clearSelection()
        if overlay.isFirstResponder { _ = overlay.resignFirstResponder() }
        overlay.isUserInteractionEnabled = false
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

    // MARK: - Helpers

    /// Deepest `TextKit2RowUIView` under `point` (container coordinates), or
    /// nil. Runs while the overlay is still idle (disabled), so `hitTest`
    /// passes straight through it to the real rows underneath.
    private func tk2Row(at point: CGPoint) -> TextKit2RowUIView? {
        guard let hit = container?.hitTest(point, with: nil) else { return nil }
        var v: UIView? = hit
        while let current = v {
            if let row = current as? TextKit2RowUIView { return row }
            v = current.superview
        }
        return nil
    }
}

extension SelectionController: UIGestureRecognizerDelegate {
    /// Our recognizers must coexist with the scroll view's pan and the
    /// interaction's own recognizers — never claim a touch exclusively.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }

    /// The tap-clear recognizer is inert unless a session is active, so idle
    /// descendant taps (checkbox toggle, facade play) are never intercepted.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        if gestureRecognizer === tapClear { return sessionActive }
        return true
    }
}

/// The transparent selection surface: a `UIView` that is also the read-only
/// `UITextInput`, so the hosted `UITextInteraction`'s `view` and `textInput`
/// are one and the same object (the condition Task 16 proved necessary).
///
/// Geometry is a crude linear stand-in over `bounds` — Task 16b tests the
/// interaction model, not rect fidelity. A word-sized selection renders as a
/// short band anchored at the press x; a multi-line (handle-dragged) selection
/// renders as a full-width block between the two y positions.
final class SelectionOverlayView: UIView, UITextInput, UITextSelectionDisplayInteractionDelegate {
    private weak var model: ADFDocumentModel?
    private let interaction = UITextInteraction(for: .nonEditable)

    /// Draws the native selection affordances (highlight + drag handles) from
    /// the same `UITextInput` geometry. **Task-16b discovery:** `UITextInteraction`
    /// alone provides the gestures + first-responder plumbing and a queryable
    /// selection (Copy returns the selected word), but does NOT render a
    /// programmatically-seeded selection — on iOS 17+ the drawing is a separate
    /// interaction that `UITextInteraction` "generally talks to". Installing it
    /// on the overlay is what makes the highlight/handles appear (spec §7's
    /// "native handles + highlight on the overlay").
    private var selectionDisplay: UITextSelectionDisplayInteraction?

    /// Ends the session when this view resigns first responder from ANY path
    /// (tap-clear, another responder taking over, UIKit-initiated resign).
    var onResign: (() -> Void)?

    /// x the initial word band is anchored at (press x, container coords).
    private var anchorX: CGFloat = 16

    init(model: ADFDocumentModel) {
        self.model = model
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

    // MARK: - Session driving

    /// Word-select at the press point and push the selection to UIKit. The
    /// overlay must already be first-responder-eligible and enabled (the
    /// controller does that before calling this).
    func beginSession(atContainerPoint point: CGPoint) {
        anchorX = max(bounds.minX + 8, min(point.x, bounds.maxX - 8))
        let center = offset(forY: point.y)
        let (lo, hi) = wordRange(around: center)
        _ = becomeFirstResponder()
        inputDelegate?.selectionWillChange(self)
        selection = Range_(Position(lo), Position(hi))
        inputDelegate?.selectionDidChange(self)
        selectionDisplay?.isActivated = true
        selectionDisplay?.setNeedsSelectionUpdate()
        selectionDisplay?.layoutManagedSubviews()
    }

    func clearSelection() {
        guard selection != nil else {
            selectionDisplay?.isActivated = false
            return
        }
        inputDelegate?.selectionWillChange(self)
        selection = nil
        inputDelegate?.selectionDidChange(self)
        selectionDisplay?.isActivated = false
        selectionDisplay?.setNeedsSelectionUpdate()
    }

    /// Is `point` (container == overlay coordinates) inside the current
    /// selection? Used to distinguish a native tap (inside) from a
    /// session-ending tap (outside).
    func selectionContains(_ point: CGPoint) -> Bool {
        guard let range = selection else { return false }
        return selectionRects(for: range).contains { $0.rect.contains(point) }
    }

    // MARK: - Crude text model (offsets are UTF-16 into `corpus`)

    private var cachedCorpus: NSString?
    private var corpus: NSString {
        if let cachedCorpus, cachedCorpus.length > 0 { return cachedCorpus }
        let text = (model?.search.selectionCorpusPlainText ?? "") as NSString
        if text.length > 0 { cachedCorpus = text }
        return text
    }

    private func clamp(_ offset: Int) -> Int { max(0, min(offset, corpus.length)) }

    private func isBoundary(_ c: unichar) -> Bool {
        c == 0x20 || c == 0x0A || c == 0x09 || c == 0x0D
    }

    /// Crude word boundary: expand to the nearest whitespace/newline on each
    /// side. Good enough for the spike's "long-press → word select".
    private func wordRange(around offset: Int) -> (Int, Int) {
        let o = clamp(offset)
        guard corpus.length > 0 else { return (0, 0) }
        var s = min(o, corpus.length - 1)
        while s > 0, !isBoundary(corpus.character(at: s - 1)) { s -= 1 }
        var e = min(o, corpus.length)
        while e < corpus.length, !isBoundary(corpus.character(at: e)) { e += 1 }
        if s == e { e = clamp(e + 1) }
        return (s, e)
    }

    final class Position: UITextPosition {
        let offset: Int
        init(_ offset: Int) { self.offset = offset }
    }
    final class Range_: UITextRange {
        let s: Position; let e: Position
        init(_ s: Position, _ e: Position) { self.s = s; self.e = e }
        override var start: UITextPosition { s }
        override var end: UITextPosition { e }
        override var isEmpty: Bool { s.offset == e.offset }
    }

    var selection: Range_?
    weak var inputDelegate: UITextInputDelegate?
    lazy var tokenizer: UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)

    // MARK: - Crude geometry (linear over `bounds`)

    private var lineHeightGuess: CGFloat { 22 }
    private var avgCharWidth: CGFloat { 8 }

    private func y(forOffset offset: Int) -> CGFloat {
        guard bounds.height > 0 else { return 0 }
        let length = max(corpus.length, 1)
        let fraction = CGFloat(clamp(offset)) / CGFloat(length)
        return bounds.minY + fraction * bounds.height
    }

    private func offset(forY yValue: CGFloat) -> Int {
        guard bounds.height > 0 else { return 0 }
        let fraction = (yValue - bounds.minY) / bounds.height
        return clamp(Int((fraction * CGFloat(corpus.length)).rounded()))
    }

    // MARK: - UITextInput (read-only minimum)

    func text(in range: UITextRange) -> String? {
        guard let r = range as? Range_ else { return nil }
        let lo = clamp(min(r.s.offset, r.e.offset))
        let hi = clamp(max(r.s.offset, r.e.offset))
        return corpus.substring(with: NSRange(location: lo, length: hi - lo))
    }
    func replace(_ range: UITextRange, withText text: String) {}
    var selectedTextRange: UITextRange? {
        get { selection }
        set {
            selection = newValue as? Range_
            // Keep the display interaction in sync when UITextInteraction
            // mutates the selection during a handle drag.
            selectionDisplay?.setNeedsSelectionUpdate()
        }
    }
    var markedTextRange: UITextRange? { nil }
    var markedTextStyle: [NSAttributedString.Key: Any]? { get { nil } set {} }
    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {}
    func unmarkText() {}
    var beginningOfDocument: UITextPosition { Position(0) }
    var endOfDocument: UITextPosition { Position(corpus.length) }
    func textRange(from f: UITextPosition, to t: UITextPosition) -> UITextRange? {
        guard let f = f as? Position, let t = t as? Position else { return nil }
        return f.offset <= t.offset ? Range_(f, t) : Range_(t, f)
    }
    func position(from p: UITextPosition, offset: Int) -> UITextPosition? {
        guard let p = p as? Position else { return nil }
        return Position(clamp(p.offset + offset))
    }
    func position(from p: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        position(from: p, offset: direction == .left ? -offset : offset)
    }
    func compare(_ a: UITextPosition, to b: UITextPosition) -> ComparisonResult {
        guard let a = a as? Position, let b = b as? Position else { return .orderedSame }
        return a.offset < b.offset ? .orderedAscending : a.offset > b.offset ? .orderedDescending : .orderedSame
    }
    func offset(from f: UITextPosition, to t: UITextPosition) -> Int {
        ((t as? Position)?.offset ?? 0) - ((f as? Position)?.offset ?? 0)
    }
    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        direction == .left ? range.start : range.end
    }
    func characterRange(byExtending p: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? { nil }
    func baseWritingDirection(for p: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection { .leftToRight }
    func setBaseWritingDirection(_ w: NSWritingDirection, for range: UITextRange) {}

    func caretRect(for p: UITextPosition) -> CGRect {
        guard let p = p as? Position else { return .zero }
        return CGRect(x: anchorX, y: y(forOffset: p.offset), width: 2, height: lineHeightGuess)
    }
    func firstRect(for range: UITextRange) -> CGRect {
        selectionRects(for: range).first?.rect ?? .zero
    }
    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        guard let r = range as? Range_ else { return [] }
        let lo = min(r.s.offset, r.e.offset)
        let hi = max(r.s.offset, r.e.offset)
        let yLo = y(forOffset: lo)
        let yHi = y(forOffset: hi)
        // Same-line (word) selection → a short band anchored at the press x, so
        // the highlight reads as a word rather than a full-width bar. A taller
        // (handle-dragged) span → a full-width block between the two y's.
        if yHi - yLo <= lineHeightGuess * 1.5 {
            let width = min(bounds.width - 32, CGFloat(hi - lo) * avgCharWidth + 24)
            let x = min(anchorX, bounds.maxX - width - 8)
            let rect = CGRect(x: max(bounds.minX + 8, x), y: yLo,
                              width: max(width, 24), height: lineHeightGuess)
            return [SelectionRect(rect: rect, containsStart: true, containsEnd: true)]
        }
        let rect = CGRect(x: bounds.minX + 8, y: yLo,
                          width: bounds.width - 16, height: yHi - yLo)
        return [SelectionRect(rect: rect, containsStart: true, containsEnd: true)]
    }
    func closestPosition(to point: CGPoint) -> UITextPosition? {
        Position(offset(forY: point.y))
    }
    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        closestPosition(to: point)
    }
    func characterRange(at point: CGPoint) -> UITextRange? {
        guard let p = closestPosition(to: point) as? Position else { return nil }
        return Range_(p, Position(clamp(p.offset + 1)))
    }
    var hasText: Bool { corpus.length > 0 }
    func insertText(_ text: String) {}
    func deleteBackward() {}

    // MARK: - Hit-testing (the ONE sanctioned override, spec §7)

    /// During a session the overlay is enabled and spans the whole content, so
    /// a naive full-bounds hit region would swallow every vertical pan and
    /// **starve the scroll view** (observed in the arbitration matrix). Instead
    /// the overlay owns ONLY touches on or near the current selection (its
    /// rects, expanded by a handle-grab margin). Every other point falls
    /// through to the content beneath — the scroll view's pan recognizer (an
    /// ancestor of both) then wins, and taps reach checkboxes / the facade.
    /// This is spec §7's "the overlay passes vertical pans through to the
    /// scroll view". Idle, the view is `isUserInteractionEnabled = false`, so
    /// this is never consulted.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard let selection else { return false }
        let grab: CGFloat = 28
        for selectionRect in selectionRects(for: selection)
        where selectionRect.rect.insetBy(dx: -grab, dy: -grab).contains(point) {
            return true
        }
        return false
    }

    // MARK: - Responder / editing

    override var canBecomeFirstResponder: Bool { true }

    /// The "resign from any path" teardown hook (spec §7). Whatever resigns the
    /// overlay — our own tap-clear, another responder, a UIKit-initiated
    /// resignation — funnels through here back into the controller's idempotent
    /// `endSession`.
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        onResign?()
        return result
    }

    /// Minimal so the edit menu is provably non-empty (row 8). Corpus-exact
    /// copy semantics are Task 20; this puts the crude selected substring on
    /// the pasteboard, which is harmless and makes "menu presence" observable.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(UIResponderStandardEditActions.copy(_:)) {
            return selection.map { !$0.isEmpty } ?? false
        }
        return super.canPerformAction(action, withSender: sender)
    }
    override func copy(_ sender: Any?) {
        guard let range = selection, let text = text(in: range) else { return }
        UIPasteboard.general.string = text
    }
}

/// One crude selection region. `containsStart`/`containsEnd` are both true —
/// there is a single stand-in rect this task, so it owns both handles.
final class SelectionRect: UITextSelectionRect {
    private let r: CGRect; private let s: Bool; private let e: Bool
    init(rect: CGRect, containsStart: Bool, containsEnd: Bool) {
        r = rect; s = containsStart; e = containsEnd
    }
    override var rect: CGRect { r }
    override var writingDirection: NSWritingDirection { .leftToRight }
    override var containsStart: Bool { s }
    override var containsEnd: Bool { e }
    override var isVertical: Bool { false }
}
#endif
