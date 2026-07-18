import Foundation
import ADFPreparation

/// The platform-agnostic ground truth for the TextKit 2 selection engine
/// (spec §7/§5): the search corpus's per-unit `plainText` joined into one
/// virtual document with `"\n"` joiners between units, prefix-summed in
/// **UTF-16** (the tokenizer's global currency — `UITextInput` arithmetic in
/// Task 19 routes through it) with `Character` conversions kept at the
/// corpus boundary only.
///
/// This ports `SelectionPrototype/SelectionPrototypeText.swift`'s
/// `PrototypeDocumentText` (Character currency, `"\n"`-joined, `unitStarts`
/// prefix sums) to UTF-16 currency and adds the atom-atomicity boundary the
/// prototype never enforced: `snapAcrossAtoms` keeps a caret from landing
/// inside an atom's `fallbackText` span, and `partSlices` always reports an
/// atom's *whole* contribution on any overlap (a partial hit selects the
/// whole pill).
///
/// A plain value type — `Sendable` because every stored member is
/// (`String`, `Int`, `Range<Int>`, `[String: Int]`), so it crosses actor
/// boundaries (built off the main actor, consumed by `@MainActor` UIKit
/// selection code) without ceremony.
public struct SelectionTextModel: Sendable {
    public struct Unit: Sendable {
        public let ownerID: String
        public let topLevelBlockID: String
        public let expandAncestorIDs: [String]
        public let plainText: String
        public let parts: [SearchTextUnit.Part]
        public let utf16Length: Int
    }

    /// One part's contribution, sliced back to a live row's geometry query:
    /// which unit, which part (text segment index or atom id), and the
    /// Character sub-range *within that part's own contribution* (0-based,
    /// not an offset into the unit's full `plainText`).
    public struct PartSlice: Sendable {
        public enum Source: Sendable, Equatable {
            case textSegment(index: Int)
            case atom(id: String)
        }
        public let unit: Int
        public let source: Source
        public let localCharRange: Range<Int>
    }

    public let units: [Unit]
    /// Prefix sums INCLUDING the `"\n"` joiner before each unit>0 — i.e. the
    /// global UTF-16 offset each unit's own `plainText` starts at.
    public let unitUTF16Starts: [Int]
    public let totalUTF16Length: Int
    /// `ownerID` → document-order index, in build (== document) order — the
    /// real implementation of `RowGeometryRegistry.orderOf` (Task 17's stub).
    public let ownerOrder: [String: Int]

    /// Sorted, non-overlapping global UTF-16 ranges of every atom part
    /// across all units — the atomicity boundary `snapAcrossAtoms`
    /// binary-searches.
    private let atomRangesGlobal: [Range<Int>]
    /// Per unit, per part (same order as `Unit.parts`): that part's global
    /// UTF-16 range — the geometry `partSlices` intersects against.
    private let unitPartGlobalRanges: [[Range<Int>]]

    private init(
        units: [Unit],
        unitUTF16Starts: [Int],
        totalUTF16Length: Int,
        ownerOrder: [String: Int],
        atomRangesGlobal: [Range<Int>],
        unitPartGlobalRanges: [[Range<Int>]]
    ) {
        self.units = units
        self.unitUTF16Starts = unitUTF16Starts
        self.totalUTF16Length = totalUTF16Length
        self.ownerOrder = ownerOrder
        self.atomRangesGlobal = atomRangesGlobal
        self.unitPartGlobalRanges = unitPartGlobalRanges
    }

    // MARK: - Build

    /// Walks `orderedItems` → `units` in document order, dropping nothing
    /// (the corpus already dropped whitespace-only units). Inserts one
    /// `"\n"` (1 UTF-16 unit) between consecutive units — matching the
    /// prototype's join and the Copy contract — and precomputes the
    /// atom/part UTF-16 ranges every query method needs.
    public static func build(orderedItems: [SearchIndexedItem]) -> SelectionTextModel {
        var units: [Unit] = []
        var unitUTF16Starts: [Int] = []
        var ownerOrder: [String: Int] = [:]
        var atomRangesGlobal: [Range<Int>] = []
        var unitPartGlobalRanges: [[Range<Int>]] = []

        var cursor = 0
        for item in orderedItems {
            for searchUnit in item.units {
                if !units.isEmpty {
                    cursor += 1 // "\n" joiner before this unit
                }
                let unitStart = cursor
                unitUTF16Starts.append(unitStart)
                ownerOrder[searchUnit.ownerID] = units.count

                var partRanges: [Range<Int>] = []
                partRanges.reserveCapacity(searchUnit.parts.count)
                for part in searchUnit.parts {
                    let localUTF16 = utf16Range(charRange: part.range, in: searchUnit.plainText)
                    let globalRange = (unitStart + localUTF16.lowerBound)..<(unitStart + localUTF16.upperBound)
                    partRanges.append(globalRange)
                    if case .atom = part.source {
                        atomRangesGlobal.append(globalRange)
                    }
                }
                unitPartGlobalRanges.append(partRanges)

                let utf16Length = searchUnit.plainText.utf16.count
                units.append(Unit(
                    ownerID: searchUnit.ownerID,
                    topLevelBlockID: searchUnit.topLevelBlockID,
                    expandAncestorIDs: searchUnit.expandAncestorIDs,
                    plainText: searchUnit.plainText,
                    parts: searchUnit.parts,
                    utf16Length: utf16Length
                ))
                cursor += utf16Length
            }
        }

        atomRangesGlobal.sort { $0.lowerBound < $1.lowerBound }

        return SelectionTextModel(
            units: units,
            unitUTF16Starts: unitUTF16Starts,
            totalUTF16Length: cursor,
            ownerOrder: ownerOrder,
            atomRangesGlobal: atomRangesGlobal,
            unitPartGlobalRanges: unitPartGlobalRanges
        )
    }

    // MARK: - Offset arithmetic

    /// Maps a global UTF-16 offset to `(unit, local)`, clamping into
    /// `[0, totalUTF16Length]`. An offset landing on the `"\n"` joiner
    /// between two units resolves to the END of the preceding unit (matches
    /// `PrototypeDocumentText.location(of:)`).
    public func locate(utf16 offset: Int) -> (unit: Int, local: Int)? {
        guard !units.isEmpty else { return nil }
        let clamped = max(0, min(offset, totalUTF16Length))
        var lo = 0, hi = units.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if unitUTF16Starts[mid] <= clamped { lo = mid } else { hi = mid - 1 }
        }
        let local = min(clamped - unitUTF16Starts[lo], units[lo].utf16Length)
        return (lo, local)
    }

    public func globalOffset(unit: Int, localUTF16: Int) -> Int {
        unitUTF16Starts[unit] + localUTF16
    }

    // MARK: - Grapheme snapping (Task 19 — offset ingestion guard)

    /// Snaps a global UTF-16 offset to the nearest GRAPHEME (composed
    /// character) boundary within its unit. Every gesture-derived offset
    /// (`closestPosition`, the long-press seed, handle drags) is passed through
    /// this before it enters the selection model, so a UTF-16 offset that would
    /// otherwise split a surrogate pair (`"a😄"`) or a combining sequence never
    /// reaches `NSString.substring` (the corpus has no guard of its own — Task
    /// 18 review #1). Offsets already on a boundary — including `0`, each unit's
    /// end, and the `"\n"` joiners between units — pass through unchanged.
    public func snapToGraphemeBoundary(_ utf16Offset: Int) -> Int {
        let clamped = max(0, min(utf16Offset, totalUTF16Length))
        guard let (unit, local) = locate(utf16: clamped) else { return clamped }
        let plain = units[unit].plainText as NSString
        // `0` and the unit's end (a `"\n"` joiner or the document end) are
        // always boundaries; `locate` clamps `local` into `[0, utf16Length]`.
        guard local > 0, local < plain.length else { return clamped }
        let sequence = plain.rangeOfComposedCharacterSequence(at: local)
        if sequence.location == local { return clamped } // already on a boundary
        let lowerGlobal = unitUTF16Starts[unit] + sequence.location
        let upperGlobal = unitUTF16Starts[unit] + sequence.location + sequence.length
        return (clamped - lowerGlobal) <= (upperGlobal - clamped) ? lowerGlobal : upperGlobal
    }

    // MARK: - Caret anchoring (global offset ↔ live-row part+char)

    /// Which part of which unit a global UTF-16 caret offset falls in, and the
    /// `Character` offset within that part — the bridge the geometry layer maps
    /// to a live row's own attributed-string UTF-16 (where an atom is ONE
    /// U+FFFC attachment char, not its multi-character `fallbackText`). `.atom`
    /// anchors report `localCharOffset == 0` at the pill's leading edge and its
    /// whole `Character` count at the trailing edge.
    public struct CaretAnchor: Sendable, Equatable {
        public let unit: Int
        public let source: SearchTextUnit.Part.Source
        public let localCharOffset: Int
    }

    public func caretAnchor(forUTF16 offset: Int) -> CaretAnchor? {
        let clamped = max(0, min(offset, totalUTF16Length))
        guard let (unit, _) = locate(utf16: clamped) else { return nil }
        let global = clamped
        let parts = units[unit].parts
        let ranges = unitPartGlobalRanges[unit]
        guard !parts.isEmpty else { return nil }
        for (index, partRange) in ranges.enumerated() {
            let isLast = index == parts.count - 1
            guard global < partRange.upperBound || isLast else { continue }
            let localUTF16 = max(0, min(global - partRange.lowerBound,
                                        partRange.upperBound - partRange.lowerBound))
            let part = parts[index]
            let charOffset: Int
            switch part.source {
            case .atom:
                charOffset = localUTF16 == 0 ? 0 : (part.range.upperBound - part.range.lowerBound)
            case .textSegment:
                let partText = Self.substring(of: units[unit].plainText, charRange: part.range)
                charOffset = Self.characterOffset(forUTF16Offset: localUTF16, in: partText)
            }
            return CaretAnchor(unit: unit, source: part.source, localCharOffset: charOffset)
        }
        return CaretAnchor(unit: unit, source: parts[0].source, localCharOffset: 0)
    }

    /// Inverse of `caretAnchor`: a `(unit, part, Character offset)` back to a
    /// global UTF-16 offset. `closestPosition` uses it to lift a live row's own
    /// UTF-16 hit (resolved back through the row's segments into a corpus part +
    /// char) into the virtual document's global offset space. `.atom` parts
    /// resolve wholesale — `charOffset <= 0` to the pill's leading edge, any
    /// larger value to its trailing edge (atomicity).
    public func globalOffset(unit: Int, partSource: SearchTextUnit.Part.Source, charOffset: Int) -> Int? {
        guard units.indices.contains(unit) else { return nil }
        let parts = units[unit].parts
        guard let index = parts.firstIndex(where: { $0.source == partSource }) else { return nil }
        let part = parts[index]
        let partRange = unitPartGlobalRanges[unit][index]
        if case .atom = part.source {
            return charOffset <= 0 ? partRange.lowerBound : partRange.upperBound
        }
        let corpusChar = max(part.range.lowerBound,
                             min(part.range.lowerBound + charOffset, part.range.upperBound))
        let localUTF16 = Self.utf16Range(charRange: 0..<corpusChar, in: units[unit].plainText).upperBound
        return unitUTF16Starts[unit] + localUTF16
    }

    // MARK: - Copy

    /// The visible-unit substring of the requested global UTF-16 range, with
    /// visible-unit contributions joined by `"\n"`. Hidden units (a closed
    /// expand ancestor) contribute nothing — their offset space is still
    /// walked (so surrounding units line up) but no text is appended for
    /// them, and no extra joiner appears where they were skipped (spec §7
    /// expand edges).
    public func text(inUTF16 range: Range<Int>, isVisible: (Unit) -> Bool) -> String {
        let lower = max(0, min(range.lowerBound, totalUTF16Length))
        let upper = max(0, min(range.upperBound, totalUTF16Length))
        guard lower < upper else { return "" }

        var pieces: [String] = []
        for (index, unit) in units.enumerated() {
            let unitStart = unitUTF16Starts[index]
            let unitEnd = unitStart + unit.utf16Length
            guard lower < unitEnd, upper > unitStart else { continue }
            guard isVisible(unit) else { continue }
            let clippedLower = max(lower, unitStart) - unitStart
            let clippedUpper = min(upper, unitEnd) - unitStart
            guard clippedLower < clippedUpper else { continue }
            pieces.append(Self.utf16Substring(of: unit.plainText, utf16Range: clippedLower..<clippedUpper))
        }
        return pieces.joined(separator: "\n")
    }

    // MARK: - Atom atomicity

    /// If `offset` lands strictly inside an atom's UTF-16 span, snaps it to
    /// that atom's forward edge (`forward: true`) or back edge
    /// (`forward: false`) — the only edge reachable walking in that
    /// direction from an interior point. Offsets outside every atom (or
    /// exactly on an edge) pass through unchanged.
    public func snapAcrossAtoms(_ offset: Int, forward: Bool) -> Int {
        let clamped = max(0, min(offset, totalUTF16Length))
        guard !atomRangesGlobal.isEmpty else { return clamped }

        // Binary search for the last atom range whose lowerBound <= clamped.
        var lo = 0, hi = atomRangesGlobal.count - 1
        var candidate = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if atomRangesGlobal[mid].lowerBound <= clamped {
                candidate = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        guard candidate >= 0 else { return clamped }
        let range = atomRangesGlobal[candidate]
        guard range.lowerBound < clamped, clamped < range.upperBound else { return clamped }
        return forward ? range.upperBound : range.lowerBound
    }

    // MARK: - Geometry slicing

    /// For each visible unit overlapping `range`, the parts whose global
    /// UTF-16 span intersects it — atoms always report their *whole*
    /// Character contribution (atomicity: a partial hit selects the whole
    /// pill), text segments report the intersected Character sub-range.
    public func partSlices(forUTF16 range: Range<Int>, isVisible: (Unit) -> Bool) -> [PartSlice] {
        let lower = max(0, min(range.lowerBound, totalUTF16Length))
        let upper = max(0, min(range.upperBound, totalUTF16Length))
        guard lower < upper else { return [] }

        var result: [PartSlice] = []
        for (unitIndex, unit) in units.enumerated() {
            let unitStart = unitUTF16Starts[unitIndex]
            let unitEnd = unitStart + unit.utf16Length
            guard lower < unitEnd, upper > unitStart else { continue }
            guard isVisible(unit) else { continue }

            for (partIndex, part) in unit.parts.enumerated() {
                let partGlobalRange = unitPartGlobalRanges[unitIndex][partIndex]
                guard partGlobalRange.lowerBound < upper, partGlobalRange.upperBound > lower else { continue }

                switch part.source {
                case .atom(let id):
                    let charCount = part.range.upperBound - part.range.lowerBound
                    result.append(PartSlice(unit: unitIndex, source: .atom(id: id), localCharRange: 0..<charCount))
                case .textSegment(let index):
                    let intersectLower = max(partGlobalRange.lowerBound, lower)
                    let intersectUpper = min(partGlobalRange.upperBound, upper)
                    guard intersectLower < intersectUpper else { continue }
                    let partLocalUTF16Lower = intersectLower - partGlobalRange.lowerBound
                    let partLocalUTF16Upper = intersectUpper - partGlobalRange.lowerBound
                    let partText = Self.substring(of: unit.plainText, charRange: part.range)
                    let charLower = Self.characterOffset(forUTF16Offset: partLocalUTF16Lower, in: partText)
                    let charUpper = Self.characterOffset(forUTF16Offset: partLocalUTF16Upper, in: partText)
                    result.append(PartSlice(unit: unitIndex, source: .textSegment(index: index), localCharRange: charLower..<charUpper))
                }
            }
        }
        return result
    }

    // MARK: - Character ↔ UTF-16 conversion (corpus boundary only)

    /// Maps a `Character` range within `text` to the equivalent UTF-16
    /// range within it, by walking `text` by `Character` and summing
    /// UTF-16 counts — the same technique as
    /// `TextRowContent.utf16Range(charRange:inSegment:of:)`.
    private static func utf16Range(charRange: Range<Int>, in text: String) -> Range<Int> {
        var precedingUTF16 = 0
        var rangeUTF16 = 0
        for (charIndex, character) in text.enumerated() {
            if charIndex < charRange.lowerBound {
                precedingUTF16 += character.utf16.count
            } else if charIndex < charRange.upperBound {
                rangeUTF16 += character.utf16.count
            } else {
                break
            }
        }
        return precedingUTF16..<(precedingUTF16 + rangeUTF16)
    }

    /// Inverse walk: the `Character` offset within `text` at which
    /// `utf16Offset` UTF-16 units have been consumed.
    private static func characterOffset(forUTF16Offset utf16Offset: Int, in text: String) -> Int {
        var utf16Count = 0
        var charCount = 0
        for character in text {
            if utf16Count >= utf16Offset { break }
            utf16Count += character.utf16.count
            charCount += 1
        }
        return charCount
    }

    private static func substring(of text: String, charRange: Range<Int>) -> String {
        guard
            let lower = text.index(text.startIndex, offsetBy: charRange.lowerBound, limitedBy: text.endIndex),
            let upper = text.index(text.startIndex, offsetBy: charRange.upperBound, limitedBy: text.endIndex)
        else { return "" }
        return String(text[lower..<upper])
    }

    /// UTF-16 sub-range slice of `text`, via an `NSString` bridge (exact
    /// under surrogate pairs, unlike `String.Index(utf16Offset:in:)` walked
    /// by hand).
    private static func utf16Substring(of text: String, utf16Range: Range<Int>) -> String {
        let ns = text as NSString
        let lower = max(0, min(utf16Range.lowerBound, ns.length))
        let upper = max(lower, min(utf16Range.upperBound, ns.length))
        return ns.substring(with: NSRange(location: lower, length: upper - lower))
    }
}
