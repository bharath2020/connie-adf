#if canImport(UIKit)
import SwiftUI
import ADFPreparation
@testable import ADFRendering

/// The document view's per-row renderer routing (`DocumentRow`), the one
/// place the probe depends on product API that older commits lack.
/// `Scripts/perf-probe.sh` overlays the probe onto exported refs and, for a
/// ref without `TextKit2Scope.inheritsRenderer` (before TK2 stack PR 2:
/// only `.richText` inherits the renderer, and there is no list width),
/// swaps this file for `Scripts/perf-probe-compat/PerfProbeCompat.legacy.swift.in`.
/// Keep the two in step: same names, same shapes.
enum PerfProbeCompat {
    static let routing = "TextKit2Scope.inheritsRenderer"

    static func rowRenderer(for kind: RenderBlock.Kind, _ renderer: ADFTextRenderer) -> ADFTextRenderer {
        TextKit2Scope.inheritsRenderer(kind) ? renderer : .swiftUI
    }

    /// A lower bound on the width a top-level row's text is laid out at
    /// (`adfTextWidthBound`, which replaced PR 2's `adfListWidth`):
    /// `.pending` until the column width is known, as `DocumentRow` seeds it.
    struct ListWidth: ViewModifier {
        let width: CGFloat

        func body(content: Content) -> some View {
            content.environment(\.adfTextWidthBound, width > 0 ? .atLeast(width) : .pending)
        }
    }
}
#endif
