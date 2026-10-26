import Foundation
import ADFPreparation

/// A read-only snapshot of the TextKit 2 renderer's counters — the proof of
/// which text engine actually drew, independent of the host's switch state.
///
/// `liveRowCount` counts TextKit 2 row views currently alive (it returns to
/// zero once a switch back to `.swiftUI` has released them); `layoutCount`
/// and `drawCount` are cumulative since launch. Always zero on platforms
/// without UIKit.
public struct ADFTextKit2Stats: Sendable, Hashable {
    /// TextKit 2 row views currently alive.
    public var liveRowCount: Int
    /// Full `ensureLayout` passes performed by TextKit 2 rows since launch.
    public var layoutCount: Int
    /// `draw(_:)` calls performed by TextKit 2 rows since launch.
    public var drawCount: Int

    public init(liveRowCount: Int, layoutCount: Int, drawCount: Int) {
        self.liveRowCount = liveRowCount
        self.layoutCount = layoutCount
        self.drawCount = drawCount
    }
}

/// How many top-level blocks of a document the TextKit 2 renderer can
/// draw (`eligibleRoots`: atom-free paragraphs and headings whose every run
/// has a font spec) versus how many stay on SwiftUI (`fallbackRoots`:
/// everything else — containers, lists, code, tables, media, atom-bearing
/// paragraphs, undescribable theme fonts). Content-based: the same answer
/// on every platform.
public struct ADFTextKit2Coverage: Sendable, Hashable {
    public var eligibleRoots: Int
    public var fallbackRoots: Int

    public init(eligibleRoots: Int, fallbackRoots: Int) {
        self.eligibleRoots = eligibleRoots
        self.fallbackRoots = fallbackRoots
    }
}

extension ADFTextRenderer {
    /// The current TextKit 2 counters (see `ADFTextKit2Stats`).
    @MainActor
    public static var textKit2Stats: ADFTextKit2Stats {
        TextKit2Diagnostics.shared.snapshot
    }

    /// Classifies a document's top-level blocks (`ADFDocumentModel.blocks`)
    /// by whether the TextKit 2 renderer draws them.
    public static func textKit2Coverage(of blocks: [RenderBlock]) -> ADFTextKit2Coverage {
        var eligible = 0
        for block in blocks {
            if case .richText(let segments, _) = block.kind,
               TextKit2Eligibility.describableText(segments) != nil {
                eligible += 1
            }
        }
        return ADFTextKit2Coverage(eligibleRoots: eligible, fallbackRoots: blocks.count - eligible)
    }
}

/// Which prepared rich text the TextKit 2 arm can draw.
enum TextKit2Eligibility {
    /// The merged text of an all-text segment list whose every run carries
    /// a font spec, or `nil` when any segment is an inline atom, any run is
    /// undescribable (a theme font supplied as a raw SwiftUI `Font`), or the
    /// text is empty — SwiftUI sizes an empty `Text` from a fixed 12 pt
    /// system font (measured: 14 pt tall at every Dynamic Type size), a
    /// placeholder with nothing to draw, so it stays on SwiftUI. The
    /// preparer emits one merged run per gap, so the common case returns
    /// the stored value without building a new string.
    static func describableText(_ segments: [InlineSegment]) -> AttributedString? {
        let text: AttributedString
        if segments.count == 1, case .text(let only) = segments[0] {
            text = only
        } else {
            var merged = AttributedString()
            for segment in segments {
                guard case .text(let run) = segment else { return nil }
                merged.append(run)
            }
            text = merged
        }
        guard !text.characters.isEmpty else { return nil }
        for (spec, _) in text.runs[\.adfFontSpec] where spec == nil {
            return nil
        }
        return text
    }
}

/// The TextKit 2 rows' counters (§2.6 of the stack plan). Rows report
/// creation, destruction, owner changes, layouts and draws; tests and the
/// public snapshot read them. Plain integers: cheap enough to stay on in
/// Release, where the demo's renderer proof needs them.
@MainActor
final class TextKit2Diagnostics {
    static let shared = TextKit2Diagnostics()

    private(set) var liveRowCount = 0
    private(set) var layoutCount = 0
    private(set) var drawCount = 0
    /// Live rows per owner (block) id.
    private var owners: [String: Int] = [:]

    var snapshot: ADFTextKit2Stats {
        ADFTextKit2Stats(liveRowCount: liveRowCount, layoutCount: layoutCount, drawCount: drawCount)
    }

    /// Live rows drawing the block `ownerID`.
    func liveRows(ownerID: String) -> Int {
        owners[ownerID] ?? 0
    }

    func rowCreated() {
        liveRowCount += 1
    }

    func rowDestroyed(ownerID: String?) {
        liveRowCount -= 1
        release(ownerID)
    }

    func row(changedOwnerFrom old: String?, to new: String?) {
        guard old != new else { return }
        release(old)
        if let new { owners[new, default: 0] += 1 }
    }

    func didLayout() {
        layoutCount += 1
    }

    func didDraw() {
        drawCount += 1
    }

    private func release(_ ownerID: String?) {
        guard let ownerID, let count = owners[ownerID] else { return }
        owners[ownerID] = count > 1 ? count - 1 : nil
    }
}
