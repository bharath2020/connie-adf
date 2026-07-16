# ADFKit — Architecture Decisions

Every significant technology choice in ADFKit, the alternatives considered, and why the chosen option won. Where a decision was validated (or reversed) by measurement during development, the numbers are included — several choices here were *changed* after profiling on the iPhone 16 Pro simulator (Release config), and those reversals are the most instructive entries.

Companion documents: `ADF-Renderer-Design.md` (the design spec), `superpowers/plans/2026-07-10-adfkit-renderer.md` (the implementation plan).

---

## 1. Rendering framework: SwiftUI, not UIKit or a web view

**Chosen:** Pure SwiftUI view tree for every element. No `UIViewRepresentable`, no Metal drawing, no TextKit. UIKit appears only at non-view edges (`CADisplayLink` in the demo HUD) behind `#if canImport(UIKit)`.

| Alternative | Pros | Cons — why rejected |
|---|---|---|
| **UIKit `UITableView`/`UICollectionView`** | Mature cell recycling; prefetch APIs; battle-tested for huge lists | Cell-reuse bookkeeping for ~34 heterogeneous block types; self-sizing cells + colspan tables + nested content = layout invalidation storms; two mental models once SwiftUI is embedded in cells via `UIHostingConfiguration` |
| **WKWebView + Atlassian's web renderer** | Pixel-perfect Confluence fidelity for free; zero schema-tracking burden | No native scrolling feel; JS bridge for every interaction; heavyweight memory baseline; Dynamic Type/VoiceOver integration is poor; offline story requires bundling a JS app |
| **SwiftUI (chosen)** | Declarative mapping from value types to views; `Layout` protocol expressive enough for colspan tables and wrapping inline content; free Dynamic Type, dark mode, VoiceOver plumbing; compiles for macOS too | Virtualization is opt-in and shallow (see §4); no continuous text selection across blocks; less direct control when the framework misbehaves — mitigated by keeping rows as plain value types |

The bet that made SwiftUI viable at 120 Hz: **views never compute**. All expensive work happens once, off-main, in a preparation pass (§3), so `body` implementations only assemble pre-computed values.

## 2. Text: SwiftUI `Text` + `AttributedString`, not TextKit 2

**Chosen:** One `Text(AttributedString)` per block, strings pre-built during preparation. Inline atoms (mentions, status pills, dates) render via a custom wrapping `Layout` interleaving `Text` runs with pill views.

- **TextKit 2 (`UITextView` representable)** — pros: continuous selection across the document, finer typographic control. Cons: UIKit sizing dance inside SwiftUI rows, per-view `NSTextLayoutManager` cost, and none of it needed for a *reader* where per-block selection suffices. Revisit only if cross-block selection becomes a requirement.
- **`Text` inline attachments (iOS 26)** — would replace the custom wrapping layout with a single `Text`; noted as an `#available` enhancement path, not the floor implementation (iOS 17).
- **Measured correction:** the first implementation merged/sliced `AttributedString`s inside `body` on every evaluation. Adversarial review flagged it; the fix pre-splits atom-bearing paragraphs into word chunks at preparation time so `body` does a 1:1 map, no string work. Rule of thumb encoded in `InlineComposer`: *if it allocates a string, it doesn't belong in a view.*

## 3. Pipeline: parse → prepare → render, with immutable value types between layers

**Chosen:** Three SPM targets. `ADFModel` (JSON → typed tree), `ADFPreparation` (tree → flat `[RenderBlock]` with pre-built strings, list markers, table layouts), `ADFRendering` (SwiftUI). Every boundary type is `Sendable + Hashable`.

- **Alternative: render directly from the decoded tree** — fewer layers, but every scroll tick pays mark-resolution and string-building costs, and SwiftUI diffing walks a deep heterogeneous tree. Rejected on the design's §8 budget (< 0.5 ms p99 per row body).
- **Alternative: per-node view models (classes)** — familiar MVVM, but reference types defeat cheap memcmp-style diffing, invite retain cycles in a recursive structure, and complicate Swift 6 sendability.
- Pros of the split as built: each layer testable without UI (66 unit tests run in ~0.25 s on macOS); preparation is trivially parallel/streamable; the flat block list is exactly what the lazy container needs. Cons: a schema change touches two layers (model + preparation), and prepared payloads duplicate some model data — accepted as the cost of a hot render path that owns nothing mutable.

## 4. Document container: `ScrollView + LazyVStack` over a flattened block list

**Chosen:** The preparer flattens `doc.content` into one `RenderBlock` per top-level unit; `LazyVStack` iterates those. Nested content renders eagerly *inside* its block.

| Alternative | Why rejected |
|---|---|
| `List` | UITableView-derived styling to fight (separators, insets, selection); breakout/full-width media wants full control of the content rect |
| Recursive tree rendering (one giant view) | `LazyVStack` only virtualizes **direct** children — a naive tree materializes the entire document at once |
| `UICollectionView` compositional layout | Real recycling (pro), but heterogeneous self-sizing SwiftUI cells re-measure constantly; hybrid complexity (§1) |

Two follow-on decisions keep pathological blocks cheap:

- **Huge tables split into slices** (§7) so an 800-row table is ~400 lazy rows, not one.
- **Far-offscreen rows collapse to exact-height spacers.** `LazyVStack` keeps instantiated views alive (it does not recycle); collapsing distant rows to `Color.clear.frame(height:)` bounds both memory and layout cost. Added during perf hardening when the stress-5k run was failing its gate; contributed to 122 → 1.5 ms/s hitch ratio.

  A collapsed row cannot re-materialize to re-measure after a resize (that livelocks layout), so it has to *state* a height at a width it may never have been laid out at. The first version scaled its one cached height inversely with width for every block kind, which is right only for reflowing text — an image grows *taller* as it widens, and a code block or table slice scrolls horizontally and keeps its height. Every rotation therefore resized the off-screen spacers wrongly, corrupting the scroll view's content height. `CollapsedRowHeight` now memoises heights *per width* (so a rotation round trip replays the exact original height) and estimates an unseen width per block kind.

**8b. Keeping the reader's place across a resize: `scrollPosition(id:)` bound to a reference type.** A `ScrollView` retains its content *offset* across a rotation or Split View change, but the rows above have reflowed to different heights, so that offset lands on different content and the reader is thrown elsewhere in the document. The fix is to anchor on a row *identity* instead — which is exactly `scrollPosition(id:)`. It was originally rejected here (§8) because binding it to `@State` re-evaluates the document view once per row crossed, for the whole of every scroll. Backing the binding with a plain (non-`@Observable`) reference type keeps the behaviour and costs nothing: SwiftUI still writes the top-visible ID continuously, but a write to a reference type invalidates no views.

- **`scrollPosition(id:)` only re-anchors on a *value change*, not on a resize — the binding alone is not enough.** SwiftUI writes the top-visible ID only during a scroll *gesture*; across a rotation the ID does not change, so SwiftUI never re-pins and silently falls back to preserving the raw content offset — the exact failure this decision was meant to prevent. On a short document a single round trip looks fine (no rows collapse, reflow is exact, the offset happens to map back), which is why it passed review; on a long document the collapsed-row height *estimates* don't round-trip portrait↔landscape, so the error **compounds every rotation** and the reader drifts further each cycle. The binding must be paired with an explicit re-assert: `onChange(of: containerWidth) { proxy.scrollTo(anchors.topRow, anchor: .top) }`. `scrollTo` re-derives the offset from the identity (summing current row heights), so it also absorbs any height change above the anchor — an Expand opened while rotated, a Split View reflow — not just the rotation itself. It fires only on a width change (a plain scroll never changes the column width), so it stays off the §8 hitch path and touches no per-row geometry. **Corollary:** the re-pin trusts `anchors.topRow`, and `scrollPosition(id:)` only writes it during a scroll *gesture* — so every *programmatic* scroll (`ScrollTargetConsumer`'s TOC jump, `-scrollToFraction`) must also set `anchors.topRow` to its target, or the next rotation re-asserts the stale pre-jump row and teleports the reader back. And because block ids are structural (§9) and collide across documents, the reader must be given a fresh view identity per document (`.id(document)`) or the anchor leaks between documents. See `docs/Rotation-Scroll-Retention.md`.

- **The `scrollPosition(id:)` binding must be tracking-only — its getter returns `nil`.** Given a non-`nil` getter, `scrollPosition(id:)` treats that row as a *standing* target and re-applies it whenever content resizes under the reader (an Expand opening, an image decoding), snapping them back to a *remembered* row — reproduced on device as scroll→rotate→scroll→tap-Expand jumping back to the pre-scroll section. It re-applies the last-committed row and is not refreshed by scrolling (the registry is non-`@Observable`), so the only cure is to withhold the target entirely: `Binding(get: { nil }, set: { anchors.topRow = $0 })`. Tracking still works (the setter records the top row); re-anchoring across a resize is done solely by the width re-pin above (a one-shot `scrollTo`, not a standing target). A remaining **sub-row jitter** (the anchor row is held every cycle but its exact top offset varies by ≤ one row) is deferred — it reproduces in the simulator and needs a one-shot capture/restore of the sub-row offset.

- **Rejected: tracking the top row with per-row geometry.** Reading `proxy.frame(in: .named(…))` from every live row to find the top-visible one *looks* cheaper than a binding, but resolving a named coordinate space inside `LazySubviewPlacements.placeSubviews` pins the main thread at **100% CPU indefinitely after a fling** — the autoscroll gate does not catch it (it measures a driven, animated scroll, 8.67 ms/s, apparently fine), only a real flick gesture does. Fling-and-watch-CPU is now part of the check.

## 5. JSON parsing: hand-rolled UTF-8 scanner, `JSONSerialization` as fallback

**Chosen:** `JSONScanner` parses the document bytes directly into `JSONValue`; if it throws, the code falls back to `JSONSerialization` bridging.

- **`JSONDecoder`/`Codable`** — idiomatic, but a `type`-discriminated union of ~40 node kinds forces a custom `init(from:)` that is slower and *loses unknown-node payloads*, which forward compatibility requires (§6).
- **`JSONSerialization` → bridge to `JSONValue`** — the original implementation. Measured on the 2.3 MB stress-5k fixture: 11 ms to parse + **95 ms** bridging `NSDictionary`/`NSNumber` objects into Swift values.
- **Direct scanner (chosen)** — same fixture: **~21 ms total**, first visible content 174 → 68 ms, passing the < 150 ms gate. Cons: ~300 lines of parsing code to own, so the battle-tested fallback stays, and the scanner has its own test suite.

This was a *reversal driven by a failed gate* — the design doc assumed platform JSON parsing was fine; the measured first-chunk latency said otherwise.

## 6. Forward compatibility: typed enum with `.unknown(raw:)` capture

**Chosen:** Unknown node types decode into `.unknown(raw: JSONValue)` (rendered as a labeled chip), unknown marks are dropped with a logged issue, malformed attrs default with a diagnostic. A parse never fails on future schema additions.

- Alternative — strict decoding that rejects unrecognized content: safer-sounding, but one new Atlassian node type would blank entire customer pages. A reader must degrade, not refuse.
- Alternative — stringly-typed dictionaries everywhere: maximally tolerant, but every view does defensive unwrapping and typos become runtime bugs. The typed enum keeps exhaustive `switch` coverage (the compiler flags unhandled node kinds when the schema mapping grows).
- Asymmetry worth noting: unknown **nodes** render a visible placeholder (the reader must know something was elided); unknown **marks** are silently dropped (styling you can't apply is safer to omit than to flag).

## 7. Tables: custom `Layout` + row slicing + synchronized horizontal scrolling

The hardest element; four separate decisions, three of them measurement-driven.

**7a. Cell placement: custom `TableRowLayout`, not SwiftUI `Grid`.** `Grid` cannot express colspan against author-supplied `colwidth` attrs with dynamic content. The custom layout measures each cell once at its fixed column width and places with the same proposal (one cached text layout per cell). `valign` becomes a placement offset. Documented v1 simplification: rowspan cells render at origin-row height only.

**7b. Row batching: slices of 2 rows, not 20.** The design guessed 20 rows per slice. Measured: `LazyVStack` materializes upcoming rows in batches, and a 20-row slice of 6 columns landing inside one frame blew the frame budget — giant-table hitch ratio **535 ms/s**. Slices of 2 rows brought it to **0.00–0.41 ms/s**. Trade-off: more identity bookkeeping (400 slices instead of 40), which measured as negligible.

**7c. Grid lines/fills: flat `Rectangle` layers, not `Canvas`.** A `Canvas` underlay was prototyped and measured **15× worse** — it rasterizes a bitmap per row, while `Rectangle` fills are cheap composited CoreAnimation layers. Kept as a code comment so nobody "optimizes" it back.

**7d. Horizontal scrolling: per-slice `ScrollView`s with a shared-offset sync, not one wrapping `ScrollView`.** One horizontal `ScrollView` around the whole table would make it a single lazy row and defeat vertical virtualization (back to 7b's 535 ms/s). Independent per-slice scrolling shipped first and was visibly broken on-device — panning one slice sheared rows out of alignment. Fix: a per-document registry maps each table ID to a shared offset; the actively-dragged slice (detected via `onScrollPhaseChange`) publishes `contentOffset.x`, followers track via `ScrollPosition.scrollTo(x:)`, and slices materializing later adopt the offset on appear. iOS 18+ APIs; on iOS 17 slices remain independent (documented floor limitation). Verified empirically with scripted swipe gestures + screenshots; gates stayed green (giant-table 0.41, stress-5k 4.67 ms/s).

## 8. Programmatic scrolling: `ScrollViewReader.scrollTo`, not `scrollPosition(id:)` binding

**Chosen:** TOC jumps use `ScrollViewReader`; the modern `scrollPosition(id:)` binding was removed.

Measured reversal: the id-binding writes the top-visible ID back on every frame, and that writeback cost grew with the number of materialized rows — a progressive slowdown the deeper the user scrolled in stress-5k. `ScrollViewReader` costs nothing at rest. Cons: `scrollTo` is fire-and-forget (no restoration state), so scroll restoration would need separate handling if ever required. Scroll-target observation was also scoped to a leaf view so an `@Observable` write doesn't invalidate the whole document view.

## 9. Media: injected provider protocol + visibility-gated structured tasks

**Chosen:** `ADFMediaProvider` protocol (host supplies bytes; Confluence media needs authenticated resolution the library cannot own), `.task(id:)`-scoped fetches that cancel on scroll-away, aspect-ratio boxes reserved from schema `width`/`height` attrs *before* any load, decoded images dropped when rows leave the viewport.

- Alternative — built-in `URLSession`/`AsyncImage` loading: zero setup for demos, but bakes auth policy into the library and `AsyncImage` offers no downsampling or cancellation control. The protocol keeps the demo offline-capable (deterministic CoreGraphics gradients) and the host in charge of caching.
- The reserved-box rule exists for scrolling, not aesthetics: unknown image heights are the primary cause of `LazyVStack` estimated-height jumpiness. media-gallery (300 images) scrolls at **0.00 ms/s** hitch.
- The image-eviction rule was a review-confirmed defect, not a nicety: `@State` held decoded images forever; a long gallery would accumulate every bitmap ever displayed. Off-screen rows now hold only the media ref.

## 10. Document loading: streamed preparation via `AsyncStream`

**Chosen:** `ADFDocumentModel.load` parses off-main, then consumes `prepareStream(chunkSize: 50)`, appending chunks on the `MainActor`. First chunk (~a screenful) arrives in 34–73 ms across all fixtures; the tail prepares below the fold.

- Alternative — prepare everything before showing anything: simpler state (one phase flip), but stress-5k would show a spinner for the full preparation time; streaming shows readable content an order of magnitude sooner.
- Appending to the tail of an `Identifiable` array is cheap for SwiftUI diffing, and IDs are structural paths (stable across re-parses), so re-theming swaps arrays without losing scroll position.
- Concurrency-review fix worth recording: `guard let self` at the top of the streaming loop turned a `[weak self]` capture into a strong hold for the loop's lifetime — releasing the model's owner didn't stop preparation. The loop now re-binds `self` weakly per iteration and `deinit` cancels the producer.

## 11. State: Observation framework (`@Observable @MainActor`), Swift 6 strict concurrency

**Chosen:** One `@Observable` model per document; all pipeline types `Sendable`; zero-warning builds under Swift 6 language mode with warnings-as-errors in the app target.

- vs `ObservableObject`/Combine: `@Observable` gives per-property dependency tracking (a phase change doesn't invalidate block rows), no `objectWillChange` broadcast storms, and no Combine import in a value-type pipeline.
- Strict concurrency is load-bearing, not ceremonial: the parse/prepare pipeline crosses isolation domains constantly, and the compiler-checked `Sendable` boundaries caught real issues at build time. The bugs that slipped through (uncancellable `Task.detached` expand preparation, the strong-`self` stream loop) were *lifetime* mistakes, not data races — and both were caught by adversarial review with executable repros, then fixed.

## 12. Identity: structural path IDs assigned at decode

**Chosen:** Every node gets `"0.2.1"`-style IDs (child indexes from the root) during decode; slices derive compound IDs (`"<tableId>#rows3"`).

Pros: deterministic across re-parses of the same JSON — SwiftUI diffing, TOC anchors, scroll targets, and the table-sync registry all key off them; no UUID churn invalidating view identity on reload. Cons: IDs shift if the *document* changes shape upstream — acceptable for a read-only renderer where a changed document is a new document.

## 13. Packaging: SPM library (3 targets) + XcodeGen demo app

**Chosen:** `ADFKit` as a Swift package with `ADFModel` / `ADFPreparation` / `ADFRendering` products; the `ADFReader` app is generated from `Demo/project.yml` (the `.xcodeproj` is gitignored).

- Layer split as *targets* (not folders) makes dependency direction compiler-enforced: `ADFModel` cannot import SwiftUI, so parsing stays UI-free by construction.
- Declaring `.macOS(.v14)` alongside iOS lets the model/preparation suites run via bare `swift test` in ~0.25 s — the TDD loop never waits for a simulator.
- XcodeGen over a committed `.xcodeproj`: project file merge conflicts disappear and app config is reviewable YAML. Cons: contributors need `xcodegen generate` once (one line in the README flow), and signing settings live outside the committed file (injected via build settings at archive time).

## 14. Theming & dark mode: token struct + luminance-derived foregrounds

**Chosen:** `ADFTheme` (fonts, spacing, panel palettes) injected via environment. For author-supplied ADF hex colors (cell fills, highlight marks), the foreground is derived from the fill's WCAG relative luminance unless an explicit `textColor` mark exists.

The second half was a screenshot-review fix: Confluence palettes are fixed light pastels, while the default dark-mode foreground is white — white-on-`#f4f5f7` measured ~1.07:1 contrast (invisible). Alternative — dark-adapting the *backgrounds* — was rejected: authors chose those colors semantically, and shifting them changes meaning; adapting the foreground preserves author intent and readability.

## 15. Verification harness: in-app scroll metrics + scripted gestures, not Instruments-first

**Chosen:** The demo app self-instruments — a `CADisplayLink` frame monitor and an `-autoscroll` launch mode that drives the full document at ~1,200 pt/s and prints `SCROLL_METRICS frames/dropped/hitchRatioMsPerS`; AXe drives real swipe gestures for interaction bugs; screenshots are diffed by eye against the element inventory.

- vs Instruments/XCTest `measure`: Instruments gives deeper *why* but isn't scriptable as a repeatable pass/fail gate in this loop; the in-app counter made "hitch ratio < 5 ms/s" a one-command check that caught two real regressions (7b, 8) and validated their fixes. `os_signpost` intervals around parse/prepare remain for Instruments deep-dives.
- Honest limitation: the simulator proves the *frame-time budget*, not 120 Hz itself. The budget is what determines whether ProMotion hardware sustains 120 fps; on-device runs (iPhone 17 Pro, `CADisableMinimumFrameDurationOnPhone` enabled) are where the HUD shows the real number.
- Measurement hygiene lesson: the HUD's own material-blur overlay perturbed the numbers it was reporting; it hides during measurement runs.

## 16. Adaptive layout: baseline-aligned inline layout, width-keyed row cache, readable measure

**Chosen (visual-review + Split View fixes, 2026-07-11):** Four related decisions that turned the fixed-portrait iPhone demo into an adaptive iPhone + iPad app (all orientations, Split View / Slide Over).

- **`WrappingInlineLayout` aligns items on text baselines, not centers.** The original layout centered every token against the line height, so any inline atom (mention pill, status chip, link card) or mixed-size text run (`fontSize: "small"`, sub/superscript) sat visibly off the line's baseline — the three misalignment classes caught in screenshot review. The layout now reads `dimensions[.firstTextBaseline]` per subview, computes per-row ascent/descent, and places each item at `rowAscent − itemAscent`. It also implements `explicitAlignment(of:)` for both text-baseline guides: a custom `Layout`'s default baseline is its bottom edge, which would misalign any *enclosing* baseline-aligned `HStack` (list rows, panels).
- **Panels align icon to `.firstTextBaseline`**, matching the list-row pattern, instead of `.top` (which aligns an SF Symbol's bounding box with the line box and floats it above the cap height).
- **`DocumentRow`'s collapsed-row height cache is width-tagged, and stale spacers *approximate* rather than re-measure.** The row-collapse optimization (§4) reserved each off-screen row's exact height with a spacer. After a window resize (rotation, entering Split View) those heights are wrong for the new wrap width — the moment the app entered Split View, the main thread livelocked at 100 % CPU with the scene frozen at its pre-split render. This took three attempts, each diagnosed by `sample`:
  1. *Per-spacer `onGeometryChange` invalidation* fixed the hang but put a geometry observer on every collapsed row — the stress-5k Release gate regressed 1.5 → 5.16 ms/s.
  2. *Passing the container width down and re-materializing stale rows* removed the observers but restored the livelock: invalidating every cached height at once mass-materializes hundreds of rows, the lazy stack's scroll-offset compensation (`makeSizeChangeTranslation`, hot in every sample) shifts the render region, appear/disappear states flip, and the loop feeds itself.
  3. *Final:* a stale spacer never re-materializes; it scales its cached height by `oldWidth / newWidth` (text reflow is roughly inverse in width). Spacer height is then a pure function of stored state — no layout feedback path exists — and the exact height is re-measured only when the row naturally re-enters the render region. Gate: 3.0–4.9 ms/s across runs on a loaded host (< 5 ms/s).
- **Readable measure:** the document column is capped at 672 pt (UIKit's readable-content width) via `@ScaledMetric`, centered, so full-screen iPad and landscape don't run body text to ~90-character lines. Scaling the cap with Dynamic Type gives larger text a proportionally wider column.

Supporting rules: view-layer dimension constants that must track text size are `@ScaledMetric` (atom-pill padding, card icon well, quote bar, table gutter/minimum column widths, media fallback height, marker column); corner radii are `ADFTheme` tokens (`chip`/`container`/`card`); the only remaining literals are hairlines and platform-required window minimums. Device support is `TARGETED_DEVICE_FAMILY = 1,2` with all four orientations on iPad (required for multitasking) and portrait + both landscapes on iPhone.

Validated in the simulator matrix: iPhone 16 Plus portrait/landscape, iPad Pro 13″ portrait/landscape, Split View at ½ and ⅓ widths next to Safari, Slide Over picker, and accessibility-large Dynamic Type inside the ⅓ split; the §15 stress-5k autoscroll gate re-run after the `DocumentRow` change.

---

## 17. ADF Beam: animated-QR transfer with a raw-deflate frame protocol

**Chosen (2026-07-11):** Confluence-page-to-ADFReader transfer works server-lessly through a dev-mode Chrome extension that fetches the page's ADF over the browser's existing session (`/wiki/api/v2/pages/{id}?body-format=atlas_doc_format`) and cycles it as animated QR frames; the app's Scan screen collects frames via camera or pasted payloads.

- **Frame protocol:** `ADF1|<docId>|<index>|<total>|<data>`, where `data` is a base64 slice (default 800 bytes) of the compressed document. Pipes cannot appear in base64, so a plain split parses it; index/total make frames self-describing, letting the collector accept any order, drop duplicates, and reset on a docId or total change (a new copy of the page mid-scan restarts cleanly).
- **Raw deflate, asserted cross-implementation.** pako's default `deflate()` emits zlib-wrapped data, but Apple's `Compression` framework `COMPRESSION_ZLIB` is *raw* deflate — the two silently disagree. Both sides use raw deflate (`pako.deflateRaw`/`inflateRaw` ↔ `COMPRESSION_ZLIB`), and a shared fixture (`make-fixture.mjs` → `kitchen-sink.chunks.txt`) is decoded by a Swift test (`CrossImplementationTests`) to prove byte-identical agreement between the JS encoder and Swift decoder.
- **The protocol core is a Foundation-only SPM target (`ADFBeam`)**, so parsing/collection/decompression are `swift test`-able on macOS; the app layer (`ScanView`) adds only camera plumbing, haptics, and navigation into the existing `ReaderView` via a temp-file `Fixture`.
- **Paste is a first-class ingestion path**, not a debug hack: the paste sheet feeds the identical collector/assembler pipeline as the camera, which is what makes the end-to-end acceptance automatable on the simulator (no camera there).

The extension is MV3 with no build step (`pako`/`qrcode-generator` vendored; CSP-safe), injecting the overlay via `chrome.scripting` on toolbar click with `activeTab` + `*.atlassian.net` host permissions.

---

## 18. Text search: env-injected controller, leaf-applied highlights, visibility-gated scrolling

**Chosen (2026-07-14):** Find-in-page lives in the library as `ADFDocumentSearch`, one `@Observable @MainActor` controller per `ADFDocumentModel` (`model.search`: `run`/`next`/`previous`/`clear`, streamed `matchCount`, a `highlights` payload). The embedder's search bar is a thin shell over it; the demo's `SearchBar` is ~70 lines.

- **Environment injection, not view parameters.** `ADFDocumentView` injects `model.search` via `\.adfDocumentSearch`, so the leaf text views that need highlights read them from the environment and no intermediate container (tables, panels, lists, columns, expands) grows a pass-through property. Views rendered outside a document view (previews) see `nil` and opt out entirely.
- **Highlights are applied at the leaf, behind a zero-work gate.** `SegmentedTextView.displayedSegments` returns the stored segments *unchanged* (no copy, no scan) unless search is active AND this owner has spans — the path every row takes while scrolling with no query, and every unmatched row during one. Matched rows repaint via `SearchHighlightPainter` (subtle background on all matches, accent on the current one, a single-blink arrival flash); atom pills (mention/status/date) are plain `Text`, not range-highlightable, so a matched pill tints whole.
- **Indexing and matching run off-main over the `Sendable` prepared blocks**; only compact results publish back. Index chunks chain as the document streams in, so match counts climb live during load; epoch guards make stale chain links from a replaced document inert. Collapsed expand bodies are indexed by preparing them with the *same* preparer configuration the view uses, so span shapes and IDs align exactly with what expansion later renders.
- **Visibility-gated margin scrolling.** Navigation scrolls only when the target row is not genuinely visible: rows report viewport visibility (`onScrollVisibilityChange`, threshold 0.95) into a non-observed `VisibleRowRegistry` on iOS 18+/macOS 15+; earlier OSes report nothing, so search always scrolls there (correct, just less minimal). Off-screen targets land with a 40 pt margin at the approach edge — `ADFScrollTargetPlacement.nearTop/.nearBottom` converts the point margin to a `UnitPoint` anchor using the viewport height measured on the scroll view's frame, never inside lazy rows (§15's livelock lesson).
- **Expand state was lifted to the model** (`model.expandedBlocks`), replacing per-view `@State`. This is what lets navigation auto-expand a match's ancestor chain — and it fixes a real bug: view-local expansion state died with the row when a lazy row scrolled away and collapsed to a spacer, so a manually opened expand silently re-collapsed. The scroll-anchor registry moved to the model for the same reason: search reads the top-visible row for browser-style "first match at/after the viewport" selection and for choosing the approach edge, without any geometry reads.
- **Accepted trade-off — document-wide leaf invalidation on navigate.** The `highlights` payload is one observable value, so every materialized matched leaf re-evaluates when the current match moves. Measured on stress-5k with thousands of matches and many rows materialized, next/previous stays hitch-free (only materialized rows do work, and the painter runs only on rows with spans), so the simpler single-payload design won over per-row observation plumbing.
- **v1 exclusions:** card/link titles, expand titles, and extension placeholder chrome are not indexed (no range-highlightable text on those surfaces); scroll alignment is block-granular (the row scrolls into view, not the specific line); no horizontal auto-scroll to matches in wide tables or code blocks.

**Verification status (2026-07-15) — idle-scroll hitch gate CLOSED.** The 23× idle-scroll regression (6.41 baseline vs 146.7–157.2 ms/s branch) was root-caused by commit-level bisection plus `sample`-profiling, and the earlier attribution above turned out wrong on every count: the per-row visibility callbacks, the per-leaf `.task(id:)` flash spawns, and the observable-environment reads were all measured **innocent** (the leaf-paint commit alone gated at 2.26 ms/s; the feed attached live to all 5,000 rows gated at 0.65 ms/s). The actual poison was one line of *shape*: `reportScrollVisibility` guarded `onScrollVisibilityChange` with a `@ViewBuilder if #available`, which compiles to `buildLimitedAvailability` and type-erases each lazy row to `AnyView`. With every row erased (either branch — the `else { self }` side measured just as badly, as did moving the branch inside a per-row `ViewModifier` body), the lazy stack loses its unary-item caching and re-walks/re-measures materialized rows every frame, a cost that grows with scroll depth (2/min → ~500/min hitches). The fix hoists the availability decision above the whole `LazyVStack` (`ADFDocumentView.rows`), instantiating an `@available`-annotated, conditional-free `ScrollVisibilityReporter` per row — one `AnyView` for the entire stack, zero per row. Post-fix gate: **1.05 / 0.98 ms/s** (two runs) vs same-day baseline re-measure 1.39–3.13 ms/s. Encoded rule: *never put `if #available` (or any `buildLimitedAvailability` construct) at a lazy container's per-item position, including inside a per-item modifier's body.* Fling-CPU still settles ≈0 with and without a 73k-match query; the full live checklist re-passed. The rotation-after-programmatic-jump defect was reproduced on baseline `main` (`1d33a7d`, TOC jump → rotate restores the pre-jump anchor): pre-existing, not a product of this branch — and fixed independently on `main` by the anchor-truthfulness write in `ScrollTargetConsumer` (see the §-scrollPosition corollary above), which this merge composes with search's placement-aware jumps.

---

## 19. Per-document text size: scoped Dynamic Type override, rescaled (never cleared) spacer heights

**Chosen (2026-07-16):** The reader's per-document text-size control is a step offset on the `DynamicTypeSize` ladder, applied by the host as `.dynamicTypeSize(system.shifted(by: step))` on `ADFDocumentView` alone (innermost modifier, so navigation chrome and the search bar keep the app's size). Persistence is host-side (`FontSizeStore`, UserDefaults keyed by `DocumentSource.storageKey`, the `TaskStateStore` pattern); `DynamicTypeSize.shifted(by:)`/`approximateBodyPointSize` live in `ADFRendering` as public helpers. `-fontSizeStep <n>` joins the launch-argument harness so gates can run at any size.

- **Why an environment override and not a theme change:** every library font is a semantic text style baked per-run into prepared `AttributedString`s, and SwiftUI re-resolves semantic fonts at draw time — so the override rescales all text with **zero re-preparation**, and every `@ScaledMetric` layout metric (readable measure, list markers, table column floors, pill paddings, sub/superscript `typeScale`) follows the same environment value. A point-size `ADFTheme` would instead force a full re-prepare per adjustment and desynchronize every `@ScaledMetric` (they track the environment, not the theme). Composes with accessibility rather than fighting it: the device setting is the baseline the step shifts from.
- **Collapsed spacers RESCALE in place; they are never cleared.** A type-size change resizes every collapsed row at an unchanged width — the one invalidation `CollapsedRowHeight`'s width-keyed memo cannot see. Clearing samples (the `item.revision` pattern) would flip every collapsed row into the `heights.isEmpty` re-materialization branch at once — exactly the §16 mass-re-materialization livelock. Instead `rescale(by: newBodyPt/oldBodyPt)` carries the remembered heights across as estimates (media excluded — pixel/fraction-sized boxes don't track text), corrected on natural re-entry like every other estimate.
- **A type-size change is a re-anchor trigger, sibling to width change.** The column width usually doesn't move when text grows — never on iPhone, and not on iPad in pane-bound layouts (Split View, Slide Over, Stage Manager windows narrower than the scaled readable cap) — so the width-change re-pin never fires there; a second `.onChange(of: dynamicTypeSize)` re-asserts `anchors.topRow` through the same one-shot, animations-disabled `scrollTo` and is the sole corrective in all of those layouts. Only a full-screen-class iPad column moves `readableWidth` (`@ScaledMetric`) and fires both; double-asserting the same anchor is harmless. This also fixes the latent stale-spacer/no-re-pin bug for *system* Dynamic Type changes mid-session.
- **Rescale factors are per-kind, exhaustive, and quadratic for wrapping text (post-review correction, 2026-07-16).** An independent adversarial review confirmed three estimate bugs in the first cut: live rows skipped the rescale (stale other-width samples replayed as "exact" after the next rotation), a linear factor cancelled against the reflowing width carry-across on full-screen iPad (spacers reported OLD heights while rows grew), and dividers (hairline + fixed padding) were rescaled at all. The fix: every row rescales (the live row's current-width sample is immediately re-recorded exactly by its geometry callback), and `RenderBlock.Kind.typeSizeRescaleFactor(bodyPointRatio:)` switches exhaustively — media and dividers 1, non-wrapping kinds (code, table slices, cards, media strips) `ratio`, wrapping kinds `ratio²` (height ∝ pointSize²÷width: taller lines AND fewer characters per line — which nets to `ratio` after the iPad width carry divides one back out). `approximateBodyPointSize` clamps `@unknown` future sizes to the ladder top so the factor stays monotonic on newer OSes.
- **Measured (2026-07-16, iPhone 16 sim, iOS 18.2, Debug):** stress-5k autoscroll — baseline 2.64/2.41 ms/s, feature at step 0 3.89/1.39 (noise-equivalent), at +3 8.15/4.56 (bigger glyph runs; pacing estimator assumes default size, so indicative only). Fling-burst CPU settles 0.0–0.3 at +3, including immediately after a mid-scroll size change across collapsed regions — the gate that catches livelocks. Search at +3: 2,557 matches / ~115 ms (spans are Character-offset based, size-independent). Mid-scroll +3 via the popover holds the reader's content; rotation round-trip at 135% re-anchors cleanly.

---

## Summary of measurement-driven reversals

| Initial choice | Measured problem | Final choice |
|---|---|---|
| `JSONSerialization` + bridge | 106 ms parse on 2.3 MB doc; first-chunk gate failed | Custom UTF-8 `JSONScanner` (~21 ms), serialization fallback |
| 20-row table slices | 535 ms/s hitch on giant-table | 2-row slices (0.00–0.41 ms/s) |
| `Canvas` row underlay (prototype) | 15× worse than layer compositing | Flat `Rectangle` fills |
| `scrollPosition(id:)` binding | Per-frame writeback scaling with materialized rows | `ScrollViewReader.scrollTo` + leaf-scoped observation |
| Independent per-slice h-scrolling | Rows shear out of alignment on real swipes | Shared-offset sync registry (iOS 18+) |
| String building in `SegmentedTextView.body` | Allocation per body evaluation | Pre-split segments at preparation time |
| `@State` images retained forever | Unbounded memory on galleries | Evict on scroll-away, keep only the ref |

The meta-lesson these share: the architecture's *shape* (value-type pipeline, flat lazy list, pre-computation) survived contact with profiling unchanged — every reversal was a tactical choice inside that shape, caught because the project had executable gates instead of assumptions.
