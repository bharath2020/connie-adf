import Foundation

/// Pure YouTube URL recognition: extracts the 11-character video ID from the
/// URL shapes YouTube links take in Confluence content. Everything else —
/// channels, playlists, handles, search results, other hosts — returns `nil`
/// so the document keeps its existing card rendering.
public enum YouTubeURL {
    /// The video ID, when `string` is a watchable YouTube video URL.
    public static func videoID(from string: String) -> String? {
        guard let components = URLComponents(string: string),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host?.lowercased()
        else { return nil }

        let pathParts = components.path.split(separator: "/").map(String.init)

        if host == "youtu.be" {
            return validated(pathParts.first)
        }

        guard isYouTubeHost(host) else { return nil }

        switch pathParts.first {
        case "watch":
            let v = components.queryItems?.first(where: { $0.name == "v" })?.value
            return validated(v)
        case "embed", "shorts", "live", "v":
            return validated(pathParts.count > 1 ? pathParts[1] : nil)
        default:
            return nil
        }
    }

    /// Poster frame for the facade, served from YouTube's image CDN.
    public static func thumbnailURL(videoID: String) -> URL? {
        URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")
    }

    /// Privacy-enhanced inline player page (no cookies until playback).
    public static func embedURL(videoID: String) -> URL? {
        URL(string: "https://www.youtube-nocookie.com/embed/\(videoID)?autoplay=1&playsinline=1")
    }

    /// Origin the embed page must be loaded under. YouTube refuses playerless
    /// requests (Error 153: no referer), so the player is loaded as an iframe
    /// HTML string with this as `baseURL` rather than as a bare URL request.
    public static let embedPageBaseURL = URL(string: "https://www.youtube-nocookie.com")

    /// Minimal page hosting the embed iframe edge-to-edge.
    public static func embedHTML(videoID: String) -> String {
        """
        <!doctype html><html><head>
        <meta name="viewport" content="initial-scale=1, maximum-scale=1">
        <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}
        iframe{position:absolute;inset:0;width:100%;height:100%;border:0}</style>
        </head><body>
        <iframe src="\(embedURL(videoID: videoID)?.absoluteString ?? "")"
          allow="autoplay; encrypted-media; picture-in-picture" allowfullscreen></iframe>
        </body></html>
        """
    }

    private static func isYouTubeHost(_ host: String) -> Bool {
        host == "youtube.com"
            || host.hasSuffix(".youtube.com")
            || host == "youtube-nocookie.com"
            || host.hasSuffix(".youtube-nocookie.com")
    }

    /// Video IDs are exactly 11 characters of `[A-Za-z0-9_-]`; anything else
    /// (handles, "results", empty) is rejected rather than guessed at.
    private static func validated(_ candidate: String?) -> String? {
        guard let candidate, candidate.count == 11,
              candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
        else { return nil }
        return candidate
    }
}
