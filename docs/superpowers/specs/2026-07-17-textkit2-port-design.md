# TextKit 2 Full Render Port — Assessment Prototype Design

**Date:** 2026-07-17
**Status:** Approved (assessment prototype; not a production commitment)
**Tracking:** issue #5 (cross-block text selection)
**Predecessors:** `docs/Text-Selection-Assessment.md` (on the `selection-prototype`
branch — UITextInput overlay + shadow-layout prototype, 2026-07-17), ADR §2
("Revisit only if cross-block selection becomes a requirement"), ADR §§8/16/18/19/20.

## 1. Goal and non-goals

Port every text-bearing block to per-row TextKit 2 rendering so that
character-level, cross-block, native text selection works everywhere — while
preserving scroll performance (stress-5k gates), fps, video player behavior,
scroll-position retention, per-document Dynamic Type, search, and streaming.

This is an **assessment prototype**: it integrates with the real lazy document
view (it must, to prove anything), runs the full gate suite, and ends in a
verdict doc (`docs/TextKit2-Port-Assessment.md`) with measurements. It is not
required to be mergeable; production porting is a follow-up decision informed
by the verdict.

**The structural bet:** with rendering and selection geometry served by the
*same* per-row `NSTextLayoutManager`, the shadow-layout drift class (the prior
assessment's #1 production risk) ceases to exist. The two risks ADR §2 named —
per-view NSTextLayoutManager cost, and the UIKit sizing dance — become the two
things this prototype measures first.

Non-goals: selection inside plugin blocks (select-as-unit per the WYSIWYG
contract); persistent video playback across recycling; sub-row scroll-anchor
precision beyond today's documented residuals.

## 2. Architecture at a glance

```
ADFPreparation (off-main, Sendable)
  InlineComposer  ──►  InlineSegment.text(AttributedString, spine: [StyledRun])
                       (segment array shape UNCHANGED — SearchIndexer invariants hold)

ADFRendering (main)
  SegmentedTextView / CodeBlockView            ◄── the -textkit2 toggle choke points
    ├─ SwiftUI Text path (toggle off; macOS)   ◄── unchanged
    └─ TextKit2RowView (toggle on, iOS)
         UIView + NSTextContentStorage/NSTextLayoutManager/NSTextContainer
         fonts resolved in updateUIView from env DynamicTypeSize
         draws fragments + pills + search highlights; self-registers for geometry

  SelectionController (iOS)
    UITextInput + UITextInteraction(.nonEditable) on an ANCESTOR
    (introspected hosting scroll view's content container)
    text model: SearchTextUnit corpus, UTF-16 global currency
    geometry: live rows' real layouts; collapsed rows interpolated
```

## 3. Preparation — dual-scope styled spine (`ADFPreparation`)

- `InlineComposer` additionally emits, per `.text` segment, a Sendable parallel
  spine: `[StyledRun { characterRange, fontSpec, colorTokens,
  underline, strike, baselineOffsetRatio, linkURL }]`.
- `FontSpec` is **semantic and size-independent**: text-style token
  (body/title/title2/title3/headline/subheadline/footnote/monospacedBody),
  symbolic traits (bold/italic), and a size-adjustment ratio (small, sub/sup).
  **No concrete point size is baked at preparation time** — this preserves ADR
  §19's zero-re-preparation per-document Dynamic Type shift.
- The `[InlineSegment]` array shape (indices, word-chunk splits for
  WrappingInlineLayout) is untouched, so `SearchHighlightSpan.segmentIndex` and
  the SearchIndexer parts map remain valid verbatim. The TK2 path concatenates
  chunks in order; TextKit re-wraps natively.
- Color tokens map to platform colors at the view layer (colors don't affect
  metrics; assessment-grade table is acceptable).
- `RenderBlock` payloads remain closure-free Hashable + Sendable values.

## 4. TextKit2RowView (`ADFRendering`)

One `UIView` per text row owning its own small TK2 stack. Live count is bounded
by the render region; a collapsed row releases everything.

**Fonts.** Resolved in `updateUIView` from `context.environment.dynamicTypeSize`,
hand-mapped to `UIContentSizeCategory` (explicit switch; clamp `@unknown`),
via `UIFont.preferredFont(forTextStyle:compatibleWith:)` plus font-descriptor
trait modifiers — **never `UIFontMetrics` scaling of a base point size**
(red-team measured divergence: 37pt vs 40pt at AX3; UIFontMetrics tracks the
`@ScaledMetric` curve, not the semantic-font curve). Resolution memoized by
(fontSpec, category). All UIKit automatic content-size adjustment disabled.
Trait-argument-less `preferredFont`/`UIFontMetrics` calls in this layer are
banned by a lint-style test. (Env→trait bridging into representables was
probe-verified on iOS 18.2.)

**Sizing.** `sizeThatFits(_:)` sets the container width, runs `ensureLayout` to
the end of the document range (deterministic, synchronous, same SwiftUI pass —
required so the §19 type-size re-pin sums correct heights), returns the height;
the last (width → height) is memoized inside the view to absorb repeated
probes. The view **never** self-invalidates (`invalidateIntrinsicContentSize`
forbidden). Zero container chrome: `lineFragmentPadding = 0`, no insets.
Exactly one geometry commit per materialization so `CollapsedRowHeight`'s
exact-replay contract holds; the row kind stays `reflowing` (h·w_old/w_new;
ratio² on type change).

**Conversion cache.** `NSAttributedString` plus Character↔UTF-16 offset tables
(and per-segment UTF-16 prefix sums) are built once per
**(documentEpoch, blockID, revision, sizeCategory)** and LRU-capped (~200).
The cache is owned by the model and purged on `load()` — structural block IDs
recur across documents (ADR §12/§20), so the document epoch is mandatory.
The cache holds **base text only**; highlights never touch it.

**Drawing.** `draw(_:)` enumerates text layout fragments: search-highlight
background rects first (converted through the cached offset tables), then
glyphs, then pills. Selection visuals are NOT drawn here — UIKit draws them
from the selection controller's `selectionRects`.

**Search integration.** The zero-work idle gate is preserved verbatim: the
SwiftUI wrapper reads one `search.isActive` Bool when idle; only owners with
spans hand span values through `updateUIView`; invalidation is per-owner;
the arrival flash maps to timed `setNeedsDisplay` of affected fragments only —
a redraw, never a relayout.

**Baselines.** *(Amended after Task 11 verification.)* List markers stay in
the existing SwiftUI marker column (preserving `TaskMarkerView` checkbox
interactivity, which CG-drawn markers would have destroyed); the TK2 row
supplies an explicit `.alignmentGuide(.firstTextBaseline)` computed as the
first text run's resolved-font ascender — a pure font function, never
measured layout. Verified: worst marker/icon drift 0.33pt at default and
step-3 sizes across lists, panels, checkboxes, decisions. Markers remain
out of the text content so copy stays byte-identical to the search corpus.
(Bare-UIView top-edge baseline behavior probe-measured as predicted.)

**RTL.** Explicit `NSParagraphStyle` per block: alignment mapped exactly as
`RichTextBlockView` maps it, flipped by the bridged `layoutDirection`;
`baseWritingDirection` set from content Bidi; `writingDirection` honored in
selection rects. A new RTL fixture (Arabic + mixed-Bidi) joins the test matrix.

**Sub/superscript.** Baseline offsets scale with the resolved-font ratio; the
TK2 rendering is now the source of truth (no concurrent SwiftUI layout to
drift from), so small visual differences from main at AX sizes are recorded in
the assessment rather than treated as bugs.

## 5. Atoms (pills) — native attachments, vector-drawn

- A custom `NSTextAttachment` subclass per atom reserves baseline-correct space
  via `attachmentBounds` (matching WrappingInlineLayout's
  rowAscent − itemAscent placement).
- Pills are drawn **in the draw pass** (rounded rect + CoreText, mirroring
  `AtomView` styling). No `ImageRenderer` bitmaps, no hosted views, no
  `NSTextAttachmentViewProvider` (documented viewport-exit recreation problem
  before iOS 27). Draw-time rendering means dark-mode and type-size changes
  resolve current traits naturally with zero invalidation storms.
- Fidelity is verified by side-by-side screenshots against main; if CG drawing
  can't match acceptably, the recorded fallback is keeping atom-bearing
  paragraphs on the SwiftUI path with whole-chunk selection granularity
  (an accepted degradation, noted in the verdict).
- **Atom atomicity is an invariant:** selection endpoints snap to the nearer
  pill edge; caret never lands strictly inside an atom's range; selection rects
  cover the whole pill when any of its range is selected; the tokenizer treats
  an atom's range as a single word. Copy uses the atom's `fallbackText` in
  full or not at all.
- Taps on links and interactive atoms are hit-tested from the row's own layout
  (link attribute / attachment at point → openURL / popover anchored at rect).

## 6. Block-kind coverage and the A/B toggle

| Kind | Treatment |
|---|---|
| richText (all-text and atom-bearing) | TK2 row |
| codeBlock | TK2 row inside the existing horizontal ScrollView; unbounded-width `sizeThatFits` yields intrinsic code width |
| listRows | TK2 row per `PreparedListRow` inline content; markers CG-drawn; trailing blocks recurse |
| panel / quote | SwiftUI chrome unchanged; interior text rows are TK2 |
| tableSlice | cell text is TK2 (behind its own sub-flag; see gates) inside the existing grid/slices/pinned headers/TableScrollSync |
| expand | header SwiftUI; body blocks render like top-level once prepared |
| media captions | TK2 row under media (media pipeline untouched) |
| custom / plugin (YouTube etc.) | untouched; select-as-unit; excluded from character ranges |

The `-textkit2` launch arg is read once into a `static let` and branches at
the top of **`SegmentedTextView`'s body and `CodeBlockView`** — the leaf choke
points every owner (blocks, list rows, captions, cells) already funnels
through. When on, the TK2 row replaces **both** of SegmentedTextView's arms
(merged-text and atom-bearing/WrappingInlineLayout); when off — and always on
macOS — the existing body runs unchanged. Branching at `BlockView` cases would
silently miss list rows and captions and corrupt the A/B numbers. A constant-Bool `if/else` at a leaf is
safe (`_ConditionalContent` with stable identity); never `#available`, never
`AnyView`, never at the lazy per-item position. Table cells get a separate
sub-flag so TK2-in-cells can be excluded (and recorded in the verdict) if the
giant-table gate kills it without killing the whole port.

## 7. Selection engine

**Attachment point — v3, session-scoped overlay.** *(Amended after Task 16
killed the v2 ancestor-interaction architecture on the real hierarchy:
`UITextInteraction`'s recognizers decline touches that hit-test to
descendant rows — the phase-1 spike passed only because its synthetic labels
were non-interactive. The same experiment proved a plain long-press
recognizer on the ancestor DOES fire over interactive descendants; that
finding is the foundation of v3. User constraint recorded: the SwiftUI
renderer path must not change — every piece of selection machinery mounts
only when `TextKit2Flags.enabled`.)*

- The read-only `UITextInput` container + `UITextInteraction(.nonEditable)` +
  `UIEditMenuInteraction` live on a **transparent overlay** spanning the
  scroll content (mounted only under the TK2 flag).
- **Idle (no selection session): the overlay is hit-test transparent**
  (`isUserInteractionEnabled = false` or hitTest → nil). Links, checkboxes,
  the video facade, expand headers, and table/code pans behave natively;
  per-frame cost is zero.
- **Session start:** our own `UILongPressGestureRecognizer` on the
  introspected content container (the ancestor — proven to fire over
  interactive descendants) begins a session: word-select at the press point
  via the text model, make the overlay first responder, enable its
  hit-testing.
- **Session active:** the overlay owns touches over the selection UI —
  `UITextInteraction` drives handles/drags/menu natively on the overlay
  (touches now hit-test TO the overlay, which is `interaction.view`, the
  exact condition Task 16 proved necessary). Tap outside the selection
  clears the session and returns the overlay to transparent; the
  first-responder resignation path must restore the idle state
  unconditionally.
- Scroll must keep working during a session (the overlay passes vertical
  pans through to the scroll view — verified in the arbitration matrix).

The remaining v2 contracts are unchanged: UTF-16 currency, on-demand-only
geometry, non-observed state + coarse session Bool, epochs + gesture-cancel,
expand policy, copy semantics, and the interaction-hardening items (copy
wiring, drag-past-edge autoscroll writing `anchors.topRow`).

**Text model.** The search corpus (`index.itemOrder` → units → plainText) with
stored cumulative prefix sums. **UTF-16 code units are the global currency**
(`UITextPosition`, all UITextInput arithmetic) because
`UITextInputStringTokenizer` computes word boundaries in UTF-16 inside UIKit,
outside any boundary we control — Character offsets appear only at the
search-corpus/parts-map boundary, converted through the cached per-unit tables.
Regression test: word-select after a non-BMP scalar; copied text equals the
visibly selected word.

**Geometry.**
- Live TK2 rows self-register (weakly, by ownerID) in a plain **non-observed**,
  document-order-sorted registry — binary-searched, evicted on row collapse.
  No beacon views at rest: the rows exist anyway; registration at
  `didMoveToWindow` is the only cost. Queries run on demand during selection
  interactions only — never during scroll.
- Collapsed-row rects are synthesized by interpolating between live neighbors
  using known spacer heights; `containsStart`/`containsEnd` are computed from
  **range membership**, never array position; `caretRect` never returns
  `.null` (synthesized from interpolation for collapsed offsets).
- **Geometry staleness:** collapsed-height corrections on re-entry, expand
  toggles, and table h-scroll offset changes (via TableScrollSync's existing
  observation) drive a coalesced `inputDelegate.selectionWillChange/DidChange`
  so UIKit re-queries selection rects. Gate: rotate with Select All active,
  then fling.
- Drag-past-edge autoscroll writes `model.anchors.topRow` (the §8b contract);
  per-touch-move work is a binary search over cached frames, never a scan of
  all-ever-registered entries.

**State.** Selection lives in a **non-observed reference box** owned by the
model (the ScrollAnchorRegistry pattern) so per-touch-move writes invalidate
nothing; SwiftUI sees only one coarse session-active Bool that flips at session
start/end. Epoch-guarded: the epoch bumps on **any** index change that is not a
pure tail append (`load()`, and `apply(_:revision:)` replacements/removals/
moves — not just document replacement). On an epoch bump mid-gesture, the
interaction's recognizers are cancelled explicitly and the range is
clamped/cleared via `inputDelegate` before the next query — no dangling
offsets, no out-of-range `text(in:)`.

**Expands.** Collapsed expand bodies stay in the offset space (offset
stability wins). Visibility is enforced at the edges: units whose
`expandAncestorIDs` are not all open are excluded from copy output, selection
rects, and `closestPosition` candidates; endpoints snap across closed ranges
(like selecting over an image). An expand toggle is a selection-rect
invalidation, not a text-model change.

**Copy.** Document-order joined slice of the virtual string, byte-identical to
the search corpus (minus hidden-expand exclusions above). List markers are
neither highlighted (rects come from real layouts, text only) nor copied —
consistent WYSIWYG; marker injection at unit boundaries is noted as a possible
production refinement, not prototyped.

## 8. Platform strategy

The conversion core (spine → attributed string), offset tables, FontSpec
resolution, and TK2 layout/measurement logic are **platform-agnostic**
(`NSTextLayoutManager` exists on macOS; `UIFont`/`NSFont` behind a typealias)
so `swift test` on macOS genuinely exercises them — the prior plan's
"macOS-safe exactness tests" were structurally unable to compile the code under
test. Only `UITextInteraction`/edit-menu/scroll-introspection glue is
`#if os(iOS)`. The 203-test package suite keeps passing; new tests cover
conversion, offset mapping, font-spec resolution, and layout determinism.

## 9. Untouched subsystems

DocumentRow/spacer collapse/`CollapsedRowHeight` machinery; scroll anchoring
(tracking-only nil-getter binding, one-shot re-pins, anchors-truthfulness);
streaming append; search indexing/matching; video coordinator + facade
discipline; media pipeline; `.id(document)` identity contract.

**Scroll anchoring.** *(Amended during phase 2–3 execution.)* During the
assessment, the one-shot re-pin was extended to a cancellable settle-window
re-pin series (commits `165db39` + `f069ab1`) to fix a pre-existing,
renderer-agnostic jump-then-rotate drift — flagged for main backport. The
tracking-only nil-getter binding and anchors-truthfulness contracts remain
untouched.

## 10. Gates and verdict criteria

Perf (both toggle branches where marked):
- stress-5k `-autoscroll` vs freshly measured same-build baseline (A/B) —
  Debug-sim baseline ~10.3 ms/s, not the ADR's release figure
- giant-table hitch (A/B) — the tableSlice sub-flag decision point
- fling burst → instantaneous CPU settles ~0 (`top -l 2`)
- **handle-drag autoscroll on stress-5k with CPU settle** (the drag path the
  autoscroll gate can't see)
- selection-session memory soak on stress-5k; media-fixture memory < 150 MB
- first chunk < 150 ms; idle soak; scene-snapshot thrash

Behavioral:
- youtube fixture: facade → play → scroll-away deactivate unchanged;
  fling-through over an active player
- rotation 8-cycle pixel-stable; **rotate-with-Select-All-then-fling**
- §19 gauntlet incl. mid-scroll type-size step over materialized TK2 rows
- **AX3 wrap-parity fixture** (accessibility-range fonts); RTL fixture
- kitchen-sink selection demo: long-press word select **past an emoji**,
  cross-block handle drag through an atom paragraph + table cell + code block,
  Select All, Copy byte-exact document order
- **pan a table and scrub a code block with an active selection**
- live-edit lands mid-handle-drag (epoch/gesture-cancel contract)
- side-by-side screenshot parity vs main (pills, headings, lists, panels)

**Kill criteria** (verdict: "no-go — fall back to geometry-oracle overlay"):
autoscroll > 2× same-build baseline; fling CPU fails to settle; type-size or
rotation scroll retention breaks; ancestor-attached UITextInteraction proves
unworkable.

## 11. Kill-fast prototype order

1. **Ancestor-attachment spike** — UITextInteraction + read-only UITextInput on
   the scroll content container over dummy rows; verify long-press-to-select
   coexists with descendant taps/pans. Kills the selection architecture
   cheapest if it fails.
2. **Bare TK2 rows** on stress-5k behind `-textkit2` (no selection): the ADR §2
   "per-view NSTextLayoutManager cost" number — the port's core bet.
   Autoscroll + fling + rotation + §19 gauntlet here.
3. **Dual-scope spine + fonts/pills/baselines/RTL** on kitchen-sink:
   screenshot parity.
4. **Selection engine** over real layouts; interaction hardening.
5. **Full gate suite + verdict doc** (`docs/TextKit2-Port-Assessment.md`),
   issue #5 update.

## 12. Deliverables

Branch `textkit2-port-prototype` (never merged to main without a follow-up
production decision); `docs/TextKit2-Port-Assessment.md` with verdict,
measurements, and screenshots; issue #5 updated with the verdict.

## Appendix: red-team provenance

This design is v2 after a four-lens adversarial review (perf gates, selection
correctness, Dynamic Type/rotation, integration; 34 findings, several backed by
simulator probes). Key redesigns it forced: ancestor-attached interaction
(sibling overlay swallowed all interactive-content touches), UTF-16 global
currency (UIKit tokenizer arithmetic), `preferredFont(compatibleWith:)` over
UIFontMetrics (AX-range divergence, measured 37 vs 40pt at AX3), draw-pass
vector pills over ImageRenderer bitmaps (main-actor placement + trait
staleness), document-epoch cache keys (structural ID collisions), non-observed
selection state (per-touch-move invalidation storms), leaf-level toggle
placement (BlockView cases miss list rows/captions), computed-ascent baselines
(bare-UIView firstTextBaseline lands on the top edge, measured), and the
platform-agnostic core (previously zero lines of the critical path compiled
under `swift test`). Caveat recorded for honesty: a payload bug meant the
panel worked partly from lens-prompt specifics and the prior assessment doc
rather than the full v1 text; findings were cross-checked against v1 before
adoption.
