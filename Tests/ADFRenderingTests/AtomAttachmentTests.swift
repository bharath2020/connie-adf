#if canImport(UIKit)
import UIKit
import SwiftUI
import Testing
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
}
#endif
