import SwiftUI
import UIKit

/// Feasibility spike (spec §11 step 1): UITextInteraction attached to an
/// ANCESTOR of interactive content. Not production code — delete or absorb.
struct SpikeScreen: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> SpikeViewController { SpikeViewController() }
    func updateUIViewController(_ vc: SpikeViewController, context: Context) {}
}

final class SpikeViewController: UIViewController {
    private let scrollView = UIScrollView()
    private let container = SpikeTextContainer()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scrollView)

        container.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 900)
        scrollView.addSubview(container)
        scrollView.contentSize = container.bounds.size
        container.buildContent()

        // THE spike: interaction on the container (ancestor of every
        // paragraph, the button, and the nested scroll view). No hitTest
        // override anywhere.
        let interaction = UITextInteraction(for: .nonEditable)
        interaction.textInput = container
        container.addInteraction(interaction)
    }
}

/// Ancestor view: hosts three paragraph labels, a button, and a nested
/// horizontal scroll view, and conforms to read-only UITextInput over the
/// concatenated paragraph text. Geometry is deliberately crude.
final class SpikeTextContainer: UIView, UITextInput {
    private(set) var paragraphs: [UILabel] = []
    private(set) var button = UIButton(type: .system)
    private(set) var hScroll = UIScrollView()
    private var texts: [String] = [
        "First paragraph of the ancestor spike. Long-press me to start a selection.",
        "Second paragraph with an emoji 😄 so drags cross it during the spike.",
        "Third paragraph after the interactive content, to drag handles into.",
    ]
    private var joined: String { texts.joined(separator: "\n") }

    func buildContent() {
        var y: CGFloat = 20
        for (i, text) in texts.enumerated() {
            let label = UILabel(frame: CGRect(x: 16, y: y, width: bounds.width - 32, height: 0))
            label.numberOfLines = 0
            label.font = .preferredFont(forTextStyle: .body)
            label.text = text
            label.sizeToFit()
            addSubview(label)
            paragraphs.append(label)
            y = label.frame.maxY + 16
            if i == 0 {
                button.frame = CGRect(x: 16, y: y, width: 160, height: 44)
                button.setTitle("Tap counter: 0", for: .normal)
                button.addAction(UIAction { [weak self] _ in
                    guard let self else { return }
                    self.tapCount += 1
                    self.button.setTitle("Tap counter: \(self.tapCount)", for: .normal)
                }, for: .touchUpInside)
                addSubview(button)
                y = button.frame.maxY + 16
            }
            if i == 1 {
                hScroll.frame = CGRect(x: 16, y: y, width: bounds.width - 32, height: 60)
                hScroll.showsHorizontalScrollIndicator = true
                let wide = UILabel(frame: CGRect(x: 0, y: 0, width: 1200, height: 60))
                wide.text = "wide horizontally scrolling content — pan me sideways — " +
                            "wide horizontally scrolling content"
                hScroll.addSubview(wide)
                hScroll.contentSize = wide.bounds.size
                addSubview(hScroll)
                y = hScroll.frame.maxY + 16
            }
        }
    }

    private var tapCount = 0

    // MARK: - Crude text model (offsets are UTF-16 into `joined`)

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

    private func clamp(_ o: Int) -> Int { max(0, min(o, (joined as NSString).length)) }
    private func paragraphIndex(forOffset o: Int) -> Int {
        var start = 0
        for (i, t) in texts.enumerated() {
            let len = (t as NSString).length
            if o <= start + len { return i }
            start += len + 1
        }
        return texts.count - 1
    }
    private func paragraphStart(_ i: Int) -> Int {
        texts.prefix(i).reduce(0) { $0 + ($1 as NSString).length + 1 }
    }

    // MARK: UITextInput (read-only minimum)

    func text(in range: UITextRange) -> String? {
        guard let r = range as? Range_ else { return nil }
        let ns = joined as NSString
        return ns.substring(with: NSRange(location: r.s.offset, length: r.e.offset - r.s.offset))
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
    var endOfDocument: UITextPosition { Position((joined as NSString).length) }
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

    // Crude geometry: per-paragraph linear interpolation.
    func caretRect(for p: UITextPosition) -> CGRect {
        guard let p = p as? Position else { return .zero }
        let i = paragraphIndex(forOffset: p.offset)
        let label = paragraphs[i]
        let start = paragraphStart(i)
        let len = max((texts[i] as NSString).length, 1)
        let fraction = CGFloat(p.offset - start) / CGFloat(len)
        return CGRect(x: label.frame.minX + fraction * label.frame.width,
                      y: label.frame.minY, width: 2, height: label.frame.height)
    }
    func firstRect(for range: UITextRange) -> CGRect {
        selectionRects(for: range).first?.rect ?? .zero
    }
    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        guard let r = range as? Range_ else { return [] }
        let si = paragraphIndex(forOffset: r.s.offset)
        let ei = paragraphIndex(forOffset: r.e.offset)
        return (si...ei).map { i in
            SpikeSelectionRect(rect: paragraphs[i].frame,
                               containsStart: i == si, containsEnd: i == ei)
        }
    }
    func closestPosition(to point: CGPoint) -> UITextPosition? {
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (i, label) in paragraphs.enumerated() {
            let clamped = CGPoint(x: max(label.frame.minX, min(point.x, label.frame.maxX)),
                                  y: max(label.frame.minY, min(point.y, label.frame.maxY)))
            let d = hypot(clamped.x - point.x, clamped.y - point.y)
            if d < bestDistance {
                bestDistance = d
                let len = (texts[i] as NSString).length
                let fraction = (clamped.x - label.frame.minX) / max(label.frame.width, 1)
                best = paragraphStart(i) + Int(fraction * CGFloat(len))
            }
        }
        return Position(clamp(best))
    }
    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        closestPosition(to: point)
    }
    func characterRange(at point: CGPoint) -> UITextRange? {
        guard let p = closestPosition(to: point) as? Position else { return nil }
        return Range_(p, Position(clamp(p.offset + 1)))
    }
    var hasText: Bool { true }
    func insertText(_ text: String) {}
    func deleteBackward() {}
    override var canBecomeFirstResponder: Bool { true }
}

final class SpikeSelectionRect: UITextSelectionRect {
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
