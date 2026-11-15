#if canImport(UIKit)
import SwiftUI
import UIKit
import Testing
import ADFModel
import ADFPreparation
@testable import ADFRendering

/// The bullet marker draws `ListRowView.bulletScale` (1.3×) the body
/// glyph's size at every nesting depth, under both text engines, without
/// moving: its centre keeps the unscaled glyph's offset from the first line
/// of text and its column, and the row keeps its height.
///
/// The reference is the row as it laid out before the marker grew: the
/// unscaled glyph in the trailing-aligned marker column, first-baseline
/// aligned with the leader, inside the same depth padding.
@Suite("List bullet marker size", .serialized)
@MainActor
struct ListBulletSizeTests {
    typealias Parity = TextKit2ListParityTests
    static var theme: ADFTheme { TK2Parity.theme }

    /// Depths 0, 1 and 2: one row per glyph (• ◦ ▪).
    static let json = Parity.list("bulletList", [
        Parity.item(Parity.paragraph([Parity.t("Depth zero")]), Parity.list("bulletList", [
            Parity.item(Parity.paragraph([Parity.t("Depth one")]), Parity.list("bulletList", [
                Parity.item(Parity.paragraph([Parity.t("Depth two")])),
            ])),
        ])),
    ])

    static func rows() async throws -> [PreparedListRow] {
        let document = "{\"type\":\"doc\",\"version\":1,\"content\":[\(json)]}"
        for block in try await Parity.blocks(Data(document.utf8)) {
            if case .listRows(let rows) = block.kind { return rows.filter { if case .bullet = $0.marker { return true } else { return false } } }
        }
        return []
    }

    /// The pre-change row: unscaled glyph, same column, gap and alignment.
    static func reference(_ row: PreparedListRow, leader: String, env: TK2Parity.Environment) -> some View {
        let markerWidth = Parity.markerWidth(env.size)
        guard case .bullet(let depth) = row.marker else { preconditionFailure() }
        return HStack(alignment: .firstTextBaseline, spacing: theme.spacing) {
            Text(ListRowView.bulletGlyph(depth: depth))
                .frame(width: markerWidth, alignment: .trailing)
            Text(leader)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(row.depth) * (markerWidth + theme.spacing))
        .environment(\.adfTheme, theme)
        .dynamicTypeSize(env.size)
    }

    /// Marker ink's pixel bounds and the first text ink row of a render.
    struct Measured {
        var marker: (rows: ClosedRange<Int>, columns: ClosedRange<Int>)
        var textTop: Int

        var height: Int { marker.rows.count }
        var width: Int { marker.columns.count }
        /// Twice the centre, in pixels, so it stays an integer.
        var centreY2: Int { marker.rows.lowerBound + marker.rows.upperBound }
        var centreX2: Int { marker.columns.lowerBound + marker.columns.upperBound }
    }

    static func measure(_ bitmap: TK2Parity.Bitmap, row: PreparedListRow, size: DynamicTypeSize) throws -> Measured {
        let inset = CGFloat(row.depth) * (Parity.markerWidth(size) + theme.spacing)
        let split = Int(((inset + Parity.markerWidth(size) + theme.spacing / 2) * bitmap.scale).rounded())
        let background = Parity.background(dark: false)
        let marker = Parity.ink(bitmap, columns: 0..<split, background: background)
        let text = Parity.ink(bitmap, columns: split..<bitmap.width, background: background)
        let first = try #require(marker.firstRow), last = try #require(marker.lastRow)
        let columns = try #require(marker.extent(first...last))
        return Measured(marker: (first...last, columns), textTop: try #require(text.firstRow))
    }

    @Test("The bullet scale is 1.3")
    func scale() {
        #expect(ListRowView.bulletScale == 1.3)
    }

    @Test("Every depth's bullet draws 1.3× larger, centred where it was, on both engines")
    func bulletSize() async throws {
        let rows = try await Self.rows()
        #expect(rows.count == 3)
        let leaders = ["Depth zero", "Depth one", "Depth two"]
        for (row, leader) in zip(rows, leaders) {
            for size in [DynamicTypeSize.large, .accessibility3] {
                let env = TK2Parity.Environment(size: size)
                let width = Parity.listWidth(documentWidth: 375)
                let referenceHeight = Parity.measure(Self.reference(row, leader: leader, env: env), width: width).size.height
                let reference = try Self.measure(Parity.render(Self.reference(row, leader: leader, env: env), width: width, height: referenceHeight + 24, dark: false).bitmap, row: row, size: size)
                for arm in [ADFTextRenderer.swiftUI, .textKit2] {
                    let label = "depth \(row.depth) \(size) \(arm)"
                    let rowHeight = Parity.measure(Parity.hostedRow(row, arm: arm, env: env, listWidth: width), width: width).size.height
                    #expect(abs(rowHeight - referenceHeight) <= Parity.tolerance, "\(label): row height \(rowHeight), unscaled \(referenceHeight)")
                    let rendered = try Parity.render(Parity.hostedRow(row, arm: arm, env: env, listWidth: width), width: width, height: rowHeight + 24, dark: false)
                    let drawn = try Self.measure(rendered.bitmap, row: row, size: size)
                    // Ink bounds include an antialiased fringe pixel on each
                    // side, so the ratio is measured on the inner size.
                    let heightRatio = Double(drawn.height - 2) / Double(reference.height - 2)
                    let widthRatio = Double(drawn.width - 2) / Double(reference.width - 2)
                    #expect((1.15...1.45).contains(heightRatio), "\(label): height \(drawn.height) px, unscaled \(reference.height) px")
                    #expect((1.15...1.45).contains(widthRatio), "\(label): width \(drawn.width) px, unscaled \(reference.width) px")
                    // Centre within a pixel of the unscaled glyph's, relative
                    // to the first line of text (vertical) and the row's
                    // leading edge (horizontal).
                    let offsetChange = abs((drawn.centreY2 - 2 * drawn.textTop) - (reference.centreY2 - 2 * reference.textTop))
                    #expect(offsetChange <= 2, "\(label): marker centre moved \(Double(offsetChange) / 2) px from the first text line")
                    #expect(abs(drawn.centreX2 - reference.centreX2) <= 2, "\(label): marker centre moved \(Double(abs(drawn.centreX2 - reference.centreX2)) / 2) px across")
                    print("bullet size \(label): \(reference.width)×\(reference.height) px -> \(drawn.width)×\(drawn.height) px, centre Δy \(Double(offsetChange) / 2) px")
                }
            }
        }
    }
}
#endif
