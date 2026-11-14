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
/// inherited styling, the rebuild control); code passes the code gate first
/// (`TextKit2CodeGate`: layout direction and the canvas bound). Anything
/// else draws the caller's SwiftUI `fallback`. These are plain `if`/`else`
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
    let fallback: Fallback

    @Environment(\.adfTextRenderer) private var renderer
    @Environment(\.adfTextOwnerKind) private var ownerKind

    init(segments: [InlineSegment], style: TextBlockStyle, ownerID: String?, allowsTextKit2: Bool = true, @ViewBuilder fallback: () -> Fallback) {
        self.segments = segments
        self.text = nil
        self.style = style
        self.ownerID = ownerID
        self.allowsTextKit2 = allowsTextKit2
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
        self.fallback = fallback()
    }

    var body: some View {
        #if canImport(UIKit)
        if renderer == .textKit2, allowsTextKit2, let text = describableText {
            if ownerKind == .code {
                TextKit2CodeGate(text: text, style: style, ownerID: ownerID) { fallback }
            } else {
                TextKit2Leaf(text: text, style: style, ownerID: ownerID, ownerKind: ownerKind) { fallback }
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
        if let text { return TextKit2Eligibility.describableText(text, owner: ownerKind) }
        return TextKit2Eligibility.describableText(segments, owner: ownerKind)
    }
    #endif
}
