#if canImport(UIKit)
import Foundation
import Testing
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
/// What a plugin block reads from the environment the views above it
/// wrote: a plugin sets no renderer and reads no text, so it sees exactly
/// what its document row, list row and container boundaries passed down.
private struct ScopeEnvironment: Equatable {
    var renderer: ADFTextRenderer
    var ownerKind: TextKit2OwnerKind
    var context: TextKit2ContainerContext
    var foreground: Color?
    var childKinds: Set<TextKit2BlockKind>
    var widthBound: TextKit2WidthBound
}

@MainActor
private final class ScopeEnvironmentRecorder {
    var observed: [String: ScopeEnvironment] = [:]
}

/// Claims every `blockCard` whose URL is `env:<name>` and records the
/// environment it is drawn in under `<name>`.
private struct ScopeEnvironmentProbe: ADFCustomBlockRenderer {
    let rendererID = "test.scope-environment-probe"
    let recorder: ScopeEnvironmentRecorder

    func claim(for node: ADFNode) -> ADFCustomBlockClaim? {
        guard case .blockCard(let url, _) = node.kind, let url, url.hasPrefix("env:") else { return nil }
        return ADFCustomBlockClaim(String(url.dropFirst("env:".count)), sizing: .reflowingText)
    }

    @MainActor
    func content(for value: String, context: ADFCustomBlockContext) -> some View {
        ScopeEnvironmentProbeView(name: value, recorder: recorder)
    }
}

private struct ScopeEnvironmentProbeView: View {
    let name: String
    let recorder: ScopeEnvironmentRecorder
    @Environment(\.adfTextRenderer) private var renderer
    @Environment(\.adfTextOwnerKind) private var ownerKind
    @Environment(\.adfTextContainerContext) private var context
    @Environment(\.adfTextForeground) private var foreground
    @Environment(\.adfContainerChildKinds) private var childKinds
    @Environment(\.adfTextWidthBound) private var widthBound

    var body: some View {
        let observed = ScopeEnvironment(
            renderer: renderer, ownerKind: ownerKind, context: context, foreground: foreground,
            childKinds: childKinds, widthBound: widthBound
        )
        Color.clear
            .frame(height: 12)
            .onChange(of: observed, initial: true) { _, observed in recorder.observed[name] = observed }
    }
}

/// Through the real document view on both renderers: what a block reads
/// at the root, in a list row, in each container and in a container in a
/// list row or in another container. The owner kind is `.list` only below
/// a list row; the context is `.container` only below a container's child
/// boundary; no view outside a caption sets an inherited foreground; no
/// view changes the container allow list, so every block reads the
/// production list; a plugin block never gets TextKit 2; and on SwiftUI
/// no container passes its width arithmetic to its children (`.pending`).
@Suite("TextKit 2 list scope: environment a block reads", .serialized)
@MainActor
struct TextKit2ScopeEnvironmentTests {
    static func probe(_ name: String) -> String { "{\"type\":\"blockCard\",\"attrs\":{\"url\":\"env:\(name)\"}}" }
    static func panel(_ content: String) -> String { "{\"type\":\"panel\",\"attrs\":{\"panelType\":\"info\"},\"content\":[\(content)]}" }
    static func listItem(_ content: String) -> String {
        TextKit2ListScopeTests.list("bulletList", TextKit2ListScopeTests.item(TextKit2ListScopeTests.t("Item"), content))
    }

    /// Each probe, and whether it sits below a list row and below a
    /// container boundary.
    static let sites: [(name: String, json: String, inList: Bool, inContainer: Bool)] = [
        ("root", probe("root"), false, false),
        ("list", listItem(probe("list")), true, false),
        ("panel", panel(probe("panel")), false, true),
        ("quote", "{\"type\":\"blockquote\",\"content\":[\(probe("quote"))]}", false, true),
        ("expand", "{\"type\":\"expand\",\"attrs\":{\"title\":\"E\"},\"content\":[\(probe("expand"))]}", false, true),
        ("extension", "{\"type\":\"bodiedExtension\",\"attrs\":{\"extensionKey\":\"k\",\"extensionType\":\"t\"},\"content\":[\(probe("extension"))]}", false, true),
        ("column", "{\"type\":\"layoutSection\",\"content\":[{\"type\":\"layoutColumn\",\"attrs\":{\"width\":50},\"content\":[\(probe("column"))]},{\"type\":\"layoutColumn\",\"attrs\":{\"width\":50},\"content\":[\(TextKit2ListScopeTests.t("Beside"))]}]}", false, true),
        ("listPanel", listItem(panel(probe("listPanel"))), true, true),
        ("quotePanel", "{\"type\":\"blockquote\",\"content\":[\(panel(probe("quotePanel")))]}", false, true),
    ]

    @Test("each block reads the owner kind, context, foreground and allow list its position gives, on both renderers", arguments: ADFTextRenderer.allCases)
    func environmentByPosition(renderer: ADFTextRenderer) async throws {
        let recorder = ScopeEnvironmentRecorder()
        let model = ADFDocumentModel(customRenderers: [ScopeEnvironmentProbe(recorder: recorder)])
        model.load(data: Data("{\"version\":1,\"type\":\"doc\",\"content\":[\(Self.sites.map(\.json).joined(separator: ","))]}".utf8))
        for _ in 0..<500 where model.phase != .ready {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.phase == .ready)
        for block in model.blocks {
            if case .expand = block.kind { model.expandedBlocks.insert(block.id) }
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 2_000))
        let host = UIHostingController(rootView: ADFDocumentView(
            model: model, mediaProvider: TextKit2DiagnosticsTests.NoMedia(), textRenderer: renderer
        ).environment(\.horizontalSizeClass, .compact))
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        for _ in 0..<250 where recorder.observed.count < Self.sites.count {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        try await TextKit2DiagnosticsTests.settle(window)
        #expect(Set(recorder.observed.keys) == Set(Self.sites.map(\.name)), "probes drawn: \(recorder.observed.keys.sorted())")
        for site in Self.sites {
            guard let observed = recorder.observed[site.name] else { continue }
            let label = "\(renderer) \(site.name)"
            #expect(observed.ownerKind == (site.inList ? .list : .root), "\(label): owner kind \(observed.ownerKind)")
            #expect(observed.context == (site.inContainer ? .container : .none), "\(label): context \(observed.context)")
            #expect(observed.foreground == nil, "\(label): foreground \(String(describing: observed.foreground))")
            #expect(observed.childKinds == TextKit2Scope.containerChildKinds, "\(label): allow list \(observed.childKinds)")
            #expect(observed.renderer == .swiftUI, "\(label): renderer \(observed.renderer)")
            if renderer == .swiftUI, site.inContainer {
                #expect(observed.widthBound == .pending, "\(label): width bound \(observed.widthBound)")
            }
        }
    }
}
#endif
