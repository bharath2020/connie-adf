import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Diagnostics only (`View.adfEngineTint`): the engine that drew a text
/// leaf, and the colour that marks it. A host's legend and renderer badge
/// use the same colours (`color`), and the leaves are filled with them at
/// `fillOpacity`.
///
/// - `.swiftUI`: SwiftUI `Text` drew the leaf (`SegmentedTextView`, or a
///   code block's SwiftUI code text). Under `.textKit2` these are the
///   leaves that stayed on SwiftUI: containers, tables, captions,
///   paragraphs with inline atoms, and every fallback.
/// - `.textKit2`: a TextKit 2 row laid the leaf out and drew it.
/// - `.textKit1Backed`: a TextKit 2 row whose text holds a link, laid out
///   and drawn through its TextKit 1 stack (`TextKit2RowView`,
///   "Of Which TextKit 1-Backed (Links)" in a host's diagnostics).
@_spi(ADFDiagnostics)
public enum ADFEngineTint: String, CaseIterable, Sendable, Identifiable {
    case swiftUI
    case textKit2
    case textKit1Backed

    public var id: String { rawValue }

    /// The opacity a leaf's fill is drawn at: the text stays readable on
    /// it in light and dark appearances.
    public static let fillOpacity = 0.2

    public var displayName: String {
        switch self {
        case .swiftUI: return "SwiftUI"
        case .textKit2: return "TextKit 2"
        case .textKit1Backed: return "TextKit 2 row on TextKit 1 (links)"
        }
    }

    /// The colour's name, for a legend or an accessibility value.
    public var colorName: String {
        switch self {
        case .swiftUI: return "orange"
        case .textKit2: return "green"
        case .textKit1Backed: return "blue"
        }
    }

    /// Full strength, for a legend or a badge (white text on it is legible).
    public var color: Color {
        Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    var rgb: (red: Double, green: Double, blue: Double) {
        switch self {
        case .swiftUI: return (0.80, 0.33, 0.00)
        case .textKit2: return (0.10, 0.52, 0.24)
        case .textKit1Backed: return (0.16, 0.38, 0.85)
        }
    }

    #if canImport(UIKit)
    /// The fill a TextKit 2 row paints behind its text.
    var fillUIColor: UIColor {
        UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: Self.fillOpacity)
    }
    #endif
}

private struct ADFEngineTintKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// `View.adfEngineTint` (diagnostics).
    var adfEngineTint: Bool {
        get { self[ADFEngineTintKey.self] }
        set { self[ADFEngineTintKey.self] = newValue }
    }
}

extension View {
    /// Diagnostics only: while `on`, every text leaf is filled with the
    /// colour of the engine that drew it (`ADFEngineTint`), so text that
    /// stays on SwiftUI under `.textKit2` stands out from TextKit 2 rows.
    ///
    /// Off (the default) costs nothing visible: a SwiftUI text leaf's tint
    /// modifier is its content alone and a TextKit 2 row keeps its clear
    /// background; each reads one environment value, which changes only
    /// when the setting does. Turning it on or off re-evaluates the text
    /// leaves once; SwiftUI leaves are rebuilt in place (no row, model or
    /// layout cache is touched) and TextKit 2 rows only change their
    /// background colour.
    @_spi(ADFDiagnostics)
    public func adfEngineTint(_ on: Bool) -> some View {
        environment(\.adfEngineTint, on)
    }
}

/// The SwiftUI arm's mark (`View.adfEngineTint`): applied to the view that
/// holds a leaf's SwiftUI `Text` (`SegmentedTextView`, a code block's
/// SwiftUI code text). Off, its body is the content alone.
struct EngineTintMark: ViewModifier {
    @Environment(\.adfEngineTint) private var on

    @ViewBuilder
    func body(content: Content) -> some View {
        if on {
            content.background(ADFEngineTint.swiftUI.color.opacity(ADFEngineTint.fillOpacity))
        } else {
            content
        }
    }
}
