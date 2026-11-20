import SwiftUI
import ADFPreparation

/// `mediaGroup`: a horizontally scrolling strip of fixed-height thumbnails.
///
/// The strip reports its own visibility in the document to the media
/// coordinator (`mediaGroupVisibility`): a thumbnail's visibility feed only
/// sees this strip's horizontal scroll view, so a thumbnail loads only while
/// it is inside the strip's viewport *and* the strip is on screen.
struct MediaStripView: View {
    let items: [PreparedMedia]

    @Environment(\.adfTheme) private var theme
    @ScaledMetric(relativeTo: .body) private var stripHeight: CGFloat = 120

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: theme.spacing) {
                ForEach(items, id: \.id) { item in
                    MediaThumbnailView(media: item, height: stripHeight, group: groupID)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .mediaGroupVisibility(group: groupID)
        .frame(height: stripHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The strip's id for the coordinator: derived from its first item's
    /// structural id, which is unique in the document.
    private var groupID: String {
        "mediaGroup:" + (items.first?.id ?? "")
    }
}

/// One strip thumbnail: fixed height, width from the intrinsic aspect ratio
/// (square fallback), coordinator-fed load (`mediaAttachment`, its strip as
/// the group), tap-to-lightbox.
struct MediaThumbnailView: View {
    let media: PreparedMedia
    let height: CGFloat
    /// The strip's id (`MediaStripView.groupID`).
    let group: String

    @Environment(\.adfTheme) private var theme
    @Environment(\.adfMedia) private var coordinator

    @State private var showsLightbox = false

    var body: some View {
        // Reads only this thumbnail's entry: a landing redraws only the
        // views showing the same key.
        let entry = self.entry
        ZStack {
            RoundedRectangle(cornerRadius: theme.containerCornerRadius)
                .fill(Color.gray.opacity(0.1))
            if let loadedImage = entry?.image {
                loadedImage
                    .resizable()
                    .scaledToFill()
            } else if entry?.failed == true {
                VStack(spacing: theme.spacing * 0.5) {
                    Image(systemName: "doc")
                    Text(media.attrs.alt ?? "Attachment")
                        .font(.caption2)
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .padding(theme.spacing * 0.5)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: thumbnailWidth, height: height)
        .clipShape(RoundedRectangle(cornerRadius: theme.containerCornerRadius))
        .mediaAttachment(viewer: media.id, key: loadKey, attrs: media.attrs, group: group)
        .onTapGesture {
            if entry?.image != nil {
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

    /// The source at the thumbnail's size (known without measuring).
    private var loadKey: MediaLoadKey? {
        MediaLoadKey(source: media.attrs.source, size: CGSize(width: thumbnailWidth, height: height))
    }

    /// This thumbnail's entry, or `nil` without a coordinator (no provider):
    /// the placeholder.
    private var entry: MediaEntry? {
        guard let coordinator, let loadKey else { return nil }
        return coordinator.entry(for: loadKey)
    }
}
