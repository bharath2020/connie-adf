import Foundation

/// Looks up the title of a smart link: a bare `https://<site>.atlassian.net/…`
/// link, or an inline card with such a URL. The host injects it into
/// `ADFDocumentView(smartLinkResolver:)`, the way it injects
/// `ADFMediaProvider`: the library never sees tokens, tenants or the
/// network, and a document without a resolver shows every link as authored.
///
/// Links resolve lazily, like images: a link is looked up only once the text
/// holding it (its paragraph, heading, list item or caption) is on screen,
/// after a short dwell, so a fling past it starts nothing; leaving the
/// screen cancels the lookup, which leaves the link plain until it appears
/// again. `ADFDocumentView(smartLinkResolution:)` can make lookups wait
/// until scrolling stops, and can add, at rest, small batches of the
/// off-screen links nearest the screen (`ADFSmartLinkResolution`). The
/// result replaces the link's text (an inline card's host) with an icon and
/// the title, in the text that shows that link only.
public protocol ADFSmartLinkResolver: Sendable {
    /// Called on a background executor while the URL is on screen (or, under
    /// `.afterScrollingWithNearby`, near it while the reader is not
    /// scrolling; such a call is cancelled when scrolling resumes), with at
    /// most one call at a time per canonical URL (scheme and host
    /// lowercased, a trailing dot, the default port and the fragment
    /// removed; URLs with user info are never passed) and at most four calls
    /// at once. A cancelled call counts toward both limits until it
    /// returns, so honour task cancellation promptly: a call cancelled
    /// because its link left the screen is made again when the link
    /// returns. Once a call returns, the URL is not asked about again in
    /// that document; throw `ADFSmartLinkError` (or any error) to leave the
    /// link plain. The title is shown on one line: control and bidirectional
    /// formatting characters are removed and whitespace collapsed, and a
    /// title left empty leaves the link plain. Hosts should cache across
    /// documents: the renderer keeps only a per-document cache.
    func resolve(_ url: URL) async throws -> ADFSmartLinkMetadata
}

/// What a resolved smart link shows: an icon by kind, then the title, as a
/// link to the same URL.
public struct ADFSmartLinkMetadata: Sendable, Hashable {
    /// The kind of thing a link points at, drawn as an SF Symbol before the
    /// title and spoken by VoiceOver ("Page, Q3 Roadmap").
    public enum Icon: Sendable, Hashable {
        /// A Confluence page.
        case page
        /// A Confluence blog post.
        case blogPost
        /// A Jira issue.
        case issue
        /// Anything else.
        case generic
    }

    /// Shown in place of the link's URL text.
    public var title: String
    public var icon: Icon

    public init(title: String, icon: Icon = .page) {
        self.title = title
        self.icon = icon
    }
}

/// Errors a resolver throws to leave a link plain. Any other error does the
/// same; these two name the common cases.
public enum ADFSmartLinkError: Error, Sendable {
    /// The reader may not see what the link points at.
    case unauthorized
    /// The link points at nothing the host can find.
    case notFound
}
