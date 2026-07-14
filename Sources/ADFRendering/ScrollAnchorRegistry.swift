/// Holds the ID of the row at the top of the viewport, so the scroll view can
/// keep the reader's place when the document reflows at a new width (rotation,
/// iPad Split View).
///
/// A `ScrollView` retains its content *offset* across a resize, but rows reflow
/// to different heights at a different width, so the same offset lands on
/// different content and the reader loses their place. `scrollPosition(id:)`
/// binds the scroll view to a row identity instead, and SwiftUI keeps that row
/// anchored through the resize.
///
/// **Why this is a plain class rather than `@State`.** SwiftUI writes the
/// binding every time the top row changes — once per row crossed, throughout
/// every scroll. Backing it with `@State` (or anything `@Observable`) would
/// re-evaluate the document view on each of those writes, and reconciling every
/// row the lazy stack has materialized is O(rows so far) — the cost the §8
/// 5k-block hitch gate measures as frame drops that grow with scroll depth,
/// and the reason `scrollPosition(id:)` was rejected here the first time.
/// Writing into a reference type invalidates nothing, so the binding is free.
///
/// Do not reach for per-row geometry to track this instead: reading
/// `proxy.frame(in: .named(…))` from inside every live row resolves a named
/// coordinate space during `LazySubviewPlacements.placeSubviews`, which pins
/// the main thread at 100% CPU and never settles after a fling.
@MainActor
final class ScrollAnchorRegistry {
    var topRow: String?
}
