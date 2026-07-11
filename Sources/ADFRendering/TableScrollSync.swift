import SwiftUI

/// Per-document registry mapping a table's ID to the horizontal content
/// offset its slices share, so the slices of one batched table (§5.1) pan as
/// a single table instead of shearing independently.
///
/// One instance lives per `ADFDocumentView` (held as `@State`, injected via
/// environment), so offsets never leak across documents. Entries are
/// reference-counted by the live slices that adopt them: when the last slice
/// of a table scrolls out of the render region (collapsing to a spacer in
/// `DocumentRow`) the offset is dropped, so a long document's registry can't
/// grow without bound. A slice re-materializing into a still-live table reads
/// the retained offset and lines up with the pinned header.
@MainActor
@Observable
final class TableScrollSync {
    /// Shared horizontal offset per table ID. Observed, so a driver's write
    /// invalidates only the slices reading the same table's offset.
    private var offsets: [String: CGFloat] = [:]

    /// Live-slice count per table ID. Not observed: retain/release churn from
    /// scrolling must never invalidate a view.
    @ObservationIgnored private var liveSlices: [String: Int] = [:]

    func sharedOffset(for tableID: String) -> CGFloat? {
        offsets[tableID]
    }

    /// Records the driving slice's offset. No-ops on sub-half-point moves so
    /// an idle table never churns observation and followers can't echo a
    /// value back to its author.
    func publish(_ offset: CGFloat, for tableID: String) {
        if let current = offsets[tableID], abs(current - offset) <= 0.5 { return }
        offsets[tableID] = offset
    }

    func retain(_ tableID: String) {
        liveSlices[tableID, default: 0] += 1
    }

    func release(_ tableID: String) {
        guard let count = liveSlices[tableID] else { return }
        if count <= 1 {
            liveSlices[tableID] = nil
            offsets[tableID] = nil
        } else {
            liveSlices[tableID] = count - 1
        }
    }
}
