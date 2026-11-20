import Foundation

/// The wire shape of the emoji service's `GET /emoji/{cloudId}/{id}` and
/// `GET /emoji/{cloudId}/site` (undocumented; observed 2026-11-19 and in
/// `@atlaskit/emoji` 73.7.0):
///
/// ```json
/// {"emojis":[{"id":"…","shortName":":name:","type":"SITE",
///             "representation":{"imagePath":"https://<site>/media-api/file/<f>/image?collection=emoji-site-<cloudId>&…",
///                               "mediaFileId":"<f>","width":32,"height":32}}],
///  "meta":{"mediaApiToken":{…same as /site/token/read…}}}
/// ```
///
/// Standard and Atlassian emoji carry a public CDN `imagePath` (or a
/// `spriteRef` in list responses without `preferredRepresentation=IMAGE`).
struct EmojiServiceResponse: Decodable {
    struct Emoji: Decodable {
        let id: String?
        let shortName: String?
        let type: String?
        let representation: Representation?
    }

    struct Representation: Decodable {
        let imagePath: String?
        let mediaFileId: String?
    }

    struct Meta: Decodable {
        let mediaApiToken: MediaAPIToken?
    }

    let emojis: [Emoji]?
    let meta: Meta?
}

/// The wire shape of `GET /emoji/{cloudId}/site/token/read` (and of
/// `meta.mediaApiToken`): a read-only media token for the site's emoji
/// collection. `expiresAt` is in seconds since 1970; `expiresIn` (ms) is
/// ignored.
struct MediaAPIToken: Decodable {
    let clientId: String?
    let jwt: String?
    let url: String?
    let collectionName: String?
    let expiresAt: Double?

    /// A usable token, or nil when `clientId` or `jwt` is missing.
    func readToken(defaultExpiry: Date) -> EmojiReadToken? {
        guard let clientId, !clientId.isEmpty, let jwt, !jwt.isEmpty else { return nil }
        let expiry = expiresAt.map { Date(timeIntervalSince1970: $0) } ?? defaultExpiry
        return EmojiReadToken(clientId: clientId, jwt: jwt, expiresAt: expiry)
    }
}

/// A cached read token. `description` and `dump` never show the JWT.
struct EmojiReadToken: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    let clientId: String
    let jwt: String
    let expiresAt: Date

    var description: String { "EmojiReadToken(expiresAt: \(expiresAt))" }
    var customMirror: Mirror { Mirror(self, children: ["expiresAt": expiresAt]) }
}

/// The parts of one emoji the fetcher needs.
struct EmojiImageReference: Sendable, Equatable {
    let id: String
    let shortName: String
    let imagePath: String
    let mediaFileId: String?

    init?(_ emoji: EmojiServiceResponse.Emoji) {
        guard let imagePath = emoji.representation?.imagePath, !imagePath.isEmpty else { return nil }
        self.id = emoji.id ?? ""
        self.shortName = emoji.shortName ?? ""
        self.imagePath = imagePath
        self.mediaFileId = emoji.representation?.mediaFileId
    }
}
