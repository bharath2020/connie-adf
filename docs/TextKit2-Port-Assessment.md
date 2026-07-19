# TextKit 2 Port Assessment

This document records feasibility spikes for the TextKit 2 port assessment
(spec §11). Each spike answers one kill/proceed question before any
production code is committed to the port.

## Spike: UITextInteraction on an ancestor

**Kill question #1:** does `UITextInteraction(.nonEditable)` deliver
cross-view text selection when attached to an **ancestor** view whose
hit-tested descendants (a button, a nested horizontal scroll view, labels)
keep native touch behavior? A prior prototype attached the interaction to a
sibling overlay, which swallowed every descendant touch. This spike attaches
the interaction directly to `SpikeTextContainer`, the ancestor of all
interactive descendants, with no `hitTest` override anywhere.

### What was built

- `Demo/ADFReader/SelectionSpike.swift` — `SpikeScreen` (a
  `UIViewControllerRepresentable`) hosting `SpikeViewController`, which lays
  out `SpikeTextContainer` (three paragraph `UILabel`s, a tap-counter
  `UIButton`, and a nested horizontal `UIScrollView`) inside an outer vertical
  `UIScrollView`. `SpikeTextContainer` conforms to `UITextInput` with a crude,
  read-only text model (whole-paragraph selection rects, linear-interpolated
  caret geometry) and has a `UITextInteraction(for: .nonEditable)` attached
  directly to it.
- `Demo/ADFReader/ADFReaderApp.swift` — added `-selectionSpike` to
  `LaunchOptions`, routed at `WindowGroup` root (before the fixture branch):
  `if options.selectionSpike { SpikeScreen().ignoresSafeArea() } else if let
  name = options.fixtureName { ... }`. Also documented the flag in the
  file's launch-argument doc comment for consistency with the existing flags.

### Deviations from the brief's code (compiler-forced)

The brief's code was transcribed verbatim and built against Xcode 26.3 /
iOS 26.2 SDK. Two `UITextInput` conformance mismatches were compiler errors,
not warnings, so both were fixed to match the current SDK's exact protocol
requirements:

1. `position(within:farthest:)` → **`position(within:farthestIn:)`**. The
   SDK's `UITextInput` declares the second argument label as `farthestIn`,
   not `farthest` (confirmed against
   `UITextInput.h`: `positionWithinRange:farthestInDirection:`). Only the
   external label changed; the parameter name and body are untouched.
2. Added a **`firstRect(for range: UITextRange) -> CGRect`** method. The SDK's
   `UITextInput` requires it (`firstRectForRange:` in the ObjC protocol) and
   the brief's listing omitted it, so `SpikeTextContainer` failed to conform.
   Implemented as the crude-geometry-consistent
   `selectionRects(for: range).first?.rect ?? .zero` — reuses the existing
   per-paragraph rects rather than introducing new geometry.

No other lines were changed. Both fixes were mechanical (satisfying an
existing protocol's exact signature); neither altered the spike's behavior
or the gesture-arbitration logic under test.

### Build

```
cd Demo && xcodegen generate
xcodebuild -project ADFReader.xcodeproj -scheme ADFReader \
  -destination "platform=iOS Simulator,name=iPhone 16" build
```
Result: **BUILD SUCCEEDED** (after the two fixes above; the initial build
with the brief's code verbatim failed with the two conformance errors).

### Run

A dedicated iPhone 16 (iOS 26.2) simulator was booted (UDID
`F3E0C639-88A4-4C36-AA27-FC0FEB14D149`) rather than reusing any of the several
iPhone 16 / 17 Pro simulators already booted on the host, to avoid
disturbing other in-progress sessions.

```
xcrun simctl boot F3E0C639-88A4-4C36-AA27-FC0FEB14D149
xcrun simctl install $D <DerivedData path>/ADFReader.app
xcrun simctl launch $D com.connie.adfreader -selectionSpike
```
Launched cleanly: three paragraphs, a "Tap counter: 0" button, and a
horizontal scroller rendered exactly as expected, in the order paragraph 1 →
button → paragraph 2 (with emoji) → h-scroll → paragraph 3 (matching
`buildContent()`'s layout order).

### Arbitration matrix — OBSERVED results

All coordinates were derived from screenshots (`xcrun simctl io $D
screenshot`) taken immediately before each action, converted from the PNG's
pixel space to UIKit points using the confirmed screen size {393, 852}
(from `axe describe-ui`'s root `AXFrame`). `axe drag` failed simulator-wide
with `FBSimulatorHIDEvent does not support touch move events` on this
install; `axe swipe` (which does emit continuous touch-move events) was used
in its place for handle-dragging, per the brief's suggested fallback.

| # | Action | Pass condition | Observed | Result |
|---|---|---|---|---|
| 1 | `axe tap` the button | counter increments | Counter went 0 → 1. Descendant tap fully alive with the interaction attached to its ancestor. | **PASS** |
| 2 | `axe swipe` horizontally over the h-scroll row | it pans | Scroll indicator appeared and the wide label visibly shifted left. Descendant horizontal pan fully alive. | **PASS** |
| 3 | `axe touch --down/--up` long-press on paragraph 1 | word selection w/ native handles appears | Long-press (1.0s hold) produced a native blue selection highlight with round drag handles at both ends and the system edit-menu callout ("Look Up \| Translate"). Selection covered the whole paragraph 1 rect (expected — geometry is whole-paragraph, not word-level, per the spike's crude `selectionRects`). | **PASS** |
| 4 | drag a handle from ¶1 into ¶3 | selection extends across paragraphs + button region | Two chained `axe swipe` drags on the end handle (first into ¶2, then into ¶3) extended the highlighted region to cover paragraphs 1, 2, and 3, spanning the button/h-scroll region between them (the crude geometry doesn't highlight the button itself, but the selection's vertical extent crosses it). | **PASS** |
| 5 | with selection active, tap the button | counter increments | Counter went 1 → 2 while the 3-paragraph selection remained visually intact (handles unchanged). Ancestor attachment did not swallow the tap, and the tap did not clear the selection. | **PASS** |
| 6 | with selection active, pan the h-scroll | it pans | The h-scroll panned fully to its end (indicator moved to the far right) while the selection remained intact throughout. | **PASS** |
| 7 | vertical swipe on ¶ text | outer scroll view scrolls | Selection was cleared first (tap in blank space) for a clean read. A vertical swipe over paragraph 2's text scrolled the outer `UIScrollView` — paragraph 1 and the button scrolled off the top, paragraph 2 moved to just under the status bar, and a vertical scroll indicator appeared. | **PASS** |
| 8 | long-press over the emoji ¶, check Copy via edit menu | copied text matches | Long-press over the emoji triggered the same native selection/handles/menu mechanism as row 3 (mechanically identical — **PASS** for the gesture-arbitration part). However the edit menu offered only **"Look Up" / "Translate"** — no **Copy** item ever appeared, on this attempt or a repeat. Confirmed two ways: (a) `axe describe-ui` dumped the menu's accessibility tree and it contains exactly two `AXStaticText` children ("Look Up", "Translate") plus a "Forward" (next-page) button, no "Copy"; (b) the device pasteboard (`xcrun simctl pbcopy`/`pbpaste`) was seeded with a sentinel string beforehand and was unchanged after the long-press, confirming no copy occurred. | **FAIL (root cause identified — see note)** |

**Row 8 root cause:** `SpikeTextContainer` never implements
`copy(_:)` / overrides `canPerformAction(_:withSender:)`. `UITextInteraction`
builds its edit menu by asking the first responder which standard edit
actions it supports; without an implemented `copy(_:)` selector, the
responder chain reports it can't perform `copy:`, so `UITextInteraction`
omits it from the menu entirely — "Look Up" and "Translate" are offered
because they're routed through system services (data detectors /
`UIReferenceLibraryViewController`) rather than through the app's responder.
This is **not** a gesture-arbitration failure (the exact same long-press
mechanism that passed in row 3 fired correctly here too) — it's a scope gap
in the brief's spike code, which was transcribed verbatim per instructions
(no compiler error is raised by omitting an optional `UIResponder` action).
A production implementation needs an explicit `copy(_:)` override (writing
`text(in: selection)` to `UIPasteboard.general.string`) plus
`canPerformAction` support for `copy:`/`_lookup:`/`_define:` etc.

### Screenshots

All paths are under the session scratchpad (not committed — see Step 6's
file list, which does not include screenshots):

- `/private/tmp/claude-501/-Users-bharath2020-Documents-projects-connie-adf/3bba22ed-b474-4a9e-aedf-efb62050268a/scratchpad/shots/01_initial.png` — initial layout (3 paragraphs, counter, h-scroll)
- `02_row1_tap_button.png` — row 1, counter 0 → 1
- `03_row2_hscroll_pan.png` — row 2, h-scroll panned (indicator visible)
- `04_row3_longpress_p1.png` — row 3, selection + native handles + edit menu on paragraph 1
- `06_row4_drag_attempt2.png` — row 4, selection spanning paragraphs 1–3 (final state after two chained handle drags; `05_row4_drag_handle.png` and `05b_row4_swipe_attempt.png` are the intermediate/failed-API attempts kept for the record)
- `07_row5_tap_during_selection.png` — row 5, counter 1 → 2 with selection still intact
- `08_row6_hscroll_during_selection.png` — row 6, h-scroll panned to its end with selection still intact
- `09_after_clear_tap.png` — selection cleared before the row 7 test
- `10_row7_vertical_swipe.png` — row 7, outer scroll view scrolled (paragraph 1/button off-screen)
- `11_before_row8.png` — pre-row-8 layout state
- `12_row8_longpress_emoji.png` — row 8, selection + handles on the emoji paragraph, edit menu showing only "Look Up" / "Translate"
- `13_row8_menu_page2.png` — tapping the menu's "Forward" chevron dismissed the menu without adding Copy (selection also cleared)

### Additional observation (not a matrix row, worth recording)

`axe describe-ui` could not see the paragraph labels, the button, or the
h-scroll view as individual accessibility elements — the entire
`SpikeTextContainer` reports as a single opaque `AXTextArea` whose `AXValue`
is the full joined text. This is consistent with how UIKit represents
`UITextInput`-conforming views to the accessibility system (as one text
area, not a container exposing subviews) and is a real product
consideration for a production port: VoiceOver users would need the crude
per-paragraph text model to be replaced by something that exposes
descendant accessibility elements correctly, or additional accessibility
work will be needed alongside the TextKit 2 port. Flagged here for the
production plan; it does not affect the gesture-arbitration verdict below.

### Verdict: **PROCEED-WITH-CONSTRAINTS**

The core kill question is answered clearly: attaching
`UITextInteraction(.nonEditable)` to an **ancestor** view — rather than a
sibling overlay — lets native descendant gestures (button taps, nested
horizontal scroll panning, outer vertical scrolling) coexist with long-press
text selection, selection-handle dragging across descendants, and selection
persisting across unrelated descendant interactions. 7 of 8 matrix rows
passed outright with no special-casing, hit-test override, or gesture
recognizer surgery anywhere in the spike. This directly refutes the
sibling-overlay prototype's touch-swallowing failure mode.

Constraints for a production build-out, both surfaced by this spike:

1. **Copy (and likely Look Up/Share follow-ons) require explicit responder
   wiring.** `copy(_:)` and `canPerformAction(_:withSender:)` must be
   implemented on the production text-input view; they are not automatic
   side effects of adopting `UITextInput` + `UITextInteraction`.
2. **Accessibility needs separate design work.** A `UITextInput`-conforming
   ancestor collapses its descendants into one opaque `AXTextArea` for
   VoiceOver/accessibility tooling; the production port needs a plan for
   exposing the button/scroller/paragraph structure to assistive
   technology, independent of the visual selection UI validated here.

Neither constraint bears on gesture arbitration — the spike's actual
purpose — so this is not a kill result. PROCEED to the next TextKit 2
feasibility spike (kill question #2, bare TK2 rows) with these two items
carried forward as known follow-up work.

## Phase 2: rendering cost

Measures spec §10's perf/behavioral gates for bare TK2 rows (kill question
#2, spec §11 step 2) behind `-textkit2` / `-textkit2NoCells`. **Measurement
only — no production code changed.** Every number below was captured today,
on the same Debug build, on the same simulator, toggling only the launch
argument between runs.

### Environment

- Simulator: `ADF-Task8-Perf`, UDID `14ACABE6-60A1-41A5-A64A-1EF86BFA47F1`,
  iOS 26.2. Prior sessions in this repo baselined on iOS 18.2 sims (e.g. the
  ADR's Debug-sim ~10.3 ms/s figure); that number is **not** used as a
  reference here. A/B validity holds regardless of iOS version because both
  toggle branches share this exact sim + exact build — only the launch
  argument changes between runs.
- Build: `Demo/ADFReader.xcodeproj`, scheme `ADFReader`, Debug configuration,
  commit `d61f091` (branch `textkit2-port-prototype`, HEAD at measurement
  time). App bundle installed 2026-07-17 22:18 (after the HEAD commit at
  22:07:57 the same day); confirmed current by `strings` on
  `ADFReader.debug.dylib` showing `TextKit2RowView.swift`,
  `-textkit2NoCells`, `-fontSizeStep`, `-scrollToFraction` — no rebuild was
  needed, the sim's existing install was already HEAD.
- Bundle id `com.connie.adfreader`. Fixtures: `stress-5k` (5000 blocks),
  `giant-table`, `kitchen-sink` (38 blocks), `media-gallery`.

### Gate 1 — stress-5k autoscroll, OFF vs `-textkit2` (kill criterion: ON ≤ 2× OFF)

```
xcrun simctl launch --console-pty $D com.connie.adfreader -fixture stress-5k -autoscroll [-textkit2] | grep SCROLL_METRICS
```

| Branch | Run | frames | dropped | hitchRatioMsPerS |
|---|---|---|---|---|
| OFF | 1 | 29578 | 55 | 1.87 |
| OFF | 2 | 29592 | 69 | 2.36 |
| `-textkit2` | 1 | 29542 | 70 | 2.37 |
| `-textkit2` | 2 | 29574 | 48 | 1.63 |

OFF mean 2.12 ms/s; ON mean 2.00 ms/s. **ON is noise-equivalent to OFF**
(runs interleave inside each other's range) — nowhere near the 2× kill
threshold. **PASS.**

### Gate 2 — giant-table autoscroll, OFF vs `-textkit2` vs `-textkit2 -textkit2NoCells`

Same command, `-fixture giant-table`.

| Branch | Run | frames | dropped | hitchRatioMsPerS |
|---|---|---|---|---|
| OFF | 1 | 2414 | 1 | 0.41 |
| OFF | 2 | 2414 | 1 | 0.41 |
| `-textkit2` | 1 | 2413 | 0 | 0.00 |
| `-textkit2` | 2 | 2413 | 0 | 0.00 |
| `-textkit2 -textkit2NoCells` | 1 | 2419 | 1 | 0.41 |
| `-textkit2 -textkit2NoCells` | 2 | 2413 | 1 | 0.41 |

TK2-in-cells (plain `-textkit2`) actually measured **better** than OFF here
(0.00 vs 0.41 ms/s) and NoCells matched OFF exactly. Cells do **not** blow
the gate, so the spec §6 exclusion (`-textkit2NoCells`) is not needed for
this fixture — recorded for completeness, no exclusion decision required.
**PASS** (all three variants).

### Gate 3 — fling burst + instantaneous CPU settle (the gate autoscroll misses)

```
xcrun simctl launch $D com.connie.adfreader -fixture stress-5k [-textkit2]
# 12× axe swipe --start-x 220 --start-y 800 --end-x 220 --end-y 120 --duration 0.08 --udid $D
sleep 3
top -l 2 -pid <pid> | tail -1
```

| Branch | PID | %CPU (2nd sample) | TIME |
|---|---|---|---|
| OFF | 36283 | 0.0 | 00:08.07 |
| `-textkit2` | 36487 | 0.1 | 00:07.55 |

Both settle to ~0 after the 12-swipe burst — **no livelock in either
branch**. **PASS.**

(Caught mid-measurement: `pgrep -f "ADFReader.app/ADFReader"` matches every
booted simulator's copy of the app, not just this sim's — three other
simulators had long-running ADFReader processes from unrelated sessions.
Filtered to this sim's UDID / the launch command's own reported PID before
reading `top`, per the "do not touch any other simulator" constraint.)

### Gate 4 — first chunk, kitchen-sink `-textkit2` (target < 150 ms)

Console `READY` line: `blocks=38 firstChunkMs=<n>`.

| Run | firstChunkMs |
|---|---|
| 1 | 75 |
| 2 | 47 |

Both well under the 150 ms gate. **PASS.**

### Gate 5 — rotation retention, stress-5k `-textkit2 -scrollToFraction 0.5`, 8× rotation round-trips

`scrollTarget = blocks[Int(0.5 * 5000)] = blocks[2500]`, and the fixture's
section headings are exactly block-index-aligned (`Section 2500` is
literally block 2500 — confirmed against `Fixtures/stress-5k.json`), so
section-heading position is a precise, zero-ambiguity proxy for scroll
position.

Protocol: launch, `sleep 2`, screenshot ("before"); 8×
(`xcrun simctl spawn $D notifyutil -p com.connie.adfreader.rotate` +
`sleep 2`); screenshot ("after"); read both PNGs.

| Run | Before (top heading) | After 8 rotations (heading position) | Approx. drift¹ |
|---|---|---|---|
| `-textkit2` run 1 | `Section 2500` at top | `Section 2410: token chunk kernel` ~60% down viewport | ≈ −95 blocks (top of screen ≈ block 2401) |
| `-textkit2` run 2 (repeat, independent launch) | `Section 2500` at top (identical) | `Section 2430: inline block swift` ~57% down viewport | ≈ −75 blocks (top of screen ≈ block 2421) |
| OFF (control, same protocol) | `Section 2500` at top (identical) | `Section 2430: inline block swift` visible essentially at the top of content (partially under the translucent nav bar), same heading text as `-textkit2` run 2 | ≈ −70 blocks (top of screen ≈ block 2430) |

¹ "Top of screen ≈ block X" values are derived estimates (heading identity
is exact from the screenshots; the within-viewport fraction is eyeballed),
not instrumented content offsets.

Screenshot evidence (repo copies, survive scratchpad cleanup):
`docs/assessment-assets/phase2-rotation/rotation_before.png` /
`rotation_after.png` (TK2 run 1), `rotation_before2.png` /
`rotation_after2.png` (TK2 run 2), `rotation_off_before.png` /
`rotation_off_after.png` (OFF control).

**Finding: retention drifts backward by roughly 70–100 blocks (~1.4–2.0% of
the 5000-block document) after 8 rotation round-trips, in BOTH toggle
branches.** The three runs are indistinguishable within run-to-run noise
(≈95 / ≈75 blocks TK2 vs ≈70 blocks OFF; the two TK2 runs differ from each
other by more than TK2 run 2 differs from OFF), so the drift is not
attributable to the TK2 renderer.

**Root cause and resolution (final — supersedes two earlier readings).**
This finding went through three interpretations; the record keeps all three
for honesty:

1. *First reading (this section's original text):* "pre-existing,
   renderer-independent" based on iOS 26.2 A/B parity — correct conclusion,
   insufficient justification (it never reconciled
   `docs/Rotation-Scroll-Retention.md`, which records this drift class as
   fixed and pixel-verified, with fix commits ancestral to the measured
   commit).
2. *Second reading (an interim amendment):* attributed the drift to an
   "unmerged improvement branch" — **factually wrong** (that branch was
   merged to main in `2a6fc94` and deleted; caught by review against git
   history). A follow-up single-run discriminator on iOS 18.2 then
   suggested the drift was TK2-specific — **also wrong**, a sampling
   artifact of a flaky bug.
3. *Final reading (instrumented, multi-run — see
   `docs/assessment-assets/phase2-rotation/`, fix commits `165db39` +
   `f069ab1`):* after a deep programmatic jump (`-scrollToFraction`/TOC),
   the ~2,500 rows above the anchor were never materialized or measured, so
   each rotation's single one-shot `scrollTo(anchor, .top)` re-pin bridges
   that gap on *estimates* and never sees the frame-by-frame height
   corrections that follow — it settles tens-to-hundreds of blocks off,
   nondeterministically. Controlled runs: drift in **3/5 TK2 AND 3/4
   toggle-OFF** launches (−37 to −163 blocks, clustering at discrete
   magnitudes), i.e. **renderer-agnostic and flaky** — a pre-existing bug
   of current main, merely *sampled* differently by the earlier
   single-run measurements (including this gate's iOS 26.2 numbers). The
   instrumentation also refuted the "TK2 rows report zero height" hypothesis
   (zero `.zero` returns, zero memo overwrites, anchor id always correct).

**Fix (landed on this branch; candidate for main backport — cleanly
separable, zero TK2 coupling per review):** keep the immediate re-pin, then
re-issue it across a post-resize settle window ([0.033, 0.1, 0.2, 0.35,
0.5] s) as cancellable work items, cancelled on the first user scroll
interaction (`onScrollPhaseChange`, document-level, availability hoisted;
pre-iOS-18 falls back to the old behavior) and on view teardown.
Verified on iOS 18.2: jump+8-rotate drift ≤ 4 blocks in 5/5 runs per
branch (0/0/0 per branch in the guard round); a user scrolling within the
settle window wins (counterfactually proven — the unguarded build
reproduces the yank-back); autoscroll 0.63 / 0.46 ms/s (OFF / ON, better
than this gate's table); fling CPU settles; 221/221 tests.

Spec §10's kill criterion is therefore judged: **retention does not break
under TK2** — the observed drift was a pre-existing main bug, now fixed on
this branch. Recommendations: (a) backport `165db39` + `f069ab1` to main;
(b) Task 13's phase-3 rotation re-run validates the fixed behavior in both
toggle branches (A/B parity plus absolute ≤1-row bar, now that the absolute
bar is achievable again).

### Gate 6 — type-size gauntlet, kitchen-sink `-textkit2 -fontSizeStep 3`

Screenshots: `type_default.png` (no flag) vs `type_step3.png`
(`-fontSizeStep 3`), same fixture, same build.

Confirmed by reading both images: text is visibly larger at step 3, and TK2
rows reflow accordingly — e.g. the inline code span `let x = 1` renders on
one line by default but wraps across two lines (`let x` / `= 1`) at step 3;
downstream line breaks in the following paragraph shift position
accordingly. **Larger AND reflowed. PASS.**

Mid-scroll live size change via the in-app text-size popover control: **not
attempted this session** — the brief marks this sub-check optional/skippable
("mark UNTESTED if flaky after 3 tries"); only the launch-argument variant
above (which is the required check) was run. **UNTESTED (optional, not
attempted).**

### Gate 7 — memory, media-gallery `-textkit2` (target < 150 MB)

Launch, 8× swipe through the gallery (`axe swipe`, 0.3 s apart), settle,
`top -l 1 -pid <pid>`.

| PID | MEM (top RSS column) |
|---|---|
| 38268 | 62M |

62 MB, well under the 150 MB gate. Tool used: `top -l 1 -pid`. **PASS.**

### Checkpoint verdict: **PROCEED to Phase 3**

| Gate | Result |
|---|---|
| stress-5k autoscroll ON ≤ 2× OFF | PASS (noise-equivalent, 2.00 vs 2.12 ms/s mean) |
| giant-table autoscroll (OFF / ON / NoCells) | PASS (ON best of the three; no exclusion needed) |
| Fling burst CPU settle (both branches) | PASS (0.0% / 0.1%) |
| First chunk < 150 ms | PASS (75 ms, 47 ms) |
| Rotation retention | PASS after fix — pre-existing renderer-agnostic jump+rotate drift root-caused and fixed on this branch (165db39 + f069ab1); ≤4-block drift 5/5 both branches on iOS 18.2 |
| Type-size gauntlet (larger + reflow) | PASS |
| Memory < 150 MB | PASS (62 MB) |

All TK2-specific perf gates pass cleanly, several with comfortable margin
(giant-table ON actually beats OFF; fling settles to ~0 in both branches;
memory at 41% of budget). The one non-clean result — rotation-retention
drift — was proven, via a same-build/same-sim OFF control not requested by
the brief but run anyway because the finding was surprising enough to
warrant it, to be pre-existing behavior unrelated to the TK2 toggle. Per
spec §11's kill-fast intent (kill the *port*, not surface bugs the port
didn't introduce), this is not treated as a kill criterion for TK2, but it
is a real product bug and is called out here so it isn't lost: **rotation
round-trips drift the scroll position backward by ~1.4–2.0% of document
length, in both the legacy and TK2 renderers** — worth its own issue before
shipping either renderer's rotation handling.

**PROCEED to Phase 3** (spec §11 step 3: dual-scope spine, fonts/pills/
baselines/RTL, screenshot parity) carrying forward: (a) the rotation-anchor
drift as a separate, renderer-independent bug to file; (b) re-run this same
matrix at Task 13 per the plan, since pills/search drawing land in Phase 3
and could change these numbers.

## Phase 3: draw-pass search highlights (Task 9)

Commit `e5213e9` (parent `f27d72b`). Dedicated sim `ADF-Task9` (iPhone 16,
iOS 18.2), created for this task, deleted at the end.

**Draw-pass architecture.** `TextKit2RowView` gains `spans`/`currentSpans`
highlight inputs, diffed independently from the base content inputs
(`TextKit2RowUIView.Inputs.Paint`, a separate `Equatable` sub-struct) behind
the same one-Bool idle gate the SwiftUI/legacy arm already uses — base text
(`segments`/`TextRowContent`) is never repainted for a highlight-only
change. `draw(_:)` runs a new `drawHighlightBackgrounds(in:)` before the
fragment-drawing loop: subtle-match fills first, current-match fills after
(so the accent wins any overlap); the current match's foreground is forced
via `layoutManager.setRenderingAttributes`, never by touching the content
storage's attributed string. The arrival flash is therefore redraw-only,
never a relayout — proven not by inspection but by a real unit test:
`TextKit2RowUIViewTests.paintOnlyChangeSkipsConversion` applies three
paint-only changes (spans populate, `dimCurrent` true, `dimCurrent` false)
and asserts the row's `conversionCount` stays at `1` throughout;
`contentChangeReconverts` confirms a segments change does bump it.

**Match-count and highlight parity** — kitchen-sink, query `heading`: OFF
and `-textkit2` both report `matches=5` (one per heading level 2-6), and
the highlight pattern is pixel-identical between arms — same words, same
positions, current match in accent, other matches subtle
(`t9_kitchensink_off_search_heading.png` /
`t9_kitchensink_tk2_search_heading.png`). **PASS, 5/5.**

**stress-5k fling gate** — query `e` settles at **73,399 matches** in both
the in-app UI counter and the OFF/`-textkit2` launch-arg `SEARCH_METRICS`
output — exact parity at scale (`t9_stress5k_tk2_search_e_73399matches.png`).
A 12× `axe swipe` fling burst with all 73,399 spans highlighted settles CPU
to **0.2%** (`top -l 2 -pid`), no livelock
(`t9_stress5k_tk2_after_fling_scroll.png`).

**Arrival flash.** Plain repeated `simctl io screenshot` calls could not
reliably catch the ~130ms dimmed window (confirmed empirically across ~20
attempts), so `xcrun simctl io recordVideo` captured the full
launch→search→flash→exit sequence, decoded to 30fps PNGs via `ffmpeg`.
Sampling the current match's background pixel across frames shows the
three-phase sequence: accent → dimmed/subtle (~130ms) → accent again —
`t9_flash_1_accent.png`, `t9_flash_2_dimmed.png`,
`t9_flash_3_accent_again.png`.

`swift test`: 222/222, 37 suites. `xcodebuild test` (iOS Simulator):
83/83, 13 suites, including the new `TextKit2RowUIView` paint/content-split
suite. Screenshots: `docs/assessment-assets/phase3-search/`.

## Phase 3 — Task 10: atom pills as vector-drawn attachments

Atom-bearing paragraphs (mentions, statuses, dates, emoji, inline cards,
attachments, extensions) now render on the TK2 arm. Each `.atom` segment
contributes one U+FFFC attachment character carrying an `AtomAttachment`
(`NSTextAttachment` subclass) sized in `attachmentBounds` and drawn vector-
style in `image(forBounds:…)` via a draw-time `UIGraphicsImageRenderer` that
reads the current traits (dark-mode correct without content invalidation).
Sizing is a pure function of `(atom, contentSizeCategory)`: `.callout`
weight-medium text (body for emoji) + `UIFontMetrics(.callout)`-scaled 8/2
paddings mirroring `AtomCapsule`/`AtomChip`'s `@ScaledMetric` chrome. No view
hosting, no `NSTextAttachmentViewProvider`, no ImageRenderer-from-SwiftUI.

### Pill size/position drift vs the SwiftUI arm (kitchen-sink, iPhone 16, iOS 18.2)

Measured from A/B screenshots (`t10_kitchensink_{off,tk2}_atoms.png`), pixels
at @3x (÷3 for pt):

| Pill | OFF width | TK2 width | Δ width | Notes |
|---|---|---|---|---|
| `@Bharath` mention capsule | 267px | 267px | **0pt** | position, height also identical (63/64px) |
| `Jul 9, 2024` date capsule | 274px | 277px | ~1pt | |
| `NEUTRAL` status capsule | 267px | 267px | **0pt** | |
| `PURPLE` status capsule | 229px | 229px | **0pt** | |
| `GREEN` status capsule | 206px | 207px | ~0.3pt | |
| `attachment` chip | 353px | 297px | ~18.7pt narrower | SF Symbol omitted |
| `Inline macro` chip | 378px | 312px | ~22pt narrower | SF Symbol omitted |

*Chip widths corrected in fix-round 1 (2026-07-18): the original 253/245px
and 334/310px entries were mis-measured. Re-measured directly from the
committed PNGs with a Python/PIL column scan — for each row inside the
chip's vertical band, find the leftmost/rightmost non-white pixel (RGB
channel < 250; chip fill is a flat `(239,239,240)` vs. page background
`(255,255,255)`), then take the width that recurs across the flat
(non-corner) rows (42–44 of ~85 sampled rows land on the same bound, so
corner rounding is not the source of the number). `attachment`: OFF
`x=[48,400]`=353px vs. TK2 `x=[48,344]`=297px. `Inline macro`: OFF
`x=[415,792]`=378px vs. TK2 `x=[358,669]`=312px. Capsule rows were
re-verified as already correct and are unchanged.*

**Capsules (mention/status/date) land within 0–1pt** at default size — well
inside the ≤1pt target — with matching baseline, tint, tint-opacity, and
uppercased status text. Verified again at `-fontSizeStep 3`
(`t10_*_atoms_step3.png`): pills scale correctly and capsule parity holds.
**Chips, by contrast, are substantially narrower than the SwiftUI arm until
SF Symbols are added** — ~18.7pt and ~22pt narrower, not the ~3–8pt
originally reported. Capsules are pixel-accurate; chips are not until T13/
phase-4 adds the missing icon glyphs.

### Known, intentional gaps (recorded per brief Step 5)

- **Chip SF Symbols omitted in v1.** `AtomChip`'s paperclip/link/puzzlepiece
  icons are not drawn by the CG path — chips are rounded-rect + text only.
  This makes chips **substantially narrower** than the SwiftUI arm — ~18.7pt
  (`attachment`/paperclip) and ~22pt (`Inline macro`/puzzlepiece), not the
  ~3–8pt originally estimated (see corrected measurement above); the missing
  icon plus its leading gap accounts for most of a chip's width at this text
  size. Chip left edge and vertical position match. Adding the symbols is a
  **higher-priority phase-4 polish item than previously stated** — this is a
  visible, substantial size discrepancy, not a rounding-error-scale gap.
- **Atom taps are not hit-tested on the TK2 arm** (mention popovers, inline-
  card links). Those still work on the SwiftUI arm; TK2-arm atom hit-testing
  is phase-4 (selection/geometry) work.
- **Whole-pill search highlight tinting is not applied on the TK2 arm.** A
  matched atom pill tints entirely on the SwiftUI arm; the TK2 arm draws
  range highlights over text but not pill-background tints for atoms. Deferred
  to T13/phase-4 alongside atom hit-testing. (Range highlights inside atom-
  bearing paragraphs DO work — see search verification below.)
- **`firstBaseline` for a pure-atom row** (a paragraph with no text run at
  all) returns the `0` fallback; recovering a pill's own ascent without
  measuring layout is a T13 baseline-fidelity item. Atom-leading rows with any
  following text are correct (they use the first text chunk's ascender).

### Search inside atom-bearing paragraphs (past chunk 0)

With atoms present, the preparer word-chunks the paragraph, so search spans
carry `segmentIndex > 0` on the TK2 path for the first time. Query `see`
(kitchen-sink) sits after the mention and date atoms in block 26; the TK2
draw-pass highlight lands exactly on `see`
(`t10_kitchensink_tk2_search_see.png`), identical to the SwiftUI arm
(`t10_kitchensink_off_search_see.png`) — proving `TextRowContent.utf16Range`'s
absolute (per-segment start + local offset) semantics correctly account for
the attachment characters the atoms insert. Headless `-searchQuery see`
reports `matches=1` on both arms.

### Perf (non-regression)

stress-5k has no atoms, so it exercises the `SegmentedTextView` refactor on
the text path only (which is behaviorally identical for text-only rows —
they compose to a single `.text` segment either way).

**Paired autoscroll A/B (fix-round 1, 2026-07-18):** the original report
cited a lone TK2 number (`hitchRatioMsPerS=4.37`) against a different
session's OFF baseline — not a valid comparison. Re-measured OFF and TK2
back-to-back on one dedicated sim (`ADF-Task10-FixR1`, iPhone 16, iOS 18.2),
same build, same install, same `stress-5k` fixture:

```
$ xcrun simctl launch --console-pty $D com.connie.adfreader -fixture stress-5k -autoscroll | grep SCROLL_METRICS
SCROLL_METRICS fixture=stress-5k frames=29814 dropped=19 hitchRatioMsPerS=0.66   (OFF)

$ xcrun simctl launch --console-pty $D com.connie.adfreader -fixture stress-5k -autoscroll -textkit2 | grep SCROLL_METRICS
SCROLL_METRICS fixture=stress-5k frames=29806 dropped=26 hitchRatioMsPerS=0.87   (TK2)
```

TK2/OFF hitch ratio = 0.87 / 0.66 ≈ **1.32×** — comfortably inside the ≤2×
bar. Sim deleted after the run. 12-swipe fling burst → app CPU settled to
**0.0%** (`top -l 2`). The atom draw path itself was fling-stressed on
kitchen-sink (alternating flings so the atom paragraph repeatedly
enters/leaves the viewport, forcing pill redraws): CPU settled to **0.0%**,
thread count 16→3 — no livelock. There is no atom-heavy stress fixture;
re-check at T13 if one is added.

## Phase 3 — Task 11: list/panel baseline parity (measurement only)

Task 7 gave `TextKit2RowView` a `.alignmentGuide(.firstTextBaseline)` that
returns `firstBaseline(of:categoryRawValue:)` — the first `.text` run's
resolved-font `.ascender`, a pure function of the resolved `FontSpec` (never
measured layout, per §16). This is what `ListRowView`
(`Sources/ADFRendering/Blocks/ListBlockView.swift:32`,
`HStack(alignment: .firstTextBaseline)`) and `PanelBlockView`
(`PanelBlockView.swift:16`) align bullet/number/checkbox/decision markers
and panel icons against. This task measures whether that computed baseline
actually lines markers/icons up with the real first line of text as well as
the SwiftUI (`Text`) arm does — the acceptance bar from the brief is ≤1pt
drift at default size, ≤2pt at `-fontSizeStep 3`.

### Method

Sim `ADF-Task11` (iPhone 16, iOS 18.2), created for this task, deleted at
the end. Demo built once (`xcodebuild … build`, `xcrun simctl install`) and
exercised via `-fixture kitchen-sink -scrollToFraction <f> [-textkit2]
[-fontSizeStep 3]`, screenshotted with `axe screenshot`. `kitchen-sink` has a
bulletList (depth 0 + a nested depth-1 item), an `orderedList`, 7 `panel`s
(info/note/tip/success/warning/error/custom), a 2-item `taskList`, and a
1-item `decisionList` — `f=0.27` (block 10/37) frames the lists+panels in
one screenshot; `f=0.755` (block 28/37) frames the task/decision rows.

Pixel measurement is Python3 + PIL, reading the PNGs directly (@3x, so
1px = ⅓pt). For each row:

1. **Column-group the row band** (`col_groups`): scan for contiguous
   non-background columns (background sampled locally — plain white for
   list rows, the panel's own pastel fill for panel rows, the decision
   row's tinted container fill for the decision row) with a gap tolerance
   (14px) wide enough to bridge intra-word glyph gaps (e.g. the two strokes
   of a double "l") but not wide enough to bridge the HStack's
   marker-to-content spacing. The first group is the marker/icon; the next
   is the first text word.
2. **Ink bounding box** of the marker group and of the text-word group
   (`ink_bbox`), each within a y-window padded a few px above/below the
   row band.
3. **offset = text_word.bottom − marker.bottom**, computed independently in
   the OFF screenshot and the `-textkit2` screenshot of the *same* row.
4. **drift = offset(TK2) − offset(OFF)**, in px, ÷3 for pt.

Step 4 is the load-bearing move: it never treats either screenshot's
absolute offset as "the" baseline distance (a bullet dot or panel icon
has no universally meaningful "baseline" of its own, and several row
labels — "Tip panel", "Warning panel" — contain descenders that shift a
naive bbox-bottom down). Instead it asks "does TK2 place the marker
relative to the text the same way OFF does for this exact row", which is
translation-invariant (immune to the two screenshots' scroll positions
not lining up to the pixel) and cancels any systematic bias from a
descender or a marker's own glyph shape (same glyph, same word, in both
arms — only the text-rendering engine behind it differs).

### Measurements (worst-case drift per row)

| Row | Default drift | `-fontSizeStep 3` drift |
|---|---|---|
| Bullet, depth 0, item 1 ("First bullet") | 0px | 0px |
| Bullet, depth 0, item 2 ("Second bullet") | 1px (0.33pt) | 1px (0.33pt) |
| Bullet, depth 1 ("Nested bullet") | 0px | 0px |
| Ordered, item 4 | 1px (0.33pt) | 0px |
| Ordered, item 5 | 0px | 1px (0.33pt) |
| Panel: Info | 0px | 1px (0.33pt) |
| Panel: Note | 0px | 1px (0.33pt) |
| Panel: Tip | 1px (0.33pt) | 0px |
| Panel: Success | 1px (0.33pt) | 0px |
| Panel: Warning | 1px (0.33pt) | 0px |
| Panel: Error | 1px (0.33pt) | 0px |
| Panel: Custom | 0px | *(clipped off-screen at step3, not measured)* |
| Task checkbox, unchecked ("Write the parser") | 0px | 0px |
| Task checkbox, checked ("Design the schema") | 1px (0.33pt) | 0px |
| Decision ("Use Swift 6 strict concurrency") | 0px | 1px (0.33pt) |

**Worst-case drift: 1px ≈ 0.33pt, at both default and `-fontSizeStep 3`.**
Comfortably inside the brief's ≤1pt / ≤2pt bars — the 1px figure is at the
resolution floor of the measurement itself (a single subpixel rounding
difference between `TextRowLayout`'s TextKit 2 line metrics and `Text`'s,
not a systematic misalignment). **Verdict: within tolerance — no change to
`firstBaseline` needed** (brief Step 3 is a no-op; Step 4's fix path was not
taken).

Screenshots (`docs/assessment-assets/phase3-baselines/`, `t11_` prefix):
`t11_{off,tk2}_lists.png` (default, lists+panels), `t11_{off,tk2}_lists_step3.png`
(`-fontSizeStep 3`), `t11_{off,tk2}_tasks.png` / `t11_{off,tk2}_tasks_step3.png`
(task/decision rows, both sizes).

### Observation (not a marker/baseline defect — recorded for T13)

The row *bands themselves* drift downward across the TK2 screenshot
relative to OFF as you move down the bulletList/panels region — e.g. the
bullet rows' y-position grows apart by ~5-6px per row, reaching ~22px by
the 5th row; the panel bands are ~5px taller in TK2 than OFF. This is a
**row-height/line-height difference between `TextRowLayout` (TextKit 2)
and SwiftUI `Text`**, not a marker-to-text misalignment — the marker inside
each row still tracks that row's own (taller-or-not) text baseline within
1px, per the measurements above. It matches Task 7's report ("the only
differences are sub-pixel vertical rhythm … Task 13's pixel-perfection
job, not gross breakage"); it isn't cumulative in the task/decision
screenshot because `-scrollToFraction` anchors to a nearby block rather
than carrying a continuous pixel offset from the top. Left to T13.

### Checkbox toggle under `-textkit2`

Launched `-textkit2 -fixture kitchen-sink -scrollToFraction 0.755`,
`axe describe-ui` found the unchecked task ("Write the parser") as
`Button "Task"`; `axe tap --label "Task" --element-type Button` toggled it.
`describe-ui` afterward shows both task rows labeled `"Completed task"`,
and the screenshots (`t11_checkbox_before.png` / `t11_checkbox_after.png`)
confirm the glyph flips from an empty square to a filled blue checkmark.
Checkboxes toggle correctly under the TK2 renderer.

### Verification

`swift test`: **223/223 pass**, 37 suites (unchanged — no code touched).
No new build warnings. No commit to `TextKit2RowView.swift`; this section
and the screenshot assets are the only changes.

## Phase 3 — Task 12: RTL + AX3 fixtures

### The predicted bug

The design red-team flagged `TextRowContent.make` (`Sources/ADFRendering/
TextKit2/TextRowContent.swift`): it accepted a `rightToLeft` parameter but
discarded it (`_ = rightToLeft`) and always set `paragraphStyle.alignment =
alignment` verbatim. `TextKit2RowView.nsAlignment` resolves `.center` and
(host-direction-flipped) `.trailing` explicitly, but its default case — "no
alignment mark", the common row — passes `NSTextAlignment.natural` straight
through (there is no "leading" case on `NSTextAlignment`). Meanwhile
`RichTextBlockView`'s `nil → .leading` mapping makes the SwiftUI arm's
"no mark" case explicitly host-direction-relative. The predicted failure:
`.natural`, resolved by TextKit against the paragraph's own first-strong
Bidi character, would make an Arabic paragraph render right-aligned under
TK2 even inside an LTR host, while the SwiftUI arm renders it left-aligned
— a visible mismatch.

### Fixture

`Fixtures/rtl-mixed.json`: 4 paragraphs (pure Arabic; Arabic with an
embedded bold Latin word, "SwiftUI"; a `center`-marked Arabic paragraph; an
`end`-marked Arabic paragraph) plus a 2-item Arabic `bulletList`. Follows
`kitchen-sink.json`'s doc-wrapper shape. Verified by launching
`-fixture rtl-mixed` (bundled automatically — `Demo/project.yml`'s
`../Fixtures` source glob picks up any file under `Fixtures/`, no
`project.yml`/`xcodegen` change needed).

### TDD: proving and fixing the gap

Added a red test to `Tests/ADFRenderingTests/TextRowContentTests.swift`
(`naturalAlignmentResolvesPerHostDirection`) asserting the paragraph
style's resolved `.alignment` for `(alignment: .natural, rightToLeft:
false/true)` — it failed before any fix (`NSTextAlignment(rawValue: 4)`
i.e. `.natural`, not the expected `.left`/`.right`), proving the gap
deterministically at the unit level regardless of any simulator/OS
resolution quirk.

Fix, in `TextRowContent.make`:

```swift
paragraphStyle.alignment = alignment == .natural ? (rightToLeft ? .right : .left) : alignment
paragraphStyle.baseWritingDirection = .natural
```

`.natural` — the signal `nsAlignment`'s default case emits for "no
alignment mark" — now resolves to an explicit `.left`/`.right` per the
already-threaded `rightToLeft` bool, mirroring `RichTextBlockView`'s
`nil → .leading` mapping exactly. Any other value (`.center`, or the
already-flipped `.left`/`.right` `nsAlignment`'s `.trailing` case
produces) passes through unchanged — `nsAlignment`'s existing logic is
untouched. `baseWritingDirection` stays `.natural`: per-paragraph Bidi run
direction (glyph ordering within a line) is still TextKit's to resolve;
only the alignment *side* is pinned to the host. Three more tests
(`resolvedTrailingAlignmentPassesThroughUnchanged`,
`centerAlignmentUnaffectedByDirection`) cover the two "already resolved"
inputs). All are `@MainActor`, macOS-runnable (no `#if os(iOS)` gate) —
they run under plain `swift test`, not just the iOS-only UIView suite.

### RTL screenshot matrix — OBSERVED results

Sim `ADF-Task12` (iPhone 16, iOS 18.2), created for this task. Built via
`cd Demo && xcodegen generate && xcodebuild … build`, installed, then
`-fixture rtl-mixed` launched in all four combinations (screenshots under
`docs/assessment-assets/phase3-rtl/`, `t12_` prefix):

**Methodology note (deviation from the brief's literal flag):**
`-AppleLanguages '(ar)'` alone does **not** flip `layoutDirection` for this
demo app — confirmed by pixel-diffing `t12_off_ltr.png` against an
`-AppleLanguages (ar)`-only capture: identical `x` bounds for every row,
only a few px of vertical drift (Arabic-font metric substitution, not a
direction change). Root cause: the app bundle has no `.lproj` at all
(`CFBundleDevelopmentRegion = en`, confirmed via `PlistBuddy`/`ls
ADFReader.app | grep lproj`), so `Bundle.main.preferredLocalizations`
always resolves to `en` regardless of `-AppleLanguages` — there is no `ar`
localization to select. The flag that actually forces RTL for an
unlocalized app is `-AppleTextDirection YES
-NSForceRightToLeftWritingDirection YES`; the RTL captures below use that
(plus `-AppleLanguages '(ar)'` for Arabic font shaping) and it visibly
flips chrome (nav-bar icon order reverses) as well as content.

Ink bounding boxes (Python3 + PIL, column-scanning each row's non-white
pixels — same method as Task 11) confirm, for every row, in both locales:

| Paragraph | OFF (LTR) | TK2 (LTR) | OFF (RTL-forced) | TK2 (RTL-forced) |
|---|---|---|---|---|
| ¶1 pure Arabic (no mark) | left, `x∈[46,470]` | left, `x∈[48,470]` | right, `x∈[703,1127]` | right, `x∈[703,1127]` |
| ¶2 Arabic+Latin (no mark) | left, `x∈[51,1079]` | left, `x∈[51,1079]` | right, `x∈[99,1127]` | right, `x∈[99,1127]` |
| ¶3 `center` mark | center, `x∈[371,808]` | center, `x∈[370,808]` | center, `x∈[371,808]` | center, `x∈[370,808]` |
| ¶4 `end` mark | right, `x∈[634,1127]` | right, `x∈[634,1127]` | left, `x∈[51,544]` | left, `x∈[51,544]` |
| bulletList (2 items) | left, indented | left, indented | right, indented | right, indented |

**Acceptance: PASS in both locales** — every paragraph's alignment side
matches between OFF and TK2 (sub-1-2px differences are the same
TextKit-vs-`Text` sub-pixel rounding Task 11 already characterized, not a
direction bug).

**Did the predicted bug actually reproduce?** Screenshots alone, taken
*after* the fix above, can't answer that — so the fix was reverted
(`git stash`), the demo rebuilt, and `-fixture rtl-mixed -textkit2`
recaptured in both locales (`t12_beforefix_tk2_{ltr,rtl}.png`). Pixel
measurement showed the **pre-fix** build *also* matched OFF in both
locales (identical `x` bounds to the post-fix captures above) — the
predicted visual mismatch did not reproduce via this launch-argument-driven
test. Reasoning: `-AppleTextDirection YES` forces
`effectiveUserInterfaceLayoutDirection` app-wide, for *every* view
including the raw `UIView` `TextKit2RowUIView` wraps — so pre-fix
`NSTextAlignment.natural` (documented as "align according to the user's
default language") tracked the same forced direction as SwiftUI's
`layoutDirection` environment, coincidentally agreeing with it. This is
exactly why the fix is still correct to make: that agreement is incidental
to a *global* UIKit-wide override, not to the codebase's own explicit
`rightToLeft` signal — a narrower override (e.g. a future per-document
`.environment(\.layoutDirection, …)` that doesn't reach a
`UIViewRepresentable`'s own `UIView.semanticContentAttribute`, since
SwiftUI environment values don't auto-propagate there) would still diverge
pre-fix. The **unit test is the reliable, deterministic reproduction** of
the bug (§ above); the simulator matrix is corroborating evidence that the
fix introduces no regression, not proof the bug was simulator-visible.
Fix kept.

### AX3 wrap parity

Ladder: `Sources/ADFRendering/DynamicTypeStep.swift`'s `DynamicTypeSize.
allCases` is `[xSmall, small, medium, large, xLarge, xxLarge, xxxLarge,
accessibility1…5]` (12 rungs, index 0–11). `ReaderView`'s `systemTypeSize`
reads the ambient `@Environment(\.dynamicTypeSize)`, which is `.large`
(index 3) on a freshly-created, un-configured simulator. `accessibility3`
is index 9, so **`-fontSizeStep 6`** (`3 → 9`) reaches it exactly — no
"max step" fallback needed.

`kitchen-sink -fontSizeStep 6`, OFF vs `-textkit2`, three long/complex
paragraphs (screenshots `t12_ax3_{off,tk2}_p{1,2,3}.png`):

1. **¶1** (bold/italic/underline/strike/code/sub/sup/color/highlight/
   small/link/annotation marks + a `hardBreak`): **6 lines**, identical
   wrap points, in both arms.
2. **¶26** (`Ping [@mention] [emoji] due [date] see [inlineCard] [placeholder]
   [mediaInline] [inlineExtension]`, atom-heavy): **7 rows**, identical
   structure/order, in both arms.
3. **¶27** (6 status-badge atoms, `NEUTRAL`/`PURPLE`/`BLUE`/`RED`/
   `YELLOW`/`GREEN`) plus the following `taskList` and `decisionList`:
   **4 lines** (status paragraph) + **2 lines** (checked task, wraps
   "Design the schema" to its own line) + **3 lines** (decision item) —
   identical in both arms.

**Verdict: exact line-count parity** at the AX3-equivalent step for all
three paragraphs (and the two list rows checked alongside them) — no
resolver bug, no divergence to investigate.

**Known, non-blocking observation (already documented at Task 10, not a
new Task-12 finding):** at this accessibility size, ¶26's `attachment` and
`Inline macro` atom chips still render without their SF Symbol icon under
TK2 (narrower, no glyph, no tint) — the exact "Chip SF Symbols omitted in
v1" gap Task 10 recorded as deferred to phase-4/T13. It affects chip
*width/styling* only; the line-wrap *count*, which is what this task
measures, is unaffected and matches exactly.

### Verification

`swift test`: **226/226 pass** (223 baseline + 3 new `TextRowContentTests`
cases), 37 suites. Warning count unchanged (2: the pre-existing
`ADFBeamTests` unhandled-resource notice and the pre-existing
`IncrementalSearchIndexTests` redundant-`#require` notice — both predate
this task). `Fixtures/rtl-mixed.json` is picked up by `Demo/project.yml`'s
existing glob; no `project.yml` edit needed (the generated `.xcodeproj` is
gitignored and regenerated via `xcodegen generate`, so it was not
hand-edited in the final state).

## Phase 3: final gates + parity (Task 13)

Measurement-only task — no production code changed (`swift test`: 226/226,
37 suites, unchanged from Task 12's baseline). This is the final measurement
pass of the port plan: the full Phase-2 gate matrix re-run now that Phase-3
features (TK2 rows, draw-pass search highlights, vector pills, baseline
guides, the RTL fix, and the settle-window rotation fix, commits `165db39`+
`f069ab1`) are all in, plus the first exercise of the YouTube video path and
the first dark-mode pass.

### Environment

Dedicated sim `ADF-Task13` (iPhone 16, iOS 18.2, UDID
`509FBF6C-3EB4-4B9B-87F6-AAFBDE163400`), created for this task, deleted at
the end. Branch `textkit2-port-prototype` at `a85ac97`. Demo built once via
`xcodebuild -project Demo/ADFReader.xcodeproj -scheme ADFReader -destination
'platform=iOS Simulator,id=<ADF-Task13>' build` (BUILD SUCCEEDED) and
installed; confirmed current by `strings` on `ADFReader.debug.dylib`
(`-textkit2NoCells`, `-scrollToFraction`, `-fontSizeStep` all present) and by
dylib mtime (Jul 18 11:16) postdating the HEAD commit timestamp (Jul 18
11:08:01). One build served the entire session — every gate below ran
against the identical binary.

### Gate 1 — stress-5k autoscroll, OFF vs `-textkit2`, ×2 each (kill criterion: ON ≤ 2× OFF)

```
OFF run 1: SCROLL_METRICS fixture=stress-5k frames=29879 dropped=18 hitchRatioMsPerS=0.61
OFF run 2: SCROLL_METRICS fixture=stress-5k frames=29887 dropped=20 hitchRatioMsPerS=0.68
ON  run 1: SCROLL_METRICS fixture=stress-5k frames=29835 dropped=22 hitchRatioMsPerS=0.75
ON  run 2: SCROLL_METRICS fixture=stress-5k frames=29824 dropped=32 hitchRatioMsPerS=1.06
```

OFF mean 0.645 ms/s, ON mean 0.905 ms/s → ratio **1.40×** — comfortably
inside the ≤2× bar. **PASS.**

### Gate 2 — giant-table autoscroll, OFF vs `-textkit2` vs `-textkit2 -textkit2NoCells`

```
OFF:              SCROLL_METRICS fixture=giant-table frames=2456 dropped=0 hitchRatioMsPerS=0.00
-textkit2:        SCROLL_METRICS fixture=giant-table frames=2449 dropped=0 hitchRatioMsPerS=0.00
-textkit2 NoCells: SCROLL_METRICS fixture=giant-table frames=2443 dropped=1 hitchRatioMsPerS=0.41
```

Cells do not blow the gate (ON ties OFF at 0.00 ms/s; NoCells is still
comfortably low). No exclusion needed. **PASS.**

### Gate 3 — fling burst + instantaneous CPU settle, stress-5k, both branches

12× `axe swipe --start-x 220 --start-y 800 --end-x 220 --end-y 120
--duration 0.08`, `sleep 3`, `top -l 2 -pid <pid>` (second sample):

| Branch | PID | Settled %CPU |
|---|---|---|
| OFF | 32266 | 0.3 |
| `-textkit2` | 32388 | 0.2 |

Both settle to near-zero. No livelock either branch. **PASS.**

### Gate 4 — first chunk, kitchen-sink `-textkit2` (target < 150 ms)

```
READY fixture=kitchen-sink blocks=38 firstChunkMs=37   (run 1)
READY fixture=kitchen-sink blocks=38 firstChunkMs=38   (run 2)
```

Both well under the 150 ms gate. **PASS.**

### Gate 5 — rotation retention, stress-5k `-scrollToFraction 0.5`, 8× rotation round-trips, both branches (bar: ABSOLUTE ≤1-row drift + A/B parity, now that the settle-window fix — `165db39`+`f069ab1` — is in)

Same block-index-aligned-heading protocol as Phase 2's Gate 5
(`scrollTarget = blocks[2500]` = `"Section 2500: spline expand fixture"`,
exact). Fixed a timing bug from the first attempt this session: the initial
5 s post-launch sleep before the "before" screenshot occasionally landed
before `-scrollToFraction` had settled (one discarded run showed `Section 0`
at the top); switched to polling the launch log for the `READY` line before
screenshotting, and widened the inter-rotation sleep from 2 s to 2.5 s so
each `UIWindowScene.requestGeometryUpdate` animation completes before the
next Darwin notification fires (confirmed by the `ROTATION requested=`
log lines alternating `landscapeRight`/`portrait` cleanly across all 8, and
by the final screenshot's file dimensions reading back as portrait,
`1179×2556`, not a mid-transition size).

| Branch | Before (top heading) | After 8 rotations | Drift |
|---|---|---|---|
| OFF | `Section 2500: spline expand fixture` | `Section 2500: spline expand fixture` | **0 rows** |
| `-textkit2` | `Section 2500: spline expand fixture` | `Section 2500: spline expand fixture` | **0 rows** |

Both before/after screenshot pairs were read directly. OFF is byte-level
pixel-identical below the status bar. ON holds the identical content
position (0-row drift; the whole visible paragraph, including the
highlighted link run and the strikethrough run, at the same rows) but is
not byte-identical: an independent review cross-correlation found a genuine
~1px vertical text-hinting jitter (best-fit dy=−1, ~20k differing pixels)
plus incidental clock/home-indicator chrome — sub-line rendering jitter,
not retention drift. Screenshots:
`docs/assessment-assets/phase3-final/t13_rot_{off,on}_{before,after}.png`.

**This is a large improvement over Phase 2's Gate 5** (~70–100 block drift,
~1.4–2.0% of the document, in both branches, on iOS 26.2) and validates the
Phase-2 fix commits' own iOS 18.2 numbers (≤4-block drift, 5/5 runs) at the
now-achievable **absolute 0-row** bar. **PASS**, both branches, A/B parity
exact.

### Gate 6 — §19 mid-scroll type-size reflow, kitchen-sink `-textkit2 -fontSizeStep 3`

`t13_step6_default.png` vs `t13_step6_step3.png`: text is visibly larger at
step 3, and the inline code span `let x = 1` wraps from one line (default)
to two (`let x` / `= 1`) — confirms TK2 rows reflow, not just up-scale.
**PASS.** Mid-scroll live popover-driven size change: not attempted this
session (brief marks it optional, same as Phase 2's Gate 6) —
**UNTESTED (optional)**.

### Gate 7 — memory, media-gallery `-textkit2` (target < 150 MB)

8× swipe through the gallery, settle, `top -l 1 -pid <pid>`: **59 MB**
(RSS). Well under budget. **PASS.**

### Gate 8 — VIDEO gate (first exercise of the YouTube path in phases 2–3; nothing since its original implementation touched this code)

Fixture: `youtube` (`Fixtures/youtube.json` — chosen over `youtube-dense.json`
for a focused, fast-to-navigate matrix; it covers an embed card, a block
card, a paragraph-wrapped smart link, and a table-cell embed, one of each
shape the renderer claims). Screenshots under
`docs/assessment-assets/phase3-final/`, `t13_video_*` prefix.

**Facade → player, same box.** Launch `-fixture youtube -textkit2`: facade
renders (thumbnail + red play button) for every claimed block
(`t13_video_facade.png`). `axe describe-ui` located the Rick Astley embed
card's "Play YouTube video" button at `{x:16, y:281.67, width:361,
height:203}` (points); `axe tap -x 196.5 -y 383` (its center) opens the real
player in place (`t13_video_player.png`, `0:01 / 3:34`, actively playing).
Pixel-measured (Python3/PIL, column/row non-white-pixel scan) box bounds, at
3× capture (`1179×2556`):

| State | top | bottom | left | right | size (px) |
|---|---|---|---|---|---|
| Facade | 845 | 1453 | 48 | 1130 | 1082×609 |
| Player (after tap) | 845 | 1453 | 48 | 1130 | 1082×609 |

**Identical to the pixel** — 1082×609 px is exactly a 16:9 box (matching
`YouTubeBlockRenderer`'s declared `sizing: .aspectRatio(width: 16, height:
9)`), and the facade→player swap changes none of it. **PASS.**

**Scroll away / scroll back.** 5× downward swipes move the viewport past
the video, a table-cell embed, and into the "Controls: must stay cards"
section (`t13_video_scrolled_away.png` — confirms non-YouTube links, e.g.
`vimeo.com`, correctly keep their existing card rendering, not a facade).
5× upward swipes return to the top: `t13_video_facade_returned.png` is
pixel-identical to the original `t13_video_facade.png` — the player tore
down and the facade re-rendered in the same box. **PASS.**

**Fling through an active player.** Fresh launch, tapped play
(`t13_video_flingthrough_before.png`, playing), then a single vertical swipe
from `(220, 900)` — inside the player's box — to `(220, 250)`:
`t13_video_flingthrough_after.png` shows the document scrolled down to the
same "Controls: must stay cards" region reached by the multi-swipe scroll-
away above. The gesture passed through the `WKWebView` to the parent scroll
view rather than being captured by the player. **PASS.**

**2× rotation round-trip over an active player.** Fresh launch, tapped
play, 2 round-trips (4× `notifyutil -p com.connie.adfreader.rotate`, 2.5 s
apart). Box bounds measured identically at every checkpoint:

| Checkpoint | top | bottom | left | right |
|---|---|---|---|---|
| Before rotation | 845 | 1453 | 48 | 1130 |
| After round-trip 1 | 845 | 1453 | 48 | 1130 |
| After round-trip 2 | 845 | 1453 | 48 | 1130 |

Geometry is pixel-stable across both round-trips; playback continued
throughout (each screenshot shows a different video frame, not a frozen
one) — `t13_video_rotate_{before,rt1,rt2}.png`. **PASS.**

All five VIDEO sub-checks pass. **Gate 8 verdict: PASS.**

### Gate 9 — screenshot parity suite: {OFF, ON} × {kitchen-sink, rtl-mixed} × {default, `-fontSizeStep 6`} × {light, dark}, plus giant-table ON default light

17 screenshots under `docs/assessment-assets/phase3-final/`, `t13_` prefix
(`t13_{off,tk2}_{ks,rtl}_{default,step6}_{light,dark}.png` +
`t13_gianttable_tk2_default_light.png`), dark toggled live via `xcrun simctl
ui $D appearance dark` (confirmed it applies to a running app without
relaunch). Every one of the 8 OFF/TK2 pairs was read directly, side by side:

| Pair | Result |
|---|---|
| kitchen-sink, default, light | Pixel-matching; known ≤1px baseline / cumulative vertical-rhythm drift only (Task 11) |
| kitchen-sink, default, dark | Same match; dark colors correct (see below) |
| kitchen-sink, step 6, light | Pixel-matching, identical wraps |
| kitchen-sink, step 6, dark | Pixel-matching, identical wraps |
| rtl-mixed, default, light | Pixel-matching; right-alignment identical both arms |
| rtl-mixed, default, dark | Pixel-matching |
| rtl-mixed, step 6, light | Matching wraps, sub-pixel rhythm drift only |
| rtl-mixed, step 6, dark | Matching wraps, sub-pixel rhythm drift only |

giant-table `-textkit2` default light (`t13_gianttable_tk2_default_light.png`):
renders cleanly, cell background tints (blue/pink/green highlight cells)
intact, no artifacts.

**No new layout/structural diffs.** The only diffs are the two already-known,
already-documented ones (chip icon widths, Task 10; ~5–6px cumulative
vertical rhythm down long lists, Task 11) — carried forward, not
regressions.

### Dark-mode result (first dark-mode check of this port)

Toggling `xcrun simctl ui $D appearance dark` and re-reading the kitchen-sink
and rtl-mixed pairs above: headings, body text, `colored`/`highlighted`
marks, links, quote bars, and code-block backgrounds all switch to their
dark-appropriate colors identically between OFF and `-textkit2` — no
TK2-specific dark-mode defect in body text.

**Atom pills were also captured specifically in dark mode**
(`-fixture kitchen-sink -scrollToFraction 0.68`, atoms-heavy paragraph;
`t13_atoms_{off,tk2}_dark.png`, crops at `t13_atoms_{off,tk2}_dark_chipcrop.png`),
since Task 10 flagged this as verified in light mode only. Result:

- **Capsules (mention, date, status badges) adapt correctly and match
  exactly** — `@Bharath` navy capsule/blue text, `Jul 9, 2024` dark-gray
  capsule/light text, and all six status badges (NEUTRAL/PURPLE/BLUE/RED/
  YELLOW/GREEN) render with the same dynamic-color-adapted tinted
  backgrounds and text in both arms.
- **One wrong-color finding, not previously documented:** the `inlineCard`
  chip (`example.atlassian.net`) renders its text in **blue (the link/tint
  color)** on the OFF (SwiftUI) arm, in both light and dark mode, but in
  **plain label color** (black in light, white in dark) on the `-textkit2`
  arm — confirmed by direct crop comparison
  (`t13_atoms_{off,tk2}_dark_chipcrop.png`) and traced to source:
  `Sources/ADFRendering/TextKit2/AtomAttachment.swift:165` sets
  `textColor = .label` uniformly for every `.chip`-style atom (inlineCard,
  mediaInline, inlineExtension), while
  `Sources/ADFRendering/Inline/AtomViews.swift`'s `InlineCardChip` wraps
  only the inlineCard case in a SwiftUI `Link`, which applies the
  environment's tint (blue) to its label — a distinction `AtomAttachment`
  doesn't replicate. This reproduces identically in light mode too (re-
  checked against the existing Task 10 screenshots,
  `docs/assessment-assets/phase3-pills/t10_kitchensink_{off,tk2}_atoms.png`)
  — it is **not** a new dark-mode regression, but a previously-undocumented
  refinement of the known "chip SF Symbols omitted" gap: the chip is
  missing its icon **and** its link tint, not just the icon. The
  `attachment`/`Inline macro` chips (never tinted on either arm) are
  unaffected and match correctly.

**Dark-mode verdict: PASS**, with one real, now-documented, low-severity
color gap (inlineCard chip tint) rolled into the existing chip-styling gap
below — no new structural or layout defect in dark mode.

### Known-gaps register (consolidated for the phase-4 planner)

Pulled together from Tasks 8, 10, 11, 12, and this task — the complete list
of intentional or discovered TK2-arm gaps still open at the end of Phase 3:

1. **Chip styling is incomplete** (Task 10, refined here): SF Symbol icons
   are omitted (chips ~18.7pt/~22pt narrower than the SwiftUI arm), and the
   `inlineCard` chip's text lacks its blue link tint (renders in default
   label color instead) — both in light and dark mode. Capsules (mention/
   date/status) are unaffected and pixel-accurate.
2. **Atom taps are not hit-tested on the TK2 arm** (mention popovers,
   inline-card link taps) — works on the SwiftUI arm; TK2 hit-testing is
   phase-4 (selection/geometry) work (Task 10).
3. **Whole-pill search highlight tinting is not applied on the TK2 arm** —
   range highlights inside atom-bearing paragraphs work; a matched atom
   pill itself doesn't tint the way it does on the SwiftUI arm (Task 10).
4. **`firstBaseline` returns the `0` fallback for a pure-atom row** (a
   paragraph with no text run at all); atom-leading rows with any following
   text are correct (Task 10).
5. **Row-height/line-height vertical rhythm drift**: TK2 rows run slightly
   taller than the SwiftUI arm's down a long list/panel region (~5–6px
   growing to ~22px by the 5th row in Task 11's measurement) — a
   `TextRowLayout` vs. SwiftUI `Text` line-height difference, not a
   marker-to-text misalignment (markers still track their own row's
   baseline within 1px). Reconfirmed present, unchanged, in this task's
   parity suite. Flagged as "Task 13's pixel-perfection job" since Task 7;
   still open — carried to phase-4.
6. **No atom-heavy stress fixture exists** to check the pill draw path's
   behavior at stress-5k-like scale (Task 10); worth adding if phase-4 does
   further pill work.
7. **RTL fix has no simulator-visible regression test** — only the unit
   test (`naturalAlignmentResolvesPerHostDirection`) reliably reproduces the
   pre-fix bug; the launch-argument-driven simulator matrix is regression
   evidence only, since `-AppleTextDirection YES` forces a global direction
   override that masked the bug pre-fix too (Task 12). A future narrower
   (per-view) direction override would need this test.
8. **Accessibility: a `UITextInput`-conforming ancestor collapses its
   descendants into one opaque `AXTextArea`** for accessibility tooling —
   recorded as a spike constraint (see the Spike section); the selection
   controller design in phase 4 must budget dedicated accessibility work,
   and TK2 rows themselves have no accessibility wiring yet (Task 10 note).
9. **Copy/edit-menu responder wiring is not free**: `UITextInteraction` on
   a custom container omits Copy unless `copy(_:)`/`canPerformAction` are
   explicitly implemented (spike row 8's FAIL) — a required phase-4
   selection-controller work item, not an optional polish.
10. **`TextRowLayoutTests.sameInputSameWidthMeasuresIdentically` flaked
    once in ~30 combined full-suite runs** across phases 1-3 (pre-existing
    on base, unrelated to any TK2 change; suspected parallel-test cache
    contention — Task 9's concerns section). Layout determinism underpins
    the `CollapsedRowHeight` exact-replay contract, so this can't just be
    waved off: a serial-vs-parallel discriminator run (e.g. N=100 serial)
    must precede any production-port decision.
11. **The mid-scroll LIVE type-size change** (in-app popover while
    scrolled deep, over materialized TK2 rows) was marked optional/
    UNTESTED in both Gate-6 runs (Phase 2 and Task 13). Spec §10 names it
    explicitly, and it exercises exactly the §19-re-pin-over-TK2-rows path
    phase 4 leans on — it must be run in phase 4, not deferred again.
12. **Spec §10's idle-soak and scene-snapshot-thrash gates** (backgrounding
    through Home/lock/app-switcher) were never run across phases 1-3.

**Resolved, not carried forward:** the rotation-retention drift that
dominated Phase 2's Gate 5 discussion (~70–100 block drift, both branches,
iOS 26.2) is fixed by `165db39`+`f069ab1` and reconfirmed at the **absolute
0-row** bar on iOS 18.2 in this task (Gate 5 above) — no longer an open
item.

### Phase 3 final verdict

All 8 numbered gates in this task's matrix **PASS**, several with
comfortable-to-large margin (rotation retention improved from ~70–100 block
drift to 0; giant-table ties or beats OFF; fling settles to ≤0.3% CPU both
branches; memory at 39% of budget). The video path — untouched by any
Phase-2/3 change — passes its first-ever exercise cleanly, including
geometry stability under rotation and gesture pass-through while a real
player is active. The screenshot parity suite finds **no new structural
diffs**; the dark-mode pass (also a first) finds body text, headings, links,
and capsule pills all correctly dynamic-color-adapted, with one small,
newly-precise (not newly-introduced) color gap in `inlineCard` chip tinting.

**Recommendation: the TK2 port has cleared all phase 1–3 kill/proceed gates.**
The twelve open items in the known-gaps register above are phase-4 work
(chip icon+tint, atom hit-testing, pill search-tint, pure-atom-row
baseline, vertical rhythm, an atom-stress fixture, a narrower RTL
regression test, accessibility ancestor-collapse budgeting, copy/edit-menu
responder wiring, the layout-determinism flake discriminator, the
mid-scroll live type-size gate, and the idle-soak/scene-thrash gates) —
none of them perf or correctness regressions, none of them block shipping
the toggle for further internal dogfooding. Backporting the
rotation-retention fix (`165db39`+`f069ab1`) to `main` independent of this
port remains recommended, as noted in Phase 2.

## Phase 4 — Task 16: introspected ancestor attachment over the real document (KILL-FAST #1)

**Kill question (spec §7/§10):** the phase-1 spike proved
`UITextInteraction(.nonEditable)` on an ancestor coexists with descendant
gestures — but on a *synthetic* `SpikeViewController` (its own `UIScrollView`
+ `UILabel`s, labels non-interactive). Does the same ancestor-attachment model
deliver text selection when the ancestor is SwiftUI's real `ADFDocumentView`
scroll-view content container and the descendants are the production
SwiftUI-hosted, interactive TK2 rows (links, `TaskMarkerView` checkboxes, the
YouTube facade, `TableScrollSync` code/table h-pans)?

**Verdict: KILLED — fall back to the geometry-oracle overlay (spec §10).**
The introspection itself works (once placed correctly), but
`UITextInteraction` attached to the introspected ancestor **does not begin a
selection over the SwiftUI-hosted TK2 rows**. It also does no harm — the
descendant gesture ecosystem is fully intact — but a selection engine that
never selects is non-viable, so the architecture dies here, cheapest, exactly
as this task was positioned to determine.

### What was built (as committed, brief-faithful)

- `Sources/ADFRendering/TextKit2/Selection/SelectionFlags.swift` — `-selection`
  (requires `-textkit2`), read once as a launch constant.
- `.../Selection/ScrollViewIntrospector.swift` — a zero-size, hidden,
  non-interactive `UIView` (`ProbeView`) that walks `superview` upward to the
  first `UIScrollView` and takes `scrollView.subviews.first` as the attachment
  container. No `hitTest` override (spec §7).
- `.../Selection/SelectionController.swift` — a detached responder conforming
  to `UITextInput`, crude whole-container geometry, placeholder corpus. Copy/
  `canPerformAction` intentionally unwired (Task 20).
- `ADFDocumentView.swift` — installs the probe behind `-selection` at the
  document-**content** level (see finding #1), and a read-only corpus accessor
  was added to `ADFDocumentSearch` (`selectionCorpusPlainText`, internal,
  read-only, no scroll-path/observable write) to back the placeholder model.

### Compiler-forced deviations from the brief's literal code (like the spike's two)

1. **`SelectionController: UIResponder`, not `NSObject`.** The SDK types
   `UITextInteraction.textInput` as `UIResponder <UITextInput> *`
   (`UITextInteraction.h`, Xcode 26.3 / iOS 26.2 SDK), so `interaction.textInput
   = self` does not compile for a plain `NSObject`. `UIResponder` is an
   `NSObject` subclass and still "not a `UIView`", so the brief's intent (a
   plain object attached to the container, not an interactive view) holds.
2. **Probe hosted inside the scroll *content*, not on the `ScrollView`** — see
   finding #1. The brief's Step-4 snippet placed `.background` on the
   `ScrollView`; that placement cannot introspect (finding #1), so the probe
   moved one level in, to a `.background` on the row stack. Still
   document-container level, never per row (§18 intact — a stable
   `_ConditionalContent` on a launch constant).
3. **Edit-menu interaction not added.** Step 2's prose mentions installing a
   `UIEditMenuInteraction`; the concrete interface + Step 3 list only the
   `UITextInteraction`, and the spike proved the menu arrives via
   `UITextInteraction` alone. A second, delegate-less edit-menu interaction
   would be inert and risk muddying arbitration, so it was omitted (Copy/edit
   menu is Task 20 regardless).

### Environment

Dedicated sim `ADF-Task16` (**iPhone 16, iOS 18.2**, UDID
`D427F885-CE35-48A2-B440-37AF95ACD25B`), created for this task, deleted at the
end. Branch `textkit2-port-prototype`. Demo built via `xcodebuild … build`
(BUILD SUCCEEDED), launched `-fixture kitchen-sink -textkit2 -selection`.
`swift test`: **226/226**, 37 suites. Warning baseline unchanged (the two
`SegmentedTextView.swift` iOS-build concurrency warnings are pre-existing on a
file this task did not touch; `swift build` is warning-clean). Introspection
outcomes captured via `os.Logger` (`subsystem com.connie.adfreader`, category
`selection`/`selectionctl`) read back with `simctl … log show`.

### Finding #1 — `.background` on a SwiftUI `ScrollView` is NOT a descendant of the `UIScrollView`

The brief's literal placement (`.background { … }` on the `ScrollView`) never
introspects: `ProbeView`'s `superview` chain runs

```
ProbeView → PlatformViewHost<…ScrollViewIntrospector> → HostingView →
UIViewControllerWrapperView → UINavigationTransitionView → UILayoutContainerView
→ PlatformViewHost<…NavigationStackRepresentable> → _UIHostingView<…> →
UIDropShadowView → UITransitionView → UIWindow
```

— **no `UIScrollView` anywhere.** SwiftUI hosts a `ScrollView`'s `.background`
in a separate `PlatformViewHost` that is a sibling *behind* the scroll view,
not inside it. The upward walk gave up after 12 attempts. Hosting the probe
inside the scroll **content** (a `.background` on the row stack) makes it a
genuine descendant, and the walk then succeeds on the first laid-out frame.

### Finding #2 — the correct content container

With the content-level probe, introspection succeeds on attempt 1:

```
scrollView = HostingScrollView          (SwiftUI's private UIScrollView subclass)
container  = PlatformGroupContainer      (= scrollView.subviews.first; the content
                                          host and ancestor of every rendered TK2 row)
scrollView.subviews = [PlatformGroupContainer, _UIScrollViewScrollIndicator]
```

So `scrollView.subviews.first` **is** the right container (the brief's
expectation held); it just is not reachable from a `ScrollView`-level
`.background`.

### Finding #3 — `UITextInteraction` stays dormant; a detached responder cannot become first responder

Attached to `PlatformGroupContainer` with `interaction.textInput = self`
(`container.isUserInteractionEnabled = true`, `container.interactions = 1`),
the interaction installs **0 gesture recognizers**. `UITextInteraction` only
activates its selection gestures when its `textInput` is the first responder,
and the detached controller **cannot become one**:
`becomeFirstResponder() → false`, `isFirstResponder = false` (even with
`canBecomeFirstResponder = true`) — a `UIResponder` with no responder-chain
`next` is not reachable in any window's chain. So long-press does nothing; the
controller's `closestPosition`/`caretRect`/`characterRange` are never called.
(The placeholder corpus is healthy — `corpus.length = 859`, `hasText = true`,
`container.bounds = 393×3380` by 3 s post-attach — so an empty document is not
the cause.)

### Finding #4 — even force-activated, it declines to select over the SwiftUI-hosted rows

Wiring the controller into the chain (`override var next { container }`) +
proactively calling `becomeFirstResponder()` makes it succeed (`→ true`,
`isFirstResponder = true`) and `UITextInteraction` then installs its full
gesture set (**14 recognizers**: `UIVariableDelayLoupeGesture`,
`UITextTapRecognizer`, `UITextRangeAdjustmentGestureRecognizer`, …). **Yet a
long-press over a TK2 paragraph still begins no selection** — no
`closestPosition`/geometry query ever fires, no handles, no edit menu (both an
`axe touch --down --up --delay` press and a same-point `axe swipe --duration`
were tried; corpus valid; controller confirmed still first responder with 14
recognizers at the moment of the press).

A decisive discriminator: a plain `UILongPressGestureRecognizer` added to the
**same** `PlatformGroupContainer` **does fire** (began→ended) on that exact
long-press. So touches *do* reach the container — `UITextInteraction`
specifically declines. The touch hit-tests to the interactive descendant row
(a `PlatformViewHost` hosting `TextKit2RowUIView`, `isUserInteractionEnabled =
true`), **not** to `interaction.view`; `UITextInteraction` will not begin a
selection for a touch that lands on a foreign descendant rather than its own
text-bearing view. In the spike this never surfaced because the "descendants"
were `UILabel`s (`isUserInteractionEnabled = false`) whose touches hit-tested
straight through to the interaction's own view. The production TK2 rows *must*
be interactive (links, checkboxes, facade), so their host views own the
hit-test and starve the ancestor interaction. This is precisely spec §10's
kill condition: *"`UITextInteraction` cannot operate with SwiftUI-hosted
hit-tested descendants."* (All finding #3/#4 experimental scaffolding —
`next` override, proactive `becomeFirstResponder`, the probe recognizer,
verbose tracing — was removed from the committed code; the committed
controller is the clean brief-faithful baseline that stays dormant.)

### Arbitration matrix — OBSERVED (kitchen-sink, `-textkit2 -selection`, iPhone 16 / iOS 18.2)

Every screenshot below was read directly (`docs/assessment-assets/phase4-selection/`,
`t16_` prefix). Because the committed interaction is **dormant** (finding #3:
0 recognizers, never first responder), it is *provably inert* and cannot alter
any descendant gesture — the descendant rows behave exactly as the
`-textkit2`-only baseline, verified directly where noted.

| # | Action | Pass condition | Observed | Result |
|---|---|---|---|---|
| 1 | tap a link run in a TK2 paragraph | link opens (openURL) | Nothing; no Safari. **Pre-existing, not a selection effect:** `TextKit2RowUIView` is a bare drawing `UIView` — `TextRowContent` sets `.link` only for *tinting* (`TextRowContent.swift:144`), there is no link-tap handler on the TK2 arm at all (extends known-gap #2 to text links). Fails identically without `-selection`. | N/A (pre-existing TK2 gap) |
| 2 | tap a task checkbox (`TaskMarkerView`) | checkbox toggles | `axe describe-ui` before: `Button "Task"` (unchecked); tap `(34,129)`; after: `Button "Completed task"` — state flipped. `t16_02_checkbox_toggled.png`. | **PASS** |
| 3 | swipe horizontally over code/table | it pans | Descendant h-scroll responds (code block h-scroll observed transiently; snaps back as it is barely wider than the column). Table h-pan via `axe swipe` is a no-op in **both** arms (a tooling limitation, not selection). Interaction inert ⇒ behaves as baseline. `t16_03_table_inview.png`. | **PASS** (baseline-equivalent) |
| 4 | long-press over a TK2 paragraph | native selection + handles + edit menu | No highlight, no handles, no menu, no keyboard; `closestPosition` never called (findings #3/#4). `t16_04_longpress_no_selection.png`. | **FAIL** |
| 5 | drag a handle across two blocks | selection extends across blocks | No selection exists to extend (blocked by #4). | **FAIL** (blocked by #4) |
| 6 | with selection active, tap the YouTube facade | player opens; selection persists | Facade (`Button "Play YouTube video"`, Rick Astley) → in-place player on tap (`t16_02a_…` → `t16_06_youtube_player.png`). Descendant tap alive. "Selection persists" is untestable — no selection can be active. | PARTIAL (facade PASS; persistence N/A) |
| 7 | with selection active, pan the table | it pans; selection persists | No selection possible; table pan behaves as baseline (interaction inert). | N/A (no selection) |
| 8 | vertical swipe on paragraph text | outer scroll scrolls | Document scrolls normally through panels/table/task-list (`t16_08_vertical_scroll.png`); interaction does not steal the fling. | **PASS** |

**Reading of the matrix:** the ancestor attachment is *harmless* (descendant
taps/scroll — rows 2, 6, 8 — all alive, exactly the coexistence the spike
promised) but *ineffective* (rows 4, 5 — the selection it exists to provide
never engages on the real rows). Rows 1/3/6-persist/7 are pre-existing gaps or
untestable consequences of the row-4 failure, not independent findings.

### Verdict: **KILLED — fall back to the geometry-oracle overlay**

Introspection is solved (`HostingScrollView` → `PlatformGroupContainer`, once
the probe is content-hosted), and ancestor attachment does not break SwiftUI's
gesture ecosystem. But `UITextInteraction` **will not drive selection from an
ancestor** when the touched descendants are independent, interactive
SwiftUI-hosted `UIView`s — it requires the touch to land on `interaction.view`
itself, which the (necessarily interactive) TK2 rows own. No in-constraints
fix exists: forcing first-responder + responder-chain wiring installs the
recognizers but still does not begin selection (finding #4), and an overlay
that owned the hit-test would swallow the descendant taps (the sibling-overlay
failure the spike was built to avoid) or require the `hitTest` override spec §7
forbids. Per spec §10 this is a valid, cheap kill: **do not build Tasks 17–25
on ancestor attachment; pursue the geometry-oracle overlay** (a self-owned,
selection-only surface that draws selection from a geometry oracle rather than
relying on `UITextInteraction`'s own hit-testing of foreign descendants), and
carry forward the two spike constraints already on record (copy/edit-menu
responder wiring; accessibility ancestor-collapse) plus the new TK2 text-link
hit-testing gap surfaced by row 1.

---

## Task 16b: v3 session-scoped overlay

**Kill question:** on the real SwiftUI-hosted TK2 hierarchy, can a
**session-scoped transparent overlay** — a `UITextInput` that hosts
`UITextInteraction(.nonEditable)` + `UIEditMenuInteraction` **on itself**, so
`interaction.view == interaction.textInput` — deliver native text selection
(the exact `touch.view == interaction.view` condition Task 16 proved
necessary), while (a) staying inert when idle, (b) starting a session from an
ancestor long-press over interactive rows, (c) NOT starving scroll during a
session, and (d) exiting cleanly? Task 16 killed v2 (ancestor-attached
interaction declines touches that hit-test to descendant rows). v3 is the pivot.

### What was built (behind `-selection` + `-textkit2`, spike quality)

- `SelectionController` (rewritten): a plain `NSObject` coordinator. On
  `attach(to:scrollView:)` (called by the unchanged `ScrollViewIntrospector`)
  it inserts a `SelectionOverlayView` into the introspected content container
  (`PlatformGroupContainer`), spanning content bounds, idle-disabled; installs
  a `UILongPressGestureRecognizer` (session start) and a `UITapGestureRecognizer`
  (tap-to-clear) on the **container** (both `cancelsTouchesInView = false`).
- `SelectionOverlayView: UIView, UITextInput`: hosts `UITextInteraction(.nonEditable)`
  + `UIEditMenuInteraction` on itself. Crude text model = search corpus joined
  plain-text; crude linear geometry over `bounds`. Long-press `.began` over a
  `TextKit2RowUIView` (hit-tested while the overlay is still disabled) → word-
  select, enable overlay, `becomeFirstResponder`, set `selectedTextRange`,
  notify `inputDelegate`, present the edit menu. Teardown is a single
  idempotent `endSession`, reached from both the tap-clear recognizer and a
  `resignFirstResponder` override (the "resign from any path" contract).
- **Zero changes** to the SwiftUI arm or any TK2-off path; no `hitTest`
  overrides anywhere; `reassertAnchor`/`anchors`/`pendingRepins` untouched.

### Two discoveries that shaped v3 (both required, both in-constraints)

1. **`UITextInteraction` alone does not render a programmatically-seeded
   selection.** With the overlay first responder and `selectedTextRange` set,
   the selection is *functionally real* — the edit menu presents and **Copy
   returns the selected word** (`UIPasteboard` = `"paragraph"`) — but **no blue
   highlight and no drag handles draw**. The header for
   `UITextSelectionDisplayInteraction` (iOS 17+) states it *"is the component
   that `UITextInteraction` generally talks to in order to accomplish all
   selection display."* Installing a `UITextSelectionDisplayInteraction` on the
   overlay (activated at session start, `setNeedsSelectionUpdate()` on every
   `selectedTextRange` mutation) is what makes the native highlight + handles
   appear. This is a **mandatory addition to the v3 stack**, not optional.
2. **An always-on full-content overlay starves scroll.** With the enabled
   overlay's default `point(inside:)` (whole bounds), a vertical pan during a
   session was swallowed — the document would not scroll (row 6 fail). The fix
   is spec §7's sanctioned override: the overlay's `point(inside:)` owns **only**
   touches within the selection rects (expanded by a handle-grab margin);
   everything else falls through to the content, so the scroll view's pan
   recognizer (an ancestor of both) wins and taps reach checkboxes / the facade.
   With this, scroll during a session works and the selection UI still renders
   and drags (the display interaction's subviews draw regardless of hit-testing).

### Arbitration matrix — OBSERVED (kitchen-sink, `-textkit2 -selection`, iPhone 16 / iOS 18.2)

Every screenshot read directly; committed under `docs/assessment-assets/phase4-selection/` (`t16b_` prefix).

| # | Action | Pass condition | Observed | Result |
|---|---|---|---|---|
| 1 | idle: tap a task checkbox | toggles (native) | `Write the parser` unchecked→checked on tap. `t16b_01`. | **PASS** |
| 2 | idle: tap video facade; scroll away | player appears; facade returns | Facade→inline YouTube player (0:00/3:33); scroll away+back → **facade returns** (player released). `t16b_02`, `t16b_02b`. | **PASS** |
| 3 | idle: pan code block horizontally | scrolls | Idle overlay is `isUserInteractionEnabled=false` ⇒ provably inert; code block behaves as baseline (content fits column, snaps like `-textkit2`-only). `t16b_03`. | **PASS** (baseline-equiv) |
| 4 | long-press a TK2 paragraph | native handles + highlight + menu | **Blue highlight + two drag handles + edit menu** on the overlay; Copy→`"paragraph"`. **THE kill question — passes.** `t16b_04`. | **PASS** |
| 5 | drag a handle (axe swipe) | selection extends; rects update | Handle drag moves the endpoint and re-queries `selectionRects` (band relocates; drag also drove content autoscroll). Crude linear geometry limits *visible* multi-block extension — architecturally functional. `t16b_05`. | **PASS** (crude geom) |
| 6 | vertical swipe during a session | document scrolls (not starved) | With `point(inside:)` pass-through, the document scrolls freely top→panels/table during an active session. **Kill criterion — passes.** `t16b_06a`, `t16b_06b`. | **PASS** |
| 7 | tap outside selection; then tap checkbox | session clears; idle restored | Tap outside → selection UI gone; then `Write the parser` checked→unchecked. **Kill criterion — passes.** `t16b_07a`, `t16b_07b`. | **PASS** |
| 8 | edit menu near selection | menu present (Copy not required) | Copy / Look Up / Translate / Share present at the selection. `t16b_04`. | **PASS** |
| 9 | relaunch w/o `-selection`; TK2 off | no side effects; identical baseline | `-textkit2` only: long-press is a **no-op** (no overlay). No flags: SwiftUI arm renders identically. `t16b_09a`, `t16b_09b`. | **PASS** |

### Verdict: **PROCEED-WITH-CONSTRAINTS**

v3 is **viable on the real hierarchy** — every kill criterion (rows 4, 6, 7)
passes and idle behavior is untouched. The overlay-as-`interaction.view`
satisfies Task 16's necessary condition, the ancestor long-press bootstraps a
session over interactive rows, and the selection is genuinely native (handles,
highlight, edit menu, working Copy). Proceed to Tasks 17–25 on the v3 overlay,
carrying these **non-negotiable constraints** the spike surfaced:

1. **`UITextSelectionDisplayInteraction` (iOS 17+) is required** to draw the
   selection — `UITextInteraction` handles gestures/menu/first-responder but
   renders nothing for a seeded selection. Keep it activated for the session and
   `setNeedsSelectionUpdate()` on every selection mutation.
2. **The overlay's `point(inside:)` must scope ownership to the selection**
   (spec §7's one sanctioned override) or the enabled overlay starves scroll.
3. **Real per-row geometry (Task 17) is needed** for faithful selection rects;
   the crude linear stand-in produces small bands and limits visible cross-block
   extension (functional, not faithful).

Carry-forward gaps unchanged from Task 16: TK2 text-link hit-testing gap (row 1
of the Task 16 matrix); copy corpus-exactness (Task 20); accessibility
ancestor-collapse. Kill-fast §11 step 1 is **cleared** — the selection
architecture is proven; the port's remaining risk moves to the perf bets
(§11 step 2, per-row `NSTextLayoutManager` cost).

## Phase 4 — Task 23: rendering fidelity closeout (chip icons, inlineCard tint, pure-atom-row baseline, vertical-rhythm decision)

Closes known-gaps-register items **#1** (chip SF Symbols + inlineCard tint)
and **#4** (pure-atom-row `firstBaseline` `0` fallback), and reaches a
recorded decision on **#5** (vertical-rhythm drift). Chip width was scheduled
here (not deferred further) because a chip's whole-pill selection rect
(Task 21) depends on the pill's real geometry — an 18–22pt-narrow chip was a
wrong selection rect, not just a cosmetic gap.

### Step 1 — chip SF Symbol icons + inlineCard tint

`AtomAttachment`'s `Style.chip` case now carries `(icon: String, tint:
UIColor)`: `.inlineCard` → `"link"`/`.systemBlue` (mirroring
`InlineCardChip`'s SwiftUI `Link`, which tints its whole label — icon and
text — with the ambient accent color); `.mediaInline` → `"paperclip"`/
`.label`; `.inlineExtension` → `"puzzlepiece.extension"`/`.label`. The icon is
resolved via `UIImage.SymbolConfiguration(font:scale:)` — the documented
UIKit equivalent of SwiftUI's `.imageScale(.small)` on a `.callout`-font
`HStack` (`AtomChip`) — sized once in `init` (pure function of `(icon name,
pillFont)`) and its width + a `UIFontMetrics`-scaled 4pt gap
(`AtomChip`'s `iconSpacing`) now contribute to `pillSize.width`, closing the
gap Task 10 flagged. `draw(into:)` pre-tints the resolved symbol via
`withTintColor(_:renderingMode:.alwaysOriginal)` against the SAME
draw-time-current traits the pill background/text already resolve against
(dark-mode correct, no invalidation) and draws it at the pill's leading
edge, vertically centered — `AtomChip`'s `HStack`'s default alignment.
`inlineCard`'s text color changed from the uniform `.label` (the
`AtomAttachment.swift:165` bug Task 13 traced) to the same `tint` the icon
uses.

New tests in `AtomAttachmentTests.swift`: `chipWidthIncludesIconGlyph`
(pins `pillSize.width` within ≤3pt of the SwiftUI-arm-measured targets
below), `chipWidthWiderThanTextAlone` (regression guard independent of the
exact target numbers), `inlineCardChipUsesTintColor` (renders the pill via
`image(forBounds:...)` and scans the raw pixel buffer for a blue-dominant
pixel, present for `.inlineCard` and absent for the `.mediaInline` control).

**Measured residual delta (`t23_kitchensink_{off,tk2}_atoms.png`,
`docs/assessment-assets/phase4-rendering/`, iPhone 16 / iOS 18.2, kitchen-sink
¶26, default size), same Python3+PIL column-scan method as Task 10 (leftmost/
rightmost non-white pixel per row in the chip's vertical band, widest bound
recurring across the flat, non-corner rows):**

| Chip | OFF width | TK2 width | Residual Δ | Was (Task 10) |
|---|---|---|---|---|
| `attachment` (paperclip) | 353px (117.67pt) | 354px (118.00pt) | **1px ≈ 0.33pt** | ~18.7pt narrower |
| `Inline macro` (puzzlepiece) | 378px (126.00pt) | 378px (126.00pt) | **0px ≈ 0.00pt** | ~22pt narrower |

Both residuals are inside the brief's ≤3pt bar by a wide margin — the icon +
gap fully accounts for the previously-missing width; the 1px `attachment`
residual is at the measurement's own resolution floor (sub-pixel hinting),
not a systematic gap. The `t23_` screenshots also show both chips'
icon glyph, shape, and (for `inlineCard`) blue tint visually matching the
SwiftUI arm. A dark-mode spot-check
(`t23_kitchensink_tk2_atoms_dark.png`, `xcrun simctl ui … appearance dark`)
confirms the `inlineCard` chip's icon+text now render in the dynamic blue
tint in dark mode too — closing the Task 13 dark-mode finding at its root
(`AtomAttachment.swift`'s uniform-`.label` bug), not just re-observing it.

### Step 2 — pure-atom-row `firstBaseline`

`AtomAttachment` gained `pillAscent: CGFloat { pillFont.ascender }` — a pure
function of `(atom, category)` (it only reads the already-resolved
`pillFont`, itself selected purely from `(atom, category)` in `init`).
`TextKit2RowView.firstBaseline` now falls through, when no `.text` segment
exists at all, to `AtomAttachment(atom:, categoryRawValue:).pillAscent` for
the row's leading atom, instead of the stale `0`. `pillAscent` deliberately
mirrors the SAME "text-font ascent, ignoring the pill's own taller padded
box" semantics `firstBaseline` already uses for an atom-LEADING row that
DOES have a following text run (documented, established behavior since
Task 10/11: that case falls through to the text chunk's ascender, not the
pill's inflated height) — an earlier draft that instead returned
`pillSize.height + originY` (the pill's own physical top-edge-above-baseline,
including padding) was ~2.9pt off a plain-font-ascender comparison at
`.large`/mention, exceeding the brief's 1pt bar; `pillFont.ascender` matches
by construction (0pt residual) and keeps the fallback consistent with the
non-fallback branch.

New tests: `AtomAttachmentTests.pillAscentIsDeterministicAndGrowsWithCategory`
/ `pillAscentWithin1ptOfTextAscent`, and a new
`TextKit2RowViewFirstBaselineTests.swift` (iOS-lane): a single-atom pure row
(`pureAtomRowReturnsNonZeroPillAscent`), two atoms glued with no separating
text (`multiAtomRowWithNoTextUsesLeadingAtom` — leading atom wins, and the
two atoms' fonts are proven to actually differ so the assertion is
non-vacuous), a regression guard that an atom-LEADING row WITH following
text is untouched (`atomLeadingRowWithFollowingTextStillUsesTextAscender`),
and the brief's own ≤1pt bar
(`pureAtomRowBaselineWithin1ptOfPillTextAscent`).

### Step 3 — vertical-rhythm characterization + DECISION

Re-measured the row-band drift Task 11 first observed (bulletList/panels
region, kitchen-sink `-scrollToFraction 0.27`, iPhone 16 / iOS 18.2,
`t23_lists_{off,tk2}[_step3].png`), using a panel-top-edge column scan (a
single-column white→fill transition scan at a fixed x inside each panel's
left margin, per screenshot) rather than Task 11's ink-bbox method — a
different, independent measurement of the same phenomenon:

| Panel (top-edge y, OFF vs TK2, default) | Cumulative drift | at `-fontSizeStep 3` |
|---|---|---|
| Info | 27px (9.0pt) | 21px (7.0pt) |
| Note | 32px (10.7pt) | 25px (8.3pt) |
| Tip | 37px (12.3pt) | 27px (9.0pt) |
| Success | 42px (14.0pt) | 31px (10.3pt) |
| Warning | 47px (15.7pt) | 35px (11.7pt) |
| Error | 52px (17.3pt) | 39px (13.0pt) |
| Custom | 57px (19.0pt) | *(clipped off-screen, matching Task 11)* |

The drift grows ~5px (default) / ~3-4px (step3) per panel — the SAME
per-row order of magnitude Task 11 measured for bullet rows (~5-6px/row) —
confirming this is the same systemic `TextRowLayout`-vs-`Text` line-height
differential, still present, still purely cumulative (it keeps growing
monotonically down the page; there is no single fixed offset to chase). The
~27px baseline already present at the first panel (above Task 11's bullet-
row-only ~0-22px range) is consistent with the intervening 2-line `swift`
code block contributing more drift per line than a plain paragraph row —
not a new or different defect, just a longer sample column than Task 11's.

**DECISION: the fix is DEFERRED to the production port, unchanged from the
brief's own rationale** — recorded here, not re-derived, because it still
holds after re-measurement: (a) this is a `TextRowLayout`-vs-SwiftUI-`Text`
line-height difference that is cosmetic **only relative to the OFF arm**;
once the port is complete and the OFF arm is removed, there is nothing left
to drift from — the TK2 arm's own vertical rhythm is internally consistent
(markers track their own row's baseline within ~1px, per Task 11). (b) Forcing
a line-height multiple to match SwiftUI `Text` risks the deterministic-sizing
/ `CollapsedRowHeight` exact-replay contract (§16) for no visual benefit once
OFF is gone. No line-metric code was changed by this task.

### Step 4 — verify

- macOS `swift test`: **280/280 pass**, 42 suites (unchanged — all new tests
  are iOS-only; `AtomAttachment.swift`/`TextKit2RowView.swift` are both
  UIKit/iOS-gated and compile to nothing on macOS).
- iOS `ADFRenderingTests` lane (`xcodebuild test`, dedicated sim
  `ADF-Task23`, iPhone 16 / iOS 18.2): **161/161 pass**, 21 suites (152
  baseline + 9 new: 5 in `AtomAttachmentTests`, 4 in
  `TextKit2RowViewFirstBaselineTests`).
- Build: 2-warning baseline held (no new warnings).
- Screenshots (`t23_` prefix) committed under
  `docs/assessment-assets/phase4-rendering/`: `t23_kitchensink_{off,tk2}_atoms.png`,
  `t23_kitchensink_tk2_atoms_dark.png`, `t23_lists_{off,tk2}[_step3].png`.

### Concerns / carried forward

- Chip corner-rounding rows were excluded from the column-scan measurement
  by construction (same method as Task 10); the 1px `attachment` residual is
  plausibly sub-pixel hinting noise, not a remaining systematic gap, but
  wasn't independently isolated further.
- Vertical-rhythm magnitude was re-measured with a DIFFERENT column (panel
  top edges vs Task 11's marker-to-text ink bboxes) and a longer span (7
  panels vs 5 bullet rows) — the two measurements are complementary
  evidence of the same phenomenon, not a like-for-like reproduction of
  Task 11's exact numbers; both agree on the ~5px/row order of magnitude.
- `AtomAttachment.pillAscent` is a NEW public surface on an otherwise
  internal type; it exists solely for `TextKit2RowView.firstBaseline`'s
  fallback and is not used anywhere else in the draw/sizing path.

## Phase 4 — Task 24: test infrastructure (atom-stress fixture, RTL selection regression, layout-determinism discriminator)

Closes known-gaps-register items **#6** (no atom-heavy stress fixture),
**#7** (RTL fix has only a unit-test reproduction, no simulator-visible
selection regression), and **#10** (the `TextRowLayoutTests.
sameInputSameWidthMeasuresIdentically` flake — the discriminator the phase-3
verdict said "must precede any production-port decision"). No production
code changed except the one test-suite trait Step 3's discriminator result
calls for.

### Step 1 — `Fixtures/atom-stress.json`

Added `makeAtomStress()`/`atomParagraph(_:index:)` to `Tools/make-fixtures.
swift` (the SAME generator infrastructure — seeded `LCG`, word soup, node
builders — that already produces `stress-5k.json`/`giant-table.json`/
`media-gallery.json`) rather than hand-authoring: 2,000 top-level paragraphs
(plus one heading), each carrying **all seven** `InlineAtom` kinds (mention,
emoji, date, status, inlineCard, mediaInline, inlineExtension — 14,000 pill
attachments total), joined by short connective text, following kitchen-
sink.json's ¶26 shape (`Ping [mention] [emoji] due [date] see [inlineCard] …
[mediaInline] [inlineExtension]`) plus a `status` atom kitchen-sink keeps in
a separate paragraph — this fixture wants every pill kind stressed together,
per paragraph. Re-running the generator reproduced `stress-5k.json`/
`giant-table.json`/`media-gallery.json` byte-for-byte (confirmed via `git
status`/`git diff --stat` — zero diff), proving the addition didn't disturb
the existing fixtures' determinism. Picked up automatically by `Demo/
project.yml`'s `../Fixtures` glob after `xcodegen generate` (re-run to
rebuild the `.xcodeproj`'s resource list) — no `project.yml` edit. Added
`StressFixtureTests.atomStressShape` (2,000 paragraphs, every paragraph
carries all 7 atom kinds) and extended `parsesCleanly`'s `arguments:` list
with `"atom-stress.json"` (zero parse issues, zero unknown nodes — same bar
the other 3 generated fixtures already meet).

**Perf spot-check** (iPhone 16 / iOS 18.2, dedicated sim, atom-stress
fixture, built+installed with the new fixture bundled):

| | OFF | `-textkit2` |
|---|---|---|
| Autoscroll (×1) | frames=8278 dropped=7 `hitchRatioMsPerS=1.16` | frames=8234 dropped=2 `hitchRatioMsPerS=0.24` |
| 12-swipe fling + `top -l 2` settle | 0.4% CPU | 0.5% CPU |

TK2/OFF hitch ratio ≈ **0.21×** — TK2 is FASTER on this atom-dense fixture
(consistent with the vector-drawn-pill design: no per-pill SwiftUI view
hosting, unlike the OFF arm's real `AtomCapsule`/`AtomChip` SwiftUI views).
Both branches' CPU settles near-zero after the fling burst — no livelock
newly exposed by 14,000 pill attachments.

### Step 2 — RTL selection-visible regression

The phase-3 RTL fix (`TextRowContent.make`'s `.natural` → explicit `.left`/
`.right` per host direction) had only `naturalAlignmentResolvesPerHostDirection`
as a reliable reproduction (Task 12: the simulator's `-AppleTextDirection
YES` masks the pre-fix bug by forcing a GLOBAL direction override that
happens to agree with the fix regardless). This step adds a
**selection-level** regression the pure-render matrix lacked: with a plain
(unforced-direction) host — `-fixture rtl-mixed -textkit2 -selection` — long-
press-select an Arabic word and Copy, checking BOTH the copied text AND
which side of the (short, left-aligned-per-¶1's-no-mark-case) line the
selection highlight lands on.

`rtl-mixed.json` ¶1 is "هذا نص عربي للاختبار" (4 words, no alignment mark, so
`.natural` → `.left` under our LTR-host fix — a SHORT line, `x∈[69,451]px`
at `@3x`, not full container width). Long-pressed twice on a dedicated sim
(`ADF-Task23`, iPhone 16 / iOS 18.2, reused from Task 23 in the same
session — see report), via `axe touch -x … -y … --down --up --delay 1.0`
(point-space coordinates, converted from pixel measurements ÷3 for `@3x`),
each followed immediately by `axe tap` on the edit menu's Copy button, read
via `xcrun simctl pbpaste`:

| Touch x (pt / px) | Copied text | Word's offset in "هذا نص عربي للاختبار" |
|---|---|---|
| 140pt / 420px (RIGHT side of the line) | `هذا` (exact) | **0** — the FIRST word |
| 33pt / 99px (LEFT side of the line) | `للاختبار` (exact) | **last** word |

Both copies are **byte-for-byte exact** against the fixture source string
(`words[0]`/`words[-1]` of `text.split(" ")`, verified in Python). This is
the correct, unambiguous signature of genuine RTL rendering: a touch near
the RIGHT edge of the (left-aligned) line selects the LOGICALLY-FIRST word,
and a touch near the LEFT edge selects the LOGICALLY-LAST word — exactly
backwards from what an (incorrectly) LTR-ordered rendering of the same
Arabic text would produce. Pixel-measured selection-highlight bands confirm
the same story geometrically: the right-side touch's highlight sits at
`x∈[389,420]px` (within the line's last ~9%), the left-side touch's at
`x∈[35,66]px` (at the line's own start) — **selection rects sit on the
correct (right-to-left-ordered) side.** Screenshots (`t24_rtl_*` prefix)
committed under `docs/assessment-assets/phase4-rendering/`:
`t24_rtl_selection_initial.png`, `t24_rtl_longpress_{right,left}.png`.

This closes gap #7 as a genuinely simulator/selection-visible regression —
unlike the Task-12 render-matrix attempt, this one does NOT depend on
`-AppleTextDirection YES` (the whole point: it runs the app with NO forced
direction override, the actual host configuration production users have),
so it will catch a real per-view direction regression the render-only matrix
structurally cannot.

### Step 3 — layout-determinism discriminator

Per the phase-3 verdict's requirement ("a serial-vs-parallel discriminator
run … must precede any production-port decision"), ran
`TextRowLayoutTests.sameInputSameWidthMeasuresIdentically` under two
regimes, each a fresh `swift test` process invocation (no shared state
carried between runs):

| Regime | Command | Runs | Failures |
|---|---|---|---|
| Serial (isolated) | `swift test --filter TextRowLayoutTests` | 100 | **0/100** |
| Parallel (full suite) | `swift test --parallel` (281 tests, 42 suites) | 140 | **1/140** |

The ONE parallel failure (run 68 of the second 100-run batch) recorded:
`sameInputSameWidthMeasuresIdentically(): (a → (320.0, 560.0)) == (b →
(320.0, 1080.0))` — two FRESH, independent `TextRowLayout` instances (each
owning its own `NSTextContentStorage`/`NSTextLayoutManager`/`NSTextContainer`
— no shared Swift-level state, and the type is `@MainActor`-isolated)
measuring the IDENTICAL text at the IDENTICAL width (320) produced different
heights. Since each instance's own state can't leak into another Swift-level,
and this reproduced ONLY when many OTHER suites' tests were scheduled
concurrently against it (never once in 100 isolated serial runs), the
contention is inside TextKit 2's own internals (undocumented as
thread/reentrancy-safe under Swift Testing's interleaved concurrent
scheduling), not a bug in this package's measurement code.

**Classification: TEST-INFRASTRUCTURE (parallel-cache contention), NOT a
product bug** — per the brief's discriminator protocol. Applied the
prescribed fix: `@Suite("TextRowLayout", .serialized)` on
`TextRowLayoutTests` (`Tests/ADFRenderingTests/TextRowLayoutTests.swift`),
with a comment recording this evidence and the classification. **Verified
the fix**: re-ran `swift test --parallel` **100 more times post-fix — 0/100
failures** (vs. 1/140 pre-fix), and confirmed via log inspection that the
suite's 4 tests now execute strictly one-at-a-time under `--parallel`
(each "started" immediately followed by its own "passed", not interleaved
with the other three, unlike the pre-fix log). `.serialized` only removes
THIS suite from other suites' concurrent scheduling window when parallel
mode is used — `swift test`'s default (serial-by-default at the SwiftPM
level) is unaffected either way.

This closes gap #10: the `CollapsedRowHeight` exact-replay contract and
selection-geometry stability are NOT threatened by a product-level
non-determinism — the underlying `TextRowLayout.measure` computation itself
never produced a wrong answer in 100 dedicated, isolated exercises; the
flake was purely a test-harness scheduling artifact.

### Step 4 — verify

- macOS `swift test`: **281/281 pass**, 42 suites (280 baseline + 1 new
  `atomStressShape`; the `parsesCleanly` parameterized test grew from 3 to 4
  cases).
- iOS `ADFRenderingTests` lane (dedicated sim, iPhone 16 / iOS 18.2):
  **161/161 pass**, 21 suites (unchanged from Task 23 — no iOS-lane test
  changes this task).
- Determinism discriminator: 100 serial / 140+100 parallel runs, as above.
- `git status`/`git diff --stat` confirmed `stress-5k.json`/`giant-table.
  json`/`media-gallery.json` are byte-identical after re-running the
  generator (only `atom-stress.json` is new).

### Concerns / carried forward

- The RTL selection regression's touch coordinates are hand-measured
  pixel positions (from a screenshot, ÷3 for point space) for THIS specific
  fixture/device/font-size combination — not resilient to a future layout
  change the way a coordinate-free, ID-based UI test would be; a follow-up
  could resolve the touch point from `RowGeometryRegistry`/`SelectionController`
  test doubles instead of a screenshot measurement, if this needs to become
  a permanent CI gate rather than a one-time regression check.
- The determinism discriminator's root cause (WHAT inside TextKit 2 races)
  was not identified beyond "not this package's Swift-level state" — only
  the classification (test-infra vs. product) was required by the brief,
  and `.serialized` is the prescribed mitigation regardless of the exact
  mechanism.
- Reused the Task 23 simulator (`ADF-Task23`) for the RTL regression and
  perf spot-check rather than creating a fresh `ADF-Task24` sim — both tasks
  ran in the same session; deleted at the very end of Task 24 instead of
  after each task. No correctness risk (app state doesn't affect either
  measurement), but it is a deviation from the "one dedicated sim per task"
  convention prior reports followed.

## Phase 4 — Task 25: accessibility — ancestor-collapse measurement, minimal exposure, production scope

Closes phase-3 gap #8. Dedicated sim `ADF-Task25` (iPhone 16, iOS 26.2),
created for this task, deleted at the end. HEAD at start: `9cbd4c3` (v3
overlay + full selection engine live — the real hierarchy this task
measures, not a spike).

### Step 1 — measure the collapse on the real v3 hierarchy

`axe describe-ui` against `-fixture kitchen-sink`, three launch
configurations, same freshly-launched scroll position (so the on-screen
element set is comparable), counting the *entire* returned tree (root
`AXApplication` included):

| Arm | Elements | Headings | Static text | Buttons/Groups | Labeled |
|---|---|---|---|---|---|
| SwiftUI (no `-textkit2`) | 32 | 6 | 21 | 2 / 1 | 31 |
| TK2, no selection (`-textkit2`) | **8** | **0** | 3 | 2 / 1 | 7 |
| TK2 + selection, idle (`-textkit2 -selection`, no session) | **8** | **0** | 3 | 2 / 1 | 7 |
| TK2 + selection, ACTIVE session (long-pressed "Heading two") | 15 | 0 | 8 | 3 / 2 | 13 |

Raw trees: `docs/assessment-assets/phase4-selection/t25_axe_trees/t25_{swiftui_kitchensink,tk2_before,tk2_selection_idle_before,tk2_selection_active_before}.json`.
Screenshots: `t25_swiftui_reference.png`, `t25_before_tk2_selection_idle.png`
(visually identical to bare `-textkit2` — the overlay is transparent/inert
while idle), `t25_before_tk2_selection_active.png` (selection engaged:
handles + edit menu with Copy, confirming Task 20's responder wiring still
works — this screenshot is evidence for the arm, not a new selection test).

**The bare TK2 arm's full tree** (`-textkit2`, no selection):

```
AXApplication 'ADFReader'
   AXGroup None                    (nav bar, empty)
   AXStaticText '4.'               (ordered-list marker)
   AXStaticText '5.'               (ordered-list marker)
   AXStaticText 'swift'            (code-block language label)
   AXButton 'Copy code'
   AXButton 'Click to expand'      (panel/expand affordance)
   AXImage 'A sunset'               (media alt text)
```

Every heading, every paragraph, every link, every task checkbox is simply
**absent** — not merged into one opaque element, just gone. This refines
the phase-1 spike's prediction: the spike measured a `UITextInput`-
conforming **ancestor** collapsing its descendants into one `AXTextArea`
(a design SelectionController never actually shipped — Task 16 killed
ancestor attachment and Tasks 16b–19 built the v3 **sibling overlay**
instead). On the real v3 hierarchy, `SelectionOverlayView` (the `UITextInput`
conformer) is a transparent sibling laid *over* the rows, not an ancestor of
them, so it cannot swallow them structurally — and, measured here, it
doesn't even register as an accessibility element of its own kind (no
`AXTextArea`/`TextView` node appears in ANY of the three configurations,
idle or active — see the full node-role tables in the raw JSON). The actual
mechanism is simpler and, from a VoiceOver user's perspective, *worse* than
"one opaque blob": bare `TextKit2RowUIView`s are plain `UIView`s with zero
accessibility wiring (the Task 10 note the register already flagged),
so they read as if the content doesn't exist at all. **Even during an
active selection session**, the tree gains only the edit menu's own
elements (`Copy`/`Select All`/`Look Up`, a `Forward` button) — the
selected text itself is never announced or exposed as any element,
confirming there is currently no VoiceOver path to "what got selected."

### Step 2 — minimal exposure prototype

**Files:**
- New: `Sources/ADFRendering/TextKit2/RowAccessibilityLabel.swift` — pure,
  macOS-testable helper (`Tests/ADFRenderingTests/RowAccessibilityLabelTests.swift`,
  12 cases): `build(segments:segmentStrings:)` reconstructs one row's full
  text by walking `[InlineSegment]` in order, taking each `.text` segment's
  plain string from `TextRowContent.segmentStrings` (already extracted —
  no re-walk of the source `AttributedString`) and substituting each
  `.atom` segment's `InlineAtom.fallbackText` in its place, concatenated
  with no separator — the exact shape `SearchIndexer.appendUnit`/
  `ADFDocumentModel.plainTitle` already use for the search corpus and TOC
  titles, so a VoiceOver label, a search hit, and a TOC entry describe a
  row with the same words. `isHeading(_:)` approximates heading detection
  from the first `.text` segment's first run's `FontSpec.style`.
- Modified: `Sources/ADFRendering/TextKit2/TextKit2RowView.swift` —
  `TextKit2RowUIView` gains `isAccessibilityElement = true` (set once in
  `init`) plus lazy `override` getters for `accessibilityLabel` (built via
  `RowAccessibilityLabel.build`, nil if the row has no content yet or an
  empty label) and `accessibilityTraits` (`[.staticText, .header]` for
  heading rows, `.staticText` otherwise). `accessibilityLanguage` is
  deliberately left at UIKit's default (`nil`) — no per-run language data
  exists in the ADF model to override it with.
- Test (iOS lane): `Tests/ADFRenderingTests/TextKit2RowAccessibilityTests.swift`
  (6 cases) — proves the getters read LIVE `apply()`-supplied content (not a
  value cached at the first `apply()`), and end-to-end atom-fallback/heading
  wiring through real `Inputs.Content`.

**Zero-cost discipline:** `accessibilityLabel`/`accessibilityTraits` are
`override var { get { ... } set {} }` computed properties, NOT stored —
`apply()`, `draw(_:)`, and `layoutSubviews()` never read or write them, so
building the label string only happens when an accessibility client
(VoiceOver, `axe`, Accessibility Inspector) actually queries the row.
Verified by code inspection (no call site anywhere in the scroll/paint/
layout path) and by `accessibilityLabelUpdatesLiveAcrossReapply` (proves the
getter re-derives from current state every call, i.e. nothing is being
opportunistically cached on the content-change path either).

**Heading approximation, documented tradeoff:** only levels 1–4
(`.title`/`.title2`/`.title3`/`.headline`) are detected; levels 5–6 bake as
`.subheadline`/`.footnote`, which `InlineComposer` ALSO uses (unbolded) for
the small-text and superscript/subscript marks, so a style-only check risks
a false positive on a bold run inside small/sup text. Confirmed via a
throwaway diagnostic print (reverted before commit, not part of the shipped
code) that a real "Heading five"/"Heading six" row's first run really does
carry `FontSpec(style: .subheadline/.footnote, bold: true)` and `isHeading`
correctly returns `false` for both — **and that `axe`/iOS's OWN heading
heuristic promotes them to `AXHeading` anyway**, independent of the app's
`.header` trait (visible in the "after" tree below). This app-level
`.header` trait is still the semantically correct, spec-compliant signal
(VoiceOver's rotor-based heading navigation is documented to rely on the
explicit trait, not any visual heuristic), it's just not the only thing
influencing `axe`'s reported `role` for large/bold text — a nuance recorded
here so a future reader doesn't mistake the level-5/6 gap for a live bug.
**One-label-per-row tradeoff:** an atom's `fallbackText`, not a per-attachment
element, is what VoiceOver reads for a mention/date/status/link pill inside
a row — matching this pass's stated bar ("one label per row"), not the
production per-run element model (scope note below).

**Verification — before/after `axe describe-ui`, same fixture/position:**

| Arm | Elements | Headings | Static text | Labeled |
|---|---|---|---|---|
| TK2, no selection — BEFORE | 8 | 0 | 3 | 7 |
| TK2, no selection — **AFTER** | **32** | **6** | **21** | **31** |
| TK2 + selection, idle — **AFTER** | 32 | 6 | 21 | 31 |
| TK2 + selection, ACTIVE session — **AFTER** | 45 | 6 | 32 | 43 |

The "AFTER" bare-TK2 tree is not just closer to the SwiftUI arm — a
role+label sequence diff between `t25_swiftui_kitchensink.json` and
`t25_tk2_after.json` (32 elements each) is **empty**: byte-identical
`(role, label)` pairs in the same order, including the heading text, the
merged-paragraph blob (`"bold italic underline strike let x = 1 H2O and x2
colored highlighted small a link annotated\nafter the break"` — SwiftUI's
own `Text`-per-paragraph granularity ALSO merges an embedded link's visible
text into the surrounding static-text label at this tree-dump level; see
Concerns), list markers, panel labels, and the image alt text. During an
active session the tree grows from 32 to 45 (the edit menu's own elements,
same as the BEFORE active-session delta) — confirmed by screenshot
(`t25_after_tk2_selection_active.png`) that the selection UI itself
(handles, edit menu, Copy) is pixel-identical to the BEFORE screenshot, and
by a live Copy-through-the-menu action (`xcrun simctl pbpaste` returned
`"Heading"`, matching the visibly selected word) that nothing about
selection was perturbed by making rows accessibility elements.

**No `SelectionController`/overlay changes were needed.** The brief
anticipated gating `SelectionController`'s `accessibilityElements`/the
container's `isAccessibilityElement`; measured reality is that
`SelectionOverlayView` never contributes an accessibility node in any
state (idle or active, before or after this task's fix — 0 `AXTextArea`/
`TextView` nodes in all seven captured trees), so there was nothing to gate
around. Task 25's fix is scoped entirely to `TextKit2RowUIView`.

### Step 3 — production accessibility scope (deferred, not built)

What full parity with the SwiftUI arm — and with a real production reading
experience — needs, beyond this task's one-label-per-row bar:

1. **Per-run / interactive element model.** Links, mentions, inline cards,
   and task checkboxes currently read as part of the row's flat label with
   no way to activate them from VoiceOver (no rotor entry, no double-tap
   action). Production needs `TextKit2RowUIView` (or a lightweight proxy
   layer) to conform to `UIAccessibilityContainer` and return an
   `accessibilityElements` array of custom `UIAccessibilityElement`s, one
   per interactive segment plus one for the surrounding static prose —
   keyed off the SAME segment/rect infrastructure this port already built
   (`TextRowContent.segmentUTF16Starts`, `selectionRects(forUTF16:)`,
   `AtomOrLinkHit`/`hitTest(atomOrLinkAt:)` from Task 21) rather than new
   geometry. Each interactive element's `accessibilityActivationPoint` +
   `accessibilityFrameInContainerSpace` would come directly from the
   existing per-segment rect query; its action would call the same
   `routeAtomTap`/`openURL` Task 21 already wired for touch. Estimated
   size: comparable to Tasks 17 + 21 combined (a registry-style query layer
   over already-real geometry, plus activation routing reusing existing
   handlers) — roughly 1–2 tasks.
2. **Text-selection rotor.** VoiceOver's built-in "rotor" for navigating by
   character/word/line when a text element has focus is NOT free from
   `UITextInput` conformance alone (measured here: `SelectionOverlayView`
   conforms to `UITextInput` today and contributes zero accessibility
   surface). Production would need to investigate `UIAccessibilityReadingContent`
   (`accessibilityLineNumber`/`accessibilityContentForLine(_:)`/
   `lineNumberForPoint(_:)`) on either the row or a synthetic per-document
   reading-content proxy, coordinated with the per-run element model above
   so VoiceOver doesn't double-announce a row's static label AND a
   rotor-navigated sub-range. This is exploratory — genuinely unknown
   whether `UITextInteraction`'s internals can be leveraged for any of it —
   sized as its own KILL-FAST-style task, roughly half-to-one task just to
   determine feasibility before committing to an implementation.
3. **The overlay's `AXTextArea` interplay during sessions.** Measured this
   task: `SelectionOverlayView` announces NOTHING today — not even the
   worse-than-spike "one opaque `AXTextArea`" the phase-1 spike predicted.
   Production needs the overlay (or session lifecycle) to explicitly call
   `UIAccessibility.post(notification:argument:)` — `.announcement` when a
   session starts/extends/ends, `.layoutChanged` pointing VoiceOver focus
   at the new selection — mirroring what a stock `UITextView` does
   automatically and a custom `UITextInput` must do by hand. This must be
   designed together with item 1 (the per-row elements) so a VoiceOver user
   isn't hearing both "row's full text" and "selection changed" as
   conflicting, redundant announcements.
4. **Selected-text announcements.** A specific instance of item 3: on
   `copy(_:)`, VoiceOver should confirm what was copied (stock text views
   post an announcement here too); currently silent.

None of this is built here — this is a scope/estimate note per the brief,
not an implementation. Rough total: **3–4 tasks**, similar in size to the
Task 17/19/21 cluster that built the selection engine's own geometry/
hit-testing layer, since items 1 and 3 above are designed to reuse that
layer rather than duplicate it.

### Verify

- macOS `swift test`: **293/293 pass**, 43 suites (281 baseline + 12 new
  `RowAccessibilityLabelTests`). 1 pre-existing warning observed on a clean
  build (`ADFBeamTests` unhandled-resource); no new warnings from either
  new file.
- iOS `ADFRenderingTests` lane (dedicated sim `ADF-Task25`, iPhone 16 /
  iOS 26.2): **179/179 pass**, 23 suites (161 baseline + 6 new
  `TextKit2RowAccessibilityTests` + the pre-existing suites' own count
  growth from unrelated parameterized cases already in the baseline).
- Demo app: `xcodebuild build` clean for both the pre-fix and post-fix
  binaries; `strings ADFReader.debug.dylib | grep RowAccessibilityLabel`
  confirms the post-fix binary is the one measured.
- `axe describe-ui` before/after comparison above; Copy-through-menu smoke
  test after the fix confirms no selection-engine regression.
- VoiceOver itself was NOT driven live (toggling VoiceOver headlessly via
  `simctl`/`notifyutil` is unreliable per prior task notes) — `axe
  describe-ui` element/role/label counts plus the `.header` trait unit
  tests are the evidence, per the brief's stated fallback.

### Concerns / carried forward

- `axe describe-ui`'s tree dump does not reveal whether the SwiftUI arm's
  embedded link ("a link" inside the merged paragraph blob) is independently
  rotor-navigable in REAL VoiceOver (SwiftUI may expose it via
  `accessibilityCustomActions`/an internal link sub-range VoiceOver reads at
  runtime that a static tree dump doesn't surface) — so the "byte-identical
  tree" result should be read as "same coarse element/label parity," not
  "proof the SwiftUI arm's own link accessibility is itself complete." This
  bears on item 1 of the production scope note either way.
- The heading-heuristic nuance (axe/iOS promotes large/bold text to
  `AXHeading` somewhat independently of the app's own `.header` trait) was
  discovered via a temporary diagnostic `print()` added and removed during
  this task, not left in the shipped code — reproducible by anyone who
  wants to re-verify by re-adding a similar print, but not itself a
  committed test (the committed tests instead pin `isHeading`'s OWN
  contract — levels 1–4 true, 5–6 false — which is the part this code
  actually controls).
- `isAccessibilityElement = true` is unconditional — a row with genuinely
  empty content (before its first `apply()`, or a defensively-empty label)
  is still technically an accessibility element with a nil label. Not
  observed to cause any VoiceOver-visible artifact in the trees captured
  (bare `UIView`s with a nil label and no traits are typically skipped by
  VoiceOver's own traversal), but not exhaustively verified against every
  fixture/timing window.
- Levels 5–6 heading detection remains a known gap (documented above and in
  the source), consistent with the brief's "approximate is acceptable,
  document" allowance rather than a bug to fix in this pass.
