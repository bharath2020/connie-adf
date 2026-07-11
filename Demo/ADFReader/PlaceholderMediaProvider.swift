import CoreGraphics
import Foundation
import SwiftUI
import ADFModel
import ADFRendering

/// Offline media for the demo: every reference renders as a deterministic
/// two-color linear gradient. A stable FNV-1a hash of the media id / URL
/// picks the hues, so the same document always shows the same images, and
/// the bitmap is drawn with CoreGraphics at exactly `targetSize` — no
/// network, no caching surprises.
struct PlaceholderMediaProvider: ADFMediaProvider {
    enum RenderError: Error {
        case contextUnavailable
    }

    func image(for attrs: MediaAttrs, targetSize: CGSize) async throws -> Image {
        let key: String
        switch attrs.source {
        case .file(let id, let collection):
            key = "file:\(collection)/\(id)"
        case .external(let url):
            key = "url:\(url)"
        }
        let cgImage = try Self.gradientImage(key: key, size: targetSize)
        return Image(decorative: cgImage, scale: 1)
    }

    private static func gradientImage(key: String, size: CGSize) throws -> CGImage {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw RenderError.contextUnavailable
        }

        let hash = fnv1a(key)
        let startHue = Double(hash & 0xFFFF) / 65_536
        let endHue = (startHue + 0.18).truncatingRemainder(dividingBy: 1)
        let components: [CGFloat] = (
            rgb(hue: startHue, saturation: 0.55, brightness: 0.9) + [1]
                + rgb(hue: endHue, saturation: 0.7, brightness: 0.6) + [1]
        ).map { CGFloat($0) }
        guard let gradient = CGGradient(
            colorSpace: colorSpace,
            colorComponents: components,
            locations: [0, 1],
            count: 2
        ) else {
            throw RenderError.contextUnavailable
        }

        context.drawLinearGradient(
            gradient,
            start: .zero,
            end: CGPoint(x: width, y: height),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        guard let image = context.makeImage() else {
            throw RenderError.contextUnavailable
        }
        return image
    }

    /// FNV-1a: stable across launches (unlike `Hashable`'s seeded hasher).
    private static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// Minimal HSB → RGB so drawing stays pure CoreGraphics (no UIKit).
    private static func rgb(hue: Double, saturation: Double, brightness: Double) -> [Double] {
        let h = (hue - hue.rounded(.down)) * 6
        let sector = min(5, max(0, Int(h)))
        let f = h - Double(sector)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * f)
        let t = brightness * (1 - saturation * (1 - f))
        switch sector {
        case 0: return [brightness, t, p]
        case 1: return [q, brightness, p]
        case 2: return [p, brightness, t]
        case 3: return [p, q, brightness]
        case 4: return [t, p, brightness]
        default: return [brightness, p, q]
        }
    }
}
