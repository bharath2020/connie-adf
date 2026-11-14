#if canImport(UIKit)
import SwiftUI
import UIKit
import Testing
import ADFModel
import ADFPreparation
@testable import ADFRendering

// Code blocks on the shared TextKit 2 row: hosted size and pixel parity
// against the SwiftUI arm, and the measure-first experiments (E1 to E5).
// Both arms are the real `BlockView` → `CodeBlockView` (or the real
// `ADFDocumentView`), chosen through the environment; nothing is a double.
//
// Suites (each is one `-only-testing:ADFRenderingTests/<type>` filter):
//
//   TextKit2CodeParitySmokeTests    every E2 shape at Large, regular weight
//   TextKit2CodeParityTests         the whole E2 matrix (shape × 6 sizes × 2
//                                   weights), dark, breakout documents
//   TextKit2CodeShapeExperiments    record only: shapes outside the admitted
//                                   cohort forced onto the row; never fails
//   TextKit2CodeMeasureFirstTests   E1 proposals, E3 canvas ladder, E4 pan
//                                   across renderer flips, E5 accessibility
//   TextKit2CodeAdapterTests        narrow outer frames, pan, and the
//                                   row-to-window conversion under a pan
//
// Every measured case prints one machine-readable line:
//
//   CODE_E2 shape=… size=… weight=… scale=… os=… dH=… dW=… inkExact=… diffPct=… <more key=value>

/// Samples, classification and the per-case measurement the code suites
/// share. Not a suite: nothing here asserts; a measurement returns its
/// failures, so a record-only experiment can print them instead.
enum TK2CodeParity {
    /// Heights and widths agree within this many points.
    static let tolerance: CGFloat = 0.01
    /// At most this fraction of pixels may differ by more than 24 in a channel.
    static let maxDifferingFraction = 0.002
    /// The column a 402 pt phone gives a top-level block (`ADFDocumentView`
    /// insets 16 pt a side).
    static let phoneWidth: CGFloat = 370
    /// Image caps, in pixels. A canvas the gate admits (at most 8,192 px a
    /// side and 16 MiB) always fits with its chrome; only blocks over the
    /// bound, which stay on SwiftUI, are cut.
    static let maxImageDimension = 8_400
    static let maxImagePixels = 12_000_000

    // MARK: Samples

    /// What the content verdict must say of a sample's prepared text.
    enum Cohort: Sendable, Equatable {
        /// Printable ASCII and LF, at most one trailing line feed.
        case admitted
        /// Admitted from iOS 26; `.trailingBreaks` before it.
        case trailingBreaks
        case fallback(TextKit2Eligibility.Fallback)
    }

    /// One row of the plan's E2 shape list.
    struct Sample: Sendable, CustomStringConvertible {
        let name: String
        let text: String
        var language: String? = "swift"
        var direction: LayoutDirection = .leftToRight
        var cohort: Cohort = .admitted
        /// Pinned by hand: the gate must admit the sample at every size up
        /// to and including this one (left to right). Past it, and for a
        /// sample with none, the gate's own answer is taken, so a gate that
        /// rejected everything would still fail here.
        var admittedThrough: DynamicTypeSize? = nil
        /// Pinned by hand: over the canvas bound at every size and scale.
        var overBudget = false

        var description: String { name }
    }

    /// Eight lines, every one under 40 columns.
    static let eightLines = [
        "func area(of rect: Rect) -> Double {",
        "    let width = rect.maxX - rect.minX",
        "    let height = rect.maxY - rect.minY",
        "    guard width > 0, height > 0 else {",
        "        return 0",
        "    }",
        "    return width * height  // points^2",
        "}",
    ].joined(separator: "\n")

    /// One 300-column line among short ones.
    static let threeHundredColumns = "let short = 1\n" + String(repeating: "0123456789", count: 30) + "\nlet end = 2"

    /// A Hebrew and an Arabic string literal.
    static let bidi = "let shalom = \"\u{05E9}\u{05DC}\u{05D5}\u{05DD}\"\nlet salaam = \"\u{0633}\u{0644}\u{0627}\u{0645}\" // rtl"

    /// 400 lines of 60 columns: over the bound at every size on 2x and 3x.
    static let overBudgetText = Array(repeating: String(repeating: "abcdefghi ", count: 6), count: 400).joined(separator: "\n")

    /// Six 130-column lines: admitted at Large, about 1,350 pt wide there,
    /// so a phone viewport pans across it.
    static let wideBlock = (0..<6).map { index in
        "let value\(index) = \"" + String(repeating: "abcdefghij", count: 11) + "\" // #"
    }.joined(separator: "\n")

    static let samples: [Sample] = [
        Sample(name: "short", text: "let x = 1", admittedThrough: .accessibility5),
        Sample(name: "eight-lines", text: eightLines, admittedThrough: .xxxLarge),
        Sample(name: "language-nil", text: eightLines, language: nil, admittedThrough: .xxxLarge),
        Sample(name: "language-empty", text: eightLines, language: "", admittedThrough: .xxxLarge),
        Sample(name: "blank-middle-1", text: "let a = 1\n\nlet b = 2", admittedThrough: .accessibility5),
        Sample(name: "blank-middle-3", text: "let a = 1\n\n\n\nlet b = 2", admittedThrough: .accessibility5),
        Sample(name: "leading-blank", text: "\nlet a = 1\nlet b = 2", admittedThrough: .accessibility5),
        Sample(name: "trailing-1", text: "let a = 1\nlet b = 2\n", admittedThrough: .accessibility5),
        Sample(name: "trailing-2", text: "let a = 1\nlet b = 2\n\n", cohort: .trailingBreaks),
        Sample(name: "trailing-3", text: "let a = 1\nlet b = 2\n\n\n", cohort: .trailingBreaks),
        Sample(name: "whitespace-line", text: "if ready {\n    \n    start(now)      \n}", admittedThrough: .accessibility5),
        Sample(name: "long-300", text: threeHundredColumns),
        Sample(name: "tabs", text: "\tindented by a tab\nkey\tvalue\n\t\tdeeper", cohort: .fallback(.codeTabs)),
        Sample(name: "emoji-cjk", text: "let total = 3 // \u{1F600} \u{5408}\u{8A08}\nprint(total)", cohort: .fallback(.codeNonASCII)),
        Sample(name: "combining", text: "let cafe\u{301} = 1 // a\u{308}\nlet n = 2", cohort: .fallback(.codeNonASCII)),
        Sample(name: "hebrew-arabic", text: bidi, cohort: .fallback(.codeNonASCII)),
        Sample(name: "hebrew-arabic-rtl", text: bidi, direction: .rightToLeft, cohort: .fallback(.codeNonASCII)),
        Sample(name: "ascii-rtl", text: eightLines, direction: .rightToLeft),
        Sample(name: "crlf", text: "let a = 1\r\nlet b = 2\r\nlet c = 3", cohort: .fallback(.codeLineBreaks)),
        Sample(name: "cr", text: "let a = 1\rlet b = 2", cohort: .fallback(.codeLineBreaks)),
        Sample(name: "line-separator", text: "let a = 1\u{2028}let b = 2", cohort: .fallback(.codeLineBreaks)),
        Sample(name: "empty", text: "", cohort: .fallback(.empty)),
        Sample(name: "newline-only", text: "\n", cohort: .fallback(.empty)),
        Sample(name: "over-budget", text: overBudgetText, overBudget: true),
    ]

    /// The samples the content verdict keeps on SwiftUI that the shape seam
    /// can force onto the row (`TK2Parity.restamped`): not the empty string
    /// (no run to stamp) and not the right-to-left ones (the gate reads the
    /// layout direction SwiftUI reads; no seam, and none wanted).
    static let experimentSamples: [Sample] = samples.filter { sample in
        sample.cohort != .admitted && sample.direction == .leftToRight && !sample.text.isEmpty
    }

    static let sizes: [DynamicTypeSize] = [.xSmall, .large, .xxxLarge, .accessibility1, .accessibility3, .accessibility5]

    /// Six sizes × regular and bold legibility.
    static let environments: [TK2Parity.Environment] = sizes.flatMap { size in
        [TK2Parity.Environment(size: size), TK2Parity.Environment(size: size, legibility: .bold)]
    }

    /// A length for a result line: three decimals.
    static func n(_ value: CGFloat) -> String { String(format: "%.3f", Double(value)) }

    /// The display scale for a result line: "2", "3".
    static func scaleText(_ scale: CGFloat) -> String { String(format: "%g", Double(scale)) }

    /// Prints one machine-readable result line: a tag, then `key=value` fields.
    static func emit(_ tag: String, _ fields: [String]) {
        print(([tag] + fields).joined(separator: " "))
    }

    // MARK: Classification

    struct Classification {
        /// Whether the TextKit 2 arm must draw the code with a TextKit 2 row.
        var textKit2: Bool
        /// "admitted", a `TextKit2Eligibility.Fallback` case, "direction" or "canvas".
        var reason: String
        var failures: [String]
    }

    /// Which engine must draw `code` under `env` at `scale`. The content
    /// verdict is pinned by hand per sample (`Sample.cohort`); the
    /// view-time answer is the gate's, with the hand-pinned anchors of
    /// `Sample.admittedThrough`, `Sample.overBudget` and right-to-left.
    @MainActor
    static func classify(_ sample: Sample, code: AttributedString, env: TK2Parity.Environment, scale: CGFloat) -> Classification {
        var failures: [String] = []
        var eligible = false
        var reason = "admitted"
        switch TextKit2Eligibility.codeVerdict(code) {
        case .eligible:
            eligible = true
        case .fallback(let fallback):
            reason = "\(fallback)"
        }
        let expected: String
        switch sample.cohort {
        case .admitted:
            expected = "admitted"
        case .trailingBreaks:
            expected = TextKit2Eligibility.trailingBreaksMatchText ? "admitted" : "\(TextKit2Eligibility.Fallback.trailingBreaks)"
        case .fallback(let fallback):
            expected = "\(fallback)"
        }
        if reason != expected { failures.append("content verdict: expected \(expected), got \(reason)") }
        guard eligible else { return Classification(textKit2: false, reason: reason, failures: failures) }

        let gate = TextKit2Scope.codeGate(
            code, sizeCategory: env.size.uiContentSizeCategory, legibilityWeight: env.legibility,
            displayScale: scale, layoutDirection: env.direction
        )
        switch gate {
        case .none:
            break
        case .some(.direction):
            reason = "direction"
        case .some(.canvas):
            reason = "canvas"
        }
        if env.direction == .rightToLeft {
            if gate != .direction { failures.append("gate: right-to-left code must stay on SwiftUI (direction), got \(reason)") }
        } else if sample.overBudget {
            if gate != .canvas { failures.append("gate: \(sample.name) must be over the canvas bound, got \(reason)") }
        } else if let through = sample.admittedThrough, env.size <= through, gate != nil {
            failures.append("gate: \(sample.name) must be admitted at \(env.size), got \(reason)")
        }
        return Classification(textKit2: gate == nil, reason: reason, failures: failures)
    }

    // MARK: Measurement

    struct Comparison {
        var inkExact = false
        /// Fraction of compared pixels differing by more than 24 in a channel.
        var fraction = 0.0
        var extras: [String] = []
        var failures: [String] = []
        /// The TextKit 2 canvas's backing size, "WxH" pixels.
        var canvasPixels = "none"
        /// Ink in the last character cell of the row's longest line.
        var farRightInk = false
        /// Ink on the last line that has visible text.
        var lastLineInk = false
    }

    struct Outcome {
        var line: String
        var failures: [String]
        var textKit2Rows: Int
        var comparison: Comparison
    }

    /// Measures one code block on both arms and prints its `CODE_E2` line.
    ///
    /// Per arm: the whole view's size at `phoneWidth`, the horizontal scroll
    /// view's viewport and content size there (the content width is the
    /// scroll range), and a bitmap of the block in a window as wide as its
    /// natural content, so every pixel of the code is compared, not just a
    /// phone viewport's.
    ///
    /// `expectTextKit2`: `true`, the TextKit 2 arm must hold exactly one
    /// row; `false`, none; `nil`, record only. Whatever was expected, a
    /// block the row drew is compared by the parity rule (sizes within
    /// 0.01 pt, ink extents exact, at most 0.2 % of pixels over 24) and a
    /// block it did not is compared for exact equality.
    @MainActor
    static func measure(
        name: String, block: RenderBlock, env: TK2Parity.Environment, expectTextKit2: Bool?, reason: String, suite: String,
        prior: [String] = [], checkBound: Bool = true
    ) async throws -> Outcome {
        var failures = prior
        let label = "\(name) \(env)"
        let scale = TK2Parity.nativeScale
        let maxPoints = (CGFloat(maxImageDimension) / scale).rounded(.down)
        let arms: [ADFTextRenderer] = [.swiftUI, .textKit2]
        let code = try TK2Parity.codeParts(block).code
        func windowHeight(_ height: CGFloat) -> CGFloat { min(max(height.rounded(.up) + 16, 64), maxPoints + 16) }

        var hosts: [TK2Parity.Host] = []
        defer {
            for host in hosts { host.close() }
        }

        // 1. At the phone column: view size, viewport, content size.
        var sizes: [CGSize] = []
        var viewports: [CGRect] = []
        var contents: [CGSize] = []
        for arm in arms {
            let view = TK2Parity.hostedCode(block, arm: arm, env: env)
            let size = TK2Parity.attachedSize(view, width: phoneWidth)
            let host = TK2Parity.Host(view, width: phoneWidth, height: windowHeight(size.height), dark: env.dark)
            hosts.append(host)
            try await host.settle()
            guard let scroll = TK2Parity.scrollViews(in: host.view).first else {
                throw TestFailure("\(label) \(arm): no horizontal scroll view")
            }
            sizes.append(size)
            viewports.append(scroll.convert(scroll.bounds, to: nil))
            contents.append(scroll.contentSize)
        }
        let phone = hosts

        // 2. At the natural width: the whole code, rendered (capped).
        let natural = max(contents[0].width, contents[1].width).rounded(.up)
        let viewHeight = max(sizes[0].height, sizes[1].height)
        var render = phone
        var renderWidth = phoneWidth
        if natural > phoneWidth {
            renderWidth = natural
            render = []
            for arm in arms {
                let host = TK2Parity.Host(
                    TK2Parity.hostedCode(block, arm: arm, env: env),
                    width: renderWidth, height: windowHeight(viewHeight), dark: env.dark
                )
                hosts.append(host)
                render.append(host)
                try await host.settle()
            }
        }
        let imageWidth = min(renderWidth, maxPoints)
        let areaHeight = (CGFloat(maxImagePixels) / (imageWidth * scale) / scale).rounded(.down)
        let imageHeight = max(min(viewHeight.rounded(.up), maxPoints, areaHeight), 1)
        let capped = imageWidth < renderWidth || imageHeight < viewHeight.rounded(.up)
        let rect = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        let diagnostics = TextKit2Diagnostics.shared
        let a = try TK2Parity.bitmap(of: render[0].window, in: rect)
        // No suspension between the two reads: the counter is process-wide.
        let drawsBefore = diagnostics.codeNativeDrawCount
        let b = try TK2Parity.bitmap(of: render[1].window, in: rect)
        let renderDraws = diagnostics.codeNativeDrawCount - drawsBefore

        // 3. The engine that drew it.
        let rows = TextKit2FallbackTests.rows(in: render[1].view)
        let stray = TextKit2FallbackTests.rows(in: render[0].view).count + TextKit2FallbackTests.rows(in: phone[0].view).count
        if stray > 0 { failures.append("the SwiftUI arm holds \(stray) TextKit 2 rows") }
        let phoneRows = TextKit2FallbackTests.rows(in: phone[1].view).count
        if phoneRows != rows.count {
            failures.append("TextKit 2 rows: \(phoneRows) at \(n(phoneWidth)) pt, \(rows.count) at \(n(renderWidth)) pt")
        }
        if let expectTextKit2 {
            if expectTextKit2, rows.count != 1 {
                failures.append("expected one TextKit 2 row (\(reason)), found \(rows.count)")
            }
            if !expectTextKit2, !rows.isEmpty {
                failures.append("expected SwiftUI (\(reason)), found \(rows.count) TextKit 2 rows")
            }
            if capped, !rows.isEmpty {
                failures.append("a TextKit 2 block was cut by the image cap (\(n(imageWidth))x\(n(imageHeight)) pt)")
            }
        }

        // 4. Sizes: within the tolerance against a row, equal without one.
        let allowed: CGFloat = rows.isEmpty ? 0 : tolerance
        let dH = sizes[1].height - sizes[0].height
        let dW = contents[1].width - contents[0].width
        if abs(dH) > allowed || abs(sizes[1].width - sizes[0].width) > allowed {
            failures.append("view size swiftUI=\(sizes[0]) textKit2=\(sizes[1])")
        }
        if abs(dW) > allowed || abs(contents[1].height - contents[0].height) > allowed {
            failures.append("scroll content size swiftUI=\(contents[0]) textKit2=\(contents[1])")
        }
        let v0 = viewports[0]
        let v1 = viewports[1]
        let originMoved = abs(v1.minX - v0.minX) > allowed || abs(v1.minY - v0.minY) > allowed
        let sizeMoved = abs(v1.width - v0.width) > allowed || abs(v1.height - v0.height) > allowed
        if originMoved || sizeMoved { failures.append("viewport swiftUI=\(v0) textKit2=\(v1)") }

        // 5. Pixels.
        let comparison: Comparison
        if rows.count == 1, let scroll = TK2Parity.scrollViews(in: render[1].view).first {
            comparison = compareTextKit2(a, b, row: rows[0], scroll: scroll, block: block, code: code, env: env, checkBound: checkBound)
        } else {
            comparison = compareExact(a, b)
        }
        failures += comparison.failures

        let weight = env.legibility == .bold ? "bold" : "regular"
        let percent = String(format: "%.4f", comparison.fraction * 100)
        let engine = rows.isEmpty ? "swiftui" : "textkit2"
        var fields: [String] = [
            "CODE_E2", "shape=\(name)", "size=\(env.size)", "weight=\(weight)",
            "scale=\(scaleText(scale))", "os=\(TK2Parity.osVersion)",
            "dH=\(n(dH))", "dW=\(n(dW))", "inkExact=\(comparison.inkExact)", "diffPct=\(percent)",
        ]
        fields += [
            "arm=\(engine)", "reason=\(reason)", "suite=\(suite)",
            "natural=\(n(contents[0].width))x\(n(contents[0].height))",
            "view=\(n(sizes[0].width))x\(n(sizes[0].height))",
            "capped=\(capped)", "renderDraws=\(renderDraws)",
        ]
        if env.direction == .rightToLeft { fields.append("dir=rtl") }
        if env.dark { fields.append("dark=true") }
        fields += comparison.extras
        fields.append("pass=\(failures.isEmpty)")
        let line = fields.joined(separator: " ")
        print(line)
        return Outcome(line: line, failures: failures.map { "\(label): \($0)" }, textKit2Rows: rows.count, comparison: comparison)
    }

    /// Two renders that must be the same view: every pixel equal.
    static func compareExact(_ a: TK2Parity.Bitmap, _ b: TK2Parity.Bitmap) -> Comparison {
        var result = Comparison()
        guard a.width == b.width, a.height == b.height else {
            result.failures.append("bitmaps differ in size: \(a.width)x\(a.height) and \(b.width)x\(b.height)")
            return result
        }
        let exact = TK2Parity.differingPixels(a, b, columns: 0..<a.width, rows: 0..<a.height, threshold: 0)
        result.inkExact = exact.count == 0
        result.extras.append("exactDiffPx=\(exact.count)")
        if exact.count != 0 {
            let rule = TK2Parity.differingPixels(a, b, columns: 0..<a.width, rows: 0..<a.height)
            result.fraction = rule.total == 0 ? 0 : Double(rule.count) / Double(rule.total)
            result.failures.append("\(exact.count) of \(exact.total) pixels differ although no TextKit 2 row drew")
        }
        return result
    }

    /// A SwiftUI render (`a`) against one whose code a TextKit 2 row drew
    /// (`b`), by the parity rule:
    /// - the row is one native TextKit 2 row with the natural layout
    ///   policy, laid out once, placed at its natural size, unshifted, on a
    ///   canvas within its admitted bound;
    /// - ink (any channel more than 8 off the box's fill) over the text
    ///   region, the row's frame and 6 pt around it: first and last ink row
    ///   equal, and each line's first and last ink column equal; a line
    ///   with visible text has ink;
    /// - at most 0.2 % of the region's pixels between the first and last
    ///   ink row differ by more than 24 in a channel;
    /// - nothing outside the region (badge, Copy, box, the rest of the
    ///   viewport) differs at all.
    ///
    /// Recorded in the line, not asserted: ink counts per pixel row
    /// (`inkRowCounts`) and how many mismatching lines have no pixel over
    /// 24 (`inkFaint`: the SF Mono edge-row effect of the stack doc's
    /// residual 3, which is not exempted here).
    @MainActor
    static func compareTextKit2(
        _ a: TK2Parity.Bitmap, _ b: TK2Parity.Bitmap, row: TextKit2RowView, scroll: UIScrollView,
        block: RenderBlock, code: AttributedString, env: TK2Parity.Environment, checkBound: Bool
    ) -> Comparison {
        var result = Comparison()
        guard a.width == b.width, a.height == b.height, a.width > 0, a.height > 0 else {
            result.failures.append("bitmaps differ in size: \(a.width)x\(a.height) and \(b.width)x\(b.height)")
            return result
        }
        let scale = a.scale
        let category = env.size.uiContentSizeCategory
        func px(_ value: CGFloat, _ rule: FloatingPointRoundingRule) -> Int { Int((value * scale).rounded(rule)) }

        // The row.
        let natural = row.measuredSize(forProposedWidth: nil)
        var faults: [String] = []
        if row.accessibilityIdentifier != "tk2-row:\(block.id)" { faults.append("identifier \(row.accessibilityIdentifier ?? "nil")") }
        if row.ownerKind != .code { faults.append("owner kind \(row.ownerKind)") }
        if row.inputs?.layoutPolicy != .natural { faults.append("layout policy is not natural") }
        if row.isTextKit1Backed { faults.append("TextKit 1-backed") }
        if row.relayoutCount != 1 { faults.append("\(row.relayoutCount) layouts") }
        if row.currentContainerWidth != 1_000_000 { faults.append("container width \(row.currentContainerWidth)") }
        if row.cachedWidths != [.infinity] { faults.append("cached widths \(row.cachedWidths)") }
        if row.drawnShift != 0 { faults.append("shift \(row.drawnShift)") }
        if abs(row.bounds.width - natural.width) > tolerance || abs(row.bounds.height - natural.height) > tolerance {
            faults.append("placed at \(row.bounds.size), natural size \(natural)")
        }
        if !faults.isEmpty { result.failures.append("row: " + faults.joined(separator: ", ")) }

        // Actual canvas ≤ admitted bound ≤ caps.
        let canvasWidth = Int((row.canvasFrame.width * scale - 0.01).rounded(.up))
        let canvasHeight = Int((row.canvasFrame.height * scale - 0.01).rounded(.up))
        result.canvasPixels = "\(canvasWidth)x\(canvasHeight)"
        result.extras.append("canvasPx=\(result.canvasPixels)")
        let bound = TextKit2Scope.codeCanvasBound(
            code, sizeCategory: category, legibilityWeight: env.legibility, displayScale: scale
        )
        if let bound {
            result.extras.append("boundPx=\(bound.pixelWidth)x\(bound.pixelHeight)")
            result.extras.append("boundBytes=\(bound.nominalBytes)")
            if checkBound, canvasWidth > bound.pixelWidth || canvasHeight > bound.pixelHeight {
                result.failures.append("canvas \(canvasWidth)x\(canvasHeight) px is over its admitted bound \(bound.pixelWidth)x\(bound.pixelHeight) px")
            }
            if checkBound, !bound.isWithinCaps { result.failures.append("the admitted bound is over a cap") }
        } else {
            result.extras.append("boundPx=none")
            if checkBound { result.failures.append("a TextKit 2 row drew code that has no admitted canvas bound") }
        }

        // TextKit 2 draws it natively (no suspension in this span).
        let diagnostics = TextKit2Diagnostics.shared
        let drawsBefore = diagnostics.codeNativeDrawCount
        for canvas in row.subviews {
            canvas.setNeedsDisplay()
            canvas.layer.displayIfNeeded()
        }
        let nativeDraws = diagnostics.codeNativeDrawCount - drawsBefore
        result.extras.append("nativeDraws=\(nativeDraws)")
        if nativeDraws < 1 { result.failures.append("the row did not draw natively") }

        // The text region: the row's frame and half the code padding around
        // it. It stays clear of the box's edges and corner arcs, which
        // would read as ink on both arms and hide a moved first or last
        // ink row; ink that left it would show as a chrome difference.
        let rowFrame = row.convert(row.bounds, to: nil)
        let viewport = scroll.convert(scroll.bounds, to: nil)
        let slack = TK2Parity.theme.spacing * 0.75
        let left = px(rowFrame.minX - slack, .down)
        let columns = left..<max(px(rowFrame.maxX + slack, .up), left)
        let topEdge = px(rowFrame.minY - slack, .down)
        let rows = topEdge..<max(px(rowFrame.maxY + slack, .up), topEdge)
        let top = min(max(topEdge, 0), a.height)

        let sampleX = min(max(px(viewport.minX + 3, .down), 0), a.width - 1)
        let sampleY = min(max(px(viewport.midY, .down), 0), a.height - 1)
        let background = a[sampleX, sampleY]
        if background != b[sampleX, sampleY] { result.failures.append("the box fill differs between the arms") }

        let inkA = TK2Parity.rowInk(a, columns: columns, rows: rows, background: background)
        let inkB = TK2Parity.rowInk(b, columns: columns, rows: rows, background: background)
        let edgesMatch = inkA.firstRow == inkB.firstRow && inkA.lastRow == inkB.lastRow
        if !edgesMatch {
            let edgesA = "\(String(describing: inkA.firstRow))...\(String(describing: inkA.lastRow))"
            let edgesB = "\(String(describing: inkB.firstRow))...\(String(describing: inkB.lastRow))"
            result.failures.append("ink rows swiftUI=\(edgesA) textKit2=\(edgesB)")
        }

        // Per line: first and last ink column.
        let layout = row.layoutResult(forProposedWidth: nil)
        let string = NSString(string: String(code.characters))
        var mismatched = 0
        var faint = 0
        var inkless = 0
        var described = 0
        var rightmost: Int?
        for (index, line) in layout.lines.enumerated() {
            let lower = px(rowFrame.minY + line.frame.minY, .toNearestOrAwayFromZero) - top
            let upper = px(rowFrame.minY + line.frame.maxY, .toNearestOrAwayFromZero) - top
            let band = lower..<max(upper, lower)
            let extentA = inkA.extent(rows: band)
            let extentB = inkB.extent(rows: band)
            if let extentB { rightmost = max(rightmost ?? extentB.upperBound, extentB.upperBound) }
            let range = line.range
            let lineText = range.location + range.length <= string.length ? string.substring(with: range) : ""
            let visible = lineText.contains { !$0.isWhitespace }
            if visible { result.lastLineInk = extentB != nil }
            if extentA != extentB {
                mismatched += 1
                let over = TK2Parity.differingPixels(a, b, columns: columns, rows: (band.lowerBound + top)..<(band.upperBound + top))
                if over.count == 0 { faint += 1 }
                if described < 4 {
                    described += 1
                    result.failures.append("line \(index) ink columns swiftUI=\(String(describing: extentA)) textKit2=\(String(describing: extentB))")
                }
            } else if extentA == nil, visible {
                inkless += 1
                result.failures.append("line \(index) has visible text and no ink on either arm")
            }
        }
        if mismatched > described { result.failures.append("\(mismatched) lines differ in ink columns in all") }
        result.inkExact = edgesMatch && mismatched == 0 && inkless == 0
        result.extras.append("inkBands=\(mismatched)/\(layout.lines.count)")
        result.extras.append("inkFaint=\(faint)")
        let countPairs = zip(inkA.counts, inkB.counts)
        result.extras.append("inkRowCounts=\(countPairs.filter { pair in pair.0 != pair.1 }.count)")

        // The far right: TextKit 2 ink, on a line, in the last character
        // cell of the longest line (the row is as wide as that line).
        if let spec = TK2Parity.theme.codeFontSpec,
           let metrics = TextKit2CodeMetrics.metrics(for: spec, category: category, legibilityWeight: env.legibility),
           let rightmost {
            result.farRightInk = rightmost >= px(rowFrame.maxX - metrics.advance, .down)
        }
        result.extras.append("rightInk=\(result.farRightInk)")
        result.extras.append("lastLineInk=\(result.lastLineInk)")

        // Differing pixels over the text region, first to last ink row.
        let firstRows = [inkA.firstRow, inkB.firstRow].compactMap { $0 }
        let lastRows = [inkA.lastRow, inkB.lastRow].compactMap { $0 }
        if let first = firstRows.min(), let last = lastRows.max() {
            let diff = TK2Parity.differingPixels(a, b, columns: columns, rows: (top + first)..<(top + last + 1))
            result.fraction = diff.total == 0 ? 0 : Double(diff.count) / Double(diff.total)
            result.extras.append("diffPx=\(diff.count)/\(diff.total)")
        }
        if result.fraction > maxDifferingFraction {
            result.failures.append("\(String(format: "%.4f", result.fraction * 100)) % of pixels differ by more than 24")
        }

        // Everything outside the text region is the same SwiftUI on both arms.
        let whole = TK2Parity.differingPixels(a, b, columns: 0..<a.width, rows: 0..<a.height, threshold: 0).count
        let inside = TK2Parity.differingPixels(a, b, columns: columns, rows: rows, threshold: 0).count
        result.extras.append("chromeDiff=\(whole - inside)")
        if whole != inside { result.failures.append("\(whole - inside) pixels differ outside the code text (badge, Copy, box)") }
        return result
    }

    /// Prepares `sample`, classifies it under `env` and measures it; every
    /// failure is one recorded issue.
    @MainActor
    static func check(_ sample: Sample, env: TK2Parity.Environment, suite: String) async throws {
        var env = env
        env.direction = sample.direction
        let block = try await TK2Parity.codeBlock(sample.text, language: sample.language)
        let code = try TK2Parity.codeParts(block).code
        // The text under test is the text written above, scalar for scalar.
        let prepared = Array(String(code.characters).unicodeScalars)
        #expect(prepared == Array(sample.text.unicodeScalars), "\(sample.name): preparation changed the code's scalars")
        let expected = classify(sample, code: code, env: env, scale: TK2Parity.nativeScale)
        let outcome = try await measure(
            name: sample.name, block: block, env: env, expectTextKit2: expected.textKit2, reason: expected.reason,
            suite: suite, prior: expected.failures
        )
        let report = outcome.failures.joined(separator: "\n")
        #expect(outcome.failures.isEmpty, "\(report)")
    }

    // MARK: Documents

    @MainActor
    static func loadedModel(_ data: Data) async throws -> ADFDocumentModel {
        let model = ADFDocumentModel()
        model.load(data: data)
        for _ in 0..<500 where model.phase != .ready {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard model.phase == .ready else { throw TestFailure("the document did not load") }
        return model
    }

    // MARK: E1

    /// Records every proposal its one subview is sized and placed at, and
    /// passes each through unchanged.
    struct ProposalProbe: Layout {
        /// Not `@Sendable`: it appends to a local of the main-actor test that
        /// makes it, and SwiftUI calls a layout on the main thread only.
        nonisolated(unsafe) let record: (String, ProposedViewSize, CGSize) -> Void

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let size = subviews[0].sizeThatFits(proposal)
            record("size", proposal, size)
            return size
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            record("place", proposal, bounds.size)
            subviews[0].place(at: bounds.origin, proposal: proposal)
        }
    }

    // MARK: E5

    /// One element an assistive technology would visit.
    struct SpokenElement: Equatable, CustomStringConvertible {
        let label: String
        let traits: UInt64

        var description: String {
            "\(label.replacingOccurrences(of: "\n", with: "\\n").prefix(48))|\(traits)"
        }
    }

    /// The accessibility elements under `object`, in the order its
    /// containers list them: an element is a leaf; a container is walked
    /// through `accessibilityElements`, then the indexed protocol, then
    /// subviews.
    @MainActor
    static func spokenElements(under object: NSObject, depth: Int = 0) -> [SpokenElement] {
        guard depth < 64 else { return [] }
        if object.isAccessibilityElement {
            return [SpokenElement(label: object.accessibilityLabel ?? "", traits: object.accessibilityTraits.rawValue)]
        }
        if let elements = object.accessibilityElements, !elements.isEmpty {
            let children = elements.compactMap { $0 as? NSObject }
            return children.flatMap { spokenElements(under: $0, depth: depth + 1) }
        }
        let count = object.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
            let children = (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject }
            return children.flatMap { spokenElements(under: $0, depth: depth + 1) }
        }
        if let view = object as? UIView {
            return view.subviews.flatMap { spokenElements(under: $0, depth: depth + 1) }
        }
        return []
    }
}

// MARK: - Smoke

/// The quick subset: every E2 shape once, at Large and regular weight.
/// `-only-testing:ADFRenderingTests/TextKit2CodeParitySmokeTests`
@Suite("TextKit 2 code parity: smoke", .serialized)
@MainActor
struct TextKit2CodeParitySmokeTests {
    @Test("every E2 shape at Large, regular weight", arguments: TK2CodeParity.samples)
    func shape(sample: TK2CodeParity.Sample) async throws {
        try await TK2CodeParity.check(sample, env: TK2Parity.Environment(size: .large), suite: "smoke")
    }
}

// MARK: - The matrix

/// The E2 matrix. Admitted shapes must really be on a TextKit 2 row
/// (`tk2-row:<id>`, drawn natively) and match by the parity rule; shapes
/// the content verdict or the gate keeps on SwiftUI must hold no row and
/// match exactly. `-only-testing:ADFRenderingTests/TextKit2CodeParityTests`
@Suite("TextKit 2 code parity", .serialized)
@MainActor
struct TextKit2CodeParityTests {
    @Test("E2: every shape at every size and weight", arguments: TK2CodeParity.samples, TK2CodeParity.environments)
    func matrix(sample: TK2CodeParity.Sample, env: TK2Parity.Environment) async throws {
        try await TK2CodeParity.check(sample, env: env, suite: "parity")
    }

    @Test("E2: dark appearance", arguments: ["short", "eight-lines", "blank-middle-3", "tabs"])
    func dark(name: String) async throws {
        let sample = try #require(TK2CodeParity.samples.first { $0.name == name })
        try await TK2CodeParity.check(sample, env: TK2Parity.Environment(size: .large, dark: true), suite: "parity")
    }

    /// Breakout `wide` and `full-width` through the real `ADFDocumentView`:
    /// a document of code blocks only, so every pixel outside a code
    /// viewport must be the same on both arms.
    @Test("E2: breakout wide and full-width through ADFDocumentView", arguments: [DynamicTypeSize.large, .accessibility1])
    func breakoutDocument(size: DynamicTypeSize) async throws {
        let data = try TK2Parity.documentData([
            TK2Parity.codeBlockNode(TK2CodeParity.eightLines, language: "swift"),
            TK2Parity.codeBlockNode(TK2CodeParity.eightLines, language: "swift", breakout: "wide"),
            TK2Parity.codeBlockNode(TK2CodeParity.eightLines, language: nil, breakout: "full-width"),
            TK2Parity.codeBlockNode(TK2CodeParity.wideBlock, language: "swift", breakout: "wide"),
        ])
        let blocks = try await TK2Parity.blocks(json: data)
        try #require(blocks.count == 4)
        let documentWidth: CGFloat = 402
        let windowHeight: CGFloat = 3_400
        let captureHeight: CGFloat = 3_300
        let tolerance = TK2CodeParity.tolerance
        let label = "breakout \(size)"

        var windows: [UIWindow] = []
        defer {
            for window in windows {
                window.isHidden = true
                window.rootViewController = nil
            }
        }
        var heights: [CGFloat] = []
        var frames: [[CGRect]] = []
        var contents: [[CGSize]] = []
        var identifiers: Set<String> = []
        for arm in [ADFTextRenderer.swiftUI, .textKit2] {
            let model = try await TK2CodeParity.loadedModel(data)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: documentWidth, height: windowHeight))
            window.overrideUserInterfaceStyle = .light
            window.backgroundColor = .white
            let document = ADFDocumentView(model: model, mediaProvider: TextKit2DiagnosticsTests.NoMedia(), textRenderer: arm)
            let host = UIHostingController(rootView: AnyView(document.dynamicTypeSize(size)))
            host.safeAreaRegions = []
            window.rootViewController = host
            window.isHidden = false
            windows.append(window)
            try await TextKit2DiagnosticsTests.settle(window)
            let outer = try #require(TK2Parity.scrollViews(in: host.view).first, "\(label) \(arm): no document scroll view")
            heights.append(outer.contentSize.height)
            let viewports = TK2Parity.nestedScrollViews(in: host.view)
                .map { (frame: $0.convert($0.bounds, to: nil), content: $0.contentSize) }
                .sorted { $0.frame.minY < $1.frame.minY }
            frames.append(viewports.map { $0.frame })
            contents.append(viewports.map { $0.content })
            if arm == .textKit2 {
                identifiers = Set(TextKit2FallbackTests.rows(in: host.view).compactMap { $0.accessibilityIdentifier })
            }
        }
        try #require(frames[0].count == 4 && frames[1].count == 4, "\(label): code viewports \(frames[0].count) and \(frames[1].count)")
        #expect(heights[1] < captureHeight, "\(label): the document is taller than the capture")
        #expect(abs(heights[0] - heights[1]) <= tolerance, "\(label): content height swiftUI=\(heights[0]) textKit2=\(heights[1])")

        // The rows the gate admits, and only those.
        let scale = windows[1].traitCollection.displayScale
        var expected: Set<String> = []
        for block in blocks {
            let code = try TK2Parity.codeParts(block).code
            guard case .eligible = TextKit2Eligibility.codeVerdict(code) else { continue }
            let gate = TextKit2Scope.codeGate(
                code, sizeCategory: size.uiContentSizeCategory, legibilityWeight: nil, displayScale: scale, layoutDirection: .leftToRight
            )
            if gate == nil { expected.insert("tk2-row:\(block.id)") }
        }
        #expect(identifiers == expected, "\(label): rows \(identifiers.sorted()) expected \(expected.sorted())")
        if size == .large { #expect(expected.count == 4, "\(label): all four blocks are admitted at Large") }

        // Same frames and scroll ranges on both arms; breakout widens them.
        for index in 0..<4 {
            let f0 = frames[0][index]
            let f1 = frames[1][index]
            let sameOrigin = abs(f0.minX - f1.minX) <= tolerance && abs(f0.minY - f1.minY) <= tolerance
            let sameSize = abs(f0.width - f1.width) <= tolerance && abs(f0.height - f1.height) <= tolerance
            #expect(sameOrigin && sameSize, "\(label) block \(index): viewport swiftUI=\(f0) textKit2=\(f1)")
            let c0 = contents[0][index]
            let c1 = contents[1][index]
            let sameContent = abs(c0.width - c1.width) <= tolerance && abs(c0.height - c1.height) <= tolerance
            #expect(sameContent, "\(label) block \(index): content swiftUI=\(c0) textKit2=\(c1)")
        }
        let margin = TK2Parity.theme.spacing * 2
        for arm in 0..<2 {
            let plain = frames[arm][0]
            let wide = frames[arm][1]
            let full = frames[arm][2]
            #expect(abs(wide.width - plain.width - margin) <= tolerance, "\(label) arm \(arm): wide is \(wide.width - plain.width) pt wider")
            #expect(abs(plain.minX - wide.minX - margin / 2) <= tolerance, "\(label) arm \(arm): wide starts at \(wide.minX)")
            #expect(abs(full.width - plain.width - margin * 2) <= tolerance, "\(label) arm \(arm): full-width is \(full.width - plain.width) pt wider")
            #expect(abs(plain.minX - full.minX - margin) <= tolerance, "\(label) arm \(arm): full-width starts at \(full.minX)")
        }

        // Pixels: the parity rule inside each code viewport, equality outside.
        let rect = CGRect(x: 0, y: 0, width: documentWidth, height: min(max(heights[0], heights[1]).rounded(.up), captureHeight))
        let a = try TK2Parity.bitmap(of: windows[0], in: rect)
        let b = try TK2Parity.bitmap(of: windows[1], in: rect)
        try #require(a.width == b.width && a.height == b.height)
        let whole = TK2Parity.differingPixels(a, b, columns: 0..<a.width, rows: 0..<a.height, threshold: 0).count
        var inside = 0
        for (index, frame) in frames[1].enumerated() {
            let columns = Int((frame.minX * scale).rounded(.down))..<Int((frame.maxX * scale).rounded(.up))
            let rows = Int((frame.minY * scale).rounded(.down))..<Int((frame.maxY * scale).rounded(.up))
            let exact = TK2Parity.differingPixels(a, b, columns: columns, rows: rows, threshold: 0)
            let rule = TK2Parity.differingPixels(a, b, columns: columns, rows: rows)
            inside += exact.count
            let fraction = rule.total == 0 ? 0 : Double(rule.count) / Double(rule.total)
            let percent = String(format: "%.4f", fraction * 100)
            #expect(fraction <= TK2CodeParity.maxDifferingFraction, "\(label) block \(index): \(percent) % of pixels differ by more than 24")
            let engine = identifiers.contains("tk2-row:\(blocks[index].id)") ? "textkit2" : "swiftui"
            TK2CodeParity.emit("CODE_E2_BREAKOUT", [
                "size=\(size)", "block=\(index)", "arm=\(engine)",
                "scale=\(TK2CodeParity.scaleText(scale))", "os=\(TK2Parity.osVersion)",
                "viewport=\(TK2CodeParity.n(frame.width))x\(TK2CodeParity.n(frame.height))",
                "x=\(TK2CodeParity.n(frame.minX))", "content=\(TK2CodeParity.n(contents[1][index].width))",
                "diffPct=\(percent)", "exactDiffPx=\(exact.count)",
            ])
        }
        #expect(whole == inside, "\(label): \(whole - inside) pixels differ outside the code viewports")
    }
}

// MARK: - Record-only experiments

/// What the row would do with text outside the admitted cohort: each such
/// shape is re-stamped with a shape that claims printable ASCII
/// (`TK2Parity.restamped`; the content verdict trusts the stamp), hosted
/// through the real `CodeBlockView`, and measured by the parity rule.
///
/// Record only: it prints `CODE_E2 … suite=experiment` (and a
/// `CODE_E2_NOTE` listing what the rule would have failed) and never fails
/// the build. Not covered, for want of a seam: the empty string (no run to
/// stamp), right-to-left layout (the gate and SwiftUI read one
/// environment value) and blocks over the canvas bound (forcing one would
/// allocate a canvas above the caps).
/// `-only-testing:ADFRenderingTests/TextKit2CodeShapeExperiments`
@Suite("TextKit 2 code shape experiments (record only)", .serialized)
@MainActor
struct TextKit2CodeShapeExperiments {
    @Test("shapes outside the admitted cohort, forced onto the row", arguments: TK2CodeParity.experimentSamples, [DynamicTypeSize.large, .accessibility3])
    func forced(sample: TK2CodeParity.Sample, size: DynamicTypeSize) async {
        let env = TK2Parity.Environment(size: size)
        do {
            let block = try await TK2Parity.codeBlock(sample.text, language: sample.language)
            let measured = ADFCodeShape(sample.text)
            let claimed = ADFCodeShape(lineCount: measured.lineCount, maxLineUTF16: max(measured.maxLineUTF16, 1))
            let forced = try TK2Parity.restamped(block, shape: claimed)
            let outcome = try await TK2CodeParity.measure(
                name: sample.name, block: forced, env: env, expectTextKit2: nil, reason: "forced", suite: "experiment",
                checkBound: false
            )
            if !outcome.failures.isEmpty {
                print("CODE_E2_NOTE shape=\(sample.name) size=\(size) rows=\(outcome.textKit2Rows) " + outcome.failures.joined(separator: " ; "))
            }
        } catch {
            TK2CodeParity.emit("CODE_E2", [
                "shape=\(sample.name)", "size=\(size)", "weight=regular",
                "scale=\(TK2CodeParity.scaleText(TK2Parity.nativeScale))", "os=\(TK2Parity.osVersion)",
                "dH=nan", "dW=nan", "inkExact=false", "diffPct=nan",
                "arm=error", "reason=forced", "suite=experiment", "error=\(error)",
            ])
        }
    }
}

// MARK: - Measure first

/// E1, E3, E4 and E5 of the plan. Each prints its own line family.
/// `-only-testing:ADFRenderingTests/TextKit2CodeMeasureFirstTests`
@Suite("TextKit 2 code: measure-first experiments", .serialized)
@MainActor
struct TextKit2CodeMeasureFirstTests {
    /// E1. The row answers every positive proposal with its natural size.
    ///
    /// Two halves. The row itself is asked directly. Then the proposals a
    /// horizontal scroll view really makes are recorded by a pass-through
    /// layout placed where `CodeBlockView` puts its leaf: the same
    /// `ScrollView(.horizontal, showsIndicators: false)`, the same
    /// `TextEngineLeaf` and padding. That is a replica of the view's body,
    /// labelled `host=replica`: the source has no seam that records
    /// proposals inside the real `CodeBlockView` (`TextKit2RowRepresentable
    /// .sizeThatFits` reports them nowhere). `TextKit2CodeAdapterTests`
    /// asserts the same independence through the real view, by outcome.
    @Test("E1: the row's size does not depend on the proposal")
    func proposalProbe() async throws {
        let theme = TK2Parity.theme
        let tolerance = TK2CodeParity.tolerance
        let block = try await TK2Parity.codeBlock(TK2CodeParity.eightLines, language: "swift")
        let code = try TK2Parity.codeParts(block).code
        let scale = TK2Parity.nativeScale
        let style = CodeBlockView.codeStyle(theme: theme)

        // The row, asked directly.
        var values = EnvironmentValues()
        values.dynamicTypeSize = .large
        values.displayScale = scale
        let row = TextKit2RowView()
        row.ownerKind = .code
        row.apply(TextKit2RowRepresentable.inputs(text: code, style: style, environment: values, layoutPolicy: .natural), ownerID: "e1")
        let natural = row.measuredSize(forProposedWidth: nil)
        #expect(natural.width > 0 && natural.height > 0, "natural size \(natural)")
        let proposals: [CGFloat?] = [nil, CGFloat.infinity, 1 / scale, 0.5, 1, 100, 320.5, natural.width, 5_000]
        for proposal in proposals {
            let size = row.measuredSize(forProposedWidth: proposal)
            let proposed = proposal.map { "\($0)" } ?? "nil"
            print("CODE_E1 host=row proposal=\(proposed) size=\(size.width)x\(size.height)")
            #expect(size == natural, "proposal \(proposed): \(size), natural \(natural)")
        }
        for proposal in [CGFloat(0), -1] {
            #expect(row.measuredSize(forProposedWidth: proposal) == .zero, "a width of \(proposal) lays nothing out")
        }
        #expect(row.relayoutCount == 1, "one layout answers every proposal, not \(row.relayoutCount)")
        #expect(row.cachedWidths == [.infinity], "cached widths \(row.cachedWidths)")

        // The proposals a horizontal scroll view makes.
        for outer in [CGFloat(370), 120.5, 44] {
            var firstSizes: [CGSize] = []
            for arm in [ADFTextRenderer.swiftUI, .textKit2] {
                var seen: [(pass: String, proposal: ProposedViewSize, size: CGSize)] = []
                let probe = TK2CodeParity.ProposalProbe(record: { pass, proposal, size in
                    seen.append((pass: pass, proposal: proposal, size: size))
                })
                let leaf = TextEngineLeaf(text: code, style: style, ownerID: block.id) {
                    Text(code)
                        .textSelection(.enabled)
                }
                .environment(\.adfTextOwnerKind, .code)
                let replica = ScrollView(.horizontal, showsIndicators: false) {
                    probe.callAsFunction { leaf }
                        .padding(theme.spacing * 1.5)
                }
                .frame(width: outer, alignment: .topLeading)
                .environment(\.adfTextRenderer, arm)
                .environment(\.adfTheme, theme)
                .dynamicTypeSize(.large)
                let host = TK2Parity.Host(replica, width: 400, height: 400)
                defer { host.close() }
                try await host.settle()

                #expect(!seen.isEmpty, "\(arm) outer=\(outer): the probe saw no proposal")
                let hostedRow = TextKit2FallbackTests.rows(in: host.view).first
                #expect((hostedRow != nil) == (arm == .textKit2), "\(arm) outer=\(outer): TextKit 2 row present = \(hostedRow != nil)")
                for entry in seen {
                    let width = entry.proposal.width.map { "\($0)" } ?? "nil"
                    let height = entry.proposal.height.map { "\($0)" } ?? "nil"
                    let positive = entry.proposal.width.map { $0 > 0 } ?? true
                    print("CODE_E1 host=replica arm=\(arm) outer=\(outer) pass=\(entry.pass) proposal=\(width)x\(height) size=\(entry.size.width)x\(entry.size.height) positive=\(positive)")
                    guard entry.pass == "size", positive, let hostedRow else { continue }
                    let same = abs(entry.size.width - hostedRow.bounds.width) <= tolerance && abs(entry.size.height - hostedRow.bounds.height) <= tolerance
                    #expect(same, "outer=\(outer) proposal \(width)x\(height): leaf \(entry.size), row \(hostedRow.bounds.size)")
                }
                if let hostedRow {
                    let isNatural = abs(hostedRow.bounds.width - natural.width) <= tolerance && abs(hostedRow.bounds.height - natural.height) <= tolerance
                    #expect(isNatural, "outer=\(outer): row \(hostedRow.bounds.size), natural \(natural)")
                    #expect(hostedRow.relayoutCount == 1, "outer=\(outer): \(hostedRow.relayoutCount) layouts")
                    #expect(hostedRow.cachedWidths == [.infinity], "outer=\(outer): cached widths \(hostedRow.cachedWidths)")
                }
                if let first = seen.first(where: { $0.pass == "size" && ($0.proposal.width.map { $0 > 0 } ?? true) }) {
                    firstSizes.append(first.size)
                }
            }
            try #require(firstSizes.count == 2, "outer=\(outer): a positive proposal on each arm")
            let same = abs(firstSizes[0].width - firstSizes[1].width) <= tolerance && abs(firstSizes[0].height - firstSizes[1].height) <= tolerance
            #expect(same, "outer=\(outer): leaf swiftUI=\(firstSizes[0]) textKit2=\(firstSizes[1])")
        }
    }

    /// E3. Blocks at 25 %, 100 % and 150 % of the admission bound, grown
    /// by lines (`tall`, 100 columns) and by columns (`wide`, two lines):
    /// the largest count within a quarter of the bound, the largest the
    /// gate admits, and the smallest at one and a half times it. At 25 %
    /// and 100 % the row draws the block, matches SwiftUI, and has ink in
    /// its far-right cell and on its last line (every line ends in `#`);
    /// at 150 % the block is on SwiftUI.
    ///
    /// The bitmap is `CALayer.render(in:)`, a CPU render: it proves the
    /// canvas draws its far edge, not that the GPU compositor shows a layer
    /// that large on a device.
    @Test("E3: canvas ladder at 25 %, 100 % and 150 % of the admission bound", arguments: ["tall", "wide"])
    func canvasLadder(axis: String) async throws {
        let scale = TK2Parity.nativeScale
        let env = TK2Parity.Environment(size: .large)
        let category = env.size.uiContentSizeCategory
        let spec = try #require(TK2Parity.theme.codeFontSpec)
        let metrics = try #require(TextKit2CodeMetrics.metrics(for: spec, category: category, legibilityWeight: nil))
        let capBytes = TextKit2Scope.maximumCodeCanvasBytes
        let capDimension = TextKit2Scope.maximumCodeCanvasDimension
        let tall = axis == "tall"

        func estimate(_ count: Int) -> TextKit2Scope.CodeCanvasBound? {
            let shape = tall ? ADFCodeShape(lineCount: count, maxLineUTF16: 100) : ADFCodeShape(lineCount: 2, maxLineUTF16: count)
            return TextKit2Scope.codeCanvasEstimate(shape, advance: metrics.advance, lineHeight: metrics.lineHeight, displayScale: scale)
        }
        /// The share of the admission bound used: over 1 is over a cap.
        func share(_ bound: TextKit2Scope.CodeCanvasBound) -> Double {
            let bytes = Double(bound.nominalBytes) / Double(capBytes)
            let width = Double(bound.pixelWidth) / Double(capDimension)
            let height = Double(bound.pixelHeight) / Double(capDimension)
            return max(bytes, width, height)
        }
        func text(_ count: Int) -> String {
            let lines = tall ? count : 2
            let columns = tall ? 100 : count
            let digits = String(repeating: "0123456789", count: columns / 10 + 1)
            let line = String(digits.prefix(columns - 1)) + "#"
            return Array(repeating: line, count: lines).joined(separator: "\n")
        }

        var quarter = 0
        var full = 0
        var over = 0
        for count in 2...20_000 {
            guard let bound = estimate(count) else { break }
            let used = share(bound)
            if used <= 0.25 { quarter = count }
            if used <= 1 { full = count }
            if used >= 1.5 {
                over = count
                break
            }
        }
        try #require(quarter > 0 && full > quarter && over > full, "\(axis): rungs \(quarter), \(full), \(over)")

        for (rung, count) in [("25", quarter), ("100", full), ("150", over)] {
            let admitted = rung != "150"
            let block = try await TK2Parity.codeBlock(text(count), language: "swift")
            let code = try TK2Parity.codeParts(block).code
            let gate = TextKit2Scope.codeGate(
                code, sizeCategory: category, legibilityWeight: nil, displayScale: scale, layoutDirection: .leftToRight
            )
            #expect((gate == nil) == admitted, "\(axis) \(rung) %: gate \(String(describing: gate))")
            if !admitted { #expect(gate == .canvas, "\(axis) \(rung) %: gate \(String(describing: gate))") }
            let outcome = try await TK2CodeParity.measure(
                name: "ladder-\(axis)-\(rung)", block: block, env: env, expectTextKit2: admitted,
                reason: admitted ? "admitted" : "canvas", suite: "ladder"
            )
            let report = outcome.failures.joined(separator: "\n")
            #expect(outcome.failures.isEmpty, "\(report)")
            if admitted {
                #expect(outcome.comparison.farRightInk, "\(axis) \(rung) %: no ink in the far-right cell of the TextKit 2 bitmap")
                #expect(outcome.comparison.lastLineInk, "\(axis) \(rung) %: no ink on the last line of the TextKit 2 bitmap")
            }
            let bound = try #require(estimate(count))
            let lines = tall ? count : 2
            let columns = tall ? 100 : count
            let used = String(format: "%.3f", share(bound))
            let isAdmitted = gate == nil
            TK2CodeParity.emit("CODE_E3", [
                "axis=\(axis)", "rung=\(rung)", "lines=\(lines)", "columns=\(columns)",
                "scale=\(TK2CodeParity.scaleText(scale))", "os=\(TK2Parity.osVersion)",
                "canvasPx=\(outcome.comparison.canvasPixels)", "boundPx=\(bound.pixelWidth)x\(bound.pixelHeight)",
                "nominalBytes=\(bound.nominalBytes)", "capBytes=\(capBytes)", "capDimension=\(capDimension)",
                "share=\(used)", "admitted=\(isAdmitted)", "rows=\(outcome.textKit2Rows)",
                "rightInk=\(outcome.comparison.farRightInk)", "lastLineInk=\(outcome.comparison.lastLineInk)",
            ])
        }
    }

    /// E4, hosted half. A wide code block in the real `ADFDocumentView`,
    /// panned 240 pt; the document's renderer is flipped five times, as the
    /// app's switch flips it. The scroll view is found again after every
    /// flip, so a replaced scroll view (offset back at zero) fails too.
    @Test("E4: five renderer flips keep a panned code block's offset within 2 px")
    func flipsKeepThePan() async throws {
        let data = try TK2Parity.documentData([
            TK2Parity.codeBlockNode("let before = 1", language: "swift"),
            TK2Parity.codeBlockNode(TK2CodeParity.wideBlock, language: "swift"),
            TK2Parity.codeBlockNode("let after = 2", language: "swift"),
        ])
        let model = try await TK2CodeParity.loadedModel(data)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 1_600))
        let host = UIHostingController(rootView: ADFDocumentView(model: model, mediaProvider: TextKit2DiagnosticsTests.NoMedia(), textRenderer: .swiftUI))
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await TextKit2DiagnosticsTests.settle(window)
        let scale = window.traitCollection.displayScale
        let pan: CGFloat = 240

        /// The widest code viewport's scroll view, as the tree holds it now.
        func widest() throws -> UIScrollView {
            let code = TK2Parity.nestedScrollViews(in: host.view)
            return try #require(code.max { $0.contentSize.width < $1.contentSize.width }, "no code scroll view")
        }
        let first = try widest()
        try #require(first.contentSize.width - first.bounds.width >= pan, "scroll range \(first.contentSize.width - first.bounds.width) pt")
        first.setContentOffset(CGPoint(x: pan, y: 0), animated: false)
        try await TextKit2DiagnosticsTests.settle(window)
        let start = try widest().contentOffset.x
        #expect(abs(start - pan) * scale <= 2, "the pan did not hold before any flip: \(start)")
        TK2CodeParity.emit("CODE_E4", [
            "flip=0", "arm=swiftUI", "offset=\(start)", "driftPx=\(TK2CodeParity.n(abs(start - pan) * scale))",
            "codeRows=0", "scale=\(TK2CodeParity.scaleText(scale))", "os=\(TK2Parity.osVersion)",
        ])

        var arm = ADFTextRenderer.swiftUI
        for flip in 1...5 {
            arm = arm == .swiftUI ? .textKit2 : .swiftUI
            host.rootView = ADFDocumentView(model: model, mediaProvider: TextKit2DiagnosticsTests.NoMedia(), textRenderer: arm)
            try await TextKit2DiagnosticsTests.settle(window)
            let scroll = try widest()
            let offset = scroll.contentOffset.x
            let drift = abs(offset - pan) * scale
            let codeRows = TextKit2FallbackTests.rows(in: host.view).filter { $0.ownerKind == .code }.count
            TK2CodeParity.emit("CODE_E4", [
                "flip=\(flip)", "arm=\(arm)", "offset=\(offset)", "driftPx=\(TK2CodeParity.n(drift))",
                "codeRows=\(codeRows)", "contentWidth=\(TK2CodeParity.n(scroll.contentSize.width))",
                "scale=\(TK2CodeParity.scaleText(scale))", "os=\(TK2Parity.osVersion)",
            ])
            #expect(drift <= 2, "flip \(flip) to \(arm): offset \(offset), panned \(pan)")
            #expect(codeRows == (arm == .textKit2 ? 3 : 0), "flip \(flip) to \(arm): \(codeRows) TextKit 2 code rows")
        }
    }

    /// E5, hosted half. The accessibility elements of one code block on
    /// each arm: labels, traits and order (badge, Copy, code).
    ///
    /// The TextKit 2 row's own exposure is always asserted. SwiftUI builds
    /// its accessibility tree for an assistive client; in a unit-test host
    /// with none it may expose nothing, and then the two trees cannot be
    /// compared here: that is printed (`CODE_E5 observable=false`) and
    /// recorded as a known issue, and the UI-test half (VoiceOver on an
    /// iOS 27 simulator) owns the comparison.
    @Test("E5: a code block's accessibility elements are the same on both arms")
    func accessibilityElements() async throws {
        let block = try await TK2Parity.codeBlock(TK2CodeParity.eightLines, language: "swift")
        let text = String(try TK2Parity.codeParts(block).code.characters)
        let env = TK2Parity.Environment(size: .large)
        var trees: [[TK2CodeParity.SpokenElement]] = []
        for arm in [ADFTextRenderer.swiftUI, .textKit2] {
            let host = TK2Parity.Host(TK2Parity.hostedCode(block, arm: arm, env: env), width: TK2CodeParity.phoneWidth, height: 600)
            defer { host.close() }
            try await host.settle()
            let elements = TK2CodeParity.spokenElements(under: host.view)
            trees.append(elements)
            let listed = elements.map { $0.description }.joined(separator: "; ")
            print("CODE_E5 arm=\(arm) count=\(elements.count) elements=[\(listed)]")
            if arm == .textKit2 {
                let row = try #require(TextKit2FallbackTests.rows(in: host.view).first, "no TextKit 2 row")
                #expect(row.isAccessibilityElement, "the row is one accessibility element")
                #expect(row.accessibilityLabel == text, "the row's label is the code")
                #expect(row.accessibilityTraits == .staticText, "traits \(row.accessibilityTraits.rawValue)")
                #expect(row.accessibilityIdentifier == "tk2-row:\(block.id)")
            }
        }
        let copyOff = trees[0].contains { $0.label == "Copy code" }
        let copyOn = trees[1].contains { $0.label == "Copy code" }
        let observable = copyOff && copyOn
        print("CODE_E5 observable=\(observable) os=\(TK2Parity.osVersion)")
        if observable {
            #expect(trees[0] == trees[1], "swiftUI=\(trees[0]) textKit2=\(trees[1])")
            for (index, tree) in trees.enumerated() {
                let badge = tree.firstIndex { $0.label == "swift" }
                let copy = tree.firstIndex { $0.label == "Copy code" }
                let code = tree.firstIndex { $0.label == text }
                if let badge, let copy, let code {
                    #expect(badge < copy && copy < code, "arm \(index): order badge=\(badge) Copy=\(copy) code=\(code)")
                } else {
                    Issue.record("arm \(index): badge, Copy or code element missing in \(tree)")
                }
            }
        } else {
            withKnownIssue("SwiftUI exposes no accessibility tree to a unit-test host without an assistive client") {
                Issue.record("E5 hosted half not observable: swiftUI=\(trees[0].count) elements, textKit2=\(trees[1].count)")
            }
        }
    }
}

// MARK: - Adapter

/// The code block's viewport is SwiftUI's on both arms; only the text
/// inside changes engine. These prove the horizontal viewport obeys the
/// frame it is given while the content keeps its natural width and scroll
/// range, and that a pan moves the row, never its layout.
/// `-only-testing:ADFRenderingTests/TextKit2CodeAdapterTests`
@Suite("TextKit 2 code adapter: viewport and pan", .serialized)
@MainActor
struct TextKit2CodeAdapterTests {
    /// The real `CodeBlockView` in a synthetic outer frame from 320 pt
    /// down to one pixel, then panned.
    @Test("the viewport obeys a narrow outer frame; the content keeps its natural width and scroll range")
    func narrowFrames() async throws {
        let block = try await TK2Parity.codeBlock(TK2CodeParity.eightLines, language: "swift")
        let env = TK2Parity.Environment(size: .large)
        let tolerance = TK2CodeParity.tolerance
        let pixel = 1 / TK2Parity.nativeScale
        let arms: [ADFTextRenderer] = [.swiftUI, .textKit2]

        // The natural content size, in an unconstrained phone column.
        var natural: [CGSize] = []
        for arm in arms {
            let host = TK2Parity.Host(TK2Parity.hostedCode(block, arm: arm, env: env), width: TK2CodeParity.phoneWidth, height: 600)
            defer { host.close() }
            try await host.settle()
            natural.append(try #require(TK2Parity.scrollViews(in: host.view).first, "\(arm): no scroll view").contentSize)
        }
        let sameNatural = abs(natural[0].width - natural[1].width) <= tolerance && abs(natural[0].height - natural[1].height) <= tolerance
        #expect(sameNatural, "natural content swiftUI=\(natural[0]) textKit2=\(natural[1])")

        let widths: [CGFloat] = [320, 200, 120.5, 44, 8, 1, pixel]
        for width in widths {
            var viewports: [CGRect] = []
            for (index, arm) in arms.enumerated() {
                let label = "\(arm) frame=\(width)"
                let view = TK2Parity.hostedCode(block, arm: arm, env: env).frame(width: width, alignment: .topLeading)
                let host = TK2Parity.Host(view, width: 400, height: 600)
                defer { host.close() }
                try await host.settle()
                let scroll = try #require(TK2Parity.scrollViews(in: host.view).first, "\(label): no scroll view")
                let viewport = scroll.convert(scroll.bounds, to: nil)
                viewports.append(viewport)
                let content = scroll.contentSize

                // The viewport is the frame's; the content is the code's.
                #expect(viewport.width <= width + pixel + tolerance, "\(label): viewport \(viewport.width) pt wide")
                #expect(viewport.minX >= -tolerance && viewport.maxX <= width + pixel + tolerance, "\(label): viewport \(viewport)")
                let sameContent = abs(content.width - natural[index].width) <= tolerance && abs(content.height - natural[index].height) <= tolerance
                #expect(sameContent, "\(label): content \(content), natural \(natural[index])")
                let row = TextKit2FallbackTests.rows(in: host.view).first
                #expect((row != nil) == (arm == .textKit2), "\(label): TextKit 2 row present = \(row != nil)")
                let placed = row?.bounds.size
                if let row {
                    let size = row.measuredSize(forProposedWidth: nil)
                    let isNatural = abs(row.bounds.width - size.width) <= tolerance && abs(row.bounds.height - size.height) <= tolerance
                    #expect(isNatural, "\(label): row \(row.bounds.size), natural \(size)")
                    #expect(row.relayoutCount == 1, "\(label): \(row.relayoutCount) layouts")
                    #expect(row.cachedWidths == [.infinity], "\(label): cached widths \(row.cachedWidths)")
                }

                // Panned: the offset holds, nothing is laid out again.
                let pan = min(60, content.width - viewport.width).rounded(.down)
                var offset: CGFloat = 0
                if pan >= 1 {
                    scroll.setContentOffset(CGPoint(x: pan, y: 0), animated: false)
                    try await host.settle()
                    let panned = try #require(TK2Parity.scrollViews(in: host.view).first, "\(label): no scroll view after the pan")
                    offset = panned.contentOffset.x
                    #expect(abs(offset - pan) <= pixel, "\(label): offset \(offset), panned \(pan)")
                    let pannedContent = panned.contentSize
                    let keptContent = abs(pannedContent.width - content.width) <= tolerance && abs(pannedContent.height - content.height) <= tolerance
                    #expect(keptContent, "\(label): content \(pannedContent) after the pan, \(content) before")
                    let pannedViewport = panned.convert(panned.bounds, to: nil)
                    let keptViewport = abs(pannedViewport.minX - viewport.minX) <= tolerance && abs(pannedViewport.width - viewport.width) <= tolerance
                    #expect(keptViewport, "\(label): viewport \(pannedViewport) after the pan, \(viewport) before")
                    if let pannedRow = TextKit2FallbackTests.rows(in: host.view).first {
                        #expect(pannedRow.bounds.size == placed, "\(label): the pan resized the row to \(pannedRow.bounds.size)")
                        #expect(pannedRow.relayoutCount == 1, "\(label): the pan laid the row out again")
                    }
                } else {
                    Issue.record("\(label): no scroll range to pan (content \(content.width), viewport \(viewport.width))")
                }
                TK2CodeParity.emit("CODE_ADAPTER", [
                    "arm=\(arm)", "frame=\(width)",
                    "viewport=\(TK2CodeParity.n(viewport.width))x\(TK2CodeParity.n(viewport.height))",
                    "content=\(TK2CodeParity.n(content.width))x\(TK2CodeParity.n(content.height))",
                    "pan=\(pan)", "offset=\(offset)", "os=\(TK2Parity.osVersion)",
                ])
            }
            let v0 = viewports[0]
            let v1 = viewports[1]
            let sameOrigin = abs(v0.minX - v1.minX) <= tolerance && abs(v0.minY - v1.minY) <= tolerance
            let sameSize = abs(v0.width - v1.width) <= tolerance && abs(v0.height - v1.height) <= tolerance
            #expect(sameOrigin && sameSize, "frame=\(width): viewport swiftUI=\(v0) textKit2=\(v1)")
        }
    }

    /// Plan 3.6 item 6: geometry the row reports in its own coordinates
    /// (what search highlights and selection will build on) lands in the
    /// window shifted by the horizontal pan, exactly, because the row is a
    /// subview of the scroll view's content.
    @Test("a row-local rectangle converted to window coordinates shifts by exactly the pan distance")
    func panShiftsWindowCoordinates() async throws {
        let block = try await TK2Parity.codeBlock(TK2CodeParity.wideBlock, language: "swift")
        let env = TK2Parity.Environment(size: .large)
        let pixel = 1 / TK2Parity.nativeScale
        let host = TK2Parity.Host(TK2Parity.hostedCode(block, arm: .textKit2, env: env), width: TK2CodeParity.phoneWidth, height: 600)
        defer { host.close() }
        try await host.settle()
        let scroll = try #require(TK2Parity.scrollViews(in: host.view).first, "no scroll view")
        let row = try #require(TextKit2FallbackTests.rows(in: host.view).first, "the wide block is not on a TextKit 2 row")
        #expect(row.isDescendant(of: scroll), "the row is inside the horizontal scroll view")
        let local = try #require(row.segmentRects(for: NSRange(location: 20, length: 12)).first, "no segment rectangle")
        #expect(local.width > 0 && local.height > 0, "segment \(local)")
        let before = row.convert(local, to: nil)
        let bounds = row.bounds
        let layouts = row.relayoutCount

        for pan in [CGFloat(120), 240, 37, 0] {
            scroll.setContentOffset(CGPoint(x: pan, y: 0), animated: false)
            try await host.settle()
            let offset = scroll.contentOffset.x
            let after = row.convert(local, to: nil)
            let shift = before.minX - after.minX
            print("CODE_PAN pan=\(pan) offset=\(offset) shift=\(shift) os=\(TK2Parity.osVersion)")
            #expect(row.window != nil && row.isDescendant(of: scroll), "pan \(pan): the row left the scroll view")
            #expect(abs(offset - pan) <= pixel, "pan \(pan): offset \(offset)")
            #expect(abs(shift - offset) <= 0.001, "pan \(pan): shifted \(shift) pt for an offset of \(offset) pt")
            let sameRest = abs(after.minY - before.minY) <= 0.001 && abs(after.width - before.width) <= 0.001 && abs(after.height - before.height) <= 0.001
            #expect(sameRest, "pan \(pan): \(after), unpanned \(before)")
            #expect(row.bounds == bounds && row.relayoutCount == layouts, "pan \(pan): the row was resized or laid out again")
            #expect(row.segmentRects(for: NSRange(location: 20, length: 12)).first == local, "pan \(pan): row-local geometry moved")
        }
    }
}

#endif
