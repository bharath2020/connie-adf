# ADFKit Text Search — Design

Date: 2026-07-14
Status: Approved pending user spec review
Branch: `worktree-adfkit-text-search`

## Goal

Find-in-page for rendered ADF documents: search for text, stream results back with a
running total and current position, navigate matches in both directions with
background highlighting and a flash on arrival, scroll matches into the viewport
with a configurable margin only when they are not already visible, and clear
everything via API. The embedding app (ADFReader demo) surfaces the metadata and
actions through a search bar.

## Decisions (from brainstorming)

| Question | Decision |
| --- | --- |
| Highlight model | All matches get a subtle highlight; current match gets an accent highlight and flashes on navigation |
| Match semantics | Literal substring, case- and diacritic-insensitive (`.caseInsensitive, .diacriticInsensitive`) |
| Collapsed expands | Matches found and counted; navigating auto-expands ancestors, then scrolls and flashes |
| Deliverable | Library API in ADFKit + working search bar in the ADFReader demo |
| Search trigger | Live as-you-type, debounced in the library (default 200 ms) |
| Architecture | Approach A: off-main index/scan, environment-injected highlight map, leaf-applied attributes |
| Auto-select | When results arrive, the first match at/after the current viewport position becomes current (browser behavior) |

## Architecture

Three pieces, matching the repo's layering:

1. **`SearchIndexer` + match types (ADFPreparation)** — pure, `Sendable`, unit-testable.
2. **`ADFDocumentSearch` (ADFRendering)** — `@MainActor @Observable` controller owned by
   `ADFDocumentModel`, exposed as `model.search`.
3. **Highlight application (ADFRendering leaf views)** — environment-injected match map
   consumed by `SegmentedTextView`, `CodeBlockView`, and `AtomView`.

### Public API

```swift
// ADFDocumentModel
public var search: ADFDocumentSearch { get }

@MainActor @Observable
public final class ADFDocumentSearch {
    // Actions
    public func run(_ query: String)   // debounced; restarts the scan
    public func next()                 // wraps last → first
    public func previous()             // wraps first → last
    public func clear()                // clears query, matches, highlights

    // Streamed, observable metadata
    public private(set) var query: String
    public private(set) var matchCount: Int
    public private(set) var currentIndex: Int?   // 0-based document order; nil = none
    public private(set) var isSearching: Bool    // scan in flight

    // Configuration
    public var scrollMargin: CGFloat = 40        // viewport inset when scrolling to a match
    public var debounceInterval: Duration = .milliseconds(200)
}
```

### Search index (ADFPreparation)

`SearchIndexer` walks `[RenderBlock]` recursively and produces one **text unit** per
segment-bearing container:

- `richText` segments, `PreparedListRow.segments` (+ recursive `trailingBlocks`),
  `codeBlock` code, media captions, and nested `[RenderBlock]` inside
  panel / quote / tableSlice cells / layoutColumns / extensionPlaceholder.
- Each unit records `(ownerID, topLevelBlockID, plainText, offsetMap)` where:
  - `ownerID` is the ID keying the highlight lookup at render time (the block/row/cell
    whose segments hold the text).
  - `topLevelBlockID` is the lazy-stack row ID used for scrolling (nested matches map
    up; table matches map to the containing `#rows<n>`/`#header` slice).
  - `plainText` is built exactly like `ADFDocumentModel.plainTitle(of:)`:
    `String(attributed.characters)` for text segments, `fallbackText` for atoms.
  - `offsetMap` translates plain-text character offsets back to
    (segment index, word-chunk index where applicable, `AttributedString` index range),
    handling the conditional word-chunk pre-splitting done when atoms are present.
- **Expand bodies**: `Kind.expand` carries unprepared `[ADFNode]`. The indexer prepares
  them off-main with the existing synchronous `DocumentPreparer.prepare` (same machinery
  the view uses on first expansion, so IDs and segment shapes align). Units inside
  record their expand-ancestor ID chain. Nested expands compose chains.
- The index is **append-only during streaming**: as document chunks arrive
  (`phase == .preparing`), new blocks are indexed incrementally; an active query rescans
  only the new units and the count keeps climbing.
- Placeholder/stray bracketed runs ("[type]") are included as rendered; hard breaks are
  `\n` in plain text (they render that way too).

### Matching

Loop of `String.range(of:options:[.caseInsensitive, .diacriticInsensitive],
range:locale:)` over each unit's `plainText`, current locale. Matches are ordered by
document position (block order, then offset). A match may:

- span multiple text segments/word chunks → highlight painted piecewise via `offsetMap`;
- cover an atom's fallback text → the atom's stable ID is recorded; the whole pill is
  tinted (pills are plain `Text`, not range-highlightable);
- straddle text/atom boundaries → counted once, painted piecewise on the parts.

### ADFDocumentSearch behavior

- `run(_:)` debounces (Task-sleep based; `run` with the same query is a no-op), cancels
  any in-flight scan, then scans the index **off the main actor** (index and blocks are
  `Sendable`), publishing `matchCount`/`isSearching` back to the main actor in chunks —
  the "streamed results" requirement. Empty query ≡ `clear()`.
- On first results, auto-select: the first match whose top-level block index ≥ the
  current `ScrollAnchorRegistry.topRow` block index (wrapping to the document start if
  none), then navigate to it.
- `next()`/`previous()` move `currentIndex` with wraparound and trigger navigation.
- `clear()` cancels the scan, resets all state, and publishes an empty highlight payload
  (leaf views early-return to the zero-cost path).
- Document `load(data:)` resets search state entirely (same as today's scrollTarget
  reset).

### Highlight delivery (environment)

`ADFDocumentView` injects `adfSearchHighlights: ADFSearchHighlights` (Equatable):

```swift
struct ADFSearchHighlights: Equatable {
    var matchesByOwner: [String: [UnitHighlight]]  // ranges/chunk slices per owner ID
    var matchedAtomIDs: Set<String>
    var currentMatch: MatchID?           // owner + range (or atom) of the current match
    var selectionGeneration: Int         // bumped on every navigation → drives flash
}
```

Consumers (leaves only, per the repo's invalidation doctrine):

- **`SegmentedTextView`**: if `matchesByOwner[ownerID]` is nil → return segments
  untouched (no copy, no work — the path every non-matching row takes while scrolling;
  mirrors `scalingBaselineOffsets`' factor==1 early return). Otherwise copy the affected
  `AttributedString`s and set `BackgroundColorAttribute` (+ contrast-derived
  `ForegroundColorAttribute`) over match ranges; the current match uses the accent token.
  The owner ID must therefore reach `SegmentedTextView` (new parameter, defaulted so
  existing call sites without searchable context — e.g. previews — opt out).
- **`CodeBlockView`**: same treatment on its single `AttributedString`.
- **`AtomView`**: whole-pill tint when its atom ID ∈ `matchedAtomIDs`; accent when it is
  the current match.

Highlight colors are two new `ADFTheme` tokens: `searchHighlight` (subtle) and
`searchCurrentHighlight` (accent), scheme-aware, legibility via the existing
`ADFHexColor.contrastingForeground`. Within a match range the search highlight
deliberately overrides author backgrounds / inline-code tint (browser behavior).

**Invalidation containment**: the environment value changes only when results change or
navigation happens — never per keystroke mid-debounce. Off-region rows are spacers
(contain no reading views), so invalidation is bounded to the render region.

### Flash on navigation

The leaf rendering the current match runs `.task(id: selectionGeneration)` pulsing the
current-match background accent → subtle → accent (one blink, ~260 ms) by toggling
the applied token. No geometry, no external timers. If the target row was collapsed far
away, the task runs when the row materializes after the scroll — flash on arrival.
`accessibilityReduceMotion` → steady accent highlight, no pulse.

### Navigation & scrolling

1. Resolve the match's `topLevelBlockID`.
2. If the match is inside collapsed expand(s): mark all ancestor IDs expanded (see
   below), then proceed to scroll.
3. **Visibility check** — new `VisibleRowRegistry` (plain, non-observable class; the
   `ScrollAnchorRegistry` pattern): on iOS 18+/macOS 15+, each `DocumentRow` reports via
   `onScrollVisibilityChange(threshold:)` whether it is genuinely in the viewport.
   Current match's row visible → no scroll; just restyle + flash. iOS 17: registry
   unavailable → always scroll (graceful degradation).
4. **Scroll with margin** — `ADFDocumentModel.scrollTarget` gains an optional anchor:
   `scrollTargetAnchor: UnitPoint?` (default nil ≡ today's `.top`). Direction: compare
   the match's top-level block index with `ScrollAnchorRegistry.topRow`'s index (no
   geometry reads). Match above viewport → anchor `UnitPoint(x: 0, y: margin / viewportHeight)`;
   below → `UnitPoint(x: 0, y: 1 − margin / viewportHeight)`. Viewport height measured
   once at the ScrollView level (safe), never in lazy rows. `ScrollTargetConsumer`
   passes the anchor through to `proxy.scrollTo`.

**Documented granularity limit**: scrolling aligns the match's *block* edge to the
margin. For blocks taller than the viewport the matched line may still need a manual
nudge; per-line geometry is this repo's documented livelock zone, so this is an
accepted v1 tradeoff. Horizontally clipped matches (wide tables/code) highlight but are
not horizontally auto-scrolled in v1.

### Expand state lifting (includes an existing bug fix)

Expansion state moves out of `ExpandBlockView`'s private `@State` into model-owned
state (e.g. `model.expandedBlocks: Set<String>`) flowing through a new environment
value; `ExpandBlockView` reads and writes it. This is independently a bug fix: today an
expand the user opened silently re-collapses when its row scrolls far away (spacer
collapse discards view `@State`) and comes back.

Navigation into a collapsed expand: expand ancestors → the view prepares the body
off-main as it does today → scroll to the expand block with margin anchor → flash when
the match materializes. `scrollTarget` addresses the expand block itself (inner blocks
are not lazy-stack rows) — acceptable, documented.

## Demo integration (ADFReader)

`ReaderView` gets a search toolbar button toggling a bottom, keyboard-adjacent search
bar: `TextField` (live, library-debounced) · `3 / 47` counter (spinner while
`isSearching`, "No matches" state) · up/down chevrons (`previous()`/`next()`) · Done
(`clear()` + dismiss). All wired through `model.search`, proving the embedder API.

## Testing & verification

**Unit tests** (`swift test`, macOS, fast):
- Indexer extraction across every container kind (kitchen-sink + generated fixtures);
  offset-map correctness through word-chunk splitting and atoms.
- Matcher: case/diacritic insensitivity, multi-segment spans, atom fallback matches,
  overlapping-adjacent matches, empty query.
- Navigation: document ordering, wraparound both directions, auto-select from viewport
  position, nested→top-level and table-slice ID mapping.
- Expand-body indexing and ancestor chains; expand state lifting.
- Streaming: append-only index growth, counts updating mid-stream, clear/reload resets.

**Perf gates** (repo doctrine — all against same-build-type fresh baselines):
- `-autoscroll` on stress-5k (`SCROLL_METRICS hitchRatioMsPerS`), with **no active
  query** (early-return path) and with a high-match query active.
- Mandatory fling-and-watch-CPU check (the autoscroll gate misses layout livelocks).
- Rotation round-trip keeps the reader's place.

**Live verification**: drive ADFReader in the simulator (existing axe/automation
harness): search, streamed count, next/prev with flash, margin scrolling, visible-match
no-scroll, collapsed-expand auto-expand navigation, clear.

## Risks & mitigations

| Risk | Mitigation |
| --- | --- |
| Body-time AttributedString work | Zero-cost early return when a block has no matches; ranges precomputed off-main; only affected segments copied |
| Document-view invalidation | Search metadata observed only by the demo toolbar + leaf consumers; highlight payload via environment changed only on results/navigation; high-frequency state in plain classes |
| Identity churn | Block IDs never change; highlights are render-time attribute edits, not model mutations |
| Geometry livelocks | No named-coordinate-space reads; visibility via `onScrollVisibilityChange` (18+) or degrade to always-scroll (17) |
| Highlight collides with author backgrounds / code tint | Theme tokens + `contrastingForeground`; override inside match range is intended |
| Far-jump 200–300 ms materialization stall | Accepted (documented in AutoScroller); one-off per jump |
| Streaming partial documents | Append-only incremental index; counts stream; auto-select re-evaluated when results first arrive |
