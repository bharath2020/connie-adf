#if canImport(UIKit)
import SwiftUI
import UIKit
import Testing
import ADFModel
import ADFPreparation
@testable import ADFRendering

/// Layout passes list text costs on first materialisation (Fable F6),
/// through the real list view, against a top-level paragraph with the same
/// text. A list row is an `HStack` of the marker and a flexible content
/// column; the stack sizes that column with a natural-width (unspecified)
/// probe before proposing the width left over. So every list leaf, the
/// leader and the paragraphs in the same column, lays out once unbounded
/// (cached under `.infinity`, one of the row's four cache slots) and once at
/// its column width, where a root paragraph is proposed its width and lays
/// out once.
///
/// Measured cost of the probe (iPhone 17 Pro simulator, iOS 26.3, the 3,686
/// eligible list leaves of `list-dense`, fresh rows each): natural ≈ 153 ms,
/// column width (322 pt) ≈ 163 ms in total, so a list leaf's first
/// materialisation costs about 1.9 times a root paragraph's, ~42 µs more
/// per leaf. That is not optimised here (the baseline path is unchanged);
/// these pins make any change to it, a cheaper natural-width answer or a new
/// probe, a measured decision. From iOS 26: before it lists keep their
/// text on SwiftUI (`TextKit2Eligibility.listsMatchText`).
@Suite("TextKit 2 list leader layouts", .serialized,
       .enabled(if: TextKit2Eligibility.listsMatchText, "before iOS 26 lists keep their text on SwiftUI"))
@MainActor
struct TextKit2ListLayoutTests {
    static let long = "A list leader long enough to wrap onto a second and a third line at phone width, with a few more words after it"

    /// A short leader, a long one with a nested list and a paragraph after
    /// it, alone in a continuation row (owners `0.0.0`, `0.0.1`,
    /// `0.0.1.1.0`, `0.0.1.2`).
    static let listJSON = """
    {"version":1,"type":"doc","content":[{"type":"bulletList","content":[
      {"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"Short leader"}]}]},
      {"type":"listItem","content":[
        {"type":"paragraph","content":[{"type":"text","text":"\(long)"}]},
        {"type":"bulletList","content":[{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"\(long)"}]}]}]},
        {"type":"paragraph","content":[{"type":"text","text":"\(long)"}]}
      ]}
    ]}]}
    """
    static let listOwners = ["0.0.0", "0.0.1", "0.0.1.1.0", "0.0.1.2"]
    static let paragraphJSON = """
    {"version":1,"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"\(long)"}]}]}
    """

    struct Row {
        let owner: String
        let layouts: Int
        let widths: Set<CGFloat>
    }

    static func rows(in view: UIView) -> [String: Row] {
        var rows: [String: Row] = [:]
        for row in TextKit2FallbackTests.rows(in: view) {
            let owner = row.ownerID ?? "?"
            rows[owner] = Row(owner: owner, layouts: row.relayoutCount, widths: Set(row.cachedWidths))
        }
        return rows
    }

    static func block(_ json: String) async throws -> RenderBlock {
        let doc = try await ADFParser().parse(Data(json.utf8))
        return try #require(DocumentPreparer(theme: TK2Parity.theme).prepare(doc).first)
    }

    static func hosted(_ block: RenderBlock) -> some View {
        BlockView(block: block)
            .environment(\.adfTextRenderer, .textKit2)
            .environment(\.adfTheme, TK2Parity.theme)
    }

    /// Text conversions (one per new row) and layout passes inside `body`.
    /// Synchronous, so no other suite's rows run in between.
    static func counting(_ body: () -> Void) -> (conversions: Int, layouts: Int) {
        let diagnostics = TextKit2Diagnostics.shared
        let conversions = diagnostics.conversionCount
        let layouts = diagnostics.layoutCount
        body()
        return (diagnostics.conversionCount - conversions, diagnostics.layoutCount - layouts)
    }

    @Test("through the document view a list leaf lays out twice (natural probe, column width), a root paragraph once")
    func documentFirstMaterialisation() async throws {
        func materialise(_ json: String) async throws -> [String: Row] {
            let model = ADFDocumentModel()
            model.load(data: Data(json.utf8))
            for _ in 0..<500 where model.phase != .ready {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(model.phase == .ready)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 1_200))
            let host = UIHostingController(rootView: ADFDocumentView(model: model, mediaProvider: TextKit2DiagnosticsTests.NoMedia(), textRenderer: .textKit2))
            window.rootViewController = host
            window.isHidden = false
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            try await TextKit2DiagnosticsTests.settle(window)
            TextKit2DiagnosticsTests.render(window) // drawing adds no layout
            return Self.rows(in: host.view)
        }
        // Content column 358 pt (390 less the document's 16 pt margins); list
        // text starts 36 pt in (28 pt marker + 8 pt spacing), 36 more per
        // nesting level.
        let list = try await materialise(Self.listJSON)
        #expect(list.keys.sorted() == Self.listOwners)
        for owner in Self.listOwners {
            let row = try #require(list[owner])
            #expect(row.layouts == 2, "\(owner)")
            #expect(row.widths == [.infinity, owner == "0.0.1.1.0" ? 286 : 322], "\(owner): \(row.widths)")
        }
        let paragraph = try await materialise(Self.paragraphJSON)
        #expect(paragraph.count == 1)
        #expect(paragraph["0.0"]?.layouts == 1)
        #expect(paragraph["0.0"]?.widths == [358])
    }

    /// Layout passes to measure the hosted block once (fresh rows), per
    /// proposed width: zero, narrow (less than the marker column), a phone
    /// column, infinite and unspecified (`fixedSize`). Every list leaf pays
    /// its natural probe at every proposal; the bounded passes after it are
    /// broken down per row in `materialised`. A root paragraph lays out once
    /// for any positive proposal, natural included, and not at all for zero.
    static let measured: [(name: String, width: CGFloat?, list: Int, paragraph: Int)] = [
        ("zero", 0, 7, 0),
        ("narrow", 40, 10, 1),
        ("phone", 300, 8, 1),
        ("infinite", .infinity, 11, 1),
        ("unspecified", nil, 11, 1),
    ]

    @Test("measuring: layout passes per proposal, list vs root paragraph")
    func measuring() async throws {
        let list = try await Self.block(Self.listJSON)
        let paragraph = try await Self.block(Self.paragraphJSON)
        for proposal in Self.measured {
            for (block, leaves, expected) in [(list, 4, proposal.list), (paragraph, 1, proposal.paragraph)] {
                let label = "\(proposal.name) \(leaves == 1 ? "paragraph" : "list")"
                let root = proposal.width == nil
                    ? AnyView(Self.hosted(block).fixedSize(horizontal: true, vertical: false))
                    : AnyView(Self.hosted(block))
                let host = UIHostingController(rootView: root)
                host.safeAreaRegions = []
                let fitting = CGSize(width: proposal.width ?? 390, height: CGFloat.greatestFiniteMagnitude)
                let counted = Self.counting { _ = host.sizeThatFits(in: fitting) }
                #expect(counted.conversions == leaves, "\(label): \(counted)")
                #expect(counted.layouts == expected, "\(label): \(counted)")
            }
        }
    }

    /// Per-row layout passes when the block is laid out in a window at the
    /// proposed width and drawn (measuring plus placement), in `listOwners`
    /// order. Widths seen (iOS 26.3): zero, the natural probe and 36 pt
    /// (the nested leader's offer is not positive: probe only); narrow, the
    /// stack's first offer (40 − 36 = 4 pt), the probe and 36 pt; phone,
    /// the probe and the column (264 pt, nested 228); unspecified, the
    /// probe, the column's widest natural width (865 pt, nested 829), the
    /// leaf's own natural width and its pixel-ceiled placed width, since a
    /// natural layout never serves placement (`placedResult(for:)`). A root
    /// paragraph pays that last pass too (∞, 829, 829.33).
    static let materialised: [(name: String, width: CGFloat?, list: [Int], paragraph: Int)] = [
        ("zero", 0, [2, 2, 1, 2], 0),
        ("narrow", 40, [3, 3, 1, 3], 1),
        ("phone", 300, [2, 2, 2, 2], 1),
        ("unspecified", nil, [4, 4, 3, 4], 3),
    ]

    @Test("materialising: per-row layout passes per proposal, list vs root paragraph")
    func materialising() async throws {
        let list = try await Self.block(Self.listJSON)
        let paragraph = try await Self.block(Self.paragraphJSON)
        for proposal in Self.materialised {
            for (block, owners, expected) in [(list, Self.listOwners, proposal.list), (paragraph, ["0.0"], [proposal.paragraph])] {
                let label = "\(proposal.name) \(owners.count == 1 ? "paragraph" : "list")"
                let content = proposal.width.map { AnyView(Self.hosted(block).frame(width: $0, alignment: .topLeading)) }
                    ?? AnyView(Self.hosted(block).fixedSize(horizontal: true, vertical: false))
                let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 5_000))
                let host = UIHostingController(rootView: content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
                host.safeAreaRegions = []
                window.rootViewController = host
                let counted = Self.counting {
                    window.isHidden = false
                    window.layoutIfNeeded()
                    TextKit2DiagnosticsTests.render(window)
                }
                let rows = Self.rows(in: host.view)
                window.isHidden = true
                window.rootViewController = nil
                #expect(owners.map { rows[$0]?.layouts } == expected, "\(label): \(rows.values.map { ($0.owner, $0.layouts, $0.widths) })")
                #expect(counted.layouts == expected.reduce(0, +), "\(label): no other row laid out")
            }
        }
    }
}
#endif
