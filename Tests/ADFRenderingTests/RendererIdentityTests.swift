import Observation
import SwiftUI
import Testing
import ADFModel
import ADFPreparation
@testable import ADFRendering
#if canImport(UIKit)
import UIKit
#endif

/// `ADFDocumentView(identifiesRenderer:)`: the registry the marked leaves
/// write (coalesced, visibility-gated publishing of `ADFRendererReport`),
/// and, through the real document view, what each leaf reports: under
/// `.textKit2` an eligible paragraph, heading and list item, and from
/// iOS 26 a panel's paragraph and a caption, report TextKit 2, a linked
/// paragraph TextKit 1, and the text the renderer leaves on SwiftUI (an
/// atom paragraph; before iOS 26 the panel's paragraph and the caption)
/// SwiftUI;
/// under `.swiftUI` everything reports SwiftUI; off, nothing is added.
@Suite("Renderer identification", .serialized)
@MainActor
struct RendererIdentityTests {
    /// A value a closure reads or sets after it is made.
    final class Box<Value>: @unchecked Sendable {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    // MARK: Registry

    @Test("a burst of leaf writes is published once, after the interval, and only what is on screen counts")
    func coalescedPublish() async throws {
        let registry = RendererIdentityRegistry()
        registry.publishInterval = .milliseconds(50)
        registry.isIdentifying = true
        for index in 0..<20 {
            registry.appeared("s:p\(index)", ownerID: "p\(index)") { .swiftUI }
            registry.setVisible("s:p\(index)", index < 5)
        }
        registry.appeared("t:h", ownerID: "h") { .textKit2 }
        registry.setVisible("t:h", true)
        #expect(registry.publishCount == 0, "published inside the burst")
        #expect(!registry.report.isIdentifying)
        try await smartLinkEventually("the publish") { registry.publishCount == 1 }
        let report = registry.report
        #expect(report.isIdentifying)
        if RendererIdentityRegistry.tracksVisibility {
            #expect(report.count(.swiftUI) == 5 && report.count(.textKit2) == 1, "\(report.counts)")
            #expect(report.engines == ["p0": .swiftUI, "p1": .swiftUI, "p2": .swiftUI, "p3": .swiftUI, "p4": .swiftUI, "h": .textKit2])
        } else {
            #expect(report.count(.swiftUI) == 20 && report.count(.textKit2) == 1, "\(report.counts)")
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(registry.publishCount == 1, "published again with nothing changed")
    }

    @Test("visibility before appearing counts; leaving drops it; a leaf and its replacement do not cancel out")
    func visibilityAndKeys() async throws {
        let registry = RendererIdentityRegistry()
        registry.publishInterval = .zero
        registry.isIdentifying = true
        registry.setVisible("t:a", true)
        registry.appeared("t:a", ownerID: "a") { .textKit2 }
        // The SwiftUI leaf replacing the row for the same block, during a
        // switch: it appears before the row disappears.
        registry.appeared("s:a", ownerID: "a") { .swiftUI }
        registry.setVisible("s:a", true)
        registry.publish()
        #expect(registry.report.engines["a"] == .textKit2, "the row wins while both are on screen")
        #expect(registry.report.total == 2)
        registry.disappeared("t:a")
        registry.publish()
        #expect(registry.report.engines == ["a": .swiftUI])
        #expect(registry.report.counts == [.swiftUI: 1])
        registry.disappeared("s:a")
        // A late visibility report for a leaf that is gone changes nothing.
        registry.setVisible("s:a", true)
        registry.publish()
        #expect(registry.report.total == 0 && registry.report.engines.isEmpty)
        #expect(registry.builtEngines.isEmpty)
    }

    @Test("a row's engine is read when the report is published; identification off publishes an empty report")
    func engineReadAtPublishAndOff() async throws {
        let registry = RendererIdentityRegistry()
        registry.publishInterval = .zero
        registry.isIdentifying = true
        let linked = Box(false)
        registry.appeared("t:r", ownerID: "r") { linked.value ? .textKit1 : .textKit2 }
        registry.setVisible("t:r", true)
        registry.publish()
        #expect(registry.report.engines == ["r": .textKit2])
        linked.value = true
        registry.engineChanged()
        try await smartLinkEventually("the re-publish") { registry.report.engines == ["r": .textKit1] }

        registry.isIdentifying = false
        try await smartLinkEventually("the report off") { !registry.report.isIdentifying }
        #expect(registry.report.engines.isEmpty && registry.report.counts.isEmpty)
    }

    @Test("an unchanged publish notifies no observer")
    func unchangedPublishIsSilent() {
        let report = ADFRendererReport()
        report.publish(isIdentifying: true, engines: ["a": .swiftUI], counts: [.swiftUI: 1])
        let notified = Box(false)
        withObservationTracking {
            _ = report.isIdentifying
            _ = report.engines
            _ = report.counts
        } onChange: {
            notified.value = true
        }
        report.publish(isIdentifying: true, engines: ["a": .swiftUI], counts: [.swiftUI: 1])
        #expect(!notified.value)
        report.publish(isIdentifying: true, engines: ["a": .textKit2], counts: [.textKit2: 1])
        #expect(notified.value)
    }

    #if canImport(UIKit)
    // MARK: Through the document view

    /// The leaves the document view built, by key (`s:`/`t:` + owner id).
    @MainActor
    private struct Hosted {
        let model: ADFDocumentModel
        let window: UIWindow
        let host: UIHostingController<ADFDocumentView>

        var built: [String: ADFTextEngine] { model.rendererIdentity.builtEngines }
        var rows: [TextKit2RowView] { TextKit2FallbackTests.rows(in: host.view) }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    private func host(_ renderer: ADFTextRenderer, identifies: Bool) async throws -> Hosted {
        let model = try await TextKit2DiagnosticsTests.loadedModel()
        model.rendererIdentity.publishInterval = .zero
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 1_600))
        let host = UIHostingController(rootView: ADFDocumentView(
            model: model, mediaProvider: TextKit2DiagnosticsTests.NoMedia(),
            textRenderer: renderer, identifiesRenderer: identifies
        ))
        window.rootViewController = host
        window.isHidden = false
        try await TextKit2DiagnosticsTests.settle(window)
        TextKit2DiagnosticsTests.render(window)
        return Hosted(model: model, window: window, host: host)
    }

    /// The test document's blocks: paragraph, heading, atom paragraph,
    /// linked paragraph, panel, list, captioned media.
    private func ids(_ model: ADFDocumentModel) throws -> (paragraph: String, heading: String, atoms: String, linked: String, panel: String, listRow: String, media: String) {
        let blocks = model.blocks
        try #require(blocks.count == 7, "\(blocks.map(\.id))")
        guard case .listRows(let rows) = blocks[5].kind, let row = rows.first else { throw TestFailure("no list row") }
        guard case .media(let media) = blocks[6].kind else { throw TestFailure("no media: \(blocks[6].kind)") }
        return (blocks[0].id, blocks[1].id, blocks[2].id, blocks[3].id, blocks[4].id, row.id, media.id)
    }

    @Test("under TextKit 2 each leaf reports the engine that drew it; fallbacks report SwiftUI")
    func textKit2Reports() async throws {
        let hosted = try await host(.textKit2, identifies: true)
        defer { hosted.close() }
        let id = try ids(hosted.model)
        let built = hosted.built
        #expect(built["t:" + id.paragraph] == .textKit2, "\(built)")
        #expect(built["t:" + id.heading] == .textKit2, "\(built)")
        #expect(built["t:" + id.linked] == .textKit1, "\(built)")
        // Left on SwiftUI: the atom paragraph.
        #expect(built["s:" + id.atoms] == .swiftUI && built["t:" + id.atoms] == nil, "\(built)")
        // The panel's paragraph and the caption are TextKit 2 rows from
        // iOS 26 (container text and captions, PR 4); before it they stay
        // on SwiftUI (`TextKit2Eligibility.containerTextMatchesText`).
        let panelLeaves = built.filter { $0.key.dropFirst(2).hasPrefix(id.panel + ".") }
        if TextKit2Eligibility.containerTextMatchesText {
            #expect(!panelLeaves.isEmpty && panelLeaves.allSatisfy { $0.key.hasPrefix("t:") && $0.value == .textKit2 }, "\(built)")
            #expect(built["t:" + id.media] == .textKit2 && built["s:" + id.media] == nil, "\(built)")
        } else {
            #expect(!panelLeaves.isEmpty && panelLeaves.allSatisfy { $0.key.hasPrefix("s:") && $0.value == .swiftUI }, "\(built)")
            #expect(built["s:" + id.media] == .swiftUI, "\(built)")
        }
        if TextKit2Eligibility.listsMatchText {
            #expect(built["t:" + id.listRow] == .textKit2, "\(built)")
        } else {
            #expect(built["s:" + id.listRow] == .swiftUI, "\(built)")
        }

        // The rows mark themselves: fill, label, accessibility value.
        let rows = hosted.rows
        #expect(!rows.isEmpty)
        for row in rows {
            #expect(row.backgroundColor == row.engine.fillUIColor, "\(row.ownerID ?? "?")")
            #expect(row.accessibilityValue == row.engine.displayName, "\(row.ownerID ?? "?")")
            let labels = row.subviews.compactMap { $0 as? UILabel }
            #expect(labels.count == 1 && labels.first?.text == row.engine.displayName, "\(row.ownerID ?? "?")")
        }
        #expect(rows.contains { $0.engine == .textKit1 } && rows.contains { $0.engine == .textKit2 })

        // The report: identifying, and whatever it shows on screen is what
        // the leaves built.
        try await smartLinkEventually("the report") { hosted.model.rendererReport.isIdentifying }
        try await Task.sleep(for: .milliseconds(100))
        let report = hosted.model.rendererReport
        for (owner, engine) in report.engines {
            let reported = engine == .swiftUI ? built["s:" + owner] : built["t:" + owner]
            #expect(reported == engine, "\(owner): report \(engine), leaf \(String(describing: reported))")
        }
        print("RENDERER_REPORT textkit2 counts=\(report.counts) engines=\(report.engines.count) built=\(built.count)")
    }

    @Test("under SwiftUI every leaf reports SwiftUI")
    func swiftUIReports() async throws {
        let hosted = try await host(.swiftUI, identifies: true)
        defer { hosted.close() }
        let id = try ids(hosted.model)
        let built = hosted.built
        #expect(hosted.rows.isEmpty)
        #expect(!built.isEmpty && built.allSatisfy { $0.key.hasPrefix("s:") && $0.value == .swiftUI }, "\(built)")
        for owner in [id.paragraph, id.heading, id.atoms, id.linked, id.listRow, id.media] {
            #expect(built["s:" + owner] == .swiftUI, "\(owner): \(built)")
        }
        try await smartLinkEventually("the report") { hosted.model.rendererReport.isIdentifying }
        #expect(hosted.model.rendererReport.engines.values.allSatisfy { $0 == .swiftUI })
    }

    @Test("off adds nothing: no registered leaf, no row mark, an empty report; turning it off clears the marks")
    func offAddsNothing() async throws {
        let hosted = try await host(.textKit2, identifies: false)
        defer { hosted.close() }
        #expect(hosted.built.isEmpty)
        let rows = hosted.rows
        #expect(!rows.isEmpty)
        for row in rows {
            #expect(row.backgroundColor == .clear && row.accessibilityValue == nil && row.subviews.count == 1, "\(row.ownerID ?? "?"): \(row.subviews)")
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!hosted.model.rendererReport.isIdentifying && hosted.model.rendererReport.total == 0)
        #expect(hosted.model.rendererIdentity.publishCount == 0, "a document that never identified published a report")

        // On, then off again.
        hosted.host.rootView = ADFDocumentView(
            model: hosted.model, mediaProvider: TextKit2DiagnosticsTests.NoMedia(),
            textRenderer: .textKit2, identifiesRenderer: true
        )
        try await TextKit2DiagnosticsTests.settle(hosted.window)
        #expect(!hosted.built.isEmpty)
        #expect(hosted.rows.allSatisfy { $0.backgroundColor != .clear })
        hosted.host.rootView = ADFDocumentView(
            model: hosted.model, mediaProvider: TextKit2DiagnosticsTests.NoMedia(),
            textRenderer: .textKit2, identifiesRenderer: false
        )
        try await TextKit2DiagnosticsTests.settle(hosted.window)
        #expect(hosted.built.isEmpty, "\(hosted.built)")
        for row in hosted.rows {
            #expect(row.backgroundColor == .clear && row.accessibilityValue == nil && row.subviews.count == 1, "\(row.ownerID ?? "?")")
        }
        try await smartLinkEventually("the report off") { !hosted.model.rendererReport.isIdentifying }
        #expect(hosted.model.rendererReport.total == 0)
    }
    #endif
}
