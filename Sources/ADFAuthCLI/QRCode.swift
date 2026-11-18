#if os(macOS)
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// A square QR symbol without its quiet zone: `size` × `size` modules,
/// row-major from the top-left, `true` = dark.
struct QRMatrix: Equatable, Sendable {
    let size: Int
    let modules: [Bool]

    init?(size: Int, modules: [Bool]) {
        guard size > 0, modules.count == size * size else { return nil }
        self.size = size
        self.modules = modules
    }

    /// Modules outside the symbol (the quiet zone) read as light.
    subscript(row: Int, column: Int) -> Bool {
        guard (0..<size).contains(row), (0..<size).contains(column) else { return false }
        return modules[row * size + column]
    }
}

/// Builds a ``QRMatrix`` with CoreImage's `CIQRCodeGenerator`.
enum QRCodeGenerator {
    /// The symbol for `text` (UTF-8), error correction level "M" by default.
    static func matrix(for text: String, correctionLevel: String = "M") -> QRMatrix? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = correctionLevel
        guard let image = filter.outputImage else { return nil }

        // The generator draws one pixel per module at scale 1.
        let extent = image.extent.integral
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else { return nil }
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        guard let cgImage = context.createCGImage(image, from: extent) else { return nil }

        // Redraw into an 8-bit grayscale bitmap we own, so the pixel layout is
        // known: one byte per pixel, first row = top of the image.
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let bitmap = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            bitmap.interpolationQuality = .none
            bitmap.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return matrix(fromGrayPixels: pixels, width: width, height: height)
    }

    /// Reads modules from a grayscale bitmap with one pixel per module (rows
    /// top to bottom; < 128 is dark) and crops to the bounding box of the
    /// dark modules, which drops any quiet zone the generator added. The
    /// three finder patterns guarantee that box is the whole symbol.
    static func matrix(fromGrayPixels pixels: [UInt8], width: Int, height: Int) -> QRMatrix? {
        guard width > 0, height > 0, pixels.count == width * height else { return nil }
        var minRow = height, maxRow = -1, minColumn = width, maxColumn = -1
        for row in 0..<height {
            for column in 0..<width where pixels[row * width + column] < 128 {
                minRow = min(minRow, row)
                maxRow = max(maxRow, row)
                minColumn = min(minColumn, column)
                maxColumn = max(maxColumn, column)
            }
        }
        guard maxRow >= 0 else { return nil }
        let size = maxRow - minRow + 1
        // QR versions 1...40 are 21...177 modules, in steps of 4.
        guard size == maxColumn - minColumn + 1, size >= 21, (size - 17) % 4 == 0 else { return nil }
        var modules: [Bool] = []
        modules.reserveCapacity(size * size)
        for row in minRow...maxRow {
            for column in minColumn...maxColumn {
                modules.append(pixels[row * width + column] < 128)
            }
        }
        return QRMatrix(size: size, modules: modules)
    }
}

/// Draws a ``QRMatrix`` as terminal text with half blocks: each character
/// cell holds two module rows (`▀` top dark, `▄` bottom dark, `█` both,
/// space neither).
enum QRTerminalRenderer {
    /// Explicit black (256-colour 16) on white (256-colour 231), so the code
    /// scans on dark and light terminal themes alike.
    static let blackOnWhite = "\u{1B}[38;5;16;48;5;231m"
    static let reset = "\u{1B}[0m"

    /// One string per pair of module rows, with a `quietZone`-module light
    /// border. With `ansi`, each line is wrapped in black-on-white colours.
    static func lines(for matrix: QRMatrix, quietZone: Int = 2, ansi: Bool = true) -> [String] {
        let total = matrix.size + 2 * max(quietZone, 0)
        let offset = max(quietZone, 0)
        var lines: [String] = []
        lines.reserveCapacity((total + 1) / 2)
        var row = 0
        while row < total {
            var line = ""
            line.reserveCapacity(total * 3)
            for column in 0..<total {
                let top = matrix[row - offset, column - offset]
                let bottom = row + 1 < total && matrix[row + 1 - offset, column - offset]
                switch (top, bottom) {
                case (true, true): line.append("█")
                case (true, false): line.append("▀")
                case (false, true): line.append("▄")
                case (false, false): line.append(" ")
                }
            }
            lines.append(ansi ? blackOnWhite + line + reset : line)
            row += 2
        }
        return lines
    }

    /// The QR for `text` as terminal lines, or nil if CoreImage can't make one.
    static func lines(for text: String, ansi: Bool = true) -> [String]? {
        QRCodeGenerator.matrix(for: text).map { lines(for: $0, ansi: ansi) }
    }
}
#endif
