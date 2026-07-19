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
/// before any query (spec §7). Stamped from `ADFDocumentModel.documentEpoch`
/// (Task 22) — bumps on any non-tail-append index change (`load`, and
/// `apply(_:revision:)` replacements/removals/moves).
@MainActor
public final class SelectionState {
    public var utf16Range: Range<Int>?
    public var epoch: UInt64 = 0
    public init() {}

    /// The pure epoch-guard/clamp core (Task 22): epoch mismatch → `nil` (the
    /// range belongs to a document generation that no longer exists); same
    /// epoch → clamp `range` into `[0, documentUTF16Length]`, returning `nil`
    /// if clamping collapses it to empty. Platform-agnostic (no UIKit), so
    /// it's `swift test`-able on macOS without the iOS-only
    /// `SelectionController`; the iOS overlay's `currentRange` and the
    /// controller's `documentDidChange()` both route through this one
    /// function instead of duplicating the clamp logic.
    public static func clampedRange(
        _ range: Range<Int>?,
        stampEpoch: UInt64,
        currentEpoch: UInt64,
        documentUTF16Length: Int
    ) -> Range<Int>? {
        guard let range, stampEpoch == currentEpoch else { return nil }
        let lower = max(0, min(range.lowerBound, documentUTF16Length))
        let upper = max(lower, min(range.upperBound, documentUTF16Length))
        return lower < upper ? lower..<upper : nil
    }
}
