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

import contextlib
import copy
import csv
import hashlib
import importlib.util
import io
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
# The summarizer in this process too: a refused design declaration (a
# known_debt or predecessor entry) lives in DESIGNS, which no plan can change.
_spec = importlib.util.spec_from_file_location("perf_summarize", SUMMARIZE)
ps = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ps)

# D is the predecessor build of design pr3 (PR 2's tip): its sha256 is the
# one the design pins.
SHA = {"A": "a" * 64, "A2": "a" * 64, "B": "b" * 64, "C": "b" * 64,
       "D": ps.DESIGNS["pr3"]["predecessor"]["app_sha256"]}
BLOCKS = {"kitchen-sink": 38, "stress-1k": 1000, "stress-5k": 5000, "giant-table": 402, "list-dense": 640,
          "code-dense": 600}
FRAMES = {"kitchen-sink": 166, "stress-1k": 5930, "stress-5k": 29665, "giant-table": 2429, "list-dense": 8400,
          "code-dense": 7800}
ELIGIBLE = {"kitchen-sink": 10, "stress-1k": 480, "stress-5k": 2400, "giant-table": 1, "list-dense": 40,
            "code-dense": 0}
LINKS = {"kitchen-sink": 1, "stress-1k": 101, "stress-5k": 507, "giant-table": 0, "list-dense": 0, "code-dense": 0}
# List text leaves (leaders + trailing) per fixture, for the lists-stage
# RENDERER_STATS fields a new build prints (stress-1k: 1,815 plain leaders).
LIST_LEAVES = {"kitchen-sink": 8, "stress-1k": 1815, "stress-5k": 8914, "giant-table": 0, "list-dense": 3000,
               "code-dense": 0}
# Top-level code roots (eligible, SwiftUI fallback) per fixture, for the
# code-block-stage RENDERER_STATS fields a PR 3 build prints.
CODE = {"kitchen-sink": (1, 0), "stress-1k": (80, 0), "stress-5k": (400, 0), "giant-table": (0, 0),
        "list-dense": (0, 0), "code-dense": (552, 48)}
CODE_KEYS = ("tk2_code_live_ready", "tk2_code_live", "tk2_code_draws", "eligible_code_roots", "fallback_code_roots",
             "code_admitted", "code_gated")
FIXTURE_SHA = {f: hashlib.sha256(f"fixture {f}".encode()).hexdigest() for f in BLOCKS}
PR45 = ["kitchen-sink", "stress-1k", "giant-table"]
PR2 = PR45 + ["list-dense"]
PR3 = PR2 + ["code-dense"]
PRED = ["list-dense", "kitchen-sink"]
FULL = ["kitchen-sink", "stress-5k", "giant-table"]
ARMS = ["A", "C", "B"]
HOST = {"load1": 2.1, "load5": 2.0, "load15": 1.9,
        "top": [{"pid": 1, "command": "/sbin/launchd", "cpu": 3.0, "simulator": False}]}

work = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.environ.get("TMPDIR", "/tmp"), "perf-summarize-tests")
os.makedirs(work, exist_ok=True)
results: list[bool] = []


def pred_block(runs: int = 5, warmup: int = 1, fixtures: list[str] | None = None, **over) -> dict:
    """The plan's predecessor block as perf-gate.sh --app-d writes it."""
    fixtures = fixtures or PRED
    block = {"arm": "D", "against": "C", "label": "predecessor (TextKit 2)", "fixtures": fixtures, "runs": runs,
             "warmup": warmup, "sensitivity_dropped_frames": 2.0,
             "arms": {"D": {"label": "predecessor (TextKit 2)", "app": "/x/D.app", "sha256": SHA["D"],
                            "role": "predecessor", "required_flags": ["-textkit2", "-rendererStats"],
                            "forbidden_flags": [], "requires_completion": True, "expected_renderer": "textkit2",
                            "fixture_sha256": {f: FIXTURE_SHA[f] for f in fixtures}},
                      "C": {"sha256": SHA["C"], "fixture_sha256": {f: FIXTURE_SHA[f] for f in fixtures}}},
             "csv": "predecessor.csv", "warmup_csv": "predecessor-warmup.csv"}
    block.update(over)
    return block


def plan(design: str, runs: int, arms: list[str], fixtures: list[str] | None = None, mode: str = "gate",
         cal_sha: str | None = None, fixture_hashes: bool | None = None, pred: bool | dict | None = None,
         **over) -> dict:
    """A plan as perf-gate.sh writes it. Designs pr2 and pr3 (gate mode) hold
    A to completion and record each arm's fixture sha256s, as the driver
    does; a pr3 gate plan carries the predecessor block (pred=False: none)."""
    fixtures = fixtures or {"pr45": PR45, "pr2": PR2, "pr3": PR3}.get(design, FULL)
    if fixture_hashes is None:
        fixture_hashes = design in ("pr2", "pr3")
    if pred is None:
        pred = design == "pr3" and mode == "gate"
    specs = {}
    for a in arms:
        cand = a in ("B", "C")
        specs[a] = {"label": a, "app": f"/x/{a}.app", "sha256": SHA[a], "role": "candidate" if cand else "baseline",
                    "required_flags": {"C": ["-textkit2", "-rendererStats"],
                                       "B": ["-rendererReset", "-rendererStats"]}.get(a, []),
                    "forbidden_flags": [] if a == "C" else (["-textkit2"] + ([] if cand else ["-rendererStats"])),
                    "requires_completion": cand or (a == "A" and design in ("pr2", "pr3") and mode == "gate"),
                    "expected_renderer": {"C": "textkit2", "B": "swiftui"}.get(a)}
        if fixture_hashes:
            specs[a]["fixture_sha256"] = {f: FIXTURE_SHA[f] for f in fixtures}
    p = {"version": 4 if fixture_hashes else 3, "mode": mode, "design": design, "pilot": False,
         "fixtures": fixtures, "runs": runs, "warmup": 1, "reference": "A",
         "candidates": ["A2"] if mode == "calibrate" else [a for a in ("C", "B") if a in arms], "arms": specs,
         "sampler": True, "footprint": True, "expected_blocks": {}, "host_start": copy.deepcopy(HOST),
         "calibration": {"path": "x", "sha256": cal_sha} if cal_sha else None}
    if pred:
        p["predecessor"] = pred if isinstance(pred, dict) else pred_block()
    p.update(over)
    return p


def row(run: int, fixture: str, arm: str, rng: random.Random, **over) -> dict:
    r = {c: "" for c in perf_trial.CSV_COLUMNS}
    flags = {"C": " -textkit2 -rendererStats", "B": " -rendererReset -rendererStats",
             "D": " -textkit2 -rendererStats"}.get(arm, "")
    frames = FRAMES[fixture]
    dropped = rng.randint(0, 1) if frames >= 2000 else 0
    r.update(run=str(run), fixture=fixture, arm=arm, label=arm, app_sha256=SHA[arm], installed_sha256=SHA[arm],
             installed_fixture_sha256=FIXTURE_SHA[fixture], argv=f"-fixture {fixture} -autoscroll{flags}",
             requires_completion="1" if arm in ("B", "C", "D") else "0",
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
    if arm in ("B", "C", "D"):
        c = arm in ("C", "D")  # D, the predecessor, runs TextKit 2 ON like C
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
        if c and ELIGIBLE[fixture] == 0 and not CODE[fixture][0]:
            r.update(tk2_layouts="0", tk2_native_draws="0", tk2_draws="0", tk1_backed_draws="0", tk2_live="0",
                     tk2_live_ready="0")
        r.update(tk2_conversions="60" if c else "0")
        if arm != "D":
            # A PR 3 build prints the code keys in both arms; PR 2's tip (D)
            # prints none. Static coverage is the same in B and C.
            code_eligible, code_fallback = CODE[fixture]
            code_gated = code_eligible // 50
            live = arm == "C" and code_eligible > 0
            r.update(tk2_code_live_ready="5" if live else "0", tk2_code_live="3" if live else "0",
                     tk2_code_draws=str(code_eligible) if live else "0", eligible_code_roots=str(code_eligible),
                     fallback_code_roots=str(code_fallback), code_admitted=str(code_eligible - code_gated),
                     code_gated=str(code_gated))
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


def pred_grid(runs: int = 5, fixtures: list[str] | None = None, seed: int = 7, mutate=None,
              first=lambda run: "D" if run % 2 else "C") -> list[dict]:
    """The D/C block's counted rows: interleaved pairs, D first on odd pairs
    and C first on even ones (order_index 1 and 2), as perf-gate.sh runs it."""
    rng = random.Random(seed)
    rows = []
    for run in range(1, runs + 1):
        for f in fixtures or PRED:
            order = ["D", "C"] if first(run) == "D" else ["C", "D"]
            for index, a in enumerate(order, 1):
                r = row(run, f, a, rng, order_index=str(index))
                if mutate:
                    mutate(r)
                rows.append(r)
    return rows


def pred_warm(warmup: int = 1, fixtures: list[str] | None = None) -> list[dict]:
    rng = random.Random(11)
    return [row(0, f, a, rng, order_index=str(i)) for _ in range(warmup) for f in fixtures or PRED
            for i, a in enumerate(("D", "C"), 1)]


def write_csv(path: str, rows: list[dict]) -> None:
    with open(path, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=perf_trial.CSV_COLUMNS)
        w.writeheader()
        w.writerows(rows)


def write(name: str, p: dict, rows: list[dict], pred_rows=None, warm_rows=None) -> str:
    """Writes one case. A plan with a predecessor block also gets its D/C
    rows (predecessor.csv) and warm-ups (predecessor-warmup.csv): by default
    a complete, quiet block of the plan's shape; a list to use those rows;
    False to leave the file out."""
    d = os.path.join(work, name)
    os.makedirs(d, exist_ok=True)
    for stale in ("trials.csv.json", "summary.md", "predecessor.csv", "predecessor-warmup.csv"):
        if os.path.exists(os.path.join(d, stale)):
            os.remove(os.path.join(d, stale))
    with open(os.path.join(d, "plan.json"), "w") as fh:
        json.dump(p, fh)
    write_csv(os.path.join(d, "trials.csv"), rows)
    block = p.get("predecessor")
    if isinstance(block, dict) and isinstance(block.get("fixtures"), list):
        shape = (int(block.get("runs") or 0), block["fixtures"])
        if pred_rows is None:
            pred_rows = pred_grid(*shape)
        if warm_rows is None:
            warm_rows = pred_warm(max(int(block.get("warmup") or 0), 1), block["fixtures"])
        if pred_rows is not False:
            write_csv(os.path.join(d, "predecessor.csv"), pred_rows)
        if warm_rows is not False:
            write_csv(os.path.join(d, "predecessor-warmup.csv"), warm_rows)
    return os.path.join(d, "trials.csv")


def summarize(path: str, *extra: str, ledger: str | None = None) -> tuple[int, dict]:
    ledger = ledger or path + ".ledger.jsonl"
    if ledger == path + ".ledger.jsonl" and os.path.exists(ledger):
        os.remove(ledger)
    res = subprocess.run([sys.executable, "-I", SUMMARIZE, path, "--quiet", "--json", path + ".json",
                          "--ledger", ledger, *extra], capture_output=True, text=True)
    data = json.load(open(path + ".json")) if os.path.exists(path + ".json") else {}
    return res.returncode, data


def summarize_here(path: str, *extra: str, ledger: str | None = None) -> tuple[int, dict]:
    """summarize() in this process, for a case that has changed ps.DESIGNS."""
    ledger = ledger or path + ".ledger.jsonl"
    if ledger == path + ".ledger.jsonl" and os.path.exists(ledger):
        os.remove(ledger)
    if os.path.exists(path + ".json"):
        os.remove(path + ".json")
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        code = ps.main([path, "--quiet", "--json", path + ".json", "--ledger", ledger, *extra])
    data = json.load(open(path + ".json")) if os.path.exists(path + ".json") else {}
    return code, data


@contextlib.contextmanager
def pr3_design(change):
    """Design pr3 with `change(design)` applied, restored afterwards."""
    saved = copy.deepcopy(ps.DESIGNS["pr3"])
    try:
        change(ps.DESIGNS["pr3"])
        yield
    finally:
        ps.DESIGNS["pr3"] = saved


def print_design_here(name: str) -> tuple[int, str]:
    """`--print-design <name>` in this process: (exit status, stderr)."""
    err = io.StringIO()
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
        code = ps.main(["--print-design", name])
    return code, err.getvalue()


def check(name: str, got: tuple[int, dict], want_code: int, want_verdict: str, contains: str | None = None,
          lacks: str | None = None) -> None:
    code, data = got
    verdict = data.get("verdict")
    problems = data.get("problems") or []
    text = json.dumps(data, default=str)
    ok = (code == want_code and verdict == want_verdict and (contains is None or contains in text)
          and (lacks is None or lacks not in text))
    results.append(ok)
    first = problems[0]["message"] if problems else (data.get("refused") or "; ".join(data.get("reduced") or []))
    print(f"{'ok  ' if ok else 'FAIL'} {name}: exit {code} {verdict} (want {want_code} {want_verdict})"
          f"{'' if contains is None or contains in text else ' [missing: ' + contains + ']'}"
          f"{'' if lacks is None or lacks not in text else ' [present: ' + lacks + ']'} {first[:100]}")


def check_that(name: str, ok: bool, detail: str = "") -> None:
    results.append(bool(ok))
    print(f"{'ok  ' if ok else 'FAIL'} {name}{': ' + detail if detail else ''}")


def mut(**cond_and_update):
    """mut(arm="C", run="2", fixture=None, set={...})"""
    updates = cond_and_update.pop("set")
    def m(r):
        if all(r.get(k) == v for k, v in cond_and_update.items()):
            r.update({k: (v(r) if callable(v) else v) for k, v in updates.items()})
    return m


def scale(key: str, factor: float):
    return lambda r: f"{float(r[key]) * factor:.1f}"


def bounds_without(fixture: str, name: str | None = None) -> str:
    """A copy of the frozen Scripts/perf-bounds.json without `fixture`: the
    state before that fixture's bound was merged (a bound is never replaced,
    so a merge or a no-bound case needs a file that lacks it)."""
    path = os.path.join(work, name or f"perf-bounds-without-{fixture}.json")
    with open(os.path.join(SCRIPTS, "perf-bounds.json")) as src:
        bounds = json.load(src)
    bounds["fixtures"].pop(fixture, None)
    (bounds.get("fixture_sources") or {}).pop(fixture, None)
    with open(path, "w") as dst:
        json.dump(bounds, dst, indent=2, sort_keys=True)
    return path


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
check("pr2 C list-dense launch→READY +30 % with the frozen bounds (13.8 %: gated) -> FAIL",
      summarize(write("pr2-ready-ld-frozen", P2, grid(3, ARMS, PR2, mutate=ready30("list-dense")))), 1, "FAIL",
      contains="bound 13.8 % <= 15 %")
check("pr2 C list-dense launch→READY +30 % -> PASS (no measured bound: advisory)",
      summarize(write("pr2-ready-ld", P2, grid(3, ARMS, PR2, mutate=ready30("list-dense"))), "--bounds",
                bounds_without("list-dense")), 0, "PASS", contains="no measured bound")
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
base_copy = bounds_without("list-dense", "perf-bounds-copy.json")
base_before = json.load(open(base_copy))
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

# ------------------------------------------------------------- design pr3
# Code-block stage (plan §7, Astra findings 2, 5): pr2 + code-dense under one
# named design, the code-native proof, PR 2's failing rows annotated as known
# debt (and still failing), and the paired D vs C predecessor supplement.
P3 = plan("pr3", 3, ARMS)
on_cd = lambda arm, **kv: mut(arm=arm, fixture="code-dense", set=kv)  # noqa: E731
check("pr3 clean -> PASS (code shares disclosed, supplement NO-ADDED-REGRESSION, debt rows improved)",
      summarize(write("pr3-pass", P3, grid(3, ARMS, PR3))), 0, "PASS", contains="gated_code_share_pct")
pass3 = json.load(open(os.path.join(work, "pr3-pass", "trials.csv.json")))
check_that("pr3 clean: supplement COMPLETE, every D/C row NO-ADDED-REGRESSION, every debt row improved",
           pass3["predecessor"]["status"] == "COMPLETE"
           and all(r["result"] == "NO-ADDED-REGRESSION" for fx in pass3["predecessor"]["fixtures"].values()
                   for r in fx["rows"].values())
           and sorted(pass3["predecessor"]["fixtures"]) == sorted(PRED)
           and [e["status"] for e in pass3["known_debt"]["entries"]] == ["improved"] * 4
           and pass3["known_debt"]["failing_rows"] == 0)
md3 = open(os.path.join(work, "pr3-pass", "summary.md")).read()
check_that("pr3 clean: the report has per-fixture B and C tables, the code line, both extra sections and one "
           "OVERALL line",
           md3.count("**C (C) vs A**") == 5 and md3.count("**B (B) vs A**") == 5
           and "Measured at this run's configuration: admitted 541, gated to SwiftUI at view time 11 (2.0 %" in md3
           and "Code blocks (top-level, static potential): eligible 552, SwiftUI fallback 48 (8.0 %" in md3
           and "Work counters (diagnostics, not gated; since launch at the end of the trial): layouts " in md3
           and "## Known debt (annotation only)" in md3 and "## Paired predecessor supplement, D vs C — COMPLETE" in md3
           and md3.count("**OVERALL: PASS**") == 1
           and md3.rstrip().splitlines()[-1] == "**OVERALL: PASS** (D/C supplement: NO-ADDED-REGRESSION (every "
                                                "fixture and metric))"
           and pass3.get("predecessor_outcome", "") == "D/C supplement: NO-ADDED-REGRESSION (every fixture and metric)")
check("pr2 with PR 2-era rows (no code columns) -> PASS (pr2 unchanged)",
      summarize(write("pr2-pr2rows", P2, grid(3, ARMS, PR2, mutate=lambda r: r.update(
          {k: "" for k in CODE_KEYS + ("tk2_conversions",)})))), 0, "PASS", lacks='"known_debt": {')

# Omission of code-dense.
check("pr3 plan without code-dense -> INCOMPLETE",
      summarize(write("pr3-nocode", plan("pr3", 3, ARMS, fixtures=PR2), grid(3, ARMS, PR2))), 5, "INCOMPLETE",
      contains="['code-dense'] declared by design pr3 are missing")
check("pr3 plan without code-dense on arm B -> INCOMPLETE",
      summarize(write("pr3-nocodeB", plan("pr3", 3, ARMS, fixture_arms={**{f: ARMS for f in PR2},
                                                                         "code-dense": ["A", "C"]}),
                      [r for r in grid(3, ARMS, PR3) if not (r["fixture"] == "code-dense" and r["arm"] == "B")])),
      5, "INCOMPLETE", contains="code-dense: arms ['B'] missing")
check("pr3 declares code-dense but its trials are absent -> INVALID",
      summarize(write("pr3-norows", P3, grid(3, ARMS, PR2))), 2, "INVALID", contains="missing trial")
check("pr2 plan carrying code-dense -> INVALID (not part of design pr2)",
      summarize(write("pr2-extra-code", plan("pr2", 3, ARMS, fixtures=PR3), grid(3, ARMS, PR3))), 2, "INVALID",
      contains="['code-dense'] are not part of design pr2")

# Missing code-native proof / all-fallback code (C), and B must show none.
check("pr3 C on code-dense without tk2CodeLive -> INVALID (code-native proof missing)",
      summarize(write("pr3-c-nocodefield", P3, grid(3, ARMS, PR3, mutate=on_cd("C", tk2_code_live="",
                                                                               tk2_code_live_ready="")))),
      2, "INVALID", contains="code-native proof missing")
check("pr3 C on code-dense with no code key at all (a PR 2 build as the candidate) -> INVALID",
      summarize(write("pr3-c-nocodekeys", P3, grid(3, ARMS, PR3, mutate=on_cd("C", **{k: "" for k in CODE_KEYS})))),
      2, "INVALID", contains="code-native proof missing")
check("pr3 C on code-dense with tk2CodeLive=0 at READY and end -> INVALID (prose/list draws are no proof)",
      summarize(write("pr3-c-codezero", P3, grid(3, ARMS, PR3, mutate=on_cd("C", tk2_code_live="0",
                                                                            tk2_code_live_ready="0")))),
      2, "INVALID", contains="no live TextKit 2 code rows")
check("pr3 C on code-dense with tk2CodeLive only at READY -> PASS",
      summarize(write("pr3-c-codeready", P3, grid(3, ARMS, PR3, mutate=on_cd("C", tk2_code_live="0")))), 0, "PASS")
check("pr3 C on code-dense with tk2CodeDraws=0 -> INVALID (live rows that never drew natively)",
      summarize(write("pr3-c-nodraws", P3, grid(3, ARMS, PR3, mutate=on_cd("C", tk2_code_draws="0")))), 2, "INVALID",
      contains="need > 0: TextKit 2 drew code glyphs natively")
check("pr3 C on code-dense without tk2CodeDraws -> INVALID",
      summarize(write("pr3-c-nodrawsfield", P3, grid(3, ARMS, PR3, mutate=on_cd("C", tk2_code_draws="")))), 2,
      "INVALID", contains="reports no tk2_code_draws")
check("pr3 C on code-dense, no code root eligible (static) -> INVALID (all-fallback code)",
      summarize(write("pr3-c-allfallback", P3, grid(3, ARMS, PR3, mutate=on_cd(
          "C", eligible_code_roots="0", fallback_code_roots="600", code_admitted="0", code_gated="0")))),
      2, "INVALID", contains="all code roots fall back to SwiftUI: eligible_code_roots 0 of 600")
check("pr3 C on code-dense, every eligible code root gated at the run's environment -> INVALID",
      summarize(write("pr3-c-allgated", P3, grid(3, ARMS, PR3, mutate=on_cd("C", code_admitted="0",
                                                                            code_gated="552")))),
      2, "INVALID", contains="all code roots fall back to SwiftUI at the run's environment")
check("pr3 C on code-dense, admitted + gated != eligible code roots -> INVALID (measured share not trustworthy)",
      summarize(write("pr3-c-codesum", P3, grid(3, ARMS, PR3, mutate=on_cd("C", code_admitted="500")))), 2, "INVALID",
      contains="code coverage inconsistent")
check("pr3 C on code-dense with zero code roots -> INVALID",
      summarize(write("pr3-c-nocoderoots", P3, grid(3, ARMS, PR3, mutate=on_cd(
          "C", eligible_code_roots="0", fallback_code_roots="0", code_admitted="0", code_gated="0")))),
      2, "INVALID", contains="no top-level code blocks in scope")
check("pr3 C on code-dense without code coverage -> INVALID",
      summarize(write("pr3-c-nocodecoverage", P3, grid(3, ARMS, PR3, mutate=on_cd("C", code_admitted="",
                                                                                  eligible_code_roots="")))),
      2, "INVALID", contains="code coverage missing")
check("pr3 B on code-dense with live TextKit 2 code rows -> INVALID",
      summarize(write("pr3-b-codelive", P3, grid(3, ARMS, PR3, mutate=on_cd("B", tk2_code_live="2")))), 2, "INVALID",
      contains="SwiftUI arm with nonzero/missing")
check("pr3 B on code-dense with native code draws -> INVALID",
      summarize(write("pr3-b-codedraws", P3, grid(3, ARMS, PR3, mutate=on_cd("B", tk2_code_draws="7")))), 2,
      "INVALID", contains="tk2_code_draws")
check("pr3 B on code-dense without the code counters -> INVALID",
      summarize(write("pr3-b-nocodefield", P3, grid(3, ARMS, PR3, mutate=on_cd(
          "B", tk2_code_live="", tk2_code_live_ready="", tk2_code_draws="")))), 2, "INVALID",
      contains="tk2_code_live")
check("pr3 B on stress-1k reporting a live code row -> INVALID (zero wherever reported)",
      summarize(write("pr3-b-1k-codelive", P3, grid(3, ARMS, PR3, mutate=mut(arm="B", fixture="stress-1k",
                                                                             set={"tk2_code_live_ready": "1"})))),
      2, "INVALID")
check("pr3 C on stress-1k with tk2CodeLive=0 -> PASS (the code proof is code-dense's)",
      summarize(write("pr3-c-1k-codezero", P3, grid(3, ARMS, PR3, mutate=mut(arm="C", fixture="stress-1k", set={
          "tk2_code_live": "0", "tk2_code_live_ready": "0", "tk2_code_draws": "0"})))), 0, "PASS")
check("pr3 C on list-dense without live list rows -> INVALID (the list proof stays on)",
      summarize(write("pr3-c-listzero", P3, grid(3, ARMS, PR3, mutate=on_ld("C", tk2_list_live="0",
                                                                            tk2_list_live_ready="0")))),
      2, "INVALID", contains="no live TextKit 2 list rows")
check("pilot of code-dense under the default design -> code proof still required (INVALID)",
      summarize(write("pr45-pilot-cd-codezero", plan("pr45", 2, ARMS, fixtures=["code-dense"], pilot=True, warmup=0),
                      grid(2, ARMS, ["code-dense"], mutate=on_cd("C", tk2_code_live="0", tk2_code_live_ready="0"))),
                "--pilot"), 2, "INVALID", contains="no live TextKit 2 code rows")
check("pilot of code-dense alone under pr3 -> PILOT (never PASS)",
      summarize(write("pr3-pilot-cd", plan("pr3", 2, ARMS, fixtures=["code-dense"], pilot=True, warmup=0, pred=False),
                      grid(2, ARMS, ["code-dense"])), "--pilot"), 4, "PILOT")

# Truncated traversal, block counts, fixture bytes: as pr2.
check("pr3 C code-dense scroll ends before the last block -> FAIL",
      summarize(write("pr3-c-short", P3, grid(3, ARMS, PR3, mutate=mut(arm="C", run="2", fixture="code-dense",
                                                                       set={"end_row": "500"})))), 1, "FAIL",
      contains="scroll ended at row 500, not the last block 599")
check("pr3 A code-dense scroll ends before the last block -> INVALID",
      summarize(write("pr3-a-short", P3, grid(3, ARMS, PR3, mutate=mut(arm="A", run="2", fixture="code-dense",
                                                                       set={"end_row": "500"})))), 2, "INVALID",
      contains="baseline_failure")
check("pr3 code-dense READY blocks 601 on B/C vs 600 on A -> INVALID",
      summarize(write("pr3-blocks", P3, grid(3, ARMS, PR3, mutate=lambda r: r.update(blocks="601", end_row="600")
                                             if r["fixture"] == "code-dense" and r["arm"] in "BC" else None))),
      2, "INVALID", contains="READY block counts disagree")
P3hash = copy.deepcopy(P3)
P3hash["arms"]["A"]["fixture_sha256"]["code-dense"] = "d" * 64
check("pr3 code-dense.json differs across arms -> INVALID",
      summarize(write("pr3-hash", P3hash, grid(3, ARMS, PR3, mutate=on_cd("A", installed_fixture_sha256="d" * 64)))),
      2, "INVALID", contains="code-dense.json differs across arms")
check("pr3 plan without fixture hashes -> INVALID",
      summarize(write("pr3-nohash", plan("pr3", 3, ARMS, fixture_hashes=False), grid(3, ARMS, PR3))), 2, "INVALID",
      contains="plan records no sha256 of code-dense.json")
check("pr3 installed code-dense.json differs from the plan on one trial -> INVALID",
      summarize(write("pr3-installed-hash", P3, grid(3, ARMS, PR3, mutate=mut(arm="B", run="1", fixture="code-dense",
                                                                              set={"installed_fixture_sha256": "f" * 64})))),
      2, "INVALID", contains="installed code-dense.json sha256")

# Same thresholds as pr2 on the new fixture; code-dense READY is advisory
# until its bound is merged.
check("pr3 C code-dense footprint at READY +20 % -> FAIL",
      summarize(write("pr3-fp20", P3, grid(3, ARMS, PR3, mutate=on_cd(
          "C", footprint_ready_kb=scale("footprint_ready_kb", 1.2))))), 1, "FAIL")
check("pr3 B code-dense dropped rate 1.2 % -> FAIL",
      summarize(write("pr3-brate", P3, grid(3, ARMS, PR3, mutate=mut(arm="B", run="1", fixture="code-dense",
                                                                     set={"dropped_frames": "94"})))), 1, "FAIL")
check("pr3 C code-dense launch→READY +30 % -> PASS (no measured bound: advisory)",
      summarize(write("pr3-ready-cd", P3, grid(3, ARMS, PR3, mutate=ready30("code-dense"))), "--bounds",
                bounds_without("code-dense")), 0, "PASS", contains="no measured bound")

# KNOWN DEBT (Astra finding 2): the four rows of PR 2's final summary, as the
# gate measures them (list-dense C: dropped Δ > 2, hitch > 10 ms/s, dropped
# rate > 1 % in every trial; kitchen-sink C: hitch > 10 ms/s).


def debt(r, c_dropped="86"):
    if r["fixture"] == "list-dense":
        c = r["arm"] == "C"
        r.update(dropped_frames=c_dropped if c else "44", hitch_ms_per_s="10.9" if c else "6.4")
    if r["fixture"] == "kitchen-sink" and r["arm"] == "C":
        r.update(dropped_frames="2", hitch_ms_per_s="11.98")


def both(*mutators):
    return lambda r: [m(r) for m in mutators] and None


debt_run = summarize(write("pr3-debt", P3, grid(3, ARMS, PR3, mutate=debt)))
check("pr3 with exactly PR 2's failing rows -> FAIL (labelled known debt, still failing, no second verdict)",
      debt_run, 1, "FAIL", contains='"status": "known-debt-fail"', lacks="excluding")
dk = debt_run[1].get("known_debt") or {}
check_that("pr3 debt run: 4 failing rows, all 4 labelled, none unlabelled, labels on the rows and breaches",
           dk.get("failing_rows") == 4 and dk.get("annotated_rows") == 4 and dk.get("not_annotated") == []
           and [e["status"] for e in dk.get("entries", [])] == ["known-debt-fail"] * 4
           and debt_run[1]["fixtures"]["list-dense"]["comparisons"]["C"]["dropped_frames"]["verdict"] == "FAIL"
           and debt_run[1]["fixtures"]["list-dense"]["comparisons"]["C"]["dropped_frames"]["known_debt"]["status"]
           == "known-debt-fail"
           and all(b.get("known_debt") for b in debt_run[1]["fixtures"]["list-dense"]["ceiling_breaches"])
           and len(debt_run[1]["fixtures"]["list-dense"]["ceiling_breaches"]) == 6)
mdd = open(os.path.join(work, "pr3-debt", "summary.md")).read()
check_that("pr3 debt run: the report labels the rows, keeps one unqualified verdict and cites the source",
           mdd.startswith("# perf gate (pr3:") and "— **FAIL**" in mdd.splitlines()[0]
           and mdd.count("OVERALL") == 1
           and mdd.rstrip().splitlines()[-1].startswith("**OVERALL: FAIL** (D/C supplement: ")
           and "**FAIL** (known debt) |" in mdd and "— known debt (still a failure)" in mdd
           and "pr2-a76736f-quiet2" in mdd and "issues/10" in mdd
           and "labelled as known debt: 4; not labelled: 0." in mdd and "excluding" not in mdd)
check("pr3 debt rows on a busy host -> FAIL-HOST-BUSY (precedence unchanged)",
      summarize(write("pr3-debt-busy", plan("pr3", 3, ARMS, host_start={**HOST, "load1": 6.5}),
                      grid(3, ARMS, PR3, mutate=debt))), 6, "FAIL-HOST-BUSY")
check("pr3 a listed metric worsens (list-dense C dropped Δ +96) while every unlisted row passes -> still FAIL",
      summarize(write("pr3-debt-worse", P3, grid(3, ARMS, PR3, mutate=lambda r: debt(r, "140")))), 1, "FAIL",
      contains='"not_annotated": []')
unlisted = summarize(write("pr3-debt-unlisted", P3, grid(3, ARMS, PR3, mutate=both(
    debt, on_cd("C", footprint_ready_kb=scale("footprint_ready_kb", 1.2))))))
check("pr3 a non-listed row fails (code-dense C memory) beside the listed rows -> FAIL, reported unlabelled",
      unlisted, 1, "FAIL",
      contains='"fixture": "code-dense", "metric": "footprint_ready_kb", "rule": "median-relative"')
check_that("pr3 non-listed failure: 5 failing rows, 4 labelled, the code-dense row is not",
           (unlisted[1].get("known_debt") or {}).get("failing_rows") == 5
           and (unlisted[1].get("known_debt") or {}).get("annotated_rows") == 4
           and "known_debt" not in unlisted[1]["fixtures"]["code-dense"]["comparisons"]["C"]["footprint_ready_kb"])
check("pr3 a non-listed row fails alone (stress-1k C dropped Δ +3) -> FAIL, nothing labelled",
      summarize(write("pr3-unlisted-only", P3, grid(3, ARMS, PR3, mutate=lambda r: r.update(
          dropped_frames="3" if r["arm"] == "C" else "0") if r["fixture"] == "stress-1k" else None))), 1, "FAIL",
      contains='"annotated_rows": 0')
check("pr3 list-dense arm B fails the listed metric -> FAIL, not labelled (only arm C carries debt)",
      summarize(write("pr3-debt-armB", P3, grid(3, ARMS, PR3, mutate=mut(arm="B", fixture="list-dense",
                                                                         set={"dropped_frames": "9"})))), 1, "FAIL",
      contains='"arm": "B", "fixture": "list-dense", "metric": "dropped_frames", "rule": "median-relative"')
check("pr3 a listed ceiling fails on code-dense (C hitch 12 ms/s) -> FAIL, not labelled (new work never is)",
      summarize(write("pr3-cd-hitch", P3, grid(3, ARMS, PR3, mutate=on_cd("C", hitch_ms_per_s="12")))), 1, "FAIL",
      contains='"arm": "C", "fixture": "code-dense", "metric": "hitch_ms_per_s", "rule": "ceiling"')

# The label never covers a crash, a timeout, a missing trial, a baseline
# failure, a missing proof or invalid provenance: it is withheld in that cell.
ld_c = lambda run, **kv: mut(arm="C", run=run, fixture="list-dense", set=kv)  # noqa: E731
for case, mutator, drop, code, verdict in (
        ("a crash", ld_c("2", status="crashed", launch_exit="1", frames=""), None, 1, "FAIL"),
        ("a timeout", ld_c("2", status="timeout", launch_exit="143", frames=""), None, 1, "FAIL"),
        ("a missing trial", None, ("list-dense", "C", "3"), 2, "INVALID"),
        ("a baseline failure", mut(arm="A", run="1", fixture="list-dense",
                                   set={"status": "timeout", "launch_exit": "143", "frames": ""}), None, 2, "INVALID"),
        ("a missing list proof", ld_c("1", tk2_list_live="", tk2_list_live_ready=""), None, 2, "INVALID"),
        ("invalid provenance", ld_c("3", installed_sha256="c" * 64), None, 2, "INVALID")):
    rows = grid(3, ARMS, PR3, mutate=both(debt, mutator) if mutator else debt)
    if drop:
        rows = [r for r in rows if (r["fixture"], r["arm"], r["run"]) != drop]
    got = summarize(write("pr3-debt-" + case.replace(" ", "-"), P3, rows))
    statuses = {(e["fixture"], e["metric"], e["rule"]): e["status"]
                for e in (got[1].get("known_debt") or {}).get("entries", [])}
    check(f"pr3 debt rows with {case} on list-dense -> {verdict}", got, code, verdict)
    check_that(f"pr3 debt rows with {case}: the list-dense labels are withheld, kitchen-sink's stays",
               [v for k, v in statuses.items() if k[0] == "list-dense"] == ["withheld"] * 3
               and statuses.get(("kitchen-sink", "hitch_ms_per_s", "ceiling")) == "known-debt-fail"
               and not any(b.get("known_debt") for b in got[1]["fixtures"]["list-dense"]["ceiling_breaches"]),
               str(statuses))

# The ledger sees the debt FAIL as a FAIL: no rerun to green.
ledger9 = os.path.join(work, "ledger-pr3.jsonl")
if os.path.exists(ledger9):
    os.remove(ledger9)
check("ledger pr3: a FAIL made only of known-debt rows", summarize(write("led3-1", P3, grid(3, ARMS, PR3, mutate=debt)),
                                                                ledger=ledger9), 1, "FAIL")
check("ledger pr3: the same candidate again -> REFUSED (an annotation is no allowance)",
      summarize(write("led3-2", P3, grid(3, ARMS, PR3)), ledger=ledger9), 2, "REFUSED")
ledger10 = os.path.join(work, "ledger-pr2-pr3.jsonl")
if os.path.exists(ledger10):
    os.remove(ledger10)
check("ledger: pr2 FAILs for these binaries", summarize(write("led23-1", P2, grid(3, ARMS, PR2, mutate=fp30_ld)),
                                                        ledger=ledger10), 1, "FAIL")
check("ledger: ... then pr3 on the same binaries -> REFUSED (pr3 includes pr2 by name)",
      summarize(write("led23-2", P3, grid(3, ARMS, PR3)), ledger=ledger10), 2, "REFUSED",
      contains="which design pr3 includes")
ledger11 = os.path.join(work, "ledger-pr45-pr3.jsonl")
if os.path.exists(ledger11):
    os.remove(ledger11)
check("ledger: pr45 FAILs for these binaries", summarize(write("led453-1", P, grid(3, ARMS, PR45, mutate=fp30)),
                                                         ledger=ledger11), 1, "FAIL")
check("ledger: ... then pr3 on the same binaries -> REFUSED (pr3 includes pr45 by name)",
      summarize(write("led453-2", P3, grid(3, ARMS, PR3)), ledger=ledger11), 2, "REFUSED",
      contains="which design pr3 includes")

# A refused known_debt entry: --print-design exits 2 (perf-gate.sh stops
# before any trial) and a summary of such a design is INVALID.
SRC = "test source; https://github.com/bharath2020/connie-adf/issues/10"
p3_rows_csv = write("pr3-refused-debt", P3, grid(3, ARMS, PR3, mutate=debt))
for case, entry, needle in (
        ("code-dense", {"fixture": "code-dense", "arm": "C", "metric": "hitch_ms_per_s", "rule": "ceiling"},
         "not a fixture of an included earlier design"),
        ("arm B", {"fixture": "list-dense", "arm": "B", "metric": "dropped_frames", "rule": "median-relative"},
         "only arm C"),
        ("arm A", {"fixture": "list-dense", "arm": "A", "metric": "hitch_ms_per_s", "rule": "ceiling"}, "only arm C"),
        ("an unknown metric", {"fixture": "list-dense", "arm": "C", "metric": "tk2_layouts", "rule": "ceiling"},
         "computes no"),
        ("an unknown rule", {"fixture": "list-dense", "arm": "C", "metric": "dropped_frames", "rule": "noise-allowance"},
         "computes no"),
        ("a rule of another design", {"fixture": "list-dense", "arm": "C", "metric": "dropped_frames",
                                      "rule": "calibrated-ucb"}, "computes no"),
        ("a metric its rule does not gate", {"fixture": "list-dense", "arm": "C", "metric": "hitch_ms_per_s",
                                             "rule": "median-relative"}, "computes no"),
        ("a fixture outside the included designs", {"fixture": "stress-5k", "arm": "C", "metric": "hitch_ms_per_s",
                                                    "rule": "ceiling"}, "not a fixture of an included earlier design"),
        ("no source", {"fixture": "list-dense", "arm": "C", "metric": "hitch_ms_per_s", "rule": "ceiling",
                       "source": ""}, "each non-empty")):
    with pr3_design(lambda d, entry=entry: d["known_debt"].append({"source": SRC, **entry})):
        errors = ps.known_debt_errors("pr3")
        code, err = print_design_here("pr3")
        got = summarize_here(p3_rows_csv)
    check_that(f"known_debt entry naming {case} -> refused (--print-design exit 2)",
               code == 2 and len(errors) >= 1 and needle in errors[0] and needle in err, f"exit {code} {errors[:1]}")
    check(f"known_debt entry naming {case} -> the summary is INVALID and nothing is labelled", got, 2, "INVALID",
          contains="design refused", lacks='"status": "known-debt-fail"')
check_that("the shipped pr3 design is not refused", ps.design_errors("pr3") == [] and print_design_here("pr3")[0] == 0)
with pr3_design(lambda d: d["known_debt"].append(dict(d["known_debt"][0]))):
    check_that("a duplicated known_debt entry -> refused", any("duplicate" in e for e in ps.known_debt_errors("pr3")))

# PREDECESSOR (Astra finding 2): the paired D vs C supplement. Its results
# never change the verdict; a missing or invalid supplement reduces the design.


def pred_delta(deltas, d_dropped=70):
    """On list-dense, D drops d_dropped frames and C d_dropped + deltas[pair];
    the hitch ratio follows the dropped count as the app measures it (one
    frame interval per dropped frame: 1000 / frames ms/s each)."""
    def m(r):
        if r["fixture"] == "list-dense":
            dropped = d_dropped + (deltas[int(r["run"]) - 1] if r["arm"] == "C" else 0)
            r.update(dropped_frames=str(dropped), hitch_ms_per_s=f"{dropped * 1000 / float(r['frames']):.4f}")
    return m


def pred_case(name, p=None, pred_rows=None, warm_rows=None, rows=None, extra=()):
    return summarize(write(name, p or P3, rows if rows is not None else grid(3, ARMS, PR3), pred_rows=pred_rows,
                           warm_rows=warm_rows), *extra)


def pred_results(got, fixture="list-dense"):
    fx = ((got[1].get("predecessor") or {}).get("fixtures") or {}).get(fixture) or {}
    return {m: r["result"] for m, r in (fx.get("rows") or {}).items()}


got = pred_case("pr3-pred-same", pred_rows=pred_grid(mutate=pred_delta([0, 1, -1, 1, 0])))
check("pr3 D/C on list-dense, C − D = 0, +1, −1, +1, 0 frames -> PASS; NO-ADDED-REGRESSION", got, 0, "PASS")
ld_rows = got[1]["predecessor"]["fixtures"]["list-dense"]["rows"]
check_that("pr3 D/C within +1 frame: all three rows NO-ADDED-REGRESSION, bounds = min and max of 5 pairs, the "
           "rate and hitch sensitivities are +2 frames in their own units (D's median frame count)",
           set(pred_results(got).values()) == {"NO-ADDED-REGRESSION"}
           and (ld_rows["dropped_frames"]["lower"], ld_rows["dropped_frames"]["upper"]) == (-1, 1)
           and ld_rows["dropped_frames"]["rank"] == 5 and ld_rows["dropped_frames"]["sensitivity"] == 2.0
           and abs(ld_rows["dropped_rate_pct"]["sensitivity"] - 200.0 / 8400) < 1e-4
           and abs(ld_rows["hitch_ms_per_s"]["sensitivity"] - 2000.0 / 8400) < 1e-3
           and ld_rows["dropped_frames"]["over_ceiling"] == {"D": 0, "C": 0}, str(pred_results(got)))
got = pred_case("pr3-pred-at-limit", pred_rows=pred_grid(mutate=pred_delta([0, 1, -1, 2, 0])))
check_that("pr3 D/C upper bound exactly +2 frames -> NO-ADDED-REGRESSION on dropped frames (the limit is inclusive, "
           "as the gate's own median Δ > 2 rule)",
           got[0] == 0 and pred_results(got)["dropped_frames"] == "NO-ADDED-REGRESSION"
           and got[1]["predecessor"]["fixtures"]["list-dense"]["rows"]["dropped_frames"]["upper"] == 2,
           str(pred_results(got)))
got = pred_case("pr3-pred-over-limit", pred_rows=pred_grid(mutate=pred_delta([3, 4, 3, 5, 3])))
check_that("pr3 D/C every pair +3 frames or more -> ADDED-REGRESSION (lower bound 3 > 2)",
           got[0] == 0 and set(pred_results(got).values()) == {"ADDED-REGRESSION"}
           and got[1]["predecessor"]["fixtures"]["list-dense"]["rows"]["dropped_frames"]["lower"] == 3,
           str(pred_results(got)))
got = pred_case("pr3-pred-added", pred_rows=pred_grid(mutate=pred_delta([10, 9, 12, 10, 11])))
check("pr3 D/C on list-dense, C drops 9–12 more frames than D -> the A/B/C verdict is still PASS", got, 0, "PASS")
check_that("pr3 D/C +9..+12 frames: ADDED-REGRESSION on dropped frames, dropped rate and hitch; kitchen-sink not",
           set(pred_results(got).values()) == {"ADDED-REGRESSION"}
           and set(pred_results(got, "kitchen-sink").values()) == {"NO-ADDED-REGRESSION"}
           and got[1]["predecessor"]["status"] == "COMPLETE", str(pred_results(got)))
mda = open(os.path.join(work, "pr3-pred-added", "summary.md")).read()
check_that("pr3 D/C ADDED-REGRESSION: reported in its own labelled section; the verdict stays PASS (exit 0) and the "
           "OVERALL line names the added regression (Fable review R4)",
           "| **ADDED-REGRESSION** |" in mda and "Separate from the A/B/C verdict: its results never change it" in mda
           and mda.rstrip().splitlines()[-1] == "**OVERALL: PASS** (D/C supplement: ADDED-REGRESSION list-dense "
                                                "(dropped_frames, dropped_rate_pct, hitch_ms_per_s))"
           and got[1].get("predecessor_outcome", "") == "D/C supplement: ADDED-REGRESSION list-dense (dropped_frames, "
                                                "dropped_rate_pct, hitch_ms_per_s)"
           and "Structural diagnostics" in mda)
got = pred_case("pr3-pred-straddle", pred_rows=pred_grid(mutate=pred_delta([-3, 0, 1, 4, 6])))
check("pr3 D/C on list-dense, C − D = −3, 0, +1, +4, +6 frames -> PASS; INCONCLUSIVE (never 'unchanged')", got, 0,
      "PASS", contains="the bounds straddle the sensitivity", lacks="unchanged")
check_that("pr3 D/C straddling +2 frames: INCONCLUSIVE although the median difference (+1) is under +2",
           pred_results(got)["dropped_frames"] == "INCONCLUSIVE"
           and got[1]["predecessor"]["fixtures"]["list-dense"]["rows"]["dropped_frames"]["median_delta"] == 1,
           str(pred_results(got)))
check_that("pr3 D/C INCONCLUSIVE: the verdict stays PASS and the OVERALL line names the unresolved rows (Fable R4)",
           got[1].get("predecessor_outcome", "").startswith("D/C supplement: INCONCLUSIVE list-dense (dropped_frames")
           and "kitchen-sink" not in got[1].get("predecessor_outcome", "")
           and open(os.path.join(work, "pr3-pred-straddle", "summary.md")).read().rstrip().splitlines()[-1]
           == f"**OVERALL: PASS** ({got[1].get('predecessor_outcome', '')})", got[1].get("predecessor_outcome", ""))
got = pred_case("pr3-pred-one-outlier", pred_rows=pred_grid(mutate=pred_delta([0, 0, 0, 0, 9])))
check_that("pr3 D/C four pairs at 0 and one at +9 frames -> INCONCLUSIVE (one pair beyond the sensitivity)",
           pred_results(got)["dropped_frames"] == "INCONCLUSIVE", str(pred_results(got)))
got = pred_case("pr3-pred-8pairs", p=plan("pr3", 3, ARMS, pred=pred_block(runs=8)),
                pred_rows=pred_grid(8, mutate=pred_delta([0, 0, 1, 0, 9, 0, -1, 0])))
check_that("pr3 D/C with 8 declared pairs: the bound is the 7th order statistic, so one +9 pair of 8 is resolved",
           pred_results(got)["dropped_frames"] == "NO-ADDED-REGRESSION"
           and got[1]["predecessor"]["fixtures"]["list-dense"]["rows"]["dropped_frames"]["rank"] == 7
           and got[1]["predecessor"]["fixtures"]["list-dense"]["rows"]["dropped_frames"]["upper"] == 1,
           str(pred_results(got)))
got = pred_case("pr3-pred-counters", pred_rows=pred_grid(mutate=both(
    pred_delta([0, 0, 0, 0, 0]), mut(arm="C", set={"tk2_layouts": "9999", "tk2_draws": "7777",
                                                   "tk2_conversions": "5555"}))))
check_that("pr3 D/C with different work counters -> reported as diagnostics, never gated: NO-ADDED-REGRESSION",
           got[0] == 0 and set(pred_results(got).values()) == {"NO-ADDED-REGRESSION"}
           and got[1]["predecessor"]["fixtures"]["list-dense"]["counters"]["C"]["tk2_layouts"]["median"] == 9999
           and got[1]["predecessor"]["fixtures"]["list-dense"]["counters"]["D"]["tk2_conversions"]["median"] == 60)
got = pred_case("pr3-pred-debt", rows=grid(3, ARMS, PR3, mutate=debt),
                pred_rows=pred_grid(mutate=pred_delta([0, 1, 0, -1, 0], d_dropped=86)))
check("pr3 known-debt FAIL with a NO-ADDED-REGRESSION supplement -> still FAIL (no supplement result softens it)",
      got, 1, "FAIL")
check_that("pr3 debt + supplement: D and C both breach the ceilings in every pair, and that is reported",
           pred_results(got)["dropped_frames"] == "NO-ADDED-REGRESSION"
           and got[1]["predecessor"]["fixtures"]["list-dense"]["rows"]["dropped_rate_pct"]["over_ceiling"]
           == {"D": 5, "C": 5})

# Missing reference D, missing pairs or warm-ups: the supplement is enforced.
check("pr3 without the predecessor block (no --app-d) -> INCOMPLETE (missing reference D)",
      pred_case("pr3-pred-missing", p=plan("pr3", 3, ARMS, pred=False)), 5, "INCOMPLETE",
      contains="paired predecessor supplement MISSING")
check_that("  ... and the OVERALL line names the missing supplement",
           open(os.path.join(work, "pr3-pred-missing", "summary.md")).read().rstrip().splitlines()[-1]
           == "**OVERALL: INCOMPLETE** (D/C supplement: MISSING (no result))")
check_that("a design without a supplement (pr2) keeps a bare OVERALL line",
           open(os.path.join(work, "pr2-pr2rows", "summary.md")).read().rstrip().splitlines()[-1]
           == "**OVERALL: PASS**")
check("pr3 debt FAIL without the predecessor block -> FAIL (a missing supplement never softens or hides a FAIL)",
      pred_case("pr3-pred-missing-fail", p=plan("pr3", 3, ARMS, pred=False), rows=grid(3, ARMS, PR3, mutate=debt)),
      1, "FAIL", contains="paired predecessor supplement MISSING")
check("pr3 with the block but no predecessor.csv -> INCOMPLETE (the D/C block did not run)",
      pred_case("pr3-pred-nocsv", pred_rows=False), 5, "INCOMPLETE", contains="no predecessor trials")
check("pr3 with no D rows at all -> INCOMPLETE (missing reference D)",
      pred_case("pr3-pred-nod", pred_rows=[r for r in pred_grid() if r["arm"] != "D"]), 5, "INCOMPLETE",
      contains='"arm": "D", "fixture": "list-dense", "kind": "invalid", "message": "missing trial"')
Pnod = plan("pr3", 3, ARMS)
del Pnod["predecessor"]["arms"]["D"]
check("pr3 block without arm D's sha256 -> INCOMPLETE (no reference D)", pred_case("pr3-pred-nodspec", p=Pnod), 5,
      "INCOMPLETE", contains="no reference D")
check("pr3 one paired run missing (list-dense C pair 4) -> INCOMPLETE; no result for that fixture",
      pred_case("pr3-pred-nopair", pred_rows=[r for r in pred_grid()
                                              if (r["fixture"], r["arm"], r["run"]) != ("list-dense", "C", "4")]),
      5, "INCOMPLETE", contains="paired predecessor supplement INVALID")
got = pred_case("pr3-pred-nopair2", pred_rows=[r for r in pred_grid()
                                               if (r["fixture"], r["arm"], r["run"]) != ("list-dense", "C", "4")])
check_that("pr3 one paired run missing: list-dense has no rows (INVALID), kitchen-sink keeps its result",
           got[1]["predecessor"]["fixtures"]["list-dense"]["status"] == "INVALID"
           and got[1]["predecessor"]["fixtures"]["list-dense"]["rows"] == {}
           and got[1]["predecessor"]["fixtures"]["kitchen-sink"]["status"] == "COMPLETE")
check("pr3 3 D/C pairs declared where the design needs 5 -> INCOMPLETE (missing paired runs)",
      pred_case("pr3-pred-3pairs", p=plan("pr3", 3, ARMS, pred=pred_block(runs=3))), 5, "INCOMPLETE",
      contains="missing paired runs")
check("pr3 D/C warm-up not declared -> INCOMPLETE",
      pred_case("pr3-pred-warm0", p=plan("pr3", 3, ARMS, pred=pred_block(warmup=0))), 5, "INCOMPLETE",
      contains="one discarded warm-up per fixture and arm")
check("pr3 D/C warm-up file missing -> INCOMPLETE", pred_case("pr3-pred-nowarmcsv", warm_rows=False), 5, "INCOMPLETE",
      contains="no predecessor warm-up trials")
check("pr3 D/C warm-up of one arm missing -> INCOMPLETE",
      pred_case("pr3-pred-nowarmD", warm_rows=[r for r in pred_warm() if not (r["arm"] == "D"
                                                                             and r["fixture"] == "list-dense")]),
      5, "INCOMPLETE", contains="warm-up trial missing (0 of 1 ran successfully)")


# A warm-up counts only when it ran successfully (Astra review R3): a row
# with the right fixture and arm is not enough.
def warm_with(m) -> list[dict]:
    rows = pred_warm()
    for r in rows:
        m(r)
    return rows


NO_READY = {"shell_status": "no_ready", "status": "no_ready", "launch_exit": "", "launch_to_ready_ms": "",
            "ready_fixture": "", "first_chunk_ms": "", "blocks": "", "frames": "", "dropped_frames": "",
            "dropped_rate_pct": "", "hitch_ms_per_s": "", "start_row": "", "end_row": "", "scroll_ms": "",
            "completed": "", "renderer": "", "renderer_ready": ""}
for slug, case, arm, change, needle in (
        ("no-ready", "times out before READY", "D", NO_READY, "warm-up not successful: trial status no_ready"),
        ("deadline", "exceeds the trial deadline after READY", "C", {"shell_status": "timeout", "status": "timeout"},
         "warm-up not successful: trial status timeout"),
        ("installed-sha", "installed another executable", "D", {"installed_sha256": "c" * 64},
         "warm-up not successful: installed sha256 " + "c" * 64),
        ("app-sha", "ran another executable", "C", {"app_sha256": "c" * 64, "installed_sha256": "c" * 64},
         "warm-up not successful: app sha256 " + "c" * 64),
        ("fixture-sha", "installed other fixture bytes", "D", {"installed_fixture_sha256": "f" * 64},
         "warm-up not successful: installed list-dense.json sha256"),
        ("short", "stopped short of the last block (truncated traversal)", "D", {"end_row": "500"},
         "warm-up not successful: scroll ended at row 500, not the last block 639"),
        ("incomplete", "did not complete its scroll", "C", {"status": "incomplete", "completed": "0"},
         "warm-up not successful: trial status incomplete"),
        ("swiftui", "ran on SwiftUI (no renderer proof)", "D", {"renderer": "swiftui", "renderer_ready": "swiftui"},
         "warm-up not successful: RENDERER_STATS renderer=swiftui"),
        ("nolist", "has no live list rows (no list proof)", "C", {"tk2_list_live": "0", "tk2_list_live_ready": "0"},
         "warm-up not successful: TextKit 2 arm with tk2_list_live_ready=0")):
    got = pred_case(f"pr3-pred-warm-{slug}",
                    warm_rows=warm_with(mut(arm=arm, fixture="list-dense", set=change)))
    check(f"pr3 D/C warm-up of arm {arm} on list-dense {case} -> INCOMPLETE (it does not count)", got, 5,
          "INCOMPLETE", contains=needle)
    check_that(f"  ... list-dense is INVALID with its warm-up missing, kitchen-sink keeps its result ({case})",
               got[1]["predecessor"]["fixtures"]["list-dense"]["status"] == "INVALID"
               and got[1]["predecessor"]["fixtures"]["kitchen-sink"]["status"] == "COMPLETE"
               and any(p["message"] == "warm-up trial missing (0 of 1 ran successfully)" and p["arm"] == arm
                       for p in got[1]["predecessor"]["problems"]))
check("pr3 a D/C warm-up row of a fixture outside the block -> INCOMPLETE (a malformed warm-up file)",
      pred_case("pr3-pred-warm-undeclared", warm_rows=pred_warm() + [r for r in pred_warm(fixtures=["code-dense"])
                                                                      if r["arm"] == "C"]),
      5, "INCOMPLETE", contains="warm-up row for an undeclared fixture/arm")
check("pr3 a counted row in the warm-up file (run 1) -> INCOMPLETE (a warm-up is run 0)",
      pred_case("pr3-pred-warm-run1", warm_rows=warm_with(mut(arm="D", fixture="kitchen-sink", set={"run": "1"}))),
      5, "INCOMPLETE", contains="warm-up not successful: run 1 (a warm-up is run 0)")
check("pr3 a failed D warm-up beside a successful one (2 rows, 1 declared) -> INCOMPLETE (never outvoted)",
      pred_case("pr3-pred-warm-outvoted", warm_rows=pred_warm() + warm_with(mut(arm="D", fixture="list-dense",
                                                                                set=NO_READY))[:1]),
      5, "INCOMPLETE", contains="warm-up not successful: trial status no_ready")
got = pred_case("pr3-pred-warm-measures", warm_rows=warm_with(mut(arm="C", set={
    "dropped_frames": "4000", "hitch_ms_per_s": "900.0", "frames": "8000"})))
check("pr3 a successful warm-up with wild measurements -> PASS (a warm-up is never measured)", got, 0, "PASS")
check_that("  ... the warm-ups stay out of the statistics: 5 pairs per arm, NO-ADDED-REGRESSION, C's dropped-frame "
           "maximum is a counted trial's",
           got[1]["predecessor"]["status"] == "COMPLETE"
           and set(pred_results(got).values()) == {"NO-ADDED-REGRESSION"}
           and got[1]["predecessor"]["fixtures"]["list-dense"]["arms"]["C"]["dropped_frames"]["n"] == 5
           and got[1]["predecessor"]["fixtures"]["list-dense"]["arms"]["C"]["dropped_frames"]["max"] <= 1)
check("pr3 block without list-dense (kitchen-sink only) -> INCOMPLETE",
      pred_case("pr3-pred-1fx", p=plan("pr3", 3, ARMS, pred=pred_block(fixtures=["kitchen-sink"]))), 5, "INCOMPLETE",
      contains="['list-dense'] declared by design pr3 are missing")
check("pr3 block naming code-dense -> INCOMPLETE (not a predecessor fixture)",
      pred_case("pr3-pred-codefx", p=plan("pr3", 3, ARMS, pred=pred_block(fixtures=PRED + ["code-dense"]))), 5,
      "INCOMPLETE", contains="are not the design's")

# D/C hash mismatches and altered fixtures.
check("pr3 a D trial installed another binary -> INCOMPLETE (D/C hash mismatch)",
      pred_case("pr3-pred-installed", pred_rows=pred_grid(mutate=mut(arm="D", run="2", fixture="list-dense",
                                                                     set={"installed_sha256": "c" * 64}))),
      5, "INCOMPLETE", contains="installed sha256")
Psame = plan("pr3", 3, ARMS)
Psame["predecessor"]["arms"]["D"]["sha256"] = SHA["C"]
check("pr3 D is the candidate's binary -> INCOMPLETE (D = C compares nothing)",
      pred_case("pr3-pred-d-is-c", p=Psame, pred_rows=pred_grid(mutate=mut(arm="D", set={
          "app_sha256": SHA["C"], "installed_sha256": SHA["C"]}))), 5, "INCOMPLETE",
      contains="D and C are the same binary")
Punpinned = plan("pr3", 3, ARMS)
Punpinned["predecessor"]["arms"]["D"]["sha256"] = "e" * 64
check("pr3 D is not the design's pinned predecessor binary -> INCOMPLETE",
      pred_case("pr3-pred-unpinned", p=Punpinned, pred_rows=pred_grid(mutate=mut(arm="D", set={
          "app_sha256": "e" * 64, "installed_sha256": "e" * 64}))), 5, "INCOMPLETE",
      contains="!= the design's pinned predecessor")
Pcsha = plan("pr3", 3, ARMS)
Pcsha["predecessor"]["arms"]["C"]["sha256"] = "9" * 64
check("pr3 the block's C is not the gated candidate -> INCOMPLETE",
      pred_case("pr3-pred-c-other", p=Pcsha), 5, "INCOMPLETE", contains="must measure the gated candidate")
Pdfix = plan("pr3", 3, ARMS)
Pdfix["predecessor"]["arms"]["D"]["fixture_sha256"]["list-dense"] = "d" * 64
check("pr3 D bundles other list-dense.json bytes than C -> INCOMPLETE (altered fixture)",
      pred_case("pr3-pred-altered", p=Pdfix, pred_rows=pred_grid(mutate=mut(arm="D", fixture="list-dense", set={
          "installed_fixture_sha256": "d" * 64}))), 5, "INCOMPLETE", contains="altered fixture")
Pbothfix = plan("pr3", 3, ARMS)
for a in ("D", "C"):
    Pbothfix["predecessor"]["arms"][a]["fixture_sha256"]["kitchen-sink"] = "d" * 64
check("pr3 D and C agree on kitchen-sink.json but not with the gate's arm A -> INCOMPLETE (altered fixture)",
      pred_case("pr3-pred-altered-both", p=Pbothfix, pred_rows=pred_grid(mutate=mut(fixture="kitchen-sink", set={
          "installed_fixture_sha256": "d" * 64}))), 5, "INCOMPLETE", contains="altered fixture")
check("pr3 one D trial installed other fixture bytes -> INCOMPLETE",
      pred_case("pr3-pred-installed-fixture", pred_rows=pred_grid(mutate=mut(arm="D", run="5", fixture="list-dense",
                                                                             set={"installed_fixture_sha256": "f" * 64}))),
      5, "INCOMPLETE", contains="installed list-dense.json sha256")
Pnofix = plan("pr3", 3, ARMS)
Pnofix["predecessor"]["arms"]["D"]["fixture_sha256"] = {}
check("pr3 block without D's fixture hashes -> INCOMPLETE",
      pred_case("pr3-pred-nofixsha", p=Pnofix), 5, "INCOMPLETE",
      contains="records no sha256 of list-dense.json in arm D")

# A borrowed noise allowance, or any other override of the frozen method.
check("pr3 block with a widened sensitivity (18 frames, the A–A′ spread) -> INCOMPLETE (borrowed noise allowance)",
      pred_case("pr3-pred-borrowed", p=plan("pr3", 3, ARMS, pred=pred_block(sensitivity_dropped_frames=18.0)),
                pred_rows=pred_grid(mutate=pred_delta([10, 9, 12, 10, 11]))), 5, "INCOMPLETE",
      contains="a noise allowance is never borrowed")
check("pr3 block with an allowance key -> INCOMPLETE (the method is frozen in the design)",
      pred_case("pr3-pred-allowance", p=plan("pr3", 3, ARMS, pred=pred_block(allowance={"dropped_frames": 18})),
                pred_rows=pred_grid(mutate=pred_delta([10, 9, 12, 10, 11]))), 5, "INCOMPLETE",
      contains="unknown key(s) ['allowance']")
check("pr3 block without the recorded sensitivity -> INCOMPLETE",
      pred_case("pr3-pred-nosens", p=plan("pr3", 3, ARMS, pred={k: v for k, v in pred_block().items()
                                                                if k != "sensitivity_dropped_frames"})), 5,
      "INCOMPLETE", contains="a noise allowance is never borrowed")
for case, change, needle in (
        ("a widened sensitivity", lambda d: d["predecessor"].update(sensitivity_dropped_frames=18.0),
         "a noise allowance is never"),
        ("a noise allowance key", lambda d: d["predecessor"].update(noise_allowance={"dropped_frames": 18}),
         "unknown key(s) ['noise_allowance']"),
        ("3 pairs", lambda d: d["predecessor"].update(runs=3), "needs >= 5 pairs"),
        ("no warm-up", lambda d: d["predecessor"].update(warmup=0), "one discarded warm-up"),
        ("code-dense as a predecessor fixture", lambda d: d["predecessor"].update(fixtures=["code-dense"]),
         "must be fixtures of an included earlier design"),
        ("arm A as the predecessor", lambda d: d["predecessor"].update(arm="A"), "with arm C only"),
        ("D as a gated arm", lambda d: d["fixtures"].update({"list-dense": ["A", "B", "C", "D"]}),
         "D never substitutes for A")):
    with pr3_design(change):
        errors = ps.predecessor_errors("pr3")
        code, err = print_design_here("pr3")
    check_that(f"design predecessor with {case} -> refused (--print-design exit 2)",
               code == 2 and any(needle in e for e in errors) and needle in err, f"exit {code} {errors[:1]}")

# D never substitutes for A.
Pda = plan("pr3", 3, ARMS)
Pda["arms"]["A"]["sha256"] = SHA["D"]
check("pr3 arm A is the pinned predecessor binary -> INVALID (D never substitutes for A)",
      pred_case("pr3-pred-a-is-d", p=Pda, rows=grid(3, ARMS, PR3, mutate=mut(arm="A", set={
          "app_sha256": SHA["D"], "installed_sha256": SHA["D"]}))), 2, "INVALID",
      contains="D never substitutes for A")
Pdarm = plan("pr3", 3, ARMS)
Pdarm["arms"]["D"] = copy.deepcopy(Pdarm["predecessor"]["arms"]["D"])
check("pr3 D listed among the plan's arms -> INVALID (never a gated arm)",
      pred_case("pr3-pred-d-arm", p=Pdarm), 2, "INVALID", contains="is an arm of the A/B/C plan")
check("pr3 D rows inside trials.csv -> INVALID (an undeclared arm is never evidence)",
      pred_case("pr3-pred-d-rows", rows=grid(3, ARMS, PR3) + [r for r in pred_grid(3) if r["arm"] == "D"]), 2,
      "INVALID", contains="row for an undeclared fixture/arm")
check("pr2 plan carrying a predecessor block -> INCOMPLETE (design pr2 declares none)",
      summarize(write("pr2-pred-block", plan("pr2", 3, ARMS, pred=True), grid(3, ARMS, PR2))), 5, "INCOMPLETE",
      contains="declares no predecessor supplement")

# Trial problems inside the block: no result, and the verdict is not theirs.
check("pr3 D's scroll stops short in one pair -> INCOMPLETE (supplement INVALID)",
      pred_case("pr3-pred-d-short", pred_rows=pred_grid(mutate=mut(arm="D", run="3", fixture="list-dense",
                                                                   set={"end_row": "500"}))), 5, "INCOMPLETE",
      contains="scroll ended at row 500")
# The gated binary C failing a counted supplement trial is the gate's own
# candidate failure (Fable review R2): FAIL, and the ledger refuses a rerun
# of the same binaries. D's failures, warm-ups and rows that cannot be
# attributed to C stay the supplement's (INVALID -> INCOMPLETE).
CRASHED = {"status": "crashed", "launch_exit": "1", "frames": ""}
pred_ledger = os.path.join(work, "pred-ledger-case.jsonl")
if os.path.exists(pred_ledger):
    os.remove(pred_ledger)
got = summarize(write("pr3-pred-c-crash", P3, grid(3, ARMS, PR3), pred_rows=pred_grid(
    mutate=mut(arm="C", run="1", fixture="kitchen-sink", set=CRASHED))), ledger=pred_ledger)
check("pr3 C crashes in a supplement trial -> FAIL (a crash of the gated binary, PRECEDENCE 1)",
      got, 1, "FAIL", contains="D/C supplement trial: candidate trial status crashed")
check_that("pr3 C crash in the supplement: a crash among the gate's problems, the supplement INVALID on that fixture "
           "only, and the OVERALL line says so",
           [(p["kind"], p["fixture"], p["arm"], p["run"]) for p in got[1]["problems"]]
           == [("crash", "kitchen-sink", "C", "1")]
           and got[1]["predecessor"]["fixtures"]["kitchen-sink"]["status"] == "INVALID"
           and got[1]["predecessor"]["fixtures"]["list-dense"]["status"] == "COMPLETE"
           and got[1].get("predecessor_outcome", "") == "D/C supplement: INVALID (no result)"
           and open(os.path.join(work, "pr3-pred-c-crash", "summary.md")).read().rstrip().splitlines()[-1]
           == "**OVERALL: FAIL** (D/C supplement: INVALID (no result))")
check("pr3 the same binaries rerun after that FAIL, now clean -> REFUSED (the crash reached the ledger)",
      summarize(write("pr3-pred-c-crash-rerun", P3, grid(3, ARMS, PR3)), ledger=pred_ledger), 2, "REFUSED",
      contains="a FAIL is never rerun to green")
for slug, case, change, needle in (
        ("timeout", "times out", {"shell_status": "timeout", "status": "timeout"}, "candidate trial status timeout"),
        ("no-ready", "gets no READY", {"shell_status": "no_ready", "status": "no_ready", "ready_fixture": "",
                                       "blocks": "", "frames": ""}, "candidate trial status no_ready"),
        ("incomplete", "does not complete its scroll", {"status": "incomplete", "completed": "0"},
         "candidate trial status incomplete"),
        ("short", "stops short of the last block", {"end_row": "500"}, "scroll ended at row 500")):
    got = pred_case(f"pr3-pred-c-{slug}", pred_rows=pred_grid(mutate=mut(arm="C", run="3", fixture="list-dense",
                                                                        set=change)))
    check(f"pr3 C {case} in a supplement pair -> FAIL (a candidate failure of the gate)", got, 1, "FAIL",
          contains="D/C supplement trial: " + needle)
    check_that(f"  ... one candidate_failure among the gate's problems ({case})",
               [(p["kind"], p["fixture"], p["arm"], p["run"]) for p in got[1]["problems"]]
               == [("candidate_failure", "list-dense", "C", "3")])
for slug, case, change, needle in (
        ("crash", "crashes", CRASHED, "baseline trial status crashed"),
        ("timeout", "times out", {"shell_status": "timeout", "status": "timeout"}, "baseline trial status timeout")):
    got = pred_case(f"pr3-pred-d-{slug}", pred_rows=pred_grid(mutate=mut(arm="D", run="2", fixture="list-dense",
                                                                        set=change)))
    check(f"pr3 D {case} in a supplement pair -> INCOMPLETE (the reference's failure stays the supplement's)", got, 5,
          "INCOMPLETE", contains=needle)
    check_that(f"  ... nothing among the gate's problems (D {case})", got[1]["problems"] == [])
got = pred_case("pr3-pred-c-crash-other-binary", pred_rows=pred_grid(mutate=mut(
    arm="C", run="2", fixture="list-dense", set={**CRASHED, "installed_sha256": "c" * 64})))
check("pr3 a supplement C row that crashed with another binary installed -> INCOMPLETE (not attributable to C)",
      got, 5, "INCOMPLETE", contains="installed sha256 " + "c" * 64)
check_that("  ... nothing among the gate's problems (a row we cannot attribute is never evidence)",
           got[1]["problems"] == [])
got = pred_case("pr3-pred-c-warm-crash", warm_rows=warm_with(mut(arm="C", fixture="list-dense", set=CRASHED)))
check("pr3 C crashes in a supplement warm-up -> INCOMPLETE (a warm-up is never counted, as in the gate)", got, 5,
      "INCOMPLETE", contains="warm-up not successful: trial status crashed")
got = pred_case("pr3-pred-c-crash-debt", rows=grid(3, ARMS, PR3, mutate=debt),
                pred_rows=pred_grid(mutate=mut(arm="C", run="4", fixture="list-dense", set=CRASHED)))
check("pr3 known-debt rows and a C crash on list-dense in the supplement -> FAIL", got, 1, "FAIL")
check_that("  ... the crash withholds the list-dense debt labels, as a crash in the gate's own trials does",
           [e["status"] for e in got[1]["known_debt"]["entries"] if e["fixture"] == "list-dense"]
           and all(e["status"] == "withheld" for e in got[1]["known_debt"]["entries"] if e["fixture"] == "list-dense"))
got = summarize(write("pr3-pilot-pred-c-crash", plan("pr3", 2, ARMS, fixtures=["kitchen-sink"], pilot=True, warmup=0,
                                                     pred=pred_block(runs=3, warmup=0, fixtures=["kitchen-sink"])),
                      grid(2, ARMS, ["kitchen-sink"]), warm_rows=False,
                      pred_rows=pred_grid(3, ["kitchen-sink"], mutate=mut(arm="C", run="2", set=CRASHED))), "--pilot")
check("pr3 pilot with a C crash in its supplement -> FAIL (a crash outranks PILOT)", got, 1, "FAIL",
      contains="D/C supplement trial: candidate trial status crashed")
check("pr3 D reports renderer=swiftui (TextKit 2 was not ON) -> INCOMPLETE",
      pred_case("pr3-pred-d-swiftui", pred_rows=pred_grid(mutate=mut(arm="D", set={"renderer": "swiftui",
                                                                                   "renderer_ready": "swiftui"}))),
      5, "INCOMPLETE", contains="need textkit2 on both")
check("pr3 D on list-dense without live list rows -> INCOMPLETE (the list proof holds for D too)",
      pred_case("pr3-pred-d-nolist", pred_rows=pred_grid(mutate=mut(arm="D", fixture="list-dense", set={
          "tk2_list_live": "0", "tk2_list_live_ready": "0"}))), 5, "INCOMPLETE",
      contains="no live TextKit 2 list rows")
check("pr3 every pair run D first -> INCOMPLETE (unbalanced order)",
      pred_case("pr3-pred-unbalanced", pred_rows=pred_grid(first=lambda run: "D")), 5, "INCOMPLETE",
      contains="unbalanced order: D first in 5 pairs, C first in 0")
check("pr3 pairs without their order -> INCOMPLETE (not interleaved)",
      pred_case("pr3-pred-noorder", pred_rows=pred_grid(mutate=lambda r: r.update(order_index=""))), 5, "INCOMPLETE",
      contains="pair not interleaved")
Pdflags = plan("pr3", 3, ARMS)
Pdflags["predecessor"]["arms"]["D"]["required_flags"] = ["-rendererReset", "-rendererStats"]
check("pr3 D declared with the switch-OFF flags -> INCOMPLETE (both must run TextKit 2 ON)",
      pred_case("pr3-pred-d-flags", p=Pdflags), 5, "INCOMPLETE", contains="both must run TextKit 2 ON")
got = pred_case("pr3-pred-busy", pred_rows=pred_grid(mutate=mut(arm="C", run="2", fixture="list-dense",
                                                                set={"host_load1": "6.4"})))
check_that("pr3 a busy host during a supplement trial -> disclosed in the supplement, the gate is not HOST-BUSY",
           got[0] == 0 and got[1]["host_busy"] is False
           and got[1]["predecessor"]["host_busy_reasons"] == ["list-dense C run 2: 1-min load 6.4 > 4"])

# Pilots: any shape; fewer than 5 pairs can never resolve the sensitivity.
got = summarize(write("pr3-pilot-pred", plan("pr3", 2, ARMS, fixtures=["kitchen-sink"], pilot=True, warmup=0,
                                             pred=pred_block(runs=3, warmup=0, fixtures=["kitchen-sink"])),
                      grid(2, ARMS, ["kitchen-sink"]), warm_rows=False), "--pilot")
check("pr3 pilot with 3 D/C pairs on kitchen-sink -> PILOT; INCONCLUSIVE (no bound below 5 pairs)", got, 4, "PILOT",
      contains="no one-sided 95 % bound on the median exists below 5 pairs")
check_that("pr3 pilot supplement: COMPLETE, every row INCONCLUSIVE",
           got[1]["predecessor"]["status"] == "COMPLETE"
           and set(pred_results(got, "kitchen-sink").values()) == {"INCONCLUSIVE"})
check("pr3 pilot without the predecessor block -> PILOT (the reduction is listed)",
      summarize(write("pr3-pilot-nopred", plan("pr3", 2, ARMS, pilot=True, warmup=0, pred=False), grid(2, ARMS, PR3)),
                "--pilot"), 4, "PILOT", contains="paired predecessor supplement MISSING")

# The bounds on the median: exact order statistics.
check_that("median bounds: none below 5 pairs; min/max at 5, 6 and 7; the 2nd extremes at 8",
           ps.PRED_MIN_PAIRS == 5 and ps.median_bounds([1, 2, 3, 4]) is None
           and ps.median_bounds([5, 1, 4, 2, 3])[:3] == (1, 5, 5)
           and abs(ps.median_bounds([5, 1, 4, 2, 3])[3] - 1 / 32) < 1e-12
           and ps.median_bounds([1, 2, 3, 4, 5, 6])[:3] == (1, 6, 6)
           and ps.median_bounds([1, 2, 3, 4, 5, 6, 7])[:3] == (1, 7, 7)
           and ps.median_bounds([1, 2, 3, 4, 5, 6, 7, 8])[:3] == (2, 7, 7)
           and ps.median_bounds([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])[:3] == (2, 9, 9))
check_that("the predecessor sensitivity is the gate's dropped-frame limit, and nothing else",
           ps.PRED_SENSITIVITY_FRAMES == ps.DROPPED_DELTA_MAX == 2.0
           and ps.DESIGNS["pr3"]["predecessor"]["sensitivity_dropped_frames"] == ps.DROPPED_DELTA_MAX)

# --print-design: perf-gate.sh takes the pr3 shape from here; pr2 and pr45
# print the new keys empty.
for name, want in (("pr3", ["fixtures=kitchen-sink stress-1k giant-table list-dense code-dense",
                            "fixture_arms=kitchen-sink=A,B,C stress-1k=A,B,C giant-table=A,B,C list-dense=A,B,C "
                            "code-dense=A,B,C",
                            "arms=A B C", "runs=3", "warmup=1", "rule=median-relative", "list_proof=list-dense",
                            "code_proof=code-dense", "baseline_completion=1", "fixture_hashes=1",
                            "includes=pr45 pr2",
                            "known_debt=kitchen-sink/C/hitch_ms_per_s/ceiling "
                            "list-dense/C/dropped_frames/median-relative list-dense/C/hitch_ms_per_s/ceiling "
                            "list-dense/C/dropped_rate_pct/ceiling",
                            "predecessor_arm=D", "predecessor_fixtures=list-dense kitchen-sink",
                            "predecessor_runs=5", "predecessor_warmup=1",
                            "predecessor_sensitivity_dropped_frames=2.0", "predecessor_app_sha256=" + SHA["D"]]),
                   ("pr2", ["code_proof=", "known_debt=", "predecessor_arm=", "predecessor_fixtures=",
                            "predecessor_runs=", "predecessor_app_sha256=", "includes=pr45"]),
                   ("pr45", ["code_proof=", "known_debt=", "predecessor_fixtures=", "includes="])):
    res = subprocess.run([sys.executable, "-I", SUMMARIZE, "--print-design", name], capture_output=True, text=True)
    lines = res.stdout.splitlines()
    ok = res.returncode == 0 and all(w in lines for w in want)
    results.append(ok)
    print(f"{'ok  ' if ok else 'FAIL'} --print-design {name} (code-block stage keys): exit {res.returncode} "
          f"{[w for w in want if w not in lines] or 'all lines present'}")
check_that("design pr3 = pr2's shape and rule plus code-dense; pr45, pr2 and full are as they were",
           ps.DESIGNS["pr3"]["rule"] == ps.DESIGNS["pr2"]["rule"] and ps.DESIGNS["pr3"]["runs"] == 3
           and ps.DESIGNS["pr3"]["warmup"] == 1 and list(ps.DESIGNS["pr3"]["fixtures"]) == PR3
           and all(v == ["A", "B", "C"] for v in ps.DESIGNS["pr3"]["fixtures"].values())
           and ps.DESIGNS["pr3"]["includes"] == ["pr45", "pr2"]
           and ps.DESIGNS["pr2"] == {"title": "per-PR gate, lists stage (~75–80 min)",
                                     "fixtures": {f: ["A", "B", "C"] for f in PR2}, "runs": 3, "warmup": 1,
                                     "rule": "median-relative", "list_proof": ["list-dense"],
                                     "baseline_completion": True, "fixture_hashes": True, "includes": ["pr45"]}
           and ps.DESIGNS["pr45"] == {"title": "per-PR gate (~45 min)", "fixtures": {f: ["A", "B", "C"] for f in PR45},
                                      "runs": 3, "warmup": 1, "rule": "median-relative"}
           and (ps.REL_LIMIT_PCT, ps.DROPPED_DELTA_MAX, ps.CEILING_HITCH_MS_PER_S, ps.CEILING_DROPPED_RATE_PCT,
                ps.CEILING_DROPPED_SMALL, ps.TRAVERSAL_FRAMES_PCT) == (15.0, 2.0, 10.0, 1.0, 3.0, 15.0))

# RENDERER_STATS parsing (perf_trial.py): the code keys land in their columns,
# the READY line feeds tk2_code_live_ready, tk2Conversions has its own column,
# and a build that prints none (PR 2's tip, arm D) leaves them empty, not 0.
code_log = os.path.join(work, "stats-code.log")
with open(code_log, "w") as fh:
    fh.write("#T0\t1000000000\n"
             "1600000000\tREADY fixture=code-dense blocks=600 firstChunkMs=50\n"
             "1600000001\tRENDERER_STATS renderer=textkit2 tk2Live=6 tk2Layouts=6 tk2Draws=6 tk2NativeDraws=6 "
             "tk1BackedRows=0 tk1BackedDraws=0 eligibleRoots=0 fallbackRoots=600 textFallbackRoots=0 linkRoots=0 "
             "tk2ListLive=0 tk2Conversions=6 eligibleTextLeaves=0 linkedTextLeaves=0 fallbackTextLeaves=0 "
             "listLeaderLeaves=0 listTrailingLeaves=0 tk2CodeLive=6 tk2CodeDraws=6 eligibleCodeRoots=552 "
             "fallbackCodeRoots=48 codeAdmitted=541 codeGated=11\n"
             "9000000000\tSCROLL_METRICS fixture=code-dense frames=7800 dropped=0 hitchRatioMsPerS=0.00 startRow=0 "
             "endRow=599 scrollMs=130000 completed=1\n"
             "9000000001\tRENDERER_STATS renderer=textkit2 tk2Live=4 tk2Layouts=541 tk2Draws=541 tk2NativeDraws=541 "
             "tk1BackedRows=0 tk1BackedDraws=0 eligibleRoots=0 fallbackRoots=600 textFallbackRoots=0 linkRoots=0 "
             "tk2ListLive=0 tk2Conversions=541 eligibleTextLeaves=0 linkedTextLeaves=0 fallbackTextLeaves=0 "
             "listLeaderLeaves=0 listTrailingLeaves=0 tk2CodeLive=4 tk2CodeDraws=540 eligibleCodeRoots=552 "
             "fallbackCodeRoots=48 codeAdmitted=541 codeGated=11 futureKey=7\n"
             "#EXIT\t9500000000\t0\n")
parsed = perf_trial.derive(code_log, "-", {"requires_completion": "1"})
want = {"tk2_code_live_ready": "6", "tk2_code_live": "4", "tk2_code_draws": "540", "eligible_code_roots": "552",
        "fallback_code_roots": "48", "code_admitted": "541", "code_gated": "11", "tk2_conversions": "541",
        "renderer_stats_extra": "futureKey=7", "status": "ok"}
old_code_log = os.path.join(work, "stats-code-old.log")
with open(old_code_log, "w") as fh:
    fh.write("".join(line.split(" tk2CodeLive=")[0] + "\n" for line in open(code_log).read().splitlines()))
old = perf_trial.derive(old_code_log, "-", {"requires_completion": "1"})
check_that("perf_trial parses the code RENDERER_STATS keys; a build without them leaves the columns empty",
           all(parsed.get(k) == v for k, v in want.items())
           and all(old.get(k) == "" for k in CODE_KEYS) and old.get("tk2_conversions") == "541"
           and old.get("status") == "ok" and old.get("renderer_stats_extra") == ""
           and all(k in perf_trial.CSV_COLUMNS for k in CODE_KEYS + ("tk2_conversions",)),
           str({k: parsed.get(k) for k in want}))

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)
