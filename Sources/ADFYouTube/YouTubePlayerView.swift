import SwiftUI
#if canImport(WebKit)
import WebKit
#endif

/// Lite-embed video block: a static facade (thumbnail + play button) that
/// swaps in a `WKWebView` running YouTube's privacy-enhanced embed page only
/// when the reader taps play.
///
/// The facade discipline is what keeps the scroll gates green: rows must be
/// cheap to materialize, so no web view exists until the reader taps play.
/// The 16:9 box itself is drawn by the library from the claim's declared
/// sizing — this view fills whatever box it is proposed, and the
/// facade→player swap changes nothing about the row's geometry.
///
/// **Scroll visibility writes NO view state — by hard-won design.** Two
/// livelocks came from binding `@State` to `onScrollVisibilityChange` here:
/// an inline write queued transactions into a scene-snapshot commit that
/// then never converged, and a deferred write turned boundary oscillation
/// into an endless every-runloop-turn relayout (each commit shifts lazy
/// placement, the binder fires with the opposite value, the deferred write
/// schedules the next turn — 100 % CPU across commits). So:
/// - The thumbnail's lifetime is the ROW's lifetime (`.task` starts on
///   materialization, dies on render-region exit like every block's state);
///   thumbnails are ~20 KB and the decoded cache makes re-entry free, so
///   viewport-level gating buys nothing.
/// - Visibility feeds ONLY player teardown, via a callback that calls
///   `deactivate` — idempotent after the first call (the coordinator writes
///   observable state only while this block is the active player), so it
///   can never sustain a feedback loop, and it is deferred off the layout
///   transaction so it can never extend a snapshot commit.
///
/// Player lifetime is coordinator-owned, not row-owned: at most one player
/// exists per document (activating another block returns this one to its
/// facade), leaving the visible viewport deactivates, and render-region
/// exit deactivates on teardown.
struct YouTubePlayerView: View {
    let videoID: String
    /// The claimed block's stable ID — the playback coordinator's key.
    let blockID: String
    let playback: YouTubePlaybackCoordinator
    let cornerRadius: CGFloat

    @State private var thumbnail: Image?

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
        .modifier(PlayerViewportGuard(blockID: blockID, playback: playback))
        .task { await loadThumbnailIfNeeded() }
        .onDisappear {
            // Render-region exit destroys the row; release the coordinator
            // slot so a stale ID can't block the next activation. (Also the
            // pre-iOS 18 teardown path, where no visibility feed exists.)
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

    /// Runs once per row materialization; state (and the decoded image ref)
    /// dies with the row at render-region exit, like every block's state.
    private func loadThumbnailIfNeeded() async {
        guard thumbnail == nil, !isPlaying else { return }
        if let cached = YouTubeThumbnailCache.image(for: videoID) {
            thumbnail = Self.image(from: cached)
            return
        }
        guard let url = YouTubeURL.thumbnailURL(videoID: videoID) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard !Task.isCancelled else { return }
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

/// Tears the active player down when its block leaves the visible viewport
/// (§6: scroll-away stops playback) — without binding any view state to the
/// visibility feed. The callback only ever calls `deactivate`, deferred off
/// the current transaction: a no-op unless this block IS the active player,
/// so at most ONE observable write follows an activation and the feed can
/// never drive a relayout loop. Below iOS 18 / macOS 15 there is no
/// visibility feed; teardown happens at render-region exit (`onDisappear`
/// in the host view).
private struct PlayerViewportGuard: ViewModifier {
    let blockID: String
    let playback: YouTubePlaybackCoordinator

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content.onScrollVisibilityChange(threshold: 0.01) { visible in
                if !visible {
                    let playback = playback
                    let blockID = blockID
                    Task { @MainActor in
                        playback.deactivate(blockID)
                    }
                }
            }
        } else {
            content
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
