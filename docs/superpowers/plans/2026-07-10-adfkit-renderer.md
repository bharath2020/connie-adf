# ADFKit iOS Renderer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Executors MUST read `docs/ADF-Renderer-Design.md` (the spec) before starting any task.

**Goal:** A working iOS reader app that renders any Confluence ADF document (schema 56.1.3, all 84 definitions) with 120 fps-capable scrolling and lazy loading.

**Architecture:** Three-layer SPM package `ADFKit` (ADFModel → ADFPreparation → ADFRendering) per the design doc: background parse to a typed tree, off-main flattening into immutable `RenderBlock`s with pre-built `AttributedString`s, SwiftUI `ScrollView + LazyVStack` over POD row views. Demo app `ADFReader` generated with XcodeGen.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, Observation framework, Swift Testing (`import Testing`), XcodeGen, iOS 17 floor with `#available` for 18/26.

## Global Constraints

- iOS deployment target: **17.0**. Package platforms: `.iOS(.v17), .macOS(.v14)` (model+preparation tests run on macOS via `swift test`).
- Swift tools version **6.0**, `swiftLanguageMode(.v6)` on all targets. Zero concurrency warnings.
- **No third-party dependencies.** Syntax highlighting is out of scope for v1 (plain monospaced code blocks).
- All public model/preparation types are `Sendable`. No `AnyView` in ADFRendering. No force-unwraps outside tests.
- Unknown node types must never fail a parse (decode to `.unknown`); unknown marks are dropped.
- UIKit imports only behind `#if canImport(UIKit)`; ADFRendering must compile for macOS (demo app is iOS-only).
- Demo app Info.plist sets `CADisableMinimumFrameDurationOnPhone: true` (120 Hz on ProMotion).
- Fixture-driven: every node type appears in `Fixtures/kitchen-sink.json`; stress fixture has ≥5,000 blocks.
- Commit after every task (repo: `/Users/bharath2020/Documents/projects/connie-adf`, git initialized in Task 0).

## File Map

```
Package.swift
Sources/ADFModel/            JSONValue.swift, ADFMark.swift, ADFNode.swift,
                             ADFNodeBuilder.swift, ADFParser.swift, ADFParseIssue.swift
Sources/ADFPreparation/      ADFTheme.swift, RenderBlock.swift, InlineComposer.swift,
                             ListPreparer.swift, TablePreparer.swift, DocumentPreparer.swift
Sources/ADFRendering/        ADFDocumentModel.swift, ADFDocumentView.swift, BlockView.swift,
                             Blocks/ (one file per family), Inline/, Media/, Environment.swift
Tests/ADFModelTests/         ParserTests.swift, MarkDecodingTests.swift, UnknownNodeTests.swift
Tests/ADFPreparationTests/   InlineComposerTests.swift, PreparerTests.swift, TablePreparerTests.swift
Fixtures/                    kitchen-sink.json, stress-5k.json, giant-table.json, media-gallery.json
Tools/make-fixtures.swift    (generator for stress fixtures)
Demo/project.yml             (XcodeGen)
Demo/ADFReader/              ADFReaderApp.swift, FixtureListView.swift, ReaderView.swift,
                             PlaceholderMediaProvider.swift, FrameRateHUD.swift, AutoScroller.swift
```

---

### Task 0: Repo + package scaffold

**Files:** Create `Package.swift`, empty target directories with placeholder sources, `.gitignore`.

**Interfaces — Produces:** compiling targets `ADFModel`, `ADFPreparation` (depends on ADFModel), `ADFRendering` (depends on both), test targets wired.

- [ ] `git init`; `.gitignore` with `.build/`, `*.xcodeproj`, `DerivedData/`, `.DS_Store`
- [ ] `Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ADFKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ADFKit", targets: ["ADFModel", "ADFPreparation", "ADFRendering"])],
    targets: [
        .target(name: "ADFModel"),
        .target(name: "ADFPreparation", dependencies: ["ADFModel"]),
        .target(name: "ADFRendering", dependencies: ["ADFModel", "ADFPreparation"]),
        .testTarget(name: "ADFModelTests", dependencies: ["ADFModel"], resources: [.copy("../../Fixtures")]),
        .testTarget(name: "ADFPreparationTests", dependencies: ["ADFPreparation"]),
    ]
)
```

- [ ] Verify: `swift build` → succeeds. Commit `chore: scaffold ADFKit package`.

---

### Task 1: ADFModel — types, builder, parser

**Files:** Create all `Sources/ADFModel/*.swift`, `Tests/ADFModelTests/*.swift`, `Fixtures/kitchen-sink.json` (hand-written, every node type + every mark at least once).

**Interfaces — Produces (exact, later tasks depend on these):**

```swift
public enum JSONValue: Sendable, Hashable {           // JSONValue.swift
    case null, bool(Bool), number(Double), string(String)
    case array([JSONValue]), object([String: JSONValue])
    public init(jsonObject: Any) throws                 // from JSONSerialization
    public subscript(key: String) -> JSONValue? { get }
    public var stringValue: String? { get }; public var doubleValue: Double? { get }
    public var intValue: Int? { get }; public var boolValue: Bool? { get }
    public var arrayValue: [JSONValue]? { get }
}

public enum ADFMark: Sendable, Hashable {              // ADFMark.swift
    case strong, em, underline, strike, code
    case subsup(isSup: Bool)
    case textColor(hex: String), backgroundColor(hex: String)
    case fontSize(String)                               // schema: only "small"
    case link(href: String, title: String?)
    case alignment(ADFAlignment)                        // enum center, end
    case indentation(level: Int)                        // 1...6
    case breakout(mode: ADFBreakoutMode, width: Double?) // wide, fullWidth
    case border(size: Double, colorHex: String)
    case annotation(id: String, annotationType: String)
    case dataConsumer, fragment
    static func parse(_ json: JSONValue) -> ADFMark?    // nil → dropped + issue
}

public struct ADFNode: Sendable, Hashable, Identifiable {  // ADFNode.swift
    public let id: String          // structural path "0.2.1"
    public let type: String        // raw ADF type string
    public let kind: Kind
    public indirect enum Kind: Sendable, Hashable {
        case doc([ADFNode])
        case paragraph(content: [ADFNode], marks: [ADFMark])
        case heading(level: Int, content: [ADFNode], marks: [ADFMark])
        case text(String, marks: [ADFMark])
        case hardBreak
        case blockquote([ADFNode])
        case bulletList([ADFNode], marks: [ADFMark])
        case orderedList(start: Int, [ADFNode], marks: [ADFMark])
        case listItem([ADFNode])
        case codeBlock(language: String?, text: String, marks: [ADFMark])
        case rule
        case panel(type: ADFPanelType, icon: String?, colorHex: String?, [ADFNode])
        case table(attrs: TableAttrs, rows: [ADFNode])
        case tableRow([ADFNode])
        case tableCell(attrs: CellAttrs, [ADFNode], isHeader: Bool)
        case expand(title: String, [ADFNode], isNested: Bool)
        case mediaSingle(layout: ADFMediaLayout, width: Double?, widthType: ADFWidthType?, [ADFNode])
        case mediaGroup([ADFNode])
        case media(MediaAttrs, marks: [ADFMark])
        case mediaInline(MediaAttrs, marks: [ADFMark])
        case caption([ADFNode])
        case taskList([ADFNode])
        case taskItem(state: ADFTaskState, [ADFNode])       // todo, done
        case decisionList([ADFNode])
        case decisionItem([ADFNode])
        case layoutSection(columns: [ADFNode], marks: [ADFMark])
        case layoutColumn(width: Double, [ADFNode])
        case blockCard(url: String?, data: JSONValue?)
        case embedCard(url: String, layout: ADFMediaLayout, width: Double?)
        case inlineCard(url: String?, data: JSONValue?)
        case mention(id: String, text: String, accessLevel: String?)
        case emoji(shortName: String, text: String?)
        case date(timestampMS: Double)                       // parsed from STRING attr
        case status(text: String, color: ADFStatusColor)
        case placeholder(text: String)
        case adfExtension(ExtensionAttrs, marks: [ADFMark])              // extension
        case bodiedExtension(ExtensionAttrs, [ADFNode], marks: [ADFMark])
        case inlineExtension(ExtensionAttrs, marks: [ADFMark])
        case syncBlock(resourceId: String?, [ADFNode])       // + bodiedSyncBlock collapse
        case unknown(raw: JSONValue)
    }
}
// Supporting value types in ADFNode.swift:
public struct TableAttrs: Sendable, Hashable { public let isNumberColumnEnabled: Bool; public let layout: String?; public let displayMode: String? }
public struct CellAttrs: Sendable, Hashable { public let colspan: Int; public let rowspan: Int; public let colwidth: [Double]?; public let backgroundHex: String?; public let valign: ADFVAlign? }
public struct MediaAttrs: Sendable, Hashable { public enum Source: Sendable, Hashable { case file(id: String, collection: String), external(url: String) }
    public let source: Source; public let width: Double?; public let height: Double?; public let alt: String?; public let mediaType: String? }
public struct ExtensionAttrs: Sendable, Hashable { public let extensionType: String; public let extensionKey: String; public let text: String?; public let parameters: JSONValue? }
public enum ADFPanelType: String, Sendable { case info, note, tip, warning, error, success, custom }
public enum ADFStatusColor: String, Sendable { case neutral, purple, blue, red, yellow, green }
public enum ADFMediaLayout: String, Sendable { case wide, fullWidth = "full-width", center, wrapRight = "wrap-right", wrapLeft = "wrap-left", alignEnd = "align-end", alignStart = "align-start" }
public enum ADFWidthType: String, Sendable { case percentage, pixel }
public enum ADFTaskState: String, Sendable { case todo = "TODO", done = "DONE" }
public enum ADFVAlign: String, Sendable { case top, middle, bottom }
public enum ADFAlignment: String, Sendable { case center, end }
public enum ADFBreakoutMode: String, Sendable { case wide, fullWidth = "full-width" }

public struct ADFParseIssue: Sendable, Hashable { public let path: String; public let message: String }  // ADFParseIssue.swift

public struct ADFDocument: Sendable {                  // ADFParser.swift
    public let version: Int
    public let root: ADFNode                           // kind == .doc
    public let issues: [ADFParseIssue]
}
public struct ADFParser: Sendable {
    public init()
    public func parse(_ data: Data) async throws -> ADFDocument   // off-main via Task.detached-free nonisolated async
}
```

Builder rules (ADFNodeBuilder.swift): switch on `type` string; missing required attrs → default + `ADFParseIssue` (heading level→1, panel type→info, unparseable date timestamp→0); unknown type → `.unknown(raw:)` + issue; `bodiedSyncBlock` collapses into `.syncBlock`; `tableHeader` → `.tableCell(isHeader: true)`; `nestedExpand` → `.expand(isNested: true)`.

- [ ] Write failing tests (Swift Testing) FIRST: kitchen-sink decodes with zero `.unknown` and zero issues; every-mark paragraph round-trips mark set; unknown node type `"whiteboard"` → `.unknown` + issue, siblings intact; date string `"1720569600000"` → `timestampMS == 1_720_569_600_000`; structural IDs `root.id == "0"`, first child `"0.0"`.
- [ ] Run `swift test` → fails. Implement. `swift test` → passes. Commit `feat: ADFModel parser for all 84 schema definitions`.

---

### Task 2: Stress fixtures + generator

**Files:** Create `Tools/make-fixtures.swift` (swift script run with `swift Tools/make-fixtures.swift`), generating `Fixtures/stress-5k.json` (5,000 mixed blocks: paragraphs with mixed marks, headings, lists 4-deep, code blocks, panels, quotes every ~10 blocks), `Fixtures/giant-table.json` (800 rows × 6 cols, colspans sprinkled, header row), `Fixtures/media-gallery.json` (300 mediaSingle nodes with width/height attrs, external URLs `placeholder://<n>`).

**Interfaces — Consumes:** none (pure JSON emit). **Produces:** the three fixture files, deterministic (seeded, no Date/random).

- [ ] Write generator; run it; validate outputs parse with `ADFParser` via a test in `ParserTests.swift` (`#expect(issues.isEmpty)`).
- [ ] Commit `feat: stress fixtures + generator`.

---

### Task 3: ADFPreparation — theme, composer, preparer

**Files:** Create all `Sources/ADFPreparation/*.swift`, `Tests/ADFPreparationTests/*.swift`.

**Interfaces — Produces (exact):**

```swift
public struct ADFTheme: Sendable, Hashable {           // ADFTheme.swift
    public var body: Font, code: Font                  // heading(level:) -> Font
    public func headingFont(_ level: Int) -> Font
    public var spacing: CGFloat                        // base unit 8
    public func panelPalette(_ type: ADFPanelType, colorHex: String?) -> PanelPalette
    public static let `default`: ADFTheme
}
public struct PanelPalette: Sendable, Hashable { public let background: Color; public let accent: Color; public let iconSystemName: String }

public enum InlineAtom: Sendable, Hashable {           // InlineComposer.swift
    case mention(text: String), status(text: String, color: ADFStatusColor)
    case date(timestampMS: Double), emoji(shortName: String)
    case inlineCard(url: String?), mediaInline(MediaAttrs), inlineExtension(name: String)
}
public enum InlineSegment: Sendable, Hashable {
    case text(AttributedString)
    case atom(InlineAtom, id: String)
}
public struct InlineComposer: Sendable {
    public init(theme: ADFTheme)
    public func compose(_ inline: [ADFNode]) -> [InlineSegment]   // merges adjacent text runs
    public func plainAttributed(_ inline: [ADFNode]) -> AttributedString // atoms as text fallback
}

public struct RenderBlock: Identifiable, Hashable, Sendable {     // RenderBlock.swift
    public let id: String
    public let kind: Kind
    public indirect enum Kind: Hashable, Sendable {
        case richText(segments: [InlineSegment], style: TextBlockStyle)
        case codeBlock(language: String?, code: AttributedString)
        case listRows([PreparedListRow])
        case panel(PanelPalette, [RenderBlock])
        case quote([RenderBlock])
        case divider
        case tableSlice(PreparedTableLayout, rows: [PreparedTableRow], isHeaderSlice: Bool)
        case media(PreparedMedia)
        case mediaStrip([PreparedMedia])
        case expand(title: String, body: [ADFNode], isNested: Bool)  // body prepared on demand
        case layoutColumns([PreparedColumn])
        case card(url: String?, title: String?, isEmbed: Bool)
        case extensionPlaceholder(title: String, body: [RenderBlock])
        case unknown(typeName: String)
    }
}
public struct TextBlockStyle: Sendable, Hashable { public let font: Font; public let isHeading: Bool; public let headingLevel: Int?; public let alignment: ADFAlignment?; public let indentation: Int; public let breakout: ADFBreakoutMode? }
public struct PreparedListRow: Sendable, Hashable { public let id: String; public let depth: Int; public let marker: ListMarker; public let segments: [InlineSegment]; public let trailingBlocks: [RenderBlock] }
public enum ListMarker: Sendable, Hashable { case bullet(depth: Int), ordered(String), task(done: Bool), decision }
public struct PreparedTableLayout: Sendable, Hashable { public let columnWidths: [Double]?; public let columnCount: Int; public let hasNumberColumn: Bool }
public struct PreparedTableRow: Sendable, Hashable { public let id: String; public let cells: [PreparedTableCell] }
public struct PreparedTableCell: Sendable, Hashable { public let id: String; public let colspan: Int; public let rowspan: Int; public let backgroundHex: String?; public let valign: ADFVAlign?; public let isHeader: Bool; public let blocks: [RenderBlock] }
public struct PreparedMedia: Sendable, Hashable { public let id: String; public let attrs: MediaAttrs; public let layout: ADFMediaLayout; public let widthFraction: Double?; public let pixelWidth: Double?; public let caption: [InlineSegment]?; public let borderHex: String?; public let linkHref: String? }
public struct PreparedColumn: Sendable, Hashable { public let id: String; public let widthPercent: Double; public let blocks: [RenderBlock] }

public struct DocumentPreparer: Sendable {             // DocumentPreparer.swift
    public init(theme: ADFTheme)
    public func prepare(_ doc: ADFDocument) -> [RenderBlock]                       // sync, for tests/expand bodies
    public func prepareStream(_ doc: ADFDocument, chunkSize: Int) -> AsyncStream<[RenderBlock]>
}
```

Rules: tables split into header slice + row slices of 20 (`tableSlice`); ordered markers computed per depth (1. / a. / i.), honoring `start`; adjacent text nodes merge into one `AttributedString`; marks map — strong→bold, em→italic, underline/strike→decorations, code→monospaced+background, subsup→`baselineOffset` ±30% + 0.75× size, textColor/backgroundColor→colors from hex, link→`.link` + underline, fontSize "small"→0.85× body.

- [ ] Failing tests first: bold+italic+link paragraph produces one merged text segment with all three attributes; ordered list `start: 4` depth 0 markers `["4.","5."]`; depth-1 markers alphabetic; 800-row table → 1 header slice + 40 row slices with stable ids; kitchen-sink prepare produces zero `.unknown` kinds; stress-5k `prepare` < 2s (`#expect` on ContinuousClock measurement).
- [ ] `swift test` green. Commit `feat: ADFPreparation flattening + inline composition`.

---

### Task 4: ADFRendering — model, document view, text/simple blocks

**Files:** Create `ADFDocumentModel.swift`, `ADFDocumentView.swift`, `BlockView.swift`, `Environment.swift`, `Blocks/RichTextBlockView.swift`, `Blocks/CodeBlockView.swift`, `Blocks/PanelBlockView.swift`, `Blocks/QuoteBlockView.swift`, `Blocks/UnknownBlockView.swift`, `Inline/SegmentedTextView.swift`, `Inline/AtomViews.swift`.

**Interfaces — Consumes:** Task 3 types. **Produces:**

```swift
@Observable @MainActor public final class ADFDocumentModel {
    public enum Phase: Equatable { case idle, parsing, preparing, ready, failed(String) }
    public private(set) var blocks: [RenderBlock]
    public private(set) var phase: Phase
    public private(set) var headings: [(id: String, title: String, level: Int)]  // TOC
    public init(theme: ADFTheme = .default)
    public func load(data: Data)                       // parses + streams chunks of 50
}
public struct ADFDocumentView: View {                  // public entry point
    public init(model: ADFDocumentModel, mediaProvider: any ADFMediaProvider)
}
public protocol ADFMediaProvider: Sendable {           // Environment.swift (used by Task 5)
    func image(for attrs: MediaAttrs, targetSize: CGSize) async throws -> Image
}
```

`ADFDocumentView`: `ScrollView` + `LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders])`, `.scrollTargetLayout()`, `ScrollPosition` binding for TOC jumps. `BlockView` switches on kind — no `AnyView`. `SegmentedTextView`: single `Text` when segments are all-text (concatenation), wrapping `Layout` interleaving `Text` + atom pills otherwise. Atom pills: mention capsule, status capsule tinted by `ADFStatusColor`, date pill (formatted `Date(timeIntervalSince1970: ms/1000)`), emoji `:shortName:` text fallback.

- [ ] Build check on iOS: `xcodebuild -scheme ADFKit -destination 'generic/platform=iOS Simulator' build` green; macOS `swift build` green. Commit `feat: rendering core + text blocks`.

---

### Task 5: Lists, tables, media, expand, layout, cards views

**Files:** Create `Blocks/ListBlockView.swift`, `Blocks/TableSliceView.swift` (+ `TableRowLayout` custom `Layout` honoring colspan; rowspan v1 = colspan-only with rowspan cells repeated note in header docs), `Media/MediaBlockView.swift`, `Media/MediaStripView.swift`, `Media/LightboxView.swift`, `Blocks/ExpandBlockView.swift`, `Blocks/LayoutColumnsView.swift`, `Blocks/CardBlockView.swift`.

**Interfaces — Consumes:** Tasks 3–4 types (`ADFMediaProvider`, `PreparedMedia`, `PreparedTableLayout`…). **Produces:** view per kind wired into `BlockView` switch.

Requirements: media reserves aspect-ratio box from attrs before load; `.task(id:)` fetch (auto-cancel on scroll-away); iOS 18+ `.onScrollVisibilityChange` gate with `.onAppear` fallback; tables wrap in horizontal `ScrollView` when needed, header slice pinned; expand prepares body off-main on first open and caches; layout columns collapse to VStack when `horizontalSizeClass == .compact` or accessibility sizes.

- [ ] Both platform builds green. Commit `feat: structural + media block views`.

---

### Task 6: ADFReader demo app

**Files:** Create `Demo/project.yml`, `Demo/ADFReader/*.swift`, `Demo/ADFReader/Info.plist` (`CADisableMinimumFrameDurationOnPhone: true`), fixtures bundled as resources.

**Interfaces — Consumes:** `ADFDocumentModel`, `ADFDocumentView`, `ADFMediaProvider`.

`PlaceholderMediaProvider`: deterministic locally-generated gradient images (`ImageRenderer`/CoreGraphics) keyed by url/id — offline demo. `FixtureListView` → `ReaderView` (toolbar: TOC menu jumping via `ScrollPosition`). `FrameRateHUD`: `CADisplayLink`-driven overlay showing current fps + dropped-frame count, toggleable. `AutoScroller`: launch arg `-autoscroll` animates through the full document then prints `SCROLL_METRICS frames=<n> dropped=<n> hitchRatio=<ms/s>` via `print`.

- [ ] `cd Demo && xcodegen generate`; `xcodebuild -project ADFReader.xcodeproj -scheme ADFReader -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build` green.
- [ ] Install + launch on booted iPhone 16 Pro sim; `xcrun simctl io booted screenshot` of kitchen-sink page. Commit `feat: ADFReader demo app`.

---

### Task 7: End-to-end verification + performance gate

- [ ] All `swift test` green (model + preparation).
- [ ] Screenshot review: kitchen-sink top/middle/bottom, giant-table, media-gallery, stress-5k — visually confirm every element family renders (checklist from design §3).
- [ ] Run `-autoscroll` on stress-5k + giant-table + media-gallery; capture `SCROLL_METRICS`; gate: hitch ratio < 5 ms/s in Release config on simulator (document caveat: true 120 fps requires ProMotion hardware; architecture verified via hitch ratio + Instruments-ready signposts).
- [ ] `os_signpost` intervals around parse/prepare; first-chunk latency logged; gate: < 150 ms for stress-5k first chunk (Release).
- [ ] Fix regressions; commit `test: e2e verification + perf gates`.

---

## Self-Review Notes

- Spec coverage: all §3 inventory rows map to Task 1 (model), 3 (preparation), 4–5 (views); §5.4 streaming → Task 4 model; §6.5 media → Task 5; §8 budget → Task 7 gates. Extension registry (§7) deliberately reduced to `extensionPlaceholder` for v1 app (registry API deferred — YAGNI; noted deviation from spec).
- Rowspan: v1 renders colspan fully; rowspan cells render in their origin row (content never lost, geometry simplified). Documented deviation.
- Type names checked task-to-task: `InlineSegment`, `PreparedMedia`, `ADFMediaProvider` consistent across Tasks 3–6.
