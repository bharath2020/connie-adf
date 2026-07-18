#if os(iOS)
import SwiftUI
import UIKit
import ADFPreparation

/// One text row rendered by TextKit 2. Sizing contract (§16): synchronous,
/// deterministic, memoized per width; the view NEVER self-invalidates —
/// SwiftUI's proposal is the only sizing authority.
struct TextKit2RowView: UIViewRepresentable {
    let segments: [InlineSegment]
    var blockAlignment: TextAlignment? = nil

    /// Search-highlight paint values, read by the caller behind the same
    /// zero-work gate the SwiftUI arm uses (`search.isActive`) — empty when
    /// no session is active. `segments` above is the BASE text and is never
    /// repainted; these values only drive draw-pass background rects and a
    /// rendering-attribute foreground inside `TextKit2RowUIView`.
    var spans: [SearchHighlightSpan] = []
    /// The navigated-to match's spans, painted over `spans` (accent wins).
    var currentSpans: [SearchHighlightSpan] = []
    /// Arrival-flash off-phase: while true the current match paints with
    /// `subtleColor` instead of `currentColor` (and no forced foreground) —
    /// alternating this produces the accent⇄subtle blink.
    var dimCurrent: Bool = false
    var subtleColor: UIColor = .clear
    var currentColor: UIColor = .clear
    var currentForeground: UIColor? = nil

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.displayScale) private var displayScale

    func makeUIView(context: Context) -> TextKit2RowUIView { TextKit2RowUIView() }

    func updateUIView(_ view: TextKit2RowUIView, context: Context) {
        view.apply(TextKit2RowUIView.Inputs(
            content: TextKit2RowUIView.Inputs.Content(
                segments: segments,
                categoryRawValue: UIContentSizeCategory(dynamicTypeSize).rawValue,
                alignment: nsAlignment,
                rightToLeft: layoutDirection == .rightToLeft,
                displayScale: displayScale),
            paint: TextKit2RowUIView.Inputs.Paint(
                spans: spans,
                currentSpans: currentSpans,
                dimCurrent: dimCurrent,
                subtleColor: subtleColor,
                currentColor: currentColor,
                currentForeground: currentForeground)))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TextKit2RowUIView, context: Context) -> CGSize? {
        uiView.measuredSize(forWidth: proposal.width)
    }

    private var nsAlignment: NSTextAlignment {
        switch blockAlignment {
        case .center: .center
        case .trailing: layoutDirection == .rightToLeft ? .left : .right
        default: .natural
        }
    }

    /// First-line ascent for enclosing `.firstTextBaseline` stacks (list
    /// markers, panel icons). Pure function of the first run's resolved font
    /// — never measured layout, so no geometry feedback (§16).
    ///
    /// Scans for the first `.text` run and returns its font ascender. An
    /// atom-LEADING row (a leading pill before any prose) falls through to the
    /// first following text chunk's ascender, which is the body ascent the
    /// pill is baseline-aligned to — correct. A pure-atom row (no text at all)
    /// returns the `0` fallback; recovering a pill's own ascent here without
    /// measuring layout is a T13 baseline-fidelity item, not this task's.
    @MainActor
    static func firstBaseline(of segments: [InlineSegment], categoryRawValue: String) -> CGFloat {
        for segment in segments {
            if case .text(let text) = segment {
                // Bracket-subscript accessor (matches `TextRowContent.make`);
                // the dynamic-member form is `run.fontSpec`, never `run.adf…`.
                let spec = text.runs.first?[FontSpecAttribute.self] ?? .body
                return FontSpecResolver.shared.font(for: spec, categoryRawValue: categoryRawValue).ascender
            }
        }
        return 0
    }
}

final class TextKit2RowUIView: UIView {
    struct Inputs: Equatable {
        /// Everything that feeds `TextRowContent.make`. Compared
        /// independently from `Paint` so an arrival-flash toggle (a
        /// paint-only change) never rebuilds `TextRowContent` or re-sets
        /// `TextRowLayout`'s attributed string — redraw only, never relayout.
        struct Content: Equatable {
            let segments: [InlineSegment]
            let categoryRawValue: String
            let alignment: NSTextAlignment
            let rightToLeft: Bool
            let displayScale: CGFloat
        }
        /// Search-highlight draw values. A change here only triggers a
        /// redraw (`setNeedsDisplay`) plus a rendering-attribute update —
        /// base text (`Content.segments`) is never touched.
        struct Paint: Equatable {
            let spans: [SearchHighlightSpan]
            let currentSpans: [SearchHighlightSpan]
            let dimCurrent: Bool
            let subtleColor: UIColor
            let currentColor: UIColor
            let currentForeground: UIColor?
        }
        let content: Content
        let paint: Paint
    }

    private let layout = TextRowLayout()
    private var inputs: Inputs?
    private(set) var content: TextRowContent?
    private var drawnWidth: CGFloat = -1

    /// Counts calls that actually rebuilt `TextRowContent` (i.e. ran
    /// `TextRowContent.make` + `TextRowLayout.setAttributedString`) —
    /// exposed so a paint-only `apply` (arrival flash, navigation to a new
    /// match) can be proven NOT to have rebuilt content, independent of
    /// `FontSpecResolver`'s own memoization.
    private(set) var conversionCount = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    func apply(_ new: Inputs) {
        guard new != inputs else { return }
        let previous = inputs
        let contentChanged = previous?.content != new.content
        let paintChanged = previous?.paint != new.paint
        inputs = new

        if contentChanged {
            let scale = UIFontMetrics(forTextStyle: .body).scaledValue(
                for: 1,
                compatibleWith: UITraitCollection(preferredContentSizeCategory:
                    UIContentSizeCategory(rawValue: new.content.categoryRawValue)))
            // ^ sole legal UIFontMetrics use: mirroring the @ScaledMetric curve
            //   for baked baseline offsets, matching SegmentedTextView.typeScale.
            let made = TextRowContent.make(
                segments: new.content.segments,
                categoryRawValue: new.content.categoryRawValue,
                alignment: new.content.alignment,
                baselineScale: scale,
                rightToLeft: new.content.rightToLeft)
            content = made
            layout.setAttributedString(made.attributed)
            conversionCount += 1
        }
        if contentChanged || paintChanged {
            applyRenderingAttributes(new.paint)
            setNeedsDisplay()
        }
    }

    func measuredSize(forWidth width: CGFloat?) -> CGSize {
        // A nil proposal — SwiftUI's "unspecified/ideal" query, and the width
        // the horizontal code-block ScrollView proposes on its scroll axis —
        // means "how wide do you want to be?". Answer with the natural
        // single-line width via TextRowLayout's unbounded sentinel (its
        // documented code-block h-scroll contract), exactly as `Text` would.
        // NOT bounds.width: that is 0 on the first sizing pass, which would
        // collapse the row to nothing before it ever lays out.
        let w = width ?? .greatestFiniteMagnitude
        guard w > 0, let inputs else { return .zero }
        return layout.measure(width: w, displayScale: inputs.content.displayScale)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.width != drawnWidth else { return }
        drawnWidth = bounds.width
        _ = layout.measure(width: bounds.width, displayScale: inputs?.content.displayScale ?? 3)
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        drawHighlightBackgrounds(in: ctx)
        layout.layoutManager.enumerateTextLayoutFragments(from: nil, options: []) { fragment in
            fragment.draw(at: fragment.layoutFragmentFrame.origin, in: ctx)
            return true
        }
    }

    // MARK: Search highlights

    /// Match background rects, drawn BEFORE glyphs so text paints on top:
    /// subtle first, current match after (so the accent overwrites where a
    /// current span overlaps a subtle one) — mirrors
    /// `SearchHighlightPainter`'s subtle-then-current ordering, just as
    /// draw-pass compositing instead of baked attributes. Base text/content
    /// storage is never touched by this.
    private func drawHighlightBackgrounds(in ctx: CGContext) {
        guard let inputs, let content else { return }
        let paint = inputs.paint
        guard !paint.spans.isEmpty || !paint.currentSpans.isEmpty else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        for span in paint.spans {
            fillRects(for: span, color: paint.subtleColor, content: content, in: ctx)
        }
        // Dimmed (arrival-flash off-phase) paints the current match with the
        // subtle color instead of the accent — same semantics as
        // `SearchHighlightPainter.apply`'s `dimCurrent` branch.
        let currentColor = paint.dimCurrent ? paint.subtleColor : paint.currentColor
        for span in paint.currentSpans {
            fillRects(for: span, color: currentColor, content: content, in: ctx)
        }
    }

    private func fillRects(
        for span: SearchHighlightSpan, color: UIColor, content: TextRowContent, in ctx: CGContext
    ) {
        guard content.segmentStrings.indices.contains(span.segmentIndex) else { return }
        let nsRange = TextRowContent.utf16Range(charRange: span.range, inSegment: span.segmentIndex, of: content)
        guard nsRange.length > 0, let range = textRange(for: nsRange) else { return }
        color.setFill()
        layout.layoutManager.enumerateTextSegments(in: range, type: .highlight) { _, frame, _, _ in
            if frame.width > 0, frame.height > 0 { ctx.fill(frame) }
            return true
        }
    }

    /// Forces the current (non-dimmed) match's foreground via a TextKit 2
    /// RENDERING ATTRIBUTE on the layout manager — never on the content
    /// storage's attributed string, so base text stays unpainted. Always
    /// clears first: a stale foreground must never survive a paint change
    /// (flash dim step, navigation to a new match) or a content rebuild that
    /// silently invalidated the previous association (a fresh attributed
    /// string means fresh text elements; any rendering attributes keyed to
    /// the old ones are already meaningless, but clearing keeps this
    /// function's contract simple: it always leaves exactly the current
    /// `paint` state applied, nothing left over from before).
    private func applyRenderingAttributes(_ paint: Inputs.Paint) {
        let layoutManager = layout.layoutManager
        let documentRange = layout.contentStorage.documentRange
        layoutManager.setRenderingAttributes([:], for: documentRange)
        guard !paint.dimCurrent, let foreground = paint.currentForeground, let content else { return }
        for span in paint.currentSpans {
            guard content.segmentStrings.indices.contains(span.segmentIndex) else { continue }
            let nsRange = TextRowContent.utf16Range(charRange: span.range, inSegment: span.segmentIndex, of: content)
            guard nsRange.length > 0, let range = textRange(for: nsRange) else { continue }
            layoutManager.setRenderingAttributes([.foregroundColor: foreground], for: range)
        }
    }

    /// Absolute UTF-16 `NSRange` → `NSTextRange`, via offsetting from the
    /// content storage's document start. TextKit 2 locations are opaque —
    /// this `location(_:offsetBy:)` walk is the only legal way to turn a
    /// UTF-16 offset into one.
    private func textRange(for nsRange: NSRange) -> NSTextRange? {
        let contentStorage = layout.contentStorage
        guard let start = contentStorage.location(contentStorage.documentRange.location, offsetBy: nsRange.location),
              let end = contentStorage.location(start, offsetBy: nsRange.length) else {
            return nil
        }
        return NSTextRange(location: start, end: end)
    }
}
#endif
