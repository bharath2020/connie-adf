import Foundation
import SwiftUI
import ADFPreparation

/// What a displayed smart-link run is showing, set by `SmartLinkDisplay` on
/// every character it substituted: the spoken text and the link action of
/// both renderers derive from it (design §6).
struct SmartLinkShown: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// The prepared text, dimmed while the lookup runs.
        case resolving
        /// An icon, a space and the title.
        case resolved(icon: ADFSmartLinkMetadata.Icon, title: String)
    }

    let run: SmartLinkRun
    let kind: Kind
    /// In a word-chunked (atom) paragraph, a chunk after the first that
    /// carries part of the same displayed link: it speaks nothing, so
    /// VoiceOver says the kind and title once, on the first chunk.
    var continuation = false
}

/// The displayed-text attributes `SmartLinkDisplay` adds (rendering-only:
/// prepared text never carries them).
enum SmartLinkShownAttribute: AttributedStringKey, Sendable {
    typealias Value = SmartLinkShown
    static let name = "adf.smartLinkShown"
}

/// Marks the icon character (U+FFFC) of a resolved smart link: SwiftUI
/// draws it as `Text(Image(systemName:))`, the TextKit 2 builder as an
/// `NSTextAttachment` (`TextKit2TextBuilder`).
enum SmartLinkIconAttribute: AttributedStringKey, Sendable {
    typealias Value = ADFSmartLinkMetadata.Icon
    static let name = "adf.smartLinkIcon"
}

/// The one pure function from smart-link stages to displayed text, shared by
/// both renderers so they cannot diverge (design §5), and the spoken text
/// both derive from it (§6).
///
/// It runs on the prepared segments AFTER search painting: a match anywhere
/// inside a smart link highlights the whole displayed title (search keeps
/// indexing the prepared URL text, so its spans stay valid). Called only
/// for owners with smart links whose stages change the display, behind the
/// `smartLinkKeys.isEmpty` gate.
enum SmartLinkDisplay {
    /// The resolving stage's link colour opacity.
    static let resolvingOpacity = 0.5
    /// The icon's placeholder character in displayed text.
    static let iconCharacter: Character = "\u{FFFC}"
    /// Between the icon and the title: never breaks the line between them.
    static let iconSeparator = "\u{00A0}"

    private typealias SUI = AttributeScopes.SwiftUIAttributes
    private typealias SmartLink = AttributeScopes.ADFAttributes.SmartLinkAttribute

    // MARK: Displayed text

    /// `segments` with every run of a key in `stages` substituted: a
    /// resolving run dimmed, a resolved run replaced by icon + title.
    /// Returns the input untouched when nothing changes.
    ///
    /// Word-chunked segments (an atom paragraph) are chunked again where a
    /// title was substituted, so a multi-word title still wraps. The no-break
    /// space after the icon is not a split point there, so the icon, the
    /// space and the title's first word share a chunk and the icon never
    /// wraps away from the title; later chunks of the same link are marked
    /// `continuation` and speak nothing.
    static func apply(
        _ stages: [SmartLinkKey: SmartLinkStage],
        to segments: [InlineSegment],
        theme: ADFTheme
    ) -> [InlineSegment] {
        guard !stages.isEmpty else { return segments }
        let chunked = segments.contains { segment in
            if case .atom = segment { return true }
            return false
        }
        var result: [InlineSegment]?
        var started: Set<SmartLinkRun> = []
        for (index, segment) in segments.enumerated() {
            guard case .text(let text) = segment,
                  let displayed = apply(stages, to: text, theme: theme) else {
                result?.append(segment)
                continue
            }
            if result == nil { result = Array(segments[..<index]) }
            if chunked {
                for chunk in InlineComposer.splitForWrappingLayout([.text(displayed)], breaksAtNoBreakSpace: false) {
                    guard case .text(let text) = chunk else {
                        result?.append(chunk)
                        continue
                    }
                    result?.append(.text(markingContinuations(in: text, started: &started)))
                }
            } else {
                result?.append(.text(displayed))
            }
        }
        return result ?? segments
    }

    /// Marks the pieces of `chunk` whose displayed link already began in an
    /// earlier chunk as continuations (`SmartLinkShown.continuation`).
    private static func markingContinuations(
        in chunk: AttributedString, started: inout Set<SmartLinkRun>
    ) -> AttributedString {
        var marked = chunk
        for (shown, range) in chunk.runs[SmartLinkShownAttribute.self] {
            guard var shown else { continue }
            if started.insert(shown.run).inserted { continue }
            shown.continuation = true
            marked[range][SmartLinkShownAttribute.self] = shown
        }
        return marked
    }

    /// One attributed string with its smart-link runs substituted, or `nil`
    /// when none of its runs changes.
    static func apply(
        _ stages: [SmartLinkKey: SmartLinkStage],
        to text: AttributedString,
        theme: ADFTheme
    ) -> AttributedString? {
        var output = AttributedString()
        var changed = false
        for (value, range) in text.runs[SmartLink.self] {
            guard let value, let stage = stages[value.key] else {
                output.append(text[range])
                continue
            }
            switch stage {
            case .resolving:
                changed = true
                output.append(resolving(text[range], run: value))
            case .resolved(let metadata):
                changed = true
                output.append(resolved(text[range], run: value, metadata: metadata, theme: theme))
            case .plain, .failed:
                output.append(text[range])
            }
        }
        return changed ? output : nil
    }

    private static func resolving(_ slice: AttributedSubstring, run: SmartLinkRun) -> AttributedString {
        var piece = AttributedString(slice)
        let foreground = slice.runs.first?[SUI.ForegroundColorAttribute.self]
        piece[SUI.ForegroundColorAttribute.self] = (foreground ?? Color.accentColor).opacity(resolvingOpacity)
        piece[SmartLinkShownAttribute.self] = SmartLinkShown(run: run, kind: .resolving)
        return piece
    }

    private static func resolved(
        _ slice: AttributedSubstring, run: SmartLinkRun, metadata: ADFSmartLinkMetadata, theme: ADFTheme
    ) -> AttributedString {
        let preparedText = String(slice.characters)
        // The coordinator lands only cleaned, non-empty titles (an empty one
        // fails the lookup); a stage published another way is cleaned here
        // too, and an empty title shows the prepared text after the icon.
        let title = cleanedTitle(metadata.title) ?? preparedText
        var attributes = slice.runs.first?.attributes ?? AttributeContainer()
        // Highlight inheritance: a search match anywhere in the prepared
        // link paints the whole title, the current match's style winning.
        let backgrounds = slice.runs.compactMap { $0[SUI.BackgroundColorAttribute.self] }
        if backgrounds.contains(theme.searchCurrentHighlight) {
            attributes[SUI.BackgroundColorAttribute.self] = theme.searchCurrentHighlight
            if let foreground = theme.searchCurrentForeground {
                attributes[SUI.ForegroundColorAttribute.self] = foreground
            }
        } else if backgrounds.contains(theme.searchHighlight) {
            attributes[SUI.BackgroundColorAttribute.self] = theme.searchHighlight
        }
        attributes[SmartLinkShownAttribute.self] = SmartLinkShown(
            run: run, kind: .resolved(icon: metadata.icon, title: title)
        )
        // The icon and the space after it are not underlined (SwiftUI cannot
        // underline an image in `Text`); the title keeps the link styling.
        var lead = attributes
        lead[SUI.UnderlineStyleAttribute.self] = nil
        var icon = AttributedString(String(iconCharacter), attributes: lead)
        icon[SmartLinkIconAttribute.self] = metadata.icon
        var result = icon
        result.append(AttributedString(iconSeparator, attributes: lead))
        result.append(AttributedString(title, attributes: attributes))
        return result
    }

    // MARK: Titles

    /// A resolved title as displayed and spoken, or `nil` when nothing is
    /// left (the lookup then fails, `SmartLinkFailure.emptyTitle`). Control
    /// characters (line feeds, carriage returns, tabs, U+2028, U+2029) and
    /// whitespace runs become one space; bidirectional formatting
    /// characters (U+202A–U+202E, U+2066–U+2069, U+200E, U+200F, U+061C)
    /// are dropped, so a title can neither break the author's paragraph
    /// into lines nor reorder the text after it; the ends are trimmed.
    nonisolated static func cleanedTitle(_ title: String) -> String? {
        var cleaned = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in title.unicodeScalars {
            if isBidiControl(scalar) { continue }
            if scalar.properties.isWhitespace || scalar.properties.generalCategory == .control {
                pendingSpace = !cleaned.isEmpty
                continue
            }
            if pendingSpace {
                cleaned.append(" ")
                pendingSpace = false
            }
            cleaned.append(scalar)
        }
        return cleaned.isEmpty ? nil : String(cleaned)
    }

    nonisolated private static func isBidiControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x202A...0x202E, 0x2066...0x2069, 0x200E, 0x200F, 0x061C: return true
        default: return false
        }
    }

    // MARK: Spoken text and actions

    /// The spoken text of one displayed smart-link piece whose visible text
    /// (without the icon) is `visibleText`: resolving says it is loading, a
    /// resolved link speaks its kind, then its whole title (whatever part of
    /// it a word chunk shows) — never the symbol's name.
    static func spokenText(_ kind: SmartLinkShown.Kind, visibleText: String) -> String {
        switch kind {
        case .resolving:
            let visible = visibleText
                .filter { $0 != iconCharacter }
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(visible), loading title"
        case .resolved(let icon, let title):
            return "\(spokenName(icon)), \(title)"
        }
    }

    /// Displayed text as VoiceOver reads it: every smart-link piece replaced
    /// by its spoken text (a `continuation` piece by nothing), everything
    /// else as shown. The label of a TextKit 2 row (`TextKit2RowView`), of a
    /// SwiftUI leaf that shows a smart link and of each word chunk in an atom
    /// paragraph (`SmartLinkSpeech`); text without a displayed smart link is
    /// returned as its characters.
    static func accessibilityText(of text: AttributedString) -> String {
        let pieces = text.runs[SmartLinkShownAttribute.self]
        guard pieces.contains(where: { $0.0 != nil }) else { return String(text.characters) }
        var result = ""
        for (shown, range) in pieces {
            let visible = String(text[range].characters)
            if let shown {
                if !shown.continuation { result += spokenText(shown.kind, visibleText: visible) }
            } else {
                result += visible
            }
        }
        return result
    }

    /// The VoiceOver custom action name for a link: the resolved title, or
    /// else the URL's host (design §6).
    static func linkActionName(_ url: URL, title: String? = nil) -> String {
        "Open link \(title ?? url.host ?? url.absoluteString)"
    }

    /// The SF Symbol drawn for a kind.
    static func symbolName(_ icon: ADFSmartLinkMetadata.Icon) -> String {
        switch icon {
        case .page: return "doc.text"
        case .blogPost: return "quote.bubble"
        case .issue: return "checkmark.square"
        case .generic: return "link"
        }
    }

    /// How VoiceOver names a kind.
    static func spokenName(_ icon: ADFSmartLinkMetadata.Icon) -> String {
        switch icon {
        case .page: return "Page"
        case .blogPost: return "Blog post"
        case .issue: return "Issue"
        case .generic: return "Link"
        }
    }

    /// One VoiceOver action per link in displayed text, in text order, named
    /// as a TextKit 2 row names its actions (`TextKit2RowView.rebuildLinks`):
    /// "Open link <title>" for a resolved smart link, else "Open link
    /// <host>". A link that only continues in this word chunk (`continuation`)
    /// is left out: its first chunk carries the action.
    static func linkActions(in text: AttributedString) -> [SmartLinkAction] {
        var actions: [SmartLinkAction] = []
        for (url, range) in text.runs[\.link] {
            guard let url else { continue }
            let shown = text[range].runs.first?[SmartLinkShownAttribute.self]
            if shown?.continuation == true { continue }
            var title: String?
            if case .resolved(_, let resolved)? = shown?.kind { title = resolved }
            actions.append(SmartLinkAction(url: url, name: linkActionName(url, title: title)))
        }
        return actions
    }

    // MARK: SwiftUI

    /// Displayed text holding smart-link pieces as one `Text`: each resolved
    /// piece is `Text(Image(systemName:))` concatenated with its title;
    /// everything else is the attributed text as is. VoiceOver reads it
    /// through `SmartLinkSpeech`, applied by the leaf: a `Text`-level label
    /// here would be ignored once `textSelection(.enabled)` applies (call
    /// #40), and SwiftUI reads the icon as U+FFFC.
    static func composedText(_ attributed: AttributedString) -> Text {
        var composed: Text?
        func add(_ piece: Text) {
            composed = composed.map { $0 + piece } ?? piece
        }
        for (shown, range) in attributed.runs[SmartLinkShownAttribute.self] {
            let slice = attributed[range]
            guard shown != nil else {
                add(Text(AttributedString(slice)))
                continue
            }
            var visible = AttributedString()
            var image: Text?
            for run in slice.runs {
                if let icon = run[SmartLinkIconAttribute.self] {
                    var symbol = Text(Image(systemName: symbolName(icon)))
                    if let font = run[SUI.FontAttribute.self] { symbol = symbol.font(font) }
                    if let foreground = run[SUI.ForegroundColorAttribute.self] {
                        symbol = symbol.foregroundStyle(foreground)
                    } else {
                        symbol = symbol.foregroundStyle(.tint)
                    }
                    image = image.map { $0 + symbol } ?? symbol
                } else {
                    visible.append(AttributedString(slice[run.range]))
                }
            }
            let title = Text(visible)
            add(image.map { $0 + title } ?? title)
        }
        return composed ?? Text(attributed)
    }
}

/// A VoiceOver action that opens one link of displayed text
/// (`SmartLinkDisplay.linkActions`).
struct SmartLinkAction: Hashable, Sendable {
    let url: URL
    let name: String
}

/// VoiceOver for a SwiftUI text leaf, or an atom paragraph's word chunk,
/// that shows smart links (design §6): a view-level label with the spoken
/// text (`SmartLinkDisplay.accessibilityText`) and one "Open link …" action
/// per link (`SmartLinkDisplay.linkActions`), word for word what a TextKit 2
/// row says and offers.
///
/// - The label is view-level because SwiftUI ignores a `Text`-level
///   `accessibilityLabel` once `textSelection(.enabled)` applies to the
///   text, and every paragraph, heading and list leader has it (call #40).
/// - Any explicit label also takes SwiftUI's link rotor off the text, so
///   while the label speaks, the links are reached through the actions, as
///   on a TextKit 2 row.
/// - `showsStage` is false while every link draws as prepared (plain,
///   failed). From iOS 18 / macOS 15 the label is then disabled and the
///   action list empty, so the leaf speaks and exposes its links exactly as
///   a leaf without smart links does. iOS 17 / macOS 14 cannot disable a
///   label: there the label (the characters, at a prepared stage) and the
///   actions are always on.
/// - Only the inputs change with the stage, never the modifier's shape, so
///   a stage change keeps the leaf's view identity. `SegmentedTextView`
///   applies it only in its branch for a merged leaf with smart-link keys
///   in a document with a resolver (a constant for the leaf), and to an
///   atom paragraph's link chunks; any other leaf draws its `Text` exactly
///   as before, so without a resolver iOS 17 / macOS 14 keep the rotor.
struct SmartLinkSpeech: ViewModifier {
    /// The displayed text (`SmartLinkDisplay.apply`).
    let text: AttributedString
    /// Whether a link shows a stage other than its prepared text.
    let showsStage: Bool

    @Environment(\.openURL) private var openURL

    /// False before iOS 18 / macOS 15: no `accessibilityLabel(_:isEnabled:)`.
    static let labelsCanBeDisabled: Bool = {
        if #available(iOS 18.0, macOS 15.0, *) { return true }
        return false
    }()

    func body(content: Content) -> some View {
        let speaks = showsStage || !Self.labelsCanBeDisabled
        let actions = speaks ? SmartLinkDisplay.linkActions(in: text) : []
        // SwiftUI lists one `accessibilityActions` block's actions in reverse
        // (measured, iOS 26.3): fed reversed, VoiceOver offers them in text
        // order, as a TextKit 2 row does (`SmartLinkAccessibilityTests`).
        labelled(content, speaks: speaks)
            .accessibilityActions {
                ForEach(actions.indices.reversed(), id: \.self) { index in
                    Button(actions[index].name) { openURL(actions[index].url) }
                }
            }
    }

    /// The label, disabled while nothing shows a stage. Both overloads
    /// return the same type, so there is no `if #available` in a view
    /// builder (which would erase the leaf to `AnyView`).
    private func labelled(
        _ content: Content, speaks: Bool
    ) -> ModifiedContent<Content, AccessibilityAttachmentModifier> {
        let label = Text(verbatim: speaks ? SmartLinkDisplay.accessibilityText(of: text) : "")
        if #available(iOS 18.0, macOS 15.0, *) {
            return content.accessibilityLabel(label, isEnabled: speaks)
        }
        return content.accessibilityLabel(label)
    }
}
