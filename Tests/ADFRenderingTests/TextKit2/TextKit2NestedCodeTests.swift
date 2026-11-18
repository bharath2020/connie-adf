#if canImport(UIKit)
import SwiftUI
import UIKit
import Testing
import ADFModel
import ADFPreparation
@_spi(ADFDiagnostics) @testable import ADFRendering

// Nested code (PR 4 step 7, plan §4.7): PR 3's whole `CodeBlockView`,
// reached through `BlockView` below a container's boundary, with no second
// scroller and no second Copy button. The renderer arrives by environment:
// `.codeBlock` is in `TextKit2Scope.containerChildKinds`, the boundary
// passes the switch to a code child, and the leaf goes through
// `TextKit2CodeGate` as top-level code does. Before iOS 26 nested code is
// `osGatedContainer` first (`TextKit2Eligibility.containerCodeVerdict`, P14).
//
// These host the real `ADFDocumentView` (or the real `BlockView`) in a
// window and read the UIKit tree: the code block's horizontal viewport, its
// natural content, the TextKit 2 row, the document's own scroll view. Where
// TextKit 2 cannot draw the code (before iOS 26, a side-by-side column, the
// canvas gate) the same checks hold with both arms on SwiftUI.
// `-only-testing:ADFRenderingTests/TextKit2NestedCodeTests`

/// Documents and hosting for the nested-code suite. Not a suite.
@MainActor
enum TK2NestedCode {
    /// Where a code block sits, each container at `0.0` of its document.
    enum Place: String, CaseIterable, Sendable, CustomStringConvertible {
        /// A panel holding a quote holding the code (`0.0.0.0`).
        case panelQuote
        /// A quote: a paragraph, then the code (`0.0.1`).
        case quote
        /// A panel whose body is the code alone (`0.0.0`): the one panel
        /// shape with code that keeps the renderer (`panelKeepsRenderer`).
        case panel
        /// An open expand: a paragraph, then the code (`0.0.1`).
        case expandBody
        /// A bodied extension: a paragraph, then the code (`0.0.1`).
        case extensionBody
        /// A 50/50 layout section stacked at a compact width: the code in
        /// the first column (`0.0.0.0`).
        case stackedColumn
        /// The same section side by side at a regular width: the column
        /// keeps the code on SwiftUI (C32).
        case sideBySideColumn

        var description: String { rawValue }

        var codeID: String {
            switch self {
            case .panelQuote, .stackedColumn, .sideBySideColumn: return "0.0.0.0"
            case .quote, .expandBody, .extensionBody: return "0.0.1"
            case .panel: return "0.0.0"
            }
        }

        var sideBySide: Bool { self == .sideBySideColumn }

        /// Whether the production rules hand the code to TextKit 2 here
        /// (left to right, within the canvas bound): from iOS 26, every
        /// place but a side-by-side column.
        var migrates: Bool { !sideBySide && TextKit2Eligibility.containerTextMatchesText }

        var openExpands: Set<String> { self == .expandBody ? ["0.0"] : [] }

        var windowWidth: CGFloat { sideBySide ? 820 : 390 }

        /// The container node around `code`.
        func container(_ code: [String: Any]) -> [String: Any] {
            let prose = TK2CodeLogic.paragraph("Prose before the nested code block.")
            let column = { (children: [[String: Any]]) in TK2CodeLogic.node("layoutColumn", attrs: ["width": 50], children) }
            switch self {
            case .panelQuote:
                return TK2CodeLogic.node("panel", attrs: ["panelType": "info"], [TK2CodeLogic.node("blockquote", [code])])
            case .quote:
                return TK2CodeLogic.node("blockquote", [prose, code])
            case .panel:
                return TK2CodeLogic.node("panel", attrs: ["panelType": "note"], [code])
            case .expandBody:
                return TK2CodeLogic.node("expand", attrs: ["title": "Nested code"], [prose, code])
            case .extensionBody:
                return TK2CodeLogic.node(
                    "bodiedExtension", attrs: ["extensionType": "com.example.nested-code", "extensionKey": "nested-code"], [prose, code]
                )
            case .stackedColumn, .sideBySideColumn:
                return TK2CodeLogic.node("layoutSection", [
                    column([code]), column([TK2CodeLogic.paragraph("The column beside the code.")]),
                ])
            }
        }
    }

    /// The places of `narrowContainerProposals` and the switch tests: each
    /// container and both column modes (plan §4.7).
    nonisolated static let proposalPlaces: [Place] = [.panelQuote, .expandBody, .extensionBody, .stackedColumn, .sideBySideColumn]

    /// The places the canvas gate is checked in: every place the code would
    /// otherwise draw on TextKit 2.
    nonisolated static let gatePlaces: [Place] = [.quote, .panel, .panelQuote, .expandBody, .extensionBody, .stackedColumn]

    /// The document: the container at `0.0`, then `trailing` paragraphs.
    static func document(_ place: Place, code: String, trailing: Int = 2) throws -> Data {
        var content = [place.container(TK2CodeLogic.code(code, language: "swift"))]
        for index in 0..<trailing {
            content.append(TK2CodeLogic.paragraph("Paragraph \(index + 1) after the container, long enough to wrap onto a second line here."))
        }
        return try TK2CodeLogic.document(content)
    }

    static func view(_ model: ADFDocumentModel, _ renderer: ADFTextRenderer, sideBySide: Bool) -> some View {
        TK2CodeLogic.documentView(model, renderer)
            .environment(\.horizontalSizeClass, sideBySide ? .regular : .compact)
            .dynamicTypeSize(.large)
    }

    /// The document of `place` around `code`, loaded, its expand opened,
    /// hosted on `renderer`, and laid out until the code's viewport is in
    /// the window (and, where the code migrates on this arm, its row).
    static func host(
        _ place: Place, code: String, renderer: ADFTextRenderer, trailing: Int = 2, height: CGFloat = 1_600, drawsRow: Bool = true
    ) async throws -> (model: ADFDocumentModel, hosted: TK2CodeLogic.Hosted) {
        let model = try await TK2CodeLogic.loadedModel(try document(place, code: code, trailing: trailing))
        model.expandedBlocks.formUnion(place.openExpands)
        let hosted = TK2CodeLogic.Hosted(view(model, renderer, sideBySide: place.sideBySide), size: CGSize(width: place.windowWidth, height: height))
        try await hosted.settle()
        try await waitForCode(hosted, place: place, row: drawsRow && renderer == .textKit2 && place.migrates)
        return (model, hosted)
    }

    /// Lays out until the code's viewport is in the window and, with `row`,
    /// its TextKit 2 row too (an expand's body is prepared off the main
    /// actor on opening).
    static func waitForCode(_ hosted: TK2CodeLogic.Hosted, place: Place, row: Bool) async throws {
        for _ in 0..<250 {
            if codeScroll(hosted) != nil, !row || codeRow(hosted, place.codeID) != nil { break }
            hosted.window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        try await hosted.settle()
    }

    /// The code block's horizontal viewport: the widest scroll view nested
    /// in the document's (each document here holds one code block).
    static func codeScroll(_ hosted: TK2CodeLogic.Hosted) -> UIScrollView? {
        TK2Parity.nestedScrollViews(in: hosted.host.view).filter { $0.window != nil }.max { $0.contentSize.width < $1.contentSize.width }
    }

    /// The document's own scroll view.
    static func documentScroll(_ hosted: TK2CodeLogic.Hosted) -> UIScrollView? {
        TK2Parity.scrollViews(in: hosted.host.view).first
    }

    static func codeRow(_ hosted: TK2CodeLogic.Hosted, _ owner: String) -> TextKit2RowView? {
        hosted.rows.first { $0.ownerID == owner }
    }

    /// The prepared code of `place` as the view gets it: from the
    /// document's blocks, or (in an expand) from the body the view prepares
    /// on opening.
    static func preparedCode(_ place: Place, in model: ADFDocumentModel) throws -> AttributedString {
        let block: RenderBlock?
        if place == .expandBody {
            let expand = try #require(model.blocks.first)
            block = TK2ExpandParity.body(of: expand).first { if case .codeBlock = $0.kind { return true }; return false }
        } else {
            block = TextKit2ContainerCoverageTests.find(place.codeID, in: model.blocks)
        }
        guard let block, case .codeBlock(_, let code) = block.kind else { throw TestFailure("\(place): no code block \(place.codeID)") }
        return code
    }

    /// What one arm shows of the code: its viewport in window coordinates,
    /// its scroll content and offset, the document's scroll geometry.
    struct Geometry {
        let viewport: CGRect
        let content: CGSize
        let offset: CGFloat
        let documentContent: CGSize
        let documentBounds: CGRect
    }

    static func geometry(_ hosted: TK2CodeLogic.Hosted, _ label: String) throws -> Geometry {
        let scroll = try #require(codeScroll(hosted), "\(label): no code viewport")
        let document = try #require(documentScroll(hosted), "\(label): no document scroll view")
        return Geometry(
            viewport: scroll.convert(scroll.bounds, to: nil), content: scroll.contentSize, offset: scroll.contentOffset.x,
            documentContent: document.contentSize, documentBounds: document.bounds
        )
    }

    /// The first accessibility element labelled `label` under `object`, as
    /// `TK2CodeParity.spokenElements` walks the tree.
    static func element(labeled label: String, under object: NSObject, depth: Int = 0) -> NSObject? {
        guard depth < 64 else { return nil }
        if object.isAccessibilityElement { return object.accessibilityLabel == label ? object : nil }
        if let elements = object.accessibilityElements, !elements.isEmpty {
            for case let child as NSObject in elements {
                if let found = element(labeled: label, under: child, depth: depth + 1) { return found }
            }
            return nil
        }
        let count = object.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
            for index in 0..<count {
                if let child = object.accessibilityElement(at: index) as? NSObject,
                   let found = element(labeled: label, under: child, depth: depth + 1) { return found }
            }
            return nil
        }
        if let view = object as? UIView {
            for subview in view.subviews {
                if let found = element(labeled: label, under: subview, depth: depth + 1) { return found }
            }
        }
        return nil
    }

    static func n(_ value: CGFloat) -> String { TK2CodeParity.n(value) }
}

/// A block plugin that draws a code block of its own: claims a `blockCard`
/// whose URL starts `nested-code:` and hosts the real `CodeBlockView` around
/// prepared code, its owner `plugin-code:<block id>`. A plugin's view is
/// never reached by the renderer (`.custom` is in no allow list and never
/// inherits), so its code stays on SwiftUI wherever the plugin sits.
private struct NestedCodePlugin: ADFCustomBlockRenderer {
    let rendererID = "test.nested-code.plugin"
    let code: AttributedString

    func claim(for node: ADFNode) -> ADFCustomBlockClaim? {
        guard case .blockCard(let url, _) = node.kind, let url, url.hasPrefix("nested-code:") else { return nil }
        return ADFCustomBlockClaim(String(url.dropFirst("nested-code:".count)), sizing: .reflowingText)
    }

    @MainActor
    func content(for value: String, context: ADFCustomBlockContext) -> some View {
        CodeBlockView(language: "swift", code: code, ownerID: "plugin-code:\(context.blockID)")
    }
}

@Suite("TextKit 2 nested code", .serialized)
@MainActor
struct TextKit2NestedCodeTests {
    typealias N = TK2NestedCode

    // MARK: Proposals

    /// The wide block (six 130-column lines, about 1,350 pt at Large) in
    /// each container and both column modes, panned to a nonzero
    /// horizontal offset, on both arms: the viewport takes the width the
    /// container proposes, the scroll content keeps the code's natural
    /// width, the document never scrolls sideways, and the TextKit 2 arm's
    /// viewport and document are the SwiftUI arm's.
    @Test("narrowContainerProposals: in a panel → quote, an expand body, an extension body, a stacked and a side-by-side column, panned, the code's natural width never leaks into its container or the document", arguments: TK2NestedCode.proposalPlaces)
    func narrowContainerProposals(place: TK2NestedCode.Place) async throws {
        let pan: CGFloat = 60
        let pixel = 1 / TK2Parity.nativeScale
        let tolerance = TK2CodeParity.tolerance
        let rowWidth = place.windowWidth - 4 * ADFTheme.default.spacing
        var arms: [Geometry] = []
        for arm in [ADFTextRenderer.swiftUI, .textKit2] {
            let label = "\(place) \(arm)"
            let (_, hosted) = try await N.host(place, code: TK2CodeParity.wideBlock, renderer: arm)
            defer { hosted.close() }
            let scroll = try #require(N.codeScroll(hosted), "\(label): no code viewport")
            scroll.setContentOffset(CGPoint(x: pan, y: 0), animated: false)
            try await hosted.settle()
            let g = try N.geometry(hosted, label)
            arms.append(g)
            let row = N.codeRow(hosted, place.codeID)
            print("NESTED_CODE_PROPOSAL place=\(place) arm=\(arm) viewport=\(N.n(g.viewport.minX)),\(N.n(g.viewport.width))x\(N.n(g.viewport.height)) content=\(N.n(g.content.width))x\(N.n(g.content.height)) offset=\(N.n(g.offset)) document=\(N.n(g.documentContent.width))/\(N.n(g.documentBounds.width)) row=\(row.map { "\(N.n($0.bounds.width))x\(N.n($0.bounds.height))" } ?? "-") os=\(TK2Parity.osVersion)")

            // The pan holds at a nonzero offset.
            #expect(abs(g.offset - pan) <= pixel, "\(label): offset \(g.offset), panned \(pan)")
            // The viewport is the container's: inside the document's row,
            // narrower than the code it scrolls.
            #expect(g.viewport.width <= rowWidth + tolerance, "\(label): viewport \(g.viewport.width) pt in a \(rowWidth) pt row")
            #expect(g.viewport.minX >= -tolerance && g.viewport.maxX <= place.windowWidth + tolerance, "\(label): viewport \(g.viewport)")
            #expect(g.content.width > g.viewport.width + pan, "\(label): content \(g.content.width) pt is the code's natural width, wider than the viewport \(g.viewport.width)")
            // The document never scrolls sideways.
            #expect(g.documentContent.width <= g.documentBounds.width + tolerance, "\(label): document content \(g.documentContent.width) pt in \(g.documentBounds.width)")

            if arm == .textKit2, place.migrates {
                let row = try #require(row, "\(label): no TextKit 2 row for \(place.codeID)")
                #expect(row.ownerKind == .code && row.containerContext == .container, "\(label): \(row.ownerKind) \(row.containerContext)")
                // The row keeps its natural size, laid out unbounded: the
                // container's proposal never reaches the code's layout.
                let natural = row.measuredSize(forProposedWidth: nil)
                #expect(abs(row.bounds.width - natural.width) <= tolerance && abs(row.bounds.height - natural.height) <= tolerance,
                        "\(label): row \(row.bounds.size), natural \(natural)")
                #expect(row.cachedWidths == [.infinity], "\(label): cached widths \(row.cachedWidths)")
                #expect(g.content.width >= row.bounds.width, "\(label): content \(g.content.width) narrower than the row \(row.bounds.width)")
                let viewport = try #require(N.codeScroll(hosted))
                #expect(row.isDescendant(of: viewport), "\(label): the row is in the code's viewport")
            } else {
                #expect(row == nil, "\(label): a TextKit 2 row for \(place.codeID)")
            }
        }
        let (a, b) = (arms[0], arms[1])
        let sameViewport = abs(a.viewport.minX - b.viewport.minX) <= pixel && abs(a.viewport.minY - b.viewport.minY) <= pixel
            && abs(a.viewport.width - b.viewport.width) <= pixel && abs(a.viewport.height - b.viewport.height) <= pixel
        #expect(sameViewport, "\(place): viewport swiftUI=\(a.viewport) textKit2=\(b.viewport)")
        #expect(abs(a.content.width - b.content.width) <= tolerance && abs(a.content.height - b.content.height) <= tolerance,
                "\(place): content swiftUI=\(a.content) textKit2=\(b.content)")
        #expect(abs(a.documentContent.height - b.documentContent.height) <= pixel,
                "\(place): document height swiftUI=\(a.documentContent.height) textKit2=\(b.documentContent.height)")
    }

    typealias Geometry = TK2NestedCode.Geometry

    // MARK: Copy

    /// Copy takes the prepared string (`CodeBlockView.copyCode`), the same
    /// `code` the leaf draws: the prepared code is the source's bytes, the
    /// TextKit 2 row draws exactly those, and, where the unit-test host
    /// exposes the Copy button to accessibility, activating it puts exactly
    /// those bytes on the pasteboard (the UI test
    /// `ContainerRendererUITests.testNestedCodePansAndCopiesExactBytes`
    /// copies through a real tap).
    @Test("copyBytesAreExact: nested code is drawn and copied as the source's exact bytes", arguments: TK2NestedCode.proposalPlaces)
    func copyBytesAreExact(place: TK2NestedCode.Place) async throws {
        let source = "let path = \"C:\\\\tmp\\\\nested\" // copy me exactly\n    print(path)   \n\n  }   // trailing spaces"
        let (model, hosted) = try await N.host(place, code: source, renderer: .textKit2)
        defer { hosted.close() }
        let prepared = try N.preparedCode(place, in: model)
        #expect(Array(String(prepared.characters).utf8) == Array(source.utf8), "\(place): prepared \(String(prepared.characters).debugDescription)")
        if place.migrates {
            let row = try #require(N.codeRow(hosted, place.codeID), "\(place): no TextKit 2 row")
            #expect(row.accessibilityLabel.map { Array($0.utf8) } == Array(source.utf8), "\(place): the row draws \(row.accessibilityLabel?.debugDescription ?? "nil")")
        } else {
            #expect(N.codeRow(hosted, place.codeID) == nil)
        }
        // The Copy button, where the host lists it. The pasteboard holds
        // this process's own sentinel first, so reading it never prompts.
        let pasteboard = UIPasteboard.general
        pasteboard.string = "nested-code-sentinel"
        let before = pasteboard.changeCount
        let copy = N.element(labeled: "Copy code", under: hosted.host.view)
        let activated = copy?.accessibilityActivate() ?? false
        try await hosted.settle()
        let changed = pasteboard.changeCount != before
        print("NESTED_CODE_COPY place=\(place) listed=\(copy != nil) activated=\(activated) changed=\(changed) os=\(TK2Parity.osVersion)")
        if changed {
            #expect(pasteboard.string.map { Array($0.utf8) } == Array(source.utf8), "\(place): copied \(pasteboard.string?.debugDescription ?? "nil")")
        }
    }

    // MARK: Switch and re-entry

    /// PR 3's E4 inside each container: the wide block panned 240 pt, then
    /// the document's renderer flipped four times; the viewport is found
    /// again after every flip, so a replaced scroll view fails too.
    @Test("offsetHoldsAcrossSwitch: a panned nested code block keeps its offset within 2 px across renderer flips", arguments: TK2NestedCode.proposalPlaces)
    func offsetHoldsAcrossSwitch(place: TK2NestedCode.Place) async throws {
        let pan: CGFloat = 240
        let (model, hosted) = try await N.host(place, code: TK2CodeParity.wideBlock, renderer: .swiftUI)
        defer { hosted.close() }
        let scale = hosted.window.traitCollection.displayScale
        let first = try #require(N.codeScroll(hosted), "\(place): no code viewport")
        try #require(first.contentSize.width - first.bounds.width >= pan, "\(place): scroll range \(first.contentSize.width - first.bounds.width) pt")
        first.setContentOffset(CGPoint(x: pan, y: 0), animated: false)
        try await hosted.settle()
        let start = try #require(N.codeScroll(hosted)).contentOffset.x
        #expect(abs(start - pan) * scale <= 2, "\(place): the pan did not hold before any flip: \(start)")
        var arm = ADFTextRenderer.swiftUI
        for flip in 1...4 {
            arm = arm == .swiftUI ? .textKit2 : .swiftUI
            hosted.show(N.view(model, arm, sideBySide: place.sideBySide))
            try await hosted.settle()
            try await N.waitForCode(hosted, place: place, row: arm == .textKit2 && place.migrates)
            let offset = try #require(N.codeScroll(hosted), "\(place) flip \(flip): no code viewport").contentOffset.x
            let drift = abs(offset - pan) * scale
            let codeRows = hosted.codeRows.count
            print("NESTED_CODE_FLIP place=\(place) flip=\(flip) arm=\(arm) offset=\(N.n(offset)) driftPx=\(N.n(drift)) codeRows=\(codeRows) os=\(TK2Parity.osVersion)")
            #expect(drift <= 2, "\(place) flip \(flip) to \(arm): offset \(offset), panned \(pan)")
            #expect(codeRows == (arm == .textKit2 && place.migrates ? 1 : 0), "\(place) flip \(flip) to \(arm): \(codeRows) TextKit 2 code rows")
        }
    }

    /// PR 3's offset contract inside each container: "C equals B". The wide
    /// block panned 240 pt, the document scrolled to its end (150
    /// paragraphs on) until the code's viewport has left the window, then
    /// back; the offset found on return under TextKit 2 (arm C) is the one
    /// SwiftUI (arm B) finds, within 2 px, whatever it is.
    @Test("reentryMatchesSwitchOff: after the code leaves the window and returns, arm C's offset equals arm B's", arguments: [TK2NestedCode.Place.panelQuote, .expandBody, .extensionBody, .stackedColumn])
    func reentryMatchesSwitchOff(place: TK2NestedCode.Place) async throws {
        let pan: CGFloat = 240
        var results: [ADFTextRenderer: (panned: CGFloat, returned: CGFloat, released: Bool)] = [:]
        var scale: CGFloat = 1
        for arm in [ADFTextRenderer.swiftUI, .textKit2] {
            let label = "\(place) \(arm)"
            let (_, hosted) = try await N.host(place, code: TK2CodeParity.wideBlock, renderer: arm, trailing: 150)
            defer { hosted.close() }
            scale = hosted.window.traitCollection.displayScale
            let scroll = try #require(N.codeScroll(hosted), "\(label): no code viewport")
            scroll.setContentOffset(CGPoint(x: pan, y: 0), animated: false)
            try await hosted.settle()
            let panned = try #require(N.codeScroll(hosted)).contentOffset.x
            // Away: to the document's end until the viewport has left.
            let document = try #require(N.documentScroll(hosted), "\(label): no document scroll view")
            var released = false
            for _ in 0..<12 {
                let end = max(0, document.contentSize.height - document.bounds.height)
                document.setContentOffset(CGPoint(x: 0, y: end), animated: false)
                try await hosted.settle()
                if N.codeScroll(hosted) == nil { released = true; break }
            }
            // Back to the top, until the viewport (and, on arm C, the row)
            // is in the window again.
            document.setContentOffset(.zero, animated: false)
            try await hosted.settle()
            try await N.waitForCode(hosted, place: place, row: arm == .textKit2 && place.migrates)
            let returned = try #require(N.codeScroll(hosted), "\(label): the code never came back").contentOffset.x
            if arm == .textKit2, place.migrates {
                #expect(N.codeRow(hosted, place.codeID) != nil, "\(label): no TextKit 2 row after the return")
            }
            results[arm] = (panned, returned, released)
            print("NESTED_CODE_REENTRY place=\(place) arm=\(arm) panned=\(N.n(panned)) released=\(released) returned=\(N.n(returned)) os=\(TK2Parity.osVersion)")
        }
        let b = try #require(results[.swiftUI]), c = try #require(results[.textKit2])
        #expect(abs(c.panned - b.panned) * scale <= 2, "\(place): the same pan gave \(c.panned) pt under TextKit 2, \(b.panned) pt under SwiftUI")
        #expect(abs(c.returned - b.returned) * scale <= 2, "\(place): after re-entry \(c.returned) pt under TextKit 2, \(b.returned) pt under SwiftUI: arm C must behave as arm B")
    }

    // MARK: Canvas gate and cost

    /// PR 3's over-budget text (400 lines of 60 columns: over the canvas
    /// bound at every size on 2x and 3x) in each container: eligible by
    /// content from iOS 26, gated where drawn (`CodeGate.canvas`), so no
    /// TextKit 2 row draws it while the document's root paragraph after it
    /// does. The fixtures' over-budget block (containers-parity
    /// KP-CODE-OVER, 0.78.1) sits in a panel beside a paragraph, a panel
    /// shape that keeps its body on SwiftUI, so this hosted case is the one
    /// that reaches the gate.
    @Test("overBudgetBlockFallsBack: an over-budget code block in a container is gated by the canvas bound and draws no TextKit 2 row", arguments: TK2NestedCode.gatePlaces)
    func overBudgetBlockFallsBack(place: TK2NestedCode.Place) async throws {
        let (model, hosted) = try await N.host(place, code: TK2CodeParity.overBudgetText, renderer: .textKit2, height: 2_400, drawsRow: false)
        defer { hosted.close() }
        let scale = hosted.window.traitCollection.displayScale
        let prepared = try N.preparedCode(place, in: model)
        // Content-eligible: only the gate keeps it.
        #expect(TK2CodeLogic.reason(TextKit2Eligibility.codeVerdict(prepared)) == nil)
        #expect(TextKit2Scope.codeGate(prepared, sizeCategory: .large, legibilityWeight: .regular, displayScale: scale, layoutDirection: .leftToRight) == .canvas)
        #expect(N.codeRow(hosted, place.codeID) == nil, "\(place): the over-budget block drew on TextKit 2")
        #expect(hosted.codeRows.isEmpty, "\(place): code rows \(hosted.codeRows.compactMap(\.ownerID))")
        // The switch reached the container: its prose before the code (the
        // 400-line block pushes everything after it out of the window).
        if [.quote, .expandBody, .extensionBody].contains(place) {
            #expect(hosted.owners.contains("0.0.0") == TextKit2Eligibility.containerTextMatchesText, "\(place): the container's prose \(hosted.owners.sorted())")
        }
        if place != .expandBody {
            // The walk and the admission split (an expand's body is not
            // walked: `unpreparedExpands`).
            var verdicts: [TextKit2Eligibility.Fallback?] = []
            TextKit2Scope.forEachLeaf(in: model.blocks) { leaf in
                if leaf.position == .containerCode, leaf.ownerID == place.codeID { verdicts.append(TK2CodeLogic.reason(leaf.verdict)) }
            }
            let want: TextKit2Eligibility.Fallback? = TextKit2Eligibility.containerTextMatchesText ? nil : .osGatedContainer
            #expect(verdicts == [want], "\(place): \(verdicts)")
            let admission = ADFTextRenderer.textKit2CodeAdmission(
                of: model.blocks, dynamicTypeSize: .large, legibilityWeight: .regular, displayScale: scale, layoutDirection: .leftToRight
            )
            let gated = TextKit2Eligibility.containerTextMatchesText ? 1 : 0
            #expect(admission.nestedCodeAdmitted == 0 && admission.nestedCodeGated == gated, "\(place): \(admission)")
        }
    }

    /// Several code blocks in one quote are all built at once (a quote is
    /// one lazy row): PR 3's caps are per block, so the canvases add up.
    /// Six admitted blocks and one over budget: six live rows, the
    /// admission split six and one, and the summed nominal canvas bytes of
    /// the six, each row within its bound. Recorded, not capped in
    /// aggregate (plan §4.7: an aggregate mitigation is its own design).
    @Test("eagerMultiCodeContainer: a quote of seven code blocks builds six TextKit 2 rows at once; admitted, gated and the summed canvas bytes are recorded")
    func eagerMultiCodeContainer() async throws {
        let texts = (0..<6).map { "let block\($0) = \($0)\n" + TK2CodeParity.eightLines } + [TK2CodeParity.overBudgetText]
        let quote = TK2CodeLogic.node("blockquote", [TK2CodeLogic.paragraph("Seven code blocks follow.")] + texts.map { TK2CodeLogic.code($0, language: "swift") })
        let model = try await TK2CodeLogic.loadedModel(try TK2CodeLogic.document([quote, TK2CodeLogic.paragraph("After the quote.")]))
        let ids = (1...7).map { "0.0.\($0)" }
        let hosted = TK2CodeLogic.Hosted(N.view(model, .textKit2, sideBySide: false), size: CGSize(width: 390, height: 1_600))
        defer { hosted.close() }
        try await hosted.settle()
        let migrates = TextKit2Eligibility.containerTextMatchesText
        for _ in 0..<250 where migrates && hosted.codeRows.count < 6 {
            hosted.window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        try await hosted.settle()
        let scale = hosted.window.traitCollection.displayScale

        let coverage = ADFTextRenderer.textKit2Coverage(of: model.blocks)
        #expect(coverage.eligibleNestedCode == (migrates ? 7 : 0) && coverage.fallbackNestedCode == (migrates ? 0 : 7), "\(coverage)")
        let admission = ADFTextRenderer.textKit2CodeAdmission(
            of: model.blocks, dynamicTypeSize: .large, legibilityWeight: .regular, displayScale: scale, layoutDirection: .leftToRight
        )
        #expect(admission.nestedCodeAdmitted == (migrates ? 6 : 0) && admission.nestedCodeGated == (migrates ? 1 : 0), "\(admission)")
        #expect(admission.admittedCodeRoots == 0 && admission.gatedCodeRoots == 0)

        let rows = hosted.codeRows
        #expect(Set(rows.compactMap(\.ownerID)) == (migrates ? Set(ids.prefix(6)) : []), "live code rows \(rows.compactMap(\.ownerID).sorted())")
        var bytes = 0
        for id in ids.prefix(6) {
            let code = try N.preparedCodeBlock(id, in: model.blocks)
            let bound = try #require(TextKit2Scope.codeCanvasBound(code, sizeCategory: .large, legibilityWeight: .regular, displayScale: scale), "\(id): no admitted bound")
            bytes += bound.nominalBytes
            if let row = rows.first(where: { $0.ownerID == id }) {
                #expect(row.bounds.width * scale <= CGFloat(bound.pixelWidth) && row.bounds.height * scale <= CGFloat(bound.pixelHeight),
                        "\(id): row \(row.bounds.size) at \(scale)x, bound \(bound.pixelWidth)x\(bound.pixelHeight) px")
            }
        }
        let over = try N.preparedCodeBlock(ids[6], in: model.blocks)
        #expect(TextKit2Scope.codeCanvasBound(over, sizeCategory: .large, legibilityWeight: .regular, displayScale: scale) == nil)
        #expect(bytes <= 6 * TextKit2Scope.maximumCodeCanvasBytes)
        print("NESTED_CODE_EAGER rows=\(rows.count) admitted=\(admission.nestedCodeAdmitted) gated=\(admission.nestedCodeGated) canvasBytes=\(bytes) perBlockCap=\(TextKit2Scope.maximumCodeCanvasBytes) scale=\(TK2CodeParity.scaleText(scale)) os=\(TK2Parity.osVersion)")
    }

    // MARK: Columns

    /// A code block in a zero-percent column beside a full one. Side by
    /// side the column keeps it on SwiftUI (C32) and both arms lay it out
    /// alike; stacked (a compact width) the column has the row's width and
    /// the code draws on TextKit 2 (from iOS 26) with the switch-off
    /// geometry.
    @Test("codeInZeroPercentColumnMatchesSwitchOff: code in a zero-percent column has the switch-off geometry side by side and stacked")
    func codeInZeroPercentColumnMatchesSwitchOff() async throws {
        let column = { (width: Double, children: [[String: Any]]) in TK2CodeLogic.node("layoutColumn", attrs: ["width": width], children) }
        let section = TK2CodeLogic.node("layoutSection", [
            column(0, [TK2CodeLogic.code(TK2CodeParity.eightLines, language: "swift")]),
            column(100, [TK2CodeLogic.paragraph("The full column beside a zero-percent one.")]),
        ])
        let data = try TK2CodeLogic.document([section, TK2CodeLogic.paragraph("After the section.")])
        let code = "0.0.0.0"
        let pixel = 1 / TK2Parity.nativeScale
        for sideBySide in [true, false] {
            let width: CGFloat = sideBySide ? 820 : 390
            var arms: [Geometry] = []
            for arm in [ADFTextRenderer.swiftUI, .textKit2] {
                let label = "\(sideBySide ? "side by side" : "stacked") \(arm)"
                let model = try await TK2CodeLogic.loadedModel(data)
                let hosted = TK2CodeLogic.Hosted(N.view(model, arm, sideBySide: sideBySide), size: CGSize(width: width, height: 1_600))
                defer { hosted.close() }
                try await hosted.settle()
                let migrates = arm == .textKit2 && !sideBySide && TextKit2Eligibility.containerTextMatchesText
                for _ in 0..<250 where N.codeScroll(hosted) == nil || (migrates && N.codeRow(hosted, code) == nil) {
                    hosted.window.layoutIfNeeded()
                    try await Task.sleep(for: .milliseconds(20))
                }
                try await hosted.settle()
                let g = try N.geometry(hosted, label)
                arms.append(g)
                print("NESTED_CODE_ZERO mode=\(label) viewport=\(N.n(g.viewport.minX)),\(N.n(g.viewport.width))x\(N.n(g.viewport.height)) content=\(N.n(g.content.width))x\(N.n(g.content.height)) document=\(N.n(g.documentContent.height)) os=\(TK2Parity.osVersion)")
                #expect((N.codeRow(hosted, code) != nil) == migrates, "\(label): TextKit 2 row \(N.codeRow(hosted, code) != nil)")
                #expect(g.documentContent.width <= g.documentBounds.width + TK2CodeParity.tolerance, "\(label): document content \(g.documentContent.width)")
            }
            let (a, b) = (arms[0], arms[1])
            #expect(abs(a.viewport.minX - b.viewport.minX) <= pixel && abs(a.viewport.minY - b.viewport.minY) <= pixel
                    && abs(a.viewport.width - b.viewport.width) <= pixel && abs(a.viewport.height - b.viewport.height) <= pixel,
                    "\(sideBySide ? "side by side" : "stacked"): viewport swiftUI=\(a.viewport) textKit2=\(b.viewport)")
            #expect(abs(a.content.width - b.content.width) <= TK2CodeParity.tolerance && abs(a.content.height - b.content.height) <= TK2CodeParity.tolerance,
                    "\(sideBySide ? "side by side" : "stacked"): content swiftUI=\(a.content) textKit2=\(b.content)")
            #expect(abs(a.documentContent.height - b.documentContent.height) <= pixel,
                    "\(sideBySide ? "side by side" : "stacked"): document height swiftUI=\(a.documentContent.height) textKit2=\(b.documentContent.height)")
        }
    }

    // MARK: Container proof

    /// Container proof comes only from rows whose owner kind is not code
    /// (plan §6.4): a quote holding only code draws one code row, which
    /// is in the code record and counts as code, never in the container
    /// record or the container counters; the coverage counts it as nested
    /// code, not as a container leaf.
    @Test("nestedCodeDoesNotSatisfyContainerProof: a nested code row counts as code only: the container counters and record never include it")
    func nestedCodeDoesNotSatisfyContainerProof() async throws {
        let diagnostics = TextKit2Diagnostics.shared
        let model = try await TK2CodeLogic.loadedModel(try TK2CodeLogic.document([
            TK2CodeLogic.node("blockquote", [TK2CodeLogic.code("let onlyCode = 1", language: "swift")]),
            TK2CodeLogic.paragraph("A root paragraph after the quote."),
        ]))
        let code = "0.0.0"
        let migrates = TextKit2Eligibility.containerTextMatchesText
        let coverage = ADFTextRenderer.textKit2Coverage(of: model.blocks)
        #expect(coverage.eligibleContainerLeaves == 0 && coverage.fallbackContainerLeaves == 0, "\(coverage)")
        #expect(coverage.eligibleNestedCode + coverage.fallbackNestedCode == 1 && coverage.eligibleNestedCode == (migrates ? 1 : 0), "\(coverage)")

        let hosted = TK2CodeLogic.Hosted(N.view(model, .textKit2, sideBySide: false))
        defer { hosted.close() }
        try await hosted.settle()
        for _ in 0..<250 where migrates && N.codeRow(hosted, code) == nil {
            hosted.window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        try await hosted.settle()
        // No suspension from here to the last read.
        let row = N.codeRow(hosted, code)
        #expect((row != nil) == migrates, "nested code row \(row != nil)")
        #expect(hosted.rows.allSatisfy { $0.containerContext != .container || $0.ownerKind == .code }, "only code below the quote")
        #expect(ADFTextRenderer.textKit2ContainerRowDraws[code] == nil, "code is never container proof")
        #expect((ADFTextRenderer.textKit2CodeRowDraws[code] != nil) == migrates, "nested code is in the code record")
        if let row {
            #expect(row.ownerKind == .code && row.containerContext == .container)
            let containerNative = diagnostics.containerNativeDrawCount
            let containerTK1 = diagnostics.containerTextKit1DrawCount
            let codeNative = diagnostics.codeNativeDrawCount
            let listed = ADFTextRenderer.textKit2CodeRowDraws[code] ?? 0
            TK2CodeLogic.draw(row)
            #expect(diagnostics.codeNativeDrawCount - codeNative == 1, "the nested code row's draw is a code draw")
            #expect(ADFTextRenderer.textKit2CodeRowDraws[code] == listed + 1)
            #expect(diagnostics.containerNativeDrawCount == containerNative && diagnostics.containerTextKit1DrawCount == containerTK1,
                    "a nested code row's draw is never a container draw")
        }

        // The live counters, on rows made here: a code row below a
        // container counts as code, not as container text; the same row
        // with a prose owner kind counts as container text. No suspension.
        let liveContainer = diagnostics.liveContainerRowCount
        let liveCode = diagnostics.liveCodeRowCount
        autoreleasepool {
            let probe = TextKit2RowView()
            probe.ownerKind = .code
            probe.containerContext = .container
            #expect(diagnostics.liveCodeRowCount - liveCode == 1 && diagnostics.liveContainerRowCount == liveContainer,
                    "a nested code row: code \(diagnostics.liveCodeRowCount - liveCode), container \(diagnostics.liveContainerRowCount - liveContainer)")
            probe.ownerKind = .root
            #expect(diagnostics.liveCodeRowCount == liveCode && diagnostics.liveContainerRowCount - liveContainer == 1)
            withExtendedLifetime(probe) {}
        }
        #expect(diagnostics.liveCodeRowCount == liveCode && diagnostics.liveContainerRowCount == liveContainer)
    }

    // MARK: Negatives

    /// Code in a list item stays SwiftUI (P5): the list row resets the
    /// renderer for an item holding a non-text block
    /// (`TextKit2Scope.rowKeepsRenderer`), at the top level and in a quote,
    /// with the production allow list and with every kind allowed. The
    /// walk never visits that code. Controls: a top-level code block (a
    /// row on any OS) and a quote's code (a row from iOS 26).
    @Test("codeInListItemStaysSwiftUI: code in a list item, at the top level or in a quote, draws no TextKit 2 row")
    func codeInListItemStaysSwiftUI() async throws {
        let item = { (children: [[String: Any]]) in TK2CodeLogic.node("listItem", children) }
        let list = { (name: String) in
            TK2CodeLogic.node("bulletList", [
                item([TK2CodeLogic.paragraph("\(name) item with code"), TK2CodeLogic.code("let inItem = \"\(name)\"")]),
                item([TK2CodeLogic.code("let codeFirst = \"\(name)\"")]),
            ])
        }
        let content = [
            list("root"),
            TK2CodeLogic.node("blockquote", [TK2CodeLogic.paragraph("A quote holding a list."), list("quoted")]),
            TK2CodeLogic.node("blockquote", [TK2CodeLogic.code("let inQuote = 1")]),
            TK2CodeLogic.code("let top = 2"),
        ]
        let model = try await TK2CodeLogic.loadedModel(try TK2CodeLogic.document(content))
        let listCode = Self.listItemCode(model.blocks)
        #expect(listCode.count == 4, "the list items' code blocks are prepared: \(listCode.sorted())")
        var walked: Set<String> = []
        TextKit2Scope.forEachLeaf(in: model.blocks) { walked.insert($0.ownerID) }
        #expect(walked.isDisjoint(with: listCode), "the walk visits list-item code: \(walked.intersection(listCode).sorted())")

        for allowed in [nil, Set(TextKit2BlockKind.allCases)] {
            let document = TK2CodeLogic.documentView(model, .textKit2)
                .transformEnvironment(\.adfContainerChildKinds) { kinds in
                    if let allowed { kinds = allowed }
                }
                .dynamicTypeSize(.large)
            let hosted = TK2CodeLogic.Hosted(document, size: CGSize(width: 390, height: 2_400))
            defer { hosted.close() }
            try await hosted.settle()
            let owners = hosted.owners
            let label = allowed == nil ? "production" : "every kind"
            #expect(owners.isDisjoint(with: listCode), "\(label): list-item code drew on TextKit 2: \(owners.intersection(listCode).sorted())")
            #expect(owners.contains("0.3"), "\(label): the top-level code block is the control")
            #expect(owners.contains("0.2.0") == TextKit2Eligibility.containerTextMatchesText, "\(label): the quote's code block")
        }
    }

    /// Every code block inside a list row's trailing blocks, at any depth.
    static func listItemCode(_ blocks: [RenderBlock], inList: Bool = false) -> Set<String> {
        var found: Set<String> = []
        for block in blocks {
            switch block.kind {
            case .codeBlock: if inList { found.insert(block.id) }
            case .listRows(let rows): found.formUnion(listItemCode(rows.flatMap(\.trailingBlocks), inList: true))
            case .panel(_, let children), .quote(let children), .extensionPlaceholder(_, let children):
                found.formUnion(listItemCode(children, inList: inList))
            case .layoutColumns(let columns): found.formUnion(listItemCode(columns.flatMap(\.blocks), inList: inList))
            default: continue
            }
        }
        return found
    }

    /// A plugin that hosts the real `CodeBlockView` never gets the
    /// renderer: at the top level (`inheritsRenderer(.custom)` is false), in
    /// a quote, a panel and a stacked column (`.custom` is in no allow
    /// list), its code stays SwiftUI while the code beside it migrates.
    @Test("codeInPluginStaysSwiftUI: a plugin's own code block draws no TextKit 2 row, at the top level or in a container")
    func codeInPluginStaysSwiftUI() async throws {
        let prepared = try TK2Parity.codeParts(try await TK2Parity.codeBlock("let inPlugin = 1", language: "swift")).code
        let plugin = { (name: String) -> [String: Any] in ["type": "blockCard", "attrs": ["url": "nested-code:\(name)"]] }
        let column = { (children: [[String: Any]]) in TK2CodeLogic.node("layoutColumn", attrs: ["width": 50], children) }
        let content: [[String: Any]] = [
            plugin("root"),
            TK2CodeLogic.node("blockquote", [TK2CodeLogic.code("let besidePlugin = 2"), plugin("quoted")]),
            TK2CodeLogic.node("panel", attrs: ["panelType": "info"], [plugin("paneled")]),
            TK2CodeLogic.node("layoutSection", [column([plugin("column")]), column([TK2CodeLogic.paragraph("Beside the plugin.")])]),
            TK2CodeLogic.code("let top = 3"),
        ]
        let model = ADFDocumentModel(customRenderers: [NestedCodePlugin(code: prepared)])
        model.load(data: try TK2CodeLogic.document(content))
        for _ in 0..<500 where model.phase != .ready {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.phase == .ready)
        let hosted = TK2CodeLogic.Hosted(N.view(model, .textKit2, sideBySide: false), size: CGSize(width: 390, height: 2_400))
        defer { hosted.close() }
        try await hosted.settle()
        // Every plugin drew its code block: four plugin viewports and the
        // two other code blocks'.
        #expect(TK2Parity.nestedScrollViews(in: hosted.host.view).count >= 6, "\(TK2Parity.nestedScrollViews(in: hosted.host.view).count) code viewports")
        let owners = hosted.owners
        let pluginRows = owners.filter { $0.hasPrefix("plugin-code:") }
        #expect(pluginRows.isEmpty, "a plugin's code drew on TextKit 2: \(pluginRows.sorted())")
        #expect(owners.contains("0.4"), "the top-level code block is the control")
        #expect(owners.contains("0.1.0") == TextKit2Eligibility.containerTextMatchesText, "the quote's own code block beside the plugin")
    }

    // MARK: OS gate

    /// Before iOS 26 nested code is `osGatedContainer` first, whatever its
    /// content (P14): the walk counts it as fallback nested code and no
    /// TextKit 2 row draws it in any container, while top-level code keeps
    /// its row. From iOS 26 the same OS check, injected as false into
    /// `containerCodeVerdict`, gives the same reason, and true gives PR 3's
    /// content verdict unchanged; top-level code is never gated by it.
    @Test("nestedCodeBeforeIOS26StaysSwiftUI: osGatedContainer before iOS 26 (injected on 26 and later), in every container; top-level code is never gated")
    func nestedCodeBeforeIOS26StaysSwiftUI() async throws {
        let eligible = TK2CodeLogic.stamped("let a = 1")
        let tabbed = TK2CodeLogic.stamped("a\tb")
        for context in [TextKit2ContainerContext.container, .caption] {
            for text in [eligible, tabbed, AttributedString()] {
                #expect(TK2CodeLogic.reason(TextKit2Eligibility.containerCodeVerdict(text, context: context, matchesText: false)) == .osGatedContainer,
                        "\(context) \(String(text.characters).debugDescription): the OS gate comes first")
                #expect(TK2CodeLogic.reason(TextKit2Eligibility.containerCodeVerdict(text, context: context, matchesText: true))
                        == TK2CodeLogic.reason(TextKit2Eligibility.codeVerdict(text)), "\(context): PR 3's content verdict")
            }
        }
        #expect(TK2CodeLogic.reason(TextKit2Eligibility.containerCodeVerdict(eligible, context: .none, matchesText: false)) == nil)
        let gated = !TextKit2Eligibility.containerTextMatchesText
        let want: TextKit2Eligibility.Fallback? = gated ? .osGatedContainer : nil
        #expect(TK2CodeLogic.reason(TextKit2Eligibility.verdict(eligible, owner: .code, context: .container)) == want)
        if #available(iOS 26.0, *) {
            #expect(TextKit2Eligibility.containerTextMatchesText)
        } else {
            #expect(!TextKit2Eligibility.containerTextMatchesText)
        }

        // Every container in one document: a quote, a panel, a panel →
        // quote, an extension body, a stacked column and an open expand,
        // after a top-level code block (the control).
        let column = { (children: [[String: Any]]) in TK2CodeLogic.node("layoutColumn", attrs: ["width": 50], children) }
        let prose = TK2CodeLogic.paragraph("Prose before the code.")
        let content: [[String: Any]] = [
            TK2CodeLogic.code("let root = 0"),
            TK2CodeLogic.node("blockquote", [TK2CodeLogic.code("let inQuote = 1")]),
            TK2CodeLogic.node("panel", attrs: ["panelType": "info"], [TK2CodeLogic.code("let inPanel = 2")]),
            TK2CodeLogic.node("panel", attrs: ["panelType": "note"], [TK2CodeLogic.node("blockquote", [TK2CodeLogic.code("let inPanelQuote = 3")])]),
            TK2CodeLogic.node("bodiedExtension", attrs: ["extensionType": "com.example.nested-code", "extensionKey": "nested-code"], [prose, TK2CodeLogic.code("let inExtension = 4")]),
            TK2CodeLogic.node("layoutSection", [column([TK2CodeLogic.code("let inColumn = 5")]), column([prose])]),
            TK2CodeLogic.node("expand", attrs: ["title": "Gated"], [prose, TK2CodeLogic.code("let inExpand = 6")]),
        ]
        let walkedNested = ["0.1.0", "0.2.0", "0.3.0.0", "0.4.1", "0.5.0.0"]
        let nested = Set(walkedNested + ["0.6.1"])
        let model = try await TK2CodeLogic.loadedModel(try TK2CodeLogic.document(content))
        var reasons: [String: TextKit2Eligibility.Fallback?] = [:]
        TextKit2Scope.forEachLeaf(in: model.blocks) { leaf in
            if leaf.position == .containerCode { reasons.updateValue(TK2CodeLogic.reason(leaf.verdict), forKey: leaf.ownerID) }
        }
        #expect(Set(reasons.keys) == Set(walkedNested), "walked nested code \(reasons.keys.sorted())")
        #expect(reasons.values.allSatisfy { $0 == want }, "\(reasons)")
        let coverage = ADFTextRenderer.textKit2Coverage(of: model.blocks)
        #expect(coverage.eligibleNestedCode == (gated ? 0 : 5) && coverage.fallbackNestedCode == (gated ? 5 : 0), "\(coverage)")
        #expect(coverage.eligibleCodeRoots == 1 && coverage.fallbackCodeRoots == 0, "the root sum: \(coverage)")

        model.expandedBlocks.insert("0.6")
        let hosted = TK2CodeLogic.Hosted(N.view(model, .textKit2, sideBySide: false), size: CGSize(width: 390, height: 2_400))
        defer { hosted.close() }
        try await hosted.settle()
        // The expand's code viewport: the root's, five nested, the expand's.
        for _ in 0..<250 where TK2Parity.nestedScrollViews(in: hosted.host.view).count < 7 || (!gated && !hosted.owners.contains("0.6.1")) {
            hosted.window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        try await hosted.settle()
        #expect(TK2Parity.nestedScrollViews(in: hosted.host.view).count >= 7, "every code block is on screen")
        let codeOwners = Set(hosted.codeRows.compactMap(\.ownerID))
        print("NESTED_CODE_OS gated=\(gated) codeRows=\(codeOwners.sorted()) os=\(TK2Parity.osVersion)")
        #expect(codeOwners == (gated ? ["0.0"] : nested.union(["0.0"])), "code rows \(codeOwners.sorted())")
    }
}

extension TK2NestedCode {
    /// The prepared code of the code block `id` anywhere in `blocks`.
    static func preparedCodeBlock(_ id: String, in blocks: [RenderBlock]) throws -> AttributedString {
        guard let block = TextKit2ContainerCoverageTests.find(id, in: blocks), case .codeBlock(_, let code) = block.kind else {
            throw TestFailure("no code block \(id)")
        }
        return code
    }
}
#endif
