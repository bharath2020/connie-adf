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
BLOCKS = {"kitchen-sink": 38, "stress-1k": 1000, "stress-5k": 5000, "giant-table": 402}
FRAMES = {"kitchen-sink": 166, "stress-1k": 5930, "stress-5k": 29665, "giant-table": 2429}
ELIGIBLE = {"kitchen-sink": 10, "stress-1k": 480, "stress-5k": 2400, "giant-table": 1}
LINKS = {"kitchen-sink": 1, "stress-1k": 101, "stress-5k": 507, "giant-table": 0}
PR45 = ["kitchen-sink", "stress-1k", "giant-table"]
FULL = ["kitchen-sink", "stress-5k", "giant-table"]
ARMS = ["A", "C", "B"]
HOST = {"load1": 2.1, "load5": 2.0, "load15": 1.9,
        "top": [{"pid": 1, "command": "/sbin/launchd", "cpu": 3.0, "simulator": False}]}

work = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.environ.get("TMPDIR", "/tmp"), "perf-summarize-tests")
os.makedirs(work, exist_ok=True)
results: list[bool] = []


def plan(design: str, runs: int, arms: list[str], fixtures: list[str] | None = None, mode: str = "gate",
         cal_sha: str | None = None, **over) -> dict:
    specs = {}
    for a in arms:
        cand = a in ("B", "C")
        specs[a] = {"label": a, "app": f"/x/{a}.app", "sha256": SHA[a], "role": "candidate" if cand else "baseline",
                    "required_flags": {"C": ["-textkit2", "-rendererStats"],
                                       "B": ["-rendererReset", "-rendererStats"]}.get(a, []),
                    "forbidden_flags": [] if a == "C" else (["-textkit2"] + ([] if cand else ["-rendererStats"])),
                    "requires_completion": cand, "expected_renderer": {"C": "textkit2", "B": "swiftui"}.get(a)}
    p = {"version": 3, "mode": mode, "design": design, "pilot": False,
         "fixtures": fixtures or (PR45 if design == "pr45" else FULL), "runs": runs, "warmup": 1, "reference": "A",
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
             argv=f"-fixture {fixture} -autoscroll{flags}", requires_completion="1" if arm in "BC" else "0",
             started_utc="2026-10-26T12:00:00Z", host_load1=f"{2 + rng.random():.2f}", host_top3="launchd=3",
             status="ok", launch_exit="0", launch_to_ready_ms=f"{600 + rng.uniform(-10, 10):.1f}",
             ready_fixture=fixture, first_chunk_ms=str(56 + rng.randint(0, 3)), blocks=str(BLOCKS[fixture]),
             frames=str(frames + rng.randint(-2, 2)), dropped_frames=str(dropped),
             dropped_rate_pct=f"{dropped / frames * 100:.3f}", hitch_ms_per_s=f"{dropped * 0.05:.2f}",
             rss_ready_kb=str(80000 + rng.randint(-300, 300)), rss_peak_kb=str(90000 + rng.randint(-300, 300)),
             footprint_ready_kb=str(60000 + rng.randint(-300, 300)),
             footprint_peak_kb=str(70000 + rng.randint(-300, 300)), memory_samples="50", footprint_samples="10")
    if arm in ("B", "C"):
        c = arm == "C"
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

# Host load.
Ph = copy.deepcopy(P)
Ph["host_start"]["load1"] = 6.5
check("host load 6.5 at start -> INVALID", summarize(write("pr45-hoststart", Ph, grid(3, ARMS, PR45))), 2, "INVALID")
Pp = copy.deepcopy(P)
Pp["host_start"]["top"] = [{"pid": 9, "command": "/usr/libexec/PerfPowerServices", "cpu": 177.0, "simulator": False}]
check("daemon at 177 % CPU at start -> INVALID", summarize(write("pr45-hostproc", Pp, grid(3, ARMS, PR45))), 2,
      "INVALID")
Ps = copy.deepcopy(P)
Ps["host_start"]["top"] = [{"pid": 9, "command": "/Library/CoreSimulator/launchd_sim", "cpu": 150.0,
                            "simulator": True}]
check("simulator process at 150 % at start -> PASS", summarize(write("pr45-hostsim", Ps, grid(3, ARMS, PR45))), 0,
      "PASS")
check("no host check in the plan -> INVALID",
      summarize(write("pr45-nohost", plan("pr45", 3, ARMS, host_start=None), grid(3, ARMS, PR45))), 2, "INVALID")
check("one trial at load 6.4 -> INVALID",
      summarize(write("pr45-trialload", P, grid(3, ARMS, PR45, mutate=mut(arm="B", run="2", fixture="stress-1k",
                                                                          set={"host_load1": "6.4"})))), 2, "INVALID")
check("trial load not recorded -> INVALID",
      summarize(write("pr45-noload", P, grid(3, ARMS, PR45, mutate=mut(arm="A", run="1", fixture="kitchen-sink",
                                                                       set={"host_load1": ""})))), 2, "INVALID")

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

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)
