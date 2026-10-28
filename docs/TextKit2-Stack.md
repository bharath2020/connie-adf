# TextKit 2 renderer stack

The TextKit 2 (TK2) text renderer is rebuilt as a stack of small PRs, each moving one more kind of content from SwiftUI `Text` onto TK2 until the two renderers reach parity. Until a kind moves, it keeps rendering through SwiftUI, so every intermediate state ships a correct document. This file is the living plan for the stack: the switch, the PR order, what each PR covers, the parity inventory, the contracts later PRs build on, and how to run the gates.

Companion documents: `Architecture-Decisions.md` §21 (the decision record), §2 (why SwiftUI `Text` was the original choice), and §4, §16, §18, §20 (lazy-row invariants every TK2 row must respect). In this file, "ADR §N" means a section of `Architecture-Decisions.md`; a bare "§N" means a section of this file.

Parity reference: **main's SwiftUI rendering**. Every pixel diff, height check and behaviour check compares against a Release build of main; main's screenshots are the final authority.

---

## 1. Purpose and the renderer switch

TK2 exists to unlock what SwiftUI `Text` cannot do in a reader: continuous text selection across blocks with native handles (§5), and finer control over layout, hit-testing and highlight painting. It must get there without regressing the scroll performance and the lazy-row invariants the SwiftUI renderer established.

**TK2 is OFF by default.** The SwiftUI renderer remains the shipping path until a separate ON-by-default decision is taken after the stack reaches parity.

### Public API

```swift
public enum ADFTextRenderer: String, CaseIterable, Sendable, Identifiable {
    case swiftUI = "swiftui"
    case textKit2 = "textkit2"
}

ADFDocumentView(model:mediaProvider:interactionHandler:taskStates:mentionContent:
                textRenderer: ADFTextRenderer = .swiftUI,
                textForeground: Color? = nil)
```

- `ADFTextRenderer` lives in `Sources/ADFRendering/TextKit2/ADFTextRenderer.swift`; `displayName` gives "SwiftUI" / "TextKit 2" for a host's picker.
- `ADFDocumentView` passes the choice to each `DocumentRow`, which sets the internal `EnvironmentValues.adfTextRenderer` to the host's choice **only for top-level `.richText` rows** and to `.swiftUI` for every other kind, so the value never leaks into a container's children.
- `RichTextBlockView` picks the engine with a plain `if`/`else` at the leaf (never `AnyView`, never `#available` at a lazy per-item position — ADR §18).
- `textForeground` colours text the document does not colour itself. It is **renderer-independent**: every row gets it as `.foregroundStyle` (what SwiftUI text, including every fallback, inherits) and TK2 rows draw the same colour from their render inputs, so switching `textRenderer` never changes text colour (pixel-tested on both arms, light and dark, `TextKit2PixelParityTests`; §6.5). A `foregroundStyle` a host applies *around* the document reaches SwiftUI text only — SwiftUI gives UIKit-hosted views no way to read it — so hosts that colour document text pass it here.
- On platforms without UIKit (`swift test` on macOS), `.textKit2` behaves as `.swiftUI`.
- **All public surface PR 1 adds:** `ADFTextRenderer` (+ `displayName`); the two `ADFDocumentView` parameters; the diagnostics read-outs below (`ADFTextKit2Stats`, `ADFTextKit2Coverage`, `ADFTextRenderer.textKit2Stats`, `.textKit2Coverage(of:)` — public because the demo reads them across the module boundary); in `ADFPreparation`, `ADFFontSpec` (+ `Font(adfFontSpec:)`, `TextStyle.swiftUITextStyle`), the `adf` attribute scope carrying it, `ADFTheme.bodyFontSpec` / `codeFontSpec` / `headingFontSpec(_:)`, and `InlineComposer.compose(_:baseFont:baseFontSpec:)`. The small-text and sub/superscript specs stay internal, like their `Font` twins.

### Demo app

- **Toggle:** the reader toolbar's renderer menu (`renderer-menu`); its label is the active renderer's name as text ("SwiftUI" / "TextKit 2", `renderer-active`). Items: `renderer-swiftui`, `renderer-textkit2`, the Frame Rate HUD toggle, and "About This Build…" (`renderer-about`). The About sheet shows the version, active renderer, the running executable's sha256 (`build-sha256`) and the live TK2 row count (`tk2-live-rows`).
- **Persistence:** `@AppStorage("adf.textkit2.enabled")` (`Demo/ADFReader/RendererPreference.swift`).
- **Launch args** (applied in `App.init`, before any view reads the key; see `Demo/ADFReader/ADFReaderApp.swift`):

  | Arg | Effect |
  |---|---|
  | `-textkit2` | Starts this launch ON whatever was persisted (writes `adf.textkit2.enabled`, marked as automation's; the next launch without the flag removes it). |
  | `-rendererReset` | Removes the key (applied first, so `-rendererReset -textkit2` starts ON from a clean slate). |
  | `-rendererStats` | Prints `RENDERER_STATS renderer=<swiftui\|textkit2> tk2Live=<n> tk2Layouts=<n> tk2Draws=<n> eligibleRoots=<n> fallbackRoots=<n>` at `READY` and alongside `SCROLL_METRICS`. tk2-gates adds `tk2NativeDraws=` (`nativeDrawCount`), `tk1BackedRows=` (`textKit1BackedRowCount`), `tk1BackedDraws=` (`textKit1BackedDrawCount`), `linkRoots=` and `textFallbackRoots=` (coverage). <!-- TODO(final-gates): confirm the demo's line --> |
  | `-rebuildControlPicks <n>` | Lifecycle gate only: the first `n` menu picks of TextKit 2 rebuild the rows TextKit 2 would swap as plain SwiftUI (the twenty-flip memory control, §8.3); About This Build shows `rebuild-control-rows`, `RENDERER_STATS` appends `rebuildControlRows=<n> rebuildControlAppeared=<n>`. |

  Never seed the key with `-adf.textkit2.enabled YES`: the argument domain pins the value and the in-app toggle would appear stuck.
- **Flip semantics:** flipping changes an environment value only. Live rows in the render region re-create their leaf; collapsed spacers keep their cached heights and rows re-measure when they re-enter. There is no `.id()` rebuild and no memo reset (that would be ADR §16's mass re-materialisation livelock). This is safe only because the two arms' heights are interchangeable, which the height-parity suite proves (§6.1, §8.1).

### Proving which renderer ran

A launch flag or a toolbar label never proves TK2 executed. `TextKit2Diagnostics` (internal, main-actor singleton) counts live rows, layouts, draws and **native draws** (draw passes in which TextKit 2 itself drew layout fragments), process-wide; each TK2 row sets `accessibilityIdentifier = "tk2-row:<ownerID>"`. Public read-outs: `ADFTextRenderer.textKit2Stats` (`liveRowCount`, `layoutCount`, `drawCount`, `nativeDrawCount`, `textKit1BackedRowCount`, `textKit1BackedDrawCount`) and `ADFTextRenderer.textKit2Coverage(of:)` (`eligibleRoots`, of which `linkRoots`; `fallbackRoots`, of which `textFallbackRoots` — paragraphs and headings kept on SwiftUI). **TextKit 1-backed rows are reported apart:** a row whose text has a link is a TK2 row (`tk2-row:<id>`, counted live) whose own TextKit 1 stack lays out and draws the text (§6.4), so its draws count in `textKit1BackedDrawCount` and never in `nativeDrawCount`; a draw is one or the other, never both. A gate that must prove TextKit 2 rendering requires `nativeDrawCount > 0`; every perf and coverage table states the TextKit 1-backed share (stress-5k 507 of 2,400 eligible roots, text-dense 808 of 3,000). Unit tests assert eligible rows create TK2 rows and ineligible ones do not, and that switching back releases them (the test's own row instances leave the window, and dropping its references lowers the live count by exactly their number). Suites run in parallel, so tests check their own hosted rows and compare a process-wide counter only across a span with no suspension; the XCUITest asserts `tk2-row:<id>` and `tk2-live-rows` in both directions.

---

## 2. Stack order (final)

| # | Scope | Notes |
|---|---|---|
| **PR 1** | Foundation: live switch, diagnostics, gates; top-level paragraphs and headings H1–H6 | This PR. Coverage and fallbacks in §3. |
| — | **Selection feasibility spike** (throwaway, not a PR in the stack) | Proves the §5 contract on two TK2 rows before PR 2 multiplies text adapters. Keep or revise the contract from its result. |
| **PR 2** | Lists | Leading paragraphs of list rows reuse the TK2 text adapter (`ListBlockView.swift:37` calls `SegmentedTextView` directly and bypasses `RichTextBlockView` today); bullet/ordered/task/decision rows, continuation rows, nested lists; markers aligned on the first text baseline the TK2 row exposes. Task toggles keep working. |
| **PR 3** | Code blocks | Keep horizontal scrolling and the Copy button; no wrapping change. |
| **PR 4** | Containers | Panels, quotes, expands (incl. nested), layout columns, media captions — and the bodies of extension placeholders, which are containers of the same shape. Media captions (inherited `.footnote` / `.secondary`) are the first container case of the inherited-style contract (§6.5), so its foreground/font part ships **no later than this PR**. |
| **PR 5** | Tables | Cells on TK2; width/height measurement. Header weight and dark-mode contrast arrive through the inherited-style contract (§6.5), extended with weight here. |
| **PR 6** | Inline atoms **and native links** | mention, status, date, emoji (short-name only), inlineCard, mediaInline, inlineExtension as text attachments; atom-bearing paragraphs leave the SwiftUI wrapping layout. **Native TextKit 2 links** land here too, replacing PR 1's TextKit 1-backed link rows (§6.4): both bring interactive inline content into TextKit 2 layout (tap routing that never swallows scrolls, per-item accessibility actions, hit rects from the drawn layout). The bar is `Text`'s TextKit 1 rendering of links — wrapping, line heights and decorations — exactly, in heights and pixels; until it is met, linked rows stay TextKit 1-backed. Follow-up: residual 5 (§6.4, centred run backgrounds), from `Text`'s own line and run origins. |
| **PR 7** | Search highlight + arrival flash in TK2 rows | Reuses the Character↔UTF-16 map from §5. |
| **PR 8** | Text selection | Cross-block, native handles, per the §5 contract and the spike result. |

**Performance is gated in every PR against main** (§8). There is no separate performance PR: a PR that fails its gate is fixed before review, never deferred. Each PR adds its feature-dense fixture and interaction checks to the gate cumulatively.

---

## 3. PR 1 coverage and fallbacks

### What TK2 draws in PR 1

A top-level `.richText` block (paragraph or heading H1–H6) when **all** of these hold:

1. the switch is ON (`.textKit2`);
2. the block contains no inline atoms (`SegmentedTextView.mergedText(segments)` is non-nil);
3. every run is *describable* — it carries an `ADFFontSpec` (§6.5), so TK2 can resolve the same font SwiftUI would;
4. before iOS 26, the text does not end in two or more hard breaks (residual found on iOS 18.5, §6.4);
5. no inherited `Text` styling the row does not reproduce is set — line spacing, text case, a line limit, a minimum scale factor or redaction (`TextKit2Leaf`); host colour arrives through `textForeground` (§6.5).

Text-run content in such blocks moves with them: every mark (strong, em, underline, strike, code, sub/sup, textColor, backgroundColor, link, annotation, small font size), hard breaks, emoji that carry a Unicode `text`, and inline placeholders. Because the preparer flattens them to top-level `.richText`, three less obvious sources are also eligible: the content of a `syncBlock` with an inline copy, a stray `caption` outside a `mediaSingle`, and an inline node at block level.

### What stays on SwiftUI in PR 1

- **Atom paragraphs** — any paragraph containing a mention, status, date, inlineCard, emoji without text, mediaInline or inlineExtension renders whole via SwiftUI.
- **Links are disclosed, not native, in PR 1:** a paragraph or heading with a link is a TK2 row laid out and drawn by its own TextKit 1 stack, as `Text` lays out linked text (captain decision; §6.4). Native TextKit 2 links are PR 6.
- **Two or more trailing hard breaks before iOS 26**, and text under inherited styling the row does not reproduce (condition 5 above).
- **Every other kind and every nested position** — lists, code blocks, tables (including the pinned header slice), panels, quotes, expands, layout columns and all of their contents, media captions, extension placeholders, custom (plugin) blocks and unknown nodes.
- **Search highlights and arrival flash** — TK2 rows do not paint them yet (PR 7).
- **Text selection and copy** — TK2 rows have none yet (PR 8). SwiftUI rows keep per-block `.textSelection(.enabled)`. This is an explicit, temporary limitation of the opt-in TK2 arm.
- **Undescribable themes** — a theme built from raw SwiftUI `Font`s without specs falls back (§6.5).

### Coverage facts (disclose in every perf table and PR description)

| Fixture | Roots | TK2-eligible in PR 1 | SwiftUI fallback |
|---|---|---|---|
| stress-5k | 5,000 | 2,400 (507 TextKit 1-backed) | 900 list roots, 400 code, 400 panels, 400 quotes, 500 expands, other kinds |
| kitchen-sink | 38 | 10 (1 TextKit 1-backed: the every-mark paragraph) | 2 atom-bearing rich-text roots plus every non-text kind |
| text-dense | 3,000 | 3,000 (808 TextKit 1-backed) | — |
| long-paragraph | 3 | <!-- TODO(final-gates): regenerated by tk2-gates without links --> | — |
| giant-table | 402 (heading + table slices) | 1 heading | the table (the fallback control) |

Counts from `ADFTextRenderer.textKit2Coverage(of:)` over each fixture prepared with the default theme (content-based; identical on iOS 18 and 26 for these fixtures, which have no paragraph ending in two hard breaks). "TextKit 1-backed" = `linkRoots`.

---

## 4. Parity inventory

One row per `RenderBlock.Kind` (`Sources/ADFPreparation/RenderBlock.swift`) and per `InlineAtom` (`Sources/ADFPreparation/InlineComposer.swift`). "Never" means the kind has no prepared rich text of its own (chrome, images, plugin views); any rich text it contains moves with the PR named.

**Selection/copy column:** "SwiftUI per-block" = the leaf has `.textSelection(.enabled)` today; every TK2 row has no selection until PR 8, after which all text participates in the §5 document-level selection.

### Block kinds

| Kind | Moves to TK2 | PR 1 behaviour | Owner-id handling | Selection / copy (before PR 8) | Links | Accessibility | Perf fixture |
|---|---|---|---|---|---|---|---|
| `richText` — top-level, atom-free paragraph / heading H1–H6 | **PR 1** | TK2 when ON and eligible (§3); otherwise SwiftUI. Link-bearing rows are still TK2 rows (`TextKit2RowView`, `tk2-row:<id>`) but TextKit 1-backed inside: the row's own TextKit 1 stack lays out, sizes, baselines, draws and hit-tests their text, as `Text` does (§6.4); reported apart (§1) | `RenderBlock.id` passed through the leaf and stored on the TK2 row; `tk2-row:<id>`; search spans key on it | TK2: none. SwiftUI arm: per-block | TK2: tap inside the link run's glyph rects (from the TextKit 1 stack) → SwiftUI `openURL`; whitespace taps rejected; links in the accent colour (a host `.tint` is not readable, §6.5) | One element: label = plain text, `staticText` (+ `header`); heading level from the SwiftUI modifier on `RichTextBlockView`; "Open link <host>" custom action per link | stress-5k (2,400 eligible, 507 TextKit 1-backed), kitchen-sink, text-dense, giant-table heading |
| `richText` — top-level, atom-bearing | PR 6 | SwiftUI, whole paragraph (`WrappingInlineLayout` over word chunks) | Block id; each atom keeps its node id (`InlineSegment.atom(_, id:)`) | SwiftUI per-block | SwiftUI `Text` links; inlineCard chips are `Link`s | SwiftUI default; atoms per the atom table | kitchen-sink (2 roots), stress-5k |
| `richText` — nested (inside a container, table cell, list trailing blocks, expand body) | With its container: PR 2 / PR 4 / PR 5 | SwiftUI (row environment reset to `.swiftUI`) | Its own block id | SwiftUI per-block | SwiftUI `Text` links | SwiftUI default | stress-5k |
| `codeBlock` | PR 3 | SwiftUI `Text` in a horizontal `ScrollView` | Block id (search spans, arrival flash) | SwiftUI per-block + Copy button (both kept) | n/a | Copy button labelled "Copy code" | stress-5k (400 code roots) |
| `listRows` — bullet, ordered, task, decision, continuation; nested lists as depth rows | PR 2 | SwiftUI; leading text via `SegmentedTextView`, not `RichTextBlockView` | Block id for the row group; each `PreparedListRow.id` owns its leading segments; task markers carry `ListMarker.task(id:)` for `taskStates` / `interactionHandler`; `trailingBlocks` keep their own ids | SwiftUI per-row (leading text) | Link marks in leading text | Bullet/number markers hidden; task toggle "Task"/"Completed task" + hint; decision labelled "Decision" | stress-5k (900 list roots, task + decision items), kitchen-sink |
| `panel` | PR 4 | SwiftUI container and children | Container id; children own ids | Children's | Children's | Icon hidden | stress-5k (400) |
| `quote` | PR 4 | SwiftUI container and children | Container id; children own ids | Children's | Children's | SwiftUI default | stress-5k (400) |
| `expand` (incl. nested expand) | PR 4 (body) | SwiftUI; body prepared off-main on first expansion; open state in `model.expandedBlocks` | Block id; body block ids come from on-demand preparation with the same preparer configuration as the search index | Body: children's. Title is chrome, not selectable | Body: children's | Title button with value "Expanded"/"Collapsed" | stress-5k (500) |
| `layoutColumns` | PR 4 | SwiftUI columns and children | Container id; `PreparedColumn.id`; children own ids | Children's | Children's | SwiftUI default | stress-5k (50 sections), kitchen-sink |
| `extensionPlaceholder` (extension, bodiedExtension, reference-only syncBlock) | Body with PR 4; chrome never | SwiftUI | Container id; body blocks own ids | Body: children's. Title is chrome | Body: children's | "Extension: <title>", children contained | stress-5k (50 bodied) |
| `tableSlice` (header slice + 2-row slices) | PR 5 | SwiftUI; the header slice is pinned via `DocumentHeader` (no renderer environment); header weight and contrast foregrounds inherited through view modifiers | Slice id `<tableID>#header` / `#rows<n>` (also the horizontal-sync key); `PreparedTableCell.id`; cell blocks own ids | Per cell block (SwiftUI per-block) | Cell blocks' | Slice is `.accessibilityElement(children: .contain)` | giant-table (800 rows), stress-5k (50 tables) |
| `media` | Image never; **caption PR 4** | SwiftUI; caption via `SegmentedTextView` with inherited `.footnote` + `.secondary` (an inherited-style case for §6.5) | `PreparedMedia.id` owns the caption | Caption: none today (no `.textSelection`) | `linkHref` on the media box | SwiftUI default | media-gallery (30 captions), stress-5k |
| `mediaStrip` | Never | SwiftUI (thumbnails; fallback labels are chrome) | Items' `PreparedMedia.id` | n/a | n/a | SwiftUI default | stress-5k (50 groups) |
| `divider` | Never | SwiftUI hairline | Block id | n/a | n/a | n/a | stress-5k (100 rules) |
| `card` (blockCard, embedCard) | Never | SwiftUI chrome | Block id | n/a | Card tap → `openURL` | "Link card: <title>" | stress-5k (50 + 50), youtube |
| `custom` (`ADFCustomBlock` plugins) | Never (consumer-rendered) | SwiftUI via the registered renderer | Block id; search treats `searchableText` as one atom unit | Consumer's | Consumer's | "Custom block: <rendererID>" fallback | youtube, youtube-dense |
| `unknown` | Never | SwiftUI chip | Block id | n/a | n/a | "Unsupported content of type <name>" | none dedicated |

### Inline atoms

All atoms move in **PR 6** as text attachments. In PR 1–5, a paragraph with any atom renders whole via SwiftUI. Each atom occupies exactly one position in the §5 address space; its copy text is the plain-text stand-in `AtomFormatting` already produces for TOC titles and accessibility labels. Search highlights atoms whole (`atomIDs`), never by span.

| Atom | Moves to TK2 | PR 1 behaviour | Owner-id handling | Selection / copy | Links / interaction | Accessibility | Perf fixture |
|---|---|---|---|---|---|---|---|
| `mention` | PR 6 | Paragraph via SwiftUI; capsule | ADF node id | Paragraph per-block (SwiftUI) | Tap presents host `mentionContent` (popover / sheet) when injected | `isButton` trait when content is injected | stress-5k (50), kitchen-sink |
| `status` | PR 6 | Same; uppercase tinted capsule | ADF node id | Same | n/a | Capsule text | stress-5k (50), kitchen-sink (6) |
| `date` | PR 6 | Same; formatted-date capsule | ADF node id | Same | n/a | Capsule text | stress-5k (50), kitchen-sink |
| `emoji` (short name only) | PR 6 | Same; `:shortName:` in secondary | ADF node id | Same | n/a | Text | stress-5k, kitchen-sink |
| `inlineCard` | PR 6 | Same; link chip showing the host | ADF node id | Same | Chip is a `Link` to the URL | Chip label | stress-5k (50), youtube |
| `mediaInline` | PR 6 | Same; paperclip chip (`alt` or "attachment") | ADF node id | Same | n/a | Chip label | stress-5k (50), kitchen-sink |
| `inlineExtension` | PR 6 | Same; puzzle-piece chip with the extension name | ADF node id | Same | n/a | Chip label | stress-5k (50), kitchen-sink |

An emoji node **with** a Unicode `text` is not an atom: the composer keeps it in the text run, so it moves with its paragraph (PR 1 for top-level rows).

---

## 5. Cross-block selection architecture contract

Design only — PR 1 contains no selection code. PR 1 preserves what this contract needs (the owner id through the TK2 leaf) and states the limitation (TK2 rows have no selection or copy; SwiftUI rows keep per-block selection). Every adapter added in PR 2–6 must fit this contract.

### 5.1 Addressing

A selection endpoint is a **document address**: `(document generation, owner id, local text position)`.

- **Document generation** distinguishes documents: structural ids (`"0.2.1"`) recur across documents, so an address from one document must never resolve in another.
- **Owner id** is the stable id of the text-bearing unit: the block id for paragraphs, headings and code; `PreparedListRow.id` for list leading text; `PreparedMedia.id` for captions; cell block ids inside tables.
- **Local text position** is an offset into that owner's merged text.
- **Document order** of owners is the order of the prepared block list, depth-first through containers — the order in which the preparer emits them.
- **Separators** between owners are a paragraph separator (`"\n"`); copy emits it between consecutive owners.
- **Atoms** occupy exactly one position each (attachment character), reserved for PR 6.

### 5.2 Offset mapping

Prepared ranges are `Character`-based (`SearchIndex` spans), TextKit works in UTF-16. Each TK2 row builds a per-run UTF-16 prefix table **once per materialisation**, from the merged `AttributedString`, alongside its `NSAttributedString`. The same table serves search highlighting (PR 7) and selection (PR 8); neither builds its own.

### 5.3 Ownership and lifetime

- The selection (anchor and focus, as addresses) lives in a **document-level state object owned by the model**, like `model.expandedBlocks` — never in a row. It survives rows collapsing to spacers and re-materialising.
- Rows **render their slice** of the selection: on materialisation a row asks the selection state for its owner's range and paints it; it never holds selection state of its own.
- A row collapsing is not a removal: the address stays valid. Only a change that removes or rewrites an owner (new document generation, a content revision at that owner) clamps the selection to the nearest surviving address.
- Unexpanded expand bodies are not prepared and are not addressable; selection and copy are WYSIWYG, matching the search contract.

### 5.4 Geometry

- Rows produce **row-local** rects from their own layout result (§6.2).
- Conversion to viewport coordinates uses the row's frame in the scroll content, obtained on demand by the interaction owner.
- No persistent named-coordinate geometry inside rows, and no SwiftUI state bound to visibility callbacks (ADR §4's rejected per-row geometry tracking and the ADR §20 lazy-row livelocks).

### 5.5 Interaction owner

- Native selection handles require a `UITextInput` implementer. The design is **one document-level overlay object implementing `UITextInput` over the §5.1 address space**, not one text view per row.
- `UITextPosition` / `UITextRange` wrap document addresses; `firstRect(for:)`, `caretRect(for:)` and `selectionRects(for:)` delegate to the rows that are live and fall back to collapsed-row estimates only for rows outside the render region.
- **Copy assembles text from the prepared model**, not from live views, so a selection that spans collapsed rows copies correctly.

### 5.6 Spike acceptance (before PR 2)

The throwaway spike must show, on two TK2 rows:

1. native handles appear and can be dragged;
2. a drag that crosses a lazy-row exit (a row collapses to a spacer mid-drag) keeps the selection;
3. copy yields exactly the expected text, including the separator;
4. fling + CPU settle stays at ~0 % with a selection active.

Result → keep this contract or revise it here before PR 2.

---

## 6. Sizing and cache contract

### 6.1 Height invariants

Collapsed rows replay exact heights (`CollapsedRowHeight`), and the live switch swaps engines without re-measuring collapsed rows. Therefore:

- The TK2 row's size is a **deterministic pure function** of (content, width, size category, display scale, layout direction, legibility weight), computed in the same SwiftUI layout pass.
- The two arms' heights are **interchangeable**: the TK2 height must equal SwiftUI's for the same inputs. The height-parity suite proves this across the whole input matrix; it is never assumed.
- No self-invalidation and no layout feedback (ADR §16): never `invalidateIntrinsicContentSize`, never SwiftUI state bound to visibility. Ordinary `setNeedsDisplay` is fine.
- No `#available` / `AnyView` at a lazy per-item position (ADR §18); the engine choice is a plain `if`/`else` at the leaf.
- No string allocation in view bodies (ADR §2): the `NSAttributedString` is built once per materialisation inside the representable, memoized by render inputs.

### 6.2 Layout result and cache

`TextKit2LayoutResult` = width, height, first baseline, last baseline, line count, line-fragment frames with their text ranges, and ink bounds (from `renderingSurfaceBounds`).

- **Cache key:** (render-inputs hash including content revision, width, size category, display scale, direction, legibility). Bounded width cache: **4 entries, LRU**.
- **Proposals:** `nil` width → natural width (unbounded container; cached under the natural width); zero → `.zero` without layout; infinite → natural width.
- **Re-sync before geometry:** the single `NSTextLayoutManager` may currently be laid out for a different width than a cached answer. On a bounds change and before drawing, the row takes the layout SwiftUI placed it from (`placedResult(for:)`: the cached bounded measurement whose reported *size* equals the bounds — height included, since two proposals that hug to the same width can wrap differently — else one of that width, else a fresh layout at `bounds.width`), sets the container to *that layout's* container width (wider than the bounds for a hugging row) and re-runs `ensureLayout` if it differs. Cached numbers are never used for geometry without that re-sync.
- **No eager layout on new inputs:** `apply` rebuilds the string and clears the cache; the next layout happens when SwiftUI measures the row or before it draws, never at the stale bounds width.
- **Baselines:** the representable exposes `.firstTextBaseline` / `.lastTextBaseline` from the placed layout (the same lookup at the guide's size, so reading a guide never lays out again), equal to SwiftUI's for single- and multi-line text (PR 2's list markers depend on it).
- **Covered by tests:** repeated and reordered proposals (A, B, A — height at A unchanged, draw geometry at A correct), content change at a stable row id, Dynamic Type change, teardown after switch or collapse, baseline exposure.

### 6.3 Line-pitch rule

- The TK2 row's height is a **measurement rule over TextKit's layout**, not a layout change: the first baseline already sits at the ascent, as in SwiftUI.
- Any correction must be **sign-correct** at every size category (leading is negative at the largest accessibility sizes) — never subtract a constant.
- The drawn area must never clip ink: the layout's ink bounds must lie within it. Covered by tests (`TextKit2RowViewTests` "the canvas covers the bounds and the ink's vertical reach", `TextKit2MetricsParityTests`), not asserted at runtime.
- Backgrounds, underline/strike, hit-testing and (later) selection rects use **the same geometry as drawing**.
- Monospaced runs resolve through the preferred text-style descriptor with `.monospaced` design, keeping ascent, descent and leading identical to body at every category. Fonts resolve with `UIFont.preferredFont(forTextStyle:compatibleWith:)`, never `UIFontMetrics` point scaling.

### 6.4 Line pitch and wrapping (measured)

Background, measured against fresh main before the fix (W = 370 pt, 3x, 70 probe cases):

- SwiftUI `Text` height = (N − 1) · (ascent + descent + leading) + ceil_px(ascent + descent); raw TK2 usage height = N · (ascent + descent + leading). At body / `.large` this made raw TK2 rows 1.667 pt taller per row, accumulating down the document.
- SwiftUI breaks one word earlier on nearly full lines (it avoids a single-word last line); line *counts* agree across strategies, so only per-line extents reveal the difference.

**Rules shipped in PR 1** (all measured against SwiftUI bitmaps and guides on iOS 26.3 at 3x and 2x, and on iOS 18.5; evidence under `<data>/parity/`):

- **Height** = ceil_px(last baseline + last-line descent), where a line's ascent/descent are the tallest/deepest run on it by its *font's* metrics — a fallback font's do not count (`Text` sizes "ab 🧪", "ab 漢字" and "ab नम" by the system font alone at 1600/1600 sizes, where Core Text's line bounds are taller) — and a baseline offset only ever grows them (a superscript's raise adds to its ascent, a subscript's drop to its descent). 930/930 heights exact (worst Δ 0) at 3x and 2x, plus 310 RTL / Bold Text cases and 156 corpus checks; with the sub/superscript-line family and the fixture sweep below <!-- TODO(final-gates) -->.
- **Superscript lines** (`stress-5k` block 503: 3.33 pt short at large, 24 pt at AX3, every row below shifted on a renderer switch). TextKit 2 lets a raised run's offset eat its descent (a line set wholly in superscript gets none) and fits the line in the font's leading-inclusive line height; `Text` keeps the descent below the baseline and lets the raise eat only the run's leading. Read from `Text.Layout` line origins (offsets −4…12 pt, every pairing of plain/sub/superscript lines): below a line `Text` keeps the largest run descent + leading, a raised run's leading reduced by its raise (never below 0); negative leading (AX5) belongs to the next line's ascent, as in TextKit. The row moves every line below such a line by the difference (drawn line by line when moved). Run backgrounds: the band moves with the run's baseline offset beyond the one the whole line shares — a highlighted superscript among plain text rises with it, a line set wholly in it does not — and spans the Core Text ascent (a subscript lowers it). The suites' sub/sup family: first, middle, last and only lines, with colour, highlight, a hard break after it (the linked variants assert their SwiftUI fallback, `TextKit2FallbackTests`). The same escape explains the lifecycle gate's −26 px (−8.67 pt) shift on a switch made straight after a programmatic jump (`lifecycle/diag3`): an eligible row above Section 500, off screen but already laid out by the lazy stack, measured differently under TK2, and the scroll view keeps its raw offset; a gesture-parked view had other rows laid out above it. Replayed with the gate's own steps: −26 px (−36 px below block 503) at 0d7730e, 0 px at 9bf45ff for the menu switch, a menu open/dismiss, re-choosing the same renderer, About open/close and a UI-less flip. Not renderer-agnostic and not issue #6. Evidence: `<data>/jump-switch-c/`.
- **Fixture sweep** (`TextKit2FixtureSweepTests`): every TextKit 2-eligible root of kitchen-sink, stress-5k and text-dense at 370 pt, large and AX3, both arms, must measure within 0.01 pt — **no exemptions**; content the row cannot match exactly is not eligible. Linked roots are measured too (TextKit 1-backed). History: 46 escapes, worst 96 pt, before the superscript-line and fallback-font rules; at 9bf45ff 10,820 measurements with every residual a link+emoji paragraph 1 px taller (8 at 3x, 17 at 2x, 9 on iOS 18.5) — a default TextKit 1 stack counting the emoji face in line heights, which the row's stack no longer does (below). Current counts per device: <!-- TODO(final-gates) --> (simulator runs after the perf calibration).
- **First baseline** is rounded to the nearest device pixel and the whole text is drawn shifted onto it (later lines keep their fractional offsets). Drawn unshifted, glyphs, underlines and strikes land 1 px low wherever the first baseline's pixel fraction is small (H1 at xxxLarge: 97.12 px). The row reports first/last baselines pixel-rounded too (16.187 → 16.333 at 3x), as `Text` does.
- **Line breaks:** `lineBreakStrategy = .standard`. 2,052 near-full Latin strings at large/xxxLarge × 370/640/353.333 pt matched per-line ink extents with `.standard` and `.pushOut` and missed 66 times with no strategy (one word later); 1,278 Korean, Japanese, Arabic and accented-Latin strings matched only with `.standard` (`.pushOut` alone missed 257 Korean strings — `.standard` adds Hangul word priority). In total 6,349 lines across 8 width/size sets, 0 mismatches.
- **Width hugging and alignment:** the reported width is the widest line, trailing whitespace included (left-to-right lines whose whitespace hangs past the container are measured with Core Text), pixel-ceiled, at most ceil_px(proposal) — `Text` reports 300.667 for a 300.5 proposal its whitespace overflows. Drawing reuses the measured layout shifted by the alignment within the hugging bounds; the canvas is clipped to the bounds horizontally because `Text` clips side overhang (an indented line-initial "j" loses its tail at 72 px). Centred/end text: bitmap sum of differences 0 at 30 of 32 width/size/direction checks (the other 2 are residual 2).
- **Trailing hard break:** the empty line's baseline = previous baseline + previous descent + its own ascent + the previous line's positive leading (its largest run's: a subscript's, not the break's, on a subscript line) + the break font's negative leading; a line's closing break never counts toward its metrics (TextKit and `Text` both skip it); before iOS 26 positive leading is dropped (negative leading applies on both). TextKit's own extra line fragment differs (it ignores negative leading after a first line, and after two breaks uses the 13.8 pt default font). 35/35 heights exact on 26.3. On iOS 18.5, with two or more trailing breaks at AX3+, `Text` also drops the middle empty line's negative leading (0.333–1.333 pt shorter, no exact rule found; `parity/ios18-trailing-break/probe49-ios18.log`), so before iOS 26 such text stays on SwiftUI (eligibility, regression-tested both ways).
- **Text containing a link is laid out, sized and drawn by TextKit 1 inside the TK2 row** (captain decision for PR 1; reported apart, §1). Measured: SwiftUI renders interactive (linked) `Text` with TextKit 1 string drawing — swizzling `NSLayoutManager` under the SwiftUI arm showed an `NSLayoutManager` (`usesFontLeading = false`, `lineFragmentPadding = 0`) in a container as wide as the `Text`'s frame, first baseline on a device pixel, `NSUnderline` on link/underline/annotation runs, `NSBackgroundColor` fills. TextKit 1 differs from TextKit 2 in wrapping (it wraps an emoji TextKit 2 lets end a line: `text-dense` block 283, one line, 22 pt, short; 36 such blocks), in line spacing (a superscript line gets its full leading) and in decorations (underlines placed per line from the line fragment, skipping descenders; backgrounds filling whole line fragments and running line-ending whitespace to the frame's edge — 8 px off a fitted model at AX3). The row therefore lays such text out and draws it with its own TextKit 1 stack configured like SwiftUI's, at the same pixel phase (fills clipped to the frame, as SwiftUI's are); lines, baselines, size (used rect clamped to the container: centred 350.667 where the line-width rule gives 353.333) and link hit-test rects come from that stack; TextKit 2 only bounds the ink. A replica matched SwiftUI's bitmaps with 0 differing pixels.
  - **Fallback fonts never grow a line** — in the TextKit 1 stack too. A default stack counts the emoji face (Apple Color Emoji, substituted into the storage) in line heights; `Text` does not (+0.0135 pt per emoji line at AX3: 1 px after the frame's ceil; 4 px for `link-emoji-wrap` at AX5). The stack's `NSLayoutManagerDelegate` takes out of each line what its substituted fonts add over the fonts the text was built with, the difference removed from the fragment, its used rect and (ascent) its baseline; lines without a substituted font are untouched. A plain line compares max-of-runs ascent/descent over both font sets, with TextKit 1's leading rules (negative leading not on a paragraph's first line, positive leading not below its last). A line with a baseline offset (sub/superscript) is order-dependent in TextKit 1 (a line opening with a subscript sits lower than one ending with it), so the delegate sets the line again with each substituted run replaced by plain characters in the built font, and removes the difference in baseline and height. Exactness on the sweep: <!-- TODO(final-gates): simulator, 3x / 2x / iOS 18.5 --> (fixed cases: `TextKit2FallbackTests`, `TextKit2HeightParityTests` `link-emoji-wrap`, `TextKit2PixelParityTests` linked emoji lines).
  - **Consequence for PR 8 (selection):** a link-bearing row is laid out and drawn by TextKit 1, so its selection rects must come from the row's TextKit 1 stack (as its link hit-test rects do), not from TextKit 2 — the lines can break differently. The row draws the highlight itself, beneath the TextKit 1 glyph pass. Any selection test must include a link-bearing row, centred, wrapped and with an emoji.
  - Evidence: `<data>/parity/link-textkit1/`, `<data>/parity/link-emoji-textkit1/`, `<data>/parity/fallback-font-metrics/`.

**Residuals** — disclosed differences, **not** exact parity: each is recorded with `withKnownIssue` or a measured tolerance, so a fix shows up as a test failure. None changes a row's height. Counts from the final runs at e6934f0 (residual 5 at 2bc0a1e) <!-- TODO(final-gates) -->:

1. **Last-baseline guide +1 px.** SwiftUI's `lastTextBaseline` guide sits exactly 1 px below its drawn baseline in 6/56 cases at 3x (H1 at AX3, sub/superscript lines; 12 known-issue records) and 2/56 at 2x; never −1 px. No formula found (best candidate 113/132). The row reports the drawn baseline, so a container aligning on the last baseline can sit 1 px off. Evidence: `parity/last-baseline/` (probe36.txt).
2. **Centred text at a fractional width.** At large, w = 300.5, both directions, 3x and 2x, SwiftUI's glyphs sit 0.5 px left of ours: its drawing layer is 849 px around an 844 px frame, and the bitmaps are identical only after a −0.5 px shift. The rule behind that layer outset is unknown (2 known-issue records). Evidence: `parity/align-center-offset/` (probe40/41/44).
3. **SF Mono rasterization.** No pixel differs by more than 24/255, but a faint edge row can flip the ink threshold: 3 line bands at 3x and 1 at 2x when it was measured; 0 in the e6934f0 runs. Recorded only when the band has no visibly differing pixel. Evidence: `parity/mono-raster/`.
4. **Underline and strike ends:** SwiftUI's end 0–2 px shorter (antialiasing level; the pixel suites still show 0 differing pixels). Evidence: `parity/link-decorations/`.
5. **Centred text with a run background** (highlight or code band). `Text` draws a band over part of a line with hard side edges floored onto its frame's pixel grid, and a band over a whole line with that line's own fractional, antialiased edges; the row does the same, which is exact on left-aligned text at 3x and 2x. Centred text is not consistent with that rule in `Text`: at AX3 a last-line whole band is ~0.22 pt narrower at each side, and at xxxLarge (3x) lines 0–1 have their glyphs about 1 px off the row's (lines 2–4 match), like residual 2 but at a whole-number width (370 pt). Differing pixels in `centred-highlight`: 3x large dark 0.34 %, xxxLarge 4.54 % / 5.08 % (light/dark), AX3 light per-row counts only; 2x large light per-row counts only, large dark 0.94 %, xxxLarge 0.05 % / 0.45 %; iOS 18.5 (3x) xxxLarge only, 4.54 % / 4.64 %. First and last ink rows are exact everywhere (no height effect), and a centred highlight after a link (TextKit 1-backed) is 0 px. Recorded with `withKnownIssue` in exactly these cases (`centredHighlightDiffers`); every other case stays hard. Finding the rule needs `Text`'s own line and run origins (a `TextRenderer` capture through `SegmentedTextView` returned no lines): follow-up with PR 6 (§2). Evidence: `parity/centred-highlight-bands/`.

Formerly residuals (fixed regression cases in `TextKit2FallbackTests`, which also check that a heading below them moves ≤ 2 px on a switch either way): two or more trailing hard breaks on iOS 18.5 — now a SwiftUI fallback before iOS 26; text with a link and an emoji — now exact through the TextKit 1 stack's fallback-font rule (above), no exemption; a highlighted sub/superscript run (formerly residual 5, ≤ 0.04 % of pixels): `Text` paints each line's run backgrounds over the glyphs of the line above (a raised band covers a descender above it), and so does the row now — 0 differing pixels and exact rows at 3x and 2x (`TextKit2PixelParityTests` sub/superscript lines; `parity/subsup-highlight-bands/`).

### 6.5 Inherited styling and themes

- `ADFTheme` gains spec-first construction; the SwiftUI `Font` is derived from the `ADFFontSpec`. A raw-`Font` initialiser stays source-compatible but marks the spec `nil` (undescribable); such runs force the SwiftUI path. No caller has to update two fields.
- `TextKit2RenderInputs` carries the resolved inherited inputs — foreground, layout direction, size category, legibility weight, colour scheme — and is part of the cache key and the redraw decision.
- **Why an explicit channel:** SwiftUI exposes no public getter for an inherited `foregroundStyle`, `tint` or font weight (the `EnvironmentValues` accessors are `package`), so a `UIViewRepresentable` cannot see what `Text` would inherit. Inherited styling therefore reaches a TK2 row only through library-owned environment values set next to the SwiftUI modifier they mirror. PR 1: `ADFDocumentView(textForeground:)` → per row `.foregroundStyle(colour)` (the SwiftUI arm) plus `adfTextForeground` (the TK2 row's `inheritedForeground`); `nil` leaves rows exactly as main. Tested hosted, including a change while ON (`TextKit2FallbackTests`) and in pixels (`TextKit2PixelParityTests`).
- **Tint:** `Text` colours links with the tint, which a foreground style does not override; the row colours them with the accent colour (`Color.accentColor`, resolved at draw time), also under `textForeground`. A host `.tint` around the document is **not readable** from UIKit (the accessor is `package`), so it recolours SwiftUI links only (§6.6).
- **Styling the row does not reproduce falls back:** readable `Text` environment — line spacing, text case, line limit, minimum scale factor, redaction — keeps the paragraph on SwiftUI (`TextKit2Leaf`, only built when the switch is ON). A `foregroundStyle` or font weight applied around the document is not readable and is not detected: with `.textKit2`, hosts colour text through `textForeground`.
- Later PRs extend the same channel: media captions' `.footnote` / `.secondary` with containers (**PR 4**, the first container case — the foreground/font part ships no later than it), table header weight and contrast foregrounds with tables (PR 5).
- Foreground precedence: a prepared foreground (author `textColor`, or the contrast colour derived from a background mark) first; then the inherited foreground; else `.label`.

### 6.6 Known costs and limitations (PR 1)

- **Colour-scheme flip:** the scheme is part of the render inputs and colours are baked into the `NSAttributedString`, so a light/dark flip rebuilds and re-lays out every live TK2 row in one frame (metrics are scheme-independent). A flip is a one-off, not a scroll path. Fix in PR 2: dynamic colours, so a scheme-only change redraws without relayout.
- **TextKit 1-backed rows hold two stacks:** the TextKit 1 stack that lays out and draws the text, and the TextKit 2 layout that bounds its ink (stress-5k: 507 of 2,400 eligible rows).
- **Canvas backing stores:** each TK2 row draws into a non-opaque canvas sized to its bounds plus ink overhang (≈ 0.9 MB for a 353 × 70 pt row at 3x). This is Core Animation memory, which a live-malloc check does not see. Resting `phys_footprint`, C vs B on text-dense at a fixed position: <!-- TODO(final-gates) --> measured after the perf calibration. The canvas cannot be opaque: it overhangs the row onto its neighbours and sits on container backgrounds.
- **Host `.tint` and inherited weight:** a host `.tint` recolours links in the SwiftUI arm only; TextKit 1-backed TK2 link rows keep the accent colour, and an inherited font weight is likewise not seen by TK2 rows (both accessors are `package`). PR 1 adds no API for them: the rest of the inherited-style contract (tint, weight) joins the explicit channel (§6.5) **no later than PR 4**.
- **Link + emoji + baseline offset at AX3+:** in a TextKit 1-backed row, a later line (not a paragraph's first) that has both a sub/superscript and an emoji may miss the negative-leading term at AX3 and above, because TextKit 1 sets the line it re-measures after a line separator as a first line (which drops negative leading). The row's height could then differ from `Text`'s by up to that line's negative leading; this is not measured, since no root in the three sweep fixtures has such a line. Plain lines use the fitted rule, which handles leading.
- **iOS 17:** the package minimum, but no iOS 17 runtime is installed on the build host. Parity is measured on iOS 26.3 (3x and 2x) and iOS 18.5 only; on iOS 17 TK2 is unverified (the pre-26 eligibility rules apply).

---

## 7. Links and accessibility (TK2 rows)

- **Links:** a `UITapGestureRecognizer` (only on rows whose text has a link) with `cancelsTouchesInView = false` that never swallows vertical flings. A tap opens a link only if the touch begins inside that link run's glyph rects (the union of its line-fragment segment rects, taken from the row's TextKit 1 stack — the engine that laid the text out), not "nearest character"; the link is resolved where the touch began, so drift within tap slop still opens it. Delivery goes through the SwiftUI `openURL` action, so hosts keep control. Native TextKit 2 links: PR 6.
- **Accessibility:** the row is one element — label = plain text, traits `staticText` (+ `header` for headings), value `nil` — plus one "Open link <host>" custom action per link range. The heading level comes from the SwiftUI `.accessibilityHeading` modifier on `RichTextBlockView`, which wraps both arms.

---

## 8. Running the gates

Every PR runs all of these against main. Proof artefacts (screenshots, perf CSVs, videos) live outside the worktree and are never committed.

**Command lines** (exact flags; each script's `--help` is the full reference). `<data>` is the task's data directory; every script takes an explicit `--udid`, refuses to run while another simulator is booted, and shuts down only a device it booted.

```sh
# Visual parity (§8.2). Defaults: fixtures kitchen-sink@0,0.5 stress-5k@0,0.5,
# appearances "light dark", size steps "0 3", arms "A A2 B C", --top-band 330
# --bottom-band 102, noise/exact-only --exact-mask 0,330,1206,460 (1206x2622).
Scripts/visual-parity.sh --udid <UDID> --ref-app <main ADFReader.app> \
    --app <branch ADFReader.app> --out <data>/visual/<run>
#   [--fixture <name>[@<f1>,<f2>...]]... [--appearances "light dark"] [--size-steps "0 3"]
#   [--arms "A A2 B C"] [--content-size large] [--settle 3] [--scroll-wait 2] [--ready-timeout 90]
#   [--mask x0,y0,x1,y1]... [--top-band 330] [--bottom-band 102]
#   [--exact-mask x0,y0,x1,y1]... [--no-exact-mask] [--threshold 24]
#   [--max-noise-pct 0] [--max-exact-pct 0] [--max-raw-pct 0.5] [--max-crop-pct 0.5] [--max-offset-px 0]
#   [--no-renderer-stats] [--keep-booted] [--skip-capture] [--dry-run]
python3 -I Scripts/visual_diff.py --out <dir> --pair <noise|exact|tolerant> <name> <ref.png> <cand.png> ...
#   [--mask ...] [--exact-mask ...] [--top-band N] [--bottom-band N] [--threshold 24] [--exact-threshold 0] [--search 100]

# Performance (§8.3). Per-PR gate, design pr45 (~40 min, no calibration); arm A is
# <data>/builds/main-a9e6aa2+stress1k (main + the stress-1k JSON):
Scripts/perf-gate.sh --udid <UDID> --app-a <main+stress1k .app> --app-b <branch .app> --app-c <branch .app> \
    --out <data>/perf/pr45-<sha>
# Full gate, design full (~8 h, once before the final parity PR): calibrate, then gate.
Scripts/perf-gate.sh --calibrate --udid <UDID> --app-a <main .app> --out <data>/perf/calibration
Scripts/perf-gate.sh --design full --udid <UDID> --app-a <main .app> --app-b <branch .app> \
    --app-c <branch .app> --calibration <data>/perf/calibration/calibration.json --out <data>/perf/full-<sha>
#   [--settle 300] [--host-wait 1200] [--host-poll 30] [--ledger <jsonl>]
#   [--arm-c-args "-textkit2"] [--candidate-args "-rendererStats"]
#   [--extra-args "<flags>"] [--expected-blocks "f=n ..."] [--trial-timeout 120] [--trial-timeout-for "f=s ..."]
#   [--ready-timeout 60] [--rss-ms 200] [--footprint-ms 1000] [--coverage "<text>"] [--appearance light|dark]
#   [--bundle-id <id>] [--keep-booted] [--dry-run]
#   pilot only: [--pilot] [--fixtures "..."] [--fixture-arms "f=A,B,C ..."] [--runs n] [--warmup 0]
#   [--no-sampler] [--no-candidate-markers]
python3 -I Scripts/perf_summarize.py <out>/trials.csv [--json summary.json] [--out summary.md] [--ledger <jsonl>] \
    [--bounds Scripts/perf-bounds.json]
python3 -I Scripts/perf_summarize.py <cal>/trials.csv --calibrate --write-calibration <cal>/calibration.json [--attempt 1]
python3 -I Scripts/perf_summarize.py <out>/trials.csv --calibration <cal>/calibration.json [--json ...] [--out ...]
python3 -I Scripts/perf_summarize.py <pilot>/trials.csv --pilot [--suggest-timeouts]
python3 -I Scripts/perf_summarize.py --print-design pr45|full
# Resolution bounds (READY gating) from an A–A′ run of untouched main:
python3 -I Scripts/perf_summarize.py <cal>/trials.csv --measure-bounds --write-bounds Scripts/perf-bounds.json
# Offline tests (no simulator): summarizer cases, driver scenarios on a fake simctl, comparator cases.
python3 -I Scripts/tests/perf_summarize_tests.py <scratch>/sum
Scripts/tests/perf-gate-scenarios.sh <scratch>/scen [scenario...]
python3 -I Scripts/tests/visual_diff_tests.py <scratch>/vd

# End-to-end video (§8.4); a negative control (wrong digest) must fail.
Scripts/e2e-video.sh --udid <UDID> --out <data>/videos/<name>.mp4
#   [--derived-data <dir>] [--skip-build] [--keep-booted] [--expected-sha256 <hex> | --negative]
#   (--skip-build needs the e2e-build-manifest.txt of an earlier build in the same derived data)
#   [--test-timeout <s>] [--recorder-ready-timeout 20] [--xcodebuild-grace <s>] [--dry-run]
#   (--create-device <name> instead of --udid: explicit opt-in, never deleted)

# Lifecycle checks (plan §3 checks 2–6) with the host agent Scripts/lifecycle_agent.py.
Scripts/lifecycle-gate.sh --udid <UDID> --out <data>/lifecycle/<run>
#   [--derived-data <dir>] [--skip-build] [--only <testName>]... [--suite-timeout 5400]
#   [--xcodebuild-grace 120] [--keep-booted] [--dry-run]
```

**Reference builds.** The reference is a Release, arm64-simulator, unsigned build of main from a clean `git archive` export (never the working tree), with `sha256.txt` beside the `.app`. `-scrollToFraction` lands exactly only since 9178cad (an animated jump into the lazy stack alone varied by up to 26 px between launches of one build: stress-5k at 0.5, step 3); a reference built from an older main needs that automation-only hunk applied, or arm A lands nondeterministically. PR 1's reference: `<data>/builds/main-a9e6aa2+scrolljump/` = a9e6aa2 + `scrolljump.patch` (the `ReaderView.scrollToFraction` hunk of 9178cad; sha256 recorded beside it). The unpatched `main-a9e6aa2` build is kept for the perf gate, which does not scroll to a fraction.

### 8.1 Parity suites

Location: `Tests/ADFRenderingTests/TextKit2/` (Swift Testing, `#if canImport(UIKit)`, so they run on the simulator only). Each suite hosts the real `RichTextBlockView` in both arms through the environment.

| Suite | Checks |
|---|---|
| `TextKit2HeightParityTests` | Height \|Δ\| ≤ 0.01 pt; first baseline, baseline pitch, last baseline and ink bounds separately; body, H1–H6, mixed mono/sub/sup; categories xSmall…AX5; 1/2/3+ lines; integer, fractional and narrow widths |
| `TextKit2LineBreakParityTests` | Per-line horizontal ink extents from both arms' bitmaps match exactly, on a corpus of nearly-full lines; TK2 line-fragment ranges logged for diagnosis |
| `TextKit2CorpusParityTests` | Heights and line breaks over the breadth corpus (scripts, emoji, combining marks, RTL, indentation, alignment, hard breaks) |
| `TextKit2MetricsParityTests` | First/last baseline guides and ink bounds against SwiftUI's |
| `TextKit2PixelParityTests` | 3x and 2x, light and dark: an H1, the every-mark paragraph, the kitchen-sink paragraph with its link (TextKit 1-backed) and without, a link after a subscript line, a centred highlight after a link and without one, linked emoji lines (large/AX3/AX5), a strike after a subscript line, the sub/sup line family, a host text colour (links keep the tint): vertical ink profile exact; differing pixels ≤ 0.2 % <!-- TODO(final-gates) --> |
| `TextKit2FixtureSweepTests` | Every eligible root of kitchen-sink, stress-5k and text-dense, large + AX3, both arms: \|Δ\| ≤ 0.01 pt, no exemptions |
| `TextKit2FallbackTests` | Fixed regression cases: linked text (link+emoji wrap, kitchen-sink paragraph, linked sub/sup) is a TextKit 1-backed row measuring exactly at large/AX3/AX5; double trailing breaks exact on iOS 26 and SwiftUI before it; unsupported inherited styling stays on SwiftUI; a heading below them moves ≤ 2 px on a switch either way; host `textForeground` reaches TK2 rows, including a change while ON |
| `TextKit2LinkTests` | Link taps (wrapped, coloured, RTL, emoji-adjacent; misses rejected), "Open link" actions, SwiftUI `openURL` delivery; a linked row counts as TextKit 1-backed and its draws never as native; only linked rows carry a tap recognizer |
| `TextKit2DiagnosticsTests` | Through `ADFDocumentView`: eligible roots get TK2 rows; plain ones are drawn natively (native draws > 0), the linked one is TextKit 1-backed (its draws counted apart, every draw one or the other); atom-bearing and non-text roots get none; switching back releases them; coverage counts |
| `TextKit2RowViewTests` | Row contract: cache and proposal cases (§6.2), placed-layout lookup, no eager relayout, resolver traits and metrics, foreground precedence (prepared, link tint, inherited, label) |
| `TextKit2FlipMemoryTests` | Diagnostic (`TK2_FLIP_MEMORY=1`): malloc traffic by size class per renderer switch on stress-5k vs the same switches with no eligible text and vs idle, plus raw `phys_footprint` per pair |

```sh
# Simulator: always address the device by udid (the name=…,OS= form does not resolve).
xcodebuild test -scheme ADFKit-Package \
  -destination 'platform=iOS Simulator,id=<udid>' \
  -only-testing:ADFRenderingTests/TextKit2HeightParityTests \
  -only-testing:ADFRenderingTests/TextKit2LineBreakParityTests \
  -only-testing:ADFRenderingTests/TextKit2CorpusParityTests \
  -only-testing:ADFRenderingTests/TextKit2MetricsParityTests \
  -only-testing:ADFRenderingTests/TextKit2FixtureSweepTests \
  -only-testing:ADFRenderingTests/TextKit2FallbackTests \
  -only-testing:ADFRenderingTests/TextKit2DiagnosticsTests \
  -only-testing:ADFRenderingTests/TextKit2PixelParityTests \
  -only-testing:ADFRenderingTests/TextKit2RowViewTests \
  -derivedDataPath <scratch>/dd-core

# Before review: the full simulator suites, and the macOS package tests.
xcodebuild test -scheme ADFKit-Package -destination 'platform=iOS Simulator,id=<udid>' \
  -only-testing:ADFRenderingTests -only-testing:ADFPreparationTests -derivedDataPath <scratch>/dd-core
swift build && swift test
```

Run the suites on a 3x device, a 2x device and the oldest installed runtime. `xcodebuild test` idles for minutes after the last test case: run it in the background and stop it once the result line appears.

### 8.2 Document-level visual parity — `Scripts/visual-parity.sh` + `Scripts/visual_diff.py`

Captures the reference build and the branch build on one simulator and scores them with `python3 -I Scripts/visual_diff.py` (Pillow + numpy; no image registration — alignment must come from layout).

- **Arms:** A = main (Release), B = branch without `-textkit2`, C = branch with `-textkit2`; plus an A–A' pair of two main captures to measure capture noise.
- **Captures:** identical device, appearance, size category, locale and status bar; `kitchen-sink` at two scroll positions and `stress-5k` at fractions 0 and 0.5 (`-scrollToFraction`); light and dark; `-fontSizeStep 0` and `3`; 2 s scroll wait + 3 s settle after `READY` (frames are identical from 2 s to 20 s after `READY`).
- **Scoring:** chrome (status bar, navigation/toolbar band, home band) is masked so only the content viewport is compared; whole-viewport % plus a separate score per text-block crop. Noise/exact pairs also mask the full-width band below the toolbar (0,330,1206,460): the glass capsules' shadows and the scroll-edge effect change with the renderer label (A–B |Δ| ≤ 14 over rows 330–450 while A–A' is 0); tolerant pairs still score it. Every pair reports its differing-pixel count and bbox, so a nonzero diff never prints as 0 %.
- **PR 1 result** <!-- TODO(final-gates) --> (refreshed after the final-head gates) (`<data>/visual/gate-4ded1a4/`, branch 4ded1a4 vs a9e6aa2 + scrolljump): 48/48 pairs PASS — A–A', A–B and A–C all 0 px in 16 configurations, every crop 0 % with a 0 px offset; `RENDERER_STATS` confirmed swiftui on every B and textkit2 on every C. `gate-8518d01/` keeps the pre-fix run (nondeterministic stress-5k p0.5 s3 landing) as root-cause evidence.
- **Pass:** A–A' noise recorded (expected 0.00 %); A–B 0.00 %; A–C ≤ 0.5 % whole-viewport **and** every text-block crop ≤ 0.5 % with a vertical offset of 0 px. A pair with no text-block crop (a blank or chrome-only viewport) is INVALID, not PASS (`visual_diff.py --allow-empty` overrides this for a deliberately empty capture).
- **Restores the device:** the run ends with the appearance and content size the device had when it started (`<data>/visual/restore-check.txt`).
- **Chrome differs from main even with the switch OFF**, and is masked for that reason: the demo's toolbar leads with the renderer menu ("SwiftUI" / "TextKit 2"), which also holds the HUD toggle and "About This Build…", so the trailing items are [renderer] [Find] [Text Size] [TOC] against main's [Find] [Text Size] [TOC] [HUD]. Only the demo app changes; the library has no chrome. The capsule widths follow the label, which is why noise/exact pairs mask the band below the toolbar.

### 8.3 Performance — `Scripts/perf-gate.sh` + `Scripts/perf_summarize.py`

Interleaved A/B/C trials on one simulator: launch to `READY` (labelled "preparation readiness", not first visible content), first chunk, autoscroll dropped frames / dropped rate / hitch ratio, memory (RSS and `footprint`, sampled peak; the app's %CPU is sampled with RSS so a stall can be told apart from host starvation). A = main (Release), B = branch with the switch OFF (`-rendererReset -rendererStats`; it carries the font-spec baking and switch plumbing on the shipping path), C = branch with `-textkit2 -rendererStats`. **Both B and C must pass.**

| Design | Fixtures × arms × pairs | Rule | When |
|---|---|---|---|
| `pr45` (default) | kitchen-sink, stress-1k (the first 1,000 blocks of stress-5k), giant-table × A/B/C × 3, one discarded warm-up per (fixture, arm) | median-relative | every PR, ~40 min |
| `full` | kitchen-sink, stress-5k, giant-table × A/B/C × ≥ 10, frozen A–A′ calibration | calibrated-ucb | once, before the final parity PR, ~8 h |

Full stress-5k is covered only by the one full gate before the final parity PR. Main a9e6aa2 has no scroll-length knob, so three pairs of full stress-5k (≈518 s a trial) do not fit 45 minutes; stress-1k is data only, and arm A is a clean `git archive a9e6aa2` plus that one JSON (`<data>/builds/main-a9e6aa2+stress1k/`, `FILES-ADDED.txt`, sha256 recorded). A design names, per fixture, the arms it runs (`DESIGNS` in `perf_summarize.py`, `fixture_arms` in `plan.json`), so another shape is configuration, not code.

**Bounds and the 15 % rule** (per PR description too). Rule: the median over 3 pairs of (cand − A) / A median, for B and C separately. From calibration attempt 1 (10 A–A′ pairs of untouched main, 2026-10-26) we took the 95th percentile of |median of 3 AA′ deltas| over all 120 triples. That's the smallest change 3 pairs can tell apart from noise:

| metric | kitchen-sink | stress-5k | giant-table | gated per PR |
|---|---:|---:|---:|---|
| launch→READY | 11 % (64 ms) | 22 % (282 ms) | 42 % (249 ms) | kitchen-sink only; stress-1k (no measured bound) and giant-table advisory |
| first chunk | 20 % (11 ms) | 11 % (8 ms) | 15 % (11 ms) | yes, 15 % with a 20 ms absolute floor |
| RSS at READY / peak | 0.5 % / 3.7 % | 3.7 % / 3.8 % | 1.0 % / 0.7 % | yes |
| footprint at READY / peak | 2.1 % / 3.1 % | 10.2 % / 8.0 % | 4.3 % / 1.6 % | yes |

- READY: kitchen-sink 11 %, stress 22 %, giant-table 42 %. First chunk: 11–20 % (8–11 ms absolute). RSS and footprint at READY and peak: 0.5–10 %.
- So the 15 % FAIL rule gates memory and kitchen-sink READY. First chunk gets 15 % with a 20 ms absolute floor. READY on stress and giant-table is advisory: 3 pairs can't resolve 15 % there.
- The gating is data, not a fixture list: `Scripts/perf-bounds.json` (written by `--measure-bounds`) holds the bounds, and launch→READY gates a fixture only when its bound is ≤ 15 % (or ≤ its absolute floor); a fixture without a measured bound is advisory. The plan records the bounds sha256 and the gated fixtures when the run starts; a later change makes the run INVALID.
- Frame metrics have median ≈ 0, so relative deltas are meaningless; only the ceilings and an absolute Δ ≤ 2 frames apply.

**What it can and can't catch** (per PR description too):
- Catches: stalls (the 27/27 kitchen-sink stall at 940 ms/s, the post-boot 197 ms/s), sustained ≥ 1 % drops, ≥ 15 % memory growth, ≥ 15 % kitchen-sink READY.
- Misses: shifts under 15 %, about half of true 15 % shifts on noisier metrics (stress footprint at READY has a 10 % floor), rare stalls that don't land in 3 trials, and READY regressions under about 25 % (stress) or 45 % (giant-table).

- **full rule:** per-metric allowance = max(max \|ΔAA′\|, absolute floor), frozen in `calibration.json` before any candidate result exists (its `created_utc` must predate the first trial), with a ceiling of 15 % of A's median; the summary prints each allowance as a % of the median. PASS if the one-sided 95 % upper bound of the mean paired delta ≤ the allowance. A calibration over the ceiling is INCONCLUSIVE: quiesce and recalibrate once.
- **Per-trial ceilings (both designs):** hitch > 10 ms/s, or dropped rate > 1 % (more than 3 dropped frames when a trial has < 2,000 frames). A candidate breach FAILs; a breach in A makes the run INVALID (environment; one predeclared rerun). Worst main values in calibration attempt 1: 6.0 ms/s (one frame on kitchen-sink) and 0.14 elsewhere.
- **Traversal and renderer proof:** B and C must reach the last block (`endRow` = blocks − 1) with frames within ±15 % of A's median, or the trial FAILs. C must report `renderer=textkit2` at READY and after the scroll, with `tk2Layouts > 0` and `tk2NativeDraws > 0`; B must report every TK2 counter 0. The TextKit 1-backed share (`linkRoots / eligibleRoots`, `tk1BackedDraws / tk2Draws`) is printed per fixture.
- **Refused before any trial** (exit 2): a gate run with less than its design (arm B, a fixture, an arm of a fixture, pairs, the warm-up, the sampler, the candidate markers or `-rendererStats`), and pr45 with a calibration or full without one.
- **Host (firstmate policy):** quiet = 1-min load ≤ 4.0 and no non-simulator process above 100 % CPU. After the settle (300 s when the run booted the device) the driver samples the host every 30 s for up to 20 min (`--host-poll`, `--host-wait`) and starts when it is quiet, or after the wait regardless. `plan.json` records the last sample and the wait; every trial row records its start time, load and busiest processes. A run that was not quiet at the start or in any counted trial is **HOST-BUSY**: its PASS counts; its FAIL is reported as `FAIL-HOST-BUSY` (exit 6) and is re-run once at the next quiet window before it counts as a FAIL. Nothing is ever killed or reniced.
- **Fail closed:** a result counts only with every declared pair present, every metric finite, exit 0, the expected `READY` line, and the installed sha256 and argv matching the arm. The summarizer reads the design and the pilot flag from `plan.json`, never from its own flags, and marks a reduced plan INCOMPLETE. Precedence: candidate crash → FAIL; invalid trial, baseline failure or A ceiling breach → INVALID; candidate failure → FAIL; too few pairs → INVALID; calibration INCONCLUSIVE; statistical or ceiling failure → FAIL; PILOT; INCOMPLETE; PASS; then a FAIL on a HOST-BUSY run → FAIL-HOST-BUSY. Exit codes: PASS 0, FAIL 1, INVALID/REFUSED 2, INCONCLUSIVE 3, PILOT 4, INCOMPLETE 5, FAIL-HOST-BUSY 6.
- **Reruns:** every verdict is appended to `perf-ledger.jsonl` beside the run directory. A FAIL with the same candidate binaries and design is never rerun (REFUSED); a FAIL-HOST-BUSY allows one rerun, and a second FAIL-HOST-BUSY for the same binaries counts as FAIL; after two INCONCLUSIVE/INVALID runs the next is REFUSED. Pilots do not count.
- **Deadlines:** per-fixture trial timeouts default to 1.5 × the pilot's longest scroll + 30 s (kitchen-sink 45 s, stress-1k 180, stress-5k 775, giant-table 95, text-dense 425, long-paragraph 45); `--suggest-timeouts` recomputes them from a pilot.
- **Fixtures:** `text-dense` (~3,000 text-only paragraphs/headings) and `long-paragraph` (one ~20,000-character paragraph; the per-row layout worst case) are generated with `Tools/make-fixtures.swift`. Main does not bundle them, so the gated designs keep to fixtures arm A can open; text-dense and long-paragraph are reported as B-vs-C information only (a pilot-shaped run, uncalibrated), and the fixture sweep (§8.1) covers text-dense heights. Later PRs add their feature-dense fixture.
- **Report:** per fixture × metric — A, B and C median (min–max), paired Δ (median, or mean with its 95 % upper bound), limit, verdict — with the coverage line and the TK1 share. Beneath the table, the PR description carries the twenty-flip memory line (refreshed at the final head): "Twenty-flip memory: control is now 20 switches that rebuild the same 9 leaf rows as plain SwiftUI (each arm in its own launch, alternating order). Before, it was 20 same-renderer picks that rebuilt nothing. Raw growth medians of 2: control +36,680 KB, TK2 +38,032 KB, excess +1,352 KB ≤ 5,120 KB, no relief. Evidence: `<data>/memory-phase4/`."

The autoscroll gate alone provably misses livelocks. Also run, in **both** arms: a real fling with an instantaneous-CPU settle check (`top -l 2 -pid <pid>` → ~0 % within 5 s), scene-snapshot thrash (Home / lock / app switcher ×5), a 60-second idle soak, and for the switch, twenty flips on stress-5k (`LifecycleUITests` test 7, via `Scripts/lifecycle-gate.sh`): the live TK2 row count is back to 0 after every OFF, and **control = twenty flips that rebuild the same leaf rows as plain SwiftUI (no TextKit 2), asserted by a rebuild counter; TK2 raw growth ≤ 5,120 KB above the control; no relief; median of 2 runs** (raw settled `phys_footprint`; a settled read is two equal reads 250 ms apart). The control (captain's rule B, decision A) rebuilds the same rows as plain SwiftUI: under `-rebuildControlPicks <n>` the demo's TextKit 2 picks apply the internal `@_spi(ADFDiagnostics) View.adfRebuildControl(true)` (an environment value) to the document, and each leaf a TextKit 2 pick would swap renders its SwiftUI `Text` at the same branch point instead — same leaves, same menu and About traffic; the test asserts the control shows the same nonzero rebuilt-row count after every ON pick (9, as TK2's live rows) and none after every OFF. Each series runs in its own launch, arm order alternating between runs: the first series of a launch takes the allocator's high-water growth (a control → TK2 order in one launch gave TK2 +4,144 / +336 KB against the control's +29,568 / +33,920). Before, the control was twenty same-renderer picks that rebuilt nothing, and the row rebuild alone — no TextKit, no UIKit row — exceeded 5,120 KB over it (`<data>/memory-phase4/`). Result <!-- TODO(final-gates): refresh at the final head -->: control 36,688 / 36,672 KB, TK2 35,696 / 40,368 KB, medians 36,680 vs 38,032, excess +1,352 KB (`<data>/memory-phase4/gate7-rebuild-control/`). The thrash cycles assert that Home, lock and the switcher each left the foreground. `test8` (Fable S16) checks the renderer launch flags on device: `-textkit2` starts on TextKit 2 over a persisted SwiftUI pick, the next plain launch is SwiftUI again, and a toolbar pick of TextKit 2 survives a plain relaunch (toolbar label and live TK2 rows each time). Measured at 9bf45ff: raw `phys_footprint` growth across flips is allocator high-water, not retention — over 10 flip pairs live malloc stayed at 63.84 MB (−384 B; largest class +2 KB, in-process zone histogram) while the footprint rose 139 → 159 MB, and `malloc_zone_pressure_relief` returns it each time (102 / 99 / 101 MB warm / +10 / +20 pairs). That is why the twenty-flip rule subtracts a SwiftUI control rather than reading after relief; `-memoryReliefHook` stays for diagnostics only. Evidence: `<data>/memory-phase2/`.

### 8.4 End-to-end video — `Scripts/e2e-video.sh`

Records `ADFReaderUITests/RendererSwitchUITests` (SwiftUI → TextKit 2 → SwiftUI on `kitchen-sink`, launched with `-rendererReset -rendererStats`) and writes a provenance manifest that ties the video to one binary.

- One isolated `build-for-testing` (Release, unsigned), then `test-without-building` with the exact generated `.xctestrun` and an explicit `--udid` (a device is created only on request, and only a device this run booted is shut down).
- The test requires the expected digest (fails when it is absent), reads the **app-observed** sha256 off the About sheet, asserts `tk2-row:<id>` / `tk2-live-rows` in both directions, and checks scroll preservation (stable element |ΔY| ≤ 2 px per switch, five round trips). After the scroll-to-top under TextKit 2 the H1's settled top (three reads 1 s apart within 0.01 pt) must be within 2 px of the SwiftUI arm's; the final switch back to SwiftUI happens with a TextKit 2 heading on screen.
- The build pins its source: the commit and clean/dirty state are read before `xcodegen generate` and again after the build (a change aborts), and `e2e-build-manifest.txt` records them with the sha256 of the app, the UI-test bundle binary and the `.xctestrun`. `--skip-build` requires that manifest and re-verifies every digest; the source is checked again at the end.
- Recording starts before the test launches and stops only after the named test's `passed` line. The recorder must stay alive throughout, and the video must cover the test (duration + 2 s ≥ recorder-ready → result), or the run fails. The manifest records the build command, commit and clean/dirty state, sha256 of the built, companion and installed binaries and of each bundled fixture, the observed digest, the test result and xcresult path, the simulator and Xcode versions, and the video's sha256 and duration. A run with a deliberately wrong digest must fail.
- Videos go in the task's data directory and the PR description, never in the repo.
