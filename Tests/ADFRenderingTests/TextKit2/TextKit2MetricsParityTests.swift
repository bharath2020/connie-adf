#if canImport(UIKit)
import SwiftUI
import UIKit
import Testing
import ADFPreparation
@testable import ADFRendering

/// Text metrics, separately (plan §4.5b): the first and last baselines an
/// enclosing container aligns to, the layout height, the baseline pitch
/// and the ink rows — SwiftUI's side from captured `alignmentGuide`
/// dimensions and its bitmap, TextKit's from its layout result and bitmap.
@Suite("TextKit 2 metrics parity", .serialized)
@MainActor
struct TextKit2MetricsParityTests {
    nonisolated static let sizes: [DynamicTypeSize] = [.xSmall, .large, .xxxLarge, .accessibility3]
    nonisolated static let widths: [CGFloat] = [370, 353.333]
    nonisolated static let tolerance: CGFloat = 0.01

    static func fixtures() async throws -> [TK2Parity.Fixture] {
        let medium = "The quick brown fox jumps over the lazy dog while seventeen purple elephants rehearse"
        return [
            try await TK2Parity.plain("one-line", "Quarterly planning notes"),
            try await TK2Parity.plain("multi-line", medium + " " + medium),
            try await TK2Parity.heading(1, medium),
            try await TK2Parity.heading(3, "Short heading"),
            try await TK2Parity.fixture("mono", content:
                TK2Parity.adfText("Call ") + "," + TK2Parity.adfText("prepare(document)", marks: "{\"type\":\"code\"}") + "," + TK2Parity.adfText(" before " + medium)),
            try await TK2Parity.fixture("subsup", content:
                TK2Parity.adfText("H") + "," + TK2Parity.adfText("2", marks: "{\"type\":\"subsup\",\"attrs\":{\"type\":\"sub\"}}") + ","
                + TK2Parity.adfText("O and E=mc") + "," + TK2Parity.adfText("2", marks: "{\"type\":\"subsup\",\"attrs\":{\"type\":\"sup\"}}") + ","
                + TK2Parity.adfText(" " + medium)),
            try await TK2Parity.fixture("hardbreak", content:
                TK2Parity.adfText("First line") + "," + TK2Parity.hardBreak + "," + TK2Parity.adfText(medium)),
        ]
    }

    /// Known residual: in a few cases SwiftUI's `lastTextBaseline` guide
    /// sits exactly one pixel below the baseline it draws (glyph ink rows
    /// are identical on both arms) — 6 of 56 here (h1 at AX3, subsup), 28
    /// of 132 in a wider sweep. No rule over the line metrics reproduced
    /// it (best candidate 113/132), so TextKit reports its drawn baseline
    /// and the +1 px cases are recorded as known issues; never -1 px.
    /// Evidence: parity/last-baseline/.
    @Test("first/last baselines and height match SwiftUI's, single- and multi-line")
    func baselines() async throws {
        var checked = 0
        var lastBaselineResiduals = 0
        for fixture in try await Self.fixtures() {
            for size in Self.sizes {
                for width in Self.widths {
                    let env = TK2Parity.Environment(size: size)
                    let s = TK2Parity.guides(fixture, arm: .swiftUI, env: env, width: width)
                    let t = TK2Parity.guides(fixture, arm: .textKit2, env: env, width: width)
                    let layout = try TK2Parity.layout(fixture, env: env, width: width)
                    let label = "\(fixture.name) \(size) w=\(width)"
                    #expect(abs(s.first - t.first) <= Self.tolerance, "\(label): first baseline swiftUI=\(s.first) textKit2=\(t.first)")
                    let onePixel = 1 / TK2Parity.nativeScale
                    if abs(s.last - t.last - onePixel) <= Self.tolerance, abs(layout.lastBaseline - t.last) <= Self.tolerance {
                        lastBaselineResiduals += 1
                        withKnownIssue("SwiftUI's last-baseline guide is 1 px below its drawn baseline") {
                            #expect(abs(s.last - t.last) <= Self.tolerance, "\(label): last baseline swiftUI=\(s.last) textKit2=\(t.last)")
                            #expect(abs(layout.lastBaseline - s.last) <= Self.tolerance, "\(label): layout last=\(layout.lastBaseline) swiftUI=\(s.last)")
                        }
                    } else {
                        #expect(abs(s.last - t.last) <= Self.tolerance, "\(label): last baseline swiftUI=\(s.last) textKit2=\(t.last)")
                        #expect(abs(layout.lastBaseline - s.last) <= Self.tolerance, "\(label): layout last=\(layout.lastBaseline) swiftUI=\(s.last)")
                    }
                    #expect(abs(s.height - t.height) <= Self.tolerance, "\(label): height swiftUI=\(s.height) textKit2=\(t.height)")
                    // The layout result is what the row reports: it must
                    // carry the same numbers.
                    #expect(abs(layout.firstBaseline - s.first) <= Self.tolerance, "\(label): layout first=\(layout.firstBaseline) swiftUI=\(s.first)")
                    #expect(abs(layout.size.height - s.height) <= Self.tolerance, "\(label): layout height=\(layout.size.height) swiftUI=\(s.height)")
                    if layout.lineCount == 1 {
                        #expect(layout.firstBaseline == layout.lastBaseline, "\(label)")
                    }
                    checked += 1
                }
            }
        }
        print("TK2 metrics parity: \(checked) fixture × size × width baselines, \(lastBaselineResiduals) with SwiftUI's last-baseline guide +1 px")
    }

    /// Known residual: SF Mono glyphs rasterize slightly differently on the
    /// two arms at identical positions (the bitmap difference is minimal at
    /// zero offset; no pixel differs by more than 24 of 255), so a faint
    /// edge row can fall either side of the ink threshold — 3 bands of the
    /// "mono" fixture. Recorded as a known issue only when the band has no
    /// visibly differing pixel. Evidence: parity/mono-raster/.
    @Test("per-line ink rows match (baseline pitch), and the ink bounds cover the ink")
    func inkRowsAndPitch() async throws {
        for fixture in try await Self.fixtures() {
            for size in [DynamicTypeSize.large, .accessibility3] {
                let env = TK2Parity.Environment(size: size)
                let width: CGFloat = 353.333
                let layout = try TK2Parity.layout(fixture, env: env, width: width)
                let height = layout.size.height + 24
                let a = try TK2Parity.render(fixture, arm: .swiftUI, env: env, width: width, height: height)
                let b = try TK2Parity.render(fixture, arm: .textKit2, env: env, width: width, height: height)
                let label = "\(fixture.name) \(size)"
                for (index, band) in TK2Parity.lineBands(layout, scale: a.scale).enumerated() {
                    let ra = Self.inkRows(a, band)
                    let rb = Self.inkRows(b, band)
                    let message: Comment = "\(label) line \(index): ink rows swiftUI=\(String(describing: ra)) textKit2=\(String(describing: rb))"
                    let visible = TK2Parity.differingFraction(a, b, rows: band.lowerBound...(min(band.upperBound, a.height) - 1)).count
                    if ra != rb, fixture.name == "mono", visible == 0 {
                        withKnownIssue("SF Mono rasterizes fainter edge rows under TextKit 2") { #expect(ra == rb, message) }
                    } else {
                        #expect(ra == rb, message)
                    }
                }
                // Every SwiftUI ink pixel lies inside TextKit's ink bounds
                // (the canvas covers them, so nothing is clipped).
                let profile = TK2Parity.inkProfile(a, dark: false)
                let blank = fixture.describableText.map { $0.characters.allSatisfy(\.isWhitespace) } ?? true
                #expect(blank || profile.firstInkRow != nil, "\(label): SwiftUI rendered no ink; nothing was compared")
                if let first = profile.firstInkRow, let last = profile.lastInkRow {
                    let ink = layout.inkBounds
                    #expect(CGFloat(first) / a.scale >= ink.minY - 1 / a.scale, "\(label): ink above inkBounds (\(first) px vs \(ink.minY) pt)")
                    #expect(CGFloat(last + 1) / a.scale <= ink.maxY + 1 / a.scale, "\(label): ink below inkBounds (\(last) px vs \(ink.maxY) pt)")
                }
            }
        }
    }

    /// First and last ink rows within a band of pixel rows.
    static func inkRows(_ bitmap: TK2Parity.Bitmap, _ band: Range<Int>) -> ClosedRange<Int>? {
        var first: Int?
        var last: Int?
        for y in max(band.lowerBound, 0)..<min(band.upperBound, bitmap.height) {
            if (0..<bitmap.width).contains(where: { TK2Parity.isInk(bitmap, $0, y, dark: false) }) {
                first = first ?? y
                last = y
            }
        }
        guard let first, let last else { return nil }
        return first...last
    }
}
#endif
