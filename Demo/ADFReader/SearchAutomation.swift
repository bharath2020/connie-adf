import Foundation
import ADFPreparation
import ADFRendering

@MainActor
enum SearchAutomation {
    static func run(
        model: ADFDocumentModel,
        query: String,
        updateCount: Int,
        fixtureName: String
    ) async {
        // The document can become ready just before its final detached index
        // batches publish. A short quiet period makes launch runs repeatable.
        try? await Task.sleep(for: .milliseconds(500))
        model.search.debounceInterval = .zero

        let searchStart = ContinuousClock.now
        model.search.run(query)
        await waitForSearchToSettle(model.search)
        let searchMilliseconds = milliseconds(since: searchStart)
        print(
            "SEARCH_METRICS fixture=\(fixtureName) query=\(query) "
                + "matches=\(model.search.matchCount) searchMs=\(format(searchMilliseconds))"
        )
        fflush(stdout)

        guard updateCount > 0,
              let targetIndex = model.blocks.indices.first(where: {
                  if case .richText(_, let style) = model.blocks[$0].kind {
                      return !style.isHeading
                  }
                  return false
              }),
              let changed = appending(" \(query)", to: model.blocks[targetIndex]) else {
            return
        }

        let original = model.blocks[targetIndex]
        let itemID = original.id
        var durations: [Double] = []
        durations.reserveCapacity(updateCount)
        for iteration in 0..<updateCount {
            let replacement = iteration.isMultiple(of: 2) ? changed : original
            let start = ContinuousClock.now
            do {
                try await model.apply(
                    [.replace(itemID: itemID, block: replacement)],
                    revision: model.documentRevision + 1
                )
            } catch {
                print("UPDATE_METRICS_ERROR iteration=\(iteration) error=\(error)")
                fflush(stdout)
                return
            }
            durations.append(milliseconds(since: start))
        }

        print(
            "UPDATE_METRICS fixture=\(fixtureName) query=\(query) iterations=\(updateCount) "
                + "matches=\(model.search.matchCount) "
                + "medianMs=\(format(percentile(durations, fraction: 0.5))) "
                + "p95Ms=\(format(percentile(durations, fraction: 0.95)))"
        )
        fflush(stdout)
    }

    private static func waitForSearchToSettle(_ search: ADFDocumentSearch) async {
        while !search.isActive {
            await Task.yield()
        }
        while search.isSearching {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    private static func appending(_ suffix: String, to block: RenderBlock) -> RenderBlock? {
        guard case .richText(let segments, let style) = block.kind else { return nil }
        var changed = segments
        changed.append(.text(AttributedString(suffix)))
        return RenderBlock(
            id: block.id,
            kind: .richText(segments: changed, style: style),
            breakout: block.breakout
        )
    }

    private static func percentile(_ values: [Double], fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(Int((Double(sorted.count) * fraction).rounded(.up)) - 1, sorted.count - 1)
        return sorted[max(index, 0)]
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let (seconds, attoseconds) = start.duration(to: .now).components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
