#!/usr/bin/env python3
"""Synthetic cases for the TK2 ÷ SwiftUI ratio and instruction verdicts of
Scripts/perf_probe.py compare, for its pick-runtime simulator choice, and
for Scripts/perf-probe.sh when the base cannot build the probe suite.

USAGE
    python3 -I Scripts/tests/perf_probe_tests.py [<workdir>]

Writes base and candidate probe JSONL plus a budgets file per case under
<workdir> (default: a temporary directory), runs `perf_probe.py compare` on
them and checks the exit status, the overall verdict and the ratio row's
verdict in summary.json. The perf-probe.sh cases export HEAD (git, bash)
under <workdir> with a stub `swift` on PATH, so <workdir> must be outside
the repository. Prints one line per case and "<passed>/<total> passed";
exits 1 on any mismatch. Standard library only.
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


def line(renderer: str, instructions) -> str:
    median, low = instructions if isinstance(instructions, tuple) else (instructions, instructions)
    return json.dumps({
        "schema": 1, "tier": "render", "fixture": FIXTURE, "renderer": renderer,
        "fixture_fnv64": "0123456789abcdef", "blocks": 100,
        "counts": {"uiviews": 10, "calayers": 20},
        "counts_unstable": [],
        "instructions": {"median": median, "min": low, "max": median, "cv_pct": 0.1},
        "mallocs": {"main": 1000, "all": 2000},
    })


def write_side(path: str, tk2, swiftui) -> None:
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("PERF_PROBE " + line("textKit2", tk2) + "\n")
        handle.write("PERF_PROBE " + line("swiftUI", swiftui) + "\n")


# (name, base (tk2, swiftUI), candidate (tk2, swiftUI), exit, overall, ratio verdict);
# an instruction figure is the median, or (median, min).
CASES = [
    ("both within the budget", (1.15e9, 1.0e9), (1.15e9, 1.0e9), 0, "PASS", "PASS"),
    ("disturbed reps lift the candidate TK2 median over the budget, minimum flat",
     (1.15e9, 1.0e9), ((1.265e9, 1.15e9), 1.0e9), 0, "PASS", "PASS"),
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


# (name, base (median, min), candidate (median, min) instructions, exit, row verdict[, candidate fixture_fnv64])
INSTRUCTION_CASES = [
    # Recorded on a loaded host (render code slice): two or three of five
    # reps did ~45 % extra main-thread work on both refs; the minimum is flat.
    ("noisy reps lift the candidate median, minimum flat", (1.5033e9, 1.4957e9), (1.6556e9, 1.5079e9), 0, "PASS"),
    ("the whole distribution rose", (1.50e9, 1.49e9), (1.60e9, 1.59e9), 1, "FAIL"),
    ("the candidate edited the fixture: not comparable, not a FAIL", (1.50e9, 1.49e9), (1.60e9, 1.59e9), 0,
     "CHANGED", "fedcba9876543210"),
]


def run_instruction_case(workdir: str, index: int, case: tuple) -> tuple[bool, str]:
    name, base, cand, want_exit, want_verdict, *cand_fnv = case
    folder = os.path.join(workdir, f"instr-{index}")
    os.makedirs(folder, exist_ok=True)
    paths = {side: os.path.join(folder, f"{side}.jsonl") for side in ("base", "cand")}
    for side, (med, low) in (("base", base), ("cand", cand)):
        record = json.loads(line("swiftUI", med))
        record["instructions"].update({"min": low, "max": med * 1.5, "cv_pct": 20.0})
        if side == "cand" and cand_fnv:
            record["fixture_fnv64"] = cand_fnv[0]
        with open(paths[side], "w", encoding="utf-8") as handle:
            handle.write("PERF_PROBE " + json.dumps(record) + "\n")
    summary = os.path.join(folder, "summary.json")
    result = subprocess.run([sys.executable, "-I", PROBE, "compare", "--base", paths["base"], "--cand", paths["cand"],
                             "--json", summary], capture_output=True, text=True)
    if result.returncode == 2 or not os.path.exists(summary):
        return False, f"compare failed (exit {result.returncode}): {result.stderr.strip()}"
    with open(summary, encoding="utf-8") as handle:
        rows = json.load(handle)["rows"]
    got = (result.returncode, rows[0]["verdict"] if rows else None)
    return got == (want_exit, want_verdict), f"got exit/verdict {got}, want {(want_exit, want_verdict)}"


def runtime(version: str, devices: list[str], platform: str = "iOS") -> dict:
    return {"platform": platform, "isAvailable": True, "version": version,
            "identifier": f"com.apple.CoreSimulator.SimRuntime.{platform}-{version.replace('.', '-')}",
            "supportedDeviceTypes": [{"name": name} for name in devices]}


# (name, runtimes, pick-runtime arguments, wanted identifier suffix or None for "no runtime")
RUNTIME_CASES = [
    ("newest runtime that supports the device, not a newer one that does not",
     [runtime("26.3", ["iPhone 17 Pro"]), runtime("27.0", ["iPhone 17 Pro"]), runtime("27.1", ["iPad Pro"])],
     ["--device-type", "iPhone 17 Pro"], "iOS-27-0"),
    ("no runtime supports the device", [runtime("27.1", ["iPad Pro"])],
     ["--device-type", "iPhone 17 Pro"], None),
    ("below --min is never picked", [runtime("18.5", ["iPhone 17 Pro"])], ["--device-type", "iPhone 17 Pro"], None),
]


def run_runtime_case(case: tuple) -> tuple[bool, str]:
    name, runtimes, extra, want = case
    result = subprocess.run([sys.executable, "-I", PROBE, "pick-runtime", "--min", "26", *extra],
                            input=json.dumps({"runtimes": runtimes}), capture_output=True, text=True)
    got = result.stdout.strip() if result.returncode == 0 else None
    ok = (got is None) if want is None else bool(got and got.endswith(want))
    return ok, f"got {got!r} (exit {result.returncode}), want {want!r}"


STUB_SWIFT = """#!/bin/sh
echo "Building for debugging..."
case "$PWD" in
    */src/{slots}) echo "$PWD/{path}:12:5: error: cannot find 'TextKit2RowView' in scope"; exit 1 ;;
esac
exit 0
"""
SUITE = "Tests/ADFPreparationTests/Perf/ParsePreparePerfTests.swift"

# (name, slots whose build fails (shell pattern), file the stub compiler error names, exit,
#  wanted stdout prefix or None for "no SKIPPED")
SCRIPT_CASES = [
    ("the base cannot build the overlaid probe suite: SKIPPED", "base", SUITE, 0,
     "T0 work probe SKIPPED: base {sha} cannot build the current probe suite "
     f"({SUITE}:12:5: error: cannot find 'TextKit2RowView' in scope)"),
    ("the base fails to build outside the probe suite: error", "base", "Sources/ADFParser/ADFParser.swift", 2, None),
    ("the candidate cannot build its own probe suite either: error", "*", SUITE, 2, None),
]


def run_script_case(workdir: str, index: int, case: tuple) -> tuple[bool, str]:
    name, slots, path, want_exit, want_prefix = case
    folder = os.path.join(workdir, f"script-{index}")
    stubs = os.path.join(folder, "bin")
    os.makedirs(stubs, exist_ok=True)
    for tool, body in (("swift", STUB_SWIFT.format(slots=slots, path=path)), ("xcodebuild", "#!/bin/sh\nexit 0\n")):
        stub = os.path.join(stubs, tool)
        with open(stub, "w", encoding="utf-8") as handle:
            handle.write(body)
        os.chmod(stub, 0o755)
    repo = os.path.dirname(SCRIPTS)
    sha = subprocess.run(["git", "-C", repo, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()[:9]
    env = dict(os.environ, PATH=stubs + os.pathsep + os.environ.get("PATH", ""))
    result = subprocess.run(["bash", os.path.join(SCRIPTS, "perf-probe.sh"), "--tier", "parse", "--allow-busy",
                             "--root", os.path.join(folder, "root"), "HEAD", "HEAD"],
                            capture_output=True, text=True, env=env)
    skipped = result.stdout.startswith("T0 work probe SKIPPED")
    ok = result.returncode == want_exit and (
        result.stdout.startswith(want_prefix.format(sha=sha)) if want_prefix else not skipped)
    return ok, f"got exit {result.returncode}, stdout {result.stdout.strip()!r}, stderr tail {result.stderr[-300:]!r}"


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
    for index, case in enumerate(INSTRUCTION_CASES):
        ok, detail = run_instruction_case(workdir, index, case)
        passed += ok
        print(f"{'ok  ' if ok else 'FAIL'} instructions: {case[0]}" + ("" if ok else f": {detail}"))
    for case in RUNTIME_CASES:
        ok, detail = run_runtime_case(case)
        passed += ok
        print(f"{'ok  ' if ok else 'FAIL'} pick-runtime: {case[0]}" + ("" if ok else f": {detail}"))
    for index, case in enumerate(SCRIPT_CASES):
        ok, detail = run_script_case(workdir, index, case)
        passed += ok
        print(f"{'ok  ' if ok else 'FAIL'} perf-probe.sh: {case[0]}" + ("" if ok else f": {detail}"))
    total = len(CASES) + len(INSTRUCTION_CASES) + len(RUNTIME_CASES) + len(SCRIPT_CASES)
    print(f"{passed}/{total} passed")
    if holder is not None:
        holder.cleanup()
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
