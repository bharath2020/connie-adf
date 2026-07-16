import ADFPreparation

/// A prepared top-level row with logical identity independent of its ADF
/// structural path. Update producers must retain this ID across replacements.
public struct ADFDocumentItem: Sendable, Hashable, Identifiable {
    public let id: String
    public let block: RenderBlock

    public init(id: String, block: RenderBlock) {
        self.id = id
        self.block = block
    }
}

/// Versioned top-level mutations. A nested edit replaces the top-level item
/// that owns it; full snapshots without stable IDs continue to use `load`.
public enum ADFDocumentMutation: Sendable, Hashable {
    /// Inserts after `afterID`; nil inserts at the document beginning.
    case insert(ADFDocumentItem, afterID: String?)
    case replace(itemID: String, block: RenderBlock)
    case remove(itemID: String)
    /// Moves after `afterID`; nil moves to the document beginning.
    case move(itemID: String, afterID: String?)
}

public enum ADFDocumentMutationError: Error, Equatable, Sendable {
    case documentNotReady
    case staleRevision(current: UInt64, received: UInt64)
    case duplicateItemID(String)
    case duplicateBlockID(String)
    case missingItemID(String)
    case missingAnchorID(String)
}
