#!/usr/bin/env python3
"""Offline cases for `Scripts/perf_instruments.py summarize`: the verdict and
the host-starved exclusion, driven through the CLI on a synthetic
results.jsonl.

USAGE
    python3 -I Scripts/tests/perf_instruments_tests.py <workdir>

No simulator and no traces. Standard library only. Exits 1 on any mismatch.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ANALYZER = os.path.join(HERE, "..", "perf_instruments.py")

results: list[bool] = []


def expect(label: str, got, want) -> None:
    ok = got == want
    results.append(ok)
    print(f"{'ok  ' if ok else 'FAIL'} {label}" + ("" if ok else f"\n     got  {got!r}\n     want {want!r}"))


def run(arm: str, n: int, window_s: float, cpu: float) -> dict:
    return {"arm": arm, "run": n, "completed": 1, "window_s": window_s,
            "renderer_cpu_ms_s": cpu, "tk_app_ms_s": cpu, "list_tk_app_ms_s": cpu,
            "main_cpu_ms_s": cpu * 2, "burst_ms_s": cpu / 10}


def summarize(workdir: str, name: str, rows: list[dict]) -> tuple[int, dict]:
    d = os.path.join(workdir, name)
    os.makedirs(d, exist_ok=True)
    res = os.path.join(d, "results.jsonl")
    with open(res, "w", encoding="utf-8") as f:
        f.write("\n".join(json.dumps(r) for r in rows) + "\n")
    out = os.path.join(d, "summary.json")
    p = subprocess.run([sys.executable, "-I", ANALYZER, "summarize", "--results", res,
                        "--base", "base", "--cand", "cand", "--json", out],
                       capture_output=True, text=True)
    with open(out, encoding="utf-8") as f:
        return p.returncode, json.load(f)


def main(workdir: str) -> int:
    os.makedirs(workdir, exist_ok=True)

    # A candidate that keeps the main thread busy also slows its own
    # sleep-paced scroll: 59 s base windows vs 94 s candidate windows.
    rc, s = summarize(workdir, "slow-candidate", [
        *(run("base", i, 59.0, 100.0) for i in (1, 2, 3)),
        *(run("cand", i, 94.0, 140.0) for i in (1, 2, 3)),
    ])
    expect("a slow, heavier candidate FAILs (exit 1)", rc, 1)
    expect("a slow, heavier candidate FAILs (overall)", s["overall"], "FAIL")
    expect("no candidate run is excluded as host-starved", s["starved"], [])

    # A single starved base run is still excluded; the rest still compare.
    rc, s = summarize(workdir, "starved-base", [
        *(run("base", i, 59.0, 100.0) for i in (1, 2, 3)),
        run("base", 4, 80.0, 300.0),
        *(run("cand", i, 59.0, 101.0) for i in (1, 2, 3)),
    ])
    expect("a starved base run is excluded", [(r["arm"], r["run"]) for r in s["starved"]],
           [("base", 4)])
    expect("same work after the exclusion PASSes", (rc, s["overall"]), (0, "PASS"))

    # One slow candidate run among normal ones stays in and counts.
    rc, s = summarize(workdir, "one-slow-candidate", [
        *(run("base", i, 59.0, 100.0) for i in (1, 2, 3)),
        run("cand", 1, 59.0, 100.0), run("cand", 2, 90.0, 130.0), run("cand", 3, 92.0, 130.0),
    ])
    expect("slow candidate runs are kept", (s["starved"], s["metrics"]["tk_app_ms_s"]["cand"]),
           ([], [100.0, 130.0, 130.0]))
    expect("the kept slow runs FAIL the median", s["overall"], "FAIL")

    print(f"\n{sum(results)}/{len(results)} passed")
    return 0 if all(results) else 1


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
