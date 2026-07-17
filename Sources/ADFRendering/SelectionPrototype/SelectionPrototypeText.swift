// PROTOTYPE — THROWAWAY CODE. Not production. Delete or absorb after verdict.
//
// Question this prototype answers: can a custom UITextInput container +
// UITextInteraction deliver native continuous text selection (start/end grab
// handles, system highlight, edit menu) ACROSS blocks rendered as separate
// SwiftUI Text views, reusing the search index as the selection's text model?
//
// This file: the linear document text model. Joins the search index's
// per-unit plain text into one virtual document string with "\n" joiners,
// with Character-offset prefix sums for global ↔ (unit, local) conversion.

#if os(iOS)
import Foundation
import ADFPreparation

/// Document-order linear text model over `SearchTextUnit`s. All offsets are
/// Character offsets (same unit as the search index).
struct PrototypeDocumentText {
    let units: [SearchTextUnit]
    /// Global Character offset of each unit's plainText start.
    let unitStarts: [Int]
    /// Full virtual document string: unit plainTexts joined by "\n".
    let virtualText: String
    /// Total length in Characters.
    let length: Int

    init(units: [SearchTextUnit]) {
        self.units = units
        var starts: [Int] = []
        starts.reserveCapacity(units.count)
        var cursor = 0
        var joined = ""
        for (index, unit) in units.enumerated() {
            if index > 0 {
                joined.append("\n")
                cursor += 1
            }
            starts.append(cursor)
            joined.append(unit.plainText)
            cursor += unit.plainText.count
        }
        self.unitStarts = starts
        self.virtualText = joined
        self.length = cursor
    }

    /// Maps a global offset to (unitIndex, localOffset). Offsets landing on a
    /// joiner "\n" resolve to the END of the preceding unit.
    func location(of globalOffset: Int) -> (unit: Int, local: Int)? {
        guard !units.isEmpty else { return nil }
        let clamped = min(max(globalOffset, 0), length)
        // Binary search for the last unit whose start <= offset.
        var low = 0, high = units.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if unitStarts[mid] <= clamped { low = mid } else { high = mid - 1 }
        }
        let local = min(clamped - unitStarts[low], units[low].plainText.count)
        return (low, local)
    }

    func globalOffset(unit: Int, local: Int) -> Int {
        unitStarts[unit] + local
    }

    /// Substring of the virtual text for a global Character range.
    func text(in range: Range<Int>) -> String {
        let lower = min(max(range.lowerBound, 0), length)
        let upper = min(max(range.upperBound, 0), length)
        guard lower < upper else { return "" }
        let start = virtualText.index(virtualText.startIndex, offsetBy: lower)
        let end = virtualText.index(start, offsetBy: upper - lower)
        return String(virtualText[start..<end])
    }

    /// Per-unit local ranges covered by a global range, in document order.
    func unitRanges(in range: Range<Int>) -> [(unit: Int, range: Range<Int>)] {
        guard let startLoc = location(of: range.lowerBound),
              let endLoc = location(of: range.upperBound),
              range.lowerBound < range.upperBound else { return [] }
        var result: [(unit: Int, range: Range<Int>)] = []
        for unit in startLoc.unit...endLoc.unit {
            let textCount = units[unit].plainText.count
            let lower = unit == startLoc.unit ? startLoc.local : 0
            let upper = unit == endLoc.unit ? endLoc.local : textCount
            if lower < upper {
                result.append((unit, lower..<upper))
            }
        }
        return result
    }
}
#endif
