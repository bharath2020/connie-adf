import SwiftUI
import ADFModel
import ADFPreparation

/// Tap-to-open lightbox: loads the media at full resolution (this is the
/// only place full-res bytes are decoded) with pinch-to-zoom, pan while
/// zoomed, and double-tap to toggle zoom.
struct LightboxView: View {
    let media: PreparedMedia

    @Environment(\.dismiss) private var dismiss
    @Environment(\.adfMediaProvider) private var provider

    @State private var loadedImage: Image?
    @State private var loadFailed = false
    @State private var zoom: CGFloat = 1
    @State private var gestureZoom: CGFloat = 1
    @State private var panOffset = CGSize.zero
    @State private var gesturePan = CGSize.zero

    private static let maxZoom: CGFloat = 8

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            if let loadedImage {
                loadedImage
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(zoom * gestureZoom)
                    .offset(
                        x: panOffset.width + gesturePan.width,
                        y: panOffset.height + gesturePan.height
                    )
                    .gesture(zoomAndPanGesture)
                    .onTapGesture(count: 2) { toggleZoom() }
                    .accessibilityLabel(media.attrs.alt ?? "Image")
                    .accessibilityAddTraits(.isImage)
            } else if loadFailed {
                ContentUnavailableView(
                    "Couldn't Load Image",
                    systemImage: "exclamationmark.triangle",
                    description: Text(media.attrs.alt ?? "")
                )
                .foregroundStyle(.white)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .task { await loadFullResolution() }
    }

    // MARK: - Gestures

    private var zoomAndPanGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                gestureZoom = value.magnification
            }
            .onEnded { value in
                zoom = min(max(zoom * value.magnification, 1), Self.maxZoom)
                gestureZoom = 1
                if zoom <= 1 {
                    withAnimation(.snappy) { panOffset = .zero }
                }
            }
            .simultaneously(
                with: DragGesture()
                    .onChanged { value in
                        guard zoom > 1 else { return }
                        gesturePan = value.translation
                    }
                    .onEnded { value in
                        guard zoom > 1 else {
                            gesturePan = .zero
                            return
                        }
                        panOffset.width += value.translation.width
                        panOffset.height += value.translation.height
                        gesturePan = .zero
                    }
            )
    }

    private func toggleZoom() {
        withAnimation(.snappy) {
            if zoom > 1 {
                zoom = 1
                panOffset = .zero
            } else {
                zoom = 2
            }
        }
    }

    // MARK: - Loading

    private func loadFullResolution() async {
        guard loadedImage == nil, let provider else {
            if provider == nil { loadFailed = true }
            return
        }
        let target = CGSize(
            width: media.attrs.width ?? 4096,
            height: media.attrs.height ?? 4096
        )
        do {
            loadedImage = try await provider.image(for: media.attrs, targetSize: target)
        } catch {
            if !Task.isCancelled {
                loadFailed = true
            }
        }
    }
}
