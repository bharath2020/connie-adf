import Foundation

/// One QR frame of the ADF Beam protocol: `ADF1|<docId>|<index>|<total>|<data>`.
///
/// `data` is a base64-encoded slice of the raw-deflate-compressed ADF JSON.
/// Indices are zero-based; `total` is the number of chunks in the document.
public struct BeamFrame: Equatable, Sendable {
    public static let prefix = "ADF1"

    public let docId: String
    public let index: Int
    public let total: Int
    /// The decoded (binary) chunk bytes.
    public let chunk: Data

    public enum ParseError: Error, Equatable {
        case badPrefix
        case badFieldCount
        case emptyDocId
        case badIndex
        case badTotal
        case indexOutOfRange
        case badBase64
    }

    public init(payload: String) throws {
        let fields = payload.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false)
        guard fields.count == 5 else { throw ParseError.badFieldCount }
        guard fields[0] == Self.prefix else { throw ParseError.badPrefix }
        guard fields[1].isEmpty == false else { throw ParseError.emptyDocId }
        guard let index = Int(fields[2]), index >= 0 else { throw ParseError.badIndex }
        guard let total = Int(fields[3]), total > 0 else { throw ParseError.badTotal }
        guard index < total else { throw ParseError.indexOutOfRange }
        guard let chunk = Data(base64Encoded: String(fields[4])), chunk.isEmpty == false else {
            throw ParseError.badBase64
        }
        self.docId = String(fields[1])
        self.index = index
        self.total = total
        self.chunk = chunk
    }
}
