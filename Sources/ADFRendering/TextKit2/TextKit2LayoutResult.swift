#if canImport(UIKit)
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
        /// The run backgrounds' band (`RunBackgrounds`): the tallest
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
#endif
