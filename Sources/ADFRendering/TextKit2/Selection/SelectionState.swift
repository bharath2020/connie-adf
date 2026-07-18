import Foundation

/// Selection lives here — a plain non-observed reference box owned by the
/// model (mirrors `ScrollAnchorRegistry`). Per-touch-move writes invalidate
/// nothing: UIKit sets `selectedTextRange` on every handle move, and routing
/// that into an `@Observable` property would re-evaluate every materialized
/// row on each move (the `ScrollAnchorRegistry` doc comment's O(rows) cost).
/// Writing into this reference type is free.
///
/// `epoch` is the document generation stamped when the current range was last
/// set; a mismatch against the model's current generation means the range
/// refers to a document that no longer exists and must be cleared/clamped
/// before any query (spec §7). Task 19 stamps it from
/// `ADFDocumentModel.documentRevision` as a placeholder; Task 22 introduces a
/// dedicated `documentEpoch` (bumping on any non-tail-append index change) and
/// switches the stamp to it.
@MainActor
public final class SelectionState {
    public var utf16Range: Range<Int>?
    public var epoch: UInt64 = 0
    public init() {}
}
