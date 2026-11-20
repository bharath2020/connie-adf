import CoreGraphics
import Foundation
import SwiftUI
import Testing
import ADFModel
import ADFPreparation
@testable import ADFRendering
#if canImport(UIKit)
import UIKit
#endif

private typealias SUI = AttributeScopes.SwiftUIAttributes
private typealias EmojiAttribute = AttributeScopes.ADFAttributes.EmojiAttribute

/// The shared custom-emoji stage → displayed-text function, the spoken text
/// derived from it, and what TextKit 2 makes of it: what both renderers
/// draw and speak.
@Suite("Emoji display")
@MainActor
struct EmojiDisplayTests {
    private static let custom6 = EmojiKey(id: nil, shortName: ":ld-custom-6:")
    private static let logo = EmojiKey(id: "atlassian-logo", shortName: ":custom-logo:")

    private static func emoji(_ shortName: String, id: String? = nil) -> String {
        let idPart = id.map { #","id":"\#($0)""# } ?? ""
        return #"{"type":"emoji","attrs":{"shortName":"\#(shortName)"\#(idPart)}}"#
    }

    private static func text(_ string: String) -> String {
        #"{"type":"text","text":"\#(string)"}"#
    }

    /// A paragraph's composed owner (segments and keys).
    private func prepared(_ content: String...) async throws -> InlineComposer.ComposedInline {
        let json = #"{"version":1,"type":"doc","content":[{"type":"paragraph","content":[\#(content.joined(separator: ","))]}]}"#
        let doc = try await ADFParser().parse(Data(json.utf8))
        guard case .paragraph(let inline, _) = try #require(doc.root.children.first).kind else {
            throw EmojiTestFailure("not a paragraph")
        }
        return InlineComposer(theme: .default).composeOwner(inline)
    }

    private static func merged(_ segments: [InlineSegment]) -> AttributedString {
        segments.reduce(into: AttributedString()) { result, segment in
            if case .text(let text) = segment { result.append(text) }
        }
    }

    private static func shown(_ text: AttributedString) -> [EmojiShown] {
        text.runs[EmojiShownAttribute.self].compactMap { $0.0 }
    }

    private static func image(width: Int = 4, height: Int = 4) -> ADFResolvedImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ADFResolvedImage(cgImage: context.makeImage()!, scale: 2)
    }

    // MARK: No resolver

    @Test("no resolver: the short name as authored, in the secondary colour, never ::name::")
    func noResolverShowsShortName() async throws {
        let composed = try await prepared(Self.text("a "), Self.emoji(":ld-custom-6:"), Self.text(" b"))
        let displayed = Self.merged(EmojiDisplay.apply(nil, to: composed.segments))
        #expect(String(displayed.characters) == "a :ld-custom-6: b")
        #expect(!String(displayed.characters).contains("::"))
        #expect(!String(displayed.characters).contains("\u{FFFC}"))
        let pieces = Self.shown(displayed)
        #expect(pieces == [EmojiShown(key: Self.custom6, kind: .shortName, occurrence: 0)])
        let range = try #require(displayed.characters.firstRange(of: ":ld-custom-6:"))
        let run = try #require(displayed[range].runs.first)
        #expect(run[SUI.ForegroundColorAttribute.self] == Color.secondary)
        #expect(run.adfFontSpec != nil)
        #expect(displayed.runs[EmojiAttribute.self].allSatisfy { $0.0 == nil })
    }

    @Test("a short name without colons is shown without colons too")
    func shortNameWithoutColons() async throws {
        let composed = try await prepared(Self.emoji("party"))
        let displayed = Self.merged(EmojiDisplay.apply(nil, to: composed.segments))
        #expect(String(displayed.characters) == "party")
    }

    @Test("segments without custom emoji come back untouched")
    func noEmojiIsIdentity() async throws {
        let composed = try await prepared(Self.text("plain "), #"{"type":"emoji","attrs":{"shortName":":rocket:","id":"1f680","text":"🚀"}}"#)
        #expect(composed.emojiKeys.isEmpty)
        #expect(EmojiDisplay.apply(nil, to: composed.segments) == composed.segments)
        #expect(EmojiDisplay.apply([:], to: composed.segments) == composed.segments)
    }

    @Test("adjacent emoji with the same key are separate pieces, in order")
    func adjacentSameKey() async throws {
        let composed = try await prepared(Self.emoji(":ld-custom-6:"), Self.emoji(":ld-custom-6:"))
        let displayed = Self.merged(EmojiDisplay.apply(nil, to: composed.segments))
        #expect(String(displayed.characters) == ":ld-custom-6::ld-custom-6:")
        #expect(Self.shown(displayed).map(\.occurrence) == [0, 1])
        #expect(SmartLinkDisplay.accessibilityText(of: displayed) == "ld custom 6ld custom 6")
    }

    // MARK: With a resolver

    @Test("pending (or no stage yet): one U+FFFC drawn as a blank box")
    func pendingIsBox() async throws {
        let composed = try await prepared(Self.text("x "), Self.emoji(":custom-logo:", id: "atlassian-logo"))
        for stages in [[Self.logo: EmojiStage.pending], [:]] {
            let displayed = Self.merged(EmojiDisplay.apply(stages, to: composed.segments))
            #expect(String(displayed.characters) == "x \u{FFFC}")
            #expect(Self.shown(displayed) == [EmojiShown(key: Self.logo, kind: .box, occurrence: 0)])
        }
    }

    @Test("resolved: the same single U+FFFC, now the image; failed: the short name")
    func resolvedAndFailed() async throws {
        let composed = try await prepared(Self.emoji(":custom-logo:", id: "atlassian-logo"), Self.emoji(":ld-custom-6:"))
        let image = Self.image()
        let stages: [EmojiKey: EmojiStage] = [Self.logo: .resolved(image), Self.custom6: .failed]
        let displayed = Self.merged(EmojiDisplay.apply(stages, to: composed.segments))
        #expect(String(displayed.characters) == "\u{FFFC}:ld-custom-6:")
        #expect(Self.shown(displayed) == [
            EmojiShown(key: Self.logo, kind: .image(EmojiImage(image)), occurrence: 0),
            EmojiShown(key: Self.custom6, kind: .shortName, occurrence: 1),
        ])
        // The same stages display equal text (a TextKit 2 row's inputs stay
        // equal, so it does not rebuild).
        #expect(Self.merged(EmojiDisplay.apply(stages, to: composed.segments)) == displayed)
    }

    @Test("stage equality compares the bitmap identity")
    func stageEquality() {
        let image = Self.image()
        #expect(EmojiStage.resolved(image) == .resolved(image))
        #expect(EmojiStage.resolved(image) != .resolved(Self.image()))
        #expect(EmojiStage.pending != .failed)
    }

    @Test("squared pads a non-square image to a square and keeps a square one")
    func squared() {
        let square = Self.image(width: 4, height: 4)
        #expect(EmojiDisplay.squared(square).cgImage === square.cgImage)
        let wide = EmojiDisplay.squared(Self.image(width: 8, height: 4))
        #expect(wide.cgImage.width == 8 && wide.cgImage.height == 8)
        #expect(wide.scale == 2)
    }

    // MARK: Keys and spoken text

    @Test("keys found in segments match the composer's per-owner keys")
    func keysInSegments() async throws {
        let composed = try await prepared(
            Self.emoji(":b:"), Self.text(" "), Self.emoji(":custom-logo:", id: "atlassian-logo"), Self.emoji(":b:")
        )
        #expect(EmojiDisplay.keys(in: composed.segments) == composed.emojiKeys)
        #expect(composed.emojiKeys == [EmojiKey(id: nil, shortName: ":b:"), Self.logo])
    }

    @Test("spoken name: no colons, hyphens and underscores as spaces",
          arguments: [
              (":ld-custom-6:", "ld custom 6"),
              (":custom_logo:", "custom logo"),
              ("party-parrot", "party parrot"),
              ("::", "emoji"),
          ])
    func spokenName(shortName: String, spoken: String) {
        #expect(EmojiDisplay.spokenName(shortName) == spoken)
    }

    @Test("VoiceOver reads the emoji's name whatever it shows")
    func accessibilityText() async throws {
        let composed = try await prepared(Self.text("Ship "), Self.emoji(":ld-custom-6:"), Self.text(" now"))
        for stages: [EmojiKey: EmojiStage]? in [nil, [Self.custom6: .pending], [Self.custom6: .resolved(Self.image())], [Self.custom6: .failed]] {
            let displayed = Self.merged(EmojiDisplay.apply(stages, to: composed.segments))
            #expect(SmartLinkDisplay.accessibilityText(of: displayed) == "Ship ld custom 6 now")
        }
    }

    @Test("a chunk holding a displayed emoji becomes a spoken token in an atom paragraph")
    func atomParagraphToken() async throws {
        let composed = try await prepared(
            Self.text("hi "), #"{"type":"mention","attrs":{"id":"u1","text":"@Ann"}}"#, Self.text(" "), Self.emoji(":ld-custom-6:")
        )
        let displayed = EmojiDisplay.apply(nil, to: composed.segments)
        let tokens = SegmentedTextView.tokens(for: displayed, composesSmartLinks: true)
        let spoken = tokens.compactMap { token -> String? in
            if case .smartLinkText(_, let spoken) = token.kind { return spoken }
            return nil
        }
        #expect(spoken == ["ld custom 6"])
    }

    // MARK: TextKit 2 eligibility

    @Test("a paragraph with a custom emoji is TextKit 2 eligible, prepared and displayed")
    func eligibility() async throws {
        let composed = try await prepared(Self.text("Ship "), Self.emoji(":ld-custom-6:"), Self.text(" now"))
        #expect(!composed.segments.contains { if case .atom = $0 { true } else { false } })
        guard case .eligible = TextKit2Eligibility.verdict(composed.segments) else {
            Issue.record("prepared paragraph fell back")
            return
        }
        for stages: [EmojiKey: EmojiStage]? in [nil, [:], [Self.custom6: .resolved(Self.image())]] {
            let displayed = EmojiDisplay.apply(stages, to: composed.segments)
            guard case .eligible = TextKit2Eligibility.verdict(displayed, owner: .list) else {
                Issue.record("displayed paragraph fell back for \(String(describing: stages))")
                continue
            }
        }
    }

    @Test("the table of contents spells a heading's custom emoji as its short name")
    func headingTitle() async throws {
        let json = #"{"version":1,"type":"doc","content":[{"type":"heading","attrs":{"level":1},"content":[\#(Self.text("Launch ")),\#(Self.emoji(":ld-custom-6:"))]}]}"#
        let model = ADFDocumentModel()
        model.load(data: Data(json.utf8))
        for _ in 0..<2_500 where model.phase != .ready {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(model.phase == .ready)
        #expect(model.headings.map(\.title) == ["Launch :ld-custom-6:"])
    }

    // MARK: Line metrics

    /// A wrapping paragraph whose custom emoji sits on its second line, so
    /// the first baseline, the line pitch below the emoji and the height
    /// all show a line that grew.
    private static let wrappingContent = [
        text("The first line of this paragraph runs long enough to wrap, and then the second line holds"),
        emoji(":ld-custom-6:"),
        text(" before the third line closes the paragraph with several more words of plain text."),
    ]

    /// The SwiftUI leaf's merged text as `SegmentedTextView` draws it, at
    /// width 300: size and baselines as the layout around it reads them.
    private static func swiftUIMetrics(_ text: AttributedString) -> LeafMetrics {
        let reading = LeafMetricsReading()
        let layout = LeafMetricsProbe(reading: reading)
        let probe = layout {
            DisplayedText(text: text, composes: true, showsStage: true)
        }
        #if canImport(UIKit)
        let host = UIHostingController(rootView: probe)
        host.safeAreaRegions = []
        _ = host.sizeThatFits(in: CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        #else
        let host = NSHostingController(rootView: probe)
        _ = host.sizeThatFits(in: CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        #endif
        return reading.metrics
    }

    @Test("SwiftUI: a box or an image keeps the line's height and baselines, as the short name has them",
          arguments: [false, true])
    func swiftUILineMetrics(wraps: Bool) async throws {
        let content = wraps ? Self.wrappingContent : [Self.text("Ship "), Self.emoji(":ld-custom-6:"), Self.text(" now")]
        let composed = try await prepared(content.joined(separator: ","))
        let shortName = Self.swiftUIMetrics(Self.merged(EmojiDisplay.apply(nil, to: composed.segments)))
        #expect(shortName.height > 0)
        for (name, stages) in [
            ("pending", [Self.custom6: EmojiStage.pending]),
            ("resolved", [Self.custom6: .resolved(Self.image(width: 64, height: 64))]),
            ("failed", [Self.custom6: .failed]),
        ] {
            let shown = Self.swiftUIMetrics(Self.merged(EmojiDisplay.apply(stages, to: composed.segments)))
            #expect(shown.height == shortName.height, "\(name): height \(shown) vs short name \(shortName)")
            #expect(shown.firstBaseline == shortName.firstBaseline, "\(name): first baseline \(shown) vs \(shortName)")
            #expect(shown.lastBaseline == shortName.lastBaseline, "\(name): last baseline \(shown) vs \(shortName)")
        }
    }

    // MARK: TextKit 2 attachment

    #if canImport(UIKit)
    @Test("TextKit 2 and SwiftUI: the same line height and baselines for the short name, the box and the image",
          arguments: [false, true])
    func textKit2LineMetrics(wraps: Bool) async throws {
        let content = wraps ? Self.wrappingContent : [Self.text("Ship "), Self.emoji(":ld-custom-6:"), Self.text(" now")]
        let composed = try await prepared(content.joined(separator: ","))
        for (name, stages) in [
            ("short name", nil),
            ("pending", [Self.custom6: EmojiStage.pending]),
            ("resolved", [Self.custom6: .resolved(Self.image(width: 64, height: 64))]),
            ("failed", [Self.custom6: .failed]),
        ] as [(String, [EmojiKey: EmojiStage]?)] {
            let displayed = Self.merged(EmojiDisplay.apply(stages, to: composed.segments))
            let row = TextKit2RowView()
            row.apply(TextKit2RenderInputs(text: displayed, displayScale: TK2Parity.nativeScale))
            let result = row.layoutResult(forProposedWidth: 300)
            let swiftUI = Self.swiftUIMetrics(displayed)
            let label = "\(name): TextKit 2 \(result.size.height)/\(result.firstBaseline)/\(result.lastBaseline) SwiftUI \(swiftUI)"
            #expect(abs(result.size.height - swiftUI.height) < 0.01, "\(label)")
            #expect(abs(result.firstBaseline - swiftUI.firstBaseline) < 0.01, "\(label)")
            #expect(abs(result.lastBaseline - swiftUI.lastBaseline) < 0.01, "\(label)")
            // Wrapped: several lines (5 at body Large on a 300 pt column),
            // the emoji past the first, so a taller line would move later
            // baselines.
            #expect(wraps ? result.lineCount > 2 : result.lineCount == 1, "\(label): \(result.lineCount) lines")
        }
    }

    @Test("TextKit 2: a box or image is a square attachment of the ascent on the baseline; a short name is text")
    func textKit2Attachment() async throws {
        let composed = try await prepared(Self.text("a "), Self.emoji(":ld-custom-6:"))
        let font = TextKit2FontResolver.font(for: ADFFontSpec(textStyle: .body), category: .large)
        let side = (font.ascender * 6).rounded(.down) / 6
        #expect(side > 0 && side <= font.ascender)
        for stages: [EmojiKey: EmojiStage] in [[:], [Self.custom6: .resolved(Self.image())]] {
            let displayed = Self.merged(EmojiDisplay.apply(stages, to: composed.segments))
            let built = TextKit2TextBuilder.attributedString(
                for: TextKit2RenderInputs(text: displayed), linkColor: .systemBlue
            )
            #expect(built.string == "a \u{FFFC}")
            let shown = try #require(Self.shown(displayed).first)
            let made = try #require(TextKit2TextBuilder.emojiAttachment(shown.kind, font: font))
            #expect(made.bounds == CGRect(x: 0, y: 0, width: side, height: side), "made")
            let attachment = try #require(built.attribute(.attachment, at: 2, effectiveRange: nil) as? NSTextAttachment)
            #expect(attachment.bounds == CGRect(x: 0, y: 0, width: side, height: side), "built \(type(of: attachment)) \(String(describing: attachment.image?.size))")
        }
        let plain = Self.merged(EmojiDisplay.apply(nil, to: composed.segments))
        let built = TextKit2TextBuilder.attributedString(for: TextKit2RenderInputs(text: plain), linkColor: .systemBlue)
        #expect(built.string == "a :ld-custom-6:")
        #expect(built.attribute(.attachment, at: 2, effectiveRange: nil) == nil)
    }

    /// The bounding box, in points, of the pure-red pixels of a bitmap.
    private static func redBox(_ bitmap: TK2Parity.Bitmap) -> CGRect? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width {
                let p = bitmap[x, y]
                guard p.r > 200, p.g < 60, p.b < 60 else { continue }
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        let s = bitmap.scale
        return CGRect(x: CGFloat(minX) / s, y: CGFloat(minY) / s, width: CGFloat(maxX - minX + 1) / s, height: CGFloat(maxY - minY + 1) / s)
    }

    private static func render(in window: UIWindow, width: CGFloat) throws -> TK2Parity.Bitmap {
        window.backgroundColor = .white
        window.isHidden = false
        window.layoutIfNeeded()
        defer { window.isHidden = true }
        return try TK2Parity.bitmap(of: window, width: width)
    }

    @Test("a resolved image draws as a square of the ascent on both engines, in the same place")
    func resolvedImageDraws() async throws {
        let composed = try await prepared(Self.text("Ship "), Self.emoji(":ld-custom-6:"), Self.text(" now"))
        let image = Self.image(width: 64, height: 64)
        let displayed = Self.merged(EmojiDisplay.apply([Self.custom6: .resolved(image)], to: composed.segments))
        let side = EmojiDisplay.box(for: TextKit2FontResolver.font(for: ADFFontSpec(textStyle: .body), category: .large)).side

        // TextKit 2: the row draws natively (no link), the attachment's image
        // included.
        let row = TextKit2RowView()
        row.apply(TextKit2RenderInputs(text: displayed, displayScale: TK2Parity.nativeScale))
        let size = row.layoutResult(forProposedWidth: 300).size
        let rowWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        row.frame = CGRect(origin: .zero, size: size)
        rowWindow.addSubview(row)
        let rowBox = try #require(Self.redBox(try Self.render(in: rowWindow, width: 300)), "TextKit 2 drew no image")
        #expect(!row.isTextKit1Backed)

        // SwiftUI: the leaf's composed `Text`.
        let host = UIHostingController(rootView: DisplayedText(text: displayed, composes: true, showsStage: true)
            .frame(width: 300, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea())
        host.safeAreaRegions = []
        let hostWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        hostWindow.rootViewController = host
        let textBox = try #require(Self.redBox(try Self.render(in: hostWindow, width: 300)), "SwiftUI drew no image")
        hostWindow.rootViewController = nil

        for (name, box) in [("TextKit 2", rowBox), ("SwiftUI", textBox)] {
            #expect(abs(box.width - side) <= 1, "\(name): \(box) vs side \(side)")
            #expect(abs(box.height - side) <= 1, "\(name): \(box) vs side \(side)")
        }
        // The same place in the line on both engines.
        #expect(abs(rowBox.minX - textBox.minX) <= 1, "x: \(rowBox) vs \(textBox)")
        #expect(abs(rowBox.minY - textBox.minY) <= 1, "y: \(rowBox) vs \(textBox)")
    }
    #endif
}

private struct EmojiTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// A text leaf's size and baselines as the layout around it reads them.
private struct LeafMetrics: Equatable, CustomStringConvertible {
    var height: CGFloat = 0
    var firstBaseline: CGFloat = 0
    var lastBaseline: CGFloat = 0

    var description: String { "\(height)/\(firstBaseline)/\(lastBaseline)" }
}

private final class LeafMetricsReading: @unchecked Sendable {  // written and read on the main thread only
    var metrics = LeafMetrics()
}

/// Lays out its one subview at the proposal and records what a parent
/// reads of it: height and first and last text baselines.
private struct LeafMetricsProbe: Layout {
    let reading: LeafMetricsReading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let dimensions = subview.dimensions(in: ProposedViewSize(width: proposal.width, height: nil))
        reading.metrics = LeafMetrics(
            height: dimensions.height,
            firstBaseline: dimensions[VerticalAlignment.firstTextBaseline],
            lastBaseline: dimensions[VerticalAlignment.lastTextBaseline]
        )
        return CGSize(width: dimensions.width, height: dimensions.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}
