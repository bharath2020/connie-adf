# Per-Document Text Size Control — Design

**Date:** 2026-07-16
**Status:** Approved

## Goal

Let the reader adjust text size per document from a control in the document view. All
text levels (headings, body, code, pills, captions, table text) scale relatively. The
control is independent of the device accessibility (Dynamic Type) setting, scoped to the
document view only — never the whole app or device. Text re-wraps without losing
content, and steady-state frame rate is unaffected.

## Decisions (approved)

1. **Persistence:** per document. Each document remembers its own size, keyed by
   `DocumentSource.storageKey`.
2. **UI:** toolbar text-size item (`textformat.size`) opening a popover with
   `A− | current % | A+` and a Reset row.
3. **Mechanism:** Dynamic Type environment override on the document subtree
   (a per-document *step offset* on the `DynamicTypeSize` ladder). The alternative — a
   point-size-parameterized `ADFTheme` with full re-preparation per change — was
   rejected: fonts are baked into `AttributedString`s at preparation time, so every
   adjustment would cost a full off-main re-prepare, and every `@ScaledMetric` layout
   metric tracks the Dynamic Type environment (not the theme), so markers, table
   minimums, paddings, and sub/superscript offsets would desynchronize.

## Why the override works here

- Every font in ADFKit is a **semantic text style** (`ADFTheme.body = .body`,
  `headingFont(_:)` = `.title`…`.footnote`, `code` = monospaced `.body`) baked per-run
  into `AttributedString`s by `InlineComposer`/`DocumentPreparer`. SwiftUI re-resolves
  semantic fonts at draw time, so an environment `dynamicTypeSize` change rescales all
  text **without re-preparation**.
- Every layout metric (readable width 672, list marker width, table column minimums,
  pill paddings, line spacing, sub/superscript `typeScale`) is `@ScaledMetric`, which
  follows the environment type size — wrapping and spacing stay coherent, and
  `LayoutColumnsView` already stacks columns at accessibility sizes.
- Steps are discrete (the ~12-size `DynamicTypeSize` ladder, roughly 82%–310% of
  default). The stepper UI wants discrete steps anyway.

## Architecture & data flow

```
FontSizeStore (UserDefaults, [storageKey: Int])
   → ReaderView @State fontSizeStep (loaded per document)
   → effective = system dynamicTypeSize shifted by step, clamped to ladder
   → ADFDocumentView.dynamicTypeSize(effective)       ← document subtree only
       → baked semantic fonts re-resolve at draw time
       → @ScaledMetric metrics follow
```

Toolbar, navigation title, and search bar stay at the app's normal size. The device
accessibility setting is never modified; it is the baseline the step shifts from, so the
control composes with it (a user at `xxLarge` gets "+2 relative to *their* normal").

## Components

### ADFKit library (`Sources/ADFRendering`) — robustness fix, no new public API

`ADFDocumentView` reacts to a runtime change of the environment `dynamicTypeSize`:

1. **Invalidate the collapsed-row height cache** (`CollapsedRowHeight`), exactly the way
   the existing `item.revision` reset does: stored samples clear, spacers fall back to
   per-kind estimates, rows re-measure only on natural re-entry. Never mass
   re-materialize rows to re-measure — that is the documented layout-livelock trap
   (Architecture-Decisions §16).
2. **Re-assert the scroll anchor**: `proxy.scrollTo(anchors.topRow, anchor: .top)` with
   animations disabled, mirroring the existing `containerWidth` re-anchor. Needed
   because a type-size change reflows heights without changing width (the only existing
   re-anchor trigger) on iPhone-width layouts.

This also fixes a latent bug: a *system* Dynamic Type change mid-session currently
leaves stale spacer heights and no re-anchor.

### ADFReader app (`Demo/ADFReader`)

- **`FontSizeStore`** — UserDefaults JSON `[storageKey: Int]` under one key, mirroring
  `TaskStateStore` (read at load, write-through on change, decode failure → empty).
- **Pure helpers** — `DynamicTypeSize.shifted(by:)` (index shift on the ladder, clamped
  to bounds) and a step→percentage mapping for the indicator label, computed from
  Apple's body point sizes as `pt(effective) / pt(system baseline)` — step 0 always
  reads 100%, i.e. the percentage is relative to the user's own baseline, not to
  `.large`.
- **`ReaderView`** — fourth `.topBarTrailing` toolbar item (`textformat.size`,
  accessibility label "Text Size") presenting a **popover**
  (`presentationCompactAdaptation(.popover)`), not a `Menu` — menu buttons dismiss on
  every tap, which kills repeated A+ tapping. Contents: `A− | 115% | A+` row plus
  "Reset to 100%". A−/A+ disable when the *effective* size sits at a ladder end;
  Reset disables at step 0. Changes update `@State` and write through to the
  store immediately. The raw step persists unclamped; clamping happens at application
  time, so a saved step stays valid if the device setting later changes.
- **`-fontSizeStep <n>` launch argument** (`LaunchOptions` pattern) so automation and
  perf gates can run at non-default sizes.

## Edge cases

- **Live state survives a size change — no reload occurs.** Search index and highlights
  are character-offset-based (font-independent); expand state and expand-body caches
  stay valid (the theme is unchanged); scroll re-pins to the top visible row.
- Tables with fixed `colwidth` wrap taller and pan horizontally at large sizes; layout
  columns stack at accessibility sizes — both existing, intended behaviors.
- At system `accessibility5`, A+ is disabled (already at ladder top); at `xSmall`, A−.

## Testing & verification

- **Unit tests:** `shifted(by:)` clamping, percentage mapping, `FontSizeStore`
  round-trip.
- **Perf gates (repo protocol):** `swift test`; `-autoscroll` SCROLL_METRICS on
  stress-5k at step 0 **and** step +3, each against a same-day, same-build-type
  baseline (Debug-sim baseline ≈ 10.3 ms/s; the < 5 ms/s budget is Release-only);
  12× axe-swipe fling burst with CPU confirmed settling to ~0.0 via `top -l 2 -pid`
  (catches layout livelocks the autoscroll gate misses).
- **Manual:** size change mid-scroll on stress-5k and giant-table (anchor retention, no
  phantom blank space); rotation after a size change; composition with a non-default
  system Dynamic Type setting.

## Out of scope (YAGNI)

Continuous slider, pinch-to-zoom gesture, `ADFTheme` point-size parameterization,
reader-wide default size, scroll-position persistence.
