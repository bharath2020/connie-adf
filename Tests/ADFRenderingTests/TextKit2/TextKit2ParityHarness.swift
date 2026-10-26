#if canImport(UIKit)
import SwiftUI
import UIKit
import Testing
import ADFModel
import ADFPreparation
@testable import ADFRendering

/// Shared plumbing for the TextKit 2 parity suites: prepared fixtures,
/// hosted measurement of the real `RichTextBlockView` on either arm, the
/// TextKit layout the hosted row computes, bitmap rendering at the device's
/// native scale, and ink-profile / per-line ink-extent comparison.
enum TK2Parity {
    static let theme = ADFTheme.default

    /// A prepared top-level paragraph or heading.
    struct Fixture: Sendable {
        let name: String
        let segments: [InlineSegment]
        let style: TextBlockStyle

        var describableText: AttributedString? { TextKit2Eligibility.describableText(segments) }
        /// Leading padding `RichTextBlockView` applies for the indentation mark.
        var indentation: CGFloat { CGFloat(max(style.indentation, 0)) * TK2Parity.theme.spacing * 3 }
    }

    /// The layout inputs a hosted row sees besides the width.
    struct Environment: Sendable, CustomStringConvertible {
        var size: DynamicTypeSize = .large
        var direction: LayoutDirection = .leftToRight
        var legibility: LegibilityWeight? = nil
        var dark = false

        var description: String {
            var parts = ["\(size)"]
            if direction == .rightToLeft { parts.append("rtl") }
            if legibility == .bold { parts.append("boldText") }
            if dark { parts.append("dark") }
            return parts.joined(separator: " ")
        }
    }

    static func adfText(_ string: String, marks: String = "") -> String {
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return marks.isEmpty
            ? "{\"type\":\"text\",\"text\":\"\(escaped)\"}"
            : "{\"type\":\"text\",\"text\":\"\(escaped)\",\"marks\":[\(marks)]}"
    }

    static let hardBreak = "{\"type\":\"hardBreak\"}"

    /// Prepares one block from ADF inline JSON (`content` is the JSON array
    /// body of a paragraph or heading; `blockMarks` its block marks).
    static func fixture(_ name: String, kind: String = "paragraph", level: Int? = nil, blockMarks: String? = nil, content: String) async throws -> Fixture {
        var attrs = level.map { ",\"attrs\":{\"level\":\($0)}" } ?? ""
        if let blockMarks { attrs += ",\"marks\":[\(blockMarks)]" }
        let json = "{\"version\":1,\"type\":\"doc\",\"content\":[{\"type\":\"\(kind)\"\(attrs),\"content\":[\(content)]}]}"
        let doc = try await ADFParser().parse(Data(json.utf8))
        let blocks = DocumentPreparer(theme: theme).prepare(doc)
        guard case .richText(let segments, let style) = try #require(blocks.first).kind else {
            throw TestFailure("block is not richText")
        }
        return Fixture(name: name, segments: segments, style: style)
    }

    static func plain(_ name: String, _ string: String) async throws -> Fixture {
        try await fixture(name, content: adfText(string))
    }

    static func heading(_ level: Int, _ string: String) async throws -> Fixture {
        try await fixture("h\(level)", kind: "heading", level: level, content: adfText(string))
    }

    // MARK: Hosting

    /// The device's native scale (3 on iPhone 17 Pro, 2 on iPhone SE).
    @MainActor
    static var nativeScale: CGFloat {
        UIWindow(frame: CGRect(x: 0, y: 0, width: 10, height: 10)).traitCollection.displayScale
    }

    /// The real leaf on one arm, as `DocumentRow` hosts it (environment
    /// renderer + Dynamic Type), at the top-leading corner.
    @MainActor
    static func hosted(_ fixture: Fixture, arm: ADFTextRenderer, env: Environment) -> some View {
        RichTextBlockView(segments: fixture.segments, style: fixture.style)
            .environment(\.adfTextRenderer, arm)
            .environment(\.adfTheme, theme)
            .environment(\.layoutDirection, env.direction)
            .environment(\.legibilityWeight, env.legibility)
            .dynamicTypeSize(env.size)
    }

    @MainActor
    static func height(_ fixture: Fixture, arm: ADFTextRenderer, env: Environment, width: CGFloat) -> CGFloat {
        let host = UIHostingController(rootView: hosted(fixture, arm: arm, env: env))
        host.safeAreaRegions = []
        return host.sizeThatFits(in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)).height
    }

    @MainActor
    static func height(_ fixture: Fixture, arm: ADFTextRenderer, size: DynamicTypeSize, width: CGFloat) -> CGFloat {
        height(fixture, arm: arm, env: Environment(size: size), width: width)
    }

    @MainActor
    static func heights(_ fixture: Fixture, env: Environment, width: CGFloat) -> (swiftUI: CGFloat, textKit2: CGFloat) {
        (height(fixture, arm: .swiftUI, env: env, width: width),
         height(fixture, arm: .textKit2, env: env, width: width))
    }

    @MainActor
    static func heights(_ fixture: Fixture, size: DynamicTypeSize, width: CGFloat) -> (swiftUI: CGFloat, textKit2: CGFloat) {
        heights(fixture, env: Environment(size: size), width: width)
    }

    /// The render inputs the hosted TextKit 2 row resolves for `env`.
    @MainActor
    static func inputs(_ fixture: Fixture, env: Environment) throws -> TextKit2RenderInputs {
        var values = EnvironmentValues()
        values.dynamicTypeSize = env.size
        values.layoutDirection = env.direction
        values.legibilityWeight = env.legibility
        values.colorScheme = env.dark ? .dark : .light
        values.displayScale = nativeScale
        return TextKit2RowRepresentable.inputs(text: try #require(fixture.describableText), style: fixture.style, environment: values)
    }

    /// The layout the hosted TextKit 2 row computes at `width` (its own
    /// width: the column minus any indentation).
    @MainActor
    static func layout(_ fixture: Fixture, env: Environment, width: CGFloat) throws -> TextKit2LayoutResult {
        let view = TextKit2RowView()
        view.apply(try inputs(fixture, env: env))
        return view.layoutResult(forProposedWidth: width - fixture.indentation)
    }

    /// First and last text baselines and height of the hosted leaf, as an
    /// enclosing baseline-aligned container reads them.
    @MainActor
    static func guides(_ fixture: Fixture, arm: ADFTextRenderer, env: Environment, width: CGFloat) -> (first: CGFloat, last: CGFloat, height: CGFloat) {
        let box = GuideBox()
        let root = VStack(alignment: .leading, spacing: 0) {
            hosted(fixture, arm: arm, env: env)
                .alignmentGuide(.leading) { dimensions in
                    let first = dimensions[.firstTextBaseline]
                    let last = dimensions[.lastTextBaseline]
                    let height = dimensions.height
                    MainActor.assumeIsolated {
                        box.first = first
                        box.last = last
                        box.height = height
                    }
                    return dimensions[.leading]
                }
        }
        .frame(width: width, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 2_000))
        let host = UIHostingController(rootView: root)
        host.safeAreaRegions = []
        window.rootViewController = host
        window.isHidden = false
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        window.isHidden = true
        window.rootViewController = nil
        return (box.first, box.last, box.height)
    }

    @MainActor
    final class GuideBox {
        var first: CGFloat = .nan
        var last: CGFloat = .nan
        var height: CGFloat = .nan
    }

    // MARK: Bitmaps

    struct Bitmap {
        let width: Int
        let height: Int
        let scale: CGFloat
        let rgba: [UInt8]

        subscript(x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
            let i = (y * width + x) * 4
            return (Int(rgba[i]), Int(rgba[i + 1]), Int(rgba[i + 2]))
        }
    }

    /// Renders the hosted leaf in a window at the device's native scale.
    /// The test host has no window scene, so `drawHierarchy` cannot run;
    /// `CALayer.render(in:)` on the laid-out window captures both arms
    /// (SwiftUI's text layers and the TextKit row's canvas) identically.
    @MainActor
    static func render(_ fixture: Fixture, arm: ADFTextRenderer, env: Environment, width: CGFloat, height: CGFloat) throws -> Bitmap {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
        window.overrideUserInterfaceStyle = env.dark ? .dark : .light
        window.backgroundColor = env.dark ? .black : .white
        let root = hosted(fixture, arm: arm, env: env)
            .frame(width: width, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea()
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        window.rootViewController = host
        window.isHidden = false
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()

        let scale = window.traitCollection.displayScale
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { context in
            window.layer.render(in: context.cgContext)
        }
        window.isHidden = true
        window.rootViewController = nil
        let cgImage = try #require(image.cgImage)

        // Only whole pixel columns: at a width that is not a whole number
        // of pixels (300.5 pt at 3x) the image's last column is part
        // window, part outside, and reads as ink on every row of both arms.
        let pixelWidth = min(cgImage.width, Int((width * scale + 0.01).rounded(.down)))
        let pixelHeight = cgImage.height
        var data = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        let context = try #require(CGContext(
            data: &data,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: pixelWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: pixelHeight))
        return Bitmap(width: pixelWidth, height: pixelHeight, scale: scale, rgba: data)
    }

    /// A pixel is ink when any channel is more than 8 off the background.
    static func isInk(_ bitmap: Bitmap, _ x: Int, _ y: Int, dark: Bool) -> Bool {
        let bg = dark ? 0 : 255
        let p = bitmap[x, y]
        return abs(p.r - bg) > 8 || abs(p.g - bg) > 8 || abs(p.b - bg) > 8
    }

    struct InkProfile: Equatable {
        var firstInkRow: Int?
        var lastInkRow: Int?
        var rowCounts: [Int]
    }

    /// Ink pixels counted per pixel row.
    static func inkProfile(_ bitmap: Bitmap, dark: Bool) -> InkProfile {
        var profile = InkProfile(rowCounts: Array(repeating: 0, count: bitmap.height))
        for y in 0..<bitmap.height {
            var count = 0
            for x in 0..<bitmap.width where isInk(bitmap, x, y, dark: dark) { count += 1 }
            profile.rowCounts[y] = count
            if count > 0 {
                if profile.firstInkRow == nil { profile.firstInkRow = y }
                profile.lastInkRow = y
            }
        }
        return profile
    }

    /// First and last ink column within a band of pixel rows, or `nil` for
    /// an inkless band (an empty line).
    static func inkExtent(_ bitmap: Bitmap, rows: Range<Int>, dark: Bool) -> ClosedRange<Int>? {
        var first: Int?
        var last: Int?
        for y in max(rows.lowerBound, 0)..<min(rows.upperBound, bitmap.height) {
            for x in 0..<bitmap.width where isInk(bitmap, x, y, dark: dark) {
                first = min(first ?? x, x)
                break
            }
            for x in stride(from: bitmap.width - 1, through: 0, by: -1) where isInk(bitmap, x, y, dark: dark) {
                last = max(last ?? x, x)
                break
            }
        }
        guard let first, let last else { return nil }
        return first...last
    }

    /// Pixel-row bands of a layout's lines.
    static func lineBands(_ layout: TextKit2LayoutResult, scale: CGFloat) -> [Range<Int>] {
        layout.lines.map { line in
            Int((line.frame.minY * scale).rounded())..<Int((line.frame.maxY * scale).rounded())
        }
    }

    /// Fraction of pixels (over the given rows, full width) whose colour
    /// differs by more than 24 in any channel.
    static func differingFraction(_ a: Bitmap, _ b: Bitmap, rows: ClosedRange<Int>) -> (fraction: Double, count: Int, total: Int) {
        precondition(a.width == b.width && a.height == b.height)
        var differing = 0
        var total = 0
        for y in rows {
            for x in 0..<a.width {
                let p = a[x, y], q = b[x, y]
                total += 1
                if abs(p.r - q.r) > 24 || abs(p.g - q.g) > 24 || abs(p.b - q.b) > 24 { differing += 1 }
            }
        }
        return (total == 0 ? 0 : Double(differing) / Double(total), differing, total)
    }

    /// Rows where the two profiles differ, for diagnostics.
    static func rowDifferences(_ a: InkProfile, _ b: InkProfile, limit: Int = 12) -> String {
        var lines: [String] = []
        for y in 0..<min(a.rowCounts.count, b.rowCounts.count) where a.rowCounts[y] != b.rowCounts[y] {
            lines.append("row \(y): swiftUI=\(a.rowCounts[y]) textKit2=\(b.rowCounts[y])")
            if lines.count >= limit { lines.append("…"); break }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Line breaks

    /// Compares per-line ink extents of both arms (the words on each line)
    /// and returns a description of every mismatching line, with TextKit's
    /// line text for diagnosis; empty when the arms agree.
    @MainActor
    static func lineBreakMismatches(_ fixture: Fixture, env: Environment, width: CGFloat) throws -> [String] {
        let layout = try layout(fixture, env: env, width: width)
        let height = max(layout.size.height, 1) + 24
        let a = try render(fixture, arm: .swiftUI, env: env, width: width, height: height)
        let b = try render(fixture, arm: .textKit2, env: env, width: width, height: height)
        let text = NSString(string: String(try #require(fixture.describableText).characters))
        var mismatches: [String] = []
        for (index, band) in lineBands(layout, scale: a.scale).enumerated() {
            let ea = inkExtent(a, rows: band, dark: env.dark)
            let eb = inkExtent(b, rows: band, dark: env.dark)
            if ea != eb {
                let range = layout.lines[index].range
                let lineText = range.location + range.length <= text.length ? text.substring(with: range) : "?"
                mismatches.append("line \(index) swiftUI=\(String(describing: ea)) textKit2=\(String(describing: eb)) tk2Text='\(lineText)'")
            }
        }
        return mismatches
    }
}

#endif
