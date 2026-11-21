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
`sizeThatFitsCount`, `infiniteWidthProposalCount` and `applyCount`, next
to the existing layout, draw and live-row counts.

`Scripts/perf-probe.sh <base> [<candidate>]` exports each ref with
`git archive` (the candidate defaults to the working tree), overlays the
probe suite and any fixture a ref lacks, builds incrementally per ref, runs
one throwaway pass after simulator boot, then compares and writes a
markdown table. Both refs must contain TextKit 2 PR 2's renderer routing
(`TextKit2Scope.inheritsRenderer`, any ref from a76736f on); the suite calls
it directly, so an older ref fails to build. One run at a time uses the
scratch root (`<root>/lock`); a second run waits for it. Rules
(`Scripts/perf-probe-budgets.json`):

- **Counts** must match the base exactly. A change is `CHANGED`: explain it
  in the PR (an intended layout or view-tree change) or treat it as a
  regression.
- **Changed fixture**: when the measured bytes differ between base and
  candidate (`FIXTURE-DIFFERS`; render tier: the slice, parse tier: the whole
  file), the two sides measure different documents. An edit outside a
  render slice leaves that slice comparable.
  Its rows are at most `CHANGED` and its ratio at most WARN, never FAIL.
- **Instructions and mallocs**: WARN at +2-5 %, FAIL at ≥ +5 % vs the
  same-session base. A line whose calibrated cross-process noise is higher
  gets max(2 %, noise) / max(5 %, 2 × noise); today only containers-SwiftUI
  (3.2 %), containers-TK2 (2.1 %) and parse youtube (10.3 %) are raised.
  An instruction rise counts only when the cheapest rep rose too: on a
  loaded host some reps do extra main-thread work on both sides (code
  slice: two of five reps at +45 %), which can lift a median but not the
  minimum. Such a line shows the smaller `min Δ` next to its verdict. Rep CV over 1 % is
  flagged `NOISY` (informational; the containers slice usually is).
- **TK2 ÷ SwiftUI instruction ratio** per fixture (the ratio of the
  minimum reps of both arms, so disturbed reps in either arm on a busy
  host do not move it), against budgets
  calibrated from 10 main passes (max × 1.02; `--calibrate 10 main
  --write-budgets`, about 8 min). Current budgets (2026-11-20, main
  bdd029f, iPhone 17 Pro on iOS 26.3, min-rep TK2 ÷ SwiftUI instruction
  ratio): list-dense 1.232, stress-1k 1.296, kitchen-sink 1.194, code
  1.195, giant-table 1.032, containers 1.231. A candidate over its budget
  fails when the base is within it, or when the candidate ratio is more
  than 2 % (`ratio_rise_fail_pct`) above the base ratio. When the base is
  over the budget too (a runtime or Xcode update, or a change already on main), it
  is a WARN that asks for recalibration. Recalibrate when main's renderer
  work changes on purpose (for example when issue 10 is fixed, list-dense
  drops).
- **TK2 layouts per TK2 row** is reported; values above 1 are the issue 10
  double layout.

Exit codes: 0 PASS/WARN/CHANGED or SKIPPED, 1 FAIL, 2 usage or infrastructure error.

In the push gate (`.no-mistakes.yaml`, `--busy-wait 300 --skip-when-busy`)
a busy host never fails or blocks the push for long: when another lane's
`perf-gate.sh` / `perf_trial.py` run, or another T0 run, is still active
after 5 minutes in total, T0 prints `T0 work probe SKIPPED` with the
command to run it by hand later, and exits 0. Run by hand, the defaults
stay: wait up to 30 minutes (`--busy-wait`), then exit 2.

T0 builds this checkout's `Perf/` suites against the base tree too. When
they do not compile there (a refactor renamed an internal the suite uses),
there is nothing to compare: T0 prints `T0 work probe SKIPPED: base <sha>
cannot build the current probe suite (<first compiler error>)` and exits 0,
in the push gate and by hand. Any other build error still exits 2.

Measured on this Mac (busy host; Debug, 5 reps, warm-up pass on):

| Comparison | Verdict | Wall time |
|---|---|---|
| main vs main | PASS, largest Δ 1.17 % | 114 s (119 s before calibration) |
| main vs this branch's working tree | PASS, largest Δ 0.69 %; only the four new counters differ (candidate only) | 112 s |
| 86abd56 (pr1) vs a76736f (pr2, issue 10) | **FAIL**: list-dense TK2 +24.2 %, stress-1k TK2 +18.6 %, kitchen-sink TK2 +5.4 % instructions; mallocs +34 % / +28 % / +6 %; 2.0 TK2 layouts per row | 140 s (30 s of it waiting on another perf process) |

The issue 10 row is recorded evidence: it was measured with a pre-PR 2
routing shim that has since been removed, so the probe can no longer
build 86abd56.

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
against `Scripts/perf-scroll-counters.json`. Both refs must contain the T1
instrumentation added with this change
(`Demo/ADFReader/ScrollCounters.swift`); an older ref is refused (exit 2).
A fixture the base lacks is copied from the candidate.

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
- T0 waits while another lane's `perf-gate.sh` / `perf_trial.py` run is in
  progress (`--busy-wait`, default 1800 s, then exit 2; in the push gate
  300 s, then skip; `--allow-busy` overrides). Only a process that runs the
  script counts; one whose command line merely mentions it (an editor,
  `git log`, an agent's prompt) does not. `perf_trial.py` run by this
  checkout's own T1 does not count.
- T1 refuses to start (exit 2) while another `perf-gate.sh`,
  `perf_trial.py`, `lifecycle-gate.sh` or `perf-scroll-counters.sh` run is
  in progress, unless given `--wait-others <s>` (wait up to that long) or
  `--force` (run anyway).
- A quiet T2 run on the Mac must not overlap your builds.
