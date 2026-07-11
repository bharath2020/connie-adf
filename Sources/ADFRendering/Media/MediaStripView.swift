import SwiftUI
import ADFPreparation

/// `mediaGroup`: a horizontally scrolling strip of fixed-height thumbnails.
struct MediaStripView: View {
    let items: [PreparedMedia]

    @Environment(\.adfTheme) private var theme
    @ScaledMetric(relativeTo: .body) private var stripHeight: CGFloat = 120

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: theme.spacing) {
                ForEach(items, id: \.id) { item in
                    MediaThumbnailView(media: item, height: stripHeight)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .frame(height: stripHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One strip thumbnail: fixed height, width from the intrinsic aspect ratio
/// (square fallback), visibility-gated fetch, tap-to-lightbox.
struct MediaThumbnailView: View {
    let media: PreparedMedia
    let height: CGFloat

    @Environment(\.adfMediaProvider) private var provider

    @State private var loadedImage: Image?
    @State private var loadFailed = false
    @State private var isVisible = false
    @State private var showsLightbox = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.1))
            if let loadedImage {
                loadedImage
                    .resizable()
                    .scaledToFill()
            } else if loadFailed {
                VStack(spacing: 4) {
                    Image(systemName: "doc")
                    Text(media.attrs.alt ?? "Attachment")
                        .font(.caption2)
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .padding(4)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: thumbnailWidth, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .modifier(ScrollVisibilityGate(isVisible: $isVisible))
        .task(id: isVisible) { await loadIfNeeded() }
        .onTapGesture {
            if loadedImage != nil {
                showsLightbox = true
            }
        }
        .accessibilityLabel(media.attrs.alt ?? "Image")
        .accessibilityAddTraits(.isImage)
        .lightbox(isPresented: $showsLightbox, media: media)
    }

    private var thumbnailWidth: CGFloat {
        guard let width = media.attrs.width, let intrinsicHeight = media.attrs.height,
              width > 0, intrinsicHeight > 0 else { return height }
        return height * CGFloat(width / intrinsicHeight)
    }

    private func loadIfNeeded() async {
        guard isVisible else {
            // §6.5: off-screen thumbnails drop their decoded image, holding
            // only the ref (see MediaBlockView.loadIfNeeded).
            loadedImage = nil
            return
        }
        guard loadedImage == nil, !loadFailed, let provider else { return }
        do {
            loadedImage = try await provider.image(
                for: media.attrs,
                targetSize: CGSize(width: thumbnailWidth, height: height)
            )
        } catch is CancellationError {
            // Scrolled away mid-fetch; retried on the next visibility change.
        } catch {
            if !Task.isCancelled {
                loadFailed = true
            }
        }
    }
}
