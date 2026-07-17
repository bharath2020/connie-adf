# Cross-Block Text Selection — Assessment & Prototype Verdict (2026-07-17)

**Question**: what does it take to support continuous text selection with
native start/end grab points — spanning blocks, like Safari/Notes — in
`ADFDocumentView`?

**Verdict: feasible without abandoning the SwiftUI architecture**, via a
custom read-only `UITextInput` container + `UITextInteraction(.nonEditable)`
overlay, with the search index as the selection's text model. Proven by a
working prototype (`Sources/ADFRendering/SelectionPrototype/`, run with
`-selectionPrototype kitchen-sink`). Estimated production cost: a
search-feature-scale effort (~1,200–1,800 non-test lines + full perf-gate
re-run), dominated by geometry fidelity, not by selection UI.

This document is the ADR §2 "revisit only if cross-block selection becomes a
requirement" revisit.

Tracking: issue [#5](https://github.com/bharath2020/connie-adf/issues/5);
prototype + this doc live on the `selection-prototype` branch.

## Why there is no cheap path

- **SwiftUI has no cross-view selection API through the iOS 26 SDK.**
  `.textSelection(.enabled)` on a container makes each `Text` individually
  selectable; `TextSelection` (iOS 18) and `AttributedTextSelection` (iOS 26)
  are bindings for editable TextField/TextEditor only. iOS 27 beta adds
  in-`Text` range selection with handles — still per-view. No OSS library
  achieves native selection across sibling SwiftUI `Text`s; the field
  converges on (a) one UITextView, (b) custom `UITextInput` container
  (Apple-sanctioned, WWDC23 "What's new with text and text interactions"),
  or (c) WKWebView.
- **One document-wide UITextView (TextKit 2) contradicts §1/§2/§8/§16
  wholesale**: it forfeits the flat lazy list, spacer collapse, 2-row table
  slices, the media pipeline, and interactive plugin blocks
  (`NSTextAttachmentViewProvider` recreates embedded views on viewport exit
  until iOS 27), and inherits TextKit 2's height-estimation instability.
  Full rewrite + every gate re-proven. Rejected again.
- **WKWebView**: against the renderer's founding constraints. Rejected.

## The architecture that works (prototyped)

A transparent UIView spanning the scroll *content* (so all geometry lives in
content space and scrolls for free), conforming to read-only `UITextInput`:

- **Text model = the search index.** `SearchTextUnit` already provides
  document-ordered per-owner plainText with a gap-free part map onto the
  exact rendered segments. The prototype joins units with "\n" into one
  virtual document string with Character-offset prefix sums;
  `UITextPosition` wraps a global offset. Copy output is exactly the joined
  slice (proven byte-identical expectations, 858 chars on kitchen-sink).
- **System-drawn selection UI.** `UITextInteraction(for: .nonEditable)`
  supplies long-press word selection (via `UITextInputStringTokenizer`),
  the blue highlight, and both grab handles — all rendered by UIKit from our
  `selectionRects(for:)` / `caretRect(for:)`. No attribute painting, no
  per-row invalidation during drags.
- **Geometry via per-row UIKit beacons + shadow TextKit layout.** Passive
  `UIViewRepresentable` beacons behind each row give row frames through
  UIKit `convert(_:to:)` — no SwiftUI geometry reads, nothing observable,
  queried only during selection interactions (respects the §8/§16 landmine
  space by construction). Character-precise rects come from a parallel
  `NSLayoutManager` over the same string at the row's width; non-eligible
  owners (nested, centered/indented, atom-bearing, code, tables) fall back
  to whole-row rects — which reads as normal block selection, like Safari
  selecting over an image.

### Prototype results (iPhone 16 sim, iOS 18.2, kitchen-sink fixture)

Verified working:
- Long-press → native word selection with system handles + highlight.
- Handle drag → live shrink/extend across blocks (858 → 694 chars observed),
  system re-anchors the handle to the exact new boundary.
- Select All / Copy → pasteboard receives the full document-ordered text
  (panels, table cells, list rows, captions, atom fallback text included).
- Continuous highlight across every block kind; precise per-line rects on
  headings and plain paragraphs, whole-row rects on fallback owners.
- Scroll and selection coexist: fling passes through the overlay; highlight
  and handles ride content; selection survives scroll away/back.
- Zero interference when no selection exists.

### Verification log (2026-07-17, axe-driven, evidence in docs/assets/selection-prototype/)

All steps on iPhone 16 simulator (iOS 18.2), Debug build, launched with
`-selectionPrototype kitchen-sink`; taps/drags via `axe` HID events.

| # | Action | Observed | Evidence |
|---|--------|----------|----------|
| 1 | Launch | Kitchen-sink renders through the real preparer; status bar "No selection — long-press text to start" | — |
| 2 | Long-press (0.9 s) on first paragraph | Native word selection: system start/end handles, blue highlight, Copy/Select All menu; status "5 chars: break". Highlight offset ~1 line upward on this mark-heavy paragraph (shadow-layout drift, gap 1) | `01-longpress-word-selection.png` |
| 3 | Tap Select All | Continuous highlight across every block: title + paragraphs precise per line, headings 2–6 tightly aligned, centered/indented/quote/lists/code as whole-row rects; status "858 chars" | `02-select-all-cross-block.png` |
| 4 | Tap Copy, read pasteboard (`simctl pbpaste`) | Exactly 858 chars, document order, one line per unit — includes panels, table cells, list rows, collapsed-expand bodies ("Hidden detail"/"Deeper detail"), media caption, atom fallbacks ("Ping @Bharath 😄 due Jul 9, 2024 …") | pasteboard dump |
| 5 | Drag start handle (1.8 s) from title to "Heading two" | Selection shrinks live 858 → 694 chars; handle snaps to the exact start of "Heading two"; menu re-presents | `03-handle-drag-shrink.png` |
| 6 | Fast fling with active selection | Scroll passes through the overlay; highlight rides content (panels, table cells, media row); no hitching, no handle artifacts with the start handle offscreen | `04-scroll-with-selection.png` |
| 7 | Scroll back to top | Selection + handles intact (694 chars) | — |
| 8 | `swift test` after adding the prototype | 203/203 package tests pass (macOS suite — validates the `#if os(iOS)` guards) | test output |

Interaction bugs observed during the same run (fold into gaps below): tap
outside the selection did not deselect, and a long-press inside an existing
selection did not restart word selection — the prototype exposes
`clearSelection()` but wires no gesture to it.

Measured/observed gaps (all addressable, none architectural):
1. **Shadow-layout drift on mark-heavy paragraphs** (bold/code/sub-sup runs
   measured at base font → wrong wrap → highlight off by a line). Fix:
   bake **dual-scope attributes** (UIKit font alongside SwiftUI font) in
   `InlineComposer` at preparation time so the shadow layout uses exact
   metrics. This is the single most important production work item.
2. **Word-chunk (atom-bearing) paragraphs** need per-chunk geometry — the
   wrapping `Layout`'s placement must be mirrored (or chunk beacons added);
   prototype used whole-row fallback.
3. Tap-to-deselect and long-press-inside-existing-selection need explicit
   gesture handling (the interaction did not provide them on our container).
4. Loupe/magnifier during drags: expected from `UITextInteraction` but not
   verifiable in static screenshots — unconfirmed.
5. Edit-menu presentation is manual (`UIEditMenuInteraction` + debounce);
   works, needs polish (dismissal rules, bar-button collisions).
6. Copy policy decisions: collapsed-expand text is currently copied (search
   corpus indexes it); block joiners ("\n" vs "\n\n"); plugin
   `searchableText` may not match visible text.

## What production takes (Option: custom UITextInput container)

1. **Dual-scope attributes** in ADFPreparation (+ shadow-layout exactness
   tests, macOS-safe). Unlocks precise geometry everywhere the merged-Text
   path renders.
2. **Selection engine** in ADFRendering: prototype's UITextInput core
   hardened (UTF-16 ↔ Character conversions at every boundary, empty-doc /
   edge offsets, writing directions), selection state lifted onto
   `ADFDocumentModel` (survives row collapse/rotation; epoch-guarded across
   document replacement and streaming tail appends).
3. **Geometry service**: per-owner beacons (list rows, table cells,
   captions — not just top-level), wrapping-layout chunk geometry, cache
   invalidation on width/Dynamic Type change (rescale-in-place rules, §19).
4. **Interaction hardening**: hitTest pass-through so links, task checkboxes,
   table/code horizontal pans, and plugin blocks stay tappable when no
   selection is active; tap-to-clear; drag-past-edge autoscroll (capture
   `UITextRangeAdjustmentGestureRecognizer` per the known workaround) that
   writes `anchors.topRow` (§8b truthfulness); remove per-Text
   `.textSelection` once the engine ships.
5. **Perf gates**: idle zero-cost proof (overlay inert without selection),
   stress-5k autoscroll vs same-build baseline, fling CPU settle (the gate
   that actually catches livelocks), rotation-with-active-selection,
   scene-snapshot thrash, idle soak.

Estimated ~1,200–1,800 non-test lines (search precedent: ~1,300 for a
comparably "modest" feature under this doctrine) — days-to-two-weeks of
focused work.

Degradations to accept initially: whole-row granularity over atoms, tables,
and nested content (upgradeable later); no selection into collapsed expands;
handles only visible for materialized endpoint rows (matches native behavior
for offscreen endpoints anyway).

## Cheap partial alternatives (rejected as the answer, useful context)

- **Do nothing / per-block selection**: today's `.textSelection(.enabled)`
  copies whole runs only, breaks at word-chunk boundaries in atom paragraphs.
- **iOS 27 (when it ships)**: free in-paragraph range selection with handles
  per `Text` — better than today, still not cross-block, still no unified
  copy.

## Prototype inventory (throwaway — delete or absorb)

- `Sources/ADFRendering/SelectionPrototype/` (4 files, `#if os(iOS)`).
- Demo hook: `-selectionPrototype <fixture>` in `ADFReaderApp.swift`.
- Run: build the demo, then
  `xcrun simctl launch <udid> com.connie.adfreader -selectionPrototype kitchen-sink`.
