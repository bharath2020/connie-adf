#if canImport(UIKit)
import SwiftUI
import UIKit
import ADFPreparation

/// SwiftUI host for `TextKit2RowView`: a top-level paragraph or heading
/// drawn by TextKit 2.
///
/// Sizing is `sizeThatFits` only — the measured size for the proposed width
/// (natural width when none is proposed), computed synchronously in the
/// same layout pass from (text, width, size category, scale). The view is
/// re-applied only when the `Hashable` inputs change.
struct TextKit2TextRow: UIViewRepresentable {
    let text: AttributedString
    let style: TextBlockStyle

    func makeUIView(context: Context) -> TextKit2RowView {
        let view = TextKit2RowView()
        view.apply(inputs(from: context.environment))
        view.openURL = openURLAction(context.environment)
        return view
    }

    func updateUIView(_ uiView: TextKit2RowView, context: Context) {
        uiView.apply(inputs(from: context.environment))
        uiView.openURL = openURLAction(context.environment)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TextKit2RowView, context: Context) -> CGSize? {
        // Inputs can arrive here before `updateUIView` in the same pass.
        uiView.apply(inputs(from: context.environment))
        return uiView.measuredSize(forProposedWidth: proposal.width)
    }

    private func inputs(from environment: EnvironmentValues) -> TextKit2TextInputs {
        TextKit2TextInputs(
            text: text,
            alignment: style.alignment,
            isHeading: style.isHeading,
            sizeCategory: environment.dynamicTypeSize.uiContentSizeCategory,
            layoutDirection: environment.layoutDirection,
            displayScale: environment.displayScale
        )
    }

    private func openURLAction(_ environment: EnvironmentValues) -> (URL) -> Void {
        let action = environment.openURL
        return { url in action(url) }
    }
}
#endif
