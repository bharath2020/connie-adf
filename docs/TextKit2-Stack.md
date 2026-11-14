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
- `ADFDocumentView` passes the choice to each `DocumentRow`, which sets the internal `EnvironmentValues.adfTextRenderer` to the host's choice **only for top-level `.richText` and `.listRows` rows** (`TextKit2Scope.inheritsRenderer`, `ADFDocumentView.swift:312-314`; a list only when it passes the list rules, §3 "PR 2: lists") and to `.swiftUI` for every other kind, so the value never leaks into a container's children. A list row is the only other setter: it passes the choice to its own text and resets every other trailing block to `.swiftUI` (`ListBlockView.swift:63`). `TextKit2RendererSetterTests` scans `Sources/` and requires exactly these two setters.
- One shared leaf, `TextEngineLeaf`, picks the engine with a plain `if`/`else` (never `AnyView`, never `#available` at a lazy per-item position — ADR §18); `RichTextBlockView` and a list row's leader both draw through it.
- On platforms without UIKit (`swift test` on macOS), `.textKit2` behaves as `.swiftUI`.
- **All public surface PR 1 adds:** `ADFTextRenderer` (+ `displayName`); the `ADFDocumentView(textRenderer:)` parameter; the diagnostics read-outs below (`ADFTextKit2Stats`, `ADFTextKit2Coverage`, `ADFTextRenderer.textKit2Stats`, `.textKit2Coverage(of:)` — public because the demo reads them across the module boundary); in `ADFPreparation`, `ADFFontSpec` (+ `Font(adfFontSpec:)`, `TextStyle.swiftUITextStyle`), the `adf` attribute scope carrying it, `ADFTheme.bodyFontSpec` / `codeFontSpec` / `headingFontSpec(_:)`, and `InlineComposer.compose(_:baseFont:baseFontSpec:)`. The small-text and sub/superscript specs stay internal, like their `Font` twins.
- **PR 2 adds no public type**, only defaulted fields on the two diagnostics read-outs, so PR 1 callers compile unchanged: `ADFTextKit2Stats.liveListRowCount` and `.conversionCount`; `ADFTextKit2Coverage.eligibleTextLeaves`, `.linkedTextLeaves`, `.fallbackTextLeaves`, `.listLeaderLeaves` and `.listTrailingLeaves` (§3, "Diagnostics and coverage").

### Demo app

- **Toggle:** the reader toolbar's renderer menu (`renderer-menu`); its label is the active renderer's name as text ("SwiftUI" / "TextKit 2", `renderer-active`). Items: `renderer-swiftui`, `renderer-textkit2`, the Frame Rate HUD toggle, and "About This Build…" (`renderer-about`). The About sheet shows the version, active renderer, the running executable's sha256 (`build-sha256`), the live TK2 row count (`tk2-live-rows`) and, since PR 2, how many of those rows draw list text ("Of Which List Text", `tk2-list-live-rows`); under `-interactionProbe` it also shows the probe's rows (below).
- **Persistence:** `@AppStorage("adf.textkit2.enabled")` (`Demo/ADFReader/RendererPreference.swift`).
- **Launch args** (applied in `App.init`, before any view reads the key; see `Demo/ADFReader/ADFReaderApp.swift`):

  | Arg | Effect |
  |---|---|
  | `-textkit2` | Starts this launch ON whatever was persisted (writes `adf.textkit2.enabled`, marked as automation's; the next launch without the flag removes it). |
  | `-rendererReset` | Removes the key (applied first, so `-rendererReset -textkit2` starts ON from a clean slate). |
  | `-rendererStats` | Prints `RENDERER_STATS renderer=<swiftui\|textkit2> tk2Live=<n> tk2Layouts=<n> tk2Draws=<n> eligibleRoots=<n> fallbackRoots=<n>` at `READY` and alongside `SCROLL_METRICS`. tk2-gates adds `tk2NativeDraws=` (`nativeDrawCount`), `tk1BackedRows=` (`textKit1BackedRowCount`), `tk1BackedDraws=` (`textKit1BackedDrawCount`), `linkRoots=` and `textFallbackRoots=` (coverage). Under `-rebuildControlPicks` the line also carries `rebuildControlRows=` and `rebuildControlAppeared=`. Confirmed at 82c9d75 (`Demo/ADFReader/RendererStats.swift`; required on every visual-gate capture; printed on every B and C perf trial). PR 2 adds, before the rebuild-control keys, `tk2ListLive=` (`liveListRowCount`), `tk2Conversions=` (`conversionCount`) and the leaf coverage `eligibleTextLeaves=`, `linkedTextLeaves=`, `fallbackTextLeaves=`, `listLeaderLeaves=`, `listTrailingLeaves=`; `Scripts/perf_trial.py` parses the list keys (`STATS_FIELDS`). |
  | `-rebuildControlPicks <n>` | Lifecycle gate only: the first `n` menu picks of TextKit 2 rebuild the rows TextKit 2 would swap as plain SwiftUI (the twenty-flip memory control, §8.3); About This Build shows `rebuild-control-rows`, `RENDERER_STATS` appends `rebuildControlRows=<n> rebuildControlAppeared=<n>`. |
  | `-scenePhaseProbe` | Lifecycle gate only: a small overlay (`scene-phase-probe`) counts the scene's own phase transitions, `background=<n> inactive=<n> active=<n> last=<phase>`. The thrash check (tests 5 and 6) reads it after each stop, because `XCUIApplication.state` reads `runningForeground` at every stop on the simulator. |
  | `-interactionProbe` | UI tests only (PR 2): records every `.taskToggled` the reader's interaction handler receives and every URL the document opens (an `openURL` action that keeps link taps in the app, so nothing goes to Safari). About This Build shows `probe-task-dispatches`, `probe-task-last` (`<id> <true\|false>`), `probe-url-opens` and `probe-url-last`, and each event prints a `PROBE …` line. Without the flag nothing is recorded, no rows appear and links open as usual (`InteractionProbe`, `Demo/ADFReader/ReaderView.swift`). |

  Never seed the key with `-adf.textkit2.enabled YES`: the argument domain pins the value and the in-app toggle would appear stuck.
- **Flip semantics:** flipping changes an environment value only. Live rows in the render region re-create their leaf; collapsed spacers keep their cached heights and rows re-measure when they re-enter. There is no `.id()` rebuild and no memo reset (that would be ADR §16's mass re-materialisation livelock). This is safe only because the two arms' heights are interchangeable, which the height-parity suite proves (§6.1, §8.1).

### Proving which renderer ran

A launch flag or a toolbar label never proves TK2 executed. `TextKit2Diagnostics` (internal, main-actor singleton) counts live rows, layouts, draws and **native draws** (draw passes in which TextKit 2 itself drew layout fragments), process-wide; each TK2 row sets `accessibilityIdentifier = "tk2-row:<ownerID>"`. Public read-outs: `ADFTextRenderer.textKit2Stats` (`liveRowCount`, `layoutCount`, `drawCount`, `nativeDrawCount`, `textKit1BackedRowCount`, `textKit1BackedDrawCount`) and `ADFTextRenderer.textKit2Coverage(of:)` (`eligibleRoots`, of which `linkRoots`; `fallbackRoots`, of which `textFallbackRoots` — paragraphs and headings kept on SwiftUI). **TextKit 1-backed rows are reported apart:** a row whose text has a link is a TK2 row (`tk2-row:<id>`, counted live) whose own TextKit 1 stack lays out and draws the text (§6.4), so its draws count in `textKit1BackedDrawCount` and never in `nativeDrawCount`; a draw is one or the other, never both. A gate that must prove TextKit 2 rendering requires `nativeDrawCount > 0`; every perf and coverage table states the TextKit 1-backed share (stress-5k 507 of 2,400 eligible roots, text-dense 808 of 3,000). Unit tests assert eligible rows create TK2 rows and ineligible ones do not, and that switching back releases them (the test's own row instances leave the window, and dropping its references lowers the live count by exactly their number). Suites run in parallel, so tests check their own hosted rows and compare a process-wide counter only across a span with no suspension; the XCUITest asserts `tk2-row:<id>` and `tk2-live-rows` in both directions.

**From PR 2**, list text is proved apart: `liveListRowCount` counts the live rows drawing list text (a top-level heading drawing natively proves nothing about lists), a list leaf's row is `tk2-row:<PreparedListRow.id>` and a list paragraph's `tk2-row:<its block id>` (owners below root level, `0.<n>.…`), and the leaf coverage counts list leaders and list paragraphs apart from roots (§3, "Diagnostics and coverage"). Coverage is static — potential coverage: it does not know an active search or the host's text environment — so the execution proof is always the live counters and row identifiers.

---

## 2. Stack order (final)

| # | Scope | Notes |
|---|---|---|
| **PR 1** | Foundation: live switch, diagnostics, gates; top-level paragraphs and headings H1–H6 | Merged 2026-10-29 as https://github.com/bharath2020/connie-adf/pull/9. Coverage and fallbacks in §3. |
| — | **Selection feasibility spike** (throwaway, not a PR in the stack) | Closed 2026-10-30: the captain's manual cross-row selection and Copy worked on the spike; the §5 contract is **kept as written** (§5.6). Production acceptance stays with PR 8. |
| **PR 2** | Lists | This PR. List leaders and the paragraphs and headings in a list row's text column draw through the shared text leaf (`TextEngineLeaf`), for bullet/ordered/task/decision rows, continuation rows and nested lists (flattened into depth rows of their root); owners are `PreparedListRow.id` for leaders and each paragraph's own block id. Markers, spacing, depth padding and the decision background stay SwiftUI chrome, aligned on the first text baseline the TK2 row exposes. Task toggles keep working. Where TK2 cannot match `Text`'s placement, and before iOS 26, the text stays on SwiftUI (§3, "PR 2: lists"). Lists inside containers and table cells move with their container (PR 4 / PR 5). |
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
5. no inherited `Text` styling the row does not reproduce is set — line spacing, text case, a line limit, a minimum scale factor or redaction (`TextKit2Leaf`);
6. the active search has no highlight for the block (`TextKit2Leaf`): while a session has spans for it, it renders on SwiftUI, which paints the highlights and the arrival flash; clearing the search returns it to TK2 (heights are equal, so the swap moves nothing).

Text-run content in such blocks moves with them: every mark (strong, em, underline, strike, code, sub/sup, textColor, backgroundColor, link, annotation, small font size), hard breaks, emoji that carry a Unicode `text`, and inline placeholders. Because the preparer flattens them to top-level `.richText`, three less obvious sources are also eligible: the content of a `syncBlock` with an inline copy, a stray `caption` outside a `mediaSingle`, and an inline node at block level.

### What stays on SwiftUI in PR 1

- **Atom paragraphs** — any paragraph containing a mention, status, date, inlineCard, emoji without text, mediaInline or inlineExtension renders whole via SwiftUI.
- **Links are disclosed, not native, in PR 1:** a paragraph or heading with a link is a TK2 row laid out and drawn by its own TextKit 1 stack, as `Text` lays out linked text (captain decision; §6.4). Native TextKit 2 links are PR 6.
- **Two or more trailing hard breaks before iOS 26**, and text under inherited styling the row does not reproduce (condition 5 above).
- **Every other kind and every nested position** — lists (PR 2, below), code blocks, tables (including the pinned header slice), panels, quotes, expands, layout columns and all of their contents, media captions, extension placeholders, custom (plugin) blocks and unknown nodes.
- **Search highlights and arrival flash** — TK2 rows do not paint them yet (PR 7); a block with highlights renders on SwiftUI while the search is active (condition 6 above).
- **Text selection and copy** — TK2 rows have none yet (PR 8). SwiftUI rows keep per-block `.textSelection(.enabled)`. This is an explicit, temporary limitation of the opt-in TK2 arm.
- **Undescribable themes** — a theme built from raw SwiftUI `Font`s without specs falls back (§6.5).

### Coverage facts (disclose in every perf table and PR description)

| Fixture | Roots | TK2-eligible in PR 1 | SwiftUI fallback |
|---|---|---|---|
| stress-5k | 5,000 | 2,400 (507 TextKit 1-backed) | 900 list roots, 400 code, 400 panels, 400 quotes, 500 expands, other kinds |
| kitchen-sink | 38 | 10 (1 TextKit 1-backed: the every-mark paragraph) | 2 atom-bearing rich-text roots plus every non-text kind |
| text-dense | 3,000 | 3,000 (808 TextKit 1-backed) | — |
| long-paragraph | 3 | 3 (1 TextKit 1-backed: the long paragraph, which carries links; measured at 82c9d75 with `-rendererStats`, not in the pr45 design) | — |
| giant-table | 402 (heading + table slices) | 1 heading | the table (the fallback control) |

Counts from `ADFTextRenderer.textKit2Coverage(of:)` over each fixture prepared with the default theme (content-based; identical on iOS 18 and 26 for these fixtures, which have no paragraph ending in two hard breaks). "TextKit 1-backed" = `linkRoots`.

### PR 2: lists

Evidence paths in this subsection and in §6.7 are under PR 2's task data directory (`<data>`).

#### Scope and boundaries

- **Roots.** `DocumentRow` passes the host's choice to a top-level `.listRows` block as it does to `.richText` (`TextKit2Scope.inheritsRenderer`, `ADFDocumentView.swift:312-314`), subject to the list rules below. The preparer flattens nesting (`ListPreparer`): a nested list becomes deeper rows of its root list, so "nested lists" means every depth row of a root list, under one policy at every depth.
- **The list child boundary.** A list row is the only other place the renderer is set. When the row keeps the renderer (rule A below), it passes the choice to its leader and to the paragraphs and headings in its text column; it sets `.swiftUI` on every other trailing block, and so on that block's whole subtree (`ListBlockView.swift:49-63`). The reset is required, not defensive: no container sets the key (panels, quotes, expands, layout columns, extension bodies and table cells recurse through plain `BlockView`), and an environment value flows to every descendant, so without it a panel inside a list item would inherit TK2. `TextKit2RendererSetterTests` scans `Sources/` and requires exactly two setters, in `ADFDocumentView.swift` and `ListBlockView.swift`.
- **Trailing `.listRows`** occur even though a direct nested list is always flattened: a list inside a `syncBlock` (transparent to the preparer), a list under a malformed item child, and a non-`taskItem` in a `taskList` or a non-`decisionItem` in a `decisionList`. `TrailingListRowsOriginTests` pins all three (`Tests/ADFPreparationTests/ListFixturePreparationTests.swift`). Under the list rules below, the row holding one keeps all its text, and the trailing list, on SwiftUI (rule A); the list's other rows keep the renderer.
- **Out of scope:** lists and text inside panels, quotes, expands, layout columns, extension bodies, media captions and table cells stay SwiftUI with their container (PR 4 / PR 5). A list never turns the renderer on by itself.
- **One rule for views and coverage.** The views and the coverage walk (`TextKit2Scope.forEachLeaf`) decide through the same `TextKit2Scope` functions and the same eligibility verdict, so the leaf counts are the leaves the views may hand to TK2.

#### Owners

- **Leader:** `PreparedListRow.id` (the item's node path), passed through `TextEngineLeaf` to the TK2 row, `tk2-row:<row id>`. A task's interaction id still comes from `ListMarker.task(id:)`.
- **Continuation rows** (`<itemID>#cont<N>`, `ListPreparer.swift:110-118`) have empty segments, so no leader view. Their paragraphs are trailing `.richText` blocks owned by their own `RenderBlock.id`, never by the `#cont` id. `SearchIndexer` agrees: it keys the leader on `row.id` and walks each trailing block on its own.
- **Chrome:** bullets, numbers, checkboxes and the decision glyph are outside every owner's text and offsets (§5.1).

#### The shared text leaf and the leader style

`TextEngineLeaf` (`Sources/ADFRendering/TextKit2/TextEngineLeaf.swift`) is the one engine branch. Under `.textKit2`, text eligible where it sits (`TextKit2Eligibility.verdict(_:owner:)`) goes to `TextKit2Leaf`, which still makes the one engine decision (search highlights, unreadable inherited styling, the rebuild control); everything else draws the caller's SwiftUI fallback, and without UIKit the fallback always runs. `RichTextBlockView` keeps its indentation, alignment and heading wrappers around the leaf. `ListRowView` gives it the leader with the existing fallback, `SegmentedTextView(segments:ownerID:).textSelection(.enabled)`, and keeps its `HStack` / `VStack`, `@ScaledMetric` marker column, spacing, depth padding and decision background unchanged. It marks its text column `adfTextOwnerKind = .list`, which the iOS 26 gate and the live list counter read. The twenty-flip rebuild control (§8.3) goes through the same leaf, so it swaps exactly the list leaves TK2 swaps.

The leader is body text: `TextBlockStyle(font: theme.body, isHeading: false, headingLevel: nil, alignment: nil, indentation: 0, breakout: nil)` (`ListRowView.leaderStyle(theme:)`). The preparer composes a leader like a root paragraph and drops its block marks; the TK2 row reads only `alignment` and `isHeading` (fonts come from the runs' `ADFFontSpec`s), so nothing else needs to match. No inherited `Text` styling reaches a leader: its only modifier is `.textSelection(.enabled)`, task and decision colours apply to the marker glyphs only, and a done task is neither struck through nor dimmed. PR 2 is therefore not a caller of the §6.5 inherited-style contract.

#### When list text stays on SwiftUI: list rules and the iOS 26 gate

Each rule keeps text on SwiftUI rather than tolerating a difference. Each was found by measuring through the real `ListBlockView` / `ADFDocumentView` at actual column widths (`TextKit2ListParityTests`), and d109f70 narrowed rules A and B to the shapes measured to diverge in hosted-row probes at 3x and 2x, plus headings beside other text, which were measured at 3x only.

| Rule | Keeps on SwiftUI | Code | Measured cause |
|---|---|---|---|
| A | every text leaf of a row, and everything in its trailing blocks, unless its text column holds one text block (the leader alone, or a lone paragraph or heading) or only paragraphs, leader included, whose every run is in the body text style (plain, links, emoji, bold, italic, inline code). So a heading, or a superscript, subscript or small-text run, beside other text keeps the row on SwiftUI, and so does any block that is not a paragraph or heading (a trailing list, a container, code, a table, media) | `TextKit2Scope.rowKeepsRenderer` (`isBodyText`: every run's `ADFFontSpec.textStyle` is `.body`) | The row's `HStack` lays its text column out a second time at the row's height, and the column's `VStack` shares that height among its blocks. A column of one block has the height to itself and matched in every shape measured. Columns of body paragraphs matched in height and first and last baselines: every multi-paragraph row of list-dense and lists-parity (326 rows) at Large, xxxLarge, AX3 and AX5 on 375 and 320 pt documents, and synthetic shapes at xSmall to AX5 and Bold Text on four widths, at 3x and 2x. A column with a sub/superscript or small-text run beside another block kept its height but moved its last baseline 22–62 pt (list-dense `0.410.2` at AX5, 375 pt: 308.67 against 370.67; 6 of 112 comparisons at 3x, 9 of 112 at 2x). Columns with a heading beside other text were measured at 3x only (0 of 15 diverged), so they stay excluded. |
| B | every row of a top-level list in which one row holds both a panel and an expand | `TextKit2Scope.listKeepsRenderer`, through `inheritsRenderer` | A list with one row holding one non-text kind matched at six sizes × four widths, 3x and 2x (code, panel, quote, expand, table, rule, a sync block, an item that starts with a code block; also lists-parity's lists `0.8` and `0.12`); that row's own text stays on SwiftUI by rule A. lists-parity's list `0.10` diverged in 1 of 24 cases (AX5, 402 pt document, 3x): the same height, but pixels differ from 1,000 pt down. Leave-one-out on its item `0.10.2` (code, panel, quote, expand, table, rule) isolates the pair: without the panel, or without the expand, the list matched; without the code block, quote, table or rule it did not. |
| C | list text laid out right to left | `TextKit2Scope.listDirectionKeepsRenderer` | Right to left, `Text` reports a column-filling line a pixel wider than proposed (292 in a 291.67 pt column at AX1) and measures it a point short of TextKit and of itself left to right. Rows drew 2 px apart, and `Text` truncated a line it had measured as fitting. |
| D | list text whose column is narrower than 1 pt | `TextKit2Scope.listTextFits` (`minimumListTextWidth`), from the list width `DocumentRow` passes (`adfListWidth`) | Deep nesting at accessibility sizes proposes a zero width. `Text` then sets one character per line, overflowing its frame, while the TK2 row answers zero with no layout. On iOS 26.3 the arms agree at every positive width down to one pixel. |

**iOS 26 gate (apart from A–D):** before iOS 26 all list text stays on SwiftUI. `TextKit2Eligibility.listsMatchText` is false there, so `TextKit2Eligibility.verdict(_:owner:)` returns `.fallback(.osGatedList)` for list text that would otherwise be eligible. The views (`TextEngineLeaf`, by `adfTextOwnerKind`) and the coverage walk both decide through it. Root paragraphs and headings keep PR 1's behaviour and pins. Precedent: PR 1's `trailingBreaksMatchText`. Cause: on iOS 18.5 (3x) the list suites had 131 real failures, mostly rows a pixel taller on TK2, which add up over lists and documents (`<data>/phase5/ios18-list-divergence.md`, §6.7).

Content fallbacks apply to list text as they do to roots (§3, PR 1): atoms, empty text (since PR 2 also text of hard breaks only, which draws nothing and whose baselines `Text` puts where no line metric does), undescribable fonts, two or more trailing breaks before iOS 26, unreadable inherited styling, and an active search highlight for that owner.

How the rules show in coverage: a row kept by rule A or a list kept by rule B is not walked, so its text is not counted as leaves at all. Rules C and D are decided when the view is built, and coverage assumes left to right and a column of at least 1 pt. The iOS 26 gate counts each gated leaf as a fallback.

#### Layout passes per list leaf

A list leaf lays out **twice** on first materialisation; a root paragraph lays out once. The row's `HStack` sizes its flexible text column with a natural-width probe first (an unspecified proposal, laid out in an unbounded container and cached under `.infinity`, one of the row's four cache slots, §6.2), then proposes the column width (322 pt, or 286 pt one level down, in a 390 pt window). `TextKit2ListLayoutTests` pins this through the document view, per proposal (zero, narrow, phone, infinite, unspecified) and per materialised row. Measured at 1e778df over list-dense's then 3,686 eligible list leaves (iPhone 17 Pro simulator, iOS 26.3): probe ≈ 153 ms and column width ≈ 163 ms in total, so a list leaf's first layout costs about 1.9 times a root paragraph's (~42 µs more per leaf). This is not optimised in PR 2. The `pr2` gate failed arm C on list-dense, and reusing the probe's layout would save only about 5–10 % of the hitch-frame work (§6.6, §8.3). The baselines are unaffected, because the guides read the placed, bounded layout (§6.2).

#### Accessibility

- A TK2 list leaf is one element, like a root row (§7): label = its plain text, traits `staticText` (+ `header` for a heading in the text column), value `nil`, and one "Open link <host>" custom action per link.
- Markers are SwiftUI chrome under either engine and keep main's exposure (`ListBlockView.swift:108-131`, `TaskMarkerView`). Bullet glyphs and continuation spacers are `accessibilityHidden(true)`. The ordered marker (`Text(text).monospacedDigit()`) is **not** hidden, so VoiceOver reads the number as its own element. The task checkbox reads "Task" or "Completed task", with the hint "Toggles the task" when the host handles toggles (no hint when read-only). The decision glyph reads "Decision".
- Measured with VoiceOver on iOS 27.0 (`XCUIDevice.voiceOverService`, `ListRendererUITests.testVoiceOverTraversalOfTasksAndDecisions`): no marker glyph is spoken; the accepted differences are in §6.7, the missing heading level (a PR 1 residual) in §7. XCUITest lists the bullet glyphs even though they are hidden (both engines, main too), so the automated tree comparison only requires them to match between arms.

#### Selection and copy

TK2 list text has none until PR 8, as root rows in PR 1 (Fable F17): under TK2 the leader loses `.textSelection(.enabled)`. The SwiftUI arm, and every list leaf that falls back, keeps per-row selection on the leader and per-block selection on trailing paragraphs.

#### Diagnostics and coverage

| Field | Counts |
|---|---|
| `ADFTextKit2Coverage.eligibleTextLeaves` | text leaves TK2 draws: the eligible roots plus the eligible list leaders and list text-column paragraphs and headings |
| `.linkedTextLeaves` | of those, the ones with a link (TextKit 1-backed rows) |
| `.fallbackTextLeaves` | text leaves in scope that stay on SwiftUI (content fallbacks, `.osGatedList`) |
| `.listLeaderLeaves` | list leaders in scope, eligible or not (a row with empty segments has none) |
| `.listTrailingLeaves` | paragraphs and headings in a list row's text column in scope, eligible or not |
| `ADFTextKit2Stats.liveListRowCount` | live TK2 rows drawing list text: the list-native proof (`tk2ListLive=`, About's `tk2-list-live-rows`) |
| `ADFTextKit2Stats.conversionCount` | prepared-text conversions into a row's `NSAttributedString` since launch: one per new text or layout input, none for an appearance flip (`tk2Conversions=`) |

- One walk (`TextKit2Scope.forEachLeaf`) counts the leaves, in prepared order. Invariant: `eligibleTextLeaves + fallbackTextLeaves == eligibleRoots + textFallbackRoots + listLeaderLeaves + listTrailingLeaves`.
- The root fields keep their PR 1 meaning, labelled "root richText, legacy". `fallbackRoots` still counts every top-level block that is not an eligible paragraph or heading, top-level lists included, so it is not a count of blocks drawn wholly by SwiftUI; use the leaf counts for that.
- The coverage pins are counted by hand from the fixtures, never derived from the walker under test (`TextKit2ListCoverageTests`). The rows `ADFDocumentView` draws for lists-parity are exactly the eligible leaves the walk counts (`TextKit2ListDiagnosticsTests`).

| Fixture | Eligible leaves / TextKit 1-backed / fallback | List leaders / list paragraphs and headings | Eligible list leaves | Kept on SwiftUI by rules A and B (not counted) |
|---|---|---|---|---|
| lists-parity | 48 / 3 / 6 | 46 / 0 | 40 | list `0.10` (rule B: item `0.10.2` holds a panel and an expand); the code-first item `0.8.12` and both rows of `0.12`, which hold a sync block's list and a stray item's list (rule A) |
| list-dense | 3,537 / 586 / 395 | 3,382 / 550 | 3,537 | 14 items whose leader or extra paragraph has a sub/superscript or small-text run, and 63 continuation rows with a paragraph and a heading (rule A) |
| kitchen-sink | 18 / 1 / 2 | 8 / 0 | 8 | none (four lists of plain leaders, one nested) |
| stress-5k | — | — | 7,543 (none linked) | — |

Counts from `ADFTextRenderer.textKit2Coverage(of:)` over each fixture prepared with the default theme, on iOS 26, pinned at d109f70 (`TextKit2ListCoverageTests` in `TextKit2ListDiagnosticsTests.swift`; stress-5k's eligible list leaves only, in `TextKit2FixtureSweepTests.expectedEligibleListLeaves`). Root counts are §3's PR 1 table, unchanged: lists-parity has 8 eligible roots and list-dense none (600 root lists and nothing else), so their eligible list leaves are 40 and 3,537. The fallback leaves are atom-bearing text: lists-parity's 6 and list-dense's 395 are list leaves, kitchen-sink's 2 its atom-bearing roots. Before iOS 26 exactly the eligible list leaves fall back as `.osGatedList` and no root does (pinned for lists-parity, kitchen-sink and list-dense). The narrowing raised the eligible list leaves from 33 to 40 (lists-parity) and from 2,984 to 3,537 (list-dense: leaders 3,071 → 3,382, list paragraphs and headings 239 → 550); kitchen-sink and stress-5k are unchanged.

#### The scope pattern later containers follow (PR 4, PR 5)

PR 2 fixes how the renderer choice enters a subtree, so containers reuse it rather than add a second mechanism:

1. The top-level kind joins `TextKit2Scope.inheritsRenderer`, with any whole-block rule it needs (as `listKeepsRenderer` for lists). `DocumentRow` stays the only root setter.
2. The container's view sets the key at its own child boundary: the choice for the text it migrates, `.swiftUI` for every other child and so its subtree, as `ListRowView` does. An environment value reaches every descendant, so a container that joins step 1 without this reset leaks TK2 into children not yet migrated.
3. `TextKit2Scope.forEachLeaf` follows the same rule, so coverage counts exactly what the views may draw.
4. `TextKit2RendererSetterTests` is updated, deliberately, to the new setter count and files.

---

## 4. Parity inventory

One row per `RenderBlock.Kind` (`Sources/ADFPreparation/RenderBlock.swift`) and per `InlineAtom` (`Sources/ADFPreparation/InlineComposer.swift`). "Never" means the kind has no prepared rich text of its own (chrome, images, plugin views); any rich text it contains moves with the PR named.

**Selection/copy column:** "SwiftUI per-block" = the leaf has `.textSelection(.enabled)` today; every TK2 row has no selection until PR 8, after which all text participates in the §5 document-level selection.

### Block kinds

| Kind | Moves to TK2 | Behaviour (as of PR 2) | Owner-id handling | Selection / copy (before PR 8) | Links | Accessibility | Perf fixture |
|---|---|---|---|---|---|---|---|
| `richText` — top-level, atom-free paragraph / heading H1–H6 | **PR 1** | TK2 when ON and eligible (§3); otherwise SwiftUI. Link-bearing rows are still TK2 rows (`TextKit2RowView`, `tk2-row:<id>`) but TextKit 1-backed inside: the row's own TextKit 1 stack lays out, sizes, baselines, draws and hit-tests their text, as `Text` does (§6.4); reported apart (§1) | `RenderBlock.id` passed through the leaf and stored on the TK2 row; `tk2-row:<id>`; search spans key on it | TK2: none. SwiftUI arm: per-block | TK2: tap inside the link run's glyph rects (from the TextKit 1 stack) → SwiftUI `openURL`; whitespace taps rejected; links in the accent colour (a host `.tint` is not readable, §6.5) | One element: label = plain text, `staticText` (+ `header`), no heading level under TK2 (PR 1 residual, §7); "Open link <host>" custom action per link | stress-5k (2,400 eligible, 507 TextKit 1-backed), kitchen-sink, text-dense, giant-table heading |
| `richText` — top-level, atom-bearing | PR 6 | SwiftUI, whole paragraph (`WrappingInlineLayout` over word chunks) | Block id; each atom keeps its node id (`InlineSegment.atom(_, id:)`) | SwiftUI per-block | SwiftUI `Text` links; inlineCard chips are `Link`s | SwiftUI default; atoms per the atom table | kitchen-sink (2 roots), stress-5k |
| `richText` — nested (inside a container, table cell, expand body, or a list row's trailing blocks) | List text column: **PR 2**; containers PR 4; table cells PR 5 | The paragraphs and headings in a top-level list row's text column: TK2 when ON and eligible under the list rules (§3, PR 2). Everything else: SwiftUI (environment reset to `.swiftUI` by `DocumentRow` or at the list child boundary) | Its own block id (`tk2-row:<id>` under TK2), also for a continuation row's paragraphs | TK2: none until PR 8. SwiftUI arm: per-block | TK2 in a list: as top-level rows (TextKit 1-backed, §7). Elsewhere SwiftUI `Text` links | TK2 in a list: one element, as top-level rows. Elsewhere SwiftUI default | stress-5k, lists-parity, list-dense |
| `codeBlock` | PR 3 | SwiftUI `Text` in a horizontal `ScrollView` | Block id (search spans, arrival flash) | SwiftUI per-block + Copy button (both kept) | n/a | Copy button labelled "Copy code" | stress-5k (400 code roots) |
| `listRows` — bullet, ordered, task, decision, continuation; nested lists as depth rows | **PR 2** | Top-level lists: each leader draws through `TextEngineLeaf` (TK2 when ON and eligible under the list rules and the iOS 26 gate, §3 PR 2; otherwise its `SegmentedTextView` fallback). Marker column, spacing, depth padding and decision background stay SwiftUI under either engine. Lists inside containers and table cells: SwiftUI, with their container | Block id for the row group; each `PreparedListRow.id` owns its leading segments (`tk2-row:<row id>`); continuation rows `<itemID>#cont<N>` have no leader, and their paragraphs own their text by block id; task markers carry `ListMarker.task(id:)` for `taskStates` / `interactionHandler`; `trailingBlocks` keep their own ids | TK2: none until PR 8. SwiftUI arm: per-row (leader `.textSelection(.enabled)`); trailing blocks per-block | TK2: as top-level rows (TextKit 1-backed tap → `openURL`, §7). SwiftUI arm: `Text` links in leading text | Bullet glyphs and continuation spacers hidden; ordered numbers **not** hidden (read as their own element); task toggle "Task"/"Completed task" + hint (with a host handler); decision labelled "Decision"; a TK2 leaf is one element (§7) | list-dense (`pr2` perf design), lists-parity, lists-links, list-tall (one 316-row root), stress-5k (900 list roots, task + decision items), kitchen-sink |
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

Design only — PR 1 and PR 2 contain no selection code. PR 1 preserves what this contract needs (the owner id through the TK2 leaf) and states the limitation (TK2 rows have no selection or copy; SwiftUI rows keep per-block selection). Every adapter added in PR 2–6 must fit this contract.

### 5.1 Addressing

A selection endpoint is a **document address**: `(document generation, owner id, local text position)`.

- **Document generation** distinguishes documents: structural ids (`"0.2.1"`) recur across documents, so an address from one document must never resolve in another.
- **Owner id** is the stable id of the text-bearing unit: the block id for paragraphs, headings and code; `PreparedListRow.id` for list leading text (a continuation row `<itemID>#cont<N>` owns no text: its paragraphs keep their block ids); `PreparedMedia.id` for captions; cell block ids inside tables.
- **Local text position** is an offset into that owner's merged text.
- **Document order** of owners is the order of the prepared block list, depth-first through containers — the order in which the preparer emits them.
- **Separators** between owners are a paragraph separator (`"\n"`); copy emits it between consecutive owners.
- **Atoms** occupy exactly one position each (attachment character), reserved for PR 6.

### 5.2 Offset mapping

Prepared ranges are `Character`-based (`SearchIndex` spans), TextKit works in UTF-16. The contract: each TK2 row builds a per-run UTF-16 prefix table **once per materialisation**, from the same merged `AttributedString` its `NSAttributedString` is built from, and the same table serves search highlighting (PR 7) and selection (PR 8); neither builds its own.

**No table exists yet** (as of PR 2). Its first consumer, PR 7, builds it; PR 2 allocates none. The text builder stays single-pass (`TextKit2TextBuilder.attributedString(for:linkColor:)` walks the merged text's runs once, appending each), so the table can be derived in that same pass.

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

**Result (closed 2026-10-30): contract kept as written.** The captain checked by hand that cross-row selection and Copy worked on the throwaway spike. That proves feasibility, not production acceptance: a drag across a lazy-row collapse, held-edge autoscroll, the exact copied bytes, revision clamping, switch lifetime, performance and VoiceOver remain unproven, and they are PR 8's obligations. No spike code ships.

The spike report's seven obligations for list adapters ("Contract verdict and obligations for lists", items 1–7 of `cadf3-sel-spike/report.md` in the task data store) are the source of PR 2's identity, geometry and marker-chrome rules. PR 2 meets those it can before selection exists:

1. Leader owner = `PreparedListRow.id`; task and decision text keeps its prepared ids; nothing is keyed by the mounted view or a row index.
2. Continuation paragraphs own their text by their own block ids, in depth-first prepared order (§3, PR 2 "Owners").
3. Rows keep no selection state or offsets (unchanged from PR 1).
4. No map is allocated, and the text builder stays single-pass (§5.2).
5. The TK2 row is the indented text view itself, with markers, gap and depth padding outside it, so row-local rects convert through its frame and no marker width enters a text offset.
6. Markers align on the row's first text baseline (§6.2); `TextKit2ListParityTests` compares first/last baselines to 0.01 pt and the marker's offset from the first text ink.
7. Registration with the document input owner and Copy from prepared text are PR 8.

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
- **Proposals:** `nil` width → natural width (unbounded container; cached under the natural width); zero → `.zero` without layout; infinite → natural width. A list leaf meets both on first materialisation: its row's `HStack` probes the text column at natural width before proposing the column width, so it lays out twice where a root lays out once (§3, PR 2 "Layout passes per list leaf").
- **Re-sync before geometry:** the single `NSTextLayoutManager` may currently be laid out for a different width than a cached answer. On a bounds change and before drawing, the row takes the layout SwiftUI placed it from (`placedResult(for:)`: the cached bounded measurement whose reported *size* equals the bounds — height included, since two proposals that hug to the same width can wrap differently — else one of that width, else a fresh layout at `bounds.width`), sets the container to *that layout's* container width (wider than the bounds for a hugging row) and re-runs `ensureLayout` if it differs. Cached numbers are never used for geometry without that re-sync.
- **No eager layout on new inputs:** `apply` rebuilds the string and clears the cache; the next layout happens when SwiftUI measures the row or before it draws, never at the stale bounds width. Since PR 2 the colour scheme is not one of these inputs: a scheme change sets the row's `overrideUserInterfaceStyle` and repaints its canvas, keeping the string, the TextKit 1 stack, the cache and the laid-out container (§6.6).
- **Baselines:** the representable exposes `.firstTextBaseline` / `.lastTextBaseline` from the placed layout (the same lookup at the guide's size, so reading a guide never lays out again), equal to SwiftUI's for single- and multi-line text. PR 2's list markers align on the first baseline: `TextKit2ListParityTests` compares each row's first and last baselines to 0.01 pt and the marker's offset from the first text ink, through the real list views.
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

- **Height** = ceil_px(last baseline + last-line descent), where a line's ascent/descent are the tallest/deepest run on it by its *font's* metrics — a fallback font's do not count (`Text` sizes "ab 🧪", "ab 漢字" and "ab नम" by the system font alone at 1600/1600 sizes, where Core Text's line bounds are taller) — and a baseline offset only ever grows them (a superscript's raise adds to its ascent, a subscript's drop to its descent). At 96778b3 (`TextKit2HeightParityTests`, the sub/superscript-line family included): 1,530/1,530 heights exact (worst |Δ| 0.0) on each of 3x, 2x and iOS 18.5, plus 510 RTL / Bold Text measurements and 156 corpus checks per device; the fixture sweep below.
- **Superscript lines** (`stress-5k` block 503: 3.33 pt short at large, 24 pt at AX3, every row below shifted on a renderer switch). TextKit 2 lets a raised run's offset eat its descent (a line set wholly in superscript gets none) and fits the line in the font's leading-inclusive line height; `Text` keeps the descent below the baseline and lets the raise eat only the run's leading. Read from `Text.Layout` line origins (offsets −4…12 pt, every pairing of plain/sub/superscript lines): below a line `Text` keeps the largest run descent + leading, a raised run's leading reduced by its raise (never below 0); negative leading (AX5) belongs to the next line's ascent, as in TextKit. The row moves every line below such a line by the difference (drawn line by line when moved). Run backgrounds: the band moves with the run's baseline offset beyond the one the whole line shares — a highlighted superscript among plain text rises with it, a line set wholly in it does not — and spans the Core Text ascent (a subscript lowers it). The suites' sub/sup family: first, middle, last and only lines, with colour, highlight, a hard break after it (the linked variants assert their SwiftUI fallback, `TextKit2FallbackTests`). The same escape explains the lifecycle gate's −26 px (−8.67 pt) shift on a switch made straight after a programmatic jump (`lifecycle/diag3`): an eligible row above Section 500, off screen but already laid out by the lazy stack, measured differently under TK2, and the scroll view keeps its raw offset; a gesture-parked view had other rows laid out above it. Replayed with the gate's own steps: −26 px (−36 px below block 503) at 0d7730e, 0 px at 9bf45ff for the menu switch, a menu open/dismiss, re-choosing the same renderer, About open/close and a UI-less flip. Not renderer-agnostic and not issue #6. Evidence: `<data>/jump-switch-c/`.
- **Fixture sweep** (`TextKit2FixtureSweepTests`): every TextKit 2-eligible root of kitchen-sink, stress-5k and text-dense at 370 pt, large and AX3, both arms, must measure within 0.01 pt — **no exemptions**; content the row cannot match exactly is not eligible. Linked roots are measured too (TextKit 1-backed). History: 46 escapes, worst 96 pt, before the superscript-line and fallback-font rules; at 9bf45ff 10,820 measurements with every residual a link+emoji paragraph 1 px taller (8 at 3x, 17 at 2x, 9 on iOS 18.5) — a default TextKit 1 stack counting the emoji face in line heights, which the row's stack no longer does (below). At 96778b3: 10,820 measurements per device, worst |Δ| 0.0 on 3x, 2x and iOS 18.5, no exemption (2 text roots stay on SwiftUI, both atom-bearing).
- **First baseline** is rounded to the nearest device pixel and the whole text is drawn shifted onto it (later lines keep their fractional offsets). Drawn unshifted, glyphs, underlines and strikes land 1 px low wherever the first baseline's pixel fraction is small (H1 at xxxLarge: 97.12 px). The row reports first/last baselines pixel-rounded too (16.187 → 16.333 at 3x), as `Text` does.
- **Line breaks:** `lineBreakStrategy = .standard`. 2,052 near-full Latin strings at large/xxxLarge × 370/640/353.333 pt matched per-line ink extents with `.standard` and `.pushOut` and missed 66 times with no strategy (one word later); 1,278 Korean, Japanese, Arabic and accented-Latin strings matched only with `.standard` (`.pushOut` alone missed 257 Korean strings — `.standard` adds Hangul word priority). In total 6,349 lines across 8 width/size sets, 0 mismatches.
- **Width hugging and alignment:** the reported width is the widest line, trailing whitespace included (left-to-right lines whose whitespace hangs past the container are measured with Core Text), pixel-ceiled, at most ceil_px(proposal) — `Text` reports 300.667 for a 300.5 proposal its whitespace overflows. Drawing reuses the measured layout shifted by the alignment within the hugging bounds; the canvas is clipped to the bounds horizontally because `Text` clips side overhang (an indented line-initial "j" loses its tail at 72 px). Centred/end text: bitmap sum of differences 0 at 30 of 32 width/size/direction checks (the other 2 are residual 2).
- **Trailing hard break:** the empty line's baseline = previous baseline + previous descent + its own ascent + the previous line's positive leading (its largest run's: a subscript's, not the break's, on a subscript line) + the break font's negative leading; a line's closing break never counts toward its metrics (TextKit and `Text` both skip it); before iOS 26 positive leading is dropped (negative leading applies on both). TextKit's own extra line fragment differs (it ignores negative leading after a first line, and after two breaks uses the 13.8 pt default font). 35/35 heights exact on 26.3. On iOS 18.5, with two or more trailing breaks at AX3+, `Text` also drops the middle empty line's negative leading (0.333–1.333 pt shorter, no exact rule found; `parity/ios18-trailing-break/probe49-ios18.log`), so before iOS 26 such text stays on SwiftUI (eligibility, regression-tested both ways).
- **Text containing a link is laid out, sized and drawn by TextKit 1 inside the TK2 row** (captain decision for PR 1; reported apart, §1). Measured: SwiftUI renders interactive (linked) `Text` with TextKit 1 string drawing — swizzling `NSLayoutManager` under the SwiftUI arm showed an `NSLayoutManager` (`usesFontLeading = false`, `lineFragmentPadding = 0`) in a container as wide as the `Text`'s frame, first baseline on a device pixel, `NSUnderline` on link/underline/annotation runs, `NSBackgroundColor` fills. TextKit 1 differs from TextKit 2 in wrapping (it wraps an emoji TextKit 2 lets end a line: `text-dense` block 283, one line, 22 pt, short; 36 such blocks), in line spacing (a superscript line gets its full leading) and in decorations (underlines placed per line from the line fragment, skipping descenders; backgrounds filling whole line fragments and running line-ending whitespace to the frame's edge — 8 px off a fitted model at AX3). The row therefore lays such text out and draws it with its own TextKit 1 stack configured like SwiftUI's, at the same pixel phase (fills clipped to the frame, as SwiftUI's are); lines, baselines, size (used rect clamped to the container: centred 350.667 where the line-width rule gives 353.333) and link hit-test rects come from that stack; TextKit 2 only bounds the ink. A replica matched SwiftUI's bitmaps with 0 differing pixels.
  - **Fallback fonts never grow a line** — in the TextKit 1 stack too. A default stack counts the emoji face (Apple Color Emoji, substituted into the storage) in line heights; `Text` does not (+0.0135 pt per emoji line at AX3: 1 px after the frame's ceil; 4 px for `link-emoji-wrap` at AX5). The stack's `NSLayoutManagerDelegate` takes out of each line what its substituted fonts add over the fonts the text was built with, the difference removed from the fragment, its used rect and (ascent) its baseline; lines without a substituted font are untouched. A plain line compares max-of-runs ascent/descent over both font sets, with TextKit 1's leading rules (negative leading not on a paragraph's first line, positive leading not below its last). A line with a baseline offset (sub/superscript) is order-dependent in TextKit 1 (a line opening with a subscript sits lower than one ending with it), so the delegate sets the line again with each substituted run replaced by plain characters in the built font, and removes the difference in baseline and height. Exactness on the sweep at 96778b3: every link+emoji root exact (10,820 measurements, worst |Δ| 0.0) on 3x, 2x and iOS 18.5 (fixed cases: `TextKit2FallbackTests`, `TextKit2HeightParityTests` `link-emoji-wrap`, `TextKit2PixelParityTests` linked emoji lines).
  - **Consequence for PR 8 (selection):** a link-bearing row is laid out and drawn by TextKit 1, so its selection rects must come from the row's TextKit 1 stack (as its link hit-test rects do), not from TextKit 2 — the lines can break differently. The row draws the highlight itself, beneath the TextKit 1 glyph pass. Any selection test must include a link-bearing row, centred, wrapped and with an emoji.
  - Evidence: `<data>/parity/link-textkit1/`, `<data>/parity/link-emoji-textkit1/`, `<data>/parity/fallback-font-metrics/`.

**Rules added in PR 2** (found on list text, shared by every TK2 row, root rows included):

- **A column-filling line's width** is capped and reported as `Text` ceils a length, width ÷ (1/scale) rounded up (`proposalCeil`), not width × scale. List columns are sums of pixel lengths a few ulps off a pixel boundary: 291.66666666666669 pt at 3x is 876 px that way, 875 px the other, and a pixel-narrower row made its list re-propose every row (lists-parity's list `0.8` drew 0.5 pt off at AX1, 375 pt document). Both the TextKit 2 and the TextKit 1 paths use it. The two roundings differ only for such off-grid widths; no PR 1 pin changed (91269a4).
- **Linked text's glyph overhang is not clipped.** `Text` draws linked text with TextKit 1 and leaves overhang at the frame's sides (a line-initial "j" keeps the pixel left of its frame); plain `Text` still clips it. A TextKit 1-backed row's canvas now extends past each side by half the tallest line's ascent, and to the ink (TextKit 1 can wrap differently from the TextKit 2 layout the ink comes from); the horizontal clip above still holds for plain rows. This is the shared row, so linked root rows get it too (f9a136d).
- **A run background covers a hyphenated line's hyphen.** TextKit hyphenates where `Text` does and inserts the hyphen after the line's last character; `Text` paints a highlight or code band over it, to the line's end, and so does the row now (lists-parity "high-lighted" at AX5, 201 pt column). The band is the shared drawing (`TextKit2RowView.RunBackgrounds`), so root paragraphs get it too (e85258a).
- **Text of hard breaks only** is an `.empty` fallback like empty text, for root and list text: it draws nothing, and `Text` puts its baselines where no line metric does (one break at Large: both at 22 pt, where a body line's baseline sits at 16.33 pt), which a list marker aligns to (1ec8120).

**Residuals** — disclosed differences, **not** exact parity: each is recorded with `withKnownIssue` or a measured tolerance, so a fix shows up as a test failure. None changes a row's height. Counts from the final unit runs at 96778b3, known-issue records on 3x / 2x / iOS 18.5: residual 1 12 / 4 / 12, residual 2 2 / 2 / 2, residual 3 0 / 0 / 0, residual 5 6 / 5 / 4 (residual 4 is a measured tolerance):

1. **Last-baseline guide +1 px.** SwiftUI's `lastTextBaseline` guide sits exactly 1 px below its drawn baseline in 6/56 cases at 3x and on iOS 18.5 (H1 at AX3, sub/superscript lines; 12 known-issue records each) and 2/56 at 2x; never −1 px. No formula found (best candidate 113/132). The row reports the drawn baseline, so a container aligning on the last baseline can sit 1 px off. Evidence: `parity/last-baseline/` (probe36.txt).
2. **Centred text at a fractional width.** At large, w = 300.5, both directions, 3x and 2x, SwiftUI's glyphs sit 0.5 px left of ours: its drawing layer is 849 px around an 844 px frame, and the bitmaps are identical only after a −0.5 px shift. The rule behind that layer outset is unknown (2 known-issue records). Evidence: `parity/align-center-offset/` (probe40/41/44).
3. **SF Mono rasterization.** No pixel differs by more than 24/255, but a faint edge row can flip the ink threshold: 3 line bands at 3x and 1 at 2x when it was measured; 0 in the e6934f0 and 96778b3 runs. Recorded only when the band has no visibly differing pixel. Evidence: `parity/mono-raster/`.
4. **Underline and strike ends:** SwiftUI's end 0–2 px shorter (antialiasing level; the pixel suites still show 0 differing pixels). Evidence: `parity/link-decorations/`.
5. **Centred text with a run background** (highlight or code band). `Text` draws a band over part of a line with hard side edges floored onto its frame's pixel grid, and a band over a whole line with that line's own fractional, antialiased edges; the row does the same, which is exact on left-aligned text at 3x and 2x. Centred text is not consistent with that rule in `Text`: at AX3 a last-line whole band is ~0.22 pt narrower at each side, and at xxxLarge (3x) lines 0–1 have their glyphs about 1 px off the row's (lines 2–4 match), like residual 2 but at a whole-number width (370 pt). Differing pixels in `centred-highlight`: 3x large dark 0.34 %, xxxLarge 4.54 % / 5.08 % (light/dark), AX3 light per-row counts only; 2x large light per-row counts only, large dark 0.94 %, xxxLarge 0.05 % / 0.45 %; iOS 18.5 (3x) xxxLarge only, 4.54 % / 4.64 %. First and last ink rows are exact everywhere (no height effect), and a centred highlight after a link (TextKit 1-backed) is 0 px. Recorded with `withKnownIssue` in exactly these cases (`centredHighlightDiffers`); every other case stays hard. Finding the rule needs `Text`'s own line and run origins (a `TextRenderer` capture through `SegmentedTextView` returned no lines): follow-up with PR 6 (§2). Evidence: `parity/centred-highlight-bands/`.

Formerly residuals (fixed regression cases in `TextKit2FallbackTests`, which also check that a heading below them moves ≤ 2 px on a switch either way): two or more trailing hard breaks on iOS 18.5 — now a SwiftUI fallback before iOS 26; text with a link and an emoji — now exact through the TextKit 1 stack's fallback-font rule (above), no exemption; a highlighted sub/superscript run (formerly residual 5, ≤ 0.04 % of pixels): `Text` paints each line's run backgrounds over the glyphs of the line above (a raised band covers a descender above it), and so does the row now — 0 differing pixels and exact rows at 3x and 2x (`TextKit2PixelParityTests` sub/superscript lines; `parity/subsup-highlight-bands/`).

### 6.5 Inherited styling and themes

- `ADFTheme` gains spec-first construction; the SwiftUI `Font` is derived from the `ADFFontSpec`. A raw-`Font` initialiser stays source-compatible but marks the spec `nil` (undescribable); such runs force the SwiftUI path. No caller has to update two fields.
- `TextKit2RenderInputs` carries the text and the resolved inherited layout inputs — alignment, heading, size category, layout direction, display scale, legibility weight — and is the cache key and the rebuild decision. Since PR 2 the colour scheme is not among them: it is the row's paint input, applied apart (`TextKit2RowView.apply(_:colorScheme:ownerID:)`, §6.6).
- **No inherited colour channel in PR 1:** SwiftUI exposes no public getter for an inherited `foregroundStyle`, `tint` or font weight (the `EnvironmentValues` accessors are `package`), so a `UIViewRepresentable` cannot see what `Text` would inherit. Nothing in PR 1's scope (top-level paragraphs and headings in ADFReader) colours text that way, so PR 1 adds no channel; the first PR with an in-repo caller of inherited styling — containers (**PR 4**: media captions' `.footnote` / `.secondary`), then tables (PR 5: header weight, contrast foregrounds) — adds a library-owned environment value set next to the SwiftUI modifier it mirrors.
- **Tint:** `Text` colours links with the tint, which a foreground style does not override; the row colours them with the accent colour (`Color.accentColor`, resolved at draw time). A host `.tint` around the document is **not readable** from UIKit (the accessor is `package`), so it recolours SwiftUI links only (§6.6).
- **Styling the row does not reproduce falls back:** readable `Text` environment — line spacing, text case, line limit, minimum scale factor, redaction — keeps the paragraph on SwiftUI (`TextKit2Leaf`, only built when the switch is ON). A `foregroundStyle` or font weight applied around the document is not readable and is not detected.
- Foreground precedence: a prepared foreground (author `textColor`, or the contrast colour derived from a background mark) first; then, for a link, the accent colour; else `.label`.

### 6.6 Known costs and limitations (PR 1, PR 2)

- **Colour-scheme flip (fixed in PR 2, 7bafca1).** In PR 1 the scheme was a render input, so a light/dark flip rebuilt a byte-identical string and re-laid out every live TK2 row in one frame (`layoutCount` +1 per row per flip). The colours were never baked in: every colour in the string is a dynamic `UIColor` (`UIColor(foreground)`, the accent colour, `.label`), resolved when the canvas draws. Now the scheme is a paint input: a change sets the row's `overrideUserInterfaceStyle` and calls `canvas.setNeedsDisplay()`, never `rebuildText()`, and the text builder and colour conversion are unchanged. `TextKit2AppearanceFlipTests` flips one hosted row light → dark → light and compares it with fresh light and dark rows, pixel-exact, for plain `.label` text, an author-hex run, run backgrounds and an accent link (TextKit 1-backed); `layoutCount`, the row's relayouts, cached widths, the text instance, frame and baselines stay unchanged, and a flip together with a width or content change still lays out and rebuilds. The native TextKit 2 path needed no fragment-display invalidation.
- **Eager list roots multiply canvases (PR 2).** A top-level list is one eager `VStack` of all its rows inside one lazy row (ADR §4: nested content renders eagerly inside its block), so every eligible leaf of a materialised list root is a live TK2 row with its own canvas. list-tall (a 316-row root list and a one-row list) reported `tk2ListLive=317` at READY under `-textkit2` at 23f43cf. Virtualisation inside a list is unchanged (out of scope). The canvases' memory is the unmeasured device cost below; the simulator does not attribute it to the app. <!-- TODO(team-lead): perf -->
- **List leaves cost frames on scroll with TextKit 2 ON (PR 2, accepted).** Each eligible list leaf is its own UIKit-hosted TK2 row and lays out twice (§3, "Layout passes per list leaf"): about 0.46 ms of main thread per leaf against 0.28 ms for `Text`. The cost lands in the frame where a list block materialises (5.9 TK2 leaves per block on list-dense); it is not a feedback loop or a per-frame relayout. With the switch ON, list-dense drops about 1.4–1.6 times the reference's frames, and PR 2's `pr2` gate fails arm C on list-dense and kitchen-sink; with the switch OFF every metric passes (§8.3 has the figures). Not fixed in PR 2: reusing the natural-width probe's layout would save about 5–10 % of the hitch-frame work and skipping the `AttributedString` compare about 2 %. The fix that would close the gap, one TK2 view per list row or block, is architectural (ids, accessibility, PR 8 selection) and is a proposed follow-up. TK2 stays OFF by default. Evidence: `<data>/perf/pr2-list-dense-c-diag/findings.md`.
- **TextKit 1-backed rows hold two stacks:** the TextKit 1 stack that lays out and draws the text, and the TextKit 2 layout that bounds its ink (stress-5k: 507 of 2,400 eligible rows).
- **Canvas backing stores:** each TK2 row draws into a non-opaque canvas sized to its bounds plus ink overhang (≈ 0.9 MB for a 353 × 70 pt row at 3x). This is Core Animation memory, which a live-malloc check does not see. Resting `phys_footprint`, C vs B on text-dense at fraction 0.5 (iPhone 17 Pro simulator, Release, 8 alternating launches, renderer confirmed by `RENDERER_STATS`, 7 live TK2 rows): medians 102,139 vs 99,923 KB, **+2,216 KB** (launch-to-launch spread ≈ 5 MB per arm), all of it malloc (TextKit objects); the CoreAnimation category is constant per arm (−320 KB in C) and IOSurface is 0 in both, so the simulator does not attribute the canvases' backing stores to the app at all. **The backing-store cost is therefore unmeasured: it needs a device run**, against SwiftUI's own text drawing layers as the B baseline (`<data>/memory-s11/`). The canvas cannot be opaque: it overhangs the row onto its neighbours and sits on container backgrounds.
- **Host `.tint` and inherited weight:** a host `.tint` recolours links in the SwiftUI arm only; TextKit 1-backed TK2 link rows keep the accent colour, and an inherited font weight is likewise not seen by TK2 rows (both accessors are `package`). PR 1 adds no API for them: the rest of the inherited-style contract (tint, weight) joins the explicit channel (§6.5) **no later than PR 4**.
- **Link + emoji + baseline offset at AX3+:** in a TextKit 1-backed row, a later line (not a paragraph's first) that has both a sub/superscript and an emoji may miss the negative-leading term at AX3 and above, because TextKit 1 sets the line it re-measures after a line separator as a first line (which drops negative leading). The row's height could then differ from `Text`'s by up to that line's negative leading; this is not measured, since no root in the three sweep fixtures has such a line. Plain lines use the fitted rule, which handles leading.
- **iOS 17:** the package minimum, but no iOS 17 runtime is installed on the build host. Parity is measured on iOS 26.3 (3x and 2x) and iOS 18.5 only; on iOS 17 TK2 is unverified (the pre-26 eligibility rules apply; list text stays on SwiftUI before iOS 26, §3 PR 2).

### 6.7 Known differences and residuals (PR 2)

Disclosed, not parity. Evidence paths are under PR 2's task data directory.

- **Unshown cached rows after OFF.** TK2 live counts can include rows SwiftUI's `LazyVStack` has cached off screen: prefetched items, the document's last row built ahead of time, and the render-region buffer. A switch updates only the rows the stack reaches, so right after OFF `liveRowCount` can still count TK2 rows that are not shown: at most 2 on kitchen-sink, and tens of list leaves on list-dense, where one cached list holds many leaves (44 seen right after OFF under host load). They are never visible: the stack re-evaluates each cached row before it appears and dismantles its TK2 view first, and it releases them when it re-approaches them. The SwiftUI rebuild control (§8.3) holds the same cached rows: on list-dense both arms kept the same number of list leaves live but not shown, 3 at the start and 8 at every stop of five 600 pt excursions. PR 1 has it too (root row `0.36.0` at 399074c). No product change: rendering SwiftUI until a row appears would change materialisation (ADR §8, §16). The switch test therefore asserts no `tk2-row` on screen right after OFF and records the live counts, then retraces its TK2 scroll path on SwiftUI and requires 0 live TK2 rows and 0 list rows (58e396a); the list storyboard asserts 0 after the same retrace. Evidence: `<data>/p7-diag/findings.md`, `<data>/p6a-stableid/plateau/gate/lifecycle.md`.
- **Accepted VoiceOver differences** (iOS 27.0). On a linked leader SwiftUI announces "Link, use the rotor…" and TK2 "Actions available", because TK2 links are custom actions (§7). SwiftUI speaks two spaces before a link and TK2 one. The VoiceOver test normalises exactly these two and compares everything else. The missing heading level on a TK2 heading is a PR 1 residual, not an accepted difference: the test pins it as a strict expected failure (§7). Evidence: `<data>/p4-uitests/runs/r14-voiceover-ios27.xcresult`, `<data>/p4-uitests/run-notes.md`.
- **SwiftUI misses a Hebrew link on its second line** (baseline quirk, main's code path). On lists-links `0.1.3`, a Hebrew link in a left-to-right paragraph, a tap on the link's glyphs at the start of its second line opens nothing on the SwiftUI arm. The link test calibrates its tap points on the SwiftUI arm and requires TK2 to open where SwiftUI did. Evidence: `<data>/p4-uitests/runs/r15-links-shapes.xcresult`, `<data>/p4-uitests/run-notes.md`.
- **iOS 18.5: list text is gated off.** At 3x, hosted lists missed `Text` (131 failures; 59 hosted-row heights over 15 rows, 58 of them +1 px at AX3, and 14 of the 15 rows hold a token wider than their column; lists and documents +0.33 to +3 pt at AX1–AX3; columns of 16 pt or less up to +1.667 pt; Hebrew filling its column reported a pixel narrower than `Text`). None of it reproduces on iOS 26.3. Evidence: `<data>/phase5/ios18-list-divergence.md`.
- **Linked text with an emoji, inline code and bold is 1 px short at AX3 (PR 1 leaf residual).** The TK2 row is a pixel shorter than `Text` in a 219 pt column (a list text column of a 320 pt document): 575.5 against 576 pt at 2x and 575.67 against 576 pt at 3x. It was found as 919.67 against 920 pt in lists-parity's mixed-column "marked paragraphs" shape in a 320 pt document at 3x. A root paragraph with the same text is short by the same pixel, so it is a leaf residual from PR 1, not a column effect; unlike §6.4's residuals it changes a row's height. Without the emoji, or without the link, the column matches at five sizes and four widths, so the mixed-column shape no longer holds an emoji (4ea2ebe). `TextKit2HeightParityTests.linkedEmojiCodeResidual` pins the residual as a known issue at both scales, with the no-link and no-emoji controls required to match, so a fix shows up as an unexpected pass (19518c7). Evidence: `<data>/phase5/h1-probe-2x.xcresult`; the root and the leaf side by side in `<data>/phase5/h1-probe2-2x.log`; the pin in `<data>/phase5/r1-height-{2x,3x}.xcresult`.
- **Run-background band edge in a whole list at 2x (PR 1 residual).** In lists-parity's list `0.8` at Large in dark appearance at 2x, `Text`'s inline-code band on row `0.8.1` covers part of one more pixel row at its top (10/255 over its 135 px width). This is PR 1's run-background edge residual, which `rowPixels` already records as a known issue. It shows only where the list places the row off the pixel grid: the row alone matches, and so does 3x. `listPixels` records it as a known issue for that label at 2x (`TextKit2ListParityTests.knownRunBackgroundEdge`), so a fix fails the test (4ea2ebe).
- **SwiftUI drops a panel paragraph's lines in a list item (baseline defect, main).** On main, lists-parity item `0.10.2`'s panel paragraph ("LP-EMBED-PANEL panel inside a list item") draws one line, ending "panel inside a li…", and the rest of its text is missing (Large, 402 pt, iOS 26.3). The panel has no line limit, and the quote and expand titles beside it wrap normally. Both arms draw it identically, because a panel in a list row is SwiftUI on either engine (and rule B keeps list `0.10` on SwiftUI). Not addressed by this PR. Evidence: `<data>/phase5/dropped-lines/`.
- **Text of hard breaks only stays on SwiftUI, root text included** (1ec8120, §6.4). It is now `.fallback(.empty)` for root and list text alike; in PR 1 a root paragraph of hard breaks only was a TK2 row.
- **iOS 18.5: root text in narrow columns (PR 1 residual).** Mixed and Hebrew root paragraphs filling a 223.3 / 255.7 / 310.7 pt column: in 12 of 144 checks `Text` reports a width 1 px wider than TK2 (wider than the proposal), and in 2 (Hebrew, AX3, 255.7 pt) TK2 is 1 px taller. Root text keeps PR 1's behaviour there. Evidence: `<data>/phase5/g2-rtl-root-probe-ios18.log`.
- **iOS 27.0 harness limit.** The switch test cannot scroll back to the top on iOS 27.0 (navigation-bar geometry; `RendererSwitchUITests`, "could not scroll back to the top"). Not a renderer result: final videos are recorded on iOS 26.3. Evidence: `<data>/videos/shakedown/switch.log`, `<data>/p4-uitests/run-notes.md`.
- **Baseline stalls.** lists-parity past LP-S5 hits the lazy-stack livelock of issue #8 (at the table inside list `0.10` and the root table `0.16`); main shows it too. Lifecycle tests L1 and L3b at lists-parity's LP-S5 list (`0.10`, fraction 0.452) stall on main's build as well. No list UI test scrolls or parks past LP-S4. Evidence: `<data>/lifecycle/ab-stall/`, `<data>/p4-uitests/run-notes.md`.

---

## 7. Links and accessibility (TK2 rows)

- **Links:** a `UITapGestureRecognizer` (only on rows whose text has a link) with `cancelsTouchesInView = false` that never swallows vertical flings. A tap opens a link only if the touch begins inside that link run's glyph rects (the union of its line-fragment segment rects, taken from the row's TextKit 1 stack — the engine that laid the text out), not "nearest character"; the link is resolved where the touch began, so drift within tap slop still opens it. Delivery goes through the SwiftUI `openURL` action, so hosts keep control. Native TextKit 2 links: PR 6. Linked list text (PR 2) uses the same row and the same handling.
- **Accessibility:** the row is one element — label = plain text, traits `staticText` (+ `header` for headings), value `nil` — plus one "Open link <host>" custom action per link range. A list leaf (PR 2) is the same element, one per leaf; list markers stay SwiftUI chrome (§3, PR 2 "Accessibility").
- **Heading level (PR 1 residual, not fixed):** the SwiftUI `.accessibilityHeading` modifier on `RichTextBlockView` covers the SwiftUI arm only; it does not carry the level to the TK2 row, which is its own UIKit element. VoiceOver on iOS 27.0 says "Heading" with no level for a TK2 heading where the SwiftUI arm says "Heading level 2" (`<data>/p4-uitests/runs/r14-voiceover-ios27.xcresult`, PR 2's data directory); the row sets the `header` trait only (`TextKit2RowView.swift:150`). Setting `.accessibilityTextHeadingLevel` over the row's `accessibilityAttributedLabel` (8faf040) changed nothing: VoiceOver ignores that text attribute on an element label (`r27-voiceover-ios27.xcresult`), so a76736f reverted it. The iOS 27.1 SDK has no public element-level heading level. `ListRendererUITests.testVoiceOverTraversalOfTasksAndDecisions` compares the heading without its level and pins the level as a strict `XCTExpectFailure`, so a fix fails the test as an unexpected pass (9246d99, `r28-voiceover-ios27.xcresult`). Candidate route: let SwiftUI own the element so `.accessibilityHeading` applies, keeping the `tk2-row:` identifiers and rebuilding the "Open link" actions as SwiftUI actions (`<data>/phase5/heading-level-followup.md`).

---

## 8. Running the gates

Every PR runs all of these against main. Proof artefacts (screenshots, perf CSVs, videos) live outside the worktree and are never committed.

**Command lines** (exact flags; each script's `--help` is the full reference). `<data>` is the task's data directory; every script takes an explicit `--udid`, refuses to run while another simulator is booted (the visual, e2e and lifecycle scripts accept `--allow-other-booted` for a provisional shakedown on a shared host; it records the other devices, and a final result is run without it), and shuts down only a device it booted.

```sh
# Visual parity (§8.2). Defaults: fixtures kitchen-sink@0,0.5 stress-5k@0,0.5
# lists-parity@0,0.119,0.214,0.357,0.405,0.452,0.548,0.643 list-dense@0.761,
# list fixtures "lists-parity:3 list-dense:3 list-tall:3" (min marker crops),
# appearances "light dark", size steps "0 3", arms "A A2 B C", --top-band 330
# --bottom-band 102, noise/exact-only --exact-mask 0,330,1206,460 (1206x2622).
Scripts/visual-parity.sh --udid <UDID> --ref-app <main(+fixtures) ADFReader.app> \
    --app <branch ADFReader.app> --out <data>/visual/<run>
#   [--fixture <name>[@<f1>,<f2>...]]... [--list-fixture <name>[:<min markers>]]...
#   [--appearances "light dark"] [--size-steps "0 3"]
#   [--arms "A A2 B C"] [--content-size large] [--settle 3] [--scroll-wait 2] [--ready-timeout 90]
#   [--mask x0,y0,x1,y1]... [--top-band 330] [--bottom-band 102]
#   [--exact-mask x0,y0,x1,y1]... [--no-exact-mask] [--threshold 24]
#   [--max-noise-pct 0] [--max-exact-pct 0] [--max-raw-pct 0.5] [--max-crop-pct 0.5] [--max-offset-px 0]
#   [--no-renderer-stats] [--allow-other-booted] [--keep-booted] [--skip-capture] [--dry-run]
#   (an A–A′ run, --arms "A A2", needs --ref-app only)
python3 -I Scripts/visual_diff.py --out <dir> --pair <noise|exact|tolerant> <name> <ref.png> <cand.png> ...
#   [--mask ...] [--exact-mask ...] [--top-band N] [--bottom-band N] [--threshold 24] [--exact-threshold 0] [--search 100]
#   [--list-pair <name prefix>[:<min markers>]]...

# Performance (§8.3). Per-PR gate, design pr45 (~40 min, no calibration); arm A is
# <data>/builds/main-a9e6aa2+stress1k (main + the stress-1k JSON):
Scripts/perf-gate.sh --udid <UDID> --app-a <main+stress1k .app> --app-b <branch .app> --app-c <branch .app> \
    --out <data>/perf/pr45-<sha>
# Lists stage (PR 2), design pr2 (~75–80 min; pr45 + list-dense); arm A is main 86abd56
# + the new list fixture JSON only (<data>/builds/main-86abd56+lists, FILES-ADDED.txt).
# Refused until list-dense's trial timeout is frozen in DEFAULT_TIMEOUTS (perf-gate.sh).
Scripts/perf-gate.sh --design pr2 --udid <UDID> --app-a <main+lists .app> --app-b <branch .app> \
    --app-c <branch .app> --out <data>/perf/pr2-<sha>
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
python3 -I Scripts/perf_summarize.py --print-design pr45|pr2|full
# Resolution bounds (READY gating) from an A–A′ run of untouched main:
python3 -I Scripts/perf_summarize.py <cal>/trials.csv --measure-bounds --write-bounds Scripts/perf-bounds.json
# A new fixture's bounds into the frozen file (never replaces an entry; records its own reference build):
python3 -I Scripts/perf_summarize.py --merge-bounds <cal>/bounds.json [--bounds Scripts/perf-bounds.json] [--write-bounds <out>]
# Offline tests (no simulator): summarizer cases, driver scenarios on a fake simctl, comparator cases.
python3 -I Scripts/tests/perf_summarize_tests.py <scratch>/sum
Scripts/tests/perf-gate-scenarios.sh <scratch>/scen [scenario...]
python3 -I Scripts/tests/visual_diff_tests.py <scratch>/vd

# End-to-end video (§8.4); a negative control (wrong digest) must fail.
Scripts/e2e-video.sh --udid <UDID> --out <data>/videos/<name>.mp4
#   [--test switch|lists] (default switch) [--derived-data <dir>] [--skip-build] [--keep-booted]
#   [--expected-sha256 <hex> | --negative] [--allow-other-booted]
#   (--skip-build needs the e2e-build-manifest.txt of an earlier build in the same derived data)
#   [--test-timeout <s>] [--recorder-ready-timeout 20] [--xcodebuild-grace <s>] [--dry-run]
#   (--create-device <name> instead of --udid: explicit opt-in, never deleted)
# Two videos from ONE build (PR 2): the switch test, then the list storyboard on its build.
Scripts/e2e-video.sh --udid <UDID> --test switch --out <data>/videos/switch.mp4
Scripts/e2e-video.sh --udid <UDID> --test lists --out <data>/videos/lists.mp4 \
    --skip-build --derived-data <data>/videos/switch.DerivedData

# Lifecycle checks (plan §3 checks 2–6; PR 2 list checks testL1…testL6) with the host agent
# Scripts/lifecycle_agent.py.
Scripts/lifecycle-gate.sh --udid <UDID> --out <data>/lifecycle/<run>
#   [--derived-data <dir>] [--skip-build] [--only <testName>]... [--suite-timeout 9000]
#   [--xcodebuild-grace 120] [--allow-other-booted] [--keep-booted] [--dry-run]
```

**Reference builds.** The reference is a Release, arm64-simulator, unsigned build of main from a clean `git archive` export (never the working tree), with `sha256.txt` beside the `.app`. `-scrollToFraction` lands exactly only since 9178cad (an animated jump into the lazy stack alone varied by up to 26 px between launches of one build: stress-5k at 0.5, step 3); a reference built from an older main needs that automation-only hunk applied, or arm A lands nondeterministically. PR 1's reference: `<data>/builds/main-a9e6aa2+scrolljump/` = a9e6aa2 + `scrolljump.patch` (the `ReaderView.scrollToFraction` hunk of 9178cad; sha256 recorded beside it). The unpatched `main-a9e6aa2` build is kept for the perf gate, which does not scroll to a fraction.

### 8.1 Parity suites

Location: `Tests/ADFRenderingTests/TextKit2/` (Swift Testing, `#if canImport(UIKit)`, so they run on the simulator only). Each root suite hosts the real `RichTextBlockView` in both arms through the environment; the list suites (PR 2) host the real `ListBlockView` / `ListRowView` and, for whole documents, `ADFDocumentView`, at the widths list text is actually proposed. The list parity, layout and sweep suites run from iOS 26 (before it list text stays on SwiftUI, and the scope and diagnostics suites assert that instead).

| Suite | Checks |
|---|---|
| `TextKit2HeightParityTests` | Height \|Δ\| ≤ 0.01 pt; first baseline, baseline pitch, last baseline and ink bounds separately; body, H1–H6, mixed mono/sub/sup; categories xSmall…AX5; 1/2/3+ lines; integer, fractional and narrow widths. PR 2 adds `linkedEmojiCodeResidual`, the linked emoji-and-code leaf residual as a known issue with its no-link and no-emoji controls (§6.7) |
| `TextKit2LineBreakParityTests` | Per-line horizontal ink extents from both arms' bitmaps match exactly, on a corpus of nearly-full lines; TK2 line-fragment ranges logged for diagnosis |
| `TextKit2CorpusParityTests` | Heights and line breaks over the breadth corpus (scripts, emoji, combining marks, RTL, indentation, alignment, hard breaks) |
| `TextKit2MetricsParityTests` | First/last baseline guides and ink bounds against SwiftUI's |
| `TextKit2PixelParityTests` | 3x and 2x, light and dark: an H1, the every-mark paragraph, the kitchen-sink paragraph with its link (TextKit 1-backed) and without, a link after a subscript line, a centred highlight after a link and without one, linked emoji lines (large/AX3/AX5), a strike after a subscript line, the sub/sup line family: first/last ink rows and per-row ink counts exact in every case (no exemption since 52ce693); differing pixels ≤ 0.2 %. At 96778b3: 169 comparisons per device (3x, 2x, iOS 18.5), the 163 outside `centred-highlight` all at 0 differing pixels; the 6 `centred-highlight` comparisons are residual 5 (`withKnownIssue` in the measured cases) |
| `TextKit2FixtureSweepTests` | Every eligible root of kitchen-sink, stress-5k and text-dense, large + AX3, both arms: \|Δ\| ≤ 0.01 pt, no exemptions. PR 2 adds every eligible list leaf of kitchen-sink, stress-5k, lists-parity and list-dense (leaders as `ListRowView` hosts them, text-column paragraphs and headings as `RichTextBlockView`), each distinct (text, style) once, with the eligible list leaf counts pinned so a walk that finds none fails; root pins unchanged |
| `TextKit2ListParityTests` (PR 2) | Lists through the real list views on both arms, at actual column widths (documents 375, 402, 320 pt and a fractional width; xSmall–AX5, Bold Text, RTL, light and dark): list heights; per-row heights and first/last baselines ≤ 0.01 pt (residual 1 as a known issue); marker and content crops compared as pixels independently, plus the marker's offset from the first text ink; whole lists; whole documents fully materialised, band by band; mixed-column shapes; column-filling reported widths; narrow and zero-width columns; the later-line link + emoji + sub/superscript leader at AX3–AX5; every fallback (atoms, empty and break-only text, trailing breaks, RTL, embedded blocks, host styling, raw-font themes) |
| `TextKit2ListScopeTests`, `TextKit2RendererSetterTests` (PR 2) | Through `ADFDocumentView`: list text follows the renderer at every depth under the list rules, excluded subtrees (a list in a container, text in a list item's container) get no TK2 row, and before iOS 26 no list text does; the renderer key is set in exactly two places (source scan, runs on every platform) |
| `TextKit2ListLayoutTests` (PR 2) | Layout passes: two per list leaf through the document view (natural probe, column width), one per root; per proposal when measuring and per row when materialising (zero, narrow, phone, infinite, unspecified) |
| `TextKit2ListCoverageTests`, `TextKit2ListDiagnosticsTests` (PR 2) | Hand-counted leaf coverage pins (lists-parity, list-dense, kitchen-sink), `.osGatedList` pins before iOS 26 (never a root), the rows drawn for lists-parity equal the eligible leaves counted, live list rows released on OFF, one conversion per text or layout-input change and none for a re-apply or flip |
| `TextKit2StableIDReplacementTests` (PR 2) | Through `ADFDocumentView`, content replaced under stable owner IDs: (a) list leaders replaced with `apply(.replace)` (growing, shrinking, same length with new words, and a paragraph alone in its continuation row), (b) a replacement document that reuses every structural ID, (c) the root-paragraph control. Each row's label, string, placement, drawn layout and cached widths' layouts match a fresh document's; changed rows convert again and lay out after the change; under a stable-ID replacement unchanged rows keep their view and string. (a) and (b) run from iOS 26 |
| `TextKit2AppearanceFlipTests` (PR 2) | One hosted row light → dark → light vs fresh light and dark rows, pixel-exact: plain `.label`, author hex, run backgrounds, accent link (TextKit 1); layout count, relayouts, cached widths, text instance, frame and baselines unchanged; a flip with a width or content change still relayouts |
| `TextKit2FallbackTests` | Fixed regression cases: linked text (link+emoji wrap, kitchen-sink paragraph, linked sub/sup) is a TextKit 1-backed row measuring exactly at large/AX3/AX5; double trailing breaks exact on iOS 26 and SwiftUI before it; unsupported inherited styling stays on SwiftUI; a heading below them moves ≤ 2 px on a switch either way; a paragraph with search highlights renders on SwiftUI while the search is active and returns to TK2 when it is cleared |
| `TextKit2LinkTests` | Link taps (wrapped, coloured, RTL, emoji-adjacent; misses rejected), "Open link" actions, SwiftUI `openURL` delivery; a linked row counts as TextKit 1-backed and its draws never as native; only linked rows carry a tap recognizer |
| `TextKit2DiagnosticsTests` | Through `ADFDocumentView`: eligible roots get TK2 rows; plain ones are drawn natively (native draws > 0), the linked one is TextKit 1-backed (its draws counted apart, every draw one or the other); atom-bearing and non-text roots get none; switching back releases them; coverage counts |
| `TextKit2RowViewTests` | Row contract: cache and proposal cases (§6.2), placed-layout lookup, no eager relayout, resolver traits and metrics, foreground precedence (prepared, link tint, label) |
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
  -only-testing:ADFRenderingTests/TextKit2ListParityTests \
  -only-testing:ADFRenderingTests/TextKit2ListScopeTests \
  -only-testing:ADFRenderingTests/TextKit2RendererSetterTests \
  -only-testing:ADFRenderingTests/TextKit2ListLayoutTests \
  -only-testing:ADFRenderingTests/TextKit2ListCoverageTests \
  -only-testing:ADFRenderingTests/TextKit2ListDiagnosticsTests \
  -only-testing:ADFRenderingTests/TextKit2AppearanceFlipTests \
  -only-testing:ADFRenderingTests/TextKit2StableIDReplacementTests \
  -derivedDataPath <scratch>/dd-core
# List preparation (PR 2): trailing .listRows origins, lists-parity / list-dense / list-tall /
# lists-links owners, markers, depths, continuations and search units.
xcodebuild test -scheme ADFKit-Package -destination 'platform=iOS Simulator,id=<udid>' \
  -only-testing:ADFPreparationTests/TrailingListRowsOriginTests \
  -only-testing:ADFPreparationTests/ListsParityPreparationTests \
  -only-testing:ADFPreparationTests/ListPerfFixturePreparationTests \
  -only-testing:ADFPreparationTests/ListsLinksPreparationTests -derivedDataPath <scratch>/dd-core

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
- **PR 1 result** at the final head (2026-10-28; branch 82c9d75 `e29c9335…` vs a9e6aa2 + scrolljump `bf2fa7fe…`, 0 uncommitted paths, device at light/large): 48/48 pairs PASS — A–A', A–B and A–C all 0 px in 16 configurations, every crop 0 % with a 0 px offset; `RENDERER_STATS` required and confirmed swiftui on every B and textkit2 on every C. 45 pairs are in `<data>/visual/gate-82c9d75/`; the kitchen-sink p0 light s3 cell was captured and scored separately in `<data>/visual/gate-82c9d75-rerun-ks-p0-light-s3/`. Earlier runs: `gate-96778b3/`, `gate-cff271e/` and `gate-4ded1a4/` (also 48/48, 0 px); `gate-8518d01/` keeps the pre-fix run (nondeterministic stress-5k p0.5 s3 landing) as root-cause evidence.
- **PR 2 list captures** (defaults since PR 2): lists-parity at eight positions and list-dense at 0.761. Each lists-parity position lands a section heading under the toolbar, so the list's first marker sits below the exact-mask band; together they cover nesting, ordered-marker boundaries, tasks and decisions, leader content, item structure, trailing lists and lists in excluded containers. list-dense at 0.761 lands deep in the document on task and decision lists. Arm A is main + the new fixture JSON. A position names a block (block = Int(position × blocks)), not a sentinel: READY block counts are a gate invariant, so a position is the same block in every arm.
- **Marker and content crops** (every pair since PR 2): each text row that starts with a marker is split into a marker crop and a content crop, and the marker's centroid, the content's first-line centroid and their relative position must match within 0.5 px, so a one-pixel marker move cannot hide inside a percentage. A list pair (`--list-fixture`, `visual_diff.py --list-pair`) with fewer marker crops than its minimum (3 by default) is INVALID, and a low-contrast fill difference such as a decision row's background, which the tolerant rule cannot see, FAILs.
- **PR 2 result** on the frozen candidate (2026-11-12; `cand-a76736f` `d0426620…` vs `main-86abd56+lists` `da6e6a7e…`, scripts at a69a77c with 0 dirty paths, iPhone 17 Pro iOS 26.3 at light/large): 156/156 pairs PASS. 13 positions (kitchen-sink 0 and 0.5, stress-5k 0 and 0.5, lists-parity at its eight positions, list-dense 0.761) × light and dark × `-fontSizeStep 0` and `3` give 52 configurations, each scored A–A′, A–B and A–C. A–A′ and A–B are 0 px in all 52. A–C is 0 px over the tolerant threshold in all 52, and all 1,163 of its text-block crops are 0 % with a 0 px offset. None of its 573 marker crops fails; the worst marker/content position Δ is 0.06 px (lists-parity p0.405 dark s3; limit 0.5 px). Each of the 36 list configurations has at least 6 marker crops (minimum 3) and 0 px fill difference. `RENDERER_STATS` was required and confirmed swiftui on all 52 B captures and textkit2 on all 52 C. This final run used `--allow-other-booted` on purpose: it ran beside the final UI rerun, and the captures do not depend on other devices (the two other booted devices are recorded in `env.txt`). Evidence: `<data>/visual/final-a76736f/`.
- **Pass:** A–A' noise recorded (expected 0.00 %); A–B 0.00 %; A–C ≤ 0.5 % whole-viewport **and** every text-block crop ≤ 0.5 % with a vertical offset of 0 px. A pair with no text-block crop (a blank or chrome-only viewport) is INVALID, not PASS (`visual_diff.py --allow-empty` overrides this for a deliberately empty capture).
- **Restores the device:** the run ends with the appearance and content size the device had when it started (`<data>/visual/restore-check.txt`).
- **Chrome differs from main even with the switch OFF**, and is masked for that reason: the demo's toolbar leads with the renderer menu ("SwiftUI" / "TextKit 2"), which also holds the HUD toggle and "About This Build…", so the trailing items are [renderer] [Find] [Text Size] [TOC] against main's [Find] [Text Size] [TOC] [HUD]. Only the demo app changes; the library has no chrome. The capsule widths follow the label, which is why noise/exact pairs mask the band below the toolbar.

### 8.3 Performance — `Scripts/perf-gate.sh` + `Scripts/perf_summarize.py`

Interleaved A/B/C trials on one simulator: launch to `READY` (labelled "preparation readiness", not first visible content), first chunk, autoscroll dropped frames / dropped rate / hitch ratio, memory (RSS and `footprint`, sampled peak; the app's %CPU is sampled with RSS so a stall can be told apart from host starvation). A = main (Release), B = branch with the switch OFF (`-rendererReset -rendererStats`; it carries the font-spec baking and switch plumbing on the shipping path), C = branch with `-textkit2 -rendererStats`. **Both B and C must pass.**

| Design | Fixtures × arms × pairs | Rule | When |
|---|---|---|---|
| `pr45` (default) | kitchen-sink, stress-1k (the first 1,000 blocks of stress-5k), giant-table × A/B/C × 3, one discarded warm-up per (fixture, arm) | median-relative | every PR, ~40 min |
| `pr2` (PR 2) | pr45's three fixtures + list-dense × A/B/C × 3, one discarded warm-up per (fixture, arm); list proof, arm-A completion and fixture hashes required (below) | median-relative, pr45's thresholds | the lists PR, ~75–80 min |
| `full` | kitchen-sink, stress-5k, giant-table × A/B/C × ≥ 10, frozen A–A′ calibration | calibrated-ucb | once, before the final parity PR, ~8 h |

Full stress-5k is covered only by the one full gate before the final parity PR. Main a9e6aa2 has no scroll-length knob, so three pairs of full stress-5k (≈518 s a trial) do not fit 45 minutes; stress-1k was data only then, and PR 1's arm A is a clean `git archive a9e6aa2` plus that one JSON (`<data>/builds/main-a9e6aa2+stress1k/`, `FILES-ADDED.txt`, sha256 recorded). Main bundles stress-1k, text-dense and long-paragraph since PR 1 merged (86abd56). PR 2's arm A is a clean `git archive 86abd56` plus only the new list fixture JSON, byte-identical to the branch's (`<data>/builds/main-86abd56+lists/`, `FILES-ADDED.txt` with sha256 per file and per bundled copy). A design names, per fixture, the arms it runs (`DESIGNS` in `perf_summarize.py`, `fixture_arms` in `plan.json`), so another shape is configuration, not code: `pr2` is one named design, never a hand-combined verdict of pr45 and a supplement, and `pr45` itself is unchanged.

**Bounds and the 15 % rule** (per PR description too). Rule: the median over 3 pairs of (cand − A) / A median, for B and C separately. From calibration attempt 1 (10 A–A′ pairs of untouched main, 2026-10-26) we took the 95th percentile of |median of 3 AA′ deltas| over all 120 triples. That's the smallest change 3 pairs can tell apart from noise:

| metric | kitchen-sink | stress-5k | giant-table | gated per PR |
|---|---:|---:|---:|---|
| launch→READY | 11 % (64 ms) | 22 % (282 ms) | 42 % (249 ms) | where the bound is ≤ 15 %: kitchen-sink (11.3 %) and, in `pr2`, list-dense (13.8 %, below); giant-table (42.0 %) and stress-1k (no measured bound) advisory |
| first chunk | 20 % (11 ms) | 11 % (8 ms) | 15 % (11 ms) | yes, 15 % with a 20 ms absolute floor |
| RSS at READY / peak | 0.5 % / 3.7 % | 3.7 % / 3.8 % | 1.0 % / 0.7 % | yes |
| footprint at READY / peak | 2.1 % / 3.1 % | 10.2 % / 8.0 % | 4.3 % / 1.6 % | yes |

- READY: kitchen-sink 11 %, stress 22 %, giant-table 42 %. First chunk: 11–20 % (8–11 ms absolute). RSS and footprint at READY and peak: 0.5–10 %.
- So the 15 % FAIL rule gates memory and kitchen-sink READY (and list-dense READY in `pr2`, below). First chunk gets 15 % with a 20 ms absolute floor. READY on stress and giant-table is advisory: 3 pairs can't resolve 15 % there.
- The gating is data, not a fixture list: `Scripts/perf-bounds.json` (written by `--measure-bounds`) holds the bounds, and launch→READY gates a fixture only when its bound is ≤ 15 % (or ≤ its absolute floor); a fixture without a measured bound is advisory. The plan records the bounds sha256 and the gated fixtures when the run starts; a later change makes the run INVALID.
- list-dense (PR 2) has no bound until an A–A′ run of main + the list fixtures is measured and merged with `--merge-bounds`, which never replaces an existing entry and records the new entry's own reference build (`fixture_sources`); until then list-dense READY is advisory, and memory and first chunk gate regardless. `app_sha256` in the bounds file is provenance only: nothing compares it with arm A. Measured and merged in `a69a77c` (2026-11-11): 5 A–A′ pairs + 1 warm-up of `main-86abd56+lists` (`da6e6a7e…`), 95th percentile over the 10 triples. launch→READY 13.8 % (89.8 ms of a 650.7 ms median) ≤ 15 %, so list-dense READY is gated; first chunk 12.5 % (8 ms); RSS at READY / peak 0.4 % / 0.4 %; footprint at READY / peak 1.8 % / 1.1 %. The bounds file is `fb5567ea…` since the merge; the existing entries are byte-identical. The host was busy throughout (1-min load ~5.3, PerfPowerServices ~160 % CPU), so the calibration is recorded HOST-BUSY; attempt 1 (load up to 21) gave 7.9 %, and the wider attempt-2 bound was merged. Evidence: `<data>/perf/bounds-list-dense-a2/` (`bounds.md`, `bounds.json`); attempt 1 in `<data>/perf/bounds-list-dense/`.
- Frame metrics have median ≈ 0, so relative deltas are meaningless; only the ceilings and an absolute Δ ≤ 2 frames apply.

**What it can and can't catch** (per PR description too):
- Catches: stalls (the 27/27 kitchen-sink stall at 940 ms/s, the post-boot 197 ms/s), sustained ≥ 1 % drops, ≥ 15 % memory growth, ≥ 15 % kitchen-sink READY (and list-dense READY in `pr2`).
- Misses: shifts under 15 %, about half of true 15 % shifts on noisier metrics (stress footprint at READY has a 10 % floor), rare stalls that don't land in 3 trials, and READY regressions under about 25 % (stress) or 45 % (giant-table).

- **full rule:** per-metric allowance = max(max \|ΔAA′\|, absolute floor), frozen in `calibration.json` before any candidate result exists (its `created_utc` must predate the first trial), with a ceiling of 15 % of A's median; the summary prints each allowance as a % of the median. PASS if the one-sided 95 % upper bound of the mean paired delta ≤ the allowance. A calibration over the ceiling is INCONCLUSIVE: quiesce and recalibrate once.
- **Per-trial ceilings (both designs):** hitch > 10 ms/s, or dropped rate > 1 % (more than 3 dropped frames when a trial has < 2,000 frames). A candidate breach FAILs; a breach in A makes the run INVALID (environment; one predeclared rerun). Worst main values in calibration attempt 1: 6.0 ms/s (one frame on kitchen-sink) and 0.14 elsewhere.
- **Traversal and renderer proof:** B and C must reach the last block (`endRow` = blocks − 1) with frames within ±15 % of A's median, or the trial FAILs. C must report `renderer=textkit2` at READY and after the scroll, with `tk2Layouts > 0` and `tk2NativeDraws > 0`; B must report every TK2 counter 0. The TextKit 1-backed share (`linkRoots / eligibleRoots`, `tk1BackedDraws / tk2Draws`) is printed per fixture.
- **List proof (`pr2`, list-dense):** C must report `tk2ListLive > 0` at READY or at the end, leaf coverage present and at least one eligible list leaf (`eligibleTextLeaves − eligibleRoots > 0`, and leaders + list paragraphs > 0); B must report `tk2ListLive = 0`. A missing proof, zero list leaves or all-fallback lists make the run INVALID, as a missing `tk2NativeDraws` does. The per-fixture "Leaf coverage" line discloses the list leader and paragraph counts, the TextKit 1-backed (linked) share, the SwiftUI-fallback share and the live list rows at READY and at the end.
- **Arm-A completion and fixture hashes (`pr2`):** arm A must report `SCROLL_METRICS completed=1 endRow=blocks−1` (main has printed it since 86abd56), so a short A is INVALID. Before any trial, and before booting, `perf-gate.sh` checks that every design fixture is bundled in each arm's `.app` with identical bytes, and refuses otherwise (exit 2, nothing run); the plan records each arm's fixture sha256 and every trial its installed copy. READY block counts must agree across arms or the run is INVALID, so PR 2 changes no list preparation, ids or block counts: that is a gate invariant, not only a scope choice.
- **Refused before any trial** (exit 2): a gate run with less than its design (arm B, a fixture, an arm of a fixture, pairs, the warm-up, the sampler, the candidate markers or `-rendererStats`), pr45 or pr2 with a calibration or full without one, a design fixture missing from or differing between the arms, and a non-pilot run with a fixture whose timeout is not yet frozen.
- **Host (firstmate policy):** quiet = 1-min load ≤ 4.0 and no non-simulator process above 100 % CPU. After the settle (300 s when the run booted the device) the driver samples the host every 30 s for up to 20 min (`--host-poll`, `--host-wait`) and starts when it is quiet, or after the wait regardless. `plan.json` records the last sample and the wait; every trial row records its start time, load and busiest processes. A run that was not quiet at the start or in any counted trial is **HOST-BUSY**: its PASS counts; its FAIL is reported as `FAIL-HOST-BUSY` (exit 6) and is re-run once at the next quiet window before it counts as a FAIL. Nothing is ever killed or reniced.
- **Fail closed:** a result counts only with every declared pair present, every metric finite, exit 0, the expected `READY` line, and the installed sha256 and argv matching the arm. The summarizer reads the design and the pilot flag from `plan.json`, never from its own flags, and marks a reduced plan INCOMPLETE. Precedence: candidate crash → FAIL; invalid trial, baseline failure or A ceiling breach → INVALID; candidate failure → FAIL; too few pairs → INVALID; calibration INCONCLUSIVE; statistical or ceiling failure → FAIL; PILOT; INCOMPLETE; PASS; then a FAIL on a HOST-BUSY run → FAIL-HOST-BUSY. Exit codes: PASS 0, FAIL 1, INVALID/REFUSED 2, INCONCLUSIVE 3, PILOT 4, INCOMPLETE 5, FAIL-HOST-BUSY 6.
- **Reruns:** every verdict is appended to `perf-ledger.jsonl` beside the run directory. A FAIL with the same candidate binaries and design is never rerun (REFUSED); a FAIL-HOST-BUSY allows one rerun, and a second FAIL-HOST-BUSY for the same binaries counts as FAIL; after two INCONCLUSIVE/INVALID runs the next is REFUSED. Pilots do not count. A design that includes another (`pr2` includes `pr45`) is also REFUSED after a FAIL of the included design for the same candidate binaries, because it re-measures those fixtures.
- **Deadlines:** per-fixture trial timeouts default to 1.5 × the pilot's longest scroll + 30 s (kitchen-sink 45 s, stress-1k 180, stress-5k 775, giant-table 95, text-dense 425, long-paragraph 45); `--suggest-timeouts` recomputes them from a pilot. list-dense is `UNFROZEN` in `DEFAULT_TIMEOUTS` until its pilot: a non-pilot run that includes it is refused even with `--trial-timeout-for`, and a pilot must pass its timeout explicitly. list-dense's pilot ran on 2026-11-11 (`<data>/perf/pilot-list-dense-a76736f/`, longest scroll 162 s), and `883ef64` froze its timeout at 275 s = ceil5(1.5 × 162 + 30). The `UNFROZEN` mechanism stays for the next fixture that needs a pilot.
- **Fixtures:** `text-dense` (~3,000 text-only paragraphs/headings) and `long-paragraph` (one ~20,000-character paragraph; the per-row layout worst case) are generated with `Tools/make-fixtures.swift`. In PR 1, main (a9e6aa2) did not bundle them, so they were reported as B-vs-C information only (a pilot-shaped run, uncalibrated). Main bundles both since 86abd56, so arm A can open them and a same-resource A/B/C comparison is possible; they stay outside the gated designs as targeted checks, and the fixture sweep (§8.1) covers text-dense heights. PR 2 adds, from the same generator: `list-dense` (600 root lists, 3,698 rows: every marker family, nesting, continuations, linked and atom-bearing leaders, root task and decision lists, trailing headings; sized with the autoscroll estimator to ≈ 111.5 s of scroll, stress-1k's class; gated in `pr2`), `lists-parity` (21 blocks covering every list shape and fallback; visual, parity and interaction tests), `lists-links` (linked list text in every shape; link tests) and `list-tall` (a 316-row root list; eager-root cost). Existing fixture bytes are unchanged.
- **Report:** per fixture × metric — A, B and C median (min–max), paired Δ (median, or mean with its 95 % upper bound), limit, verdict — with the coverage line and the TK1 share. PR 2's table also carries each fixture's leaf coverage line. **PR 2 result** on the frozen candidate (`pr2`, 2026-11-14 02:50–03:49Z; `cand-a76736f` `d0426620…` vs `main-86abd56+lists` `da6e6a7e…`, 3 pairs + 1 warm-up, iPhone 17 Pro iOS 26.3, bounds `fb5567ea…`): **FAIL-HOST-BUSY** (exit 6). B passes every metric on all four fixtures. C fails list-dense dropped frames (median 71 vs A's 44, median Δ +28, limit ≤ 2) and breaches the per-trial ceilings in every trial on list-dense and on kitchen-sink (table); C's launch→READY, first chunk and memory pass. launch→READY gates on kitchen-sink and list-dense and is advisory on stress-1k and giant-table (bounds above). HOST-BUSY: the run started quiet (1-min load 3.96), then 20 of 36 trial samples had a load over 4 (4.02–6.95), from the host's own processes, none over 100 % CPU; no other simulator was booted. It is the one quiet rerun of a first run that was INVALID on a busy host (2026-11-11, `<data>/perf/pr2-a76736f/`: main breached the hitch ceiling on kitchen-sink), so the verdict ships as measured, with no third run. C's cost is per-leaf TextKit 2 hosting plus two layouts per list leaf, in the frame where a list block materialises (`<data>/perf/pr2-list-dense-c-diag/findings.md`). TextKit 2 stays OFF by default, and one TextKit 2 view per list row or block is the proposed follow-up. Evidence: `<data>/perf/pr2-a76736f-quiet2/` (`summary.md`, `trials.csv`, `plan.json`).

  | fixture | arm | launch→READY, median Δ / A | first chunk, median Δ / A | dropped frames: median vs A's, median Δ (limit ≤ 2) | per-trial ceilings (hitch 10 ms/s, dropped rate 1 %) | memory, median Δ / A (RSS and footprint, at READY and peak) |
  |---|---|---|---|---|---|---|
  | kitchen-sink | B | −1.5 % PASS | +0.0 % PASS | 0 vs 1, Δ −1 PASS | PASS (hitch 0.00 ms/s) | −0.7 to +0.2 % PASS |
  | kitchen-sink | C | −1.9 % PASS | +12.5 % PASS | 2 vs 1, Δ +1 PASS | **FAIL** in 3 of 3 trials: hitch 11.98, 18.07, 11.98 ms/s (2–3 dropped frames of ~165; A: 0–1, hitch 0.00–9.44) | −0.3 to +1.6 % PASS |
  | stress-1k | B | +3.1 % advisory | +3.4 % PASS | 0 vs 0, Δ 0 PASS | PASS (hitch 0.00 ms/s) | −0.1 to +2.1 % PASS |
  | stress-1k | C | +0.5 % advisory | +13.6 % PASS | 1 vs 0, Δ +1 PASS | PASS (hitch 0.17–0.34 ms/s) | +0.1 to +1.5 % PASS |
  | giant-table | B | −7.8 % advisory | +2.3 % PASS | 0 vs 0, Δ 0 PASS | PASS (hitch 0.00 ms/s) | −1.3 to −0.1 % PASS |
  | giant-table | C | −5.0 % advisory | −11.6 % PASS | 0 vs 0, Δ 0 PASS | PASS (hitch 0.00 ms/s) | −0.5 to +0.4 % PASS |
  | list-dense | B | −6.4 % PASS | −1.5 % PASS | 37 vs 44, Δ −1 PASS | PASS (hitch 5.53–6.59 ms/s, dropped rate 0.534–0.621 %) | +0.3 to +1.3 % PASS |
  | list-dense | C | +1.3 % PASS | +16.7 % PASS (11 ms ≤ the 20 ms floor) | 71 vs 44, Δ +28 **FAIL** | **FAIL** in 3 of 3 trials: hitch 10.76–11.05 ms/s, dropped rate 1.018–1.047 % (A: 5.51–7.18 ms/s, 0.535–0.693 %) | +0.3 to +3.5 % PASS |

  Beneath the table, the PR description carries the twenty-flip memory line (refreshed at the final head); PR 1's read: "Twenty-flip memory: control is now 20 switches that rebuild the same 9 leaf rows as plain SwiftUI (each arm in its own launch, alternating order). Before, it was 20 same-renderer picks that rebuilt nothing. Raw growth medians of 2 at 82c9d75: control +29,792 KB, TK2 +32,616 KB, excess +2,824 KB ≤ 5,120 KB, no relief. Evidence: `<data>/lifecycle/run-82c9d75/`, `<data>/memory-phase4/`."

The autoscroll gate alone provably misses livelocks. Also run, in **both** arms: a real fling with an instantaneous-CPU settle check (`top -l 2 -pid <pid>` → ~0 % within 5 s), scene-snapshot thrash (Home / lock / app switcher ×5), a 60-second idle soak, and for the switch, twenty flips on stress-5k (`LifecycleUITests` test 7, via `Scripts/lifecycle-gate.sh`): the live TK2 row count is back to 0 after every OFF, and **control = twenty flips that rebuild the same leaf rows as plain SwiftUI (no TextKit 2), asserted by a rebuild counter; TK2 raw growth ≤ 5,120 KB above the control; no relief; median of 2 runs** (raw settled `phys_footprint`; a settled read is two equal reads 250 ms apart). The control (captain's rule B, decision A) rebuilds the same rows as plain SwiftUI: under `-rebuildControlPicks <n>` the demo's TextKit 2 picks apply the internal `@_spi(ADFDiagnostics) View.adfRebuildControl(true)` (an environment value) to the document, and each leaf a TextKit 2 pick would swap renders its SwiftUI `Text` at the same branch point instead — same leaves, same menu and About traffic; the test asserts the control shows the same nonzero rebuilt-row count after every ON pick as TK2's live rows, and none after every OFF (9 rows at PR 1's head; the test compares the two counts and never hard-codes one). Each series runs in its own launch, arm order alternating between runs: the first series of a launch takes the allocator's high-water growth (a control → TK2 order in one launch gave TK2 +4,144 / +336 KB against the control's +29,568 / +33,920). Before, the control was twenty same-renderer picks that rebuilt nothing, and the row rebuild alone — no TextKit, no UIKit row — exceeded 5,120 KB over it (`<data>/memory-phase4/`). Result at the final head 82c9d75: control 33,440 / 26,144 KB, TK2 33,200 / 32,032 KB, medians 29,792 vs 32,616, excess +2,824 KB (`<data>/lifecycle/run-82c9d75/`); at 604605c it was control 36,688 / 36,672 KB, TK2 35,696 / 40,368 KB, excess +1,352 KB (`<data>/memory-phase4/gate7-rebuild-control/`). The thrash cycles assert that Home, lock and the switcher each left the foreground, by the app's own scene phases (`-scenePhaseProbe`: Home and lock each add a background transition, the switcher a background or inactive one, and the app ends active) on every stop of all five cycles. `XCUIApplication.state` is recorded only as a cross-check: it reads foreground at every stop on the simulator, even while the screenshot shows the Home screen. The check as first added in ef6ea6e read that state, so it failed at 96778b3. It had not existed at cff271e, whose test 5 and 6 recorded the same all-foreground states and passed. `test8` (Fable S16) checks the renderer launch flags on device: `-textkit2` starts on TextKit 2 over a persisted SwiftUI pick, the next plain launch is SwiftUI again, and a toolbar pick of TextKit 2 survives a plain relaunch (toolbar label and live TK2 rows each time). Measured at 9bf45ff: raw `phys_footprint` growth across flips is allocator high-water, not retention — over 10 flip pairs live malloc stayed at 63.84 MB (−384 B; largest class +2 KB, in-process zone histogram) while the footprint rose 139 → 159 MB, and `malloc_zone_pressure_relief` returns it each time (102 / 99 / 101 MB warm / +10 / +20 pairs). That is why the twenty-flip rule subtracts a SwiftUI control rather than reading after relief; `-memoryReliefHook` stays for diagnostics only. Evidence: `<data>/memory-phase2/`.

**List lifecycle checks (PR 2)**, `LifecycleUITests` `testL1…testL6` on lists-parity and list-dense, run by the same gate (`--only <testName>` for one); tests 1–8 stay as they were. A list row drawn by TK2 is a `tk2-row:<owner>` element with an owner below root level, so the checks see list leaves flip:

- **L1** five ON/OFF round trips at a parked list position in each fixture: every switch moves every common label ≤ 2 px, nothing accumulates (each OFF within 2 px of the start, each ON of the first ON), the ordered marker stays on its leader's line, and the landmarks keep their owners; then Fable F14: About's live count exceeds the root-owned TK2 rows on screen and list-owned rows exist, and OFF releases every row.
- **L2** test 1's collapse round trip on list-dense, both directions (ON at the park, away until the parked list leaves the render region, OFF, back; and the reverse, so the list rematerialises naturally as TK2): forward returns within 2 px of the no-switch control's park, reverse within 2 px of the ON park, every switch moves labels ≤ 2 px, and no label pair changes order.
- **L3a / L3b** rotation and Text Size 0→3→0 on list-dense, each drift's TK2 excess over the SwiftUI arm ≤ 2 px and CPU settling ≤ 2 % within 5 s; and on lists-parity (no media), search over list text, opened expands and toggled tasks surviving ON, rotation, size steps and OFF.
- **L4a / L4b** a switch during list-dense's streamed load (after READY the last root's leaders are TK2 rows owned by their `PreparedListRow.id`); and a replacement document with colliding structural ids (list-dense and lists-parity share row owners): each document shows only its own text, and no cached height leaks through a colliding owner.
- **L5a / L5b** test 5/6's fling, Home/lock/switcher ×5 and 60 s soak on list-dense in each arm, with list-owned TK2 rows after the thrash.
- **L6** test 7's rule-B twenty flips on list-dense (every root a list): the control and TK2 show the same ON count, list leaders and text included, and Fable F14 holds after each TK2 series.

A no-switch control drift over 2 px is PR 1's known lifecycle flake (Fable F16; test 1 failed once on 14 px and passed on rerun): it is recorded as `failure_class` and rerun, never re-tuned. Durations: ~43 min for tests 1–8 and ~56 min for the list tests, plus the build. <!-- TODO(team-lead): lifecycle result (run path, per-test verdicts) -->

### 8.4 End-to-end video — `Scripts/e2e-video.sh`

Records one named UI test (`--test`, nothing else accepted) and writes a provenance manifest that ties the video to one binary:

- `--test switch` (default): `ADFReaderUITests/RendererSwitchUITests/testLiveSwitchSwiftUIToTextKit2AndBack`, SwiftUI → TextKit 2 → SwiftUI on `kitchen-sink`, launched with `-rendererReset -rendererStats`.
- `--test lists` (PR 2): `ADFReaderUITests/ListStoryboardUITests/testListStoryboardSwiftUIToTextKit2AndBack`, the list storyboard (Astra §8 steps 1–6), opened from the fixture list: lists-parity for nesting, ordered markers, tasks and decisions (all above its tables), then list-dense, which holds only lists, for a continuation paragraph, the atom and heading-column fallbacks and search (bbc3b4c). Along the way: list-owned TK2 rows and linked rows reported as TextKit 1-backed, five round trips at a list landmark, a task toggle and decision chrome across switches and a scroll away and back, a search that falls back per owner and returns to TK2, and OFF, with the live count recorded right after the switch and 0 required once the TK2 path has been retraced (§6.7).
- Both tests assert the About checksum with the same failure message, so `--negative` works for either. Two videos come from **one** build: `--test switch` builds; `--test lists --skip-build --derived-data <the first run's>` reuses it, and both provenance files carry the same build-manifest digests. Before running, the UI-test bundle binary must contain the selected test method's name, or the run fails.
- `--allow-other-booted` is for a provisional shakedown on a shared host only: the other devices are recorded in the log and the provenance; a final video is recorded without it.
- One isolated `build-for-testing` (Release, unsigned), then `test-without-building` with the exact generated `.xctestrun` and an explicit `--udid` (a device is created only on request, and only a device this run booted is shut down).
- The switch test requires the expected digest (fails when it is absent), reads the **app-observed** sha256 off the About sheet, asserts `tk2-row:<id>` / `tk2-live-rows` in both directions, and checks scroll preservation (stable element |ΔY| ≤ 2 px per switch, five round trips). After the scroll-to-top under TextKit 2 the H1's settled top (three reads 1 s apart within 0.01 pt) must be within 2 px of the SwiftUI arm's; the final switch back to SwiftUI happens with a TextKit 2 heading on screen. Since PR 2, OFF is checked in two steps (§6.7, unshown cached rows): no `tk2-row` element is on screen right after the switch, and after the TextKit 2 scroll path has been retraced on SwiftUI, the live count and the list-text count are 0.
- Final videos are recorded on iOS 26.3: the switch test's scroll-to-top fails on iOS 27.0's navigation-bar geometry (§6.7). <!-- TODO(team-lead): final video paths, provenance and negative-control result -->
- The build pins its source: the commit and clean/dirty state are read before `xcodegen generate` and again after the build (a change aborts), and `e2e-build-manifest.txt` records them with the sha256 of the app, the UI-test bundle binary and the `.xctestrun`. `--skip-build` requires that manifest and re-verifies every digest; the source is checked again at the end.
- Recording starts before the test launches and stops only after the named test's `passed` line. The recorder must stay alive throughout, and the video must cover the test (duration + 2 s ≥ recorder-ready → result), or the run fails. The manifest records the build command, commit and clean/dirty state, sha256 of the built, companion and installed binaries and of each bundled fixture, the observed digest, the test result and xcresult path, the simulator and Xcode versions, and the video's sha256 and duration. A run with a deliberately wrong digest must fail.
- Videos go in the task's data directory and the PR description, never in the repo.
