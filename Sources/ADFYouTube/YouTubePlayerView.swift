import SwiftUI
#if canImport(WebKit)
import WebKit
#endif

/// Lite-embed video block: a static facade (thumbnail + play button) that
/// swaps in a `WKWebView` running YouTube's privacy-enhanced embed page only
/// when the reader taps play.
///
/// The facade discipline is what keeps the scroll gates green: rows must be
/// cheap to materialize, so no web view (and no network fetch) exists until
/// the block is visible (thumbnail) or tapped (player). The 16:9 box itself
/// is drawn by the library from the claim's declared sizing — this view
/// fills whatever box it is proposed, and the facade→player swap changes
/// nothing about the row's geometry.
///
/// Player lifetime is coordinator-owned, not row-owned: at most one player
/// exists per document (activating another block returns this one to its
/// facade), and leaving the visible viewport deactivates — the web view is
/// dismantled at viewport exit, not at the much later render-region exit
/// the lazy stack uses for row teardown.
struct YouTubePlayerView: View {
    let videoID: String
    /// The claimed block's stable ID — the playback coordinator's key.
    let blockID: String
    let playback: YouTubePlaybackCoordinator
    let cornerRadius: CGFloat

    @State private var thumbnail: Image?
    @State private var isVisible = false
    @State private var visibilityCoalescer = VisibilityCoalescer()

    private var isPlaying: Bool {
        playback.activeBlockID == blockID
    }

    var body: some View {
        ZStack {
            if isPlaying {
                #if canImport(WebKit)
                EmbedWebView(videoID: videoID)
                #endif
            } else {
                facade
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .modifier(VisibilityGate(isVisible: $isVisible, coalescer: visibilityCoalescer))
        .task(id: fetchKey) { await loadThumbnailIfNeeded() }
        .onChange(of: isVisible) { _, visible in
            // Fully off the visible viewport ⇒ stop playback and dismantle
            // the web view now (§6: scroll-away stops playback) — the row
            // itself stays materialized until the render-region exit.
            if !visible {
                playback.deactivate(blockID)
            }
        }
        .onDisappear {
            // Render-region exit destroys the row; release the coordinator
            // slot so a stale ID can't block the next activation.
            playback.deactivate(blockID)
        }
    }

    private var facade: some View {
        Button {
            playback.activate(blockID)
        } label: {
            ZStack {
                // The overlay is bounded to the rectangle's size, so the
                // fill-scaled thumbnail can never inflate the box layout.
                Rectangle()
                    .fill(.black)
                    .overlay {
                        if let thumbnail {
                            thumbnail
                                .resizable()
                                .scaledToFill()
                        }
                    }
                    .clipped()
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 56))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .red)
                    .shadow(radius: 8)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel("Play YouTube video")
    }

    // MARK: Thumbnail

    private struct FetchKey: Equatable {
        var isVisible: Bool
        var videoID: String
    }

    private var fetchKey: FetchKey {
        FetchKey(isVisible: isVisible, videoID: videoID)
    }

    private func loadThumbnailIfNeeded() async {
        guard isVisible else {
            // Off-screen rows drop decoded image state (§6.5); re-entry
            // repaints from the decoded cache below, without a re-decode.
            thumbnail = nil
            return
        }
        guard thumbnail == nil, !isPlaying else { return }
        if let cached = YouTubeThumbnailCache.image(for: videoID) {
            thumbnail = Self.image(from: cached)
            return
        }
        guard let url = YouTubeURL.thumbnailURL(videoID: videoID) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let decoded = await Self.decodedImage(from: data) {
                YouTubeThumbnailCache.store(decoded, for: videoID)
                thumbnail = Self.image(from: decoded)
            }
        } catch {
            // Facade stays a black box with a play button — still usable.
        }
    }

    private static func image(from platformImage: YouTubeThumbnailCache.PlatformImage) -> Image {
        #if canImport(UIKit)
        Image(uiImage: platformImage)
        #elseif canImport(AppKit)
        Image(nsImage: platformImage)
        #endif
    }

    /// Fully decoded, ready-to-draw bitmap — decoding happens here, in the
    /// async fetch path, never lazily at first draw during a scroll frame.
    private static func decodedImage(from data: Data) async -> YouTubeThumbnailCache.PlatformImage? {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        return await image.byPreparingForDisplay() ?? image
        #elseif canImport(AppKit)
        return NSImage(data: data)
        #endif
    }
}

/// Flips `isVisible` as the block enters/leaves the visible scroll region —
/// `.onScrollVisibilityChange` where available, appear/disappear on the lazy
/// row below iOS 18 / macOS 15. All writes route through the deferred,
/// latest-wins `VisibilityCoalescer` — see its doc for why both properties
/// are load-bearing (snapshot-commit livelock; stale-commit race).
private struct VisibilityGate: ViewModifier {
    @Binding var isVisible: Bool
    let coalescer: VisibilityCoalescer

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content.onScrollVisibilityChange(threshold: 0.01) { visible in
                deferredSet(visible)
            }
        } else {
            content
                .onAppear { deferredSet(true) }
                .onDisappear { deferredSet(false) }
        }
    }

    private func deferredSet(_ visible: Bool) {
        coalescer.set(visible) { desired in
            if isVisible != desired {
                isVisible = desired
            }
        }
    }
}

#if canImport(WebKit)

#if canImport(UIKit)
import UIKit

/// Inline YouTube embed. Created only after an explicit play tap — never
/// during scroll — so its construction cost stays off the row path.
private struct EmbedWebView: UIViewRepresentable {
    let videoID: String

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: Self.configuration())
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        // An iframe page with a baseURL, not a bare URL request: YouTube
        // requires a referer for embedded playback (Error 153 without one).
        webView.loadHTMLString(
            YouTubeURL.embedHTML(videoID: videoID),
            baseURL: YouTubeURL.embedPageBaseURL
        )
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: ()) {
        // Stop media and networking immediately; the process teardown then
        // isn't at the mercy of WebKit's own cleanup timing.
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    static func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        return configuration
    }
}

#elseif canImport(AppKit)
import AppKit

private struct EmbedWebView: NSViewRepresentable {
    let videoID: String

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString(
            YouTubeURL.embedHTML(videoID: videoID),
            baseURL: YouTubeURL.embedPageBaseURL
        )
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    static func dismantleNSView(_ webView: WKWebView, coordinator: ()) {
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }
}
#endif

#endif
