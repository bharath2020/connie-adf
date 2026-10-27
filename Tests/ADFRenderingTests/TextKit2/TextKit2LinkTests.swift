#if canImport(UIKit)
import SwiftUI
import UIKit
import Testing
import ADFPreparation
@testable import ADFRendering

/// Link taps and link accessibility of TextKit 2 rows (plan §2.10): a tap
/// opens the exact URL only when it lands on the link's glyphs — wrapped,
/// coloured, right-to-left and emoji-adjacent links alike — and never on
/// whitespace or outside the text; VoiceOver gets one "Open link" custom
/// action per link. A linked row is laid out and drawn by its TextKit 1
/// stack and reported as such, never as a native TextKit 2 draw.
@Suite("TextKit 2 links", .serialized)
@MainActor
struct TextKit2LinkTests {
    static func link(_ text: String, _ href: String, marks: String = "") -> String {
        let link = "{\"type\":\"link\",\"attrs\":{\"href\":\"\(href)\"}}"
        return TK2Parity.adfText(text, marks: marks.isEmpty ? link : link + "," + marks)
    }

    /// A laid-out row for `fixture` at `width`, with an injected opener.
    @MainActor
    final class Row {
        let view = TextKit2RowView()
        var opened: [URL] = []
        let text: NSString

        init(_ fixture: TK2Parity.Fixture, env: TK2Parity.Environment = .init(), width: CGFloat) throws {
            let inputs = try TK2Parity.inputs(fixture, env: env)
            text = NSString(string: String(inputs.text.characters))
            view.apply(inputs)
            let size = view.measuredSize(forProposedWidth: width)
            view.frame = CGRect(origin: .zero, size: size)
            view.layoutIfNeeded()
            view.openURL = { [unowned self] url in self.opened.append(url) }
        }

        /// Centres of the glyph-segment rects of `substring`.
        func centres(of substring: String) throws -> [CGPoint] {
            let range = text.range(of: substring)
            try #require(range.location != NSNotFound, "'\(substring)' not in the row text")
            let rects = view.segmentRects(for: range)
            // Never vacuous: every caller loops over these.
            try #require(!rects.isEmpty, "'\(substring)' has no glyph rects")
            return rects.map { CGPoint(x: $0.midX, y: $0.midY) }
        }
    }

    @Test("a link wrapped over several lines opens its URL from every line")
    func wrappedLink() async throws {
        let linkText = "the complete release notes for the TextKit two reader port"
        let fixture = try await TK2Parity.fixture("wrapped", content:
            TK2Parity.adfText("Read ") + "," + Self.link(linkText, "https://example.com/notes?a=1&b=2") + "," + TK2Parity.adfText(" today."))
        let row = try Row(fixture, width: 200)
        let centres = try row.centres(of: linkText)
        #expect(centres.count >= 2, "link should wrap at 200 pt, got \(centres.count) segment(s)")
        for point in centres {
            #expect(row.view.openLink(at: point))
        }
        #expect(row.opened == Array(repeating: URL(string: "https://example.com/notes?a=1&b=2")!, count: centres.count))
    }

    @Test("a coloured link opens its URL and keeps the author's colour")
    func colouredLink() async throws {
        let fixture = try await TK2Parity.fixture("coloured", content:
            TK2Parity.adfText("See ") + "," + Self.link("the red link", "https://example.com/red", marks: "{\"type\":\"textColor\",\"attrs\":{\"color\":\"#ff5630\"}}")
            + "," + TK2Parity.adfText(" for details."))
        let row = try Row(fixture, width: 370)
        for point in try row.centres(of: "the red link") {
            #expect(row.view.openLink(at: point))
        }
        #expect(row.opened == [URL(string: "https://example.com/red")!])
        // TextKit must not restyle the run with its own link colour.
        let attributed = TextKit2TextBuilder.attributedString(for: try TK2Parity.inputs(fixture, env: .init()), linkColor: .blue)
        let colour = try #require(attributed.attribute(.foregroundColor, at: row.text.range(of: "red").location, effectiveRange: nil) as? UIColor)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        colour.getRed(&r, green: &g, blue: &b, alpha: &a)
        #expect(abs(r - 1) < 0.01 && abs(g - 0x56 / 255.0) < 0.01 && abs(b - 0x30 / 255.0) < 0.01)
        #expect(attributed.attribute(.link, at: row.text.range(of: "red").location, effectiveRange: nil) == nil)
    }

    @Test("a right-to-left link opens its URL under both layout directions")
    func rightToLeftLink() async throws {
        let fixture = try await TK2Parity.fixture("rtl", content:
            TK2Parity.adfText("اقرأ ") + "," + Self.link("ملاحظات الإصدار", "https://example.com/ar") + "," + TK2Parity.adfText(" اليوم"))
        for direction in [LayoutDirection.rightToLeft, .leftToRight] {
            let row = try Row(fixture, env: .init(direction: direction), width: 370)
            for point in try row.centres(of: "ملاحظات الإصدار") {
                #expect(row.view.openLink(at: point), "\(direction)")
            }
            #expect(row.opened == [URL(string: "https://example.com/ar")!], "\(direction)")
        }
    }

    @Test("a link between emoji opens; the emoji themselves do not")
    func emojiAdjacentLink() async throws {
        let fixture = try await TK2Parity.fixture("emoji", content:
            TK2Parity.adfText("👍🏽") + "," + Self.link("go", "https://example.com/go") + "," + TK2Parity.adfText("👨‍👩‍👧‍👦 done"))
        let row = try Row(fixture, width: 370)
        for point in try row.centres(of: "go") {
            #expect(row.view.openLink(at: point))
        }
        for point in try row.centres(of: "👍🏽") + row.centres(of: "👨‍👩‍👧‍👦") {
            #expect(!row.view.openLink(at: point))
        }
        #expect(row.opened == [URL(string: "https://example.com/go")!])
    }

    @Test("taps on whitespace, past a line's end or outside the row open nothing")
    func missesAreRejected() async throws {
        let fixture = try await TK2Parity.fixture("misses", content:
            Self.link("A link that ends the first line and", "https://example.com/x") + "," + TK2Parity.adfText(" then plain words."))
        let row = try Row(fixture, width: 250)
        let layout = row.view.layoutResult(forProposedWidth: 250)
        try #require(layout.lines.count >= 2)
        let last = try #require(layout.lines.last)
        // Past the end of the (plain) last line, inside the row.
        #expect(!row.view.openLink(at: CGPoint(x: 248, y: last.frame.midY)))
        // The space between words inside the link counts as the link's
        // glyph run (segment rects cover it); a point between lines does not
        // exist in a tight layout, so check outside the bounds instead.
        #expect(!row.view.openLink(at: CGPoint(x: 10, y: -5)))
        #expect(!row.view.openLink(at: CGPoint(x: 10, y: row.view.bounds.maxY + 5)))
        #expect(!row.view.openLink(at: CGPoint(x: -3, y: layout.lines[0].frame.midY)))
        // The plain words on the last line.
        for point in try row.centres(of: "plain words") {
            #expect(!row.view.openLink(at: point))
        }
        #expect(row.opened.isEmpty)
    }

    @Test("each link is an 'Open link <host>' custom action that opens it")
    func accessibilityActions() async throws {
        let fixture = try await TK2Parity.fixture("a11y", content:
            Self.link("one", "https://one.example.com/a") + "," + TK2Parity.adfText(" and ") + "," + Self.link("two", "https://two.example.com/b"))
        let row = try Row(fixture, width: 370)
        let actions = try #require(row.view.accessibilityCustomActions)
        #expect(actions.map(\.name) == ["Open link one.example.com", "Open link two.example.com"])
        for action in actions {
            _ = action.actionHandler?(action)
        }
        #expect(row.opened == [URL(string: "https://one.example.com/a")!, URL(string: "https://two.example.com/b")!])
        #expect(row.view.isAccessibilityElement)
        #expect(row.view.accessibilityLabel == "one and two")
        #expect(row.view.accessibilityValue == nil)
    }

    @Test("a hosted row delivers taps through SwiftUI's openURL action")
    func swiftUIOpenURL() async throws {
        let fixture = try await TK2Parity.fixture("hosted", content:
            TK2Parity.adfText("Open ") + "," + Self.link("the hosted link", "https://example.com/hosted"))
        let box = URLBox()
        let root = TK2Parity.hosted(fixture, arm: .textKit2, env: .init())
            .environment(\.openURL, OpenURLAction { url in
                MainActor.assumeIsolated { box.urls.append(url) }
                return .handled
            })
            .frame(width: 370, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 370, height: 300))
        let host = UIHostingController(rootView: root)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        let view = try #require(Self.firstRow(in: host.view))
        let range = (String(try #require(fixture.describableText).characters) as NSString).range(of: "the hosted link")
        let rect = try #require(view.segmentRects(for: range).first)
        #expect(view.openLink(at: CGPoint(x: rect.midX, y: rect.midY)))
        #expect(box.urls == [URL(string: "https://example.com/hosted")!])
    }

    @Test("a linked row counts as TextKit 1-backed; its draws never count as native TextKit 2")
    func textKit1BackedCounters() async throws {
        let diagnostics = TextKit2Diagnostics.shared
        let fixture = try await TK2Parity.fixture("counted", content:
            TK2Parity.adfText("Read ") + "," + Self.link("the notes", "https://example.com/notes"))
        // Read after the last suspension: rows of earlier tests can be
        // released across one.
        let rowsBefore = diagnostics.textKit1BackedRowCount
        let row = try Row(fixture, width: 370)
        let view = row.view
        #expect(view.isTextKit1Backed)
        #expect(diagnostics.textKit1BackedRowCount == rowsBefore + 1)
        let native = diagnostics.nativeDrawCount
        let backed = diagnostics.textKit1BackedDrawCount
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        _ = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { context in
            view.layer.render(in: context.cgContext)
        }
        #expect(diagnostics.textKit1BackedDrawCount > backed)
        #expect(diagnostics.nativeDrawCount == native, "a TextKit 1 draw counted as native")
        // Release: `TextKit2DiagnosticsTests` (switching back to SwiftUI).
    }

    @Test("only a row with a link carries a tap recognizer")
    func recognizerOnlyWithLinks() async throws {
        let plain = try Row(try await TK2Parity.plain("plain", "No link here."), width: 370)
        #expect(plain.view.gestureRecognizers?.isEmpty ?? true)
        let linked = try Row(try await TK2Parity.fixture("one-link", content: Self.link("a link", "https://example.com")), width: 370)
        #expect(linked.view.gestureRecognizers?.count == 1)
        // New text without a link drops it again.
        linked.view.apply(try TK2Parity.inputs(try await TK2Parity.plain("plain-again", "No link now."), env: .init()))
        #expect(linked.view.gestureRecognizers?.isEmpty ?? true)
    }

    @MainActor
    final class URLBox {
        var urls: [URL] = []
    }

    static func firstRow(in view: UIView) -> TextKit2RowView? {
        if let row = view as? TextKit2RowView { return row }
        for subview in view.subviews {
            if let row = firstRow(in: subview) { return row }
        }
        return nil
    }
}
#endif
