import Foundation
import os
import ADFRendering

/// Offline smart-link titles for the demo: the stand-in for a Confluence or
/// Jira lookup. No network. Every answer comes from the URL itself:
///
/// | URL | Title | Icon |
/// | --- | --- | --- |
/// | `…/pages/<id>/Q3+Roadmap` | `Q3 Roadmap` | `.page` |
/// | `…/blog/<yyyy>/<mm>/<dd>/<id>/Release+Notes` | `Release Notes` | `.blogPost` |
/// | `…/browse/MOB-1402` | `MOB-1402 <made-up summary>` | `.issue` |
/// | `…/wiki/spaces/ENG[/…]` | `ENG space` | `.generic` |
/// | anything else | the host | `.generic` |
///
/// Each lookup waits `configuration.delay` with `Task.sleep`, so a lookup
/// the library cancels (its row left the screen) ends at once with
/// `CancellationError`. A share of URLs (`configuration.failureRate`) fails
/// with `.unauthorized` or `.notFound`; which ones is fixed by a stable hash
/// of the URL, so the same links fail on every launch and in every
/// document. Nothing is cached: the library dedups per document, and a demo
/// that reopens a document should show the lookups again.
///
/// The resolver counts what it sees — calls, cancellations, lookups in
/// flight, resolved, failed — for About This Build. These are the host's
/// view; the library's own coordinator counters are separate.
final class MockSmartLinkResolver: ADFSmartLinkResolver {
    struct Configuration: Sendable, Equatable {
        var delay: Duration
        /// 0…1: the share of URLs whose lookup throws.
        var failureRate: Double

        static let `default` = Configuration(delay: .milliseconds(800), failureRate: 0.1)

        /// One line for About This Build, e.g. `Delay 0.8 s · failure rate 10 %`.
        var summary: String {
            let (wholeSeconds, attoseconds) = delay.components
            let seconds = (Double(wholeSeconds) + Double(attoseconds) / 1e18)
                .formatted(.number.precision(.fractionLength(0 ... 3)))
            let percent = (failureRate * 100).formatted(.number.precision(.fractionLength(0 ... 1)))
            return "Delay \(seconds) s · failure rate \(percent) %"
        }
    }

    /// Since launch, across every document.
    struct Counts: Sendable, Equatable {
        var calls = 0
        var cancelled = 0
        var inFlight = 0
        var resolved = 0
        var failed = 0
    }

    let configuration: Configuration
    private let counts = OSAllocatedUnfairLock(initialState: Counts())

    init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    /// A consistent copy of the counters (one lock acquisition).
    var snapshot: Counts {
        counts.withLock { $0 }
    }

    func resolve(_ url: URL) async throws -> ADFSmartLinkMetadata {
        counts.withLock {
            $0.calls += 1
            $0.inFlight += 1
        }
        do {
            if configuration.delay > .zero {
                try await Task.sleep(for: configuration.delay)
            }
            try Task.checkCancellation()
        } catch {
            counts.withLock {
                $0.inFlight -= 1
                $0.cancelled += 1
            }
            throw error
        }
        switch Self.outcome(for: url, failureRate: configuration.failureRate) {
        case .success(let metadata):
            counts.withLock {
                $0.inFlight -= 1
                $0.resolved += 1
            }
            return metadata
        case .failure(let error):
            counts.withLock {
                $0.inFlight -= 1
                $0.failed += 1
            }
            throw error
        }
    }

    // MARK: - Deterministic answers

    /// What a lookup of `url` returns once its delay has passed. Pure and
    /// stable across launches: the failure draw is FNV-1a over `stableKey`.
    static func outcome(for url: URL, failureRate: Double) -> Result<ADFSmartLinkMetadata, ADFSmartLinkError> {
        let hash = fnv1a(stableKey(url))
        let draw = Double(hash % 10_000) / 10_000
        if draw < min(max(failureRate, 0), 1) {
            return .failure((hash / 10_000) % 2 == 0 ? .unauthorized : .notFound)
        }
        return .success(metadata(for: url))
    }

    /// Lower-case host without a trailing dot, then the encoded path and
    /// query. Scheme and fragment are left out, so `http`/`https` and
    /// `#section` variants of one page share one outcome.
    static func stableKey(_ url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var host = (components?.host ?? url.host ?? "").lowercased()
        while host.hasSuffix(".") {
            host.removeLast()
        }
        let path = components?.percentEncodedPath ?? url.path
        let query = components?.percentEncodedQuery.map { "?" + $0 } ?? ""
        return host + path + query
    }

    static func metadata(for url: URL) -> ADFSmartLinkMetadata {
        // `pathComponents` is percent-decoded; Confluence slugs use `+`
        // for spaces, which decoding leaves alone.
        let parts = url.pathComponents.filter { $0 != "/" }
        if let index = parts.firstIndex(of: "browse"), index + 1 < parts.count {
            let key = parts[index + 1]
            return ADFSmartLinkMetadata(title: "\(key) \(issueSummary(for: key))", icon: .issue)
        }
        if let index = parts.firstIndex(of: "pages") {
            let title: String
            if index + 2 < parts.count {
                title = slugTitle(parts[index + 2])
            } else if index + 1 < parts.count {
                title = "Page \(parts[index + 1])"
            } else {
                title = "Untitled page"
            }
            return ADFSmartLinkMetadata(title: title, icon: .page)
        }
        if let index = parts.firstIndex(of: "blog") {
            let last = parts[(index + 1)...].last
            let title = last.flatMap { Int($0) == nil ? slugTitle($0) : nil } ?? "Blog post"
            return ADFSmartLinkMetadata(title: title, icon: .blogPost)
        }
        if let index = parts.firstIndex(of: "spaces"), index + 1 < parts.count {
            return ADFSmartLinkMetadata(title: "\(parts[index + 1]) space", icon: .generic)
        }
        return ADFSmartLinkMetadata(title: url.host ?? url.absoluteString, icon: .generic)
    }

    private static func slugTitle(_ slug: String) -> String {
        let title = slug.replacingOccurrences(of: "+", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? "Untitled" : title
    }

    private static let issueSummaries = [
        "Crash on launch when offline",
        "Search highlights the wrong range",
        "Table header loses its background in dark mode",
        "Add VoiceOver labels to task checkboxes",
        "Speed up first paint for long pages",
        "Code block scrolls past its last column",
        "Expand state resets after rotation",
        "Inline card shows the raw URL",
        "Links in lists ignore the text colour",
        "Release 2.5 sign-off",
    ]

    private static func issueSummary(for key: String) -> String {
        issueSummaries[Int(fnv1a(key) % UInt64(issueSummaries.count))]
    }

    /// FNV-1a: stable across launches (unlike `Hashable`'s seeded hasher).
    private static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

extension MockSmartLinkResolver {
    /// The one resolver every reader in this process uses, built from this
    /// launch's arguments (`-smartLinks`, `-smartLinkDelay`,
    /// `-smartLinkFailureRate`; see `LaunchOptions`); `nil` under
    /// `-smartLinks off`. Read from the process arguments rather than a
    /// reader's `LaunchOptions` because readers opened from the space list
    /// or a beam get `.none`. One instance, so About This Build's counts
    /// cover the whole launch and every `ADFDocumentView` body pass sees
    /// the same resolver.
    static let shared: MockSmartLinkResolver? = make(options: LaunchOptions())

    static func make(options: LaunchOptions) -> MockSmartLinkResolver? {
        guard options.smartLinksEnabled else { return nil }
        return MockSmartLinkResolver(configuration: Configuration(
            delay: .milliseconds(Int((options.smartLinkDelay * 1_000).rounded())),
            failureRate: options.smartLinkFailureRate
        ))
    }
}
