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
/// - It attaches the leaf to the coordinator while it is on screen
///   (`smartLinkAttachment`).
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
    /// while it is on screen: `attach` on appear (with the row it sits in),
    /// `detach` on disappear, `update` when its keys change under a stable
    /// identity. Leaves without smart links (or without an owner id) get no
    /// modifier at all. Appear/disappear, not visibility: whether the row is
    /// on screen comes from the row's own feed (`ScrollVisibilityReporter`).
    @ViewBuilder
    func smartLinkAttachment(ownerID: String?, keys: [SmartLinkKey]) -> some View {
        if let ownerID, !keys.isEmpty {
            modifier(SmartLinkAttachment(ownerID: ownerID, keys: keys))
        } else {
            self
        }
    }
}

private struct SmartLinkAttachment: ViewModifier {
    let ownerID: String
    let keys: [SmartLinkKey]

    @Environment(\.adfSmartLinks) private var smartLinks
    @Environment(\.adfSmartLinkRowID) private var rowID

    func body(content: Content) -> some View {
        content
            .onAppear { smartLinks?.attach(leaf: ownerID, row: rowID, keys: keys) }
            .onDisappear { smartLinks?.detach(leaf: ownerID) }
            .onChange(of: keys) { _, keys in
                smartLinks?.update(leaf: ownerID, row: rowID, keys: keys)
            }
    }
}
