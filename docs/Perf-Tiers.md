# Performance tiers: T0, T1, T2

Perf checks count **renderer work** on every change, and measure **frames**
only at a few checkpoints. Frame statistics need a quiet Mac and still vary
about 18 % on the same build. Work counts (TextKit 2 layouts, draws, hosted
views and layers, allocations, CPU instructions retired) repeat exactly or
within about 0.3 % on a busy host.

```text
every push (T0, ~2-4 min, busy host OK) -> per PR (T1, ~10-15 min, busy host OK) -> checkpoints (T2, quiet host)
work probe in unit tests                    demo-app scroll with counters + idle CPU    Scripts/perf-gate.sh frame statistics
```

| Tier | When | Command | Fails on |
|---|---|---|---|
| **T0 work probe** | every push (no-mistakes test step, see `.no-mistakes.yaml`) | `Scripts/perf-probe.sh <base> [<candidate>]` | a work count changed without explanation; instructions or mallocs ≥ +5 % vs a same-session base (+2-5 % warns); a TK2 ÷ SwiftUI instruction ratio over its budget |
| **T1 scroll counters** | every PR that touches rendering, row lifecycle, scrolling or the demo app | `Scripts/perf-scroll-counters.sh <base> <candidate\|.>` | rows materialised, legs or TK2 layouts move more than ±1 % vs base; work during the 5 s idle after the scroll over budget (livelock shape) |
| **T2 frame statistics** | only: once per stack, before TextKit 2 is turned on by default, before a TestFlight upload, or when T0/T1 flags a cost rise whose user-visible impact must be sized | `Scripts/perf-gate.sh` (short-sample designs) plus Instruments, on a quiet host | the existing bounds in `Scripts/perf-bounds.json` |

T2 is no longer a per-PR step. A PR that touches rendering runs T0 and T1,
records both tables in its description, and runs T2 only for one of the
reasons in the table. The AGENTS.md perf gates for row-lifecycle changes
(manual fling CPU settle, scene-snapshot thrash, idle soak) still apply to
the changes they name.

## T0: work probe

Two Swift Testing suites, skipped unless `PERF_PROBE=1` or `PERF_PROBE_OUT`
is set, so ordinary test runs do not pay for them:

- **Render tier**, `Tests/ADFRenderingTests/Perf/PerfProbeTests.swift`, iOS
  simulator. Fixed fixture slices (list-dense first 100 root lists,
  kitchen-sink, stress-1k first 100 roots, giant-table first 40 rows, 40
  code blocks, 60 panels/expands/quotes) are hosted in a non-lazy `VStack` in a 390-pt
  window, laid out and rendered once. Both renderers run in the same
  process: one warm-up rep, then interleaved measured reps.
- **Parse tier**, `Tests/ADFPreparationTests/Perf/ParsePreparePerfTests.swift`,
  macOS `swift test`. `ADFParser.parse` + `DocumentPreparer.prepare` on every
  fixture.

Each suite prints one JSON line per fixture × renderer (prefix
`PERF_PROBE `): counts (`tk2.layoutCount`, `tk2.drawCount`, `tk2_rows`,
`uiviews`, `calayers`, the sizing counters below), instructions retired
(`proc_pid_rusage` `ri_instructions`; median, min, max, CV), mallocs, and
CPU/wall time as diagnostics only. CPU time and wall time are not gated: on
a busy host they vary up to 77 % for the same instruction count.

Product counters used by the probe live in `ADFTextKit2Stats`
(`Sources/ADFRendering/TextKit2/TextKit2Diagnostics.swift`):
`sizeThatFitsCount`, `infiniteWidthProposalCount`,
`unspecifiedWidthProposalCount` and `applyCount`, next to the existing
layout, draw and live-row counts.

`Scripts/perf-probe.sh <base> [<candidate>]` exports each ref with
`git archive` (the candidate defaults to the working tree), overlays the
probe suite and any fixture a ref lacks, builds incrementally per ref, runs
one throwaway pass after simulator boot, then compares and writes a
markdown table. Rules (`Scripts/perf-probe-budgets.json`):

- **Counts** must match the base exactly. A change is `CHANGED`: explain it
  in the PR (an intended layout or view-tree change) or treat it as a
  regression.
- **Instructions and mallocs**: WARN at +2-5 %, FAIL at ≥ +5 % vs the
  same-session base. A line whose calibrated cross-process noise is higher
  gets max(2 %, noise) / max(5 %, 2 × noise); today only code-SwiftUI
  (2.3 %) and containers-TK2 (2.1 %) are raised. Rep CV over 1 % is
  flagged `NOISY` (informational; the containers slice usually is).
- **TK2 ÷ SwiftUI instruction ratio** per fixture, against budgets
  calibrated from 10 main passes (max × 1.02; `--calibrate 10 main
  --write-budgets`, about 8 min). Current budgets: list-dense 1.216,
  stress-1k 1.291, kitchen-sink 1.128, code 1.188, giant-table 1.027,
  containers 1.026. Recalibrate when main's renderer work changes on
  purpose (for example when issue 10 is fixed, list-dense drops).
- **TK2 layouts per TK2 row** is reported; values above 1 are the issue 10
  double layout.

Exit codes: 0 PASS/WARN/CHANGED, 1 FAIL, 2 usage or infrastructure error.

Measured on this Mac (busy host; Debug, 5 reps, warm-up pass on):

| Comparison | Verdict | Wall time |
|---|---|---|
| main vs main | PASS, largest Δ 1.17 % | 114 s (119 s before calibration) |
| main vs this branch's working tree | PASS, largest Δ 0.69 %; only the four new counters differ (candidate only) | 112 s |
| 86abd56 (pr1) vs a76736f (pr2, issue 10) | **FAIL**: list-dense TK2 +24.2 %, stress-1k TK2 +18.6 %, kitchen-sink TK2 +5.4 % instructions; mallocs +34 % / +28 % / +6 %; 2.0 TK2 layouts per row | 140 s (30 s of it waiting on another perf process) |

A render pass takes 35-40 s on a warm simulator below host load 15, and
70-145 s at load 30-110; the parse tier takes about 12 s. Counts never
varied between reps or passes.

## T1: scroll counters

The demo app scrolls a fixture fast and counts work instead of frames.
Launch arguments (documented in `Demo/ADFReader/ADFReaderApp.swift`):
`-autoscrollSpeed <pt/s>` (default 1,200, the gate's speed),
`-scrollCounters` and `-idleSeconds <s>` (default 5). With
`-scrollCounters` the app prints one `SCROLL_COUNTERS` line after the idle
window: rows that entered or left the lazy region
(`ADFRowLifecycle` in `Sources/ADFRendering/RowLifecycleDiagnostics.swift`),
live, in-window and off-window TK2 rows, instructions and CPU during the
scroll, and instructions, row churn and TK2 layouts during the idle window.
A livelock spins the main thread during the idle window; a healthy build
does almost nothing there. `RENDERER_STATS` is unchanged, and
`Scripts/perf_trial.py` adds the new fields as extra CSV columns.

`Scripts/perf-scroll-counters.sh <base> <candidate|.>` builds both arms,
runs one throwaway launch, then 1 trial per fixture × renderer per arm
(no warm-up discard, no 300 s settle, no host-load wait), and compares
against `Scripts/perf-scroll-counters.json`.

Defaults: fixtures kitchen-sink, list-dense and stress-1k, both renderers,
6,000 pt/s (list-dense scrolls in about 24 s instead of 116 s), 5 s idle.
Budgets (`Scripts/perf-scroll-counters.json`, calibrated on main from 48
trials at 6,000 pt/s):

- **Counts**: legs, rows in region, live and off-window TK2 rows, and TK2
  layouts matched exactly in every calibration trial; row appear/disappear
  moved by ±1 row, so the slack is 1 row. The TK2 size-query counters
  follow frame timing (up to 2.1 %), so they get a 5 % tolerance.
- **Idle window**: at most 8 M instructions/s (calibration max 2.68 M/s,
  median 0.74 M/s); no row churn and no TK2 layouts.
- **Scroll instructions**: warn only, at +5 % (+10 % on kitchen-sink, whose
  0.5 s scroll spreads up to 7.2 %). In-app instructions move with how many
  frames the host renders, so they cannot fail a PR.
- A candidate that hangs, crashes or never finishes the scroll while the
  base finishes is a FAIL.

Exit codes: 0 PASS/WARN, 1 FAIL, 2 invalid run or refused.

Measured on this Mac (busy host): main vs the working tree took 381 s
including two Release builds (25 s each) and 12 trials (324 s), PASS. Three
main-vs-main runs took 332-335 s each, all PASS. Two hand-made livelocks
both FAIL. In the first, rows toggle their own height and the scroll never
finishes. In the second, the same loop starts only after the scroll; scroll
counts are unchanged, but idle work rises to 30-32 M instructions/s, 12-18×
the base.

## T2: frame statistics

Unchanged: `Scripts/perf-gate.sh`, `Scripts/perf_summarize.py`,
`Scripts/perf-bounds.json`. Run it on a quiet host, only at the checkpoints
in the table above. Its job is to size user-visible frame impact, not to
detect that work changed.

## Shared-Mac rules for all tiers

- Use one simulator of your own (`--udid`, or let the script create and
  delete one). Never use another lane's simulator or the captain's
  "ADF Play (captain)" simulator.
- T0 and T1 wait while another lane's `perf-gate.sh` / `perf_trial.py`
  run is in progress (`--allow-busy` / `--force` overrides). A quiet T2
  run on the Mac must not overlap your builds.
