#if os(iOS)
import UIKit
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

    /// True from session start until teardown. Gates the recognizers on the
    /// gesture path without reading the observed `model.selectionSessionActive`.
    private var sessionActive = false

    init(model: ADFDocumentModel) {
        self.model = model
        self.geometrySource = RowGeometrySource(registry: geometryRegistry)
        self.overlay = SelectionOverlayView(model: model, geometrySource: geometrySource)
        self.editMenu = UIEditMenuInteraction(delegate: nil)
        super.init()
        overlay.addInteraction(editMenu)
        overlay.onResign = { [weak self] in self?.endSession() }
        geometrySource.referenceView = overlay
    }

    /// Installs the overlay + gesture recognizers on the introspected content
    /// container. Called once by `ScrollViewIntrospector`. Idempotent.
    func attach(to container: UIView, scrollView: UIScrollView) {
        guard !attached else { return }
        attached = true
        self.container = container
        self.scrollView = scrollView

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
    }

    // MARK: - Session lifecycle

    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, !sessionActive, let container, let model else { return }
        let point = g.location(in: container)
        guard tk2Row(at: point) != nil else { return }

        // Rebuild the corpus model from the CURRENT index: the introspector
        // attaches before streaming indexing finishes, so the attach-time model
        // can be empty/stale. Cheap and off the scroll path (session start only).
        rebuildTextModel()

        overlay.frame = container.bounds
        container.bringSubviewToFront(overlay)
        overlay.isUserInteractionEnabled = true

        sessionActive = true
        overlay.beginSession(atContainerPoint: point)
        // The ONE observed flip at session start (first non-empty selection).
        model.setSelectionSessionActive(true)
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
        if gestureRecognizer === tapClear { return sessionActive }
        return true
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
    func beginSession(atContainerPoint point: CGPoint) {
        guard let seed = resolver.closestGlobalOffset(toContainerPoint: point) else { return }
        _ = becomeFirstResponder()
        inputDelegate?.selectionWillChange(self)
        let seedPosition = SelectionTextPosition(seed)
        let word = wordRange(around: seedPosition) ?? fallbackRange(around: seed)
        writeSelection(word.range)
        inputDelegate?.selectionDidChange(self)
        selectionDisplay?.isActivated = true
        selectionDisplay?.setNeedsSelectionUpdate()
        selectionDisplay?.layoutManagedSubviews()
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

    /// Is `point` (overlay coordinates) inside the current selection? Used to
    /// distinguish a native tap (inside) from a session-ending tap (outside).
    func selectionContains(_ point: CGPoint) -> Bool {
        guard let range = currentRange else { return false }
        return resolver.selectionRects(forUTF16: range).contains { $0.rect.contains(point) }
    }

    // MARK: Selection state (the non-observed model box)

    /// The live range from `model.selection`, epoch-guarded and clamped to the
    /// current document length. A stale epoch (a document generation that no
    /// longer exists) reports no selection (Task 22 adds mid-gesture cancel).
    private var currentRange: Range<Int>? {
        guard let model, let range = model.selection.utf16Range else { return nil }
        guard model.selection.epoch == model.documentRevision else { return nil }
        let total = textModel.totalUTF16Length
        let lower = max(0, min(range.lowerBound, total))
        let upper = max(lower, min(range.upperBound, total))
        return lower < upper ? lower..<upper : lower..<upper
    }

    /// Writes a range into the model box (a non-observed write). Both endpoints
    /// pass through the single ingestion guard (`snapIngested`): grapheme-snap,
    /// then snap to the NEARER edge of any atom they land strictly inside, so a
    /// caret/handle never rests inside a pill (spec §7 "endpoints snap to the
    /// nearer pill edge"). Rect atomicity — a range that overlaps a pill draws
    /// the whole pill — is handled separately by `partSlices`.
    private func writeSelection(_ range: Range<Int>) {
        guard let model else { return }
        let currentResolver = resolver
        let lower = currentResolver.snapIngested(min(range.lowerBound, range.upperBound))
        let upper = currentResolver.snapIngested(max(range.lowerBound, range.upperBound))
        model.selection.utf16Range = lower..<max(lower, upper)
        model.selection.epoch = model.documentRevision // placeholder → documentEpoch in Task 22
        selectionDisplay?.setNeedsSelectionUpdate()
    }

    // MARK: UITextInput (read-only)

    private func clamp(_ offset: Int) -> Int { max(0, min(offset, textModel.totalUTF16Length)) }

    func text(in range: UITextRange) -> String? {
        guard let range = range as? SelectionTextRange else { return nil }
        return textModel.text(inUTF16: range.range, isVisible: { [weak self] in self?.isUnitVisible($0) ?? true })
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
