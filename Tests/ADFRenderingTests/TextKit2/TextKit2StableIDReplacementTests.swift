#if canImport(UIKit)
import SwiftUI
import UIKit
import Testing
import ADFModel
import ADFPreparation
@testable import ADFRendering

/// Content replaced under stable owner IDs (Astra §6 item 4), in the real
/// document view with TextKit 2 ON. A TextKit 2 row keeps its view for as
/// long as SwiftUI keeps its identity — the owner ID (`PreparedListRow.id`
/// for a list leader, the node path for trailing or root text) — and caches
/// layouts per width. So new text arriving under an old owner must rebuild
/// the row: its accessibility label, its string, every cached layout and the
/// layout it draws must be the new content's, and the document must place
/// it exactly where a fresh document with the new content places it.
///
/// - (a) a stable-ID replacement (`ADFDocumentModel.apply(.replace)`) of a
///   list: leaders that grow (1 → 3 lines), shrink (3 → 1), keep their
///   length with new words (a trailing paragraph alone in its continuation
///   row), and rows left as they were;
/// - (b) a replacement document (`load`) whose rows reuse every structural
///   ID with different content;
/// - (c) the root-paragraph control: the same replacement of a top-level
///   paragraph (PR 1's path).
///
/// Every check compares each row with the same owner's row in a document
/// loaded fresh with the new content (same window, same width). A row whose
/// text changed must also have converted its text again and laid out after
/// the change; a row whose text did not change under a stable-ID replacement
/// must keep its view and its converted string (no conversion).
@Suite("TextKit 2 stable-ID content replacement", .serialized)
@MainActor
struct TextKit2StableIDReplacementTests {
    struct Content {
        var leader0: String
        var leader1: String
        var nested: String
        var continuation: String
        var leader2: String
        var root: String
        var rootTail: String
    }

    static let before = Content(
        leader0: "LEADER-A-OLD short",
        leader1: "LEADER-B-OLD shrinks: a list leader long enough to wrap onto a second and a third line at phone width, with a few more words",
        nested: "Nested leader unchanged",
        continuation: "Continuation paragraph BEFORE the replacement",
        leader2: "Unchanged leader",
        root: "ROOT-OLD short",
        rootTail: "Root paragraph unchanged"
    )

    static let after = Content(
        leader0: "LEADER-A-NEW grows: a list leader long enough to wrap onto a second and a third line at phone width, with more words",
        leader1: "LEADER-B-NEW short",
        nested: "Nested leader unchanged",
        continuation: "Continuation paragraph AFTER! the replacement",
        leader2: "Unchanged leader",
        root: "ROOT-NEW grows: a top-level paragraph long enough to wrap onto a second and a third line at phone width, with more",
        rootTail: "Root paragraph unchanged"
    )

    /// One bullet list (`0.0`: leaders `0.0.0`, `0.0.1` with nested leader
    /// `0.0.1.1.0` and the paragraph `0.0.1.2` alone in its continuation
    /// row, `0.0.2`), then two root paragraphs (`0.1`, `0.2`).
    static func json(list: Content, root: Content) -> String {
        func paragraph(_ text: String) -> String {
            #"{"type":"paragraph","content":[{"type":"text","text":"\#(text)"}]}"#
        }
        func item(_ content: String...) -> String {
            #"{"type":"listItem","content":[\#(content.joined(separator: ","))]}"#
        }
        let nested = #"{"type":"bulletList","content":[\#(item(paragraph(list.nested)))]}"#
        let bullets = [item(paragraph(list.leader0)),
                       item(paragraph(list.leader1), nested, paragraph(list.continuation)),
                       item(paragraph(list.leader2))]
        return #"{"version":1,"type":"doc","content":[{"type":"bulletList","content":[\#(bullets.joined(separator: ","))]},"#
            + "\(paragraph(root.root)),\(paragraph(root.rootTail))]}"
    }

    static func texts(list: Content, root: Content) -> [String: String] {
        ["0.0.0": list.leader0, "0.0.1": list.leader1, "0.0.1.1.0": list.nested, "0.0.1.2": list.continuation,
         "0.0.2": list.leader2, "0.1": root.root, "0.2": root.rootTail]
    }

    static func changed(_ old: [String: String], _ new: [String: String]) -> Set<String> {
        Set(new.keys.filter { old[$0] != new[$0] })
    }

    // MARK: Hosting

    @MainActor
    struct Hosted {
        let model: ADFDocumentModel
        let window: UIWindow
        let root: UIView

        func close() {
            window.isHidden = true
            window.rootViewController = nil
        }

        func settle() async throws {
            try await TextKit2DiagnosticsTests.settle(window)
            TextKit2DiagnosticsTests.render(window)
        }

        /// This window's rows by owner (every owner once).
        func rows() -> [String: TextKit2RowView] {
            let found = TextKit2FallbackTests.rows(in: root)
            let owners = found.map { $0.ownerID ?? "?" }
            #expect(Set(owners).count == owners.count, "an owner drawn twice: \(owners.sorted())")
            return Dictionary(found.map { ($0.ownerID ?? "?", $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    static func ready(_ model: ADFDocumentModel) async throws {
        for _ in 0..<500 where model.phase != .ready {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.phase == .ready)
    }

    static func host(_ json: String) async throws -> Hosted {
        let model = ADFDocumentModel()
        model.load(data: Data(json.utf8))
        try await ready(model)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 1_200))
        let host = UIHostingController(rootView: ADFDocumentView(
            model: model, mediaProvider: TextKit2DiagnosticsTests.NoMedia(), textRenderer: .textKit2
        ))
        window.rootViewController = host
        window.isHidden = false
        let hosted = Hosted(model: model, window: window, root: host.view)
        try await hosted.settle()
        return hosted
    }

    /// The prepared top-level block `id` of `json`, prepared as `model` does.
    static func block(_ id: String, of json: String, for model: ADFDocumentModel) async throws -> RenderBlock {
        let doc = try await ADFParser().parse(Data(json.utf8))
        return try #require(DocumentPreparer(theme: model.theme).prepare(doc).first { $0.id == id })
    }

    // MARK: Row state

    /// What a row showed before the replacement. Held strongly, so an
    /// identity compare cannot be fooled by a new object at a freed address.
    struct Before {
        let view: TextKit2RowView
        let string: NSAttributedString
        let relayouts: Int
        let label: String?
    }

    static func before(_ rows: [String: TextKit2RowView]) -> [String: Before] {
        rows.mapValues {
            Before(view: $0, string: $0.attributed, relayouts: $0.relayoutCount, label: $0.accessibilityLabel)
        }
    }

    static func windowFrame(_ row: TextKit2RowView) -> CGRect {
        row.convert(row.bounds, to: nil)
    }

    static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 0.01 && abs(a.minY - b.minY) <= 0.01
            && abs(a.width - b.width) <= 0.01 && abs(a.height - b.height) <= 0.01
    }

    /// Every row against the fresh document's row with the same owner:
    /// label, string, placement, the drawn layout, and each cached width's
    /// layout. Changed rows rebuilt (new converted string, laid out after
    /// the change); with `stable`, unchanged rows kept their view and string
    /// and every row kept its view. Returns figures for the evidence line.
    static func verify(
        _ name: String, replaced: Hosted, fresh: Hosted, start: [String: Before], expected: [String: String],
        changed: Set<String>, stable: Bool
    ) -> [String: String] {
        let rows = replaced.rows(), freshRows = fresh.rows()
        #expect(Set(rows.keys) == Set(expected.keys), "\(name): owners \(rows.keys.sorted())")
        #expect(Set(freshRows.keys) == Set(expected.keys), "\(name): fresh owners \(freshRows.keys.sorted())")
        let oldLabels = Set(start.values.compactMap(\.label)).subtracting(expected.values)
        var figures: [String: String] = [:]
        for (owner, text) in expected.sorted(by: { $0.key < $1.key }) {
            guard let row = rows[owner], let freshRow = freshRows[owner], let was = start[owner] else {
                Issue.record("\(name) \(owner): row missing")
                continue
            }
            #expect(row.accessibilityLabel == text, "\(name) \(owner): label \(row.accessibilityLabel ?? "nil")")
            #expect(row.attributed.string == text, "\(name) \(owner): drawing \(row.attributed.string)")
            #expect(!oldLabels.contains(row.accessibilityLabel ?? ""), "\(name) \(owner): an old label")
            let frame = windowFrame(row), freshFrame = windowFrame(freshRow)
            #expect(close(frame, freshFrame), "\(name) \(owner): placed \(frame), fresh \(freshFrame)")
            #expect(row.drawn != nil && row.drawn == freshRow.drawn,
                    "\(name) \(owner): drawn \(row.drawn?.size ?? .zero) / \(row.drawn?.lineCount ?? -1) lines, fresh \(freshRow.drawn?.size ?? .zero) / \(freshRow.drawn?.lineCount ?? -1)")
            if let lines = row.drawn?.lines, let last = lines.last {
                #expect(last.range.upperBound == (text as NSString).length, "\(name) \(owner): lines end at \(last.range.upperBound)")
            }
            let widths = row.cachedWidths
            #expect(!widths.isEmpty, "\(name) \(owner): nothing cached")
            // Each cached entry (read back without a layout) is the new
            // content's layout at that width.
            for width in widths {
                let proposal = width.isFinite ? width : nil
                let cached = row.layoutResult(forProposedWidth: proposal)
                let expectedResult = freshRow.layoutResult(forProposedWidth: proposal)
                #expect(cached == expectedResult,
                        "\(name) \(owner) @\(width): cached \(cached.size) / \(cached.lineCount) lines, fresh \(expectedResult.size) / \(expectedResult.lineCount)")
            }
            let reused = row === was.view
            let reconverted = row.attributed !== was.string
            if changed.contains(owner) {
                #expect(reconverted, "\(name) \(owner): text changed but the row kept its converted string")
                if reused {
                    #expect(row.relayoutCount > was.relayouts, "\(name) \(owner): no layout after the change")
                }
            } else if stable {
                #expect(!reconverted, "\(name) \(owner): unchanged text converted again")
            }
            if stable {
                #expect(reused, "\(name) \(owner): a stable owner got a new row view")
            }
            figures[owner] = "\(changed.contains(owner) ? "changed" : "same"),view=\(reused ? "reused" : "new"),"
                + "converted=\(reconverted),lines=\(row.drawn?.lineCount ?? -1),h=\(frame.height),y=\(frame.minY),"
                + "widths=\(widths.map { $0.isFinite ? "\($0)" : "inf" }.joined(separator: "/"))"
        }
        return figures
    }

    static func evidence(_ name: String, conversions: Int, changed: Set<String>, _ figures: [String: String]) {
        print("STABLEID \(name): conversions=\(conversions) changed=\(changed.sorted()) "
              + figures.sorted { $0.key < $1.key }.map { "\($0.key)[\($0.value)]" }.joined(separator: " "))
    }

    // MARK: Tests

    @Test("(a) list rows replaced under their stable owner IDs draw, label and lay out the new text",
          .enabled(if: TextKit2Eligibility.listsMatchText, "before iOS 26 lists keep their text on SwiftUI"))
    func listStableIDReplacement() async throws {
        let oldJSON = Self.json(list: Self.before, root: Self.before)
        let newJSON = Self.json(list: Self.after, root: Self.before)
        let old = Self.texts(list: Self.before, root: Self.before), new = Self.texts(list: Self.after, root: Self.before)
        let changed = Self.changed(old, new)
        #expect(changed == ["0.0.0", "0.0.1", "0.0.1.2"])

        let hosted = try await Self.host(oldJSON)
        defer { hosted.close() }
        let startRows = hosted.rows()
        #expect(startRows.mapValues { $0.accessibilityLabel ?? "" } == old, "the old document's rows")
        let start = Self.before(startRows)
        let replacement = try await Self.block("0.0", of: newJSON, for: hosted.model)
        let conversions = TextKit2Diagnostics.shared.conversionCount
        try await hosted.model.apply([.replace(itemID: "0.0", block: replacement)], revision: 1)
        try await hosted.settle()
        let converted = TextKit2Diagnostics.shared.conversionCount - conversions
        // Other suites can convert while this one waits: at least one per
        // changed row (the per-row check below is exact).
        #expect(converted >= changed.count, "conversions \(converted)")

        let fresh = try await Self.host(newJSON)
        defer { fresh.close() }
        let figures = Self.verify("(a) list replace", replaced: hosted, fresh: fresh, start: start,
                                  expected: new, changed: changed, stable: true)
        Self.evidence("(a) list replace", conversions: converted, changed: changed, figures)
    }

    @Test("(b) a replacement document reusing every structural ID draws, labels and lays out the new text",
          .enabled(if: TextKit2Eligibility.listsMatchText, "before iOS 26 lists keep their text on SwiftUI"))
    func collidingIDsReplacementDocument() async throws {
        let oldJSON = Self.json(list: Self.before, root: Self.before)
        let newJSON = Self.json(list: Self.after, root: Self.after)
        let old = Self.texts(list: Self.before, root: Self.before), new = Self.texts(list: Self.after, root: Self.after)
        let changed = Self.changed(old, new)
        #expect(changed == ["0.0.0", "0.0.1", "0.0.1.2", "0.1"])
        #expect(Set(old.keys) == Set(new.keys), "every structural ID collides")

        let hosted = try await Self.host(oldJSON)
        defer { hosted.close() }
        let start = Self.before(hosted.rows())
        let conversions = TextKit2Diagnostics.shared.conversionCount
        hosted.model.load(data: Data(newJSON.utf8))
        try await Self.ready(hosted.model)
        try await hosted.settle()
        let converted = TextKit2Diagnostics.shared.conversionCount - conversions
        #expect(converted >= changed.count, "conversions \(converted)")

        let fresh = try await Self.host(newJSON)
        defer { fresh.close() }
        let figures = Self.verify("(b) replacement document", replaced: hosted, fresh: fresh, start: start,
                                  expected: new, changed: changed, stable: false)
        Self.evidence("(b) replacement document", conversions: converted, changed: changed, figures)
    }

    @Test("(c) control: a root paragraph replaced under its stable ID draws, labels and lays out the new text")
    func rootParagraphStableIDReplacement() async throws {
        let oldJSON = Self.json(list: Self.before, root: Self.before)
        let newJSON = Self.json(list: Self.before, root: Self.after)
        let old = Self.texts(list: Self.before, root: Self.before), new = Self.texts(list: Self.before, root: Self.after)
        let changed = Self.changed(old, new)
        #expect(changed == ["0.1"])

        let hosted = try await Self.host(oldJSON)
        defer { hosted.close() }
        // Before iOS 26 the list stays on SwiftUI: only root rows are drawn.
        let owners = TextKit2Eligibility.listsMatchText ? Set(old.keys) : ["0.1", "0.2"]
        let expected = new.filter { owners.contains($0.key) }
        let start = Self.before(hosted.rows())
        let replacement = try await Self.block("0.1", of: newJSON, for: hosted.model)
        let conversions = TextKit2Diagnostics.shared.conversionCount
        try await hosted.model.apply([.replace(itemID: "0.1", block: replacement)], revision: 1)
        try await hosted.settle()
        let converted = TextKit2Diagnostics.shared.conversionCount - conversions
        #expect(converted >= changed.count, "conversions \(converted)")

        let fresh = try await Self.host(newJSON)
        defer { fresh.close() }
        let figures = Self.verify("(c) root replace", replaced: hosted, fresh: fresh, start: start,
                                  expected: expected, changed: changed, stable: true)
        Self.evidence("(c) root replace", conversions: converted, changed: changed, figures)
    }
}
#endif
