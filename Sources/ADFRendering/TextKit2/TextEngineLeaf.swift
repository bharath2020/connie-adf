import SwiftUI
import ADFPreparation

/// One text-bearing leaf drawn by the engine the environment selects: a
/// top-level paragraph or heading (`RichTextBlockView`), or a list row's
/// leader (`ListRowView`; its trailing paragraphs go through
/// `RichTextBlockView`). Under `.textKit2`, eligible text
/// (`TextKit2Eligibility`) goes to `TextKit2Leaf`, which makes the one
/// engine decision (search highlights, inherited styling, the rebuild
/// control). Anything else draws the caller's SwiftUI `fallback`. This is a
/// plain `if`/`else`, never `AnyView` or `#available` (§18's per-row
/// erasure lesson). Without UIKit the fallback always runs.
struct TextEngineLeaf<Fallback: View>: View {
    let segments: [InlineSegment]
    let style: TextBlockStyle
    let ownerID: String?
    let fallback: Fallback

    @Environment(\.adfTextRenderer) private var renderer

    init(segments: [InlineSegment], style: TextBlockStyle, ownerID: String?, @ViewBuilder fallback: () -> Fallback) {
        self.segments = segments
        self.style = style
        self.ownerID = ownerID
        self.fallback = fallback()
    }

    var body: some View {
        #if canImport(UIKit)
        if renderer == .textKit2, let text = TextKit2Eligibility.describableText(segments) {
            TextKit2Leaf(text: text, style: style, ownerID: ownerID) { fallback }
        } else {
            fallback
        }
        #else
        fallback
        #endif
    }
}
