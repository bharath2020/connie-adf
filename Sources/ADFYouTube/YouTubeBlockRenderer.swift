import SwiftUI
import ADFModel
import ADFPreparation
import ADFRendering

/// The payload a claim carries: everything the player needs, parsed once at
/// preparation time.
public struct YouTubeVideo: Hashable, Sendable {
    public let videoID: String

    public init(videoID: String) {
        self.videoID = videoID
    }
}

/// Renders YouTube links as inline video players (a 16:9 lite-embed facade;
/// the real player loads on tap). Claims:
/// - `embedCard` / `blockCard` / stray block-level `inlineCard` with a
///   watchable YouTube URL, and
/// - paragraphs whose entire content is one such link (an `inlineCard` smart
///   link or a bare link-marked text run), ignoring whitespace-only siblings.
///
/// Declines everything else — channels, playlists, non-YouTube URLs, and
/// links mid-sentence keep their existing rendering.
///
/// `searchableText` is deliberately `nil`: the facade renders a thumbnail,
/// not the URL, and find-in-page should only match text the reader can see.
public struct YouTubeBlockRenderer: ADFCustomBlockRenderer {
    public let rendererID = "adfkit.youtube"

    public init() {}

    // MARK: Claiming (off-main, once per block-level node — stay cheap)

    public func claim(for node: ADFNode) -> ADFCustomBlockClaim? {
        switch node.kind {
        case .embedCard(let url, _, _):
            return claim(url: url)
        case .blockCard(let url, let data), .inlineCard(let url, let data):
            return claim(url: url ?? data?["url"]?.stringValue)
        case .paragraph(let content, _):
            return claim(soloLinkIn: content)
        default:
            return nil
        }
    }

    private func claim(url: String?) -> ADFCustomBlockClaim? {
        guard let url, let videoID = YouTubeURL.videoID(from: url) else { return nil }
        return ADFCustomBlockClaim(
            YouTubeVideo(videoID: videoID),
            sizing: .aspectRatio(width: 16, height: 9)
        )
    }

    /// A paragraph that IS one link: exactly one non-whitespace inline child,
    /// which is a YouTube smart link (`inlineCard`) or a bare link-marked
    /// text run. Real Confluence paragraphs carry standalone whitespace text
    /// nodes around atoms, so whitespace siblings are ignored.
    private func claim(soloLinkIn content: [ADFNode]) -> ADFCustomBlockClaim? {
        var solo: ADFNode?
        for child in content {
            if case .text(let string, let marks) = child.kind,
               string.allSatisfy(\.isWhitespace), marks.isEmpty {
                continue
            }
            guard solo == nil else { return nil }
            solo = child
        }
        switch solo?.kind {
        case .inlineCard(let url, let data):
            return claim(url: url ?? data?["url"]?.stringValue)
        case .text(_, let marks):
            for mark in marks {
                if case .link(let href, _) = mark {
                    return claim(url: href)
                }
            }
            return nil
        default:
            return nil
        }
    }

    // MARK: Rendering

    @MainActor
    public func content(for value: YouTubeVideo, context: ADFCustomBlockContext) -> some View {
        YouTubePlayerView(
            videoID: value.videoID,
            cornerRadius: context.theme.containerCornerRadius
        )
    }
}
