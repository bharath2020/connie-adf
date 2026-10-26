#!/usr/bin/env python3
"""Fail-closed verdicts for Scripts/perf-gate.sh runs (plan §6.1–§6.3).

USAGE
    # 1. calibration (main .app as both arms A and A2), frozen before any
    #    candidate run:
    python3 -I Scripts/perf_summarize.py <cal>/trials.csv --calibrate \\
        --write-calibration <cal>/calibration.json [--attempt 1]
    # 2. gate (A = main, C = branch -textkit2, B = branch without it):
    python3 -I Scripts/perf_summarize.py <out>/trials.csv \\
        --calibration <cal>/calibration.json [--json summary.json] \\
        [--out summary.md] [--prior-summary <earlier summary.json>]
    # pilot (n >= 5; never PASS) and deadline suggestion:
    python3 -I Scripts/perf_summarize.py <pilot>/trials.csv --pilot \\
        [--calibration …] [--suggest-timeouts]

    The run's plan.json (written by perf-gate.sh next to trials.csv; or
    --plan) declares the fixtures, the number of runs and, per arm, the app
    sha256, the required/forbidden launch flags and whether the arm must
    report completion fields and renderer stats. Nothing outside the plan
    is assumed.

VALIDITY (fail closed) — every declared (fixture, arm) has exactly one row
    per run 1..runs; each row: status ok, launch_exit 0, installed and app
    sha256 equal the plan's, argv carries the arm's required flags and none
    of its forbidden ones, READY names the fixture, blocks > 0 and equal
    across every arm/run of the fixture (and to --expected-blocks if
    declared), frames > 0, dropped <= frames, every required metric present,
    finite and >= 0, memory samples > 0 (when the sampler ran); candidate-
    binary arms also need SCROLL_METRICS completed=1 and, when declared, the
    RENDERER_STATS proof (C: renderer=textkit2, tk2Layouts > 0; B:
    renderer=swiftui, tk2Layouts = 0, tk2Live = 0 — the renderer must match
    on the READY line and the final line). Precedence:
      1. a candidate (B/C) crash on a provenance-clean row  -> FAIL
      2. any baseline failure or any validity problem       -> INVALID
      3. a candidate timeout / no READY / incomplete scroll -> FAIL
      4. calibration INCONCLUSIVE                           -> INCONCLUSIVE
      5. statistics (below)                                 -> PASS / FAIL
    A row whose status says ok but whose exit code is nonzero or whose
    metrics are missing is a driver/data defect -> INVALID, never PASS.

CALIBRATION (--calibrate) — per fixture and metric, paired deltas
    d_i = A2_i - A_i; allowance = max(max|d_i|, floor). Floors:
    launch_to_ready 50 ms, first_chunk 20 ms, dropped_frames 2,
    dropped_rate 0.5 %-points, hitch 0.10 ms/s, memory 2,048 KB.
    Noise ceiling: max|d_i| > 25 % of A's median (latency, memory) or > 10
    frames (dropped_frames) -> INCONCLUSIVE, but only when max|d_i| also
    exceeds the floor (noise inside the floor cannot widen the allowance).
    dropped_rate and hitch have floors but no ceiling. Rerun rule: quiesce
    the host and rerun the calibration once (--attempt 2); still noisy ->
    report INCONCLUSIVE, do not gate.

GATE — per fixture, candidate arm (C and B, both gated) and metric:
    paired deltas d_i = X_i - A_i over the n runs (n >= 10; 5 = pilot only);
    UCB95 = mean(d) + t(0.95, n-1) * sd(d) / sqrt(n); PASS iff UCB95 <=
    allowance (from the frozen calibration; the plan records its sha256 and
    a changed file is INVALID). --prior-summary refuses (exit 2) to gate a
    candidate whose sha256 already FAILed, and a second rerun of an
    INCONCLUSIVE.

LABELS — launch_to_ready_ms is "preparation readiness" (READY: model
    prepared), not first visible content; rss_peak_kb is a sampled peak;
    footprint_peak_kb is the kernel's phys_footprint_peak as of the last
    sample; trials are fresh-install, warmed-system (uninstall resets
    preferences, not OS/font caches).

EXIT  0 PASS / CALIBRATED, 1 FAIL, 2 INVALID (or refused, or bad input),
      3 INCONCLUSIVE, 4 PILOT (pilot run with no FAIL; never a PASS).

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

EXIT = {"PASS": 0, "CALIBRATED": 0, "FAIL": 1, "INVALID": 2, "REFUSED": 2, "INCONCLUSIVE": 3, "PILOT": 4}

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
CEILING_PCT = 25.0
CEILING_DROPPED = 10.0
MIN_PAIRS = 10
PILOT_PAIRS = 5

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
    value = value.strip()
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


def check_rows(rows: list[dict], plan: dict, problems: Problems, expected_blocks: dict) -> dict:
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
        if spec.get("requires_completion"):
            if row.get("completed") != "1":
                bad.append(f"SCROLL_METRICS completed={row.get('completed') or '∅'} (need 1)")
            if finite(row.get("end_row")) is None:
                bad.append("SCROLL_METRICS endRow missing")
        renderer = spec.get("expected_renderer")
        if renderer:
            layouts = finite(row.get("tk2_layouts"))
            live = finite(row.get("tk2_live"))
            live_ready = finite(row.get("tk2_live_ready"))
            if row.get("renderer") != renderer or row.get("renderer_ready") != renderer:
                bad.append(f"RENDERER_STATS renderer={row.get('renderer_ready') or '∅'} at READY / "
                           f"{row.get('renderer') or '∅'} at the end (need {renderer} on both)")
            elif renderer == "textkit2" and (layouts is None or layouts <= 0):
                bad.append(f"TextKit 2 arm with tk2Layouts={row.get('tk2_layouts') or '∅'}")
            elif renderer == "swiftui" and (layouts != 0 or live != 0 or live_ready != 0):
                bad.append(f"SwiftUI arm with tk2Layouts={row.get('tk2_layouts') or '∅'} tk2Live="
                           f"{row.get('tk2_live_ready') or '∅'}/{row.get('tk2_live') or '∅'}")
        if bad:
            for message in bad:
                problems.add("invalid", message, **where)
            continue
        clean[(fixture, arm)][run] = row

    # Completeness and block-count agreement.
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
    return clean


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


# ------------------------------------------------------------- calibration


def calibrate(rows: list[dict], plan: dict, args: argparse.Namespace, csv_path: str) -> dict:
    problems = Problems()
    if plan.get("mode") != "calibrate":
        problems.add("invalid", f"plan mode is {plan.get('mode')!r}, not 'calibrate'")
    arms = plan["arms"]
    ref, cands = plan.get("reference", "A"), plan.get("candidates", [])
    if len(cands) != 1 or ref not in arms or cands[0] not in arms:
        problems.add("invalid", "calibration needs exactly one reference and one repeat arm")
    elif arms[ref].get("sha256") != arms[cands[0]].get("sha256"):
        problems.add("invalid", "calibration arms must be the same .app (same sha256)")
    clean = check_rows(rows, plan, problems, plan.get("expected_blocks", {}))
    runs = int(plan["runs"])
    min_pairs = PILOT_PAIRS if args.pilot else MIN_PAIRS
    if runs < min_pairs:
        problems.add("invalid", f"{runs} runs declared; calibration needs >= {min_pairs}"
                     + ("" if args.pilot else " (use --pilot for a 5-run pilot)"))
    metrics = gated_metrics(plan)
    rep = cands[0] if cands else "A2"
    result = {"version": 2, "kind": "perf-calibration", "created_utc": now_utc(), "source_csv": os.path.abspath(csv_path),
              "source_csv_sha256": sha256_file(csv_path), "plan_sha256": plan.get("_sha256"),
              "app_sha256": arms.get(ref, {}).get("sha256"), "attempt": args.attempt, "pilot": bool(args.pilot),
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
                ceiling, rule = None, "none (floor only)"
            too_noisy = bool(max_abs is not None and ceiling is not None and max_abs > ceiling and max_abs > floor)
            noisy |= too_noisy
            entry["n_pairs"] = max(entry["n_pairs"], len(deltas))
            entry["metrics"][metric] = {
                "deltas": [round(d, 4) for d in deltas], "max_abs_delta": max_abs, "floor": floor,
                "allowance": None if max_abs is None else max(max_abs, floor), "a_median": a_median,
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
    elif args.pilot:
        result["verdict"] = "PILOT"
    else:
        result["verdict"] = "CALIBRATED"
    return result


# -------------------------------------------------------------------- gate


def gate(rows: list[dict], plan: dict, args: argparse.Namespace, calibration: dict | None,
         calibration_path: str | None) -> dict:
    problems = Problems()
    if plan.get("mode") != "gate":
        problems.add("invalid", f"plan mode is {plan.get('mode')!r}, not 'gate'")
    arms = plan["arms"]
    ref = plan.get("reference", "A")
    cands = [c for c in plan.get("candidates", []) if c in arms]
    if ref not in arms or not cands:
        problems.add("invalid", "plan needs a reference arm and at least one candidate arm")
    runs = int(plan["runs"])
    min_pairs = PILOT_PAIRS if args.pilot else MIN_PAIRS
    if runs < min_pairs:
        problems.add("invalid", f"{runs} runs declared; the gate needs >= {min_pairs} pairs"
                     + ("" if args.pilot else " (5 = --pilot only)"))
    metrics = gated_metrics(plan)

    # Calibration: required (floors-only allowed for a pilot), frozen, same reference build.
    allowances: dict = {}
    cal_verdict = None
    if calibration is None:
        if not args.pilot:
            problems.add("invalid", "no --calibration given (only a --pilot may run on floors alone)")
        for fixture in plan["fixtures"]:
            allowances[fixture] = dict(FLOORS)
    else:
        cal_verdict = calibration.get("verdict")
        if cal_verdict == "PILOT" and not args.pilot:
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

    clean = check_rows(rows, plan, problems, plan.get("expected_blocks", {}))

    # Statistics (always computed for the report; only decisive at step 5).
    fixtures_out: dict = {}
    stat_fail = False
    for fixture in plan["fixtures"]:
        fx: dict = {"arms": {}, "comparisons": {}, "renderer": {}, "sampler": {}}
        for arm in arms:
            arm_rows = list(clean[(fixture, arm)].values())
            fx["arms"][arm] = {m: describe([v for v in (metric_value(r, m) for r in arm_rows) if v is not None])
                               for m in metrics + ["frames", "blocks", "scroll_ms", "trial_wall_ms"]}
            fx["renderer"][arm] = {k: describe([v for v in (finite(r.get(k)) for r in arm_rows) if v is not None])
                                   for k in ["tk2_live_ready", "tk2_live", "tk2_layouts", "tk2_draws",
                                             "eligible_roots", "fallback_roots"]}
            fx["sampler"][arm] = {k: describe([v for v in (finite(r.get(k)) for r in arm_rows) if v is not None])
                                  for k in ["rss_interval_ms_median", "rss_interval_ms_max",
                                            "footprint_interval_ms_median", "footprint_interval_ms_max",
                                            "memory_samples", "footprint_samples"]}
        for arm in cands:
            comp = {}
            for metric in metrics:
                deltas = pairs(clean, fixture, ref, arm, runs, metric)
                n = len(deltas)
                allowance = allowances.get(fixture, {}).get(metric)
                entry = {"n": n, "allowance": allowance, "mean": None, "sd": None, "t": None, "ucb95": None,
                         "verdict": "n/a"}
                if n >= 2:
                    mean = statistics.fmean(deltas)
                    sd = statistics.stdev(deltas)
                    t = t95(n - 1)
                    ucb = mean + t * sd / math.sqrt(n)
                    entry.update(mean=mean, sd=sd, t=t, ucb95=ucb)
                    if n < min_pairs:
                        entry["verdict"] = "n/a"
                        problems.add("insufficient", f"{arm} {metric}: {n} clean pairs < {min_pairs}", fixture, arm)
                    elif allowance is None:
                        entry["verdict"] = "n/a"
                    else:
                        entry["verdict"] = "PASS" if ucb <= allowance else "FAIL"
                        stat_fail |= entry["verdict"] == "FAIL"
                else:
                    problems.add("insufficient", f"{arm} {metric}: {n} clean pairs", fixture, arm)
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
    elif args.pilot:
        verdict = "PILOT"
    else:
        verdict = "PASS"

    result = {"version": 2, "kind": "perf-gate-summary", "created_utc": now_utc(), "verdict": verdict,
              "plan": plan, "reference": ref, "candidates": cands, "metrics": metrics, "pilot": bool(args.pilot),
              "min_pairs": min_pairs, "calibration": calibration_path, "calibration_verdict": cal_verdict,
              "problems": problems.items, "fixtures": fixtures_out,
              "candidate_sha256": {a: arms[a].get("sha256") for a in cands}}
    return result


def apply_prior(result: dict, prior_path: str | None) -> None:
    result["rerun_count"] = 0
    if not prior_path:
        return
    with open(prior_path, encoding="utf-8") as handle:
        prior = json.load(handle)
    result["rerun_of"] = os.path.abspath(prior_path)
    prior_verdict = prior.get("verdict_before_refusal", prior.get("verdict"))
    same_code = prior.get("candidate_sha256") == result.get("candidate_sha256")
    if not same_code:
        pass  # a code change is measured afresh
    elif prior_verdict == "FAIL":
        result["refused"] = "a FAIL is never rerun to green without a code change (candidate sha256 unchanged)"
    elif prior_verdict == "INCONCLUSIVE":
        result["rerun_count"] = int(prior.get("rerun_count", 0)) + 1
        if result["rerun_count"] > 1:
            result["refused"] = "only one rerun is allowed for INCONCLUSIVE"
    if result.get("refused"):
        result["verdict_before_refusal"] = result["verdict"]
        result["verdict"] = "REFUSED"


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


def render_gate(summary: dict, csv_path: str, coverage: str | None) -> str:
    plan = summary["plan"]
    arms = plan["arms"]
    ref = summary["reference"]
    lines = [f"# perf gate — **{summary['verdict']}**", ""]
    if summary.get("refused"):
        lines += [f"REFUSED: {summary['refused']} (verdict before refusal: {summary['verdict_before_refusal']})", ""]
    lines.append(f"Source: `{csv_path}`; calibration: `{summary['calibration'] or 'none (floors only)'}` "
                 f"({summary['calibration_verdict'] or 'n/a'})  ")
    lines.append("Arms: " + ", ".join(f"{a} = {arms[a].get('label', a)} (`{arms[a].get('sha256', '')[:12]}`"
                                      f"{' ' + ' '.join(arms[a].get('required_flags', [])) if arms[a].get('required_flags') else ''})"
                                      for a in arms) + "  ")
    lines.append(f"Rule: per fixture × metric, paired deltas X−{ref} over n ≥ {summary['min_pairs']} balanced-order "
                 "runs; PASS iff mean + t₀.₉₅·sd/√n ≤ allowance (frozen A–A′ calibration, floors applied). "
                 "B and C are both gated.  ")
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
        for arm in summary["candidates"]:
            comp = fx["comparisons"].get(arm, {})
            lines.append(f"**{arm} ({arms[arm].get('label', arm)}) vs {ref}**")
            lines.append("")
            lines.append(f"| metric | {ref} median (min–max) | {arm} median (min–max) | n | mean Δ | UCB95 Δ | allowance | verdict |")
            lines.append("|---|---|---|---:|---:|---:|---:|---|")
            for metric in summary["metrics"]:
                c = comp.get(metric, {})
                verdict = c.get("verdict", "n/a")
                lines.append(f"| {LABELS.get(metric, metric)} ({UNITS.get(metric, 'KB')}) | "
                             f"{fmt_desc(fx['arms'][ref].get(metric), metric)} | "
                             f"{fmt_desc(fx['arms'][arm].get(metric), metric)} | {c.get('n', 0)} | "
                             f"{fmt(c.get('mean'), metric)} | {fmt(c.get('ucb95'), metric)} | "
                             f"{fmt(c.get('allowance'), metric)} | {'**FAIL**' if verdict == 'FAIL' else verdict} |")
            lines.append("")
        rend = [a for a in arms if any(fx["renderer"][a].get(k) for k in ("tk2_layouts", "tk2_draws"))]
        if rend:
            lines.append("Renderer stats (median per trial, final RENDERER_STATS): "
                         + "; ".join(f"{a}: layouts {fmt_desc(fx['renderer'][a]['tk2_layouts'], 'frames')}, "
                                     f"draws {fmt_desc(fx['renderer'][a]['tk2_draws'], 'frames')}, "
                                     f"live at READY {fmt_desc(fx['renderer'][a]['tk2_live_ready'], 'frames')}, "
                                     f"eligible/fallback roots {fmt_desc(fx['renderer'][a]['eligible_roots'], 'frames')}"
                                     f"/{fmt_desc(fx['renderer'][a]['fallback_roots'], 'frames')}"
                                     for a in rend))
            lines.append("")
        samp = fx["sampler"].get(ref, {})
        if samp.get("rss_interval_ms_median"):
            lines.append(f"Sampler actual intervals ({ref}): RSS median {fmt_desc(samp['rss_interval_ms_median'], '')} ms, "
                         f"max {fmt_desc(samp['rss_interval_ms_max'], '')} ms; footprint median "
                         f"{fmt_desc(samp.get('footprint_interval_ms_median'), '')} ms, max "
                         f"{fmt_desc(samp.get('footprint_interval_ms_max'), '')} ms.")
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
        lines.append("| metric | A median | max \\|ΔAA′\\| | floor | allowance | ceiling | noisy |")
        lines.append("|---|---:|---:|---:|---:|---:|---|")
        for metric, m in entry["metrics"].items():
            lines.append(f"| {LABELS.get(metric, metric)} | {fmt(m['a_median'], metric)} | "
                         f"{fmt(m['max_abs_delta'], metric)} | {fmt(m['floor'], metric)} | "
                         f"{fmt(m['allowance'], metric)} | {fmt(m['ceiling'], metric)} ({m['ceiling_rule']}) | "
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
    parser.add_argument("csv", help="trials.csv from perf-gate.sh")
    parser.add_argument("--plan", help="plan.json (default: next to the CSV)")
    parser.add_argument("--calibrate", action="store_true", help="summarize an A–A2 calibration run")
    parser.add_argument("--write-calibration", help="calibration JSON to write (with --calibrate)")
    parser.add_argument("--attempt", type=int, default=1, help="calibration attempt number (rerun rule: max 2)")
    parser.add_argument("--calibration", help="frozen calibration.json for the gate")
    parser.add_argument("--pilot", action="store_true", help="n >= 5 allowed; the verdict is never PASS")
    parser.add_argument("--prior-summary", help="summary.json of the previous gate run (rerun rule)")
    parser.add_argument("--json", dest="json_path", help="write the summary JSON here")
    parser.add_argument("--out", help="write the Markdown here (default: summary.md / calibration.md next to the CSV)")
    parser.add_argument("--coverage", help="coverage line for the table (plan §2.5)")
    parser.add_argument("--suggest-timeouts", action="store_true",
                        help="print per-fixture --trial-timeout-for values from this (pilot) CSV and exit")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args(argv)

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
    apply_prior(summary, args.prior_summary)
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
