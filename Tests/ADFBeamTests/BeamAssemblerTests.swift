import Foundation
import Testing
@testable import ADFBeam

@Suite("BeamAssembler")
struct BeamAssemblerTests {
    @Test("deflate then inflate round-trips arbitrary bytes")
    func roundTrip() throws {
        let original = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let compressed = try BeamAssembler.deflate(original)
        #expect(try BeamAssembler.inflate(compressed) == original)
    }

    @Test("a chunked document reassembles to the original JSON")
    func chunkedRoundTrip() throws {
        let json = Data(#"{"version":1,"type":"doc","content":[{"type":"paragraph"}]}"#.utf8)
        let compressed = try BeamAssembler.deflate(json)

        let chunkSize = 16
        var frames: [BeamFrame] = []
        let total = (compressed.count + chunkSize - 1) / chunkSize
        for index in 0..<total {
            let slice = compressed[compressed.startIndex.advanced(by: index * chunkSize)..<compressed.startIndex.advanced(by: min((index + 1) * chunkSize, compressed.count))]
            frames.append(try BeamFrame(payload: "ADF1|doc|\(index)|\(total)|\(Data(slice).base64EncodedString())"))
        }

        let collector = ChunkCollector()
        for frame in frames.shuffled() {
            collector.accept(frame)
        }
        #expect(try BeamAssembler.assemble(collector) == json)
    }

    @Test("assembling an incomplete collector throws")
    func incompleteThrows() throws {
        let collector = ChunkCollector()
        collector.accept(try BeamFrame(payload: "ADF1|d|0|2|aGk="))
        #expect(throws: BeamAssembler.AssemblyError.incomplete) {
            try BeamAssembler.assemble(collector)
        }
    }

    @Test("garbage bytes fail to inflate")
    func garbageFails() {
        #expect(throws: BeamAssembler.AssemblyError.decompressionFailed) {
            try BeamAssembler.inflate(Data([0xFF, 0x00, 0xAB, 0xCD, 0x01, 0x02, 0x03]))
        }
    }
}
