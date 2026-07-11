/// A non-fatal problem encountered while building the node tree.
///
/// Issues never fail a parse; they surface recoveries (defaulted attributes,
/// dropped marks, unknown node types) for logging and diagnostics.
public struct ADFParseIssue: Sendable, Hashable {
    /// Structural path ID of the node the issue was found at (e.g. `"0.2.1"`).
    public let path: String
    public let message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}
