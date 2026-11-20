import SwiftUI
import ADFPreparation

/// Renders a composed inline sequence.
///
/// Fast path: when every segment is text, the runs concatenate into a single
/// `Text(AttributedString)`. When atoms (mentions, statuses, dates, …) are
/// present, a wrapping custom `Layout` interleaves word-level `Text` chunks
/// with inline pill views.
///
/// Smart links (`smartLinkKeys`, the owner's prepared keys): the leaf reads
/// the coordinator's entries for exactly those keys and draws the displayed
/// text (`SmartLinkDisplay`) after search painting. Empty keys — nearly
/// every owner — and a document without a resolver (no `adfSmartLinks`)
/// read nothing and do nothing. While a link shows a stage
/// other than its prepared text, the leaf speaks the spoken text and offers
/// an "Open link …" action per link (`SmartLinkSpeech`, view-level, so the
/// callers' `textSelection(.enabled)` keeps it; in an atom paragraph each
/// word chunk holding a link does), word for word what a TextKit 2 row says.
///
/// Custom emoji (`emojiKeys`, the owner's prepared keys): the leaf replaces
/// each emoji's U+FFFC with what its stage shows (`EmojiDisplay`) after the
/// smart-link substitution, with or without a resolver (no resolver: the
/// short name), and speaks the emoji's name through the same
/// `SmartLinkSpeech`. Owners without custom emoji do nothing.
struct SegmentedTextView: View {
    let segments: [InlineSegment]
    /// ID search highlights are keyed by (`RenderBlock.id`, list-row id, or
    /// media id). `nil` opts out of search entirely (previews, chrome).
    var ownerID: String? = nil
    /// The owner's smart links (`RenderBlock.smartLinkKeys`,
    /// `PreparedListRow.smartLinkKeys`, `PreparedMedia.captionSmartLinkKeys`).
    var smartLinkKeys: [SmartLinkKey] = []
    /// The owner's custom emoji (`RenderBlock.emojiKeys`,
    /// `PreparedListRow.emojiKeys`). `nil`: not handed over by the caller (a
    /// media caption), so the leaf finds them in `segments`
    /// (`EmojiDisplay.keys(in:)`) and, since such a caller does not feed
    /// them to the emoji coordinator, shows their short names.
    var emojiKeys: [EmojiKey]? = nil

    /// Gap between wrapped lines, scaled with Dynamic Type so line rhythm
    /// tracks the text size it separates.
    @ScaledMetric(relativeTo: .body) private var lineSpacing: CGFloat = 3

    /// The live Dynamic Type factor: `1` at the default size, growing with
    /// larger accessibility sizes. Used to scale sub/superscript baseline
    /// offsets, which are baked as fixed points at preparation time and would
    /// otherwise stay put while the font grew.
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

    @Environment(\.adfDocumentSearch) private var search
    @Environment(\.adfSmartLinks) private var smartLinks
    @Environment(\.adfEmoji) private var emojiCoordinator
    @Environment(\.adfTheme) private var theme
    /// The document's identity registry while it identifies its renderer
    /// (`ADFDocumentView(identifiesRenderer:)`); `nil`, the default, adds
    /// nothing to the leaf.
    @Environment(\.adfRendererIdentity) private var rendererIdentity
    /// Flash off-phase: while true the current match paints with the subtle
    /// color, so alternating it blinks the accent (§ arrival flash).
    @State private var flashDimmed = false

    var body: some View {
        let _ = TextLeafDiagnostics.countSegmentedBody()
        let _ = smartLinks?.noteLeafBody(ownerID, engine: false)
        let stages = smartLinkStages
        let emoji = ownerEmojiKeys
        let displayed = displayedSegments(smartLinks: stages, emoji: emoji)
        // An owner with custom emoji always shows them substituted (a
        // constant for the leaf, as `smartLinkKeys` is).
        let showsEmoji = !emoji.isEmpty
        let composesSmartLinks = !stages.isEmpty
        let composes = composesSmartLinks || showsEmoji
        let merged = Self.mergedText(displayed)
        Group {
            if let merged, smartLinks == nil || smartLinkKeys.isEmpty, !showsEmoji {
                Text(Self.scalingBaselineOffsets(in: merged, by: typeScale))
            } else if let merged {
                // A leaf with smart links or custom emoji (a constant for
                // the leaf, so the branch never flips with a stage):
                // VoiceOver hears the stage through `SmartLinkSpeech`, whose
                // inputs alone change.
                let text = Self.scalingBaselineOffsets(in: merged, by: typeScale)
                DisplayedText(text: text, composes: composes, showsStage: composes)
            } else {
                WrappingInlineLayout(lineSpacing: lineSpacing) {
                    ForEach(Self.tokens(for: displayed, composesSmartLinks: composes)) { token in
                        InlineTokenView(
                            token: token,
                            typeScale: typeScale,
                            atomHighlight: atomHighlight(for: token)
                        )
                    }
                }
            }
        }
        .searchArrivalFlash(ownerID: ownerID, dimmed: $flashDimmed)
        .swiftUIEngineMark(rendererIdentity, ownerID: ownerID)
    }

    /// One `Text` for the leaf's merged text: the attributed string as is,
    /// or, when the owner shows a smart link or a custom emoji, composed with
    /// its icons and emoji images (`SmartLinkDisplay.composedText`). Both
    /// are `Text`: no structural branch. VoiceOver's text for it is the
    /// leaf's `SmartLinkSpeech`.
    @MainActor
    static func text(
        _ attributed: AttributedString, composesSmartLinks: Bool, metrics: EmojiDisplay.Metrics = .init()
    ) -> Text {
        composesSmartLinks ? SmartLinkDisplay.composedText(attributed, metrics: metrics) : Text(attributed)
    }

    // MARK: Custom emoji

    /// The owner's custom emoji keys: as handed over, or found in the
    /// segments when the caller handed none.
    private var ownerEmojiKeys: [EmojiKey] {
        emojiKeys ?? EmojiDisplay.keys(in: segments)
    }

    /// The stages of the owner's custom emoji: the coordinator's entries for
    /// exactly `keys` (the leaf's observation dependency on them, as
    /// `smartLinkStages`), or `nil` (every emoji shows its short name)
    /// without a resolver, or when the caller handed no `emojiKeys`. Such
    /// a caller (a media caption) does not attach the leaf to the emoji
    /// coordinator, so its emoji would never be asked for and would stay
    /// blank boxes; they show their short names instead.
    private func emojiStages(for keys: [EmojiKey]) -> [EmojiKey: EmojiStage]? {
        guard emojiKeys != nil, let emojiCoordinator else { return nil }
        return emojiCoordinator.displayStages(for: keys, owner: ownerID)
    }

    // MARK: Smart links

    /// The zero-work gate: an owner without smart links reads nothing.
    /// Otherwise the entries for its own keys are read (its only
    /// observation dependency on smart links), and only stages that change
    /// the display come back.
    private var smartLinkStages: [SmartLinkKey: SmartLinkStage] {
        guard !smartLinkKeys.isEmpty, let smartLinks else { return [:] }
        return smartLinks.displayStages(for: smartLinkKeys, owner: ownerID)
    }

    /// Search painting first, on the prepared segments its spans index;
    /// then the smart-link substitution, so a match inside a link
    /// highlights its whole title; then the custom emoji (`EmojiDisplay`),
    /// for an owner with any.
    private func displayedSegments(
        smartLinks stages: [SmartLinkKey: SmartLinkStage], emoji: [EmojiKey]
    ) -> [InlineSegment] {
        var displayed = displayedSegments
        if !stages.isEmpty {
            displayed = SmartLinkDisplay.apply(stages, to: displayed, theme: theme)
        }
        if !emoji.isEmpty {
            displayed = EmojiDisplay.apply(emojiStages(for: emoji), to: displayed)
        }
        return displayed
    }

    // MARK: Search highlighting

    /// The zero-work gate: rows without matches return the stored segments
    /// untouched (no copy, no scan) — the path every row takes while
    /// scrolling with no search active, and every unmatched row during one.
    /// With no active session the gate reads ONE observable Bool
    /// (`isActive`, which flips at most twice per session) and never touches
    /// the `highlights` struct — leaf materialization during plain scrolling
    /// is what the §8 hitch gate measures.
    private var displayedSegments: [InlineSegment] {
        guard let ownerID, let search, search.isActive else {
            return segments
        }
        let highlights = search.ownerHighlights(for: ownerID)
        let spans = highlights.spans
        let currentSpans = highlights.currentSpans
        guard !spans.isEmpty || !currentSpans.isEmpty else { return segments }
        return SearchHighlightPainter.paint(
            segments: segments,
            spans: spans,
            currentSpans: currentSpans,
            theme: theme,
            dimCurrent: flashDimmed
        )
    }

    private func atomHighlight(for token: InlineToken) -> AtomHighlightState? {
        guard case .atom(_, let id) = token.kind,
              let ownerID, let search, search.isActive else { return nil }
        let highlights = search.ownerHighlights(for: ownerID)
        if highlights.currentAtomIDs.contains(id) {
            return .current(dimmed: flashDimmed)
        }
        return highlights.atomIDs.contains(id) ? .subtle : nil
    }

    /// Multiplies any baked sub/superscript baseline offsets by the Dynamic
    /// Type factor so the raise/drop tracks the font size. Returns the input
    /// untouched at the default size (factor `1`) — the overwhelmingly common
    /// case does zero work and never walks the runs.
    static func scalingBaselineOffsets(in text: AttributedString, by factor: CGFloat) -> AttributedString {
        guard factor != 1 else { return text }
        var scaled = text
        let edits: [(Range<AttributedString.Index>, CGFloat)] = scaled.runs.compactMap { run in
            run.baselineOffset.map { (run.range, $0 * factor) }
        }
        for (range, offset) in edits {
            scaled[range].baselineOffset = offset
        }
        return scaled
    }

    /// The pre-merged text run for all-text content, or `nil` when any
    /// segment is an atom. The preparer emits one merged run per gap, so the
    /// common case returns the existing value without building or copying an
    /// `AttributedString` inside `body` (§5.3).
    nonisolated static func mergedText(_ segments: [InlineSegment]) -> AttributedString? {
        if segments.count == 1, case .text(let only) = segments[0] {
            return only
        }
        var merged = AttributedString()
        for segment in segments {
            guard case .text(let text) = segment else { return nil }
            merged.append(text)
        }
        return merged
    }

    /// Maps segments 1:1 to layout tokens. Word-level chunking already
    /// happened at preparation time (`InlineComposer.splitForWrappingLayout`),
    /// so no character scanning or attributed-string slicing runs here — a
    /// standalone `"\n"` chunk becomes an explicit line break. Only when the
    /// owner shows a smart link or a custom emoji (`composesSmartLinks`) are
    /// chunks looked into: one holding a displayed link or emoji becomes a
    /// `smartLinkText` token with its spoken text.
    static func tokens(for segments: [InlineSegment], composesSmartLinks: Bool = false) -> [InlineToken] {
        var tokens: [InlineToken] = []
        tokens.reserveCapacity(segments.count)
        for segment in segments {
            switch segment {
            case .atom(let atom, let id):
                tokens.append(InlineToken(id: tokens.count, kind: .atom(atom, id: id)))
            case .text(let text):
                if isLineBreak(text) {
                    tokens.append(InlineToken(id: tokens.count, kind: .lineBreak))
                } else if composesSmartLinks, Self.showsDisplayedPiece(text) {
                    let spoken = SmartLinkDisplay.accessibilityText(of: text)
                    tokens.append(InlineToken(id: tokens.count, kind: .smartLinkText(text, spoken: spoken)))
                } else {
                    tokens.append(InlineToken(id: tokens.count, kind: .text(text)))
                }
            }
        }
        return tokens
    }

    /// Whether a chunk holds a displayed smart link or custom emoji.
    private static func showsDisplayedPiece(_ text: AttributedString) -> Bool {
        text.runs[SmartLinkShownAttribute.self].contains(where: { $0.0 != nil })
            || text.runs[EmojiShownAttribute.self].contains(where: { $0.0 != nil })
    }

    /// True for a chunk that is exactly one `"\n"` (O(1), no full scan).
    private static func isLineBreak(_ text: AttributedString) -> Bool {
        let characters = text.characters
        guard let first = characters.first, first == "\n" else { return false }
        return characters.index(after: characters.startIndex) == characters.endIndex
    }
}

/// Text-leaf body evaluations since launch, process-wide (diagnostics: the
/// demo's About sheet and the smart-link UI test's proof that a resolution
/// re-evaluates no other leaf). Plain integers bumped at the top of each
/// leaf's `body`: nothing observable, so counting adds no dependency and
/// invalidates nothing.
@MainActor
enum TextLeafDiagnostics {
    /// `SegmentedTextView.body`: every text leaf SwiftUI's `Text` draws.
    private(set) static var segmentedBodies = 0
    /// `TextEngineLeaf.body`: every paragraph, heading, list leader and code
    /// text, before the engine choice (under TextKit 2 the row's text input
    /// is made here).
    private(set) static var engineBodies = 0

    @discardableResult
    static func countSegmentedBody() -> Int {
        segmentedBodies &+= 1
        return segmentedBodies
    }

    @discardableResult
    static func countEngineBody() -> Int {
        engineBodies &+= 1
        return engineBodies
    }
}

/// Text-leaf body evaluations since launch (`ADFTextRenderer.textLeafStats`),
/// process-wide: under SwiftUI a text leaf re-evaluates `SegmentedTextView`
/// (its engine leaf too only when its inputs changed), under TextKit 2 a
/// row's text input is made in its engine leaf.
@_spi(ADFDiagnostics)
public struct ADFTextLeafStats: Sendable, Hashable {
    /// `SegmentedTextView` body evaluations (SwiftUI-drawn text leaves).
    public var segmentedTextBodies: Int
    /// Engine-leaf body evaluations (paragraphs, headings, list leaders and
    /// code text, on either renderer).
    public var engineLeafBodies: Int
    /// Both counts.
    public var total: Int { segmentedTextBodies + engineLeafBodies }

    public init(segmentedTextBodies: Int = 0, engineLeafBodies: Int = 0) {
        self.segmentedTextBodies = segmentedTextBodies
        self.engineLeafBodies = engineLeafBodies
    }
}

extension ADFTextRenderer {
    /// Text-leaf body evaluations since launch (see `ADFTextLeafStats`).
    @_spi(ADFDiagnostics)
    @MainActor
    public static var textLeafStats: ADFTextLeafStats {
        ADFTextLeafStats(
            segmentedTextBodies: TextLeafDiagnostics.segmentedBodies,
            engineLeafBodies: TextLeafDiagnostics.engineBodies
        )
    }
}

/// One unit placed by `WrappingInlineLayout`.
struct InlineToken: Identifiable, Hashable {
    enum Kind: Hashable {
        case text(AttributedString)
        /// A word chunk holding a displayed smart link or custom emoji, with
        /// the text VoiceOver speaks for it: the link's whole spoken text on
        /// its first chunk, nothing on a continuation chunk (hidden then).
        case smartLinkText(AttributedString, spoken: String)
        case atom(InlineAtom, id: String)
        case lineBreak
    }

    let id: Int
    let kind: Kind
}

/// Whole-pill search emphasis for atoms (pills are plain `Text`, not
/// range-highlightable, so a matched pill tints entirely).
enum AtomHighlightState: Equatable {
    case subtle
    case current(dimmed: Bool)
}

struct InlineTokenView: View {
    let token: InlineToken
    /// Live Dynamic Type factor for scaling sub/superscript baseline offsets
    /// on word-chunk text tokens (see `SegmentedTextView`).
    var typeScale: CGFloat = 1
    var atomHighlight: AtomHighlightState? = nil

    @Environment(\.adfTheme) private var theme

    var body: some View {
        switch token.kind {
        case .text(let text):
            Text(SegmentedTextView.scalingBaselineOffsets(in: text, by: typeScale))
        case .smartLinkText(let text, let spoken):
            let scaled = SegmentedTextView.scalingBaselineOffsets(in: text, by: typeScale)
            DisplayedText(text: scaled, composes: true, showsStage: true)
                .accessibilityHidden(spoken.allSatisfy(\.isWhitespace))
        case .atom(let atom, _):
            AtomView(atom: atom)
                .background {
                    if let atomHighlight {
                        RoundedRectangle(cornerRadius: theme.chipCornerRadius)
                            .fill(highlightColor(atomHighlight))
                    }
                }
        case .lineBreak:
            Color.clear
                .frame(width: 0, height: 0)
                .layoutValue(key: LineBreakLayoutKey.self, value: true)
        }
    }

    private func highlightColor(_ state: AtomHighlightState) -> Color {
        switch state {
        case .subtle, .current(dimmed: true):
            return theme.searchHighlight
        case .current(dimmed: false):
            return theme.searchCurrentHighlight
        }
    }
}

/// Displayed text with smart-link or custom-emoji pieces, as one `Text`
/// (`SegmentedTextView.text`) with its `SmartLinkSpeech`: a leaf's merged
/// text, or one word chunk of an atom paragraph. Its own view, so only such
/// text reads the font environment an emoji box is sized in; every other
/// leaf reads none of it.
struct DisplayedText: View {
    let text: AttributedString
    /// Whether to compose icons and emoji images (`composedText`).
    let composes: Bool
    /// Whether VoiceOver speaks the displayed text (`SmartLinkSpeech`).
    let showsStage: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.legibilityWeight) private var legibilityWeight

    var body: some View {
        let metrics = EmojiDisplay.Metrics(dynamicTypeSize: dynamicTypeSize, legibilityWeight: legibilityWeight)
        SegmentedTextView.text(text, composesSmartLinks: composes, metrics: metrics)
            .modifier(SmartLinkSpeech(text: text, showsStage: showsStage))
    }
}

/// Marks a subview as a forced line break for `WrappingInlineLayout`.
struct LineBreakLayoutKey: LayoutValueKey {
    static let defaultValue = false
}

/// Flow layout: places subviews left-to-right, wrapping to a new line when
/// the proposed width is exhausted (or on an explicit line-break subview).
/// Items on a line share one text baseline — mixed font sizes (small marks,
/// sub/superscript) and atom pills sit on the same line as the prose around
/// them, exactly as `Text` would place them. Centering against the line
/// height instead makes baselines diverge by half the height difference.
struct WrappingInlineLayout: Layout {
    var lineSpacing: CGFloat = 3

    private struct Item {
        let index: Int
        let size: CGSize
        /// Distance from the item's top edge to its first text baseline.
        /// Views without text report their bottom edge, which keeps pills
        /// whose baseline doesn't propagate resting on the line's baseline.
        let ascent: CGFloat
    }

    private struct Row {
        var items: [Item] = []
        var width: CGFloat = 0
        /// Tallest top-to-baseline distance on the row.
        var ascent: CGFloat = 0
        /// Deepest baseline-to-bottom distance on the row.
        var descent: CGFloat = 0
        var height: CGFloat { ascent + descent }
    }

    private func rows(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for (index, subview) in subviews.enumerated() {
            if subview[LineBreakLayoutKey.self] {
                current.items.append(Item(index: index, size: .zero, ascent: 0))
                rows.append(current)
                current = Row()
                continue
            }
            let dimensions = subview.dimensions(in: .unspecified)
            let size = CGSize(width: dimensions.width, height: dimensions.height)
            let ascent = dimensions[VerticalAlignment.firstTextBaseline]
            if !current.items.isEmpty, current.width + size.width > maxWidth {
                rows.append(current)
                current = Row()
            }
            current.items.append(Item(index: index, size: size, ascent: ascent))
            current.width += size.width
            current.ascent = max(current.ascent, ascent)
            current.descent = max(current.descent, size.height - ascent)
        }
        if !current.items.isEmpty {
            rows.append(current)
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = rows(subviews: subviews, maxWidth: maxWidth)
        let height = rows.reduce(CGFloat.zero) { $0 + $1.height }
            + lineSpacing * CGFloat(max(rows.count - 1, 0))
        let contentWidth = rows.map(\.width).max() ?? 0
        let width = maxWidth.isFinite ? min(contentWidth, maxWidth) : contentWidth
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews: subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + row.ascent - item.ascent),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width
            }
            y += row.height + lineSpacing
        }
    }

    /// A `Layout`'s default text baselines are its bottom edge; without real
    /// ones, a baseline-aligned container (list rows, panels) would hang the
    /// whole first line's height below its neighbor's baseline. Report the
    /// first row's and last row's baselines.
    func explicitAlignment(
        of guide: VerticalAlignment,
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGFloat? {
        switch guide {
        case .firstTextBaseline:
            let rows = rows(subviews: subviews, maxWidth: bounds.width)
            guard let first = rows.first else { return nil }
            return bounds.minY + first.ascent
        case .lastTextBaseline:
            let rows = rows(subviews: subviews, maxWidth: bounds.width)
            guard let last = rows.last else { return nil }
            let lastRowTop = rows.dropLast().reduce(CGFloat.zero) { $0 + $1.height + lineSpacing }
            return bounds.minY + lastRowTop + last.ascent
        default:
            return nil
        }
    }
}
