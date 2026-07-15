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
| `media` | Aspect-ratio bound — grows **taller** as it widens, until its width cap (media never upscales past its explicit or intrinsic pixel width) | shorter |
| `mediaStrip`, `codeBlock`, `tableSlice`, `divider`, `card` | Scrolls horizontally / fixed — height **unchanged** | shorter |
| `richText`, `listRows`, `panel`, `quote`, … | Reflows — height falls as width rises | ✓ |

So every rotation resized the off-screen spacers wrongly, which corrupts the scroll view's content height. **That is the phantom blank space.**

**Fix:** `CollapsedRowHeight`.

- **Remember, don't derive.** Heights are memoised **per container width**. Rotating to landscape and back replays the *exact* portrait height rather than a heuristic's guess at it. The set of widths a document is ever laid out at is small (portrait, landscape, a Split View fraction), so the memo stays tiny; it is bounded at 6 samples because dragging an iPad Split View divider lays the document out at a continuum of widths.
- **Only estimate a width never seen before**, and estimate it **per block kind** using the table above.

The estimate remains provisional either way: the exact height is re-measured when the row naturally re-enters the render region.

Three refinements came out of review (all `CollapsedRowHeightTests`-covered):

- **Record width and height from the same geometry read.** Keying the record by the document-level `containerWidth` property filed it under a *stale* width: the stack's width observation commits its `@State` write one update pass after layout, so during a rotation every live row recorded its new-width height under the old-width key — overwriting the exact sample the memo exists to replay (and the poisoned entry is authoritative, because exact matches bypass estimation). At first materialization the property is still zero, so those records were silently dropped and first-screen rows could never collapse. The row now observes its own `CGSize` on a full-width wrapper, so the key is the width the row was actually laid out at, atomically.
- **`mediaStrip` is `invariant`, not `proportional`** — it is a horizontally scrolling strip of fixed-height thumbnails; classifying it aspect-ratio-bound inflated every collapsed strip by the width ratio on rotation.
- **`media`'s proportional estimate clamps at the box's width cap** (explicit pixel width, else intrinsic width — media never upscales). Without the clamp, a small image's spacer kept growing with the column: a 300 pt-wide image measured in a 400 pt column was estimated 75% too tall in a 700 pt column.

All gates re-ran clean after the refinements (fling-settle CPU 0.0%; autoscroll 7.5–9.7 ms/s across three runs vs 8.4 same-day baseline; media-gallery and kitchen-sink rotation round trips keep the reader's place with no trailing blank space). Rotation is now scriptable without the Simulator UI: `xcrun simctl spawn <udid> notifyutil -p com.connie.adfreader.rotate` (see `RotationHook` in the demo app) — the Device menu path needs a focused device window, which a shared/headless Mac cannot guarantee.

### 3. Nothing re-anchored the scroll view

A `ScrollView` retains its content **offset** across a resize. But at a new width the rows above the reader have reflowed to different heights, so the same offset lands on different content. **That is the lost position.** No amount of fixing (1) and (2) addresses it — even with perfectly correct heights, an offset is the wrong thing to preserve.

**Fix:** anchor on a row **identity** instead — `scrollPosition(id:)`, bound to a plain reference type. See ADR §8b.

`scrollPosition(id:)` was originally rejected in §8 because binding it to `@State` writes the top-visible ID back once per row crossed, for the whole of every scroll, re-evaluating the document view (and reconciling every materialized row) each time. That objection is about the **binding's storage**, not the API. Backing it with a non-`@Observable` class keeps the behaviour and costs nothing: SwiftUI still writes on every row crossed, and a write to a reference type invalidates no views.

> **Follow-up (see "Drift over repeated rotations" below): the binding by itself does not re-anchor on a resize.** `scrollPosition(id:)` only re-pins when its bound *value changes*, and the top-row ID does not change during a rotation. The identity has to be re-asserted explicitly on every width change; without that, this fix silently degrades back to preserving the offset.

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

## Drift over repeated rotations (follow-up)

**Status:** fixed.
**Touches:** `Sources/ADFRendering/ADFDocumentView.swift`.
**Symptom:** on a long document, rotating portrait↔landscape *repeatedly* walks the reader's place forward a fraction of a screen each cycle; after a handful of round trips it has drifted well away (reported from a stress-5k recording, Expand 45 / Section 50 region).

### Root cause

Fix (3) above assumed `scrollPosition(id:)` re-anchors the bound row on *any* resize. It doesn't — **it only re-anchors when the bound value *changes*.** SwiftUI writes the top-visible ID to the binding only during a scroll *gesture*; across a rotation the top row's ID is unchanged, so SwiftUI never re-pins and falls back to preserving the raw content **offset** — the very thing (3) set out to avoid.

Confirmed by instrumentation: over six rotations the anchor binding is written **zero** times and the ID stays frozen, yet the content at the viewport top marches forward each cycle. Because the ID isn't re-pinned, the retained offset lands on reflowed content at the new width; the collapsed-row height *estimates* above the viewport don't round-trip portrait↔landscape, so the mismatch **compounds every cycle**. (The original verification missed it: the kitchen-sink round trip is one cycle of a short document, where no rows collapse and reflow is exact, so the offset happens to map back.)

### Fix

Re-assert the anchor by identity whenever the content column changes width:

```swift
.onChange(of: containerWidth) {
    guard let anchor = anchors.topRow else { return }
    // Snap, don't slide — the width change may carry the rotation's
    // animation transaction, and a re-anchor should be instantaneous.
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) { proxy.scrollTo(anchor, anchor: .top) }
}
```

`scrollTo` re-derives the offset from the row identity — summing the *current* heights of the rows before the anchor — so it restores the reader's row no matter how those heights changed: rotation reflow, **or an Expand opened while rotated**, or a Split View reflow. Anchoring by identity (not a saved offset) is exactly what makes it robust to a content-height change between orientations.

It fires only on a width change; a plain scroll gesture never changes the column width, so it stays off the §8 hitch path and touches no per-row geometry. (Rotating *mid-fling* does change width during a scroll — the one exception — and re-anchoring by identity is the right thing there too.)

**The re-pin only works if `anchors.topRow` is truthful, and `scrollPosition(id:)` keeps it truthful only for scroll *gestures*.** A programmatic `proxy.scrollTo` (the TOC jump in `ScrollTargetConsumer`, `-scrollToFraction`) does *not* write the binding, so after a jump the registry still names the *pre-jump* top row. Left alone, the very next rotation would re-assert that stale row and teleport the reader back to where they were before the jump — a regression far worse than the drift. So every programmatic scroll must also set `anchors.topRow` to its target (the jump uses `anchor: .top`, so the target *is* the new top row). This is a free write — the registry is a plain reference type (§8b) — but it is mandatory, not optional; a new jump entry point that forgets it reintroduces the teleport.

**Caller contract:** `ADFDocumentView` keeps the anchor in `@State`, keyed to the view's identity. Block ids are structural paths (`"0.5"`) that are stable within a document but *collide across documents*, so a host that swaps `model` while holding the view's identity constant carries a stale `topRow` into the new document. Give the reader a fresh identity per document (a new `ReaderView` per navigation, or `.id(document)`); the demo does this already.

### Verification

| Check | Result |
|---|---|
| stress-5k, 8 portrait↔landscape cycles | Portrait frames **1–8 pixel-identical** (mean diff ≤ 0.02); drift eliminated |
| TOC jump, then rotate (gesture-scrolled first, so the pre-jump anchor is non-nil) | Position **held at the jump target** (mean diff 0.16); no teleport back |
| Expand a block, then rotate round trip | Position **retained** to within the sub-row residual (~28 px here), expanded content intact |
| kitchen-sink (short doc), 3 round trips | No regression (mean diff 0.21) |
| Fling burst on stress-5k, **instantaneous** idle CPU | **0.0%** — re-pin does not reintroduce the livelock |
| `swift test` | 112 tests pass |

**Known residuals (not addressed).** Both are one-time, bounded, non-accumulating, and share one root: `anchor: .top` can only align a row's *edge* to the viewport, so it can't represent an arbitrary sub-row position. Fixing either needs a one-shot content-offset read at rotation (`onScrollGeometryChange`), never a continuous per-row geometry read (that livelocks — see below).

1. **Tall top row.** If the top-visible row is tall and you rotate while scrolled into its middle, the first rotation snaps that row's top to the viewport top — a **≤ one-row** reposition.
2. **Bottom-clamped jump.** `scrollTo(target, .top)` clamps when `target` is within one viewport of the document end, so `target` lands mid-viewport rather than at top; the anchor is then recorded a little high. Because the landscape viewport is *shorter* than portrait, a target that clamps in one orientation may reach the top in the other, giving a **≤ one-viewport** forward reposition on the first rotation after a jump into the last screen. (Still strictly better than the pre-fix behaviour, which re-asserted the *pre-jump* row and teleported the reader clear across the document.)

**Perf-gate note:** `ps -o %cpu=` is a lifetime-weighted average and reads ~10% right after a launch-parse + fling burst even when idle; it is *not* the instantaneous figure the gate wants. Confirm settle with `top -l 2 -pid <pid> -stats cpu` (reads 0.0 when truly idle) rather than trusting the `ps` average.

## Simulator automation gotcha

`Rotate Left` / `Rotate Right` act on the **frontmost Simulator device window**. With several simulators booted, `AXRaise` the target window by name first or you will silently rotate someone else's device (and your own test will read as "rotation had no effect").

Two more traps hit while reproducing this:

- **Rotation needs settle time between toggles.** `RotationHook.toggle` reads `scene.interfaceOrientation` to decide which way to go; fire the next `notifyutil` before the geometry update lands and it reads the stale orientation and no-ops. At ~1.2 s between toggles the cycle desynced (ended landscape); ~2.2 s is reliable. A desync looks exactly like the bug — verify orientation from the `ROTATION requested=…` console line, not by counting toggles.
- **`axe` taps use portrait-fixed coordinates.** `axe describe-ui` / `axe tap` do not map into a rotated orientation, so tapping a control *while the device is landscape* lands in the wrong place. Drive taps (expand a block, hit the TOC) in **portrait**; use the rotation hook only to change orientation.
