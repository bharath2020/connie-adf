# Per-Document Text Size Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A per-document text-size control in the reader's toolbar that scales every ADF element relatively (via a Dynamic Type override scoped to the document subtree), persists per document, and does not degrade scroll performance.

**Architecture:** The app stores an `Int` step offset per `DocumentSource.storageKey` and applies `system dynamicTypeSize shifted by step` as a `.dynamicTypeSize()` override on `ADFDocumentView` only. All ADFKit fonts are semantic styles baked per-run into AttributedStrings, so they re-resolve at draw time with **zero re-preparation**; all layout metrics are `@ScaledMetric` and follow. The library gains two reactions to a runtime type-size change: collapsed-row spacer heights are **rescaled in place** (never emptied — an empty cache re-materializes the row, and doing that to thousands of collapsed rows at once is the documented layout-livelock trap), and the scroll anchor is re-asserted (mirroring the existing width-change re-anchor, because a type-size change reflows heights without changing width on iPhone).

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, Swift Testing (`import Testing`, `@Suite`/`@Test`/`#expect`), SPM package + xcodegen demo app.

**Spec:** `docs/superpowers/specs/2026-07-16-per-document-text-size-design.md`

## Global Constraints

- Package platforms: iOS 17, macOS 14. Demo app: iOS 17.0, `SWIFT_TREAT_WARNINGS_AS_ERRORS: YES`, strict concurrency `complete`.
- NEVER empty a collapsed row's `CollapsedRowHeight` for a document-wide change: `heights.isEmpty` re-materializes the row (`if isInRenderRegion || heights.isEmpty` in `DocumentRow.body`). Spacer heights must remain a pure function of stored state (Architecture-Decisions §16).
- NEVER introduce a per-row `if #available` / `AnyView` erasure in the lazy stack (§18), and never read named-coordinate-space geometry inside lazy rows.
- All perf comparisons must be same-day, same-build-type (Debug sim autoscroll baseline ≈ 10 ms/s; the < 5 ms/s budget is Release-only).
- Simulator etiquette (user memory): reuse the booted simulator, don't shut it down; rotation via `notifyutil -p com.connie.adfreader.rotate`; fling via `axe swipe`; CPU via `top -l 2 -pid`, never `ps -o %cpu=`.
- Conventional commit messages (`feat:`, `test:`, `docs:`, `perf:`), each ending with the Claude Code co-author trailer.

---

### Task 0: Capture the perf baseline (before any code change)

**Files:** none (measurement only; save numbers to the session scratchpad)

- [ ] **Step 1: Build the demo app for the simulator**

```bash
cd /Users/bharath2020/Documents/projects/connie-adf
xcodebuild -project Demo/ADFReader.xcodeproj -scheme ADFReader \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -configuration Debug -quiet build
```

Expected: `BUILD SUCCEEDED` (adjust destination to an available/booted device; check `xcrun simctl list devices booted`).

- [ ] **Step 2: Run the autoscroll gate on stress-5k at HEAD**

```bash
APP=$(xcodebuild -project Demo/ADFReader.xcodeproj -scheme ADFReader \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -configuration Debug \
  -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{d=$3}/ FULL_PRODUCT_NAME/{n=$3}END{print d"/"n}')
xcrun simctl install booted "$APP"
xcrun simctl launch --console-pty booted com.connie.adfreader -fixture stress-5k -autoscroll
```

Expected: a `READY fixture=stress-5k …` line, then one `SCROLL_METRICS fixture=stress-5k frames=… dropped=… hitchRatioMsPerS=…` line, then the app exits.

- [ ] **Step 3: Record the baseline**

Save the full `SCROLL_METRICS` line to `<scratchpad>/perf-baseline.txt`. Run it twice; keep both lines (run-to-run noise matters when comparing later).

---

### Task 1: `DynamicTypeSize` step helpers in ADFRendering

**Files:**
- Create: `Sources/ADFRendering/DynamicTypeStep.swift`
- Test: `Tests/ADFRenderingTests/DynamicTypeStepTests.swift`

**Interfaces:**
- Produces: `public extension DynamicTypeSize { func shifted(by steps: Int) -> DynamicTypeSize; var approximateBodyPointSize: CGFloat }` — consumed by Task 3 (spacer rescale ratio) and Task 5 (effective size + percentage label).

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/ADFRenderingTests/DynamicTypeStepTests.swift
import SwiftUI
import Testing
import ADFRendering

/// The per-document text-size control moves along the DynamicTypeSize ladder
/// relative to the system baseline; these helpers are the whole mechanism.
@Suite("Dynamic Type stepping")
struct DynamicTypeStepTests {
    @Test("A step moves one rung along the ladder")
    func shiftsUpAndDown() {
        #expect(DynamicTypeSize.large.shifted(by: 1) == .xLarge)
        #expect(DynamicTypeSize.large.shifted(by: -1) == .medium)
        #expect(DynamicTypeSize.xxxLarge.shifted(by: 1) == .accessibility1)
    }

    @Test("Shifting clamps at both ends of the ladder")
    func clampsAtEnds() {
        #expect(DynamicTypeSize.accessibility4.shifted(by: 5) == .accessibility5)
        #expect(DynamicTypeSize.small.shifted(by: -9) == .xSmall)
        #expect(DynamicTypeSize.accessibility5.shifted(by: 1) == .accessibility5)
        #expect(DynamicTypeSize.xSmall.shifted(by: -1) == .xSmall)
    }

    @Test("A zero shift is the identity for every size")
    func zeroIsIdentity() {
        for size in DynamicTypeSize.allCases {
            #expect(size.shifted(by: 0) == size)
        }
    }

    @Test("Body point sizes grow strictly along the ladder, 17pt at .large")
    func pointSizesAreMonotonic() {
        let sizes = DynamicTypeSize.allCases.map(\.approximateBodyPointSize)
        #expect(sizes == sizes.sorted())
        #expect(Set(sizes).count == sizes.count)
        #expect(DynamicTypeSize.large.approximateBodyPointSize == 17)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter DynamicTypeStepTests`
Expected: compile FAILURE — `shifted(by:)` / `approximateBodyPointSize` not defined.

- [ ] **Step 3: Implement**

```swift
// Sources/ADFRendering/DynamicTypeStep.swift
import SwiftUI

/// Ladder arithmetic for a host-driven text-size control.
///
/// A host that wants "per-view text size" applies
/// `.dynamicTypeSize(system.shifted(by: step))` to `ADFDocumentView` — the
/// override composes with the user's accessibility setting (it shifts from
/// that baseline) instead of replacing it. All library fonts are semantic
/// styles and all metrics are `@ScaledMetric`, so the override rescales the
/// whole document without re-preparation.
public extension DynamicTypeSize {
    /// This size moved `steps` rungs along the `DynamicTypeSize` ladder,
    /// clamped at `.xSmall` and `.accessibility5`.
    func shifted(by steps: Int) -> DynamicTypeSize {
        let ladder = DynamicTypeSize.allCases
        guard let index = ladder.firstIndex(of: self) else { return self }
        return ladder[min(max(index + steps, 0), ladder.count - 1)]
    }

    /// Apple's default body point size at this Dynamic Type size. The ratio
    /// between two sizes approximates how much rendered text grows — used
    /// for the collapsed-spacer estimate and the control's percentage label.
    var approximateBodyPointSize: CGFloat {
        switch self {
        case .xSmall: 14
        case .small: 15
        case .medium: 16
        case .large: 17
        case .xLarge: 19
        case .xxLarge: 21
        case .xxxLarge: 23
        case .accessibility1: 28
        case .accessibility2: 33
        case .accessibility3: 40
        case .accessibility4: 47
        case .accessibility5: 53
        @unknown default: 17
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter DynamicTypeStepTests`
Expected: 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ADFRendering/DynamicTypeStep.swift Tests/ADFRenderingTests/DynamicTypeStepTests.swift
git commit -m "feat: add DynamicTypeSize step helpers for host text-size controls"
```

---

### Task 2: In-place rescale for collapsed spacer heights

**Files:**
- Modify: `Sources/ADFRendering/CollapsedRowHeight.swift`
- Test: `Tests/ADFRenderingTests/CollapsedRowHeightTests.swift` (append tests)

**Interfaces:**
- Consumes: nothing new.
- Produces: `mutating func rescale(by factor: CGFloat)` on `CollapsedRowHeight`; `var scalesWithTypeSize: Bool` on `RenderBlock.Kind` (internal, both) — consumed by Task 3's `DocumentRow`.

- [ ] **Step 1: Write the failing tests** (append inside `CollapsedRowHeightTests`)

```swift
    /// A Dynamic Type change resizes every collapsed row at an unchanged
    /// width. Samples must NOT be dropped — an empty memo re-materializes
    /// the row, and re-materializing thousands at once livelocks layout
    /// (§16). Instead the remembered heights are carried across as scaled
    /// estimates, corrected when the row naturally re-enters.
    @Test("A type-size change rescales remembered heights in place")
    func rescaleScalesEverySample() {
        var heights = CollapsedRowHeight()
        heights.record(height: 100, at: 400)
        heights.record(height: 60, at: 800)
        heights.rescale(by: 28.0 / 17.0)
        #expect(!heights.isEmpty)
        #expect(heights.height(at: 400, scaling: .reflowing) == 100 * 28.0 / 17.0)
        #expect(heights.height(at: 800, scaling: .reflowing) == 60 * 28.0 / 17.0)
    }

    @Test("Rescaling by 1 or on an empty memo is a no-op")
    func rescaleDegenerateCases() {
        var empty = CollapsedRowHeight()
        empty.rescale(by: 2)
        #expect(empty.isEmpty)

        var heights = CollapsedRowHeight()
        heights.record(height: 100, at: 400)
        heights.rescale(by: 1)
        #expect(heights.height(at: 400, scaling: .reflowing) == 100)
    }

    /// Media boxes are sized from pixel attributes or column fractions —
    /// text size does not move them, so their spacers must not rescale.
    @Test("Every block kind declares whether its height tracks the type size")
    func kindsDeclareTypeSizeResponse() {
        #expect(!RenderBlock.Kind.media(.stub()).scalesWithTypeSize)
        #expect(RenderBlock.Kind.codeBlock(language: nil, code: "").scalesWithTypeSize)
        #expect(RenderBlock.Kind.listRows([]).scalesWithTypeSize)
        #expect(RenderBlock.Kind.divider.scalesWithTypeSize)
        #expect(RenderBlock.Kind.mediaStrip([]).scalesWithTypeSize)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter CollapsedRowHeightTests`
Expected: compile FAILURE — `rescale(by:)` / `scalesWithTypeSize` not defined.

- [ ] **Step 3: Implement** (in `Sources/ADFRendering/CollapsedRowHeight.swift`)

Add to `CollapsedRowHeight` (after `record(height:at:)`):

```swift
    /// Carries every remembered height across a Dynamic Type size change as
    /// an estimate: text reflows at the same width to roughly
    /// `factor = newBodyPointSize / oldBodyPointSize` times the height.
    ///
    /// Rescaling — never clearing — is load-bearing: an empty memo makes
    /// `DocumentRow` re-materialize the row to measure it, and a type-size
    /// change hits every collapsed row at once (see §16: mass
    /// re-materialization livelocks layout). The estimate is provisional,
    /// like the per-kind width estimates: the exact height is re-measured
    /// when the row naturally re-enters the render region.
    mutating func rescale(by factor: CGFloat) {
        guard factor > 0, factor != 1 else { return }
        samples = samples.map { ($0.width, $0.height * factor) }
    }
```

Add to the `RenderBlock.Kind` extension (after `heightScaling`):

```swift
    /// Whether this block's rendered height tracks the text size. Media
    /// boxes are sized from pixel attributes or column fractions, so a
    /// Dynamic Type change leaves them alone; everything else contains
    /// text that grows (`mediaStrip`'s fixed height is itself a
    /// `@ScaledMetric`, so it moves too).
    var scalesWithTypeSize: Bool {
        if case .media = self { return false }
        return true
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter CollapsedRowHeightTests`
Expected: all tests PASS (existing 11 + new 3).

- [ ] **Step 5: Commit**

```bash
git add Sources/ADFRendering/CollapsedRowHeight.swift Tests/ADFRenderingTests/CollapsedRowHeightTests.swift
git commit -m "feat: rescale collapsed spacer heights across type-size changes"
```

---

### Task 3: React to runtime type-size changes in the document view

**Files:**
- Modify: `Sources/ADFRendering/ADFDocumentView.swift`

**Interfaces:**
- Consumes: `DynamicTypeSize.approximateBodyPointSize` (Task 1), `CollapsedRowHeight.rescale(by:)`, `RenderBlock.Kind.scalesWithTypeSize` (Task 2).
- Produces: `ADFDocumentView` now handles any environment `dynamicTypeSize` change (host override or system setting) without stale spacers or scroll drift. No API change.

- [ ] **Step 1: Extract the shared re-anchor and add the type-size trigger**

In `ADFDocumentView`, add an environment read next to the other properties (after `containerWidth`, line ~29):

```swift
    /// Watched so a runtime type-size change (host override or the system
    /// setting) can re-assert the scroll anchor: it reflows every row's
    /// height at an unchanged column width on iPhone, so the width-change
    /// re-pin below never fires for it.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
```

Replace the body of `.onChange(of: containerWidth) { … }` (keep its full comment block) and add a sibling `onChange`, both delegating to one helper:

```swift
            .onChange(of: containerWidth) {
                reassertAnchor(proxy)
            }
            // A Dynamic Type change is the width change's sibling: every row
            // reflows to a new height while the column width stays the same
            // (on iPhone — on iPad `readableWidth` is @ScaledMetric, so the
            // width re-pin above fires too; double-asserting the same anchor
            // is harmless). Same one-shot, identity-based re-pin, same
            // reasons — see the comment above.
            .onChange(of: dynamicTypeSize) {
                reassertAnchor(proxy)
            }
```

Add the helper after `anchorBinding`:

```swift
    /// One-shot, identity-based scroll re-pin: re-derives the offset for the
    /// remembered top row from current row heights. Snap, don't slide: the
    /// triggering change can carry an animation transaction, and a re-anchor
    /// should be instantaneous.
    private func reassertAnchor(_ proxy: ScrollViewProxy) {
        guard let anchor = model.anchors.topRow else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(anchor, anchor: .top)
        }
    }
```

- [ ] **Step 2: Rescale collapsed spacers in `DocumentRow`**

Add to `DocumentRow` (after the `visibility` property):

```swift
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
```

Add after the existing `.onChange(of: item.revision) { … }` modifier:

```swift
        .onChange(of: dynamicTypeSize) { old, new in
            // The text size changed under a collapsed row. Its remembered
            // heights must move with the text — but the row must NOT
            // re-materialize to re-measure (mass re-materialization
            // livelocks layout, see `heights`), and emptying the memo would
            // do exactly that via the `heights.isEmpty` branch above. So
            // the samples are rescaled in place: an estimate, corrected on
            // natural re-entry. A live row stays materialized and its
            // geometry callback re-records the exact height.
            guard !isInRenderRegion, block.kind.scalesWithTypeSize else { return }
            heights.rescale(by: new.approximateBodyPointSize / old.approximateBodyPointSize)
        }
```

- [ ] **Step 3: Build and run the package tests**

Run: `swift build && swift test`
Expected: build succeeds, all tests PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/ADFRendering/ADFDocumentView.swift
git commit -m "fix: keep scroll anchor and spacer heights truthful across type-size changes"
```

---

### Task 4: Per-document persistence and launch-argument override (app)

**Files:**
- Create: `Demo/ADFReader/FontSizeStore.swift`
- Modify: `Demo/ADFReader/ADFReaderApp.swift` (LaunchOptions)

**Interfaces:**
- Produces: `FontSizeStore` with `func step(for docKey: String) -> Int` and `func setStep(_ step: Int, docKey: String)`; `LaunchOptions.fontSizeStep: Int?` — consumed by Task 5's `ReaderView`.

- [ ] **Step 1: Create the store** (mirrors `TaskStateStore`; no app test target exists — verified through Task 6's integration run)

```swift
// Demo/ADFReader/FontSizeStore.swift
import Foundation

/// Persists the per-document text-size step as `[docKey: Int]` in
/// UserDefaults. Read-modify-write per change; the data set is tiny.
struct FontSizeStore {
    var defaults: UserDefaults = .standard
    private let key = "adf.fontSizeSteps"

    func step(for docKey: String) -> Int {
        all()[docKey] ?? 0
    }

    func setStep(_ step: Int, docKey: String) {
        var map = all()
        if step == 0 {
            // The default needs no entry; dropping it keeps the map from
            // accumulating a key per document ever visited.
            map.removeValue(forKey: docKey)
        } else {
            map[docKey] = step
        }
        if let data = try? JSONEncoder().encode(map) {
            defaults.set(data, forKey: key)
        }
    }

    private func all() -> [String: Int] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Int].self, from: data)
        else { return [:] }
        return decoded
    }
}
```

- [ ] **Step 2: Add `-fontSizeStep` to `LaunchOptions`**

In `Demo/ADFReader/ADFReaderApp.swift`: extend the doc comment list with

```swift
/// - `-fontSizeStep <n>` opens the reader with the text-size control at
///   step `n` (ladder steps relative to the system size), bypassing the
///   persisted per-document value — so perf gates can run at large sizes.
```

add the property after `searchUpdates`:

```swift
    var fontSizeStep: Int?
```

and the parser case after the `-searchUpdates` case:

```swift
            case "-fontSizeStep" where arguments.index(after: index) < arguments.endIndex:
                index = arguments.index(after: index)
                fontSizeStep = Int(arguments[index])
```

- [ ] **Step 3: Verify it compiles**

Run: `xcodebuild -project Demo/ADFReader.xcodeproj -scheme ADFReader -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -configuration Debug -quiet build`
Expected: `BUILD SUCCEEDED` (FontSizeStore is unused until Task 5 — that is fine; unused-type warnings don't exist, and warnings-as-errors stays green).

- [ ] **Step 4: Commit**

```bash
git add Demo/ADFReader/FontSizeStore.swift Demo/ADFReader/ADFReaderApp.swift
git commit -m "feat: persist per-document text-size steps and add -fontSizeStep launch arg"
```

---

### Task 5: Toolbar control and the scoped override

**Files:**
- Create: `Demo/ADFReader/TextSizeControl.swift`
- Modify: `Demo/ADFReader/ReaderView.swift`

**Interfaces:**
- Consumes: `FontSizeStore`, `LaunchOptions.fontSizeStep` (Task 4), `DynamicTypeSize.shifted(by:)` / `.approximateBodyPointSize` (Task 1, via `import ADFRendering`).
- Produces: the user-facing feature.

- [ ] **Step 1: Create the popover control**

```swift
// Demo/ADFReader/TextSizeControl.swift
import SwiftUI
import ADFRendering

/// Popover content for the toolbar text-size item: step the document's type
/// size down/up along the Dynamic Type ladder, with a percentage readout
/// relative to the reader's own baseline (step 0 = 100%) and a reset.
///
/// A popover, not a `Menu`: menu buttons dismiss on every tap, which kills
/// repeated A+ tapping.
struct TextSizeControl: View {
    @Binding var step: Int
    let systemTypeSize: DynamicTypeSize
    let onChange: (Int) -> Void

    private var effective: DynamicTypeSize { systemTypeSize.shifted(by: step) }

    private var percent: Int {
        Int((effective.approximateBodyPointSize
            / systemTypeSize.approximateBodyPointSize * 100).rounded())
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    adjust(-1)
                } label: {
                    Image(systemName: "textformat.size.smaller")
                        .frame(minWidth: 44, minHeight: 36)
                }
                .disabled(effective == DynamicTypeSize.allCases.first)
                .accessibilityLabel("Decrease Text Size")

                Text("\(percent)%")
                    .font(.callout.monospacedDigit())
                    .frame(minWidth: 56)

                Button {
                    adjust(1)
                } label: {
                    Image(systemName: "textformat.size.larger")
                        .frame(minWidth: 44, minHeight: 36)
                }
                .disabled(effective == DynamicTypeSize.allCases.last)
                .accessibilityLabel("Increase Text Size")
            }

            Divider()

            Button("Reset to 100%") {
                set(0)
            }
            .font(.callout)
            .disabled(step == 0)
            .accessibilityLabel("Reset Text Size")
        }
        .padding(12)
    }

    private func adjust(_ delta: Int) {
        // Step from the EFFECTIVE size, not the raw step: a persisted step
        // that overshoots the ladder under the current system size (saved
        // when the system size was different) would otherwise need several
        // taps before anything visibly changes.
        let ladder = DynamicTypeSize.allCases
        guard let target = ladder.firstIndex(of: effective.shifted(by: delta)),
              let base = ladder.firstIndex(of: systemTypeSize) else { return }
        set(target - base)
    }

    private func set(_ newStep: Int) {
        step = newStep
        onChange(newStep)
    }
}
```

- [ ] **Step 2: Wire `ReaderView`**

In `Demo/ADFReader/ReaderView.swift`:

Add state/properties (after `automationStarted`):

```swift
    @State private var fontSizeStep = 0
    @State private var textSizePresented = false
    /// The un-overridden size — the override is applied deeper, on
    /// `ADFDocumentView` only, so this reads the system/app baseline.
    @Environment(\.dynamicTypeSize) private var systemTypeSize
```

and (after `taskStore`):

```swift
    private let fontSizeStore = FontSizeStore()
```

Apply the override — the FIRST modifier on `ADFDocumentView`, so the
navigation bar, toolbar, search bar, and overlays outside it keep the app's
normal size:

```swift
        ADFDocumentView(model: model,
                        mediaProvider: mediaProvider,
                        interactionHandler: handle,
                        taskStates: taskStates,
                        mentionContent: { AnyView(ProfileCard(name: $0)) })
            .dynamicTypeSize(systemTypeSize.shifted(by: fontSizeStep))
            .navigationTitle(source.title)
```

Add the toolbar item in `toolbarContent`, between the "Find in Page" and
"Table of Contents" items:

```swift
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                textSizePresented.toggle()
            } label: {
                Label("Text Size", systemImage: "textformat.size")
            }
            .popover(isPresented: $textSizePresented) {
                TextSizeControl(
                    step: $fontSizeStep,
                    systemTypeSize: systemTypeSize
                ) { newStep in
                    fontSizeStore.setStep(newStep, docKey: source.storageKey)
                }
                .presentationCompactAdaptation(.popover)
            }
        }
```

Load the persisted step in `load()`, after `taskStates = …`:

```swift
        // A launch-argument step bypasses (and never writes) the persisted
        // value, so automation runs don't disturb the user's choice.
        fontSizeStep = options.fontSizeStep ?? fontSizeStore.step(for: source.storageKey)
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project Demo/ADFReader.xcodeproj -scheme ADFReader -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -configuration Debug -quiet build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Smoke-run on the simulator**

```bash
xcrun simctl install booted "$APP"
xcrun simctl launch --console-pty booted com.connie.adfreader -fixture kitchen-sink -fontSizeStep 3
```

Expected: READY line prints; a screenshot (`xcrun simctl io booted screenshot …`) shows visibly larger text than a `-fontSizeStep 0` run, with the navigation bar/toolbar unchanged.

- [ ] **Step 5: Commit**

```bash
git add Demo/ADFReader/TextSizeControl.swift Demo/ADFReader/ReaderView.swift
git commit -m "feat: per-document text size control in the reader toolbar"
```

---

### Task 6: Verification — element coverage and perf gates

**Files:** none (verification; screenshots to the session scratchpad)

The completion criteria: **every ADF element responds to the size increase appropriately (own size + layout), and scroll performance does not degrade.**

- [ ] **Step 1: Element-coverage screenshots**

For each fixture in `kitchen-sink`, `giant-table`, `media-gallery`: launch with `-fontSizeStep 0` and `-fontSizeStep 3` (and kitchen-sink also at `-3`), screenshot, compare:

```bash
xcrun simctl launch booted com.connie.adfreader -fixture kitchen-sink -fontSizeStep 3
sleep 3 && xcrun simctl io booted screenshot <scratchpad>/kitchen-sink-plus3.png
```

Checklist (view the screenshots): headings h1–h6, paragraph text, inline code, code blocks, list rows + markers (indent tracks size), panels, quotes, table cells + header + number gutter, mention/status/date pills, card/link blocks, expand titles, media captions all visibly larger and proportionate; media images unchanged (pixel-sized — intended); nothing clipped or truncated; toolbar/nav title unchanged. Scroll to cover the whole fixture (use `-scrollToFraction` for deep sections).

- [ ] **Step 2: Autoscroll gate at default size (regression check)**

Same commands as Task 0. Compare `hitchRatioMsPerS` against `<scratchpad>/perf-baseline.txt`. Expected: within run-to-run noise of the baseline.

- [ ] **Step 3: Autoscroll gate at +3**

```bash
xcrun simctl launch --console-pty booted com.connie.adfreader -fixture stress-5k -autoscroll -fontSizeStep 3
```

Expected: completes with a `SCROLL_METRICS` line in the same regime as baseline (note: `BlockHeightEstimator` paces legs assuming default-size text, so pacing skews slightly — the number is indicative; the hard gate is Step 4). No hitch storm, no livelock.

- [ ] **Step 4: Fling-burst CPU gate (the one that catches livelocks)**

Launch `stress-5k` at `-fontSizeStep 3`, then:

```bash
for i in $(seq 1 12); do axe swipe -x 200 --start-y 700 --end-y 200 --duration 0.05 --udid <udid>; done
sleep 5
PID=$(xcrun simctl spawn booted launchctl list | grep com.connie.adfreader | awk '{print $1}')
top -l 2 -pid $PID -stats pid,cpu | tail -2
```

Expected: CPU settles to ~0.0 (second `top` sample). Repeat at step 0 after changing size mid-session (Step 5) — the rescale path must not leave layout unstable.

- [ ] **Step 5: Mid-scroll size change (anchor + spacer integrity)**

Launch `-fixture stress-5k -scrollToFraction 0.5` (no step arg). Via the UI (axe taps on "Text Size", then "Increase Text Size" ×3): confirm the reader stays on the same content (no teleport), then fling up and down past collapsed regions: no phantom blank space, no jumps. Then rotate (`notifyutil -p com.connie.adfreader.rotate`) and confirm position retention still behaves.

- [ ] **Step 6: Persistence round-trip**

Open a fixture from the space list (no launch args), set +2 via the control, kill and relaunch the app, reopen the same document: size restored; a different document still at 100%. Reset to 100%; relaunch; still 100%.

- [ ] **Step 7: Full test suite**

Run: `swift test`
Expected: all PASS.

---

### Task 7: Document the decision

**Files:**
- Modify: `docs/Architecture-Decisions.md` (append a section)

- [ ] **Step 1: Append the ADR entry** — a short section following the doc's existing style, recording: per-document text size = `.dynamicTypeSize()` override scoped to `ADFDocumentView` (semantic fonts + `@ScaledMetric` make it free — no re-preparation); collapsed spacers RESCALE in place on type-size change (never clear — empty memo ⇒ re-materialization ⇒ §16 livelock); type-size change is a re-anchor trigger sibling to width change; measured gate numbers from Task 6.

- [ ] **Step 2: Commit**

```bash
git add docs/Architecture-Decisions.md
git commit -m "docs: record per-document text size design in architecture decisions"
```

---

## Self-Review Notes

- Spec coverage: persistence (Task 4), popover UI + scoping (Task 5), library robustness (Tasks 2–3), helpers + percentage (Task 1), launch arg (Task 4), perf protocol + element coverage (Tasks 0, 6), docs (Task 7). Spec amendment for the rescale-vs-reset correction and helper location is committed alongside this plan.
- Deviations from spec, both improvements discovered against real code: (1) invalidation = **rescale in place**, not revision-style reset (reset ⇒ `heights.isEmpty` ⇒ mass re-materialization ⇒ livelock); (2) step helpers live in `ADFRendering` as public extensions (testable via `swift test`; the app has no test target) rather than app-side.
