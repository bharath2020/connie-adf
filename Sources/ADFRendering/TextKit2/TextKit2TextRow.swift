#if canImport(UIKit)
import SwiftUI
import UIKit
import ADFPreparation

/// The TextKit 2 arm of a text leaf (`TextEngineLeaf`) for eligible text:
/// the TextKit 2 row, unless the environment carries text styling the row
/// does not reproduce, or the active search has highlights for this owner
/// (the row paints no search highlight or arrival flash) — then `fallback`
/// (the SwiftUI `Text` path). Only constructed when the switch is ON, so
/// the SwiftUI arm reads none of these values.
/// Under `View.adfRebuildControl` (diagnostics) the row's place holds
/// `fallback` instead, counted. `ownerKind` is whose text this is
/// (`TextKit2OwnerKind`): the row counts itself by it and takes its layout
/// policy from it, so code (`.code`) is laid out once and never wraps. Code
/// reaches this view only through `TextKit2CodeGate`.
struct TextKit2Leaf<Fallback: View>: View {
    let text: AttributedString
    let style: TextBlockStyle
    let ownerID: String?
    let ownerKind: TextKit2OwnerKind
    let fallback: Fallback

    @Environment(\.lineSpacing) private var lineSpacing
    @Environment(\.textCase) private var textCase
    @Environment(\.lineLimit) private var lineLimit
    @Environment(\.minimumScaleFactor) private var minimumScaleFactor
    @Environment(\.redactionReasons) private var redactionReasons
    @Environment(\.adfRebuildControl) private var rebuildControl
    @Environment(\.adfDocumentSearch) private var search

    init(
        text: AttributedString, style: TextBlockStyle, ownerID: String?, ownerKind: TextKit2OwnerKind = .root,
        @ViewBuilder fallback: () -> Fallback
    ) {
        self.text = text
        self.style = style
        self.ownerID = ownerID
        self.ownerKind = ownerKind
        self.fallback = fallback()
    }

    var body: some View {
        if !hasSearchHighlights, Self.supportsEnvironment(
            lineSpacing: lineSpacing, textCase: textCase, lineLimit: lineLimit,
            minimumScaleFactor: minimumScaleFactor, redactionReasons: redactionReasons
        ) {
            if rebuildControl {
                fallback
                    .onAppear { TextKit2Diagnostics.shared.rebuildControlRow(appeared: true) }
                    .onDisappear { TextKit2Diagnostics.shared.rebuildControlRow(appeared: false) }
            } else {
                TextKit2TextRow(text: text, style: style, ownerID: ownerID, ownerKind: ownerKind)
            }
        } else {
            fallback
        }
    }

    /// The same gate as `SegmentedTextView.displayedSegments`: with no
    /// active session it reads only `isActive`.
    private var hasSearchHighlights: Bool {
        guard let ownerID, let search, search.isActive else { return false }
        let highlights = search.ownerHighlights(for: ownerID)
        return !highlights.spans.isEmpty || !highlights.currentSpans.isEmpty
    }

    /// Whether inherited `Text` styling is absent (all defaults): line
    /// spacing, text case, a line limit (with its truncation and
    /// tightening), shrink-to-fit and redaction all change how `Text`
    /// lays out or draws, and the row reproduces none of them. Tint, which
    /// `Text` uses for links, is not readable from UIKit: rows draw links in
    /// the accent colour.
    static func supportsEnvironment(
        lineSpacing: CGFloat, textCase: Text.Case?, lineLimit: Int?,
        minimumScaleFactor: CGFloat, redactionReasons: RedactionReasons
    ) -> Bool {
        lineSpacing == 0 && textCase == nil && lineLimit == nil
            && minimumScaleFactor == 1 && redactionReasons.isEmpty
    }
}

/// A paragraph, heading, list text or code text drawn by TextKit 2.
///
/// Sizing is `sizeThatFits` only — the memoized layout for the proposed
/// width (natural width when none is proposed, and for code at every
/// width: `TextKit2LayoutPolicy.natural`), computed synchronously in
/// the same layout pass from the `Hashable` render inputs. The first and
/// last text baselines come from the same layout result, so a
/// baseline-aligned container (list rows, PR 2) aligns with TextKit
/// geometry exactly as it does with `Text`.
struct TextKit2TextRow: View {
    let text: AttributedString
    let style: TextBlockStyle
    var ownerID: String? = nil
    var ownerKind: TextKit2OwnerKind = .root

    /// While the document identifies its renderer, the row reports itself
    /// (`View.rendererIdentityFeed`; the row view marks itself). `nil`, the
    /// default, adds nothing.
    @Environment(\.adfRendererIdentity) private var rendererIdentity

    var body: some View {
        // A handle per evaluation, not view state (the TK2 sources hold
        // none, `TextKit2RowViewTests`): the alignment guides query the
        // live row view's layout cache through it.
        let handle = TextKit2RowHandle()
        let row = TextKit2RowRepresentable(text: text, style: style, ownerID: ownerID, ownerKind: ownerKind, handle: handle)
            .alignmentGuide(.firstTextBaseline) { dimensions in
                let size = CGSize(width: dimensions.width, height: dimensions.height)
                return MainActor.assumeIsolated { handle.firstBaseline(placedAt: size) } ?? dimensions.height
            }
            .alignmentGuide(.lastTextBaseline) { dimensions in
                let size = CGSize(width: dimensions.width, height: dimensions.height)
                return MainActor.assumeIsolated { handle.lastBaseline(placedAt: size) } ?? dimensions.height
            }
        if let rendererIdentity, let ownerID {
            // The engine is read from the live row view when the report is
            // published, so a row that turns TextKit 1-backed reports it.
            row.rendererIdentityFeed(rendererIdentity, key: "t:" + ownerID, ownerID: ownerID) { handle.engine }
        } else {
            row
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

    /// The engine the live row view reports (`.textKit2` before it exists).
    var engine: ADFTextEngine {
        view?.engine ?? .textKit2
    }
}

struct TextKit2RowRepresentable: UIViewRepresentable {
    let text: AttributedString
    let style: TextBlockStyle
    let ownerID: String?
    var ownerKind: TextKit2OwnerKind = .root
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
        view.ownerKind = ownerKind
        view.apply(
            Self.inputs(text: text, style: style, environment: context.environment, layoutPolicy: ownerKind.layoutPolicy),
            colorScheme: context.environment.colorScheme,
            ownerID: ownerID
        )
        // After `apply`: the mark depends on whether the text made the row
        // TextKit 1-backed.
        view.rendererIdentity = context.environment.adfRendererIdentity
        let action = context.environment.openURL
        view.openURL = { url in action(url) }
    }

    /// The row's layout inputs; the colour scheme is applied apart, as a
    /// paint input (`TextKit2RowView.apply(_:colorScheme:ownerID:)`).
    /// `layoutPolicy` is the owner kind's (`TextKit2OwnerKind.layoutPolicy`:
    /// `.natural` for code, else `.wrapping`).
    static func inputs(
        text: AttributedString, style: TextBlockStyle, environment: EnvironmentValues,
        layoutPolicy: TextKit2LayoutPolicy = .wrapping
    ) -> TextKit2RenderInputs {
        TextKit2RenderInputs(
            text: text,
            alignment: style.alignment,
            isHeading: style.isHeading,
            sizeCategory: environment.dynamicTypeSize.uiContentSizeCategory,
            layoutDirection: environment.layoutDirection,
            displayScale: environment.displayScale,
            legibilityWeight: environment.legibilityWeight,
            layoutPolicy: layoutPolicy
        )
    }
}
#endif
