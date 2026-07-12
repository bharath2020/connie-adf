import Foundation

/// Collects `BeamFrame`s for one document: accepts frames in any order,
/// ignores duplicates, and resets when a frame from a different document
/// (different docId, or same docId with a different total) arrives.
public final class ChunkCollector {
    public enum Outcome: Equatable, Sendable {
        /// A new chunk was stored.
        case accepted
        /// This chunk was already collected; nothing changed.
        case duplicate
        /// The frame belongs to a different document; the collector reset
        /// and stored the frame as the first chunk of the new document.
        case reset
    }

    public private(set) var docId: String?
    public private(set) var total: Int?
    private var chunks: [Int: Data] = [:]

    public init() {}

    public var receivedCount: Int { chunks.count }
    public var receivedIndices: Set<Int> { Set(chunks.keys) }
    public var isComplete: Bool {
        guard let total else { return false }
        return chunks.count == total
    }

    @discardableResult
    public func accept(_ frame: BeamFrame) -> Outcome {
        if docId != frame.docId || total != frame.total {
            let hadDocument = docId != nil
            reset()
            docId = frame.docId
            total = frame.total
            chunks[frame.index] = frame.chunk
            return hadDocument ? .reset : .accepted
        }
        guard chunks[frame.index] == nil else { return .duplicate }
        chunks[frame.index] = frame.chunk
        return .accepted
    }

    public func reset() {
        docId = nil
        total = nil
        chunks.removeAll()
    }

    /// The chunks concatenated in index order, or nil until complete.
    public func assembledChunks() -> Data? {
        guard let total, chunks.count == total else { return nil }
        var joined = Data()
        for index in 0..<total {
            guard let chunk = chunks[index] else { return nil }
            joined.append(chunk)
        }
        return joined
    }
}
