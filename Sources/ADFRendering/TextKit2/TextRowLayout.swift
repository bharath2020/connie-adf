import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// One row's TextKit 2 stack. Measurement is FULL layout (`ensureLayout` to
/// the document end) so a given (text, width) always yields the same height —
/// the CollapsedRowHeight exact-replay contract. Viewport-estimated layout is
/// forbidden here: an estimate-then-settle height double-commits row geometry
/// and feeds the §16 livelock loop.
@MainActor
public final class TextRowLayout {
    public let contentStorage = NSTextContentStorage()
    public let layoutManager = NSTextLayoutManager()
    public let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    private var lastWidth: CGFloat?
    private var lastSize: CGSize?

    public init() {
        container.lineFragmentPadding = 0
        contentStorage.addTextLayoutManager(layoutManager)
        layoutManager.textContainer = container
    }

    public func setAttributedString(_ attributed: NSAttributedString) {
        contentStorage.attributedString = attributed
        lastWidth = nil
        lastSize = nil
    }

    public func measure(width: CGFloat, displayScale: CGFloat) -> CGSize {
        if lastWidth == width, let lastSize { return lastSize }
        container.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        let bounds = layoutManager.usageBoundsForTextContainer
        let height = (bounds.maxY * displayScale).rounded(.up) / displayScale
        // `.greatestFiniteMagnitude` is, by definition, finite — `isFinite`
        // alone can't detect the "unbounded" sentinel callers pass for the
        // code-block h-scroll case. Treat that sentinel (and true infinity)
        // as unbounded so the natural width comes from measured bounds.
        let isUnbounded = !width.isFinite || width == .greatestFiniteMagnitude
        let naturalWidth = isUnbounded ? (bounds.maxX * displayScale).rounded(.up) / displayScale : width
        let size = CGSize(width: naturalWidth, height: height)
        lastWidth = width
        lastSize = size
        return size
    }
}
