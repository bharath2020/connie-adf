import Foundation
import SwiftUI
import Testing
import ADFModel
import ADFPreparation
@_spi(ADFDiagnostics) @testable import ADFRendering

/// What one existing fixture's structure gives (`TextKit2CodeCoverageTests`).
struct TK2CodeCoveragePin: Sendable {
    /// Prepared top-level blocks.
    let blocks: Int
    /// Top-level code blocks eligible by content, and falling back by
    /// content. Together: the top-level `codeBlock` nodes.
    let eligibleCode: Int
    let fallbackCode: Int
    /// The text counts from iOS 26 (before it the list leaves that are
    /// eligible here fall back, `TextKit2Eligibility.listsMatchText`).
    let eligibleRoots: Int
    let eligibleTextLeaves: Int
    let fallbackTextLeaves: Int
}

/// The pins of one of PR 3's generated code fixtures, counted from its JSON
/// by a standalone script outside the project's code (Python, `json.load`;
/// the shape, content verdict and canvas bound re-derived from their
/// documented rules, the bound at SF Mono's font-file metrics), not by the
/// coverage walk.
struct TK2CodeNewFixturePins {
    /// Top-level nodes (each prepares to one top-level block).
    var blocks: Int
    /// Top-level `codeBlock` nodes.
    var codeBlocks: Int
    /// `eligibleCodeRoots` from iOS 26, and before it (where a block ending
    /// in two or more line feeds falls back as `.trailingBreaks`).
    var eligible: Int
    var eligibleBeforeIOS26: Int
    /// `admittedCodeRoots` at Large, no Bold Text, left to right, on a 3x
    /// and on a 2x display, on iOS 26 or later.
    var admittedAt3x: Int
    var admittedAt2x: Int
    /// Code blocks prepared below the top level (out of scope: in neither
    /// code count). An expand's body is not prepared with the document.
    var nestedCode: Int
}

/// Code in the static coverage (plan 4): top-level code blocks have two
/// counts of their own, `eligibleCodeRoots` and `fallbackCodeRoots`, which
/// sum to the top-level code blocks, and they join none of the text counts
/// PR 2 pinned.
///
/// How the pins were counted: from each fixture's JSON, by a standalone walk
/// outside the project's code (Python, `json.load`), not by the coverage
/// walk. Top-level code: the `codeBlock` nodes directly in the document's
/// `content`, each one's text checked for emptiness, a scalar outside
/// U+0020 to U+007E and LF, and trailing line feeds. kitchen-sink has one
/// (index 12, two lines, 28 columns); stress-1k has 80 and stress-5k 400
/// (index `i` with `i % 10 == 5` and `i % 50 != 45`; at most 8 lines and 39
/// columns; the other code blocks sit in expands); lists-parity has none
/// (its two code blocks sit in list items `0.8.12` and `0.10.2`) and
/// list-dense none. Every one of them is non-empty printable ASCII and line
/// feeds with no trailing line feed, so all are eligible on every OS.
///
/// The text counts of kitchen-sink, lists-parity and list-dense are
/// `TextKit2ListCoverageTests`' pins; stress-5k's are
/// `TextKit2FixtureSweepTests`' (2,400 roots, 7,543 list leaves). stress-1k
/// had no pin: 480 top-level paragraphs and headings and 1,542 list
/// paragraphs, none with an atom, counted the same way (the count that
/// reproduces stress-5k's pins).
@Suite("TextKit 2 code coverage")
@MainActor
struct TextKit2CodeCoverageTests {
    nonisolated static let fixtures = ["kitchen-sink", "stress-1k", "stress-5k", "lists-parity", "list-dense"]

    nonisolated static let pins: [String: TK2CodeCoveragePin] = [
        "kitchen-sink": TK2CodeCoveragePin(
            blocks: 38, eligibleCode: 1, fallbackCode: 0, eligibleRoots: 10, eligibleTextLeaves: 18, fallbackTextLeaves: 2
        ),
        "stress-1k": TK2CodeCoveragePin(
            blocks: 1_000, eligibleCode: 80, fallbackCode: 0, eligibleRoots: 480, eligibleTextLeaves: 2_022, fallbackTextLeaves: 0
        ),
        "stress-5k": TK2CodeCoveragePin(
            blocks: 5_000, eligibleCode: 400, fallbackCode: 0, eligibleRoots: 2_400, eligibleTextLeaves: 9_943, fallbackTextLeaves: 0
        ),
        "lists-parity": TK2CodeCoveragePin(
            blocks: 21, eligibleCode: 0, fallbackCode: 0, eligibleRoots: 8, eligibleTextLeaves: 48, fallbackTextLeaves: 6
        ),
        "list-dense": TK2CodeCoveragePin(
            blocks: 600, eligibleCode: 0, fallbackCode: 0, eligibleRoots: 0, eligibleTextLeaves: 3_537, fallbackTextLeaves: 395
        ),
    ]

    nonisolated static func isCode(_ block: RenderBlock) -> Bool {
        if case .codeBlock = block.kind { return true }
        return false
    }

    @Test("existing fixtures: the code roots are pinned and sum to the top-level code blocks; PR 2's text counts did not change",
          arguments: fixtures)
    func existingFixtures(fixture: String) async throws {
        let pin = try #require(Self.pins[fixture])
        let blocks = try await TextKit2ListCoverageTests.blocks(fixture)
        let coverage = ADFTextRenderer.textKit2Coverage(of: blocks)
        #expect(blocks.count == pin.blocks)

        // Code: its two counts, summing to the top-level code blocks (found
        // here by kind, not by the walk).
        let codeBlocks = blocks.filter { Self.isCode($0) }
        #expect(coverage.eligibleCodeRoots == pin.eligibleCode, "eligibleCodeRoots \(coverage.eligibleCodeRoots)")
        #expect(coverage.fallbackCodeRoots == pin.fallbackCode, "fallbackCodeRoots \(coverage.fallbackCodeRoots)")
        #expect(coverage.eligibleCodeRoots + coverage.fallbackCodeRoots == codeBlocks.count)
        #expect(codeBlocks.count == pin.eligibleCode + pin.fallbackCode, "\(codeBlocks.count) top-level code blocks")
        // The walk visits each of them once, as a code root, in order.
        var codeLeaves: [String] = []
        TextKit2Scope.forEachLeaf(in: blocks) { leaf in
            if leaf.position == .codeRoot { codeLeaves.append(leaf.ownerID) }
        }
        #expect(codeLeaves == codeBlocks.map(\.id))

        // Text: PR 2's pins, unchanged. Code joined none of them.
        let lists = TextKit2Eligibility.listsMatchText
        let eligibleLeaves = lists ? pin.eligibleTextLeaves : pin.eligibleRoots
        let gatedLeaves = lists ? 0 : pin.eligibleTextLeaves - pin.eligibleRoots
        #expect(coverage.eligibleRoots == pin.eligibleRoots, "eligibleRoots \(coverage.eligibleRoots)")
        #expect(coverage.eligibleTextLeaves == eligibleLeaves, "eligibleTextLeaves \(coverage.eligibleTextLeaves)")
        #expect(coverage.fallbackTextLeaves == pin.fallbackTextLeaves + gatedLeaves, "fallbackTextLeaves \(coverage.fallbackTextLeaves)")
        // The legacy root count still holds every top-level code block.
        #expect(coverage.fallbackRoots == blocks.count - pin.eligibleRoots)
        #expect(coverage.eligibleTextLeaves + coverage.fallbackTextLeaves
            == coverage.eligibleRoots + coverage.textFallbackRoots + coverage.listLeaderLeaves + coverage.listTrailingLeaves)

        // Counted apart: the same document without its code blocks has the
        // same counts, but for the code roots and the legacy root total.
        let withoutCode = blocks.filter { !Self.isCode($0) }
        var expected = ADFTextRenderer.textKit2Coverage(of: withoutCode)
        #expect(expected.eligibleCodeRoots == 0 && expected.fallbackCodeRoots == 0)
        expected.eligibleCodeRoots = coverage.eligibleCodeRoots
        expected.fallbackCodeRoots = coverage.fallbackCodeRoots
        expected.fallbackRoots += codeBlocks.count
        #expect(coverage == expected)
    }

    @Test("a theme whose code font is a raw SwiftUI Font: every top-level code block is a fallback code root")
    func rawCodeFontTheme() async throws {
        let theme = ADFTheme(code: .system(size: 13, design: .monospaced))
        #expect(theme.codeFontSpec == nil)
        let doc = try await ADFParser().parse(try TextKit2ListCoverageTests.fixtureData("stress-1k"))
        let coverage = ADFTextRenderer.textKit2Coverage(of: DocumentPreparer(theme: theme).prepare(doc))
        #expect(coverage.eligibleCodeRoots == 0)
        #expect(coverage.fallbackCodeRoots == 80)
        let admission = ADFTextRenderer.textKit2CodeAdmission(
            of: DocumentPreparer(theme: theme).prepare(doc),
            dynamicTypeSize: .large, legibilityWeight: nil, displayScale: 3, layoutDirection: .leftToRight
        )
        #expect(admission.admittedCodeRoots == 0 && admission.gatedCodeRoots == 0, "admission counts eligible code only")
    }

    @Test("code admission: admitted and gated sum to the eligible code roots; nothing is admitted without UIKit")
    func admissionSums() async throws {
        let blocks = try await TextKit2ListCoverageTests.blocks("kitchen-sink")
        let eligible = ADFTextRenderer.textKit2Coverage(of: blocks).eligibleCodeRoots
        let admission = ADFTextRenderer.textKit2CodeAdmission(
            of: blocks, dynamicTypeSize: .large, legibilityWeight: nil, displayScale: 3, layoutDirection: .leftToRight
        )
        #expect(admission.admittedCodeRoots + admission.gatedCodeRoots == eligible)
        #if canImport(UIKit)
        #expect(admission.admittedCodeRoots == 1 && admission.gatedCodeRoots == 0)
        #else
        #expect(admission.admittedCodeRoots == 0 && admission.gatedCodeRoots == eligible)
        #endif
    }

    // MARK: The three new fixtures

    /// The checks a new fixture's pins feed.
    static func check(_ name: String, _ pins: TK2CodeNewFixturePins) async throws {
        let blocks = try await TextKit2ListCoverageTests.blocks(name)
        let coverage = ADFTextRenderer.textKit2Coverage(of: blocks)
        let codeBlocks = blocks.filter { Self.isCode($0) }.count
        let eligible = TextKit2Eligibility.trailingBreaksMatchText ? pins.eligible : pins.eligibleBeforeIOS26
        #expect(blocks.count == pins.blocks, "\(name): \(blocks.count) top-level blocks")
        #expect(codeBlocks == pins.codeBlocks, "\(name): \(codeBlocks) top-level code blocks")
        #expect(coverage.eligibleCodeRoots == eligible, "\(name): eligibleCodeRoots \(coverage.eligibleCodeRoots)")
        #expect(coverage.fallbackCodeRoots == pins.codeBlocks - eligible, "\(name): fallbackCodeRoots \(coverage.fallbackCodeRoots)")
        #expect(coverage.eligibleCodeRoots + coverage.fallbackCodeRoots == codeBlocks, "\(name)")
        let nested = TextKit2CodeScopeRuleTests.nestedCodeIDs(blocks)
        #expect(nested.count == pins.nestedCode, "\(name): nested code \(nested.sorted())")
        #if canImport(UIKit)
        for (scale, admitted) in [(CGFloat(3), pins.admittedAt3x), (CGFloat(2), pins.admittedAt2x)] {
            let admission = ADFTextRenderer.textKit2CodeAdmission(
                of: blocks, dynamicTypeSize: .large, legibilityWeight: nil, displayScale: scale, layoutDirection: .leftToRight
            )
            #expect(admission.admittedCodeRoots + admission.gatedCodeRoots == coverage.eligibleCodeRoots, "\(name) @\(scale)x")
            // The admitted pins are iOS 26's: before it a block ending in two
            // or more line feeds is not eligible, so it is in neither count.
            if TextKit2Eligibility.trailingBreaksMatchText {
                #expect(admission.admittedCodeRoots == admitted, "\(name) @\(scale)x: admitted \(admission.admittedCodeRoots)")
                #expect(admission.gatedCodeRoots == pins.eligible - admitted, "\(name) @\(scale)x: gated \(admission.gatedCodeRoots)")
            }
        }
        #endif
    }

    @Test("code-parity: code pins")
    func codeParityPins() async throws {
        // Counted from the JSON; each agrees with fixture-notes section 5.
        try await Self.check("code-parity", TK2CodeNewFixturePins(
            blocks: 34,              // top-level nodes
            codeBlocks: 24,          // top-level codeBlock nodes
            eligible: 18,            // eligibleCodeRoots from iOS 26: CP-01 to CP-18
            eligibleBeforeIOS26: 16, // the same without the blocks ending in two or more line feeds (CP-12, CP-13)
            admittedAt3x: 16,        // codeAdmitted at Large on 3x: not CP-15 (9,461 px wide), CP-17
            admittedAt2x: 17,        // codeAdmitted at Large on 2x: not CP-17
            nestedCode: 2            // code in the list item (0.30.0.1) and the panel (0.31.1); the expand's is not prepared
        ))
    }

    @Test("code-parity: which blocks fall back by content, and which the canvas gates")
    func codeParityBlocks() async throws {
        // The block ids (`0.<index>`) of each kind, read from the JSON.
        let tabs: Set<String> = ["0.23"]                       // CP-19: a horizontal tab
        let nonASCII: Set<String> = ["0.24", "0.25", "0.26"]   // CP-20 to CP-22: a scalar above U+007F
        let empty: Set<String> = ["0.27", "0.28"]              // CP-23 (no text), CP-24 (one line feed)
        let trailingLineFeeds: Set<String> = ["0.14", "0.15"]  // CP-12, CP-13: two and three trailing line feeds
        let overCanvasAt3x: Set<String> = ["0.18", "0.20"]     // CP-15 (width cap), CP-17
        let overCanvasAt2x: Set<String> = ["0.20"]             // CP-17

        let blocks = try await TextKit2ListCoverageTests.blocks("code-parity")
        var reasons: [TextKit2Eligibility.Fallback: Set<String>] = [:]
        TextKit2Scope.forEachLeaf(in: blocks) { leaf in
            guard leaf.position == .codeRoot, case .fallback(let reason) = leaf.verdict else { return }
            reasons[reason, default: []].insert(leaf.ownerID)
        }
        var expected: [TextKit2Eligibility.Fallback: Set<String>] = [.codeTabs: tabs, .codeNonASCII: nonASCII, .empty: empty]
        if !TextKit2Eligibility.trailingBreaksMatchText { expected[.trailingBreaks] = trailingLineFeeds }
        #expect(reasons == expected)

        #if canImport(UIKit)
        for (scale, over) in [(CGFloat(3), overCanvasAt3x), (CGFloat(2), overCanvasAt2x)] {
            var gated: Set<String> = []
            TextKit2Scope.forEachLeaf(in: blocks) { leaf in
                guard leaf.position == .codeRoot, case .eligible(let text) = leaf.verdict else { return }
                let gate = TextKit2Scope.codeGate(
                    text, sizeCategory: .large, legibilityWeight: nil, displayScale: scale, layoutDirection: .leftToRight
                )
                if gate != nil { gated.insert(leaf.ownerID) }
                #expect(gate == nil || gate == .canvas, "\(leaf.ownerID) @\(scale)x")
            }
            #expect(gated == over, "@\(scale)x: gated \(gated.sorted())")
        }
        #else
        _ = (overCanvasAt3x, overCanvasAt2x)
        #endif
    }

    @Test("code-dense: code pins")
    func codeDensePins() async throws {
        // Counted from the JSON (lighten ladder version 1); each agrees with
        // fixture-notes section 6.
        try await Self.check("code-dense", TK2CodeNewFixturePins(
            blocks: 600,              // top-level nodes
            codeBlocks: 600,          // top-level codeBlock nodes
            eligible: 600,            // eligibleCodeRoots: printable ASCII and LF, no trailing line feed
            eligibleBeforeIOS26: 600, // the same before iOS 26
            admittedAt3x: 582,        // codeAdmitted at Large on 3x: the 18 blocks kept over the budget are gated
            // codeAdmitted at Large on 2x: CD-005, CD-374, CD-534 and CD-271
            // are gated. CD-271 (21 lines x 214 columns, 16.10 MiB at the
            // font-file metrics) is the one block inside the generator's 3 %
            // metric band. If a run admits it (597), the measured metrics are
            // below the font file's: re-pin from the run, not from this count.
            admittedAt2x: 596,
            nestedCode: 0             // no nested code
        ))
    }

    @Test("code-tall: code pins")
    func codeTallPins() async throws {
        // Counted from the JSON; each agrees with fixture-notes section 7.
        try await Self.check("code-tall", TK2CodeNewFixturePins(
            blocks: 12,              // top-level nodes: 11 code blocks and the CT-SEQ heading
            codeBlocks: 11,          // CT-TALL, CT-NEAR, CT-END, CT-SEQ-1 to CT-SEQ-8
            eligible: 11,            // eligibleCodeRoots
            eligibleBeforeIOS26: 11, // the same before iOS 26: no block ends in a line feed
            admittedAt3x: 10,        // codeAdmitted at Large on 3x: CT-TALL, the 400-line block, is over the height cap
            admittedAt2x: 10,        // codeAdmitted at Large on 2x: CT-TALL is over the height cap at any scale
            nestedCode: 0            // no nested code
        ))
    }
}

#if canImport(UIKit)
import UIKit

/// The live side of the code diagnostics (plan 4) and the layout contract of
/// a code row (plan 3.4): admission measured at an explicit environment;
/// rows drawing code counted live, their native draws counted apart and by
/// owner; and one layout per set of inputs, whatever SwiftUI proposes, read
/// by measuring, placing, drawing and rectangle conversion alike.
///
/// The counters are process-wide and other suites' rows come and go across a
/// suspension: a counter is only compared across a span with no suspension
/// in it, and the per-owner proof is only read exactly for owner ids no
/// other suite uses (`tk2-code-diagnostics.…`).
@Suite("TextKit 2 code diagnostics", .serialized)
@MainActor
struct TextKit2CodeDiagnosticsTests {
    /// Three lines of code, the second the longest.
    nonisolated static let sample = "func greet() {\n    print(\"hello, code row\")\n}"

    /// The inputs the code view's representable gives a row for `string`:
    /// the natural policy, the default environment unless stated.
    static func inputs(
        _ string: String, spec: ADFFontSpec = TK2CodeLogic.mono, alignment: ADFAlignment? = nil,
        category: UIContentSizeCategory = .large, direction: LayoutDirection = .leftToRight, scale: CGFloat = 3,
        weight: LegibilityWeight? = nil, policy: TextKit2LayoutPolicy = .natural
    ) -> TextKit2RenderInputs {
        TextKit2RenderInputs(
            text: TK2CodeLogic.stamped(string, spec: spec), alignment: alignment, sizeCategory: category,
            layoutDirection: direction, displayScale: scale, legibilityWeight: weight, layoutPolicy: policy
        )
    }

    /// A code row as the representable makes one: counted as code first,
    /// then given its inputs and its owner.
    static func codeRow(_ inputs: TextKit2RenderInputs, ownerID: String? = nil) -> TextKit2RowView {
        let row = TextKit2RowView()
        row.ownerKind = .code
        row.apply(inputs, ownerID: ownerID)
        return row
    }

    /// Places `row` at `size` and syncs it, as a layout pass does. (When a
    /// bare view runs its layout pass is UIKit's business; reading a
    /// rectangle syncs the row itself.)
    static func place(_ row: TextKit2RowView, at size: CGSize) {
        row.frame = CGRect(origin: .zero, size: size)
        row.layoutIfNeeded()
        _ = row.segmentRects(for: NSRange(location: 0, length: 1))
    }

    /// Draws `row` once into an offscreen context, through the function its
    /// canvas draws with.
    static func draw(_ row: TextKit2RowView) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: max(row.bounds.width, 1), height: max(row.bounds.height, 1))
        _ = UIGraphicsImageRenderer(size: size, format: format).image { context in
            row.drawText(in: context.cgContext, canvasOrigin: row.canvasFrame.origin)
        }
    }

    /// UTF-16 offsets at which the lines of `string` start: zero, and the
    /// offset after each line feed.
    static func lineStarts(_ string: String) -> [Int] {
        var starts = [0]
        for (offset, unit) in string.utf16.enumerated() where unit == 0x0A {
            starts.append(offset + 1)
        }
        return starts
    }

    // MARK: Admission at an explicit environment

    /// Admitted and gated as the rule functions give them block by block,
    /// without the coverage walk: the content verdict, the font's metrics
    /// at this size and weight, and the pure canvas bound at this scale.
    static func recomputed(
        _ blocks: [RenderBlock], _ category: UIContentSizeCategory, weight: LegibilityWeight?, scale: CGFloat
    ) -> [Int] {
        var admitted = 0
        var gated = 0
        for block in blocks {
            guard case .codeBlock(_, let code) = block.kind,
                  case .eligible = TextKit2Eligibility.codeVerdict(code),
                  let run = code.runs.first, let shape = run.adfCodeShape, let spec = run.adfFontSpec else { continue }
            let metrics = TextKit2CodeMetrics.metrics(for: spec, category: category, legibilityWeight: weight)
            let bound = metrics.flatMap {
                TextKit2Scope.codeCanvasBound(shape, advance: $0.advance, lineHeight: $0.lineHeight, displayScale: scale)
            }
            if bound != nil { admitted += 1 } else { gated += 1 }
        }
        return [admitted, gated]
    }

    @Test("code admission is measured at the environment it is given: the text size, the scale and the layout direction")
    func admission() async throws {
        let large = try #require(TextKit2CodeMetrics.metrics(for: TK2CodeLogic.mono, category: .large))
        let columns = TextKit2CodeFallbackTests.longestAdmittedLine(large, scale: 3)
        // `0.0` a short block; `0.1` the longest line the bound admits at
        // Large on 3x; `0.2` code with a tab, a content fallback that is in
        // neither count; `0.3` a paragraph.
        let data = try TK2CodeLogic.document([
            TK2CodeLogic.code("let a = 1"),
            TK2CodeLogic.code(String(repeating: "x", count: columns)),
            TK2CodeLogic.code("a\tb"),
            TK2CodeLogic.paragraph("Not code"),
        ])
        let blocks = try await TK2CodeLogic.prepared(data)
        let coverage = ADFTextRenderer.textKit2Coverage(of: blocks)
        #expect(coverage.eligibleCodeRoots == 2 && coverage.fallbackCodeRoots == 1)

        func measured(
            _ size: DynamicTypeSize, weight: LegibilityWeight? = nil, scale: CGFloat = 3,
            direction: LayoutDirection = .leftToRight
        ) -> [Int] {
            let counts = ADFTextRenderer.textKit2CodeAdmission(
                of: blocks, dynamicTypeSize: size, legibilityWeight: weight, displayScale: scale, layoutDirection: direction
            )
            return [counts.admittedCodeRoots, counts.gatedCodeRoots]
        }
        // The text size: the long line fits up to Large, and needs a canvas
        // over the width cap above it.
        #expect(measured(.xSmall) == [2, 0])
        #expect(measured(.large) == [2, 0])
        #expect(measured(.xxxLarge) == [1, 1])
        #expect(measured(.accessibility5) == [1, 1])
        // The scale: the same line at the same size takes two thirds of the
        // pixels on a 2x display (23 pt text against 17 pt: 1.36 times the
        // width, under the 1.5 the 2x display leaves).
        #expect(measured(.large, scale: 2) == [2, 0])
        #expect(measured(.xxxLarge, scale: 2) == [2, 0])
        // The layout direction: right to left gates every eligible block.
        #expect(measured(.large, direction: .rightToLeft) == [0, 2])
        #expect(measured(.xSmall, scale: 2, direction: .rightToLeft) == [0, 2])
        // Bold Text is passed on to the font's metrics; whatever they are,
        // the two counts are the eligible blocks, and they are the rules'.
        for weight in TextKit2CodeFallbackTests.weights {
            for size in DynamicTypeSize.allCases {
                let counts = measured(size, weight: weight)
                #expect(counts[0] + counts[1] == 2, "\(size) \(String(describing: weight))")
                #expect(counts == Self.recomputed(blocks, size.uiContentSizeCategory, weight: weight, scale: 3),
                        "\(size) \(String(describing: weight))")
            }
        }
    }

    @Test("fixtures: every eligible code block is admitted at the default environment and none right to left; other environments follow the rules",
          arguments: ["kitchen-sink", "stress-1k", "stress-5k"])
    func fixtureAdmission(fixture: String) async throws {
        let pin = try #require(TextKit2CodeCoverageTests.pins[fixture])
        let blocks = try await TextKit2ListCoverageTests.blocks(fixture)
        let eligible = ADFTextRenderer.textKit2Coverage(of: blocks).eligibleCodeRoots
        #expect(eligible == pin.eligibleCode)

        // The default environment of a 3x iPhone: kitchen-sink 1 and 0,
        // stress-1k 80 and 0, stress-5k 400 and 0. The largest of these
        // blocks is 8 lines of 39 columns: about 1,232 by 615 pixels, 3 MB,
        // against caps of 8,192 pixels and 16 MiB.
        let atDefault = ADFTextRenderer.textKit2CodeAdmission(
            of: blocks, dynamicTypeSize: .large, legibilityWeight: nil, displayScale: 3, layoutDirection: .leftToRight
        )
        #expect(atDefault.admittedCodeRoots == pin.eligibleCode && atDefault.gatedCodeRoots == 0,
                "admitted \(atDefault.admittedCodeRoots), gated \(atDefault.gatedCodeRoots)")

        for weight in TextKit2CodeFallbackTests.weights {
            for scale in [CGFloat(2), 3] {
                var previous = Int.max
                for size in DynamicTypeSize.allCases {
                    let label = "\(size) \(String(describing: weight)) @\(scale)x"
                    let admission = ADFTextRenderer.textKit2CodeAdmission(
                        of: blocks, dynamicTypeSize: size, legibilityWeight: weight, displayScale: scale, layoutDirection: .leftToRight
                    )
                    #expect(admission.admittedCodeRoots + admission.gatedCodeRoots == eligible, "\(label)")
                    let expected = Self.recomputed(blocks, size.uiContentSizeCategory, weight: weight, scale: scale)
                    #expect([admission.admittedCodeRoots, admission.gatedCodeRoots] == expected, "\(label)")
                    // Below the accessibility sizes these blocks are far
                    // under the caps (xxxLarge on 3x: about 5.5 MB).
                    if !size.isAccessibilitySize {
                        #expect(admission.gatedCodeRoots == 0, "\(label): gated \(admission.gatedCodeRoots)")
                    }
                    // A larger text size never admits more.
                    #expect(admission.admittedCodeRoots <= previous, "\(label)")
                    previous = admission.admittedCodeRoots

                    let rightToLeft = ADFTextRenderer.textKit2CodeAdmission(
                        of: blocks, dynamicTypeSize: size, legibilityWeight: weight, displayScale: scale, layoutDirection: .rightToLeft
                    )
                    #expect(rightToLeft.admittedCodeRoots == 0 && rightToLeft.gatedCodeRoots == eligible, "\(label), right to left")
                }
            }
        }

        // The measurement depends on the text size: at AX5 on 3x (53 pt
        // text) an 8-line block of 39 columns needs about 3,836 by 1,904
        // pixels, 29 MB, over the 16 MiB cap. Both stress documents have
        // such blocks; kitchen-sink's two short lines still fit.
        let atAX5 = ADFTextRenderer.textKit2CodeAdmission(
            of: blocks, dynamicTypeSize: .accessibility5, legibilityWeight: nil, displayScale: 3, layoutDirection: .leftToRight
        )
        if fixture == "kitchen-sink" {
            #expect(atAX5.gatedCodeRoots == 0)
        } else {
            #expect(atAX5.gatedCodeRoots > 0, "gated \(atAX5.gatedCodeRoots) of \(eligible) at AX5")
        }
    }

    // MARK: Live rows and native draws

    @Test("a hosted document: rows drawing code are counted live, and their native draws apart from a paragraph's; switching back releases them")
    func liveCodeRows() async throws {
        let diagnostics = TextKit2Diagnostics.shared
        // `0.0` a paragraph, `0.1` eligible code, `0.2` code with a tab
        // (drawn by SwiftUI), `0.3` eligible code.
        let data = try TK2CodeLogic.document([
            TK2CodeLogic.paragraph("A paragraph"),
            TK2CodeLogic.code("let a = 1\nprint(a)", language: "swift"),
            TK2CodeLogic.code("all:\n\ttrue"),
            TK2CodeLogic.code("let b = 2"),
        ])
        let model = try await TK2CodeLogic.loadedModel(data)
        let coverage = ADFTextRenderer.textKit2Coverage(of: model.blocks)
        #expect(coverage.eligibleRoots == 1 && coverage.eligibleCodeRoots == 2 && coverage.fallbackCodeRoots == 1)

        let hosted = TK2CodeLogic.Hosted(TK2CodeLogic.documentView(model, .textKit2))
        defer { hosted.close() }
        try await hosted.settle()
        var rows = hosted.rows
        var codeRows = rows.filter { $0.ownerKind == .code }
        #expect(Set(rows.compactMap(\.ownerID)) == ["0.0", "0.1", "0.3"])
        #expect(rows.count == 3, "one row per owner")
        #expect(Set(codeRows.compactMap(\.ownerID)) == ["0.1", "0.3"])
        let viewports = hosted.scrollViews.count
        #expect(viewports >= 1 + 3, "the document and its three code blocks: \(viewports) scroll views")

        // The public snapshots are the counters. (No suspension from here
        // to the last read: only these rows draw, each once, now.)
        #expect(ADFTextRenderer.textKit2Stats == diagnostics.snapshot)
        #expect(ADFTextRenderer.textKit2CodeRowDraws == diagnostics.codeRowDraws)
        #expect(diagnostics.snapshot.liveCodeRowCount == diagnostics.liveCodeRowCount)
        #expect(diagnostics.snapshot.codeNativeDrawCount == diagnostics.codeNativeDrawCount)
        #expect(diagnostics.liveCodeRowCount >= 2, "at least this window's two code rows")
        #expect(diagnostics.liveCodeRowCount <= diagnostics.liveRowCount)
        #expect(diagnostics.codeRowDraws.count <= diagnostics.liveCodeRowCount, "never more owners than live code rows")
        let listed = ADFTextRenderer.textKit2CodeRowDraws
        #expect(listed["0.1"] != nil && listed["0.3"] != nil, "a live code row's owner is listed, drawn or not")

        let draws = diagnostics.drawCount
        let native = diagnostics.nativeDrawCount
        let codeNative = diagnostics.codeNativeDrawCount
        for row in rows { TK2CodeLogic.draw(row) }
        #expect(diagnostics.drawCount - draws == 3)
        #expect(diagnostics.nativeDrawCount - native == 3, "TextKit 2 itself drew all three")
        #expect(diagnostics.codeNativeDrawCount - codeNative == 2, "the paragraph's native draw is not a code draw")
        let drawn = ADFTextRenderer.textKit2CodeRowDraws
        for owner in ["0.1", "0.3"] {
            #expect((drawn[owner] ?? 0) - (listed[owner] ?? 0) == 1, "\(owner): one native draw more")
        }
        // The tab block's code is on SwiftUI and the paragraph is not code:
        // neither owner's entry moved.
        #expect(drawn["0.2"] == listed["0.2"])
        #expect(drawn["0.0"] == listed["0.0"])
        // One code row again: its owner only.
        if let first = codeRows.first, let owner = first.ownerID {
            TK2CodeLogic.draw(first)
            #expect(diagnostics.codeNativeDrawCount - codeNative == 3)
            #expect((ADFTextRenderer.textKit2CodeRowDraws[owner] ?? 0) - (drawn[owner] ?? 0) == 1)
        }

        hosted.show(TK2CodeLogic.documentView(model, .swiftUI))
        try await hosted.settle()
        #expect(hosted.rows.isEmpty)
        #expect(hosted.scrollViews.count == viewports, "the code blocks stay on screen, on SwiftUI")
        for row in rows {
            #expect(row.window == nil, "\(row.ownerID ?? "?") still on screen")
        }
        // SwiftUI let go of them: dropping this test's references releases
        // them now, and the live counts drop with them.
        let live = diagnostics.liveRowCount
        let liveCode = diagnostics.liveCodeRowCount
        rows.removeAll()
        codeRows.removeAll()
        #expect(live - diagnostics.liveRowCount == 3, "rows released: \(live - diagnostics.liveRowCount)")
        #expect(liveCode - diagnostics.liveCodeRowCount == 2, "code rows released: \(liveCode - diagnostics.liveCodeRowCount)")
        #expect(diagnostics.codeRowDraws.count <= diagnostics.liveCodeRowCount)
    }

    @Test("the per-owner proof: an eligible code block's owner is listed and counts its row's native draws; code on SwiftUI is absent; a released row's owner goes")
    func perOwnerProof() async throws {
        let diagnostics = TextKit2Diagnostics.shared
        let eligible = "tk2-code-diagnostics.proof.eligible"
        let tabbed = "tk2-code-diagnostics.proof.tabbed"
        let code = TK2CodeLogic.stamped("let a = 1\nprint(a)")
        let tabCode = TK2CodeLogic.stamped("all:\n\ttrue")
        func codeBlocks(_ renderer: ADFTextRenderer) -> some View {
            VStack(alignment: .leading, spacing: 0) {
                TK2CodeLogic.codeView(code, ownerID: eligible, renderer: renderer)
                TK2CodeLogic.codeView(tabCode, ownerID: tabbed, renderer: renderer)
            }
        }

        let hosted = TK2CodeLogic.Hosted(codeBlocks(.textKit2))
        defer { hosted.close() }
        try await hosted.settle()
        var rows = hosted.rows
        #expect(rows.count == 1 && rows.first?.ownerKind == .code && rows.first?.ownerID == eligible)
        #expect(hosted.scrollViews.count == 2, "both code blocks are on screen")

        // No suspension from here to the last read.
        let listed = try #require(ADFTextRenderer.textKit2CodeRowDraws[eligible], "a live code row is listed, drawn or not")
        #expect(ADFTextRenderer.textKit2CodeRowDraws[tabbed] == nil, "code on SwiftUI is absent")
        let codeNative = diagnostics.codeNativeDrawCount
        for row in rows { TK2CodeLogic.draw(row) }
        for row in rows { TK2CodeLogic.draw(row) }
        #expect(ADFTextRenderer.textKit2CodeRowDraws[eligible] == listed + 2, "TextKit 2 itself drew this block's code, twice")
        #expect(diagnostics.codeNativeDrawCount - codeNative == 2)
        #expect(ADFTextRenderer.textKit2CodeRowDraws[tabbed] == nil)
        #expect(diagnostics.codeRowDraws.count <= diagnostics.liveCodeRowCount)

        hosted.show(codeBlocks(.swiftUI))
        try await hosted.settle()
        #expect(hosted.rows.isEmpty)
        #expect(hosted.scrollViews.count == 2, "both code blocks stay on screen, on SwiftUI")
        let liveCode = diagnostics.liveCodeRowCount
        rows.removeAll()
        #expect(liveCode - diagnostics.liveCodeRowCount == 1, "the code row is released")
        #expect(ADFTextRenderer.textKit2CodeRowDraws[eligible] == nil, "its owner goes with it")
        #expect(ADFTextRenderer.textKit2CodeRowDraws[tabbed] == nil)
        #expect(diagnostics.codeRowDraws.count <= diagnostics.liveCodeRowCount)
    }

    @Test("the per-owner registry follows what rows report: joined with an id, counted per native code draw, moved with the id, gone with the last row")
    func registry() {
        let diagnostics = TextKit2Diagnostics.shared
        let id = "tk2-code-diagnostics.registry.first"
        let moved = "tk2-code-diagnostics.registry.moved"
        let unknown = "tk2-code-diagnostics.registry.unknown"
        // No suspension in this test: the counters move only by its calls.
        let liveRows = diagnostics.liveRowCount
        let liveCode = diagnostics.liveCodeRowCount
        let liveList = diagnostics.liveListRowCount
        let owners = diagnostics.codeRowDraws.count
        let native = diagnostics.nativeDrawCount
        let codeNative = diagnostics.codeNativeDrawCount

        // A new row becomes a code row before it has an id (the
        // representable sets the kind first), then gets its id.
        diagnostics.rowCreated()
        diagnostics.row(ownerKind: .code, was: .root, ownerID: nil)
        #expect(diagnostics.liveCodeRowCount - liveCode == 1)
        #expect(diagnostics.codeRowDraws.count == owners, "a code row without an id is live but not listed")
        diagnostics.row(ownerID: id, was: nil, ownerKind: .code)
        #expect(diagnostics.codeRowDraws[id] == 0, "listed at zero before it draws")
        #expect(diagnostics.codeRowDraws.count == owners + 1)
        #expect(ADFTextRenderer.textKit2CodeRowDraws == diagnostics.codeRowDraws)

        // Only a native draw of a code row counts for its owner.
        diagnostics.didDraw(native: true, code: true, ownerID: id)
        #expect(diagnostics.codeRowDraws[id] == 1)
        diagnostics.didDraw(native: false, code: true, ownerID: id)
        diagnostics.didDraw(native: true, code: false, ownerID: id)
        diagnostics.didDraw(native: false, textKit1: true, code: true, ownerID: id)
        #expect(diagnostics.codeRowDraws[id] == 1)
        #expect(diagnostics.codeNativeDrawCount - codeNative == 1)
        #expect(diagnostics.nativeDrawCount - native == 2)
        // A draw for an owner with no live code row, or for no owner, adds
        // to the total and creates no entry.
        diagnostics.didDraw(native: true, code: true, ownerID: unknown)
        diagnostics.didDraw(native: true, code: true, ownerID: nil)
        #expect(diagnostics.codeRowDraws[unknown] == nil)
        #expect(diagnostics.codeRowDraws.count == owners + 1)
        #expect(diagnostics.codeNativeDrawCount - codeNative == 3)

        // The row's id changes: its draws so far go with the old id.
        diagnostics.row(ownerID: moved, was: id, ownerKind: .code)
        #expect(diagnostics.codeRowDraws[id] == nil)
        #expect(diagnostics.codeRowDraws[moved] == 0)
        diagnostics.didDraw(native: true, code: true, ownerID: moved)
        #expect(diagnostics.codeRowDraws[moved] == 1)

        // A second live row for the same owner (a row being replaced): one
        // entry, which outlives the first row to go.
        diagnostics.rowCreated()
        diagnostics.row(ownerKind: .code, was: .root, ownerID: nil)
        diagnostics.row(ownerID: moved, was: nil, ownerKind: .code)
        #expect(diagnostics.liveCodeRowCount - liveCode == 2)
        #expect(diagnostics.codeRowDraws.count == owners + 1, "one entry per owner")
        diagnostics.rowDestroyed(ownerKind: .code, ownerID: moved)
        #expect(diagnostics.codeRowDraws[moved] == 1, "the other row keeps the entry and its draws")
        #expect(diagnostics.liveCodeRowCount - liveCode == 1)

        // The row stops being code: out of the proof and the live code count.
        diagnostics.row(ownerKind: .list, was: .code, ownerID: moved)
        #expect(diagnostics.codeRowDraws[moved] == nil)
        #expect(diagnostics.liveCodeRowCount == liveCode)
        #expect(diagnostics.liveListRowCount - liveList == 1)
        // A list row's id is never listed.
        diagnostics.row(ownerID: id, was: moved, ownerKind: .list)
        #expect(diagnostics.codeRowDraws[id] == nil && diagnostics.codeRowDraws.count == owners)
        // Code again, with its id: a new entry, at zero.
        diagnostics.row(ownerKind: .code, was: .list, ownerID: id)
        #expect(diagnostics.codeRowDraws[id] == 0)
        #expect(diagnostics.liveListRowCount == liveList)
        // Released.
        diagnostics.rowDestroyed(ownerKind: .code, ownerID: id)
        #expect(diagnostics.codeRowDraws[id] == nil)
        #expect(diagnostics.codeRowDraws.count == owners)
        #expect(diagnostics.liveRowCount == liveRows)
        #expect(diagnostics.liveCodeRowCount == liveCode)
        #expect(diagnostics.liveListRowCount == liveList)
        #expect(diagnostics.codeRowDraws.count <= diagnostics.liveCodeRowCount)
    }

    @Test("real rows report themselves: live code from the kind, listed from the id, a code-native draw per draw pass, and out of both when released")
    func rowsReportThemselves() {
        let diagnostics = TextKit2Diagnostics.shared
        let first = "tk2-code-diagnostics.rows.first"
        let second = "tk2-code-diagnostics.rows.second"
        let inputs = Self.inputs(Self.sample)
        // No suspension in this test: the counters move only by these rows.
        let liveRows = diagnostics.liveRowCount
        let liveCode = diagnostics.liveCodeRowCount
        let liveList = diagnostics.liveListRowCount
        let codeNative = diagnostics.codeNativeDrawCount
        autoreleasepool {
            let row = TextKit2RowView()
            #expect(diagnostics.liveRowCount - liveRows == 1)
            #expect(diagnostics.liveCodeRowCount == liveCode, "a new row is a root row")
            row.ownerKind = .code
            #expect(diagnostics.liveCodeRowCount - liveCode == 1)
            row.ownerKind = .code
            #expect(diagnostics.liveCodeRowCount - liveCode == 1, "the same kind again counts nothing")
            #expect(diagnostics.codeRowDraws[first] == nil)
            row.apply(inputs, ownerID: first)
            #expect(diagnostics.codeRowDraws[first] == 0, "listed before it has drawn")

            // Live, measured and placed, but not drawn: no code-native draw.
            Self.place(row, at: row.measuredSize(forProposedWidth: nil))
            #expect(diagnostics.codeNativeDrawCount == codeNative, "measuring and placing draw nothing")
            Self.draw(row)
            Self.draw(row)
            #expect(diagnostics.codeNativeDrawCount - codeNative == 2)
            #expect(diagnostics.codeRowDraws[first] == 2)

            // The same row under another id: listed afresh.
            row.apply(inputs, ownerID: second)
            #expect(diagnostics.codeRowDraws[first] == nil)
            #expect(diagnostics.codeRowDraws[second] == 0)
            Self.draw(row)
            #expect(diagnostics.codeRowDraws[second] == 1)
            #expect(diagnostics.codeNativeDrawCount - codeNative == 3)

            // Drawing list text instead: a native draw, not a code one.
            row.ownerKind = .list
            #expect(diagnostics.codeRowDraws[second] == nil)
            #expect(diagnostics.liveCodeRowCount == liveCode)
            #expect(diagnostics.liveListRowCount - liveList == 1)
            let native = diagnostics.nativeDrawCount
            Self.draw(row)
            #expect(diagnostics.nativeDrawCount - native == 1)
            #expect(diagnostics.codeNativeDrawCount - codeNative == 3, "a list row's native draw is not a code draw")
            row.ownerKind = .code
            #expect(diagnostics.codeRowDraws[second] == 0, "code again: a new entry")
            #expect(diagnostics.liveListRowCount == liveList)

            // A code row with no owner id (a preview): live and drawing
            // natively, never listed.
            let owners = diagnostics.codeRowDraws.count
            let preview = Self.codeRow(inputs)
            #expect(diagnostics.liveCodeRowCount - liveCode == 2)
            Self.place(preview, at: preview.measuredSize(forProposedWidth: nil))
            Self.draw(preview)
            #expect(diagnostics.codeNativeDrawCount - codeNative == 4)
            #expect(diagnostics.codeRowDraws.count == owners)
            #expect(diagnostics.codeRowDraws[second] == 0)
            // The checks above count `row` as live; keep it alive past its
            // last use so an optimised build cannot release it early.
            withExtendedLifetime(row) {}
        }
        // Both rows are released: out of every live count and of the proof.
        #expect(diagnostics.liveRowCount == liveRows)
        #expect(diagnostics.liveCodeRowCount == liveCode)
        #expect(diagnostics.liveListRowCount == liveList)
        #expect(diagnostics.codeRowDraws[second] == nil)
    }

    // MARK: One layout per set of inputs

    @Test("a code row lays out once per set of inputs: measuring, placing, the baseline guides, drawing and rectangles all read that one layout")
    func oneLayoutPerInputs() {
        let diagnostics = TextKit2Diagnostics.shared
        // No suspension in this test: only this row converts and lays out.
        let conversions = diagnostics.conversionCount
        let layouts = diagnostics.layoutCount
        let row = Self.codeRow(Self.inputs(Self.sample), ownerID: "tk2-code-diagnostics.once")
        #expect(diagnostics.conversionCount - conversions == 1)
        #expect(row.relayoutCount == 0 && diagnostics.layoutCount == layouts, "new inputs lay nothing out by themselves")
        #expect(row.cachedWidths.isEmpty && row.drawn == nil)

        // Measure: SwiftUI probes a row with several proposals.
        let natural = row.layoutResult(forProposedWidth: nil)
        #expect(row.relayoutCount == 1)
        let proposals: [CGFloat?] = [nil, 390, 0, 1, 320.5, CGFloat.infinity, 390]
        for proposal in proposals {
            _ = row.measuredSize(forProposedWidth: proposal)
        }
        #expect(row.relayoutCount == 1)
        #expect(row.cachedWidths == [.infinity], "one memoized layout, the natural one")

        // Place: at the size it reported.
        Self.place(row, at: natural.size)
        #expect(row.drawn == natural)
        #expect(row.drawnShift == 0)
        #expect(row.currentContainerWidth == natural.width, "the container stays where the measurement left it")
        // The baseline guides read the placed layout.
        #expect(row.placedResult(for: natural.size).firstBaseline == natural.firstBaseline)
        #expect(row.placedResult(for: natural.size).lastBaseline == natural.lastBaseline)
        #expect(row.relayoutCount == 1)

        // Draw, twice, and convert a range to rectangles.
        let codeNative = diagnostics.codeNativeDrawCount
        Self.draw(row)
        Self.draw(row)
        #expect(diagnostics.codeNativeDrawCount - codeNative == 2)
        let length = (Self.sample as NSString).length
        #expect(!row.segmentRects(for: NSRange(location: 0, length: length)).isEmpty)
        #expect(row.relayoutCount == 1)
        #expect(diagnostics.layoutCount - layouts == 1, "one layout in all, across measure, place and draw")
        #expect(diagnostics.conversionCount - conversions == 1)
        #expect(row.cachedWidths == [.infinity])
        #expect(row.drawn == natural)

        // A pure function of the inputs: a fresh row gives the same layout,
        // whatever it is proposed first.
        let fresh = Self.codeRow(Self.inputs(Self.sample))
        #expect(fresh.layoutResult(forProposedWidth: 200) == natural)
    }

    @Test("new content, a new font (text size, Bold Text, font spec), a new scale or a new policy each convert and lay out once more; a re-apply, a colour scheme flip or a new owner id do neither")
    func newLayoutPerChange() {
        let diagnostics = TextKit2Diagnostics.shared
        let row = TextKit2RowView()
        row.ownerKind = .code
        // No suspension in this test: only this row converts and lays out.
        var conversions = diagnostics.conversionCount
        var layouts = diagnostics.layoutCount
        var relayouts = row.relayoutCount
        var scheme = ColorScheme.light
        var owner: String? = nil

        /// Applies `inputs`, then measures, places and draws the row as
        /// SwiftUI would; expects one conversion and one layout when the
        /// inputs changed, none otherwise. Returns the layout.
        func generation(_ inputs: TextKit2RenderInputs, _ name: String, changed: Bool) -> TextKit2LayoutResult {
            row.apply(inputs, colorScheme: scheme, ownerID: owner)
            if changed {
                #expect(row.cachedWidths.isEmpty && row.drawn == nil, "\(name): the old layout must not outlive its inputs")
                #expect(row.relayoutCount == relayouts, "\(name): no layout before SwiftUI measures")
            }
            let result = row.layoutResult(forProposedWidth: 390)
            _ = row.measuredSize(forProposedWidth: nil)
            Self.place(row, at: result.size)
            Self.draw(row)
            let expected = changed ? 1 : 0
            #expect(row.relayoutCount - relayouts == expected, "\(name): \(row.relayoutCount - relayouts) layout(s)")
            #expect(diagnostics.layoutCount - layouts == expected, "\(name): \(diagnostics.layoutCount - layouts) layout(s) counted")
            #expect(diagnostics.conversionCount - conversions == expected, "\(name): \(diagnostics.conversionCount - conversions) conversion(s)")
            #expect(row.cachedWidths == [.infinity], "\(name)")
            #expect(row.drawn == result, "\(name)")
            relayouts = row.relayoutCount
            layouts = diagnostics.layoutCount
            conversions = diagnostics.conversionCount
            return result
        }

        var inputs = Self.inputs(Self.sample)
        let first = generation(inputs, "first inputs", changed: true)
        #expect(first.lineCount == 3)

        // Nothing the layout depends on changed.
        let same = generation(inputs, "the same inputs again", changed: false)
        #expect(same == first)
        scheme = .dark
        let flipped = generation(inputs, "a colour scheme flip", changed: false)
        #expect(flipped == first)
        #expect(row.overrideUserInterfaceStyle == .dark)
        owner = "tk2-code-diagnostics.change"
        let renamed = generation(inputs, "a new owner id", changed: false)
        #expect(renamed == first)
        #expect(row.accessibilityIdentifier == "tk2-row:tk2-code-diagnostics.change")

        // Content.
        inputs.text = TK2CodeLogic.stamped(Self.sample + "\nlet added = \"a line longer than any other in the sample\"")
        let longer = generation(inputs, "new content", changed: true)
        #expect(longer.lineCount == 4)
        #expect(longer.size.height > first.size.height && longer.size.width > first.size.width)

        // Font: the text size.
        inputs.text = TK2CodeLogic.stamped(Self.sample)
        inputs.sizeCategory = .accessibilityLarge
        let larger = generation(inputs, "a larger text size", changed: true)
        #expect(larger.lineCount == 3)
        #expect(larger.size.height > first.size.height && larger.size.width > first.size.width)

        // Font: Bold Text.
        inputs.legibilityWeight = .bold
        let bold = generation(inputs, "Bold Text", changed: true)
        #expect(bold.lineCount == 3)

        // Font: another spec, which travels in the text.
        inputs.text = TK2CodeLogic.stamped(Self.sample, spec: ADFFontSpec(textStyle: .footnote, monospaced: true))
        let footnote = generation(inputs, "another font spec", changed: true)
        #expect(footnote.lineCount == 3)
        #expect(footnote.size.height < bold.size.height && footnote.size.width < bold.size.width)

        // Scale.
        inputs.displayScale = 2
        let twoX = generation(inputs, "another display scale", changed: true)
        #expect(twoX.lineCount == 3)

        // Policy: the same text wrapping is another set of inputs, laid out
        // at the width it is proposed.
        inputs.layoutPolicy = .wrapping
        row.apply(inputs, colorScheme: scheme, ownerID: owner)
        #expect(row.cachedWidths.isEmpty && row.drawn == nil, "a new policy drops the natural layout")
        #expect(diagnostics.conversionCount - conversions == 1, "the policy is part of the inputs")
        let wrapped = row.layoutResult(forProposedWidth: 60)
        #expect(row.relayoutCount - relayouts == 1)
        #expect(wrapped.width == 60 && wrapped.lineCount > 3, "wrapping at 60 pt: \(wrapped.lineCount) line fragments")
        #expect(row.cachedWidths == [60])
        conversions = diagnostics.conversionCount
        layouts = diagnostics.layoutCount
        relayouts = row.relayoutCount

        // And back: the natural layout again, the same as before.
        inputs.layoutPolicy = .natural
        let again = generation(inputs, "back to the natural policy", changed: true)
        #expect(again == twoX, "the same inputs give the same layout")
    }

    // MARK: The proposal matrix

    @Test("the natural policy's proposal matrix: zero answers .zero with no layout; nil, infinite, narrow, fractional and regular widths all answer the one natural layout")
    func proposalMatrix() throws {
        let row = Self.codeRow(Self.inputs(Self.sample))

        // Zero (or less): `.zero`, and nothing laid out.
        for proposal in [CGFloat(0), -1, -390] {
            #expect(row.layoutResult(forProposedWidth: proposal) == .zero, "\(proposal)")
            #expect(row.measuredSize(forProposedWidth: proposal) == .zero, "\(proposal)")
        }
        #expect(row.relayoutCount == 0 && row.cachedWidths.isEmpty, "a zero proposal performs no layout")

        let natural = row.layoutResult(forProposedWidth: nil)
        #expect(row.relayoutCount == 1)
        // As tall as its lines and as wide as its longest line (its columns
        // times the font's fixed advance), not as its container.
        let shape = ADFCodeShape(Self.sample)
        let metrics = try #require(TextKit2CodeMetrics.metrics(for: TK2CodeLogic.mono, category: .large))
        let longest = CGFloat(shape.maxLineUTF16) * metrics.advance
        #expect(natural.lineCount == shape.lineCount)
        #expect(natural.size.width <= longest + 1 && natural.size.width >= longest * 0.9,
                "\(natural.size.width) pt wide; \(shape.maxLineUTF16) columns are \(longest) pt")
        #expect(natural.size.height <= CGFloat(shape.lineCount) * metrics.lineHeight + 1)
        #expect(natural.width > natural.size.width, "laid out in a container far wider than the text")
        #expect(natural.width == row.currentContainerWidth)

        let proposals: [(name: String, width: CGFloat?)] = [
            ("nil", nil),
            ("infinity", CGFloat.infinity),
            ("a third of a point", CGFloat(1) / 3),
            ("one point", 1),
            ("narrower than a column", 4),
            ("fractional", 123.456),
            ("half the text", natural.size.width / 2),
            ("the natural width", natural.size.width),
            ("a hair over it", natural.size.width + 0.001),
            ("a phone", 390),
            ("a phone's fractional column", 353.333),
            ("a tablet", 1_024),
            ("wider than any screen", 100_000),
            ("the largest finite width", CGFloat.greatestFiniteMagnitude),
        ]
        for proposal in proposals {
            #expect(row.layoutResult(forProposedWidth: proposal.width) == natural, "\(proposal.name)")
            #expect(row.measuredSize(forProposedWidth: proposal.width) == natural.size, "\(proposal.name)")
            #expect(row.relayoutCount == 1, "\(proposal.name): \(row.relayoutCount) layouts")
            #expect(row.cachedWidths == [.infinity], "\(proposal.name): cached \(row.cachedWidths)")
            #expect(row.currentContainerWidth == natural.width, "\(proposal.name)")
        }
        // Zero still answers `.zero` once the layout exists, and keeps it.
        #expect(row.layoutResult(forProposedWidth: 0) == .zero)
        #expect(row.cachedWidths == [.infinity])

        // A, B, A: nothing moves between the proposals.
        let a = row.layoutResult(forProposedWidth: 300)
        let b = row.layoutResult(forProposedWidth: 640)
        #expect(a == natural && b == natural && row.layoutResult(forProposedWidth: 300) == natural)
        #expect(row.relayoutCount == 1 && row.currentContainerWidth == natural.width)

        // Placement: whatever frame the row is given (taller, shorter,
        // narrower, wider), it draws the natural layout with no shift.
        let frames = [
            natural.size,
            CGSize(width: natural.size.width, height: natural.size.height + 37.5),
            CGSize(width: natural.size.width, height: 10),
            CGSize(width: 200, height: natural.size.height),
            CGSize(width: natural.size.width + 120, height: natural.size.height + CGFloat(1) / 3),
        ]
        for frame in frames {
            #expect(row.placedResult(for: frame) == natural, "\(frame)")
            Self.place(row, at: frame)
            #expect(row.drawn == natural, "\(frame)")
            #expect(row.drawnShift == 0, "\(frame)")
            #expect(row.currentContainerWidth == natural.width, "\(frame)")
            // The canvas is the bounds horizontally and covers the ink
            // vertically, as for any row.
            let canvas = row.canvasFrame
            #expect(canvas.minX == 0 && canvas.width == frame.width, "\(frame): canvas \(canvas)")
            #expect(canvas.minY <= natural.inkBounds.minY && canvas.maxY >= natural.inkBounds.maxY, "\(frame): canvas \(canvas)")
        }
        #expect(row.placedResult(for: CGSize(width: 0, height: 40)) == .zero)
        #expect(row.relayoutCount == 1, "\(row.relayoutCount) layouts after every proposal and placement")

        // The control: the same text wrapping lays out per width, and its
        // container follows the last width laid out.
        let wrapping = TextKit2RowView()
        wrapping.apply(Self.inputs(Self.sample, policy: .wrapping))
        let narrow = wrapping.layoutResult(forProposedWidth: 120)
        let wide = wrapping.layoutResult(forProposedWidth: 640)
        #expect(wrapping.layoutResult(forProposedWidth: 120) == narrow)
        #expect(wrapping.relayoutCount == 2 && wrapping.cachedWidths == [640, 120])
        #expect(wrapping.currentContainerWidth == 640)
        #expect(narrow.lineCount > natural.lineCount && wide.lineCount == natural.lineCount)
        #expect(wide.size == natural.size, "unwrapped, the two policies size the text alike")
    }

    @Test("new content under the same owner id drops the old layout and is laid out once; an appearance-only change keeps the string and the layout")
    func sameOwnerReplacementAndAppearance() {
        let diagnostics = TextKit2Diagnostics.shared
        let owner = "tk2-code-diagnostics.replace"
        let old = "let a = 1"
        let new = "let a = 1\nlet b = 2\nprint(a + b, \"replaced under the same owner\")"
        // No suspension in this test.
        let row = Self.codeRow(Self.inputs(old), ownerID: owner)
        let before = row.layoutResult(forProposedWidth: 390)
        Self.place(row, at: before.size)
        Self.draw(row)
        let oldString = row.attributed
        #expect(row.relayoutCount == 1)
        #expect(diagnostics.codeRowDraws[owner] == 1)

        // Appearance only: the colour scheme is a paint input.
        let conversions = diagnostics.conversionCount
        row.apply(Self.inputs(old), colorScheme: .dark, ownerID: owner)
        #expect(row.overrideUserInterfaceStyle == .dark)
        #expect(row.attributed === oldString, "the converted string is kept")
        #expect(diagnostics.conversionCount == conversions)
        #expect(row.drawn == before && row.cachedWidths == [.infinity])
        Self.draw(row)
        #expect(row.relayoutCount == 1, "a flip lays nothing out")
        #expect(diagnostics.codeRowDraws[owner] == 2)

        // New content under the same owner.
        row.apply(Self.inputs(new), colorScheme: .dark, ownerID: owner)
        #expect(diagnostics.conversionCount - conversions == 1)
        #expect(row.ownerID == owner && row.accessibilityIdentifier == "tk2-row:\(owner)")
        #expect(row.accessibilityLabel == new)
        #expect(row.attributed.string == new && row.attributed !== oldString)
        #expect(row.cachedWidths.isEmpty && row.drawn == nil, "the old layout must not outlive its content")
        #expect(row.relayoutCount == 1, "no layout until SwiftUI measures the new content")
        let after = row.layoutResult(forProposedWidth: 390)
        #expect(row.relayoutCount == 2)
        #expect(after.lineCount == 3)
        #expect(after.size.height > before.size.height && after.size.width > before.size.width)
        #expect(after.lines.last?.range.upperBound == (new as NSString).length)
        // Still at its old frame, placement reads the new layout.
        #expect(row.placedResult(for: before.size) == after)
        Self.place(row, at: after.size)
        Self.draw(row)
        #expect(row.drawn == after)
        #expect(row.relayoutCount == 2 && row.cachedWidths == [.infinity])
        // The owner's entry stayed with the row, and kept counting.
        #expect(diagnostics.codeRowDraws[owner] == 3)
        // The layout a fresh row computes for the new content.
        let fresh = Self.codeRow(Self.inputs(new))
        #expect(fresh.layoutResult(forProposedWidth: nil) == after)
    }

    // MARK: Lines never wrap

    nonisolated static let longLineCategories: [UIContentSizeCategory] = [
        .extraSmall, .large, .extraExtraExtraLarge, .accessibilityMedium, .accessibilityExtraLarge,
        .accessibilityExtraExtraExtraLarge,
    ]

    /// One line of exactly 300 columns, made of words: a wrapping layout
    /// would break it at any of its spaces.
    nonisolated static let longLine = String(String(repeating: "value = compute(a, b); ", count: 14).prefix(300))

    @Test("a 300-column line never wraps: the line fragments are the line feeds plus one, at every text size, weight and scale",
          arguments: longLineCategories)
    func longLinesNeverWrap(category: UIContentSizeCategory) throws {
        #expect(Self.longLine.utf16.count == 300 && !Self.longLine.hasSuffix(" "))
        let texts: [(name: String, string: String)] = [
            ("alone", Self.longLine),
            ("among short lines", "short\n" + Self.longLine + "\nend"),
            ("twice, around an empty line", Self.longLine + "\n\n" + Self.longLine),
            ("before a trailing line feed", Self.longLine + "\n"),
        ]
        for weight in [LegibilityWeight?.none, .bold] {
            let metrics = try #require(TextKit2CodeMetrics.metrics(for: TK2CodeLogic.mono, category: category, legibilityWeight: weight))
            for scale in [CGFloat(2), 3] {
                for item in texts {
                    let label = "\(item.name), \(category.rawValue), \(String(describing: weight)), @\(scale)x"
                    let lineFeeds = item.string.utf16.filter { $0 == 0x0A }.count
                    #expect(ADFCodeShape(item.string).maxLineUTF16 == 300 && ADFCodeShape(item.string).lineCount == lineFeeds + 1, "\(label)")

                    let row = Self.codeRow(Self.inputs(item.string, category: category, scale: scale, weight: weight))
                    // Proposed a phone's width, as its scroll view's
                    // viewport is: far narrower than the line.
                    let result = row.layoutResult(forProposedWidth: 320)
                    #expect(result.lineCount == lineFeeds + 1, "\(label): \(result.lineCount) line fragments")
                    // As wide as 300 columns: never the proposal, and never
                    // more than the canvas bound counts on.
                    #expect(result.size.width > 320, "\(label): \(result.size.width) pt wide")
                    #expect(result.size.width <= 300 * metrics.advance + 1, "\(label): \(result.size.width) pt wide, advance \(metrics.advance)")
                    #expect(result.size.width >= 300 * metrics.advance * 0.9, "\(label): \(result.size.width) pt wide, advance \(metrics.advance)")
                    // Each line fragment starts where its line does.
                    if !item.string.hasSuffix("\n") {
                        #expect(result.lines.map(\.range.location) == Self.lineStarts(item.string), "\(label)")
                        #expect(result.lines.last?.range.upperBound == (item.string as NSString).length, "\(label)")
                    }
                    // Placed at its natural size, and squeezed into the
                    // viewport's width: the same fragments, no new layout.
                    for width in [result.size.width, 320] {
                        Self.place(row, at: CGSize(width: width, height: result.size.height))
                        #expect(row.drawn?.lineCount == lineFeeds + 1, "\(label), placed \(width) pt wide")
                        #expect(row.drawnShift == 0, "\(label), placed \(width) pt wide")
                    }
                    #expect(row.relayoutCount == 1, "\(label): \(row.relayoutCount) layouts")
                }
            }
        }

        // The control: the same line wrapping at that width takes several
        // fragments, so the counts above are the policy's doing.
        let wrapping = TextKit2RowView()
        wrapping.apply(Self.inputs(Self.longLine, category: category, policy: .wrapping))
        let wrapped = wrapping.layoutResult(forProposedWidth: 320)
        #expect(wrapped.lineCount > 1, "\(category.rawValue): the wrapping control has \(wrapped.lineCount) line fragment(s)")
    }

    // MARK: Left alignment

    @Test("a code row's lines are left-aligned and drawn with no shift, whatever alignment or layout direction its inputs carry")
    func leftAlignedWithZeroShift() throws {
        let string = "short\na much longer line of code than the first\nmid length line"
        let lastLine = (string as NSString).range(of: "mid length line")
        let alignments: [ADFAlignment?] = [nil, .center, .end]
        for alignment in alignments {
            for direction in [LayoutDirection.leftToRight, .rightToLeft] {
                let label = "\(String(describing: alignment)) \(direction)"
                let row = Self.codeRow(Self.inputs(string, alignment: alignment, direction: direction))
                let style = row.attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
                #expect(style?.alignment == .left, "\(label)")

                let natural = row.layoutResult(forProposedWidth: 390)
                #expect(natural.lineCount == 3, "\(label)")
                // Every line starts at the row's own left edge, the short
                // ones included.
                #expect(natural.lines.allSatisfy { abs($0.frame.minX) < 0.01 }, "\(label): lines at \(natural.lines.map(\.frame.minX))")

                // Placed at its natural width, stretched and squeezed.
                for width in [natural.size.width, natural.size.width + 200, 150] {
                    Self.place(row, at: CGSize(width: width, height: natural.size.height))
                    #expect(row.drawnShift == 0, "\(label), \(width) pt wide")
                    let first = try #require(row.segmentRects(for: NSRange(location: 0, length: 5)).first, "\(label), \(width) pt wide")
                    let last = try #require(row.segmentRects(for: lastLine).first, "\(label), \(width) pt wide")
                    #expect(abs(first.minX) < 0.01, "\(label), \(width) pt wide: first line at \(first.minX)")
                    #expect(abs(last.minX) < 0.01, "\(label), \(width) pt wide: last line at \(last.minX)")
                    #expect(row.canvasFrame.minX == 0, "\(label), \(width) pt wide")
                }
                #expect(row.relayoutCount == 1, "\(label)")
            }
        }

        // The control: wrapping text keeps the alignment its inputs ask for.
        let centred = TextKit2RowView()
        centred.apply(Self.inputs(string, alignment: .center, policy: .wrapping))
        let centredStyle = centred.attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(centredStyle?.alignment == .center)
        let trailing = TextKit2RowView()
        trailing.apply(Self.inputs(string, direction: .rightToLeft, policy: .wrapping))
        let trailingStyle = trailing.attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(trailingStyle?.alignment == .right)
    }

    // MARK: Hosted

    @Test("hosted: the real code row lays out once for SwiftUI's measure, place and draw; a colour scheme flip lays nothing out; a new text size lays out once more")
    func hostedOneLayout() async throws {
        let diagnostics = TextKit2Diagnostics.shared
        let owner = "tk2-code-diagnostics.hosted"
        let code = TK2CodeLogic.stamped(TextKit2CodeFallbackTests.block)
        // One view type for every state, so SwiftUI keeps the row's identity.
        func codeBlock(_ size: DynamicTypeSize, _ scheme: ColorScheme) -> some View {
            TK2CodeLogic.codeView(code, ownerID: owner, size: size).environment(\.colorScheme, scheme)
        }

        let hosted = TK2CodeLogic.Hosted(codeBlock(.large, .light))
        defer { hosted.close() }
        try await hosted.settle()
        #expect(hosted.rows.count == 1)
        let row = try #require(hosted.codeRows.first)
        #expect(row.inputs?.layoutPolicy == .natural && row.inputs?.sizeCategory == .large)
        #expect(row.relayoutCount == 1, "\(row.relayoutCount) layouts for the first measure and placement")
        #expect(row.cachedWidths == [.infinity], "cached \(row.cachedWidths)")
        let natural = row.layoutResult(forProposedWidth: nil)
        #expect(row.relayoutCount == 1)
        #expect(natural.lineCount == 8)
        #expect(row.drawn == natural && row.drawnShift == 0)
        // SwiftUI placed the row at the size it measured, inside the code
        // block's scroll view.
        #expect(abs(row.bounds.width - natural.size.width) < 0.01 && abs(row.bounds.height - natural.size.height) < 0.01,
                "placed \(row.bounds.size), measured \(natural.size)")
        #expect(row.overrideUserInterfaceStyle == .light)

        // A draw pass, now (no suspension to the last read).
        let layouts = diagnostics.layoutCount
        let codeNative = diagnostics.codeNativeDrawCount
        let listed = try #require(ADFTextRenderer.textKit2CodeRowDraws[owner])
        TK2CodeLogic.draw(row)
        #expect(diagnostics.layoutCount == layouts, "drawing lays nothing out")
        #expect(diagnostics.codeNativeDrawCount - codeNative == 1)
        #expect(ADFTextRenderer.textKit2CodeRowDraws[owner] == listed + 1)
        #expect(row.relayoutCount == 1)

        // Appearance only.
        let string = row.attributed
        hosted.show(codeBlock(.large, .dark))
        try await hosted.settle()
        let flipped = try #require(hosted.codeRows.first)
        #expect(flipped === row, "the row view is kept across a flip")
        #expect(flipped.overrideUserInterfaceStyle == .dark)
        #expect(flipped.attributed === string, "no conversion")
        #expect(flipped.relayoutCount == 1, "a flip lays nothing out: \(flipped.relayoutCount) layouts")
        #expect(flipped.drawn == natural)

        // A new text size: new inputs, one more layout.
        hosted.show(codeBlock(.accessibility1, .dark))
        try await hosted.settle()
        let resized = try #require(hosted.codeRows.first, "8 lines of 39 columns are still within the canvas bound at AX1")
        #expect(resized.inputs?.sizeCategory == .accessibilityMedium)
        #expect(resized.relayoutCount == (resized === row ? 2 : 1), "\(resized.relayoutCount) layouts after the size change")
        #expect(resized.cachedWidths == [.infinity], "cached \(resized.cachedWidths)")
        let larger = resized.layoutResult(forProposedWidth: nil)
        #expect(larger.lineCount == 8)
        #expect(larger.size.height > natural.size.height && larger.size.width > natural.size.width)
        #expect(resized.drawn == larger && resized.drawnShift == 0)
        #expect(abs(resized.bounds.width - larger.size.width) < 0.01 && abs(resized.bounds.height - larger.size.height) < 0.01,
                "placed \(resized.bounds.size), measured \(larger.size)")
    }

    @Test("hosted: a code block replaced under its stable id draws, labels and lays out the new code")
    func hostedStableIDReplacement() async throws {
        let old = "let a = 1"
        let new = "let a = 1\nlet b = 2\nprint(a + b) // replaced under the same id"
        let oldData = try TK2CodeLogic.document([TK2CodeLogic.code(old), TK2CodeLogic.paragraph("After the code")])
        let newData = try TK2CodeLogic.document([TK2CodeLogic.code(new), TK2CodeLogic.paragraph("After the code")])
        let model = try await TK2CodeLogic.loadedModel(oldData)
        let hosted = TK2CodeLogic.Hosted(TK2CodeLogic.documentView(model, .textKit2))
        defer { hosted.close() }
        try await hosted.settle()
        let row = try #require(hosted.codeRows.first { $0.ownerID == "0.0" })
        #expect(row.accessibilityLabel == old)
        let oldString = row.attributed
        let oldRelayouts = row.relayoutCount
        let oldSize = row.bounds.size

        let prepared = try await TK2CodeLogic.prepared(newData)
        let replacement = try #require(prepared.first { $0.id == "0.0" })
        try await model.apply([.replace(itemID: "0.0", block: replacement)], revision: 1)
        try await hosted.settle()

        let rows = hosted.codeRows.filter { $0.ownerID == "0.0" }
        #expect(rows.count == 1, "one row for the owner")
        let replaced = try #require(rows.first)
        #expect(replaced.accessibilityLabel == new)
        #expect(replaced.attributed.string == new, "drawing \(replaced.attributed.string)")
        #expect(replaced.attributed !== oldString, "the text changed but the row kept its converted string")
        #expect(replaced.cachedWidths == [.infinity], "cached \(replaced.cachedWidths)")
        let layout = try #require(replaced.drawn, "the row never synced to its new bounds")
        #expect(layout.lineCount == 3)
        #expect(layout.lines.last?.range.upperBound == (new as NSString).length, "the drawn lines end where the new code does")
        #expect(replaced.relayoutCount == (replaced === row ? oldRelayouts + 1 : 1), "\(replaced.relayoutCount) layouts")
        // Placed at the new content's size.
        #expect(abs(replaced.bounds.width - layout.size.width) < 0.01 && abs(replaced.bounds.height - layout.size.height) < 0.01,
                "placed \(replaced.bounds.size), laid out \(layout.size)")
        #expect(replaced.bounds.height > oldSize.height && replaced.bounds.width > oldSize.width)
        // The layout a fresh row computes for the same inputs.
        let inputs = try #require(replaced.inputs)
        let fresh = Self.codeRow(inputs)
        #expect(fresh.layoutResult(forProposedWidth: nil) == layout)
        // The other block's row is untouched.
        #expect(hosted.owners == ["0.0", "0.1"])
    }
}
#endif
