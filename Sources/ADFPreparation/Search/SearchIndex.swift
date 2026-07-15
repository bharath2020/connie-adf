import Foundation

/// One searchable run of text extracted from the prepared block tree, with
/// enough bookkeeping to paint highlights back onto the exact segments the
/// view layer renders and to scroll to the containing lazy-stack row.
public struct SearchTextUnit: Sendable, Hashable {
    /// ID the rendering view knows itself by when looking up highlights:
    /// the rich-text/code block's `RenderBlock.id`, a `PreparedListRow.id`,
    /// or a `PreparedMedia.id` for captions.
    public let ownerID: String
    /// ID of the containing top-level lazy-stack row (`scrollTarget` key).
    /// For nested content (table cells, panel children, expand bodies) this
    /// is the enclosing top-level block/slice, not the owner.
    public let topLevelBlockID: String
    /// Expand blocks (outermost first) that must be open for this unit's
    /// content to be on screen. Empty for content outside expands.
    public let expandAncestorIDs: [String]
    /// Concatenated plain text: `String(text.characters)` for text segments,
    /// `InlineComposer.fallbackText` for atoms, in segment order.
    public let plainText: String
    /// Ordered, gap-free composition map from `plainText` Character offsets
    /// back to segments/atoms.
    public let parts: [Part]

    public struct Part: Sendable, Hashable {
        public enum Source: Sendable, Hashable {
            /// Index into the owner's `[InlineSegment]` (word chunks included:
            /// the index is into the SAME array the view renders).
            case textSegment(index: Int)
            /// Structural node ID of an atom pill.
            case atom(id: String)
        }

        public let source: Source
        /// This part's contribution as Character offsets in `plainText`.
        public let range: Range<Int>

        public init(source: Source, range: Range<Int>) {
            self.source = source
            self.range = range
        }
    }

    public init(
        ownerID: String,
        topLevelBlockID: String,
        expandAncestorIDs: [String],
        plainText: String,
        parts: [Part]
    ) {
        self.ownerID = ownerID
        self.topLevelBlockID = topLevelBlockID
        self.expandAncestorIDs = expandAncestorIDs
        self.plainText = plainText
        self.parts = parts
    }
}

/// One query hit: a Character-offset range in one unit's `plainText`.
/// Document order is (unitIndex, range.lowerBound) ascending.
public struct SearchMatch: Sendable, Hashable {
    public let unitIndex: Int
    public let range: Range<Int>

    public init(unitIndex: Int, range: Range<Int>) {
        self.unitIndex = unitIndex
        self.range = range
    }
}

/// One paintable slice of a match: a Character-offset range inside one
/// segment's `AttributedString`. Produced by `SearchMatcher.spans(for:in:)`,
/// consumed by the rendering layer's highlight painter.
public struct SearchHighlightSpan: Sendable, Hashable {
    public let segmentIndex: Int
    public let range: Range<Int>

    public init(segmentIndex: Int, range: Range<Int>) {
        self.segmentIndex = segmentIndex
        self.range = range
    }
}
