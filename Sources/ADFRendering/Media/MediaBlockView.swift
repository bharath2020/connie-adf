import SwiftUI
import ADFModel
import ADFPreparation

/// One block-level media item (`mediaSingle`, or a stray `media`).
///
/// The aspect-ratio box is reserved from the ADF `width`/`height` attrs
/// *before* any bytes load, so there is zero layout shift and the lazy stack
/// gets correct estimated heights. Loading belongs to the document's
/// `MediaCoordinator` (ADR §24): the box attaches as a viewer with its load
/// key (source + measured box size) and its own scroll visibility
/// (`mediaAttachment`), and draws the key's `MediaEntry` — the coordinator
/// dwells, caps concurrent loads, cancels on scroll-away and releases the
/// image once nothing shows it. No `@State` is bound to visibility. Without a
/// provider (no coordinator) the box keeps its placeholder. Tapping a loaded
/// image opens the zoomable lightbox; a `link` mark on the media routes the
/// tap to the URL instead.
struct MediaBlockView: View {
    let media: PreparedMedia

    @Environment(\.adfTheme) private var theme
    @Environment(\.adfMedia) private var coordinator
    @Environment(\.openURL) private var openURL

    @State private var boxSize = CGSize.zero
    @State private var containerWidth = CGFloat.zero
    @State private var showsLightbox = false

    var body: some View {
        VStack(alignment: stackAlignment, spacing: theme.spacing * 0.75) {
            mediaBox
            if let caption = media.caption, !caption.isEmpty {
                Self.caption(
                    caption, ownerID: media.id, layout: media.layout, theme: theme, smartLinkKeys: media.captionSmartLinkKeys
                )
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

    // MARK: - Caption

    /// The caption below the box: a text leaf (`TextEngineLeaf`) owned by
    /// the media's id, the owner search highlights. Its SwiftUI text is the
    /// `.footnote`, `.secondary` caption; under the TextKit 2 renderer an
    /// eligible caption is a TextKit 2 row in the caption context, drawing
    /// its uncoloured runs in the same foreground (`adfCaptionLeaf`). Every
    /// prepared caption run carries its own font, so `.footnote` sets no
    /// caption metric and the row needs no font of its own. A layout whose
    /// caption frame does not match keeps it on SwiftUI
    /// (`TextKit2Scope.captionLayoutKeepsRenderer`), and so does a caption
    /// whose runs carry a run background (the caption verdict,
    /// `TextKit2Scope.captionRunsKeepRenderer`). No selection: the caption
    /// has none on either engine.
    ///
    /// Smart links (`PreparedMedia.captionSmartLinkKeys`): the leaf is a
    /// `SmartLinkTextLeaf`, as a paragraph's is, so a TextKit 2 caption row
    /// draws the displayed stage as its input, the SwiftUI text reads the
    /// stages itself, and the leaf attaches to the coordinator and feeds it
    /// its visibility. With no keys or no resolver it adds nothing.
    static func caption(
        _ segments: [InlineSegment], ownerID: String, layout: ADFMediaLayout, theme: ADFTheme,
        smartLinkKeys: [SmartLinkKey] = []
    ) -> some View {
        SmartLinkTextLeaf(
            segments: segments, smartLinkKeys: smartLinkKeys, style: captionStyle(theme: theme), ownerID: ownerID,
            allowsTextKit2: TextKit2Scope.captionLayoutKeepsRenderer(layout)
        ) {
            SegmentedTextView(segments: segments, ownerID: ownerID, smartLinkKeys: smartLinkKeys)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .adfCaptionLeaf()
    }

    /// The caption leaf's block style, for every media layout: the list
    /// leader's (`ListRowView.leaderStyle(theme:)`), body text with no
    /// alignment, as the caption's `Text` has none. A TextKit 2 row reads
    /// only its alignment and heading flag; fonts come from the runs.
    static func captionStyle(theme: ADFTheme) -> TextBlockStyle {
        TextBlockStyle(font: theme.body, isHeading: false, headingLevel: nil, alignment: nil, indentation: 0, breakout: nil)
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
            .mediaAttachment(viewer: media.id, key: loadKey, attrs: media.attrs, group: nil)
            .onTapGesture { handleTap() }
            .accessibilityLabel(media.attrs.alt ?? "Image")
            .accessibilityAddTraits(.isImage)
    }

    private var boxContent: some View {
        // Reads only this box's entry: a landing redraws only the views
        // showing the same key.
        let entry = self.entry
        let loadedImage = entry?.image
        let loadFailed = entry?.failed ?? false
        return ZStack {
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

    /// The load key: the source at the measured box size (rounded), so a box
    /// that settles on a new size (rotation, Split View) moves to a new
    /// load. `nil` until the box has been measured.
    private var loadKey: MediaLoadKey? {
        MediaLoadKey(source: media.attrs.source, size: boxSize)
    }

    /// This box's entry, or `nil` without a coordinator (no provider) or
    /// before the box is measured: the placeholder.
    private var entry: MediaEntry? {
        guard let coordinator, let loadKey else { return nil }
        return coordinator.entry(for: loadKey)
    }

    private func handleTap() {
        if let href = media.linkHref, let url = URL(string: href) {
            openURL(url)
        } else if entry?.image != nil {
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
