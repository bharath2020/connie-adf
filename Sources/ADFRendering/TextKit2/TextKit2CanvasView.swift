#if canImport(UIKit)
import UIKit

/// The row's drawing surface: covers the row's bounds plus the glyph ink
/// overhang. Not interactive and not an accessibility element — the row
/// owns both.
final class TextKit2CanvasView: UIView {
    weak var row: TextKit2RowView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        row?.drawText(in: context, canvasOrigin: frame.origin)
    }
}
#endif
