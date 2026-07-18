#if os(iOS)
import UIKit

/// Read-only selection controller for the TextKit 2 arm (spec §7, phase 4).
///
/// Unlike the phase-1 spike — where the `UITextInput` conformer WAS the
/// interactive `UIView` — this controller is a detached responder that
/// *attaches to* the introspected document scroll view's content container
/// (an ANCESTOR of every rendered TK2 row). The `UITextInteraction` lives on
/// that container, so (in principle) descendant gestures keep native behavior
/// and the interaction's geometry is already in content space.
///
/// **Task-16 fidelity: crude.** Geometry is whole-container (one region per
/// selection, linear-interpolated by vertical position), matching the spike's
/// crude level but over the *real* rows. `copy(_:)`/`canPerformAction` are
/// deliberately NOT wired here (spike row 8's known "no Copy in the menu") —
/// Task 20's job.
///
/// **Zero-work idle (§8b):** with no selection session, UIKit calls none of
/// the `UITextInput` methods below and the interaction only holds dormant,
/// event-driven gesture recognizers — nothing runs per frame.
///
/// Base class is `UIResponder`, not `NSObject` as the brief's prose reads:
/// the SDK types `UITextInteraction.textInput` as `UIResponder <UITextInput>`,
/// so a plain `NSObject` cannot be assigned to it. `UIResponder` is an
/// `NSObject` subclass and is still "not a `UIView`", so the brief's intent —
/// a plain object attached to the container rather than an interactive view —
/// holds. Compiler-forced deviation, like the spike's `farthestIn`/`firstRect`
/// SDK fixes.
///
/// **Task-16 verdict: this attachment model does NOT deliver selection on the
/// production SwiftUI hierarchy — see `docs/TextKit2-Port-Assessment.md`
/// (Phase 4 — Task 16). It is retained as the assessed, non-viable baseline
/// the geometry-oracle-overlay fallback replaces.**
final class SelectionController: UIResponder, UITextInput {
    weak var model: ADFDocumentModel?
    let interaction = UITextInteraction(for: .nonEditable)

    private weak var container: UIView?
    private weak var scrollView: UIScrollView?
    private var attached = false

    /// Placeholder corpus (UTF-16 into this joined string). Cached once it is
    /// non-empty; recomputed only while the document is still streaming (the
    /// index fills in as chunks arrive). Task 18 replaces it entirely.
    private var cachedCorpus: NSString?

    init(model: ADFDocumentModel) {
        self.model = model
        super.init()
    }

    /// Installs the interaction on the introspected content container. Called
    /// once by `ScrollViewIntrospector` after the SwiftUI scroll view has laid
    /// out its content subview. Idempotent.
    func attach(to container: UIView, scrollView: UIScrollView) {
        guard !attached else { return }
        attached = true
        self.container = container
        self.scrollView = scrollView
        interaction.textInput = self
        container.addInteraction(interaction)
    }

    // MARK: - Placeholder text model (offsets are UTF-16 into `corpus`)

    private var corpus: NSString {
        if let cachedCorpus, cachedCorpus.length > 0 { return cachedCorpus }
        let text = (model?.search.selectionCorpusPlainText ?? "") as NSString
        if text.length > 0 { cachedCorpus = text }
        return text
    }

    private func clamp(_ offset: Int) -> Int { max(0, min(offset, corpus.length)) }

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

    // MARK: - Crude container geometry
    //
    // One region per selection, interpolated by vertical position within the
    // container's bounds — the whole-owner stand-in this task calls for (the
    // real per-owner frame map is Task 17). Rect fidelity is not under test in
    // Task 16; attachment + arbitration on the real hierarchy is.

    private var lineHeightGuess: CGFloat { 22 }

    private func y(forOffset offset: Int) -> CGFloat {
        guard let bounds = container?.bounds, bounds.height > 0 else { return 0 }
        let length = max(corpus.length, 1)
        let fraction = CGFloat(clamp(offset)) / CGFloat(length)
        return bounds.minY + fraction * bounds.height
    }

    private func offset(forPoint point: CGPoint) -> Int {
        guard let bounds = container?.bounds, bounds.height > 0 else { return 0 }
        let fraction = (point.y - bounds.minY) / bounds.height
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
        set { selection = newValue as? Range_ }
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
        guard let p = p as? Position, let bounds = container?.bounds else { return .zero }
        return CGRect(x: bounds.minX, y: y(forOffset: p.offset), width: 2, height: lineHeightGuess)
    }
    func firstRect(for range: UITextRange) -> CGRect {
        selectionRects(for: range).first?.rect ?? .zero
    }
    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        guard let r = range as? Range_, let bounds = container?.bounds else { return [] }
        let yStart = y(forOffset: min(r.s.offset, r.e.offset))
        let yEnd = y(forOffset: max(r.s.offset, r.e.offset))
        let rect = CGRect(x: bounds.minX, y: yStart,
                          width: bounds.width, height: max(yEnd - yStart, lineHeightGuess))
        return [SelectionRect(rect: rect, containsStart: true, containsEnd: true)]
    }
    func closestPosition(to point: CGPoint) -> UITextPosition? {
        Position(offset(forPoint: point))
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

    // A detached responder must volunteer to become first responder for the
    // interaction to start a selection session at all (UIResponder defaults to
    // `false`) — the same override the spike's view carried. NOTE (Task-16
    // finding): this alone is insufficient — a detached responder with no
    // responder-chain `next` returns `false` from `becomeFirstResponder()`, so
    // `UITextInteraction` never installs its gesture recognizers. See the
    // assessment for why wiring it up still does not deliver selection.
    override var canBecomeFirstResponder: Bool { true }
}

/// One crude selection region. `containsStart`/`containsEnd` are both true —
/// there is a single whole-container rect this task, so it owns both handles.
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
