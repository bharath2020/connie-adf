import Foundation
import SwiftUI
import ADFPreparation

/// Everything leaf text views need to paint search highlights, published by
/// `ADFDocumentSearch.highlights`. Changes only when results change or the
/// user navigates — never per keystroke mid-debounce.
public struct ADFSearchHighlights: Equatable, Sendable {
    /// All matches' text spans, keyed by owner ID (rich-text/code block id,
    /// list-row id, media id). Spans use LOCAL Character offsets per segment.
    public internal(set) var spansByOwner: [String: [SearchHighlightSpan]]
    /// Atom pills covered by any match (whole-pill subtle highlight).
    public internal(set) var matchedAtomIDs: Set<String>
    /// The navigated-to match, painted with the accent style + flash.
    public internal(set) var current: Current?

    public struct Current: Equatable, Sendable {
        public internal(set) var ownerID: String
        public internal(set) var spans: [SearchHighlightSpan]
        public internal(set) var atomIDs: Set<String>
        /// Bumped on every navigation; drives the arrival flash.
        public internal(set) var generation: Int
    }

    public static let none = ADFSearchHighlights(
        spansByOwner: [:], matchedAtomIDs: [], current: nil
    )

    public var isActive: Bool {
        !spansByOwner.isEmpty || !matchedAtomIDs.isEmpty || current != nil
    }
}

private struct ADFDocumentSearchKey: EnvironmentKey {
    static let defaultValue: ADFDocumentSearch? = nil
}

extension EnvironmentValues {
    /// The document's search controller, injected by `ADFDocumentView` so
    /// leaf text views can observe `highlights` without the document view
    /// ever re-evaluating (the reference itself never changes).
    public var adfDocumentSearch: ADFDocumentSearch? {
        get { self[ADFDocumentSearchKey.self] }
        set { self[ADFDocumentSearchKey.self] = newValue }
    }
}
