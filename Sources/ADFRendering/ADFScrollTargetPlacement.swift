import SwiftUI

/// Where a programmatic scroll should land its target block: at the exact
/// top (legacy), or near an edge with a point margin left visible — search
/// navigation uses the edge nearest the match's approach direction.
public enum ADFScrollTargetPlacement: Equatable, Sendable {
    case top
    case nearTop(margin: CGFloat)
    case nearBottom(margin: CGFloat)

    /// The `ScrollViewProxy.scrollTo` anchor expressing this placement in a
    /// viewport of the given height. Margins are clamped to 40% of the
    /// viewport so degenerate configurations cannot center-or-worse a jump.
    public func anchor(viewportHeight: CGFloat) -> UnitPoint {
        switch self {
        case .top:
            return .top
        case .nearTop(let margin):
            return UnitPoint(x: 0.5, y: Self.fraction(margin, viewportHeight))
        case .nearBottom(let margin):
            return UnitPoint(x: 0.5, y: 1 - Self.fraction(margin, viewportHeight))
        }
    }

    private static func fraction(_ margin: CGFloat, _ height: CGFloat) -> CGFloat {
        guard height > 0 else { return 0 }
        return min(max(margin, 0) / height, 0.4)
    }
}
