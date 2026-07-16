# Horizontal Search Reveal Plan

## Status

Proposed follow-up to the incremental find-in-page implementation.

## Problem

Find-in-page navigation scrolls to the containing top-level document row, but
the current highlighted match can remain outside the horizontal viewport in a
long code line or a wide table.

The search result currently carries an owner ID, top-level block ID, expand
ancestors, and character ranges. It does not carry table/cell/column context or
rendered horizontal geometry. Code blocks render one attributed `Text` inside a
horizontal `ScrollView`; table slices use separate horizontal scroll views with
shared numeric offsets on iOS 18 and later.

## Desired Behavior

When Next, Previous, or initial selection changes the current match:

1. Expand any collapsed ancestors and complete the existing vertical reveal.
2. Reveal the current highlighted range horizontally with a small margin.
3. Apply the minimum horizontal movement and do nothing when the match is
   already visible.
4. Trigger only for the current match, never for every base highlight.
5. Defer programmatic movement while the user is actively dragging, then honor
   the latest request.
6. Preserve synchronized table header/body offsets where synchronization is
   supported.
7. Continue to work after incremental document updates, Dynamic Type changes,
   and rotation.

## Existing Constraints

- `ADFDocumentSearch.navigate` publishes the current paint payload before it
  decides whether vertical scrolling is necessary. Horizontal reveal must
  therefore react to the current generation independently of the vertical
  visible-row early return.
- `SearchTextUnit` has no horizontal-container metadata.
- `Text(AttributedString)` does not expose a stable child view for an arbitrary
  substring, so code reveal requires text geometry rather than a normal
  `ScrollViewReader` ID.
- Table column widths are resolved in the view from document attributes,
  viewport width, Dynamic Type, and the optional number gutter. The index can
  retain structural column information, but not a final pixel offset.
- Table slices synchronize numeric content offsets through `TableScrollSync`
  on iOS 18 and later. The iOS 17 fallback currently scrolls slices
  independently.

## Proposed Architecture

### Search Context

Extend `SearchTextUnit` with an optional horizontal context:

```swift
public enum SearchHorizontalContext: Sendable, Hashable {
    case code
    case table(
        tableID: String,
        cellID: String,
        startColumn: Int,
        columnSpan: Int
    )
}
```

`SearchIndexer` threads table context while descending through a cell. It does
not compute pixel geometry. Incremental index replacement remains item-local.

### Reveal Request

Publish a generation-scoped request when the current result changes. The
request contains the owner, current text spans or atom IDs, structural
horizontal context, and navigation generation. Leaves consume a generation at
most once.

The request must remain valid across the two-step collapsed-expand path:

1. publish current highlight and expansion state;
2. materialize and vertically reveal the row;
3. resolve local horizontal geometry;
4. minimally adjust the horizontal offset.

A newer navigation generation supersedes any pending request. A stale request
must never move a scroll view after the user has navigated elsewhere.

### Code Blocks

For the current code owner:

1. Convert the current character range into the attributed substring range.
2. Resolve the horizontal bounds with the same font and attributed runs used
   by the displayed code.
3. Compare those bounds with the visible content interval, including a 16-24
   point margin.
4. Scroll only by the amount needed to include the bounds, clamped to the
   content extent.

The measurement must handle tabs, Unicode grapheme clusters, Dynamic Type, and
multiline code. A match spanning lines uses the union needed to expose its
start and end where possible; if the range is wider than the viewport, align
its leading edge in left-to-right layout and trailing edge in right-to-left
layout.

The implementation should retain the current selectable SwiftUI text behavior.
A UIKit/AppKit text-layout helper is acceptable for measurement, but it should
not replace the rendered view unless measurement parity cannot be achieved.

### Tables

`SearchIndexer` records the table ID, cell ID, starting column, and colspan.
`TableSliceScrollView` resolves the same column widths it uses for layout and
builds a prefix-width array. Cell bounds then require two prefix lookups plus
the optional number gutter.

`TableScrollSync` gains a programmatic reveal operation that:

1. receives the cell bounds, viewport width, margin, and generation;
2. calculates the minimal clamped target offset;
3. records the shared offset for the table;
4. lets every visible iOS 18+ slice follow through its existing
   `ScrollPosition` binding.

For iOS 17, the matched slice uses a stable cell/column anchor through
`ScrollViewReader`. Cross-slice synchronization remains at the current platform
floor unless a separate UIKit scroll bridge is added.

If a cell is itself wider than the viewport, cell reveal is followed by local
text-range geometry. This is necessary for a strict guarantee that the actual
highlight, rather than only its containing cell, is visible.

### Interaction Rules

- Do not issue a horizontal scroll when the target plus margin already
  intersects the visible interval.
- Do not interrupt an active user drag or deceleration. Retain only the latest
  reveal generation and apply it when the scroll phase becomes idle.
- A user-driven table offset remains authoritative until navigation requests a
  different current result.
- Rotation and Dynamic Type invalidate resolved widths. Re-evaluate the current
  reveal after layout settles without changing the search selection.
- Clear pending requests when search closes or the current owner disappears
  after a document mutation.

## Complexity Targets

Let:

- `N` be the document searchable character count;
- `C` be the number of columns in the target table;
- `L` be the character count of the current code or rich-text owner.

The existing search matching complexity does not change.

- Build table prefix widths: `O(C)` per resolved table layout.
- Reveal a table cell after prefix construction: `O(1)` per navigation.
- Resolve code/rich-text range geometry: `O(L)` for the current owner only.
- Additional retained state: `O(C)` per active table layout plus `O(1)` for the
  current reveal request.
- Navigation must not add a document-wide `O(N)` scan.

## Delivery Estimate

| Scope | Engineering effort |
| --- | ---: |
| Containing-cell reveal on iOS 18+ | 2-3 days |
| Exact code reveal plus table reveal on iOS 17/18 | 4-6 days |
| Exact glyph reveal in arbitrary unusually wide rich-text cells and atoms | 6-9 days total |

The recommended first delivery is the 4-6 day scope. It guarantees long-code
visibility, handles normal table cells exactly, retains iOS 17 behavior, and
leaves only the unusually wide rich-text-cell geometry as an explicit extension
if fixtures demonstrate that it is needed.

## Acceptance Criteria

- [ ] A match near the end of a long code line becomes fully visible with the
      configured margin.
- [ ] Matches in the first, middle, and last columns of a wide table become
      visible.
- [ ] Colspan and author-provided column widths resolve correctly.
- [ ] Next and Previous scroll only when the new current match is clipped.
- [ ] Table header and visible body slices remain horizontally aligned on iOS
      18 and later.
- [ ] iOS 17 reveals the match in its containing slice without regressing
      existing behavior.
- [ ] Collapsed expands reveal vertically before horizontal positioning.
- [ ] Repeated document updates preserve or restore the current result and
      reveal it.
- [ ] User dragging is not interrupted by stale programmatic requests.
- [ ] Dynamic Type, rotation, Unicode, tabs, multiline matches, and
      right-to-left layout are covered.
- [ ] Idle scrolling remains within the existing performance envelope.

## Test Plan

### Unit Tests

- Index table owners with table ID, start column, and colspan.
- Preserve horizontal context through incremental item replacement.
- Calculate minimal offsets for targets before, inside, and after the viewport.
- Clamp offsets at both content boundaries.
- Validate prefix widths with a number gutter, explicit widths, fallback widths,
  and colspan.
- Supersede stale reveal generations and defer the latest request while
  interaction is active.

### Rendering and Navigation Tests

- Long code line: first, middle, last, Unicode, and tab-adjacent matches.
- Wide table: header, first/middle/last columns, colspan, and sliced rows.
- Next/Previous within one horizontal owner and across different owners.
- Match inside a collapsed expand.
- Active-query document mutation that moves or removes the current match.
- Rotation and representative Dynamic Type sizes.
- iOS 17 fallback and iOS 18+ synchronized paths.

## Measurement Plan

Add deterministic demo automation that selects known long-code and wide-table
matches. For each navigation, record:

- request-to-horizontally-visible latency;
- target and final content offsets;
- whether the current-highlight frame intersects the viewport with margin;
- main-thread time and scroll hitches during repeated Next/Previous navigation;
- idle-scroll and incremental-update benchmark results.

Compare before and after using the same simulator or device, build
configuration, fixture, query, viewport, Dynamic Type size, and run count.
Report medians and p95 values, plus failures to satisfy the visibility
assertion. The expected steady-state table navigation work is constant after
layout prefix construction; code measurement is bounded to the current owner.

## Expected Files

- `Sources/ADFPreparation/Search/SearchIndex.swift`
- `Sources/ADFPreparation/Search/SearchIndexer.swift`
- `Sources/ADFPreparation/Search/IncrementalSearchIndex.swift`
- `Sources/ADFRendering/Search/ADFDocumentSearch.swift`
- `Sources/ADFRendering/Search/SearchOwnerHighlights.swift`
- `Sources/ADFRendering/Blocks/CodeBlockView.swift`
- `Sources/ADFRendering/Blocks/TableSliceView.swift`
- `Sources/ADFRendering/TableScrollSync.swift`
- search/index/rendering tests
- deterministic Demo search automation
