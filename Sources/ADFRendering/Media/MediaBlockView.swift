import SwiftUI
import ADFModel
import ADFPreparation

/// One block-level media item (`mediaSingle`, or a stray `media`).
///
/// The aspect-ratio box is reserved from the ADF `width`/`height` attrs
/// *before* any bytes load, so there is zero layout shift and the lazy stack
/// gets correct estimated heights. The fetch is gated on scroll visibility
/// (`.onScrollVisibilityChange` on iOS 18+, `.onAppear` fallback below) and
/// runs through the injected `ADFMediaProvider` inside `.task(id:)`, so
/// scrolling away cancels in-flight loads. Tapping a loaded image opens the
/// zoomable lightbox; a `link` mark on the media routes the tap to the URL
/// instead.
struct MediaBlockView: View {
    let media: PreparedMedia

    @Environment(\.adfTheme) private var theme
    @Environment(\.adfMediaProvider) private var provider
    @Environment(\.openURL) private var openURL

    @State private var loadedImage: Image?
    @State private var loadFailed = false
    @State private var isVisible = false
    @State private var boxSize = CGSize.zero
    @State private var containerWidth = CGFloat.zero
    @State private var showsLightbox = false

    var body: some View {
        VStack(alignment: stackAlignment, spacing: theme.spacing * 0.75) {
            mediaBox
            if let caption = media.caption, !caption.isEmpty {
                SegmentedTextView(segments: caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            containerWidth = width
        }
        .lightbox(isPresented: $showsLightbox, media: media)
    }

    // MARK: - Box

    private var mediaBox: some View {
        boxContent
            .modifier(MediaAspectBox(ratio: aspectRatio))
            .frame(width: explicitWidth)
            .frame(maxWidth: naturalWidthCap)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                if let borderHex = media.borderHex, let color = Color(adfHex: borderHex) {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(color, lineWidth: 2)
                }
            }
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { size in
                boxSize = size
            }
            .modifier(ScrollVisibilityGate(isVisible: $isVisible))
            .task(id: fetchKey) { await loadIfNeeded() }
            .onTapGesture { handleTap() }
            .accessibilityLabel(media.attrs.alt ?? "Image")
            .accessibilityAddTraits(.isImage)
    }

    private var boxContent: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.1))
            if let loadedImage {
                loadedImage
                    .resizable()
                    .scaledToFill()
            } else if loadFailed {
                // Non-image attachments (and failed loads) render as a
                // document chip: icon + name.
                VStack(spacing: 4) {
                    Image(systemName: "doc")
                        .imageScale(.large)
                    Text(media.attrs.alt ?? "Attachment")
                        .font(.footnote)
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .padding(theme.spacing)
            } else {
                Image(systemName: "photo")
                    .imageScale(.large)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Geometry

    /// Intrinsic aspect ratio from the ADF attrs, when both dimensions exist.
    private var aspectRatio: CGFloat? {
        guard let width = media.attrs.width, let height = media.attrs.height,
              width > 0, height > 0 else { return nil }
        return CGFloat(width / height)
    }

    /// Width from the `mediaSingle` attrs: exact pixels (capped to the
    /// container) or a fraction of the measured container width.
    private var explicitWidth: CGFloat? {
        if let pixel = media.pixelWidth {
            let width = CGFloat(pixel)
            return containerWidth > 0 ? min(width, containerWidth) : width
        }
        if let fraction = media.widthFraction, containerWidth > 0 {
            return containerWidth * CGFloat(fraction)
        }
        return nil
    }

    /// Without an explicit width, never upscale past the intrinsic pixel
    /// width from the attrs.
    private var naturalWidthCap: CGFloat? {
        guard explicitWidth == nil else { return nil }
        return media.attrs.width.map { CGFloat($0) }
    }

    private var frameAlignment: Alignment {
        switch media.layout {
        case .wrapLeft, .alignStart: return .leading
        case .wrapRight, .alignEnd: return .trailing
        case .center, .wide, .fullWidth: return .center
        }
    }

    private var stackAlignment: HorizontalAlignment {
        switch media.layout {
        case .wrapLeft, .alignStart: return .leading
        case .wrapRight, .alignEnd: return .trailing
        case .center, .wide, .fullWidth: return .center
        }
    }

    // MARK: - Loading

    private struct FetchKey: Equatable {
        var isVisible: Bool
        var width: CGFloat
        var height: CGFloat
    }

    /// `.task(id:)` restarts (cancelling the previous fetch) when visibility
    /// flips or the reserved box settles on a new size.
    private var fetchKey: FetchKey {
        FetchKey(
            isVisible: isVisible,
            width: boxSize.width.rounded(),
            height: boxSize.height.rounded()
        )
    }

    private func loadIfNeeded() async {
        guard isVisible, loadedImage == nil, !loadFailed,
              boxSize.width > 0, boxSize.height > 0,
              let provider else { return }
        do {
            loadedImage = try await provider.image(for: media.attrs, targetSize: boxSize)
        } catch is CancellationError {
            // Scrolled away mid-fetch; the next visibility change retries.
        } catch {
            if !Task.isCancelled {
                loadFailed = true
            }
        }
    }

    private func handleTap() {
        if let href = media.linkHref, let url = URL(string: href) {
            openURL(url)
        } else if loadedImage != nil {
            showsLightbox = true
        }
    }
}

/// Reserves the media box geometry before any bytes load: exact aspect ratio
/// when the attrs carry dimensions, a fixed-height band otherwise.
struct MediaAspectBox: ViewModifier {
    let ratio: CGFloat?

    func body(content: Content) -> some View {
        if let ratio {
            content.aspectRatio(ratio, contentMode: .fit)
        } else {
            content.frame(height: 220)
        }
    }
}

/// Flips `isVisible` as the view enters/leaves the visible scroll region:
/// `.onScrollVisibilityChange` (iOS 18 / macOS 15) with a low threshold so
/// fetches start as items approach; `.onAppear`/`.onDisappear` on the lazy
/// row is the iOS 17 fallback.
struct ScrollVisibilityGate: ViewModifier {
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

extension View {
    /// Presents the zoomable lightbox: full-screen on iOS, a sheet on macOS.
    @ViewBuilder
    func lightbox(isPresented: Binding<Bool>, media: PreparedMedia) -> some View {
        #if os(macOS)
        sheet(isPresented: isPresented) {
            LightboxView(media: media)
                .frame(minWidth: 560, minHeight: 420)
        }
        #else
        fullScreenCover(isPresented: isPresented) {
            LightboxView(media: media)
        }
        #endif
    }
}
