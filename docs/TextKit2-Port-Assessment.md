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
