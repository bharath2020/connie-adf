#if canImport(UIKit)
import UIKit
import SwiftUI
import Testing
import ADFModel
import ADFPreparation
@testable import ADFRendering

/// Trivial `NSTextLocation` for the sizing tests: `attachmentBounds` must be
/// a pure function of `(atom, category)` and never read the location, so a
/// stub that always compares `.orderedSame` is sufficient.
final class NSTextLocationStub: NSObject, NSTextLocation {
    func compare(_ location: any NSTextLocation) -> ComparisonResult { .orderedSame }
}

@Suite("AtomAttachment") @MainActor
struct AtomAttachmentTests {
    private let large = UIContentSizeCategory.large.rawValue
    private let ax3 = UIContentSizeCategory.accessibilityExtraLarge.rawValue

    @Test func boundsAreDeterministicPerCategory() {
        let a = AtomAttachment(atom: .status(text: "done", color: .green), categoryRawValue: large)
        let b = AtomAttachment(atom: .status(text: "done", color: .green), categoryRawValue: large)
        #expect(a.pillSize == b.pillSize)
    }

    @Test func boundsGrowWithCategory() {
        let small = AtomAttachment(atom: .mention(text: "@Bharath"), categoryRawValue: large)
        let big = AtomAttachment(atom: .mention(text: "@Bharath"), categoryRawValue: ax3)
        #expect(big.pillSize.width > small.pillSize.width)
        #expect(big.pillSize.height > small.pillSize.height)
    }

    @Test func baselineOriginSitsPillOnLineBaseline() {
        let att = AtomAttachment(atom: .date(timestampMS: 1_720_000_000_000), categoryRawValue: large)
        let lineFont = UIFont.preferredFont(forTextStyle: .body)
        let bounds = att.attachmentBounds(
            for: [:], location: NSTextLocationStub(),
            textContainer: nil, proposedLineFragment: .zero, position: .zero)
        // Pill bottom must not hang below the line's descent (rowAscent −
        // itemAscent placement: origin.y ≥ -descent of the pill's text font).
        #expect(bounds.origin.y <= 0)
        #expect(bounds.origin.y >= -lineFont.pointSize)
        #expect(bounds.size == att.pillSize)
    }

    // MARK: Task 23 — chip SF Symbols + inlineCard tint

    /// Chip `pillSize.width` now includes the leading SF Symbol glyph +
    /// its 4pt gap, closing the ~18.7/22pt gap Task 10 measured against the
    /// SwiftUI arm (`docs/TextKit2-Port-Assessment.md`, "Pill size/position
    /// drift", kitchen-sink @3x: `attachment` chip 353px OFF ≈ 117.67pt;
    /// `Inline macro` chip 378px OFF ≈ 126pt, both at `.large`/default). The
    /// ≤3pt bar is the brief's own tolerance for this task's fix.
    @Test func chipWidthIncludesIconGlyph() {
        let attachmentChip = AtomAttachment(
            atom: .mediaInline(MediaAttrs(source: .file(id: "m-1", collection: "c-1"), width: nil, height: nil, alt: nil, mediaType: nil)),
            categoryRawValue: large)
        #expect(abs(attachmentChip.pillSize.width - 353.0 / 3.0) <= 3.0)

        let extensionChip = AtomAttachment(atom: .inlineExtension(name: "Inline macro"), categoryRawValue: large)
        #expect(abs(extensionChip.pillSize.width - 378.0 / 3.0) <= 3.0)
    }

    /// A chip's width strictly grows once the icon is drawn — regression
    /// guard independent of the exact SwiftUI-measured target above (would
    /// still catch a future accidental icon-drop even if the target numbers
    /// drift with a system font update).
    @Test func chipWidthWiderThanTextAlone() {
        let chip = AtomAttachment(atom: .inlineExtension(name: "Inline macro"), categoryRawValue: large)
        let textOnlyWidth = ("Inline macro" as NSString)
            .size(withAttributes: [.font: UIFont.preferredFont(forTextStyle: .callout)]).width
        #expect(chip.pillSize.width > textOnlyWidth)
    }

    /// `.inlineCard`'s chip text renders in the link tint (matching
    /// `InlineCardChip`'s SwiftUI `Link`), not `.label` — the
    /// `AtomAttachment.swift:165` uniform-`.label` bug Task 13 traced.
    /// `pillFont`/`textColor` aren't exposed directly, so this renders the
    /// pill and checks for a non-gray, blue-leaning pixel in the text region
    /// (`.mediaInline`'s label-color chip is the control: its text region
    /// must NOT show the same blue).
    @Test func inlineCardChipUsesTintColor() {
        let inlineCard = AtomAttachment(atom: .inlineCard(url: "https://example.com"), categoryRawValue: large)
        let mediaChip = AtomAttachment(atom: .mediaInline(MediaAttrs(source: .file(id: "m-2", collection: "c-2"), width: nil, height: nil, alt: "x", mediaType: nil)), categoryRawValue: large)
        #expect(hasBlueTextPixel(inlineCard))
        #expect(!hasBlueTextPixel(mediaChip))
    }

    /// True if any pixel in `attachment`'s rendered image is blue-dominant
    /// (systemBlue text/icon), scanning the whole pill (background is a
    /// neutral gray fill, so any strongly-blue pixel must be glyph ink).
    private func hasBlueTextPixel(_ attachment: AtomAttachment) -> Bool {
        guard let image = attachment.image(forBounds: .zero, textContainer: nil, characterIndex: 0),
              let cgImage = image.cgImage
        else { return false }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return false }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2]), a = Int(pixels[i + 3])
            guard a > 128 else { continue }
            if b > 150, b - r > 40, b - g > 20 { return true }
        }
        return false
    }

    // MARK: Task 23 — pure-atom-row baseline

    /// `pillAscent` is a pure function of `(atom, category)`: identical
    /// atom+category yields the identical value, and it grows with category
    /// (mirrors `boundsAreDeterministicPerCategory`/`boundsGrowWithCategory`
    /// above for `pillSize`).
    @Test func pillAscentIsDeterministicAndGrowsWithCategory() {
        let a = AtomAttachment(atom: .status(text: "done", color: .green), categoryRawValue: large)
        let b = AtomAttachment(atom: .status(text: "done", color: .green), categoryRawValue: large)
        #expect(a.pillAscent == b.pillAscent)

        let big = AtomAttachment(atom: .status(text: "done", color: .green), categoryRawValue: ax3)
        #expect(big.pillAscent > a.pillAscent)
    }

    /// `pillAscent` is within 1pt of the pill's own text-font ascent — the
    /// brief's bar for `TextKit2RowView.firstBaseline`'s pure-atom-row
    /// fallback (padding/rounding account for the small residual).
    @Test func pillAscentWithin1ptOfTextAscent() {
        let att = AtomAttachment(atom: .mention(text: "@Bharath"), categoryRawValue: large)
        let callout = FontSpecResolver.shared.font(for: FontSpec(style: .callout), categoryRawValue: large)
        let calloutMedium = UIFont.systemFont(ofSize: callout.pointSize, weight: .medium)
        #expect(abs(att.pillAscent - calloutMedium.ascender) <= 1.0)
    }
}
#endif
