#if canImport(UIKit)
import SwiftUI
import UIKit
import Testing
import ADFModel
import ADFPreparation
@testable import ADFRendering

/// Bullet markers at every nesting depth, under both text engines, measured
/// from rendered pixels against the item text beside them:
///
/// - Size: each mark (• dot, ◦ ring, ▪ square) is
///   `ListRowView.bulletDiameterToCapHeight` (0.48) of the text's capital
///   height across, the proportion the captain asked for, and all three
///   share that footprint.
/// - Position: the mark is centred where the body font's own • is centred
///   on the first line of text, in the marker column, and the row keeps the
///   height it had with the glyph.
/// - Look: flat marks in the text colour (never the emoji ▪), the ring
///   hollow, the dot and square solid at their centre, the square to its
///   corners.
@Suite("List bullet marker size", .serialized)
@MainActor
struct ListBulletSizeTests {
    typealias Parity = TextKit2ListParityTests
    static var theme: ADFTheme { TK2Parity.theme }

    /// Depths 0, 1 and 2: one row per mark (• ◦ ▪). Flat-topped and
    /// flat-bottomed capitals only, so the first line's ink is exactly the
    /// capital height (round letters overshoot it).
    static let leaders = ["TIER I", "TIER II", "TIER III"]
    static let json = Parity.list("bulletList", [
        Parity.item(Parity.paragraph([Parity.t(leaders[0])]), Parity.list("bulletList", [
            Parity.item(Parity.paragraph([Parity.t(leaders[1])]), Parity.list("bulletList", [
                Parity.item(Parity.paragraph([Parity.t(leaders[2])])),
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

    /// The row as it laid out with glyph markers: `glyph` in the
    /// trailing-aligned marker column, first-baseline aligned with the
    /// leader, inside the same depth padding.
    static func reference(_ row: PreparedListRow, glyph: String, leader: String, env: TK2Parity.Environment) -> some View {
        let markerWidth = Parity.markerWidth(env.size)
        return HStack(alignment: .firstTextBaseline, spacing: theme.spacing) {
            Text(glyph)
                .frame(width: markerWidth, alignment: .trailing)
            Text(leader)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(row.depth) * (markerWidth + theme.spacing))
        .environment(\.adfTheme, theme)
        .environment(\.legibilityWeight, env.legibility)
        .dynamicTypeSize(env.size)
    }

    /// A render's marker ink bounds and its first text line's ink rows.
    struct Measured {
        var marker: (rows: ClosedRange<Int>, columns: ClosedRange<Int>)
        var capitals: ClosedRange<Int>
        var inset: Int

        /// Sizes at half coverage.
        var height: Int { marker.rows.count }
        var width: Int { marker.columns.count }
        var capHeight: Int { capitals.count }
        /// Twice the centre, in pixels, so it stays an integer: vertically
        /// from the capitals' top, horizontally from the depth padding.
        var centreY2: Int { marker.rows.lowerBound + marker.rows.upperBound - 2 * capitals.lowerBound }
        var centreX2: Int { marker.columns.lowerBound + marker.columns.upperBound - 2 * inset }
        var centre: (x: Int, y: Int) { ((marker.columns.lowerBound + marker.columns.upperBound) / 2, (marker.rows.lowerBound + marker.rows.upperBound) / 2) }
    }

    static func measure(_ bitmap: TK2Parity.Bitmap, row: PreparedListRow, env: TK2Parity.Environment) throws -> Measured {
        let inset = CGFloat(row.depth) * (Parity.markerWidth(env.size) + theme.spacing)
        let split = Int(((inset + Parity.markerWidth(env.size) + theme.spacing / 2) * bitmap.scale).rounded())
        let marker = coverage(bitmap, columns: 0..<split, dark: env.dark)
        let text = coverage(bitmap, columns: split..<bitmap.width, dark: env.dark)
        let first = try #require(marker.firstRow), last = try #require(marker.lastRow)
        let columns = try #require(marker.extent(first...last))
        let capitals = try #require(text.bands.first)
        return Measured(marker: (first...last, columns), capitals: capitals, inset: Int((inset * bitmap.scale).rounded()))
    }

    /// Ink at half coverage or more: every channel at least halfway from
    /// the background to the text colour (black on white, white on black).
    static func coverage(_ bitmap: TK2Parity.Bitmap, columns: Range<Int>, dark: Bool) -> Parity.Ink {
        var ink = Parity.Ink(counts: Array(repeating: 0, count: bitmap.height), starts: Array(repeating: 0, count: bitmap.height), ends: Array(repeating: 0, count: bitmap.height))
        for y in 0..<bitmap.height {
            var count = 0, first = -1, last = -1
            for x in max(columns.lowerBound, 0)..<min(columns.upperBound, bitmap.width) {
                let p = bitmap[x, y]
                let covered = dark ? min(p.r, p.g, p.b) >= 128 : max(p.r, p.g, p.b) < 128
                if covered {
                    count += 1
                    if first < 0 { first = x }
                    last = x
                }
            }
            ink.counts[y] = count
            ink.starts[y] = first
            ink.ends[y] = last
        }
        return ink
    }

    static func render(_ view: some View, env: TK2Parity.Environment, width: CGFloat) throws -> (bitmap: TK2Parity.Bitmap, height: CGFloat) {
        let height = Parity.measure(view, width: width).size.height
        return (try Parity.render(view, width: width, height: height + 24, dark: env.dark).bitmap, height)
    }

    static func isColour(_ p: (r: Int, g: Int, b: Int), _ c: (Int, Int, Int)) -> Bool {
        abs(p.r - c.0) <= 24 && abs(p.g - c.1) <= 24 && abs(p.b - c.2) <= 24
    }

    @Test("A bullet is 0.48 of the capital height; only the third level is a square")
    func proportions() {
        #expect(ListRowView.bulletDiameterToCapHeight == 0.48)
        #expect((0..<6).map(ListRowView.bulletGlyph) == ["•", "◦", "▪", "•", "◦", "▪"])
    }

    @Test("Every depth's mark is 0.48 of the capital height, centred like the font's dot, flat and in the text colour, on both engines")
    func bulletMarks() async throws {
        let rows = try await Self.rows()
        try #require(rows.count == 3)
        var environments: [TK2Parity.Environment] = []
        for size in [DynamicTypeSize.large, .xxxLarge, .accessibility3] {
            environments.append(TK2Parity.Environment(size: size))
            environments.append(TK2Parity.Environment(size: size, dark: true))
        }
        environments.append(TK2Parity.Environment(size: .large, legibility: .bold))
        let width = Parity.listWidth(documentWidth: 375)
        for env in environments {
            for arm in [ADFTextRenderer.swiftUI, .textKit2] {
                var footprints: [Measured] = []
                for (row, leader) in zip(rows, Self.leaders) {
                    let label = "depth \(row.depth) \(env) \(arm)"
                    let hosted = Parity.hostedRow(row, arm: arm, env: env, listWidth: width)
                    let rendered = try Self.render(hosted, env: env, width: width)
                    let drawn = try Self.measure(rendered.bitmap, row: row, env: env)
                    // The row keeps the height it had with its glyph.
                    let glyphRow = Self.reference(row, glyph: ListRowView.bulletGlyph(depth: row.depth), leader: leader, env: env)
                    let glyphHeight = Parity.measure(glyphRow, width: width).size.height
                    #expect(abs(rendered.height - glyphHeight) <= Parity.tolerance, "\(label): row height \(rendered.height), with the glyph \(glyphHeight)")
                    // 0.48 of the capital height, within two pixels (a
                    // round mark's ends cover less than half a pixel).
                    let expected = Double(drawn.capHeight) * Double(ListRowView.bulletDiameterToCapHeight)
                    #expect(abs(Double(drawn.width) - expected) <= 2, "\(label): mark \(drawn.width) px wide, capitals \(drawn.capHeight) px")
                    #expect(abs(Double(drawn.height) - expected) <= 2, "\(label): mark \(drawn.height) px tall, capitals \(drawn.capHeight) px")
                    // Centred where the font's own • is centred.
                    let dot = try Self.measure(Self.render(Self.reference(row, glyph: "•", leader: leader, env: env), env: env, width: width).bitmap, row: row, env: env)
                    #expect(abs(drawn.centreY2 - dot.centreY2) <= 2, "\(label): centre \(Double(drawn.centreY2 - dot.centreY2) / 2) px off the glyph dot's, vertically")
                    #expect(abs(drawn.centreX2 - dot.centreX2) <= 2, "\(label): centre \(Double(drawn.centreX2 - dot.centreX2) / 2) px off the glyph dot's, across")
                    // Flat, in the text colour: the dot and square solid at
                    // the centre, the ring hollow there; the square solid
                    // to its corners (an emoji square is shaded, a round
                    // mark leaves its corners empty).
                    let text: (Int, Int, Int) = env.dark ? (255, 255, 255) : (0, 0, 0)
                    let centre = rendered.bitmap[drawn.centre.x, drawn.centre.y]
                    if row.depth == 1 {
                        #expect(Self.isColour(centre, Parity.background(dark: env.dark)), "\(label): ring centre \(centre) is not hollow")
                    } else {
                        #expect(Self.isColour(centre, text), "\(label): centre \(centre) is not the text colour")
                    }
                    if ListRowView.bulletGlyph(depth: row.depth) == "▪" {
                        var off = 0
                        for y in drawn.marker.rows.dropFirst().dropLast() {
                            for x in drawn.marker.columns.dropFirst().dropLast() where !Self.isColour(rendered.bitmap[x, y], text) {
                                off += 1
                            }
                        }
                        #expect(off == 0, "\(label): \(off) pixels inside the square are not the text colour")
                    }
                    footprints.append(drawn)
                    print("bullet mark \(label): \(drawn.width)×\(drawn.height) px, capitals \(drawn.capHeight) px, glyph dot \(dot.width)×\(dot.height) px")
                }
                // One footprint for all three marks (a square's ends reach
                // a pixel further than a circle's at half coverage).
                for mark in footprints.dropFirst() {
                    #expect(abs(mark.width - footprints[0].width) <= 2 && abs(mark.height - footprints[0].height) <= 2,
                            "\(env) \(arm): footprints \(footprints.map { "\($0.width)×\($0.height)" })")
                }
            }
        }
    }
}
#endif
