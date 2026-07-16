import Observation
import ADFPreparation

/// Stable observable state for one rendered text owner. Leaves retain this
/// reference across query and document updates, so publishing a delta only
/// invalidates owners whose paint payload actually changed.
@Observable @MainActor
final class SearchOwnerHighlights {
    private(set) var spans: [SearchHighlightSpan] = []
    private(set) var atomIDs: Set<String> = []
    private(set) var currentSpans: [SearchHighlightSpan] = []
    private(set) var currentAtomIDs: Set<String> = []
    private(set) var currentGeneration: Int?

    func setBase(spans: [SearchHighlightSpan], atomIDs: Set<String>) {
        self.spans = spans
        self.atomIDs = atomIDs
    }

    func setCurrent(
        spans: [SearchHighlightSpan],
        atomIDs: Set<String>,
        generation: Int
    ) {
        currentSpans = spans
        currentAtomIDs = atomIDs
        currentGeneration = generation
    }

    func clearCurrent() {
        guard currentGeneration != nil else { return }
        currentSpans = []
        currentAtomIDs = []
        currentGeneration = nil
    }

    func clear() {
        spans = []
        atomIDs = []
        clearCurrent()
    }
}
