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

    /// Row identity for `RowGeometryRegistry` self-registration (Task 17) —
    /// the same key `SegmentedTextView.ownerID` already uses for search
    /// highlighting. `nil` opts the row out of registration entirely
    /// (previews, chrome), same as search.
    var ownerID: String? = nil
    /// The document's row-geometry registry, threaded down from
    /// `ADFDocumentView` via `SegmentedTextView`. `nil` outside a document
    /// (previews) or when selection isn't wired — registration is then a
    /// no-op.
    var registry: RowGeometryRegistry? = nil

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
    /// Matched-atom id sets for the whole-pill tint (Task 21, gap #3), read
    /// behind the same `search.isActive` zero-work gate as `spans` above —
    /// empty when no session is active. Mirrors the SwiftUI arm's
    /// `atomHighlight(for:)` (`SegmentedTextView.swift`), which paints the
    /// SAME two sets over `AtomView`'s background.
    var atomIDs: Set<String> = []
    var currentAtomIDs: Set<String> = []
    /// The pill corner radius the tint rect is drawn with — matches the
    /// SwiftUI arm's `theme.chipCornerRadius` (`InlineTokenView`'s
    /// `.background { RoundedRectangle(cornerRadius: theme.chipCornerRadius) }`),
    /// applied uniformly to every atom kind there (capsule pills included),
    /// so this stays byte-for-byte the same shape as the parity target.
    var chipCornerRadius: CGFloat = 6

    /// Host-supplied mention-popover content, mirrored from the SwiftUI arm's
    /// `adfMentionContent` environment key (`AtomViews.MentionAtomView`) —
    /// the TK2-arm hit-test route presents the SAME content in a native
    /// popover anchored to the tapped pill. `nil` renders mentions read-only,
    /// exactly like the SwiftUI arm with no host callback injected.
    var mentionContent: (@MainActor (String) -> AnyView)? = nil
    /// URL-open action, mirrored from the SwiftUI arm's `\.openURL`
    /// environment (SwiftUI always supplies a concrete default —
    /// `UIApplication.shared.open` — even with no host override, so this
    /// property defaults the same way rather than being optional).
    var openURL: @MainActor (URL) -> Void = { UIApplication.shared.open($0) }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.displayScale) private var displayScale

    func makeUIView(context: Context) -> TextKit2RowUIView { TextKit2RowUIView() }

    func updateUIView(_ view: TextKit2RowUIView, context: Context) {
        view.ownerID = ownerID
        view.registry = registry
        view.registerIfNeeded()
        view.mentionContent = mentionContent
        view.openURL = openURL
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
                currentForeground: currentForeground,
                atomIDs: atomIDs,
                currentAtomIDs: currentAtomIDs,
                chipCornerRadius: chipCornerRadius)))
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
    /// pill is baseline-aligned to — correct. A pure-atom row (no text run at
    /// all, e.g. a paragraph of nothing but atoms with no separating text)
    /// recovers the leading atom's OWN pill ascent (Task 23) —
    /// `AtomAttachment.pillAscent`, a pure function of `(atom, category)`
    /// derived from the same geometry the pill draws with, never measured
    /// layout (§16). Falls through to the `0` fallback only if `segments` is
    /// empty (shouldn't happen for a real row, but keeps the function total).
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
        if case .atom(let atom, _) = segments.first {
            return AtomAttachment(atom: atom, categoryRawValue: categoryRawValue).pillAscent
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
            /// Matched-atom id sets for the whole-pill tint (Task 21, gap
            /// #3) — empty when no search session is active.
            var atomIDs: Set<String> = []
            var currentAtomIDs: Set<String> = []
            var chipCornerRadius: CGFloat = 6
        }
        let content: Content
        let paint: Paint
    }

    private let layout = TextRowLayout()
    private var inputs: Inputs?
    private(set) var content: TextRowContent?
    private var drawnWidth: CGFloat = -1

    /// Row-geometry self-registration (Task 17). `ownerID`/`registry` are set
    /// by `TextKit2RowView.updateUIView`, independent of `Inputs`/`apply` —
    /// registration is a pure identity/window concern, never a content
    /// rebuild trigger.
    var ownerID: String?
    weak var registry: RowGeometryRegistry?

    /// Task 21 — atom/link hit-testing routing targets, set every
    /// `updateUIView` pass alongside `ownerID`/`registry` (a plain identity
    /// concern, independent of `Inputs`/`apply`). See `handleRowTap`.
    var mentionContent: (@MainActor (String) -> AnyView)?
    var openURL: @MainActor (URL) -> Void = { UIApplication.shared.open($0) }

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
        // Task 25 — minimal accessibility exposure (gap #8): every row is a
        // VoiceOver element. A stored `true` set once here, NOT recomputed
        // per `apply()` — the expensive part (building the label string) is
        // isolated to the lazily-evaluated `accessibilityLabel`/
        // `accessibilityTraits` getters below, which UIKit only calls when
        // an accessibility client actually queries the tree.
        isAccessibilityElement = true
        // Task 21 — idle link/atom tap handling (gap #1/#2), a plain
        // descendant-level recognizer on the row itself: it works whether or
        // not `SelectionFlags.enabled` is even true (`SelectionController`
        // doesn't exist when it's false), which is exactly the case the
        // phase-3 register flagged ("TK2-arm text links have no tap
        // handler"). No `hitTest` override — see `handleRowTap` for the
        // interplay with the v3 selection overlay when
        // `SelectionFlags.enabled` IS true.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleRowTap(_:)))
        // A held-then-released touch still satisfies a plain
        // `UITapGestureRecognizer` (it has no built-in maximum duration) —
        // confirmed on-device: a 1s hold on a link opened it via THIS
        // recognizer even though `SelectionController`'s ancestor long-press
        // (0.5s `minimumPressDuration`) had already started a word-select
        // session on the SAME touch, since ancestor/descendant recognizers
        // are independent by default (the same fact `touchHitsDescendantControl`
        // exists to arbitrate for tap-to-clear). `tapDurationSentinel` gives
        // `tap` a genuine maximum hold duration, self-contained on the row —
        // no reference to `SelectionController` (or its existence) needed —
        // so a long hold anywhere always resolves to "start selection, don't
        // also open the link/atom," whether or not `SelectionFlags.enabled`
        // is true.
        tap.require(toFail: tapDurationSentinel)
        addGestureRecognizer(tap)
        addGestureRecognizer(tapDurationSentinel)
    }

    /// Duration-only gate for `handleRowTap` — see `init`'s comment. Never
    /// given a target/action: only its PASS/FAIL state matters, via
    /// `tap.require(toFail:)`. `minimumPressDuration` sits just under
    /// `SelectionController`'s long-press threshold (UIKit's 0.5s default)
    /// so a deliberate long-press always fails this sentinel first, letting
    /// the real long-press recognizer win the touch cleanly.
    private let tapDurationSentinel: UILongPressGestureRecognizer = {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = 0.4
        recognizer.cancelsTouchesInView = false
        return recognizer
    }()
    required init?(coder: NSCoder) { fatalError("unused") }

    /// Registers with `registry` when this row enters a window, evicts when
    /// it leaves (the collapse path — a row's `TextKit2RowUIView` is torn
    /// down when its `DocumentRow` collapses to a spacer). No beacon views at
    /// rest: this is the only registration cost, and it never runs on the
    /// scroll path itself (only on the one-time window-attach transition).
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let ownerID else { return }
        if window != nil { registry?.register(ownerID: ownerID, view: self) }
        else { registry?.unregister(ownerID: ownerID) }
    }

    /// Registers immediately if this view is ALREADY inside a window when
    /// `ownerID`/`registry` are (re)assigned by `updateUIView` — `didMoveToWindow`
    /// only fires on a window TRANSITION, so a lazily-materialized row whose
    /// `updateUIView` sets these after SwiftUI already inserted it into the
    /// live hierarchy would otherwise never register. Idempotent (`register`
    /// itself de-dupes by `ownerID`), so calling this every `updateUIView`
    /// pass is harmless.
    func registerIfNeeded() {
        guard window != nil, let ownerID else { return }
        registry?.register(ownerID: ownerID, view: self)
    }

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
        guard !paint.spans.isEmpty || !paint.currentSpans.isEmpty
            || !paint.atomIDs.isEmpty || !paint.currentAtomIDs.isEmpty else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        drawAtomPillHighlights(paint, content: content, in: ctx)
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

    /// Whole-pill search-match tint (Task 21, gap #3): a matched atom's ONE
    /// U+FFFC attachment char (Task 10) tints entirely — a partial-glyph
    /// highlight makes no sense for a pill, so this fills a rounded rect over
    /// the WHOLE attachment glyph rect rather than routing atom segments
    /// through `fillRects`' per-`Character` span math (which is a no-op for
    /// them anyway: `content.segmentStrings[index] == ""` for every atom).
    /// Mirrors the SwiftUI arm's `atomHighlight(for:)` +
    /// `InlineTokenView.highlightColor(_:)` (`SegmentedTextView.swift`):
    /// current-match wins over subtle, dimmed current uses the subtle color,
    /// same `chipCornerRadius` shape for every atom kind (capsule pills
    /// included) — a byte-for-byte parity match, not just a visual
    /// approximation. Drawn BEFORE `fillRects` so a corner nicked by a
    /// following span-based fill (there won't be one here, but the ordering
    /// is the same "background before glyphs" contract) never draws over it.
    private func drawAtomPillHighlights(_ paint: Inputs.Paint, content: TextRowContent, in ctx: CGContext) {
        guard !paint.atomIDs.isEmpty || !paint.currentAtomIDs.isEmpty else { return }
        guard let segments = inputs?.content.segments else { return }
        for (index, segment) in segments.enumerated() {
            guard case .atom(_, let id) = segment else { continue }
            let isCurrent = paint.currentAtomIDs.contains(id)
            guard isCurrent || paint.atomIDs.contains(id) else { continue }
            let color = isCurrent ? (paint.dimCurrent ? paint.subtleColor : paint.currentColor) : paint.subtleColor
            let nsRange = NSRange(location: content.segmentUTF16Starts[index], length: 1)
            color.setFill()
            for rect in selectionRects(forUTF16: nsRange) where rect.width > 0 && rect.height > 0 {
                UIBezierPath(roundedRect: rect, cornerRadius: paint.chipCornerRadius).fill()
            }
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
    /// UTF-16 offset into one. Promoted to `internal` (from Task 9's
    /// `private`) so the geometry-query methods below — reachable from
    /// `@testable import` — can share it.
    func textRange(for nsRange: NSRange) -> NSTextRange? {
        let contentStorage = layout.contentStorage
        guard let start = contentStorage.location(contentStorage.documentRange.location, offsetBy: nsRange.location),
              let end = contentStorage.location(start, offsetBy: nsRange.length) else {
            return nil
        }
        return NSTextRange(location: start, end: end)
    }

    // MARK: Row geometry (Task 17)

    /// Real-layout selection rects for a UTF-16 range in THIS row's attributed
    /// string, in the row's own coordinate space. Reads the already-committed
    /// `layoutManager` — never triggers a re-measure (§16). The caller
    /// converts to container space via `convert(_:to:)`.
    func selectionRects(forUTF16 range: NSRange) -> [CGRect] {
        guard range.length > 0, let textRange = textRange(for: range) else { return [] }
        var rects: [CGRect] = []
        layout.layoutManager.enumerateTextSegments(in: textRange, type: .selection) { _, frame, _, _ in
            if frame.width > 0, frame.height > 0 { rects.append(frame) }
            return true
        }
        return rects
    }

    func caretRect(atUTF16 offset: Int) -> CGRect? {
        guard let textRange = textRange(for: NSRange(location: offset, length: 0)) else { return nil }
        var caret: CGRect?
        layout.layoutManager.enumerateTextSegments(in: textRange, type: .standard) { _, frame, _, _ in
            caret = CGRect(x: frame.minX, y: frame.minY, width: 2, height: frame.height); return false
        }
        return caret
    }

    /// UTF-16 offset in THIS row nearest a point in the row's own space, via
    /// the TK2 line fragment under the point (`NSTextLineFragment` is UTF-16).
    func closestUTF16Offset(to point: CGPoint) -> Int? {
        var result: Int?
        layout.layoutManager.enumerateTextLayoutFragments(from: nil, options: []) { fragment in
            let frame = fragment.layoutFragmentFrame
            guard frame.minY <= point.y, point.y < frame.maxY else { return true }
            let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
            for line in fragment.textLineFragments {
                let lineRect = line.typographicBounds
                guard local.y >= lineRect.minY, local.y < lineRect.maxY || line === fragment.textLineFragments.last else { continue }
                let charInLine = line.characterIndex(for: CGPoint(x: local.x, y: lineRect.midY))
                let fragmentStart = layout.contentStorage.offset(
                    from: layout.contentStorage.documentRange.location,
                    to: fragment.rangeInElement.location)
                result = fragmentStart + charInLine
                return false
            }
            return true
        }
        return result
    }

    // MARK: Selection part mapping (Task 19)

    /// Segment index of the atom whose structural node ID is `id`, or nil.
    /// The selection engine turns a corpus atom part (`.atom(id:)`) into the
    /// ONE U+FFFC attachment char the row renders for it, located at
    /// `content.segmentUTF16Starts[index]` (Task 10 — one attachment char per
    /// atom). Walks the row's own input segments, which carry each atom's ID
    /// (`InlineSegment.atom(_, id:)`).
    func segmentIndex(forAtomID id: String) -> Int? {
        guard let segments = inputs?.content.segments else { return nil }
        for (index, segment) in segments.enumerated() {
            if case .atom(_, let atomID) = segment, atomID == id { return index }
        }
        return nil
    }

    /// Resolves a UTF-16 offset in THIS row's attributed string back to the
    /// corpus part it belongs to and the `Character` offset within that part —
    /// the inverse of the search/selection part → row-UTF-16 mapping. Used by
    /// `closestPosition` so a live-row hit lifts to the virtual document's
    /// global offset space (the row treats an atom as one U+FFFC char; the
    /// returned `.atom` offset is 0 at the pill's leading edge, 1 past it).
    func rowAnchor(atRowUTF16 offset: Int) -> (source: SearchTextUnit.Part.Source, localCharOffset: Int)? {
        guard let content, let segments = inputs?.content.segments, !segments.isEmpty else { return nil }
        var segment = 0
        for (index, start) in content.segmentUTF16Starts.enumerated() {
            if start <= offset { segment = index } else { break }
        }
        let within = offset - content.segmentUTF16Starts[segment]
        switch segments[segment] {
        case .atom(_, let id):
            return (.atom(id: id), within >= 1 ? 1 : 0)
        case .text:
            let charOffset = TextRowContent.characterOffset(forUTF16Offset: within, inSegment: segment, of: content)
            return (.textSegment(index: segment), charOffset)
        }
    }

    // MARK: Atom/link hit-testing (Task 21)

    /// A tap target resolved from the row's own committed layout: either a
    /// text run's `.link` attribute, or an atom's structural node ID.
    enum AtomOrLinkHit: Equatable {
        case link(URL)
        case atom(id: String)
    }

    /// The link or atom under `point` (row-local coordinates), or nil if
    /// `point` isn't actually over a glyph/attachment's own drawn bounds.
    ///
    /// Unlike `closestUTF16Offset` (a "nearest" query used to seed a text
    /// selection anywhere in the row, including blank trailing space),
    /// this is an EXACT hit-test: it re-verifies the candidate character's
    /// own glyph rect — via `selectionRects(forUTF16:)`, the same
    /// `enumerateTextSegments(type: .selection)` geometry `RowGeometrySource`
    /// already uses for atom rects — actually contains `point`, so a tap past
    /// the end of a short line (or in the gutter beside a pill) never
    /// resolves to that line's last character.
    func hitTest(atomOrLinkAt point: CGPoint) -> AtomOrLinkHit? {
        guard let offset = closestUTF16Offset(to: point) else { return nil }
        let glyphRects = selectionRects(forUTF16: NSRange(location: offset, length: 1))
        guard glyphRects.contains(where: { $0.contains(point) }) else { return nil }
        guard let anchor = rowAnchor(atRowUTF16: offset) else { return nil }
        if case .atom(let id) = anchor.source { return .atom(id: id) }
        guard let attributed = content?.attributed, offset < attributed.length,
              let url = attributed.attribute(.link, at: offset, effectiveRange: nil) as? URL
        else { return nil }
        return .link(url)
    }

    /// Idle tap handling (spec parity gaps #1/#2 — see `init`'s comment for
    /// why this lives on the row rather than the container). Composes with
    /// the v3 selection overlay (Task 20) purely through existing hit-test
    /// mechanics: when a session is active, the overlay is frontmost and
    /// spans the whole content, but `SelectionOverlayView.point(inside:with:)`
    /// only claims points near the CURRENT selection's own rects — so a tap
    /// there hit-tests to the overlay and never reaches this recognizer at
    /// all (a sibling of the overlay, not an ancestor of the hit view, gets
    /// no delivery — the exact "row taps only receive touches the overlay
    /// declines" contract). A tap elsewhere in a live session (e.g. a link in
    /// a DIFFERENT paragraph than the current selection) still reaches BOTH
    /// this recognizer AND `SelectionController`'s ancestor tap-to-clear
    /// recognizer — by design (documented, not fought): the link opens AND
    /// the selection clears ("cleared-then-native"), matching how tapping
    /// away from a native text selection elsewhere always clears it.
    @objc private func handleRowTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let hit = hitTest(atomOrLinkAt: gesture.location(in: self)) else { return }
        switch hit {
        case .link(let url):
            openURL(url)
        case .atom(let id):
            routeAtomTap(id: id)
        }
    }

    /// Routes an atom tap exactly like the SwiftUI arm's `AtomView` does:
    /// only `.mention` (popover, if the host injected `adfMentionContent`)
    /// and `.inlineCard` (open URL, mirroring `InlineCardChip`'s `Link`) are
    /// interactive — `.status`/`.date`/`.emoji`/`.mediaInline`/
    /// `.inlineExtension` render read-only pills there too, so a tap on one
    /// here is a no-op, not a constrained gap.
    private func routeAtomTap(id: String) {
        guard let segments = inputs?.content.segments,
              let segIndex = segmentIndex(forAtomID: id),
              case .atom(let atom, _) = segments[segIndex] else { return }
        switch atom {
        case .mention(let raw):
            guard let mentionContent, let content else { return }
            let anchor = selectionRects(
                forUTF16: NSRange(location: content.segmentUTF16Starts[segIndex], length: 1)
            ).first ?? bounds
            presentMentionPopover(mentionContent(AtomFormatting.mentionText(raw)), anchorRect: anchor)
        case .inlineCard(let urlString):
            guard let urlString, let url = URL(string: urlString) else { return }
            openURL(url)
        case .status, .date, .emoji, .mediaInline, .inlineExtension:
            break
        }
    }

    /// Presents host-supplied SwiftUI content in a native popover anchored to
    /// the tapped pill — the UIKit-context equivalent of the SwiftUI arm's
    /// `.popover(isPresented:)` (adapts to a sheet in a compact size class,
    /// same as there). Found via the standard `next`-responder walk to the
    /// nearest `UIViewController`; a miss (no host view controller reachable)
    /// is a silent no-op rather than a crash.
    private func presentMentionPopover(_ view: AnyView, anchorRect: CGRect) {
        guard let presenter = nearestViewController() else { return }
        let hosting = UIHostingController(rootView: view)
        hosting.modalPresentationStyle = .popover
        hosting.popoverPresentationController?.sourceView = self
        hosting.popoverPresentationController?.sourceRect = anchorRect
        hosting.popoverPresentationController?.permittedArrowDirections = .any
        presenter.present(hosting, animated: true)
    }

    private func nearestViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let viewController = current as? UIViewController { return viewController }
            responder = current.next
        }
        return nil
    }

    // MARK: Accessibility (Task 25 — minimal exposure prototype, gap #8)

    /// Measured baseline (`docs/TextKit2-Port-Assessment.md`, "Phase 4 —
    /// Task 25"): a bare `TextKit2RowUIView` exposes NOTHING to VoiceOver —
    /// not merged into one opaque `AXTextArea` (the phase-1 spike's
    /// *ancestor*-`UITextInput* design), just entirely absent, because a
    /// plain `UIView` carries no accessibility by default. This is the
    /// minimal fix: one accessibility element per row, carrying the row's
    /// full text as ONE label — proving a path exists, not the production
    /// per-run element model (scope note in the assessment covers that).
    ///
    /// Computed ONLY when actually queried — never cached, never touched by
    /// `apply()`/`draw()`/`layoutSubviews()` — so an idle scroll pass with
    /// VoiceOver off pays exactly nothing beyond the one `isAccessibilityElement`
    /// store in `init`. Built from `content.segmentStrings` (already
    /// extracted by `TextRowContent.make` — no re-walk of the source
    /// `AttributedString`) plus each atom's `fallbackText`, via
    /// `RowAccessibilityLabel.build` (a pure, macOS-testable helper).
    override var accessibilityLabel: String? {
        get {
            guard let content, let segments = inputs?.content.segments, !segments.isEmpty else { return nil }
            let label = RowAccessibilityLabel.build(segments: segments, segmentStrings: content.segmentStrings)
            return label.isEmpty ? nil : label
        }
        set {}
    }

    /// `.header` for heading rows (approximated from the first text run's
    /// `FontSpec.style` — levels 1–4 only, see `RowAccessibilityLabel.isHeading`'s
    /// doc comment for why 5–6 are out of scope), `.staticText` otherwise —
    /// the same read-only-text baseline every other UIKit label carries.
    /// Computed lazily, same discipline as `accessibilityLabel` above.
    override var accessibilityTraits: UIAccessibilityTraits {
        get {
            guard let segments = inputs?.content.segments else { return .staticText }
            return RowAccessibilityLabel.isHeading(segments) ? [.staticText, .header] : .staticText
        }
        set {}
    }

    // `accessibilityLanguage` is deliberately left at UIKit's default
    // (`nil`): a row's text always renders in the host UI's own language —
    // there is no per-run language override anywhere in the ADF model this
    // minimal pass would have data for — so `nil` (inherit from the
    // surrounding accessibility container) is already correct, not an
    // omission.
}
#endif
