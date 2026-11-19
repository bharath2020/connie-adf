#if canImport(UIKit)
import SwiftUI
import UIKit
import Testing
import ADFModel
import ADFPreparation
@testable import ADFRendering

// Negative controls for the container matrices' leaf-drawing exception
// (lead dispositions M3). A container case that fails in pixels only is
// accepted as the leaf's residual (`Verdict.cause == "leafDrawing"`) only
// when the residual accounts for every differing pixel, owner by owner
// (`Verdict.residualMismatch`): no chrome failure, no differing pixel
// outside the TextKit 2 rows, and for each owner the same owner alone
// differing in the same pixel rows of its row by exactly as many pixels,
// and no owner differing by more than the per-owner cap (delta review R2).
//
// A quote of two paragraphs is hosted through the production path, and
// each paragraph alone as the leaf control hosts it, at an environment
// where both arms match exactly. A known residual is then painted into the
// TextKit 2 arm of the first paragraph, in the container and alone at the
// same rows of its row: accepted (the positive control), and so is the same
// residual with pixels left of the row, where a line-initial italic glyph's
// tail is that SwiftUI draws and the row clips, alone at the same place too,
// even in the quote's bar. A second defect beside it, in the container
// only, must be rejected: in the quote's bar (chrome), outside every row,
// in the other paragraph's row, in other rows of the same paragraph, more
// pixels in the same rows, or left of the row; and so must a real one, the
// TextKit 2 arm hosted with another inherited foreground.

@Suite("TextKit 2 container residual attribution (leafDrawing negative controls)", .serialized)
@MainActor
struct TextKit2ContainerResidualTests {
    typealias P = TK2ContainerProbe
    typealias B = TK2ContainerBody

    /// `bitmap` with the device pixels `x` × `y` painted `color`.
    static func stamp(_ bitmap: TK2Parity.Bitmap, x: Range<Int>, y: Range<Int>, color: (UInt8, UInt8, UInt8) = (255, 0, 0)) -> TK2Parity.Bitmap {
        var rgba = bitmap.rgba
        for row in y.clamped(to: 0..<bitmap.height) {
            for column in x.clamped(to: 0..<bitmap.width) {
                let i = (row * bitmap.width + column) * 4
                rgba[i] = color.0
                rgba[i + 1] = color.1
                rgba[i + 2] = color.2
                rgba[i + 3] = 255
            }
        }
        return TK2Parity.Bitmap(width: bitmap.width, height: bitmap.height, scale: bitmap.scale, rgba: rgba)
    }

    /// The quote, its two paragraphs, and both arms hosted in the
    /// container and alone at one environment and width.
    struct Case {
        let block: RenderBlock
        let children: [RenderBlock]
        let env: TK2Parity.Environment
        let rowWidth: CGFloat
        let container: (swiftUI: P.Arm, textKit2: P.Arm)
        let alone: [(swiftUI: P.Arm, textKit2: P.Arm)]

        func frame(_ owner: String) throws -> CGRect {
            try #require(container.textKit2.rows.first { $0.owner == owner }?.frame, "\(owner): no TextKit 2 row in the quote")
        }

        func aloneFrame(_ index: Int) throws -> CGRect {
            let owner = children[index].id
            return try #require(alone[index].textKit2.rows.first { $0.owner == owner }?.frame, "\(owner): no TextKit 2 row alone")
        }
    }

    static func quote(env: TK2Parity.Environment, documentWidth: CGFloat, make: ((ADFTextRenderer) -> AnyView)? = nil) async throws -> Case {
        let json = P.quote([P.paragraph(P.t(P.words(16, from: 2))), P.paragraph(P.t(P.words(20, from: 7)))])
        let block = try #require(try await P.prepared([json]).first)
        guard case .quote(let children) = block.kind, children.count == 2 else { throw TestFailure("not a quote of two paragraphs") }
        let rowWidth = P.rowWidth(documentWidth: documentWidth)
        let container = try P.pair(width: rowWidth, pixels: true, dark: env.dark) { arm in
            make?(arm) ?? AnyView(P.environment(BlockView(block: block), arm: B.rowRenderer(block, arm), env: env, rowWidth: rowWidth, allowed: nil))
        }
        let alone = try B.leafArms(children, in: .quote, width: P.childWidth(.quote, rowWidth: rowWidth, env: env), env: env)
        return Case(block: block, children: children, env: env, rowWidth: rowWidth, container: container, alone: alone)
    }

    /// The matrix's verdict for `c` with the TextKit 2 bitmaps replaced:
    /// geometry, the quote's crops (bar and content, `crops`), owner
    /// attribution and the leaf control.
    static func verdict(_ c: Case, container: TK2Parity.Bitmap? = nil, alone: [TK2Parity.Bitmap]? = nil) throws -> P.Verdict {
        var verdict = P.geometry(c.container.swiftUI.guides, c.container.textKit2.guides)
        let a = try #require(c.container.swiftUI.bitmap)
        let b = try #require(container ?? c.container.textKit2.bitmap)
        let s = P.spacing
        let bar = P.Crop(name: "bar", columns: P.columns(from: 0, to: s, width: c.rowWidth, scale: a.scale, rtl: false))
        let content = P.Crop(name: "content", columns: P.columns(from: s, to: c.rowWidth, width: c.rowWidth, scale: a.scale, rtl: false))
        P.pixels(&verdict, a, b, crops: [bar, content], background: P.background(c.env), rows: c.container.textKit2.rows, dark: c.env.dark)
        var control = P.LeafControl()
        for (index, arms) in c.alone.enumerated() {
            var textKit2 = arms.textKit2
            if let alone { textKit2.bitmap = alone[index] }
            control.add(arms.swiftUI, textKit2, dark: c.env.dark)
        }
        verdict.leaf = control
        return verdict
    }

    /// The painted residual: three pixel rows from 4 px below the row's
    /// top edge, `width` px wide from 12 pt in, in the row framed `frame`.
    static func residualPixels(_ frame: CGRect, scale: CGFloat, width: Int = 10, rowOffset: Int = 4) -> (x: Range<Int>, y: Range<Int>) {
        let top = Int((frame.minY * scale).rounded()) + rowOffset
        let x0 = Int(((frame.minX + 12) * scale).rounded())
        return (x0..<(x0 + width), top..<(top + 3))
    }

    @Test("leafDrawing accepts a residual its owner shows alone in the same rows, and rejects a second defect beside it: chrome, outside every row, another owner, other rows of the owner, more pixels, a wrong foreground")
    func secondDefectBesideAResidualIsRejected() async throws {
        guard TextKit2Eligibility.containerTextMatchesText else {
            // Before iOS 26 no container text draws on TextKit 2: there is
            // no leaf to attribute.
            let c = try await Self.quote(env: TK2Parity.Environment(), documentWidth: 375)
            #expect(c.container.textKit2.rows.isEmpty, "before iOS 26 the quote's text is gated")
            return
        }
        // An environment where the quote and its paragraphs alone match
        // exactly, so every differing pixel below is painted.
        var found: Case?
        for (size, width) in [(DynamicTypeSize.large, CGFloat(375)), (.large, 402), (.medium, 375), (.xLarge, 375)] {
            let c = try await Self.quote(env: TK2Parity.Environment(size: size), documentWidth: width)
            let base = try Self.verdict(c)
            if base.pass, base.differing == 0, base.engine, base.leaf?.differing == 0, c.container.textKit2.owners == Set(c.children.map(\.id)) {
                found = c
                break
            }
            print("CONTAINER_RESIDUAL_BASE size=\(size) W=\(width) skipped: pass=\(base.pass) differing=\(base.differing) leafDiffering=\(base.leaf?.differing ?? -1) owners=\(c.container.textKit2.owners.sorted())")
        }
        let c = try #require(found, "no environment where the quote matches exactly")
        let scale = TK2Parity.nativeScale
        let first = c.children[0].id, second = c.children[1].id
        let containerB = try #require(c.container.textKit2.bitmap)
        let aloneB = try c.alone.map { try #require($0.textKit2.bitmap) }

        // The known residual: owner `first`, alone and in the quote.
        let inQuote = Self.residualPixels(try c.frame(first), scale: scale)
        let alone = Self.residualPixels(try c.aloneFrame(0), scale: scale)
        let residualContainer = Self.stamp(containerB, x: inQuote.x, y: inQuote.y)
        var residualAlone = aloneB
        residualAlone[0] = Self.stamp(aloneB[0], x: alone.x, y: alone.y)

        let positive = try Self.verdict(c, container: residualContainer, alone: residualAlone)
        #expect(!positive.pass && positive.geometryPass, "the painted residual fails the pixel rule: \(positive.pixelFailures)")
        #expect(positive.residualMismatch == nil, "the residual accounts for the failure: \(positive.residualMismatch ?? "-")")
        #expect(positive.cause == "leafDrawing", "positive control: \(positive.cause) residual=\(positive.residual?.summary ?? "-") leaf=\(positive.leaf?.residual.summary ?? "-")")
        print("CONTAINER_RESIDUAL_POSITIVE size=\(c.env.size) W=\(c.rowWidth) cause=\(positive.cause) residual=\(positive.residual?.summary ?? "-") leafResidual=\(positive.leaf?.residual.summary ?? "-")")

        // The residual with overhang: two pixels 4 pt left of the row (in
        // the quote's content inset) and two 10 pt left of it (in its bar),
        // in the residual's rows, in the container and alone.
        let aloneFrame = try c.aloneFrame(0)
        let quoteFrame = try c.frame(first)
        func left(_ frame: CGRect, by points: CGFloat) -> Range<Int> {
            let x0 = Int(((frame.minX - points) * scale).rounded())
            return x0..<(x0 + 2)
        }
        for (name, points) in [("overhang", CGFloat(4)), ("overhangIntoChrome", CGFloat(10))] {
            let container = Self.stamp(residualContainer, x: left(quoteFrame, by: points), y: inQuote.y.lowerBound..<(inQuote.y.lowerBound + 1))
            var aloneArms = residualAlone
            aloneArms[0] = Self.stamp(residualAlone[0], x: left(aloneFrame, by: points), y: alone.y.lowerBound..<(alone.y.lowerBound + 1))
            let verdict = try Self.verdict(c, container: container, alone: aloneArms)
            print("CONTAINER_RESIDUAL_POSITIVE case=\(name) cause=\(verdict.cause) chrome=\(verdict.chromeFailures.count) mismatch={\(verdict.residualMismatch ?? "-")} residual=\(verdict.residual?.summary ?? "-")")
            #expect(verdict.residual?.overhang[first]?.count == 2, "\(name): \(verdict.residual?.summary ?? "-")")
            #expect(verdict.residualMismatch == nil, "\(name): \(verdict.residualMismatch ?? "-")")
            #expect(verdict.cause == "leafDrawing", "\(name): \(verdict.cause)")
        }

        // Second defects, in the quote only.
        let firstFrame = try c.frame(first)
        let secondFrame = try c.frame(second)
        let below = Int(((c.container.textKit2.guides.height + 6) * scale).rounded())
        let contentX = Int(((firstFrame.minX + 40) * scale).rounded())
        let lastRows = Int((firstFrame.maxY * scale).rounded()) - 8
        let negatives: [(name: String, x: Range<Int>, y: Range<Int>, expect: String)] = [
            ("chrome", Int(P.spacing * 0.25 * scale)..<Int(P.spacing * 0.75 * scale), inQuote.y, "chrome"),
            ("outsideEveryRow", contentX..<(contentX + 10), below..<(below + 3), "outside every TextKit 2 row"),
            ("anotherOwner", Self.residualPixels(secondFrame, scale: scale).x, Self.residualPixels(secondFrame, scale: scale).y, "\(second):"),
            ("otherRowsOfTheOwner", inQuote.x, lastRows..<(lastRows + 3), "\(first): rows"),
            ("morePixelsInTheSameRows", inQuote.x.upperBound..<(inQuote.x.upperBound + 20), inQuote.y, "\(first): 90 px differ in the container, 30 alone"),
            // One pixel more in the same rows: the count is exact
            // (delta review R2).
            ("onePixelMore", inQuote.x.upperBound..<(inQuote.x.upperBound + 1), inQuote.y.lowerBound..<(inQuote.y.lowerBound + 1), "\(first): 31 px differ in the container, 30 alone"),
            // Left of the row: not alone.
            ("pastTheRowsEdge", left(quoteFrame, by: 4), inQuote.y.lowerBound..<(inQuote.y.lowerBound + 1), "\(first): 2 px past its row's edges"),
        ]
        for negative in negatives {
            let painted = Self.stamp(residualContainer, x: negative.x, y: negative.y)
            let verdict = try Self.verdict(c, container: painted, alone: residualAlone)
            let mismatch = verdict.residualMismatch
            print("CONTAINER_RESIDUAL_NEGATIVE case=\(negative.name) cause=\(verdict.cause) mismatch={\(mismatch ?? "-")} residual=\(verdict.residual?.summary ?? "-")")
            #expect(!verdict.pass, "\(negative.name): the second defect fails the pixel rule")
            #expect(verdict.cause != "leafDrawing", "\(negative.name): accepted as the leaf's residual")
            #expect(mismatch?.contains(negative.expect) == true, "\(negative.name): \(mismatch ?? "-"), expected \(negative.expect)")
        }

        // Delta review R2: a residual of thousands of pixels is rejected
        // even when its owner alone shows it in the same rows, pixel for
        // pixel (a defect driven by the width, which reproduces alone at
        // that width); the same shape under the cap is accepted.
        for (name, width, accepted) in [("thousandsOfPixels", 400, false), ("underTheCap", 80, true)] {
            func block(_ frame: CGRect) -> (x: Range<Int>, y: Range<Int>) {
                let top = Int((frame.minY * scale).rounded()) + 4
                let x0 = Int(((frame.minX + 12) * scale).rounded())
                return (x0..<(x0 + width), top..<(top + 6))
            }
            let here = block(firstFrame), there = block(aloneFrame)
            #expect(here.x.upperBound < Int(firstFrame.maxX * scale), "\(name): the block fits the row")
            var aloneArms = aloneB
            aloneArms[0] = Self.stamp(aloneB[0], x: there.x, y: there.y)
            let verdict = try Self.verdict(c, container: Self.stamp(containerB, x: here.x, y: here.y), alone: aloneArms)
            let mismatch = verdict.residualMismatch
            let count = verdict.residual?.owners[first]?.count ?? 0
            print("CONTAINER_RESIDUAL_CAP case=\(name) cause=\(verdict.cause) mismatch={\(mismatch ?? "-")} residual=\(verdict.residual?.summary ?? "-") leafResidual=\(verdict.leaf?.residual.summary ?? "-")")
            #expect(count == width * 6 && verdict.leaf?.residual.owners[first]?.count == count, "\(name): the owner alone shows the same \(width * 6) px")
            #expect(!verdict.pass)
            if accepted {
                #expect(count <= P.residualOwnerCap && mismatch == nil && verdict.cause == "leafDrawing", "\(name): \(verdict.cause) \(mismatch ?? "-")")
            } else {
                #expect(count > 2_000 && verdict.cause != "leafDrawing", "\(name): accepted as the leaf's residual")
                #expect(mismatch?.contains("past the per-owner cap") == true, "\(name): \(mismatch ?? "-")")
            }
        }

        // A real defect beside the residual: the TextKit 2 arm hosted with
        // another inherited foreground, red text in both paragraphs.
        let red = try await Self.quote(env: c.env, documentWidth: c.rowWidth + 4 * P.spacing) { arm in
            AnyView(
                P.environment(BlockView(block: c.block), arm: B.rowRenderer(c.block, arm), env: c.env, rowWidth: c.rowWidth, allowed: nil)
                    .environment(\.adfTextForeground, arm == .textKit2 ? Color.red : nil)
            )
        }
        let redB = try #require(red.container.textKit2.bitmap)
        let redFrame = try red.frame(red.children[0].id)
        let redResidual = Self.residualPixels(redFrame, scale: scale)
        let foreground = try Self.verdict(red, container: Self.stamp(redB, x: redResidual.x, y: redResidual.y), alone: residualAlone)
        print("CONTAINER_RESIDUAL_NEGATIVE case=foreground cause=\(foreground.cause) mismatch={\(foreground.residualMismatch ?? "-")} residual=\(foreground.residual?.summary ?? "-")")
        #expect(red.container.textKit2.owners == Set(red.children.map(\.id)), "the red arm draws both paragraphs on TextKit 2")
        #expect(!foreground.pass && foreground.cause != "leafDrawing", "a wrong foreground beside the residual: \(foreground.cause)")
        #expect(foreground.residualMismatch != nil)
    }
}
#endif
