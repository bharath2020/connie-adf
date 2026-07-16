# Text Search: Independent Review & Complexity Analysis

**Date:** 2026-07-15
**Scope:** the find-in-page text-search feature, branch `worktree-adfkit-text-search`
(19 commits, `8769750..1aced71`), reviewed as a whole.
**Provenance:** produced by an independent opus-class reviewer with no prior
involvement in the feature's development or its per-task reviews — fresh eyes over
the full diff, the pre-existing rendering machinery, the spec
(`docs/superpowers/specs/2026-07-14-adfkit-text-search-design.md`), and the
measured performance record (`docs/Architecture-Decisions.md` §18).

**Verdict: With fixes.** The architecture is sound, concurrency is careful and
well-tested, and the performance doctrine is honored with evidence. One
Important issue should land before merge (the streamed auto-select gap, §4.2);
the Minor items are fine to fold in or track as follow-ups.

---

## 1. Quantities used throughout

| Symbol | Meaning |
| --- | --- |
| **B** | top-level lazy-stack blocks (rows/slices) |
| **N** | nodes in the prepared block tree |
| **T** | total searchable characters in the document |
| **U** | extracted text units |
| **M** | matches for a query |
| **Q** | query length |
| **V** | materialized rows in the render region (small; bounded by viewport, ≈ dozens) |
| **S** | parts/segments in one text unit |
| **D** | expand-nesting depth |

All string offsets in this feature are **Character (grapheme) offsets**, deliberately.

---

## 2. Pipeline 1 — Finding matches in the ADF corpus

Files: `Sources/ADFPreparation/Search/{SearchIndex,SearchIndexer,SearchMatcher}.swift`,
plus the index/scan orchestration in `Sources/ADFRendering/Search/ADFDocumentSearch.swift`.

### 2.1 Data structures & algorithms

- **Unit extraction** (`SearchIndexer.units` → `collect`): a recursive pre-order walk
  of `[RenderBlock]`. Each segment-bearing container (rich text, code, list rows +
  their `trailingBlocks`, media captions, and the children of
  panels/quotes/extensions/layout columns/table cells) becomes one `SearchTextUnit`.
  Per unit it builds `plainText` by concatenating `String(text.characters)` for text
  segments and `InlineComposer.fallbackText(atom)` for atoms, and a **gap-free
  `parts` offset map** in Character units keyed by the *segment index into the same
  array the view renders* (word-chunk splits included). Whitespace-only units are
  dropped.
  **Cost: O(N + T) time; O(T) extra space** — the index holds a *second full copy*
  of every searchable character as `plainText`. The space is essential to the
  offset-mapping design but is a real memory cost (roughly doubles the resident
  text of the document).
- **Expand bodies:** `Kind.expand` carries *unprepared* `[ADFNode]`; the indexer
  re-runs `DocumentPreparer(theme:).prepare(...)` on a synthetic doc to flatten it,
  so IDs and segment shapes match what `ExpandBlockView` later renders. This is a
  **second preparation pass** of every expand subtree (the view prepares it again on
  first open) — added work O(expand-subtree), but off-main and once, and it is what
  makes matches inside *collapsed* expands findable and paintable at all.
- **Matching** (`SearchMatcher.matchRanges`): a
  `String.range(of:options:[.caseInsensitive, .diacriticInsensitive])` loop per
  unit, advancing `searchStart` and carrying a running Character `startOffset` so
  each index conversion is a short local `distance(...)` rather than a scan from the
  string's start. Returns Character ranges **in the original text**, so
  case/diacritic folds that change UTF-8/UTF-16 (or even grapheme) lengths never
  desynchronize the highlight from the source — the offsets always describe the
  source, not the query. **Worst case O(T·Q)** with a large ICU constant (diacritic
  folding normalizes).
- **Span slicing** (`SearchMatcher.spans`): maps one match range through `parts`
  into per-segment local Character ranges plus covered atom IDs. **O(S) per match.**

### 2.2 Where the work runs / amortization

Indexing and matching run **off the main actor**. Per streamed 50-block chunk,
`indexAppended` chains a `Task` that awaits the previous link, then does the
extraction in `Task.detached(priority: .userInitiated)`. Scanning (`drainScan`)
runs on the main actor but performs the actual matching detached per **256-unit
batch**, hopping back to main between batches to publish `matchCount`/`highlights`
— this is the "streamed counts" surface. Indexing is incremental: new chunks are
indexed and scanned as the document loads, so the count climbs live.

### 2.3 Worst-case hot spots and what bounds them

1. **Per-batch main-actor cost in `appendMatches`.** For every match it recomputes
   `spans(...)` (O(S)) on the main thread, and then rebuilds
   `ADFSearchHighlights(spansByOwner: baseSpans, …)`. Because the
   previously-published `highlights` still references `baseSpans`' storage, the next
   in-place `baseSpans[...].append` triggers Swift **copy-on-write of the whole
   growing spans dictionary**. Across a scan this is worst-case
   **O(M × number-of-batches)** dictionary-copy work on the main actor, plus O(M·S)
   span slicing. Bounded because it only happens *during* an active scan/load, never
   during idle scroll, and matching itself is detached; but for a common query over
   a large corpus (the verification record cites a 73,399-match stress query) it is
   the single largest main-thread cost this feature adds. A publication throttle or
   COW-friendly accumulation would cut it.
2. **`range(of:)` with diacritic folding** is materially slower than a byte compare;
   total O(T·Q). Bounded by detached execution + batching.
3. **Double preparation of expand bodies.** Bounded (once, off-main).

### 2.4 Essential vs accidental complexity

- *Essential:* extracting searchable text, an offset map, and
  case/diacritic-insensitive matching with source-aligned offsets.
- *Accidental (justified):* the second `plainText` copy and the `parts` map exist
  only because highlights must be painted back onto the *exact* pre-split segment
  array the renderer uses — a consequence of the "no string work in `body`" doctrine
  (the renderer cannot re-derive offsets cheaply); word-chunk-aware indexing exists
  because `InlineComposer.splitForWrappingLayout` pre-splits atom-bearing
  paragraphs; expand re-preparation exists because expand bodies are stored
  unprepared (§5.1 of the renderer design).
- *Accidental (avoidable):* the per-batch full-dictionary rebuild (§2.3, item 1).

### 2.5 Maintainability grade: **B+**

The three types are small, pure, `Sendable`, and unit-tested with
gap-free-coverage assertions. What a maintainer must internalize:

1. **The segment index in `SearchTextUnit.Part` is an index into the identical
   `[InlineSegment]` array the leaf view renders.** If preparation ever changes how
   it splits or merges segments (e.g. a new merge rule), the indexer and the painter
   must move together or highlights land on the wrong characters.
2. Offsets are grapheme offsets everywhere, on purpose.

---

## 3. Pipeline 2 — Highlighting matches in the UI

Files: `Sources/ADFRendering/Search/{ADFSearchHighlights,SearchHighlightPainter,SearchArrivalFlash}.swift`;
changes in `SegmentedTextView.swift`, `CodeBlockView.swift`.

### 3.1 Data structures & algorithms

`ADFSearchHighlights` is one `Equatable`/`Sendable` value:
`spansByOwner: [String: [SearchHighlightSpan]]`, `matchedAtomIDs: Set<String>`, and
an optional `Current` (owner + spans + atom IDs + `generation`). It is injected once
via the `\.adfDocumentSearch` environment key — the *reference* never changes, so
the document view never re-evaluates.

**Per-leaf zero-work gate.** `SegmentedTextView.displayedSegments` and
`CodeBlockView.displayedCode` short-circuit on
`guard let ownerID, let search, search.isActive else { return … }` — with no active
session the leaf reads exactly **one observable Bool** (`isActive`, which flips at
most twice per search session) and never touches `highlights`. This is the
load-bearing invariant that keeps idle scrolling free.

**Painting** (`SearchHighlightPainter`) only runs when the owner has spans. It
copies just the affected `.text` segments and sets `BackgroundColorAttribute`
(subtle for all matches; `searchCurrentHighlight` plus a forced
`searchCurrentForeground` for the current match; the subtle color when
`dimCurrent`), sorted so the current-match accent wins on overlap. Atom pills
cannot hold ranged attributes, so a matched atom tints whole via an
`AtomHighlightState` background in `InlineTokenView`.
**Cost per painted leaf ≈ O(edits × segment length)** because
`AttributedString.characters.index(offsetBy:)` is linear and re-derived per edit;
for prose word-chunks (≈1 edit each) this is trivial, but a single visible **code
block with many matches** is worst-case quadratic in the code's length — bounded
only by "it's on screen."

**Flash.** `SearchArrivalFlash` attaches `.task(id: Trigger)` **only on the current
match's owner**, toggling `dimmed` false→true→false in 130 ms steps (one blink;
steady accent under Reduce Motion). Because attributes cannot animate, the blink is
a discrete token swap. It works "on arrival" because the `.task` fires when the row
materializes after the scroll lands.

### 3.2 Invalidation granularity

`highlights` is a single observable value, so any materialized leaf that passed the
`isActive` gate re-evaluates when it changes (per scan batch, and on every
navigation). This is **bounded by V** (the render region) — off-region rows are
height-only spacers with no reading views. Note it is slightly broader than the
architecture doc implies: *every* materialized leaf in an active session re-reads
`highlights` (registering a dependency) before the emptiness check, so unmatched
visible leaves also re-evaluate on each batch/navigation — but each does only an
O(1) dictionary miss and returns the stored segments unchanged.

### 3.3 Essential vs accidental complexity

- *Essential:* apply background attributes to matched ranges at render time.
- *Accidental (justified by doctrine):* the whole zero-work-gate apparatus, the
  single-payload environment value, the separate coarse `isActive` Bool, and the
  flash living *inside* the modifier body — all exist to satisfy "no high-frequency
  observable state at document level" and to avoid re-evaluating the document view.
  The §18 performance post-mortem shows how unforgiving this is: a naive
  `if #available` around the visibility feed (Pipeline 3) cost a **23× idle-scroll
  regression** (146.7 ms/s vs ~6 ms/s baseline) before it was root-caused.

### 3.4 Maintainability grade: **B**

The gates are correct but subtle, and the correctness of "which observable does a
leaf touch when idle" is spread across four files with long explanatory comments.
A maintainer must understand:

1. The `isActive` Bool is the idle firewall — reading `highlights` unconditionally
   would reintroduce document-wide churn.
2. The flash's conditional `.task` lives inside the `ViewModifier` body
   deliberately (keeping the leaf's *outer* type unary for the lazy stack), and as a
   side effect flips `_ConditionalContent` branches on the one or two involved
   leaves per navigation — measured harmless but structurally load-bearing.

---

## 4. Pipeline 3 — Finding (navigating to) matches in the UI

Files: `ADFDocumentSearch.navigate` / `initialSelectionIndex`;
`ADFScrollTargetPlacement.swift`; `VisibleRowRegistry.swift` +
`ScrollVisibilityReporter`; `ADFDocumentView.swift` (`rows`/`stack`,
`ScrollTargetConsumer`); `ExpandBlockView.swift`; the model's
`expandedBlocks`/`anchors`.

### 4.1 Algorithms

- Match → row mapping is a precomputed `blockOrder: [String: Int]` dictionary
  giving each top-level block/slice a document-order index in **O(1)**.
- `next`/`previous` are modular arithmetic over `matches.count`.
- Auto-select (`initialSelectionIndex`) is **O(M)**: the first match whose
  `topLevelBlockID` order ≥ the top-visible row's order (browser behavior), read
  from the model-owned `ScrollAnchorRegistry` with **no geometry reads**.
- `navigate`: recompute the current match's spans, bump `generation`, publish
  `highlights.current`; union the match's `expandAncestorIDs` into
  `model.expandedBlocks` (O(D)); if not expanding and
  `VisibleRowRegistry.isVisible(target)` → **return without scrolling**
  (restyle + flash only); else choose `.nearTop`/`.nearBottom` from the
  target-vs-top-row order comparison and set `scrollTargetPlacement` **before**
  `scrollTarget` (the consumer observes only the latter).

### 4.2 Where the work runs / bounds

All main-actor, all O(1)/O(M) dictionary and set work — no per-row geometry.
Visibility is fed by `onScrollVisibilityChange(threshold: 0.95)` into a **plain,
non-observable** `VisibleRowRegistry` (writes invalidate nothing) on iOS 18 /
macOS 15; earlier OSes report nothing, so `isVisible` is always false and
navigation always scrolls (graceful degradation). The viewport height for the
margin→`UnitPoint` conversion is measured on the **scroll view's own frame** in
`ScrollTargetConsumer`, never inside a lazy row; `ADFScrollTargetPlacement.anchor`
clamps the margin to ≤40% of the viewport and degrades to the plain edge at zero
height.

### 4.3 Where the real complexity lives

**In view *shape*, not algorithms.** The availability decision for the visibility
feed is hoisted **above** the `LazyVStack` (`rows` → generic `stack(reporter:)`),
so exactly one `AnyView` is created for the whole stack and each row keeps a
stable, conditional-free type. The commit history is explicit that putting
`if #available` at the per-row position — even inside a per-row `ViewModifier`
body — compiles to `buildLimitedAvailability` / `AnyView`, destroys the lazy
stack's unary-item caching, and regressed idle scroll 23×.

The collapsed-expand reveal is a two-step dance: set `expandedBlocks`
(`ExpandBlockView` reads it from the model, not `@State`, so it survives
spacer-collapse), which triggers off-main body preparation, then *always* scroll
(the expand needs a layout pass to reveal the body).

Documented v1 limits: block-granular scrolling (a match line inside a
taller-than-viewport block may need a manual nudge), no horizontal auto-scroll in
wide tables/code, and `scrollTarget` addresses the expand block itself rather than
the inner match.

### 4.4 Maintainability grade: **B−** (the trickiest pipeline)

A maintainer must understand:

1. The **`#available`-at-per-row-position landmine** — the single most expensive
   lesson in this branch, now guarded by comments in three places.
2. `scrollTargetPlacement` must be set before `scrollTarget`, because the consumer
   observes only the latter.
3. Expansion state and the scroll anchor both live on the *model* specifically so
   navigation and spacer-collapse don't fight over view `@State`.

---

## 5. Cross-cutting: essential vs accidental complexity, and maintainability verdict

The *essential* feature is modest: extract text, match, paint, scroll. Nearly all
of the ~1,300 non-test lines are **accidental complexity forced by ADFKit's
pre-existing performance doctrine** — the value-type pipeline, the flat lazy list,
"views never compute," no high-frequency observable state at the document level,
no per-row geometry. Concretely, that doctrine dictates:

- the duplicated `plainText` + `parts` offset map (Pipeline 1),
- the `isActive` firewall + single-payload environment + leaf-only painting
  (Pipeline 2),
- the non-observable registries + availability-hoisting (Pipeline 3).

This is *appropriate* accidental complexity — it is the cost of not regressing a
120 Hz reader — and the branch pays it deliberately, with measurements (idle
hitch gate 1.05 / 0.98 ms/s post-fix vs a same-day baseline of 1.39–3.13 ms/s;
the visibility feed attached to all 5,000 rows measured at 0.65 ms/s; fling-CPU
settles ≈0 even with a 73k-match query active). The one place accidental
complexity looks avoidable is the per-batch `highlights`/`baseSpans` rebuild
(§2.3, item 1). Everything else is well-contained.

**Overall maintainability: B / B+.** The code is unusually well-commented (the
comments *are* the design rationale and are worth keeping), small per file, and
pinned by 39 targeted tests. The risk is not any single file but the number of
**cross-file invariants that are invisible to the compiler**:

1. segment-index alignment between indexer and painter,
2. "which observable does an idle leaf read,"
3. "set placement before target,"
4. "never branch on `#available` per row."

A future maintainer who violates any one of these gets either wrong highlights or
a silent 20×+ scroll regression that the autoscroll gate won't catch (only the
fling-CPU check will). These are documented, but they are landmines.

---

## 6. Independent review findings

### 6.1 Strengths

- **Concurrency is genuinely sound.** Indexing/matching are detached over
  `Sendable` values; publishing is main-actor; the epoch guard (`indexEpoch`)
  makes stale index-chain links from a replaced document inert even though only
  the newest link is cancelled — with a dedicated test
  (`reloadMidStreamLeaksNothing`) exercising exactly the reload-mid-stream race.
  `activeScanQuery` cleanly prevents one scan from mixing two queries and prevents
  a still-debouncing query from being scanned early. No data races; the weak model
  reference breaks the retain cycle.
- **The offset design is correct and robust.** Doing all offsets in Character
  space, and always measuring distances in the *source* text, means
  case/diacritic folding (different UTF/grapheme lengths) cannot desynchronize a
  highlight — verified by the folded-matching tests. This is the subtle thing most
  implementations get wrong; this one gets it right.
- **The zero-work idle gate is real and measured.** `isActive` as a single coarse
  Bool, plus leaf-only painting, plus the availability decision hoisted above the
  lazy stack, is a coherent story backed by the documented 23× regression
  post-mortem. The fix is correct and the rationale is preserved as
  executable-adjacent comments.
- **Test quality is high.** 39 new tests pin the right invariants: gap-free offset
  maps across every container kind and the kitchen-sink fixture;
  folded/overlapping/atom-straddling matches; document-order and both-direction
  wraparound; nested→top-level and table-slice ID mapping; streamed counts to the
  full total; reload-mid-stream leak-freedom; placement clamping and zero-height
  degradation. All 151 tests pass in ~0.3 s.
- **The API surface is mostly clean** — one controller on `model.search`, thin
  observable metadata, and a ~70-line demo `SearchBar` proving the embedder API.

### 6.2 Important (should fix before merge)

- **Auto-select is silently skipped when the first match streams in after the
  initial scan pass.** `drainScan(autoSelect:)` only auto-selects on the first
  scan; every subsequent resume from `scanAppendedUnitsIfNeeded` passes `false`.
  If the initial drain finishes with zero matches (the query term lives only in
  not-yet-indexed tail blocks at that instant), later batches append matches but
  `currentIndex` stays `nil` forever. Result: the demo counter reads "1 / N"
  (because it renders `(currentIndex ?? 0) + 1`) while nothing is actually
  selected, accent-highlighted, or scrolled to — until the user manually taps
  Next. This violates the stated "browser behavior: the first match at/after the
  viewport becomes current." Reproduce by loading a large document and immediately
  searching a term that first appears past the first ~50 blocks.
  **Fix:** have the scan perform auto-select whenever
  `currentIndex == nil && !matches.isEmpty` — e.g. carry a `pendingAutoSelect`
  flag rather than a per-call parameter.

### 6.3 Minor

1. **Per-batch `highlights` rebuild copies the whole spans dictionary** (COW;
   see §2.3). Off the idle path, but the largest main-thread cost the feature
   adds; consider throttling `highlights` publication during an in-flight scan or
   accumulating into a copy-friendly structure.
2. **The painter is quadratic for a many-match code block.** `apply` re-derives
   the characters view and does an O(offset) `index(offsetBy:)` per edit, so a
   single *visible* code block with k matches over length L is O(k·L).
   Precomputing indices in one forward pass would remove it.
3. **`locale: nil` vs the design doc's "current locale".** The matcher passes
   `locale: nil` (non-locale-aware folding; changes Turkish-I behavior); the spec
   says current-locale. Harmless, but the doc and code disagree — pick one
   intentionally.
4. **`dimmed` can be left `true` if the flash task is cancelled during its second
   sleep.** Benign in practice (a leaf that is no longer the current owner paints
   with empty current spans, so the dim flag is unobserved, and a fresh flash
   resets it first), but a `defer`-reset would harden the latent stuck state.
5. **`nearBottom` is chosen when the target *is* the top row but fails the 0.95
   visibility threshold**, pushing it toward the far edge rather than nudging it
   up. Narrow edge case; the visibility gate usually returns early for the
   anchored top row.
6. **Broad public API surface in ADFPreparation.** `SearchIndexer`,
   `SearchMatcher`, `SearchTextUnit`, `SearchMatch`, `SearchHighlightSpan` are all
   `public` but only need to be visible to the sibling ADFRendering target.
   Swift's `package` access level would keep them out of ADFKit's public surface
   while still crossing the target boundary — worth doing before this ships as a
   stable API.
7. **Streaming counter cosmetics:** while a scan is settling with
   `currentIndex == nil` but `matchCount > 0`, the demo shows "1 / N". Cosmetic;
   same root cause as the Important issue above.

---

## 7. Measured performance record (for reference)

| Measurement (Debug simulator, stress-5k unless noted) | Value |
| --- | --- |
| Idle-scroll hitch gate, branch (post-fix, two runs) | 1.05 / 0.98 ms/s |
| Idle-scroll hitch gate, same-day baseline re-measure | 1.39–3.13 ms/s |
| Regression before the availability-hoisting fix | 146.7–157.2 ms/s (~23×) |
| Visibility feed attached live to all 5,000 rows | 0.65 ms/s |
| Fling-CPU settle, idle / with 73,399-match query | ≈0.0% / 0.2% |
| Full unit suite | 151 tests in ~0.3 s |
