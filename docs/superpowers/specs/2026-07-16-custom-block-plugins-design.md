# Custom Block Plugins (consumer-provided node renderers) — Design

**Date:** 2026-07-16
**Branch:** `custom-block-plugins`
**First use case:** a YouTube URL (embedCard / blockCard / paragraph-wrapped smart link)
renders an inline video player instead of a link card.

> Reviewed by a four-skeptic adversarial panel (scroll-perf, Swift 6
> concurrency/API, search, preparation/threading) before implementation; the
> amendments it produced are folded in below and marked *(panel)*.

## Goal

Let ADFKit consumers register plugins that claim ADF nodes at preparation time and
render them with consumer-provided SwiftUI views — while preserving every invariant
the reader is built on: 120 fps scroll (§8 gates), truthful collapsed-row spacers,
scroll-position retention across rotation / Split View / Dynamic Type changes,
find-in-page participation, and Dynamic Type conformance.

## Approaches considered

**A. YouTube special-case inside CardBlockView** (the §6.6 SmartLinkResolver path).
Smallest diff, but not extensible — consumers cannot provide views, and every new
embed type means another library release. Rejected: the requirement is a plugin
mechanism, video is just the first plugin.

**B. View-only plugin: an environment closure `(RenderBlock) -> AnyView?` tried by
`BlockView` before its switch.** No preparation changes, but it breaks three
compile-enforced contracts at once: the claimed block keeps its original kind, so
`heightScaling` / `typeSizeRescaleFactor` are wrong for a 16:9 player (a `.card` is
`invariant`; a video is width-proportional — the exact misclassification that
corrupted content height in the mediaStrip regression); search still indexes the
original text (or nothing, for `.card`); and paragraph-wrapped links can't be
promoted to block embeds. Rejected.

**C. Two-phase plugin: preparation-time matcher producing a value descriptor +
render-time view factory resolved via environment. (Chosen.)**
This is the split the codebase's own rules force: `RenderBlock.Kind` payloads must
be closure-free Sendable+Hashable values (rows diff cheaply, preparation runs on a
detached task), while consumer views are `@MainActor` and enter the tree through the
environment — the `ADFMediaProvider` precedent.

## Architecture

### 1. Value descriptor (ADFPreparation)

A matcher returns an **`ADFCustomBlockClaim`** (typed payload via a generic init,
sizing declaration, optional searchable text). The claim loop stamps the claiming
preparer's `rendererID` into the resulting **`ADFCustomBlock`** — whose init is
internal, so a claim can never reference the wrong renderer *(panel: closes both
the typo'd-ID and copy-pasted-ID silent-placeholder classes at the type level)*.

```swift
public struct ADFCustomBlockClaim: Sendable, Hashable {
    public init<V: Hashable & Sendable>(_ value: V,
                                        sizing: ADFCustomBlockSizing,
                                        searchableText: String? = nil)
}

public struct ADFCustomBlock: Sendable, Hashable {   // internal init — library-stamped
    public let rendererID: String
    public let value: ADFCustomBlockValue            // type-erased Hashable & Sendable box
    public let sizing: ADFCustomBlockSizing
    public let searchableText: String?
}

public enum ADFCustomBlockSizing: Sendable, Hashable {
    /// Video/map embeds. → heightScaling .proportional(cap: maxWidth), rescale 1.
    /// The LIBRARY draws this box (see §4), so profile and geometry agree by
    /// construction (panel).
    case aspectRatio(width: Double, height: Double, maxWidth: Double? = nil)
    /// Link-card/strip chrome. → .invariant, factor ratio.
    case scaledChrome
    /// Wrapping text. → .reflowing, factor ratio².
    case reflowingText
}
```

`ADFCustomBlockValue` erases any `Hashable & Sendable` payload. *(panel)* Both
`==` **and** `hash(into:)` must go through `AnyHashable`: its equality is
bridging-normalized (`1 as Int == 1.0 as Double`), so hashing the unwrapped value
directly would violate the Hashable law.

`RenderBlock.Kind` gains **`case custom(ADFCustomBlock)`**. Every exhaustive switch
is extended (compile-enforced): `heightScaling`, `typeSizeRescaleFactor`,
`defaultVerticalPadding` (8, container class), `SearchIndexer.collect`, `BlockView`,
and the demo's `BlockHeightEstimator`.

### 2. Matcher protocol (ADFPreparation)

```swift
public protocol ADFCustomBlockPreparer: Sendable {
    var rendererID: String { get }          // unique per document (asserted in DEBUG)
    func claim(for node: ADFNode) -> ADFCustomBlockClaim?
}
```

`BlockPreparer.blocks(for:)` consults plugins at the top of its switch (skipping
`.doc`): first registered claimer wins; declined nodes keep built-in rendering.
The matcher runs inside the detached prepare walk — measured budget *(panel)*: a
reject-path matcher costs ~8 ns/consult (~0.05 ms on the 5k-block stress fixture,
0.07 % of the walk); keep matchers at ≤ ~1 µs/node — string/kind checks, no regex.

**Reach** *(panel, corrected)*: claims intercept everywhere the block walk goes —
top level, panels, quotes, table cells, layout columns, bodied extensions, list
**trailing** blocks, and expand bodies. They do NOT see inline positions: atoms
mid-paragraph, and the **leading paragraph of a list item** (list rows compose it
inline — `ListPreparer.itemRows`), which therefore keeps its chip rendering in v1.
A paragraph whose entire content is one smart link IS claimable; matchers must
ignore whitespace-only text siblings around the link *(panel: real Confluence
paragraphs carry them)*.

### 3. Configuration threading — model-owned, by construction

*(panel: the original "four sites" enumeration missed the two `SearchIndexer`
constructions inside `ADFDocumentSearch` — the exact drift that silently breaks
search alignment for expand bodies. Fixed by removing those construction sites
entirely.)*

- `ADFDocumentModel.init(theme:customRenderers:)` owns the ordered renderer list —
  the single source of truth for matching, rendering, and indexing.
- `load()` builds `DocumentPreparer(theme:customPreparers:)` from it.
- `ADFDocumentSearch` no longer constructs indexers: `indexAppended` /
  `applyIndexChanges` receive the model's prebuilt `SearchIndexer(theme:customPreparers:)`.
- `SearchIndexer` re-prepares expand bodies with the same `customPreparers`.
- `ExpandBlockView` prepares open bodies **model-first** (`search?.model`), with
  the environment registry only as a preview fallback *(panel: overriding the
  registry environment below `ADFDocumentView` is unsupported)*.
- `ADFSearchBench` and the test suites construct plugin-free preparers deliberately.

### 4. Renderer protocol + registry (ADFRendering)

```swift
public protocol ADFCustomBlockRenderer: ADFCustomBlockPreparer {
    associatedtype Value: Hashable & Sendable       // (panel: typed payload —
    associatedtype Content: View                    //  no impossible-nil unbox
    @MainActor @ViewBuilder                         //  in consumer code)
    func content(for value: Value, context: ADFCustomBlockContext) -> Content
}
```

The library unboxes the typed payload and erases the view inside a protocol
extension (where `Self` is concrete); a type mismatch falls back to the neutral
chip. The registry is an immutable `Sendable` final class **created once in
`ADFDocumentModel.init`** and injected by reference through an optional-nil-default
environment key (the `TableScrollSync` pattern) *(panel: both rules are
load-bearing — a per-body-eval registry would invalidate every custom leaf on any
host update)*. Duplicate `rendererID`s are asserted against in DEBUG.

`BlockView` gains one concrete leaf case, `CustomBlockView`. **Why AnyView here is
safe** *(panel, corrected justification)*: the lazy item's outer type stays
`DocumentRow`'s — memcmp-diffable, skipped entirely during scroll — and the erased
type is the renderer's fixed `Content`, resolved by `rendererID` from an immutable
registry, so identity cannot churn. The measured §8 poison was erasure of the
row's OUTER type via `buildLimitedAvailability`. Corollary rule: `CustomBlockView`
must remain a case of `BlockView`'s switch and must never wrap the row or a
per-row modifier. A missing renderer renders a neutral placeholder chip (§7:
nothing silently disappears).

For `.aspectRatio` sizing, **`CustomBlockView` draws the declared box** (aspect
ratio + `maxWidth` cap) and proposes it to the consumer view — the sizing profile
the spacer estimator uses and the rendered geometry agree by construction, the way
`MediaBlockView` derives both from one `PreparedMedia` *(panel)*.

### 5. The viewport contract (what a plugin view gets and must do)

- Fill the proposal. For `.aspectRatio` the library draws the box; other sizings
  are proposed the content-column width (nested containers propose their inner
  width). Never `GeometryReader`, never named-coordinate-space reads (livelock
  class).
- Height MUST be a deterministic function of (proposed width, environment) —
  **independent of view-local state, including interaction state**: a facade and
  the player it swaps in must occupy the identical box *(panel)*. Content that
  genuinely changes goes through `model.apply(.replace…)` (revision bump discards
  stale spacer samples).
- Dynamic Type: semantic fonts / `@ScaledMetric` only; the per-document override
  composes through the environment with zero re-preparation.
- Heavy machinery (WKWebView, AVPlayer) MUST NOT be created in a scrolling row —
  facade first, real player only on explicit tap (the one-time tap hitch is
  sanctioned; a scroll hitch is not). An embedded web view must not capture the
  document's scroll gestures (`scrollView.isScrollEnabled = false`) *(panel)*.
- View state dies when the row leaves the render region; state that must survive
  belongs host-side, keyed by `context.blockID`.
- Search: `searchableText` is indexed as one whole-block **atom-part** unit
  (whole-view tint — no range painting, so truncated rendering can't desync
  highlights). **WYSIWYG contract** *(panel)*: contribute ONLY text the plugin
  view actually renders — matching invisible text makes "Next" cycle matches with
  nothing visibly changing. `CustomBlockView` owns the zero-work gate in the
  canonical order (`search.isActive` Bool first; then the per-owner store's
  `currentAtomIDs`/`atomIDs` — the span fields are always empty for atom units;
  never the aggregate `highlights`), draws the default border emphasis + arrival
  flash, and passes the resolved state via `context.searchEmphasis`. Scroll-to-
  match and expand auto-open work unmodified (units carry `topLevelBlockID` +
  `expandAncestorIDs`).

### 6. YouTube plugin (package target `ADFYouTube`)

Ships as an optional product; the demo app registers it as an ordinary consumer.

- **Matcher:** claims `embedCard` / `blockCard` / stray `inlineCard`, and
  paragraphs that are exactly one YouTube smart link (whitespace siblings
  ignored). Video ID via `URLComponents` (youtube.com + subdomains, youtu.be,
  youtube-nocookie.com; /watch?v=, /embed/, /shorts/, /live/, /v/; IDs are exactly
  11 chars of `[A-Za-z0-9_-]`). Channels, playlists, handles, other hosts decline.
- **Payload:** `YouTubeVideo { videoID }`; sizing `.aspectRatio(width: 16, height: 9)`;
  `searchableText: nil` *(panel: the facade renders a thumbnail, not the URL —
  WYSIWYG; also avoids per-substring duplicate matches inflating counts)*.
- **View:** lite-embed facade — thumbnail (`i.ytimg.com`, fetched once per row
  materialization into a bounded decoded cache; state dies at render-region
  exit like all block state) + play button; tap swaps
  in a WKWebView loading
  `youtube-nocookie.com/embed/<id>?autoplay=1&playsinline=1` (inline playback,
  document scroll gestures preserved). Scroll-away tears the player down —
  playback stops by design.

### 7. Testing & verification

- Preparation: claim/decline, rendererID stamping, first-claim-wins, nested
  interception (panel, quote, table cell, layout column, list trailing), breakout
  carry, determinism, kitchen-sink non-interference. *(All passing.)*
- Search: atom-unit shape (gap-free, Character offsets), whitespace skip,
  **expand-body parity with plugins** (the only shape that exercises the indexer's
  internal re-prepare), atom-only publication (`spansByOwner` empty), end-to-end
  `ADFDocumentSearch` integration: match → whole-block highlight → expand
  auto-open → scroll target; nil-text corpus neutrality. *(All passing.)*
- Rendering: sizing → scaling/rescale mapping; proportional spacer carry.
  *(All passing.)*
- ADFYouTube: URL matrix (14 accept / 17 reject), claim shapes, youtube.json
  fixture inventory. *(All passing.)*
- Demo gates: `-fixture stress-5k -autoscroll` hitch ratio vs a fresh same-build
  baseline; **manual fling + instantaneous-CPU settle** (the autoscroll gate
  provably misses livelocks); rotation + type-size scroll retention on
  youtube.json; facade→player same-box check; play-then-fling gesture check.

## Post-implementation performance review

**Reviewed:** 2026-07-16  
**Scope:** WebView lifetime, scrolling behavior, memory scaling, and
portrait↔landscape scroll retention on `custom-block-plugins`.

### Summary

Many YouTube blocks are inexpensive while they remain untapped: each is a
SwiftUI facade with a visibility-gated thumbnail, not a `WKWebView`. The
dominant cost begins after activation. Every tapped player creates a separate
`WKWebView`, and the current viewport gate does not tear it down when the player
leaves the visible viewport.

No accumulating orientation drift reproduced on the 27-block YouTube fixture.
Two complete portrait↔landscape round trips retained the same logical row, and
the second cycle returned to the same vertical coordinate. A bounded one-time
snap of approximately 21 points did reproduce: the identity re-pin retains the
row but loses the reader's sub-row offset, matching the known residual in
`ADFDocumentView`.

The review found one high-impact lifetime issue, two medium scroll/visibility
risks, and one lower-grade thumbnail bottleneck.

> **Resolution status (2026-07-16, commit follows this review):** all four
> issues fixed and verified — per-issue notes below.

### 1. High — activated WebViews outlive viewport visibility

`YouTubePlayerView.isVisible` controls only the thumbnail task. After a tap,
`isPlaying` remains true until SwiftUI destroys the entire lazy row:

```swift
if isPlaying {
    EmbedWebView(videoID: videoID)
}

.modifier(VisibilityGate(isVisible: $isVisible))
```

A lazy row can remain in SwiftUI's render/prefetch region after it is completely
outside the viewport. Consequently, scrolling a playing video out of sight does
not immediately dismantle its `WKWebView`, contrary to the viewport contract in
§6. Playback, networking, timers, WebContent processes, and compositor surfaces
can remain active until the row eventually leaves the wider render region.

Live iOS 18.2 Simulator verification:

- Activating two visible players created two distinct WebContent processes.
- Both processes remained alive after the first player was fully outside the
  visible viewport.
- The Simulator reported approximately 356–363 MB RSS for each WebContent
  process and approximately 282 MB for the app after both players were active.
  Simulator RSS is not a device-memory prediction and may count shared pages in
  more than one process, but the process-per-activated-player scaling is clear.
- Scrolling far enough for a lazy row to leave the render region eventually
  destroyed its WebContent process.

The document should own the active player identity and enforce at most one
active `WKWebView` at a time. The player should also be dismantled on a reliable
viewport-exit signal if scroll-away is meant to stop playback. A
`dismantleUIView` hook that stops loading/playback is useful cleanup, but does not
replace an explicit active-player limit.

> **FIXED.** `YouTubePlaybackCoordinator` (`@MainActor @Observable`, one per
> renderer instance) owns the active player identity: `isPlaying` is derived
> from `activeBlockID == blockID`, so activating any block returns the previous
> player to its facade — at most one `WKWebView` exists per document. Viewport
> exit (`isVisible → false`) and render-region exit (`onDisappear`) both
> deactivate, with stale deactivations ignored by ID. `dismantleUIView` /
> `dismantleNSView` stop loading and blank the page. Verified live: two visible
> players tapped in sequence → first instantly back to facade while second
> plays; playing player scrolled out of viewport → facade on return.
> Unit-tested: exclusivity + stale-deactivation ordering.

### 2. Medium — proportional spacers scale fixed row padding

`DocumentRow` records the height after applying the custom block's fixed
8-point vertical padding on each side. `CollapsedRowHeight.proportional`, however,
scales the complete measurement by the width ratio:

```swift
return newest.height * target / source
```

The actual row height is affine, not fully proportional:

```text
actual height = width × 9/16 + 16 points of fixed padding
```

For the observed 361→640-point content-width change:

```text
actual landscape row    = 640 × 9/16 + 16             = 376.0 pt
estimated collapsed row = (361 × 9/16 + 16) × 640/361 ≈ 388.4 pt
error                                                     ≈ +12.4 pt
```

One hundred collapsed video rows can therefore overstate the unseen
orientation's content height by approximately 1,240 points. The identity re-pin
still holds the selected top row, so this did not recreate progressive
row-identity drift in the tested fixture. It does distort total content height
and scrollbar proportions, and can cause corrections as rows rematerialize and
replace estimated heights with exact measurements.

`CustomBlockRenderingTests.spacerCarry()` currently records `202.5` points at a
360-point width—the bare 16:9 box—while production records the padded row. The test
therefore misses this error. The collapsed-height model needs to carry
proportional content and fixed chrome separately, and the test should record the
same complete row height as `DocumentRow`.

> **FIXED.** `CollapsedRowHeight.Scaling.proportional` gained `fixedOverhead`:
> the carry is now affine — `(measured − overhead) × ratio + overhead` — and
> custom aspect blocks declare `defaultVerticalPadding × 2` (16 pt), making the
> uncapped-aspect carry EXACT (the review's 361→640 case now reproduces
> 376.0 pt to the point, error 0 instead of +12.4). Media keeps overhead 0
> (its rows mix caption/layout chrome; the small inflation stays in the
> documented self-correcting class). `spacerCarry` records the complete padded
> row height, and a new `portraitLandscapeAffineCarry` test pins the review's
> measured widths. The demo `BlockHeightEstimator` adds the padding too.

### 3. Medium — deferred visibility can commit a stale callback

`VisibilityGate.deferredSet` compares against committed state before scheduling
its main-actor task:

```swift
guard visible != isVisible else { return }
Task { @MainActor in
    if isVisible != visible {
        isVisible = visible
    }
}
```

Starting from `isVisible == false`, a `true` callback can schedule a deferred
write; if `false` then arrives before that task executes, it matches the still-
false committed state and is discarded. The queued task subsequently commits
stale `true`. The inverse sequence can leave a visible row false.

This can retain offscreen decoded thumbnails, start unnecessary network work, or
leave a visible facade without its thumbnail. Scene snapshots and rapid scroll
callbacks are the most likely triggers. A stable, non-observable coordinator
should retain the latest desired value and coalesce it into one deferred commit,
or the pending commit should be replaced using a generation/token. The final
callback must not be discarded by comparing it only with committed state.

> **FIXED — twice, the durable way.** A latest-wins coalescer first replaced
> the committed-state guard, but a live recurrence proved ANY state bound to
> the visibility feed is a livelock: with genuine boundary oscillation, each
> deferred commit shifts lazy placement, the binder fires with the opposite
> value, and the next commit is scheduled — 100 % CPU across commits (captured
> with sample(1): `beginTransaction` runloop observer → `flushTransactions` →
> full lazy placement, every turn). Final fix: visibility writes NO view
> state. Thumbnails load per row materialization (`.task`, bounded by
> render-region lifetime like all block state; the decoded cache makes
> re-entry free), and the visibility feed drives only `deactivate` — a
> deferred, idempotent coordinator call that writes observable state at most
> once per activation, so it cannot sustain a loop. The coalescer is deleted.

### 4. Low — repeated full thumbnail decode

The thumbnail path downloads `hqdefault.jpg`, constructs `UIImage(data:)`, and
stores a SwiftUI `Image`. Viewport exit drops that decoded state. Re-entry can
reuse encoded bytes from `URLCache`, but still constructs and decodes the image
again. Rapidly crossing many video facades can therefore create allocation and
decode churn adjacent to scrolling.

Use a bounded decoded-thumbnail cache keyed by video ID and target pixel size,
and downsample away from the render path. This is materially smaller than the
activated-WebView cost but becomes visible in embed-dense documents.

> **FIXED.** `YouTubeThumbnailCache` (`NSCache`, 48 entries, evicts under
> memory pressure, main-actor confined) stores fully decoded bitmaps keyed by
> video ID; decode happens once in the async fetch path via
> `byPreparingForDisplay()`, never lazily during a scroll frame. Re-entering
> rows repaint from the decoded cache with zero network or decode work.
> (hqdefault.jpg is 480×360, so a size-keyed variant adds nothing today.)

### Scrolling and memory impact by state

| Embed state | Scrolling impact | Memory/process impact |
|---|---|---|
| Untapped, offscreen | No WebView; no thumbnail work in the settled state | Minimal SwiftUI row state |
| Untapped, visible | Thumbnail request/decode on entry; facade remains lightweight | Approximately one decoded thumbnail per visible facade |
| Tapped, visible | Web content and compositing add work; vertical drag still reaches the document because the inner WebView scroll view is disabled | One active `WKWebView`; live testing observed another WebContent process per activated player |
| Tapped, outside viewport but inside lazy render region | No direct gesture conflict, but offscreen playback/rendering can compete with document scrolling | WebView and WebContent process remain alive under the current implementation |
| Far enough outside the lazy render region | Row collapses to a spacer | WebView is dismantled; process/cache memory may not return immediately |

The live gesture test began a vertical drag directly over an activated player;
the document scrolled correctly, so `webView.scrollView.isScrollEnabled = false`
prevented direct scroll stealing in the tested iOS 18.2 environment. The larger
risk with many activated players is indirect: memory pressure, WebContent CPU,
network/media work, and extra compositor surfaces can reduce scrolling headroom
or provoke WebContent eviction/application termination.

### Verification performed

| Check | Result |
|---|---|
| `swift test` | **200 tests in 32 suites passed** |
| Release Simulator build | **Passed** |
| Two portrait↔landscape round trips on YouTube fixture | Same logical row retained; no accumulating drift in this fixture |
| Sub-row alignment across first rotation | Approximately 21-point bounded snap reproduced |
| Vertical drag starting inside active player | Document scrolled; no direct gesture capture reproduced |
| Two active players, then scroll one offscreen | Both WebContent processes remained alive until lazy-row teardown |

### Recommended release gates

1. Enforce a single active WebView per document and verify the prior process is
   released when another player starts or the active player leaves the viewport.
   → **Done**: coordinator-enforced; verified live (two-player takeover,
   viewport-exit teardown) + unit tests.
2. Add a complete-row proportional-spacer test that includes fixed vertical
   padding at portrait and landscape widths.
   → **Done**: `spacerCarry` (complete padded row) +
   `portraitLandscapeAffineCarry` (the review's 361→640 case, exact).
3. Add a deterministic visibility-coalescing test for `true → false` and
   `false → true` callbacks delivered before the deferred commit runs.
   → **Superseded**: visibility no longer commits view state at all (see the
   issue-3 resolution), so there is nothing to coalesce; the loop-immunity property
   is structural (deactivate is idempotent per activation), pinned by the
   coordinator unit tests.
4. Add a long, embed-dense rotation fixture with collapsed video rows above the
   anchor; assert content height, scrollbar end position, and repeated-cycle
   anchor stability.
   → **Done**: `Fixtures/youtube-dense.json` (242 blocks, 80 embeds); two
   rotation round trips at mid-document are pixel-identical with ~40 collapsed
   video rows above the anchor (affine spacers make the estimate exact, so
   content height no longer drifts by ~1,240 pt per 100 rows).
5. Add a multi-player memory/scroll gate that activates several players before
   a fling. Facade-only autoscroll does not exercise the dominant WebView cost.
   → **Done** (recast): multiple simultaneous players can no longer exist; the
   gate is now "activate, then fling across the dense fixture" — CPU settles
   0.0.

## Explicitly out of scope (v1)

Inline-position custom atoms (including list-item leading paragraphs); range-level
highlight painting inside plugin views; persistent playback state across
scroll-away; oEmbed title resolution — when added it must go through
`model.apply(_:revision:)` **and be keyed to a document generation**: structural
item IDs recur across documents, so a stale async upgrade from document A would
otherwise graft into document B *(panel)*; `SmartLinkResolver` generalization;
plugin flags for `ADFSearchBench`.
