#if canImport(UIKit)
import UIKit

extension TextKit2RowView {
    /// Run background fills as SwiftUI draws them for text without a link
    /// (text with one is drawn by TextKit 1, `drawTextKit1`) — measured
    /// from its bitmaps (xSmall … AX5, with and without sub/superscripts on
    /// the line): per line the run touches, a band from the baseline up by
    /// the line's `bandAscent` and down by its descent — moved by the run's
    /// baseline offset beyond the one the whole line shares (a superscript
    /// highlighted among plain text rises by its raise; a line set wholly
    /// in it does not move) — top and bottom edges unsnapped
    /// (antialiased: the partial pixel rows carry the fill's coverage), the
    /// leading between lines unpainted; horizontally from the run's first
    /// caret to its last, trailing whitespace included (and the hyphen
    /// ending a hyphenated line) — a band over part
    /// of a line with its side edges on the row's pixel grid, both moved
    /// down (`pixelColumns`), a band over a whole line with the line's own
    /// fractional edges (antialiased; measured at 3x and 2x on code,
    /// highlight, sub/superscript and centred bands);
    /// clipped to the row's bounds; each line's bands painted just before
    /// its glyphs, so over the glyphs of the lines above. Coordinates here
    /// already carry the first-baseline snap.
    struct RunBackgrounds {
        let row: TextKit2RowView
        let result: TextKit2LayoutResult
        let fills: [(range: NSRange, color: UIColor, offset: CGFloat)]
        let scale: CGFloat
        // The context is translated by `drawnShift` and the first-baseline
        // snap; the row's edges in these coordinates.
        let clipRight: CGFloat
        let clipTop: CGFloat
        let clipBottom: CGFloat

        /// Nil when the text has no run background.
        @MainActor
        init?(_ row: TextKit2RowView, scale: CGFloat) {
            var fills: [(range: NSRange, color: UIColor, offset: CGFloat)] = []
            let attributed = row.attributed
            attributed.enumerateAttribute(.adfRunBackground, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
                guard let color = value as? UIColor else { return }
                attributed.enumerateAttribute(.baselineOffset, in: range) { offset, run, _ in
                    fills.append((run, color, (offset as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0))
                }
            }
            guard !fills.isEmpty, let result = row.drawn, let first = result.lines.first else { return nil }
            let shift = TextKit2RowView.pixelRound(first.baseline, scale: scale) - first.baseline
            self.row = row
            self.result = result
            self.fills = fills
            self.scale = scale
            clipRight = row.bounds.width - row.drawnShift
            clipTop = -shift
            clipBottom = result.size.height - shift
        }

        /// The bands on line `index`.
        @MainActor
        func draw(line index: Int, in context: CGContext) {
            guard index < result.lines.count else { return }
            let line = result.lines[index]
            for fill in fills {
                let overlap = NSIntersectionRange(fill.range, line.range)
                guard overlap.length > 0 else { continue }
                let raise = fill.offset - line.sharedOffset
                let top = max(line.baseline - line.bandAscent - raise, clipTop)
                let bottom = min(line.baseline + line.descent - raise, clipBottom)
                guard bottom > top else { continue }
                // A band over the whole line keeps its edges where the line's
                // are; one over part of it gets hard side edges.
                let wholeLine = overlap.location == line.range.location && NSMaxRange(overlap) == NSMaxRange(line.range)
                // The overlap lies on this line, so its segments do too.
                var rects = row.containerSegmentRects(for: overlap)
                // A hyphenated line ends in the hyphen TextKit inserts after
                // its last character, past the run's last caret; `Text`
                // paints the band over it too, to the line's end (measured:
                // "high-lighted" highlighted at AX5 in a 201 pt column).
                if NSMaxRange(overlap) == NSMaxRange(line.range), endsHyphenated(line: index),
                   let last = rects.indices.max(by: { rects[$0].maxX < rects[$1].maxX }), line.frame.maxX > rects[last].maxX {
                    rects[last].size.width = line.frame.maxX - rects[last].minX
                }
                for rect in rects {
                    let right = min(rect.maxX, clipRight)
                    guard right > rect.minX else { continue }
                    let band = CGRect(x: rect.minX, y: top, width: right - rect.minX, height: bottom - top)
                    context.setFillColor(fill.color.cgColor)
                    context.fill(wholeLine ? band : row.pixelColumns(band, scale: scale))
                }
            }
        }

        /// Whether line `index` breaks inside a word, after a letter (TextKit
        /// hyphenates there, `Text`'s own hyphenation), rather than at a space,
        /// a break or the text's end.
        @MainActor
        private func endsHyphenated(line index: Int) -> Bool {
            guard index < result.lines.count - 1 else { return false }
            let end = NSMaxRange(result.lines[index].range)
            let string = row.attributed.string as NSString
            guard end > 0, end <= string.length, let scalar = Unicode.Scalar(string.character(at: end - 1)) else { return false }
            return CharacterSet.letters.contains(scalar)
        }
    }

    /// `rect` (container coordinates) with its left and right edges moved
    /// down onto the row's pixel grid — whole pixels from the row's own
    /// origin, as `Text` places its run backgrounds' side edges in its
    /// frame (measured: a span from 391.3 to 601.5 px fills columns
    /// 391…600 hard-edged; in a centred frame at a fractional pixel the
    /// same edges come out antialiased by that fraction). Top and bottom
    /// stay where they are.
    private func pixelColumns(_ rect: CGRect, scale: CGFloat) -> CGRect {
        // A geometric snap threshold of 0.001 px, not a test tolerance: an
        // edge that is on a pixel boundary can come out a hair below it in
        // floating point (a centred row's right edge, 1101.9999 px), and
        // flooring would move it a whole pixel left.
        let left = ((rect.minX + drawnShift) * scale + 0.001).rounded(.down) / scale - drawnShift
        let right = ((rect.maxX + drawnShift) * scale + 0.001).rounded(.down) / scale - drawnShift
        guard right > left else { return .null }
        return CGRect(x: left, y: rect.minY, width: right - left, height: rect.height)
    }
}
#endif
