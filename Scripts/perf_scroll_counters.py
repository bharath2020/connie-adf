#!/usr/bin/env python3
"""Helpers for Scripts/perf-scroll-counters.sh, the T1 scroll-counter tier
(standard library only; run with `python3 -I`).

SUBCOMMANDS
    others --self-pid <pid>
        Prints one line per other perf run on this host (`<pid> <command>`):
        processes executing perf-gate.sh, perf_trial.py, lifecycle-gate.sh
        or perf-scroll-counters.sh (as the program, or its interpreter's
        script; a shell that only mentions a name does not count), excluding
        <pid>, its ancestors and its descendants (this run's own
        perf_trial.py children). Prints nothing when the host has none.

    export-worktree --repo <dir> --dest <dir>
        Copies the working tree's tracked and untracked, non-ignored files
        (`git ls-files -co --exclude-standard`) into <dest>, which must be
        empty or missing: the candidate `.` (uncommitted changes included).

    overlay --dest <export> --fixture-source <dir> --fixtures "<names>"
            --record <json>
        Refuses (exit 2) an exported ref without the T1 instrumentation
        (Demo/ADFReader/ScrollCounters.swift): T1 needs refs that contain
        it. Copies each requested fixture the ref lacks from
        <fixture-source> (data only) and notes fixtures whose bytes differ.
        Writes what it did to <record>.

    compare --csv <trials.csv> --budget <json> --out <md> [--speed <pt/s>]
            [--base-label <s>] [--candidate-label <s>] [--phases <tsv>]
            [--overlay <json>]... [--title <s>]
        Pairs each (fixture, renderer) base trial with its candidate trial
        and applies the budget (Scripts/perf-scroll-counters.json):
        counts within ±count_tolerance_pct of base (per column:
        count_tolerance_pct_by_column; or an absolute slack, if larger),
        candidate idle instructions per second, idle row churn and idle
        TextKit 2 layouts within fixed budgets, scroll instructions a WARN
        above scroll_instructions_warn_pct. Writes a markdown report and
        prints it. Exit 0 PASS or WARN, 1 FAIL, 2 INVALID.

    pick-runtime --device-type <name>   (reads `simctl list runtimes -j` on stdin)
        Prints the identifier of the newest available iOS runtime that
        supports <name>.

    device-state --udid <udid>          (reads `simctl list devices -j` on stdin)
        Prints the device's state (Booted, Shutdown, …) or Missing.

TRIALS CSV (written by perf_trial.py parse; the T1 driver's meta columns)
    arm = base | candidate, label = the requested renderer (swiftui |
    textkit2), argv = the launch arguments, requires_completion = 1,
    requires_counters = 1.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys

# ------------------------------------------------------------------ others

PERF_SCRIPTS = {"perf-gate.sh", "perf_trial.py", "lifecycle-gate.sh", "perf-scroll-counters.sh"}
INTERPRETER = re.compile(r"^(env|bash|sh|zsh|python[0-9.]*|Python)$")


def runs_perf_script(command: str) -> bool:
    """True when the process executes one of PERF_SCRIPTS: the script is
    the program, or the first operand after interpreters and their flags
    (`bash perf-gate.sh …`, `…/Python -I -u …/perf_trial.py sample …`). A
    shell whose command text merely mentions a name (`zsh -c "pgrep -f
    perf_trial.py"`, an agent's wrapper around this script) is not a run."""
    for token in command.split():
        name = os.path.basename(token)
        if name in PERF_SCRIPTS:
            return True
        if token.startswith("-") or INTERPRETER.match(name):
            if token == "-c":
                return False  # an inline shell script, not a script file
            continue
        return False
    return False


def cmd_others(args: argparse.Namespace) -> int:
    out = subprocess.run(["ps", "-Ao", "pid=,ppid=,command="], capture_output=True, text=True).stdout
    procs: dict[int, tuple[int, str]] = {}
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
            procs[int(parts[0])] = (int(parts[1]), parts[2])
    # Descendants of this run only (its perf_trial.py children). Never the
    # ancestors' descendants: a shared ancestor (the agent host, a terminal)
    # also parents every other lane's runs.
    descendants = {args.self_pid}
    changed = True
    while changed:
        changed = False
        for pid, (ppid, _) in procs.items():
            if ppid in descendants and pid not in descendants:
                descendants.add(pid)
                changed = True
    ancestors = set()
    pid = args.self_pid
    while pid in procs and pid > 1:  # e.g. a `bash -c "…perf-scroll-counters.sh…"` wrapper
        pid = procs[pid][0]
        ancestors.add(pid)
    own = descendants | ancestors | {os.getpid()}
    for pid, (_, command) in sorted(procs.items()):
        if pid not in own and runs_perf_script(command):
            shown = command if len(command) <= 220 else command[:60] + " … " + command[-150:]
            print(f"{pid} {shown}")
    return 0


# --------------------------------------------------------- export-worktree


def cmd_export_worktree(args: argparse.Namespace) -> int:
    repo, dest = os.path.abspath(args.repo), os.path.abspath(args.dest)
    if os.path.exists(dest) and os.listdir(dest):
        print(f"export-worktree: {dest} is not empty", file=sys.stderr)
        return 2
    listed = subprocess.run(["git", "-C", repo, "ls-files", "-z", "-co", "--exclude-standard"],
                            capture_output=True, check=True).stdout.split(b"\0")
    copied = 0
    for raw in listed:
        if not raw:
            continue
        rel = raw.decode("utf-8", errors="surrogateescape")
        src = os.path.join(repo, rel)
        if not os.path.isfile(src) and not os.path.islink(src):
            continue  # tracked but deleted in the working tree
        target = os.path.join(dest, rel)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copy2(src, target, follow_symlinks=False)
        copied += 1
    print(f"export-worktree: {copied} files from {repo}")
    return 0


# ----------------------------------------------------------------- overlay

SCROLL_COUNTERS = "Demo/ADFReader/ScrollCounters.swift"


def sha256(path: str) -> str:
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def cmd_overlay(args: argparse.Namespace) -> int:
    dest = os.path.abspath(args.dest)
    record: dict = {"dest": dest, "fixtures": {}}

    def refuse(why: str) -> int:
        record["error"] = why
        write_record(args.record, record)
        print(f"overlay: {why}", file=sys.stderr)
        return 2

    if not os.path.exists(os.path.join(dest, SCROLL_COUNTERS)):
        return refuse(f"{dest} lacks {SCROLL_COUNTERS}: the ref predates the T1 instrumentation; "
                      "T1 needs base and candidate refs that contain it")

    for name in args.fixtures.split():
        rel = f"Fixtures/{name}.json"
        mine, theirs = os.path.join(dest, rel), os.path.join(os.path.abspath(args.fixture_source), rel)
        if not os.path.exists(mine):
            if not os.path.exists(theirs):
                return refuse(f"fixture {name}.json is in neither {dest} nor {args.fixture_source}")
            os.makedirs(os.path.dirname(mine), exist_ok=True)
            shutil.copy2(theirs, mine)
            record["fixtures"][name] = {"action": "added", "sha256": sha256(mine)}
        else:
            entry = {"action": "native", "sha256": sha256(mine)}
            if os.path.exists(theirs) and sha256(theirs) != entry["sha256"]:
                entry["differs_from_fixture_source"] = sha256(theirs)
            record["fixtures"][name] = entry
    write_record(args.record, record)
    print("overlay: fixtures: "
          + ", ".join(f"{k}={v['action']}{' (DIFFERS)' if 'differs_from_fixture_source' in v else ''}"
                      for k, v in record["fixtures"].items()))
    return 0


def write_record(path: str, record: dict) -> None:
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(record, handle, indent=2, sort_keys=True)
        handle.write("\n")


# ----------------------------------------------------------------- compare


def as_float(value: str | None) -> float | None:
    if value is None or value == "":
        return None
    try:
        return float(value)
    except ValueError:
        return None


def fmt(value: float | None) -> str:
    if value is None:
        return "–"
    if abs(value) >= 1e9:
        return f"{value / 1e9:.3f} G"
    if abs(value) >= 1e6:
        return f"{value / 1e6:.2f} M"
    return f"{value:g}"


def pct(base: float | None, cand: float | None) -> float | None:
    if base is None or cand is None or base == 0:
        return None
    return (cand - base) / base * 100


def requested_renderer(row: dict) -> str:
    return row.get("label") or ("textkit2" if "-textkit2" in (row.get("argv") or "").split() else "swiftui")


# Candidate statuses (perf_trial.py) that FAIL a cell whose base finished:
# READY came, then the app never completed the scroll and idle window
# (timeout, incomplete, no_metrics) or died (crashed). no_ready and
# no_counters stay INVALID (launch or build problems).
CANDIDATE_BROKE = {"timeout", "incomplete", "no_metrics", "crashed"}


def check_valid(row: dict | None, renderer: str, speed: float | None) -> list[str]:
    if row is None:
        return ["no trial"]
    why = []
    if row.get("status") != "ok":
        why.append(f"status={row.get('status') or '∅'}")
    if row.get("completed") != "1":
        why.append(f"completed={row.get('completed') or '∅'}")
    if row.get("renderer") and row["renderer"] != renderer:
        why.append(f"renderer={row['renderer']} (asked {renderer})")
    if not row.get("renderer"):
        why.append("no RENDERER_STATS")
    got = as_float(row.get("counters_speed"))
    if speed is not None and (got is None or abs(got - speed) > 0.5):
        why.append(f"speed={row.get('counters_speed') or '∅'} (asked {speed:g})")
    return why


def cmd_compare(args: argparse.Namespace) -> int:
    with open(args.budget, encoding="utf-8") as handle:
        budget = json.load(handle)
    with open(args.csv, newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    pairs: dict[tuple[str, str], dict[str, dict]] = {}
    order: list[tuple[str, str]] = []
    for row in rows:
        key = (row.get("fixture", ""), requested_renderer(row))
        if key not in pairs:
            pairs[key] = {}
            order.append(key)
        pairs[key][row.get("arm", "")] = row  # a rerun of the same cell: the last row wins

    tolerance = float(budget["count_tolerance_pct"])
    tolerance_by_column = budget.get("count_tolerance_pct_by_column", {})
    slack = budget.get("count_abs_slack", {})
    counts = budget["counts"]
    idle_ips_max = float(budget["idle_instructions_per_second_max"])
    churn_max = float(budget["idle_row_churn_max"])
    idle_layouts_max = float(budget["idle_tk2_layouts_max"])
    warn_pct = budget.get("scroll_instructions_warn_pct")
    fail_pct = budget.get("scroll_instructions_fail_pct")

    table, details, missing_notes = [], [], []
    missing_by_field: dict[str, list[str]] = {}
    verdicts = []
    for fixture, renderer in order:
        base, cand = pairs[(fixture, renderer)].get("base"), pairs[(fixture, renderer)].get("candidate")
        invalid = [f"base: {w}" for w in check_valid(base, renderer, args.speed)]
        fails, warns, missing = [], [], []
        candidate_why = check_valid(cand, renderer, args.speed)
        if not invalid and cand is not None and cand.get("status") in CANDIDATE_BROKE:
            # The base finished this cell and the candidate did not: the
            # candidate hung, spun or crashed — a regression, not a bad run.
            fails.append(f"candidate did not finish the trial (status={cand.get('status')}) while the base "
                         "did: a hang, livelock or crash")
        else:
            invalid += [f"candidate: {w}" for w in candidate_why]
        if (base is not None and cand is not None and not fails
                and base.get("blocks") != cand.get("blocks")):
            invalid.append(f"blocks differ ({base.get('blocks')} vs {cand.get('blocks')}): not the same document")
        if not invalid and not fails:
            assert base is not None and cand is not None
            for column in counts:
                b, c = as_float(base.get(column)), as_float(cand.get(column))
                if b is None or c is None:
                    if b is not None or c is not None:
                        missing.append(f"{column} ({'base' if b is None else 'candidate'})")
                    continue
                column_pct = float(tolerance_by_column.get(column, tolerance))
                allowed = max(abs(b) * column_pct / 100, float(slack.get(column, slack.get("default", 0))))
                if abs(c - b) > allowed:
                    fails.append(f"{column} {fmt(b)} → {fmt(c)} ({pct(b, c):+.2f} %)" if b else
                                 f"{column} {fmt(b)} → {fmt(c)}")
            d = pct(as_float(base.get("scroll_instructions")), as_float(cand.get("scroll_instructions")))
            fixture_warn = budget.get("scroll_instructions_warn_pct_by_fixture", {}).get(fixture, warn_pct)
            if d is not None and fail_pct is not None and d > float(fail_pct):
                fails.append(f"scroll_instructions {d:+.2f} % > +{fail_pct} %")
            elif d is not None and fixture_warn is not None and d > float(fixture_warn):
                warns.append(f"scroll_instructions {d:+.2f} % > +{fixture_warn} %")
            for arm_name, row in (("candidate", cand), ("base", base)):
                instructions, ms = as_float(row.get("idle_instructions")), as_float(row.get("idle_ms"))
                over = []
                if instructions is not None and ms:
                    ips = instructions / (ms / 1000)
                    if ips > idle_ips_max:
                        over.append(f"idle {fmt(ips)} instr/s > {fmt(idle_ips_max)}")
                elif arm_name == "candidate":
                    missing.append("idle_instructions (candidate)")
                churn = sum(as_float(row.get(k)) or 0 for k in ("idle_row_appears", "idle_row_disappears"))
                if churn > churn_max:
                    over.append(f"idle row churn {churn:g} > {churn_max:g}")
                layouts = as_float(row.get("idle_tk2_layouts")) or 0
                if layouts > idle_layouts_max:
                    over.append(f"idle TK2 layouts {layouts:g} > {idle_layouts_max:g}")
                if arm_name == "candidate":
                    fails += over
                elif over:
                    warns.append("base also over the idle budget: " + "; ".join(over))
        verdict = "INVALID" if invalid else "FAIL" if fails else "WARN" if warns else "PASS"
        verdicts.append(verdict)

        def pair(column: str) -> str:
            b = as_float(base.get(column)) if base else None
            c = as_float(cand.get(column)) if cand else None
            return f"{fmt(b)} → {fmt(c)}"

        def idle_rate(row: dict | None) -> str:
            if not row:
                return "–"
            instructions, ms = as_float(row.get("idle_instructions")), as_float(row.get("idle_ms"))
            return fmt(instructions / (ms / 1000)) if instructions is not None and ms else "–"

        d = pct(as_float(base.get("scroll_instructions")) if base else None,
                as_float(cand.get("scroll_instructions")) if cand else None)
        table.append(f"| {fixture} | {renderer} | **{verdict}** | {pair('tk2_layouts')} | {pair('row_appears')} "
                     f"| {pair('tk2_off_window')} | {pair('scroll_instructions')} "
                     f"({'–' if d is None else f'{d:+.2f} %'}) | {idle_rate(base)} → {idle_rate(cand)} "
                     f"| {pair('scroll_ms')} |")
        for kind, items in (("INVALID", invalid), ("FAIL", fails), ("WARN", warns)):
            for item in items:
                details.append(f"- {fixture} · {renderer} · {kind}: {item}")
        for item in missing:
            missing_notes.append(f"{fixture} · {renderer}")
            missing_by_field.setdefault(item, []).append(f"{fixture} · {renderer}")

    overall = ("INVALID" if "INVALID" in verdicts or not verdicts else "FAIL" if "FAIL" in verdicts
               else "WARN" if "WARN" in verdicts else "PASS")
    lines = [f"# {args.title}", "",
             f"Base `{args.base_label}` vs candidate `{args.candidate_label}`; speed "
             f"{args.speed:g} pt/s; budget `{args.budget}`.", "",
             f"**Verdict: {overall}** ({len(verdicts)} fixture × renderer pairs; counts within "
             f"±{tolerance:g} % of base; candidate idle ≤ {fmt(idle_ips_max)} instr/s, row churn ≤ "
             f"{churn_max:g}, TK2 layouts ≤ {idle_layouts_max:g}; scroll instructions warn above "
             f"{'+' + str(warn_pct) + ' %' if warn_pct is not None else 'never'}).", "",
             "| fixture | renderer | verdict | TK2 layouts | rows appeared | TK2 off-window | scroll instructions "
             "| idle instr/s | scroll ms |",
             "|---|---|---|---|---|---|---|---|---|", *table, ""]
    if details:
        lines += ["## Findings", "", *details, ""]
    if missing_by_field:
        lines += ["## Fields one build does not report (not compared)", ""]
        for item, cells in missing_by_field.items():
            lines.append(f"- {item}: {len(cells)} cell(s) ({', '.join(cells)})")
        lines.append("")
    if args.overlay:
        lines += ["## Fixtures per arm", ""]
    for path in args.overlay or []:
        try:
            with open(path, encoding="utf-8") as handle:
                record = json.load(handle)
        except (OSError, ValueError):
            continue
        name = os.path.basename(path)
        fixtures = ", ".join(f"{k} {v['action']}" + (" — DIFFERS from the candidate's copy"
                                                     if "differs_from_fixture_source" in v else "")
                             for k, v in record.get("fixtures", {}).items())
        lines.append(f"- `{name}`: {fixtures}")
    if args.overlay:
        lines.append("")
    if args.phases and os.path.exists(args.phases):
        lines += ["## Phase timings", "", "| phase | seconds |", "|---|---|"]
        with open(args.phases, encoding="utf-8") as handle:
            for line in handle:
                parts = line.rstrip("\n").split("\t")
                if len(parts) == 2:
                    lines.append(f"| {parts[0]} | {parts[1]} |")
        lines.append("")
    text = "\n".join(lines)
    with open(args.out, "w", encoding="utf-8") as handle:
        handle.write(text)
    print(text)
    return {"PASS": 0, "WARN": 0, "FAIL": 1}.get(overall, 2)


# ---------------------------------------------------------------- simulator


def version_key(text: str) -> tuple[int, ...]:
    return tuple(int(x) for x in re.findall(r"\d+", text))


def cmd_pick_runtime(args: argparse.Namespace) -> int:
    data = json.load(sys.stdin)
    best = None
    for runtime in data.get("runtimes", []):
        if runtime.get("platform", "iOS") != "iOS" or not runtime.get("isAvailable", False):
            continue
        names = {d.get("name") for d in runtime.get("supportedDeviceTypes", [])}
        if names and args.device_type not in names:
            continue
        key = version_key(runtime.get("version", ""))
        if best is None or key > best[0]:
            best = (key, runtime["identifier"])
    if best is None:
        print(f"pick-runtime: no available iOS runtime supports {args.device_type!r}", file=sys.stderr)
        return 2
    print(best[1])
    return 0


def cmd_device_state(args: argparse.Namespace) -> int:
    data = json.load(sys.stdin)
    for devices in data.get("devices", {}).values():
        for device in devices:
            if device.get("udid", "").upper() == args.udid.upper():
                print(device.get("state", "Unknown"))
                return 0
    print("Missing")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("others")
    p.add_argument("--self-pid", type=int, required=True)
    p.set_defaults(func=cmd_others)

    p = sub.add_parser("export-worktree")
    p.add_argument("--repo", required=True)
    p.add_argument("--dest", required=True)
    p.set_defaults(func=cmd_export_worktree)

    p = sub.add_parser("overlay")
    p.add_argument("--dest", required=True)
    p.add_argument("--fixture-source", required=True)
    p.add_argument("--fixtures", required=True)
    p.add_argument("--record", required=True)
    p.set_defaults(func=cmd_overlay)

    p = sub.add_parser("compare")
    p.add_argument("--csv", required=True)
    p.add_argument("--budget", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--speed", type=float)
    p.add_argument("--base-label", default="base")
    p.add_argument("--candidate-label", default="candidate")
    p.add_argument("--phases")
    p.add_argument("--overlay", action="append")
    p.add_argument("--title", default="T1 scroll counters")
    p.set_defaults(func=cmd_compare)

    p = sub.add_parser("pick-runtime")
    p.add_argument("--device-type", required=True)
    p.set_defaults(func=cmd_pick_runtime)

    p = sub.add_parser("device-state")
    p.add_argument("--udid", required=True)
    p.set_defaults(func=cmd_device_state)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
