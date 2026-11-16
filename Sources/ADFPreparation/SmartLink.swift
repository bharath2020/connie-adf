import Foundation

/// The identity a smart link is looked up by: its canonical URL, with the
/// scheme and host lowercased and the fragment removed, everything else as
/// authored. Runs with the same key share one lookup and one displayed
/// stage, wherever they sit in the document (`docs/Architecture-Decisions.md`
/// §22).
///
/// Package-internal: preparation stamps it, the renderer resolves it, and a
/// host never sees it (the resolver receives `url`).
package struct SmartLinkKey: Hashable, Sendable, CustomStringConvertible {
    /// The canonical URL, the one the host's resolver is asked about.
    package let url: URL

    /// The key of a URL string that qualifies as a smart link
    /// (`SmartLinkQualification.key(for:)`), or `nil`.
    package init?(_ urlString: String) {
        guard let key = SmartLinkQualification.key(for: urlString) else { return nil }
        self = key
    }

    init(canonicalURL: URL) {
        self.url = canonicalURL
    }

    package var description: String { url.absoluteString }
}

/// The smart link one prepared text run shows: its key, and its occurrence
/// within the run's owner (paragraph, heading, list leader or caption),
/// numbered from 0 in document order. The occurrence keeps two adjacent
/// runs of the same URL distinct — equal attribute values would merge
/// them into one run — so each is substituted on its own.
package struct SmartLinkRun: Hashable, Sendable {
    package let key: SmartLinkKey
    package let occurrence: Int

    package init(key: SmartLinkKey, occurrence: Int) {
        self.key = key
        self.occurrence = occurrence
    }
}

/// Which links are smart-link candidates (design §1).
///
/// A run qualifies when it is a `link` mark or an `inlineCard`, its URL is
/// `http`/`https` on a host ending in `.atlassian.net` (lowercased, one
/// trailing dot ignored, never `atlassian.net` itself or a lookalike such as
/// `evilatlassian.net` or `atlassian.net.evil.com`), and, for a link mark,
/// the link is bare: its text is its href (`isBare`). Labelled links keep
/// the author's words. Qualification is by host only: the host's resolver
/// decides what it can resolve and throws for the rest.
package enum SmartLinkQualification {
    /// The key of `urlString` when it is an `http`/`https` URL on an
    /// `*.atlassian.net` host, else `nil`. Cheap rejection first: no URL is
    /// parsed unless the string mentions `atlassian.net`.
    package static func key(for urlString: String) -> SmartLinkKey? {
        guard urlString.range(of: "atlassian.net", options: .caseInsensitive) != nil,
              var components = URLComponents(string: urlString),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), isAtlassianHost(host) else {
            return nil
        }
        components.scheme = scheme
        components.host = host
        components.fragment = nil
        guard let url = components.url else { return nil }
        return SmartLinkKey(canonicalURL: url)
    }

    /// Whether a lowercased host is a tenant of `atlassian.net`: it ends in
    /// `.atlassian.net` (after dropping one trailing dot) with a non-empty
    /// label before it.
    package static func isAtlassianHost(_ host: String) -> Bool {
        let suffix = ".atlassian.net"
        let bare = host.hasSuffix(".") ? String(host.dropLast()) : host
        return bare.hasSuffix(suffix) && bare.count > suffix.count
    }

    /// Whether a link mark is bare: its text equals its href once both are
    /// normalised — whitespace trimmed, a leading `http://` or `https://`
    /// dropped, one trailing `/` dropped, the host compared without case
    /// and the rest exactly.
    package static func isBare(text: String, href: String) -> Bool {
        let a = normalised(text), b = normalised(href)
        return a.host == b.host && a.rest == b.rest
    }

    private static func normalised(_ string: String) -> (host: String, rest: Substring) {
        var value = Substring(string.trimmingCharacters(in: .whitespacesAndNewlines))
        for scheme in ["https://", "http://"] where value.lowercased().hasPrefix(scheme) {
            value = value.dropFirst(scheme.count)
            break
        }
        if value.hasSuffix("/") { value = value.dropLast() }
        let slash = value.firstIndex(of: "/") ?? value.endIndex
        return (value[..<slash].lowercased(), value[slash...])
    }
}
