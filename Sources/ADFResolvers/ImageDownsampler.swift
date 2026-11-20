import CoreGraphics
import Foundation
import ImageIO

/// Decodes encoded image bytes straight to a bitmap no larger than needed.
///
/// ImageIO makes the thumbnail from the encoded data, so the image is never
/// decoded at full resolution: a 4000 × 3000 photo shown at 512 pixels costs
/// a 512-pixel bitmap, not a 48 MB one.
public enum ImageDownsampler {
    public enum Error: Swift.Error, Equatable {
        /// The bytes are not an image ImageIO can decode.
        case undecodable
    }

    /// A decoded bitmap of `data` whose longer side is at most
    /// `maxPixelSize` pixels, with the image's orientation applied. A
    /// smaller image keeps its own size; it is never scaled up.
    ///
    /// Decoding happens here, so call it off the main thread.
    public static func downsample(_ data: Data, maxPixelSize: Int) throws -> CGImage {
        // Not caching the source keeps ImageIO from holding a full-size
        // decode of it.
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            throw Error.undecodable
        }
        let thumbnailOptions = [
            // Always from the full image: an embedded thumbnail may be too
            // small or stale.
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Decode now, on this thread, rather than at first draw.
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            throw Error.undecodable
        }
        return image
    }
}
