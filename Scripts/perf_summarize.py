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
    python3 -I Scripts/perf_summarize.py --print-design pr45

    The run's plan.json (written by perf-gate.sh next to trials.csv; or
    --plan) declares the design, fixtures, runs, warm-ups, host state at
    start and, per arm, the app sha256, the required/forbidden launch flags
    and whether the arm must report completion fields and renderer stats.
    Nothing outside the plan is assumed, and the plan, not a command-line
    flag, says whether a run is a pilot (--pilot must agree with it).

DESIGNS (DESIGNS below; a run that declares less is INCOMPLETE, never PASS)
    pr45  kitchen-sink, stress-1k, giant-table × arms A, B, C × 3 pairs,
          >= 1 discarded warm-up per (fixture, arm), sampler and footprint
          on, B/C completion and renderer markers on. Rule "median-
          relative". About 40 min including boot and a 5-min settle.
    full  kitchen-sink, stress-5k, giant-table × A, B, C × >= 10 pairs,
          frozen A–A′ calibration. Rule "calibrated-ucb". About 8 h.
    Reduced (INCOMPLETE, exit 5): an arm, a declared fixture or pairs
    missing, sampler or footprint off, B/C markers off.

VALIDITY (fail closed) — every declared (fixture, arm) has exactly one row
    per run 1..runs; each row: status ok, launch_exit 0, installed and app
    sha256 equal the plan's, argv carries the arm's required flags and none
    of its forbidden ones, READY names the fixture, blocks > 0 and equal
    across every arm/run of the fixture (and to expected_blocks if
    declared), frames > 0, dropped <= frames, every required metric present,
    finite and >= 0, memory samples > 0, the host's 1-min load recorded and
    <= 6.0 at the trial's start (non-pilot). Candidate (B/C) rows also need
    SCROLL_METRICS completed=1 with endRow = blocks − 1 and frames within
    ±15 % of A's median (traversal), and the RENDERER_STATS proof on the
    final line: C renderer=textkit2 on both lines, tk2Layouts > 0 and
    tk2NativeDraws > 0; B renderer=swiftui, tk2Layouts = tk2Live =
    tk2NativeDraws = tk1BackedDraws = 0. The plan must record a host check
    at start (1-min load <= 4.0, no non-simulator process > 100 % CPU).

CEILINGS (both designs, every counted trial) — hitch > 10 ms/s; dropped
    rate > 1 % on a trial with >= 2,000 frames; > 3 dropped frames on a
    trial with fewer. A candidate breach FAILs; a breach by A in the same
    run makes it INVALID (environment; one predeclared rerun).

RULE pr45 ("median-relative") — per fixture, candidate arm (B and C) and
    metric, paired deltas d_i = X_i − A_i over the 3 runs; r = median(d_i) /
    median(A). FAIL if r > 15 % for memory (RSS and footprint at READY and
    peak), first chunk (and median d > 20 ms) and launch→READY on
    kitchen-sink; launch→READY on the other fixtures is ADVISORY (reported,
    never gating): three pairs cannot resolve 15 % there. Dropped frames:
    FAIL if median d > 2 frames. Resolution evidence (95th percentile of
    |median of 3 A–A′ deltas| over 120 triples, untouched main, 2026-10-26
    noise run): READY kitchen-sink 11 %, stress-5k 22 %, giant-table 42 %;
    first chunk 11–20 % (8–11 ms); memory 0.5–10 %. So the gate catches a
    >= 15 % memory, first-chunk or kitchen-sink READY regression and any
    stall or sustained drop over the ceilings; it misses smaller shifts,
    about half of true 15 % shifts on the noisiest memory metric, rare
    stalls that land in none of 3 trials, and READY regressions under
    about 25 % (stress) or 45 % (giant-table).

RULE full ("calibrated-ucb") — calibration (--calibrate), per fixture and
    metric: d_i = A2_i − A_i; allowance = max(max|d_i|, floor). Floors:
    launch_to_ready 50 ms, first_chunk 20 ms, dropped_frames 2, dropped_rate
    0.5 %-points, hitch 0.10 ms/s, memory 2,048 KB. Noise ceiling: max|d_i|
    > 15 % of A's median (latency, memory) or > 10 frames (dropped_frames)
    -> INCONCLUSIVE, only when max|d_i| also exceeds the floor. The gate:
    d_i = X_i − A_i, n >= 10; UCB95 = mean(d) + t(0.95, n−1)·sd(d)/√n;
    PASS iff UCB95 <= allowance. The calibration must be frozen (sha256 in
    the plan) and created before the first counted trial started.

PRECEDENCE
      1. a candidate crash on a provenance-clean row        -> FAIL
      2. any baseline failure, validity problem, A ceiling
         breach or host-load violation                       -> INVALID
      3. a candidate timeout / no READY / incomplete scroll  -> FAIL
      4. (full) calibration INCONCLUSIVE                      -> INCONCLUSIVE
      5. a rule or ceiling FAIL                               -> FAIL
      6. plan.pilot                                           -> PILOT
      7. a reduced design                                     -> INCOMPLETE
      8. otherwise                                            -> PASS

RERUN LEDGER — every verdict is appended to perf-ledger.jsonl in the run
    directory's parent (or --ledger). A candidate whose sha256s already
    FAILed under the same design is REFUSED (a FAIL is never rerun to green
    without a code change); after one INCONCLUSIVE or INVALID, one rerun is
    allowed, a second is REFUSED. Re-summarising the same run directory is
    not a rerun. Pilot, INCOMPLETE and PASS entries do not count.

LABELS — launch_to_ready_ms is "preparation readiness" (READY: model
    prepared), not first visible content; rss_peak_kb is a sampled peak;
    footprint_peak_kb is the kernel's phys_footprint_peak as of the last
    sample; trials are fresh-install, warmed-system (uninstall resets
    preferences, not OS/font caches). Every summary discloses the
    TextKit 1-backed share of the C arm per fixture (link roots of the
    eligible roots; TextKit 1 draws of all TK2-row draws).

EXIT  0 PASS / CALIBRATED, 1 FAIL, 2 INVALID (or REFUSED, or bad input),
      3 INCONCLUSIVE, 4 PILOT, 5 INCOMPLETE (reduced design; never a PASS).

Standard library only; run with `python3 -I`.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import os
import statistics
import sys
from datetime import datetime, timezone

EXIT = {"PASS": 0, "CALIBRATED": 0, "FAIL": 1, "INVALID": 2, "REFUSED": 2, "INCONCLUSIVE": 3, "PILOT": 4,
        "INCOMPLETE": 5}

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

# The declared designs. perf-gate.sh takes its defaults from here
# (--print-design); a plan that declares less than its design is INCOMPLETE.
DESIGNS = {
    "pr45": {"title": "per-PR gate (~45 min)", "fixtures": ["kitchen-sink", "stress-1k", "giant-table"],
             "arms": ["A", "B", "C"], "runs": 3, "warmup": 1, "rule": "median-relative"},
    "full": {"title": "full gate (~8 h, before the final parity PR)",
             "fixtures": ["kitchen-sink", "stress-5k", "giant-table"],
             "arms": ["A", "B", "C"], "runs": MIN_PAIRS, "warmup": 1, "rule": "calibrated-ucb"},
}

# Rule pr45 ("median-relative").
REL_LIMIT_PCT = 15.0
REL_ABS_FLOORS = {"first_chunk_ms": 20.0}
READY_GATED_FIXTURES = {"kitchen-sink"}
DROPPED_DELTA_MAX = 2.0

# Absolute per-trial ceilings (Fable M1), both designs.
CEILING_HITCH_MS_PER_S = 10.0
CEILING_DROPPED_RATE_PCT = 1.0
CEILING_DROPPED_SMALL = 3.0
SMALL_TRIAL_FRAMES = 2000.0

# Traversal (Fable S5): candidate frames within ±15 % of A's median.
TRAVERSAL_FRAMES_PCT = 15.0

# Host load (non-pilot): start check recorded by perf-gate.sh; per trial.
HOST_START_LOAD_MAX = 4.0
HOST_PROCESS_CPU_MAX = 100.0
HOST_TRIAL_LOAD_MAX = 6.0

# Renderer proof columns (Scripts/perf_trial.py STATS_FIELDS).
NATIVE_DRAWS = "tk2_native_draws"
TK1_BACKED_ROWS = "tk1_backed_rows"
TK1_BACKED_DRAWS = "tk1_backed_draws"
LINK_ROOTS = "link_roots"

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


def check_host_start(plan: dict, problems: Problems) -> None:
    """The start-of-run host check perf-gate.sh records (non-pilot only)."""
    host = plan.get("host_start")
    if not isinstance(host, dict) or finite(host.get("load1")) is None:
        problems.add("invalid", "plan records no host check at start (load average, busiest processes)")
        return
    if float(host["load1"]) > HOST_START_LOAD_MAX:
        problems.add("invalid", f"host 1-min load {host['load1']} > {HOST_START_LOAD_MAX:g} at start")
    for proc in host.get("top", []):
        cpu = finite(proc.get("cpu"))
        if cpu is not None and cpu > HOST_PROCESS_CPU_MAX and not proc.get("simulator"):
            problems.add("invalid", f"host process {proc.get('command')} at {cpu:g} % CPU at start "
                                    f"(> {HOST_PROCESS_CPU_MAX:g} %)")


def check_rows(rows: list[dict], plan: dict, problems: Problems, expected_blocks: dict, pilot: bool) -> dict:
    """Validates rows against the plan; returns {(fixture, arm): {run: row}} of
    the rows that passed every check (so statistics only see clean data)."""
    fixtures = plan["fixtures"]
    arms = plan["arms"]
    runs = int(plan["runs"])
    metrics = gated_metrics(plan)
    clean: dict = {(f, a): {} for f in fixtures for a in arms}
    seen: dict = {}

    for row in rows:
        run_v = finite(row.get("run"))
        if run_v is None or run_v < 1:
            continue  # warm-ups live in warmup.csv; run 0 is never counted
        run = int(run_v)
        fixture, arm = row.get("fixture", ""), row.get("arm", "")
        where = {"fixture": fixture, "arm": arm, "run": str(run)}
        if fixture not in fixtures or arm not in arms:
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
        provenance_ok = True
        if row.get("app_sha256", "") != spec.get("sha256"):
            problems.add("invalid", f"app sha256 {row.get('app_sha256') or '∅'} != plan {spec.get('sha256')}", **where)
            provenance_ok = False
        if row.get("installed_sha256", "") != spec.get("sha256"):
            problems.add("invalid", f"installed sha256 {row.get('installed_sha256') or '∅'} != plan {spec.get('sha256')}",
                         **where)
            provenance_ok = False
        argv = flags_in(row.get("argv", ""))
        missing = [f for f in spec.get("required_flags", []) if f not in argv]
        forbidden = [f for f in spec.get("forbidden_flags", []) if f in argv]
        if missing or forbidden or "-fixture" not in argv or fixture not in argv:
            problems.add("invalid", f"argv wrong for arm (missing {missing}, forbidden {forbidden}): {row.get('argv')}",
                         **where)
            provenance_ok = False
        if not pilot:
            load = finite(row.get("host_load1"))
            if load is None:
                problems.add("invalid", "host 1-min load not recorded for the trial", **where)
            elif load > HOST_TRIAL_LOAD_MAX:
                problems.add("invalid", f"host 1-min load {load:g} > {HOST_TRIAL_LOAD_MAX:g} at the trial's start",
                             **where)

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
            bad += renderer_problems(row, renderer)
        if bad:
            for message in bad:
                problems.add("invalid", message, **where)
            continue
        if traversal:
            for message in traversal:
                problems.add("candidate_failure", message, **where)
            continue
        clean[(fixture, arm)][run] = row

    # Completeness, block-count agreement, traversal against A's frames.
    ref = plan.get("reference", "A")
    for fixture in fixtures:
        counts = set()
        for arm in arms:
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
            if not spec.get("requires_completion"):
                continue
            for run, row in list(clean[(fixture, arm)].items()):
                frames = finite(row.get("frames")) or 0.0
                if abs(frames - a_frames) > a_frames * TRAVERSAL_FRAMES_PCT / 100.0:
                    problems.add("candidate_failure", f"traversal: {frames:g} frames vs {ref} median {a_frames:g} "
                                 f"(> ±{TRAVERSAL_FRAMES_PCT:g} %)", fixture, arm, str(run))
                    del clean[(fixture, arm)][run]
    return clean


def renderer_problems(row: dict, renderer: str) -> list[str]:
    """The RENDERER_STATS proof for one candidate row (final line counters)."""
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
        return out
    zero = {"tk2_layouts": layouts, "tk2_live": finite(row.get("tk2_live")),
            "tk2_live_ready": finite(row.get("tk2_live_ready")), NATIVE_DRAWS: native,
            TK1_BACKED_DRAWS: finite(row.get(TK1_BACKED_DRAWS))}
    nonzero = {k: row.get(k) or "∅" for k, v in zero.items() if v != 0}
    return [f"SwiftUI arm with nonzero/missing TextKit 2 counters {nonzero}"] if nonzero else []


def ceiling_breaches(row: dict) -> list[str]:
    out = []
    frames = finite(row.get("frames")) or 0.0
    dropped = finite(row.get("dropped_frames")) or 0.0
    hitch = finite(row.get("hitch_ms_per_s")) or 0.0
    if hitch > CEILING_HITCH_MS_PER_S:
        out.append(f"hitch {hitch:g} ms/s > {CEILING_HITCH_MS_PER_S:g}")
    if frames >= SMALL_TRIAL_FRAMES:
        rate = dropped / frames * 100.0
        if rate > CEILING_DROPPED_RATE_PCT:
            out.append(f"dropped rate {rate:.3f} % > {CEILING_DROPPED_RATE_PCT:g} % ({dropped:g}/{frames:g})")
    elif dropped > CEILING_DROPPED_SMALL:
        out.append(f"{dropped:g} dropped frames > {CEILING_DROPPED_SMALL:g} on a {frames:g}-frame trial")
    return out


def check_ceilings(clean: dict, plan: dict, problems: Problems) -> list[dict]:
    """Per-trial absolute ceilings. A baseline breach is an environment
    problem (INVALID); returns the candidate breaches (FAIL)."""
    breaches = []
    for (fixture, arm), runs in clean.items():
        role = plan["arms"][arm].get("role", "baseline")
        for run, row in runs.items():
            for message in ceiling_breaches(row):
                if role == "candidate":
                    breaches.append({"fixture": fixture, "arm": arm, "run": str(run), "message": message})
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
    missing_fixtures = [f for f in design["fixtures"] if f not in plan["fixtures"]]
    extra_fixtures = [f for f in plan["fixtures"] if f not in design["fixtures"]]
    if missing_fixtures:
        reduced.append(f"fixtures {missing_fixtures} declared by design {name} are missing")
    if extra_fixtures and not pilot:
        problems.add("invalid", f"fixtures {extra_fixtures} are not part of design {name}")
    missing_arms = [a for a in design["arms"] if a not in plan["arms"]]
    if missing_arms:
        reduced.append(f"arms {missing_arms} missing")
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
    if int(plan.get("warmup", 0)) < design["warmup"] and not pilot:
        problems.add("invalid", f"warmup {plan.get('warmup', 0)} < {design['warmup']} (one discarded warm-up per "
                                "fixture and arm)")
    return design, reduced


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
        a = clean[(fixture, ref)].get(run)
        x = clean[(fixture, arm)].get(run)
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
                                TK1_BACKED_ROWS, "tk2_layouts", "text_fallback_roots", "fallback_roots")}
    out["link_root_share_pct"] = (out[LINK_ROOTS] / out["eligible_roots"] * 100.0
                                  if out[LINK_ROOTS] is not None and out["eligible_roots"] else None)
    out["tk1_draw_share_pct"] = (out[TK1_BACKED_DRAWS] / out["tk2_draws"] * 100.0
                                 if out[TK1_BACKED_DRAWS] is not None and out["tk2_draws"] else None)
    return out


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
    if not pilot:
        check_host_start(plan, problems)
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
              "fixtures": {}, "problems": []}
    noisy = False
    for fixture in plan["fixtures"]:
        entry = {"n_pairs": 0, "metrics": {}, "verdict": "CALIBRATED"}
        for metric in metrics:
            deltas = pairs(clean, fixture, ref, rep, runs, metric)
            a_vals = [v for v in (metric_value(r, metric) for r in clean[(fixture, ref)].values()) if v is not None]
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


def compare_median_relative(fixture: str, metric: str, deltas: list[float], a_median: float | None) -> dict:
    """Rule pr45 for one (fixture, arm, metric)."""
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
        elif metric == "launch_to_ready_ms" and fixture not in READY_GATED_FIXTURES:
            entry["verdict"] = "ADVISORY >15 %" if over else "advisory"
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
         calibration_path: str | None) -> dict:
    problems = Problems()
    pilot = resolve_pilot(plan, args, problems)
    if plan.get("mode") != "gate":
        problems.add("invalid", f"plan mode is {plan.get('mode')!r}, not 'gate'")
    design, reduced = design_conformance(plan, problems, pilot)
    rule = design["rule"] if design else None
    arms = plan["arms"]
    ref = plan.get("reference", "A")
    cands = [c for c in plan.get("candidates", []) if c in arms]
    if ref not in arms or not cands:
        problems.add("invalid", "plan needs a reference arm and at least one candidate arm")
    runs = int(plan["runs"])
    if pilot:
        min_pairs = PILOT_PAIRS
    else:
        # A reduced plan is INCOMPLETE (below), not INVALID for its own count.
        min_pairs = min(design["runs"], runs) if design else MIN_PAIRS
        check_host_start(plan, problems)
    metrics = gated_metrics(plan)

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
        for arm in arms:
            arm_rows = list(clean[(fixture, arm)].values())
            fx["arms"][arm] = {m: describe([v for v in (metric_value(r, m) for r in arm_rows) if v is not None])
                               for m in metrics + ["frames", "blocks", "scroll_ms", "trial_wall_ms", "host_load1"]}
            fx["renderer"][arm] = {k: describe([v for v in (finite(r.get(k)) for r in arm_rows) if v is not None])
                                   for k in ["tk2_live_ready", "tk2_live", "tk2_layouts", "tk2_draws", NATIVE_DRAWS,
                                             TK1_BACKED_ROWS, TK1_BACKED_DRAWS, "eligible_roots", "fallback_roots",
                                             "text_fallback_roots", LINK_ROOTS]}
            fx["sampler"][arm] = {k: describe([v for v in (finite(r.get(k)) for r in arm_rows) if v is not None])
                                  for k in ["rss_interval_ms_median", "rss_interval_ms_max",
                                            "footprint_interval_ms_median", "footprint_interval_ms_max",
                                            "memory_samples", "footprint_samples"]}
            if arms[arm].get("expected_renderer") == "textkit2":
                fx["tk1_share"] = tk1_share(arm_rows)
        for arm in cands:
            comp = {}
            for metric in metrics:
                deltas = pairs(clean, fixture, ref, arm, runs, metric)
                if len(deltas) < min_pairs:
                    problems.add("insufficient", f"{arm} {metric}: {len(deltas)} clean pairs < {min_pairs}",
                                 fixture, arm)
                if rule == "median-relative":
                    a_desc = fx["arms"][ref].get(metric)
                    entry = compare_median_relative(fixture, metric, deltas, a_desc["median"] if a_desc else None)
                else:
                    entry = compare_ucb(deltas, allowances.get(fixture, {}).get(metric), min_pairs)
                stat_fail |= entry["verdict"] == "FAIL"
                comp[metric] = entry
            fx["comparisons"][arm] = comp
        fixtures_out[fixture] = fx

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

    return {"version": 3, "kind": "perf-gate-summary", "created_utc": now_utc(), "verdict": verdict,
            "design": plan.get("design"), "rule": rule, "reduced": reduced, "plan": plan, "reference": ref,
            "candidates": cands, "metrics": metrics, "pilot": pilot, "min_pairs": min_pairs,
            "calibration": calibration_path, "calibration_verdict": cal_verdict, "problems": problems.items,
            "fixtures": fixtures_out, "candidate_sha256": {a: arms[a].get("sha256") for a in cands}}


# ------------------------------------------------------------------ ledger


def apply_ledger(result: dict, ledger_path: str, run_dir: str) -> None:
    """The rerun rule across runs (see RERUN LEDGER)."""
    result["ledger"] = ledger_path
    result["rerun_count"] = 0
    prior = []
    if os.path.exists(ledger_path):
        with open(ledger_path, encoding="utf-8") as handle:
            for line in handle:
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if (entry.get("run_dir") != run_dir and entry.get("design") == result.get("design")
                        and entry.get("candidate_sha256") == result.get("candidate_sha256")
                        and not entry.get("pilot")):
                    prior.append(entry)
    by_dir: dict = {}
    for entry in prior:
        by_dir[entry["run_dir"]] = entry.get("verdict_before_refusal") or entry.get("verdict")
    if not result.get("pilot"):
        if "FAIL" in by_dir.values():
            result["refused"] = "a FAIL is never rerun to green without a code change (candidate sha256 unchanged)"
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
            f"{fmt(share[TK1_BACKED_ROWS], 'frames')}.")


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
    lines.append(f"Source: `{csv_path}`" + (f"; calibration: `{summary['calibration']}` ({summary['calibration_verdict']})"
                                            if summary.get("rule") == "calibrated-ucb" else "") + "  ")
    lines.append("Arms: " + ", ".join(f"{a} = {arms[a].get('label', a)} (`{arms[a].get('sha256', '')[:12]}`"
                                      f"{' ' + ' '.join(arms[a].get('required_flags', [])) if arms[a].get('required_flags') else ''})"
                                      for a in arms) + "  ")
    host = plan.get("host_start") or {}
    if host:
        lines.append(f"Host at start: 1-min load {host.get('load1')}; busiest "
                     + ", ".join(f"{os.path.basename(p.get('command', '?'))} {p.get('cpu')} %" for p in host.get("top", []))
                     + "  ")
    if summary.get("rule") == "median-relative":
        lines.append(f"Rule: per fixture × metric, median over {summary['min_pairs']} balanced-order pairs of X−{ref}, "
                     f"relative to {ref}'s median; FAIL > {REL_LIMIT_PCT:g} % (memory, first chunk with a 20 ms floor, "
                     "launch→READY on kitchen-sink; launch→READY elsewhere advisory), dropped frames median Δ > "
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
            lines.append(f"- **ceiling FAIL** {b['arm']} run {b['run']}: {b['message']}")
        if fx.get("ceiling_breaches"):
            lines.append("")
        for arm in summary["candidates"]:
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
                        f"{fmt_desc(fx['arms'][ref].get(metric), metric)} | "
                        f"{fmt_desc(fx['arms'][arm].get(metric), metric)} | {c.get('n', 0)} | ")
                if summary.get("rule") == "median-relative":
                    tail = (f"{fmt(c.get('median_delta'), metric)} | {fmt_pct(c.get('median_rel_pct'))} | "
                            f"{c.get('limit') or '–'} | ")
                else:
                    tail = (f"{fmt(c.get('mean'), metric)} | {fmt(c.get('ucb95'), metric)} | "
                            f"{fmt(c.get('allowance'), metric)} | ")
                lines.append(head + tail + f"{'**FAIL**' if verdict == 'FAIL' else verdict} |")
            lines.append("")
        rend = [a for a in arms if any(fx["renderer"][a].get(k) for k in ("tk2_layouts", "tk2_draws"))]
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
        loads = fx["arms"].get(ref, {}).get("host_load1")
        if loads:
            lines.append(f"Host 1-min load at trial start ({ref}): {fmt_desc(loads, '')}.")
            lines.append("")
    lines.append(f"**OVERALL: {summary['verdict']}**")
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
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args(argv)

    if args.print_design:
        design = DESIGNS.get(args.print_design)
        if not design:
            print(f"error: unknown design {args.print_design!r} (known: {' '.join(sorted(DESIGNS))})", file=sys.stderr)
            return 2
        print(f"fixtures={' '.join(design['fixtures'])}\narms={' '.join(design['arms'])}\nruns={design['runs']}\n"
              f"warmup={design['warmup']}\nrule={design['rule']}\nhost_start_load_max={HOST_START_LOAD_MAX:g}\n"
              f"host_process_cpu_max={HOST_PROCESS_CPU_MAX:g}\nhost_trial_load_max={HOST_TRIAL_LOAD_MAX:g}")
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
    summary = gate(rows, plan, args, calibration, args.calibration)
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
    print(f"gate {summary['verdict']}: wrote {out_path}" + (f" and {args.json_path}" if args.json_path else ""),
          file=sys.stderr)
    return EXIT[summary["verdict"]]


if __name__ == "__main__":
    sys.exit(main())
