import SwiftUI
@_spi(ADFDiagnostics) import ADFRendering

/// The `-smartLinkProbe` overlay (UI tests only): every counter the
/// smart-link UI test compares, read in one poll and shown as one line
///
///     calls=<n> cancelled=<n> inFlight=<n> resolved=<n> failed=<n>
///     refreshes=<n> owners=<n> mockCalls=<n> mockCancelled=<n>
///     mockInFlight=<n> leaves=<n> segmented=<n> engine=<n>
///     conversions=<n> layouts=<n> live=<n> res=<mode> scrolling=<0|1>
///     scrollEnds=<n> scrollCalls=<n> deferred=<n> waiting=<n>
///     pfBatches=<n> pfCalls=<n> pfInFlight=<n> pfCancelled=<n> pfHits=<n>
///     pfMaxBatch=<n> pfPeak=<n> pfFar=<n> B=<n> D=<n> held=<n> holds=<n>
///     dims=<n>
///
/// under the accessibility identifier `smartlink-probe`: the document's
/// smart-link counters (`ADFDocumentModel.smartLinkStats`, refreshed owners),
/// the mock resolver's, the text-leaf body evaluations since launch
/// (`ADFTextRenderer.textLeafStats`: total, SwiftUI `Text`, engine leaf) and
/// the TextKit 2 conversions, layouts and live rows, then the resolution
/// mode (`res=`, the `ADFSmartLinkResolution` raw value) and its scroll and
/// nearby counters, with the nearby limits (`B=` keys per batch, `D=`
/// positions), then design §10's: titles held now (`held=`, zero at rest),
/// titles held since launch (`holds=`) and loading looks shown (`dims=`).
/// One element read in one
/// query, so a test gets a consistent snapshot in well under a second
/// without opening About This Build (whose rows are read one at a time). It
/// polls every 250 ms in its own task and keeps the line in its own state,
/// never in the document's: like `ScenePhaseProbe` it touches no document
/// view, and the test's quiet-window reads show it re-evaluates no leaf.
/// Absent without the flag.
struct SmartLinkProbe: View {
    let model: ADFDocumentModel
    @State private var line = "…"

    var body: some View {
        Text(verbatim: line)
            .font(.system(size: 7).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(2)
            .allowsHitTesting(false)
            .accessibilityIdentifier("smartlink-probe")
            .task {
                while !Task.isCancelled {
                    line = Self.read(model)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
    }

    static func read(_ model: ADFDocumentModel) -> String {
        let stats = model.smartLinkStats
        let mock = MockSmartLinkResolver.shared?.snapshot
        let leaves = ADFTextRenderer.textLeafStats
        let textKit2 = ADFTextRenderer.textKit2Stats
        let fields: [(String, Int)] = [
            ("calls", stats.resolverCalls), ("cancelled", stats.cancellations), ("inFlight", stats.inFlight),
            ("resolved", stats.resolved), ("failed", stats.failed), ("refreshes", stats.leafRefreshes),
            ("owners", model.smartLinkLeafRefreshesByOwner.count),
            ("mockCalls", mock?.calls ?? -1), ("mockCancelled", mock?.cancelled ?? -1),
            ("mockInFlight", mock?.inFlight ?? -1),
            ("leaves", leaves.total), ("segmented", leaves.segmentedTextBodies), ("engine", leaves.engineLeafBodies),
            ("conversions", textKit2.conversionCount), ("layouts", textKit2.layoutCount), ("live", textKit2.liveRowCount),
        ]
        let modeFields: [(String, Int)] = [
            ("scrolling", stats.isScrolling ? 1 : 0), ("scrollEnds", stats.scrollEnds),
            ("scrollCalls", stats.scrollingCalls), ("deferred", stats.deferred), ("waiting", stats.waiting),
            ("pfBatches", stats.prefetchBatches), ("pfCalls", stats.prefetchCalls),
            ("pfInFlight", stats.prefetchInFlight), ("pfCancelled", stats.prefetchCancellations),
            ("pfHits", stats.prefetchHits), ("pfMaxBatch", stats.largestPrefetchBatch),
            ("pfPeak", stats.peakPrefetchInFlight), ("pfFar", stats.farthestPrefetch),
            ("B", model.smartLinkNearbyLimits.batch), ("D", model.smartLinkNearbyLimits.distance),
            ("held", stats.titlesHeldNow), ("holds", stats.titlesHeld), ("dims", stats.resolvingShown),
        ]
        return (fields.map { "\($0.0)=\($0.1)" } + ["res=\(stats.resolution.rawValue)"]
            + modeFields.map { "\($0.0)=\($0.1)" }).joined(separator: " ")
    }
}
