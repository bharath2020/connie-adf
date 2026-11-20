import CoreGraphics

/// A decoded image that a host resolver hands to the renderer: a custom
/// emoji from `ADFEmojiResolver`, and later a media image. The bitmap is
/// already decoded (and, for media, downsampled), so drawing it costs no
/// decode on the main thread.
public struct ADFResolvedImage: @unchecked Sendable {
    // `@unchecked`: `CGImage` is immutable once made, so sharing it across
    // tasks is safe, but not every SDK marks it `Sendable`.

    /// The decoded bitmap.
    public let cgImage: CGImage
    /// Pixels per point of `cgImage`: its size in points is its pixel size
    /// divided by this.
    public let scale: CGFloat

    public init(cgImage: CGImage, scale: CGFloat) {
        self.cgImage = cgImage
        self.scale = scale
    }
}
