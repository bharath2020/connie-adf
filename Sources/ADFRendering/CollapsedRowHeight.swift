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
        /// media).
        case proportional(cap: CGFloat?)
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
        case .proportional(let cap):
            // Clamp both widths at the cap: past it the box no longer grows,
            // so the height only responds to the capped portion of a width
            // change (measured and target both above the cap ⇒ unchanged).
            let target = min(width, cap ?? .infinity)
            let source = min(newest.width, cap ?? .infinity)
            guard source > 0 else { return newest.height }
            return newest.height * target / source
        case .reflowing:
            return newest.height * newest.width / width
        }
    }
}

extension RenderBlock.Kind {
    var heightScaling: CollapsedRowHeight.Scaling {
        switch self {
        case .media(let media):
            .proportional(cap: media.maxWidthCap)
        case .codeBlock, .tableSlice, .divider, .card, .mediaStrip:
            // `mediaStrip` is a horizontally scrolling strip of fixed-height
            // thumbnails (`MediaStripView`), so like code and table slices
            // its height ignores the column width.
            .invariant
        case .richText, .listRows, .panel, .quote, .expand, .layoutColumns,
             .extensionPlaceholder, .unknown:
            .reflowing
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
