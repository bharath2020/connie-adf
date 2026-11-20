import Foundation

/// The key of a custom emoji: an emoji node with no unicode text, which the
/// renderer cannot draw by itself.
public struct ADFEmojiReference: Sendable, Hashable {
    /// The Atlassian emoji id, for example `"atlassian-logo"`. `nil` when
    /// the document does not record one.
    public let id: String?
    /// The short name as the document records it, for example
    /// `":ld-custom-6:"`.
    public let shortName: String

    public init(id: String?, shortName: String) {
        self.id = id
        self.shortName = shortName
    }
}

/// Looks up the image of a custom emoji (an emoji with no unicode text).
/// The host injects it into `ADFDocumentView(emojiResolver:)`, the way it
/// injects `ADFSmartLinkResolver` and `ADFMediaProvider`: the library never
/// sees tokens, tenants or the network. Unicode emoji draw natively and are
/// never passed here.
public protocol ADFEmojiResolver: Sendable {
    /// Called on a background executor while the emoji is on screen, with
    /// the same contract as `ADFSmartLinkResolver`: at most one call at a
    /// time per reference, at most four calls at once, and no second call
    /// for a reference in one document once a call returns. Honour task
    /// cancellation promptly: a call cancelled because its emoji left the
    /// screen is made again when the emoji returns. Throw to show the short
    /// name instead. Hosts should cache across documents.
    func image(for emoji: ADFEmojiReference) async throws -> ADFResolvedImage
}
