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
- **View:** lite-embed facade — thumbnail (`i.ytimg.com`, visibility-gated
  `.task(id:)` fetch, dropped off-screen like §6.5 media) + play button; tap swaps
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

## Explicitly out of scope (v1)

Inline-position custom atoms (including list-item leading paragraphs); range-level
highlight painting inside plugin views; persistent playback state across
scroll-away; oEmbed title resolution — when added it must go through
`model.apply(_:revision:)` **and be keyed to a document generation**: structural
item IDs recur across documents, so a stale async upgrade from document A would
otherwise graft into document B *(panel)*; `SmartLinkResolver` generalization;
plugin flags for `ADFSearchBench`.
