// PROTOTYPE — THROWAWAY CODE. Not production. Delete or absorb after verdict.
//
// This file: the transparent overlay that spans the scroll content and
// conforms to (read-only) UITextInput so UITextInteraction(.nonEditable) can
// drive NATIVE selection UI — system grab handles, highlight, loupe — across
// all blocks at once. Positions are global Character offsets into the virtual
// document string; geometry is delegated to PrototypeGeometryService.

#if os(iOS)
import UIKit
import SwiftUI

// MARK: Position / range value types

final class PrototypeTextPosition: UITextPosition {
    let offset: Int
    init(_ offset: Int) { self.offset = offset }
}

final class PrototypeTextRange: UITextRange {
    let range: Range<Int>
    init(_ range: Range<Int>) { self.range = range }

    override var isEmpty: Bool { range.isEmpty }
    override var start: UITextPosition { PrototypeTextPosition(range.lowerBound) }
    override var end: UITextPosition { PrototypeTextPosition(range.upperBound) }
}

final class PrototypeSelectionRect: UITextSelectionRect {
    private let _rect: CGRect
    private let _containsStart: Bool
    private let _containsEnd: Bool

    init(rect: CGRect, containsStart: Bool, containsEnd: Bool) {
        self._rect = rect
        self._containsStart = containsStart
        self._containsEnd = containsEnd
    }

    override var rect: CGRect { _rect }
    override var writingDirection: NSWritingDirection { .leftToRight }
    override var containsStart: Bool { _containsStart }
    override var containsEnd: Bool { _containsEnd }
    override var isVertical: Bool { false }
}

// MARK: Overlay view

@MainActor
protocol PrototypeSelectionOverlayDelegate: AnyObject {
    func selectionDidChange(_ selectedText: String?)
}

final class PrototypeSelectionOverlayView: UIView {
    private let docText: PrototypeDocumentText
    private let geometry: PrototypeGeometryService
    weak var selectionDelegate: PrototypeSelectionOverlayDelegate?

    private var selectedRange: Range<Int>? {
        didSet { selectionChanged() }
    }

    private var textInteraction: UITextInteraction?
    private var editMenuInteraction: UIEditMenuInteraction?
    private var menuDebounce: Task<Void, Never>?
    private var debugLayer: CAShapeLayer?

    weak var _inputDelegate: (any UITextInputDelegate)?
    private var _markedTextStyle: [NSAttributedString.Key: Any]?
    private lazy var _tokenizer = UITextInputStringTokenizer(textInput: self)

    init(docText: PrototypeDocumentText, geometry: PrototypeGeometryService) {
        self.docText = docText
        self.geometry = geometry
        super.init(frame: .zero)
        backgroundColor = .clear

        let interaction = UITextInteraction(for: .nonEditable)
        interaction.textInput = self
        addInteraction(interaction)
        textInteraction = interaction

        let editMenu = UIEditMenuInteraction(delegate: self)
        addInteraction(editMenu)
        editMenuInteraction = editMenu
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // Read-only container: allow first-responder status (edit menu plumbing)
    // but suppress the software keyboard UIKeyInput would otherwise summon.
    override var canBecomeFirstResponder: Bool { true }
    private let emptyInputView = UIView(frame: .zero)
    override var inputView: UIView? { emptyInputView }

    // MARK: Selection actions

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copy(_:)) { return selectedRange?.isEmpty == false }
        if action == #selector(selectAll(_:)) { return docText.length > 0 }
        return false
    }

    override func copy(_ sender: Any?) {
        guard let selectedRange, !selectedRange.isEmpty else { return }
        UIPasteboard.general.string = docText.text(in: selectedRange)
        selectedRange.isEmpty ? () : dismissMenu()
    }

    override func selectAll(_ sender: Any?) {
        _inputDelegate?.selectionWillChange(self)
        selectedRange = 0..<docText.length
        _inputDelegate?.selectionDidChange(self)
    }

    func clearSelection() {
        _inputDelegate?.selectionWillChange(self)
        selectedRange = nil
        _inputDelegate?.selectionDidChange(self)
    }

    private func selectionChanged() {
        let text = selectedRange.flatMap { $0.isEmpty ? nil : docText.text(in: $0) }
        selectionDelegate?.selectionDidChange(text)
        scheduleMenu()
    }

    /// Presents the edit menu near the selection after handle drags settle.
    private func scheduleMenu() {
        menuDebounce?.cancel()
        guard let range = selectedRange, !range.isEmpty else {
            dismissMenu()
            return
        }
        menuDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self else { return }
            self.presentMenu(for: range)
        }
    }

    private func presentMenu(for range: Range<Int>) {
        guard let first = selectionRects(for: PrototypeTextRange(range)).first else { return }
        let configuration = UIEditMenuConfiguration(
            identifier: "prototype-selection",
            sourcePoint: CGPoint(x: first.rect.midX, y: first.rect.minY - 8)
        )
        editMenuInteraction?.presentEditMenu(with: configuration)
    }

    private func dismissMenu() {
        editMenuInteraction?.dismissMenu()
    }

    // MARK: Debug fidelity overlay

    func setDebugRectsVisible(_ visible: Bool) {
        debugLayer?.removeFromSuperlayer()
        debugLayer = nil
        guard visible else { return }
        let layer = CAShapeLayer()
        let path = UIBezierPath()
        for rect in geometry.debugRects(in: self) {
            path.append(UIBezierPath(rect: rect))
        }
        layer.path = path.cgPath
        layer.strokeColor = UIColor.systemPink.cgColor
        layer.fillColor = UIColor.clear.cgColor
        layer.lineWidth = 0.5
        self.layer.addSublayer(layer)
        debugLayer = layer
    }
}

// MARK: UITextInput conformance (read-only)

extension PrototypeSelectionOverlayView: UITextInput {
    // UIKeyInput — inert: this container never edits.
    var hasText: Bool { false }
    func insertText(_ text: String) {}
    func deleteBackward() {}

    func text(in range: UITextRange) -> String? {
        guard let range = range as? PrototypeTextRange else { return nil }
        return docText.text(in: range.range)
    }

    func replace(_ range: UITextRange, withText text: String) {}

    var selectedTextRange: UITextRange? {
        get { selectedRange.map { PrototypeTextRange($0) } }
        set {
            guard let newValue = newValue as? PrototypeTextRange else {
                selectedRange = nil
                return
            }
            selectedRange = newValue.range
        }
    }

    var markedTextRange: UITextRange? { nil }
    var markedTextStyle: [NSAttributedString.Key: Any]? {
        get { _markedTextStyle }
        set { _markedTextStyle = newValue }
    }
    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {}
    func unmarkText() {}

    var beginningOfDocument: UITextPosition { PrototypeTextPosition(0) }
    var endOfDocument: UITextPosition { PrototypeTextPosition(docText.length) }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let from = fromPosition as? PrototypeTextPosition,
              let to = toPosition as? PrototypeTextPosition else { return nil }
        return PrototypeTextRange(min(from.offset, to.offset)..<max(from.offset, to.offset))
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let position = position as? PrototypeTextPosition else { return nil }
        let target = position.offset + offset
        guard target >= 0, target <= docText.length else { return nil }
        return PrototypeTextPosition(target)
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        switch direction {
        case .right: return self.position(from: position, offset: offset)
        case .left: return self.position(from: position, offset: -offset)
        case .up, .down:
            // Line navigation unsupported in the prototype: clamp in place.
            return position
        @unknown default: return position
        }
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        guard let a = (position as? PrototypeTextPosition)?.offset,
              let b = (other as? PrototypeTextPosition)?.offset else { return .orderedSame }
        if a < b { return .orderedAscending }
        if a > b { return .orderedDescending }
        return .orderedSame
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        guard let a = (from as? PrototypeTextPosition)?.offset,
              let b = (toPosition as? PrototypeTextPosition)?.offset else { return 0 }
        return b - a
    }

    var inputDelegate: (any UITextInputDelegate)? {
        get { _inputDelegate }
        set { _inputDelegate = newValue }
    }

    var tokenizer: any UITextInputTokenizer { _tokenizer }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        guard let range = range as? PrototypeTextRange else { return nil }
        switch direction {
        case .left, .up: return PrototypeTextPosition(range.range.lowerBound)
        case .right, .down: return PrototypeTextPosition(range.range.upperBound)
        @unknown default: return nil
        }
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        guard let position = position as? PrototypeTextPosition else { return nil }
        switch direction {
        case .left, .up:
            return PrototypeTextRange(max(position.offset - 1, 0)..<position.offset)
        case .right, .down:
            return PrototypeTextRange(position.offset..<min(position.offset + 1, docText.length))
        @unknown default: return nil
        }
    }

    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
        .leftToRight
    }
    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    // MARK: Geometry

    func firstRect(for range: UITextRange) -> CGRect {
        selectionRects(for: range).first?.rect ?? .null
    }

    func caretRect(for position: UITextPosition) -> CGRect {
        guard let position = position as? PrototypeTextPosition,
              let location = docText.location(of: position.offset) else { return .null }
        return geometry.caretRect(unit: location.unit, localOffset: location.local, in: self)
    }

    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        guard let range = range as? PrototypeTextRange, !range.range.isEmpty else { return [] }
        let pieces = docText.unitRanges(in: range.range)
        var rects: [CGRect] = []
        for piece in pieces {
            rects.append(contentsOf: geometry.rects(unit: piece.unit, localRange: piece.range, in: self))
        }
        return rects.enumerated().map { index, rect in
            PrototypeSelectionRect(
                rect: rect,
                containsStart: index == 0,
                containsEnd: index == rects.count - 1
            )
        }
    }

    func closestPosition(to point: CGPoint) -> UITextPosition? {
        geometry.closestOffset(to: point, in: self).map { PrototypeTextPosition($0) }
    }

    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        guard let range = range as? PrototypeTextRange,
              let position = geometry.closestOffset(to: point, in: self) else { return nil }
        let clamped = min(max(position, range.range.lowerBound), range.range.upperBound)
        return PrototypeTextPosition(clamped)
    }

    func characterRange(at point: CGPoint) -> UITextRange? {
        guard let offset = geometry.closestOffset(to: point, in: self) else { return nil }
        return PrototypeTextRange(offset..<min(offset + 1, docText.length))
    }
}

// MARK: Edit menu

extension PrototypeSelectionOverlayView: @preconcurrency UIEditMenuInteractionDelegate {
    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        let copyAction = UIAction(title: "Copy") { [weak self] _ in
            self?.copy(nil)
        }
        let selectAllAction = UIAction(title: "Select All") { [weak self] _ in
            self?.selectAll(nil)
        }
        return UIMenu(children: [copyAction, selectAllAction])
    }
}

// MARK: SwiftUI wrapper

struct PrototypeSelectionOverlay: UIViewRepresentable {
    let docText: PrototypeDocumentText
    let geometry: PrototypeGeometryService
    let showDebugRects: Bool
    let onSelectionChanged: @MainActor (String?) -> Void

    func makeUIView(context: Context) -> PrototypeSelectionOverlayView {
        let view = PrototypeSelectionOverlayView(docText: docText, geometry: geometry)
        view.selectionDelegate = context.coordinator
        context.coordinator.onSelectionChanged = onSelectionChanged
        return view
    }

    func updateUIView(_ uiView: PrototypeSelectionOverlayView, context: Context) {
        context.coordinator.onSelectionChanged = onSelectionChanged
        uiView.setDebugRectsVisible(showDebugRects)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: PrototypeSelectionOverlayDelegate {
        var onSelectionChanged: (@MainActor (String?) -> Void)?
        func selectionDidChange(_ selectedText: String?) {
            onSelectionChanged?(selectedText)
        }
    }
}
#endif
