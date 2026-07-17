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
struct YouTubePlayerView: View {
    let videoID: String
    let cornerRadius: CGFloat

    /// Dies when the row leaves the render region — scroll-away tears the
    /// player down and playback stops, matching the reader's "off-screen
    /// rows drop expensive state" rule.
    @State private var isPlaying = false
    @State private var thumbnail: Image?
    @State private var isVisible = false

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
        .modifier(VisibilityGate(isVisible: $isVisible))
        .task(id: fetchKey) { await loadThumbnailIfNeeded() }
    }

    private var facade: some View {
        Button {
            isPlaying = true
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
            // Off-screen rows drop decoded image state; re-entry reloads
            // from the URL cache.
            thumbnail = nil
            return
        }
        guard thumbnail == nil, !isPlaying,
              let url = YouTubeURL.thumbnailURL(videoID: videoID) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            #if canImport(UIKit)
            if let image = UIImage(data: data) {
                thumbnail = Image(uiImage: image)
            }
            #elseif canImport(AppKit)
            if let image = NSImage(data: data) {
                thumbnail = Image(nsImage: image)
            }
            #endif
        } catch {
            // Facade stays a black box with a play button — still usable.
        }
    }
}

/// Flips `isVisible` as the block enters/leaves the visible scroll region —
/// same shape as the media views' gate: `.onScrollVisibilityChange` where
/// available, appear/disappear on the lazy row below iOS 18 / macOS 15.
private struct VisibilityGate: ViewModifier {
    @Binding var isVisible: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content.onScrollVisibilityChange(threshold: 0.01) { visible in
                isVisible = visible
            }
        } else {
            content
                .onAppear { isVisible = true }
                .onDisappear { isVisible = false }
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
}
#endif

#endif
