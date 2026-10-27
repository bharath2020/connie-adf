#if canImport(UIKit)
import SwiftUI
import UIKit
import ADFPreparation

/// The TextKit 2 arm of `RichTextBlockView` for eligible text: the TextKit 2
/// row, unless the environment carries text styling the row does not
/// reproduce — then `fallback` (the SwiftUI `Text` path). Only constructed
/// when the switch is ON, so the SwiftUI arm reads none of these values.
/// Under `ADFTextRenderer.rebuildControl` (diagnostics) the row's place
/// holds `fallback` instead, counted.
struct TextKit2Leaf<Fallback: View>: View {
    let text: AttributedString
    let style: TextBlockStyle
    let ownerID: String?
    let fallback: Fallback

    @Environment(\.lineSpacing) private var lineSpacing
    @Environment(\.textCase) private var textCase
    @Environment(\.lineLimit) private var lineLimit
    @Environment(\.minimumScaleFactor) private var minimumScaleFactor
    @Environment(\.redactionReasons) private var redactionReasons

    init(text: AttributedString, style: TextBlockStyle, ownerID: String?, @ViewBuilder fallback: () -> Fallback) {
        self.text = text
        self.style = style
        self.ownerID = ownerID
        self.fallback = fallback()
    }

    var body: some View {
        if Self.supportsEnvironment(
            lineSpacing: lineSpacing, textCase: textCase, lineLimit: lineLimit,
            minimumScaleFactor: minimumScaleFactor, redactionReasons: redactionReasons
        ) {
            if TextKit2Diagnostics.shared.rebuildControl {
                fallback
                    .onAppear { TextKit2Diagnostics.shared.rebuildControlRow(appeared: true) }
                    .onDisappear { TextKit2Diagnostics.shared.rebuildControlRow(appeared: false) }
            } else {
                TextKit2TextRow(text: text, style: style, ownerID: ownerID)
            }
        } else {
            fallback
        }
    }

    /// Whether inherited `Text` styling is absent (all defaults): line
    /// spacing, text case, a line limit (with its truncation and
    /// tightening), shrink-to-fit and redaction all change how `Text`
    /// lays out or draws, and the row reproduces none of them. Colour comes
    /// through `adfTextForeground`. Tint, which `Text` uses for links, is
    /// not readable from UIKit: rows draw links in the accent colour.
    static func supportsEnvironment(
        lineSpacing: CGFloat, textCase: Text.Case?, lineLimit: Int?,
        minimumScaleFactor: CGFloat, redactionReasons: RedactionReasons
    ) -> Bool {
        lineSpacing == 0 && textCase == nil && lineLimit == nil
            && minimumScaleFactor == 1 && redactionReasons.isEmpty
    }
}

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
        // A handle per evaluation, not view state (the TK2 sources hold
        // none, `TextKit2RowViewTests`): the alignment guides query the
        // live row view's layout cache through it.
        let handle = TextKit2RowHandle()
        TextKit2RowRepresentable(text: text, style: style, ownerID: ownerID, handle: handle)
            .alignmentGuide(.firstTextBaseline) { dimensions in
                let size = CGSize(width: dimensions.width, height: dimensions.height)
                return MainActor.assumeIsolated { handle.firstBaseline(placedAt: size) } ?? dimensions.height
            }
            .alignmentGuide(.lastTextBaseline) { dimensions in
                let size = CGSize(width: dimensions.width, height: dimensions.height)
                return MainActor.assumeIsolated { handle.lastBaseline(placedAt: size) } ?? dimensions.height
            }
    }
}

/// Weak link from a `TextKit2TextRow` value to the row view its
/// representable created, for the alignment-guide closures.
@MainActor
final class TextKit2RowHandle {
    weak var view: TextKit2RowView?

    /// Baselines of the layout the row was placed from: a guide is read at
    /// the placed (hugging) size, which a proposal-keyed lookup would miss
    /// and lay out again.
    func firstBaseline(placedAt size: CGSize) -> CGFloat? {
        view?.placedResult(for: size).firstBaseline
    }

    func lastBaseline(placedAt size: CGSize) -> CGFloat? {
        view?.placedResult(for: size).lastBaseline
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
            colorScheme: environment.colorScheme,
            inheritedForeground: environment.adfTextForeground
        )
    }
}
#endif
