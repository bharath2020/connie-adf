# Rotation: losing the reader's place, and phantom blank space

**Status:** fixed on `fix/rotation-scroll-retention`.
**Touches:** `Sources/ADFRendering/ADFDocumentView.swift`, `CollapsedRowHeight.swift`, `ScrollAnchorRegistry.swift`.
**Related:** ADR §8 (far-offscreen rows collapse to spacers), ADR §8b (keeping the reader's place across a resize).

## Problem statement

Reported from a screen recording on iPhone, reading the *Performance Test Report* page of the ADFReader Test Bed. Rotating the device broke the document in two ways:

1. **The scroll position was lost.** The reader was partway down the document; rotating to landscape threw them back near the top.
2. **Phantom blank space.** After rotating back to portrait the document ended early — a large empty region below the last block, with the scroll view still allowing a scroll into the void.

Both reproduce on a simulator, on any document long enough for rows to leave the render region. They are not specific to that page.

## Root cause

One origin: `DocumentRow`, and specifically how a **collapsed row states its height**.

`LazyVStack` never recycles — it keeps every row it has materialized alive — so §8 collapses far-offscreen rows to a `Color.clear` spacer. A collapsed row must therefore report a height *without laying its block out*: re-materializing stale rows en masse after a resize livelocks layout at 100% CPU. So the spacer's height has to be a pure function of what the row remembers.

It remembered the wrong things, in three ways.

### 1. The width being measured was not the width rows lay out in

`containerWidth` was observed *outside* the `readableWidth` cap:

```swift
LazyVStack { … }
    .padding(.horizontal, margin)
    .frame(maxWidth: readableWidth)   // caps the column
    .frame(maxWidth: .infinity)
    .onGeometryChange { $0.size.width } action: { containerWidth = $0 }  // ← reads the *uncapped* width
```

So it reported the scroll view's full width (430 → 814 pt on rotation) rather than the column the rows actually occupy (398 → 609 pt). Every collapsed spacer was then rescaled by a ratio the rows had never been laid out at. Worse, on iPad — where the cap binds in *both* orientations — the column width does not change at all, yet `containerWidth` moved, so spacers were rescaled for no reason whatsoever.

**Fix:** observe the stack itself, before the padding and the cap.

### 2. One height rule was applied to every block kind

A collapsed row scaled its single cached height *inversely* with width:

```swift
return measured.height * measured.containerWidth / containerWidth
```

That model is only right for reflowing text. It is wrong in *slope* for some kinds and wrong in *sign* for others:

| Block kind | How height actually answers a width change | Old rule said |
|---|---|---|
| `media`, `mediaStrip` | Aspect-ratio bound — grows **taller** as it widens | shorter |
| `codeBlock`, `tableSlice`, `divider`, `card` | Scrolls horizontally / fixed — height **unchanged** | shorter |
| `richText`, `listRows`, `panel`, `quote`, … | Reflows — height falls as width rises | ✓ |

So every rotation resized the off-screen spacers wrongly, which corrupts the scroll view's content height. **That is the phantom blank space.**

**Fix:** `CollapsedRowHeight`.

- **Remember, don't derive.** Heights are memoised **per container width**. Rotating to landscape and back replays the *exact* portrait height rather than a heuristic's guess at it. The set of widths a document is ever laid out at is small (portrait, landscape, a Split View fraction), so the memo stays tiny; it is bounded at 6 samples because dragging an iPad Split View divider lays the document out at a continuum of widths.
- **Only estimate a width never seen before**, and estimate it **per block kind** using the table above.

The estimate remains provisional either way: the exact height is re-measured when the row naturally re-enters the render region.

### 3. Nothing re-anchored the scroll view

A `ScrollView` retains its content **offset** across a resize. But at a new width the rows above the reader have reflowed to different heights, so the same offset lands on different content. **That is the lost position.** No amount of fixing (1) and (2) addresses it — even with perfectly correct heights, an offset is the wrong thing to preserve.

**Fix:** anchor on a row **identity** instead — `scrollPosition(id:)`, bound to a plain reference type. See ADR §8b.

`scrollPosition(id:)` was originally rejected in §8 because binding it to `@State` writes the top-visible ID back once per row crossed, for the whole of every scroll, re-evaluating the document view (and reconciling every materialized row) each time. That objection is about the **binding's storage**, not the API. Backing it with a non-`@Observable` class keeps the behaviour and costs nothing: SwiftUI still writes on every row crossed, and a write to a reference type invalidates no views.

## Rejected approach: tracking the top row with per-row geometry

The first attempt at (3) found the top-visible row itself, by reading each live row's position in the scroll view's coordinate space:

```swift
.onGeometryChange(for: RowPosition.self) { proxy in
    RowPosition(minY: proxy.frame(in: .named(scrollSpace)).minY,        // ← do not do this
                viewportWidth: proxy.bounds(of: .named(scrollSpace))?.width ?? 0)
} action: { anchors.report(id: block.id, position: $0) }
```

This **pins the main thread at 100% CPU indefinitely after a fling.** Resolving a named coordinate space from inside a lazy row happens during `LazySubviewPlacements.placeSubviews`, and in a 5,000-row `LazyVStack` the layout never settles. A `sample` of the hung process puts those two lines at the top of the hot path.

Do not put named-coordinate-space geometry reads in lazy rows.

## The perf gate did not catch it

**`-autoscroll` / `SCROLL_METRICS` is not sufficient to clear a scrolling change.** It drives an animated `scrollTo`, not a flick, and it reported a perfectly healthy **8.67 ms/s** for the build that livelocked under a real gesture.

Add a fling-and-watch-CPU check:

```bash
xcrun simctl launch $D com.connie.adfreader -fixture stress-5k
for i in $(seq 1 12); do
  axe swipe --start-x 220 --start-y 800 --end-x 220 --end-y 120 --duration 0.08 --udid $D
done
sleep 3
ps -p $(pgrep -f "ADFReader.app/ADFReader" | head -1) -o %cpu=   # must settle to ~0.0, not 100
```

Also note: **the documented `< 5 ms/s` gate is not reachable in a Debug simulator build.** Unmodified `main` measures ~10.3 ms/s. Always compare against a freshly-measured baseline of the *same* build type rather than against the 1.5 ms/s figure in the ADR, which must come from a release/device run. That discrepancy is worth resolving separately.

## Verification

| Check | Result |
|---|---|
| Fling burst on stress-5k, CPU after settle | **0.0%** (baseline 0.0%; rejected approach 100%) |
| Rotation round trip, kitchen-sink | Content-identical to the pre-rotation frame |
| Performance Test Report, rotate and scroll to bottom | No trailing blank space; ends at the last block |
| TOC jump (`scrollTo`) with `scrollPosition(id:)` bound | Works — the two do not fight over the scroll view |
| `swift test` | 110 tests pass, incl. 9 new `CollapsedRowHeightTests` |
| stress-5k autoscroll | 10.96 ms/s vs 10.29 ms/s on unmodified `main` — no regression |

## Simulator automation gotcha

`Rotate Left` / `Rotate Right` act on the **frontmost Simulator device window**. With several simulators booted, `AXRaise` the target window by name first or you will silently rotate someone else's device (and your own test will read as "rotation had no effect").
