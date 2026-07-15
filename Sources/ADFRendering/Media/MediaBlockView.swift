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
                SegmentedTextView(segments: caption, ownerID: media.id)
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
            .frame(width: fractionWidth)
            .frame(maxWidth: maxWidthCap)
            .clipShape(RoundedRectangle(cornerRadius: theme.containerCornerRadius))
            .overlay {
                if let borderHex = media.borderHex, let color = Color(adfHex: borderHex) {
                    RoundedRectangle(cornerRadius: theme.containerCornerRadius)
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
            RoundedRectangle(cornerRadius: theme.containerCornerRadius)
                .fill(Color.gray.opacity(0.1))
            if let loadedImage {
                loadedImage
                    .resizable()
                    .scaledToFill()
            } else if loadFailed {
                // Non-image attachments (and failed loads) render as a
                // document chip: icon + name.
                VStack(spacing: theme.spacing * 0.5) {
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

    /// Fixed width for percentage `mediaSingle` attrs: a fraction of the
    /// measured container width (a fraction can never exceed the container,
    /// so it cannot inflate the measurement it derives from).
    private var fractionWidth: CGFloat? {
        guard media.pixelWidth == nil, let fraction = media.widthFraction,
              containerWidth > 0 else { return nil }
        return containerWidth * CGFloat(fraction)
    }

    /// Width cap for the box: an exact pixel width, or (without an explicit
    /// width) the intrinsic pixel width from the attrs so the media never
    /// upscales. Expressed as `maxWidth` — not a fixed width — so the layout
    /// proposal clamps oversized media to the viewport. (A fixed `width:`
    /// bypasses the proposal and, worse, inflates the measured container
    /// width it would need for clamping, so a 400 pt image on a 370 pt
    /// column ran off the screen edge.)
    private var maxWidthCap: CGFloat? {
        if let pixel = media.pixelWidth {
            return CGFloat(pixel)
        }
        guard media.widthFraction == nil else { return nil }
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
        guard isVisible else {
            // §6.5: off-screen rows drop their decoded image state, holding
            // only the ref — lazy stacks keep rows alive, so without this
            // eviction every bitmap ever loaded would stay resident.
            // Re-approaching reloads (typically from the provider's cache).
            loadedImage = nil
            return
        }
        guard loadedImage == nil, !loadFailed,
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
/// when the attrs carry dimensions, a band otherwise whose height scales
/// with Dynamic Type (a dimensionless attachment renders as a document chip,
/// so its band should track the chip's text size).
struct MediaAspectBox: ViewModifier {
    let ratio: CGFloat?

    @ScaledMetric(relativeTo: .body) private var fallbackHeight: CGFloat = 220

    func body(content: Content) -> some View {
        if let ratio {
            content.aspectRatio(ratio, contentMode: .fit)
        } else {
            content.frame(height: fallbackHeight)
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
