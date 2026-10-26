#if canImport(UIKit)
import SwiftUI
import UIKit
import ADFPreparation

/// A top-level paragraph or heading drawn by TextKit 2.
///
/// Sizing is `sizeThatFits` only — the memoized layout for the proposed
/// width (natural width when none is proposed), computed synchronously in
/// the same layout pass from the `Hashable` render inputs. The first and
/// last text baselines come from the same layout result, so a
/// baseline-aligned container (list rows, PR 2) aligns with TextKit
/// geometry exactly as it does with `Text`.
struct TextKit2TextRow: View {
    let text: AttributedString
    let style: TextBlockStyle
    var ownerID: String? = nil

    var body: some View {
        // A handle per evaluation (not state): the alignment guides query
        // the live row view's layout cache through it.
        let handle = TextKit2RowHandle()
        TextKit2RowRepresentable(text: text, style: style, ownerID: ownerID, handle: handle)
            .alignmentGuide(.firstTextBaseline) { dimensions in
                let width = dimensions.width
                return MainActor.assumeIsolated { handle.firstBaseline(width: width) } ?? dimensions.height
            }
            .alignmentGuide(.lastTextBaseline) { dimensions in
                let width = dimensions.width
                return MainActor.assumeIsolated { handle.lastBaseline(width: width) } ?? dimensions.height
            }
    }
}

/// Weak link from a `TextKit2TextRow` value to the row view its
/// representable created, for the alignment-guide closures.
@MainActor
final class TextKit2RowHandle {
    weak var view: TextKit2RowView?

    func firstBaseline(width: CGFloat) -> CGFloat? {
        view?.layoutResult(forProposedWidth: width).firstBaseline
    }

    func lastBaseline(width: CGFloat) -> CGFloat? {
        view?.layoutResult(forProposedWidth: width).lastBaseline
    }
}

struct TextKit2RowRepresentable: UIViewRepresentable {
    let text: AttributedString
    let style: TextBlockStyle
    let ownerID: String?
    let handle: TextKit2RowHandle

    func makeUIView(context: Context) -> TextKit2RowView {
        let view = TextKit2RowView()
        update(view, context: context)
        return view
    }

    func updateUIView(_ uiView: TextKit2RowView, context: Context) {
        update(uiView, context: context)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TextKit2RowView, context: Context) -> CGSize? {
        // Inputs can arrive here before `updateUIView` in the same pass.
        update(uiView, context: context)
        return uiView.measuredSize(forProposedWidth: proposal.width)
    }

    private func update(_ view: TextKit2RowView, context: Context) {
        handle.view = view
        view.apply(Self.inputs(text: text, style: style, environment: context.environment), ownerID: ownerID)
        let action = context.environment.openURL
        view.openURL = { url in action(url) }
    }

    static func inputs(text: AttributedString, style: TextBlockStyle, environment: EnvironmentValues) -> TextKit2RenderInputs {
        TextKit2RenderInputs(
            text: text,
            alignment: style.alignment,
            isHeading: style.isHeading,
            sizeCategory: environment.dynamicTypeSize.uiContentSizeCategory,
            layoutDirection: environment.layoutDirection,
            displayScale: environment.displayScale,
            legibilityWeight: environment.legibilityWeight,
            colorScheme: environment.colorScheme
        )
    }
}
#endif
