#if canImport(UIKit)
import SwiftUI
import UIKit

/// One paragraph or heading drawn by TextKit 2.
///
/// The view owns its text stack (content storage → layout manager → one
/// unbounded-height container with no padding) and is sized by a full
/// synchronous `ensureLayout` over the document range. Its height follows
/// SwiftUI's `Text` model rather than TextKit's own frame: TextKit charges
/// the font's leading on every line including the last, SwiftUI only
/// *between* lines, so the row height is
/// `ceil_to_pixel(last baseline + deepest descent on the last line)`.
/// Measured sizes are memoized per width and the view NEVER invalidates
/// itself (no intrinsic-size invalidation, no layout requests: the SwiftUI
/// side sizes it through `sizeThatFits`, and a self-invalidating row in a
/// lazy stack is the §16 livelock).
final class TextKit2RowView: UIView {
    private let contentStorage = NSTextContentStorage()
    private let layoutManager = NSTextLayoutManager()
    private let textContainer = NSTextContainer(size: CGSize(width: 1, height: CGFloat.greatestFiniteMagnitude))

    private(set) var inputs: TextKit2TextInputs?
    private var attributed = NSAttributedString()
    /// Width the text container is currently laid out at.
    private var layoutWidth: CGFloat = -1
    /// `sizeThatFits` results per proposed width (`nil` key = natural width).
    private var sizeMemo: [CGFloat: CGSize] = [:]
    /// Number of container-width relayouts performed; tests assert that
    /// re-measuring an already measured width performs none.
    private(set) var relayoutCount = 0

    /// Delivered by the representable from the SwiftUI `openURL` action.
    var openURL: ((URL) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        contentStorage.addTextLayoutManager(layoutManager)
        textContainer.lineFragmentPadding = 0
        layoutManager.textContainer = textContainer
        isAccessibilityElement = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: TextKit2RowView, _) in
            // Dynamic colours (`UIColor.label`, mark colours) resolve at
            // draw time, so a scheme change only needs a redraw — never a
            // relayout (metrics are scheme-independent).
            view.setNeedsDisplay()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Inputs

    /// Re-applies the text when (and only when) `inputs` changed; a no-op
    /// otherwise, so repeated SwiftUI updates with the same value cost one
    /// `Hashable` compare.
    func apply(_ newInputs: TextKit2TextInputs) {
        guard newInputs != inputs else { return }
        inputs = newInputs
        rebuildAttributedString()
        accessibilityLabel = String(newInputs.text.characters)
        accessibilityTraits = newInputs.isHeading ? [.staticText, .header] : [.staticText]
    }

    private func rebuildAttributedString() {
        guard let inputs else { return }
        attributed = TextKit2TextBuilder.attributedString(for: inputs, linkColor: tintColor)
        contentStorage.attributedString = attributed
        contentScaleFactor = inputs.displayScale
        layoutWidth = -1
        sizeMemo.removeAll(keepingCapacity: true)
        setNeedsDisplay()
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        // Only link colour changes — layout is unaffected, so the memo
        // survives (same inputs, same metrics); the glyph colour is read
        // from the string at draw time.
        guard inputs != nil else { return }
        let width = layoutWidth
        rebuildAttributedString()
        if width >= 0 { layout(at: width) }
    }

    // MARK: Measurement

    /// The size for a proposed width (`nil` / infinite = natural width).
    /// Pure in (inputs, width); memoized.
    func measuredSize(forProposedWidth proposed: CGFloat?) -> CGSize {
        let key = (proposed == nil || !(proposed!.isFinite)) ? CGFloat.infinity : max(proposed!, 1)
        if let cached = sizeMemo[key] { return cached }
        let size: CGSize
        if key == .infinity {
            layout(at: Self.naturalLayoutWidth)
            let metrics = layoutMetrics()
            size = CGSize(width: pixelCeil(metrics.maxLineWidth), height: metrics.height)
        } else {
            layout(at: key)
            size = CGSize(width: key, height: layoutMetrics().height)
        }
        sizeMemo[key] = size
        return size
    }

    /// Widest line at a proposed width (parity diagnostics: a shifted line
    /// break moves this by a whole word even when the line count holds).
    func contentWidth(forProposedWidth proposed: CGFloat) -> CGFloat {
        layout(at: max(proposed, 1))
        return layoutMetrics().maxLineWidth
    }

    private static let naturalLayoutWidth: CGFloat = 1_000_000

    private func layout(at width: CGFloat) {
        guard width != layoutWidth else { return }
        layoutWidth = width
        relayoutCount += 1
        textContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
    }

    private struct LayoutMetrics {
        var height: CGFloat = 0
        var maxLineWidth: CGFloat = 0
    }

    private func layoutMetrics() -> LayoutMetrics {
        var metrics = LayoutMetrics()
        var lastBaseline: CGFloat?
        var lastRange = NSRange(location: 0, length: 0)
        layoutManager.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            let elementStart = self.elementStartOffset(of: fragment)
            for line in fragment.textLineFragments {
                lastBaseline = frame.minY + line.typographicBounds.minY + line.glyphOrigin.y
                lastRange = NSRange(location: elementStart + line.characterRange.location, length: line.characterRange.length)
                metrics.maxLineWidth = max(metrics.maxLineWidth, line.typographicBounds.width)
            }
            return true
        }
        guard let lastBaseline else {
            // Empty text: SwiftUI gives an empty `Text` one body line.
            let category = inputs?.sizeCategory ?? .large
            let font = TextKit2FontResolver.font(for: .init(textStyle: .body), category: category)
            metrics.height = pixelCeil(font.ascender - font.descender)
            return metrics
        }
        metrics.height = pixelCeil(lastBaseline + maxDescent(in: lastRange))
        return metrics
    }

    /// The deepest descent on a line, honouring baseline offsets (a
    /// subscript reaches below its font's descender).
    private func maxDescent(in range: NSRange) -> CGFloat {
        var descent: CGFloat = 0
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: attributed.length))
        guard clamped.length > 0 else { return descent }
        attributed.enumerateAttributes(in: clamped) { attributes, _, _ in
            guard let font = attributes[.font] as? UIFont else { return }
            let offset = (attributes[.baselineOffset] as? CGFloat) ?? 0
            descent = max(descent, -font.descender - offset)
        }
        return descent
    }

    private func elementStartOffset(of fragment: NSTextLayoutFragment) -> Int {
        guard let location = fragment.textElement?.elementRange?.location else { return 0 }
        return contentStorage.offset(from: contentStorage.documentRange.location, to: location)
    }

    private func pixelCeil(_ value: CGFloat) -> CGFloat {
        let scale = inputs?.displayScale ?? 1
        return (value * scale).rounded(.up) / scale
    }

    // MARK: Drawing

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        layout(at: max(bounds.width, 1))
        drawRunBackgrounds(in: context)
        layoutManager.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
            fragment.draw(at: fragment.layoutFragmentFrame.origin, in: context)
            return true
        }
    }

    /// Run background fills, SwiftUI-style: a full line-pitch tall band
    /// (ascent + descent + leading) per line the run touches, spanning the
    /// run's glyphs including trailing whitespace up to the wrap point.
    private func drawRunBackgrounds(in context: CGContext) {
        var fills: [(NSRange, UIColor)] = []
        attributed.enumerateAttribute(.adfRunBackground, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            if let color = value as? UIColor { fills.append((range, color)) }
        }
        guard !fills.isEmpty else { return }
        let containerWidth = layoutWidth
        layoutManager.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            let elementStart = self.elementStartOffset(of: fragment)
            for line in fragment.textLineFragments {
                let lineRange = NSRange(location: elementStart + line.characterRange.location, length: line.characterRange.length)
                let lineTop = frame.minY + line.typographicBounds.minY
                let lineHeight = line.typographicBounds.height
                for (range, color) in fills {
                    let overlap = NSIntersectionRange(range, lineRange)
                    guard overlap.length > 0 else { continue }
                    let startX = line.locationForCharacter(at: overlap.location - elementStart).x
                    let endX = line.locationForCharacter(at: NSMaxRange(overlap) - elementStart).x
                    let x0 = frame.minX + line.typographicBounds.minX + min(startX, endX)
                    let x1 = min(frame.minX + line.typographicBounds.minX + max(startX, endX), containerWidth)
                    guard x1 > x0 else { continue }
                    context.setFillColor(color.cgColor)
                    context.fill(CGRect(x: x0, y: lineTop, width: x1 - x0, height: lineHeight))
                }
            }
            return true
        }
    }

    // MARK: Links

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let openURL else { return }
        let point = recognizer.location(in: self)
        guard let url = link(at: point) else { return }
        openURL(url)
    }

    /// The link under a point in the view's coordinates, if any.
    func link(at point: CGPoint) -> URL? {
        guard attributed.length > 0, bounds.contains(point) else { return nil }
        layout(at: max(bounds.width, 1))
        guard let fragment = layoutManager.textLayoutFragment(for: point) else { return nil }
        let frame = fragment.layoutFragmentFrame
        let pointInFragment = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        let elementStart = elementStartOffset(of: fragment)
        for line in fragment.textLineFragments where line.typographicBounds.contains(pointInFragment) {
            let pointInLine = CGPoint(
                x: pointInFragment.x - line.typographicBounds.minX,
                y: pointInFragment.y - line.typographicBounds.minY
            )
            let index = line.characterIndex(for: pointInLine)
            guard index != NSNotFound else { return nil }
            let absolute = elementStart + index
            guard absolute >= 0, absolute < attributed.length else { return nil }
            // A tap past the end of the line resolves to its last character;
            // only count it as a link if the point is over the glyphs.
            let glyphEnd = line.locationForCharacter(at: line.characterRange.location + line.characterRange.length).x
            guard pointInLine.x <= glyphEnd else { return nil }
            return attributed.attribute(.link, at: absolute, effectiveRange: nil) as? URL
        }
        return nil
    }
}
#endif
