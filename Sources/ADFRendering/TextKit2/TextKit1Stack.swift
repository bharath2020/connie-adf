#if canImport(UIKit)
import UIKit

/// A TextKit 1 stack configured as SwiftUI's string drawing configures it
/// (font leading off, no line fragment padding), with one difference from
/// a default stack that `Text` also has: a fallback font (an emoji's
/// Apple Color Emoji, substituted into the storage by TextKit 1) never
/// grows a line. Measured: TextKit 1 counts the emoji face's taller
/// metrics (+0.0135 pt per emoji line at AX3, one pixel after the frame's
/// ceil, 4 px over `link-emoji-wrap` at AX5); `Text` sizes such lines by
/// the run's own font, as TextKit 2 rows do (`glyphMetrics`).
final class TextKit1Stack: NSObject, NSLayoutManagerDelegate {
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
    /// the text was built with: the line's metrics over the storage's
    /// fonts (after substitution) and over the built ones, the difference
    /// removed from the fragment, its used rect and (above the baseline)
    /// its baseline. On a line without a baseline offset the metrics are
    /// TextKit 1's measured rule (`extent`). With one, TextKit 1's metric
    /// depends on the order of the runs (measured: a line opening with a
    /// subscript is set lower than one ending with it), so both are read
    /// from TextKit 1 itself, setting the line alone (`lineMetrics`); the
    /// emoji's taller face then counts where its subscript run sets the
    /// line's ascent (+0.0046 pt at large: a pixel at 2x). Lines without
    /// a substituted font are left exactly as TextKit 1 set them.
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
        guard range.length > 0, hasSubstitution(in: range) else { return false }
        let paragraph = (storage.string as NSString).paragraphRange(for: range)
        let firstLine = paragraph.location == range.location
        let lastLine = NSMaxRange(paragraph) == NSMaxRange(range)
        let ascent: CGFloat
        let height: CGFloat
        if hasBaselineOffset(in: range) {
            let substituted = Self.lineMetrics(of: storage.attributedSubstring(from: range), firstLine: firstLine, lastLine: lastLine)
            let built = Self.lineMetrics(of: unsubstitutedLine(range), firstLine: firstLine, lastLine: lastLine)
            ascent = max(substituted.baseline - built.baseline, 0)
            height = max(substituted.height - built.height, 0)
        } else {
            let substituted = Self.extent(of: storage, in: range, firstLine: firstLine, lastLine: lastLine)
            let built = Self.extent(of: intended, in: range, firstLine: firstLine, lastLine: lastLine)
            ascent = max(substituted.ascent - built.ascent, 0)
            height = ascent + max(substituted.descent - built.descent, 0)
        }
        guard ascent > 0 || height > 0 else { return false }
        lineFragmentRect.pointee.size.height -= height
        lineFragmentUsedRect.pointee.size.height -= height
        baselineOffset.pointee -= ascent
        return true
    }

    private func hasBaselineOffset(in range: NSRange) -> Bool {
        var found = false
        intended.enumerateAttribute(.baselineOffset, in: range) { value, _, stop in
            if let offset = value as? NSNumber, offset.doubleValue != 0 {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// How TextKit 1 (font leading off) sizes a line without baseline
    /// offsets from the fonts set over `range`, measured from its line
    /// fragments: above the baseline the tallest ascent plus a negative
    /// leading (not on a paragraph's first line), below it the deepest
    /// descent plus a positive leading (not on a paragraph's last line).
    /// So an emoji's Apple Color Emoji (leading 0) takes back the system
    /// font's −1.25 pt leading above a line at AX5, adds its 0.014 pt taller
    /// ascent at AX3, and its 0.0016 pt deeper descent on a last line.
    private static func extent(of string: NSAttributedString, in range: NSRange, firstLine: Bool, lastLine: Bool) -> (ascent: CGFloat, descent: CGFloat) {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        string.enumerateAttribute(.font, in: range) { value, _, _ in
            guard let font = value as? UIFont else { return }
            ascent = max(ascent, font.ascender + (firstLine ? 0 : min(font.leading, 0)))
            descent = max(descent, -font.descender + (lastLine ? 0 : max(font.leading, 0)))
        }
        return (ascent, descent)
    }

    /// Whether TextKit 1 replaced a font the text was built with in `range`.
    private func hasSubstitution(in range: NSRange) -> Bool {
        var found = false
        storage.enumerateAttribute(.font, in: range) { value, run, stop in
            let built = intended.attribute(.font, at: run.location, effectiveRange: nil) as? UIFont
            if (value as? UIFont) != built {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// The line's text as built, its substituted characters (an emoji,
    /// which no built font draws) replaced by as many "x" in the built run's
    /// attributes: the fonts and offsets TextKit 1 would have set the line
    /// in without fallback.
    private func unsubstitutedLine(_ range: NSRange) -> NSAttributedString {
        let line = NSMutableAttributedString(attributedString: intended.attributedSubstring(from: range))
        storage.enumerateAttribute(.font, in: range) { value, run, _ in
            let built = intended.attribute(.font, at: run.location, effectiveRange: nil) as? UIFont
            guard (value as? UIFont) != built else { return }
            let local = NSRange(location: run.location - range.location, length: run.length)
            line.replaceCharacters(in: local, with: String(repeating: "x", count: run.length))
        }
        return line
    }

    /// Baseline and height of `line` set by TextKit 1 as this stack sets
    /// it, on one line (an unbounded container), after a line separator
    /// when it is not a paragraph's first line and before one (and an "x")
    /// when it is not its last. Known gap: TextKit 1 treats
    /// a line after a separator as a first line for negative leading
    /// (AX3+), so on a later line with both an offset and an emoji at such
    /// sizes the difference can miss the leading the emoji takes back — no
    /// sweep root has one (a plain line uses `extent`, which has the rule).
    private static func lineMetrics(of line: NSAttributedString, firstLine: Bool, lastLine: Bool) -> (baseline: CGFloat, height: CGFloat) {
        let text = NSMutableAttributedString(attributedString: line)
        if !lastLine, line.length > 0 {
            let attributes = line.attributes(at: line.length - 1, effectiveRange: nil)
            text.append(NSAttributedString(string: "\u{2028}x", attributes: attributes))
        }
        if !firstLine {
            let attributes = line.length > 0 ? line.attributes(at: 0, effectiveRange: nil) : [:]
            text.insert(NSAttributedString(string: "x\u{2028}", attributes: attributes), at: 0)
        }
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        manager.usesFontLeading = false
        let container = NSTextContainer(size: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        let glyph = manager.glyphIndexForCharacter(at: firstLine ? 0 : 2)
        let rect = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return (manager.location(forGlyphAt: glyph).y, rect.height)
    }
}
#endif
