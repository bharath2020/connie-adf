#!/usr/bin/env python3
"""Synthetic cases for the TK2 ÷ SwiftUI ratio verdict of
Scripts/perf_probe.py compare.

USAGE
    python3 -I Scripts/tests/perf_probe_tests.py [<workdir>]

Writes base and candidate probe JSONL plus a budgets file per case under
<workdir> (default: a temporary directory), runs `perf_probe.py compare` on
them and checks the exit status, the overall verdict and the ratio row's
verdict in summary.json. Prints one line per case and "<passed>/<total>
passed"; exits 1 on any mismatch. Standard library only.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile

SCRIPTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROBE = os.path.join(SCRIPTS, "perf_probe.py")
FIXTURE = "list-dense"
BUDGET = 1.2


def line(renderer: str, instructions: float) -> str:
    return json.dumps({
        "schema": 1, "tier": "render", "fixture": FIXTURE, "renderer": renderer,
        "fixture_fnv64": "0123456789abcdef", "blocks": 100,
        "counts": {"uiviews": 10, "calayers": 20},
        "counts_unstable": [],
        "instructions": {"median": instructions, "min": instructions, "max": instructions, "cv_pct": 0.1},
        "mallocs": {"main": 1000, "all": 2000},
    })


def write_side(path: str, tk2: float, swiftui: float) -> None:
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("PERF_PROBE " + line("textKit2", tk2) + "\n")
        handle.write("PERF_PROBE " + line("swiftUI", swiftui) + "\n")


# (name, base (tk2, swiftUI), candidate (tk2, swiftUI), exit, overall, ratio verdict)
CASES = [
    ("both within the budget", (1.15e9, 1.0e9), (1.15e9, 1.0e9), 0, "PASS", "PASS"),
    ("candidate over, base within", (1.18e9, 1.0e9), (1.18e9, 0.97e9), 1, "FAIL", "FAIL"),
    ("base also over, candidate at the base ratio", (1.25e9, 1.0e9), (1.25e9, 1.0e9), 0, "WARN", "WARN"),
    ("base also over, candidate slightly above it", (1.25e9, 1.0e9), (1.255e9, 1.0e9), 0, "WARN", "WARN"),
    ("base also over, candidate clearly above it", (1.25e9, 1.0e9), (1.25e9, 0.96e9), 1, "FAIL", "FAIL"),
]


def run_case(workdir: str, index: int, case: tuple) -> tuple[bool, str]:
    name, base, cand, want_exit, want_overall, want_ratio = case
    folder = os.path.join(workdir, f"case-{index}")
    os.makedirs(folder, exist_ok=True)
    base_path, cand_path = os.path.join(folder, "base.jsonl"), os.path.join(folder, "cand.jsonl")
    budgets, summary = os.path.join(folder, "budgets.json"), os.path.join(folder, "summary.json")
    write_side(base_path, *base)
    write_side(cand_path, *cand)
    with open(budgets, "w", encoding="utf-8") as handle:
        json.dump({"ratio_budgets": {FIXTURE: {"max": BUDGET}}}, handle)
    result = subprocess.run([sys.executable, "-I", PROBE, "compare", "--base", base_path, "--cand", cand_path,
                             "--budgets", budgets, "--json", summary], capture_output=True, text=True)
    if result.returncode == 2 or not os.path.exists(summary):
        return False, f"compare failed (exit {result.returncode}): {result.stderr.strip()}"
    with open(summary, encoding="utf-8") as handle:
        data = json.load(handle)
    ratio = next((r["verdict"] for r in data["ratios"] if r["fixture"] == FIXTURE), None)
    got = (result.returncode, data["verdict"], ratio)
    want = (want_exit, want_overall, want_ratio)
    return got == want, f"got exit/verdict/ratio {got}, want {want}"


def main() -> int:
    if len(sys.argv) > 1:
        workdir = os.path.abspath(sys.argv[1])
        os.makedirs(workdir, exist_ok=True)
        holder = None
    else:
        holder = tempfile.TemporaryDirectory(prefix="perf-probe-tests-")
        workdir = holder.name
    passed = 0
    for index, case in enumerate(CASES):
        ok, detail = run_case(workdir, index, case)
        passed += ok
        print(f"{'ok  ' if ok else 'FAIL'} {case[0]}" + ("" if ok else f": {detail}"))
    print(f"{passed}/{len(CASES)} passed")
    if holder is not None:
        holder.cleanup()
    return 0 if passed == len(CASES) else 1


if __name__ == "__main__":
    sys.exit(main())
