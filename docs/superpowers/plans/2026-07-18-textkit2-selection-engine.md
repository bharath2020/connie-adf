# TextKit 2 Selection Engine — Implementation Plan (Phases 4–5)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build (or kill) native character-level, cross-block text selection over the per-row TextKit 2 renderer proven in phases 1–3 — the ADR §2 "revisit only if cross-block selection becomes a requirement" revisit, tracked by issue #5 — and end in the final assessment verdict, per `docs/superpowers/specs/2026-07-17-textkit2-port-design.md` §§7, 10, 11 (steps 4–5).

**Architecture:** A read-only `UITextInput` + `UITextInteraction(.nonEditable)` + `UIEditMenuInteraction` attached to an **ancestor** — the *introspected* hosting `UIScrollView`'s content container — over the real SwiftUI-hosted lazy document (the phase-1 spike proved the arbitration on a *synthetic* UIKit stack; the real hierarchy needs a scroll-view introspector that does not exist yet). The text model is the search corpus (`index.itemOrder → units → plainText`) with freshly-built **UTF-16** cumulative prefix sums; geometry comes from live TK2 rows' *own* real layouts through a non-observed, document-order-sorted registry with collapsed-row interpolation; selection state lives in a non-observed reference box on `ADFDocumentModel`, epoch-guarded against non-tail-append mutations.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI + UIKit, TextKit 2 (`NSTextLayoutManager`/`NSTextContentStorage`), `UITextInput`/`UITextInteraction`/`UIEditMenuInteraction`, Swift Testing, xcodegen, axe (simulator automation).

**Scope note:** This plan covers spec phases 4–5 (selection engine → interaction hardening → epochs → remaining gates → verdict). It is the deliverable Task 14 of `docs/superpowers/plans/2026-07-17-textkit2-port-prototype.md` promised, written now that phases 1–3 have cleared their gates (see `docs/TextKit2-Port-Assessment.md`, "Phase 3 final verdict"). It builds on the phase 1–3 branch `textkit2-port-prototype` (HEAD `8ba8fb3`) and the phase-3 known-gaps register (12 items); every register item is either **scheduled** in a task below or **explicitly deferred** with a recorded rationale (see the Self-review checklist). Numbering continues from the phases 1–3 plan (Tasks 0–14) to keep one coherent task stream on the shared branch: this plan is Tasks 15–28.

## Global Constraints

Every task implicitly includes these. The first block is carried forward verbatim from the phases 1–3 plan and `docs/Architecture-Decisions.md`; the second block is the selection-specific set from spec §7.

**Carried forward (phases 1–3):**

- Platform floor iOS 17 / macOS 14; TK2 + selection glue `#if os(iOS)`; the package must keep building and all existing tests passing via bare `swift test` on macOS. The **2-warning baseline** is fixed (`ADFBeamTests` unhandled-resource + `IncrementalSearchIndexTests` redundant-`#require`) — any new warning is a regression to fix or explain.
- Never branch on `#available` (or introduce `AnyView`) at any per-row position; a constant-`Bool` `if/else` at a leaf is safe (§18, §20). The `-selection` toggle is read once into a `static let` and branched only at the document-container level, never per lazy row.
- No string allocation, `AttributedString` scanning, or TextKit layout inside SwiftUI `body` beyond O(1) memoized lookups (§2, §5.3). Selection geometry queries run in UIKit interaction callbacks, never in a SwiftUI evaluation.
- `TextKit2RowUIView` never calls `invalidateIntrinsicContentSize`; `sizeThatFits` stays synchronous, deterministic (`ensureLayout` to end), memoized per width; exactly one geometry commit per materialization (§16 livelock class). Adding geometry-query methods must not perturb this — queries read the already-laid-out `layoutManager`, they never trigger a re-measure.
- Fonts resolve at the view layer from `context.environment.dynamicTypeSize` via `UIFont.preferredFont(forTextStyle:compatibleWith:)` + descriptor traits — never `UIFontMetrics` scaling of a base point size; nothing size-dependent is baked at preparation time (§19).
- `RenderBlock`/segment payloads stay closure-free `Sendable + Hashable`; the `[InlineSegment]` array shape (indices, word-chunk splits) must not change — `SearchHighlightSpan.segmentIndex`, the SearchIndexer parts map, and now the selection geometry bridge all index it (§18).
- **RULE ZERO — foreground-only measurement:** every perf/behavioral number is captured with the app in the foreground on a dedicated, freshly-created simulator (created at task start, deleted at task end); `axe` + `notifyutil -p com.connie.adfreader.rotate` for rotation (`RotationHook`); `AXRaise` the target Simulator window by name before rotating; filter `pgrep`/`top` by this sim's UDID or the launch command's own PID (other booted sims run unrelated copies of the app — do not touch them).
- Perf verification for any scrolling change: `-autoscroll` vs a **freshly measured same-build baseline** (A/B, same sim, same install, only the launch arg changes) **plus** a real fling burst with instantaneous CPU settling to ~0 (`top -l 2 -pid`, not `ps`) — the autoscroll gate provably misses livelocks.
- **Evidence integrity:** every number written into the assessment doc must match the screenshot/console output it cites. Two phase-1–3 tasks were caught overclaiming (Task 10 chip drift, Task 13 rotation jitter); re-derive from the artifact before writing, and if a check is flaky after 3 tries mark it UNTESTED rather than guess.
- Git: commit at the end of every task; branch `textkit2-port-prototype`; never merge to main within this plan.

**Selection-specific (spec §7):**

- **UTF-16 is the global currency.** Every `UITextPosition`, every `position(from:offset:)`/`offset(from:to:)`/`compare(_:to:)`, and every prefix sum is UTF-16 code units, because `UITextInputStringTokenizer` computes word boundaries in UTF-16 inside UIKit, outside any boundary we control. `Character` offsets appear only at the search-corpus/parts-map boundary, converted through cached per-unit tables.
- **Geometry is on-demand only.** Queried during selection interactions, never during scroll or idle. Live rows self-register (weakly, by `ownerID`) in a plain **non-observed** registry at `didMoveToWindow`; that registration is the only at-rest cost. Queries binary-search the document-order-sorted registry; eviction happens on row collapse.
- **Whole-block fallback for collapsed rows.** Collapsed-row rects are synthesized by interpolating between live neighbors using known spacer heights; `containsStart`/`containsEnd` are computed from **range membership**, never array position; `caretRect` never returns `.null`.
- **Select-as-unit for plugin/custom blocks:** excluded from character ranges; endpoints snap across them like selecting over an image.
- **Atom atomicity is an invariant:** selection endpoints snap to the nearer pill edge; the caret never lands strictly inside an atom's range; selection rects cover the whole pill when any of its range is selected; the tokenizer treats an atom's range as a single word; copy uses the atom's `fallbackText` in full or not at all.
- **Epoch-guarded state.** Selection lives in a non-observed reference box owned by the model (the `ScrollAnchorRegistry` pattern); per-touch-move writes invalidate nothing; SwiftUI sees only one coarse session-active `Bool` that flips at session start/end. The document epoch bumps on **any** index change that is not a pure tail append (`load()`, and `apply(_:revision:)` replacements/removals/moves/non-tail inserts). On an epoch bump mid-gesture, the interaction's recognizers are cancelled explicitly and the range is clamped/cleared via `inputDelegate` before the next query.
- **Expand visibility at the edges.** Collapsed expand bodies stay in the offset space (offset stability wins); units whose `expandAncestorIDs` are not all open are excluded from copy output, selection rects, and `closestPosition` candidates; endpoints snap across closed ranges; an expand toggle is a selection-rect invalidation, not a text-model change.
- **Copy** is a document-order joined slice of the virtual string, byte-identical to the search corpus (minus hidden-expand exclusions), joined per unit by `"\n"`. List markers are neither highlighted (rects come from real layouts, text only) nor copied.
- **Drag-past-edge autoscroll writes `model.anchors.topRow`** (the §8b truthfulness contract); per-touch-move work is a binary search over cached frames, never a scan of all-ever-registered entries.
- **`hitTest` is never overridden; there is no capture-vs-pass region logic.** Tap-to-clear and long-press-inside-selection are ancestor recognizers with failure requirements against descendant controls. `copy(_:)`/`canPerformAction(_:withSender:)` responder wiring is mandatory (spike constraint #1), not an automatic side effect of adopting `UITextInput`.
- The **platform-agnostic** selection core (text model, offset math, prefix sums, registry math, epoch logic) is `swift test`-runnable on macOS; only `UITextInteraction`/edit-menu/scroll-introspection glue is `#if os(iOS)`.

**Demo build reference (used by Tasks 16, 20, 21, 23, 25, 26, 27):**

```bash
cd /Users/bharath2020/Documents/projects/connie-adf/Demo
xcodegen generate                      # after adding any Demo/Sources file
xcodebuild -project ADFReader.xcodeproj -scheme ADFReader \
  -destination "platform=iOS Simulator,id=<DEDICATED-SIM-UDID>" build
xcrun simctl install <UDID> <DerivedData>/Build/Products/Debug-iphonesimulator/ADFReader.app
# Confirm the install is HEAD before measuring (phases 1–3 discipline):
strings <path>/ADFReader.debug.dylib | grep -E "SelectionController|-selection|RowGeometryRegistry"
```

---

### Task 15: Plan commit

**Files:** this plan document only (git).

- [ ] **Step 1: Commit the plan**

```bash
cd /Users/bharath2020/Documents/projects/connie-adf
git add docs/superpowers/plans/2026-07-18-textkit2-selection-engine.md
git commit -m "docs: TextKit 2 selection engine implementation plan (phases 4-5)"
```

---

## Phase 4 — Selection engine

### Task 16 — [KILL-FAST #1] Introspected ancestor attachment over the real document

**Why first:** the phase-1 spike proved `UITextInteraction(.nonEditable)` on an ancestor coexists with descendant gestures — but on a *synthetic* `SpikeViewController` that built its own `UIScrollView` + `UILabel`s. The real target is SwiftUI's `ADFDocumentView` scroll view, which **has no introspection hook today** (confirmed: the only `UIScrollView`/`UITextInput` code in the repo is the throwaway `SelectionSpike.swift`; `ADFDocumentView` talks to its `ScrollView` only through `ScrollViewProxy` + the tracking `scrollPosition(id:)` binding). If `UITextInteraction` cannot operate as an ancestor of *SwiftUI-hosted* interactive descendants (links, `TaskMarkerView` checkboxes, the YouTube facade, `TableScrollSync`/code horizontal pans) — or if the introspected content container is the wrong ancestor — the whole architecture dies here, cheapest. Geometry is deliberately crude at this task (whole-owner rects); the question is *attachment + arbitration on the real hierarchy*, not rect fidelity.

**Files:**
- Create: `Sources/ADFRendering/TextKit2/Selection/ScrollViewIntrospector.swift` (`#if os(iOS)`)
- Create: `Sources/ADFRendering/TextKit2/Selection/SelectionController.swift` (`#if os(iOS)`; crude skeleton this task, fleshed out in Tasks 18–22)
- Create: `Sources/ADFRendering/TextKit2/Selection/SelectionFlags.swift`
- Modify: `Sources/ADFRendering/ADFDocumentView.swift` (install the introspector behind `-selection`)
- Modify: `Demo/ADFReader/ADFReaderApp.swift` (document `-selection` in the launch-arg comment; it is read by `SelectionFlags`, not parsed into `LaunchOptions`)
- Modify: `docs/TextKit2-Port-Assessment.md` (record the arbitration matrix on the real hierarchy)

**Interfaces:**
- Produces: `enum SelectionFlags { static let enabled: Bool }` (`-selection`, requires `-textkit2`); `struct ScrollViewIntrospector: UIViewRepresentable` that walks up the superview chain to the enclosing `UIScrollView`, grabs its first content subview as the container, and installs a `SelectionController` on it; `final class SelectionController: NSObject, UITextInput` (crude whole-owner geometry this task).

- [ ] **Step 1: `SelectionFlags.swift`**

```swift
import Foundation

/// Launch-arg toggle for the selection engine, read ONCE (constant, never
/// flips at runtime). Requires `-textkit2` — selection is served by the same
/// per-row TK2 layouts, so it is meaningless on the SwiftUI arm.
public enum SelectionFlags {
    public static let enabled: Bool =
        ProcessInfo.processInfo.arguments.contains("-selection")
        && ProcessInfo.processInfo.arguments.contains("-textkit2")
}
```

- [ ] **Step 2: `ScrollViewIntrospector.swift`**

The introspector is a zero-size `UIView` installed via `.background`. On `didMoveToWindow` it walks `superview` upward to the first `UIScrollView`, takes that scroll view's **first content subview** (SwiftUI's hosted content container — the ancestor of every rendered row) as the attachment target, and installs the controller's `UITextInteraction` + `UIEditMenuInteraction` on it. No `hitTest` override anywhere (spec §7).

```swift
#if os(iOS)
import SwiftUI
import UIKit

/// Finds SwiftUI's underlying `UIScrollView` and attaches the selection
/// controller to its content container (an ANCESTOR of every rendered row),
/// so descendant gestures keep native behavior and content-space geometry
/// scrolls for free (spec §7 feasibility question #1). No `hitTest` override.
struct ScrollViewIntrospector: UIViewRepresentable {
    let controller: SelectionController

    func makeUIView(context: Context) -> ProbeView { ProbeView(controller: controller) }
    func updateUIView(_ view: ProbeView, context: Context) { view.controller = controller }

    final class ProbeView: UIView {
        var controller: SelectionController
        private weak var attachedContainer: UIView?

        init(controller: SelectionController) {
            self.controller = controller
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isHidden = true
        }
        required init?(coder: NSCoder) { fatalError("unused") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            // Defer one runloop turn: on first `didMoveToWindow` the SwiftUI
            // scroll view may not yet have laid out its content subview.
            DispatchQueue.main.async { [weak self] in self?.attachIfPossible() }
        }

        private func attachIfPossible() {
            guard attachedContainer == nil else { return }
            var v: UIView? = superview
            while let current = v, !(current is UIScrollView) { v = current.superview }
            guard let scrollView = v as? UIScrollView,
                  let container = scrollView.subviews.first else { return }
            controller.attach(to: container, scrollView: scrollView)
            attachedContainer = container
        }
    }
}
#endif
```

Record in the assessment which subview is the correct content container (`scrollView.subviews.first` is the expected SwiftUI content host; if it is a private wrapper, log the view hierarchy with `container.recursiveDescription` (via KVC on the debug build) and adjust — this discovery is part of the kill question).

- [ ] **Step 3: `SelectionController.swift` — crude skeleton**

This task's controller conforms to `UITextInput` with **whole-owner** geometry (one rect per owner block, linear-interpolated caret) — the exact fidelity level of the phase-1 spike, but over the *real* rows. It holds the introspected container, a `UITextInteraction(for: .nonEditable)`, and a placeholder text model (the joined `SearchTextUnit.plainText` corpus). Reuse the spike's `UITextInput` conformance as the starting boilerplate:

```bash
# Boilerplate source (adapt, do not copy blind): the spike's read-only
# UITextInput conformance, already SDK-correct (position(within:farthestIn:),
# firstRect(for:) present per the phase-1 assessment's two recorded fixes).
sed -n '88,225p' Demo/ADFReader/SelectionSpike.swift
```

**Deltas from the spike boilerplate for this task's skeleton:**
1. `SelectionController` is `NSObject, UITextInput` (not a `UIView`) — it *attaches to* the introspected container rather than being an interactive view itself. `attach(to:scrollView:)` stores both, sets `interaction.textInput = self`, and `container.addInteraction(interaction)`.
2. `beginningOfDocument`/`endOfDocument`/`text(in:)` read a `SelectionTextModel`-shaped placeholder built this task from `model.search`'s corpus (`index.itemOrder → units → plainText`, UTF-16 length). Task 18 replaces the placeholder with the real prefix-sum model.
3. Geometry (`selectionRects`/`caretRect`/`closestPosition`) returns whole-owner rects from a *temporary* per-owner frame map populated in Task 17; this task may stub them to return the container bounds so the interaction has *something* to draw — the matrix below tests arbitration, not rect correctness.
4. `copy(_:)`/`canPerformAction` are **not** wired this task (spike row 8's known FAIL) — Task 20 adds them; note the expected "no Copy in the menu" here so it is not mistaken for a regression.

The controller exposes `func attach(to container: UIView, scrollView: UIScrollView)` and holds `weak var model: ADFDocumentModel?`, `let interaction = UITextInteraction(for: .nonEditable)`.

- [ ] **Step 4: Install behind `-selection` in `ADFDocumentView`**

In `ADFDocumentView` (the `ScrollViewReader { proxy in ScrollView { rows … } … }`), add — at the **document-container level only**, never per row — a background probe:

```swift
    // ... existing modifiers on the ScrollView ...
    #if os(iOS)
    .background {
        if SelectionFlags.enabled {
            ScrollViewIntrospector(controller: selectionController)
        }
    }
    #endif
```

`selectionController` is a `@State` on `ADFDocumentView` created once (`SelectionController(model: model)`), guarded so it is only constructed on iOS with the flag on. The `if SelectionFlags.enabled` reads a launch constant — a stable `_ConditionalContent`, not a per-row `#available`, so §18 is satisfied.

- [ ] **Step 5: Build + dedicated sim + arbitration matrix on the REAL hierarchy**

Create a dedicated sim (`ADF-Task16`, iPhone 16), build+install per the reference, launch `-fixture kitchen-sink -textkit2 -selection`. Run the same 8-row matrix the spike ran, but assert each descendant is a **real** SwiftUI-hosted control:

| # | Action | Pass condition |
|---|---|---|
| 1 | `axe tap` a link run in a TK2 paragraph | link opens (openURL) — descendant taps alive with the interaction attached |
| 2 | `axe tap` a task checkbox (`TaskMarkerView`) | checkbox toggles (state flips in `describe-ui`) |
| 3 | `axe swipe` horizontally over a code block / wide table | it pans (`TableScrollSync`/code h-scroll alive) |
| 4 | `axe touch` long-press over a TK2 paragraph | native selection + handles + edit menu appears |
| 5 | drag a handle across two blocks | selection extends across blocks (crude whole-block rects OK) |
| 6 | with selection active, tap the YouTube facade | player opens; selection persists |
| 7 | with selection active, pan the table | it pans; selection persists |
| 8 | vertical swipe on paragraph text | outer scroll scrolls |

Kill criterion (spec §10): if `UITextInteraction` cannot operate with SwiftUI-hosted hit-tested descendants (interaction internals cancel descendant touches, wrong content container, etc.), record **KILLED — fall back to geometry-oracle overlay** and stop.

- [ ] **Step 6: Record + commit** — write a "Phase 4 — Task 16: real-hierarchy ancestor attachment" section into `docs/TextKit2-Port-Assessment.md` with the matrix + screenshots + which content subview was the correct container. Commit:

```bash
git add Sources/ADFRendering/TextKit2/Selection Sources/ADFRendering/ADFDocumentView.swift \
  Demo/ADFReader/ADFReaderApp.swift docs/TextKit2-Port-Assessment.md
git commit -m "feat: introspected ancestor attachment of selection controller over real TK2 rows"
```

---

### Task 17 — [KILL-FAST #2] Row geometry registry + on-demand row-layout queries

**Why second:** with attachment proven, the next unknown is whether a live TK2 row can answer *character-level* rect/caret/hit-test queries from its **own** real layout (not a shadow layout — the prototype's #1 drift class), sorted and interpolated across a lazy stack where most rows are collapsed. This is the geometry substitute for the prototype's `PrototypeBeaconRegistry` + shadow-TextKit `PrototypeGeometryService`, replaced by real per-row TK2 layouts.

**Files:**
- Create: `Sources/ADFRendering/TextKit2/Selection/RowGeometryRegistry.swift`
- Modify: `Sources/ADFRendering/TextKit2/TextKit2RowView.swift` (self-registration + geometry-query methods on `TextKit2RowUIView`)
- Modify: `Sources/ADFRendering/Inline/SegmentedTextView.swift` (thread `ownerID` + the registry into the TK2 arm)
- Test: `Tests/ADFRenderingTests/RowGeometryRegistryTests.swift` (macOS-runnable: registry math)
- Test: `Tests/ADFRenderingTests/TextKit2RowGeometryTests.swift` (iOS lane: real-layout rect queries)

**Interfaces:**
- Produces: `@MainActor final class RowGeometryRegistry` (plain non-observed, document-order-sorted, binary-searched); `TextKit2RowUIView` gains `ownerID`, self-registration at `didMoveToWindow`/eviction, and `selectionRects(forUTF16 range: NSRange) -> [CGRect]`, `caretRect(atUTF16 offset: Int) -> CGRect?`, `closestUTF16Offset(to point: CGPoint) -> Int?` over its own `layout.layoutManager`.

- [ ] **Step 1: `RowGeometryRegistry.swift`** (platform-agnostic core; the `CGRect`/`CGPoint`/`UIView` types compile on macOS via `CoreGraphics`/`AppKit`, but the registry itself references only `CGRect` + a weak view box, so its *math* is macOS-testable)

```swift
import Foundation
#if canImport(UIKit)
import UIKit
public typealias ADFPlatformView = UIView
#elseif canImport(AppKit)
import AppKit
public typealias ADFPlatformView = NSView
#endif

/// Live TK2 rows, keyed by ownerID, kept in DOCUMENT ORDER for binary search.
/// A plain non-observed class (the `ScrollAnchorRegistry`/`VisibleRowRegistry`
/// pattern): rows register at `didMoveToWindow` and evict on collapse; writes
/// invalidate nothing. Queried ONLY during selection interactions — never on
/// the scroll path (spec §7).
@MainActor
public final class RowGeometryRegistry {
    /// Document order is supplied by the text model (built from
    /// `index.itemOrder`), NOT by registration order — a lazily-materialized
    /// row can register long after a later row. `orderOf` maps ownerID → its
    /// index in document order; the registry re-sorts its live entries by it.
    public var orderOf: (String) -> Int = { _ in .max }

    private struct Entry { let ownerID: String; weak var view: ADFPlatformView? }
    private var entries: [Entry] = []               // sorted by orderOf(ownerID)

    public init() {}

    public func register(ownerID: String, view: ADFPlatformView) {
        evictDead()
        entries.removeAll { $0.ownerID == ownerID }
        let entry = Entry(ownerID: ownerID, view: view)
        let idx = insertionIndex(forOrder: orderOf(ownerID))
        entries.insert(entry, at: idx)
    }

    public func unregister(ownerID: String) {
        entries.removeAll { $0.ownerID == ownerID || $0.view == nil }
    }

    public func liveView(for ownerID: String) -> ADFPlatformView? {
        entries.first { $0.ownerID == ownerID }?.view
    }

    /// Live rows whose ownerID sorts within `[lowerOrder, upperOrder]`, in
    /// document order — the candidate set for a selection range's rects. O(log
    /// n + k), never a scan of all-ever-registered entries.
    public func liveEntries(orderRange: ClosedRange<Int>) -> [(ownerID: String, view: ADFPlatformView)] {
        evictDead()
        return entries.compactMap { e in
            guard let v = e.view else { return nil }
            let o = orderOf(e.ownerID)
            return orderRange.contains(o) ? (e.ownerID, v) : nil
        }
    }

    /// The live row nearest (vertically) to a content-space point, plus the
    /// two live neighbors bracketing a gap — the inputs collapsed-row
    /// interpolation needs. `frameInContainer` converts each row to the
    /// container's coordinate space (the ancestor the controller attaches to).
    public func nearestLive(
        toY y: CGFloat, frameInContainer: (ADFPlatformView) -> CGRect
    ) -> (below: (ownerID: String, frame: CGRect)?, above: (ownerID: String, frame: CGRect)?) {
        evictDead()
        var above: (String, CGRect)?
        var below: (String, CGRect)?
        for e in entries {
            guard let v = e.view else { continue }
            let f = frameInContainer(v)
            if f.maxY <= y { above = (e.ownerID, f) }
            else if f.minY >= y, below == nil { below = (e.ownerID, f) }
        }
        return (below.map { ($0.0, $0.1) }, above.map { ($0.0, $0.1) })
    }

    private func insertionIndex(forOrder order: Int) -> Int {
        var lo = 0, hi = entries.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if orderOf(entries[mid].ownerID) < order { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func evictDead() { entries.removeAll { $0.view == nil } }
}
```

- [ ] **Step 2: `RowGeometryRegistryTests.swift`** (macOS-runnable — uses bare `ADFPlatformView`s with set frames)

```swift
import Foundation
import Testing
@testable import ADFRendering
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@Suite("RowGeometryRegistry") @MainActor
struct RowGeometryRegistryTests {
    private func view(y: CGFloat, h: CGFloat) -> ADFPlatformView {
        let v = ADFPlatformView(frame: CGRect(x: 0, y: y, width: 300, height: h)); return v
    }

    @Test func keepsDocumentOrderRegardlessOfRegistrationOrder() {
        let r = RowGeometryRegistry()
        r.orderOf = { ["a": 0, "b": 1, "c": 2][$0] ?? .max }
        r.register(ownerID: "c", view: view(y: 200, h: 20))   // registered first
        r.register(ownerID: "a", view: view(y: 0, h: 20))
        r.register(ownerID: "b", view: view(y: 100, h: 20))
        let live = r.liveEntries(orderRange: 0...2).map(\.ownerID)
        #expect(live == ["a", "b", "c"])
    }

    @Test func evictsCollapsedRows() {
        let r = RowGeometryRegistry()
        r.orderOf = { $0 == "a" ? 0 : 1 }
        do { let v = view(y: 0, h: 20); r.register(ownerID: "a", view: v) }  // v deallocs
        r.register(ownerID: "b", view: view(y: 40, h: 20))
        #expect(r.liveEntries(orderRange: 0...1).map(\.ownerID) == ["b"])
    }

    @Test func nearestLiveBracketsAGap() {
        let r = RowGeometryRegistry()
        r.orderOf = { ["a": 0, "z": 9][$0] ?? .max }
        r.register(ownerID: "a", view: view(y: 0, h: 20))     // maxY 20
        r.register(ownerID: "z", view: view(y: 500, h: 20))   // minY 500
        let (below, above) = r.nearestLive(toY: 250) { $0.frame }
        #expect(above?.ownerID == "a")
        #expect(below?.ownerID == "z")
    }
}
```

- [ ] **Step 3: Row self-registration + geometry queries on `TextKit2RowUIView`**

`TextKit2RowView` gains `var ownerID: String?` and `var geometry: RowGeometryRegistry?`, threaded from `SegmentedTextView` (which already has `ownerID`). `TextKit2RowUIView` gains `ownerID`/`registry` and:

```swift
    // In TextKit2RowUIView:
    var ownerID: String?
    weak var registry: RowGeometryRegistry?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let ownerID else { return }
        if window != nil { registry?.register(ownerID: ownerID, view: self) }
        else { registry?.unregister(ownerID: ownerID) }
    }

    /// Real-layout selection rects for a UTF-16 range in THIS row's attributed
    /// string, in the row's own coordinate space. Reads the already-committed
    /// `layoutManager` — never triggers a re-measure (§16). The caller
    /// converts to container space via `convert(_:to:)`.
    func selectionRects(forUTF16 range: NSRange) -> [CGRect] {
        guard range.length > 0, let textRange = textRange(for: range) else { return [] }
        var rects: [CGRect] = []
        layout.layoutManager.enumerateTextSegments(in: textRange, type: .selection) { _, frame, _, _ in
            if frame.width > 0, frame.height > 0 { rects.append(frame) }
            return true
        }
        return rects
    }

    func caretRect(atUTF16 offset: Int) -> CGRect? {
        guard let textRange = textRange(for: NSRange(location: offset, length: 0)) else { return nil }
        var caret: CGRect?
        layout.layoutManager.enumerateTextSegments(in: textRange, type: .standard) { _, frame, _, _ in
            caret = CGRect(x: frame.minX, y: frame.minY, width: 2, height: frame.height); return false
        }
        return caret
    }

    /// UTF-16 offset in THIS row nearest a point in the row's own space, via
    /// the TK2 line fragment under the point (`NSTextLineFragment` is UTF-16).
    func closestUTF16Offset(to point: CGPoint) -> Int? {
        var result: Int?
        layout.layoutManager.enumerateTextLayoutFragments(from: nil, options: []) { fragment in
            let frame = fragment.layoutFragmentFrame
            guard frame.minY <= point.y, point.y < frame.maxY else { return true }
            let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
            for line in fragment.textLineFragments {
                let lineRect = line.typographicBounds
                guard local.y >= lineRect.minY, local.y < lineRect.maxY || line === fragment.textLineFragments.last else { continue }
                let charInLine = line.characterIndex(for: CGPoint(x: local.x, y: lineRect.midY))
                let fragmentStart = layout.contentStorage.offset(
                    from: layout.contentStorage.documentRange.location,
                    to: fragment.rangeInElement.location)
                result = fragmentStart + charInLine
                return false
            }
            return true
        }
        return result
    }
```

(`textRange(for:)` — the private `NSRange → NSTextRange` helper — already exists in `TextKit2RowUIView` from Task 9; promote its visibility to `internal` for these methods. `offset(from:to:)` on `NSTextContentStorage` returns the UTF-16 distance.)

- [ ] **Step 4: `TextKit2RowGeometryTests.swift`** (iOS lane, `#if canImport(UIKit)`; run via the Demo test scheme) — build a row from a two-line paragraph, `measure(width:)`, assert `selectionRects(forUTF16:)` for a mid-string range returns ≥1 non-empty rect whose `minX > 0` for a range starting mid-line, and `closestUTF16Offset(to:)` at the row's top-left returns `0`. Assert `caretRect(atUTF16: length)` is non-nil (never `.null`).

- [ ] **Step 5: Wire the registry.** `ADFDocumentView` creates one `RowGeometryRegistry` (on the `SelectionController`), sets `registry.orderOf` from the selection text model's owner order (Task 18), and passes it down through `SegmentedTextView` → `TextKit2RowView` → `TextKit2RowUIView`. This task can set `orderOf` to a stub (registration still sorts once Task 18 supplies the real order). Verify `swift test --filter RowGeometryRegistryTests` (macOS) + the iOS lane pass; full `swift test` green.

- [ ] **Step 6: Commit** — `git commit -am "feat: RowGeometryRegistry + on-demand real-layout row geometry queries"`

---

### Task 18 — [KILL-FAST #3a] SelectionTextModel — UTF-16 prefix-sum corpus, atom snapping, copy

**Why third:** the text model is the platform-agnostic heart — the offset arithmetic every `UITextInput` method routes through, the atom-atomicity boundary, and the copy slice. It has zero UIKit dependencies, so it is fully `swift test`-runnable on macOS, and it must be correct before the controller (Task 19) can trust any offset. The prototype's `PrototypeDocumentText` used **Character** currency with `"\n"` joiners and stored `unitStarts` — this task ports that shape but switches the global currency to **UTF-16** (the tokenizer mandate) and adds atom-range snapping (the prototype never enforced atomicity).

**Files:**
- Create: `Sources/ADFRendering/TextKit2/Selection/SelectionTextModel.swift`
- Test: `Tests/ADFRenderingTests/SelectionTextModelTests.swift` (macOS-runnable)

**Interfaces:**
- Consumes: `SearchIndexedItem` (`id`, `topLevelBlockID`, `units`), `SearchTextUnit` (`ownerID`, `topLevelBlockID`, `expandAncestorIDs`, `plainText`, `parts`).
- Produces:

```swift
public struct SelectionTextModel {
    public struct Unit {
        public let ownerID: String
        public let topLevelBlockID: String
        public let expandAncestorIDs: [String]
        public let plainText: String
        public let parts: [SearchTextUnit.Part]
        public let utf16Length: Int
    }
    public struct PartSlice {                     // model → live row, for geometry
        public enum Source { case textSegment(index: Int); case atom(id: String) }
        public let unit: Int
        public let source: Source
        public let localCharRange: Range<Int>     // Character offset within that part's contribution
    }
    public let units: [Unit]
    public let unitUTF16Starts: [Int]             // prefix sums INCLUDING the "\n" joiner before each unit>0
    public let totalUTF16Length: Int
    public let ownerOrder: [String: Int]          // ownerID → document-order index (feeds RowGeometryRegistry.orderOf)

    public static func build(orderedItems: [SearchIndexedItem]) -> SelectionTextModel
    public func locate(utf16 offset: Int) -> (unit: Int, local: Int)?    // clamps into [0, total]
    public func globalOffset(unit: Int, localUTF16: Int) -> Int
    public func text(inUTF16 range: Range<Int>, isVisible: (Unit) -> Bool) -> String
    public func snapAcrossAtoms(_ offset: Int, forward: Bool) -> Int      // atom atomicity + expand edges
    public func partSlices(forUTF16 range: Range<Int>, isVisible: (Unit) -> Bool) -> [PartSlice]
}
```

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
import ADFPreparation
@testable import ADFRendering

@Suite("SelectionTextModel")
struct SelectionTextModelTests {
    private func textUnit(owner: String, top: String, _ text: String, expands: [String] = []) -> SearchTextUnit {
        SearchTextUnit(ownerID: owner, topLevelBlockID: top, expandAncestorIDs: expands,
                       plainText: text,
                       parts: [.init(source: .textSegment(index: 0), range: 0..<text.count)])
    }
    private func item(_ id: String, _ units: [SearchTextUnit]) -> SearchIndexedItem {
        SearchIndexedItem(id: id, topLevelBlockID: id, units: units)
    }

    @Test func prefixSumsCountUTF16IncludingJoiners() {
        let m = SelectionTextModel.build(orderedItems: [
            item("b0", [textUnit(owner: "b0", top: "b0", "ab")]),      // 2 utf16
            item("b1", [textUnit(owner: "b1", top: "b1", "c😄")]),     // c=1, 😄=2 → 3 utf16
        ])
        // unit0 starts at 0; unit1 starts after "ab" (2) + one "\n" joiner (1) = 3
        #expect(m.unitUTF16Starts == [0, 3])
        #expect(m.totalUTF16Length == 3 /*unit0*/ + 1 /*joiner*/ + 3 /*unit1*/)  // = 7
    }

    @Test func locateAndGlobalOffsetRoundTripAcrossJoiner() {
        let m = SelectionTextModel.build(orderedItems: [
            item("b0", [textUnit(owner: "b0", top: "b0", "ab")]),
            item("b1", [textUnit(owner: "b1", top: "b1", "cd")]),
        ])
        // global 4 = unit1 local 0 (unit0 len 2 + joiner 1 = 3 is unit1 start → local 1 = global 4)
        #expect(m.globalOffset(unit: 1, localUTF16: 1) == 4)
        let loc = m.locate(utf16: 4)
        #expect(loc?.unit == 1 && loc?.local == 1)
    }

    @Test func copyIsDocumentOrderJoinedByNewline() {
        let m = SelectionTextModel.build(orderedItems: [
            item("b0", [textUnit(owner: "b0", top: "b0", "hello")]),
            item("b1", [textUnit(owner: "b1", top: "b1", "world")]),
        ])
        #expect(m.text(inUTF16: 0..<m.totalUTF16Length, isVisible: { _ in true }) == "hello\nworld")
    }

    @Test func hiddenExpandUnitsExcludedFromCopy() {
        let m = SelectionTextModel.build(orderedItems: [
            item("b0", [textUnit(owner: "b0", top: "b0", "open")]),
            item("b1", [textUnit(owner: "b1", top: "e0", "hidden", expands: ["e0"])]),
            item("b2", [textUnit(owner: "b2", top: "b2", "tail")]),
        ])
        // e0 closed → its unit contributes nothing; endpoints snap across it.
        let copied = m.text(inUTF16: 0..<m.totalUTF16Length, isVisible: { !$0.expandAncestorIDs.contains("e0") })
        #expect(copied == "open\ntail")
    }

    @Test func atomRangeSnapsToNearerEdge() {
        // "@Bharath" is one atom part (fallbackText, 8 chars = 8 utf16).
        let atomUnit = SearchTextUnit(
            ownerID: "b0", topLevelBlockID: "b0", expandAncestorIDs: [],
            plainText: "@Bharath done",
            parts: [.init(source: .atom(id: "m1"), range: 0..<8),
                    .init(source: .textSegment(index: 1), range: 8..<13)])  // " done"
        let m = SelectionTextModel.build(orderedItems: [item("b0", [atomUnit])])
        #expect(m.snapAcrossAtoms(2, forward: true) == 8)    // inside atom, nearer forward edge
        #expect(m.snapAcrossAtoms(2, forward: false) == 0)   // inside atom, nearer back edge
        #expect(m.snapAcrossAtoms(9, forward: true) == 9)    // in " done" text — unchanged
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter SelectionTextModelTests` → FAIL: `SelectionTextModel` not found.

- [ ] **Step 3: Implement** — `build` walks `orderedItems` → `units`, dropping nothing (the corpus already dropped whitespace-only units); computes `utf16Length = plainText.utf16.count` per unit; accumulates `unitUTF16Starts` inserting **one `"\n"` (1 UTF-16 unit) between consecutive units** (matching the prototype's join and the Copy contract). `ownerOrder[unit.ownerID] = documentIndex`. Precompute `atomRangesGlobal: [Range<Int>]` (sorted): for each unit, for each `.atom` part, convert the part's Character range to a UTF-16 range within `plainText` (walk `plainText` by `Character` summing `utf16.count` — the same technique as `TextRowContent.utf16Range`), offset by `unitUTF16Starts[unit]`.

  - `locate(utf16:)`: clamp to `[0, total]`, binary-search `unitUTF16Starts` for the containing unit; a joiner offset (between units) resolves to the end of the preceding unit.
  - `globalOffset(unit:localUTF16:)`: `unitUTF16Starts[unit] + localUTF16`.
  - `text(inUTF16:isVisible:)`: iterate units overlapping the range; for each **visible** unit, take its local UTF-16 sub-range, slice `plainText` (via `String.Index(utf16Offset:in:)` or an `NSString` bridge), append; join visible-unit contributions with `"\n"`. Hidden units contribute nothing (spec §7 expand edges).
  - `snapAcrossAtoms(_:forward:)`: binary-search `atomRangesGlobal`; if `offset` is strictly inside an atom's range, return `forward ? min(dist-to-edges pick) …` — pick the nearer edge, ties broken by `forward` (nearer forward vs back edge as the test pins). Also snaps across a fully-hidden-expand unit's range to the nearest visible boundary (reuse the same edge logic over hidden-unit global ranges).
  - `partSlices(forUTF16:isVisible:)`: for each visible unit overlapping the range, intersect with each part's global UTF-16 range (precomputed), and emit a `PartSlice` with the part's source and the **local Character** sub-range within that part's contribution (converting the intersected UTF-16 sub-range back to Character offsets within the part). Text parts carry `.textSegment(index:)`; atom parts carry `.atom(id:)` and always emit the atom's *whole* char range (atomicity — a partial hit selects the whole pill).

- [ ] **Step 4: Run to verify pass** — `swift test --filter SelectionTextModelTests` → 5 passed; full `swift test` green.
- [ ] **Step 5: Commit** — `git add Sources/ADFRendering/TextKit2/Selection/SelectionTextModel.swift Tests/ADFRenderingTests/SelectionTextModelTests.swift && git commit -m "feat: SelectionTextModel — UTF-16 prefix-sum corpus, atom snapping, copy slice"`

---

### Task 19 — [KILL-FAST #3b] SelectionController full UITextInput over the real model + geometry

**Why fourth:** with a correct text model (Task 18) and real-layout geometry (Task 17), the controller becomes real: `text(in:)`/position arithmetic delegate to `SelectionTextModel` in UTF-16; `selectionRects`/`caretRect`/`closestPosition` route global offsets → `partSlices` → the live row's `selectionRects(forUTF16:)` (character-level for live rows, whole-block interpolation for collapsed rows). Selection state moves to a non-observed box on the model; SwiftUI sees one coarse session Bool. The word-select-past-emoji regression the spec names becomes provable here.

**Files:**
- Modify: `Sources/ADFRendering/TextKit2/Selection/SelectionController.swift` (replace the crude skeleton)
- Create: `Sources/ADFRendering/TextKit2/Selection/SelectionState.swift`
- Modify: `Sources/ADFRendering/ADFDocumentModel.swift` (add the non-observed `selection` box + observed `selectionSessionActive`)
- Test: `Tests/ADFRenderingTests/SelectionControllerOffsetTests.swift` (macOS-runnable core: offset↔position, tokenizer-facing arithmetic, collapsed interpolation math via an injected geometry stub)

**Interfaces:**
- Produces: `final class SelectionTextPosition: UITextPosition` (UTF-16 `offset: Int`); `final class SelectionTextRange: UITextRange` (`range: Range<Int>`); `final class ADFSelectionRect: UITextSelectionRect`; `@MainActor final class SelectionState { var utf16Range: Range<Int>?; var epoch: UInt64 }` (non-observed box); `ADFDocumentModel.selection: SelectionState` (`@ObservationIgnored`), `ADFDocumentModel.selectionSessionActive: Bool` (observed, flips twice per session).

- [ ] **Step 1: `SelectionState.swift`** (the `ScrollAnchorRegistry` pattern, extended for the epoch stamp)

```swift
import Foundation

/// Selection lives here — a plain non-observed reference box owned by the
/// model (mirrors `ScrollAnchorRegistry`). Per-touch-move writes invalidate
/// nothing. `epoch` is the document epoch stamped when the current range was
/// last set; a mismatch against `ADFDocumentModel.documentEpoch` means the
/// range refers to a document generation that no longer exists and must be
/// cleared/clamped before any query (spec §7).
@MainActor
public final class SelectionState {
    public var utf16Range: Range<Int>?
    public var epoch: UInt64 = 0
    public init() {}
}
```

`ADFDocumentModel` gains (near `anchors`):

```swift
    @ObservationIgnored public let selection = SelectionState()
    /// The ONE coarse Bool SwiftUI observes for selection — flips at session
    /// start/end only (like `search.isActive`), so idle rows never re-evaluate
    /// on a per-touch-move selection write.
    public private(set) var selectionSessionActive = false
    func setSelectionSessionActive(_ active: Bool) { selectionSessionActive = active }
```

(The `documentEpoch` property is added in Task 22; this task stamps `selection.epoch` from `model.documentRevision` as a placeholder and switches to `documentEpoch` in Task 22 — noted inline so the switch is not forgotten.)

- [ ] **Step 2: Rewrite `SelectionController` conformance.** Reuse the spike/prototype boilerplate, then apply deltas:

```bash
# The read-only UITextInput boilerplate to adapt (position/range subclasses,
# text(in:), textRange(from:to:), compare, offset, position(within:farthestIn:)):
sed -n '88,225p' Demo/ADFReader/SelectionSpike.swift
# The prototype's production-shaped range/rect subclasses + selectionRects
# splitting a global range per unit (adapt the per-unit split; replace shadow
# geometry with live-row queries + interpolation):
git show selection-prototype:Sources/ADFRendering/SelectionPrototype/SelectionPrototypeOverlay.swift
```

**Deltas (all NEW logic — write it, don't copy):**
1. **UTF-16 everywhere.** `SelectionTextPosition.offset` is a UTF-16 offset into the virtual document; every `position(from:offset:)`, `offset(from:to:)`, `compare`, `beginningOfDocument`/`endOfDocument` uses `model` UTF-16 lengths. `text(in:)` → `textModel.text(inUTF16: r.range, isVisible: isUnitVisible)`.
2. **Geometry via model → live rows.** `selectionRects(for:)`:
   ```
   let slices = textModel.partSlices(forUTF16: range.range, isVisible: isUnitVisible)
   group slices by unit → owner; for each owner:
     if let row = registry.liveView(for: ownerID) as? TextKit2RowUIView:
        for each text slice: nsRange = TextRowContent.utf16Range(charRange: slice.localCharRange, inSegment: k, of: row.content!)
                             rects += row.selectionRects(forUTF16: nsRange).map { row.convert($0, to: container) }
        for each atom slice: segIndex = row.segmentIndex(forAtomID: id); nsRange = whole attachment char at content.segmentUTF16Starts[segIndex], length 1
                             rects += row.selectionRects(forUTF16: nsRange) ... (covers the whole pill — atomicity)
     else (collapsed): one interpolated whole-owner rect from registry.nearestLive bracketing this owner's document order + known spacer heights.
   wrap each rect in ADFSelectionRect(containsStart:/containsEnd:) computed from RANGE MEMBERSHIP (is range.lowerBound within this owner's global range? etc.), never array position.
   ```
3. **`closestPosition(to:)`**: point is in container space; `registry.nearestLive(toY:)` picks the row; convert the point into the row's space; `row.closestUTF16Offset(to:)` → owner-local UTF-16 → map to a global offset via the owner's unit start + a local-UTF-16→global conversion; for points in a collapsed gap, snap to the nearer bracketing owner's start/end. Finally `snapAcrossAtoms` the result so the caret never lands strictly inside a pill.
4. **`caretRect(for:)`** never returns `.null`: live row → `row.caretRect(atUTF16:)`; collapsed → interpolated 2pt caret at the owner's leading edge.
5. **State on the model.** `selectedTextRange` getter builds a `SelectionTextRange` from `model.selection.utf16Range`; setter writes `model.selection.utf16Range` (a non-observed write) bracketed as UIKit expects. Session start (first non-empty selection) calls `model.setSelectionSessionActive(true)`; clear calls `false`.
6. **`isUnitVisible(_:)`**: `unit.expandAncestorIDs.allSatisfy(model.expandedBlocks.contains)` — the expand-edge predicate.
7. **Model rebuild hook.** `SelectionController.rebuildTextModel()` rebuilds `SelectionTextModel.build(orderedItems: model.search.orderedIndexItems)` and sets `registry.orderOf = { textModel.ownerOrder[$0] ?? .max }`. Called on attach and on epoch bump (Task 22). (Add a small internal accessor on `ADFDocumentSearch`/`IncrementalSearchIndex` to vend `orderedItems` for the controller — `index.orderedItems` already exists per the index API; expose it through the search controller.)

- [ ] **Step 3: `SelectionControllerOffsetTests.swift`** (macOS-runnable — the controller's *offset arithmetic* and *collapsed interpolation* are platform-agnostic if geometry is injected; test them without `UITextInteraction`). Inject a fake geometry source (a protocol `SelectionGeometrySource` the controller depends on, with a test impl returning fixed rects) so `selectionRects`/`closestPosition` math is exercised on macOS. Key cases:
  - `wordSelectAfterNonBMPScalarStaysAligned`: build a model with `"a😄 word"`; assert the UTF-16 range the tokenizer would produce for "word" (offsets computed via the model) maps back through `text(in:)` to exactly `"word"` (the spec's named regression: copied text equals the visibly selected word across a non-BMP scalar).
  - `collapsedOwnerInterpolatesBetweenLiveNeighbors`: two live rects bracketing a collapsed owner → the collapsed owner's synthesized rect lies between them and is non-empty.
  - `containsStartEndFromRangeMembership`: a 3-owner selection reports `containsStart` only on the first owner's rect and `containsEnd` only on the last, regardless of registry insertion order.

- [ ] **Step 4: Run** — `swift test --filter SelectionControllerOffsetTests` (macOS) → pass; full `swift test` green. iOS smoke: launch `-fixture kitchen-sink -textkit2 -selection`, long-press a word containing/adjacent to the emoji paragraph, Copy is still absent (Task 20) but the highlight covers exactly one word — screenshot for the record.
- [ ] **Step 5: Commit** — `git commit -am "feat: SelectionController full UITextInput over SelectionTextModel + real-layout geometry"`

---

### Task 20 — [KILL-FAST #4] Interaction hardening: copy, edit menu, tap-to-clear, long-press-in-selection, drag autoscroll

**Why fifth:** selection now works but is inert at the edges — the spike proved Copy is omitted without explicit responder wiring, and the prototype wired neither tap-to-clear, long-press-restart, nor drag-past-edge autoscroll (its `clearSelection()` was a dead stub). These are the interactions that make selection usable and that must not fight the ancestor-attachment arbitration.

**Files:**
- Modify: `Sources/ADFRendering/TextKit2/Selection/SelectionController.swift`
- Create: `Sources/ADFRendering/TextKit2/Selection/SelectionAutoscroller.swift`
- Test: `Tests/ADFRenderingTests/SelectionAutoscrollerTests.swift` (macOS-runnable: edge-distance → velocity → target-offset math)

**Interfaces:**
- Produces: `copy(_:)`/`canPerformAction(_:withSender:)`/`selectAll(_:)` responder overrides on `SelectionController`; a `UIEditMenuInteraction` presenter; ancestor `UITapGestureRecognizer` (tap-to-clear) + a long-press-in-selection recognizer, both with `require(toFail:)`/delegate failure requirements against descendant controls; `@MainActor final class SelectionAutoscroller` driving a `CADisplayLink` that writes `model.anchors.topRow`.

- [ ] **Step 1: Copy + edit menu.** Implement on `SelectionController` (adapt the prototype's `copy(_:)`/`canPerformAction`/`selectAll(_:)`/`UIEditMenuInteractionDelegate`, `git show selection-prototype:Sources/ADFRendering/SelectionPrototype/SelectionPrototypeOverlay.swift`):
  - `override func canPerformAction(_ action:, withSender:) -> Bool`: `copy:` iff selection non-empty; `selectAll:` iff document non-empty; delegate `_lookup:`/`_define:`/`_translate:` to `super`.
  - `override func copy(_:)`: `UIPasteboard.general.string = textModel.text(inUTF16: range, isVisible: isUnitVisible)` — the byte-exact, hidden-expand-excluded, `"\n"`-joined document slice. **Copy must reproduce `InlineComposer.fallbackText` for atoms** (it does, because the corpus `plainText` already embeds it — no separate atom formatting in the controller; record the invariant that Copy inherits atom text from the corpus).
  - Present the menu via `UIEditMenuInteraction` on the container; keep the presentation minimal (the prototype's debounced manual present is a reference, but `UITextInteraction(.nonEditable)` presents its own menu on long-press — prefer letting the interaction drive it and only add `canPerformAction`/`copy` so Copy appears; a manual presenter is the fallback if the interaction's menu is unreliable).
  - `canBecomeFirstResponder = true`; suppress the keyboard (`inputView = empty` if the interaction ever makes it first responder).

- [ ] **Step 2: Tap-to-clear + long-press-in-selection.** Add two ancestor gesture recognizers on the container:
  - A `UITapGestureRecognizer` that clears the selection (`model.selection.utf16Range = nil`, bracketed by `inputDelegate.selectionWillChange/DidChange`, `setSelectionSessionActive(false)`). Its delegate returns `false` for `gestureRecognizer(_:shouldReceive:)` when the touch hit-tests to a descendant control (link, checkbox, scroll view) so descendant taps win — **no `hitTest` override; failure requirements only** (spec §7).
  - A long-press recognizer that, when it begins **inside** the current selection, hands off to word-restart (does not clear); outside, defers to the interaction's own long-press. Wire `require(toFail:)` against `UITextInteraction`'s recognizers as needed so the two do not double-fire.

- [ ] **Step 3: `SelectionAutoscroller.swift`** — drag-past-edge autoscroll. When a handle drag reaches within an edge band of the scroll view, a `CADisplayLink` advances `scrollView.contentOffset` by a velocity that grows with edge penetration, and — critically — **writes `model.anchors.topRow`** to the owner now at the top (found via `registry`/`textModel` order) on each step, so the §8b anchors-truthfulness contract holds (a programmatic scroll that forgets this reintroduces the rotation teleport, per `docs/Rotation-Scroll-Retention.md`). Per-move work is a binary search over cached frames, never a scan.

```swift
#if os(iOS)
import UIKit

@MainActor
final class SelectionAutoscroller {
    private weak var scrollView: UIScrollView?
    private var link: CADisplayLink?
    private var velocity: CGFloat = 0
    var topOwnerProvider: (CGFloat) -> String? = { _ in nil }   // contentOffsetY → ownerID
    var onScrollStep: (String?) -> Void = { _ in }              // writes model.anchors.topRow

    init(scrollView: UIScrollView) { self.scrollView = scrollView }

    /// Called on every handle-drag touch-move with the touch's Y in the
    /// scroll view's bounds. `edgeBand` ~ 80pt; velocity ramps toward
    /// `maxV` ~ 900pt/s as the touch penetrates the band.
    func update(touchYInBounds y: CGFloat, viewportHeight h: CGFloat) {
        let band: CGFloat = 80, maxV: CGFloat = 900
        if y < band { velocity = -maxV * (band - y) / band }
        else if y > h - band { velocity = maxV * (y - (h - band)) / band }
        else { velocity = 0 }
        if velocity == 0 { stop() } else { start() }
    }
    func stop() { link?.invalidate(); link = nil; velocity = 0 }

    private func start() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(step))
        l.add(to: .main, forMode: .common); link = l
    }
    @objc private func step(_ link: CADisplayLink) {
        guard let sv = scrollView, velocity != 0 else { return }
        let dy = velocity * CGFloat(link.targetTimestamp - link.timestamp)
        let maxY = max(0, sv.contentSize.height - sv.bounds.height)
        let newY = min(max(0, sv.contentOffset.y + dy), maxY)
        sv.contentOffset.y = newY
        onScrollStep(topOwnerProvider(newY))       // <-- writes model.anchors.topRow (§8b)
    }
}
#endif
```

`SelectionAutoscrollerTests` (macOS — the velocity ramp + clamped target-offset math are pure): assert `update` inside the band produces zero velocity, near the top edge produces negative velocity proportional to penetration, and a `step`-equivalent offset advance clamps at `[0, maxY]`. (The `topOwnerProvider`/`onScrollStep` wiring is asserted in the iOS gate, Task 26.)

- [ ] **Step 4: iOS verification** — dedicated sim, `-fixture stress-5k -textkit2 -selection`: long-press → Copy now appears in the edit menu; Copy writes the selected text (verify via `simctl pbpaste`, seeded-sentinel method from the spike); tap in blank space clears; drag a handle to the bottom edge → the document autoscrolls and the selection extends. Screenshot each.
- [ ] **Step 5: Commit** — `git commit -am "feat: selection copy/edit-menu wiring, tap-to-clear, long-press-in-selection, drag autoscroll writing anchors.topRow"`

---

### Task 21 — Atom atomicity, link/atom hit-testing, whole-pill highlight tint

Closes phase-3 known gaps **#2** (atom taps not hit-tested on the TK2 arm) and **#3** (whole-pill search-highlight tint), which are selection/geometry work by the phase-3 register's own classification.

**Files:**
- Modify: `Sources/ADFRendering/TextKit2/Selection/SelectionController.swift` (atom-edge endpoint snapping on every range set; tap hit-testing)
- Modify: `Sources/ADFRendering/TextKit2/TextKit2RowView.swift` (`segmentIndex(forAtomID:)`, atom/link hit-testing from the row's own layout; whole-pill highlight background)
- Modify: `Sources/ADFRendering/TextKit2/AtomAttachment.swift` (expose the pill's tint/geometry for whole-pill highlight)
- Test: `Tests/ADFRenderingTests/TextKit2RowGeometryTests.swift` (extend: atom attachment-char rect; atom-id → segment index)

**Interfaces:**
- Produces: `TextKit2RowUIView.segmentIndex(forAtomID:) -> Int?`; `TextKit2RowUIView.hitTest(atomOrLinkAt point: CGPoint) -> AtomOrLinkHit?` (returns `.link(URL)` or `.atom(id:)` from the layout's attachment/link attributes at the point); a whole-pill highlight path drawing the matched atom's pill-background tint when `currentAtomIDs`/`atomIDs` (already on `SearchOwnerHighlights`) contains the atom.

- [ ] **Step 1: Enforce atomicity on every range set.** In `SelectionController.selectedTextRange`'s setter (and after tokenizer word-select), snap both endpoints via `textModel.snapAcrossAtoms(_:forward:)` so the caret never lands strictly inside an atom and any partial atom hit selects the whole pill. Add a test to `SelectionTextModelTests` (already covers `snapAcrossAtoms`) plus a controller-level test that a range starting mid-atom is widened to the atom edge.
- [ ] **Step 2: Atom/link hit-testing from the row's own layout.** `TextKit2RowUIView.hitTest(atomOrLinkAt:)` uses `enumerateTextLayoutFragments` + `NSTextLineFragment.characterIndex(for:)` to find the character under the point, then reads the attributed string's `.link`/attachment at that index. `SelectionController`'s tap-to-clear recognizer, before clearing, asks the hit-tested live row whether the tap landed on a link or interactive atom and, if so, routes it (openURL / atom popover anchor) instead of clearing — restoring TK2-arm atom taps (gap #2) **without** overriding `hitTest` (the routing happens inside the ancestor tap recognizer's action).
- [ ] **Step 3: Whole-pill highlight tint (gap #3).** In `TextKit2RowUIView.drawHighlightBackgrounds`, when a matched atom's id is in `paint`'s atom-id set (thread `atomIDs`/`currentAtomIDs` from `SearchOwnerHighlights` into `Inputs.Paint`, mirroring the SwiftUI arm's `atomHighlight(for:)`), fill the attachment char's segment rect with the subtle/current color before glyphs — the pill tints entirely, matching the SwiftUI arm.
- [ ] **Step 4: Verify** — extend `TextKit2RowGeometryTests` (iOS lane) with `atomAttachmentCharProducesOnePillRect` and `segmentIndexForAtomIDMatches`. Visual: kitchen-sink `-textkit2 -selection`, tap a mention atom → popover; search a term that matches a status atom → the whole pill tints. Screenshot A/B vs the SwiftUI arm.
- [ ] **Step 5: Commit** — `git commit -am "feat: atom atomicity + TK2-arm atom/link hit-testing + whole-pill search-highlight tint"`

---

### Task 22 — [KILL-FAST #5] Document epoch, gesture-cancel, expand policy, geometry-staleness coalescing

**Why last of the kill-fast set:** correctness under mutation is what separates a demo from a shippable selection engine. `ADFDocumentModel` has `documentRevision: UInt64` but **no `documentEpoch`** (confirmed) — the spec calls one "mandatory" because structural block IDs recur across documents. This task introduces it, guards selection against stale offsets, and wires the expand-toggle / collapsed-height / table-h-scroll staleness signals into a coalesced `inputDelegate` re-query.

**Files:**
- Modify: `Sources/ADFRendering/ADFDocumentModel.swift` (`documentEpoch`; bump on `load()` + non-tail-append `apply`)
- Modify: `Sources/ADFRendering/TextKit2/Selection/SelectionController.swift` (epoch guard; gesture-cancel; staleness coalescing)
- Test: `Tests/ADFRenderingTests/SelectionEpochTests.swift` (macOS-runnable)

**Interfaces:**
- Produces: `ADFDocumentModel.documentEpoch: UInt64` (`public private(set)`, monotonic, never reset); `ADFDocumentModel.bumpDocumentEpochIfNeeded(for:)` helper distinguishing pure tail-append; `SelectionController.documentDidChange()` (clamp/clear + cancel recognizers via `inputDelegate` before the next query) and `selectionGeometryDidGoStale()` (coalesced `selectionWillChange`/`DidChange`).

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import ADFRendering
import ADFModel

@Suite("Selection epoch guard") @MainActor
struct SelectionEpochTests {
    @Test func loadBumpsEpochMonotonically() async {
        let model = ADFDocumentModel(theme: .default)
        let before = model.documentEpoch
        model.load(data: minimalDocData())          // helper: a 1-paragraph ADF doc
        await model.settle()                          // helper: await phase == .ready
        #expect(model.documentEpoch > before)
    }

    @Test func pureTailAppendDoesNotBumpEpoch() {
        let model = ADFDocumentModel(theme: .default)
        let e = model.documentEpoch
        model.bumpDocumentEpochIfNeeded(for: [.insert(item("z"), afterID: model.lastItemID)])
        #expect(model.documentEpoch == e)             // tail insert → no bump
    }

    @Test func replaceRemoveMoveBumpEpoch() {
        let model = ADFDocumentModel(theme: .default)  // preloaded with a,b,c
        let e0 = model.documentEpoch
        model.bumpDocumentEpochIfNeeded(for: [.replace(itemID: "b", block: block("b"))])
        #expect(model.documentEpoch > e0)
        let e1 = model.documentEpoch
        model.bumpDocumentEpochIfNeeded(for: [.remove(itemID: "b")])
        #expect(model.documentEpoch > e1)
        let e2 = model.documentEpoch
        model.bumpDocumentEpochIfNeeded(for: [.move(itemID: "a", afterID: "c")])
        #expect(model.documentEpoch > e2)
    }

    @Test func staleSelectionEpochClampsRangeToClear() {
        let state = SelectionState()
        state.utf16Range = 10..<20; state.epoch = 5
        // Guard logic (extracted to a pure function so it's macOS-testable):
        let cleared = SelectionController.clampedRange(state.utf16Range, stampEpoch: state.epoch,
                                                        currentEpoch: 6, documentUTF16Length: 100)
        #expect(cleared == nil)                        // epoch mismatch → clear
        let kept = SelectionController.clampedRange(0..<3, stampEpoch: 6, currentEpoch: 6, documentUTF16Length: 100)
        #expect(kept == 0..<3)
        let clamped = SelectionController.clampedRange(90..<200, stampEpoch: 6, currentEpoch: 6, documentUTF16Length: 100)
        #expect(clamped == 90..<100)                   // same epoch, out-of-range tail → clamp
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter SelectionEpochTests` → FAIL (`documentEpoch`/`bumpDocumentEpochIfNeeded`/`clampedRange` missing).

- [ ] **Step 3: Implement**
  - `ADFDocumentModel`: add `public private(set) var documentEpoch: UInt64 = 0`. In `load(...)`: `documentEpoch &+= 1` (once, at reset — monotonic across documents so stale offsets from a prior document are inert; do NOT reset to 0 like `documentRevision`). Add `func bumpDocumentEpochIfNeeded(for mutations: [ADFDocumentMutation])`: bump unless the batch is a **pure tail append** — every mutation is `.insert(_, afterID:)` whose `afterID` is the current last item id (or `nil` on an empty document). Call it from `apply(_:revision:)` after the batch commits (both the general path and the `applyReplacementBatchIfPossible` replace-only fast path — replace changes content offsets, so it bumps). Streaming `append(_:)` during `load` does NOT call it (the single `load` bump covers the streaming build).
  - `SelectionController`: stamp `model.selection.epoch = model.documentEpoch` whenever it sets a range. Add `static func clampedRange(_ range: Range<Int>?, stampEpoch: UInt64, currentEpoch: UInt64, documentUTF16Length: Int) -> Range<Int>?` (pure): epoch mismatch → `nil`; else clamp to `[0, length]`, returning `nil` if it collapses. `documentDidChange()`: rebuild the text model, then apply `clampedRange`; if the range changed/cleared, call `inputDelegate?.selectionWillChange(self)` / `…DidChange(self)`; if a gesture is in flight, cancel the interaction's recognizers explicitly (`interaction.gesturesForFailureRequirements`/disable-enable the interaction) before the next query so no dangling offset reaches `text(in:)`.
  - `selectionGeometryDidGoStale()`: a coalesced (one-runloop-debounced) `selectionWillChange`/`DidChange` pair so UIKit re-queries `selectionRects`. Drive it from: expand toggles (observe `model.expandedBlocks`), collapsed-height corrections on re-entry, and `TableScrollSync` h-scroll offset changes (its existing observation). An expand toggle is a **rect invalidation, not a text-model change** — but if the toggle changed which units are visible, also rebuild is unnecessary (visibility is a query-time predicate via `isUnitVisible`), so only the re-query fires.
  - Hook `documentDidChange()`: `ADFDocumentModel.apply`/`load` notify the controller (a weak callback or the controller observes `documentEpoch`). Prefer an explicit `model.onDocumentEpochChanged` closure the controller registers, to keep it off the observation path.

- [ ] **Step 4: Run** — `swift test --filter SelectionEpochTests` → pass; full `swift test` green.
- [ ] **Step 5: iOS verification (the spec's named gate — live-edit mid-drag)** — build a harness that applies an `apply(_:revision:)` replacement to a mid-document item while a handle drag is in flight (reuse the `-searchUpdates` mutation harness pattern); assert no crash, no out-of-range `text(in:)`, and the selection either clamps or clears cleanly. Screenshot before/after.
- [ ] **Step 6: Commit** — `git commit -am "feat: document epoch + selection gesture-cancel/clamp + expand/geometry staleness coalescing"`

---

## Phase 4 — rendering closeout, fixtures, accessibility

### Task 23 — Rendering fidelity closeout: chip icons + inlineCard tint, pure-atom-row baseline, vertical-rhythm decision

Closes phase-3 gaps **#1** (chip SF Symbols omitted; inlineCard chip lacks link tint — ~18.7/22pt narrower than the SwiftUI arm) and **#4** (pure-atom-row `firstBaseline` returns the `0` fallback), and reaches a recorded decision on **#5** (vertical-rhythm drift). Chip width is scheduled here — not deferred — because a chip's whole-pill **selection rect** depends on the pill's real geometry; a chip that renders 18–22pt too narrow produces a wrong selection rect for that atom.

**Files:**
- Modify: `Sources/ADFRendering/TextKit2/AtomAttachment.swift` (draw the SF Symbol glyph + widen `pillSize`; inlineCard `textColor = tint`)
- Modify: `Sources/ADFRendering/TextKit2/TextKit2RowView.swift` (`firstBaseline` pure-atom-row path)
- Modify: `docs/TextKit2-Port-Assessment.md`
- Test: `Tests/ADFRenderingTests/AtomAttachmentTests.swift` (extend: chip width now includes the icon; inlineCard tint)

- [ ] **Step 1: Chip SF Symbols + inlineCard tint.** In `AtomAttachment`, for `.inlineCard`/`.mediaInline`/`.inlineExtension` chips, draw the SF Symbol (`link`/`paperclip`/`puzzlepiece`, mirroring `AtomChip`) at the leading edge in `image(forBounds:…)` and add its width + leading gap to `pillSize` — closing the ~18.7/22pt gap Task 10 measured. Set `.inlineCard`'s `textColor` to the link tint (matching `InlineCardChip`'s SwiftUI `Link`), not `.label` (the `AtomAttachment.swift:165` uniform `.label` bug Task 13 traced). Extend `AtomAttachmentTests`: `chipWidthIncludesIconGlyph` (chip `pillSize.width` now within ≤3pt of the SwiftUI arm's measured width), `inlineCardChipUsesTintColor`.
- [ ] **Step 2: Pure-atom-row baseline.** `TextKit2RowView.firstBaseline` currently returns `0` when a row has no `.text` run. Recover the pill's own ascent from the leading atom's `AtomAttachment.pillSize`/pill-font ascent (a pure function of `(atom, category)`, never measured layout — §16). Add an iOS-lane test asserting a pure-atom row's `firstBaseline` is non-zero and within 1pt of the pill's text ascent.
- [ ] **Step 3: Vertical-rhythm characterization + DECISION.** Re-measure the ~5–6px-growing-to-~22px cumulative row-height drift (Task 11 method: column-scan A/B PNGs) at default + step 3 on a long list. **Decision (recorded here, deferral rationale in the verdict):** the fix is **deferred** to the production port, because (a) it is a `TextRowLayout`-vs-SwiftUI-`Text` line-height difference that is *cosmetic vs the OFF arm* only — once the port is full the OFF arm is removed and there is nothing to drift from, and (b) forcing a line-height multiple to match `Text` risks the deterministic-sizing / `CollapsedRowHeight` exact-replay contract (§16). Record the measured magnitude and this rationale; do not change line metrics.
- [ ] **Step 4: Verify + commit** — `swift test` green; iOS lane green; A/B screenshots committed under `docs/assessment-assets/phase4-rendering/`. `git commit -am "feat: chip SF Symbols + inlineCard tint + pure-atom-row baseline; vertical-rhythm decision recorded"`

---

### Task 24 — Test infrastructure: atom-stress fixture, RTL simulator regression, determinism discriminator

Closes phase-3 gaps **#6** (no atom-heavy stress fixture), **#7** (RTL fix has only a unit test, no simulator-visible regression), and **#10** (the `TextRowLayoutTests.sameInputSameWidthMeasuresIdentically` flake — a serial-vs-parallel discriminator "must precede any production-port decision").

**Files:**
- Create: `Fixtures/atom-stress.json`
- Modify: `docs/TextKit2-Port-Assessment.md`
- (No production code; measurement + fixture only.)

- [ ] **Step 1: `atom-stress.json`.** Author a fixture of ~2,000 atom-dense paragraphs (mentions, statuses, dates, emoji, inline cards, media inline, inline extensions per paragraph) following `kitchen-sink.json`'s doc-wrapper shape; picked up automatically by `Demo/project.yml`'s `../Fixtures` glob (no `project.yml` edit). This is the fixture selection perf (Task 26) and pill-draw stress need.
- [ ] **Step 2: RTL simulator regression.** The phase-3 RTL fix (`TextRowContent.make` natural→left/right) has only `naturalAlignmentResolvesPerHostDirection` as a reliable reproduction; `-AppleTextDirection YES` masks it in the simulator. Add a **selection-visible** RTL check: with `-fixture rtl-mixed -textkit2 -selection`, long-press-select an Arabic word and Copy — assert the copied text equals the visibly selected Arabic word and the selection rects sit on the correct (right) side. This gives the RTL path a selection-level regression the pure-render matrix lacked. Record screenshots.
- [ ] **Step 3: Determinism discriminator.** Run `TextRowLayoutTests.sameInputSameWidthMeasuresIdentically` **N=100 serial** (`swift test --filter TextRowLayoutTests --num-workers 1` in a loop, or a bespoke 100-iteration test) and a parallel run, to discriminate real non-determinism from parallel-cache contention. Layout determinism underpins the `CollapsedRowHeight` exact-replay contract *and* selection geometry stability, so record the result explicitly: if the flake reproduces serially it is a **production-blocker** finding for the verdict; if only in parallel it is test-harness contention. Record counts (e.g., "0/100 serial, K/100 parallel").
- [ ] **Step 4: Record + commit** — write the three results into the assessment doc. `git add Fixtures/atom-stress.json docs/TextKit2-Port-Assessment.md && git commit -m "test: atom-stress fixture, RTL selection regression, layout-determinism discriminator"`

---

### Task 25 — Accessibility: ancestor-collapse measurement + minimal exposure prototype + production scope

Closes phase-3 gap **#8** (a `UITextInput`-conforming ancestor collapses its descendants into one opaque `AXTextArea`; the spike flagged this as "separate design work" the phase-4 controller must budget). This task **schedules the scoping/measurement and a minimal exposure prototype; the full production accessibility build is explicitly deferred** (a full port would need a rotor/element model out of scope for the assessment).

**Files:**
- Modify: `Sources/ADFRendering/TextKit2/Selection/SelectionController.swift` (minimal `accessibilityElements` exposure, gated so it does not perturb the selection UI)
- Modify: `docs/TextKit2-Port-Assessment.md`

- [ ] **Step 1: Measure the collapse.** With `-fixture kitchen-sink -textkit2 -selection`, `axe describe-ui` and confirm the container reports as one opaque `AXTextArea` (the spike's observation, now on the real hierarchy). Record which descendant elements (links, checkboxes, headings) disappear from the a11y tree.
- [ ] **Step 2: Minimal exposure prototype.** Prototype exposing the live TK2 rows' text + interactive descendants as `accessibilityElements` on the container (or setting `isAccessibilityElement = false` on the container so descendants surface), and confirm VoiceOver can reach a link/checkbox while selection still works. This is a **scoping** prototype — enough to prove a path exists, not the production element model.
- [ ] **Step 3: Write the production a11y scope** into the assessment: what a full port needs (per-row accessibility elements, a text-selection rotor, `UIAccessibilityContainer` conformance) and the estimated size. **Deferred to the production port** — recorded as such.
- [ ] **Step 4: Commit** — `git commit -am "spike: selection accessibility ancestor-collapse measurement + minimal exposure; production scope recorded"`

---

## Phase 5 — Full gate suite + verdict

### Task 26 — Perf + soak gates with selection active

Runs spec §10's perf/behavioral gates that involve selection, plus the two **never-run** phase-1–3 gates (register **#12** idle-soak + scene-snapshot) and the register **#11** mid-scroll LIVE type-size run the spec names explicitly. All numbers under RULE ZERO (foreground, dedicated sim, A/B same-build).

**Files:** Modify `docs/TextKit2-Port-Assessment.md` (record all numbers).

- [ ] **Step 1: Selection autoscroll A/B.** `-fixture stress-5k -autoscroll` with `{-textkit2}` vs `{-textkit2 -selection}` (the selection engine installed but idle) — assert the idle selection path adds no scroll cost (ON ≤ 2× the same-build `-textkit2` baseline; target noise-equivalent, since selection geometry is on-demand-only and idle rows observe one Bool).
- [ ] **Step 2: Handle-drag autoscroll CPU settle** (the drag path the `-autoscroll` gate cannot see — spec §10). On stress-5k, drive a handle drag to the edge (`axe swipe` continuous), hold at the edge to autoscroll a burst, release; `top -l 2 -pid` second sample settles to ~0. No livelock in the `CADisplayLink` autoscroll loop.
- [ ] **Step 3: Fling-with-selection.** With a large active selection (Select All on stress-5k), 12× `axe swipe` fling burst; CPU settles ~0; the highlight rides content (selection geometry is content-space, scrolls for free).
- [ ] **Step 4: Selection-session memory soak.** stress-5k, repeated select→scroll→clear cycles (~50), `top -l 1 -pid` RSS stays bounded (< 150 MB) and does not grow monotonically across cycles — the `SelectionTextModel` rebuild + registry eviction must not leak.
- [ ] **Step 5: Idle-soak + scene-snapshot thrash (register #12 — never run in phases 1–3).** Leave the app idle 60s with a selection active → zero-work idle (CPU ~0, no wakeups). Then Home → lock → app-switcher → foreground (`simctl` UI events) repeatedly; confirm no crash, the selection survives or clears cleanly (per the epoch guard), and scene-snapshot rendering does not thrash the TK2 rows.
- [ ] **Step 6: Mid-scroll LIVE type-size (register #11 — spec §10 names it; deferred UNTESTED twice in phases 1–3, "must be run in phase 4").** Scroll deep into stress-5k `-textkit2 -selection`, then change the text size via the in-app popover while scrolled (not the launch arg); confirm TK2 rows reflow, the reader keeps its place (the §19 re-pin over materialized TK2 rows), and any active selection re-queries its rects cleanly. If flaky after 3 tries, mark UNTESTED **with the reason** — but attempt it (the spec requires the attempt).
- [ ] **Step 7: Record + commit** — `git commit -am "measure: selection perf + soak gates (incl. idle-soak/scene-snapshot, mid-scroll live type-size)"`

---

### Task 27 — Behavioral gate suite: kitchen-sink selection demo + parity

Runs spec §10's behavioral selection gates: the kitchen-sink demo, rotate-with-Select-All-then-fling, pan-table/scrub-code-with-selection, emoji word-select, live-edit-mid-drag (re-confirm from Task 22), and side-by-side parity.

**Files:** Modify `docs/TextKit2-Port-Assessment.md`; screenshots under `docs/assessment-assets/phase5-selection/`.

- [ ] **Step 1: Kitchen-sink selection demo.** `-fixture kitchen-sink -textkit2 -selection`:
  - Long-press **word-select past an emoji** (the spec's named regression): the selected/copied word equals the visible word across the non-BMP scalar.
  - Cross-block handle drag **through an atom paragraph + a table cell + a code block**: selection extends continuously; atoms select as whole pills.
  - **Select All** → continuous cross-block highlight.
  - **Copy** → paste and diff the result against the expected document-order string: byte-exact, `"\n"`-joined, hidden-expand-excluded, atom `fallbackText` in full, list markers absent.
- [ ] **Step 2: Rotate-with-Select-All-then-fling** (spec §10). Select All on stress-5k, 8× rotation round-trips (`notifyutil` rotate, AXRaise first), then a fling burst; assert the selection survives rotation (geometry re-queried via the staleness coalescing), scroll retention holds (0-row bar, per the phase-3 fix), and CPU settles.
- [ ] **Step 3: Pan-table + scrub-code with an active selection** (spec §10). With a selection spanning a table and a code block, pan the table horizontally and scrub the code block horizontally; both pan natively (ancestor-attachment arbitration) and the selection rects update (TableScrollSync staleness signal).
- [ ] **Step 4: Live-edit-mid-drag** re-confirmation (from Task 22's harness) at demo scale; screenshot.
- [ ] **Step 5: Side-by-side parity** vs the SwiftUI arm for the newly-completed rendering (chip icons/tint from Task 23, whole-pill tint from Task 21): kitchen-sink pills, headings, lists, panels — {OFF, ON} × {default, step 6} × {light, dark}. Confirm no new structural diffs beyond the deferred vertical-rhythm one.
- [ ] **Step 6: Record + commit** — `git commit -am "measure: behavioral selection gate suite + parity"`

---

### Task 28 — Final verdict: assessment rewrite + issue #5 update + production-port decision

**Files:**
- Modify: `docs/TextKit2-Port-Assessment.md` (the final phase 4–5 verdict)
- (Issue #5 via `gh`)

- [ ] **Step 1: Write the phase 4–5 verdict section** in `docs/TextKit2-Port-Assessment.md`: the Task 16 kill-question answer (ancestor attachment on the real hierarchy), the selection engine gate results (Tasks 26–27) against spec §10's kill criteria, the closed known-gaps (register #1–4, #6–8, #10–12), the two explicit deferrals (vertical-rhythm fix #5; full production accessibility #8) with rationale, and the determinism-discriminator result (#10) as a gate on the production decision.
- [ ] **Step 2: Overall verdict** — one of: **PROCEED to production port** (selection engine cleared all §10 kill criteria; enumerate the production work: remove per-`Text` `.textSelection`, the full a11y element model, the deferred vertical-rhythm decision revisit, backport of the rotation fix `165db39`+`f069ab1` to main) / **PROCEED-WITH-CONSTRAINTS** (list them) / **NO-GO — fall back to the geometry-oracle overlay** (per spec §10 kill criteria: autoscroll > 2× baseline, fling CPU fails to settle, retention breaks, or ancestor attachment proved unworkable). Ground every claim in a cited Task 26/27 number.
- [ ] **Step 3: Update issue #5** with the final verdict, replacing the prototype-era "production plan" checklist with the assessment's measured outcome and the production-port decision:

```bash
gh issue comment 5 --body "$(cat <<'EOF'
## TextKit 2 selection engine — phase 4–5 assessment complete

<verdict summary, key §10 numbers, closed gaps, the two deferrals, production-port decision>

Assessment: docs/TextKit2-Port-Assessment.md (phase 4–5 verdict)
Branch: textkit2-port-prototype
EOF
)"
```

(If the verdict is PROCEED, note that issue #5 stays open to track the production port; if NO-GO, record the fallback and the reasons.)
- [ ] **Step 4: Report to the user** — the kill-question answer, the §10 gate results vs criteria, the two deferrals, and the production-port recommendation.
- [ ] **Step 5: Commit** — `git commit -am "docs: TextKit 2 selection engine phase 4-5 verdict + issue #5 update"`

---

## Self-review checklist (ran at authoring)

- **Spec coverage:** §7 attachment/ancestor → Task 16; §7 geometry registry + collapsed interpolation → Task 17; §7 UTF-16 text model + prefix sums + copy → Task 18; §7 selection controller + non-observed state + session Bool → Task 19; §7 copy/tokenizer/tap-to-clear/long-press/drag-autoscroll-anchors.topRow → Task 20; §7 atom atomicity + hit-testing + whole-pill tint → Task 21; §7 epochs/gesture-cancel/expand-edges/geometry-staleness → Task 22; §8 platform-agnostic core tested on macOS → Tasks 17 (registry math), 18 (text model), 19 (offset arithmetic), 22 (epoch logic); §10 perf/soak gates → Task 26; §10 behavioral gates → Task 27; §11 steps 4–5 → all of Phase 4 + Tasks 26–28; §12 deliverables (assessment verdict + issue #5) → Task 28.
- **Phase-3 known-gaps register (12 items) — every item scheduled or explicitly deferred:** #1 chip icons/tint → Task 23 (scheduled); #2 atom taps → Task 21 (scheduled); #3 whole-pill highlight tint → Task 21 (scheduled); #4 pure-atom-row `firstBaseline` → Task 23 (scheduled); #5 vertical rhythm → Task 23 characterizes, **fix DEFERRED** to production (rationale: cosmetic-vs-OFF-arm only, and forcing line-height risks the deterministic-sizing contract); #6 atom-stress fixture → Task 24 (scheduled); #7 RTL sim regression → Task 24 (scheduled, as a selection-level check); #8 accessibility → Task 25 scopes + prototypes, **full build DEFERRED** to production; #9 copy wiring → Task 20 (scheduled); #10 determinism-flake discriminator → Task 24 (scheduled, gates the production decision); #11 mid-scroll live type-size → Task 26 (scheduled, spec-required attempt); #12 idle-soak + scene-snapshot → Task 26 (scheduled). **Deliberately deferred (not scheduled as a fix): #5 vertical-rhythm line-height parity, and the full production accessibility element model within #8** — both recorded in the Task 28 verdict.
- **Placeholder scan:** two intentional forward-references are flagged inline — Task 19 stamps `selection.epoch` from `documentRevision` and Task 22 switches it to the new `documentEpoch` (noted at the Task 19 code site); Task 16's crude whole-owner geometry is explicitly superseded by Tasks 17/19. No other TODO/stub is left un-owned.
- **Type consistency:** `SelectionTextModel` (T18) consumed by `SelectionController` (T19, T20, T22) and `RowGeometryRegistry.orderOf` (T17/T19); `SelectionState` + `documentEpoch` (T19/T22) on `ADFDocumentModel`; `RowGeometryRegistry` (T17) queried by the controller (T19) and autoscroller (T20); `PartSlice.Source` (T18) resolved to `TextRowContent.utf16Range(charRange:inSegment:)` (existing) + `segmentIndex(forAtomID:)` (T21); `selectionSessionActive` observed Bool mirrors `search.isActive`'s zero-work-idle pattern; `SelectionFlags.enabled` requires `-textkit2`, read once, branched only at the document container (§18).
- **Deviations from spec recorded:** the geometry substrate is live TK2 rows' *own* real layouts (not the prototype's shadow-TextKit) — this is the design's structural bet, so it is a fulfillment, not a deviation; the copy join uses `"\n"` between units (matching the prototype and the WYSIWYG multi-block contract) while each unit's bytes stay corpus-identical; `documentEpoch` is introduced fresh (it did not exist — only `documentRevision` did) and is monotonic-never-reset so cross-document structural-ID collisions are inert (spec §7 "document epoch is mandatory").
</content>
</invoke>
