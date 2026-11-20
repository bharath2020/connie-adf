import SwiftUI
@_spi(ADFDiagnostics) import ADFRendering

/// The `-mediaProbe` overlay (UI tests only): every media counter
/// `MediaUITests` compares, read in one poll and shown as one line
///
///     started=<n> finished=<n> cancelled=<n> failed=<n> released=<n>
///     maxRunning=<n> running=<n> mockCalls=<n> mockCancelled=<n>
///     mockInFlight=<n> mockFetched=<n> mockFailed=<n>
///
/// under the accessibility identifier `media-probe`: the document's media
/// coordinator counters (`ADFDocumentModel.mediaCounters`: provider calls
/// started, landed, cancelled, failed, decoded images released, the most
/// calls at once and the calls running now), then the demo mock fetch's
/// counts since launch (`DemoMedia.shared.mock`; only the provider's memory
/// and disk misses reach it), each `-1` under `-media off` (no mock).
///
/// Like `SmartLinkProbe`: one element read in one query, so a test gets a
/// consistent snapshot without opening About This Build; it polls every
/// 250 ms in its own task and keeps the line in its own state, never in the
/// document's. Absent without the flag.
struct MediaProbe: View {
    let model: ADFDocumentModel
    @State private var line = "…"

    var body: some View {
        Text(verbatim: line)
            .font(.system(size: 7).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(2)
            .allowsHitTesting(false)
            .accessibilityIdentifier("media-probe")
            .task {
                while !Task.isCancelled {
                    line = Self.read(model)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
    }

    static func read(_ model: ADFDocumentModel) -> String {
        let counters = model.mediaCounters
        let mock = DemoMedia.shared.mock?.snapshot
        let fields: [(String, Int)] = [
            ("started", counters.started), ("finished", counters.finished), ("cancelled", counters.cancelled),
            ("failed", counters.failed), ("released", counters.released), ("maxRunning", counters.maxRunning),
            ("running", counters.running),
            ("mockCalls", mock?.calls ?? -1), ("mockCancelled", mock?.cancelled ?? -1),
            ("mockInFlight", mock?.inFlight ?? -1), ("mockFetched", mock?.fetched ?? -1),
            ("mockFailed", mock?.failed ?? -1),
        ]
        return fields.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
    }
}
