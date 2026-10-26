#if canImport(UIKit)
import CoreText
import SwiftUI
import UIKit

/// The geometry of one TextKit 2 layout at one width — what sizing, the
/// baseline guides, drawing and hit-testing all read, so they can never
/// disagree.
struct TextKit2LayoutResult: Equatable {
    struct Line: Equatable {
        /// Typographic frame of the line fragment, row coordinates.
        var frame: CGRect
        /// Baseline position, row coordinates (unrounded layout value).
        var baseline: CGFloat
        /// Tallest ascent and deepest descent of the glyphs set on the line,
        /// baseline offsets and fallback fonts included.
        var ascent: CGFloat
        var descent: CGFloat
        /// UTF-16 range of the line in the row's string.
        var range: NSRange
    }

    /// The container width the text was laid out at (the proposed width,
    /// or an unbounded width for a natural-size proposal).
    var width: CGFloat
    /// The size reported to SwiftUI. Like `Text`, the row hugs its lines:
    /// the width is the widest line (trailing whitespace included)
    /// pixel-ceiled, at most the proposal pixel-ceiled (measured: `Text`
    /// reports 300.667 for a 300.5 proposal its whitespace overflows), so
    /// SwiftUI positions it — and rounds that position to the pixel grid —
    /// exactly as it positions `Text` (centre and end alignment).
    var size: CGSize
    /// First and last baselines as SwiftUI's `Text` reports them to
    /// alignment guides: the layout baselines rounded to the nearest pixel
    /// (measured; e.g. 16.187 → 16.333 at 3x).
    var firstBaseline: CGFloat
    var lastBaseline: CGFloat
    var lines: [Line]
    /// Union of the layout fragments' rendering surface bounds, row
    /// coordinates: every pixel glyph ink can touch. The canvas covers it.
    var inkBounds: CGRect

    var lineCount: Int { lines.count }

    static let zero = TextKit2LayoutResult(width: 0, size: .zero, firstBaseline: 0, lastBaseline: 0, lines: [], inkBounds: .zero)
}

/// One paragraph or heading drawn by TextKit 2.
///
/// The view owns its text stack (content storage → layout manager → one
/// unbounded-height container with no padding) and is sized by a full
/// synchronous `ensureLayout` over the document range.
///
/// **Height rule** (measured, plan §4.2/§4.5): SwiftUI's `Text` is
/// `ceil_px(last baseline + deepest descent on the last line)` — TextKit's
/// own fragment frames also charge the font's leading below the last line
/// (≈1.67 pt per body row, the old attempt's cumulative drift), and
/// SwiftUI's leading is not a constant (negative at AX5), so the rule is
/// read from the layout rather than corrected by a subtraction.
///
/// **Sizing contract** (§2.8): results are memoized per width in a 4-entry
/// LRU and are a pure function of (inputs, width). The view NEVER asks
/// SwiftUI to re-measure it (no intrinsic-size invalidation, no layout
/// requests: a self-invalidating row in a lazy stack is the §16 livelock).
/// The single layout manager may have been laid out for another width than
/// the one being drawn, so drawing and hit-testing first re-sync the
/// container to `bounds.width`.
///
/// **Drawing** happens on `canvas`, a non-interactive subview covering the
/// bounds plus the ink overhang (`inkBounds`), so glyphs that reach above
/// the first line or past the edges are never clipped by the backing store.
/// The whole text is drawn shifted so its FIRST baseline sits on the
/// nearest device pixel (later lines keep their fractional offsets from
/// it), and run backgrounds are drawn by the row — SwiftUI's rendering,
/// measured from its bitmaps (`TextKit2PixelParityTests`). Drawn at the
/// unshifted layout position, TextKit's glyphs, underlines and strikes
/// land one pixel lower wherever the first baseline's pixel fraction is
/// small (e.g. H1 at xxxLarge, 97.12 px). Text containing a link is drawn
/// through TextKit 1, as SwiftUI draws it (`drawTextKit1`).
final class TextKit2RowView: UIView, UIGestureRecognizerDelegate {
    private let contentStorage = NSTextContentStorage()
    private let layoutManager = NSTextLayoutManager()
    private let textContainer = NSTextContainer(size: CGSize(width: 1, height: CGFloat.greatestFiniteMagnitude))
    private let canvas = TextKit2CanvasView()

    private(set) var inputs: TextKit2RenderInputs?
    private var attributed = NSAttributedString()
    private var links: [(range: NSRange, url: URL)] = []
    /// Draws text containing a link (`drawTextKit1`); nil otherwise.
    private var textKit1: TextKit1Stack?
    /// Width the layout manager is currently laid out at (`-1`: none).
    private var containerWidth: CGFloat = -1
    /// The layout being drawn and hit-tested (set by `syncToBounds`), and
    /// the horizontal offset from its container to the row: lines are laid
    /// out (and aligned) in the measured container, then shifted so they
    /// sit aligned within the hugging bounds SwiftUI placed the row at.
    private var drawn: TextKit2LayoutResult?
    private var drawnShift: CGFloat = 0
    /// 0 for left-aligned lines, 0.5 centred, 1 right-aligned.
    private var alignmentFactor: CGFloat = 0
    private var cache = LayoutCache()
    /// Container-width relayouts performed by this view (the global count
    /// lives in `TextKit2Diagnostics`).
    private(set) var relayoutCount = 0

    /// The block this row draws; also its accessibility identifier
    /// (`tk2-row:<ownerID>`) and its key in `TextKit2Diagnostics`.
    private(set) var ownerID: String?

    /// Delivered by the representable from the SwiftUI `openURL` action.
    var openURL: ((URL) -> Void)?

    private lazy var tapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        return recognizer
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        clipsToBounds = false
        contentStorage.addTextLayoutManager(layoutManager)
        textContainer.lineFragmentPadding = 0
        layoutManager.textContainer = textContainer
        canvas.row = self
        addSubview(canvas)
        isAccessibilityElement = true
        addGestureRecognizer(tapRecognizer)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: TextKit2RowView, _) in
            // Dynamic colours (`UIColor.label`, mark colours) resolve at
            // draw time, so a scheme change only needs a redraw — never a
            // relayout (metrics are scheme-independent).
            view.canvas.setNeedsDisplay()
        }
        TextKit2Diagnostics.shared.rowCreated()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        let owner = ownerID
        // UIKit releases views on the main thread; hop there if a caller
        // ever drops the last reference elsewhere.
        if Thread.isMainThread {
            MainActor.assumeIsolated { TextKit2Diagnostics.shared.rowDestroyed(ownerID: owner) }
        } else {
            DispatchQueue.main.async { TextKit2Diagnostics.shared.rowDestroyed(ownerID: owner) }
        }
    }

    // MARK: Inputs

    /// Re-applies the text when (and only when) `inputs` changed; a no-op
    /// otherwise, so repeated SwiftUI updates with the same value cost one
    /// `Hashable` compare.
    func apply(_ newInputs: TextKit2RenderInputs, ownerID newOwnerID: String? = nil) {
        if newOwnerID != ownerID {
            TextKit2Diagnostics.shared.row(changedOwnerFrom: ownerID, to: newOwnerID)
            ownerID = newOwnerID
            accessibilityIdentifier = newOwnerID.map { "tk2-row:\($0)" }
        }
        guard newInputs != inputs else { return }
        let schemeChanged = newInputs.colorScheme != inputs?.colorScheme
        inputs = newInputs
        if schemeChanged {
            overrideUserInterfaceStyle = newInputs.colorScheme == .dark ? .dark : .light
        }
        rebuildText()
        accessibilityLabel = String(newInputs.text.characters)
        accessibilityValue = nil
        accessibilityTraits = newInputs.isHeading ? [.staticText, .header] : [.staticText]
    }

    private func rebuildText() {
        guard let inputs else { return }
        attributed = TextKit2TextBuilder.attributedString(for: inputs, linkColor: Self.linkColor)
        contentStorage.attributedString = attributed
        canvas.contentScaleFactor = inputs.displayScale
        containerWidth = -1
        drawn = nil
        cache.removeAll()
        switch (attributed.length > 0 ? attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle : nil)?.alignment {
        case .center: alignmentFactor = 0.5
        case .right: alignmentFactor = 1
        default: alignmentFactor = 0
        }
        rebuildLinks()
        textKit1 = links.isEmpty ? nil : TextKit1Stack(attributed)
        syncToBounds()
        canvas.setNeedsDisplay()
    }

    /// SwiftUI colours `Text` links with the accent colour (measured: the
    /// iOS 26 system blue, 0/136/255 light — not `UIColor.link`, and not a
    /// UIKit `tintColor`, which is unset outside a shown window). A dynamic
    /// colour, resolved at draw time for the row's appearance.
    private static let linkColor = UIColor(Color.accentColor)

    // MARK: Measurement

    /// The layout for a proposed width: `nil` or infinite = natural width
    /// (unbounded container), zero = `.zero` without any layout. Pure in
    /// (inputs, width); memoized.
    func layoutResult(forProposedWidth proposed: CGFloat?) -> TextKit2LayoutResult {
        guard inputs != nil else { return .zero }
        if let proposed, proposed.isFinite {
            guard proposed > 0 else { return .zero }
            return result(atWidth: proposed)
        }
        if let natural = cache.value(for: .infinity) { return natural }
        let natural = compute(atContainerWidth: Self.unboundedWidth)
        cache.insert(natural, for: .infinity)
        return natural
    }

    /// The size for a proposed width (see `layoutResult(forProposedWidth:)`).
    func measuredSize(forProposedWidth proposed: CGFloat?) -> CGSize {
        layoutResult(forProposedWidth: proposed).size
    }

    private func result(atWidth width: CGFloat) -> TextKit2LayoutResult {
        if let cached = cache.value(for: width) { return cached }
        let result = compute(atContainerWidth: width)
        cache.insert(result, for: width)
        return result
    }

    private static let unboundedWidth: CGFloat = 1_000_000

    private func ensureContainer(width: CGFloat) {
        guard width != containerWidth else { return }
        containerWidth = width
        relayoutCount += 1
        TextKit2Diagnostics.shared.didLayout()
        textContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
    }

    private func compute(atContainerWidth width: CGFloat) -> TextKit2LayoutResult {
        ensureContainer(width: width)
        let scale = inputs?.displayScale ?? 1
        var lines: [TextKit2LayoutResult.Line] = []
        var ink = CGRect.null
        var maxLineWidth: CGFloat = 0
        let text = attributed.string as NSString
        let leftToRight = layoutManager.baseWritingDirection(at: layoutManager.documentRange.location) != .rightToLeft
        layoutManager.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            ink = ink.union(fragment.renderingSurfaceBounds.offsetBy(dx: frame.minX, dy: frame.minY))
            let elementStart = self.elementStartOffset(of: fragment)
            for line in fragment.textLineFragments {
                let bounds = line.typographicBounds.offsetBy(dx: frame.minX, dy: frame.minY)
                let range = NSRange(location: elementStart + line.characterRange.location, length: line.characterRange.length)
                let metrics = self.glyphMetrics(onLine: range)
                lines.append(.init(
                    frame: bounds,
                    baseline: bounds.minY + line.glyphOrigin.y,
                    ascent: metrics.ascent,
                    descent: metrics.descent,
                    range: range
                ))
                maxLineWidth = max(maxLineWidth, self.measuredLineWidth(line, range: range, text: text, leftToRight: leftToRight))
            }
            return true
        }
        settleTrailingEmptyLine(&lines)
        guard let first = lines.first, let last = lines.last else {
            // Empty text: SwiftUI gives an empty `Text` one body line.
            let font = TextKit2FontResolver.font(
                for: .init(textStyle: .body), category: inputs?.sizeCategory ?? .large,
                legibilityWeight: inputs?.legibilityWeight
            )
            let height = Self.pixelCeil(font.ascender - font.descender, scale: scale)
            let baseline = Self.pixelRound(font.ascender, scale: scale)
            return TextKit2LayoutResult(
                width: width, size: CGSize(width: width, height: height),
                firstBaseline: baseline, lastBaseline: baseline, lines: [], inkBounds: .zero
            )
        }
        let height = Self.pixelCeil(last.baseline + last.descent, scale: scale)
        // Text with a link is sized as TextKit 1 sizes it (SwiftUI lays it
        // out there, see `drawTextKit1`): by the union of its lines' used
        // rects — narrower than the widest line when lines are centred or
        // end-aligned (their trailing whitespace hangs past the edge).
        // Measured: 350.667 for the 353.333 the line-width rule gives.
        let union = lines.reduce(CGRect.null) { $0.union($1.frame) }
        let hugging = Self.pixelCeil(textKit1 == nil ? maxLineWidth : union.width, scale: scale)
        let reportedWidth = width == Self.unboundedWidth ? hugging : min(hugging, Self.pixelCeil(width, scale: scale))
        return TextKit2LayoutResult(
            width: width,
            size: CGSize(width: reportedWidth, height: height),
            firstBaseline: Self.pixelRound(first.baseline, scale: scale),
            lastBaseline: Self.pixelRound(last.baseline, scale: scale),
            lines: lines,
            inkBounds: ink.isNull ? .zero : ink
        )
    }

    /// Places the empty line a trailing hard break opens the way `Text`
    /// does: its baseline sits the previous line's descent plus its own
    /// ascent plus the font's leading below the previous baseline — before
    /// iOS 26 without positive leading (negative leading applies on both).
    /// Measured on iOS 26.3 and 18.5, xSmall…AX5, body and title1, one and
    /// two trailing breaks: every height exact. TextKit's own extra line
    /// fragment differs: it ignores negative leading after a first line,
    /// and after two breaks it takes the default font (13.8 pt tall).
    /// Residual (iOS 18.5 only): with two or more trailing breaks at AX3+,
    /// `Text` also drops the negative leading of the middle empty line —
    /// 0.333–1.333 pt shorter than this layout.
    private func settleTrailingEmptyLine(_ lines: inout [TextKit2LayoutResult.Line]) {
        guard lines.count >= 2, let last = lines.last, last.range.length == 0,
              attributed.length > 0, last.range.location >= attributed.length else { return }
        let previous = lines[lines.count - 2]
        let font = attributed.attribute(.font, at: attributed.length - 1, effectiveRange: nil) as? UIFont
        var leading = font?.leading ?? 0
        if #unavailable(iOS 26.0) { leading = min(0, leading) }
        let baseline = previous.baseline + previous.descent + last.ascent + leading
        var settled = last
        settled.frame.origin.y += baseline - last.baseline
        settled.baseline = baseline
        lines[lines.count - 1] = settled
    }

    /// A line's width as `Text` sizes itself by (measured against its
    /// reported widths): TextKit's line width, except that a left-to-right
    /// line ending in whitespace TextKit let hang past the container counts
    /// that whitespace too.
    private func measuredLineWidth(_ line: NSTextLineFragment, range: NSRange, text: NSString, leftToRight: Bool) -> CGFloat {
        let width = line.typographicBounds.width
        guard leftToRight, range.length > 0, NSMaxRange(range) <= text.length,
              let last = Unicode.Scalar(text.character(at: NSMaxRange(range) - 1)),
              CharacterSet.whitespaces.contains(last) else { return width }
        let ctLine = CTLineCreateWithAttributedString(attributed.attributedSubstring(from: range) as CFAttributedString)
        return max(width, CTLineGetTypographicBounds(ctLine, nil, nil, nil))
    }

    /// The tallest ascent and deepest descent of the glyphs set on a line:
    /// per attribute run, CoreText's typographic bounds of that run — which
    /// count a fallback font (emoji, CJK) with its own metrics and already
    /// include the run's baseline offset (a subscript's descent grows by its
    /// drop; measured). An empty line (after a trailing hard break) takes
    /// the attributes of the break.
    private func glyphMetrics(onLine range: NSRange) -> (ascent: CGFloat, descent: CGFloat) {
        let length = attributed.length
        guard length > 0 else { return (0, 0) }
        var measured = NSIntersectionRange(range, NSRange(location: 0, length: length))
        if measured.length == 0 {
            measured = NSRange(location: min(max(range.location - 1, 0), length - 1), length: 1)
        }
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        attributed.enumerateAttributes(in: measured) { _, runRange, _ in
            let run = attributed.attributedSubstring(from: runRange)
            let line = CTLineCreateWithAttributedString(run as CFAttributedString)
            var runAscent: CGFloat = 0, runDescent: CGFloat = 0, leading: CGFloat = 0
            CTLineGetTypographicBounds(line, &runAscent, &runDescent, &leading)
            ascent = max(ascent, runAscent)
            descent = max(descent, runDescent)
        }
        return (ascent, descent)
    }

    private func elementStartOffset(of fragment: NSTextLayoutFragment) -> Int {
        guard let location = fragment.textElement?.elementRange?.location else { return 0 }
        return contentStorage.offset(from: contentStorage.documentRange.location, to: location)
    }

    /// Ceil to the pixel grid with SwiftUI's arithmetic: `n × (1/scale)`,
    /// not `n / scale`. The two differ by one ulp for some `n` at scale 3
    /// (127/3 = 42.333333333333336 vs 127 × ⅓ = 42.33333333333333), and the
    /// larger value re-ceils to the NEXT pixel wherever SwiftUI rounds a
    /// reported size up (`UIHostingController.sizeThatFits` does): a
    /// one-pixel height error from float representation alone. The guard
    /// keeps the result a fixed point of the ceil.
    static func pixelCeil(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return value }
        let pixels = (value * scale).rounded(.up)
        var result = pixels * (1 / scale)
        while result * scale > pixels { result = result.nextDown }
        return result
    }

    /// Rounds to the nearest pixel with the same arithmetic as `pixelCeil`.
    static func pixelRound(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return value }
        let pixels = (value * scale).rounded()
        var result = pixels * (1 / scale)
        while result * scale > pixels { result = result.nextDown }
        return result
    }

    // MARK: Layout and drawing

    override func layoutSubviews() {
        super.layoutSubviews()
        syncToBounds()
    }

    /// Re-syncs the layout manager to the layout this view is drawn with
    /// and sizes the canvas: the bounds horizontally (SwiftUI's `Text`
    /// clips glyph overhang at its frame's edges — measured: a line-initial
    /// "j" under an indentation loses its tail) and the bounds plus the ink
    /// overhang vertically. Called on bounds changes, on new inputs, and
    /// before every draw and hit test.
    @discardableResult
    private func syncToBounds() -> TextKit2LayoutResult? {
        guard inputs != nil, bounds.width > 0 else { return nil }
        // The measurement SwiftUI sized this row from: its reported width is
        // the bounds width. (A natural-size measurement's container is
        // unbounded, useless for alignment.) Otherwise lay out at the
        // bounds width.
        let current = cache.mostRecent { $0.size.width == bounds.width && $0.width != Self.unboundedWidth }
            ?? result(atWidth: bounds.width)
        ensureContainer(width: current.width)
        drawn = current
        drawnShift = alignmentFactor * (bounds.width - current.width)
        let ink = current.inkBounds.offsetBy(dx: drawnShift, dy: 0)
        let top = min(bounds.minY, ink.minY)
        let bottom = max(bounds.maxY, ink.maxY)
        let rows = CGRect(x: 0, y: top, width: 1, height: bottom - top).integral
        let canvasFrame = CGRect(x: bounds.minX, y: rows.minY, width: bounds.width, height: rows.height)
        if canvas.frame != canvasFrame {
            canvas.frame = canvasFrame
            canvas.setNeedsDisplay()
        }
        return current
    }

    /// Draws backgrounds, then glyphs, into the canvas's context (whose
    /// origin sits at `origin` in row coordinates).
    fileprivate func drawText(in context: CGContext, canvasOrigin origin: CGPoint) {
        guard syncToBounds() != nil else { return }
        TextKit2Diagnostics.shared.didDraw()
        context.saveGState()
        context.translateBy(x: -origin.x, y: -origin.y)
        let scale = inputs?.displayScale ?? 1
        if let textKit1 {
            drawTextKit1(textKit1, in: context, scale: scale)
        } else {
            context.translateBy(x: drawnShift, y: 0)
            if let first = drawn?.lines.first {
                context.translateBy(x: 0, y: Self.pixelRound(first.baseline, scale: scale) - first.baseline)
            }
            drawRunBackgrounds(in: context, scale: scale)
            layoutManager.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
                fragment.draw(at: fragment.layoutFragmentFrame.origin, in: context)
                return true
            }
        }
        context.restoreGState()
    }

    /// Text containing a link, drawn as SwiftUI draws it: SwiftUI renders
    /// such text (interactive) through TextKit 1 string drawing, whose
    /// underlines, strikethroughs (descender-skipping, placed per line) and
    /// background fills (whole line fragments, leading included) TextKit 2
    /// does not reproduce. Measured: SwiftUI draws with an
    /// `NSLayoutManager` (font leading off, no line fragment padding) in a
    /// container as wide as the `Text`'s frame, its first baseline on a
    /// device pixel — this does the same, identical to the pixel
    /// (`TextKit2PixelParityTests`). The TextKit 2 layout still sizes the
    /// row and hit-tests links; both engines break these lines the same.
    private func drawTextKit1(_ stack: TextKit1Stack, in context: CGContext, scale: CGFloat) {
        if stack.container.size.width != bounds.width {
            stack.container.size = CGSize(width: bounds.width, height: CGFloat.greatestFiniteMagnitude)
        }
        let glyphs = stack.manager.glyphRange(for: stack.container)
        guard glyphs.length > 0 else { return }
        let baseline = stack.manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).minY
            + stack.manager.location(forGlyphAt: 0).y
        let origin = CGPoint(x: 0, y: Self.pixelRound(baseline, scale: scale) - baseline)
        UIGraphicsPushContext(context)
        // SwiftUI clips the fills (not the glyphs) to the frame: the last
        // line's fragment can reach a pixel row below it.
        context.saveGState()
        context.clip(to: bounds)
        stack.manager.drawBackground(forGlyphRange: glyphs, at: origin)
        context.restoreGState()
        stack.manager.drawGlyphs(forGlyphRange: glyphs, at: origin)
        UIGraphicsPopContext()
    }

    /// Run background fills as SwiftUI draws them for text without a link
    /// (text with one is drawn by TextKit 1, `drawTextKit1`) — measured
    /// from its bitmaps (xSmall … AX5, with and without sub/superscripts on
    /// the line): per line the run touches, a band from the baseline up by
    /// the line's ascent and down by its descent, edges unsnapped
    /// (antialiased: the partial pixel rows and columns carry the fill's
    /// coverage), the leading between lines unpainted; horizontally from
    /// the run's first caret to its last, trailing whitespace included;
    /// clipped to the row's bounds. Coordinates here already carry the
    /// first-baseline snap.
    private func drawRunBackgrounds(in context: CGContext, scale: CGFloat) {
        var fills: [(NSRange, UIColor)] = []
        attributed.enumerateAttribute(.adfRunBackground, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            if let color = value as? UIColor { fills.append((range, color)) }
        }
        guard !fills.isEmpty, let result = drawn, let first = result.lines.first else { return }
        let shift = Self.pixelRound(first.baseline, scale: scale) - first.baseline
        // The context is translated by `drawnShift` and `shift`; the row's
        // right and bottom edges in these coordinates.
        let clipRight = bounds.width - drawnShift
        let clipBottom = result.size.height - shift
        for line in result.lines {
            let top = line.baseline - line.ascent
            let bottom = min(line.baseline + line.descent, clipBottom)
            guard bottom > top else { continue }
            for (range, color) in fills {
                let overlap = NSIntersectionRange(range, line.range)
                guard overlap.length > 0 else { continue }
                // The overlap lies on this line, so its segments do too.
                for rect in containerSegmentRects(for: overlap) {
                    let right = min(rect.maxX, clipRight)
                    guard right > rect.minX else { continue }
                    context.setFillColor(color.cgColor)
                    context.fill(CGRect(x: rect.minX, y: top, width: right - rect.minX, height: bottom - top))
                }
            }
        }
    }

    // MARK: Links

    private func rebuildLinks() {
        var found: [(range: NSRange, url: URL)] = []
        attributed.enumerateAttribute(.adfLink, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            if let url = value as? URL { found.append((range, url)) }
        }
        links = found
        accessibilityCustomActions = found.isEmpty ? nil : found.map { link in
            UIAccessibilityCustomAction(name: Self.linkActionName(link.url)) { [weak self] _ in
                guard let self, let openURL = self.openURL else { return false }
                openURL(link.url)
                return true
            }
        }
    }

    /// VoiceOver custom action name for a link.
    static func linkActionName(_ url: URL) -> String {
        "Open link \(url.host ?? url.absoluteString)"
    }

    /// Only a touch that starts on a link's glyphs begins the tap, so taps
    /// elsewhere — and every scroll — pass straight through.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === tapRecognizer else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        return link(at: gestureRecognizer.location(in: self)) != nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        openLink(at: recognizer.location(in: self))
    }

    /// Opens the link under `point` through `openURL`; `false` when no
    /// link's glyphs are there (or no handler is installed).
    @discardableResult
    func openLink(at point: CGPoint) -> Bool {
        guard let openURL, let url = link(at: point) else { return false }
        openURL(url)
        return true
    }

    /// The link whose glyphs lie under `point` (row coordinates), if any:
    /// the point must fall inside one of the link range's text-segment
    /// rects (its glyph runs, one per line it spans) — never "the nearest
    /// character", so whitespace past a line's end or below the text
    /// resolves to nothing.
    func link(at point: CGPoint) -> URL? {
        guard !links.isEmpty, bounds.contains(point), syncToBounds() != nil else { return nil }
        for link in links where segmentRects(for: link.range).contains(where: { $0.contains(point) }) {
            return link.url
        }
        return nil
    }

    /// Text-segment rects (row coordinates) covering a UTF-16 range in the
    /// layout being drawn.
    func segmentRects(for range: NSRange) -> [CGRect] {
        guard syncToBounds() != nil else { return [] }
        return containerSegmentRects(for: range).map { $0.offsetBy(dx: drawnShift, dy: 0) }
    }

    /// Text-segment rects in the layout container's coordinates.
    private func containerSegmentRects(for range: NSRange) -> [CGRect] {
        let documentStart = contentStorage.documentRange.location
        guard range.location != NSNotFound,
              let start = contentStorage.location(documentStart, offsetBy: range.location),
              let end = contentStorage.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return [] }
        var rects: [CGRect] = []
        layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
            if frame.width > 0 { rects.append(frame) }
            return true
        }
        return rects
    }

    // MARK: Test hooks

    /// The frame the canvas draws into (row coordinates).
    var canvasFrame: CGRect { canvas.frame }

    /// Width the layout manager is laid out at right now.
    var currentContainerWidth: CGFloat { containerWidth }

    /// Widths currently memoized, most recently used last.
    var cachedWidths: [CGFloat] { cache.keys }
}

/// The row's drawing surface: covers the row's bounds plus the glyph ink
/// overhang. Not interactive and not an accessibility element — the row
/// owns both.
private final class TextKit2CanvasView: UIView {
    weak var row: TextKit2RowView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        row?.drawText(in: context, canvasOrigin: frame.origin)
    }
}

/// Bounded width → layout memo (least recently used evicted first).
/// A TextKit 1 stack configured as SwiftUI's string drawing configures it.
private struct TextKit1Stack {
    let storage: NSTextStorage
    let manager = NSLayoutManager()
    let container = NSTextContainer(size: .zero)

    init(_ string: NSAttributedString) {
        storage = NSTextStorage(attributedString: string)
        manager.usesFontLeading = false
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
    }
}

private struct LayoutCache {
    static let capacity = 4
    private var entries: [(width: CGFloat, result: TextKit2LayoutResult)] = []

    var keys: [CGFloat] { entries.map(\.width) }

    /// A cached result without touching the recency order.
    func peek(_ width: CGFloat) -> TextKit2LayoutResult? {
        entries.first { $0.width == width }?.result
    }

    /// The most recently used result matching `predicate`.
    func mostRecent(where predicate: (TextKit2LayoutResult) -> Bool) -> TextKit2LayoutResult? {
        entries.last { predicate($0.result) }?.result
    }

    mutating func value(for width: CGFloat) -> TextKit2LayoutResult? {
        guard let index = entries.firstIndex(where: { $0.width == width }) else { return nil }
        let entry = entries.remove(at: index)
        entries.append(entry)
        return entry.result
    }

    mutating func insert(_ result: TextKit2LayoutResult, for width: CGFloat) {
        entries.removeAll { $0.width == width }
        entries.append((width, result))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: true)
    }
}
#endif
