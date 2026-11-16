import SwiftUI
import ADFPreparation

/// A text leaf (`TextEngineLeaf`) whose owner may hold smart links: a
/// paragraph or heading (`RichTextBlockView`) or a list row's leader
/// (`ListRowView`). It lives outside `TextKit2/` on purpose, so the TextKit 2
/// sources stay free of view state and visibility plumbing.
///
/// - Under `.textKit2` it reads the owner's entries and hands the row the
///   displayed text (`SmartLinkDisplay.apply`) as its input: a changed stage
///   is a changed input, and only that row rebuilds its string and lays out
///   again (`TextKit2RowView.apply` exits early on equal inputs). A resolved
///   smart link keeps the row on TextKit 2: the displayed text is ordinary
///   described text, its icon a text attachment.
/// - The SwiftUI `fallback` (`SegmentedTextView`) reads the entries itself,
///   after search painting, so this view computes nothing on that arm.
/// - It attaches the leaf to the coordinator while it is materialised and
///   reports the leaf's own viewport visibility (`smartLinkAttachment`).
///
/// With no smart links (`smartLinkKeys` empty — nearly every owner) it reads
/// nothing and adds no modifier: the leaf is `TextEngineLeaf` as before.
struct SmartLinkTextLeaf<Fallback: View>: View {
    let segments: [InlineSegment]
    let smartLinkKeys: [SmartLinkKey]
    let style: TextBlockStyle
    let ownerID: String?
    var allowsTextKit2 = true
    let fallback: Fallback

    @Environment(\.adfTextRenderer) private var renderer
    @Environment(\.adfSmartLinks) private var smartLinks
    @Environment(\.adfTheme) private var theme

    init(
        segments: [InlineSegment], smartLinkKeys: [SmartLinkKey], style: TextBlockStyle, ownerID: String?,
        allowsTextKit2: Bool = true, @ViewBuilder fallback: () -> Fallback
    ) {
        self.segments = segments
        self.smartLinkKeys = smartLinkKeys
        self.style = style
        self.ownerID = ownerID
        self.allowsTextKit2 = allowsTextKit2
        self.fallback = fallback()
    }

    var body: some View {
        let _ = smartLinks?.noteLeafBody(ownerID, engine: true)
        TextEngineLeaf(segments: textKit2Segments, style: style, ownerID: ownerID, allowsTextKit2: allowsTextKit2) {
            fallback
        }
        .smartLinkAttachment(ownerID: ownerID, keys: smartLinkKeys)
    }

    /// The segments the TextKit 2 arm judges and draws: the displayed text
    /// when the switch is ON and a stage changes the display, else the
    /// prepared segments untouched (no copy).
    private var textKit2Segments: [InlineSegment] {
        guard !smartLinkKeys.isEmpty, renderer == .textKit2, allowsTextKit2, let smartLinks else { return segments }
        let stages = smartLinks.displayStages(for: smartLinkKeys, owner: ownerID)
        guard !stages.isEmpty else { return segments }
        return SmartLinkDisplay.apply(stages, to: segments, theme: theme)
    }
}

extension View {
    /// Attaches a text leaf with smart links to the document's coordinator
    /// and feeds it the leaf's own visibility: `attach` on appear, `detach`
    /// on disappear (the backstop: a leaf that leaves the render region is
    /// no longer visible), and, from iOS 18 / macOS 15, the leaf's
    /// `onScrollVisibilityChange(threshold: 0.01)` (any point on screen,
    /// through nested scroll views such as a table's). Visibility is the
    /// leaf's, not its row's, so a tall list row resolves only the items on
    /// screen; a prefetched leaf is attached but not visible and asks
    /// nothing. A change of coordinator, owner id or keys under a stable
    /// view moves the attachment (and its known visibility) to the new one.
    ///
    /// Leaves without smart links (or without an owner id) get no modifier
    /// at all, so documents without smart links pay nothing. Every callback
    /// writes only the coordinator's non-observable dictionaries, never view
    /// state (§16/§20).
    @ViewBuilder
    func smartLinkAttachment(ownerID: String?, keys: [SmartLinkKey]) -> some View {
        if let ownerID, !keys.isEmpty {
            modifier(SmartLinkAttachment(ownerID: ownerID, keys: keys))
        } else {
            self
        }
    }
}

struct SmartLinkAttachment: ViewModifier {
    let ownerID: String
    let keys: [SmartLinkKey]

    @Environment(\.adfSmartLinks) private var smartLinks

    /// What the leaf is attached as; a change detaches the old and attaches
    /// the new. The coordinator is compared by identity.
    struct Attachment: Equatable {
        let coordinator: SmartLinkCoordinator?
        let ownerID: String
        let keys: [SmartLinkKey]

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.coordinator === rhs.coordinator && lhs.ownerID == rhs.ownerID && lhs.keys == rhs.keys
        }
    }

    func body(content: Content) -> some View {
        visibilityFeed(content)
            .onAppear { smartLinks?.attach(leaf: ownerID, keys: keys) }
            .onDisappear { smartLinks?.detach(leaf: ownerID) }
            .onChange(of: Attachment(coordinator: smartLinks, ownerID: ownerID, keys: keys)) { old, new in
                Self.move(from: old, to: new)
            }
    }

    /// The leaf's visibility feed. The `#available` branch sits on a leaf
    /// with smart links, deep inside its row — never at a lazy stack's
    /// per-item position, which stays conditional-free (§18; the same shape
    /// as `ScrollVisibilityGate` on media).
    @ViewBuilder
    private func visibilityFeed(_ content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content.onScrollVisibilityChange(threshold: 0.01) { [smartLinks, ownerID] visible in
                smartLinks?.setLeafVisible(ownerID, visible)
            }
        } else {
            content
        }
    }

    /// Moves a live leaf's attachment: keys alone change in place; a new
    /// coordinator (the host swapped models) or owner id (`apply(.replace)`
    /// gave the block a new id) detaches from the old and attaches to the
    /// new, carrying the visibility the old one knew, since a leaf that
    /// stays on screen reports no new crossing. Under one coordinator the
    /// new attachment lands first, so a key both show never loses demand
    /// and its running lookup is not cancelled by the move.
    @MainActor
    static func move(from old: Attachment, to new: Attachment) {
        if old.coordinator === new.coordinator, old.ownerID == new.ownerID {
            new.coordinator?.update(leaf: new.ownerID, keys: new.keys)
            return
        }
        let visible = old.coordinator?.knownVisibility(of: old.ownerID)
        if old.coordinator === new.coordinator {
            new.coordinator?.attach(leaf: new.ownerID, keys: new.keys, visible: visible)
            old.coordinator?.detach(leaf: old.ownerID)
        } else {
            old.coordinator?.detach(leaf: old.ownerID)
            new.coordinator?.attach(leaf: new.ownerID, keys: new.keys, visible: visible)
        }
    }
}
