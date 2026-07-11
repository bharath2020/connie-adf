# ADF Renderer for iOS — Design Document

**Target:** Native iOS reader for Confluence documents in Atlassian Document Format (ADF), schema `@atlaskit/adf-schema@56.1.3`.
**Baseline:** iOS 17 minimum (Observation framework, `visualEffect`, modern ScrollView APIs), with `#available` enhancements for iOS 18/26. Swift 6 language mode, strict concurrency.
**Non-goals (v1):** editing, comments/annotations UI, offline media caching policy (pluggable), real-time collaborative updates.

---

## 1. Requirements

1. Render **every** node and mark in the ADF full schema (inventory in §3), with a graceful fallback for unknown/future nodes.
2. Smooth 60/120 fps scrolling on documents with thousands of blocks (large Confluence pages: giant tables, hundreds of media items, deeply nested lists).
3. Lazy: parse off the main thread; materialize views only for on-screen content; load media only when (nearly) visible.
4. Read-only, but interactive where reading requires it: link taps, expand/collapse, image lightbox, checkbox display (non-editable), smart-card taps.
5. Full Dynamic Type, VoiceOver, dark mode support.

---

## 2. Architecture Overview

Three layers, each independently testable, connected by immutable value types:

```
┌────────────────────────────────────────────────────────────┐
│  1. PARSING (background actor)                             │
│     JSON → ADFNode tree (typed enum, Codable, Sendable)    │
├────────────────────────────────────────────────────────────┤
│  2. PREPARATION (background, incremental)                  │
│     ADFNode tree → [RenderBlock]                           │
│     • flatten doc children into a stable-ID block list     │
│     • pre-resolve inline runs → AttributedString           │
│     • pre-compute list numbering, table column layout      │
├────────────────────────────────────────────────────────────┤
│  3. RENDERING (SwiftUI, main actor)                        │
│     ScrollView + LazyVStack over [RenderBlock]             │
│     • one POD row view per top-level block                 │
│     • recursive block views inside containers              │
│     • async media pipeline with visibility-driven loading  │
└────────────────────────────────────────────────────────────┘
```

Key idea: **the expensive work (JSON decode, mark → attribute resolution, string building) happens once, off-main, producing immutable `Sendable` values.** SwiftUI `body` implementations only assemble pre-computed values, so scrolling never triggers heavy computation.

### Module layout (SPM package `ADFKit`)

```
ADFKit/
├── ADFModel/          // Layer 1 — no UI imports, runs anywhere
│   ├── ADFNode.swift          // node enum + payload structs
│   ├── ADFMark.swift          // mark enum
│   ├── ADFDecoding.swift      // custom Decodable, unknown-node capture
│   └── ADFValidator.swift     // optional schema sanity checks
├── ADFPreparation/    // Layer 2 — imports Foundation + SwiftUI (AttributedString only)
│   ├── RenderBlock.swift      // flattened block model with stable IDs
│   ├── InlineComposer.swift   // inline nodes + marks → AttributedString
│   ├── DocumentPreparer.swift // actor: tree → [RenderBlock], chunked
│   └── ADFTheme.swift         // fonts, colors, spacing tokens
└── ADFRendering/      // Layer 3 — SwiftUI views
    ├── ADFDocumentView.swift  // public entry point
    ├── BlockView.swift        // block dispatcher
    ├── blocks/…               // one view file per block family
    ├── inline/…               // status, mention, emoji, date, inline card
    └── media/…                // MediaView, provider protocol, lightbox
```

---

## 3. Element Inventory (schema 56.1.3 → renderer mapping)

The full schema has **84 definitions**, but many are constraint variants of the same node (`paragraph_with_no_marks_node`, `paragraph_with_alignment_node`, `paragraph_with_indentation_node`, `paragraph_with_font_size_node` are all `type: "paragraph"` with different allowed marks). The decoder keys on the JSON `type` field, so variants collapse. The renderer implements **~34 node types + 17 marks**:

### Block nodes

| ADF type | Schema defs collapsed | Rendering |
|---|---|---|
| `doc` | doc_node | Root → `[RenderBlock]` |
| `paragraph` | paragraph_* (4 variants) | `Text(AttributedString)` |
| `heading` | heading_* (4 variants) | `Text` styled per level 1–6, anchor ID for deep links |
| `blockquote` | blockquote_node | Leading accent bar + inset children |
| `bulletList` / `orderedList` / `listItem` | 3 defs | Custom recursive list layout; pre-computed markers (•/◦/▪, 1./a./i. per depth), `order` attr respected |
| `codeBlock` | codeBlock_node, codeBlock_root_only_node | Monospaced block, horizontal scroll, optional syntax highlighting (Splash/tree-sitter, pluggable), language badge, copy button |
| `rule` | rule_node | `Divider()` |
| `panel` | panel_node | Tinted rounded container + leading icon per `panelType` (info/note/tip/success/warning/error/custom w/ `panelIcon`/`panelColor` attrs) |
| `table` / `tableRow` / `tableCell` / `tableHeader` | 5 defs (incl. table_cell_content) | Custom grid (§6.4): horizontal scroll, sticky header row, colspan/rowspan/colwidth/background honored |
| `expand` / `nestedExpand` | 4 defs | Disclosure container, lazy body materialization on first expand |
| `mediaSingle` / `mediaGroup` / `media` / `mediaInline` / `caption` | 6 defs | Async media pipeline (§6.5); layout attr (center/wrap-left/wrap-right/align-start/align-end/wide/full-width), width as % or pixels per `widthType`, caption below |
| `taskList` / `taskItem` | + blockTaskItem_node | Checkbox glyph (read-only) + inline content, nested lists |
| `decisionList` / `decisionItem` | 2 defs | "⃟" decision icon container styling |
| `layoutSection` / `layoutColumn` | 3 defs | Multi-column `HStack` with width %; collapses to vertical stack under compact width / accessibility sizes |
| `blockCard` / `embedCard` | 2 defs | Smart-link card: URL or `data` payload → styled card, tap opens; embedCard falls back to blockCard style (no iframe) |
| `extension` / `bodiedExtension` | 4 defs (with_marks variants) | Extension registry (§7); default = labeled placeholder card, bodied variant renders its children |
| `syncBlock` / `bodiedSyncBlock` | 2 defs | Treated as transparent containers (render `content`); resolves via extension registry if remote fetch needed |
| *unknown* | — | `UnknownNodeView`: subtle placeholder chip with node type; raw JSON preserved in model |

### Inline nodes

| ADF type | Rendering |
|---|---|
| `text` | Run in `AttributedString`, marks applied |
| `hardBreak` | `\n` inside the attributed string |
| `mention` | Rounded "@Name" pill — inline via custom attribute + tap routing |
| `emoji` | Unicode text run when `text` repr exists; otherwise custom image attachment via media provider |
| `date` | Localized formatted date pill (attr `timestamp` is a *string* of epoch milliseconds — decode as String, then parse) |
| `status` | Colored capsule (`color` attr: neutral/purple/blue/red/yellow/green) — rendered as inline attachment |
| `inlineCard` | Smart link chip: icon + resolved title (async resolve, URL fallback) |
| `inlineExtension` | Registry lookup; placeholder chip fallback |
| `placeholder` | Grey italic placeholder text |
| `code_inline` (text + code mark) | Monospaced run with background |

### Marks (17)

`strong`, `em`, `underline`, `strike`, `code`, `subsup`, `textColor`, `backgroundColor`, `fontSize`, `link`, `alignment`, `indentation`, `breakout`, `border`, `annotation` (render underline decoration, no UI in v1), `dataConsumer` (no visual), `fragment` (no visual). All map to `AttributedString` attributes or block-level layout modifiers (`alignment`, `indentation`, `breakout` apply to the block; `border` applies to media).

---

## 4. Layer 1 — Parsing

### 4.1 Model

A recursive enum with typed payload structs. `Sendable`, `Hashable` by identity, decoded with a custom `init(from:)` that switches on `type`:

```swift
public indirect enum ADFNode: Sendable {
    case doc(content: [ADFNode], version: Int)
    case paragraph(Paragraph)          // content: [ADFNode], marks: [ADFMark]
    case heading(Heading)              // level: Int, content, marks
    case text(TextNode)                // text: String, marks: [ADFMark]
    case bulletList(content: [ADFNode], marks: [ADFMark])
    case orderedList(order: Int?, content: [ADFNode], marks: [ADFMark])
    // … one case per type in §3 …
    case unknown(type: String, raw: JSONValue)   // forward compatibility
}
```

Decoding rules:

- **Unknown node types never fail the document.** They decode into `.unknown` carrying the raw JSON (a lightweight `JSONValue` enum), so future schema additions degrade gracefully instead of blanking the page.
- **Unknown marks are dropped with a debug log** (a mark you can't render is safer to ignore than a node).
- **Malformed required attrs** (e.g. heading without `level`) fall back to defaults rather than throwing; a `[ADFParseIssue]` diagnostics array is surfaced for logging.
- Decoding runs inside `ADFParser`, an `actor`-isolated wrapper, so a 5 MB document never blocks the main thread:

```swift
public struct ADFParser: Sendable {
    public func parse(_ data: Data) async throws -> ADFDocument {
        // runs on the concurrent executor — Data in, Sendable tree out
        try JSONDecoder().decode(ADFDocument.self, from: data)
    }
}
```

### 4.2 Stable identity

ADF JSON has no node IDs. During decode we assign each node a **structural path ID** (`"0"`, `"0.2"`, `"0.2.1"` — child indexes from the root), stored alongside the payload. This ID is:

- stable across re-parses of the same JSON → SwiftUI diffing and `ScrollPosition` restoration work;
- the anchor key for programmatic scrolling (table of contents, deep links to headings);
- the cache key for prepared `AttributedString`s and resolved media.

---

## 5. Layer 2 — Preparation (the flattening pass)

### 5.1 Why flatten

`LazyVStack` only virtualizes its **direct** children. Rendering the tree naively (one giant recursive view) forces full materialization. So the preparer walks `doc.content` and emits one `RenderBlock` per **top-level block**, and the lazy container iterates those. Nested content inside a block (list items, table cells, panel children) renders eagerly *within its block row* — acceptable because a single block's subtree is bounded, while the document's length is not.

Two refinements keep pathological blocks cheap:

- **Huge tables** are split: the table emits a header `RenderBlock` plus one `RenderBlock` per row-batch (e.g. 20 rows), so a 2,000-row table still virtualizes. Shared column-layout metadata lives in the table's prepared model.
- **`expand` bodies** are *not* prepared until first expansion (stored as unprepared `[ADFNode]`, prepared on demand off-main).

### 5.2 RenderBlock

```swift
public struct RenderBlock: Identifiable, Hashable, Sendable {
    public let id: String              // structural path ID
    public let kind: Kind              // enum with prepared payloads

    public enum Kind: Hashable, Sendable {
        case richText(AttributedString, style: TextBlockStyle) // paragraph & heading
        case codeBlock(PreparedCode)
        case list(PreparedList)        // pre-numbered, pre-indented rows
        case panel(PreparedPanel)      // children as nested [RenderBlock]
        case quote([RenderBlock])
        case tableHeader(PreparedTableLayout, rows: [PreparedRow])
        case tableRows(PreparedTableLayout, rows: [PreparedRow])
        case media(PreparedMedia)      // dimensions known up front (attrs width/height)
        case expand(PreparedExpand)    // title + unprepared body nodes
        case divider
        // … taskList, decisionList, layout, cards, extension, unknown …
    }
}
```

Everything inside `Kind` is a value type; **no closures, no references** → rows qualify as POD-adjacent for cheap SwiftUI diffing.

### 5.3 Inline composition → `AttributedString`

`InlineComposer` converts a `[ADFNode]` inline sequence plus theme into one `AttributedString`:

- Marks map to standard attributes (`font`, `foregroundColor`, `backgroundColor`, `strikethroughStyle`, `underlineStyle`, `link`, monospaced font + background for `code`, baseline offset + smaller font for `subsup`).
- `fontSize`/`textColor`/`backgroundColor` respect Dynamic Type by scaling with `UIFontMetrics`, and text colors are contrast-adjusted per color scheme (Atlassian palettes have light/dark variants). Note: the `fontSize` mark's only schema-legal value is `"small"` — map it to a scaled-down text style, not arbitrary point sizes.
- Inline *atoms* (mention, status, date, emoji-image, inlineCard) use **custom `AttributeScope` attributes**; the text view renders them as styled runs where pure text suffices (mention, date) and splits into `Text` + inline views only when a run needs live content (inlineCard resolution). On **iOS 26+, `Text` inline attachments** render these natively inside one `Text`; on iOS 17/18 the fallback is a wrapping `Layout` that interleaves `Text` segments and pill views.
- Link taps route through `.environment(\.openURL, ...)` so the host app intercepts Confluence-internal links.

`AttributedString` building is the single most expensive per-block operation — doing it once in the preparer (and never in `body`) is the core performance decision.

### 5.4 Incremental preparation (lazy loading of the document itself)

For very long documents the preparer streams:

```swift
@Observable @MainActor
public final class ADFDocumentModel {
    public private(set) var blocks: [RenderBlock] = []
    public private(set) var phase: Phase = .parsing   // parsing → preparing → ready

    func load(_ data: Data, theme: ADFTheme) {
        Task {
            let doc = try await parser.parse(data)
            for await chunk in preparer.prepareStream(doc, theme: theme, chunkSize: 50) {
                blocks.append(contentsOf: chunk)      // main-actor append
            }
            phase = .ready
        }
    }
}
```

The first chunk (~first screen and a half) arrives in tens of milliseconds; the reader sees content immediately while the tail prepares in the background. Appending to the tail of an `Identifiable` array is cheap for SwiftUI diffing and invisible to the user (content appears below the fold).

Re-theming (Dynamic Type size change, light/dark switch) re-runs preparation off-main and swaps the array — IDs are stable, so scroll position holds.

---

## 6. Layer 3 — Rendering

### 6.1 Entry point

```swift
public struct ADFDocumentView: View {
    let model: ADFDocumentModel
    @State private var scrollPosition = ScrollPosition(idType: String.self)

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.blocks) { block in
                    BlockView(block: block)          // POD row
                        .padding(block.kind.verticalPadding)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal)
        }
        .scrollPosition($scrollPosition)             // iOS 18: ID-based restore & TOC jumps
        .environment(\.adfTheme, theme)
        .overlay { if model.phase == .parsing { ProgressView() } }
    }
}
```

Choices and rationale:

- **`ScrollView + LazyVStack`** over `List`: no UITableView styling to fight, full-width control for breakout/wide media, and `LazyVStack` virtualization is sufficient because rows are pre-computed values (cheap to instantiate). Lazy stacks keep created views alive rather than recycling, so per-row memory must be small — which the flattened value-type design guarantees (media bitmaps are the exception and are explicitly evicted off-screen, §6.5).
- **`scrollTargetLayout` + `ScrollPosition`** (iOS 17/18) power table-of-contents navigation ("jump to heading") and position restoration across re-theming.
- **No `AnyView`**: `BlockView` is a single concrete view that `switch`es on `block.kind` — SwiftUI resolves this as a conditional structural type, preserving identity per §list-patterns.

```swift
struct BlockView: View {          // POD: one stored let, memcmp-diffable
    let block: RenderBlock
    var body: some View {
        switch block.kind {
        case .richText(let str, let style): RichTextBlock(text: str, style: style)
        case .codeBlock(let code):          CodeBlockView(code: code)
        case .list(let list):               ListBlockView(list: list)
        case .tableRows(let layout, let r): TableRowsView(layout: layout, rows: r)
        case .media(let media):             MediaBlockView(media: media)
        case .expand(let expand):           ExpandView(expand: expand)
        // …
        }
    }
}
```

### 6.2 Text blocks

`Text(attributedString)` with `.textSelection(.enabled)`. Headings additionally register their path ID via `scrollTargetLayout` anchors and expose `.accessibilityAddTraits(.isHeader)` with heading level. Alignment/indentation marks become `frame(maxWidth:.infinity, alignment:)` / leading padding on the block.

### 6.3 Lists

Prepared list rows carry `depth`, `marker` (pre-formatted string), and composed content. Rendered as a `Grid`/`HStack` per row — marker column fixed-width, content column flexible — so wrapped lines align under the text, not the marker. Task items swap the marker for `checkmark.square.fill`/`square` symbols; decision items use the decision glyph in a tinted container.

### 6.4 Tables

The hardest element. Design:

- Wrap in a **horizontal `ScrollView`** when natural width exceeds the container; `colwidth` attrs give exact column widths, otherwise columns are measured from an off-screen sizing pass over the first N rows (cached in `PreparedTableLayout`).
- Custom `Layout`-conforming `TableRowLayout` places cells honoring **colspan/rowspan** (SwiftUI `Grid` can't span rows arbitrarily with dynamic content, so a small custom Layout is cleaner).
- **Sticky header**: header block is `.pinned` via `LazyVStack(pinnedViews:)` section headers when the table is split into header + row-batch blocks (§5.1) — headers stay visible while rows scroll.
- Cell backgrounds, `tableHeader` bold styling, per-cell `valign` (top/middle/bottom), and number-column attr supported. Each cell's content is its own nested `[RenderBlock]` stack (cells can contain lists, media, nested content).
- Accessibility: rows read as "row 3 of 40, column Name: value" via `accessibilityElement(children: .contain)` + custom rotor.

### 6.5 Media pipeline (lazy loading of assets)

Confluence media requires authenticated URL resolution, so media loading is a **protocol the host injects**:

```swift
public protocol ADFMediaProvider: Sendable {
    func resolve(_ ref: ADFMediaRef) async throws -> ResolvedMedia   // URL + auth
    func thumbnail(for ref: ADFMediaRef, targetSize: CGSize) async throws -> Image
}
```

`ADFMediaRef` mirrors the schema's two `media` variants: `.file(id:collection:)` (Atlassian-hosted, needs authenticated resolution) and `.external(url:)` (plain URL, fetched directly — the provider short-circuits resolution).

- **Placeholder sizing first**: ADF media attrs carry `width`/`height`, so `MediaBlockView` reserves the exact aspect-ratio box *before* any bytes load — zero layout shift, and `LazyVStack` gets correct estimated heights (the #1 cause of scroll jumpiness).
- **Visibility-driven fetch**: `.onScrollVisibilityChange(threshold: 0.01)` (iOS 18) starts the fetch as the item approaches; iOS 17 fallback is `.onAppear`/`.onDisappear` on the lazy row. Fetch tasks are structured (`.task(id:)`) so scrolling away **cancels** in-flight downloads automatically.
- **Downsampling**: provider decodes to the displayed pixel size (`ImageIO` thumbnailing), never full-resolution into memory; full res loads only in the tap-to-open lightbox (zoomable, share sheet).
- Two-tier cache: `NSCache` for decoded images (auto-evicts under pressure) over the host's disk/HTTP layer. Off-screen rows drop their decoded image state, holding only the ref.
- `mediaGroup` renders a thumbnail strip (horizontal scroll); files (non-image media) render a document chip with name/size; `caption` renders as secondary text under the media box; `border` mark and `link` mark on media are applied to the container.

### 6.6 Expand / layout / cards

- **Expand**: chevron header; on first expansion, body nodes are prepared off-main (spinner for the ~1 frame it takes), then cached. Animation via `animation(.snappy, value: isExpanded)`.
- **LayoutSection**: `ViewThatFits`-style adaptive — columns side-by-side at regular width, stacked at compact/accessibility sizes.
- **Cards** (`inlineCard`/`blockCard`/`embedCard`): a `SmartLinkResolver` protocol (host-injected, same pattern as media) resolves URL → title/icon/preview asynchronously; unresolved cards render the URL immediately, upgrading in place when metadata arrives.

---

## 7. Extensibility & unknowns

- **`ADFExtensionRegistry`**: hosts register renderers keyed by `(extensionType, extensionKey)` returning SwiftUI views for macros they care about (TOC, Jira issue table, charts). Unregistered extensions render a neutral card: puzzle-piece icon + extension title/key, with `bodiedExtension` still rendering its children below.
- **Unknown nodes** (`.unknown`) render a low-emphasis chip ("Unsupported content: `whiteboard`") — the reader always knows something was elided; nothing silently disappears.
- **Theme** (`ADFTheme`) is a token struct (fonts, spacing scale, panel palettes, code style) injected via environment, so the host app restyles without forking views.

---

## 8. Performance budget & verification

| Risk | Mitigation | Verification |
|---|---|---|
| Body-time work during scroll | All strings/layout pre-computed in Layer 2; POD row views | Instruments SwiftUI template: view-body durations < 0.5 ms p99 |
| Estimated-height jumpiness in LazyVStack | Known media dimensions; table row batching; consistent text metrics | Manual fling test on 5k-block fixture; hitch ratio < 5 ms/s (Animation Hitches instrument) |
| Memory on media-heavy docs | Downsampled decodes, NSCache eviction, off-screen state drop | Memory graph on 300-image fixture; steady-state < 150 MB |
| Main-thread parse stall | Actor-isolated parse + streamed preparation | First-content time < 100 ms on 5 MB doc (signpost measured) |
| Redundant invalidation | `@Observable` model; rows depend only on their own `RenderBlock` value | `Self._logChanges()` audit; SwiftUI Instruments cause-graph |

Test strategy: golden-fixture suite — a corpus of real exported Confluence pages (every node type ×2, plus adversarial: 2,000-row table, 500-image gallery, 10-deep nested lists) with snapshot tests per block view and a scrolling performance XCUITest measuring `os_signpost` hitch metrics.

---

## 9. Rollout plan

1. **M1 — Text core:** model + decoder for all types (unknown fallback), preparer, paragraph/heading/lists/quote/rule/panel/codeBlock, marks complete. Ships a readable page.
2. **M2 — Structure:** tables (with batching + sticky headers), expand, layout sections, task/decision lists.
3. **M3 — Rich media:** media pipeline + provider protocol, lightbox, cards + smart-link resolver, inline atoms (mention/status/date/emoji).
4. **M4 — Polish:** extension registry, TOC navigation via ScrollPosition, accessibility rotor for headings, performance hardening against the budget in §8.
