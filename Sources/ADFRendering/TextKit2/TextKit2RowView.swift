#if os(iOS)
import SwiftUI
import UIKit
import ADFPreparation

/// One text row rendered by TextKit 2. Sizing contract (§16): synchronous,
/// deterministic, memoized per width; the view NEVER self-invalidates —
/// SwiftUI's proposal is the only sizing authority.
struct TextKit2RowView: UIViewRepresentable {
    let segments: [InlineSegment]
    var blockAlignment: TextAlignment? = nil

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.displayScale) private var displayScale

    func makeUIView(context: Context) -> TextKit2RowUIView { TextKit2RowUIView() }

    func updateUIView(_ view: TextKit2RowUIView, context: Context) {
        view.apply(TextKit2RowUIView.Inputs(
            segments: segments,
            categoryRawValue: UIContentSizeCategory(dynamicTypeSize).rawValue,
            alignment: nsAlignment,
            rightToLeft: layoutDirection == .rightToLeft,
            displayScale: displayScale))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TextKit2RowUIView, context: Context) -> CGSize? {
        uiView.measuredSize(forWidth: proposal.width)
    }

    private var nsAlignment: NSTextAlignment {
        switch blockAlignment {
        case .center: .center
        case .trailing: layoutDirection == .rightToLeft ? .left : .right
        default: .natural
        }
    }

    /// First-line ascent for enclosing `.firstTextBaseline` stacks (list
    /// markers, panel icons). Pure function of the first run's resolved font
    /// — never measured layout, so no geometry feedback (§16).
    @MainActor
    static func firstBaseline(of segments: [InlineSegment], categoryRawValue: String) -> CGFloat {
        for segment in segments {
            if case .text(let text) = segment {
                // Bracket-subscript accessor (matches `TextRowContent.make`);
                // the dynamic-member form is `run.fontSpec`, never `run.adf…`.
                let spec = text.runs.first?[FontSpecAttribute.self] ?? .body
                return FontSpecResolver.shared.font(for: spec, categoryRawValue: categoryRawValue).ascender
            }
        }
        return 0
    }
}

final class TextKit2RowUIView: UIView {
    struct Inputs: Equatable {
        let segments: [InlineSegment]
        let categoryRawValue: String
        let alignment: NSTextAlignment
        let rightToLeft: Bool
        let displayScale: CGFloat
    }

    private let layout = TextRowLayout()
    private var inputs: Inputs?
    private(set) var content: TextRowContent?
    private var drawnWidth: CGFloat = -1

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    func apply(_ new: Inputs) {
        guard new != inputs else { return }
        inputs = new
        let scale = UIFontMetrics(forTextStyle: .body).scaledValue(
            for: 1,
            compatibleWith: UITraitCollection(preferredContentSizeCategory:
                UIContentSizeCategory(rawValue: new.categoryRawValue)))
        // ^ sole legal UIFontMetrics use: mirroring the @ScaledMetric curve
        //   for baked baseline offsets, matching SegmentedTextView.typeScale.
        let made = TextRowContent.make(
            segments: new.segments,
            categoryRawValue: new.categoryRawValue,
            alignment: new.alignment,
            baselineScale: scale,
            rightToLeft: new.rightToLeft)
        content = made
        layout.setAttributedString(made.attributed)
        setNeedsDisplay()
    }

    func measuredSize(forWidth width: CGFloat?) -> CGSize {
        // A nil proposal — SwiftUI's "unspecified/ideal" query, and the width
        // the horizontal code-block ScrollView proposes on its scroll axis —
        // means "how wide do you want to be?". Answer with the natural
        // single-line width via TextRowLayout's unbounded sentinel (its
        // documented code-block h-scroll contract), exactly as `Text` would.
        // NOT bounds.width: that is 0 on the first sizing pass, which would
        // collapse the row to nothing before it ever lays out.
        let w = width ?? .greatestFiniteMagnitude
        guard w > 0, let inputs else { return .zero }
        return layout.measure(width: w, displayScale: inputs.displayScale)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.width != drawnWidth else { return }
        drawnWidth = bounds.width
        _ = layout.measure(width: bounds.width, displayScale: inputs?.displayScale ?? 3)
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        layout.layoutManager.enumerateTextLayoutFragments(from: nil, options: []) { fragment in
            fragment.draw(at: fragment.layoutFragmentFrame.origin, in: ctx)
            return true
        }
    }
}
#endif
