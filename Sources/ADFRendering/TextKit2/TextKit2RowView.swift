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
        /// Tallest ascent and deepest descent of the runs set on the line,
        /// by their fonts, as `Text` counts them (`glyphMetrics`).
        var ascent: CGFloat
        var descent: CGFloat
        /// The run backgrounds' band (`drawRunBackgrounds`): the tallest
        /// ascent with baseline offsets applied as CoreText applies them (a
        /// subscript lowers it), and the baseline offset every run on the
        /// line shares (0 when they differ).
        var bandAscent: CGFloat = 0
        var sharedOffset: CGFloat = 0
        /// UTF-16 range of the line in the row's string.
        var range: NSRange
        /// How far below TextKit's own placement the line sits (nonzero
        /// after a superscript line, see `settleSuperscriptLines`); `frame`
        /// and `baseline` already include it.
        var offset: CGFloat = 0
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
/// small (e.g. H1 at xxxLarge, 97.12 px). Text containing a link is laid
/// out and drawn through TextKit 1, as SwiftUI lays it out and draws it
/// (`textKit1Result`, `drawTextKit1`); such a row reports itself as
/// TextKit 1-backed, never as a native TextKit 2 draw
/// (`TextKit2Diagnostics`).
final class TextKit2RowView: UIView, UIGestureRecognizerDelegate {
    private let contentStorage = NSTextContentStorage()
    private let layoutManager = NSTextLayoutManager()
    private let textContainer = NSTextContainer(size: CGSize(width: 1, height: CGFloat.greatestFiniteMagnitude))
    private let canvas = TextKit2CanvasView()

    private(set) var inputs: TextKit2RenderInputs?
    private var attributed = NSAttributedString()
    private var links: [(range: NSRange, url: URL)] = []
    /// Lays out and draws text containing a link (`textKit1Result`,
    /// `drawTextKit1`); nil otherwise.
    private var textKit1: TextKit1Stack? {
        didSet {
            guard (textKit1 != nil) != isTextKit1Backed else { return }
            isTextKit1Backed = textKit1 != nil
            TextKit2Diagnostics.shared.row(textKit1Backed: isTextKit1Backed)
        }
    }
    /// Whether the row's TextKit 1 stack lays out and draws its text.
    private(set) var isTextKit1Backed = false
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

    /// Present only while the text has a link (`rebuildLinks`).
    private var tapRecognizer: UITapGestureRecognizer?
    /// The link under the touch that began the tap: a finger drifting
    /// within tap slop off the glyphs still opens it.
    private var tapLink: URL?

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
        // No trait-change registration: the colour scheme arrives as an
        // input (`apply` sets the override and redraws), and the override
        // shields the row from its ancestors' scheme. No tap recognizer
        // either until the text has a link (`rebuildLinks`): rows are
        // created and released by the screenful on every switch, so each
        // per-row object counts.
        TextKit2Diagnostics.shared.rowCreated()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        let owner = ownerID
        let backed = isTextKit1Backed
        // UIKit releases views on the main thread; hop there if a caller
        // ever drops the last reference elsewhere.
        if Thread.isMainThread {
            MainActor.assumeIsolated { TextKit2Diagnostics.shared.rowDestroyed(ownerID: owner, textKit1Backed: backed) }
        } else {
            DispatchQueue.main.async { TextKit2Diagnostics.shared.rowDestroyed(ownerID: owner, textKit1Backed: backed) }
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
        // No layout here: SwiftUI re-measures after new inputs and the row
        // syncs on its next bounds change or draw (`syncToBounds`). Laying
        // out at the old bounds width now would usually be wasted — a
        // hugging row's next size differs.
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

    /// The layout SwiftUI placed this row from: the most recent bounded
    /// measurement whose reported size is `size` — matching the height
    /// too, since two proposals that hug to the same width can wrap
    /// differently — else one of that width (a parent that stretches the
    /// height), else a layout at `size.width`. (A natural-size
    /// measurement's container is unbounded, useless for alignment.)
    func placedResult(for size: CGSize) -> TextKit2LayoutResult {
        guard inputs != nil, size.width > 0 else { return .zero }
        let bounded = { (result: TextKit2LayoutResult) in result.width != Self.unboundedWidth }
        return cache.mostRecent { $0.size == size && bounded($0) }
            ?? cache.mostRecent { $0.size.width == size.width && bounded($0) }
            ?? result(atWidth: size.width)
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
        var belows: [(extent: CGFloat, raised: Bool)] = []
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
                    bandAscent: metrics.bandAscent,
                    sharedOffset: metrics.sharedOffset,
                    range: range
                ))
                belows.append((metrics.below, metrics.raised))
                // Once a line fills a bounded width, the reported width is
                // that width; no further line needs measuring.
                if width == Self.unboundedWidth || maxLineWidth < width {
                    maxLineWidth = max(maxLineWidth, self.measuredLineWidth(line, range: range, text: text, leftToRight: leftToRight))
                }
            }
            return true
        }
        if let textKit1, !lines.isEmpty {
            return textKit1Result(textKit1, width: width, ink: ink, scale: scale)
        }
        if belows.contains(where: \.raised) { settleSuperscriptLines(&lines, belows: belows) }
        if let moved = lines.last?.offset, moved > 0, !ink.isNull { ink.size.height += moved }
        settleTrailingEmptyLine(&lines, belows: belows)
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
        let hugging = Self.pixelCeil(maxLineWidth, scale: scale)
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

    /// Moves the lines below a line set with a raised (superscript) run to
    /// where `Text` places them. TextKit 2 lets a raised run's offset eat
    /// its descent (a line of superscript only gets none) and fits the line
    /// in the font's leading-inclusive line height; `Text` keeps the run's
    /// descent below the baseline and only lets the raise eat the run's
    /// leading — measured from `Text.Layout` line origins (offsets −4…12 pt,
    /// every pairing of plain, superscript and subscript lines). Such a
    /// line is followed by its `below` extent (`glyphMetrics`); every line
    /// under it moves down by the difference to TextKit's own spacing.
    /// Lines without a raised run keep TextKit's spacing (the same rule).
    private func settleSuperscriptLines(_ lines: inout [TextKit2LayoutResult.Line], belows: [(extent: CGFloat, raised: Bool)]) {
        var offset: CGFloat = 0
        for index in lines.indices {
            if offset != 0 {
                lines[index].frame.origin.y += offset
                lines[index].baseline += offset
                lines[index].offset = offset
            }
            guard belows[index].raised, index + 1 < lines.count else { continue }
            // TextKit's spacing below this line: to the next line's top.
            let below = lines[index + 1].frame.minY + offset - lines[index].baseline
            offset += belows[index].extent - below
        }
    }

    /// Text with a link, laid out as `Text` lays it out (and draws it,
    /// `drawTextKit1`): by the row's TextKit 1 stack. TextKit 1 breaks
    /// lines differently next to emoji (an emoji TextKit 2 lets end a line
    /// wraps), spaces a superscript line by its full leading, and sizes
    /// the frame by its used rect (measured: every height of `Text`,
    /// xSmall…AX5, and the `text-dense` blocks TextKit 2 sized a line
    /// short). Its line heights leave fallback fonts out, as `Text`'s do
    /// (`TextKit1Stack`). The used rect stops at the container's edges —
    /// narrower than the widest line when lines are centred or end-aligned
    /// (their trailing whitespace hangs past the edge; measured 350.667 for
    /// the 353.333 the line-width rule gives). TextKit 2's layout still
    /// bounds the ink (`ink`).
    private func textKit1Result(_ stack: TextKit1Stack, width: CGFloat, ink: CGRect, scale: CGFloat) -> TextKit2LayoutResult {
        stack.setWidth(width)
        let manager = stack.manager
        var lines: [TextKit2LayoutResult.Line] = []
        var glyph = 0
        while glyph < manager.numberOfGlyphs {
            var glyphs = NSRange()
            let rect = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &glyphs)
            let used = manager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            let range = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let metrics = glyphMetrics(onLine: range)
            // A glyph's location sits its run's baseline offset off the line's.
            let raise = (attributed.attribute(.baselineOffset, at: range.location, effectiveRange: nil) as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
            lines.append(.init(
                frame: CGRect(x: used.minX, y: rect.minY, width: used.width, height: rect.height),
                baseline: rect.minY + manager.location(forGlyphAt: glyph).y + raise,
                ascent: metrics.ascent, descent: metrics.descent,
                bandAscent: metrics.bandAscent, sharedOffset: metrics.sharedOffset,
                range: range
            ))
            glyph = max(NSMaxRange(glyphs), glyph + 1)
        }
        let extra = manager.extraLineFragmentRect
        if !extra.isEmpty {
            let metrics = glyphMetrics(onLine: NSRange(location: attributed.length, length: 0))
            lines.append(.init(
                frame: CGRect(x: extra.minX, y: extra.minY, width: 0, height: extra.height),
                baseline: extra.minY + metrics.ascent, ascent: metrics.ascent, descent: metrics.descent,
                range: NSRange(location: attributed.length, length: 0)
            ))
        }
        let usedRect = manager.usedRect(for: stack.container)
        let hugging = Self.pixelCeil(min(usedRect.maxX, width) - max(usedRect.minX, 0), scale: scale)
        let reportedWidth = width == Self.unboundedWidth ? hugging : min(hugging, Self.pixelCeil(width, scale: scale))
        let first = lines.first?.baseline ?? 0
        let last = lines.last?.baseline ?? 0
        let bounds = CGRect(x: 0, y: 0, width: usedRect.maxX, height: usedRect.maxY)
        return TextKit2LayoutResult(
            width: width,
            size: CGSize(width: reportedWidth, height: Self.pixelCeil(usedRect.maxY, scale: scale)),
            firstBaseline: Self.pixelRound(first, scale: scale),
            lastBaseline: Self.pixelRound(last, scale: scale),
            lines: lines,
            inkBounds: ink.isNull ? bounds : ink.union(bounds)
        )
    }

    /// Places the empty line a trailing hard break opens the way `Text`
    /// does: its baseline sits the previous line's descent plus its own
    /// ascent plus the leading below the previous baseline — the previous
    /// line's positive leading (`glyphMetrics`: a subscript's, not the
    /// break's, on a subscript line), the break font's negative leading —
    /// before iOS 26 without positive leading (negative applies on both).
    /// Measured on iOS 26.3 and 18.5, xSmall…AX5, body and title1, one and
    /// two trailing breaks: every height exact. TextKit's own extra line
    /// fragment differs: it ignores negative leading after a first line,
    /// and after two breaks it takes the default font (13.8 pt tall).
    /// Before iOS 26, with two or more trailing breaks at AX3+, `Text` also
    /// drops the negative leading of the middle empty line (0.333–1.333 pt
    /// shorter than this layout, no exact rule found), so such text stays
    /// on SwiftUI there (`TextKit2Eligibility`).
    private func settleTrailingEmptyLine(_ lines: inout [TextKit2LayoutResult.Line], belows: [(extent: CGFloat, raised: Bool)]) {
        guard lines.count >= 2, let last = lines.last, last.range.length == 0,
              attributed.length > 0, last.range.location >= attributed.length else { return }
        let previous = lines[lines.count - 2]
        let font = attributed.attribute(.font, at: attributed.length - 1, effectiveRange: nil) as? UIFont
        var leading = min(0, font?.leading ?? 0)
        if #available(iOS 26.0, *) { leading += belows[lines.count - 2].extent - previous.descent }
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

    /// The tallest ascent and deepest descent of the glyphs set on a line,
    /// as `Text.Layout` reports them: per attribute run, its font's — a
    /// fallback font's (emoji, Devanagari) do not count: `Text` sizes "ab 🧪"
    /// and "ab नम" by the system font alone, 1600/1600 sizes 10…58 pt,
    /// where CoreText's line bounds are taller — with a baseline offset only
    /// ever growing them (a superscript's raise adds to its ascent, a
    /// subscript's drop to its descent; measured). A line's
    /// closing break does not count (TextKit and `Text` both skip it); an
    /// empty line (after a trailing hard break) takes the attributes of the
    /// break.
    ///
    /// `below`: the extent `Text` keeps below the baseline before the next
    /// line's ascent — the largest of the runs' descent plus leading, a
    /// raised run's leading reduced by its raise (measured from
    /// `Text.Layout` line origins). Negative leading (AX5) is not part of
    /// it: it shortens the next line's ascent, as TextKit lays it out.
    /// `raised`: the line has a raised run. `bandAscent`, `sharedOffset`:
    /// see `TextKit2LayoutResult.Line`.
    private func glyphMetrics(onLine range: NSRange) -> (ascent: CGFloat, descent: CGFloat, below: CGFloat, raised: Bool, bandAscent: CGFloat, sharedOffset: CGFloat) {
        let length = attributed.length
        guard length > 0 else { return (0, 0, 0, false, 0, 0) }
        var measured = NSIntersectionRange(range, NSRange(location: 0, length: length))
        if measured.length == 0 {
            measured = NSRange(location: min(max(range.location - 1, 0), length - 1), length: 1)
        } else if measured.length > 1,
                  let end = Unicode.Scalar((attributed.string as NSString).character(at: NSMaxRange(measured) - 1)),
                  CharacterSet.newlines.contains(end) {
            measured.length -= 1
        }
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var below = -CGFloat.greatestFiniteMagnitude
        var raised = false
        var bandAscent = -CGFloat.greatestFiniteMagnitude
        var offsets: Set<CGFloat> = []
        attributed.enumerateAttributes(in: measured) { attributes, _, _ in
            let offset = (attributes[.baselineOffset] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
            let font = attributes[.font] as? UIFont ?? UIFont.preferredFont(forTextStyle: .body)
            let runAscent = font.ascender, runDescent = -font.descender, leading = font.leading
            ascent = max(ascent, runAscent + max(offset, 0))
            descent = max(descent, runDescent + max(-offset, 0))
            bandAscent = max(bandAscent, runAscent + offset)
            offsets.insert(offset)
            if offset > 0 { raised = true }
            below = max(below, runDescent + max(-offset, 0) + max(leading - max(offset, 0), 0))
        }
        return (ascent, descent, below, raised, bandAscent, offsets.count == 1 ? offsets.first ?? 0 : 0)
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

    /// Re-syncs the layout manager to the layout SwiftUI placed this row
    /// from (`placedResult(for:)`, whose container width can be wider than
    /// the bounds of a hugging row) and sizes the canvas: the bounds horizontally (SwiftUI's `Text`
    /// clips glyph overhang at its frame's edges — measured: a line-initial
    /// "j" under an indentation loses its tail) and the bounds plus the ink
    /// overhang vertically. Called on bounds changes, on new inputs, and
    /// before every draw and hit test.
    @discardableResult
    private func syncToBounds() -> TextKit2LayoutResult? {
        guard inputs != nil, bounds.width > 0 else { return nil }
        let current = placedResult(for: bounds.size)
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
        context.saveGState()
        context.translateBy(x: -origin.x, y: -origin.y)
        let scale = inputs?.displayScale ?? 1
        if let textKit1 {
            drawTextKit1(textKit1, in: context, scale: scale)
            context.restoreGState()
            TextKit2Diagnostics.shared.didDraw(native: false, textKit1: true)
            return
        }
        context.translateBy(x: drawnShift, y: 0)
        if let first = drawn?.lines.first {
            context.translateBy(x: 0, y: Self.pixelRound(first.baseline, scale: scale) - first.baseline)
        }
        drawRunBackgrounds(in: context, scale: scale)
        let offsets = drawn?.lines.map(\.offset) ?? []
        var index = 0
        var fragments = 0
        layoutManager.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
            let origin = fragment.layoutFragmentFrame.origin
            let lines = fragment.textLineFragments
            let moved = offsets[min(index, offsets.count)..<min(index + lines.count, offsets.count)].contains { $0 != 0 }
            if moved {
                // Lines below a superscript line sit lower than TextKit
                // placed them (`settleSuperscriptLines`).
                for (line, offset) in zip(lines, offsets[index...]) {
                    let at = line.typographicBounds.origin
                    line.draw(at: CGPoint(x: origin.x + at.x, y: origin.y + at.y + offset), in: context)
                }
            } else {
                fragment.draw(at: origin, in: context)
            }
            index += lines.count
            fragments += 1
            return true
        }
        context.restoreGState()
        TextKit2Diagnostics.shared.didDraw(native: fragments > 0)
    }

    /// Text containing a link, drawn as SwiftUI draws it: SwiftUI renders
    /// such text (interactive) through TextKit 1 string drawing, whose
    /// underlines, strikethroughs (descender-skipping, placed per line) and
    /// background fills (whole line fragments, leading included) TextKit 2
    /// does not reproduce. Measured: SwiftUI draws with an
    /// `NSLayoutManager` (font leading off, no line fragment padding) in a
    /// container as wide as the `Text`'s frame, its first baseline on a
    /// device pixel — this does the same, identical to the pixel
    /// (`TextKit2PixelParityTests`). The same stack lays the text out
    /// (`textKit1Result`) and hit-tests its links.
    private func drawTextKit1(_ stack: TextKit1Stack, in context: CGContext, scale: CGFloat) {
        stack.setWidth(bounds.width)
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
    /// the line's `bandAscent` and down by its descent — moved by the run's
    /// baseline offset beyond the one the whole line shares (a superscript
    /// highlighted among plain text rises by its raise; a line set wholly
    /// in it does not move) — edges
    /// unsnapped (antialiased: the partial pixel rows and columns carry the
    /// fill's coverage), the leading between lines unpainted; horizontally
    /// from the run's first caret to its last, trailing whitespace
    /// included; clipped to the row's bounds. Coordinates here already
    /// carry the first-baseline snap.
    private func drawRunBackgrounds(in context: CGContext, scale: CGFloat) {
        var fills: [(range: NSRange, color: UIColor, offset: CGFloat)] = []
        attributed.enumerateAttribute(.adfRunBackground, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            guard let color = value as? UIColor else { return }
            attributed.enumerateAttribute(.baselineOffset, in: range) { offset, run, _ in
                fills.append((run, color, (offset as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0))
            }
        }
        guard !fills.isEmpty, let result = drawn, let first = result.lines.first else { return }
        let shift = Self.pixelRound(first.baseline, scale: scale) - first.baseline
        // The context is translated by `drawnShift` and `shift`; the row's
        // edges in these coordinates.
        let clipRight = bounds.width - drawnShift
        let clipTop = -shift
        let clipBottom = result.size.height - shift
        for line in result.lines {
            for fill in fills {
                let overlap = NSIntersectionRange(fill.range, line.range)
                guard overlap.length > 0 else { continue }
                let raise = fill.offset - line.sharedOffset
                let top = max(line.baseline - line.bandAscent - raise, clipTop)
                let bottom = min(line.baseline + line.descent - raise, clipBottom)
                guard bottom > top else { continue }
                // The overlap lies on this line, so its segments do too.
                for rect in containerSegmentRects(for: overlap) {
                    let right = min(rect.maxX, clipRight)
                    guard right > rect.minX else { continue }
                    context.setFillColor(fill.color.cgColor)
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
        if found.isEmpty, let recognizer = tapRecognizer {
            removeGestureRecognizer(recognizer)
            tapRecognizer = nil
        } else if !found.isEmpty, tapRecognizer == nil {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
            tapRecognizer = recognizer
        }
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
        guard let tapRecognizer, gestureRecognizer === tapRecognizer else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        tapLink = link(at: gestureRecognizer.location(in: self))
        return tapLink != nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let url = tapLink else { return }
        tapLink = nil
        openURL?(url)
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

    // MARK: Geometry

    /// Text-segment rects (row coordinates) covering a UTF-16 range in the
    /// layout being drawn — the geometry search highlights (PR 7) and
    /// selection (PR 8) build on.
    func segmentRects(for range: NSRange) -> [CGRect] {
        guard syncToBounds() != nil else { return [] }
        if let textKit1 { return textKit1SegmentRects(textKit1, for: range) }
        return containerSegmentRects(for: range).map { $0.offsetBy(dx: drawnShift, dy: 0) }
    }

    /// Text-segment rects (row coordinates) of text with a link, which
    /// TextKit 1 lays out and draws (`drawTextKit1`): per line, the glyphs'
    /// bounding rect across the line fragment's height.
    private func textKit1SegmentRects(_ stack: TextKit1Stack, for range: NSRange) -> [CGRect] {
        stack.setWidth(bounds.width)
        let manager = stack.manager
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return [] }
        let scale = inputs?.displayScale ?? 1
        let baseline = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).minY + manager.location(forGlyphAt: 0).y
        let snap = Self.pixelRound(baseline, scale: scale) - baseline
        var rects: [CGRect] = []
        manager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, lineGlyphs, _ in
            let part = NSIntersectionRange(lineGlyphs, glyphs)
            guard part.length > 0 else { return }
            let box = manager.boundingRect(forGlyphRange: part, in: stack.container)
            if box.width > 0 { rects.append(CGRect(x: box.minX, y: rect.minY + snap, width: box.width, height: rect.height)) }
        }
        return rects
    }

    /// Text-segment rects in the layout container's coordinates.
    private func containerSegmentRects(for range: NSRange) -> [CGRect] {
        let documentStart = contentStorage.documentRange.location
        guard range.location != NSNotFound,
              let start = contentStorage.location(documentStart, offsetBy: range.location),
              let end = contentStorage.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return [] }
        var rects: [CGRect] = []
        let lines = drawn?.lines ?? []
        layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
            guard frame.width > 0 else { return true }
            // Moved with its line (`settleSuperscriptLines`), found by where
            // TextKit placed it.
            let offset = lines.first { line in
                line.offset != 0 && (line.frame.minY - line.offset..<line.frame.maxY - line.offset).contains(frame.midY)
            }?.offset ?? 0
            rects.append(frame.offsetBy(dx: 0, dy: offset))
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

/// A TextKit 1 stack configured as SwiftUI's string drawing configures it
/// (font leading off, no line fragment padding), with one difference from
/// a default stack that `Text` also has: a fallback font (an emoji's
/// Apple Color Emoji, substituted into the storage by TextKit 1) never
/// grows a line. Measured: TextKit 1 counts the emoji face's taller
/// metrics (+0.0135 pt per emoji line at AX3, one pixel after the frame's
/// ceil, 4 px over `link-emoji-wrap` at AX5); `Text` sizes such lines by
/// the run's own font, as TextKit 2 rows do (`glyphMetrics`).
private final class TextKit1Stack: NSObject, NSLayoutManagerDelegate {
    let storage: NSTextStorage
    let manager = NSLayoutManager()
    let container = NSTextContainer(size: .zero)
    /// The string as built, before TextKit 1 substitutes fallback fonts.
    private let intended: NSAttributedString

    init(_ string: NSAttributedString) {
        intended = string
        storage = NSTextStorage(attributedString: string)
        super.init()
        manager.usesFontLeading = false
        manager.delegate = self
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
    }

    func setWidth(_ width: CGFloat) {
        guard container.size.width != width else { return }
        container.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    }

    /// Takes out of each line what its fallback fonts add over the fonts
    /// the text was built with: the same max-of-runs metric over the
    /// storage's fonts (after substitution) and over the built ones, the
    /// difference removed from the fragment and its used rect (the ascent
    /// part also from the baseline). Lines without a substituted font are
    /// left exactly as TextKit 1 set them.
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<CGRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<CGRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let range = NSIntersectionRange(characters, NSRange(location: 0, length: min(intended.length, storage.length)))
        guard range.length > 0 else { return false }
        let substituted = Self.extent(of: storage, in: range)
        let built = Self.extent(of: intended, in: range)
        let ascent = max(substituted.ascent - built.ascent, 0)
        let descent = max(substituted.descent - built.descent, 0)
        guard ascent > 0 || descent > 0 else { return false }
        lineFragmentRect.pointee.size.height -= ascent + descent
        lineFragmentUsedRect.pointee.size.height -= ascent + descent
        baselineOffset.pointee -= ascent
        return true
    }

    /// The tallest ascent and deepest descent of the fonts set over
    /// `range`, a baseline offset only ever growing them.
    private static func extent(of string: NSAttributedString, in range: NSRange) -> (ascent: CGFloat, descent: CGFloat) {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        string.enumerateAttributes(in: range) { attributes, _, _ in
            guard let font = attributes[.font] as? UIFont else { return }
            let offset = (attributes[.baselineOffset] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
            ascent = max(ascent, font.ascender + max(offset, 0))
            descent = max(descent, -font.descender + max(-offset, 0))
        }
        return (ascent, descent)
    }
}

/// Bounded width → layout memo (least recently used evicted first).
private struct LayoutCache {
    static let capacity = 4
    private var entries: [(width: CGFloat, result: TextKit2LayoutResult)] = []

    var keys: [CGFloat] { entries.map(\.width) }

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
