import Foundation

/// The scopes ADFReader asks for when the user creates a scoped API token.
public enum AtlassianTokenScopes {
    /// Everything ADFReader asks for: ``read`` followed by ``write``.
    public static let required: [String] = read + write

    /// Read pages, spaces, blog posts, comments, content metadata (title
    /// emoji, version numbers) and attachment files (images in pages).
    public static let read: [String] = [
        "read:page:confluence",
        "read:space:confluence",
        "read:blogpost:confluence",
        readComment,
        contentMetadata,
        attachment,
        attachmentDownload,
    ]

    /// Create footer comments and replies, create and edit pages, create
    /// blog posts. These are the granular scopes the gateway lists on
    /// `confluence.createFooterCommentOnPage` / `replyToComment`,
    /// `createPage` / `updateCurrentPage` and `createBlogPost`. No delete
    /// scopes.
    public static let write: [String] = [writeComment, writePage, writeBlogPost]

    /// Guards `confluence.createFooterCommentOnPage` and `confluence.replyToComment`.
    public static let writeComment = "write:comment:confluence"
    /// Guards the `ConfluenceComment` those two mutations return (its ID is
    /// needed to reply). It is in ``read``; tokens created before write
    /// support lack it, so ``missingWriteScopes(in:)`` checks it too.
    public static let readComment = "read:comment:confluence"
    /// Guards `confluence.createPage` and `confluence.updateCurrentPage`.
    public static let writePage = "write:page:confluence"
    /// Guards `confluence.createBlogPost`.
    public static let writeBlogPost = "write:blogpost:confluence"

    /// The ``write`` scopes plus ``readComment`` missing from `scopes` (a
    /// stored credential's scope list). Empty means the token can write.
    public static func missingWriteScopes(in scopes: [String]) -> [String] {
        let present = Set(scopes)
        return (write + [readComment]).filter { !present.contains($0) }
    }

    /// The scope that guards `ConfluencePage.metadata` (title emoji). It is in
    /// ``required``; a token created without it gets the emoji reported as
    /// unavailable by the probe.
    public static let contentMetadata = "read:content.metadata:confluence"

    /// The granular scope for listing a page's attachments
    /// (`GET /wiki/api/v2/pages/{id}/attachments`). It is in ``required``.
    public static let attachment = "read:attachment:confluence"

    /// The classic scope the v1 attachment download
    /// (`GET /wiki/rest/api/content/{id}/child/attachment/{attachmentId}/download`)
    /// lists as current; the granular ``attachment`` scope is only "beta" there.
    /// It is in ``required``. Tokens created before it was added can list
    /// attachments but not download them; they need re-creating.
    public static let attachmentDownload = "readonly:content.attachment:confluence"

    /// Default token lifetime ADFReader suggests.
    public static let defaultExpiryDays = 90
}

/// Links to Atlassian's API token page, plus the manual steps to follow there.
public enum AtlassianTokenPage {
    /// The page where tokens are listed and revoked.
    public static let manageURL = URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!

    /// The token page with query parameters that ask Atlassian to open the
    /// "Create API token with scopes" flow prefilled for Confluence:
    /// `?autofillToken&expiryDays=<n>&appId=confluence&selectedScopes=<JSON array>`.
    ///
    /// - Important: Atlassian does not document these preselection parameters
    ///   and they are unverified. Always show ``manualSteps(expiryDays:)``
    ///   next to this link.
    /// - Parameter expiryDays: Clamped to 1...365 (Atlassian's maximum).
    public static func createURL(expiryDays: Int = AtlassianTokenScopes.defaultExpiryDays) -> URL {
        let days = min(max(expiryDays, 1), 365)
        let scopesData = (try? JSONSerialization.data(withJSONObject: AtlassianTokenScopes.required, options: [.withoutEscapingSlashes])) ?? Data("[]".utf8)
        let scopesJSON = String(decoding: scopesData, as: UTF8.self)
        var components = URLComponents(url: manageURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedQueryItems = [
            URLQueryItem(name: "autofillToken", value: nil),
            URLQueryItem(name: "expiryDays", value: String(days)),
            URLQueryItem(name: "appId", value: "confluence"),
            URLQueryItem(name: "selectedScopes", value: strictPercentEncode(scopesJSON)),
        ]
        return components.url!
    }

    /// Click-by-click steps for creating the token by hand.
    public static func manualSteps(expiryDays: Int = AtlassianTokenScopes.defaultExpiryDays) -> [String] {
        [
            "Sign in to id.atlassian.com with the account you use for the site.",
            "Click “Create API token with scopes”.",
            "Name it “ADFReader” and set it to expire in \(expiryDays) days, then click Next.",
            "Choose the app “Confluence”, then click Next.",
            "Tick these scopes: \(AtlassianTokenScopes.required.joined(separator: ", ")). Search for “read” and then “write” to find them (\(AtlassianTokenScopes.attachmentDownload) is a classic scope and may be listed apart from the others). Click Next.",
            "Check the summary and click “Create token”.",
            "Click “Copy” to copy the token. Atlassian shows it only once.",
        ]
    }

    /// ``manualSteps(expiryDays:)`` for the default 90-day expiry.
    public static var manualSteps: [String] { manualSteps() }

    private static func strictPercentEncode(_ string: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
}
