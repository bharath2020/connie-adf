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
                textRenderer: ADFTextRenderer = .swiftUI)
```

- `ADFTextRenderer` lives in `Sources/ADFRendering/TextKit2/ADFTextRenderer.swift`; `displayName` gives "SwiftUI" / "TextKit 2" for a host's picker.
- `ADFDocumentView` passes the choice to each `DocumentRow`, which sets the internal `EnvironmentValues.adfTextRenderer` to the host's choice **only for top-level `.richText` rows** and to `.swiftUI` for every other kind, so the value never leaks into a container's children.
- `RichTextBlockView` picks the engine with a plain `if`/`else` at the leaf (never `AnyView`, never `#available` at a lazy per-item position — ADR §18).
- On platforms without UIKit (`swift test` on macOS), `.textKit2` behaves as `.swiftUI`.

### Demo app

- **Toggle:** the reader toolbar's renderer menu (`renderer-menu`); its label is the active renderer's name as text ("SwiftUI" / "TextKit 2", `renderer-active`). Items: `renderer-swiftui`, `renderer-textkit2`, the Frame Rate HUD toggle, and "About This Build…" (`renderer-about`). The About sheet shows the version, active renderer, the running executable's sha256 (`build-sha256`) and the live TK2 row count (`tk2-live-rows`).
- **Persistence:** `@AppStorage("adf.textkit2.enabled")` (`Demo/ADFReader/RendererPreference.swift`).
- **Launch args** (applied in `App.init`, before any view reads the key; see `Demo/ADFReader/ADFReaderApp.swift`):

  | Arg | Effect |
  |---|---|
  | `-textkit2` | Seeds `adf.textkit2.enabled` ON. |
  | `-rendererReset` | Removes the key (applied first, so `-rendererReset -textkit2` starts ON from a clean slate). |
  | `-rendererStats` | Prints `RENDERER_STATS renderer=<swiftui\|textkit2> tk2Live=<n> tk2Layouts=<n> tk2Draws=<n> eligibleRoots=<n> fallbackRoots=<n>` at `READY` and alongside `SCROLL_METRICS`. |

  Never seed the key with `-adf.textkit2.enabled YES`: the argument domain pins the value and the in-app toggle would appear stuck.
- **Flip semantics:** flipping changes an environment value only. Live rows in the render region re-create their leaf; collapsed spacers keep their cached heights and rows re-measure when they re-enter. There is no `.id()` rebuild and no memo reset (that would be ADR §16's mass re-materialisation livelock). This is safe only because the two arms' heights are interchangeable, which the height-parity suite proves (§6.1, §8.1).

### Proving which renderer ran

A launch flag or a toolbar label never proves TK2 executed. `TextKit2Diagnostics` (internal, main-actor singleton) counts live rows, layouts and draws, keyed by owner id; each TK2 row sets `accessibilityIdentifier = "tk2-row:<ownerID>"`. Unit tests assert eligible rows create TK2 rows and ineligible ones do not, and that switching back releases them (live count returns to 0); the XCUITest asserts `tk2-row:<id>` and `tk2-live-rows` in both directions.

---

## 2. Stack order (final)

| # | Scope | Notes |
|---|---|---|
| **PR 1** | Foundation: live switch, diagnostics, gates; top-level paragraphs and headings H1–H6 | This PR. Coverage and fallbacks in §3. |
| — | **Selection feasibility spike** (throwaway, not a PR in the stack) | Proves the §5 contract on two TK2 rows before PR 2 multiplies text adapters. Keep or revise the contract from its result. |
| **PR 2** | Lists | Leading paragraphs of list rows reuse the TK2 text adapter (`ListBlockView.swift:37` calls `SegmentedTextView` directly and bypasses `RichTextBlockView` today); bullet/ordered/task/decision rows, continuation rows, nested lists; markers aligned on the first text baseline the TK2 row exposes. Task toggles keep working. |
| **PR 3** | Code blocks | Keep horizontal scrolling and the Copy button; no wrapping change. |
| **PR 4** | Containers | Panels, quotes, expands (incl. nested), layout columns, media captions — and the bodies of extension placeholders, which are containers of the same shape. |
| **PR 5** | Tables | Cells on TK2; width/height measurement. Header weight and dark-mode contrast arrive through the inherited-style contract (§6.5), which ships **no later than this PR**. |
| **PR 6** | Inline atoms | mention, status, date, emoji (short-name only), inlineCard, mediaInline, inlineExtension as text attachments; atom-bearing paragraphs leave the SwiftUI wrapping layout. |
| **PR 7** | Search highlight + arrival flash in TK2 rows | Reuses the Character↔UTF-16 map from §5. |
| **PR 8** | Text selection | Cross-block, native handles, per the §5 contract and the spike result. |

**Performance is gated in every PR against main** (§8). There is no separate performance PR: a PR that fails its gate is fixed before review, never deferred. Each PR adds its feature-dense fixture and interaction checks to the gate cumulatively.

---

## 3. PR 1 coverage and fallbacks

### What TK2 draws in PR 1

A top-level `.richText` block (paragraph or heading H1–H6) when **all** of these hold:

1. the switch is ON (`.textKit2`);
2. the block contains no inline atoms (`SegmentedTextView.mergedText(segments)` is non-nil);
3. every run is *describable* — it carries an `ADFFontSpec` (§6.5), so TK2 can resolve the same font SwiftUI would.

Text-run content in such blocks moves with them: every mark (strong, em, underline, strike, code, sub/sup, textColor, backgroundColor, link, small font size), hard breaks, emoji that carry a Unicode `text`, and inline placeholders. Because the preparer flattens them to top-level `.richText`, three less obvious sources are also eligible: the content of a `syncBlock` with an inline copy, a stray `caption` outside a `mediaSingle`, and an inline node at block level.

### What stays on SwiftUI in PR 1

- **Atom paragraphs** — any paragraph containing a mention, status, date, inlineCard, emoji without text, mediaInline or inlineExtension renders whole via SwiftUI.
- **Every other kind and every nested position** — lists, code blocks, tables (including the pinned header slice), panels, quotes, expands, layout columns and all of their contents, media captions, extension placeholders, custom (plugin) blocks and unknown nodes.
- **Search highlights and arrival flash** — TK2 rows do not paint them yet (PR 7).
- **Text selection and copy** — TK2 rows have none yet (PR 8). SwiftUI rows keep per-block `.textSelection(.enabled)`. This is an explicit, temporary limitation of the opt-in TK2 arm.
- **Undescribable themes** — a theme built from raw SwiftUI `Font`s without specs falls back (§6.5).

### Coverage facts (disclose in every perf table and PR description)

| Fixture | Roots | TK2-eligible in PR 1 | SwiftUI fallback |
|---|---|---|---|
| stress-5k | 5,000 | 2,400 (1,900 paragraphs + 500 headings) | 900 list roots, 400 code, 400 panels, 400 quotes, 500 expands |
| kitchen-sink | — | 9 rich-text roots | 2 atom-bearing rich-text roots plus every non-text kind |
| giant-table | 2 (heading + table) | 1 heading | 1 table (the fallback control) |

---

## 4. Parity inventory

One row per `RenderBlock.Kind` (`Sources/ADFPreparation/RenderBlock.swift`) and per `InlineAtom` (`Sources/ADFPreparation/InlineComposer.swift`). "Never" means the kind has no prepared rich text of its own (chrome, images, plugin views); any rich text it contains moves with the PR named.

**Selection/copy column:** "SwiftUI per-block" = the leaf has `.textSelection(.enabled)` today; every TK2 row has no selection until PR 8, after which all text participates in the §5 document-level selection.

### Block kinds

| Kind | Moves to TK2 | PR 1 behaviour | Owner-id handling | Selection / copy (before PR 8) | Links | Accessibility | Perf fixture |
|---|---|---|---|---|---|---|---|
| `richText` — top-level, atom-free paragraph / heading H1–H6 | **PR 1** | TK2 when ON and every run describable; otherwise SwiftUI. Link-bearing rows are still TK2 rows (`TextKit2RowView`, `tk2-row:<id>`) but are TextKit 1-backed inside: the row's own TextKit 1 stack lays out, sizes, baselines, draws and hit-tests their text, as SwiftUI's `Text` does (§6.4) | `RenderBlock.id` passed through the leaf and stored on the TK2 row; `tk2-row:<id>`; search spans key on it | TK2: none. SwiftUI arm: per-block | TK2: tap inside the link run's glyph rects (from the row's TextKit 1 stack) → SwiftUI `openURL`; whitespace taps rejected | One element: label = plain text, `staticText` (+ `header`); heading level from the SwiftUI modifier on `RichTextBlockView`; "Open link <host>" custom action per link | stress-5k (2,400 eligible), kitchen-sink, text-dense, long-paragraph, giant-table heading |
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
- **Re-sync before geometry:** the single `NSTextLayoutManager` may currently be laid out for a different width than a cached answer. Before drawing or hit-testing, `layoutSubviews` makes the container width equal `bounds.width` and re-runs `ensureLayout` if it differs. Cached numbers are never used for geometry without that re-sync.
- **Baselines:** the representable exposes `.firstTextBaseline` / `.lastTextBaseline` from the layout result, equal to SwiftUI's for single- and multi-line text (PR 2's list markers depend on it).
- **Covered by tests:** repeated and reordered proposals (A, B, A — height at A unchanged, draw geometry at A correct), content change at a stable row id, Dynamic Type change, teardown after switch or collapse, baseline exposure.

### 6.3 Line-pitch rule

- The TK2 row's height is a **measurement rule over TextKit's layout**, not a layout change: the first baseline already sits at the ascent, as in SwiftUI.
- Any correction must be **sign-correct** at every size category (leading is negative at the largest accessibility sizes) — never subtract a constant.
- The drawn area must never clip ink: the layout's ink bounds must lie within it (asserted).
- Backgrounds, underline/strike, hit-testing and (later) selection rects use **the same geometry as drawing**.
- Monospaced runs resolve through the preferred text-style descriptor with `.monospaced` design, keeping ascent, descent and leading identical to body at every category. Fonts resolve with `UIFont.preferredFont(forTextStyle:compatibleWith:)`, never `UIFontMetrics` point scaling.

### 6.4 Line pitch and wrapping (measured)

Background, measured against fresh main before the fix (W = 370 pt, 3x, 70 probe cases):

- SwiftUI `Text` height = (N − 1) · (ascent + descent + leading) + ceil_px(ascent + descent); raw TK2 usage height = N · (ascent + descent + leading). At body / `.large` this made raw TK2 rows 1.667 pt taller per row, accumulating down the document.
- SwiftUI breaks one word earlier on nearly full lines (it avoids a single-word last line); line *counts* agree across strategies, so only per-line extents reveal the difference.

**Rules shipped in PR 1** (all measured against SwiftUI bitmaps and guides on iOS 26.3 at 3x and 2x, and on iOS 18.5; evidence under `<data>/parity/`):

- **Height** = ceil_px(last baseline + last-line descent), where a line's ascent/descent are the tallest/deepest run on it by its *font's* metrics — a fallback font's do not count (`Text` sizes "ab 🧪", "ab 漢字" and "ab नम" by the system font alone at 1600/1600 sizes, where Core Text's line bounds are taller) — and a baseline offset only ever grows them (a superscript's raise adds to its ascent, a subscript's drop to its descent). 930/930 heights exact (worst Δ 0) at 3x and 2x, plus 310 RTL / Bold Text cases and 156 corpus checks; with the sub/superscript-line family and the fixture sweep below, 1,530 + 510 + 10,820 measurements.
- **Superscript lines** (`stress-5k` block 503: 3.33 pt short at large, 24 pt at AX3, every row below shifted on a renderer switch). TextKit 2 lets a raised run's offset eat its descent (a line set wholly in superscript gets none) and fits the line in the font's leading-inclusive line height; `Text` keeps the descent below the baseline and lets the raise eat only the run's leading. Read from `Text.Layout` line origins (offsets −4…12 pt, every pairing of plain/sub/superscript lines): below a line `Text` keeps the largest run descent + leading, a raised run's leading reduced by its raise (never below 0); negative leading (AX5) belongs to the next line's ascent, as in TextKit. The row moves every line below such a line by the difference (drawn line by line when moved). Run backgrounds: the band moves with the run's baseline offset beyond the one the whole line shares — a highlighted superscript among plain text rises with it, a line set wholly in it does not — and spans the Core Text ascent (a subscript lowers it). The suites' sub/sup family: first, middle, last and only lines, with colour, highlight, a link before or on the run, a hard break after it. The same escape explains the lifecycle gate's −26 px (−8.67 pt) shift on a switch made straight after a programmatic jump (`lifecycle/diag3`): an eligible row above Section 500, off screen but already laid out by the lazy stack, measured differently under TK2, and the scroll view keeps its raw offset; a gesture-parked view had other rows laid out above it. Replayed with the gate's own steps: −26 px (−36 px below block 503) at 0d7730e, 0 px at 9bf45ff for the menu switch, a menu open/dismiss, re-choosing the same renderer, About open/close and a UI-less flip. Not renderer-agnostic and not issue #6. Evidence: `<data>/jump-switch-c/`.
- **Fixture sweep:** every TextKit 2-eligible root of kitchen-sink, stress-5k and text-dense (10, 2,400, 3,000 blocks) at 370 pt, large and AX3, both arms: 10,820 measurements, max |Δ| 0.333 pt (residual 6). Per device at 9bf45ff (`TextKit2FixtureSweepTests`): 3x iOS 26.3 max 0.333 pt, 8 residuals; 2x (SE) max 0.5 pt (1 px), 17 residuals; iOS 18.5 max 0.333 pt, 9 residuals — all of them residual 6. Before this round: 46 escapes, worst 96 pt (superscript lines, link text wrapped by TextKit 2 instead of TextKit 1, fallback-font line metrics).
- **First baseline** is rounded to the nearest device pixel and the whole text is drawn shifted onto it (later lines keep their fractional offsets). Drawn unshifted, glyphs, underlines and strikes land 1 px low wherever the first baseline's pixel fraction is small (H1 at xxxLarge: 97.12 px). The row reports first/last baselines pixel-rounded too (16.187 → 16.333 at 3x), as `Text` does.
- **Line breaks:** `lineBreakStrategy = .standard`. 2,052 near-full Latin strings at large/xxxLarge × 370/640/353.333 pt matched per-line ink extents with `.standard` and `.pushOut` and missed 66 times with no strategy (one word later); 1,278 Korean, Japanese, Arabic and accented-Latin strings matched only with `.standard` (`.pushOut` alone missed 257 Korean strings — `.standard` adds Hangul word priority). In total 6,349 lines across 8 width/size sets, 0 mismatches.
- **Width hugging and alignment:** the reported width is the widest line, trailing whitespace included (left-to-right lines whose whitespace hangs past the container are measured with Core Text), pixel-ceiled, at most ceil_px(proposal) — `Text` reports 300.667 for a 300.5 proposal its whitespace overflows. Drawing reuses the measured layout shifted by the alignment within the hugging bounds; the canvas is clipped to the bounds horizontally because `Text` clips side overhang (an indented line-initial "j" loses its tail at 72 px). Centred/end text: bitmap sum of differences 0 at 30 of 32 width/size/direction checks (the other 2 are residual 2).
- **Trailing hard break:** the empty line's baseline = previous baseline + previous descent + its own ascent + the previous line's positive leading (its largest run's: a subscript's, not the break's, on a subscript line) + the break font's negative leading; a line's closing break never counts toward its metrics (TextKit and `Text` both skip it); before iOS 26 positive leading is dropped (negative leading applies on both). TextKit's own extra line fragment differs (it ignores negative leading after a first line, and after two breaks uses the 13.8 pt default font). 35/35 heights exact on 26.3; see residual 4 for iOS 18.5.
- **Text containing a link is laid out, sized and drawn by TextKit 1**, exactly as SwiftUI does (since 9bf45ff layout too, not only drawing). Swizzling `NSLayoutManager` under the SwiftUI arm showed that SwiftUI renders interactive (linked) text with `NSAttributedString` string drawing: an `NSLayoutManager` (`usesFontLeading = false`, `lineFragmentPadding = 0`) in a container as wide as the `Text`'s frame, first baseline on a device pixel, `NSUnderline` on link/underline/annotation runs, `NSBackgroundColor` fills. TextKit 1's decorations differ from TextKit 2's and from any formula we fitted: underlines are placed per line from the line fragment (8 px lower than the fitted model on lines after a line holding both a sub- and a superscript, kitchen-sink at AX3), skip descenders, and backgrounds fill whole line fragments (leading included) and run line-ending whitespace to the frame's edge. The row therefore draws such text with its own TextKit 1 stack at the same pixel phase (fills clipped to the frame, as SwiftUI's are) and sizes it by the stack's used rect clamped to the container (centred: 350.667, where the line-width rule gives 353.333). Its lines, baselines and link hit-test rects come from that stack too: TextKit 1 wraps an emoji TextKit 2 lets end a line (`text-dense` block 283: one line, 22 pt, short at large; 36 such blocks in the sweep) and spaces a superscript line by its full leading. A replica of that drawing matched SwiftUI's bitmaps with 0 differing pixels; after the change the kitchen-sink paragraph, a link after a subscript line and a centred highlight after a link are 0 differing pixels at large/xxxLarge/AX3, light and dark, on iOS 26.3 and 18.5. TextKit 2 only bounds such a row's ink. Evidence: `<data>/parity/link-textkit1/` (README, probe logs, crops), `<data>/parity/link-emoji-textkit1/`.
  - **Consequence for PR 8 (selection):** a link-bearing row is laid out and drawn by TextKit 1, so its selection rects must come from the row's TextKit 1 stack (as its link hit-test rects do), not from TextKit 2 — the lines can break differently. The row draws the highlight itself, beneath the TextKit 1 glyph pass. Any selection test must include a link-bearing row, centred, wrapped and with an emoji.

**Residuals** (each recorded with `withKnownIssue` or a measured tolerance, so a fix shows up as a test failure; counts from the final runs at e6934f0; residuals 6–7 and the sweep at 9bf45ff):

1. **Last-baseline guide +1 px.** SwiftUI's `lastTextBaseline` guide sits exactly 1 px below its drawn baseline in 6/56 cases at 3x (H1 at AX3, sub/superscript lines; 12 known-issue records) and 2/56 at 2x; never −1 px. No formula found (best candidate 113/132). Evidence: `parity/last-baseline/` (probe36.txt).
2. **Centred text at a fractional width.** At large, w = 300.5, both directions, 3x and 2x, SwiftUI's glyphs sit 0.5 px left of ours: its drawing layer is 849 px around an 844 px frame, and the bitmaps are identical after a −0.5 px shift. The rule behind that layer outset is unknown (2 known-issue records). Evidence: `parity/align-center-offset/` (probe40/41/44).
3. **SF Mono rasterization.** No pixel differs by more than 24/255, but a faint edge row can flip the ink threshold: 3 line bands at 3x and 1 at 2x when it was measured; 0 in the e6934f0 runs. Recorded only when the band has no visibly differing pixel. Evidence: `parity/mono-raster/`.
4. **iOS 18.5 only, two or more trailing hard breaks at AX3+:** `Text` also drops the middle empty line's negative leading — 0.333–1.333 pt shorter than our layout. Evidence: `parity/ios18-trailing-break/probe49-ios18.log`.
5. **Plain-text (link-free) underline and strike ends:** SwiftUI's end 0–2 px shorter (antialiasing level; the pixel suites still show 0 differing pixels). Evidence: `parity/link-decorations/`.
6. **Text with a link and an emoji:** `Text` lays it out with TextKit 1 but does not count the emoji font's metrics in line heights as TextKit 1 does (+0.0135 pt per emoji line at AX3): 1 px taller in 8/10,820 sweep measurements at 3x (17 at 2x, 9 on iOS 18.5; AX3), 4 px for `link-emoji-wrap` at AX5; never shorter (known-issue records). Evidence: `parity/link-emoji-textkit1/`, `parity/fallback-font-metrics/`.
7. **Highlighted sub/superscript run, horizontal edges:** its band starts and ends a fraction of a pixel off `Text`'s (one antialiased column; ≤ 0.04 % of pixels); rows exact. Evidence: `parity/subsup-highlight-bands/`.

### 6.5 Inherited styling and themes

- `ADFTheme` gains spec-first construction; the SwiftUI `Font` is derived from the `ADFFontSpec`. A raw-`Font` initialiser stays source-compatible but marks the spec `nil` (undescribable); such runs force the SwiftUI path. No caller has to update two fields.
- `TextKit2RenderInputs` carries the resolved inherited inputs — foreground, font weight, tint, layout direction, size category, legibility weight, colour scheme — and is part of the cache key and the redraw decision. Top-level rows in PR 1 inherit no foreground or weight, but the fields exist so PR 2–5 do not reinvent them: table header weight and contrast foregrounds, and media captions' `.footnote` / `.secondary`, are delivered through this contract. It ships **no later than the tables PR (PR 5)**.
- Foreground precedence: a prepared foreground (author `textColor`, or the contrast colour derived from a background mark) first; then the inherited foreground; then link tint (only when no foreground was set); else `.label`.

---

## 7. Links and accessibility (TK2 rows)

- **Links:** a `UITapGestureRecognizer` with `cancelsTouchesInView = false` that never swallows vertical flings. A tap opens a link only if it lies inside that link run's glyph rects (the union of its line-fragment segment rects, taken from the row's TextKit 1 stack — the engine that laid the text out), not "nearest character"; `NSNotFound` is guarded. Delivery goes through the SwiftUI `openURL` action, so hosts keep control.
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

# Performance (§8.3): calibrate once (main as both arms), then gate.
Scripts/perf-gate.sh --calibrate --udid <UDID> --app-a <main ADFReader.app> \
    --out <data>/perf/calibration [--fixtures "..."] [--runs 10]
Scripts/perf-gate.sh --udid <UDID> --app-a <main .app> --app-b <branch .app> --app-c <branch .app> \
    --calibration <data>/perf/calibration/calibration.json --out <data>/perf/gate [--fixtures "..."] [--runs 10]
#   [--pilot] [--arm-c-args "-textkit2"] [--candidate-args "-rendererStats"] [--no-candidate-markers]
#   [--extra-args "<flags>"] [--expected-blocks "f=n ..."] [--trial-timeout 120] [--trial-timeout-for "f=s ..."]
#   [--ready-timeout 60] [--rss-ms 200] [--footprint-ms 1000] [--no-sampler] [--prior-summary <json>]
#   [--coverage "<text>"] [--appearance light|dark] [--bundle-id <id>] [--keep-booted] [--dry-run]
python3 -I Scripts/perf_summarize.py <cal>/trials.csv --calibrate --write-calibration <cal>/calibration.json [--attempt 1]
python3 -I Scripts/perf_summarize.py <out>/trials.csv --calibration <cal>/calibration.json \
    [--json summary.json] [--out summary.md] [--prior-summary <earlier summary.json>]
python3 -I Scripts/perf_summarize.py <pilot>/trials.csv --pilot [--calibration ...] [--suggest-timeouts]

# End-to-end video (§8.4); a negative control (wrong digest) must fail.
Scripts/e2e-video.sh --udid <UDID> --out <data>/videos/<name>.mp4
#   [--derived-data <dir>] [--skip-build] [--keep-booted] [--expected-sha256 <hex> | --negative]
#   [--test-timeout <s>] [--recorder-ready-timeout 20] [--xcodebuild-grace <s>] [--dry-run]
#   (--create-device <name> instead of --udid: explicit opt-in, never deleted)

# Lifecycle checks (plan §3 checks 2–6) with the host agent Scripts/lifecycle_agent.py.
Scripts/lifecycle-gate.sh --udid <UDID> --out <data>/lifecycle/<run>
#   [--derived-data <dir>] [--skip-build] [--only <testName>]... [--suite-timeout 3600]
#   [--xcodebuild-grace 120] [--keep-booted] [--dry-run]
```

**Reference builds.** The reference is a Release, arm64-simulator, unsigned build of main from a clean `git archive` export (never the working tree), with `sha256.txt` beside the `.app`. `-scrollToFraction` lands exactly only since 9178cad (an animated jump into the lazy stack alone varied by up to 26 px between launches of one build: stress-5k at 0.5, step 3); a reference built from an older main needs that automation-only hunk applied, or arm A lands nondeterministically. PR 1's reference: `<data>/builds/main-a9e6aa2+scrolljump/` = a9e6aa2 + `scrolljump.patch` (the `ReaderView.scrollToFraction` hunk of 9178cad; sha256 recorded beside it). The unpatched `main-a9e6aa2` build is kept for the perf gate, which does not scroll to a fraction.

### 8.1 Parity suites

Location: `Tests/ADFRenderingTests/TextKit2/` (Swift Testing, `#if canImport(UIKit)`, so they run on the simulator only). Each suite hosts the real `RichTextBlockView` in both arms through the environment.

| Suite | Checks |
|---|---|
| `TextKit2HeightParityTests` | Height \|Δ\| ≤ 0.01 pt; first baseline, baseline pitch, last baseline and ink bounds separately; body, H1–H6, mixed mono/sub/sup; categories xSmall…AX5; 1/2/3+ lines; integer, fractional and narrow widths |
| `TextKit2WrapParityTests` | Per-line horizontal ink extents from both arms' bitmaps match exactly, on a corpus of nearly-full lines; TK2 line-fragment ranges logged for diagnosis |
| `TextKit2PixelParityTests` | 3x and 2x, light and dark, an H1, the every-mark paragraph, the kitchen-sink paragraph, a link after a subscript line and a centred highlight after a link: vertical ink profile exact; differing pixels ≤ 0.2 % (all currently 0) |
| `TextKit2RowViewTests` | Row contract: cache and proposal cases (§6.2), resolver traits and metrics, diagnostics counters, link hit-testing |

```sh
# Simulator: always address the device by udid (the name=…,OS= form does not resolve).
xcodebuild test -scheme ADFKit-Package \
  -destination 'platform=iOS Simulator,id=<udid>' \
  -only-testing:ADFRenderingTests/TextKit2HeightParityTests \
  -only-testing:ADFRenderingTests/TextKit2WrapParityTests \
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
- **PR 1 result** (`<data>/visual/gate-4ded1a4/`, branch 4ded1a4 vs a9e6aa2 + scrolljump): 48/48 pairs PASS — A–A', A–B and A–C all 0 px in 16 configurations, every crop 0 % with a 0 px offset; `RENDERER_STATS` confirmed swiftui on every B and textkit2 on every C. `gate-8518d01/` keeps the pre-fix run (nondeterministic stress-5k p0.5 s3 landing) as root-cause evidence.
- **Pass:** A–A' noise recorded (expected 0.00 %); A–B 0.00 %; A–C ≤ 0.5 % whole-viewport **and** every text-block crop ≤ 0.5 % with a vertical offset of 0 px.

### 8.3 Performance — `Scripts/perf-gate.sh` + `Scripts/perf_summarize.py`

Interleaved A/B/C trials on one simulator: launch to `READY` (labelled "preparation readiness", not first visible content), first chunk, autoscroll dropped frames / dropped rate / hitch ratio, memory (RSS and `footprint`, sampled peak).

- **Fail closed:** a result is valid only with the full count of counted runs for every fixture and arm, every metric present and finite, exit 0, the expected `READY` line, and the installed sha256 and argv matching the arm. Anything else is INVALID (non-zero exit), never PASS. A candidate crash or timeout FAILs.
- **Calibrate first:** 10 paired A-vs-A' trials per fixture with the main app as both arms; per-metric allowance = max(max \|ΔAA'\|, absolute floor); frozen in `calibration.json` before any candidate result is inspected. Too noisy → INCONCLUSIVE, quiesce and recalibrate once.
- **Gate:** ≥ 10 counted pairs per fixture and arm pair, balanced order, one discarded warm-up. PASS if the one-sided 95 % upper bound of the mean paired delta ≤ the allowance. **Both C (ON) and B (OFF) must pass** — B carries the font-spec baking and switch plumbing on the shipping path. A FAIL is never rerun to green without a code change.
- **Fixtures (PR 1):** `kitchen-sink`, `stress-5k`, `giant-table`, plus `text-dense` (~3,000 text-only paragraphs/headings) and `long-paragraph` (one ~20,000-character paragraph; the per-row layout worst case), generated with `Tools/make-fixtures.swift`. Later PRs add their feature-dense fixture.
- **Report:** per fixture × metric — A and C (and B) median (min–max), mean paired Δ with its 95 % upper bound, allowance, verdict — with the §3 coverage line.

The autoscroll gate alone provably misses livelocks. Also run, in **both** arms: a real fling with an instantaneous-CPU settle check (`top -l 2 -pid <pid>` → ~0 % within 5 s), scene-snapshot thrash (Home / lock / app switcher ×5), a 60-second idle soak, and for the switch, twenty flips on stress-5k (live TK2 row count back to 0 when OFF; settled memory growth ≤ 5 MB). Measured at 9bf45ff: raw `phys_footprint` growth across flips is allocator high-water, not retention — over 10 flip pairs live malloc stayed at 63.84 MB (−384 B; largest class +2 KB, in-process zone histogram) while the footprint rose 139 → 159 MB, and `malloc_zone_pressure_relief` returns it each time (102 / 99 / 101 MB warm / +10 / +20 pairs). A footprint threshold should be read after relief, or on live malloc bytes. Evidence: `<data>/memory-phase2/`.

### 8.4 End-to-end video — `Scripts/e2e-video.sh`

Records `ADFReaderUITests/RendererSwitchUITests` (SwiftUI → TextKit 2 → SwiftUI on `kitchen-sink`, launched with `-rendererReset -rendererStats`) and writes a provenance manifest that ties the video to one binary.

- One isolated `build-for-testing` (Release, unsigned), then `test-without-building` with the exact generated `.xctestrun` and an explicit `--udid` (a device is created only on request, and only a device this run booted is shut down).
- The test requires the expected digest (fails when it is absent), reads the **app-observed** sha256 off the About sheet, asserts `tk2-row:<id>` / `tk2-live-rows` in both directions, and checks scroll preservation (stable element |ΔY| ≤ 2 px per switch, five round trips).
- Recording starts before the test launches and stops only after the named test's `passed` line. The manifest records the build command, commit and clean/dirty state, sha256 of the built, companion and installed binaries and of each bundled fixture, the observed digest, the test result and xcresult path, the simulator and Xcode versions, and the video's sha256 and duration. A run with a deliberately wrong digest must fail.
- Videos go in the task's data directory and the PR description, never in the repo.
