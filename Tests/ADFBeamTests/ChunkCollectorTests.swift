import Foundation
import Testing
@testable import ADFBeam

@Suite("ChunkCollector")
struct ChunkCollectorTests {
    private func frame(_ docId: String, _ index: Int, _ total: Int, _ text: String) throws -> BeamFrame {
        try BeamFrame(payload: "ADF1|\(docId)|\(index)|\(total)|\(Data(text.utf8).base64EncodedString())")
    }

    @Test("frames arriving out of order complete and join in index order")
    func outOfOrder() throws {
        let collector = ChunkCollector()
        #expect(collector.accept(try frame("d", 2, 3, "C")) == .accepted)
        #expect(collector.isComplete == false)
        #expect(collector.accept(try frame("d", 0, 3, "A")) == .accepted)
        #expect(collector.accept(try frame("d", 1, 3, "B")) == .accepted)
        #expect(collector.isComplete)
        #expect(collector.assembledChunks() == Data("ABC".utf8))
    }

    @Test("duplicate frames are ignored and do not change progress")
    func duplicates() throws {
        let collector = ChunkCollector()
        collector.accept(try frame("d", 0, 2, "A"))
        #expect(collector.accept(try frame("d", 0, 2, "A")) == .duplicate)
        #expect(collector.receivedCount == 1)
        #expect(collector.receivedIndices == [0])
    }

    @Test("a frame with a different docId resets the collector")
    func docIdReset() throws {
        let collector = ChunkCollector()
        collector.accept(try frame("first", 0, 3, "A"))
        collector.accept(try frame("first", 1, 3, "B"))
        #expect(collector.accept(try frame("second", 0, 2, "X")) == .reset)
        #expect(collector.docId == "second")
        #expect(collector.total == 2)
        #expect(collector.receivedCount == 1)
    }

    @Test("same docId with a different total also resets")
    func totalMismatchReset() throws {
        let collector = ChunkCollector()
        collector.accept(try frame("d", 0, 3, "A"))
        #expect(collector.accept(try frame("d", 0, 2, "A")) == .reset)
        #expect(collector.total == 2)
        #expect(collector.receivedCount == 1)
    }

    @Test("assembledChunks is nil until every chunk has landed")
    func incompleteAssembly() throws {
        let collector = ChunkCollector()
        #expect(collector.assembledChunks() == nil)
        collector.accept(try frame("d", 0, 2, "A"))
        #expect(collector.assembledChunks() == nil)
        collector.accept(try frame("d", 1, 2, "B"))
        #expect(collector.assembledChunks() == Data("AB".utf8))
    }

    @Test("reset clears document identity and progress")
    func manualReset() throws {
        let collector = ChunkCollector()
        collector.accept(try frame("d", 0, 1, "A"))
        collector.reset()
        #expect(collector.docId == nil)
        #expect(collector.total == nil)
        #expect(collector.receivedCount == 0)
        #expect(collector.isComplete == false)
    }
}
