import SwiftUI
import ADFPreparation

/// One text-bearing leaf drawn by the engine the environment selects: a
/// top-level paragraph or heading (`RichTextBlockView`), a list row's
/// leader (`ListRowView`; its trailing paragraphs go through
/// `RichTextBlockView`), or a code block's code text (`CodeBlockView`,
/// which hands it the prepared code string). Under `.textKit2`, text
/// eligible where it sits (`TextKit2Eligibility`, by `adfTextOwnerKind`:
/// list text only from iOS 26, code by the code rules) goes to
/// `TextKit2Leaf`, which makes the one engine decision (search highlights,
/// inherited styling, the under-1-pt width guard, the rebuild control);
/// code passes the code gate first (`TextKit2CodeGate`: layout direction,
/// the canvas bound and, before iOS 26, interior empty lines above AX3).
/// Anything else draws the caller's SwiftUI `fallback`. These are plain `if`/`else`
/// branches, never `AnyView` or `#available` (§18's per-row erasure
/// lesson). Without UIKit the fallback always runs.
struct TextEngineLeaf<Fallback: View>: View {
    /// The leaf's inline content; empty when it was handed `text`.
    let segments: [InlineSegment]
    /// Prepared attributed text handed over as one string (a code block's
    /// code); `nil` for a leaf made of segments.
    let text: AttributedString?
    let style: TextBlockStyle
    let ownerID: String?
    /// `false` keeps the leaf on SwiftUI whatever the renderer: the
    /// leader of a list row that keeps its text on SwiftUI
    /// (`TextKit2Scope.rowKeepsRenderer`, right-to-left layout:
    /// `listDirectionKeepsRenderer`) or has no room for it
    /// (`TextKit2Scope.listTextFits`).
    let allowsTextKit2: Bool
    /// How much narrower the leaf is laid out than the region its width
    /// bound (`adfTextWidthBound`) covers: a paragraph's indentation
    /// (`RichTextBlockView`). The under-1-pt guard (`TextKit2Scope.textFits`)
    /// subtracts it. Always 0 for a leaf handed `text` (code, which the
    /// guard exempts).
    let widthInset: CGFloat
    let fallback: Fallback

    @Environment(\.adfTextRenderer) private var renderer
    @Environment(\.adfTextOwnerKind) private var ownerKind
    /// Where the leaf sits (`TextKit2ContainerContext`, set by a
    /// container's boundary): an input of the verdict beside the owner
    /// kind, and of the row's counters.
    @Environment(\.adfTextContainerContext) private var context

    init(
        segments: [InlineSegment], style: TextBlockStyle, ownerID: String?, allowsTextKit2: Bool = true,
        widthInset: CGFloat = 0, @ViewBuilder fallback: () -> Fallback
    ) {
        self.segments = segments
        self.text = nil
        self.style = style
        self.ownerID = ownerID
        self.allowsTextKit2 = allowsTextKit2
        self.widthInset = widthInset
        self.fallback = fallback()
    }

    /// A leaf for prepared attributed text held as one string, such as a
    /// code block's code: no segment array is built for it on either arm.
    /// The text is judged for the owner kind in the environment
    /// (`TextKit2Eligibility.describableText(_:owner:)`), so the caller
    /// marks the leaf with `adfTextOwnerKind` (`.code` for code).
    init(text: AttributedString, style: TextBlockStyle, ownerID: String?, allowsTextKit2: Bool = true, @ViewBuilder fallback: () -> Fallback) {
        self.segments = []
        self.text = text
        self.style = style
        self.ownerID = ownerID
        self.allowsTextKit2 = allowsTextKit2
        self.widthInset = 0
        self.fallback = fallback()
    }

    var body: some View {
        #if canImport(UIKit)
        if renderer == .textKit2, allowsTextKit2, let text = describableText {
            if ownerKind == .code {
                TextKit2CodeGate(text: text, style: style, ownerID: ownerID, context: context) { fallback }
            } else {
                TextKit2Leaf(
                    text: text, style: style, ownerID: ownerID, ownerKind: ownerKind, context: context, widthInset: widthInset
                ) { fallback }
            }
        } else {
            fallback
        }
        #else
        fallback
        #endif
    }

    #if canImport(UIKit)
    /// The text TextKit 2 draws for this leaf where it sits, or `nil`.
    /// Read only when the switch is ON (the condition above stops at the
    /// renderer first), so the SwiftUI arm computes nothing here.
    private var describableText: AttributedString? {
        if let text { return TextKit2Eligibility.describableText(text, owner: ownerKind, context: context) }
        return TextKit2Eligibility.describableText(segments, owner: ownerKind, context: context)
    }
    #endif
}
