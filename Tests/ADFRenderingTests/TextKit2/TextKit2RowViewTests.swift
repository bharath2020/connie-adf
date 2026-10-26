#if canImport(UIKit)
import SwiftUI
import UIKit
import Testing
import ADFModel
import ADFPreparation
@testable import ADFRendering

private struct ScaledOne: View {
    @ScaledMetric(relativeTo: .body) private var one: CGFloat = 1
    var body: some View { Color.clear.frame(width: 10, height: one * 3000) }
}

/// The row view's sizing and drawing contract (plan §2.8, §4.5f):
/// deterministic, memoized in a bounded per-width cache, never
/// self-invalidating, geometry re-synced to the drawn width; the font
/// resolver preserves text-style metrics.
@Suite("TextKit 2 row view", .serialized)
@MainActor
struct TextKit2RowViewTests {
    static let sentence = "The quick brown fox jumps over the lazy dog while seventeen purple elephants rehearse Beethoven near a shimmering river bank at dawn"

    private func text(_ string: String, spec: ADFFontSpec = ADFFontSpec(textStyle: .body)) -> AttributedString {
        var text = AttributedString(string)
        text.font = .body
        text.adfFontSpec = spec
        return text
    }

    private func inputs(_ string: String, size: DynamicTypeSize = .large) -> TextKit2RenderInputs {
        TextKit2RenderInputs(text: text(string), sizeCategory: size.uiContentSizeCategory, displayScale: TK2Parity.nativeScale)
    }

    // MARK: Sizing and cache

    @Test("layout results are deterministic and memoized per width")
    func measurementMemo() {
        let view = TextKit2RowView()
        view.apply(inputs(Self.sentence))
        let first = view.layoutResult(forProposedWidth: 370)
        let relayouts = view.relayoutCount
        #expect(view.layoutResult(forProposedWidth: 370) == first)
        #expect(view.relayoutCount == relayouts, "re-measuring a measured width must not relayout")

        let wide = view.layoutResult(forProposedWidth: 640)
        #expect(view.relayoutCount == relayouts + 1)
        #expect(wide.size.height < first.size.height)
        #expect(wide.width == 640)
        #expect(wide.size.width <= 640, "the row hugs its widest line, like Text")
        #expect(wide.lineCount < first.lineCount)
        #expect(view.layoutResult(forProposedWidth: 370) == first)
        #expect(view.relayoutCount == relayouts + 1, "a memoized width replays without relayout")

        // Same inputs on a fresh view: same answer.
        let other = TextKit2RowView()
        other.apply(inputs(Self.sentence))
        #expect(other.layoutResult(forProposedWidth: 370) == first)
    }

    @Test("the width cache is bounded to four entries, least recently used evicted")
    func boundedCache() {
        let view = TextKit2RowView()
        view.apply(inputs(Self.sentence))
        for width in [CGFloat(300), 320, 340, 360] { _ = view.layoutResult(forProposedWidth: width) }
        #expect(view.cachedWidths == [300, 320, 340, 360])
        _ = view.layoutResult(forProposedWidth: 300)
        #expect(view.cachedWidths == [320, 340, 360, 300])
        _ = view.layoutResult(forProposedWidth: 380)
        #expect(view.cachedWidths == [340, 360, 300, 380], "320 was least recently used")
    }

    @Test("proposals: nil and infinite give the natural width; zero gives .zero without layout")
    func proposals() {
        let view = TextKit2RowView()
        view.apply(inputs("Short"))
        let relayouts = view.relayoutCount
        #expect(view.layoutResult(forProposedWidth: 0) == .zero)
        #expect(view.relayoutCount == relayouts, "a zero proposal performs no layout")

        let natural = view.measuredSize(forProposedWidth: nil)
        #expect(natural.width > 0 && natural.width < 100)
        let scale = TK2Parity.nativeScale
        #expect((natural.width * scale).rounded() == natural.width * scale, "natural width is pixel-aligned")
        #expect(view.measuredSize(forProposedWidth: .infinity) == natural)
        #expect(view.measuredSize(forProposedWidth: 370).height == natural.height)
        // Placed at its natural width (which the 370 proposal also hugs
        // to), the row draws a layout whose text fits those bounds.
        view.frame = CGRect(origin: .zero, size: natural)
        view.layoutIfNeeded()
        let rects = view.segmentRects(for: NSRange(location: 0, length: 5))
        #expect(!rects.isEmpty)
        #expect(rects.allSatisfy { $0.minX >= -0.01 && $0.maxX <= natural.width + 0.01 }, "\(rects) outside \(natural.width)")
    }

    @Test("an aligned row hugs its lines and draws them aligned within its bounds")
    func alignedHugging() throws {
        for (alignment, direction) in [(ADFAlignment?.none, LayoutDirection.leftToRight), (.center, .leftToRight), (.end, .leftToRight), (.none, .rightToLeft), (.center, .rightToLeft)] {
            let view = TextKit2RowView()
            view.apply(TextKit2RenderInputs(text: text("Short line"), alignment: alignment, layoutDirection: direction))
            let result = view.layoutResult(forProposedWidth: 370)
            #expect(result.width == 370)
            #expect(result.size.width < 200, "hugging width \(result.size.width)")
            // SwiftUI places the row at its reported width.
            view.frame = CGRect(origin: .zero, size: result.size)
            view.layoutIfNeeded()
            #expect(view.currentContainerWidth == 370, "drawn from the measured layout, no relayout")
            let rect = try #require(view.segmentRects(for: NSRange(location: 0, length: 10)).first)
            let label = "\(String(describing: alignment)) \(direction)"
            #expect(rect.minX >= -0.01 && rect.maxX <= result.size.width + 0.01, "\(label): \(rect) outside \(result.size.width)")
            #expect(result.size.width - rect.width < 1, "\(label): \(rect) does not fill \(result.size.width)")
            #expect(view.canvasFrame.minX == 0 && view.canvasFrame.width == result.size.width, "\(label): canvas \(view.canvasFrame)")
        }
    }

    @Test("reordered proposals (A, B, A) keep A's height and draw geometry at A")
    func reorderedProposals() throws {
        let view = TextKit2RowView()
        view.apply(inputs(Self.sentence))
        let a = view.layoutResult(forProposedWidth: 300)
        _ = view.layoutResult(forProposedWidth: 640)
        #expect(view.currentContainerWidth == 640, "the single layout manager now sits at B")
        let again = view.layoutResult(forProposedWidth: 300)
        #expect(again == a)
        // SwiftUI places the row at A: drawing and hit-testing must use A's
        // geometry, not the layout manager's last width.
        view.frame = CGRect(x: 0, y: 0, width: 300, height: a.size.height)
        view.layoutIfNeeded()
        #expect(view.currentContainerWidth == 300)
        let lastLine = try #require(a.lines.last)
        let rects = view.segmentRects(for: lastLine.range)
        #expect(rects.allSatisfy { abs($0.minY - lastLine.frame.minY) < 0.01 }, "segments at A's line positions: \(rects) vs \(lastLine.frame)")
    }

    @Test("re-applying equal inputs is a no-op; new content at a stable row clears the cache")
    func contentChange() {
        let view = TextKit2RowView()
        view.apply(inputs("one"), ownerID: "7")
        let size = view.measuredSize(forProposedWidth: 300)
        let relayouts = view.relayoutCount
        view.apply(inputs("one"), ownerID: "7")
        #expect(view.measuredSize(forProposedWidth: 300) == size)
        #expect(view.relayoutCount == relayouts)

        view.apply(inputs(Self.sentence + " " + Self.sentence), ownerID: "7")
        #expect(view.cachedWidths.isEmpty || view.cachedWidths == [view.currentContainerWidth])
        #expect(view.measuredSize(forProposedWidth: 300).height > size.height)
    }

    @Test("a Dynamic Type change re-measures at the new size")
    func dynamicTypeChange() {
        let view = TextKit2RowView()
        view.apply(inputs("one"))
        let large = view.measuredSize(forProposedWidth: 300)
        view.apply(inputs("one", size: .accessibility3))
        let ax3 = view.measuredSize(forProposedWidth: 300)
        #expect(ax3.height > large.height)
        let fresh = TextKit2RowView()
        fresh.apply(inputs("one", size: .accessibility3))
        #expect(fresh.measuredSize(forProposedWidth: 300) == ax3)
    }

    @Test("the canvas covers the bounds and the ink's vertical reach; horizontally it is the bounds")
    func inkNeverClipped() async throws {
        let strings = ["Ångström ÅÊÎ Ṏ", "Italic overhang fff", "emoji 👩🏽‍💻🇯🇵 tall ˚", "g̈ÿj descenders"]
        for string in strings {
            for spec in [ADFFontSpec(textStyle: .body), ADFFontSpec(textStyle: .title, bold: true, italic: true)] {
                let view = TextKit2RowView()
                view.apply(TextKit2RenderInputs(text: text(string, spec: spec), displayScale: TK2Parity.nativeScale))
                let result = view.layoutResult(forProposedWidth: 300)
                view.frame = CGRect(origin: .zero, size: result.size)
                view.layoutIfNeeded()
                #expect(view.canvasFrame.contains(view.bounds))
                // Text clips glyph overhang at its frame's sides (measured:
                // an indented line-initial "j"), never above or below.
                #expect(view.canvasFrame.minX == view.bounds.minX && view.canvasFrame.width == view.bounds.width)
                #expect(view.canvasFrame.minY <= result.inkBounds.minY && view.canvasFrame.maxY >= result.inkBounds.maxY, "\(string): ink \(result.inkBounds) outside canvas \(view.canvasFrame)")
            }
        }
    }

    @Test("the TextKit 2 sources never self-invalidate")
    func noSelfInvalidation() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ADFRendering/TextKit2")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".swift") }
        #expect(files.count >= 6)
        for file in files {
            let source = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
            for forbidden in ["invalidateIntrinsicContentSize", "setNeedsLayout", "onScrollVisibilityChange", "@State"] {
                #expect(!source.contains(forbidden), "\(file) contains \(forbidden)")
            }
        }
    }

    // MARK: Accessibility

    @Test("accessibility: one element with the plain text, heading traits, no value, owner identifier")
    func accessibility() {
        let view = TextKit2RowView()
        view.apply(TextKit2RenderInputs(text: text("Heading text", spec: ADFFontSpec(textStyle: .title, bold: true)), isHeading: true), ownerID: "3")
        #expect(view.isAccessibilityElement)
        #expect(view.accessibilityLabel == "Heading text")
        #expect(view.accessibilityValue == nil)
        #expect(view.accessibilityTraits.contains(.header))
        #expect(view.accessibilityTraits.contains(.staticText))
        #expect(view.accessibilityIdentifier == "tk2-row:3")
        #expect(view.accessibilityCustomActions == nil)

        let body = TextKit2RowView()
        body.apply(TextKit2RenderInputs(text: text("Body text")))
        #expect(!body.accessibilityTraits.contains(.header))
    }

    // MARK: Font resolver

    nonisolated static let categories: [UIContentSizeCategory] = [
        .extraSmall, .small, .medium, .large, .extraLarge, .extraExtraLarge, .extraExtraExtraLarge,
        .accessibilityMedium, .accessibilityLarge, .accessibilityExtraLarge,
        .accessibilityExtraExtraLarge, .accessibilityExtraExtraExtraLarge,
    ]

    @Test("every text style resolves at every category to the preferred font's size and metrics")
    func resolverCoversLadder() {
        for style in ADFFontSpec.TextStyle.allCases {
            for category in Self.categories {
                let traits = UITraitCollection(preferredContentSizeCategory: category)
                let expected = UIFont.preferredFont(forTextStyle: TextKit2FontResolver.uiTextStyle(style), compatibleWith: traits)
                let font = TextKit2FontResolver.font(for: ADFFontSpec(textStyle: style), category: category)
                #expect(font.pointSize == expected.pointSize, "\(style) \(category.rawValue)")
                #expect(font.ascender == expected.ascender && font.descender == expected.descender && font.leading == expected.leading, "\(style) \(category.rawValue) metrics")
            }
        }
    }

    @Test("bold, italic and monospaced traits are present")
    func resolverTraits() {
        let bold = TextKit2FontResolver.font(for: ADFFontSpec(textStyle: .body, bold: true), category: .large)
        #expect(bold.fontDescriptor.symbolicTraits.contains(.traitBold))
        let italic = TextKit2FontResolver.font(for: ADFFontSpec(textStyle: .body, italic: true), category: .large)
        #expect(italic.fontDescriptor.symbolicTraits.contains(.traitItalic))
        let both = TextKit2FontResolver.font(for: ADFFontSpec(textStyle: .title2, bold: true, italic: true), category: .accessibilityExtraLarge)
        #expect(both.fontDescriptor.symbolicTraits.contains(.traitBold))
        #expect(both.fontDescriptor.symbolicTraits.contains(.traitItalic))
        let mono = TextKit2FontResolver.font(for: ADFFontSpec(textStyle: .body, monospaced: true), category: .large)
        #expect(mono.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) || mono.fontName.localizedCaseInsensitiveContains("mono"))
        let monoBold = TextKit2FontResolver.font(for: ADFFontSpec(textStyle: .footnote, bold: true, monospaced: true), category: .extraExtraExtraLarge)
        #expect(monoBold.fontDescriptor.symbolicTraits.contains(.traitBold))
        #expect(monoBold.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) || monoBold.fontName.localizedCaseInsensitiveContains("mono"))
    }

    @Test("the Bold Text setting resolves heavier faces at unchanged metrics")
    func resolverLegibilityWeight() {
        let regular = TextKit2FontResolver.font(for: ADFFontSpec(textStyle: .body), category: .large)
        let boldText = TextKit2FontResolver.font(for: ADFFontSpec(textStyle: .body), category: .large, legibilityWeight: .bold)
        #expect(regular.fontName != boldText.fontName || regular.fontDescriptor != boldText.fontDescriptor)
        #expect(boldText.pointSize == regular.pointSize)
    }

    @Test("monospaced runs keep the text style's line metrics", arguments: categories)
    func monoKeepsMetrics(category: UIContentSizeCategory) {
        let body = TextKit2FontResolver.font(for: ADFFontSpec(textStyle: .body), category: category)
        let mono = TextKit2FontResolver.font(for: ADFFontSpec(textStyle: .body, monospaced: true), category: category)
        #expect(mono.pointSize == body.pointSize)
        #expect(abs(mono.ascender - body.ascender) < 0.001)
        #expect(abs(mono.descender - body.descender) < 0.001)
        #expect(abs(mono.leading - body.leading) < 0.001)
        #expect(abs(mono.lineHeight - body.lineHeight) < 0.001)
    }

    @Test("resolved fonts are memoized")
    func resolverMemo() {
        let spec = ADFFontSpec(textStyle: .headline, italic: true)
        let a = TextKit2FontResolver.font(for: spec, category: .extraLarge)
        let b = TextKit2FontResolver.font(for: spec, category: .extraLarge)
        #expect(a === b)
    }

    @Test("the Dynamic Type bridge is exhaustive, distinct and ordered")
    func bridge() {
        let mapped = DynamicTypeSize.allCases.map(\.uiContentSizeCategory)
        #expect(Set(mapped).count == DynamicTypeSize.allCases.count)
        #expect(mapped == Self.categories)
        for (size, category) in zip(DynamicTypeSize.allCases, mapped) {
            #expect(size.isAccessibilitySize == category.isAccessibilityCategory)
        }
    }

    @Test("baseline offsets scale exactly like SwiftUI's @ScaledMetric(relativeTo: .body)", arguments: DynamicTypeSize.allCases)
    func baselineScaleMatchesScaledMetric(size: DynamicTypeSize) {
        let host = UIHostingController(rootView: ScaledOne().dynamicTypeSize(size))
        host.safeAreaRegions = []
        let measured: CGSize = host.sizeThatFits(in: CGSize(width: 10, height: CGFloat.greatestFiniteMagnitude))
        let swiftUI = measured.height / 3000
        let textKit2 = TextKit2TextBuilder.baselineScale(for: size.uiContentSizeCategory)
        #expect(abs(swiftUI - textKit2) < 0.001, "\(size): swiftUI=\(swiftUI) textKit2=\(textKit2)")
    }

    // MARK: Builder

    @Test("pixel ceil uses SwiftUI's arithmetic and is a fixed point")
    func pixelCeil() {
        for scale in [CGFloat(2), 3] {
            for raw in stride(from: CGFloat(10), to: 200, by: 0.0371) {
                let value = TextKit2RowView.pixelCeil(raw, scale: scale)
                #expect(value >= raw - 1e-9)
                #expect(value - raw < 1 / scale + 1e-9)
                #expect(TextKit2RowView.pixelCeil(value, scale: scale) == value, "\(raw) @\(scale) → \(value) is not stable")
            }
        }
        #expect(TextKit2RowView.pixelCeil(42.287, scale: 3) == 127 * (1 / CGFloat(3)))
    }

    @Test("foreground precedence: prepared colour, inherited colour, label")
    func foregroundPrecedence() {
        var authored = text("red ")
        authored.foregroundColor = .red
        let plain = text("plain")
        func colour(_ inputs: TextKit2RenderInputs, at offset: Int) -> UIColor? {
            TextKit2TextBuilder.attributedString(for: inputs).attribute(.foregroundColor, at: offset, effectiveRange: nil) as? UIColor
        }
        func same(_ a: UIColor?, _ b: UIColor) -> Bool {
            let light = UITraitCollection(userInterfaceStyle: .light)
            guard let a else { return false }
            return a.resolvedColor(with: light).cgColor.components == b.resolvedColor(with: light).cgColor.components
        }
        let base = TextKit2RenderInputs(text: authored + plain)
        #expect(same(colour(base, at: 0), UIColor(Color.red)))
        #expect(same(colour(base, at: 4), UIColor.label))

        var inherited = base
        inherited.inheritedForeground = .green
        #expect(same(colour(inherited, at: 0), UIColor(Color.red)), "prepared colour beats inherited")
        #expect(same(colour(inherited, at: 4), UIColor(Color.green)))
    }

    @Test("alignment resolves against the SwiftUI layout direction")
    func alignmentFromLayoutDirection() {
        #expect(TextKit2TextBuilder.nsAlignment(nil, layoutDirection: .leftToRight) == .left)
        #expect(TextKit2TextBuilder.nsAlignment(nil, layoutDirection: .rightToLeft) == .right)
        #expect(TextKit2TextBuilder.nsAlignment(.center, layoutDirection: .rightToLeft) == .center)
        #expect(TextKit2TextBuilder.nsAlignment(.end, layoutDirection: .leftToRight) == .right)
        #expect(TextKit2TextBuilder.nsAlignment(.end, layoutDirection: .rightToLeft) == .left)
    }
}
#endif
