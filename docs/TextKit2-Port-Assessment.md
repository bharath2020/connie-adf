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
