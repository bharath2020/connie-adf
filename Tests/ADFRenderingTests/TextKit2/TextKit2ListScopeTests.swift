import Foundation
import Testing

/// The renderer choice is set in exactly two places (Fable F4): the
/// document row (`DocumentRow`: top-level `.richText`, `.listRows` and
/// `.codeBlock`) and the list row's trailing-block boundary
/// (`ListRowView`). A third setter, such as a container passing it on,
/// would leak TextKit 2 into an excluded subtree. A code block only reads
/// the choice (`TextKit2CodeScopeRuleTests`). Source scan, so it runs on
/// every platform.
@Suite("TextKit 2 list scope: renderer setters")
struct TextKit2RendererSetterTests {
    @Test("the renderer environment key is set in exactly two places")
    func twoSetters() throws {
        var sources = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { sources.deleteLastPathComponent() } // …/Tests/ADFRenderingTests/TextKit2 → repo root
        sources.appendPathComponent("Sources")
        let enumerator = try #require(FileManager.default.enumerator(atPath: sources.path))
        var setters: [String] = []
        var scanned = 0
        while let path = enumerator.nextObject() as? String {
            guard path.hasSuffix(".swift") else { continue }
            scanned += 1
            let source = try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
            for (index, line) in source.components(separatedBy: .newlines).enumerated() {
                // A write: `.environment(\.adfTextRenderer, …)`,
                // `transformEnvironment(\.adfTextRenderer)` or an assignment.
                // Reads are `@Environment(\.adfTextRenderer)`.
                let code = line.components(separatedBy: "//").first ?? line
                if code.contains("\\.adfTextRenderer,") || code.contains("transformEnvironment(\\.adfTextRenderer")
                    || code.contains(".adfTextRenderer =") {
                    setters.append("\((path as NSString).lastPathComponent):\(index + 1)")
                }
            }
        }
        #expect(scanned > 50, "scanned \(scanned) source files")
        #expect(setters.count == 2, "setters: \(setters)")
        #expect(Set(setters.map { $0.prefix { $0 != ":" } }) == ["ADFDocumentView.swift", "ListBlockView.swift"], "setters: \(setters)")
    }
}

#if canImport(UIKit)
import SwiftUI
import UIKit
import ADFModel
import ADFPreparation
@testable import ADFRendering

/// Through the real document view under `.textKit2`: list leaders and a
/// list row's direct paragraphs get TextKit 2 rows at every depth when
/// the row's column holds one text block or only body-styled paragraphs
/// (here two). A row holding anything but text (here a code block, a
/// panel and a sync block) keeps all its own text on SwiftUI, the list
/// reached through the sync block included, while its plain neighbour
/// keeps TextKit 2 (`TextKit2Scope.rowKeepsRenderer`); a list with a row
/// holding both a panel and an expand keeps every row's text on SwiftUI
/// (`TextKit2Scope.listKeepsRenderer`). A list inside a container and text
/// inside a list's container get no row. Before iOS 26 no list text gets
/// one (`TextKit2Eligibility.listsMatchText`).
@Suite("TextKit 2 list scope", .serialized)
@MainActor
struct TextKit2ListScopeTests {
    static func t(_ string: String) -> String { "{\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"\(string)\"}]}" }
    static func item(_ children: String...) -> String { "{\"type\":\"listItem\",\"content\":[\(children.joined(separator: ","))]}" }
    static func list(_ type: String = "bulletList", _ items: String...) -> String { "{\"type\":\"\(type)\",\"content\":[\(items.joined(separator: ","))]}" }

    /// Ids are node paths ("0.<root>.<child>…"); a list row is owned by its
    /// item's id.
    static let document = """
    {"version":1,"type":"doc","content":[
      \(list("bulletList",
        item(
          t("Leader"),
          t("Second paragraph"),
          "{\"type\":\"codeBlock\",\"content\":[{\"type\":\"text\",\"text\":\"let x = 1\"}]}",
          "{\"type\":\"panel\",\"attrs\":{\"panelType\":\"info\"},\"content\":[\(t("Panel text")),\(list("bulletList", item(t("Panel list"))))]}",
          "{\"type\":\"bodiedSyncBlock\",\"attrs\":{\"resourceId\":\"ari:cloud:confluence:site/s\",\"localId\":\"s\"},\"content\":[\(list("orderedList", item(t("Synced leader"), t("Synced paragraph"), "{\"type\":\"blockquote\",\"content\":[\(t("Synced quote"))]}")))]}"
        ),
        item(t("Plain item beside it"))
      )),
      \(list("bulletList",
        item(t("Second item"), list("bulletList", item(t("Nested leader"))), t("Second item, after its list")),
        item(t("Third item"), t("Third item's second paragraph"))
      )),
      {"type":"panel","attrs":{"panelType":"note"},"content":[\(list("bulletList", item(t("Root panel list"))))]},
      \(t("Root paragraph")),
      \(list("bulletList",
        item(
          t("Item with a panel and an expand"),
          "{\"type\":\"panel\",\"attrs\":{\"panelType\":\"info\"},\"content\":[\(t("Its panel text"))]}",
          "{\"type\":\"expand\",\"attrs\":{\"title\":\"Details\"},\"content\":[\(t("Its expand text"))]}"
        ),
        item(t("Plain item in that list"))
      ))
    ]}
    """

    /// Hand-derived from the document above.
    static let expectedRows: Set<String> = [
        "0.0.1",          // the plain item beside the item holding a code block, a panel and a sync block
        "0.1.0",          // second list's first item's leader
        "0.1.0.1.0",      // flattened nested list's leader (depth 1)
        "0.1.0.2",        // the paragraph after it, alone in a continuation row (trailing .richText)
        "0.1.1",          // third item's leader and
        "0.1.1.1",        // its second paragraph: two body paragraphs in one column
        "0.3",            // root paragraph
    ]
    /// Text on SwiftUI: the first list's first item, which also holds a
    /// code block, a panel and a sync block — its own text (leader and
    /// second paragraph), the panel and its list, the list reached through
    /// the sync block (leader, paragraph) and the quote in its row; the
    /// list in a root panel; the last list, whose first item holds a panel
    /// and an expand — that item's leader, its panel text and the plain
    /// item beside it.
    static let excludedOwners: Set<String> = [
        "0.0.0", "0.0.0.1", "0.0.0.3.0", "0.0.0.3.1.0", "0.0.0.4.0.0", "0.0.0.4.0.0.1", "0.0.0.4.0.0.2.0",
        "0.2.0.0", "0.4.0", "0.4.0.1.0", "0.4.1",
    ]

    static func model() async throws -> ADFDocumentModel {
        let model = ADFDocumentModel()
        model.load(data: Data(document.utf8))
        for _ in 0..<500 where model.phase != .ready {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.phase == .ready)
        return model
    }

    @Test("list text follows the renderer at every depth; excluded subtrees stay on SwiftUI")
    func scope() async throws {
        let model = try await Self.model()
        // The excluded owners exist as prepared text (so their absence below
        // is the scope's doing, not a missing block).
        var allTextOwners: Set<String> = []
        func collect(_ blocks: [RenderBlock]) {
            for block in blocks {
                switch block.kind {
                case .richText: allTextOwners.insert(block.id)
                case .listRows(let rows):
                    for row in rows {
                        if !row.segments.isEmpty { allTextOwners.insert(row.id) }
                        collect(row.trailingBlocks)
                    }
                case .panel(_, let children), .quote(let children): collect(children)
                default: break
                }
            }
        }
        collect(model.blocks)
        #expect(allTextOwners.isSuperset(of: Self.expectedRows.union(Self.excludedOwners)), "prepared text owners: \(allTextOwners.sorted())")

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 2_000))
        let host = UIHostingController(rootView: ADFDocumentView(model: model, mediaProvider: TextKit2DiagnosticsTests.NoMedia(), textRenderer: .textKit2))
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await TextKit2DiagnosticsTests.settle(window)
        let found = Set(TextKit2DiagnosticsTests.identifiers(in: host.view).map { String($0.dropFirst("tk2-row:".count)) })
        let expected: Set<String> = TextKit2Eligibility.listsMatchText ? Self.expectedRows : ["0.3"]
        #expect(found == expected, "missing \(expected.subtracting(found).sorted()), unexpected \(found.subtracting(expected).sorted())")
        #expect(found.isDisjoint(with: Self.excludedOwners))

        host.rootView = ADFDocumentView(model: model, mediaProvider: TextKit2DiagnosticsTests.NoMedia(), textRenderer: .swiftUI)
        try await TextKit2DiagnosticsTests.settle(window)
        #expect(TextKit2DiagnosticsTests.identifiers(in: host.view).isEmpty)
    }
}
#endif
