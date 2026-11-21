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
        try thumbnail(of: try source(of: data), maxPixelSize: maxPixelSize)
    }

    /// A decoded bitmap of `data` just large enough to fill `pixelSize`
    /// when scaled to fill it (aspect kept, overflow cropped), with its
    /// longer side at most `maxPixelSize` pixels: an image whose aspect
    /// differs from the box is decoded so its shorter side still covers
    /// the box. A smaller image keeps its own size; it is never scaled up.
    ///
    /// Decoding happens here, so call it off the main thread.
    public static func downsample(_ data: Data, covering pixelSize: CGSize, maxPixelSize: Int) throws -> CGImage {
        let source = try source(of: data)
        let longest = coveringLongestSide(of: source, for: pixelSize)
            ?? Int(max(pixelSize.width, pixelSize.height).rounded(.up))
        return try thumbnail(of: source, maxPixelSize: min(longest, maxPixelSize))
    }

    private static func source(of data: Data) throws -> CGImageSource {
        // Not caching the source keeps ImageIO from holding a full-size
        // decode of it.
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            throw Error.undecodable
        }
        return source
    }

    private static func thumbnail(of source: CGImageSource, maxPixelSize: Int) throws -> CGImage {
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

    /// The longer side, in pixels, at which the image fills `pixelSize`
    /// with its orientation applied; nil when the source reports no size.
    private static func coveringLongestSide(of source: CGImageSource, for pixelSize: CGSize) -> Int? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let rawHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              rawWidth > 0, rawHeight > 0 else { return nil }
        // EXIF orientations 5–8 turn the image a quarter, swapping its sides.
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let (width, height) = (5 ... 8).contains(orientation) ? (rawHeight, rawWidth) : (rawWidth, rawHeight)
        let fill = max(Double(pixelSize.width) / width, Double(pixelSize.height) / height)
        guard fill.isFinite, fill > 0 else { return nil }
        return Int((fill * max(width, height)).rounded(.up))
    }
}
