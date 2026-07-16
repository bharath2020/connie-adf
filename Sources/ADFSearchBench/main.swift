import Foundation
import ADFModel
import ADFPreparation

private enum Variant: String {
    case legacy
    case incremental
}

private enum Workload: String {
    case verify
    case staticQuery = "static"
    case updates
    case spans
}

private struct Arguments {
    let workload: Workload
    let variant: Variant?
    let fixturePath: String
    let query: String
    let iterations: Int
    let parts: Int

    static func parse() throws -> Self {
        var values = Array(CommandLine.arguments.dropFirst())
        guard let workloadValue = values.first,
              let workload = Workload(rawValue: workloadValue) else {
            throw BenchmarkError.usage
        }
        values.removeFirst()

        var variant: Variant?
        var fixturePath = "Fixtures/stress-5k.json"
        var query = "fixture"
        var iterations = 20
        var parts = 5_000
        var index = 0
        while index < values.count {
            switch values[index] {
            case "--variant":
                index += 1
                guard index < values.count, let parsed = Variant(rawValue: values[index]) else {
                    throw BenchmarkError.usage
                }
                variant = parsed
            case "--fixture":
                index += 1
                guard index < values.count else { throw BenchmarkError.usage }
                fixturePath = values[index]
            case "--query":
                index += 1
                guard index < values.count else { throw BenchmarkError.usage }
                query = values[index]
            case "--iterations":
                index += 1
                guard index < values.count, let parsed = Int(values[index]), parsed > 0 else {
                    throw BenchmarkError.usage
                }
                iterations = parsed
            case "--parts":
                index += 1
                guard index < values.count, let parsed = Int(values[index]), parsed > 0 else {
                    throw BenchmarkError.usage
                }
                parts = parsed
            default:
                throw BenchmarkError.usage
            }
            index += 1
        }

        if workload != .verify, variant == nil {
            throw BenchmarkError.usage
        }
        return Self(
            workload: workload,
            variant: variant,
            fixturePath: fixturePath,
            query: query,
            iterations: iterations,
            parts: parts
        )
    }
}

private enum BenchmarkError: Error, CustomStringConvertible {
    case usage
    case noMutableBlocks
    case resultMismatch(String)

    var description: String {
        switch self {
        case .usage:
            return "usage: ADFSearchBench <verify|static|updates|spans> [--variant legacy|incremental] [--fixture path] [--query text] [--iterations n] [--parts n]"
        case .noMutableBlocks:
            return "fixture contains no rich-text blocks for the update workload"
        case .resultMismatch(let context):
            return "legacy and incremental results differ: \(context)"
        }
    }
}

private struct Snapshot: Equatable {
    var matchCount = 0
    var textSpanCount = 0
    var atomCount = 0
    var checksum = 0

    static func += (lhs: inout Snapshot, rhs: Snapshot) {
        lhs.matchCount += rhs.matchCount
        lhs.textSpanCount += rhs.textSpanCount
        lhs.atomCount += rhs.atomCount
        lhs.checksum &+= rhs.checksum
    }

    static func -= (lhs: inout Snapshot, rhs: Snapshot) {
        lhs.matchCount -= rhs.matchCount
        lhs.textSpanCount -= rhs.textSpanCount
        lhs.atomCount -= rhs.atomCount
        lhs.checksum &-= rhs.checksum
    }
}

private struct CanonicalHit: Equatable {
    let itemID: String
    let ownerID: String
    let range: Range<Int>
    let painting: SearchMatchPainting
}

private struct Corpus {
    let blocks: [RenderBlock]
    let items: [SearchIndexedItem]
    let indexer: SearchIndexer

    static func load(path: String) async throws -> Self {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let document = try await ADFParser().parse(data)
        let indexer = SearchIndexer(theme: .default)
        let blocks = DocumentPreparer(theme: .default).prepare(document)
        let items = blocks.map { block in
            SearchIndexedItem(id: block.id, units: indexer.units(for: [block]))
        }
        return Self(blocks: blocks, items: items, indexer: indexer)
    }
}

private func summary(
    itemID: String,
    units: [SearchTextUnit],
    matches: [SearchIndexedItemMatch]
) -> Snapshot {
    var snapshot = Snapshot()
    for match in matches {
        let unit = units[match.unitIndex]
        snapshot.matchCount += 1
        snapshot.textSpanCount += match.painting.textSpans.count
        snapshot.atomCount += match.painting.atomIDs.count
        snapshot.checksum &+= itemID.count &* 31
        snapshot.checksum &+= unit.ownerID.count &* 17
        snapshot.checksum &+= match.range.lowerBound &* 7
        snapshot.checksum &+= match.range.upperBound
        for span in match.painting.textSpans {
            snapshot.checksum &+= span.segmentIndex &* 13
            snapshot.checksum &+= span.range.lowerBound &* 5
            snapshot.checksum &+= span.range.upperBound
        }
        for atomID in match.painting.atomIDs {
            snapshot.checksum &+= atomID.count &* 19
        }
    }
    return snapshot
}

private func legacySnapshot(units: [SearchTextUnit], query: String) -> Snapshot {
    let matches = SearchMatcher.matches(in: units, unitIndexOffset: 0, query: query)
    var snapshot = Snapshot()
    for match in matches {
        let unit = units[match.unitIndex]
        let painting = SearchMatcher.spans(for: match.range, in: unit)
        snapshot.matchCount += 1
        snapshot.textSpanCount += painting.textSpans.count
        snapshot.atomCount += painting.atomIDs.count
        snapshot.checksum &+= unit.topLevelBlockID.count &* 31
        snapshot.checksum &+= unit.ownerID.count &* 17
        snapshot.checksum &+= match.range.lowerBound &* 7
        snapshot.checksum &+= match.range.upperBound
        for span in painting.textSpans {
            snapshot.checksum &+= span.segmentIndex &* 13
            snapshot.checksum &+= span.range.lowerBound &* 5
            snapshot.checksum &+= span.range.upperBound
        }
        for atomID in painting.atomIDs {
            snapshot.checksum &+= atomID.count &* 19
        }
    }
    return snapshot
}

private func incrementalSnapshot(items: [SearchIndexedItem], query: String) -> Snapshot {
    var snapshot = Snapshot()
    for item in items {
        let result = IncrementalSearchIndex.result(for: item, query: query)
        snapshot += summary(itemID: item.id, units: item.units, matches: result.matches)
    }
    return snapshot
}

private func legacyHits(units: [SearchTextUnit], query: String) -> [CanonicalHit] {
    SearchMatcher.matches(in: units, unitIndexOffset: 0, query: query).map { match in
        let unit = units[match.unitIndex]
        let painting = SearchMatcher.spans(for: match.range, in: unit)
        return CanonicalHit(
            itemID: unit.topLevelBlockID,
            ownerID: unit.ownerID,
            range: match.range,
            painting: SearchMatchPainting(
                textSpans: painting.textSpans,
                atomIDs: painting.atomIDs
            )
        )
    }
}

private func incrementalHits(items: [SearchIndexedItem], query: String) -> [CanonicalHit] {
    items.flatMap { item in
        let result = IncrementalSearchIndex.result(for: item, query: query)
        return result.matches.map { match in
            CanonicalHit(
                itemID: item.id,
                ownerID: item.units[match.unitIndex].ownerID,
                range: match.range,
                painting: match.painting
            )
        }
    }
}

private func modified(_ block: RenderBlock, suffix: String) -> RenderBlock? {
    guard case .richText(let segments, let style) = block.kind else { return nil }
    var changed = segments
    changed.append(.text(AttributedString(suffix)))
    return RenderBlock(
        id: block.id,
        kind: .richText(segments: changed, style: style),
        breakout: block.breakout
    )
}

private func percentile(_ values: [Double], fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = min(Int((Double(sorted.count) * fraction).rounded(.up)) - 1, sorted.count - 1)
    return sorted[max(index, 0)]
}

private func measure(iterations: Int, operation: () -> Snapshot) -> (times: [Double], result: Snapshot) {
    var times: [Double] = []
    times.reserveCapacity(iterations)
    var result = Snapshot()
    for _ in 0..<iterations {
        let start = DispatchTime.now().uptimeNanoseconds
        result = operation()
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        times.append(Double(elapsed) / 1_000_000)
    }
    return (times, result)
}

private func printResult(
    workload: Workload,
    variant: Variant,
    iterations: Int,
    blockCount: Int,
    unitCount: Int,
    times: [Double],
    result: Snapshot
) {
    let total = times.reduce(0, +)
    print(
        "RESULT workload=\(workload.rawValue) variant=\(variant.rawValue) iterations=\(iterations) " +
        "blocks=\(blockCount) units=\(unitCount) matches=\(result.matchCount) spans=\(result.textSpanCount) " +
        "medianMs=\(String(format: "%.3f", percentile(times, fraction: 0.5))) " +
        "p95Ms=\(String(format: "%.3f", percentile(times, fraction: 0.95))) " +
        "totalMs=\(String(format: "%.3f", total)) checksum=\(result.checksum)"
    )
}

private func verify(_ corpus: Corpus, query: String) throws {
    let units = corpus.indexer.units(for: corpus.blocks)
    let legacy = legacyHits(units: units, query: query)
    let incremental = incrementalHits(items: corpus.items, query: query)
    guard legacy == incremental else {
        throw BenchmarkError.resultMismatch("static query \(query), legacy=\(legacy.count), incremental=\(incremental.count)")
    }

    guard let target = corpus.blocks.indices.first(where: { modified(corpus.blocks[$0], suffix: " benchmarkneedle") != nil }),
          let replacement = modified(corpus.blocks[target], suffix: " benchmarkneedle") else {
        throw BenchmarkError.noMutableBlocks
    }
    var blocks = corpus.blocks
    blocks[target] = replacement
    var items = corpus.items
    items[target] = SearchIndexedItem(id: replacement.id, units: corpus.indexer.units(for: [replacement]))
    let changedLegacy = legacyHits(units: corpus.indexer.units(for: blocks), query: "benchmarkneedle")
    let changedIncremental = incrementalHits(items: items, query: "benchmarkneedle")
    guard changedLegacy == changedIncremental else {
        throw BenchmarkError.resultMismatch("single-block replacement")
    }
    print("VERIFY ok blocks=\(corpus.blocks.count) query=\(query) hits=\(legacy.count) updateHits=\(changedLegacy.count)")
}

private func runStatic(_ corpus: Corpus, variant: Variant, query: String, iterations: Int) {
    switch variant {
    case .legacy:
        let units = corpus.indexer.units(for: corpus.blocks)
        _ = legacySnapshot(units: units, query: query)
        let measured = measure(iterations: iterations) {
            legacySnapshot(units: units, query: query)
        }
        printResult(
            workload: .staticQuery,
            variant: variant,
            iterations: iterations,
            blockCount: corpus.blocks.count,
            unitCount: units.count,
            times: measured.times,
            result: measured.result
        )
    case .incremental:
        _ = incrementalSnapshot(items: corpus.items, query: query)
        let measured = measure(iterations: iterations) {
            incrementalSnapshot(items: corpus.items, query: query)
        }
        printResult(
            workload: .staticQuery,
            variant: variant,
            iterations: iterations,
            blockCount: corpus.blocks.count,
            unitCount: corpus.items.reduce(0) { $0 + $1.units.count },
            times: measured.times,
            result: measured.result
        )
    }
}

private func runUpdates(_ corpus: Corpus, variant: Variant, iterations: Int) throws {
    let mutableIndices = corpus.blocks.indices.filter {
        modified(corpus.blocks[$0], suffix: " benchmarkneedle") != nil
    }
    guard !mutableIndices.isEmpty else { throw BenchmarkError.noMutableBlocks }
    let query = "benchmarkneedle"
    var times: [Double] = []
    times.reserveCapacity(iterations)
    var final = Snapshot()

    switch variant {
    case .legacy:
        var blocks = corpus.blocks
        for iteration in 0..<iterations {
            let target = mutableIndices[(iteration / 2) % mutableIndices.count]
            let replacement = iteration.isMultiple(of: 2)
                ? modified(corpus.blocks[target], suffix: " \(query)")!
                : corpus.blocks[target]
            let start = DispatchTime.now().uptimeNanoseconds
            blocks[target] = replacement
            let units = corpus.indexer.units(for: blocks)
            final = legacySnapshot(units: units, query: query)
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            times.append(Double(elapsed) / 1_000_000)
        }
    case .incremental:
        var items = corpus.items
        var itemSummaries = Dictionary(uniqueKeysWithValues: items.map { item in
            let result = IncrementalSearchIndex.result(for: item, query: query)
            return (item.id, summary(itemID: item.id, units: item.units, matches: result.matches))
        })
        var total = itemSummaries.values.reduce(into: Snapshot()) { $0 += $1 }
        for iteration in 0..<iterations {
            let target = mutableIndices[(iteration / 2) % mutableIndices.count]
            let replacement = iteration.isMultiple(of: 2)
                ? modified(corpus.blocks[target], suffix: " \(query)")!
                : corpus.blocks[target]
            let start = DispatchTime.now().uptimeNanoseconds
            let item = SearchIndexedItem(id: replacement.id, units: corpus.indexer.units(for: [replacement]))
            let result = IncrementalSearchIndex.result(for: item, query: query)
            let next = summary(itemID: item.id, units: item.units, matches: result.matches)
            if let old = itemSummaries[item.id] { total -= old }
            itemSummaries[item.id] = next
            total += next
            items[target] = item
            final = total
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            times.append(Double(elapsed) / 1_000_000)
        }
        withExtendedLifetime(items) {}
    }

    printResult(
        workload: .updates,
        variant: variant,
        iterations: iterations,
        blockCount: corpus.blocks.count,
        unitCount: corpus.items.reduce(0) { $0 + $1.units.count },
        times: times,
        result: final
    )
}

private func runSpans(variant: Variant, parts: Int, iterations: Int) {
    var unitParts: [SearchTextUnit.Part] = []
    unitParts.reserveCapacity(parts)
    for index in 0..<parts {
        unitParts.append(.init(source: .textSegment(index: index), range: index..<(index + 1)))
    }
    let unit = SearchTextUnit(
        ownerID: "segmented",
        topLevelBlockID: "segmented",
        expandAncestorIDs: [],
        plainText: String(repeating: "a", count: parts),
        parts: unitParts
    )
    let ranges = SearchMatcher.matchRanges(in: unit.plainText, query: "a")
    var times: [Double] = []
    var final = Snapshot()
    for _ in 0..<iterations {
        let start = DispatchTime.now().uptimeNanoseconds
        switch variant {
        case .legacy:
            var snapshot = Snapshot()
            for range in ranges {
                let painting = SearchMatcher.spans(for: range, in: unit)
                snapshot.matchCount += 1
                snapshot.textSpanCount += painting.textSpans.count
                snapshot.atomCount += painting.atomIDs.count
                snapshot.checksum &+= range.lowerBound &+ painting.textSpans.count
            }
            final = snapshot
        case .incremental:
            let paintings = SearchMatcher.spans(for: ranges, in: unit)
            var snapshot = Snapshot()
            for (range, painting) in zip(ranges, paintings) {
                snapshot.matchCount += 1
                snapshot.textSpanCount += painting.textSpans.count
                snapshot.atomCount += painting.atomIDs.count
                snapshot.checksum &+= range.lowerBound &+ painting.textSpans.count
            }
            final = snapshot
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        times.append(Double(elapsed) / 1_000_000)
    }
    printResult(
        workload: .spans,
        variant: variant,
        iterations: iterations,
        blockCount: 1,
        unitCount: 1,
        times: times,
        result: final
    )
}

@main
private enum ADFSearchBench {
    static func main() async {
        do {
            let arguments = try Arguments.parse()
            if arguments.workload == .spans {
                runSpans(variant: arguments.variant!, parts: arguments.parts, iterations: arguments.iterations)
                return
            }
            let corpus = try await Corpus.load(path: arguments.fixturePath)
            switch arguments.workload {
            case .verify:
                try verify(corpus, query: arguments.query)
            case .staticQuery:
                runStatic(corpus, variant: arguments.variant!, query: arguments.query, iterations: arguments.iterations)
            case .updates:
                try runUpdates(corpus, variant: arguments.variant!, iterations: arguments.iterations)
            case .spans:
                break
            }
        } catch {
            FileHandle.standardError.write(Data("ERROR \(error)\n".utf8))
            exit(2)
        }
    }
}
