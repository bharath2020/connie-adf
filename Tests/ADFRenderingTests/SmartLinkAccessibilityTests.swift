#if canImport(UIKit)
import SwiftUI
import UIKit
import Darwin
import Testing
import ADFModel
import ADFPreparation
@_spi(ADFDiagnostics) @testable import ADFRendering

/// Design §6 on the SwiftUI renderer, read from SwiftUI's live accessibility
/// tree, not from the functions a leaf's body calls (call #39, amended by
/// #40): a paragraph, a list leader and an atom paragraph's word chunks
/// speak every stage word for word as a TextKit 2 row does, and offer the
/// same "Open link …" actions, which open the link.
///
/// SwiftUI builds its accessibility tree only for an assistive client, so
/// the suite switches the simulator's accessibility automation on (as
/// XCUITest does) and restores the value it found. The leaves are the real
/// `BlockView`s, hosted without the document's scroll view, whose lazy
/// content this walk does not reach.
@Suite("Smart-link VoiceOver in SwiftUI's accessibility tree", .serialized)
@MainActor
struct SmartLinkAccessibilityTests {
    typealias T = TextKit2SmartLinkTests

    static let other = "https://example.com/docs"
    static let page = T.page
    static let issue = ADFSmartLinkMetadata(title: "Fix the cache", icon: .issue)
    static let long = ADFSmartLinkMetadata(title: "Q3 Roadmap planning notes", icon: .page)
    /// iOS 18 / macOS 15 can disable a label (`accessibilityLabel(_:isEnabled:)`):
    /// a leaf showing its links as prepared is then untouched. Before, its
    /// label and actions are always on.
    static var labelsCanBeDisabled: Bool {
        if #available(iOS 18.0, macOS 15.0, *) { return true }
        return false
    }

    // MARK: Accessibility runtime

    /// The simulator's accessibility automation switch (`libAccessibility`),
    /// which makes SwiftUI build its accessibility tree in a unit-test host.
    /// It is a device-wide setting: always restore what `set` returns.
    enum Automation {
        typealias Getter = @convention(c) () -> Int32
        typealias Setter = @convention(c) (Int32) -> Void

        static let functions: (get: Getter, set: Setter)? = {
            let library = "/usr/lib/libAccessibility.dylib"
            let root = ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"]
            for path in [root.map { $0 + library }, library].compactMap({ $0 }) {
                guard let handle = dlopen(path, RTLD_NOW),
                      let get = dlsym(handle, "_AXSAutomationEnabled"),
                      let set = dlsym(handle, "_AXSSetAutomationEnabled") else { continue }
                return (unsafeBitCast(get, to: Getter.self), unsafeBitCast(set, to: Setter.self))
            }
            return nil
        }()

        /// Sets the switch; returns the value it had.
        @discardableResult
        static func set(_ value: Int32) throws -> Int32 {
            let functions = try #require(functions, "libAccessibility's automation switch was not found")
            let previous = functions.get()
            functions.set(value)
            return previous
        }
    }

    // MARK: Reading the tree

    /// One accessibility element as an assistive client meets it.
    struct Element: CustomStringConvertible {
        let object: NSObject
        let label: String
        let actions: [UIAccessibilityCustomAction]
        let actionNames: [String]
        let rotors: Int

        var description: String { "\(label.debugDescription) actions=\(actionNames) rotors=\(rotors)" }
    }

    /// Every element under `object`, in container order: an element is a
    /// leaf; a container is walked through `accessibilityElements`, then the
    /// indexed protocol, then subviews. Hidden elements are not listed.
    static func elements(under object: NSObject, depth: Int = 0) -> [Element] {
        guard depth < 64, !object.accessibilityElementsHidden else { return [] }
        if object.isAccessibilityElement {
            return [Element(
                object: object, label: object.accessibilityLabel ?? "",
                actions: object.accessibilityCustomActions ?? [],
                actionNames: (object.accessibilityCustomActions ?? []).map { $0.name },
                rotors: object.accessibilityCustomRotors?.count ?? 0
            )]
        }
        if let children = object.accessibilityElements, !children.isEmpty {
            return children.compactMap { $0 as? NSObject }.flatMap { elements(under: $0, depth: depth + 1) }
        }
        let count = object.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
            return (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject }
                .flatMap { elements(under: $0, depth: depth + 1) }
        }
        if let view = object as? UIView {
            return view.subviews.flatMap { elements(under: $0, depth: depth + 1) }
        }
        return []
    }

    /// The tree, read again (up to 2 s) until `done` holds: SwiftUI updates
    /// accessibility after it renders.
    static func read(_ host: TK2Parity.Host, until done: ([Element]) -> Bool) async throws -> [Element] {
        var found: [Element] = []
        for _ in 0..<20 {
            try await host.settle()
            found = elements(under: host.view)
            if done(found) { return found }
            try await Task.sleep(for: .milliseconds(100))
        }
        return found
    }

    // MARK: Hosting

    /// URLs the leaves asked the environment's `openURL` to open.
    final class Opened {
        var urls: [URL] = []
    }

    /// `model`'s blocks as the document draws them (`BlockView`), on the
    /// SwiftUI renderer with the model's coordinator, without a scroll view.
    static func host(_ model: ADFDocumentModel, opened: Opened) -> TK2Parity.Host {
        let blocks = VStack(alignment: .leading, spacing: 8) {
            ForEach(model.blocks) { block in
                BlockView(block: block)
            }
        }
        .environment(\.adfTheme, model.theme)
        .environment(\.adfTextRenderer, .swiftUI)
        .environment(\.adfSmartLinks, model.smartLinks)
        .environment(\.openURL, OpenURLAction { url in
            opened.urls.append(url)
            return .handled
        })
        return TK2Parity.Host(blocks, width: 390, height: 600)
    }

    static func model(_ json: String) async throws -> ADFDocumentModel {
        let model = ADFDocumentModel()
        model.smartLinks.timing.dwell = .zero
        model.smartLinks.hasVisibilityFeed = false
        model.load(data: Data(json.utf8))
        try await TextKit2StableIDReplacementTests.ready(model)
        return model
    }

    // MARK: Tests

    @Test("a paragraph and a list leader speak every stage as the TextKit 2 row does, and their actions open the links")
    func paragraphAndListLeader() async throws {
        let previous = try Automation.set(1)
        defer { _ = try? Automation.set(previous) }
        let a = T.a
        let sentence = T.paragraph(T.text("See "), T.link(a), T.text(" and "), T.link(Self.other), T.text(" now"))
        let item = T.paragraph(T.text("Item "), T.link(a))
        let model = try await Self.model(T.document([
            sentence, #"{"type":"bulletList","content":[{"type":"listItem","content":[\#(item)]}]}"#,
        ]))
        let opened = Opened()
        let host = Self.host(model, opened: opened)
        defer { host.close() }
        // The TextKit 2 row of the same paragraph: the reference.
        let textKit2 = try await T.host(T.document([sentence]), renderer: .textKit2, resolver: nil)
        defer { textKit2.close() }

        let stages: [(name: String, stage: SmartLinkStage, see: String, item: String, title: String?)] = [
            ("plain", .plain, "See \(a) and \(Self.other) now", "Item \(a)", nil),
            ("resolving", .resolving, "See \(a), loading title and \(Self.other) now", "Item \(a), loading title", nil),
            ("resolved page", .resolved(Self.page), "See Page, Q3 Roadmap and \(Self.other) now", "Item Page, Q3 Roadmap",
             "Q3 Roadmap"),
            ("resolved issue", .resolved(Self.issue), "See Issue, Fix the cache and \(Self.other) now",
             "Item Issue, Fix the cache", "Fix the cache"),
            ("failed", .failed(.unauthorized), "See \(a) and \(Self.other) now", "Item \(a)", nil),
        ]
        for (name, stage, see, item, title) in stages {
            for coordinator in [model.smartLinks, textKit2.model.smartLinks] {
                coordinator.entry(for: T.key(a)).publish(stage)
            }
            try await textKit2.settle()
            let row = try #require(textKit2.rows()["0.0"], "\(name): no TextKit 2 row")
            let tree = try await Self.read(host) { tree in
                tree.contains { $0.label == see } && tree.contains { $0.label == item }
            }
            print("SMARTLINK_AX \(name): \(tree) textKit2=\(row.accessibilityLabel ?? "nil") \(T.actionNames(row))")
            let paragraph = try #require(tree.first { $0.label.hasPrefix("See ") }, "\(name): no paragraph in \(tree)")
            let leader = try #require(tree.first { $0.label.hasPrefix("Item ") }, "\(name): no list leader in \(tree)")
            // Spoken text: design §6, word for word what the TextKit 2 row says.
            #expect(paragraph.label == see, "\(name): the paragraph speaks \(paragraph.label.debugDescription)")
            #expect(paragraph.label == row.accessibilityLabel, "\(name): TextKit 2 says \(row.accessibilityLabel ?? "nil")")
            #expect(leader.label == item, "\(name): the list leader speaks \(leader.label.debugDescription)")
            #expect(!tree.contains { $0.label.contains("\u{FFFC}") }, "\(name): an element reads the icon character")
            // Links: while a stage shows, the label hides SwiftUI's link
            // rotor and the actions reach the links, named as TextKit 2 names
            // them. As prepared (iOS 18+), the leaf is untouched: no label,
            // no actions, the rotor as on any leaf.
            if stage.changesDisplay || !Self.labelsCanBeDisabled {
                #expect(paragraph.actionNames == T.actionNames(row), "\(name): actions \(paragraph.actionNames)")
                #expect(leader.actionNames == ["Open link \(title ?? "acme.atlassian.net")"], "\(name): \(leader.actionNames)")
            } else {
                #expect(paragraph.actionNames.isEmpty && leader.actionNames.isEmpty, "\(name): \(paragraph) \(leader)")
                #expect(paragraph.rotors > 0 && leader.rotors > 0, "\(name): the link rotor is gone: \(paragraph) \(leader)")
            }
            if case .resolved = stage {
                // Each action opens its own link through `openURL`, as a tap
                // on the link does.
                opened.urls = []
                for action in paragraph.actions + leader.actions {
                    #expect(action.actionHandler?(action) == true, "\(name): \(action.name) not handled")
                }
                #expect(opened.urls == [URL(string: a)!, URL(string: Self.other)!, URL(string: a)!],
                        "\(name): opened \(opened.urls)")
            }
        }
    }

    @Test("an atom paragraph: the first word chunk of a link speaks it once and opens it; the others are hidden")
    func atomParagraphChunks() async throws {
        let previous = try Automation.set(1)
        defer { _ = try? Automation.set(previous) }
        let a = T.a
        let mention = #"{"type":"mention","attrs":{"id":"1","text":"@sam"}}"#
        let model = try await Self.model(T.document([
            T.paragraph(T.text("Ping "), mention, T.text(" see "), T.link(a), T.text(", ok")),
        ]))
        let opened = Opened()
        let host = Self.host(model, opened: opened)
        defer { host.close() }
        let entry = model.smartLinks.entry(for: T.key(a))

        // As prepared the URL is one chunk with its own text and the rotor.
        let plain = try await Self.read(host) { $0.contains { $0.label == "\(a), " } }
        print("SMARTLINK_AX atom plain: \(plain)")
        let plainChunk = try #require(plain.first { $0.label == "\(a), " }, "no URL chunk in \(plain)")
        #expect(plainChunk.actionNames.isEmpty && plainChunk.rotors > 0, "\(plainChunk)")

        entry.publish(.resolving)
        let resolving = try await Self.read(host) { $0.contains { $0.label == "\(a), loading title, " } }
        print("SMARTLINK_AX atom resolving: \(resolving)")
        let loading = try #require(resolving.first { $0.label == "\(a), loading title, " }, "no loading chunk in \(resolving)")
        #expect(loading.actionNames == ["Open link acme.atlassian.net"], "\(loading)")

        entry.publish(.resolved(Self.long))
        let resolved = try await Self.read(host) { $0.contains { $0.label == "Page, Q3 Roadmap planning notes" } }
        print("SMARTLINK_AX atom resolved: \(resolved)")
        let first = try #require(resolved.first { $0.label == "Page, Q3 Roadmap planning notes" },
                                 "no title chunk in \(resolved)")
        #expect(first.actionNames == ["Open link Q3 Roadmap planning notes"], "\(first)")
        // The title is spoken once: its continuation chunks are hidden, and
        // the last keeps only its own comma.
        let labels = resolved.map(\.label)
        #expect(labels.filter { $0.contains("Roadmap") }.count == 1, "\(labels)")
        #expect(!labels.contains { $0.contains("planning") && !$0.hasPrefix("Page,") }, "\(labels)")
        #expect(!labels.contains { $0.contains("\u{FFFC}") }, "\(labels)")
        #expect(resolved.filter { !$0.actions.isEmpty }.count == 1, "one chunk carries the link's action: \(resolved)")
        opened.urls = []
        #expect(first.actions.first.map { $0.actionHandler?($0) == true } == true)
        #expect(opened.urls == [URL(string: a)!], "opened \(opened.urls)")
    }
}
#endif
