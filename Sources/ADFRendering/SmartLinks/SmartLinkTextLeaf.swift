import SwiftUI
import ADFPreparation

/// A text leaf (`TextEngineLeaf`) whose owner may hold smart links or
/// custom emoji: a paragraph or heading (`RichTextBlockView`) or a list
/// row's leader (`ListRowView`). It lives outside `TextKit2/` on purpose, so
/// the TextKit 2 sources stay free of view state and visibility plumbing.
///
/// - Under `.textKit2` it reads the owner's entries and hands the row the
///   displayed text (`SmartLinkDisplay.apply`, then `EmojiDisplay.apply`)
///   as its input: a changed stage is a changed input, and only that row
///   rebuilds its string and lays out again (`TextKit2RowView.apply` exits
///   early on equal inputs). A resolved smart link or custom emoji keeps the
///   row on TextKit 2: its icon or image is a text attachment.
/// - The SwiftUI `fallback` (`SegmentedTextView`) reads the entries itself,
///   after search painting, so this view computes nothing on that arm.
/// - It attaches the leaf to the coordinators while it is materialised and
///   reports the leaf's own viewport visibility through one feed shared by
///   both (`textLeafAttachment`).
///
/// - Custom emoji (`emojiKeys`): under `.textKit2` the row's input shows
///   each emoji as its stage draws it, with or without a resolver, so the
///   row never draws a raw U+FFFC; the SwiftUI `fallback` does the same
///   itself.
///
/// With no smart links (`smartLinkKeys` empty — nearly every owner) or no
/// smart-link resolver (no `adfSmartLinks`), and no custom emoji or no
/// emoji resolver (no `adfEmoji`), it reads no stage and adds no modifier:
/// the leaf is `TextEngineLeaf` as before (custom emoji without a resolver
/// still show their short names).
struct SmartLinkTextLeaf<Fallback: View>: View {
    let segments: [InlineSegment]
    let smartLinkKeys: [SmartLinkKey]
    /// The owner's custom emoji; `nil`: found in `segments` and shown as
    /// short names, never fed to the emoji coordinator
    /// (`SegmentedTextView.emojiKeys`).
    let emojiKeys: [EmojiKey]?
    let style: TextBlockStyle
    let ownerID: String?
    var allowsTextKit2 = true
    /// Handed to the leaf unchanged (`TextEngineLeaf.widthInset`): a
    /// paragraph's indentation, which the under-1-pt width guard subtracts.
    var widthInset: CGFloat = 0
    let fallback: Fallback

    @Environment(\.adfTextRenderer) private var renderer
    @Environment(\.adfSmartLinks) private var smartLinks
    @Environment(\.adfEmoji) private var emoji
    @Environment(\.adfTheme) private var theme

    init(
        segments: [InlineSegment], smartLinkKeys: [SmartLinkKey], emojiKeys: [EmojiKey]? = nil,
        style: TextBlockStyle, ownerID: String?,
        allowsTextKit2: Bool = true, widthInset: CGFloat = 0, @ViewBuilder fallback: () -> Fallback
    ) {
        self.segments = segments
        self.smartLinkKeys = smartLinkKeys
        self.emojiKeys = emojiKeys
        self.style = style
        self.ownerID = ownerID
        self.allowsTextKit2 = allowsTextKit2
        self.widthInset = widthInset
        self.fallback = fallback()
    }

    var body: some View {
        let _ = smartLinks?.noteLeafBody(ownerID, engine: true)
        let ownerEmoji = ownerEmojiKeys
        TextEngineLeaf(
            segments: textKit2Segments(emoji: ownerEmoji), style: style, ownerID: ownerID,
            allowsTextKit2: allowsTextKit2, widthInset: widthInset
        ) {
            fallback
        }
        .textLeafAttachment(
            ownerID: ownerID,
            smartLinkKeys: smartLinks == nil ? [] : smartLinkKeys,
            emojiKeys: emoji == nil || emojiKeys == nil ? [] : ownerEmoji
        )
    }

    /// The owner's custom emoji keys: as handed over, or found in the
    /// segments.
    private var ownerEmojiKeys: [EmojiKey] {
        emojiKeys ?? EmojiDisplay.keys(in: segments)
    }

    /// The segments the TextKit 2 arm judges and draws: the displayed text
    /// when the switch is ON and a smart-link stage changes the display or
    /// the owner has custom emoji, else the prepared segments untouched (no
    /// copy).
    private func textKit2Segments(emoji keys: [EmojiKey]) -> [InlineSegment] {
        guard renderer == .textKit2, allowsTextKit2 else { return segments }
        var displayed = segments
        if !smartLinkKeys.isEmpty, let smartLinks {
            let stages = smartLinks.displayStages(for: smartLinkKeys, owner: ownerID)
            if !stages.isEmpty {
                displayed = SmartLinkDisplay.apply(stages, to: displayed, theme: theme)
            }
        }
        if !keys.isEmpty {
            displayed = EmojiDisplay.apply(emojiStages(for: keys), to: displayed)
        }
        return displayed
    }

    /// The stages of the owner's custom emoji: the coordinator's entries for
    /// exactly `keys` (this leaf's observation dependency on them), or
    /// `nil` without a resolver or handed keys (every emoji shows its short
    /// name).
    private func emojiStages(for keys: [EmojiKey]) -> [EmojiKey: EmojiStage]? {
        guard emojiKeys != nil, let emoji else { return nil }
        return emoji.displayStages(for: keys, owner: ownerID)
    }
}

extension View {
    /// Attaches a text leaf to the document's smart-link and custom-emoji
    /// coordinators and feeds both the leaf's own visibility through ONE
    /// feed (`TextLeafAttachment`): `attach` on appear, `detach` on
    /// disappear (the backstop: a leaf that leaves the render region is no
    /// longer visible), and, from iOS 18 / macOS 15, the leaf's
    /// `onScrollVisibilityChange(threshold: 0.01)` (any point on screen,
    /// through nested scroll views such as a table's) and
    /// `onScrollVisibilityChange(threshold: 0.99999)` (all of it on screen:
    /// an outcome that would reflow the leaf mid-scroll waits for it).
    /// Visibility is the leaf's, not its row's, so a tall list row asks only
    /// for the items on screen; a prefetched leaf is attached but not
    /// visible and asks nothing. A change of coordinator, owner id or keys
    /// under a stable view moves the attachment (and its known visibility)
    /// to the new one, per coordinator.
    ///
    /// The caller passes empty keys for a coordinator that is not installed
    /// (`adfSmartLinks` / `adfEmoji` is `nil`). A leaf with neither (or
    /// without an owner id) gets no modifier at all, so documents without
    /// smart links and custom emoji pay nothing; with only one, only that
    /// coordinator is fed. Every callback writes only the coordinators'
    /// non-observable dictionaries, never view state (§16/§20).
    @ViewBuilder
    func textLeafAttachment(ownerID: String?, smartLinkKeys: [SmartLinkKey], emojiKeys: [EmojiKey]) -> some View {
        if let ownerID, !smartLinkKeys.isEmpty || !emojiKeys.isEmpty {
            modifier(TextLeafAttachment(ownerID: ownerID, smartLinkKeys: smartLinkKeys, emojiKeys: emojiKeys))
        } else {
            self
        }
    }
}

/// The one visibility feed of a text leaf, serving the smart-link and the
/// custom-emoji coordinators (`textLeafAttachment`). Two feeds on one leaf
/// would double the visibility callbacks of every leaf with both.
struct TextLeafAttachment: ViewModifier {
    let ownerID: String
    /// Empty when the leaf has no smart links or no smart-link coordinator
    /// is installed.
    let smartLinkKeys: [SmartLinkKey]
    /// Empty when the leaf has no custom emoji or no emoji coordinator is
    /// installed.
    let emojiKeys: [EmojiKey]

    @Environment(\.adfSmartLinks) private var smartLinks
    @Environment(\.adfEmoji) private var emoji

    func body(content: Content) -> some View {
        // A coordinator the leaf has no keys for is not fed at all.
        let links = smartLinkKeys.isEmpty ? nil : smartLinks
        let emoji = emojiKeys.isEmpty ? nil : emoji
        visibilityFeed(content, links: links, emoji: emoji)
            .onAppear {
                links?.attach(leaf: ownerID, keys: smartLinkKeys)
                emoji?.attach(leaf: ownerID, keys: emojiKeys)
            }
            .onDisappear {
                links?.detach(leaf: ownerID)
                emoji?.detach(leaf: ownerID)
            }
            // A coordinator newly fed by a leaf the other one already
            // feeds takes the visibility the other knows: the leaf's feed
            // reports no new crossing for it while it stays on screen.
            .onChange(of: SmartLinkAttachment.Attachment(coordinator: links, ownerID: ownerID, keys: smartLinkKeys)) { old, new in
                SmartLinkAttachment.move(
                    from: old, to: new,
                    otherVisible: emoji?.knownVisibility(of: new.ownerID),
                    otherFullyVisible: emoji?.knownFullVisibility(of: new.ownerID)
                )
            }
            .onChange(of: EmojiAttachment(coordinator: emoji, ownerID: ownerID, keys: emojiKeys)) { old, new in
                EmojiAttachment.move(
                    from: old, to: new,
                    otherVisible: links?.knownVisibility(of: new.ownerID),
                    otherFullyVisible: links?.knownFullVisibility(of: new.ownerID)
                )
            }
    }

    /// The leaf's visibility feeds: any point on screen (demand) and all of
    /// it on screen (when an outcome may land mid-scroll). Each callback
    /// tells every coordinator the leaf feeds, writing only their
    /// non-observable state (§16/§20). The `#available` branch sits on a
    /// leaf with keys, deep inside its row — never at a lazy stack's
    /// per-item position, which stays conditional-free (§18).
    @ViewBuilder
    private func visibilityFeed(
        _ content: Content, links: SmartLinkCoordinator?, emoji: EmojiCoordinator?
    ) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content
                .onScrollVisibilityChange(threshold: 0.01) { [links, emoji, ownerID] visible in
                    links?.setLeafVisible(ownerID, visible)
                    emoji?.setLeafVisible(ownerID, visible)
                }
                .onScrollVisibilityChange(threshold: SmartLinkAttachment.fullVisibilityThreshold) { [links, emoji, ownerID] fully in
                    links?.setLeafFullyVisible(ownerID, fully)
                    emoji?.setLeafFullyVisible(ownerID, fully)
                }
        } else {
            content
        }
    }
}

/// What a leaf is attached to the emoji coordinator as; a change detaches
/// the old and attaches the new (`SmartLinkAttachment.Attachment`'s twin).
struct EmojiAttachment: Equatable {
    let coordinator: EmojiCoordinator?
    let ownerID: String
    let keys: [EmojiKey]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.coordinator === rhs.coordinator && lhs.ownerID == rhs.ownerID && lhs.keys == rhs.keys
    }

    /// Moves a live leaf's attachment, as `SmartLinkAttachment.move` does:
    /// keys alone change in place; a new coordinator or owner id detaches
    /// from the old and attaches to the new, carrying the known visibility,
    /// the new attachment first under one coordinator so a shared key never
    /// loses demand. `otherVisible` / `otherFullyVisible`: what the leaf's
    /// other coordinator knows, used when the old one knows nothing (it was
    /// not fed: no coordinator, or no keys).
    @MainActor
    static func move(from old: Self, to new: Self, otherVisible: Bool? = nil, otherFullyVisible: Bool? = nil) {
        if old.coordinator === new.coordinator, old.ownerID == new.ownerID {
            new.coordinator?.update(leaf: new.ownerID, keys: new.keys)
            return
        }
        let visible = old.coordinator?.knownVisibility(of: old.ownerID) ?? otherVisible
        let fully = old.coordinator?.knownFullVisibility(of: old.ownerID) ?? otherFullyVisible
        if old.coordinator === new.coordinator {
            new.coordinator?.attach(leaf: new.ownerID, keys: new.keys, visible: visible, fullyVisible: fully)
            old.coordinator?.detach(leaf: old.ownerID)
        } else {
            old.coordinator?.detach(leaf: old.ownerID)
            new.coordinator?.attach(leaf: new.ownerID, keys: new.keys, visible: visible, fullyVisible: fully)
        }
    }
}

/// The smart-link half of `TextLeafAttachment`: the attachment identity,
/// the moves, and the full-visibility threshold both coordinators use.
enum SmartLinkAttachment {
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

    /// The full-visibility feed's threshold: the share of the leaf inside
    /// the scroll view's visible region (its safe area) above which it
    /// reports "fully on screen". Not 1.0: SwiftUI never reports `true` at
    /// 1.0, even for a view far inside the viewport (it compares strictly
    /// above the threshold; measured on iOS 27.1). 0.99999 switches exactly
    /// where the leaf's frame enters and leaves the visible region, at
    /// fractional offsets too (measured at 3.25 pt steps, alongside 0.9999,
    /// 0.999, 0.995 and 0.99, which agreed; 0.95 reported a view with
    /// 1.7 pt cut off as fully visible). At most 0.001 % of a leaf's height
    /// can be cut off, far below a pixel; floating-point noise in the frames
    /// (about 1e-13 pt) is far below that. Proven per renderer in
    /// `TextKit2SmartLinkTests.fullVisibilityFeedHoldsTitles`.
    static let fullVisibilityThreshold = 0.99999

    /// Moves a live leaf's attachment: keys alone change in place; a new
    /// coordinator (the host swapped models) or owner id (`apply(.replace)`
    /// gave the block a new id) detaches from the old and attaches to the
    /// new, carrying the visibility (any point, and all of it) the old one
    /// knew, since a leaf that stays on screen reports no new crossing.
    /// Under one coordinator the new attachment lands first, so a key both
    /// show never loses demand and its running lookup is not cancelled by
    /// the move. `otherVisible` / `otherFullyVisible`: what the leaf's other
    /// coordinator (custom emoji) knows, used when the old one knows
    /// nothing (it was not fed).
    @MainActor
    static func move(
        from old: Attachment, to new: Attachment, otherVisible: Bool? = nil, otherFullyVisible: Bool? = nil
    ) {
        if old.coordinator === new.coordinator, old.ownerID == new.ownerID {
            new.coordinator?.update(leaf: new.ownerID, keys: new.keys)
            return
        }
        let visible = old.coordinator?.knownVisibility(of: old.ownerID) ?? otherVisible
        let fully = old.coordinator?.knownFullVisibility(of: old.ownerID) ?? otherFullyVisible
        if old.coordinator === new.coordinator {
            new.coordinator?.attach(leaf: new.ownerID, keys: new.keys, visible: visible, fullyVisible: fully)
            old.coordinator?.detach(leaf: old.ownerID)
        } else {
            old.coordinator?.detach(leaf: old.ownerID)
            new.coordinator?.attach(leaf: new.ownerID, keys: new.keys, visible: visible, fullyVisible: fully)
        }
    }
}
