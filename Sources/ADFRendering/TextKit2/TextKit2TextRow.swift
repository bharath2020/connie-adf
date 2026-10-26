#if canImport(UIKit)
import SwiftUI
import ADFPreparation

/// A top-level paragraph or heading drawn by TextKit 2 (skeleton: renders
/// the SwiftUI path until the UIKit row lands).
struct TextKit2TextRow: View {
    let text: AttributedString
    let style: TextBlockStyle

    var body: some View {
        Text(text)
            .multilineTextAlignment(style.alignment == .center ? .center : style.alignment == .end ? .trailing : .leading)
    }
}
#endif
