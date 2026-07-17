import CoreGraphics
import ADFPreparation

/// The height a collapsed row reports for a container width.
///
/// A row that has scrolled out of the render region is replaced by a spacer
/// (see `ADFDocumentView.DocumentRow`), and the spacer must state a height
/// without laying the block out — re-materializing every stale row at once
/// livelocks layout. So the row remembers what it measured.
///
/// Two rules, in order:
///
/// 1. **Remember, don't derive.** Heights are kept per container width, so
///    rotating to landscape and back restores the *exact* portrait height
///    rather than a heuristic's guess at it. The widths a document is ever
///    laid out at are few (portrait, landscape, a Split View fraction), so
///    the memo stays tiny.
/// 2. **Only estimate a width never seen before**, and estimate it per block
///    kind. Height does not respond to width the same way for every block:
///    an image grows taller as it widens, a code block or table slice scrolls
///    horizontally and keeps its height, and only reflowing text trades width
///    for height. Applying one rule to all three (the previous behaviour) made
///    a rotation resize every off-screen spacer wrongly, which corrupts the
///    scroll view's content height.
///
/// The estimate is provisional either way: the exact height is re-measured
/// when the row naturally re-enters the render region.
struct CollapsedRowHeight {
    /// How a block's height responds to a change in container width.
    enum Scaling: Equatable {
        /// Aspect-ratio bound (media): wider means taller — but only up to
        /// `cap`, the width past which the box stops growing (media never
        /// upscales beyond its explicit or intrinsic pixel width). `nil`
        /// means the box tracks the column at any width (fraction-width
        /// media). `fixedOverhead` is the part of the measured row height
        /// that does NOT scale with width (the row's vertical padding): the
        /// measured height is affine (`box(width) + overhead`), so carrying
        /// the whole measurement proportionally would inflate the overhead
        /// by the width ratio — ~12 pt per row portrait→landscape, an error
        /// that multiplies across every collapsed row.
        case proportional(cap: CGFloat?, fixedOverhead: CGFloat)
        /// Fixed height, or horizontally scrollable (code, table slices,
        /// dividers, link cards, media strips): width does not move the
        /// height.
        case invariant
        /// Wrapping text: roughly as many fewer lines as the column gained
        /// width, so height falls as width rises.
        case reflowing
    }

    /// Most recent measurements, newest first, one per width. Bounded because
    /// dragging an iPad Split View divider lays the document out at a
    /// continuum of widths, and a row must not accumulate one entry per frame.
    private var samples: [(width: CGFloat, height: CGFloat)] = []
    private static let capacity = 6

    var isEmpty: Bool { samples.isEmpty }

    /// Rounded so that sub-point layout jitter at one orientation doesn't
    /// read as a new width and force a re-estimate.
    private static func key(_ width: CGFloat) -> CGFloat {
        (width * 2).rounded() / 2
    }

    mutating func record(height: CGFloat, at width: CGFloat) {
        guard width > 0 else { return }
        let width = Self.key(width)
        samples.removeAll { $0.width == width }
        samples.insert((width, height), at: 0)
        if samples.count > Self.capacity {
            samples.removeLast(samples.count - Self.capacity)
        }
    }

    /// Carries every remembered height across a Dynamic Type size change as
    /// an estimate: text reflows at the same width to roughly
    /// `factor = newBodyPointSize / oldBodyPointSize` times the height.
    ///
    /// Rescaling — never clearing — is load-bearing: an empty memo makes
    /// `DocumentRow` re-materialize the row to measure it, and a type-size
    /// change hits every collapsed row at once (see §16: mass
    /// re-materialization livelocks layout). The estimate is provisional,
    /// like the per-kind width estimates: the exact height is re-measured
    /// when the row naturally re-enters the render region.
    ///
    /// When the readable measure also moves with the type size (full-screen
    /// iPad, where the column is capped by a `@ScaledMetric` width), this
    /// rescale composes with the per-kind width carry-across in `height(at:)`
    /// — the reflowing carry divides one point-size ratio back out, which is
    /// why wrapping kinds rescale by the ratio squared (see
    /// `RenderBlock.Kind.typeSizeRescaleFactor`).
    mutating func rescale(by factor: CGFloat) {
        guard factor > 0, factor != 1 else { return }
        samples = samples.map { ($0.width, $0.height * factor) }
    }

    /// The height to report at `width`: the measured one when this row has
    /// been laid out at that width before, otherwise the newest measurement
    /// carried across by `scaling`.
    func height(at width: CGFloat, scaling: Scaling) -> CGFloat? {
        guard let newest = samples.first else { return nil }
        let width = Self.key(width)
        if let exact = samples.first(where: { $0.width == width }) {
            return exact.height
        }
        guard width > 0, newest.width > 0 else { return newest.height }
        switch scaling {
        case .invariant:
            return newest.height
        case .proportional(let cap, let fixedOverhead):
            // Clamp both widths at the cap: past it the box no longer grows,
            // so the height only responds to the capped portion of a width
            // change (measured and target both above the cap ⇒ unchanged).
            // Only the content portion scales; the fixed overhead (vertical
            // row padding) carries across unchanged — for an uncapped
            // aspect box the affine carry is exact, not an estimate.
            let target = min(width, cap ?? .infinity)
            let source = min(newest.width, cap ?? .infinity)
            guard source > 0 else { return newest.height }
            let content = max(newest.height - fixedOverhead, 0)
            return content * target / source + fixedOverhead
        case .reflowing:
            return newest.height * newest.width / width
        }
    }
}

extension RenderBlock.Kind {
    var heightScaling: CollapsedRowHeight.Scaling {
        switch self {
        case .media(let media):
            // Media keeps the historical whole-row carry (overhead 0): its
            // rows mix box, caption, and layout-dependent padding, so a
            // single fixed overhead would be a guess — the small padding
            // inflation stays in the documented self-correcting-estimate
            // class. Custom aspect blocks below carry their known fixed
            // padding exactly instead.
            .proportional(cap: media.maxWidthCap, fixedOverhead: 0)
        case .codeBlock, .tableSlice, .divider, .card, .mediaStrip:
            // `mediaStrip` is a horizontally scrolling strip of fixed-height
            // thumbnails (`MediaStripView`), so like code and table slices
            // its height ignores the column width.
            .invariant
        case .richText, .listRows, .panel, .quote, .expand, .layoutColumns,
             .extensionPlaceholder, .unknown:
            .reflowing
        case .custom(let custom):
            // The plugin declared its profile at preparation time; map it
            // onto the same three behaviors the built-in kinds use. The
            // aspect box's measured row height includes the row's fixed
            // vertical padding (`defaultVerticalPadding` top + bottom),
            // which must not scale with the width ratio.
            switch custom.sizing {
            case .aspectRatio(_, _, let maxWidth):
                .proportional(
                    cap: maxWidth.map { CGFloat($0) },
                    fixedOverhead: defaultVerticalPadding * 2
                )
            case .scaledChrome:
                .invariant
            case .reflowingText:
                .reflowing
            }
        }
    }

    /// The factor a collapsed row's remembered heights scale by when the
    /// body point size changes by `ratio` (new ÷ old). Exhaustive on
    /// purpose, like `heightScaling` above: a new block kind must declare
    /// how its height answers the text size, or it doesn't compile.
    ///
    /// Wrapping text roughly follows `height ∝ pointSize² ÷ width` (each
    /// line gets taller AND fits fewer characters), so reflowing kinds scale
    /// by `ratio²` — which also keeps the estimate honest on full-screen
    /// iPad, where the `@ScaledMetric` readable column widens by ~`ratio`
    /// and `height(at:)`'s reflowing carry-across divides one `ratio` back
    /// out. Non-wrapping text (code, table slices, cards, media strips —
    /// the strip height is itself `@ScaledMetric`) keeps its line structure
    /// and scales linearly. Media boxes are pixel- or fraction-sized and a
    /// divider is a hairline plus fixed padding — neither tracks the text
    /// size. (Captioned media and `@ScaledMetric` fallback boxes make the
    /// media `1` a slight understatement — the same self-correcting-estimate
    /// class as the width heuristics; exact on natural re-entry.)
    ///
    /// The factor applies to a row's WHOLE remembered height, so a collapsed
    /// OPEN expand whose body is dominated by media or code is over-scaled
    /// by up to `ratio²` — the largest error this estimate class can carry,
    /// since expand bodies are unbounded in height. Position is unaffected
    /// (the re-anchor holds the top row by identity); only content height
    /// and scrollbar proportions are off until the row re-enters (ADR §19).
    func typeSizeRescaleFactor(bodyPointRatio ratio: CGFloat) -> CGFloat {
        switch self {
        case .media, .divider:
            1
        case .codeBlock, .tableSlice, .card, .mediaStrip:
            ratio
        case .richText, .listRows, .panel, .quote, .expand, .layoutColumns,
             .extensionPlaceholder, .unknown:
            ratio * ratio
        case .custom(let custom):
            switch custom.sizing {
            case .aspectRatio: 1
            case .scaledChrome: ratio
            case .reflowingText: ratio * ratio
            }
        }
    }
}

private extension PreparedMedia {
    /// Mirrors `MediaBlockView.maxWidthCap`: the width past which the media
    /// box stops growing — an explicit pixel width, else the intrinsic width
    /// (media never upscales). Fraction-width media has no cap; its box is a
    /// fraction of the column at any width.
    var maxWidthCap: CGFloat? {
        if let pixelWidth, pixelWidth > 0 { return CGFloat(pixelWidth) }
        guard widthFraction == nil else { return nil }
        return attrs.width.flatMap { $0 > 0 ? CGFloat($0) : nil }
    }
}
