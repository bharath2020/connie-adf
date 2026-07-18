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

**Reconciliation with `docs/Rotation-Scroll-Retention.md`.** That document
records this drift class as fixed and verified pixel-identical (8 cycles,
mean diff ≤ 0.02), and its fix commits are ancestors of the commit measured
here — an apparent contradiction. It is resolved by cross-session history:
on 2026-07-17, the per-document-text-size session measured rotation drift
A/B against a **main** build under the same notifyutil protocol and
recorded *"branch ≤8-block wobble vs main 100-block excursion, same
protocol"* — i.e., main exhibits a ~100-block rotation excursion despite
those fix commits, and the further improvement that achieves ≤8-block
behavior lives on the **unmerged** branch `feature/per-document-text-size`
(7 commits on ecb5072, deliberately kept unmerged). `textkit2-port-prototype`
forked from main (d677949), which still carries the excursion; the ~70–100
blocks measured here matches the prior session's main measurement in
magnitude. The drift is therefore **inherited baseline, not a port
regression**. (This run used iOS 26.2 vs the original 18.2 verification —
noted, but unproven as a factor and unnecessary to explain the result.)

Spec §10's kill criterion ("rotation scroll retention breaks") is
accordingly judged against the inherited baseline: the port provably does
not worsen it (A/B parity above). Recommendations: (a) file a tracking
issue to land the unmerged rotation improvement on main (or re-fix there);
(b) Task 13's phase-3 rotation re-run should use A/B-vs-toggle-OFF parity
as the bar, with an iOS 18.2 spot-check if time permits.

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
| Rotation retention (TK2 vs OFF, A/B) | HOLDS vs inherited baseline (drift indistinguishable within noise across branches; known main-branch excursion — see reconciliation above) |
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
