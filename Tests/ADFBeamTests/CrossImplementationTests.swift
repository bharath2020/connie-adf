import Foundation
import Testing
@testable import ADFBeam

/// Feeds the JS-encoder-generated fixture (`make-fixture.mjs`) through the
/// Swift decoder, proving the two protocol implementations agree.
@Suite("Cross-implementation fixtures")
struct CrossImplementationTests {
    private func repoRootURL() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent() // …/Tests/ADFBeamTests
        url.deleteLastPathComponent() // …/Tests
        url.deleteLastPathComponent() // repo root
        return url
    }

    @Test("JS-encoded kitchen-sink chunks reassemble to the original JSON bytes")
    func kitchenSinkChunksRoundTrip() throws {
        let root = repoRootURL()
        let chunksText = try String(
            contentsOf: root.appendingPathComponent("Tests/ADFBeamTests/Fixtures/kitchen-sink.chunks.txt"),
            encoding: .utf8
        )
        let original = try Data(contentsOf: root.appendingPathComponent("Fixtures/kitchen-sink.json"))

        let collector = ChunkCollector()
        let lines = chunksText.split(separator: "\n").shuffled()
        #expect(lines.count > 1, "fixture should span multiple chunks")
        for line in lines {
            let frame = try BeamFrame(payload: String(line))
            #expect(frame.docId == "kitchen-sink-fixture")
            #expect(frame.chunk.count <= 800)
            collector.accept(frame)
        }
        #expect(collector.isComplete)
        #expect(try BeamAssembler.assemble(collector) == original)
    }
}
