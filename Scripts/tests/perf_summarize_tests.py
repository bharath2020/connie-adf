#!/usr/bin/env python3
"""Synthetic positive and negative cases for Scripts/perf_summarize.py.

USAGE
    python3 -I Scripts/tests/perf_summarize_tests.py <workdir>

Writes one plan.json + trials.csv per case under <workdir> (outside the
repository), runs the summarizer on it and checks the exit status and
verdict. Prints one line per case and "<passed>/<total> passed"; exits 1 on
any mismatch. Standard library only.
"""

from __future__ import annotations

import copy
import csv
import hashlib
import importlib.util
import json
import os
import random
import subprocess
import sys

sys.dont_write_bytecode = True

SCRIPTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SUMMARIZE = os.path.join(SCRIPTS, "perf_summarize.py")
_spec = importlib.util.spec_from_file_location("perf_trial", os.path.join(SCRIPTS, "perf_trial.py"))
perf_trial = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(perf_trial)

SHA = {"A": "a" * 64, "A2": "a" * 64, "B": "b" * 64, "C": "b" * 64}
BLOCKS = {"kitchen-sink": 38, "stress-1k": 1000, "stress-5k": 5000, "giant-table": 402, "list-dense": 640}
FRAMES = {"kitchen-sink": 166, "stress-1k": 5930, "stress-5k": 29665, "giant-table": 2429, "list-dense": 8400}
ELIGIBLE = {"kitchen-sink": 10, "stress-1k": 480, "stress-5k": 2400, "giant-table": 1, "list-dense": 40}
LINKS = {"kitchen-sink": 1, "stress-1k": 101, "stress-5k": 507, "giant-table": 0, "list-dense": 0}
# List text leaves (leaders + trailing) per fixture, for the lists-stage
# RENDERER_STATS fields a new build prints (stress-1k: 1,815 plain leaders).
LIST_LEAVES = {"kitchen-sink": 8, "stress-1k": 1815, "stress-5k": 8914, "giant-table": 0, "list-dense": 3000}
FIXTURE_SHA = {f: hashlib.sha256(f"fixture {f}".encode()).hexdigest() for f in BLOCKS}
PR45 = ["kitchen-sink", "stress-1k", "giant-table"]
PR2 = PR45 + ["list-dense"]
FULL = ["kitchen-sink", "stress-5k", "giant-table"]
ARMS = ["A", "C", "B"]
HOST = {"load1": 2.1, "load5": 2.0, "load15": 1.9,
        "top": [{"pid": 1, "command": "/sbin/launchd", "cpu": 3.0, "simulator": False}]}

work = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.environ.get("TMPDIR", "/tmp"), "perf-summarize-tests")
os.makedirs(work, exist_ok=True)
results: list[bool] = []


def plan(design: str, runs: int, arms: list[str], fixtures: list[str] | None = None, mode: str = "gate",
         cal_sha: str | None = None, fixture_hashes: bool | None = None, **over) -> dict:
    """A plan as perf-gate.sh writes it. Design pr2 (gate mode) holds A to
    completion and records each arm's fixture sha256s, as the driver does."""
    fixtures = fixtures or {"pr45": PR45, "pr2": PR2}.get(design, FULL)
    if fixture_hashes is None:
        fixture_hashes = design == "pr2"
    specs = {}
    for a in arms:
        cand = a in ("B", "C")
        specs[a] = {"label": a, "app": f"/x/{a}.app", "sha256": SHA[a], "role": "candidate" if cand else "baseline",
                    "required_flags": {"C": ["-textkit2", "-rendererStats"],
                                       "B": ["-rendererReset", "-rendererStats"]}.get(a, []),
                    "forbidden_flags": [] if a == "C" else (["-textkit2"] + ([] if cand else ["-rendererStats"])),
                    "requires_completion": cand or (a == "A" and design == "pr2" and mode == "gate"),
                    "expected_renderer": {"C": "textkit2", "B": "swiftui"}.get(a)}
        if fixture_hashes:
            specs[a]["fixture_sha256"] = {f: FIXTURE_SHA[f] for f in fixtures}
    p = {"version": 4 if fixture_hashes else 3, "mode": mode, "design": design, "pilot": False,
         "fixtures": fixtures, "runs": runs, "warmup": 1, "reference": "A",
         "candidates": ["A2"] if mode == "calibrate" else [a for a in ("C", "B") if a in arms], "arms": specs,
         "sampler": True, "footprint": True, "expected_blocks": {}, "host_start": copy.deepcopy(HOST),
         "calibration": {"path": "x", "sha256": cal_sha} if cal_sha else None}
    p.update(over)
    return p


def row(run: int, fixture: str, arm: str, rng: random.Random, **over) -> dict:
    r = {c: "" for c in perf_trial.CSV_COLUMNS}
    flags = {"C": " -textkit2 -rendererStats", "B": " -rendererReset -rendererStats"}.get(arm, "")
    frames = FRAMES[fixture]
    dropped = rng.randint(0, 1) if frames >= 2000 else 0
    r.update(run=str(run), fixture=fixture, arm=arm, label=arm, app_sha256=SHA[arm], installed_sha256=SHA[arm],
             installed_fixture_sha256=FIXTURE_SHA[fixture], argv=f"-fixture {fixture} -autoscroll{flags}", requires_completion="1" if arm in "BC" else "0",
             started_utc="2026-10-26T12:00:00Z", host_load1=f"{2 + rng.random():.2f}", host_top3="launchd=3",
             status="ok", launch_exit="0", launch_to_ready_ms=f"{600 + rng.uniform(-10, 10):.1f}",
             ready_fixture=fixture, first_chunk_ms=str(56 + rng.randint(0, 3)), blocks=str(BLOCKS[fixture]),
             frames=str(frames + rng.randint(-2, 2)), dropped_frames=str(dropped),
             dropped_rate_pct=f"{dropped / frames * 100:.3f}", hitch_ms_per_s=f"{dropped * 0.05:.2f}",
             rss_ready_kb=str(80000 + rng.randint(-300, 300)), rss_peak_kb=str(90000 + rng.randint(-300, 300)),
             footprint_ready_kb=str(60000 + rng.randint(-300, 300)),
             footprint_peak_kb=str(70000 + rng.randint(-300, 300)), memory_samples="50", footprint_samples="10")
    # Main >= 86abd56 prints the completion fields too (checked where the
    # design holds A to completion: pr2).
    r.update(start_row="0", end_row=str(BLOCKS[fixture] - 1), scroll_ms="9000", completed="1")
    if arm in ("B", "C"):
        c = arm == "C"
        lists = LIST_LEAVES[fixture]
        r.update(tk2_list_live_ready=("4" if lists else "0") if c else "0",
                 tk2_list_live=("2" if lists else "0") if c else "0",
                 eligible_text_leaves=str(ELIGIBLE[fixture] + lists * 8 // 10),
                 linked_text_leaves=str(LINKS[fixture] + lists // 10), fallback_text_leaves=str(2 + lists // 10),
                 list_leader_leaves=str(lists * 9 // 10), list_trailing_leaves=str(lists // 10))
        r.update(start_row="0", end_row=str(BLOCKS[fixture] - 1), scroll_ms="9000", completed="1",
                 renderer="textkit2" if c else "swiftui", renderer_ready="textkit2" if c else "swiftui",
                 tk2_live="3" if c else "0", tk2_live_ready="9" if c else "0",
                 tk2_layouts=str(ELIGIBLE[fixture] + 1) if c else "0", tk2_draws="40" if c else "0",
                 tk2_native_draws="30" if c else "0", tk1_backed_rows="1" if c else "0",
                 tk1_backed_draws="10" if c else "0", eligible_roots=str(ELIGIBLE[fixture]),
                 fallback_roots="20", text_fallback_roots="2", link_roots=str(LINKS[fixture]))
        if c and ELIGIBLE[fixture] == 0:
            r.update(tk2_layouts="0", tk2_native_draws="0", tk2_draws="0", tk1_backed_draws="0", tk2_live="0",
                     tk2_live_ready="0")
    r.update(over)
    return r


def grid(runs: int, arms: list[str], fixtures: list[str], seed: int = 1, mutate=None) -> list[dict]:
    rng = random.Random(seed)
    rows = []
    for run in range(1, runs + 1):
        for f in fixtures:
            for a in arms:
                r = row(run, f, a, rng)
                if mutate:
                    mutate(r)
                rows.append(r)
    return rows


def write(name: str, p: dict, rows: list[dict]) -> str:
    d = os.path.join(work, name)
    os.makedirs(d, exist_ok=True)
    for stale in ("trials.csv.json", "summary.md"):
        if os.path.exists(os.path.join(d, stale)):
            os.remove(os.path.join(d, stale))
    with open(os.path.join(d, "plan.json"), "w") as fh:
        json.dump(p, fh)
    with open(os.path.join(d, "trials.csv"), "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=perf_trial.CSV_COLUMNS)
        w.writeheader()
        w.writerows(rows)
    return os.path.join(d, "trials.csv")


def summarize(path: str, *extra: str, ledger: str | None = None) -> tuple[int, dict]:
    ledger = ledger or path + ".ledger.jsonl"
    if ledger == path + ".ledger.jsonl" and os.path.exists(ledger):
        os.remove(ledger)
    res = subprocess.run([sys.executable, "-I", SUMMARIZE, path, "--quiet", "--json", path + ".json",
                          "--ledger", ledger, *extra], capture_output=True, text=True)
    data = json.load(open(path + ".json")) if os.path.exists(path + ".json") else {}
    return res.returncode, data


def check(name: str, got: tuple[int, dict], want_code: int, want_verdict: str, contains: str | None = None) -> None:
    code, data = got
    verdict = data.get("verdict")
    problems = data.get("problems") or []
    text = json.dumps(data, default=str)
    ok = code == want_code and verdict == want_verdict and (contains is None or contains in text)
    results.append(ok)
    first = problems[0]["message"] if problems else (data.get("refused") or "; ".join(data.get("reduced") or []))
    print(f"{'ok  ' if ok else 'FAIL'} {name}: exit {code} {verdict} (want {want_code} {want_verdict})"
          f"{'' if contains is None or contains in text else ' [missing: ' + contains + ']'} {first[:100]}")


def mut(**cond_and_update):
    """mut(arm="C", run="2", fixture=None, set={...})"""
    updates = cond_and_update.pop("set")
    def m(r):
        if all(r.get(k) == v for k, v in cond_and_update.items()):
            r.update({k: (v(r) if callable(v) else v) for k, v in updates.items()})
    return m


def scale(key: str, factor: float):
    return lambda r: f"{float(r[key]) * factor:.1f}"


# ------------------------------------------------------------ design pr45
P = plan("pr45", 3, ARMS)
check("pr45 clean -> PASS", summarize(write("pr45-pass", P, grid(3, ARMS, PR45))), 0, "PASS",
      contains="link_root_share_pct")

# Must 3 / S1 / S4: reduced designs are INCOMPLETE, never PASS.
check("pr45 without arm B -> INCOMPLETE",
      summarize(write("pr45-noB", plan("pr45", 3, ["A", "C"]), grid(3, ["A", "C"], PR45))), 5, "INCOMPLETE")
check("pr45 sampler off -> INCOMPLETE",
      summarize(write("pr45-nosampler", plan("pr45", 3, ARMS, sampler=False, footprint=False),
                      grid(3, ARMS, PR45))), 5, "INCOMPLETE")
Pm = copy.deepcopy(P)
for a in ("B", "C"):
    Pm["arms"][a].update(requires_completion=False, expected_renderer=None)
check("pr45 candidate markers off -> INCOMPLETE", summarize(write("pr45-nomarkers", Pm, grid(3, ARMS, PR45))), 5,
      "INCOMPLETE")
check("pr45 fewer fixtures -> INCOMPLETE",
      summarize(write("pr45-2fx", plan("pr45", 3, ARMS, fixtures=PR45[:2]), grid(3, ARMS, PR45[:2]))), 5, "INCOMPLETE")
check("pr45 two pairs -> INCOMPLETE",
      summarize(write("pr45-2runs", plan("pr45", 2, ARMS), grid(2, ARMS, PR45))), 5, "INCOMPLETE")
check("pr45 extra fixture -> INVALID",
      summarize(write("pr45-extra", plan("pr45", 3, ARMS, fixtures=PR45 + ["stress-5k"]),
                      grid(3, ARMS, PR45 + ["stress-5k"]))), 2, "INVALID")
check("unknown design -> INVALID", summarize(write("nodesign", plan("x", 3, ARMS, fixtures=PR45),
                                                   grid(3, ARMS, PR45))), 2, "INVALID")

# M2: the plan, not the flag, decides pilot; warm-up required.
check("plan pilot summarized without --pilot -> INVALID",
      summarize(write("pr45-pilotplan", plan("pr45", 3, ARMS, pilot=True), grid(3, ARMS, PR45))), 2, "INVALID")
check("--pilot on a non-pilot plan -> INVALID", summarize(write("pr45-pilotflag", P, grid(3, ARMS, PR45)), "--pilot"),
      2, "INVALID")
check("pilot plan with --pilot -> PILOT (never PASS)",
      summarize(write("pr45-pilot", plan("pr45", 3, ARMS, pilot=True, warmup=0), grid(3, ARMS, PR45)), "--pilot"),
      4, "PILOT")
check("warmup 0 (non-pilot) -> INVALID", summarize(write("pr45-warm0", plan("pr45", 3, ARMS, warmup=0),
                                                         grid(3, ARMS, PR45))), 2, "INVALID")

# M1: absolute ceilings.
check("C hitch 12 ms/s on one trial -> FAIL",
      summarize(write("pr45-chitch", P, grid(3, ARMS, PR45, mutate=mut(arm="C", run="2", fixture="giant-table",
                                                                       set={"hitch_ms_per_s": "12"})))), 1, "FAIL")
check("C 27/27-style stall on kitchen-sink -> FAIL",
      summarize(write("pr45-stall", P, grid(3, ARMS, PR45, mutate=mut(arm="C", run="1", fixture="kitchen-sink",
                                                                      set={"frames": "160", "dropped_frames": "27",
                                                                           "hitch_ms_per_s": "939.74"})))),
      1, "FAIL")
check("C 4 dropped on kitchen-sink -> FAIL",
      summarize(write("pr45-c4", P, grid(3, ARMS, PR45, mutate=mut(arm="C", run="3", fixture="kitchen-sink",
                                                                   set={"dropped_frames": "4"})))), 1, "FAIL")
check("B dropped rate 1.2 % on stress-1k -> FAIL",
      summarize(write("pr45-brate", P, grid(3, ARMS, PR45, mutate=mut(arm="B", run="1", fixture="stress-1k",
                                                                      set={"dropped_frames": "72"})))), 1, "FAIL")
check("A hitch 12 ms/s (environment) -> INVALID",
      summarize(write("pr45-ahitch", P, grid(3, ARMS, PR45, mutate=mut(arm="A", run="2", fixture="stress-1k",
                                                                       set={"hitch_ms_per_s": "12"})))), 2, "INVALID")
check("A breach + C breach in the same run -> INVALID",
      summarize(write("pr45-bothhitch", P, grid(3, ARMS, PR45, mutate=lambda r: r.update(hitch_ms_per_s="12")
                                                if r["run"] == "1" and r["arm"] in "AC" else None))), 2, "INVALID")

# Rule: median relative.
check("C footprint at READY +20 % -> FAIL",
      summarize(write("pr45-fp20", P, grid(3, ARMS, PR45, mutate=mut(arm="C", fixture="stress-1k",
                                                                     set={"footprint_ready_kb": scale("footprint_ready_kb", 1.2)})))),
      1, "FAIL")
check("C footprint at READY +10 % -> PASS",
      summarize(write("pr45-fp10", P, grid(3, ARMS, PR45, mutate=mut(arm="C", fixture="stress-1k",
                                                                     set={"footprint_ready_kb": scale("footprint_ready_kb", 1.1)})))),
      0, "PASS")
check("C +20 % memory in one pair only (median holds) -> PASS",
      summarize(write("pr45-fp1pair", P, grid(3, ARMS, PR45, mutate=mut(arm="C", run="2", fixture="stress-1k",
                                                                        set={"rss_peak_kb": scale("rss_peak_kb", 1.2)})))),
      0, "PASS")
check("B launch→READY +20 % on kitchen-sink -> FAIL",
      summarize(write("pr45-ready-ks", P, grid(3, ARMS, PR45, mutate=mut(arm="B", fixture="kitchen-sink",
                                                                         set={"launch_to_ready_ms": scale("launch_to_ready_ms", 1.2)})))),
      1, "FAIL")
check("C launch→READY +30 % on giant-table -> PASS (advisory)",
      summarize(write("pr45-ready-gt", P, grid(3, ARMS, PR45, mutate=mut(arm="C", fixture="giant-table",
                                                                         set={"launch_to_ready_ms": scale("launch_to_ready_ms", 1.3)})))),
      0, "PASS", contains="ADVISORY >15 %")
check("C first chunk +18 ms (32 %, under the 20 ms floor) -> PASS",
      summarize(write("pr45-chunk18", P, grid(3, ARMS, PR45, mutate=mut(arm="C", fixture="kitchen-sink",
                                                                        set={"first_chunk_ms": lambda r: str(int(r["first_chunk_ms"]) + 18)})))),
      0, "PASS")
check("C first chunk +25 ms (44 %) -> FAIL",
      summarize(write("pr45-chunk25", P, grid(3, ARMS, PR45, mutate=mut(arm="C", fixture="kitchen-sink",
                                                                        set={"first_chunk_ms": lambda r: str(int(r["first_chunk_ms"]) + 25)})))),
      1, "FAIL")
check("C dropped +3 frames on stress-1k (under the 1 % ceiling) -> FAIL",
      summarize(write("pr45-drop3", P, grid(3, ARMS, PR45, mutate=lambda r: r.update(dropped_frames="0")
                                            if r["arm"] != "C" else r.update(dropped_frames="3")))), 1, "FAIL")

# Renderer proof and traversal (Astra Must 3, Fable S5).
check("C with tk2NativeDraws=0 -> INVALID",
      summarize(write("pr45-nonative", P, grid(3, ARMS, PR45, mutate=mut(arm="C", fixture="stress-1k",
                                                                         set={"tk2_native_draws": "0"})))), 2, "INVALID")
check("C without the tk2NativeDraws field -> INVALID",
      summarize(write("pr45-nofield", P, grid(3, ARMS, PR45, mutate=mut(arm="C", run="1", fixture="kitchen-sink",
                                                                        set={"tk2_native_draws": ""})))), 2, "INVALID")
check("B with TextKit 1-backed draws -> INVALID",
      summarize(write("pr45-btk1", P, grid(3, ARMS, PR45, mutate=mut(arm="B", run="2", fixture="kitchen-sink",
                                                                      set={"tk1_backed_draws": "3"})))), 2, "INVALID")
check("C scroll ends before the last block -> FAIL",
      summarize(write("pr45-short", P, grid(3, ARMS, PR45, mutate=mut(arm="C", run="2", fixture="stress-1k",
                                                                      set={"end_row": "700"})))), 1, "FAIL")
check("B frames 30 % below A (traversal) -> FAIL",
      summarize(write("pr45-frames", P, grid(3, ARMS, PR45, mutate=mut(arm="B", run="3", fixture="giant-table",
                                                                       set={"frames": "1700"})))), 1, "FAIL")

# Host (firstmate policy): a busy host never invalidates; it marks the run
# HOST-BUSY, where a PASS counts and a FAIL becomes FAIL-HOST-BUSY (exit 6).
fp30 = mut(arm="C", fixture="stress-1k", set={"footprint_ready_kb": scale("footprint_ready_kb", 1.3)})
Ph = copy.deepcopy(P)
Ph["host_start"]["load1"] = 6.5
check("host load 6.5 at start -> PASS, HOST-BUSY", summarize(write("pr45-hoststart", Ph, grid(3, ARMS, PR45))), 0,
      "PASS", contains='"host_busy": true')
check("host load 6.5 at start + C memory +30 % -> FAIL-HOST-BUSY",
      summarize(write("pr45-hoststart-fail", Ph, grid(3, ARMS, PR45, mutate=fp30))), 6, "FAIL-HOST-BUSY")
Pp = copy.deepcopy(P)
Pp["host_start"]["top"] = [{"pid": 9, "command": "/usr/libexec/PerfPowerServices", "cpu": 177.0, "simulator": False}]
check("daemon at 177 % CPU at start + C crash -> FAIL-HOST-BUSY",
      summarize(write("pr45-hostproc", Pp, grid(3, ARMS, PR45, mutate=mut(arm="C", run="1", fixture="kitchen-sink",
                                                                          set={"status": "crashed", "launch_exit": "1",
                                                                               "frames": ""})))), 6, "FAIL-HOST-BUSY")
Ps = copy.deepcopy(P)
Ps["host_start"]["top"] = [{"pid": 9, "command": "/Library/CoreSimulator/launchd_sim", "cpu": 150.0,
                            "simulator": True}]
check("simulator process at 150 % at start -> PASS, not busy", summarize(write("pr45-hostsim", Ps, grid(3, ARMS, PR45))),
      0, "PASS", contains='"host_busy": false')
check("no host check in the plan -> INVALID",
      summarize(write("pr45-nohost", plan("pr45", 3, ARMS, host_start=None), grid(3, ARMS, PR45))), 2, "INVALID")
check("one trial at load 6.4 -> PASS, HOST-BUSY",
      summarize(write("pr45-trialload", P, grid(3, ARMS, PR45, mutate=mut(arm="B", run="2", fixture="stress-1k",
                                                                          set={"host_load1": "6.4"})))), 0, "PASS",
      contains="stress-1k B run 2: 1-min load 6.4")
check("one trial with a daemon at 150 % + C memory +30 % -> FAIL-HOST-BUSY",
      summarize(write("pr45-trialdaemon", P, grid(3, ARMS, PR45, mutate=lambda r: (fp30(r), r.update(
          host_top3="PerfPowerServices=150;launchd=3") if r["run"] == "1" and r["arm"] == "A" else None)))),
      6, "FAIL-HOST-BUSY")
check("one trial with a simulator process at 150 % -> PASS, not busy",
      summarize(write("pr45-trialsim", P, grid(3, ARMS, PR45, mutate=mut(arm="A", run="1", fixture="giant-table",
                                                                         set={"host_top3": "launchd_sim=150*"})))),
      0, "PASS", contains='"host_busy": false')
check("trial load not recorded -> INVALID",
      summarize(write("pr45-noload", P, grid(3, ARMS, PR45, mutate=mut(arm="A", run="1", fixture="kitchen-sink",
                                                                       set={"host_load1": ""})))), 2, "INVALID")

# BOUNDS: launch→READY gates only where the measured bound allows (default
# Scripts/perf-bounds.json: kitchen-sink yes, giant-table no, stress-1k unmeasured).
ready30 = lambda f: mut(arm="C", fixture=f, set={"launch_to_ready_ms": scale("launch_to_ready_ms", 1.3)})  # noqa: E731
check("C launch→READY +30 % on stress-1k (no measured bound) -> PASS (advisory)",
      summarize(write("pr45-ready-1k", P, grid(3, ARMS, PR45, mutate=ready30("stress-1k")))), 0, "PASS",
      contains="no measured bound")
bounds_file = os.path.join(work, "bounds-1k.json")
with open(bounds_file, "w") as fh:
    json.dump({"fixtures": {"stress-1k": {"launch_to_ready_ms": {"p95_pct": 10.0, "p95_abs": 60.0}},
                            "kitchen-sink": {"launch_to_ready_ms": {"p95_pct": 11.0, "p95_abs": 63.0}}}}, fh)
check("bounds file with a 10 % stress-1k bound: READY +30 % -> FAIL",
      summarize(write("pr45-ready-1k-gated", P, grid(3, ARMS, PR45, mutate=ready30("stress-1k"))), "--bounds",
                bounds_file), 1, "FAIL")
check("no bounds file: kitchen-sink READY +30 % -> PASS (advisory everywhere)",
      summarize(write("pr45-nobounds", P, grid(3, ARMS, PR45, mutate=ready30("kitchen-sink"))), "--bounds",
                os.path.join(work, "no-such-bounds.json")), 0, "PASS")
check("bounds changed after the run was declared -> INVALID",
      summarize(write("pr45-boundsha", plan("pr45", 3, ARMS, bounds_sha256="0" * 64), grid(3, ARMS, PR45))), 2,
      "INVALID", contains="bounds changed")
check("plan's gated fixtures differ from the bounds -> INVALID",
      summarize(write("pr45-boundgated", plan("pr45", 3, ARMS, bound_gated={"launch_to_ready_ms": ["giant-table"]}),
                      grid(3, ARMS, PR45))), 2, "INVALID")

# fixture_arms: the per-fixture arm set is plan data.
check("giant-table without B (fixture_arms) -> INCOMPLETE",
      summarize(write("pr45-gtnoB", plan("pr45", 3, ARMS, fixture_arms={"kitchen-sink": ARMS, "stress-1k": ARMS,
                                                                       "giant-table": ["A", "C"]}),
                      [r for r in grid(3, ARMS, PR45) if not (r["fixture"] == "giant-table" and r["arm"] == "B")])),
      5, "INCOMPLETE", contains="giant-table: arms ['B'] missing")
check("pilot with B on kitchen-sink only -> PILOT",
      summarize(write("pr45-pilot-fa", plan("pr45", 2, ARMS, pilot=True, warmup=0,
                                            fixture_arms={"kitchen-sink": ARMS, "stress-1k": ["A", "C"],
                                                          "giant-table": ["A", "C"]}),
                      [r for r in grid(2, ARMS, PR45) if r["arm"] != "B" or r["fixture"] == "kitchen-sink"]),
                "--pilot"), 4, "PILOT")
check("row for an arm the fixture does not run -> INVALID",
      summarize(write("pr45-undeclared", plan("pr45", 3, ARMS, fixture_arms={"kitchen-sink": ARMS, "stress-1k": ARMS,
                                                                           "giant-table": ["A", "C"]}),
                      grid(3, ARMS, PR45))), 2, "INVALID", contains="undeclared")
check("fixture without the reference arm -> INVALID",
      summarize(write("pr45-noref", plan("pr45", 3, ARMS, fixture_arms={"kitchen-sink": ARMS, "stress-1k": ARMS,
                                                                       "giant-table": ["B", "C"]}),
                      [r for r in grid(3, ARMS, PR45) if not (r["fixture"] == "giant-table" and r["arm"] == "A")])),
      2, "INVALID")

# Classic validity cases (§6.1).
check("candidate crash -> FAIL",
      summarize(write("pr45-crash", P, grid(3, ARMS, PR45, mutate=mut(arm="C", run="2", fixture="kitchen-sink",
                                                                      set={"status": "crashed", "launch_exit": "1",
                                                                           "frames": ""})))), 1, "FAIL")
check("baseline timeout -> INVALID",
      summarize(write("pr45-atimeout", P, grid(3, ARMS, PR45, mutate=mut(arm="A", run="2", fixture="kitchen-sink",
                                                                         set={"status": "timeout", "launch_exit": "143",
                                                                              "frames": ""})))), 2, "INVALID")
check("wrong installed checksum -> INVALID",
      summarize(write("pr45-sha", P, grid(3, ARMS, PR45, mutate=mut(arm="C", run="1", fixture="stress-1k",
                                                                    set={"installed_sha256": "c" * 64})))), 2, "INVALID")
check("missing metric -> INVALID",
      summarize(write("pr45-missing", P, grid(3, ARMS, PR45, mutate=mut(arm="B", run="3", fixture="giant-table",
                                                                        set={"hitch_ms_per_s": ""})))), 2, "INVALID")
check("candidate flag on arm A -> INVALID",
      summarize(write("pr45-argv", P, grid(3, ARMS, PR45, mutate=mut(arm="A", run="1", fixture="giant-table",
                                                                     set={"argv": lambda r: r["argv"] + " -textkit2"})))),
      2, "INVALID")
check("missing trial -> INVALID",
      summarize(write("pr45-missingtrial", P, [r for r in grid(3, ARMS, PR45)
                                               if not (r["arm"] == "B" and r["run"] == "3")])), 2, "INVALID")
check("full calibration passed to pr45 -> INVALID",
      summarize(write("pr45-cal", P, grid(3, ARMS, PR45)), "--calibration", os.path.join(work, "pr45-pass", "plan.json")),
      2, "INVALID")

# Rerun ledger (Fable S2): shared ledger across run directories.
ledger = os.path.join(work, "ledger-case.jsonl")
if os.path.exists(ledger):
    os.remove(ledger)
fail_rows = grid(3, ARMS, PR45, mutate=mut(arm="C", fixture="stress-1k",
                                           set={"footprint_ready_kb": scale("footprint_ready_kb", 1.3)}))
check("ledger: first run FAILs", summarize(write("led-1", P, fail_rows), ledger=ledger), 1, "FAIL")
check("ledger: same run directory re-summarised -> FAIL again (not a rerun)",
      summarize(os.path.join(work, "led-1", "trials.csv"), ledger=ledger), 1, "FAIL")
check("ledger: new run, same candidate -> REFUSED", summarize(write("led-2", P, grid(3, ARMS, PR45)), ledger=ledger),
      2, "REFUSED")
P_new = copy.deepcopy(P)
for a in ("B", "C"):
    P_new["arms"][a]["sha256"] = "e" * 64
new_rows = grid(3, ARMS, PR45, mutate=lambda r: r.update(app_sha256="e" * 64, installed_sha256="e" * 64)
                if r["arm"] in "BC" else None)
check("ledger: after a code change -> measured afresh", summarize(write("led-3", P_new, new_rows), ledger=ledger), 0,
      "PASS")
ledger2 = os.path.join(work, "ledger-invalid.jsonl")
if os.path.exists(ledger2):
    os.remove(ledger2)
inv_rows = grid(3, ARMS, PR45, mutate=mut(arm="A", run="1", fixture="stress-1k", set={"hitch_ms_per_s": "15"}))
check("ledger: INVALID run", summarize(write("led-inv-1", P, inv_rows), ledger=ledger2), 2, "INVALID")
check("ledger: one rerun allowed", summarize(write("led-inv-2", P, inv_rows), ledger=ledger2), 2, "INVALID")
check("ledger: second rerun -> REFUSED", summarize(write("led-inv-3", P, grid(3, ARMS, PR45)), ledger=ledger2), 2,
      "REFUSED")

ledger3 = os.path.join(work, "ledger-busy.jsonl")
if os.path.exists(ledger3):
    os.remove(ledger3)
check("ledger: FAIL on a busy host -> FAIL-HOST-BUSY",
      summarize(write("led-busy-1", Ph, grid(3, ARMS, PR45, mutate=fp30)), ledger=ledger3), 6, "FAIL-HOST-BUSY")
check("ledger: the busy rerun FAILs again -> FAIL (counts)",
      summarize(write("led-busy-2", Ph, grid(3, ARMS, PR45, mutate=fp30)), ledger=ledger3), 1, "FAIL",
      contains="host_busy_rerun_spent")
check("ledger: after that FAIL -> REFUSED", summarize(write("led-busy-3", P, grid(3, ARMS, PR45)), ledger=ledger3), 2,
      "REFUSED")
ledger4 = os.path.join(work, "ledger-busy-pass.jsonl")
if os.path.exists(ledger4):
    os.remove(ledger4)
check("ledger: FAIL-HOST-BUSY, then", summarize(write("led-busyp-1", Ph, grid(3, ARMS, PR45, mutate=fp30)),
                                                ledger=ledger4), 6, "FAIL-HOST-BUSY")
check("ledger: ... a quiet rerun PASSes -> PASS",
      summarize(write("led-busyp-2", P, grid(3, ARMS, PR45)), ledger=ledger4), 0, "PASS")

# ------------------------------------------------------------- bounds
bcsv = write("bounds-measure", plan("full", 10, ["A", "A2"], fixtures=PR45, mode="calibrate"),
             grid(10, ["A", "A2"], PR45))
bout = os.path.join(work, "bounds-measure", "bounds.json")
res = subprocess.run([sys.executable, "-I", SUMMARIZE, bcsv, "--measure-bounds", "--quiet", "--write-bounds", bout],
                     capture_output=True, text=True)
bd = json.load(open(bout)) if os.path.exists(bout) else {}
entry = bd.get("fixtures", {}).get("kitchen-sink", {}).get("launch_to_ready_ms", {})
ok = res.returncode == 0 and bd.get("verdict") == "MEASURED" and entry.get("n_subsets") == 120 and entry.get("p95_pct")
results.append(bool(ok))
print(f"{'ok  ' if ok else 'FAIL'} measure bounds from 10 A–A′ pairs: exit {res.returncode} {bd.get('verdict')} "
      f"subsets {entry.get('n_subsets')} kitchen-sink READY {entry.get('p95_pct')}")
res = subprocess.run([sys.executable, "-I", SUMMARIZE, write("bounds-gate", P, grid(3, ARMS, PR45)), "--measure-bounds",
                      "--quiet", "--write-bounds", os.path.join(work, "bounds-gate", "b.json")],
                     capture_output=True, text=True)
ok = res.returncode == 2
results.append(ok)
print(f"{'ok  ' if ok else 'FAIL'} measure bounds from a gate run -> INVALID: exit {res.returncode}")

# ------------------------------------------------------------- design full
cal_csv = write("cal", plan("full", 10, ["A", "A2"], mode="calibrate"), grid(10, ["A", "A2"], FULL))
cal = os.path.join(work, "cal", "calibration.json")
res = subprocess.run([sys.executable, "-I", SUMMARIZE, cal_csv, "--calibrate", "--quiet", "--write-calibration", cal],
                     capture_output=True, text=True)
cald = json.load(open(cal))
ok = res.returncode == 0 and cald["verdict"] == "CALIBRATED"
results.append(ok)
print(f"{'ok  ' if ok else 'FAIL'} full calibration clean: exit {res.returncode} {cald['verdict']}")
cal_sha = hashlib.sha256(open(cal, "rb").read()).hexdigest()

ncsv = write("cal-noisy", plan("full", 10, ["A", "A2"], mode="calibrate"),
             grid(10, ["A", "A2"], FULL, mutate=mut(arm="A2", run="3", set={"launch_to_ready_ms": "900"})))
res = subprocess.run([sys.executable, "-I", SUMMARIZE, ncsv, "--calibrate", "--quiet"], capture_output=True, text=True)
ncal = json.load(open(os.path.join(work, "cal-noisy", "calibration.json")))
ok = res.returncode == 3 and ncal["verdict"] == "INCONCLUSIVE"
results.append(ok)
print(f"{'ok  ' if ok else 'FAIL'} full calibration noisy (+300 ms once, > 15 %): exit {res.returncode} {ncal['verdict']}")

FP = plan("full", 10, ARMS, cal_sha=cal_sha)
late = lambda r: r.update(started_utc="2099-01-01T00:00:00Z")  # noqa: E731
check("full clean -> PASS", summarize(write("full-pass", FP, grid(10, ARMS, FULL, mutate=late)), "--calibration", cal),
      0, "PASS")
check("full: calibration newer than the trials -> INVALID",
      summarize(write("full-calnew", FP, grid(10, ARMS, FULL)), "--calibration", cal), 2, "INVALID")
check("full: no calibration -> INVALID", summarize(write("full-nocal", plan("full", 10, ARMS),
                                                         grid(10, ARMS, FULL, mutate=late))), 2, "INVALID")
FP2 = copy.deepcopy(FP)
FP2["calibration"]["sha256"] = "0" * 64
check("full: calibration edited after start -> INVALID",
      summarize(write("full-calchanged", FP2, grid(10, ARMS, FULL, mutate=late)), "--calibration", cal), 2, "INVALID")


def outlier(r):
    run = int(r["run"])
    if r["arm"] == "A":
        r["first_chunk_ms"] = "1000" if run % 5 == 0 else "100"
    if r["arm"] == "C":
        r["first_chunk_ms"] = "900"
    late(r)


check("full: A=[100x4,1000] vs C=[900] -> FAIL",
      summarize(write("full-outlier", FP, grid(10, ARMS, FULL, mutate=outlier)), "--calibration", cal), 1, "FAIL")
check("full: C hitch ceiling breach -> FAIL",
      summarize(write("full-hitch", FP, grid(10, ARMS, FULL, mutate=lambda r: (late(r), r.update(hitch_ms_per_s="11")
                                                                               if r["arm"] == "C" and r["run"] == "4" else None))),
                "--calibration", cal), 1, "FAIL")
check("full: 5 pairs -> INCOMPLETE",
      summarize(write("full-5", plan("full", 5, ARMS, cal_sha=cal_sha), grid(5, ARMS, FULL, mutate=late)),
                "--calibration", cal), 5, "INCOMPLETE")

# ------------------------------------------------------------- design pr2
# Lists stage (Fable F2/F7, Astra §7): pr45 + list-dense under one named
# design, the list-native proof, A held to completion, fixture bytes pinned.
P2 = plan("pr2", 3, ARMS)
on_ld = lambda arm, **kv: mut(arm=arm, fixture="list-dense", set=kv)  # noqa: E731
check("pr2 clean -> PASS (list leaf shares disclosed)", summarize(write("pr2-pass", P2, grid(3, ARMS, PR2))), 0, "PASS",
      contains="linked_leaf_share_pct")
check("pr45 with PR 1-era rows (no list fields, no fixture hashes) -> PASS (pr45 unchanged)",
      summarize(write("pr45-pr1rows", P, grid(3, ARMS, PR45, mutate=lambda r: r.update(
          {k: "" for k in ("installed_fixture_sha256", "tk2_list_live", "tk2_list_live_ready", "eligible_text_leaves",
                           "linked_text_leaves", "fallback_text_leaves", "list_leader_leaves",
                           "list_trailing_leaves")})))), 0, "PASS")

# Omission of the list supplement.
check("pr2 plan without list-dense -> INCOMPLETE",
      summarize(write("pr2-nolist", plan("pr2", 3, ARMS, fixtures=PR45), grid(3, ARMS, PR45))), 5, "INCOMPLETE",
      contains="['list-dense'] declared by design pr2 are missing")
check("pr2 plan without list-dense on arm B -> INCOMPLETE",
      summarize(write("pr2-nolistB", plan("pr2", 3, ARMS, fixture_arms={**{f: ARMS for f in PR45},
                                                                         "list-dense": ["A", "C"]}),
                      [r for r in grid(3, ARMS, PR2) if not (r["fixture"] == "list-dense" and r["arm"] == "B")])),
      5, "INCOMPLETE", contains="list-dense: arms ['B'] missing")
check("pr2 declares list-dense but its trials are absent -> INVALID",
      summarize(write("pr2-norows", P2, grid(3, ARMS, PR45))), 2, "INVALID", contains="missing trial")
check("pr2 pilot without list-dense -> PILOT (never PASS)",
      summarize(write("pr2-pilot-nolist", plan("pr2", 2, ARMS, fixtures=PR45, pilot=True, warmup=0),
                      grid(2, ARMS, PR45)), "--pilot"), 4, "PILOT")

# Missing list-native proof / all-fallback lists (C), and B must show none.
check("pr2 C on list-dense without tk2ListLive -> INVALID (list-native proof missing)",
      summarize(write("pr2-c-nolistfield", P2, grid(3, ARMS, PR2, mutate=on_ld("C", tk2_list_live="",
                                                                               tk2_list_live_ready="")))),
      2, "INVALID", contains="list-native proof missing")
check("pr2 C on list-dense with tk2ListLive=0 at READY and end -> INVALID (headings alone are no proof)",
      summarize(write("pr2-c-listzero", P2, grid(3, ARMS, PR2, mutate=on_ld("C", tk2_list_live="0",
                                                                            tk2_list_live_ready="0")))),
      2, "INVALID", contains="no live TextKit 2 list rows")
check("pr2 C on list-dense with tk2ListLive only at READY -> PASS",
      summarize(write("pr2-c-listready", P2, grid(3, ARMS, PR2, mutate=on_ld("C", tk2_list_live="0")))), 0, "PASS")
check("pr2 C on list-dense, every list leaf on SwiftUI -> INVALID (all-fallback lists)",
      summarize(write("pr2-c-allfallback", P2, grid(3, ARMS, PR2, mutate=on_ld(
          "C", tk2_list_live="0", tk2_list_live_ready="0", eligible_text_leaves=lambda r: r["eligible_roots"],
          linked_text_leaves=lambda r: r["link_roots"], fallback_text_leaves="3002")))),
      2, "INVALID", contains="all list leaves fall back to SwiftUI")
check("pr2 C on list-dense, coverage says no eligible list leaf -> INVALID even with live rows",
      summarize(write("pr2-c-allfallback-static", P2, grid(3, ARMS, PR2, mutate=on_ld(
          "C", eligible_text_leaves=lambda r: r["eligible_roots"])))), 2, "INVALID",
      contains="all list leaves fall back to SwiftUI")
check("pr2 C on list-dense without leaf coverage -> INVALID",
      summarize(write("pr2-c-nocoverage", P2, grid(3, ARMS, PR2, mutate=on_ld("C", eligible_text_leaves="",
                                                                              list_leader_leaves="")))),
      2, "INVALID", contains="list leaf coverage missing")
check("pr2 C on list-dense with no list leaves in scope -> INVALID",
      summarize(write("pr2-c-nolistleaves", P2, grid(3, ARMS, PR2, mutate=on_ld("C", list_leader_leaves="0",
                                                                                list_trailing_leaves="0")))),
      2, "INVALID", contains="no list text in scope")
check("pr2 B on list-dense with live TextKit 2 list rows -> INVALID",
      summarize(write("pr2-b-listlive", P2, grid(3, ARMS, PR2, mutate=on_ld("B", tk2_list_live="2")))), 2, "INVALID",
      contains="SwiftUI arm with nonzero/missing")
check("pr2 B on list-dense without tk2ListLive -> INVALID",
      summarize(write("pr2-b-nolistfield", P2, grid(3, ARMS, PR2, mutate=on_ld("B", tk2_list_live="",
                                                                               tk2_list_live_ready="")))),
      2, "INVALID", contains="tk2_list_live")
check("pr2 B on stress-1k reporting live list rows -> INVALID (zero wherever reported)",
      summarize(write("pr2-b-1k-listlive", P2, grid(3, ARMS, PR2, mutate=mut(arm="B", fixture="stress-1k",
                                                                             set={"tk2_list_live_ready": "3"})))),
      2, "INVALID")
check("pr2 C on stress-1k with tk2ListLive=0 -> PASS (list proof is list-dense's)",
      summarize(write("pr2-c-1k-listzero", P2, grid(3, ARMS, PR2, mutate=mut(arm="C", fixture="stress-1k", set={
          "tk2_list_live": "0", "tk2_list_live_ready": "0"})))), 0, "PASS")
check("pilot of list-dense under the default design -> list proof still required (INVALID)",
      summarize(write("pr45-pilot-ld-listzero", plan("pr45", 2, ARMS, fixtures=["list-dense"], pilot=True, warmup=0),
                      grid(2, ARMS, ["list-dense"], mutate=on_ld("C", tk2_list_live="0", tk2_list_live_ready="0"))),
                "--pilot"), 2, "INVALID", contains="no live TextKit 2 list rows")

# Truncated traversal: a candidate that stops short FAILs (precedence 3); A,
# held to completion by pr2, makes the run INVALID.
check("pr2 C list-dense scroll ends before the last block -> FAIL",
      summarize(write("pr2-c-short", P2, grid(3, ARMS, PR2, mutate=mut(arm="C", run="2", fixture="list-dense",
                                                                       set={"end_row": "500"})))), 1, "FAIL",
      contains="scroll ended at row 500, not the last block 639")
check("pr2 A list-dense scroll ends before the last block -> INVALID",
      summarize(write("pr2-a-short", P2, grid(3, ARMS, PR2, mutate=mut(arm="A", run="2", fixture="list-dense",
                                                                       set={"end_row": "500"})))), 2, "INVALID",
      contains="baseline_failure")
check("pr2 A list-dense trial incomplete (completed=0) -> INVALID",
      summarize(write("pr2-a-incomplete", P2, grid(3, ARMS, PR2, mutate=mut(arm="A", run="1", fixture="list-dense",
                                                                            set={"status": "incomplete",
                                                                                 "completed": "0"})))),
      2, "INVALID", contains="baseline trial status incomplete")
P2noA = copy.deepcopy(P2)
P2noA["arms"]["A"]["requires_completion"] = False
check("pr2 plan without A's completion markers -> INCOMPLETE",
      summarize(write("pr2-a-nomarkers", P2noA, grid(3, ARMS, PR2))), 5, "INCOMPLETE",
      contains="arm A lacks completion markers")
check("pr45 A scroll short (A not held to completion) -> PASS (pr45 unchanged)",
      summarize(write("pr45-a-short", P, grid(3, ARMS, PR45, mutate=mut(arm="A", run="2", fixture="stress-1k",
                                                                        set={"end_row": "500"})))), 0, "PASS")

# Gate invariant (Fable F2): READY block counts equal across arms.
check("pr2 list-dense READY blocks 641 on B/C vs 640 on A -> INVALID",
      summarize(write("pr2-blocks", P2, grid(3, ARMS, PR2, mutate=lambda r: r.update(blocks="641", end_row="640")
                                             if r["fixture"] == "list-dense" and r["arm"] in "BC" else None))),
      2, "INVALID", contains="READY block counts disagree")

# Mismatched fixture bytes.
P2hash = copy.deepcopy(P2)
P2hash["arms"]["A"]["fixture_sha256"]["list-dense"] = "d" * 64
check("pr2 list-dense.json differs across arms -> INVALID",
      summarize(write("pr2-hash", P2hash, grid(3, ARMS, PR2, mutate=on_ld("A", installed_fixture_sha256="d" * 64)))),
      2, "INVALID", contains="list-dense.json differs across arms")
check("pr2 plan without fixture hashes -> INVALID",
      summarize(write("pr2-nohash", plan("pr2", 3, ARMS, fixture_hashes=False), grid(3, ARMS, PR2))), 2, "INVALID",
      contains="plan records no sha256 of list-dense.json")
check("pr2 installed list-dense.json differs from the plan on one trial -> INVALID",
      summarize(write("pr2-installed-hash", P2, grid(3, ARMS, PR2, mutate=mut(arm="C", run="3", fixture="list-dense",
                                                                              set={"installed_fixture_sha256": "f" * 64})))),
      2, "INVALID", contains="installed list-dense.json sha256")
P45hash = plan("pr45", 3, ARMS, fixture_hashes=True)
P45hash["arms"]["B"]["fixture_sha256"]["stress-1k"] = "d" * 64
check("pr45 with recorded fixture hashes that differ -> INVALID (checked whenever recorded)",
      summarize(write("pr45-hash", P45hash, grid(3, ARMS, PR45, mutate=mut(arm="B", fixture="stress-1k",
                                                                           set={"installed_fixture_sha256": "d" * 64})))),
      2, "INVALID", contains="stress-1k.json differs across arms")

# Same thresholds as pr45.
check("pr2 C list-dense footprint at READY +20 % -> FAIL",
      summarize(write("pr2-fp20", P2, grid(3, ARMS, PR2, mutate=on_ld(
          "C", footprint_ready_kb=scale("footprint_ready_kb", 1.2))))), 1, "FAIL")
check("pr2 B list-dense dropped rate 1.2 % -> FAIL",
      summarize(write("pr2-brate", P2, grid(3, ARMS, PR2, mutate=mut(arm="B", run="1", fixture="list-dense",
                                                                     set={"dropped_frames": "101"})))), 1, "FAIL")
check("pr2 C list-dense launch→READY +30 % -> PASS (no measured bound: advisory)",
      summarize(write("pr2-ready-ld", P2, grid(3, ARMS, PR2, mutate=ready30("list-dense")))), 0, "PASS",
      contains="no measured bound")
bounds_ld = os.path.join(work, "bounds-ld.json")
with open(bounds_ld, "w") as fh:
    json.dump({"fixtures": {"list-dense": {"launch_to_ready_ms": {"p95_pct": 9.0, "p95_abs": 80.0}}}}, fh)
check("pr2 with a merged 9 % list-dense READY bound: READY +30 % -> FAIL",
      summarize(write("pr2-ready-ld-gated", P2, grid(3, ARMS, PR2, mutate=ready30("list-dense"))), "--bounds",
                bounds_ld), 1, "FAIL")

# Pilot, host, ledger.
check("pr2 pilot -> PILOT (never PASS)",
      summarize(write("pr2-pilot", plan("pr2", 2, ARMS, pilot=True, warmup=0), grid(2, ARMS, PR2)), "--pilot"),
      4, "PILOT")
P2h = copy.deepcopy(P2)
P2h["host_start"]["load1"] = 6.5
fp30_ld = on_ld("C", footprint_ready_kb=scale("footprint_ready_kb", 1.3))
check("pr2 busy host + C list-dense memory +30 % -> FAIL-HOST-BUSY",
      summarize(write("pr2-hostbusy", P2h, grid(3, ARMS, PR2, mutate=fp30_ld))), 6, "FAIL-HOST-BUSY")
ledger5 = os.path.join(work, "ledger-pr2.jsonl")
if os.path.exists(ledger5):
    os.remove(ledger5)
check("ledger pr2: first run FAILs", summarize(write("led2-1", P2, grid(3, ARMS, PR2, mutate=fp30_ld)),
                                               ledger=ledger5), 1, "FAIL")
check("ledger pr2: same candidate rerun -> REFUSED", summarize(write("led2-2", P2, grid(3, ARMS, PR2)),
                                                               ledger=ledger5), 2, "REFUSED")
ledger6 = os.path.join(work, "ledger-pr45-pr2.jsonl")
if os.path.exists(ledger6):
    os.remove(ledger6)
check("ledger: pr45 FAILs for these binaries", summarize(write("led45-1", P, grid(3, ARMS, PR45, mutate=fp30)),
                                                         ledger=ledger6), 1, "FAIL")
check("ledger: ... then pr2 on the same binaries -> REFUSED (pr2 includes pr45)",
      summarize(write("led45-2", P2, grid(3, ARMS, PR2)), ledger=ledger6), 2, "REFUSED",
      contains="which design pr2 includes")
ledger7 = os.path.join(work, "ledger-pr2-pr45.jsonl")
if os.path.exists(ledger7):
    os.remove(ledger7)
check("ledger: pr2 FAILs on list-dense", summarize(write("led2b-1", P2, grid(3, ARMS, PR2, mutate=fp30_ld)),
                                                   ledger=ledger7), 1, "FAIL")
check("ledger: ... pr45 is not REFUSED by it (pr45 includes nothing; never the PR 2 gate)",
      summarize(write("led2b-2", P, grid(3, ARMS, PR45)), ledger=ledger7), 0, "PASS")
ledger8 = os.path.join(work, "ledger-pr2-invalid.jsonl")
if os.path.exists(ledger8):
    os.remove(ledger8)
inv2 = grid(3, ARMS, PR2, mutate=mut(arm="A", run="1", fixture="list-dense", set={"hitch_ms_per_s": "15"}))
check("ledger pr2: INVALID run", summarize(write("led2i-1", P2, inv2), ledger=ledger8), 2, "INVALID")
check("ledger pr2: one rerun allowed", summarize(write("led2i-2", P2, inv2), ledger=ledger8), 2, "INVALID")
check("ledger pr2: second rerun -> REFUSED", summarize(write("led2i-3", P2, grid(3, ARMS, PR2)), ledger=ledger8), 2,
      "REFUSED")

# --print-design: perf-gate.sh takes the pr2 shape from here; pr45 unchanged.
for name, want in (("pr2", ["fixtures=kitchen-sink stress-1k giant-table list-dense",
                            "fixture_arms=kitchen-sink=A,B,C stress-1k=A,B,C giant-table=A,B,C list-dense=A,B,C",
                            "runs=3", "warmup=1", "rule=median-relative", "list_proof=list-dense",
                            "baseline_completion=1", "fixture_hashes=1", "includes=pr45"]),
                   ("pr45", ["fixtures=kitchen-sink stress-1k giant-table",
                             "fixture_arms=kitchen-sink=A,B,C stress-1k=A,B,C giant-table=A,B,C", "runs=3",
                             "warmup=1", "rule=median-relative", "list_proof=", "baseline_completion=0",
                             "fixture_hashes=0", "includes="])):
    res = subprocess.run([sys.executable, "-I", SUMMARIZE, "--print-design", name], capture_output=True, text=True)
    lines = res.stdout.splitlines()
    ok = res.returncode == 0 and all(w in lines for w in want)
    results.append(ok)
    print(f"{'ok  ' if ok else 'FAIL'} --print-design {name}: exit {res.returncode} "
          f"{[w for w in want if w not in lines] or 'all lines present'}")

# RENDERER_STATS parsing (perf_trial.py): the list keys land in their columns,
# the READY line feeds tk2_list_live_ready, and an old build leaves them empty.
log_path = os.path.join(work, "stats.log")
with open(log_path, "w") as fh:
    fh.write("#T0\t1000000000\n"
             "1600000000\tREADY fixture=list-dense blocks=640 firstChunkMs=50\n"
             "1600000001\tRENDERER_STATS renderer=textkit2 tk2Live=9 tk2Layouts=1 tk2Draws=0 tk2NativeDraws=0 "
             "tk1BackedRows=0 tk1BackedDraws=0 eligibleRoots=40 fallbackRoots=600 textFallbackRoots=0 linkRoots=0 "
             "tk2ListLive=6 eligibleTextLeaves=2440 linkedTextLeaves=300 fallbackTextLeaves=302 "
             "listLeaderLeaves=2700 listTrailingLeaves=300\n"
             "9000000000\tSCROLL_METRICS fixture=list-dense frames=8400 dropped=0 hitchRatioMsPerS=0.00 startRow=0 "
             "endRow=639 scrollMs=140000 completed=1\n"
             "9000000001\tRENDERER_STATS renderer=textkit2 tk2Live=3 tk2Layouts=900 tk2Draws=950 tk2NativeDraws=800 "
             "tk1BackedRows=1 tk1BackedDraws=150 eligibleRoots=40 fallbackRoots=600 textFallbackRoots=0 linkRoots=0 "
             "tk2ListLive=2 eligibleTextLeaves=2440 linkedTextLeaves=300 fallbackTextLeaves=302 "
             "listLeaderLeaves=2700 listTrailingLeaves=300 futureKey=7\n"
             "#EXIT\t9500000000\t0\n")
parsed = perf_trial.derive(log_path, "-", {"requires_completion": "1"})
want = {"tk2_list_live_ready": "6", "tk2_list_live": "2", "eligible_text_leaves": "2440", "linked_text_leaves": "300",
        "fallback_text_leaves": "302", "list_leader_leaves": "2700", "list_trailing_leaves": "300",
        "renderer_stats_extra": "futureKey=7"}
ok = all(parsed.get(k) == v for k, v in want.items())
old_log = os.path.join(work, "stats-old.log")
with open(old_log, "w") as fh:
    fh.write("".join(line + "\n" for line in open(log_path).read().splitlines()
                     if "tk2ListLive" not in line))
old = perf_trial.derive(old_log, "-", {})
ok = ok and all(old.get(k) == "" for k in want if k != "renderer_stats_extra")
results.append(ok)
print(f"{'ok  ' if ok else 'FAIL'} perf_trial parses the list RENDERER_STATS keys "
      f"({ {k: parsed.get(k) for k in want} }); an old build leaves them empty")

# list-dense bounds: a 3-pair calibrate-mode pilot on A only, measured, then
# merged into a copy of Scripts/perf-bounds.json (never replacing an entry).
ld_plan = plan("full", 3, ["A", "A2"], fixtures=["list-dense"], mode="calibrate", pilot=True, fixture_hashes=True)
ld_csv = write("bounds-ld-measure", ld_plan, grid(3, ["A", "A2"], ["list-dense"]))
ld_out = os.path.join(work, "bounds-ld-measure", "bounds.json")
res = subprocess.run([sys.executable, "-I", SUMMARIZE, ld_csv, "--measure-bounds", "--quiet", "--write-bounds", ld_out],
                     capture_output=True, text=True)
ldb = json.load(open(ld_out)) if os.path.exists(ld_out) else {}
ok = (res.returncode == 0 and ldb.get("verdict") == "MEASURED"
      and ldb.get("fixtures", {}).get("list-dense", {}).get("launch_to_ready_ms", {}).get("n_subsets") == 1
      and ldb.get("fixture_sha256", {}).get("list-dense") == FIXTURE_SHA["list-dense"])
results.append(ok)
print(f"{'ok  ' if ok else 'FAIL'} measure list-dense bounds from 3 A–A′ pairs: exit {res.returncode} {ldb.get('verdict')}")
base_copy = os.path.join(work, "perf-bounds-copy.json")
with open(os.path.join(SCRIPTS, "perf-bounds.json")) as src, open(base_copy, "w") as dst:
    base_before = json.load(src)
    json.dump(base_before, dst, indent=2, sort_keys=True)
res = subprocess.run([sys.executable, "-I", SUMMARIZE, "--merge-bounds", ld_out, "--bounds", base_copy],
                     capture_output=True, text=True)
merged = json.load(open(base_copy))
src_entry = (merged.get("fixture_sources") or {}).get("list-dense") or {}
ok = (res.returncode == 0 and "list-dense" in merged["fixtures"]
      and all(merged["fixtures"][f] == base_before["fixtures"][f] for f in base_before["fixtures"])
      and merged["app_sha256"] == base_before["app_sha256"] and src_entry.get("app_sha256") == SHA["A"]
      and src_entry.get("fixture_sha256") == FIXTURE_SHA["list-dense"])
results.append(ok)
print(f"{'ok  ' if ok else 'FAIL'} merge list-dense bounds: exit {res.returncode}; existing entries unchanged; "
      f"fixture_sources.list-dense app {str(src_entry.get('app_sha256'))[:8]}")
res = subprocess.run([sys.executable, "-I", SUMMARIZE, "--merge-bounds", ld_out, "--bounds", base_copy],
                     capture_output=True, text=True)
ok = res.returncode == 2 and "already bounded" in res.stderr
results.append(ok)
print(f"{'ok  ' if ok else 'FAIL'} merge the same fixture again -> refused: exit {res.returncode}")
bad_measure = os.path.join(work, "bounds-ld-measure", "bounds-invalid.json")
with open(bad_measure, "w") as fh:
    json.dump({**ldb, "verdict": "INVALID", "fixtures": {"lists-parity": {}}}, fh)
res = subprocess.run([sys.executable, "-I", SUMMARIZE, "--merge-bounds", bad_measure, "--bounds", base_copy],
                     capture_output=True, text=True)
ok = res.returncode == 2 and "MEASURED" in res.stderr
results.append(ok)
print(f"{'ok  ' if ok else 'FAIL'} merge an INVALID measurement -> refused: exit {res.returncode}")
res = subprocess.run([sys.executable, "-I", SUMMARIZE, write("bounds-ld-gate", P2, grid(3, ARMS, PR2)),
                      "--measure-bounds", "--quiet", "--write-bounds", os.path.join(work, "bounds-ld-gate", "b.json")],
                     capture_output=True, text=True)
ok = res.returncode == 2
results.append(ok)
print(f"{'ok  ' if ok else 'FAIL'} measure bounds from a pr2 gate run (not A–A′) -> INVALID: exit {res.returncode}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)
