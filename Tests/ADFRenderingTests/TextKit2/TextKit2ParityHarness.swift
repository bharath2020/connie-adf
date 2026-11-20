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
        /// The inherited foreground the library sets on a leaf
        /// (`adfTextForeground`; `.secondary` on a caption): the SwiftUI
        /// arm gets it as its foreground style, the TextKit 2 row as its
        /// inherited foreground.
        var foreground: Color? = nil

        var description: String {
            var parts = ["\(size)"]
            if direction == .rightToLeft { parts.append("rtl") }
            if legibility == .bold { parts.append("boldText") }
            if dark { parts.append("dark") }
            if let foreground { parts.append("foreground=\(foreground)") }
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
            .modifier(InheritedForeground(color: env.foreground))
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
        values.displayScale = nativeScale
        values.adfTextForeground = env.foreground
        return TextKit2RowRepresentable.inputs(text: try #require(fixture.describableText), style: fixture.style, environment: values)
    }

    /// `Environment.foreground` on a hosted leaf, as the library sets an
    /// inherited foreground beside the SwiftUI style it mirrors
    /// (`adfCaptionLeaf`): the foreground style for `Text`, the explicit
    /// copy for the TextKit 2 row.
    struct InheritedForeground: ViewModifier {
        let color: Color?

        func body(content: Content) -> some View {
            if let color {
                content
                    .foregroundStyle(color)
                    .environment(\.adfTextForeground, color)
            } else {
                content
            }
        }
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
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        return try bitmap(of: window, width: width)
    }

    /// The window's laid-out layer tree at the device's native scale (see
    /// `render`), cropped to the whole pixel columns of `width`.
    @MainActor
    static func bitmap(of window: UIWindow, width: CGFloat) throws -> Bitmap {
        let scale = window.traitCollection.displayScale
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { context in
            window.layer.render(in: context.cgContext)
        }
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
            let range = layout.lines[index].range
            let lineText = range.location + range.length <= text.length ? text.substring(with: range) : "?"
            if ea != eb {
                mismatches.append("line \(index) swiftUI=\(String(describing: ea)) textKit2=\(String(describing: eb)) tk2Text='\(lineText)'")
            } else if ea == nil, lineText.contains(where: { !$0.isWhitespace }) {
                // Both blank on a line with visible text: nothing was compared.
                mismatches.append("line \(index) has no ink on either arm tk2Text='\(lineText)'")
            }
        }
        return mismatches
    }
}

// MARK: - Code blocks

/// Plumbing for the code-block parity suites (`TextKit2CodeParityTests`):
/// prepared code blocks, the real `BlockView` (so the real `CodeBlockView`)
/// hosted on either arm in a window that stays up for inspection, the
/// horizontal scroll view behind it, bitmaps of a window rectangle, and
/// region ink / pixel comparison. Additions only: nothing above changes.
extension TK2Parity {
    // MARK: Prepared code blocks

    /// An ADF `codeBlock` node. `language` nil leaves the attribute out, an
    /// empty string passes through; empty `text` leaves the content out;
    /// `breakout` is the mark's mode (`"wide"`, `"full-width"`).
    static func codeBlockNode(_ text: String, language: String? = nil, breakout: String? = nil) -> [String: Any] {
        var node: [String: Any] = ["type": "codeBlock"]
        if let language {
            let attrs: [String: Any] = ["language": language]
            node["attrs"] = attrs
        }
        if !text.isEmpty {
            let textNode: [String: Any] = ["type": "text", "text": text]
            node["content"] = [textNode]
        }
        if let breakout {
            let modeAttrs: [String: Any] = ["mode": breakout]
            let mark: [String: Any] = ["type": "breakout", "attrs": modeAttrs]
            node["marks"] = [mark]
        }
        return node
    }

    /// A `doc` holding `nodes`, as JSON. `JSONSerialization` does the
    /// escaping, so tabs, CR, CRLF and non-ASCII text reach the parser as
    /// written.
    static func documentData(_ nodes: [[String: Any]]) throws -> Data {
        let doc: [String: Any] = ["version": 1, "type": "doc", "content": nodes]
        return try JSONSerialization.data(withJSONObject: doc, options: [.withoutEscapingSlashes])
    }

    /// The prepared blocks of a document.
    @MainActor
    static func blocks(json data: Data, theme: ADFTheme = TK2Parity.theme) async throws -> [RenderBlock] {
        DocumentPreparer(theme: theme).prepare(try await ADFParser().parse(data))
    }

    /// One prepared code block: parsed and prepared as in a document, so it
    /// carries the font spec and the code shape preparation stamps.
    @MainActor
    static func codeBlock(_ text: String, language: String? = nil, theme: ADFTheme = TK2Parity.theme) async throws -> RenderBlock {
        let data = try documentData([codeBlockNode(text, language: language)])
        let prepared = try await blocks(json: data, theme: theme)
        guard let block = prepared.first, case .codeBlock = block.kind else {
            throw TestFailure("the document's first block is not a code block")
        }
        return block
    }

    /// The prepared language and code string of a code block.
    static func codeParts(_ block: RenderBlock) throws -> (language: String?, code: AttributedString) {
        guard case .codeBlock(let language, let code) = block.kind else {
            throw TestFailure("block \(block.id) is not a code block")
        }
        return (language, code)
    }

    /// The same block with `shape` stamped over its code in place of the
    /// shape preparation measured. The content verdict trusts the stamped
    /// shape (`TextKit2Eligibility.codeVerdict`), so this is the seam the
    /// record-only experiments use to put text outside the admitted cohort
    /// on the TextKit 2 row. The characters are untouched. An empty string
    /// has no run to stamp and comes back unchanged.
    static func restamped(_ block: RenderBlock, shape: ADFCodeShape) throws -> RenderBlock {
        let parts = try codeParts(block)
        var code = parts.code
        code[AttributeScopes.ADFAttributes.CodeShapeAttribute.self] = shape
        return RenderBlock(id: block.id, kind: .codeBlock(language: parts.language, code: code), breakout: block.breakout)
    }

    // MARK: Hosting

    /// A code block as `ADFDocumentView`'s row hosts it: the real
    /// `BlockView` (which builds the real `CodeBlockView`), the renderer
    /// through the environment, at the top-leading corner.
    @MainActor
    static func hostedCode(_ block: RenderBlock, arm: ADFTextRenderer, env: Environment, theme: ADFTheme = TK2Parity.theme) -> some View {
        BlockView(block: block)
            .environment(\.adfTextRenderer, TextKit2Scope.inheritsRenderer(block.kind) ? arm : .swiftUI)
            .environment(\.adfTheme, theme)
            .environment(\.layoutDirection, env.direction)
            .environment(\.legibilityWeight, env.legibility)
            .dynamicTypeSize(env.size)
    }

    /// The size `view` takes at `width` and an unspecified height, from a
    /// hosting controller that is in a window: the environment's display
    /// scale is then the device's, as in the rendered hosts, so a rule that
    /// reads it (the code canvas gate) decides the same in both.
    @MainActor
    static func attachedSize(_ view: some View, width: CGFloat) -> CGSize {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: max(width, 1), height: 600))
        let host = UIHostingController(rootView: view)
        host.safeAreaRegions = []
        window.rootViewController = host
        window.isHidden = false
        window.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        return host.sizeThatFits(in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
    }

    /// A view laid out at `width` and its own height at the top-leading
    /// corner of a scene-less window at the device's native scale (the root
    /// `TextKit2ListParityTests.render` uses), kept up until `close()` so
    /// its UIKit tree can be inspected, panned and rendered.
    @MainActor
    final class Host {
        let window: UIWindow
        let controller: UIHostingController<AnyView>

        init(_ view: some View, width: CGFloat, height: CGFloat, dark: Bool = false) {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            window.backgroundColor = dark ? .black : .white
            let controller = UIHostingController(rootView: AnyView(
                view
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: width, alignment: .topLeading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .ignoresSafeArea()
            ))
            controller.view.backgroundColor = .clear
            controller.safeAreaRegions = []
            window.rootViewController = controller
            window.isHidden = false
            window.layoutIfNeeded()
            controller.view.layoutIfNeeded()
            self.window = window
            self.controller = controller
        }

        var view: UIView { controller.view }
        var scale: CGFloat { window.traitCollection.displayScale }

        func layout() {
            window.layoutIfNeeded()
            controller.view.layoutIfNeeded()
        }

        /// Lays out until the scroll views' geometry and the TextKit 2 row
        /// count stop changing (a `ScrollView` can take a run-loop turn to
        /// size its content): at least two 10 ms turns, at most `turns`.
        func settle(turns: Int = 15) async throws {
            var last = ""
            var stable = 0
            for _ in 0..<turns {
                layout()
                let geometry = TK2Parity.scrollViews(in: view).map { "\($0.frame) \($0.contentSize) \($0.contentOffset)" }
                let now = geometry.joined(separator: "|") + " rows=\(TextKit2FallbackTests.rows(in: view).count)"
                stable = now == last ? stable + 1 : 0
                if stable >= 2 { return }
                last = now
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    /// Every scroll view under `view` that is not a text view, outermost
    /// first. A hosted code block has one: its horizontal viewport.
    @MainActor
    static func scrollViews(in view: UIView) -> [UIScrollView] {
        var found: [UIScrollView] = []
        if let scroll = view as? UIScrollView, !(view is UITextView) { found.append(scroll) }
        for subview in view.subviews { found += scrollViews(in: subview) }
        return found
    }

    /// The scroll views nested in another scroll view: in a hosted
    /// document, the code blocks' horizontal viewports (the first of
    /// `scrollViews(in:)` is the document's own).
    @MainActor
    static func nestedScrollViews(in view: UIView) -> [UIScrollView] {
        scrollViews(in: view).filter { scroll in
            var ancestor = scroll.superview
            while let current = ancestor {
                if current is UIScrollView { return true }
                ancestor = current.superview
            }
            return false
        }
    }

    // MARK: Regions

    /// A rectangle of a laid-out window (window coordinates) at the
    /// device's native scale, cropped to its whole pixel columns:
    /// `bitmap(of:width:)` for part of a window, as
    /// `TextKit2ListParityTests.band(of:y:)` renders one. Throws instead of
    /// recording an issue, so a record-only experiment can catch it.
    @MainActor
    static func bitmap(of window: UIWindow, in rect: CGRect) throws -> Bitmap {
        let scale = window.traitCollection.displayScale
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: rect, format: format).image { context in
            window.layer.render(in: context.cgContext)
        }
        guard let cgImage = image.cgImage else { throw TestFailure("no image for \(rect)") }
        let pixelWidth = min(cgImage.width, Int((rect.width * scale + 0.01).rounded(.down)))
        let pixelHeight = cgImage.height
        guard pixelWidth > 0, pixelHeight > 0 else { throw TestFailure("empty image for \(rect)") }
        var data = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        guard let context = CGContext(
            data: &data, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: pixelWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw TestFailure("no bitmap context for \(rect)") }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: pixelHeight))
        return Bitmap(width: pixelWidth, height: pixelHeight, scale: scale, rgba: data)
    }

    /// Ink in a region of a bitmap, per pixel row of the region: the count
    /// and the first and last ink column (bitmap coordinates).
    struct RowInk: Equatable {
        var counts: [Int]
        var extents: [ClosedRange<Int>?]

        /// First and last pixel row with ink, relative to the region's top.
        var firstRow: Int? { counts.firstIndex { $0 > 0 } }
        var lastRow: Int? { counts.lastIndex { $0 > 0 } }

        /// First and last ink column over a band of the region's rows, or
        /// `nil` for an inkless band (an empty line).
        func extent(rows band: Range<Int>) -> ClosedRange<Int>? {
            var first: Int?
            var last: Int?
            for y in band.clamped(to: 0..<extents.count) {
                guard let extent = extents[y] else { continue }
                first = min(first ?? extent.lowerBound, extent.lowerBound)
                last = max(last ?? extent.upperBound, extent.upperBound)
            }
            guard let first, let last else { return nil }
            return first...last
        }
    }

    /// Ink over `columns` × `rows` of a bitmap (both clamped to it). A pixel
    /// is ink when any channel is more than `threshold` off `background`.
    static func rowInk(
        _ bitmap: Bitmap, columns: Range<Int>, rows: Range<Int>, background: (r: Int, g: Int, b: Int), threshold: Int = 8
    ) -> RowInk {
        let columns = columns.clamped(to: 0..<bitmap.width)
        let rows = rows.clamped(to: 0..<bitmap.height)
        var counts: [Int] = []
        var extents: [ClosedRange<Int>?] = []
        counts.reserveCapacity(rows.count)
        extents.reserveCapacity(rows.count)
        bitmap.rgba.withUnsafeBufferPointer { pixels in
            for y in rows {
                var count = 0
                var first = -1
                var last = -1
                var i = (y * bitmap.width + columns.lowerBound) * 4
                for x in columns {
                    let r: Int = Int(pixels[i]) - background.r
                    let g: Int = Int(pixels[i + 1]) - background.g
                    let b: Int = Int(pixels[i + 2]) - background.b
                    if abs(r) > threshold || abs(g) > threshold || abs(b) > threshold {
                        count += 1
                        if first < 0 { first = x }
                        last = x
                    }
                    i += 4
                }
                counts.append(count)
                extents.append(first < 0 ? nil : first...last)
            }
        }
        return RowInk(counts: counts, extents: extents)
    }

    /// Pixels over `columns` × `rows` (clamped to what both bitmaps hold)
    /// whose colour differs by more than `threshold` in any channel: 24 is
    /// the parity rule's, 0 counts every difference.
    static func differingPixels(
        _ a: Bitmap, _ b: Bitmap, columns: Range<Int>, rows: Range<Int>, threshold: Int = 24
    ) -> (count: Int, total: Int) {
        let columns = columns.clamped(to: 0..<min(a.width, b.width))
        let rows = rows.clamped(to: 0..<min(a.height, b.height))
        var count = 0
        a.rgba.withUnsafeBufferPointer { p in
            b.rgba.withUnsafeBufferPointer { q in
                for y in rows {
                    var i = (y * a.width + columns.lowerBound) * 4
                    var j = (y * b.width + columns.lowerBound) * 4
                    for _ in columns {
                        let dr: Int = Int(p[i]) - Int(q[j])
                        let dg: Int = Int(p[i + 1]) - Int(q[j + 1])
                        let db: Int = Int(p[i + 2]) - Int(q[j + 2])
                        if abs(dr) > threshold || abs(dg) > threshold || abs(db) > threshold { count += 1 }
                        i += 4
                        j += 4
                    }
                }
            }
        }
        return (count, columns.count * rows.count)
    }

    /// The OS a result line was measured on: "26.3", "18.5.1".
    static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let base = "\(version.majorVersion).\(version.minorVersion)"
        return version.patchVersion == 0 ? base : "\(base).\(version.patchVersion)"
    }
}

#endif
