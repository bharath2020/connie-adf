import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The text engine that drew a text leaf, as the leaf reports it
/// (`ADFDocumentView(identifiesRenderer:)`, `ADFRendererReport`). Not the
/// renderer setting (`ADFTextRenderer`): under `.textKit2` the text the
/// TextKit 2 renderer leaves on SwiftUI reports `.swiftUI`.
public enum ADFTextEngine: String, CaseIterable, Sendable, Identifiable {
    /// SwiftUI `Text`: every text leaf under `.swiftUI`, and under
    /// `.textKit2` every leaf it does not cover (containers and the text in
    /// them, tables, captions, paragraphs with inline atoms, text with
    /// active search highlights or inherited styling, and code the code
    /// gate keeps; see `ADFTextRenderer`).
    case swiftUI
    /// A TextKit 2 row that TextKit 2 lays out and draws.
    case textKit2
    /// A TextKit 2 row whose text holds a link: its TextKit 1 stack lays it
    /// out and draws it, the way SwiftUI's `Text` lays out linked text.
    case textKit1

    public var id: String { rawValue }

    /// The engine's name, as its leaves' labels show it.
    public var displayName: String {
        switch self {
        case .swiftUI: return "SwiftUI"
        case .textKit2: return "TextKit 2"
        case .textKit1: return "TextKit 1"
        }
    }

    /// The colour the engine marks its leaves with: orange SwiftUI, green
    /// TextKit 2, blue TextKit 1. White text on it is legible; a leaf is
    /// filled with it at 20 % opacity.
    public var color: Color {
        Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    static let fillOpacity = 0.2

    var rgb: (red: Double, green: Double, blue: Double) {
        switch self {
        case .swiftUI: return (0.80, 0.33, 0.00)
        case .textKit2: return (0.10, 0.52, 0.24)
        case .textKit1: return (0.16, 0.38, 0.85)
        }
    }

    #if canImport(UIKit)
    var uiColor: UIColor {
        UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }

    /// The fill a TextKit 2 row paints behind its text.
    var fillUIColor: UIColor {
        UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: Self.fillOpacity)
    }
    #endif
}

/// What the renderer reports drawing while its document view identifies
/// it (`ADFDocumentView(identifiesRenderer: true)`): for each text leaf on
/// screen, the engine that drew it, as that leaf reports it, never inferred
/// from the renderer setting. Read it from `ADFDocumentModel.rendererReport`.
///
/// Published at most four times a second, after the view update that
/// changed it, and read by nothing in the document: a host view observing
/// it (a renderer badge) invalidates no row. "On screen" is the leaf's
/// scroll visibility from iOS 18 / macOS 15; before, every leaf the lazy
/// stack has built counts. With identification off it is empty and
/// `isIdentifying` is false.
@Observable @MainActor
public final class ADFRendererReport {
    /// Whether the document view identifies its renderer.
    public private(set) var isIdentifying = false
    /// The engine that drew each text leaf on screen, keyed by the leaf's
    /// owner: a block's id (`RenderBlock.id`), a list row's or a media
    /// caption's.
    public private(set) var engines: [String: ADFTextEngine] = [:]
    /// How many text leaves on screen each engine drew.
    public private(set) var counts: [ADFTextEngine: Int] = [:]

    init() {}

    /// The text leaves on screen `engine` drew.
    public func count(_ engine: ADFTextEngine) -> Int {
        counts[engine] ?? 0
    }

    /// All text leaves on screen.
    public var total: Int {
        counts.values.reduce(0, +)
    }

    /// Sets only what changed: an unchanged publish notifies no observer.
    func publish(isIdentifying: Bool, engines: [String: ADFTextEngine], counts: [ADFTextEngine: Int]) {
        if self.isIdentifying != isIdentifying { self.isIdentifying = isIdentifying }
        if self.engines != engines { self.engines = engines }
        if self.counts != counts { self.counts = counts }
    }
}

/// The document's side of `identifiesRenderer`: the leaves that mark
/// themselves register here, and `report` is published from it. Not
/// observable: leaves write it from `onAppear`, `onDisappear` and their
/// scroll visibility, and those writes invalidate nothing (§16, §20; the
/// `VisibleRowRegistry` pattern). One coalesced publish follows a burst of
/// writes, `publishInterval` later, from a task, never inside a view
/// update.
@MainActor
final class RendererIdentityRegistry {
    private struct Leaf {
        var appearances: Int
        let ownerID: String
        /// Read at publish time: a TextKit 2 row's engine follows its text
        /// (a link makes it TextKit 1-backed).
        var engine: @MainActor () -> ADFTextEngine
    }

    let report = ADFRendererReport()
    /// How long after a change the report is published; changes meanwhile
    /// join that publish.
    var publishInterval: Duration = .milliseconds(250)

    /// Set by `ADFDocumentView` from `identifiesRenderer`, as the view is
    /// built: a change publishes (from a task, never during the update).
    var isIdentifying = false {
        didSet {
            guard isIdentifying != oldValue else { return }
            changed()
        }
    }

    /// Whether leaves report their scroll visibility (iOS 18 / macOS 15).
    /// Without it, a built leaf counts as on screen.
    static let tracksVisibility: Bool = {
        if #available(iOS 18.0, macOS 15.0, *) { return true }
        return false
    }()

    private var leaves: [String: Leaf] = [:]
    /// Leaves reported on screen, kept for a leaf whose visibility arrives
    /// before it appears; dropped when it disappears.
    private var visible: Set<String> = []
    private var publishPending = false
    /// Publishes so far (tests: coalescing).
    private(set) var publishCount = 0

    /// A marked leaf appeared. `key` is unique per leaf and engine family
    /// (`s:` SwiftUI, `t:` TextKit row), so a leaf and the one replacing it
    /// for the same owner during a renderer switch never cancel out.
    func appeared(_ key: String, ownerID: String, engine: @escaping @MainActor () -> ADFTextEngine) {
        if var leaf = leaves[key] {
            leaf.appearances += 1
            leaf.engine = engine
            leaves[key] = leaf
        } else {
            leaves[key] = Leaf(appearances: 1, ownerID: ownerID, engine: engine)
        }
        changed()
    }

    func disappeared(_ key: String) {
        guard var leaf = leaves[key] else { return }
        leaf.appearances -= 1
        if leaf.appearances > 0 {
            leaves[key] = leaf
        } else {
            leaves[key] = nil
            visible.remove(key)
        }
        changed()
    }

    func setVisible(_ key: String, _ isVisible: Bool) {
        let changedVisibility = isVisible ? visible.insert(key).inserted : visible.remove(key) != nil
        if changedVisibility, leaves[key] != nil { changed() }
    }

    /// A live TextKit 2 row's engine changed (its text gained or lost a
    /// link).
    func engineChanged() {
        changed()
    }

    /// The leaves built now, by key (tests: what each leaf reports, on
    /// screen or not).
    var builtEngines: [String: ADFTextEngine] {
        leaves.mapValues { $0.engine() }
    }

    private func changed() {
        guard !publishPending else { return }
        publishPending = true
        let interval = publishInterval
        Task { @MainActor [weak self] in
            if interval > .zero { try? await Task.sleep(for: interval) }
            self?.publish()
        }
    }

    /// Publishes the report now (also the coalesced publish's body).
    func publish() {
        publishPending = false
        publishCount += 1
        var engines: [String: ADFTextEngine] = [:]
        var counts: [ADFTextEngine: Int] = [:]
        if isIdentifying {
            for (key, leaf) in leaves where !Self.tracksVisibility || visible.contains(key) {
                let engine = leaf.engine()
                counts[engine, default: 0] += 1
                // A block and the leaf replacing it during a switch: the
                // TextKit row wins until the other leaves.
                if engines[leaf.ownerID] == nil || engine != .swiftUI {
                    engines[leaf.ownerID] = engine
                }
            }
        }
        report.publish(isIdentifying: isIdentifying, engines: engines, counts: counts)
    }
}

private struct ADFRendererIdentityKey: EnvironmentKey {
    static let defaultValue: RendererIdentityRegistry? = nil
}

extension EnvironmentValues {
    /// The document's identity registry while `ADFDocumentView` identifies
    /// its renderer; `nil` (the default) otherwise, and then no leaf adds
    /// anything.
    var adfRendererIdentity: RendererIdentityRegistry? {
        get { self[ADFRendererIdentityKey.self] }
        set { self[ADFRendererIdentityKey.self] = newValue }
    }
}

extension View {
    /// A SwiftUI text leaf's mark while its document identifies its
    /// renderer (`registry` non-nil): the SwiftUI fill behind the text, a
    /// "SwiftUI" label over its top trailing corner (an overlay: layout is
    /// unchanged), "SwiftUI" as its accessibility value, and its report
    /// (`RendererIdentityFeed`). With `registry` nil the leaf is `self`:
    /// no modifier at all.
    @ViewBuilder
    func swiftUIEngineMark(_ registry: RendererIdentityRegistry?, ownerID: String?) -> some View {
        if let registry {
            modifier(SwiftUIEngineMark(registry: registry, ownerID: ownerID))
        } else {
            self
        }
    }

    /// A TextKit row's report (its fill, label and accessibility value are
    /// the row view's own: `TextKit2RowView.rendererIdentity`).
    func rendererIdentityFeed(
        _ registry: RendererIdentityRegistry, key: String, ownerID: String,
        engine: @escaping @MainActor () -> ADFTextEngine
    ) -> some View {
        modifier(RendererIdentityFeed(registry: registry, key: key, ownerID: ownerID, engine: engine))
    }
}

/// See `View.swiftUIEngineMark`.
struct SwiftUIEngineMark: ViewModifier {
    let registry: RendererIdentityRegistry
    let ownerID: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        let marked = content
            .accessibilityValue(ADFTextEngine.swiftUI.displayName)
            .background(ADFTextEngine.swiftUI.color.opacity(ADFTextEngine.fillOpacity))
            .overlay(alignment: .topTrailing) { EngineLabel(engine: .swiftUI) }
        if let ownerID {
            marked.rendererIdentityFeed(registry, key: "s:" + ownerID, ownerID: ownerID) { .swiftUI }
        } else {
            marked
        }
    }
}

/// The label over a SwiftUI leaf's top trailing corner, straddling its top
/// edge; the TextKit 2 row draws the same one in UIKit
/// (`TextKit2RowView.engineLabel`). Fixed size, hidden from VoiceOver (the
/// leaf's accessibility value names the engine) and from touches.
struct EngineLabel: View {
    let engine: ADFTextEngine

    static let fontSize: CGFloat = 9
    /// Up from the leaf's top edge.
    static let rise: CGFloat = 9

    var body: some View {
        Text(engine.displayName)
            .font(.system(size: Self.fontSize, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(engine.color, in: RoundedRectangle(cornerRadius: 3))
            .fixedSize()
            .offset(y: -Self.rise)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Reports a marked leaf to the registry: built on appear, gone on
/// disappear (the backstop: a leaf that leaves the render region is not on
/// screen), and, from iOS 18 / macOS 15, on screen by its
/// `onScrollVisibilityChange(threshold: 0.01)`. The `#available` branch sits
/// on the leaf, deep in its row, never at a lazy stack's per-item position
/// (§18; `SmartLinkAttachment`'s shape). Every callback writes the
/// non-observable registry only, never view state.
struct RendererIdentityFeed: ViewModifier {
    let registry: RendererIdentityRegistry
    let key: String
    let ownerID: String
    let engine: @MainActor () -> ADFTextEngine

    func body(content: Content) -> some View {
        visibilityFeed(content)
            .onAppear { [registry, key, ownerID, engine] in registry.appeared(key, ownerID: ownerID, engine: engine) }
            .onDisappear { [registry, key] in registry.disappeared(key) }
    }

    @ViewBuilder
    private func visibilityFeed(_ content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content.onScrollVisibilityChange(threshold: 0.01) { [registry, key] visible in
                registry.setVisible(key, visible)
            }
        } else {
            content
        }
    }
}
