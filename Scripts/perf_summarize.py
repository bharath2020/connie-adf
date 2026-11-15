#!/usr/bin/env python3
"""Fail-closed verdicts for Scripts/perf-gate.sh runs (plan §6.1–§6.3).

USAGE
    # per-PR gate (design pr45, ~45 min: A = main, B = branch switch OFF,
    # C = branch -textkit2; 3 pairs; no calibration):
    python3 -I Scripts/perf_summarize.py <out>/trials.csv [--json summary.json]
    # full gate (design full, ~8 h, once before the final parity PR):
    python3 -I Scripts/perf_summarize.py <cal>/trials.csv --calibrate \\
        --write-calibration <cal>/calibration.json [--attempt 1]
    python3 -I Scripts/perf_summarize.py <out>/trials.csv \\
        --calibration <cal>/calibration.json [--json summary.json]
    # pilot (plan.pilot = true; never PASS) and deadline suggestion:
    python3 -I Scripts/perf_summarize.py <pilot>/trials.csv --pilot [--suggest-timeouts]
    # what a design declares (perf-gate.sh reads its defaults from here):
    python3 -I Scripts/perf_summarize.py --print-design pr45|pr2|pr3|full
    # resolution bounds from an A–A′ run of untouched main (BOUNDS below):
    python3 -I Scripts/perf_summarize.py <cal>/trials.csv --measure-bounds \
        --write-bounds Scripts/perf-bounds.json
    # add a newly measured fixture's bounds to the frozen file (never
    # replaces an entry; records the fixture's own reference build):
    python3 -I Scripts/perf_summarize.py --merge-bounds <cal>/bounds.json \
        [--bounds Scripts/perf-bounds.json] [--write-bounds <out>]

    The run's plan.json (written by perf-gate.sh next to trials.csv; or
    --plan) declares the design, fixtures, runs, warm-ups, host state at
    start and, per arm, the app sha256, the required/forbidden launch flags
    and whether the arm must report completion fields and renderer stats.
    Nothing outside the plan is assumed, and the plan, not a command-line
    flag, says whether a run is a pilot (--pilot must agree with it).

DESIGNS (DESIGNS below; a run that declares less is INCOMPLETE, never PASS)
    Each design names its fixtures and, per fixture, the arms it runs; the
    plan records the same as fixture_arms, so a design's shape is
    configuration (perf-gate.sh reads it with --print-design).
    pr45  kitchen-sink, stress-1k, giant-table, each × arms A, B, C × 3
          pairs, >= 1 discarded warm-up per (fixture, arm), sampler and
          footprint on, B/C completion and renderer markers on. Rule
          "median-relative". About 40 min including boot and a 5-min settle.
    pr2   lists stage (PR 2): pr45's three fixtures plus list-dense, each ×
          A, B, C × 3 pairs, 1 warm-up, rule and thresholds as pr45 (one
          named cumulative design, never a separately combined verdict:
          Fable F2). On top of pr45: list-dense needs the list-native proof
          (list_proof), arm A must report SCROLL_METRICS completion
          (baseline_completion: main >= 86abd56 prints endRow/completed),
          the plan must record every arm's bundled fixture JSON sha256 and
          they must agree (fixture_hashes), and a FAIL under pr45 for the
          same candidate binaries refuses a pr2 run (includes). About 75–80
          min plus the quiet-host wait. list-dense has no measured READY
          bound until one is merged (advisory until then) and its trial
          timeout is frozen in perf-gate.sh after the pilot.
    pr3   code-block stage (PR 3): pr2's four fixtures plus code-dense, each
          × A, B, C × 3 pairs, 1 warm-up, rule and thresholds as pr2 (one
          named cumulative design; it includes pr45 and pr2, each named:
          includes is not transitive). On top of pr2: code-dense needs the
          code-native proof (code_proof, CODE PROOF below); rows that failed
          in PR 2's final shipped result are annotated and still fail
          (known_debt, KNOWN DEBT below); and the paired predecessor
          supplement D vs C is enforced (predecessor, PREDECESSOR below).
          code-dense has no measured READY bound until one is merged and
          its trial timeout stays UNFROZEN in perf-gate.sh until its pilot.
          About 85–110 min for the 60 A/B/C trials plus about 40 min for the
          D/C block, plus the quiet-host wait.
    full  kitchen-sink, stress-5k, giant-table × A, B, C × >= 10 pairs,
          frozen A–A′ calibration. Rule "calibrated-ucb". About 8 h.
    Reduced (INCOMPLETE, exit 5): a declared fixture, an arm of a fixture or
    pairs missing, sampler or footprint off, B/C markers off, A's
    completion markers off where the design requires them, the design's
    predecessor supplement missing or invalid.

VALIDITY (fail closed) — every declared (fixture, arm) has exactly one row
    per run 1..runs; each row: status ok, launch_exit 0, installed and app
    sha256 equal the plan's, argv carries the arm's required flags and none
    of its forbidden ones, READY names the fixture, blocks > 0 and equal
    across every arm/run of the fixture (and to expected_blocks if
    declared), frames > 0, dropped <= frames, every required metric present,
    finite and >= 0, memory samples > 0, and (non-pilot) the host's 1-min
    load recorded for the trial. Candidate (B/C) rows also need
    SCROLL_METRICS completed=1 with endRow = blocks − 1 and frames within
    ±15 % of A's median (traversal), and the RENDERER_STATS proof on the
    final line: C renderer=textkit2 on both lines, tk2Layouts > 0 and
    tk2NativeDraws > 0; B renderer=swiftui, tk2Layouts = tk2Live =
    tk2NativeDraws = tk1BackedDraws = 0. A non-pilot plan must record the
    host check at start.
    LIST PROOF (a fixture named in any design's list_proof, e.g. list-dense;
    columns from perf_trial.py STATS_FIELDS): C needs tk2_list_live > 0 at
    READY or at the end (live TextKit 2 rows owned by list text: a
    heading/paragraph native-draw total is not list proof), the leaf
    coverage columns present, list leaves in scope and at least one
    eligible list leaf (eligible_text_leaves − eligible_roots > 0, else
    every list leaf falls back to SwiftUI); B needs tk2_list_live = 0 on
    both lines (a B row that reports it on any fixture must report 0).
    CODE PROOF (a fixture named in any design's code_proof, e.g. code-dense):
    C needs tk2_code_live > 0 at READY or at the end (live TextKit 2 rows
    owned by a top-level code block), tk2_code_draws > 0 (TextKit 2 drew
    code glyphs natively), the code coverage columns present, code roots in
    scope (eligible_code_roots + fallback_code_roots > 0), at least one
    statically eligible code root and at least one admitted at the run's
    actual environment (code_admitted > 0; else every code root falls back
    to SwiftUI), and code_admitted + code_gated = eligible_code_roots (the
    app's own identity); B needs tk2_code_live = 0 on both lines and
    tk2_code_draws = 0 (a B row that reports them on any fixture must
    report 0). The summary reports the measured admitted / gated share of
    the run configuration separately from the static eligible count.
    FIXTURE BYTES: where the plan records arms.<arm>.fixture_sha256
    (perf-gate.sh preflight; required by fixture_hashes designs), every arm
    of a fixture must bundle the same JSON and each trial's installed copy
    (installed_fixture_sha256) must match. A reference arm that requires
    completion (baseline_completion) is held to the same endRow rule; its
    truncated scroll is a baseline failure (INVALID), a candidate's is FAIL.

CEILINGS (both designs, every counted trial) — hitch > 10 ms/s; dropped
    rate > 1 % on a trial with >= 2,000 frames; > 3 dropped frames on a
    trial with fewer. A candidate breach FAILs; a breach by A in the same
    run makes it INVALID (environment; one predeclared rerun).

RULE pr45 ("median-relative") — per fixture, candidate arm (B and C) and
    metric, paired deltas d_i = X_i − A_i over the 3 runs; r = median(d_i) /
    median(A). FAIL if r > 15 % for memory (RSS and footprint at READY and
    peak) and first chunk (unless median d <= 20 ms). launch→READY is gated
    only on a fixture whose measured resolution bound is within the limit
    (BOUNDS below); elsewhere it is ADVISORY (reported, never gating).
    Dropped frames: FAIL if median d > 2 frames.

BOUNDS (Scripts/perf-bounds.json, written by --measure-bounds from an A–A′
    run of untouched main) — per fixture and metric, the 95th percentile of
    |median of 3 A–A′ deltas| over every triple of pairs: the smallest shift
    three pairs tell apart from noise. 2026-10-26 noise run (10 pairs, 120
    triples): READY kitchen-sink 11 %, stress-5k 22 %, giant-table 42 %;
    first chunk 11–20 % (8–11 ms); memory 0.5–10 %. A metric in
    BOUND_GATED_METRICS (launch→READY) gates a fixture only when its bound
    is <= 15 % (or <= the metric's absolute floor); a fixture with no
    measured bound (stress-1k, list-dense until merged) is advisory. The
    plan records the bounds sha256 and the gated fixtures when the run
    starts; a later change makes the run INVALID. The file's app_sha256
    (and fixture_sources.<f>.app_sha256 for a merged fixture) is
    provenance only: no gate compares it with arm A, because bounds
    describe a fixture's noise on main, and every reference build since has
    had a different executable digest (a resource-only rebuild changes it).
    --merge-bounds adds a measured fixture without touching the existing
    entries and refuses to replace one. So the gate catches a >= 15 % memory, first-chunk or
    kitchen-sink READY regression and any stall or sustained drop over the
    ceilings; it misses smaller shifts, about half of true 15 % shifts on
    the noisiest memory metric, rare stalls that land in none of 3 trials,
    and READY regressions under about 25 % (stress) or 45 % (giant-table).

RULE full ("calibrated-ucb") — calibration (--calibrate), per fixture and
    metric: d_i = A2_i − A_i; allowance = max(max|d_i|, floor). Floors:
    launch_to_ready 50 ms, first_chunk 20 ms, dropped_frames 2, dropped_rate
    0.5 %-points, hitch 0.10 ms/s, memory 2,048 KB. Noise ceiling: max|d_i|
    > 15 % of A's median (latency, memory) or > 10 frames (dropped_frames)
    -> INCONCLUSIVE, only when max|d_i| also exceeds the floor. The gate:
    d_i = X_i − A_i, n >= 10; UCB95 = mean(d) + t(0.95, n−1)·sd(d)/√n;
    PASS iff UCB95 <= allowance. The calibration must be frozen (sha256 in
    the plan) and created before the first counted trial started.

KNOWN DEBT (design key known_debt; an annotation, never an allowance) —
    rows {fixture, arm, metric, rule, source} that failed in an earlier
    stage's final shipped result and were accepted as debt (pr3: the
    TextKit 2 ON list rows of PR 2's final run, issue 10). A listed row
    that fails is labelled as known debt and STILL FAILS: thresholds,
    precedence, the verdict line, the exit code and the ledger are
    unchanged, and no verdict "excluding" these rows exists. A listed row
    that passes is reported as improved. The label is withheld wherever the
    row's cell (that arm or the reference on that fixture) or the run has a
    problem: it never covers a missing proof, invalid provenance, a missing
    trial, a baseline failure, a crash or a timeout. A design is refused
    (--print-design exits 2; a summary is INVALID) when an entry names a
    fixture that is not a fixture of an included earlier design (never the
    stage's own fixture, e.g. code-dense), an arm other than C, or a
    metric/rule pair the design does not compute, or lacks its source.

PREDECESSOR (design key predecessor; supplemental, never the verdict) — an
    enforced paired comparison of binary D (the previous stage's final tip
    with TextKit 2 ON; pr3: PR 2's gated build, its sha256 pinned in the
    design) against C on the design's predecessor fixtures (pr3: list-dense
    and kitchen-sink). perf-gate.sh --app-d runs it inside the named run:
    one warm-up per (fixture, arm), then interleaved, balanced D,C / C,D
    pairs; rows in predecessor.csv, warm-ups in predecessor-warmup.csv, the
    declaration in plan.json under "predecessor". D never substitutes for
    A: D is never a plan arm, and a reference arm with the pinned
    predecessor sha256 is INVALID. The method is frozen here, before any
    candidate timing. Per fixture and metric (dropped frames, dropped rate,
    hitch ratio): d_i = C_i − D_i over the pairs; sensitivity = the gate's
    own dropped-frame scale, +2 frames (for the rate and the hitch ratio
    the same 2 frames converted with D's median frame count: 200 / frames
    %-points and 2,000 / frames ms/s); [L, U] = the one-sided 95 %
    distribution-free bounds on the median paired difference (order
    statistics d_(n+1−u) and d_(u), u the smallest rank with
    P(Bin(n, 1/2) >= u) <= 0.05; with n = 5 the smallest and the largest
    difference; below 5 pairs no bound exists):
        U <= sensitivity  -> NO-ADDED-REGRESSION
        L >  sensitivity  -> ADDED-REGRESSION
        otherwise         -> INCONCLUSIVE (the pairs cannot resolve the
                             sensitivity; never "unchanged")
    No noise allowance enters (not the bounds file, a calibration or an
    A–A′ spread): a plan that records another sensitivity or an allowance
    is INVALID, a design that declares one is refused. Each row also counts
    the D and C trials over the per-trial ceilings. Work counters (layouts,
    conversions, draws, live rows) are structural diagnostics, never gated
    for equality. The supplement is INVALID (no result) on any problem in
    its trials or declaration: no D, a missing trial, pair or warm-up, an
    unsuccessful warm-up (one counts only when its row shows the arm's
    binary, fixture bytes and flags, a launch to READY with exit 0, the
    renderer proof the arm needs and, where the arm is held to completion,
    a scroll to the last block; its measurements are never read), an
    installed or pinned sha256 mismatch, D = C or D = A, fixture bytes that
    differ between D and C (or from the gate's), unbalanced order. Its
    results never change the A/B/C verdict; a MISSING or INVALID supplement
    makes the design reduced (INCOMPLETE instead of PASS; a FAIL, INVALID
    or PILOT verdict stays what it is). The OVERALL line (and the stderr
    verdict line, and summary.json "predecessor_outcome") names the
    supplement's outcome beside the verdict: its status when it has no
    result, else every ADDED-REGRESSION and INCONCLUSIVE row by fixture,
    or NO-ADDED-REGRESSION. The gated binary C failing a counted
    supplement trial is not a result but the gate's own candidate failure
    (PRECEDENCE 1 and 3, so FAIL, and the ledger): a crash, or a timeout,
    no READY or incomplete scroll on a row attributable to C. D's failures,
    warm-ups (as the gate's own) and rows that are not C's stay the
    supplement's.

HOST (firstmate policy, 2026-10-26) — quiet = 1-min load <= 4.0 and no
    non-simulator process above 100 % CPU. perf-gate.sh waits up to 20 min
    for a quiet host, then runs anyway; the plan records the start sample
    and the wait, every row its load and busiest processes. A run whose
    start or any counted trial was not quiet is HOST-BUSY: its PASS counts;
    its FAIL is reported as FAIL-HOST-BUSY (exit 6) and is re-run once at
    the next quiet window before it counts. Nothing is ever killed.

PRECEDENCE
      1. a candidate crash on a provenance-clean row (a D/C
         supplement trial of C included)                     -> FAIL
      2. any baseline failure, validity problem or A
         ceiling breach                                      -> INVALID
      3. a candidate timeout / no READY / incomplete scroll
         (a D/C supplement trial of C included)              -> FAIL
      4. (full) calibration INCONCLUSIVE                      -> INCONCLUSIVE
      5. a rule or ceiling FAIL                               -> FAIL
      6. plan.pilot                                           -> PILOT
      7. a reduced design                                     -> INCOMPLETE
      8. otherwise                                            -> PASS
    then a FAIL on a HOST-BUSY run                            -> FAIL-HOST-BUSY

RERUN LEDGER — every verdict is appended to perf-ledger.jsonl in the run
    directory's parent (or --ledger). A candidate whose sha256s already
    FAILed under the same design is REFUSED (a FAIL is never rerun to green
    without a code change). A FAIL-HOST-BUSY allows one rerun: a second
    FAIL-HOST-BUSY for the same binaries counts as FAIL. After one
    INCONCLUSIVE or INVALID, one rerun is allowed, a second is REFUSED.
    Re-summarising the same run directory is not a rerun. Pilot,
    INCOMPLETE and PASS entries do not count. A design that includes
    another (pr2 includes pr45; pr3 includes pr45 and pr2) is also REFUSED
    after a FAIL of the included design for the same candidate binaries: it
    re-measures those fixtures, so a PASS would rerun that FAIL to green.
    Known-debt annotations and the predecessor supplement's results never
    enter the ledger: a FAIL made only of annotated rows is a FAIL there
    too, and so is a FAIL made by C failing a supplement trial.

LABELS — launch_to_ready_ms is "preparation readiness" (READY: model
    prepared), not first visible content; rss_peak_kb is a sampled peak;
    footprint_peak_kb is the kernel's phys_footprint_peak as of the last
    sample; trials are fresh-install, warmed-system (uninstall resets
    preferences, not OS/font caches). Every summary discloses the
    TextKit 1-backed share of the C arm per fixture (link roots of the
    eligible roots; TextKit 1 draws of all TK2-row draws), and, for a
    build that reports code coverage, the static code roots (eligible /
    SwiftUI fallback) and the measured admitted / gated code roots.

EXIT  0 PASS / CALIBRATED, 1 FAIL, 2 INVALID (or REFUSED, or bad input),
      3 INCONCLUSIVE, 4 PILOT, 5 INCOMPLETE (reduced design; never a PASS),
      6 FAIL-HOST-BUSY (re-run once when the host is quiet).

Standard library only; run with `python3 -I`.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import itertools
import json
import math
import os
import statistics
import sys
from datetime import datetime, timezone

EXIT = {"PASS": 0, "CALIBRATED": 0, "MEASURED": 0, "FAIL": 1, "INVALID": 2, "REFUSED": 2, "INCONCLUSIVE": 3,
        "PILOT": 4, "INCOMPLETE": 5, "FAIL-HOST-BUSY": 6}

LATENCY = ["launch_to_ready_ms", "first_chunk_ms"]
FRAMES = ["dropped_frames", "dropped_rate_pct", "hitch_ms_per_s"]
MEMORY = ["rss_ready_kb", "rss_peak_kb", "footprint_ready_kb", "footprint_peak_kb"]
FLOORS = {
    "launch_to_ready_ms": 50.0,
    "first_chunk_ms": 20.0,
    "dropped_frames": 2.0,
    "dropped_rate_pct": 0.5,
    "hitch_ms_per_s": 0.10,
    "rss_ready_kb": 2048.0,
    "rss_peak_kb": 2048.0,
    "footprint_ready_kb": 2048.0,
    "footprint_peak_kb": 2048.0,
}
UNITS = {"launch_to_ready_ms": "ms", "first_chunk_ms": "ms", "dropped_frames": "frames",
         "dropped_rate_pct": "%", "hitch_ms_per_s": "ms/s"}
LABELS = {
    "launch_to_ready_ms": "launch→READY (preparation readiness)",
    "first_chunk_ms": "first chunk",
    "dropped_frames": "dropped frames",
    "dropped_rate_pct": "dropped rate",
    "hitch_ms_per_s": "hitch ratio",
    "rss_ready_kb": "RSS at READY",
    "rss_peak_kb": "RSS sampled peak",
    "footprint_ready_kb": "footprint at READY",
    "footprint_peak_kb": "footprint peak (kernel)",
}
CEILING_PCT = 15.0
CEILING_DROPPED = 10.0
MIN_PAIRS = 10
PILOT_PAIRS = 2

# The declared designs: fixture -> the arms it runs. perf-gate.sh takes its
# defaults from here (--print-design); a plan that declares less than its
# design is INCOMPLETE.
ALL_ARMS = ["A", "B", "C"]
DESIGNS = {
    "pr45": {"title": "per-PR gate (~45 min)",
             "fixtures": {"kitchen-sink": ALL_ARMS, "stress-1k": ALL_ARMS, "giant-table": ALL_ARMS},
             "runs": 3, "warmup": 1, "rule": "median-relative"},
    # Lists stage (PR 2, Fable F2/F7): pr45 + list-dense, same arms, pairs,
    # warm-up and rule. Optional keys (absent = off):
    #   list_proof           fixtures whose C rows must prove live TextKit 2
    #                        list rows and whose B rows must report none
    #   baseline_completion  the reference arm must report SCROLL_METRICS
    #                        completion (endRow = blocks − 1)
    #   fixture_hashes       the plan must record each arm's bundled fixture
    #                        JSON sha256 (perf-gate.sh preflight)
    #   includes             designs whose FAILs (same candidate binaries)
    #                        refuse this design in the ledger
    #   code_proof           fixtures whose C rows must prove live, natively
    #                        drawn TextKit 2 code rows and whose B rows must
    #                        report none (pr3, added below)
    #   known_debt           annotated rows of an earlier stage's accepted
    #                        failures (KNOWN DEBT; pr3)
    #   predecessor          the enforced paired D vs C supplement
    #                        (PREDECESSOR; pr3)
    "pr2": {"title": "per-PR gate, lists stage (~75–80 min)",
            "fixtures": {"kitchen-sink": ALL_ARMS, "stress-1k": ALL_ARMS, "giant-table": ALL_ARMS,
                         "list-dense": ALL_ARMS},
            "runs": 3, "warmup": 1, "rule": "median-relative",
            "list_proof": ["list-dense"], "baseline_completion": True, "fixture_hashes": True,
            "includes": ["pr45"]},
    "full": {"title": "full gate (~8 h, before the final parity PR)",
             "fixtures": {"kitchen-sink": ALL_ARMS, "stress-5k": ALL_ARMS, "giant-table": ALL_ARMS},
             "runs": MIN_PAIRS, "warmup": 1, "rule": "calibrated-ucb"},
}


def list_proof_fixtures() -> set[str]:
    """Fixtures that need the list-native proof in every run that carries
    renderer markers (a pilot of list-dense included), from all designs."""
    return {f for d in DESIGNS.values() for f in d.get("list_proof", [])}


def code_proof_fixtures() -> set[str]:
    """Fixtures that need the code-native proof in every run that carries
    renderer markers (a pilot of code-dense included), from all designs."""
    return {f for d in DESIGNS.values() for f in d.get("code_proof", [])}

# Rule pr45 ("median-relative").
REL_LIMIT_PCT = 15.0
REL_ABS_FLOORS = {"first_chunk_ms": 20.0}
DROPPED_DELTA_MAX = 2.0

# Resolution bounds (BOUNDS): metrics gated per fixture only where measured
# noise lets three pairs resolve the limit.
BOUNDS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "perf-bounds.json")
BOUND_GATED_METRICS = ["launch_to_ready_ms"]
BOUND_PAIRS = 3
BOUND_PERCENTILE = 95.0

# Absolute per-trial ceilings (Fable M1), both designs.
CEILING_HITCH_MS_PER_S = 10.0
CEILING_DROPPED_RATE_PCT = 1.0
CEILING_DROPPED_SMALL = 3.0
SMALL_TRIAL_FRAMES = 2000.0

# Traversal (Fable S5): candidate frames within ±15 % of A's median.
TRAVERSAL_FRAMES_PCT = 15.0

# Known debt (KNOWN DEBT): the rule name of a per-trial ceiling row, the
# metrics the ceilings read, and the only arm an annotation may name.
CEILING_RULE = "ceiling"
CEILING_METRICS = ["hitch_ms_per_s", "dropped_rate_pct", "dropped_frames"]
DEBT_ARM = "C"
DEBT_KEYS = ("fixture", "arm", "metric", "rule", "source")

# Paired predecessor supplement (PREDECESSOR). The sensitivity is the gate's
# own dropped-frame scale and nothing else; the confidence is one-sided.
PRED_ARM = "D"
PRED_AGAINST = "C"
PRED_ALPHA = 0.05
PRED_SENSITIVITY_FRAMES = DROPPED_DELTA_MAX
PRED_METRICS = ["dropped_frames", "dropped_rate_pct", "hitch_ms_per_s"]
# The fewest pairs for which a one-sided (1 − PRED_ALPHA) order-statistic
# bound on a median exists: 2^-n <= alpha.
PRED_MIN_PAIRS = next(n for n in range(1, 64) if 0.5 ** n <= PRED_ALPHA)
PRED_RESULTS = ("NO-ADDED-REGRESSION", "ADDED-REGRESSION", "INCONCLUSIVE")
PRED_DESIGN_KEYS = {"arm", "against", "label", "fixtures", "runs", "warmup", "sensitivity_dropped_frames",
                    "app_sha256", "source"}
PRED_PLAN_KEYS = {"arm", "against", "label", "fixtures", "runs", "warmup", "sensitivity_dropped_frames", "arms",
                  "csv", "warmup_csv"}
PRED_CSV = "predecessor.csv"
PRED_WARMUP_CSV = "predecessor-warmup.csv"

# Code-block stage (PR 3; Astra findings 2, 5, 7 on the code-block plan).
# The debt rows are the rows that failed in PR 2's final shipped summary,
# copied from it line by line; the predecessor D is the binary that summary
# measured (the app sources of PR 2's final tip 0910835 equal a76736f's: only
# docs, scripts and one UI test changed after it).
PR2_FINAL_RUN = ("PR 2 final gate run perf/pr2-a76736f-quiet2 in the cadf3-tk2-stack-02 data directory "
                 "(FAIL-HOST-BUSY, 2026-11-14 02:50–03:49Z; calls C23 and C24)")
ISSUE_10 = "https://github.com/bharath2020/connie-adf/issues/10"
DESIGNS["pr3"] = {
    "title": "per-PR gate, code-block stage (~85–110 min + ~40 min D/C supplement)",
    "fixtures": {"kitchen-sink": ALL_ARMS, "stress-1k": ALL_ARMS, "giant-table": ALL_ARMS,
                 "list-dense": ALL_ARMS, "code-dense": ALL_ARMS},
    "runs": 3, "warmup": 1, "rule": "median-relative",
    "list_proof": ["list-dense"], "code_proof": ["code-dense"],
    "baseline_completion": True, "fixture_hashes": True,
    "includes": ["pr45", "pr2"],
    "known_debt": [
        {"fixture": "kitchen-sink", "arm": "C", "metric": "hitch_ms_per_s", "rule": CEILING_RULE,
         "source": f"{PR2_FINAL_RUN}, summary.md:13-15 (C hitch 11.98, 18.07, 11.98 ms/s > 10 in 3 of 3 trials); "
                   f"{ISSUE_10}"},
        {"fixture": "list-dense", "arm": "C", "metric": "dropped_frames", "rule": "median-relative",
         "source": f"{PR2_FINAL_RUN}, summary.md:144 (C median 71 vs A's 44, median Δ +28, limit ≤ 2); {ISSUE_10}"},
        {"fixture": "list-dense", "arm": "C", "metric": "hitch_ms_per_s", "rule": CEILING_RULE,
         "source": f"{PR2_FINAL_RUN}, summary.md:131,133,135 (C hitch 11.05, 10.84, 10.76 ms/s > 10 in 3 of 3 "
                   f"trials); {ISSUE_10}"},
        {"fixture": "list-dense", "arm": "C", "metric": "dropped_rate_pct", "rule": CEILING_RULE,
         "source": f"{PR2_FINAL_RUN}, summary.md:132,134,136 (C dropped rate 1.047, 1.018, 1.030 % > 1 % in 3 of 3 "
                   f"trials); {ISSUE_10}"},
    ],
    "predecessor": {
        "arm": PRED_ARM, "against": PRED_AGAINST, "label": "predecessor (PR 2 final tip, TextKit 2)",
        "fixtures": ["list-dense", "kitchen-sink"], "runs": PRED_MIN_PAIRS, "warmup": 1,
        "sensitivity_dropped_frames": PRED_SENSITIVITY_FRAMES,
        "app_sha256": "d04266209ed7c0b29c4393e90b22333baa1f1732de49e1eabc92b57f6013c361",
        "source": f"builds/cand-a76736f/ADFReader.app in the cadf3-tk2-stack-02 data directory: the candidate "
                  f"binary of the {PR2_FINAL_RUN}",
    },
}

# Host (HOST): quiet thresholds and perf-gate.sh's wait for a quiet host.
HOST_QUIET_LOAD_MAX = 4.0
HOST_PROCESS_CPU_MAX = 100.0
HOST_WAIT_S = 1200
HOST_POLL_S = 30

# Renderer proof columns (Scripts/perf_trial.py STATS_FIELDS).
NATIVE_DRAWS = "tk2_native_draws"
TK1_BACKED_ROWS = "tk1_backed_rows"
TK1_BACKED_DRAWS = "tk1_backed_draws"
LINK_ROOTS = "link_roots"
# List-native proof and leaf coverage columns (perf_trial.py STATS_FIELDS /
# READY_STATS_FIELDS map them from the RENDERER_STATS log keys).
LIST_LIVE = "tk2_list_live"
LIST_LIVE_READY = "tk2_list_live_ready"
ELIGIBLE_LEAVES = "eligible_text_leaves"
LINKED_LEAVES = "linked_text_leaves"
FALLBACK_LEAVES = "fallback_text_leaves"
LIST_LEADER_LEAVES = "list_leader_leaves"
LIST_TRAILING_LEAVES = "list_trailing_leaves"
LEAF_COLUMNS = [ELIGIBLE_LEAVES, LINKED_LEAVES, FALLBACK_LEAVES, LIST_LEADER_LEAVES, LIST_TRAILING_LEAVES]
# Code-native proof and code coverage columns (code-block stage, PR 3):
# live TextKit 2 code rows, native code draws, the static code roots
# (eligible + fallback = the top-level code blocks) and the code roots the
# view-time gate (canvas caps, layout direction) admitted / kept on SwiftUI
# at the run's actual environment.
CODE_LIVE = "tk2_code_live"
CODE_LIVE_READY = "tk2_code_live_ready"
CODE_DRAWS = "tk2_code_draws"
ELIGIBLE_CODE = "eligible_code_roots"
FALLBACK_CODE = "fallback_code_roots"
CODE_ADMITTED = "code_admitted"
CODE_GATED = "code_gated"
CODE_COLUMNS = [ELIGIBLE_CODE, FALLBACK_CODE, CODE_ADMITTED, CODE_GATED]
# A work counter (prepared-text conversions): a structural diagnostic.
CONVERSIONS = "tk2_conversions"

# One-sided 95 % Student t quantiles; between table rows the next LOWER df is
# used (a larger quantile, i.e. conservative).
T95 = [(1, 6.314), (2, 2.920), (3, 2.353), (4, 2.132), (5, 2.015), (6, 1.943), (7, 1.895),
       (8, 1.860), (9, 1.833), (10, 1.812), (11, 1.796), (12, 1.782), (13, 1.771), (14, 1.761),
       (15, 1.753), (16, 1.746), (17, 1.740), (18, 1.734), (19, 1.729), (20, 1.725), (21, 1.721),
       (22, 1.717), (23, 1.714), (24, 1.711), (25, 1.708), (26, 1.706), (27, 1.703), (28, 1.701),
       (29, 1.699), (30, 1.697), (40, 1.684), (60, 1.671), (120, 1.658)]


def t95(df: int) -> float:
    if df < 1:
        return math.inf
    value = 1.645
    for d, t in T95:
        if d <= df:
            value = t
        else:
            break
    return value if df <= 120 else 1.645


# ------------------------------------------------------------------ inputs


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def finite(value: str | None) -> float | None:
    if value is None:
        return None
    value = str(value).strip()
    if not value:
        return None
    try:
        x = float(value)
    except ValueError:
        return None
    if math.isnan(x) or math.isinf(x):
        return None
    return x


def load_csv(path: str) -> list[dict]:
    with open(path, newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        rows = list(reader)
        if not reader.fieldnames or "arm" not in reader.fieldnames or "run" not in reader.fieldnames:
            raise SystemExit(f"{path}: not a perf-gate trials CSV (no run/arm columns)")
    return rows


def gated_metrics(plan: dict) -> list[str]:
    metrics = LATENCY + FRAMES
    if plan.get("sampler", True):
        metrics += ["rss_ready_kb", "rss_peak_kb"]
        if plan.get("footprint", True):
            metrics += ["footprint_ready_kb", "footprint_peak_kb"]
    return metrics


def parse_utc(text: str | None) -> datetime | None:
    if not text:
        return None
    try:
        return datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


# --------------------------------------------------------------- validity


class Problems:
    def __init__(self) -> None:
        self.items: list[dict] = []

    def add(self, kind: str, message: str, fixture: str = "", arm: str = "", run: str = "") -> None:
        self.items.append({"kind": kind, "fixture": fixture, "arm": arm, "run": run, "message": message})

    def of(self, kind: str) -> list[dict]:
        return [p for p in self.items if p["kind"] == kind]


def flags_in(argv: str) -> list[str]:
    return argv.split()


def host_sample_busy(load1: float | None, top: list[tuple[str, float, bool]]) -> list[str]:
    """Why one host sample is not quiet (empty when it is)."""
    why = []
    if load1 is not None and load1 > HOST_QUIET_LOAD_MAX:
        why.append(f"1-min load {load1:g} > {HOST_QUIET_LOAD_MAX:g}")
    for name, cpu, simulator in top:
        if cpu > HOST_PROCESS_CPU_MAX and not simulator:
            why.append(f"{name} at {cpu:g} % CPU > {HOST_PROCESS_CPU_MAX:g}")
    return why


def parse_top3(text: str | None) -> list[tuple[str, float, bool]]:
    """A row's host_top3, `name=cpu;…`, a trailing `*` marking a simulator process."""
    out = []
    for item in (text or "").split(";"):
        name, _, value = item.partition("=")
        simulator = value.endswith("*")
        cpu = finite(value.rstrip("*"))
        if name and cpu is not None:
            out.append((name, cpu, simulator))
    return out


def host_state(plan: dict, rows: list[dict], problems: Problems, pilot: bool) -> list[str]:
    """HOST: the reasons a run is HOST-BUSY (start sample after the wait, then
    every counted trial). A non-pilot plan without the start record is
    INVALID; a trial without its load is caught in check_rows."""
    reasons = []
    host = plan.get("host_start")
    if not isinstance(host, dict) or finite(host.get("load1")) is None:
        if not pilot:
            problems.add("invalid", "plan records no host check at start (load average, busiest processes)")
    else:
        top = [(os.path.basename(str(p.get("command", "?"))), finite(p.get("cpu")) or 0.0, bool(p.get("simulator")))
               for p in host.get("top", [])]
        why = host_sample_busy(float(host["load1"]), top)
        if why:
            wait = plan.get("host_wait") or {}
            waited = f" after waiting {wait.get('waited_s')} s" if wait.get("waited_s") is not None else ""
            reasons.append(f"at start{waited}: " + "; ".join(why))
    for row in rows:
        run = finite(row.get("run"))
        if run is None or run < 1:
            continue
        why = host_sample_busy(finite(row.get("host_load1")), parse_top3(row.get("host_top3")))
        if why:
            reasons.append(f"{row.get('fixture')} {row.get('arm')} run {int(run)}: " + "; ".join(why))
    return reasons


def fixture_arms(plan: dict) -> dict:
    """fixture -> the arms the plan runs on it (all plan arms if not declared)."""
    declared = plan.get("fixture_arms")
    if isinstance(declared, dict):
        return {f: [a for a in declared.get(f, [])] for f in plan["fixtures"]}
    return {f: list(plan["arms"]) for f in plan["fixtures"]}


def check_fixture_arms(plan: dict, problems: Problems) -> None:
    declared = plan.get("fixture_arms")
    if isinstance(declared, dict) and sorted(declared) != sorted(plan["fixtures"]):
        problems.add("invalid", f"fixture_arms {sorted(declared)} != fixtures {sorted(plan['fixtures'])}")
    ref = plan.get("reference", "A")
    for fixture, arms in fixture_arms(plan).items():
        unknown = [a for a in arms if a not in plan["arms"]]
        if unknown:
            problems.add("invalid", f"fixture_arms names undeclared arms {unknown}", fixture)
        if ref not in arms:
            problems.add("invalid", f"reference arm {ref} does not run on this fixture", fixture)


def check_rows(rows: list[dict], plan: dict, problems: Problems, expected_blocks: dict, pilot: bool) -> dict:
    """Validates rows against the plan; returns {(fixture, arm): {run: row}} of
    the rows that passed every check (so statistics only see clean data)."""
    fixtures = plan["fixtures"]
    arms = plan["arms"]
    declared = fixture_arms(plan)
    runs = int(plan["runs"])
    metrics = gated_metrics(plan)
    clean: dict = {(f, a): {} for f in fixtures for a in declared[f] if a in arms}
    seen: dict = {}
    list_proof = list_proof_fixtures()
    code_proof = code_proof_fixtures()

    for row in rows:
        run_v = finite(row.get("run"))
        if run_v is None or run_v < 1:
            continue  # warm-ups live in warmup.csv; run 0 is never counted
        run = int(run_v)
        fixture, arm = row.get("fixture", ""), row.get("arm", "")
        where = {"fixture": fixture, "arm": arm, "run": str(run)}
        if fixture not in fixtures or arm not in arms or arm not in declared[fixture]:
            problems.add("invalid", "row for an undeclared fixture/arm", **where)
            continue
        if run > runs:
            problems.add("invalid", f"run {run} beyond the declared {runs}", **where)
            continue
        key = (fixture, arm, run)
        if key in seen:
            problems.add("invalid", "duplicate row", **where)
            continue
        seen[key] = row
        spec = arms[arm]
        role = spec.get("role", "baseline")

        # Provenance first: a row we cannot attribute is never evidence.
        provenance = provenance_problems(row, spec, fixture)
        for message in provenance:
            problems.add("invalid", message, **where)
        provenance_ok = not provenance
        if not pilot and finite(row.get("host_load1")) is None:
            problems.add("invalid", "host 1-min load not recorded for the trial", **where)

        status = row.get("status", "")
        exit_v = finite(row.get("launch_exit"))
        if status != "ok":
            if role == "candidate":
                kind = "crash" if status == "crashed" and provenance_ok else "candidate_failure"
                problems.add(kind, f"candidate trial status {status} (exit {row.get('launch_exit') or '∅'})", **where)
            else:
                problems.add("baseline_failure", f"baseline trial status {status} (exit {row.get('launch_exit') or '∅'})",
                             **where)
            continue
        if not provenance_ok:
            continue

        # status == ok from here: anything inconsistent is a data defect.
        bad = []
        if exit_v != 0:
            bad.append(f"status ok but launch_exit {row.get('launch_exit') or '∅'}")
        if row.get("ready_fixture", "") != fixture:
            bad.append(f"READY fixture {row.get('ready_fixture') or '∅'} != {fixture}")
        blocks = finite(row.get("blocks"))
        if blocks is None or blocks <= 0:
            bad.append("READY blocks missing or 0")
        frames = finite(row.get("frames"))
        if frames is None or frames <= 0:
            bad.append("frames missing or 0")
        for metric in metrics:
            if metric == "dropped_rate_pct":
                continue  # derived below
            value = finite(row.get(metric))
            if value is None or value < 0:
                bad.append(f"{metric} missing/non-finite/negative ({row.get(metric) or '∅'})")
        dropped = finite(row.get("dropped_frames"))
        if frames and dropped is not None and dropped > frames:
            bad.append("dropped > frames")
        if plan.get("sampler", True):
            if (finite(row.get("memory_samples")) or 0) <= 0:
                bad.append("no RSS samples")
            if plan.get("footprint", True) and (finite(row.get("footprint_samples")) or 0) <= 0:
                bad.append("no footprint samples")
        traversal = []
        if spec.get("requires_completion"):
            end_row = finite(row.get("end_row"))
            if row.get("completed") != "1":
                bad.append(f"SCROLL_METRICS completed={row.get('completed') or '∅'} (need 1)")
            if end_row is None:
                bad.append("SCROLL_METRICS endRow missing")
            elif blocks and end_row != blocks - 1:
                traversal.append(f"scroll ended at row {end_row:g}, not the last block {blocks - 1:g}")
        renderer = spec.get("expected_renderer")
        if renderer:
            bad += renderer_problems(row, renderer, fixture in list_proof, fixture in code_proof)
        if bad:
            for message in bad:
                problems.add("invalid", message, **where)
            continue
        if traversal:
            # A candidate that stops short FAILs; a reference arm held to
            # completion (baseline_completion) that stops short is the
            # environment's problem: INVALID.
            kind = "candidate_failure" if role == "candidate" else "baseline_failure"
            for message in traversal:
                problems.add(kind, message, **where)
            continue
        clean[(fixture, arm)][run] = row

    # Completeness, block-count agreement, traversal against A's frames.
    ref = plan.get("reference", "A")
    for fixture in fixtures:
        counts = set()
        for arm in [a for a in declared[fixture] if a in arms]:
            for run in range(1, runs + 1):
                if (fixture, arm, run) not in seen:
                    problems.add("invalid", "missing trial", fixture, arm, str(run))
            counts |= {finite(r.get("blocks")) for r in clean[(fixture, arm)].values()}
        counts.discard(None)
        if len(counts) > 1:
            problems.add("invalid", f"READY block counts disagree across arms/runs: {sorted(counts)}", fixture)
        want = expected_blocks.get(fixture)
        if want is not None and counts and counts != {float(want)}:
            problems.add("invalid", f"READY blocks {sorted(counts)} != expected {want}", fixture)
        ref_frames = [finite(r.get("frames")) for r in clean.get((fixture, ref), {}).values()]
        ref_frames = [f for f in ref_frames if f]
        if not ref_frames:
            continue
        a_frames = statistics.median(ref_frames)
        for arm, spec in arms.items():
            if arm == ref or not spec.get("requires_completion") or (fixture, arm) not in clean:
                continue
            for run, row in list(clean[(fixture, arm)].items()):
                frames = finite(row.get("frames")) or 0.0
                if abs(frames - a_frames) > a_frames * TRAVERSAL_FRAMES_PCT / 100.0:
                    problems.add("candidate_failure", f"traversal: {frames:g} frames vs {ref} median {a_frames:g} "
                                 f"(> ±{TRAVERSAL_FRAMES_PCT:g} %)", fixture, arm, str(run))
                    del clean[(fixture, arm)][run]
    return clean


def provenance_problems(row: dict, spec: dict, fixture: str) -> list[str]:
    """Why a row cannot be attributed to its arm (empty when it can): the
    arm's binary built and installed, the arm's bundled fixture bytes
    installed, the arm's flags on the fixture's argv."""
    out = []
    if row.get("app_sha256", "") != spec.get("sha256"):
        out.append(f"app sha256 {row.get('app_sha256') or '∅'} != plan {spec.get('sha256')}")
    if row.get("installed_sha256", "") != spec.get("sha256"):
        out.append(f"installed sha256 {row.get('installed_sha256') or '∅'} != plan {spec.get('sha256')}")
    want_fixture = (spec.get("fixture_sha256") or {}).get(fixture)
    if want_fixture and (row.get("installed_fixture_sha256") or "") != want_fixture:
        out.append(f"installed {fixture}.json sha256 {row.get('installed_fixture_sha256') or '∅'} != "
                   f"plan {want_fixture} (the arm's bundled fixture at preflight)")
    argv = flags_in(row.get("argv", ""))
    missing = [f for f in spec.get("required_flags", []) if f not in argv]
    forbidden = [f for f in spec.get("forbidden_flags", []) if f in argv]
    if missing or forbidden or "-fixture" not in argv or fixture not in argv:
        out.append(f"argv wrong for arm (missing {missing}, forbidden {forbidden}): {row.get('argv')}")
    return out


def warmup_problems(row: dict, spec: dict, fixture: str, list_proof: bool, code_proof: bool) -> list[str]:
    """Why one discarded warm-up does not count (empty when it ran
    successfully): it is run 0, it is attributable to its arm (provenance),
    it launched, reached READY on its fixture and exited 0 (status ok: no
    timeout, no missing READY, no crash), it carries the renderer proof the
    arm requires, and it scrolled to the last block where the arm is held
    to completion. Its measurements are never read: a warm-up never enters
    the statistics."""
    out = []
    if finite(row.get("run")) != 0:
        out.append(f"run {row.get('run') or '∅'} (a warm-up is run 0)")
    out += provenance_problems(row, spec, fixture)
    status = row.get("status", "")
    if status != "ok":
        return out + [f"trial status {status or '∅'} (exit {row.get('launch_exit') or '∅'})"]
    if finite(row.get("launch_exit")) != 0:
        out.append(f"status ok but launch_exit {row.get('launch_exit') or '∅'}")
    if row.get("ready_fixture", "") != fixture:
        out.append(f"READY fixture {row.get('ready_fixture') or '∅'} != {fixture}")
    blocks = finite(row.get("blocks"))
    if blocks is None or blocks <= 0:
        out.append("READY blocks missing or 0")
    if spec.get("requires_completion"):
        end_row = finite(row.get("end_row"))
        if row.get("completed") != "1":
            out.append(f"SCROLL_METRICS completed={row.get('completed') or '∅'} (need 1)")
        if end_row is None:
            out.append("SCROLL_METRICS endRow missing")
        elif blocks and end_row != blocks - 1:
            out.append(f"scroll ended at row {end_row:g}, not the last block {blocks - 1:g}")
    renderer = spec.get("expected_renderer")
    if renderer:
        out += renderer_problems(row, renderer, list_proof, code_proof)
    return out


def renderer_problems(row: dict, renderer: str, list_proof: bool = False, code_proof: bool = False) -> list[str]:
    """The RENDERER_STATS proof for one candidate row (final line counters);
    `list_proof` adds the list-native proof (LIST PROOF), `code_proof` the
    code-native proof (CODE PROOF)."""
    if row.get("renderer") != renderer or row.get("renderer_ready") != renderer:
        return [f"RENDERER_STATS renderer={row.get('renderer_ready') or '∅'} at READY / "
                f"{row.get('renderer') or '∅'} at the end (need {renderer} on both)"]
    layouts = finite(row.get("tk2_layouts"))
    native = finite(row.get(NATIVE_DRAWS))
    if renderer == "textkit2":
        out = []
        if layouts is None or layouts <= 0:
            out.append(f"TextKit 2 arm with tk2Layouts={row.get('tk2_layouts') or '∅'}")
        if native is None or native <= 0:
            out.append(f"TextKit 2 arm with tk2NativeDraws={row.get(NATIVE_DRAWS) or '∅'} (need > 0: native "
                       "TextKit 2 drew glyphs)")
        if list_proof:
            out += list_proof_problems(row)
        if code_proof:
            out += code_proof_problems(row)
        return out
    zero = {"tk2_layouts": layouts, "tk2_live": finite(row.get("tk2_live")),
            "tk2_live_ready": finite(row.get("tk2_live_ready")), NATIVE_DRAWS: native,
            TK1_BACKED_DRAWS: finite(row.get(TK1_BACKED_DRAWS))}
    # A build that reports live list rows must report none with the switch
    # OFF; on a list-proof fixture the counter is required.
    if list_proof or row.get(LIST_LIVE) or row.get(LIST_LIVE_READY):
        zero[LIST_LIVE_READY] = finite(row.get(LIST_LIVE_READY))
        zero[LIST_LIVE] = finite(row.get(LIST_LIVE))
    # The same for code rows: none live and none drawn with the switch OFF
    # wherever the build reports them; required on a code-proof fixture.
    if code_proof or row.get(CODE_LIVE) or row.get(CODE_LIVE_READY) or row.get(CODE_DRAWS):
        zero[CODE_LIVE_READY] = finite(row.get(CODE_LIVE_READY))
        zero[CODE_LIVE] = finite(row.get(CODE_LIVE))
        zero[CODE_DRAWS] = finite(row.get(CODE_DRAWS))
    nonzero = {k: row.get(k) or "∅" for k, v in zero.items() if v != 0}
    return [f"SwiftUI arm with nonzero/missing TextKit 2 counters {nonzero}"] if nonzero else []


def list_proof_problems(row: dict) -> list[str]:
    """LIST PROOF for a C row: live TextKit 2 rows owned by list text at READY
    or at the end, and static leaf coverage that leaves list text eligible.
    Root headings and paragraphs drawing natively prove nothing about lists."""
    out = []
    live = [v for v in (finite(row.get(LIST_LIVE_READY)), finite(row.get(LIST_LIVE))) if v is not None]
    if not live:
        out.append(f"list-native proof missing: RENDERER_STATS reports no {LIST_LIVE} (live TextKit 2 list rows) "
                   "at READY or at the end")
    elif max(live) <= 0:
        out.append(f"TextKit 2 arm with {LIST_LIVE_READY}={row.get(LIST_LIVE_READY) or '∅'} and "
                   f"{LIST_LIVE}={row.get(LIST_LIVE) or '∅'}: no live TextKit 2 list rows (lists stayed on SwiftUI; "
                   "a heading/paragraph native-draw total is not list proof)")
    leaves = {c: finite(row.get(c)) for c in LEAF_COLUMNS}
    missing = [c for c, v in leaves.items() if v is None]
    if missing:
        out.append(f"list leaf coverage missing from RENDERER_STATS: {missing}")
        return out
    list_leaves = leaves[LIST_LEADER_LEAVES] + leaves[LIST_TRAILING_LEAVES]
    # eligible_text_leaves spans root richText and list text; eligible_roots
    # is the root richText share of it, so the difference is list text.
    eligible_list = leaves[ELIGIBLE_LEAVES] - (finite(row.get("eligible_roots")) or 0.0)
    if list_leaves <= 0:
        out.append(f"no list text in scope ({LIST_LEADER_LEAVES} + {LIST_TRAILING_LEAVES} = 0): the fixture exercises "
                   "no list leaves")
    elif eligible_list <= 0:
        out.append(f"all list leaves fall back to SwiftUI: {ELIGIBLE_LEAVES} {leaves[ELIGIBLE_LEAVES]:g} − "
                   f"eligible_roots {row.get('eligible_roots') or '∅'} leaves 0 of {list_leaves:g} list leaves "
                   "eligible")
    return out


def code_proof_problems(row: dict) -> list[str]:
    """CODE PROOF for a C row: live TextKit 2 rows owned by a top-level code
    block at READY or at the end, native code draws, and code coverage that
    leaves code eligible statically and admitted at the run's environment.
    Headings, paragraphs or list text drawing natively prove nothing about
    code, so the global counters are not consulted here."""
    out = []
    live = [v for v in (finite(row.get(CODE_LIVE_READY)), finite(row.get(CODE_LIVE))) if v is not None]
    if not live:
        out.append(f"code-native proof missing: RENDERER_STATS reports no {CODE_LIVE} (live TextKit 2 code rows) "
                   "at READY or at the end")
    elif max(live) <= 0:
        out.append(f"TextKit 2 arm with {CODE_LIVE_READY}={row.get(CODE_LIVE_READY) or '∅'} and "
                   f"{CODE_LIVE}={row.get(CODE_LIVE) or '∅'}: no live TextKit 2 code rows (code stayed on SwiftUI; "
                   "a heading/paragraph/list native-draw total is not code proof)")
    draws = finite(row.get(CODE_DRAWS))
    if draws is None:
        out.append(f"code-native proof missing: RENDERER_STATS reports no {CODE_DRAWS} (native TextKit 2 code draws)")
    elif draws <= 0:
        out.append(f"TextKit 2 arm with {CODE_DRAWS}={row.get(CODE_DRAWS) or '∅'} (need > 0: TextKit 2 drew code "
                   "glyphs natively)")
    coverage = {c: finite(row.get(c)) for c in CODE_COLUMNS}
    missing = [c for c, v in coverage.items() if v is None]
    if missing:
        out.append(f"code coverage missing from RENDERER_STATS: {missing}")
        return out
    roots = coverage[ELIGIBLE_CODE] + coverage[FALLBACK_CODE]
    if roots <= 0:
        out.append(f"no top-level code blocks in scope ({ELIGIBLE_CODE} + {FALLBACK_CODE} = 0): the fixture "
                   "exercises no code roots")
    elif coverage[ELIGIBLE_CODE] <= 0:
        out.append(f"all code roots fall back to SwiftUI: {ELIGIBLE_CODE} 0 of {roots:g} top-level code blocks "
                   "(static coverage)")
    elif coverage[CODE_ADMITTED] <= 0:
        out.append(f"all code roots fall back to SwiftUI at the run's environment: {CODE_ADMITTED} 0, {CODE_GATED} "
                   f"{coverage[CODE_GATED]:g} of {coverage[ELIGIBLE_CODE]:g} eligible code roots (the view-time gate "
                   "admitted none)")
    elif coverage[CODE_ADMITTED] + coverage[CODE_GATED] != coverage[ELIGIBLE_CODE]:
        out.append(f"code coverage inconsistent: {CODE_ADMITTED} {coverage[CODE_ADMITTED]:g} + {CODE_GATED} "
                   f"{coverage[CODE_GATED]:g} != {ELIGIBLE_CODE} {coverage[ELIGIBLE_CODE]:g} (every eligible code "
                   "root is either admitted or gated at the run's environment)")
    return out


def ceiling_breaches(row: dict) -> list[tuple[str, str]]:
    """The per-trial ceilings one row exceeds, as (metric, message): the
    metric is the row a known-debt annotation or the predecessor supplement
    names (CEILING_METRICS)."""
    out = []
    frames = finite(row.get("frames")) or 0.0
    dropped = finite(row.get("dropped_frames")) or 0.0
    hitch = finite(row.get("hitch_ms_per_s")) or 0.0
    if hitch > CEILING_HITCH_MS_PER_S:
        out.append(("hitch_ms_per_s", f"hitch {hitch:g} ms/s > {CEILING_HITCH_MS_PER_S:g}"))
    if frames >= SMALL_TRIAL_FRAMES:
        rate = dropped / frames * 100.0
        if rate > CEILING_DROPPED_RATE_PCT:
            out.append(("dropped_rate_pct",
                        f"dropped rate {rate:.3f} % > {CEILING_DROPPED_RATE_PCT:g} % ({dropped:g}/{frames:g})"))
    elif dropped > CEILING_DROPPED_SMALL:
        out.append(("dropped_frames",
                    f"{dropped:g} dropped frames > {CEILING_DROPPED_SMALL:g} on a {frames:g}-frame trial"))
    return out


def check_ceilings(clean: dict, plan: dict, problems: Problems) -> list[dict]:
    """Per-trial absolute ceilings. A baseline breach is an environment
    problem (INVALID); returns the candidate breaches (FAIL)."""
    breaches = []
    for (fixture, arm), runs in clean.items():
        role = plan["arms"][arm].get("role", "baseline")
        for run, row in runs.items():
            for metric, message in ceiling_breaches(row):
                if role == "candidate":
                    breaches.append({"fixture": fixture, "arm": arm, "run": str(run), "metric": metric,
                                     "rule": CEILING_RULE, "message": message})
                else:
                    problems.add("invalid", f"baseline ceiling breach ({message}): environment, not the candidate",
                                 fixture, arm, str(run))
    return breaches


def design_conformance(plan: dict, problems: Problems, pilot: bool) -> tuple[dict | None, list[str]]:
    """Returns (design, reductions). Reductions make a run INCOMPLETE."""
    name = plan.get("design")
    design = DESIGNS.get(name or "")
    if design is None:
        problems.add("invalid", f"plan design {name!r} is not one of {sorted(DESIGNS)}")
        return None, []
    reduced = []
    declared = fixture_arms(plan)
    missing_fixtures = [f for f in design["fixtures"] if f not in declared]
    extra_fixtures = [f for f in declared if f not in design["fixtures"]]
    if missing_fixtures:
        reduced.append(f"fixtures {missing_fixtures} declared by design {name} are missing")
    if extra_fixtures and not pilot:
        problems.add("invalid", f"fixtures {extra_fixtures} are not part of design {name}")
    for fixture, want in design["fixtures"].items():
        missing_arms = [a for a in want if fixture in declared and a not in declared[fixture]]
        if missing_arms:
            reduced.append(f"{fixture}: arms {missing_arms} missing")
    if int(plan["runs"]) < design["runs"]:
        reduced.append(f"{plan['runs']} pairs declared, design {name} needs {design['runs']}")
    if not plan.get("sampler", False):
        reduced.append("memory sampler off")
    elif not plan.get("footprint", False):
        reduced.append("footprint sampling off")
    for arm in ("B", "C"):
        spec = plan["arms"].get(arm)
        if spec and not (spec.get("requires_completion") and spec.get("expected_renderer")):
            reduced.append(f"arm {arm} lacks completion/renderer markers")
    ref = plan.get("reference", "A")
    if design.get("baseline_completion") and not plan["arms"].get(ref, {}).get("requires_completion"):
        reduced.append(f"arm {ref} lacks completion markers (design {name} holds the reference to endRow = "
                       "blocks − 1)")
    if int(plan.get("warmup", 0)) < design["warmup"] and not pilot:
        problems.add("invalid", f"warmup {plan.get('warmup', 0)} < {design['warmup']} (one discarded warm-up per "
                                "fixture and arm)")
    return design, reduced


def check_fixture_hashes(plan: dict, design: dict | None, problems: Problems) -> None:
    """FIXTURE BYTES: every arm of a fixture bundles the same JSON (sha256s
    recorded by perf-gate.sh's preflight as arms.<arm>.fixture_sha256).
    Required by a fixture_hashes design; checked whenever recorded."""
    arms = plan["arms"]
    recorded = any(isinstance(spec.get("fixture_sha256"), dict) for spec in arms.values())
    if not (recorded or (design or {}).get("fixture_hashes")):
        return
    for fixture, fixture_arm_list in fixture_arms(plan).items():
        shas = {}
        for arm in fixture_arm_list:
            sha = (arms.get(arm, {}).get("fixture_sha256") or {}).get(fixture)
            if sha:
                shas[arm] = sha
            else:
                problems.add("invalid", f"plan records no sha256 of {fixture}.json in arm {arm}'s .app (fixture "
                                        "preflight)", fixture, arm)
        if len(set(shas.values())) > 1:
            problems.add("invalid", f"{fixture}.json differs across arms ("
                         + ", ".join(f"{a} {s[:12]}" for a, s in sorted(shas.items()))
                         + "): the arms do not open the same document", fixture)


def metric_value(row: dict, metric: str) -> float | None:
    if metric == "dropped_rate_pct":
        frames, dropped = finite(row.get("frames")), finite(row.get("dropped_frames"))
        if not frames or dropped is None:
            return None
        return dropped / frames * 100.0
    return finite(row.get(metric))


def describe(values: list[float]) -> dict | None:
    if not values:
        return None
    return {"n": len(values), "median": statistics.median(values), "min": min(values), "max": max(values),
            "mean": statistics.fmean(values)}


def pairs(clean: dict, fixture: str, ref: str, arm: str, runs: int, metric: str) -> list[float]:
    out = []
    for run in range(1, runs + 1):
        a = clean.get((fixture, ref), {}).get(run)
        x = clean.get((fixture, arm), {}).get(run)
        if a is None or x is None:
            continue
        va, vx = metric_value(a, metric), metric_value(x, metric)
        if va is None or vx is None:
            continue
        out.append(vx - va)
    return out


def tk1_share(rows: list[dict]) -> dict:
    """The TextKit 1-backed share of a C arm (median over trials)."""
    def med(key: str) -> float | None:
        values = [v for v in (finite(r.get(key)) for r in rows) if v is not None]
        return statistics.median(values) if values else None
    out = {k: med(k) for k in ("eligible_roots", LINK_ROOTS, "tk2_draws", NATIVE_DRAWS, TK1_BACKED_DRAWS,
                                TK1_BACKED_ROWS, "tk2_layouts", "text_fallback_roots", "fallback_roots",
                                LIST_LIVE_READY, LIST_LIVE, *LEAF_COLUMNS, CODE_LIVE_READY, CODE_LIVE, CODE_DRAWS,
                                *CODE_COLUMNS, CONVERSIONS)}
    out["link_root_share_pct"] = (out[LINK_ROOTS] / out["eligible_roots"] * 100.0
                                  if out[LINK_ROOTS] is not None and out["eligible_roots"] else None)
    out["tk1_draw_share_pct"] = (out[TK1_BACKED_DRAWS] / out["tk2_draws"] * 100.0
                                 if out[TK1_BACKED_DRAWS] is not None and out["tk2_draws"] else None)
    eligible, linked, fallback = out[ELIGIBLE_LEAVES], out[LINKED_LEAVES], out[FALLBACK_LEAVES]
    out["linked_leaf_share_pct"] = linked / eligible * 100.0 if linked is not None and eligible else None
    out["fallback_leaf_share_pct"] = (fallback / (eligible + fallback) * 100.0
                                      if fallback is not None and eligible is not None and eligible + fallback else None)
    # Code roots: the static share that can never be TextKit 2 (fallback of
    # eligible + fallback) and, separately, the share the view-time gate kept
    # on SwiftUI at this run's environment (gated of admitted + gated).
    code_eligible, code_fallback = out[ELIGIBLE_CODE], out[FALLBACK_CODE]
    admitted, gated = out[CODE_ADMITTED], out[CODE_GATED]
    out["fallback_code_share_pct"] = (code_fallback / (code_eligible + code_fallback) * 100.0
                                      if code_fallback is not None and code_eligible is not None
                                      and code_eligible + code_fallback else None)
    out["gated_code_share_pct"] = (gated / (admitted + gated) * 100.0
                                   if gated is not None and admitted is not None and admitted + gated else None)
    return out

# ------------------------------------------- known debt and the predecessor


def computed_rule_rows(design: dict) -> set[tuple[str, str]]:
    """The (metric, rule) rows a design computes a FAIL-capable verdict for:
    its statistical rule per metric, and the per-trial ceilings."""
    rule = design["rule"]
    rows = {(m, CEILING_RULE) for m in CEILING_METRICS}
    if rule == "median-relative":
        rows |= {(m, rule) for m in LATENCY + MEMORY + ["dropped_frames"]}
    else:
        rows |= {(m, rule) for m in LATENCY + FRAMES + MEMORY}
    return rows


def earlier_fixtures(design: dict) -> set[str]:
    """The fixtures of the designs this one includes (the earlier stages')."""
    return {f for name in design.get("includes", []) for f in DESIGNS.get(name, {}).get("fixtures", {})}


def known_debt_errors(name: str) -> list[str]:
    """KNOWN DEBT: why a design's known_debt list is refused (empty when it
    is sound). An entry may name only a fixture of an included earlier
    design, arm C and a metric/rule row the design computes."""
    design = DESIGNS.get(name) or {}
    entries = design.get("known_debt")
    if not entries:
        return []
    errors = []
    earlier = earlier_fixtures(design)
    rows = computed_rule_rows(design)
    seen = set()
    for index, entry in enumerate(entries):
        where = f"design {name} known_debt[{index}]"
        if not isinstance(entry, dict) or any(not str(entry.get(k) or "").strip() for k in DEBT_KEYS):
            errors.append(f"{where}: needs {', '.join(DEBT_KEYS)}, each non-empty: {entry!r}")
            continue
        fixture, arm, metric, rule = (entry[k] for k in DEBT_KEYS[:4])
        if fixture in design.get("code_proof", []) or fixture not in earlier or fixture not in design["fixtures"]:
            errors.append(f"{where}: fixture {fixture!r} is not a fixture of an included earlier design "
                          f"({', '.join(design.get('includes', [])) or 'none'}: {sorted(earlier)}); this stage's "
                          "own work never carries debt")
        if arm != DEBT_ARM:
            errors.append(f"{where}: arm {arm!r}: only arm {DEBT_ARM} (TextKit 2 ON) may carry known debt; the "
                          "reference and the shipping path (switch OFF) never do")
        if (metric, rule) not in rows:
            errors.append(f"{where}: design {name} computes no {rule!r} row for metric {metric!r} (rows: "
                          + ", ".join(f"{m}/{r}" for m, r in sorted(rows)) + ")")
        key = (fixture, arm, metric, rule)
        if key in seen:
            errors.append(f"{where}: duplicate of an earlier entry {key}")
        seen.add(key)
    return errors


def predecessor_errors(name: str) -> list[str]:
    """PREDECESSOR: why a design's predecessor declaration is refused (empty
    when it is sound): D against C only, on fixtures of an included earlier
    design, with enough pairs for the bound, a warm-up, and the gate's own
    dropped-frame sensitivity (no allowance, no other key)."""
    design = DESIGNS.get(name) or {}
    pred = design.get("predecessor")
    if pred is None:
        return []
    where = f"design {name} predecessor"
    if not isinstance(pred, dict):
        return [f"{where}: not a mapping"]
    errors = []
    unknown = sorted(set(pred) - PRED_DESIGN_KEYS)
    if unknown:
        errors.append(f"{where}: unknown key(s) {unknown}: the method is frozen (no noise allowance, no override)")
    if pred.get("arm") != PRED_ARM or pred.get("against") != PRED_AGAINST:
        errors.append(f"{where}: compares arm {PRED_ARM} (the predecessor) with arm {PRED_AGAINST} only, got "
                      f"{pred.get('arm')!r} vs {pred.get('against')!r}")
    if any(PRED_ARM in arms for arms in design["fixtures"].values()):
        errors.append(f"{where}: arm {PRED_ARM} is a gated arm of the design: D never substitutes for A")
    fixtures = pred.get("fixtures") or []
    earlier = earlier_fixtures(design)
    bad = [f for f in fixtures if f not in design["fixtures"] or f not in earlier]
    if not fixtures or bad:
        errors.append(f"{where}: fixtures {fixtures} must be fixtures of an included earlier design that this "
                      f"design also runs ({sorted(earlier & set(design['fixtures']))})")
    runs, warmup = pred.get("runs"), pred.get("warmup")
    if not isinstance(runs, int) or runs < PRED_MIN_PAIRS:
        errors.append(f"{where}: runs {runs!r}: a one-sided {100 * (1 - PRED_ALPHA):g} % bound on a median needs "
                      f">= {PRED_MIN_PAIRS} pairs")
    if not isinstance(warmup, int) or warmup < 1:
        errors.append(f"{where}: warmup {warmup!r}: one discarded warm-up per fixture and arm is required")
    if pred.get("sensitivity_dropped_frames") != PRED_SENSITIVITY_FRAMES:
        errors.append(f"{where}: sensitivity_dropped_frames {pred.get('sensitivity_dropped_frames')!r} is not the "
                      f"gate's dropped-frame scale (+{PRED_SENSITIVITY_FRAMES:g}): a noise allowance is never "
                      "borrowed and the scale is never widened")
    return errors


def design_errors(name: str | None) -> list[str]:
    """Why a design's declarations are refused before anything is measured."""
    if not name or name not in DESIGNS:
        return []
    return known_debt_errors(name) + predecessor_errors(name)


def annotate_known_debt(design: dict | None, plan: dict, fixtures_out: dict, cand_ceiling: list[dict],
                        problems: Problems, clean: dict, ref: str, runs: int, rule: str | None) -> dict | None:
    """KNOWN DEBT: labels the failing rule and ceiling rows the design lists
    and reports each listed row's state. It reads the verdicts and changes
    none: a labelled row still fails. Returns None when nothing is listed."""
    entries = (design or {}).get("known_debt")
    if not entries:
        return None
    declared = fixture_arms(plan)
    failing: dict = {}
    for fixture, fx in fixtures_out.items():
        for arm, comp in fx["comparisons"].items():
            for metric, entry in comp.items():
                if entry.get("verdict") == "FAIL":
                    failing[(fixture, arm, metric, rule)] = {"fixture": fixture, "arm": arm, "metric": metric,
                                                             "rule": rule}
    for breach in cand_ceiling:
        key = (breach["fixture"], breach["arm"], breach["metric"], CEILING_RULE)
        failing.setdefault(key, {"fixture": breach["fixture"], "arm": breach["arm"], "metric": breach["metric"],
                                 "rule": CEILING_RULE, "trials": []})["trials"].append(breach["run"])
    report, annotated = [], set()
    for entry in entries:
        fixture, arm, metric, rule_name = (entry[k] for k in DEBT_KEYS[:4])
        key = (fixture, arm, metric, rule_name)
        item = dict(entry)
        # The label never covers a missing proof, invalid provenance, a
        # missing trial, a baseline failure, a crash or a timeout: any
        # problem in this cell, in the reference's cell or in the run
        # withholds it.
        blocking = [p for p in problems.items if p["fixture"] in ("", fixture) and p["arm"] in ("", arm, ref)]
        comparison = fixtures_out.get(fixture, {}).get("comparisons", {}).get(arm, {}).get(metric, {})
        if fixture not in declared or arm not in declared[fixture]:
            item["status"] = "not-run"
        elif blocking:
            item["status"] = "withheld"
            item["why"] = f"[{blocking[0]['kind']}] {blocking[0]['message']}"
        elif key in failing:
            item["status"] = "known-debt-fail"
            item["trials"] = failing[key].get("trials")
            annotated.add(key)
        elif rule_name == CEILING_RULE and len(clean.get((fixture, arm), {})) >= runs:
            item["status"] = "improved"
        elif rule_name != CEILING_RULE and comparison.get("verdict") == "PASS":
            item["status"] = "improved"
        else:
            item["status"] = "not-evaluated"
        if rule_name != CEILING_RULE and comparison and item["status"] in ("known-debt-fail", "improved"):
            comparison["known_debt"] = {"status": item["status"], "source": entry["source"]}
        report.append(item)
    for breach in cand_ceiling:
        if (breach["fixture"], breach["arm"], breach["metric"], CEILING_RULE) in annotated:
            breach["known_debt"] = True
    return {"entries": report, "failing_rows": len(failing), "annotated_rows": len(annotated),
            "not_annotated": [row for key, row in failing.items() if key not in annotated]}


def median_bounds(deltas: list[float], alpha: float = PRED_ALPHA) -> tuple[float, float, int, float] | None:
    """One-sided (1 − alpha) distribution-free bounds on the median of paired
    differences: (L, U, u, tail), L = d_(n+1−u), U = d_(u), u the smallest
    rank with tail = P(Bin(n, 1/2) >= u) <= alpha (the chance that the true
    median lies beyond that order statistic). None when no rank qualifies:
    fewer than PRED_MIN_PAIRS pairs."""
    n = len(deltas)
    ordered = sorted(deltas)
    for u in range(n // 2 + 1, n + 1):
        tail = sum(math.comb(n, k) for k in range(u, n + 1)) / 2.0 ** n
        if tail <= alpha:
            return ordered[n - u], ordered[u - 1], u, tail
    return None


def predecessor_result(deltas: list[float], sensitivity: float) -> dict:
    """PREDECESSOR: one (fixture, metric) row from its paired differences
    C − D. INCONCLUSIVE whenever the pairs cannot resolve the sensitivity."""
    entry = {"n": len(deltas), "deltas": [round(d, 4) for d in deltas], "median_delta": None, "lower": None,
             "upper": None, "rank": None, "confidence_pct": None, "sensitivity": sensitivity,
             "result": "INCONCLUSIVE", "why": "no clean pairs"}
    if not deltas:
        return entry
    entry["median_delta"] = statistics.median(deltas)
    bounds = median_bounds(deltas)
    if bounds is None:
        entry["why"] = (f"{len(deltas)} pairs: no one-sided {100 * (1 - PRED_ALPHA):g} % bound on the median exists "
                        f"below {PRED_MIN_PAIRS} pairs")
        return entry
    lower, upper, rank, tail = bounds
    entry.update(lower=lower, upper=upper, rank=rank, confidence_pct=(1.0 - tail) * 100.0)
    if upper <= sensitivity:
        entry["result"], entry["why"] = "NO-ADDED-REGRESSION", "upper bound <= sensitivity"
    elif lower > sensitivity:
        entry["result"], entry["why"] = "ADDED-REGRESSION", "lower bound > sensitivity"
    else:
        entry["why"] = "the bounds straddle the sensitivity: these pairs cannot resolve it"
    return entry


PRED_COUNTERS = ["tk2_layouts", CONVERSIONS, "tk2_draws", NATIVE_DRAWS, TK1_BACKED_DRAWS, "tk2_live_ready",
                 "tk2_live", LIST_LIVE_READY, LIST_LIVE, CODE_LIVE_READY, CODE_LIVE, CODE_DRAWS]


def predecessor_supplement(plan: dict, name: str | None, design: dict | None, pilot: bool, run_dir: str,
                           csv_path: str | None, warmup_path: str | None) -> dict | None:
    """PREDECESSOR: the paired D vs C supplement of a run (None when neither
    the design nor the plan has one). status MISSING (declared by the
    design, absent from the plan), INVALID (any problem: no result) or
    COMPLETE; per fixture and metric a result of PRED_RESULTS. Nothing here
    feeds the A/B/C statistics or problems."""
    declared = (design or {}).get("predecessor")
    block = plan.get("predecessor")
    if declared is None and block is None:
        return None
    problems = Problems()
    out: dict = {"status": "MISSING", "pilot": pilot, "declared": declared, "fixtures": {}, "problems": [],
                 "host_busy_reasons": [], "arm": PRED_ARM, "against": PRED_AGAINST, "alpha": PRED_ALPHA,
                 "sensitivity_dropped_frames": PRED_SENSITIVITY_FRAMES, "min_pairs": PRED_MIN_PAIRS}
    if block is None:
        out["problems"] = [{"kind": "missing", "fixture": "", "arm": "", "run": "",
                            "message": f"plan.json has no predecessor block (perf-gate.sh --app-d): design {name} "
                                       f"enforces {PRED_ARM} vs {PRED_AGAINST} on {declared.get('fixtures')}"}]
        return out
    out["status"] = "INVALID"
    if declared is None or not isinstance(block, dict):
        problems.add("invalid", f"the plan carries a predecessor block but design {name} declares no predecessor "
                                "supplement" if declared is None else "the plan's predecessor block is not a mapping")
        out["problems"] = problems.items
        return out

    # The declaration: nothing but the frozen method may be recorded.
    unknown = sorted(set(block) - PRED_PLAN_KEYS)
    if unknown:
        problems.add("invalid", f"predecessor block has unknown key(s) {unknown}: the method is frozen in the "
                                "design (a noise allowance or another override is never supplied by a run)")
    if block.get("arm") != PRED_ARM or block.get("against") != PRED_AGAINST:
        problems.add("invalid", f"predecessor block compares {block.get('arm')!r} with {block.get('against')!r}, "
                                f"not {PRED_ARM} with {PRED_AGAINST}")
    if block.get("sensitivity_dropped_frames") != PRED_SENSITIVITY_FRAMES:
        problems.add("invalid", f"predecessor sensitivity {block.get('sensitivity_dropped_frames')!r} recorded by "
                                f"the run is not the gate's dropped-frame scale (+{PRED_SENSITIVITY_FRAMES:g}): a "
                                "noise allowance is never borrowed and the scale is never widened")
    fixtures = [f for f in (block.get("fixtures") or [])]
    want_fixtures = list(declared.get("fixtures") or [])
    extra = [f for f in fixtures if f not in want_fixtures]
    missing = [f for f in want_fixtures if f not in fixtures]
    if extra or not fixtures:
        problems.add("invalid", f"predecessor fixtures {fixtures} are not the design's {want_fixtures}")
    if missing and not pilot:
        problems.add("invalid", f"predecessor fixtures {missing} declared by design {name} are missing")
    try:
        runs, warmup = int(block.get("runs")), int(block.get("warmup"))
    except (TypeError, ValueError):
        runs, warmup = 0, 0
        problems.add("invalid", f"predecessor block lacks runs/warmup ({block.get('runs')!r}, "
                                f"{block.get('warmup')!r})")
    if runs < 1:
        problems.add("invalid", f"predecessor runs {runs}: no paired run declared")
    if not pilot:
        if runs < int(declared.get("runs") or 0):
            problems.add("invalid", f"{runs} predecessor pairs declared, design {name} needs "
                                    f">= {declared.get('runs')} (missing paired runs)")
        if warmup < int(declared.get("warmup") or 0):
            problems.add("invalid", f"predecessor warmup {warmup} < {declared.get('warmup')} (one discarded "
                                    f"warm-up per fixture and arm)")

    # The binaries: D pinned, D != C, D != A, same flags as C (TextKit 2 ON).
    arms = plan["arms"]
    ref = plan.get("reference", "A")
    block_arms = block.get("arms") if isinstance(block.get("arms"), dict) else {}
    d_spec = dict(block_arms.get(PRED_ARM) or {})
    c_main = arms.get(PRED_AGAINST)
    d_sha = d_spec.get("sha256")
    if not d_sha:
        problems.add("invalid", f"predecessor block records no arm {PRED_ARM} with its app sha256 (no reference "
                                f"{PRED_ARM})", arm=PRED_ARM)
    if not c_main:
        problems.add("invalid", f"arm {PRED_AGAINST} is not in the plan: nothing to compare {PRED_ARM} with",
                     arm=PRED_AGAINST)
    c_spec = dict(c_main or {})
    if d_sha and c_main:
        if d_sha == c_spec.get("sha256"):
            problems.add("invalid", f"{PRED_ARM} and {PRED_AGAINST} are the same binary ({d_sha[:12]}): the "
                                    "predecessor must be the previous stage's build, not the candidate")
        if (block_arms.get(PRED_AGAINST) or {}).get("sha256") not in (None, c_spec.get("sha256")):
            problems.add("invalid", f"predecessor block's {PRED_AGAINST} sha256 "
                                    f"{block_arms[PRED_AGAINST].get('sha256')} != the plan's arm {PRED_AGAINST} "
                                    f"{c_spec.get('sha256')} (the supplement must measure the gated candidate)")
        if d_spec.get("required_flags") != c_spec.get("required_flags"):
            problems.add("invalid", f"{PRED_ARM} flags {d_spec.get('required_flags')} != {PRED_AGAINST} flags "
                                    f"{c_spec.get('required_flags')}: both must run TextKit 2 ON with the same flags")
        for arm, spec in ((PRED_ARM, d_spec), (PRED_AGAINST, c_spec)):
            if not pilot and not (spec.get("requires_completion") and spec.get("expected_renderer") == "textkit2"):
                problems.add("invalid", f"arm {arm} lacks completion/renderer markers (need a full traversal and "
                                        "renderer=textkit2)", arm=arm)
    if d_sha and d_sha == arms.get(ref, {}).get("sha256"):
        problems.add("invalid", f"{PRED_ARM} is the reference arm {ref}'s binary ({d_sha[:12]}): D never "
                                "substitutes for A")
    pin = declared.get("app_sha256")
    if pin and d_sha and d_sha != pin:
        problems.add("invalid", f"{PRED_ARM} app sha256 {d_sha} != the design's pinned predecessor {pin} "
                                f"({declared.get('source', 'no source')})", arm=PRED_ARM)

    # The fixture bytes: D and C open the same document, the gate's.
    c_fixtures = dict(c_spec.get("fixture_sha256") or {})
    c_fixtures.update((block_arms.get(PRED_AGAINST) or {}).get("fixture_sha256") or {})
    c_spec["fixture_sha256"] = c_fixtures
    d_fixtures = d_spec.get("fixture_sha256") or {}
    gate_fixtures = arms.get(ref, {}).get("fixture_sha256") or {}
    for fixture in fixtures:
        shas = {PRED_ARM: d_fixtures.get(fixture), PRED_AGAINST: c_fixtures.get(fixture)}
        for arm, sha in shas.items():
            if not sha:
                problems.add("invalid", f"predecessor block records no sha256 of {fixture}.json in arm {arm}'s .app",
                             fixture, arm)
        if gate_fixtures.get(fixture):
            shas[ref] = gate_fixtures[fixture]
        if len({v for v in shas.values() if v}) > 1:
            problems.add("invalid", f"{fixture}.json differs ("
                         + ", ".join(f"{a} {(v or '∅')[:12]}" for a, v in sorted(shas.items()))
                         + "): the predecessor pair must open the same document as the gate (altered fixture)",
                         fixture)

    # The trials: the gate's own row checks on a D-vs-C plan.
    path = csv_path or os.path.join(run_dir, str(block.get("csv") or PRED_CSV))
    out["csv"] = path
    rows: list[dict] = []
    if not os.path.exists(path):
        problems.add("invalid", f"no predecessor trials at {path} (the {PRED_ARM}/{PRED_AGAINST} block did not run)")
    else:
        try:
            rows = load_csv(path)
        except (OSError, SystemExit) as error:
            problems.add("invalid", f"cannot read the predecessor trials: {error}")
    clean: dict = {}
    usable = bool(fixtures) and runs >= 1 and bool(d_sha) and bool(c_main) and os.path.exists(path)
    if usable:
        sub = {"fixtures": fixtures, "runs": runs, "reference": PRED_ARM,
               "arms": {PRED_ARM: {**d_spec, "role": "baseline"}, PRED_AGAINST: c_spec},
               "fixture_arms": {f: [PRED_ARM, PRED_AGAINST] for f in fixtures},
               "sampler": plan.get("sampler", True), "footprint": plan.get("footprint", True)}
        clean = check_rows(rows, sub, problems, plan.get("expected_blocks", {}), pilot)
        for fixture in fixtures:
            first = {PRED_ARM: 0, PRED_AGAINST: 0}
            for run in range(1, runs + 1):
                d_row = clean.get((fixture, PRED_ARM), {}).get(run)
                c_row = clean.get((fixture, PRED_AGAINST), {}).get(run)
                if d_row is None or c_row is None:
                    continue
                order = {PRED_ARM: finite(d_row.get("order_index")), PRED_AGAINST: finite(c_row.get("order_index"))}
                if sorted(v for v in order.values() if v is not None) != [1.0, 2.0]:
                    problems.add("invalid", f"pair not interleaved: order_index {PRED_ARM}="
                                            f"{d_row.get('order_index') or '∅'}, {PRED_AGAINST}="
                                            f"{c_row.get('order_index') or '∅'} (need 1 and 2)", fixture, "", str(run))
                    continue
                first[PRED_ARM if order[PRED_ARM] == 1.0 else PRED_AGAINST] += 1
            if abs(first[PRED_ARM] - first[PRED_AGAINST]) > 1:
                problems.add("invalid", f"unbalanced order: {PRED_ARM} first in {first[PRED_ARM]} pairs, "
                                        f"{PRED_AGAINST} first in {first[PRED_AGAINST]}", fixture)
        if warmup > 0:
            warm_path = warmup_path or os.path.join(run_dir, str(block.get("warmup_csv") or PRED_WARMUP_CSV))
            warm_rows: list[dict] = []
            if not os.path.exists(warm_path):
                problems.add("invalid", f"no predecessor warm-up trials at {warm_path} ({warmup} declared per "
                                        "fixture and arm)")
            else:
                try:
                    warm_rows = load_csv(warm_path)
                except (OSError, SystemExit) as error:
                    problems.add("invalid", f"cannot read the predecessor warm-ups: {error}")
                # A warm-up counts only when it ran successfully; one that did
                # not (or a row of no declared fixture and arm) makes the
                # supplement INVALID even when enough others succeeded.
                ran = {(f, a): 0 for f in fixtures for a in (PRED_ARM, PRED_AGAINST)}
                specs = {PRED_ARM: d_spec, PRED_AGAINST: c_spec}
                list_proof, code_proof = list_proof_fixtures(), code_proof_fixtures()
                for r in warm_rows:
                    fixture, arm = r.get("fixture", ""), r.get("arm", "")
                    if (fixture, arm) not in ran:
                        problems.add("invalid", "warm-up row for an undeclared fixture/arm", fixture, arm, "0")
                        continue
                    why = warmup_problems(r, specs[arm], fixture, fixture in list_proof, fixture in code_proof)
                    for message in why:
                        problems.add("invalid", f"warm-up not successful: {message}", fixture, arm, "0")
                    if not why:
                        ran[(fixture, arm)] += 1
                for (fixture, arm), count in ran.items():
                    if count < warmup:
                        problems.add("invalid", f"warm-up trial missing ({count} of {warmup} ran successfully)",
                                     fixture, arm)
        for row in rows:
            run = finite(row.get("run"))
            if run is None or run < 1:
                continue
            why = host_sample_busy(finite(row.get("host_load1")), parse_top3(row.get("host_top3")))
            if why:
                out["host_busy_reasons"].append(f"{row.get('fixture')} {row.get('arm')} run {int(run)}: "
                                                + "; ".join(why))

    for fixture in fixtures:
        d_rows = list(clean.get((fixture, PRED_ARM), {}).values())
        c_rows = list(clean.get((fixture, PRED_AGAINST), {}).values())
        fx: dict = {"status": "COMPLETE", "rows": {}, "arms": {}, "counters": {}}
        for arm, arm_rows in ((PRED_ARM, d_rows), (PRED_AGAINST, c_rows)):
            fx["arms"][arm] = {m: describe([v for v in (metric_value(r, m) for r in arm_rows) if v is not None])
                               for m in PRED_METRICS + ["frames", "blocks", "host_load1"]}
            fx["counters"][arm] = {k: describe([v for v in (finite(r.get(k)) for r in arm_rows) if v is not None])
                                   for k in PRED_COUNTERS}
        frames = [v for v in (finite(r.get("frames")) for r in d_rows) if v]
        if len(d_rows) != runs or len(c_rows) != runs or not frames:
            # Complete-trial check: every declared pair, or no result.
            if not [p for p in problems.items if p["fixture"] in ("", fixture)]:
                problems.add("invalid", f"{len(d_rows)} {PRED_ARM} and {len(c_rows)} {PRED_AGAINST} clean trials of "
                                        f"{runs} declared pairs", fixture)
        if [p for p in problems.items if p["fixture"] in ("", fixture)]:
            fx["status"] = "INVALID"
        else:
            frames_ref = statistics.median(frames)
            fx["frames_ref"] = frames_ref
            # The same +2 frames in each metric's unit, by D's median frame
            # count: a rate of 2 / frames, a hitch of 2 frame intervals per
            # scroll second (2 × (scroll / frames) / scroll).
            scale = {"dropped_frames": PRED_SENSITIVITY_FRAMES,
                     "dropped_rate_pct": PRED_SENSITIVITY_FRAMES / frames_ref * 100.0,
                     "hitch_ms_per_s": PRED_SENSITIVITY_FRAMES / frames_ref * 1000.0}
            for metric in PRED_METRICS:
                entry = predecessor_result(pairs(clean, fixture, PRED_ARM, PRED_AGAINST, runs, metric), scale[metric])
                entry["over_ceiling"] = {arm: sum(1 for r in arm_rows if any(m == metric for m, _ in ceiling_breaches(r)))
                                         for arm, arm_rows in ((PRED_ARM, d_rows), (PRED_AGAINST, c_rows))}
                fx["rows"][metric] = entry
        out["fixtures"][fixture] = fx
    # The gated binary C failing a counted trial (a crash; a timeout, no
    # READY or an incomplete scroll on a row attributable to C) is a
    # candidate failure of the gate, not only of the supplement: gate()
    # adds these to its own problems (PRECEDENCE 1 and 3, the ledger). D's
    # failures and every warm-up stay here.
    unattributable = {(p["fixture"], p["run"]) for p in problems.items
                      if p["arm"] == PRED_AGAINST and p["kind"] == "invalid"}
    out["candidate_failures"] = [dict(p) for p in problems.items if p["arm"] == PRED_AGAINST and (
        p["kind"] == "crash" or (p["kind"] == "candidate_failure" and (p["fixture"], p["run"]) not in unattributable))]
    out["problems"] = problems.items
    out["runs"], out["warmup"] = runs, warmup
    out["arms"] = {PRED_ARM: {"label": d_spec.get("label", PRED_ARM), "sha256": d_sha},
                   PRED_AGAINST: {"label": c_spec.get("label", PRED_AGAINST), "sha256": c_spec.get("sha256")}}
    out["status"] = "INVALID" if problems.items else "COMPLETE"
    return out


def predecessor_outcome(sup: dict | None) -> str:
    """The supplement's outcome as the OVERALL line and summary.json name it
    ("" without a supplement): its status when it has no result, else every
    ADDED-REGRESSION and INCONCLUSIVE row by fixture. It never changes the
    verdict; it keeps an added regression or an unresolved result beside
    it, where a reader of the verdict line sees it."""
    if not sup:
        return ""
    head = f"{sup['arm']}/{sup['against']} supplement: "
    if sup.get("status") != "COMPLETE":
        return head + f"{sup.get('status')} (no result)"
    parts = []
    for result in ("ADDED-REGRESSION", "INCONCLUSIVE"):
        cells = [f"{fixture} ({', '.join(m for m, row in fx['rows'].items() if row['result'] == result)})"
                 for fixture, fx in sup["fixtures"].items()
                 if any(row["result"] == result for row in fx["rows"].values())]
        if cells:
            parts.append(f"{result} " + ", ".join(cells))
    return head + ("; ".join(parts) if parts else "NO-ADDED-REGRESSION (every fixture and metric)")


# ------------------------------------------------------------------ bounds


def load_bounds(path: str) -> tuple[dict | None, str | None]:
    if not path or not os.path.exists(path):
        return None, None
    with open(path, encoding="utf-8") as handle:
        return json.load(handle), sha256_file(path)


def bound_gate(bounds: dict | None, fixture: str, metric: str) -> tuple[bool, str]:
    """BOUNDS: (gated?, why) for a BOUND_GATED_METRICS metric on a fixture."""
    entry = ((bounds or {}).get("fixtures") or {}).get(fixture, {}).get(metric)
    if not entry or entry.get("p95_pct") is None:
        return False, "no measured bound"
    pct, absolute = float(entry["p95_pct"]), float(entry.get("p95_abs") or 0.0)
    floor = REL_ABS_FLOORS.get(metric)
    if pct <= REL_LIMIT_PCT or (floor is not None and absolute <= floor):
        return True, f"bound {pct:.1f} % <= {REL_LIMIT_PCT:g} %"
    return False, f"bound {pct:.1f} % > {REL_LIMIT_PCT:g} %"


def bound_gated_fixtures(bounds: dict | None, fixtures: list[str]) -> dict:
    """metric -> the fixtures it gates (the rest are advisory)."""
    return {m: [f for f in fixtures if bound_gate(bounds, f, m)[0]] for m in BOUND_GATED_METRICS}


def percentile_nearest_rank(values: list[float], pct: float) -> float:
    ordered = sorted(values)
    return ordered[max(int(math.ceil(pct / 100.0 * len(ordered))) - 1, 0)]


def measure_bounds(rows: list[dict], plan: dict, csv_path: str) -> dict:
    """BOUNDS from an A–A′ run (perf-gate.sh --calibrate on untouched main)."""
    problems = Problems()
    if plan.get("mode") != "calibrate":
        problems.add("invalid", f"plan mode is {plan.get('mode')!r}; bounds come from an A–A′ (calibrate) run")
    ref, cands = plan.get("reference", "A"), plan.get("candidates", [])
    rep_arm = cands[0] if cands else "A2"
    check_fixture_hashes(plan, None, problems)
    clean = check_rows(rows, plan, problems, plan.get("expected_blocks", {}), True)
    runs = int(plan["runs"])
    out = {"version": 1, "kind": "perf-resolution-bounds", "created_utc": now_utc(),
           "source_csv": os.path.abspath(csv_path), "source_csv_sha256": sha256_file(csv_path),
           "app_sha256": plan["arms"].get(ref, {}).get("sha256"), "pairs_per_gate": BOUND_PAIRS,
           "fixture_sha256": dict(plan["arms"].get(ref, {}).get("fixture_sha256") or {}),
           "percentile": BOUND_PERCENTILE,
           "method": f"{BOUND_PERCENTILE:g}th percentile (nearest rank) of |median of {BOUND_PAIRS} A–A′ deltas| "
                     f"over every {BOUND_PAIRS}-subset of the clean pairs; p95_pct relative to A's median",
           "fixtures": {}, "problems": []}
    for fixture in plan["fixtures"]:
        out["fixtures"][fixture] = {}
        for metric in LATENCY + MEMORY:
            deltas = pairs(clean, fixture, ref, rep_arm, runs, metric)
            a_vals = [v for v in (metric_value(r, metric) for r in clean.get((fixture, ref), {}).values()) if v is not None]
            if len(deltas) < BOUND_PAIRS or not a_vals:
                problems.add("invalid", f"{metric}: {len(deltas)} clean pairs < {BOUND_PAIRS}", fixture)
                continue
            medians = [abs(statistics.median(t)) for t in itertools.combinations(deltas, BOUND_PAIRS)]
            p95 = percentile_nearest_rank(medians, BOUND_PERCENTILE)
            a_median = statistics.median(a_vals)
            out["fixtures"][fixture][metric] = {"n_pairs": len(deltas), "n_subsets": len(medians),
                                                "a_median": a_median, "p95_abs": p95,
                                                "p95_pct": p95 / a_median * 100.0 if a_median else None}
    out["problems"] = problems.items
    out["verdict"] = "INVALID" if problems.items else "MEASURED"
    return out


def render_bounds(b: dict) -> str:
    lines = [f"# perf resolution bounds — **{b['verdict']}**", "",
             f"Source: `{b['source_csv']}` (sha256 `{b['source_csv_sha256'][:12]}`); reference "
             f"`{(b.get('app_sha256') or '')[:12]}`. Method: {b['method']}.", ""]
    for p in b.get("problems", []):
        lines.append(f"- [{p['kind']}] {p['fixture']}: {p['message']}")
    lines += ["", "| fixture | metric | A median | bound | bound / A | gates at 15 %? |", "|---|---|---:|---:|---:|---|"]
    for fixture, metrics in b["fixtures"].items():
        for metric, m in metrics.items():
            gated = bound_gate(b, fixture, metric)[1] if metric in BOUND_GATED_METRICS else "always gated"
            pct = m.get("p95_pct")
            lines.append(f"| {fixture} | {LABELS.get(metric, metric)} | {fmt(m['a_median'], metric)} | "
                         f"{fmt(m['p95_abs'], metric)} | {'–' if pct is None else f'{pct:.1f} %'} | {gated} |")
    lines.append("")
    return "\n".join(lines)


def merge_bounds(base: dict | None, measured: dict) -> tuple[dict | None, list[str]]:
    """Adds the fixtures of a --measure-bounds result to the frozen bounds.
    Never replaces an entry (a bound is frozen once gates have used it) and
    records each added fixture's own provenance in fixture_sources, since the
    top-level app_sha256 describes only the entries measured with it."""
    errors = []
    if measured.get("kind") != "perf-resolution-bounds" or measured.get("verdict") != "MEASURED":
        errors.append(f"measured bounds verdict {measured.get('verdict')!r} (need MEASURED from --measure-bounds)")
    if not isinstance(base, dict) or not isinstance(base.get("fixtures"), dict):
        errors.append("no base bounds file to merge into (--bounds)")
        return None, errors
    for key in ("pairs_per_gate", "percentile"):
        if base.get(key) != measured.get(key):
            errors.append(f"{key} {measured.get(key)!r} != base {base.get(key)!r} (bounds must share one method)")
    added = measured.get("fixtures") or {}
    if not added:
        errors.append("measured bounds name no fixtures")
    clash = sorted(f for f in added if f in base["fixtures"])
    if clash:
        errors.append(f"already bounded: {clash} (frozen; a replacement needs its own reviewed change)")
    if errors:
        return None, errors
    out = json.loads(json.dumps(base))
    sources = out.setdefault("fixture_sources", {})
    for fixture, metrics in added.items():
        out["fixtures"][fixture] = metrics
        sources[fixture] = {"app_sha256": measured.get("app_sha256"),
                            "fixture_sha256": (measured.get("fixture_sha256") or {}).get(fixture),
                            "source_csv": measured.get("source_csv"),
                            "source_csv_sha256": measured.get("source_csv_sha256"),
                            "measured_utc": measured.get("created_utc"), "merged_utc": now_utc()}
    return out, []


# ------------------------------------------------------------- calibration


def resolve_pilot(plan: dict, args: argparse.Namespace, problems: Problems) -> bool:
    pilot = bool(plan.get("pilot", False))
    if bool(args.pilot) != pilot:
        problems.add("invalid", f"--pilot {'given' if args.pilot else 'absent'} but plan.pilot = {pilot} "
                                "(the plan decides)")
    return pilot


def calibrate(rows: list[dict], plan: dict, args: argparse.Namespace, csv_path: str) -> dict:
    problems = Problems()
    pilot = resolve_pilot(plan, args, problems)
    if plan.get("mode") != "calibrate":
        problems.add("invalid", f"plan mode is {plan.get('mode')!r}, not 'calibrate'")
    arms = plan["arms"]
    ref, cands = plan.get("reference", "A"), plan.get("candidates", [])
    if len(cands) != 1 or ref not in arms or cands[0] not in arms:
        problems.add("invalid", "calibration needs exactly one reference and one repeat arm")
    elif arms[ref].get("sha256") != arms[cands[0]].get("sha256"):
        problems.add("invalid", "calibration arms must be the same .app (same sha256)")
    host_busy = host_state(plan, rows, problems, pilot)
    check_fixture_arms(plan, problems)
    check_fixture_hashes(plan, None, problems)
    if not pilot:
        if int(plan.get("warmup", 0)) < 1:
            problems.add("invalid", "warmup 0: one discarded warm-up per fixture and arm is required")
    clean = check_rows(rows, plan, problems, plan.get("expected_blocks", {}), pilot)
    runs = int(plan["runs"])
    min_pairs = PILOT_PAIRS if pilot else MIN_PAIRS
    if runs < min_pairs:
        problems.add("invalid", f"{runs} runs declared; calibration needs >= {min_pairs}")
    metrics = gated_metrics(plan)
    rep = cands[0] if cands else "A2"
    result = {"version": 3, "kind": "perf-calibration", "created_utc": now_utc(), "source_csv": os.path.abspath(csv_path),
              "source_csv_sha256": sha256_file(csv_path), "plan_sha256": plan.get("_sha256"),
              "app_sha256": arms.get(ref, {}).get("sha256"), "attempt": args.attempt, "pilot": pilot,
              "floors": FLOORS, "ceilings": {"latency_and_memory_pct_of_median": CEILING_PCT,
                                             "dropped_frames": CEILING_DROPPED,
                                             "applies_only_above_floor": True},
              "fixtures": {}, "problems": [], "host_busy": host_busy}
    noisy = False
    for fixture in plan["fixtures"]:
        entry = {"n_pairs": 0, "metrics": {}, "verdict": "CALIBRATED"}
        for metric in metrics:
            deltas = pairs(clean, fixture, ref, rep, runs, metric)
            a_vals = [v for v in (metric_value(r, metric) for r in clean.get((fixture, ref), {}).values()) if v is not None]
            a_median = statistics.median(a_vals) if a_vals else None
            max_abs = max((abs(d) for d in deltas), default=None)
            floor = FLOORS[metric]
            if metric in LATENCY or metric in MEMORY:
                ceiling = None if a_median is None else a_median * CEILING_PCT / 100.0
                rule = f"{CEILING_PCT:g}% of A median"
            elif metric == "dropped_frames":
                ceiling, rule = CEILING_DROPPED, f"{CEILING_DROPPED:g} frames"
            else:
                ceiling, rule = None, "none (per-trial absolute ceilings apply)"
            too_noisy = bool(max_abs is not None and ceiling is not None and max_abs > ceiling and max_abs > floor)
            noisy |= too_noisy
            entry["n_pairs"] = max(entry["n_pairs"], len(deltas))
            allowance = None if max_abs is None else max(max_abs, floor)
            entry["metrics"][metric] = {
                "deltas": [round(d, 4) for d in deltas], "max_abs_delta": max_abs, "floor": floor,
                "allowance": allowance, "a_median": a_median,
                "allowance_pct_of_median": (allowance / a_median * 100.0) if allowance is not None and a_median else None,
                "ceiling": ceiling, "ceiling_rule": rule, "noisy": too_noisy,
            }
            if len(deltas) < min_pairs:
                problems.add("invalid", f"{metric}: {len(deltas)} clean pairs < {min_pairs}", fixture)
        if any(m["noisy"] for m in entry["metrics"].values()):
            entry["verdict"] = "INCONCLUSIVE"
        result["fixtures"][fixture] = entry
    result["problems"] = problems.items
    if problems.items:
        result["verdict"] = "INVALID"
    elif noisy:
        result["verdict"] = "INCONCLUSIVE"
    elif pilot:
        result["verdict"] = "PILOT"
    else:
        result["verdict"] = "CALIBRATED"
    return result


# -------------------------------------------------------------------- gate


def compare_median_relative(metric: str, deltas: list[float], a_median: float | None, gated: bool = True) -> dict:
    """Rule pr45 for one (fixture, arm, metric); `gated` False makes a
    latency/memory verdict advisory (BOUNDS)."""
    entry = {"n": len(deltas), "deltas": [round(d, 4) for d in deltas], "median_delta": None, "a_median": a_median,
             "median_rel_pct": None, "limit": None, "verdict": "n/a"}
    if not deltas:
        return entry
    med = statistics.median(deltas)
    entry["median_delta"] = med
    if a_median:
        entry["median_rel_pct"] = med / a_median * 100.0
    if metric == "dropped_frames":
        entry["limit"] = f"median Δ ≤ {DROPPED_DELTA_MAX:g} frames"
        entry["verdict"] = "FAIL" if med > DROPPED_DELTA_MAX else "PASS"
    elif metric in ("dropped_rate_pct", "hitch_ms_per_s"):
        entry["limit"] = "per-trial ceiling"
        entry["verdict"] = "ceiling"
    elif metric in LATENCY or metric in MEMORY:
        floor = REL_ABS_FLOORS.get(metric)
        entry["limit"] = f"median Δ ≤ {REL_LIMIT_PCT:g} % of A" + (f" or ≤ {floor:g} ms" if floor else "")
        over = entry["median_rel_pct"] is not None and entry["median_rel_pct"] > REL_LIMIT_PCT
        if floor is not None and med <= floor:
            over = False
        if entry["median_rel_pct"] is None:
            entry["verdict"] = "n/a"
        elif not gated:
            entry["verdict"] = f"ADVISORY >{REL_LIMIT_PCT:g} %" if over else "advisory"
        else:
            entry["verdict"] = "FAIL" if over else "PASS"
    return entry


def compare_ucb(deltas: list[float], allowance: float | None, min_pairs: int) -> dict:
    n = len(deltas)
    entry = {"n": n, "allowance": allowance, "mean": None, "sd": None, "t": None, "ucb95": None, "verdict": "n/a"}
    if n >= 2:
        mean = statistics.fmean(deltas)
        sd = statistics.stdev(deltas)
        t = t95(n - 1)
        ucb = mean + t * sd / math.sqrt(n)
        entry.update(mean=mean, sd=sd, t=t, ucb95=ucb)
        if n >= min_pairs and allowance is not None:
            entry["verdict"] = "PASS" if ucb <= allowance else "FAIL"
    return entry


def gate(rows: list[dict], plan: dict, args: argparse.Namespace, calibration: dict | None,
         calibration_path: str | None, bounds: dict | None = None, bounds_sha: str | None = None) -> dict:
    problems = Problems()
    pilot = resolve_pilot(plan, args, problems)
    check_fixture_arms(plan, problems)
    declared = fixture_arms(plan)
    if plan.get("mode") != "gate":
        problems.add("invalid", f"plan mode is {plan.get('mode')!r}, not 'gate'")
    design, reduced = design_conformance(plan, problems, pilot)
    check_fixture_hashes(plan, design, problems)
    rule = design["rule"] if design else None
    arms = plan["arms"]
    ref = plan.get("reference", "A")
    # KNOWN DEBT / PREDECESSOR: a design whose declarations are refused
    # measures nothing; and D never substitutes for A or joins the gate.
    refused_design = design_errors(plan.get("design"))
    for message in refused_design:
        problems.add("invalid", f"design refused: {message}")
    pred_declared = (design or {}).get("predecessor")
    if pred_declared:
        if PRED_ARM in arms or ref == PRED_ARM or PRED_ARM in plan.get("candidates", []):
            problems.add("invalid", f"arm {PRED_ARM} (the predecessor) is an arm of the A/B/C plan: D never "
                                    "substitutes for A and is never a gated arm")
        pin = pred_declared.get("app_sha256")
        if pin and arms.get(ref, {}).get("sha256") == pin:
            problems.add("invalid", f"reference arm {ref} is the design's pinned predecessor binary ({pin[:12]}): "
                                    "D never substitutes for A")
    cands = [c for c in plan.get("candidates", []) if c in arms]
    if ref not in arms or not cands:
        problems.add("invalid", "plan needs a reference arm and at least one candidate arm")
    runs = int(plan["runs"])
    if pilot:
        min_pairs = PILOT_PAIRS
    else:
        # A reduced plan is INCOMPLETE (below), not INVALID for its own count.
        min_pairs = min(design["runs"], runs) if design else MIN_PAIRS
    host_busy = host_state(plan, rows, problems, pilot)
    metrics = gated_metrics(plan)

    # BOUNDS: which fixtures a bound-gated metric gates, frozen in the plan.
    gated_by_bound = bound_gated_fixtures(bounds, plan["fixtures"])
    if rule == "median-relative":
        if plan.get("bounds_sha256") is not None and plan.get("bounds_sha256") != bounds_sha:
            problems.add("invalid", f"bounds file sha256 {bounds_sha} != {plan.get('bounds_sha256')} recorded when "
                                    "the run started (bounds changed after the run was declared)")
        if plan.get("bound_gated") is not None and plan.get("bound_gated") != gated_by_bound:
            problems.add("invalid", f"bound-gated fixtures {gated_by_bound} != {plan.get('bound_gated')} recorded "
                                    "when the run started")

    # Calibration (rule calibrated-ucb only): frozen, same reference build,
    # created before the first counted trial.
    allowances: dict = {}
    cal_verdict = None
    if rule == "calibrated-ucb":
        if calibration is None:
            if not pilot:
                problems.add("invalid", "no --calibration given (only a pilot may run on floors alone)")
            for fixture in plan["fixtures"]:
                allowances[fixture] = dict(FLOORS)
        else:
            cal_verdict = calibration.get("verdict")
            if cal_verdict == "PILOT" and not pilot:
                problems.add("invalid", "calibration is a pilot calibration; rerun it with >= 10 pairs")
            elif cal_verdict not in ("CALIBRATED", "INCONCLUSIVE", "PILOT"):
                problems.add("invalid", f"calibration verdict {cal_verdict!r} is not usable")
            if calibration.get("app_sha256") != arms.get(ref, {}).get("sha256"):
                problems.add("invalid", f"calibration reference sha256 {calibration.get('app_sha256')} != plan A "
                             f"{arms.get(ref, {}).get('sha256')}")
            frozen = (plan.get("calibration") or {}).get("sha256")
            if not frozen:
                problems.add("invalid", "plan does not record the calibration sha256 (not frozen before the run)")
            elif calibration_path and sha256_file(calibration_path) != frozen:
                problems.add("invalid", "calibration file changed after the gate run started (sha256 differs)")
            created = parse_utc(calibration.get("created_utc"))
            starts = [parse_utc(r.get("started_utc")) for r in rows if (finite(r.get("run")) or 0) >= 1]
            if created is None:
                problems.add("invalid", "calibration has no created_utc")
            elif not pilot and (not starts or any(s is None for s in starts)):
                problems.add("invalid", "trial start times (started_utc) missing; cannot prove the calibration "
                                        "predates the candidate trials")
            elif starts and all(starts) and created > min(starts):
                problems.add("invalid", f"calibration created {calibration.get('created_utc')} after the first "
                                        "counted trial started (not frozen before candidate inspection)")
            for fixture in plan["fixtures"]:
                cal_fixture = calibration.get("fixtures", {}).get(fixture)
                if not cal_fixture:
                    problems.add("invalid", "fixture missing from the calibration", fixture)
                    continue
                allowances[fixture] = {}
                for metric in metrics:
                    cm = cal_fixture.get("metrics", {}).get(metric)
                    if not cm or cm.get("allowance") is None:
                        problems.add("invalid", f"calibration has no allowance for {metric}", fixture)
                        continue
                    allowances[fixture][metric] = float(cm["allowance"])
    elif calibration is not None:
        problems.add("invalid", f"design {plan.get('design')} takes no calibration")

    clean = check_rows(rows, plan, problems, plan.get("expected_blocks", {}), pilot)
    cand_ceiling = check_ceilings(clean, plan, problems)

    fixtures_out: dict = {}
    stat_fail = bool(cand_ceiling)
    for fixture in plan["fixtures"]:
        fx: dict = {"arms": {}, "comparisons": {}, "renderer": {}, "sampler": {}, "tk1_share": None,
                    "ceiling_breaches": [b for b in cand_ceiling if b["fixture"] == fixture]}
        for arm in [a for a in declared[fixture] if a in arms]:
            arm_rows = list(clean[(fixture, arm)].values())
            fx["arms"][arm] = {m: describe([v for v in (metric_value(r, m) for r in arm_rows) if v is not None])
                               for m in metrics + ["frames", "blocks", "scroll_ms", "trial_wall_ms", "host_load1"]}
            fx["renderer"][arm] = {k: describe([v for v in (finite(r.get(k)) for r in arm_rows) if v is not None])
                                   for k in ["tk2_live_ready", "tk2_live", "tk2_layouts", "tk2_draws", NATIVE_DRAWS,
                                             TK1_BACKED_ROWS, TK1_BACKED_DRAWS, "eligible_roots", "fallback_roots",
                                             "text_fallback_roots", LINK_ROOTS, LIST_LIVE_READY, LIST_LIVE,
                                             *LEAF_COLUMNS, CONVERSIONS, CODE_LIVE_READY, CODE_LIVE, CODE_DRAWS,
                                             *CODE_COLUMNS]}
            fx["sampler"][arm] = {k: describe([v for v in (finite(r.get(k)) for r in arm_rows) if v is not None])
                                  for k in ["rss_interval_ms_median", "rss_interval_ms_max",
                                            "footprint_interval_ms_median", "footprint_interval_ms_max",
                                            "memory_samples", "footprint_samples"]}
            if arms[arm].get("expected_renderer") == "textkit2":
                fx["tk1_share"] = tk1_share(arm_rows)
        for arm in [a for a in cands if a in declared[fixture]]:
            comp = {}
            for metric in metrics:
                deltas = pairs(clean, fixture, ref, arm, runs, metric)
                if len(deltas) < min_pairs:
                    problems.add("insufficient", f"{arm} {metric}: {len(deltas)} clean pairs < {min_pairs}",
                                 fixture, arm)
                if rule == "median-relative":
                    a_desc = fx["arms"].get(ref, {}).get(metric)
                    gated = metric not in BOUND_GATED_METRICS or fixture in gated_by_bound[metric]
                    entry = compare_median_relative(metric, deltas, a_desc["median"] if a_desc else None, gated)
                    if not gated:
                        entry["limit"] = f"advisory ({bound_gate(bounds, fixture, metric)[1]})"
                else:
                    entry = compare_ucb(deltas, allowances.get(fixture, {}).get(metric), min_pairs)
                stat_fail |= entry["verdict"] == "FAIL"
                comp[metric] = entry
            fx["comparisons"][arm] = comp
        fixtures_out[fixture] = fx

    # PREDECESSOR: the D vs C supplement, from its own rows and problems. A
    # declared supplement that is missing or invalid reduces the design; its
    # results (PRED_RESULTS) change nothing. A failure of the gated binary C
    # in its counted trials is the gate's own candidate failure.
    supplement = None
    if design is not None and not refused_design:
        csv_arg = getattr(args, "csv", None)
        run_dir = os.path.dirname(os.path.abspath(csv_arg)) if csv_arg else os.getcwd()
        supplement = predecessor_supplement(plan, plan.get("design"), design, pilot, run_dir,
                                            getattr(args, "predecessor_csv", None),
                                            getattr(args, "predecessor_warmup_csv", None))
        for p in (supplement or {}).get("candidate_failures", []):
            problems.add(p["kind"], f"D/C supplement trial: {p['message']}", p["fixture"], p["arm"], p["run"])
        if supplement is not None and supplement["status"] != "COMPLETE":
            reduced.append(f"paired predecessor supplement {supplement['status']} ({PRED_ARM} vs {PRED_AGAINST}; "
                           f"design {plan.get('design')} enforces it)")
    # KNOWN DEBT: labels only; stat_fail and every verdict stay as computed.
    known_debt = None if refused_design else annotate_known_debt(design, plan, fixtures_out, cand_ceiling, problems,
                                                                 clean, ref, runs, rule)

    crashes = problems.of("crash")
    invalid = problems.of("invalid") + problems.of("baseline_failure")
    cand_fail = problems.of("candidate_failure")
    if crashes:
        verdict = "FAIL"
    elif invalid:
        verdict = "INVALID"
    elif cand_fail:
        verdict = "FAIL"
    elif problems.of("insufficient"):
        verdict = "INVALID"
    elif cal_verdict == "INCONCLUSIVE":
        verdict = "INCONCLUSIVE"
    elif stat_fail:
        verdict = "FAIL"
    elif pilot:
        verdict = "PILOT"
    elif reduced:
        verdict = "INCOMPLETE"
    else:
        verdict = "PASS"
    if verdict == "FAIL" and host_busy:
        verdict = "FAIL-HOST-BUSY"

    return {"version": 3, "kind": "perf-gate-summary", "created_utc": now_utc(), "verdict": verdict,
            "host_busy": bool(host_busy), "host_busy_reasons": host_busy, "fixture_arms": declared,
            "bounds": {"path": getattr(args, "bounds", None), "sha256": bounds_sha, "gated": gated_by_bound,
                       "why": {m: {f: bound_gate(bounds, f, m)[1] for f in plan["fixtures"]}
                               for m in BOUND_GATED_METRICS}},
            "design": plan.get("design"), "rule": rule, "reduced": reduced, "plan": plan, "reference": ref,
            "candidates": cands, "metrics": metrics, "pilot": pilot, "min_pairs": min_pairs,
            "calibration": calibration_path, "calibration_verdict": cal_verdict, "problems": problems.items,
            "fixtures": fixtures_out, "candidate_sha256": {a: arms[a].get("sha256") for a in cands},
            "known_debt": known_debt, "predecessor": supplement,
            "predecessor_outcome": predecessor_outcome(supplement)}


# ------------------------------------------------------------------ ledger


def apply_ledger(result: dict, ledger_path: str, run_dir: str) -> None:
    """The rerun rule across runs (see RERUN LEDGER)."""
    result["ledger"] = ledger_path
    result["rerun_count"] = 0
    prior = []
    included = DESIGNS.get(result.get("design") or "", {}).get("includes", [])
    included_fails = []
    if os.path.exists(ledger_path):
        with open(ledger_path, encoding="utf-8") as handle:
            for line in handle:
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if (entry.get("run_dir") == run_dir or entry.get("candidate_sha256") != result.get("candidate_sha256")
                        or entry.get("pilot")):
                    continue
                if entry.get("design") == result.get("design"):
                    prior.append(entry)
                elif (entry.get("design") in included
                      and (entry.get("verdict_before_refusal") or entry.get("verdict")) == "FAIL"):
                    included_fails.append(entry)
    by_dir: dict = {}
    for entry in prior:
        by_dir[entry["run_dir"]] = entry.get("verdict_before_refusal") or entry.get("verdict")
    if not result.get("pilot"):
        if "FAIL" in by_dir.values():
            result["refused"] = "a FAIL is never rerun to green without a code change (candidate sha256 unchanged)"
        elif included_fails:
            result["refused"] = (f"these candidate binaries FAILed design {included_fails[0].get('design')} "
                                 f"({included_fails[0].get('run_dir')}), which design {result.get('design')} "
                                 "includes: a FAIL is never rerun to green without a code change")
        elif result["verdict"] == "FAIL-HOST-BUSY" and "FAIL-HOST-BUSY" in by_dir.values():
            # The one quiet-window rerun is spent: this FAIL counts.
            result["host_busy_rerun_spent"] = True
            result["verdict"] = "FAIL"
        else:
            reruns = sum(1 for v in by_dir.values() if v in ("INCONCLUSIVE", "INVALID"))
            result["rerun_count"] = reruns
            if reruns >= 2:
                result["refused"] = "only one predeclared rerun after an INCONCLUSIVE/INVALID run"
    if result.get("refused"):
        result["verdict_before_refusal"] = result["verdict"]
        result["verdict"] = "REFUSED"
    with open(ledger_path, "a", encoding="utf-8") as handle:
        handle.write(json.dumps({"run_dir": run_dir, "design": result.get("design"), "pilot": result.get("pilot"),
                                 "candidate_sha256": result.get("candidate_sha256"), "verdict": result["verdict"],
                                 "verdict_before_refusal": result.get("verdict_before_refusal"),
                                 "created_utc": result["created_utc"]}, sort_keys=True) + "\n")


# ------------------------------------------------------------------ output


def now_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def fmt(value: float | None, metric: str = "") -> str:
    if value is None:
        return "–"
    if metric.endswith("_kb") or metric in ("dropped_frames", "blocks", "frames"):
        return f"{value:,.0f}" if abs(value - round(value)) < 1e-9 else f"{value:,.1f}"
    if metric in ("dropped_rate_pct", "hitch_ms_per_s"):
        return f"{value:.3f}"
    return f"{value:.1f}"


def fmt_desc(d: dict | None, metric: str) -> str:
    if not d:
        return "–"
    return f"{fmt(d['median'], metric)} ({fmt(d['min'], metric)}–{fmt(d['max'], metric)})"


def fmt_pct(value: float | None) -> str:
    return "–" if value is None else f"{value:+.1f} %"


def share_line(share: dict | None) -> str:
    if not share:
        return "TextKit 1-backed share (C): no clean C rows."
    def pct(value: float | None) -> str:
        return "–" if value is None else f"{value:.1f} %"
    return (f"TextKit 1-backed share (C, median per trial): link roots {fmt(share[LINK_ROOTS], 'frames')} of "
            f"{fmt(share['eligible_roots'], 'frames')} eligible roots ({pct(share['link_root_share_pct'])}); "
            f"TextKit 1 draws {fmt(share[TK1_BACKED_DRAWS], 'frames')} of {fmt(share['tk2_draws'], 'frames')} "
            f"TK2-row draws ({pct(share['tk1_draw_share_pct'])}); native TextKit 2 draws "
            f"{fmt(share[NATIVE_DRAWS], 'frames')}; TextKit 1-backed rows live at the end "
            f"{fmt(share[TK1_BACKED_ROWS], 'frames')}." + leaf_line(share, pct) + code_line(share, pct)
            + work_line(share))


def work_line(share: dict) -> str:
    """The work counters of a C arm (structural diagnostics, never gated):
    TextKit 2 layouts and prepared-text conversions since launch."""
    if share.get("tk2_layouts") is None:
        return ""
    return (f" Work counters (diagnostics, not gated; since launch at the end of the trial): layouts "
            f"{fmt(share['tk2_layouts'], 'frames')}, conversions {fmt(share.get(CONVERSIONS), 'frames')}.")


def leaf_line(share: dict, pct) -> str:
    """The leaf coverage of the F4 scope (root richText + list text), when the
    build reports it (lists stage); empty otherwise."""
    if share.get(ELIGIBLE_LEAVES) is None:
        return ""
    return (f" Leaf coverage (root richText + list text, potential): list leaves "
            f"{fmt(share[LIST_LEADER_LEAVES], 'frames')} leaders + {fmt(share[LIST_TRAILING_LEAVES], 'frames')} "
            f"trailing; eligible text leaves {fmt(share[ELIGIBLE_LEAVES], 'frames')}, linked (TextKit 1-backed) "
            f"{fmt(share[LINKED_LEAVES], 'frames')} ({pct(share['linked_leaf_share_pct'])}), SwiftUI fallback "
            f"{fmt(share[FALLBACK_LEAVES], 'frames')} ({pct(share['fallback_leaf_share_pct'])} of eligible + "
            f"fallback); live TextKit 2 list rows at READY / end {fmt(share[LIST_LIVE_READY], 'frames')} / "
            f"{fmt(share[LIST_LIVE], 'frames')}.")


def code_line(share: dict, pct) -> str:
    """The code coverage of a build that reports it (code-block stage): the
    static potential, then, separately, what the view-time gate (canvas
    caps, layout direction) admitted at this run's environment; empty
    otherwise."""
    if share.get(ELIGIBLE_CODE) is None:
        return ""
    return (f" Code blocks (top-level, static potential): eligible {fmt(share[ELIGIBLE_CODE], 'frames')}, SwiftUI "
            f"fallback {fmt(share[FALLBACK_CODE], 'frames')} ({pct(share['fallback_code_share_pct'])} of eligible + "
            f"fallback). Measured at this run's configuration: admitted {fmt(share[CODE_ADMITTED], 'frames')}, "
            f"gated to SwiftUI at view time {fmt(share[CODE_GATED], 'frames')} ({pct(share['gated_code_share_pct'])} of "
            f"admitted + gated); native code draws {fmt(share[CODE_DRAWS], 'frames')}; live TextKit 2 code rows at "
            f"READY / end {fmt(share[CODE_LIVE_READY], 'frames')} / {fmt(share[CODE_LIVE], 'frames')}.")


DEBT_STATUS_TEXT = {
    "known-debt-fail": "**FAIL** (known debt; still counts as a failure)",
    "improved": "passes in this run: improved",
    "withheld": "annotation withheld (a problem in this cell or the run)",
    "not-evaluated": "not evaluated in this run",
    "not-run": "not run (the plan omits this fixture or arm)",
}


def render_known_debt(summary: dict) -> list[str]:
    """KNOWN DEBT section: annotations and counts, never a verdict."""
    debt = summary.get("known_debt")
    if not debt:
        return []
    lines = ["## Known debt (annotation only)", "",
             "Rows that failed in an earlier stage's final shipped result and were accepted as debt. A listed row "
             "that fails here still counts as a failure: the verdict, the exit code and the ledger are those of "
             "the full A/B/C gate, and no verdict excludes these rows. A listed row that passes is reported as "
             "improved; an annotation never creates an allowance.", "",
             "| fixture | arm | metric | rule | this run | source |", "|---|---|---|---|---|---|"]
    for entry in debt["entries"]:
        state = DEBT_STATUS_TEXT.get(entry["status"], entry["status"])
        if entry.get("trials"):
            state += f" (trials {', '.join(entry['trials'])})"
        if entry.get("why"):
            state += f": {entry['why']}"
        lines.append(f"| {entry['fixture']} | {entry['arm']} | {LABELS.get(entry['metric'], entry['metric'])} | "
                     f"{entry['rule']} | {state} | {entry['source']} |")
    lines += ["", f"Failing rule and ceiling rows in this run: {debt['failing_rows']}; labelled as known debt: "
                  f"{debt['annotated_rows']}; not labelled: {len(debt['not_annotated'])}"
                  + ("." if not debt["not_annotated"] else
                     " (" + "; ".join(f"{r['fixture']} {r['arm']} {LABELS.get(r['metric'], r['metric'])} [{r['rule']}]"
                                      for r in debt["not_annotated"]) + ")."), ""]
    return lines


def render_predecessor(summary: dict) -> list[str]:
    """PREDECESSOR section: the D vs C supplement, labelled apart from the
    A/B/C verdict."""
    sup = summary.get("predecessor")
    if not sup:
        return []
    lines = [f"## Paired predecessor supplement, {sup['arm']} vs {sup['against']} — {sup['status']}"
             + (" (pilot)" if sup.get("pilot") else ""), "",
             "Separate from the A/B/C verdict: its results never change it (the verdict line names them), while a "
             f"crash, timeout or incomplete scroll of the gated binary {sup['against']} in a counted trial is a "
             f"candidate failure of the gate; {sup['arm']} never replaces the reference "
             "arm. Method, frozen in the design before any candidate timing: interleaved, balanced "
             f"{sup['arm']},{sup['against']} / {sup['against']},{sup['arm']} pairs after the warm-ups; paired "
             f"differences {sup['against']} − {sup['arm']}; sensitivity = the gate's dropped-frame scale "
             f"(+{sup['sensitivity_dropped_frames']:g} frames; for the dropped rate and the hitch ratio the same "
             f"frames converted with {sup['arm']}'s median frame count); one-sided "
             f"{100 * (1 - sup['alpha']):g} % distribution-free bounds on the median paired difference (needs >= "
             f"{sup['min_pairs']} pairs). Upper bound ≤ sensitivity: NO-ADDED-REGRESSION; lower bound > sensitivity: "
             "ADDED-REGRESSION; otherwise INCONCLUSIVE (the pairs cannot resolve the sensitivity; never "
             "\"unchanged\"). No noise allowance is used.", ""]
    if sup.get("arms"):
        lines.append("Arms: " + ", ".join(f"{a} = {spec.get('label', a)} (`{(spec.get('sha256') or '')[:12]}`)"
                                          for a, spec in sup["arms"].items())
                     + f"; {sup.get('runs')} pairs + {sup.get('warmup')} warm-up(s) per fixture.  ")
    busy = sup.get("host_busy_reasons") or []
    if busy:
        lines.append(f"HOST-BUSY in {len(busy)} supplement trial samples: " + " | ".join(busy[:6])
                     + (f" | … {len(busy) - 6} more" if len(busy) > 6 else "") + "  ")
    if sup.get("status") != "COMPLETE":
        lines += ["", f"No incremental result where the supplement is {sup['status']}: it is not evidence that "
                      "nothing regressed."]
    for p in (sup.get("problems") or [])[:30]:
        where = " ".join(x for x in (p["fixture"], p["arm"], f"run {p['run']}" if p["run"] else "") if x)
        lines.append(f"- [{p['kind']}] {where}: {p['message']}")
    if len(sup.get("problems") or []) > 30:
        lines.append(f"- … {len(sup['problems']) - 30} more in the JSON")
    lines.append("")
    d_arm, c_arm = sup["arm"], sup["against"]
    for fixture, fx in sup["fixtures"].items():
        lines += [f"### {fixture} ({d_arm} vs {c_arm}) — {fx['status']}", ""]
        if fx["rows"]:
            lines += [f"| metric | {d_arm} median (min–max) | {c_arm} median (min–max) | pairs | median Δ "
                      f"({c_arm}−{d_arm}) | bounds [L, U] | sensitivity | trials over the ceiling {d_arm} / {c_arm} "
                      "| result |", "|---|---|---|---:|---:|---|---:|---|---|"]
            for metric, row in fx["rows"].items():
                bounds = ("–" if row["lower"] is None else
                          f"[{fmt(row['lower'], metric)}, {fmt(row['upper'], metric)}] at {row['confidence_pct']:.1f} %")
                result = row["result"] if row["result"] != "INCONCLUSIVE" else f"INCONCLUSIVE ({row['why']})"
                lines.append(f"| {LABELS.get(metric, metric)} ({UNITS.get(metric, '')}) | "
                             f"{fmt_desc(fx['arms'][d_arm].get(metric), metric)} | "
                             f"{fmt_desc(fx['arms'][c_arm].get(metric), metric)} | {row['n']} | "
                             f"{fmt(row['median_delta'], metric)} | {bounds} | {fmt(row['sensitivity'], metric)} | "
                             f"{row['over_ceiling'][d_arm]} / {row['over_ceiling'][c_arm]} of {row['n']} | "
                             f"**{result}** |")
            lines.append("")
        counters = fx.get("counters") or {}
        if any(counters.get(a, {}).get("tk2_layouts") for a in (d_arm, c_arm)):
            lines.append("Structural diagnostics (work counters, median (min–max) per trial; reported, not gated "
                         "for equality): "
                         + "; ".join(f"{a}: layouts {fmt_desc(counters[a]['tk2_layouts'], 'frames')}, conversions "
                                     f"{fmt_desc(counters[a][CONVERSIONS], 'frames')}, draws "
                                     f"{fmt_desc(counters[a]['tk2_draws'], 'frames')} (native "
                                     f"{fmt_desc(counters[a][NATIVE_DRAWS], 'frames')}, TextKit 1-backed "
                                     f"{fmt_desc(counters[a][TK1_BACKED_DRAWS], 'frames')}), live rows at READY / "
                                     f"end {fmt_desc(counters[a]['tk2_live_ready'], 'frames')} / "
                                     f"{fmt_desc(counters[a]['tk2_live'], 'frames')}, list rows "
                                     f"{fmt_desc(counters[a][LIST_LIVE_READY], 'frames')} / "
                                     f"{fmt_desc(counters[a][LIST_LIVE], 'frames')}, code rows "
                                     f"{fmt_desc(counters[a][CODE_LIVE_READY], 'frames')} / "
                                     f"{fmt_desc(counters[a][CODE_LIVE], 'frames')}"
                                     for a in (d_arm, c_arm) if a in counters) + ".")
            lines.append("")
    return lines


def render_gate(summary: dict, csv_path: str, coverage: str | None) -> str:
    plan = summary["plan"]
    arms = plan["arms"]
    ref = summary["reference"]
    design = DESIGNS.get(summary.get("design") or "", {})
    lines = [f"# perf gate ({summary.get('design')}: {design.get('title', '?')}) — **{summary['verdict']}**", ""]
    if summary.get("refused"):
        lines += [f"REFUSED: {summary['refused']} (verdict before refusal: {summary['verdict_before_refusal']})", ""]
    if summary.get("reduced"):
        lines += ["INCOMPLETE design: " + "; ".join(summary["reduced"]), ""]
    if summary.get("host_busy"):
        reasons = summary.get("host_busy_reasons") or []
        lines += [f"HOST-BUSY ({len(reasons)} samples not quiet; a PASS counts, a FAIL is re-run once when the host is "
                  "quiet): " + " | ".join(reasons[:8]) + (f" | … {len(reasons) - 8} more" if len(reasons) > 8 else ""),
                  ""]
    if summary.get("host_busy_rerun_spent"):
        lines += ["The quiet-window rerun after a FAIL-HOST-BUSY is spent: this FAIL counts.", ""]
    lines.append(f"Source: `{csv_path}`" + (f"; calibration: `{summary['calibration']}` ({summary['calibration_verdict']})"
                                            if summary.get("rule") == "calibrated-ucb" else "") + "  ")
    if any(len(v) != len(arms) for v in (summary.get("fixture_arms") or {}).values()):
        lines.append("Arms per fixture: " + "; ".join(f"{f} {' '.join(v)}" for f, v in summary["fixture_arms"].items())
                     + "  ")
    lines.append("Arms: " + ", ".join(f"{a} = {arms[a].get('label', a)} (`{arms[a].get('sha256', '')[:12]}`"
                                      f"{' ' + ' '.join(arms[a].get('required_flags', [])) if arms[a].get('required_flags') else ''})"
                                      for a in arms) + "  ")
    host = plan.get("host_start") or {}
    if host:
        lines.append(f"Host at start: 1-min load {host.get('load1')}; busiest "
                     + ", ".join(f"{os.path.basename(p.get('command', '?'))} {p.get('cpu')} %" for p in host.get("top", []))
                     + "  ")
    if summary.get("rule") == "median-relative":
        bounds = summary.get("bounds") or {}
        ready = ", ".join(f"{f} ({why})" for f, why in (bounds.get("why") or {}).get("launch_to_ready_ms", {}).items())
        lines.append(f"Rule: per fixture × metric, median over {summary['min_pairs']} balanced-order pairs of X−{ref}, "
                     f"relative to {ref}'s median; FAIL > {REL_LIMIT_PCT:g} % (memory, first chunk with a 20 ms floor, "
                     f"launch→READY where its resolution bound allows: {ready or '–'}; bounds "
                     f"`{(bounds.get('sha256') or 'none')[:12]}`), dropped frames median Δ > "
                     f"{DROPPED_DELTA_MAX:g}; per-trial ceilings hitch > {CEILING_HITCH_MS_PER_S:g} ms/s, dropped rate > "
                     f"{CEILING_DROPPED_RATE_PCT:g} % (≥ {SMALL_TRIAL_FRAMES:,.0f} frames) or > {CEILING_DROPPED_SMALL:g} "
                     "dropped. B and C are both gated.  ")
    else:
        lines.append(f"Rule: per fixture × metric, paired deltas X−{ref} over n ≥ {summary['min_pairs']} balanced-order "
                     "runs; PASS iff mean + t₀.₉₅·sd/√n ≤ allowance (frozen A–A′ calibration, floors applied), plus "
                     "the per-trial ceilings. B and C are both gated.  ")
    lines.append("Labels: launch→READY is *preparation readiness* (model prepared), not first visible content; "
                 "RSS peak is a sampled peak; footprint peak is the kernel phys_footprint_peak; trials are "
                 "fresh-install, warmed-system.  ")
    if coverage:
        lines.append(f"Coverage: {coverage}  ")
    lines.append("")
    if summary["problems"]:
        lines.append(f"## Problems ({len(summary['problems'])})")
        lines.append("")
        for p in summary["problems"][:60]:
            where = " ".join(x for x in (p["fixture"], p["arm"], f"run {p['run']}" if p["run"] else "") if x)
            lines.append(f"- [{p['kind']}] {where}: {p['message']}")
        if len(summary["problems"]) > 60:
            lines.append(f"- … {len(summary['problems']) - 60} more in the JSON")
        lines.append("")
    for fixture, fx in summary["fixtures"].items():
        lines.append(f"## {fixture}")
        lines.append("")
        for b in fx.get("ceiling_breaches", []):
            lines.append(f"- **ceiling FAIL** {b['arm']} run {b['run']}: {b['message']}"
                         + (" — known debt (still a failure)" if b.get("known_debt") else ""))
        if fx.get("ceiling_breaches"):
            lines.append("")
        for arm in [a for a in summary["candidates"] if a in fx["comparisons"]]:
            comp = fx["comparisons"].get(arm, {})
            lines.append(f"**{arm} ({arms[arm].get('label', arm)}) vs {ref}**")
            lines.append("")
            if summary.get("rule") == "median-relative":
                lines.append(f"| metric | {ref} median (min–max) | {arm} median (min–max) | n | median Δ | median Δ / {ref} | limit | verdict |")
                lines.append("|---|---|---|---:|---:|---:|---|---|")
            else:
                lines.append(f"| metric | {ref} median (min–max) | {arm} median (min–max) | n | mean Δ | UCB95 Δ | allowance | verdict |")
                lines.append("|---|---|---|---:|---:|---:|---:|---|")
            for metric in summary["metrics"]:
                c = comp.get(metric, {})
                verdict = c.get("verdict", "n/a")
                head = (f"| {LABELS.get(metric, metric)} ({UNITS.get(metric, 'KB')}) | "
                        f"{fmt_desc(fx['arms'].get(ref, {}).get(metric), metric)} | "
                        f"{fmt_desc(fx['arms'][arm].get(metric), metric)} | {c.get('n', 0)} | ")
                if summary.get("rule") == "median-relative":
                    tail = (f"{fmt(c.get('median_delta'), metric)} | {fmt_pct(c.get('median_rel_pct'))} | "
                            f"{c.get('limit') or '–'} | ")
                else:
                    tail = (f"{fmt(c.get('mean'), metric)} | {fmt(c.get('ucb95'), metric)} | "
                            f"{fmt(c.get('allowance'), metric)} | ")
                debt = (c.get("known_debt") or {}).get("status")
                note = {"known-debt-fail": " (known debt)", "improved": " (known debt: improved)"}.get(debt, "")
                lines.append(head + tail + f"{'**FAIL**' if verdict == 'FAIL' else verdict}{note} |")
            lines.append("")
        rend = [a for a in fx["renderer"] if any(fx["renderer"][a].get(k) for k in ("tk2_layouts", "tk2_draws"))]
        if rend:
            lines.append("Renderer stats (median per trial, final RENDERER_STATS): "
                         + "; ".join(f"{a}: layouts {fmt_desc(fx['renderer'][a]['tk2_layouts'], 'frames')}, "
                                     f"draws {fmt_desc(fx['renderer'][a]['tk2_draws'], 'frames')} (native "
                                     f"{fmt_desc(fx['renderer'][a][NATIVE_DRAWS], 'frames')}, TextKit 1-backed "
                                     f"{fmt_desc(fx['renderer'][a][TK1_BACKED_DRAWS], 'frames')}), "
                                     f"live at READY {fmt_desc(fx['renderer'][a]['tk2_live_ready'], 'frames')}, "
                                     f"eligible/fallback roots {fmt_desc(fx['renderer'][a]['eligible_roots'], 'frames')}"
                                     f"/{fmt_desc(fx['renderer'][a]['fallback_roots'], 'frames')}"
                                     for a in rend))
            lines.append("")
        if any(arms[a].get("expected_renderer") == "textkit2" for a in arms):
            lines.append(share_line(fx.get("tk1_share")))
            lines.append("")
        samp = fx["sampler"].get(ref, {})
        if samp.get("rss_interval_ms_median"):
            lines.append(f"Sampler actual intervals ({ref}): RSS median {fmt_desc(samp['rss_interval_ms_median'], '')} ms, "
                         f"max {fmt_desc(samp['rss_interval_ms_max'], '')} ms; footprint median "
                         f"{fmt_desc(samp.get('footprint_interval_ms_median'), '')} ms, max "
                         f"{fmt_desc(samp.get('footprint_interval_ms_max'), '')} ms.")
            lines.append("")
        loads = (fx["arms"].get(ref) or {}).get("host_load1")
        if loads:
            lines.append(f"Host 1-min load at trial start ({ref}): {fmt_desc(loads, '')}.")
            lines.append("")
    lines += render_known_debt(summary)
    lines += render_predecessor(summary)
    outcome = summary.get("predecessor_outcome")
    lines.append(f"**OVERALL: {summary['verdict']}**" + (f" ({outcome})" if outcome else ""))
    lines.append("")
    return "\n".join(lines)


def render_calibration(cal: dict) -> str:
    lines = [f"# perf calibration — **{cal['verdict']}** (attempt {cal['attempt']})", "",
             f"Source: `{cal['source_csv']}` (sha256 `{cal['source_csv_sha256'][:12]}`); reference "
             f"`{(cal.get('app_sha256') or '')[:12]}`", ""]
    for p in cal.get("problems", [])[:40]:
        where = " ".join(x for x in (p["fixture"], p["arm"], f"run {p['run']}" if p["run"] else "") if x)
        lines.append(f"- [{p['kind']}] {where}: {p['message']}")
    if cal.get("problems"):
        lines.append("")
    for fixture, entry in cal["fixtures"].items():
        lines.append(f"## {fixture} — {entry['verdict']} (n = {entry['n_pairs']})")
        lines.append("")
        lines.append("| metric | A median | max \\|ΔAA′\\| | floor | allowance | allowance / A | ceiling | noisy |")
        lines.append("|---|---:|---:|---:|---:|---:|---:|---|")
        for metric, m in entry["metrics"].items():
            pct = m.get("allowance_pct_of_median")
            lines.append(f"| {LABELS.get(metric, metric)} | {fmt(m['a_median'], metric)} | "
                         f"{fmt(m['max_abs_delta'], metric)} | {fmt(m['floor'], metric)} | "
                         f"{fmt(m['allowance'], metric)} | {'–' if pct is None else f'{pct:.1f} %'} | "
                         f"{fmt(m['ceiling'], metric)} ({m['ceiling_rule']}) | "
                         f"{'**yes**' if m['noisy'] else 'no'} |")
        lines.append("")
    if cal["verdict"] == "INCONCLUSIVE":
        lines.append("Noise ceiling exceeded: quiesce the host and rerun the calibration once (--attempt 2); "
                     "if still noisy, report INCONCLUSIVE and do not gate.")
        lines.append("")
    return "\n".join(lines)


AUTOSCROLL_FIXED_MS = 5500.0


def suggest_timeouts(rows: list[dict]) -> dict:
    """Per-fixture trial deadline = 1.5 × the longest observed scroll + 30 s,
    rounded up to 5 s. The scroll duration is scroll_ms when the app reports
    it, else (main prints no scrollMs) the trial wall time minus READY and
    the autoscroller's fixed sleeps: 3 s before the scroll, 0.5 s after it
    and 2 s before exit (Demo/ADFReader/AutoScroller.swift, same on main)."""
    out: dict = {}
    for row in rows:
        fixture = row.get("fixture", "")
        scroll = finite(row.get("scroll_ms"))
        if scroll is None:
            wall, ready = finite(row.get("trial_wall_ms")), finite(row.get("launch_to_ready_ms"))
            if wall is None or ready is None or row.get("status") != "ok":
                continue
            scroll = max(wall - ready - AUTOSCROLL_FIXED_MS, 0.0)
        out[fixture] = max(out.get(fixture, 0.0), scroll)
    return {f: int(math.ceil((1.5 * s / 1000.0 + 30.0) / 5.0) * 5) for f, s in out.items()}


# -------------------------------------------------------------------- main


def load_plan(csv_path: str, plan_path: str | None) -> dict:
    path = plan_path or os.path.join(os.path.dirname(os.path.abspath(csv_path)), "plan.json")
    if not os.path.exists(path):
        raise SystemExit(f"no plan.json at {path} (pass --plan); the summary refuses to guess what was declared")
    with open(path, encoding="utf-8") as handle:
        plan = json.load(handle)
    for key in ("fixtures", "runs", "arms"):
        if key not in plan:
            raise SystemExit(f"{path}: plan lacks {key!r}")
    plan["_sha256"] = sha256_file(path)
    return plan


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("csv", nargs="?", help="trials.csv from perf-gate.sh")
    parser.add_argument("--plan", help="plan.json (default: next to the CSV)")
    parser.add_argument("--calibrate", action="store_true", help="summarize an A–A2 calibration run (design full)")
    parser.add_argument("--write-calibration", help="calibration JSON to write (with --calibrate)")
    parser.add_argument("--attempt", type=int, default=1, help="calibration attempt number (rerun rule: max 2)")
    parser.add_argument("--calibration", help="frozen calibration.json (design full)")
    parser.add_argument("--pilot", action="store_true", help="assert the plan is a pilot (must match plan.pilot)")
    parser.add_argument("--ledger", help="rerun ledger (default: perf-ledger.jsonl in the run directory's parent)")
    parser.add_argument("--json", dest="json_path", help="write the summary JSON here")
    parser.add_argument("--out", help="write the Markdown here (default: summary.md / calibration.md next to the CSV)")
    parser.add_argument("--coverage", help="coverage line for the table (plan §2.5)")
    parser.add_argument("--suggest-timeouts", action="store_true",
                        help="print per-fixture --trial-timeout-for values from this (pilot) CSV and exit")
    parser.add_argument("--print-design", metavar="NAME", help="print a design's declared shape (k=v lines) and exit")
    parser.add_argument("--bounds", default=BOUNDS_PATH, help="resolution bounds JSON (default: Scripts/perf-bounds.json)")
    parser.add_argument("--measure-bounds", action="store_true",
                        help="write resolution bounds from this A–A′ (calibrate-mode) run and exit")
    parser.add_argument("--write-bounds", help="bounds JSON to write (with --measure-bounds / --merge-bounds; "
                                               "--merge-bounds default: the --bounds file, in place)")
    parser.add_argument("--merge-bounds", metavar="MEASURED_JSON",
                        help="add the fixtures of a --measure-bounds result to --bounds (never replaces one) and exit")
    parser.add_argument("--predecessor-csv", help="the D/C supplement's counted trials (default: the plan's "
                                                  f"predecessor.csv name, {PRED_CSV}, next to the CSV)")
    parser.add_argument("--predecessor-warmup-csv", help="the D/C supplement's warm-ups (default: "
                                                         f"{PRED_WARMUP_CSV} next to the CSV)")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args(argv)

    if args.print_design:
        design = DESIGNS.get(args.print_design)
        if not design:
            print(f"error: unknown design {args.print_design!r} (known: {' '.join(sorted(DESIGNS))})", file=sys.stderr)
            return 2
        refused = design_errors(args.print_design)
        if refused:
            for message in refused:
                print(f"error: design refused: {message}", file=sys.stderr)
            return 2
        bounds, bounds_sha = load_bounds(args.bounds)
        arms = [a for a in ALL_ARMS if any(a in v for v in design["fixtures"].values())]
        gated = bound_gated_fixtures(bounds, list(design["fixtures"]))
        pred = design.get("predecessor") or {}
        print(f"fixtures={' '.join(design['fixtures'])}\n"
              f"fixture_arms={' '.join(f + '=' + ','.join(v) for f, v in design['fixtures'].items())}\n"
              f"arms={' '.join(arms)}\nruns={design['runs']}\nwarmup={design['warmup']}\nrule={design['rule']}\n"
              f"list_proof={' '.join(design.get('list_proof', []))}\n"
              f"code_proof={' '.join(design.get('code_proof', []))}\n"
              f"known_debt={' '.join('/'.join(e[k] for k in DEBT_KEYS[:4]) for e in design.get('known_debt', []))}\n"
              f"predecessor_arm={pred.get('arm', '')}\n"
              f"predecessor_fixtures={' '.join(pred.get('fixtures', []))}\n"
              f"predecessor_runs={pred.get('runs', '')}\npredecessor_warmup={pred.get('warmup', '')}\n"
              f"predecessor_sensitivity_dropped_frames={pred.get('sensitivity_dropped_frames', '')}\n"
              f"predecessor_app_sha256={pred.get('app_sha256') or ''}\n"
              f"baseline_completion={1 if design.get('baseline_completion') else 0}\n"
              f"fixture_hashes={1 if design.get('fixture_hashes') else 0}\n"
              f"includes={' '.join(design.get('includes', []))}\n"
              f"bounds_sha256={bounds_sha or ''}\nbound_gated={json.dumps(gated, sort_keys=True)}\n"
              f"host_quiet_load_max={HOST_QUIET_LOAD_MAX:g}\nhost_process_cpu_max={HOST_PROCESS_CPU_MAX:g}\n"
              f"host_wait_s={HOST_WAIT_S}\nhost_poll_s={HOST_POLL_S}")
        return 0
    if args.merge_bounds:
        try:
            with open(args.merge_bounds, encoding="utf-8") as handle:
                measured = json.load(handle)
            base, _ = load_bounds(args.bounds)
        except (OSError, ValueError) as error:
            print(f"error: cannot read bounds: {error}", file=sys.stderr)
            return 2
        merged, errors = merge_bounds(base, measured)
        if errors:
            for message in errors:
                print(f"error: merge refused: {message}", file=sys.stderr)
            return 2
        target = args.write_bounds or args.bounds
        with open(target, "w", encoding="utf-8") as handle:
            json.dump(merged, handle, indent=2, sort_keys=True)
            handle.write("\n")
        print(f"bounds merged: {sorted(measured['fixtures'])} into {target} (sha256 {sha256_file(target)})",
              file=sys.stderr)
        return 0
    if not args.csv:
        parser.error("trials.csv is required")
    try:
        rows = load_csv(args.csv)
    except (OSError, SystemExit) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    if args.suggest_timeouts:
        suggestion = suggest_timeouts(rows)
        if not suggestion:
            print("no usable trials to estimate scroll durations from", file=sys.stderr)
            return 2
        print(" ".join(f"{f}={s}" for f, s in sorted(suggestion.items())))
        return 0
    try:
        plan = load_plan(args.csv, args.plan)
    except SystemExit as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    here = os.path.dirname(os.path.abspath(args.csv))

    if args.measure_bounds:
        measured = measure_bounds(rows, plan, args.csv)
        out_json = args.write_bounds or os.path.join(here, "bounds.json")
        with open(out_json, "w", encoding="utf-8") as handle:
            json.dump(measured, handle, indent=2, sort_keys=True)
            handle.write("\n")
        text = render_bounds(measured)
        with open(args.out or os.path.join(here, "bounds.md"), "w", encoding="utf-8") as handle:
            handle.write(text)
        if not args.quiet:
            print(text)
        print(f"bounds {measured['verdict']}: wrote {out_json}", file=sys.stderr)
        return EXIT[measured["verdict"]]

    if args.calibrate:
        if args.attempt not in (1, 2):
            print("error: the rerun rule allows calibration attempts 1 and 2 only", file=sys.stderr)
            return 2
        cal = calibrate(rows, plan, args, args.csv)
        text = render_calibration(cal)
        cal_path = args.write_calibration or os.path.join(here, "calibration.json")
        with open(cal_path, "w", encoding="utf-8") as handle:
            json.dump(cal, handle, indent=2, sort_keys=True)
            handle.write("\n")
        out_path = args.out or os.path.join(here, "calibration.md")
        with open(out_path, "w", encoding="utf-8") as handle:
            handle.write(text)
        if args.json_path:
            with open(args.json_path, "w", encoding="utf-8") as handle:
                json.dump(cal, handle, indent=2, sort_keys=True)
                handle.write("\n")
        if not args.quiet:
            print(text)
        print(f"calibration {cal['verdict']}: wrote {cal_path} and {out_path}", file=sys.stderr)
        return EXIT[cal["verdict"]]

    calibration = None
    if args.calibration:
        try:
            with open(args.calibration, encoding="utf-8") as handle:
                calibration = json.load(handle)
        except (OSError, ValueError) as error:
            print(f"error: cannot read calibration: {error}", file=sys.stderr)
            return 2
    bounds, bounds_sha = load_bounds(args.bounds)
    summary = gate(rows, plan, args, calibration, args.calibration, bounds, bounds_sha)
    apply_ledger(summary, args.ledger or os.path.join(os.path.dirname(here), "perf-ledger.jsonl"), here)
    text = render_gate(summary, args.csv, args.coverage)
    out_path = args.out or os.path.join(here, "summary.md")
    with open(out_path, "w", encoding="utf-8") as handle:
        handle.write(text)
    if args.json_path:
        with open(args.json_path, "w", encoding="utf-8") as handle:
            json.dump(summary, handle, indent=2, sort_keys=True, default=str)
            handle.write("\n")
    if not args.quiet:
        print(text)
    outcome = summary.get("predecessor_outcome")
    print(f"gate {summary['verdict']}" + (f" ({outcome})" if outcome else "") + f": wrote {out_path}"
          + (f" and {args.json_path}" if args.json_path else ""), file=sys.stderr)
    return EXIT[summary["verdict"]]


if __name__ == "__main__":
    sys.exit(main())
