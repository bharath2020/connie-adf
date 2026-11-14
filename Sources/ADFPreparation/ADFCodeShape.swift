import Foundation

/// The shape of one code block's text, measured once when the block is
/// prepared and stamped over the whole (non-empty) code string as the
/// `adfCodeShape` attribute, next to its font spec.
///
/// A text engine other than SwiftUI's `Text` decides from it, in constant
/// time, whether it may draw the block and how large its drawing surface
/// can get: a view body evaluates that decision on every pass, so it must
/// never scan the code (views never compute). SwiftUI ignores the
/// attribute, and the string's characters are never changed for it: no tab
/// expansion, no line-break normalisation.
///
/// **Lines** are split at LF (U+000A) only, the one line break an engine is
/// admitted for. Every other scalar, a CR or a Unicode line separator
/// included, counts as a UTF-16 unit of the line it sits on.
///
/// **Newlines**, for `trailingNewlineCount` and `isAllNewlines`, are counted
/// as `Character.isNewline` counts them, so the two facts answer exactly
/// what a scan of the characters would: LF, CR, CRLF (one character), VT,
/// FF, NEL (U+0085), U+2028 and U+2029.
///
/// An empty string has no run to carry an attribute, so it has no shape;
/// a reader treats a missing shape on non-empty code as unknown (and keeps
/// the block on SwiftUI) rather than scanning for one.
package struct ADFCodeShape: Sendable, Hashable {
    /// Number of lines: the LF count plus one, so a trailing LF opens a
    /// last, empty line.
    package var lineCount: Int
    /// UTF-16 length of the longest line, its LF excluded.
    package var maxLineUTF16: Int
    /// How many newline characters end the text (`Character.isNewline`).
    package var trailingNewlineCount: Int
    /// Whether the text is non-empty and holds newline characters only.
    package var isAllNewlines: Bool
    /// Whether every scalar is printable ASCII (U+0020 to U+007E) or LF.
    package var isPrintableASCIIAndLF: Bool
    /// Whether the text has a horizontal tab (U+0009).
    package var hasTabs: Bool
    /// Whether the text has a scalar above U+007F.
    package var hasNonASCII: Bool
    /// Whether the text has a line break other than LF: CR (so CRLF too),
    /// VT, FF, NEL, U+2028 or U+2029.
    package var hasOtherLineBreaks: Bool

    package init(
        lineCount: Int,
        maxLineUTF16: Int,
        trailingNewlineCount: Int = 0,
        isAllNewlines: Bool = false,
        isPrintableASCIIAndLF: Bool = true,
        hasTabs: Bool = false,
        hasNonASCII: Bool = false,
        hasOtherLineBreaks: Bool = false
    ) {
        self.lineCount = lineCount
        self.maxLineUTF16 = maxLineUTF16
        self.trailingNewlineCount = trailingNewlineCount
        self.isAllNewlines = isAllNewlines
        self.isPrintableASCIIAndLF = isPrintableASCIIAndLF
        self.hasTabs = hasTabs
        self.hasNonASCII = hasNonASCII
        self.hasOtherLineBreaks = hasOtherLineBreaks
    }

    /// Measures `text` in one pass over its Unicode scalars.
    package init(_ text: String) {
        var lineCount = 1
        var line = 0
        var longest = 0
        var trailing = 0
        var allNewlines = true
        var printable = true
        var tabs = false
        var nonASCII = false
        var otherBreaks = false
        var afterCarriageReturn = false
        var isEmpty = true

        for scalar in text.unicodeScalars {
            isEmpty = false
            let value = scalar.value
            var isNewline = false
            switch value {
            case 0x0A:
                lineCount += 1
                if line > longest { longest = line }
                line = 0
                isNewline = true
                // CRLF is one newline character: the CR already counted.
                if !afterCarriageReturn { trailing += 1 }
            case 0x20...0x7E:
                line += 1
            case 0x09:
                tabs = true
                printable = false
                line += 1
            case 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029:
                otherBreaks = true
                printable = false
                if value > 0x7F { nonASCII = true }
                line += 1
                isNewline = true
                trailing += 1
            default:
                printable = false
                if value > 0x7F { nonASCII = true }
                line += value > 0xFFFF ? 2 : 1
            }
            if !isNewline {
                trailing = 0
                allNewlines = false
            }
            afterCarriageReturn = value == 0x0D
        }
        if line > longest { longest = line }

        self.init(
            lineCount: lineCount,
            maxLineUTF16: longest,
            trailingNewlineCount: trailing,
            isAllNewlines: allNewlines && !isEmpty,
            isPrintableASCIIAndLF: printable,
            hasTabs: tabs,
            hasNonASCII: nonASCII,
            hasOtherLineBreaks: otherBreaks
        )
    }
}
