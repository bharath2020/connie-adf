import Foundation

/// The identity a custom emoji (an emoji node with no unicode text) is
/// looked up by: its Atlassian id, when the document records one, and its
/// short name as authored (`":ld-custom-6:"`, colons included). Runs with
/// the same key share one lookup and one displayed stage, wherever they sit
/// in the document.
///
/// Package-internal: preparation stamps it on the emoji's U+FFFC character
/// (`AttributeScopes.ADFAttributes.EmojiAttribute`), the renderer maps it to
/// the public `ADFEmojiReference` its host's resolver receives.
package struct EmojiKey: Hashable, Sendable, CustomStringConvertible {
    /// The Atlassian emoji id, for example `"atlassian-logo"`; `nil` when
    /// the document does not record one.
    package let id: String?
    /// The short name as the document records it, for example
    /// `":ld-custom-6:"`.
    package let shortName: String

    package init(id: String?, shortName: String) {
        self.id = id
        self.shortName = shortName
    }

    package var description: String { id.map { "\(shortName) (\($0))" } ?? shortName }

    /// The character a custom emoji occupies in prepared text: one U+FFFC
    /// (OBJECT REPLACEMENT CHARACTER) carrying the key. The renderer
    /// replaces it with the short name, a fixed box or the image
    /// (`EmojiDisplay`), so it is never drawn as is.
    package static let character: Character = "\u{FFFC}"
}
