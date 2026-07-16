# Search and Highlighting: Incremental Update Results

**Date:** 2026-07-15  
**Fixture:** `Fixtures/stress-5k.json` (5,000 top-level blocks, 14,247 search units)  
**Baseline:** untouched `ed056bd` build for simulator comparison; the benchmark's
`legacy` variant reproduces full-corpus re-index/rescan and per-match span slicing.  
**Machine:** Apple M4 Pro (14 cores, 48 GB), macOS 26.3, Xcode 26.3.  
**Simulator:** iPhone 17 Pro, iOS 26.2, Debug app. Engine benchmarks use the
release `ADFSearchBench` executable.

## Notation

To avoid overloading `N`, this report uses the same notation as
`Text-Search-Complexity-Review.md`:

| Symbol | Meaning |
| --- | --- |
| `B` | top-level document items / lazy-stack rows |
| `N` | nodes in the prepared block tree |
| `T` | searchable `Character` (grapheme) count |
| `U` | extracted search text units |
| `Q` | query length |
| `M` | query matches |
| `S_i` | segment/atom parts in unit `i` |
| `P` | emitted paint spans and atom hits |
| `Delta N`, `Delta T` | nodes and searchable characters in changed items |
| `C` | changed top-level items in one mutation batch |

If `N` was previously used informally for document string length, that quantity is
`T` here. This distinction matters because parsing/indexing depends on nodes and
text, while matching depends on searchable text and query length.

## Complexity Results

| Operation | Previous implementation | Implemented approach | Factual conclusion |
| --- | --- | --- | --- |
| Initial indexing | `O(N + T)` time, `O(T + sum S_i)` index space | Same, split into independently replaceable top-level items | No asymptotic full-load change |
| New full query | Worst-case `O(T * Q)` matching through Foundation's case/diacritic-folded `range(of:)` | Same matcher; per-item results | Full query still has to inspect the corpus; no claimed asymptotic improvement |
| Match-to-paint projection | `O(sum(M_i * S_i))` | `O(sum(S_i + M_i + P_i))` over matched units | Repeated part-map scans removed |
| Scan aggregation/publication | Span projection and growing whole-map COW on main actor; worst case `O(M * batches)` copying | Match/projection detached; results retained per item and published per affected owner | Main publication is proportional to changed result payload, not all prior matches |
| Paint one visible string | `O(E * L)` for `E` edits over length `L` | `O(L + E)` endpoint lookup and one forward character walk | Quadratic many-match code-block path removed |
| Active-query replacement, search engine | Required full rebuild/rescan to support replacement: `O(N + T + T * Q + P)` | `O(Delta N + Delta T + Delta T * Q + Delta P)` | Search work is localized to changed items |
| Public model replacement | No replacement API | `O(B + C + localized search)` because the public flat `[RenderBlock]` snapshot still copies on write; stable row/highlight stores localize SwiftUI invalidation | Search is delta-based; flat snapshot publication remains the end-to-end bound |
| Insert/remove/move | Unsupported by append-only index | `O(B + changed-item indexing/search)` due flat-array/order/section rebuild | Correct and versioned, but not sublinear in `B` |
| Next/previous rank lookup | `O(1)` over a flat match array | Worst-case `O(B)` over per-item result counts | Intentional tradeoff for cheap replacement; still a theoretical regression |

The lower bound for a previously unseen full query is `Omega(T + M)` because the
corpus must be inspected and matches emitted. A custom folded-text representation
plus a linear matcher could tighten the current `O(T * Q)` worst case, but it would
need an additional source-offset map to preserve Unicode-correct highlights. For
frequent replacements, the implemented search-index bound is already proportional
to the changed searchable text. Removing the remaining model-level `O(B)` term
would require replacing the public flat block snapshot with a chunked sequence or
order-statistics tree.

## Measured Results

All timed variants produce the same result counts and checksum. Independent
verification matched all 2,607 `fixture` hits and the one-hit replacement result.

| Release workload | Legacy median / p95 | Incremental median / p95 | Result |
| --- | ---: | ---: | ---: |
| Full query `fixture`, 2,607 matches, 30 runs | 59.612 / 63.226 ms | 58.702 / 60.575 ms | 1.5% faster median |
| Full query `e`, 73,399 matches, 15 runs | 70.510 / 74.194 ms | 73.471 / 74.854 ms | 4.2% slower median |
| 100 one-block add/remove updates, active query | 168.976 / 176.917 ms | 0.018 / 0.042 ms | about 9,400x faster median |
| 5,000-part, 5,000-hit span projection, 20 runs | 3.606 / 4.269 ms | 0.199 / 0.241 ms | 18.1x faster median |

The static-query results are effectively parity and validate the complexity
prediction: partitioning helps updates, not a brand-new query over all text. The
high-hit `e` case shows the per-item result overhead honestly; the new path is not
uniformly faster for full scans.

Peak resident size for the 20-update release process was **71.53 MiB legacy** and
**64.92 MiB incremental**, a 6.61 MiB (9.2%) reduction. Both processes loaded and
prepared the same fixture; the difference is transient full-corpus rebuild state.

Three Debug simulator runs with 2,607 active matches and 100 replacements each:

| Metric | Run 1 | Run 2 | Run 3 |
| --- | ---: | ---: | ---: |
| Full query | 114.601 ms | 114.467 ms | 117.539 ms |
| Replacement median | 14.116 ms | 13.843 ms | 14.166 ms |
| Replacement p95 | 16.199 ms | 15.140 ms | 15.366 ms |

The end-to-end simulator number includes version validation, public model
publication, detached re-index/rescan, owner-highlight publication, and the visible
row update. All three p95 values remained below a 16.67 ms 60 Hz frame interval.

Full 5,000-block autoscroll frame pacing:

| Build | Frames | Reported hitches | Hitch ratio |
| --- | ---: | ---: | ---: |
| Untouched baseline | 29,591 | 103 | 3.51 ms/s |
| Incremental implementation | 29,625 | 93 | 3.17 ms/s |

This is one long run per build, so it is a regression check rather than a
statistically strong frame-pacing comparison.

## Verification Commands

```sh
swift test
swift build -c release --product ADFSearchBench
.build/release/ADFSearchBench verify --query fixture
.build/release/ADFSearchBench static --variant legacy --query fixture --iterations 30
.build/release/ADFSearchBench static --variant incremental --query fixture --iterations 30
.build/release/ADFSearchBench updates --variant legacy --iterations 100
.build/release/ADFSearchBench updates --variant incremental --iterations 100
.build/release/ADFSearchBench spans --variant legacy --parts 5000 --iterations 20
.build/release/ADFSearchBench spans --variant incremental --parts 5000 --iterations 20
```

The suite contains 160 tests in 25 suites, including differential batch-span
tests, localized replacement, stable identity through insert/move/remove,
revision/atomicity failures, stale-current cleanup, and the streamed late-result
auto-selection regression from the prior review.

## Comparison With The Prior Review

The previous report was accurate about the unchanged `O(N + T)` indexing cost,
the matcher's `O(T * Q)` worst case, Unicode/source-offset requirements, and the
importance of keeping search work off the main actor. Its important streamed
auto-selection finding was real and is now covered by a regression test.

Its two largest performance concerns were also confirmed and removed:

1. Per-match `O(S)` span slicing and growing global highlight publication were
   replaced by detached batch projection and per-item/per-owner delta state.
2. The visible many-match painter changed from `O(E * L)` to `O(L + E)`.

The prior report did not analyze arbitrary document replacement because the old
controller was append-only. The new measurements make that distinction explicit:
full-query performance is nearly unchanged, while changed-item search work is
localized by four orders of magnitude on this fixture. The remaining `O(B)` flat
model snapshot and `O(B)` navigation rank lookup are documented rather than
presented as theoretically optimal.
