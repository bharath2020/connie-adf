import Foundation

/// One attachment of a Confluence page, from
/// `GET /wiki/api/v2/pages/{id}/attachments` (`AttachmentBulk`).
///
/// ``fileId`` is the ID that ADF `media.attrs.id` carries; ``id`` is the
/// attachment ID (`att…`) that the download endpoint takes. They differ.
public struct AtlassianAttachment: Sendable, Hashable {
    /// The attachment ID, for example `att229378`.
    public let id: String
    /// The file name.
    public let title: String
    /// The media-services file ID referenced by `atlas_doc_format` bodies.
    public let fileId: String
    /// The MIME type, for example `image/png`. Empty when Atlassian sent none.
    public let mediaType: String
    /// Size in bytes, when Atlassian sent it.
    public let fileSize: Int?

    public init(id: String, title: String, fileId: String, mediaType: String, fileSize: Int?) {
        self.id = id
        self.title = title
        self.fileId = fileId
        self.mediaType = mediaType
        self.fileSize = fileSize
    }
}

/// The wire shape of one page of `getPageAttachments`
/// (`MultiEntityResult<Attachment>`).
struct AttachmentListResponse: Decodable {
    struct Item: Decodable {
        let id: String?
        let title: String?
        let fileId: String?
        let mediaType: String?
        let fileSize: Int?
    }

    struct Links: Decodable {
        /// A relative URL with a `cursor` query, for example
        /// `/wiki/api/v2/pages/229377/attachments?cursor=…`. Absent on the
        /// last page.
        let next: String?
    }

    let results: [Item]?
    let links: Links?

    enum CodingKeys: String, CodingKey {
        case results
        case links = "_links"
    }

    /// Items with both an attachment ID and a file ID (the others can never
    /// match an ADF media node or be downloaded).
    var attachments: [AtlassianAttachment] {
        (results ?? []).compactMap { item in
            guard let id = item.id, !id.isEmpty, let fileId = item.fileId, !fileId.isEmpty else { return nil }
            return AtlassianAttachment(id: id, title: item.title ?? "", fileId: fileId, mediaType: item.mediaType ?? "", fileSize: item.fileSize)
        }
    }
}

/// The wire shape of `GET https://<site>/_edge/tenant_info`.
struct TenantInfoResponse: Decodable {
    let cloudId: String?
}
