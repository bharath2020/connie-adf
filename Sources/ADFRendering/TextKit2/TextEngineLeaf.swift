import SwiftUI
import ADFPreparation

/// One text-bearing leaf drawn by the engine the environment selects: a
/// top-level paragraph or heading (`RichTextBlockView`), or a list row's
/// leader (`ListRowView`; its trailing paragraphs go through
/// `RichTextBlockView`). Under `.textKit2`, text eligible where it sits
/// (`TextKit2Eligibility`, by `adfTextOwnerKind`: list text only from
/// iOS 26) goes to `TextKit2Leaf`, which makes the one
/// engine decision (search highlights, inherited styling, the rebuild
/// control). Anything else draws the caller's SwiftUI `fallback`. This is a
/// plain `if`/`else`, never `AnyView` or `#available` (§18's per-row
/// erasure lesson). Without UIKit the fallback always runs.
struct TextEngineLeaf<Fallback: View>: View {
    let segments: [InlineSegment]
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
        self.style = style
        self.ownerID = ownerID
        self.allowsTextKit2 = allowsTextKit2
        self.fallback = fallback()
    }

    var body: some View {
        #if canImport(UIKit)
        if renderer == .textKit2, allowsTextKit2, let text = TextKit2Eligibility.describableText(segments, owner: ownerKind) {
            TextKit2Leaf(text: text, style: style, ownerID: ownerID, ownerKind: ownerKind) { fallback }
        } else {
            fallback
        }
        #else
        fallback
        #endif
    }
}
