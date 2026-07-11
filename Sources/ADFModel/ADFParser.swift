import Foundation

/// A fully parsed ADF document: typed tree plus non-fatal diagnostics.
public struct ADFDocument: Sendable {
    public let version: Int
    /// Always `kind == .doc`.
    public let root: ADFNode
    public let issues: [ADFParseIssue]

    public init(version: Int, root: ADFNode, issues: [ADFParseIssue]) {
        self.version = version
        self.root = root
        self.issues = issues
    }
}

/// Parses ADF JSON data into an `ADFDocument`.
///
/// `parse` is a nonisolated async function, so it hops off the caller's actor
/// and runs on the concurrent executor — a multi-megabyte document never
/// blocks the main thread. Throws only for malformed JSON or a non-object
/// root; unknown node types decode to `.unknown` and never fail.
public struct ADFParser: Sendable {
    /// The document could not be parsed at all (as opposed to per-node
    /// recoveries, which surface as `ADFParseIssue`s).
    public enum ParseError: Error, Sendable {
        case rootNotAnObject
    }

    public init() {}

    public func parse(_ data: Data) async throws -> ADFDocument {
        let object = try JSONSerialization.jsonObject(with: data)
        let json = try JSONValue(jsonObject: object)
        guard case .object = json else {
            throw ParseError.rootNotAnObject
        }
        return ADFNodeBuilder.buildDocument(json)
    }
}
