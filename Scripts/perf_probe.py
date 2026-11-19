#!/usr/bin/env python3
"""Verdicts for Scripts/perf-probe.sh, the T0 work probe (standard library
only; run with `python3 -I`).

USAGE
    # base vs candidate (one or more probe passes per side; a side's passes
    # are combined by the median of their per-pass medians):
    python3 -I Scripts/perf_probe.py compare \\
        --base <base.jsonl>... --cand <cand.jsonl>... \\
        [--budgets Scripts/perf-probe-budgets.json] \\
        [--base-label main@7301c30] [--cand-label WORKTREE@<tree>] \\
        [--out report.md] [--json summary.json] [--strict-counts] \\
        [--meta 'key=value']...
    # ratio budgets from N passes of one ref (normally main), each pass
    # its own JSONL file:
    python3 -I Scripts/perf_probe.py calibrate --runs <pass>.jsonl... \\
        [--budgets Scripts/perf-probe-budgets.json] [--margin-pct 2] \\
        --out <calibrated.json>
    # newest available iOS simulator runtime >= --min (simctl JSON on stdin):
    xcrun simctl list runtimes -j | python3 -I Scripts/perf_probe.py pick-runtime --min 26
    # mirror a directory, rewriting only changed files (keeps mtimes, so
    # builds of an exported tree stay incremental):
    python3 -I Scripts/perf_probe.py sync <src> <dst> [--keep .swiftpm --keep .build]

INPUT  One JSON object per line, as the probe suites print them after
    `PERF_PROBE ` (Tests/ADFRenderingTests/Perf/PerfProbeTests.swift, tier
    "render"; Tests/ADFPreparationTests/Perf/ParsePreparePerfTests.swift,
    tier "parse"). Lines are keyed by (tier, fixture, renderer). Fields
    used: counts{}, counts_unstable[], instructions{median,min,max,cv_pct},
    instructions_layout{}, mallocs{main|all}, fixture_fnv64, blocks.

RULES (thresholds from the budgets file; defaults in DEFAULT_BUDGETS)
    instructions   median Δ vs the same-session base: FAIL at >= +fail_pct
                   (5), WARN at >= +warn_pct (2), each raised for a line
                   whose calibrated cross-process noise is larger:
                   warn = max(warn_pct, noise_warn_factor × noise), fail =
                   max(fail_pct, noise_fail_factor × noise), noise =
                   instruction_noise_pct["tier/fixture/renderer"], the
                   spread (max/min − 1) of the pass medians in a
                   calibration. Either side's rep CV above noise_cv_pct (1)
                   adds NOISY (rerun before trusting it).
    mallocs        render: main-thread count; parse: all threads. Same
                   thresholds as instructions (mallocs_*_pct), raised by
                   the calibrated malloc_noise_pct the same way.
    counts         every counter must match exactly; a difference is
                   CHANGED ("explain or re-baseline"), exit 0 unless
                   --strict-counts. A counter only one side has (a new
                   product counter) is listed, never CHANGED. A counter
                   whose reps disagreed (counts_unstable) is listed apart.
    ratio          render tier, candidate TextKit 2 ÷ SwiftUI instructions
                   per fixture <= ratio_budgets[fixture] (FAIL above);
                   null budget = uncalibrated, reported only.
    layouts/row    TextKit 2 arm: tk2.layoutCount ÷ tk2_rows, budget
                   tk2_layouts_per_row_max (1.0). Reported as a signal
                   (issue 10); a FAIL only with enforce_layouts_per_row.
    fixture        a fixture whose bytes differ between sides is flagged
                   FIXTURE-DIFFERS (its counts and instructions are not
                   comparable).

EXIT  0 PASS / WARN / CHANGED; 1 FAIL (or CHANGED with --strict-counts);
      2 usage or input error.
"""

import argparse
import json
import math
import os
import statistics
import sys

DEFAULT_BUDGETS = {
    "instructions_warn_pct": 2.0,
    "instructions_fail_pct": 5.0,
    "mallocs_warn_pct": 2.0,
    "mallocs_fail_pct": 5.0,
    "noise_cv_pct": 1.0,
    "tk2_layouts_per_row_max": 1.0,
    "enforce_layouts_per_row": False,
    "ratio_budgets": {},
    "instruction_noise_pct": {},
    "noise_warn_factor": 1.0,
    "noise_fail_factor": 2.0,
}

RANK = {"PASS": 0, "WARN": 1, "CHANGED": 2, "FAIL": 3}


def die(message):
    print(f"perf_probe: error: {message}", file=sys.stderr)
    sys.exit(2)


def load_lines(paths):
    """Per file: {(tier, fixture, renderer): record}."""
    passes = []
    for path in paths:
        records = {}
        try:
            with open(path, encoding="utf-8") as handle:
                for number, raw in enumerate(handle, 1):
                    raw = raw.strip()
                    if raw.startswith("PERF_PROBE "):
                        raw = raw[len("PERF_PROBE "):]
                    if not raw.startswith("{"):
                        continue
                    try:
                        record = json.loads(raw)
                    except json.JSONDecodeError as error:
                        die(f"{path}:{number}: {error}")
                    key = (record.get("tier", "?"), record.get("fixture", "?"), record.get("renderer", "-"))
                    records[key] = record
        except OSError as error:
            die(f"{path}: {error}")
        if not records:
            die(f"{path}: no probe lines")
        passes.append(records)
    return passes


def median(values):
    values = [v for v in values if v is not None]
    return statistics.median(values) if values else None


def combine(passes):
    """One record per key across passes: medians of the per-pass medians;
    counts from the first pass, with keys that differ between passes added
    to counts_unstable."""
    keys = []
    for records in passes:
        for key in records:
            if key not in keys:
                keys.append(key)
    combined = {}
    for key in keys:
        present = [records[key] for records in passes if key in records]
        first = dict(present[0])
        unstable = set(first.get("counts_unstable", []))
        for other in present[1:]:
            unstable.update(other.get("counts_unstable", []))
            for name, value in other.get("counts", {}).items():
                if first.get("counts", {}).get(name) != value:
                    unstable.add(name)
        first["counts_unstable"] = sorted(unstable)
        for field in ("instructions", "instructions_layout", "instructions_parse", "instructions_prepare", "cpu_ms", "wall_ms"):
            stats = [r.get(field) for r in present if isinstance(r.get(field), dict)]
            if not stats:
                continue
            first[field] = {
                "median": median([s.get("median") for s in stats]),
                "min": min(s.get("min", math.inf) for s in stats),
                "max": max(s.get("max", -math.inf) for s in stats),
                "cv_pct": max(s.get("cv_pct", 0.0) for s in stats),
                "passes": len(stats),
                "pass_medians": [s.get("median") for s in stats],
            }
        mallocs = [r.get("mallocs") for r in present if isinstance(r.get("mallocs"), dict)]
        if mallocs:
            first["mallocs"] = {name: median([m.get(name) for m in mallocs]) for name in mallocs[0]}
        first["passes"] = len(present)
        combined[key] = first
    return combined


def load_budgets(path):
    budgets = dict(DEFAULT_BUDGETS)
    if path:
        try:
            with open(path, encoding="utf-8") as handle:
                budgets.update(json.load(handle))
        except (OSError, json.JSONDecodeError) as error:
            die(f"budgets {path}: {error}")
    return budgets


def pct(base, cand):
    if base in (None, 0) or cand is None:
        return None
    return (cand - base) / base * 100.0


def fmt_pct(value):
    return "–" if value is None else f"{value:+.2f} %"


def fmt_b(value):
    return "–" if value is None else f"{value / 1e9:.4f}"


def malloc_count(record):
    mallocs = record.get("mallocs") or {}
    return mallocs.get("main") if record.get("tier") == "render" else mallocs.get("all")


def threshold_verdict(delta, warn, fail):
    if delta is None:
        return "PASS"
    if delta >= fail:
        return "FAIL"
    if delta >= warn:
        return "WARN"
    return "PASS"


def layouts_per_row(record):
    if not record or record.get("renderer") != "textKit2":
        return None
    counts = record.get("counts", {})
    rows = counts.get("tk2_rows")
    layouts = counts.get("tk2.layoutCount")
    if not rows or layouts is None:
        return None
    return layouts / rows


def instr_median(record):
    stats = (record or {}).get("instructions") or {}
    return stats.get("median")


def compare(args):
    budgets = load_budgets(args.budgets)
    base = combine(load_lines(args.base))
    cand = combine(load_lines(args.cand))
    rows, notes = [], []
    one_sided_names = set()
    worst = "PASS"
    keys = list(base) + [k for k in cand if k not in base]
    for key in keys:
        tier, fixture, renderer = key
        b, c = base.get(key), cand.get(key)
        if b is None or c is None:
            notes.append(f"- `{tier} {fixture} {renderer}`: only in {'candidate' if b is None else 'base'}; not compared.")
            continue
        flags, verdict = [], "PASS"
        if b.get("fixture_fnv64") and c.get("fixture_fnv64") and b["fixture_fnv64"] != c["fixture_fnv64"]:
            flags.append("FIXTURE-DIFFERS")
        bi, ci = instr_median(b), instr_median(c)
        d_instr = pct(bi, ci)
        noise = (budgets.get("instruction_noise_pct") or {}).get(f"{tier}/{fixture}/{renderer}") or 0.0
        warn_at = max(budgets["instructions_warn_pct"], budgets["noise_warn_factor"] * noise)
        fail_at = max(budgets["instructions_fail_pct"], budgets["noise_fail_factor"] * noise)
        v = threshold_verdict(d_instr, warn_at, fail_at)
        verdict = max(verdict, v, key=RANK.get)
        noisy = [side for side, r in (("base", b), ("cand", c))
                 if ((r.get("instructions") or {}).get("cv_pct") or 0) > budgets["noise_cv_pct"]]
        if noisy:
            flags.append("NOISY(" + ",".join(noisy) + ")")
        bm, cm = malloc_count(b), malloc_count(c)
        d_malloc = pct(bm, cm)
        mnoise = (budgets.get("malloc_noise_pct") or {}).get(f"{tier}/{fixture}/{renderer}") or 0.0
        v = threshold_verdict(d_malloc, max(budgets["mallocs_warn_pct"], budgets["noise_warn_factor"] * mnoise),
                              max(budgets["mallocs_fail_pct"], budgets["noise_fail_factor"] * mnoise))
        if v != "PASS":
            flags.append(f"mallocs {v}")
        verdict = max(verdict, v, key=RANK.get)
        bc, cc = b.get("counts", {}), c.get("counts", {})
        changed, one_sided = [], []
        for name in sorted(set(bc) | set(cc)):
            if name not in bc or name not in cc:
                one_sided.append(f"{name} ({'cand' if name not in bc else 'base'} only: {cc.get(name, bc.get(name))})")
            elif bc[name] != cc[name]:
                changed.append(f"{name} {bc[name]}→{cc[name]}")
        if changed:
            verdict = max(verdict, "CHANGED", key=RANK.get)
            notes.append(f"- `{tier} {fixture} {renderer}` counts changed (explain or re-baseline): " + ", ".join(changed))
        for name in one_sided:
            one_sided_names.add(name.split(" (")[0] + (" (candidate only)" if "(cand only" in name else " (base only)"))
        unstable = sorted(set(b.get("counts_unstable", [])) | set(c.get("counts_unstable", [])))
        if unstable:
            flags.append("unstable counts")
            notes.append(f"- `{tier} {fixture} {renderer}` counters that varied between reps or passes: " + ", ".join(unstable))
        worst = max(worst, verdict, key=RANK.get)
        rows.append({
            "tier": tier, "fixture": fixture, "renderer": renderer, "verdict": verdict, "flags": flags,
            "base_instr": bi, "cand_instr": ci, "instr_delta_pct": d_instr, "warn_at": warn_at, "fail_at": fail_at,
            "base_mallocs": bm, "cand_mallocs": cm, "mallocs_delta_pct": d_malloc,
            "counts_changed": changed, "base_cv": (b.get("instructions") or {}).get("cv_pct"),
            "cand_cv": (c.get("instructions") or {}).get("cv_pct"),
        })

    # Cross-renderer ratio and the layouts-per-row signal (render tier).
    ratio_rows = []
    fixtures = []
    for (tier, fixture, _renderer) in keys:
        if tier == "render" and fixture not in fixtures:
            fixtures.append(fixture)
    for fixture in fixtures:
        def ratio(side):
            tk2 = instr_median(side.get(("render", fixture, "textKit2")))
            sui = instr_median(side.get(("render", fixture, "swiftUI")))
            return tk2 / sui if tk2 and sui else None
        br, cr = ratio(base), ratio(cand)
        budget = (budgets.get("ratio_budgets") or {}).get(fixture)
        limit = budget.get("max") if isinstance(budget, dict) else budget
        verdict = "PASS"
        if cr is None:
            verdict = "–"
        elif limit is None:
            verdict = "uncalibrated"
        elif cr > limit:
            verdict = "FAIL"
        blpr = layouts_per_row(base.get(("render", fixture, "textKit2")))
        clpr = layouts_per_row(cand.get(("render", fixture, "textKit2")))
        signal = ""
        if clpr is not None and clpr > budgets["tk2_layouts_per_row_max"]:
            signal = f"> {budgets['tk2_layouts_per_row_max']:g} (issue 10)"
            if budgets.get("enforce_layouts_per_row"):
                verdict = "FAIL"
        if verdict == "FAIL":
            worst = "FAIL"
        ratio_rows.append({
            "fixture": fixture, "base_ratio": br, "cand_ratio": cr, "budget": limit, "verdict": verdict,
            "base_layouts_per_row": blpr, "cand_layouts_per_row": clpr, "signal": signal,
        })

    if one_sided_names:
        notes.append("- counters on one side only (a counter one ref lacks; not compared): " + ", ".join(sorted(one_sided_names)))
    exit_code = 1 if worst == "FAIL" or (worst == "CHANGED" and args.strict_counts) else 0
    overall = worst if not (worst == "CHANGED" and args.strict_counts) else "FAIL (counts changed, --strict-counts)"

    out = []
    out.append(f"# T0 work probe: {args.base_label} → {args.cand_label}")
    out.append("")
    out.append(f"**Verdict: {overall}** (instructions warn ≥ +{budgets['instructions_warn_pct']:g} %, "
               f"fail ≥ +{budgets['instructions_fail_pct']:g} %; counts exact; ratio budgets from the budgets file)")
    out.append("")
    for meta in args.meta or []:
        out.append(f"- {meta}")
    if args.meta:
        out.append("")
    out.append("| tier | fixture | renderer | base instr (B) | cand instr (B) | Δ instr | warn/fail at | CV b/c | Δ mallocs | counts | verdict |")
    out.append("|---|---|---|---|---|---|---|---|---|---|---|")
    for r in rows:
        cv = "/".join("–" if v is None else f"{v:.2f}" for v in (r["base_cv"], r["cand_cv"]))
        counts = "same" if not r["counts_changed"] else f"{len(r['counts_changed'])} changed"
        verdict = r["verdict"] + ("" if not r["flags"] else " · " + ", ".join(r["flags"]))
        out.append(f"| {r['tier']} | {r['fixture']} | {r['renderer']} | {fmt_b(r['base_instr'])} | {fmt_b(r['cand_instr'])} | "
                   f"{fmt_pct(r['instr_delta_pct'])} | {r['warn_at']:.1f}/{r['fail_at']:.1f} % | {cv} | {fmt_pct(r['mallocs_delta_pct'])} | {counts} | {verdict} |")
    if ratio_rows:
        out.append("")
        out.append("| fixture | TK2 ÷ SwiftUI base | cand | budget | TK2 layouts/row base → cand | verdict |")
        out.append("|---|---|---|---|---|---|")
        for r in ratio_rows:
            def f3(v):
                return "–" if v is None else f"{v:.3f}"
            out.append(f"| {r['fixture']} | {f3(r['base_ratio'])} | {f3(r['cand_ratio'])} | {f3(r['budget'])} | "
                       f"{f3(r['base_layouts_per_row'])} → {f3(r['cand_layouts_per_row'])} {r['signal']} | {r['verdict']} |")
    if notes:
        out.append("")
        out.append("Notes:")
        out.extend(notes)
    text = "\n".join(out) + "\n"
    sys.stdout.write(text)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(text)
    if args.json:
        with open(args.json, "w", encoding="utf-8") as handle:
            json.dump({"verdict": overall, "exit": exit_code, "rows": rows, "ratios": ratio_rows,
                       "base": args.base_label, "cand": args.cand_label}, handle, indent=2)
    return exit_code


def calibrate(args):
    budgets = load_budgets(args.budgets)
    passes = load_lines(args.runs)
    ratios, spreads, malloc_spreads = {}, {}, {}
    for records in passes:
        for (tier, fixture, renderer), record in records.items():
            m = instr_median(record)
            if m:
                spreads.setdefault((tier, fixture, renderer), []).append(m)
            a = malloc_count(record)
            if a:
                malloc_spreads.setdefault((tier, fixture, renderer), []).append(a)
        for (tier, fixture, renderer), record in records.items():
            if tier != "render" or renderer != "textKit2":
                continue
            tk2 = instr_median(record)
            sui = instr_median(records.get(("render", fixture, "swiftUI")))
            if tk2 and sui:
                ratios.setdefault(fixture, []).append(tk2 / sui)
    calibrated = {}
    print(f"calibration from {len(passes)} result files (render and parse passes), margin {args.margin_pct:g} %")
    print("| fixture | passes | TK2÷SwiftUI min | median | max | budget |")
    print("|---|---|---|---|---|---|")
    for fixture in sorted(ratios):
        values = ratios[fixture]
        limit = math.ceil(max(values) * (1 + args.margin_pct / 100.0) * 1000) / 1000
        calibrated[fixture] = {"max": limit, "observed_max": round(max(values), 4),
                               "observed_median": round(statistics.median(values), 4), "passes": len(values)}
        print(f"| {fixture} | {len(values)} | {min(values):.4f} | {statistics.median(values):.4f} | {max(values):.4f} | {limit:.3f} |")
    print("")
    print("| tier | fixture | renderer | passes | instr spread (max/min − 1) | warn/fail at |")
    print("|---|---|---|---|---|---|")
    noise = {}
    for (tier, fixture, renderer), values in sorted(spreads.items()):
        spread = (max(values) / min(values) - 1) * 100 if min(values) else 0
        noise[f"{tier}/{fixture}/{renderer}"] = round(spread, 3)
        warn_at = max(budgets["instructions_warn_pct"], budgets["noise_warn_factor"] * spread)
        fail_at = max(budgets["instructions_fail_pct"], budgets["noise_fail_factor"] * spread)
        print(f"| {tier} | {fixture} | {renderer} | {len(values)} | {spread:.2f} % | {warn_at:.1f}/{fail_at:.1f} % |")
    budgets["instruction_noise_pct"] = noise
    budgets["malloc_noise_pct"] = {
        f"{t}/{f}/{r}": round((max(v) / min(v) - 1) * 100, 3) for (t, f, r), v in sorted(malloc_spreads.items()) if min(v)
    }
    budgets["ratio_budgets"] = calibrated
    budgets["calibration"] = {"passes": max((len(v) for v in spreads.values()), default=0), "margin_pct": args.margin_pct}
    if args.meta:
        # Machine-local paths stay out of the committed budgets.
        budgets["calibration"]["meta"] = [m for m in args.meta if not m.startswith("results:")]
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(budgets, handle, indent=2, sort_keys=True)
        handle.write("\n")
    print(f"\nwrote {args.out}")
    return 0


def sync(args):
    """Make <dst> hold exactly <src>'s files, rewriting only files whose
    bytes differ (so unchanged sources keep their mtimes and incremental
    builds stay incremental). Top-level names in --keep are neither copied
    nor deleted (build state such as .swiftpm/ or .build/)."""
    import filecmp
    import shutil
    src, dst = os.path.abspath(args.src), os.path.abspath(args.dst)
    keep = set(args.keep or [])
    if not os.path.isdir(src):
        die(f"sync: no directory {src}")
    os.makedirs(dst, exist_ok=True)
    wanted = set()
    copied = unchanged = 0
    for root, dirs, files in os.walk(src):
        rel = os.path.relpath(root, src)
        if rel == ".":
            dirs[:] = [d for d in dirs if d not in keep]
            files = [f for f in files if f not in keep]
        for name in dirs:
            relpath = os.path.normpath(os.path.join(rel, name))
            wanted.add(relpath)
            target = os.path.join(dst, relpath)
            if os.path.islink(target) or (os.path.exists(target) and not os.path.isdir(target)):
                os.remove(target)
            os.makedirs(target, exist_ok=True)
        for name in files:
            relpath = os.path.normpath(os.path.join(rel, name))
            wanted.add(relpath)
            source, target = os.path.join(src, relpath), os.path.join(dst, relpath)
            if os.path.islink(source):
                link = os.readlink(source)
                if os.path.islink(target) and os.readlink(target) == link:
                    unchanged += 1
                    continue
                if os.path.lexists(target):
                    os.remove(target)
                os.symlink(link, target)
                copied += 1
                continue
            if os.path.islink(target):
                os.remove(target)
            if os.path.isfile(target) and filecmp.cmp(source, target, shallow=False):
                if (os.stat(source).st_mode & 0o777) != (os.stat(target).st_mode & 0o777):
                    shutil.copymode(source, target)
                unchanged += 1
                continue
            shutil.copyfile(source, target)
            shutil.copymode(source, target)
            copied += 1
    stale_files, stale_dirs = [], []
    for root, dirs, files in os.walk(dst):
        rel = os.path.relpath(root, dst)
        if rel == ".":
            dirs[:] = [d for d in dirs if d not in keep]
            files = [f for f in files if f not in keep]
        for name in files:
            relpath = os.path.normpath(os.path.join(rel, name))
            if relpath not in wanted:
                stale_files.append(os.path.join(dst, relpath))
        for name in list(dirs):
            relpath = os.path.normpath(os.path.join(rel, name))
            if relpath not in wanted:
                stale_dirs.append(os.path.join(dst, relpath))
                dirs.remove(name)
    for path in stale_files:
        os.remove(path)
    for path in stale_dirs:
        if os.path.islink(path):
            os.remove(path)
        else:
            shutil.rmtree(path)
    print(f"sync {dst}: {copied} written, {unchanged} unchanged, {len(stale_files) + len(stale_dirs)} removed")
    return 0


def pick_runtime(args):
    best = None
    for runtime in json.load(sys.stdin).get("runtimes", []):
        if runtime.get("platform") != "iOS" or not runtime.get("isAvailable"):
            continue
        version = tuple(int(p) for p in str(runtime.get("version", "0")).split(".") if p.isdigit())
        if not version or version[0] < args.min:
            continue
        if best is None or version > best[0]:
            best = (version, runtime["identifier"])
    if best is None:
        return 1
    print(best[1])
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    c = sub.add_parser("compare")
    c.add_argument("--base", nargs="+", required=True)
    c.add_argument("--cand", nargs="+", required=True)
    c.add_argument("--budgets")
    c.add_argument("--base-label", default="base")
    c.add_argument("--cand-label", default="candidate")
    c.add_argument("--out")
    c.add_argument("--json")
    c.add_argument("--strict-counts", action="store_true")
    c.add_argument("--meta", action="append")
    k = sub.add_parser("calibrate")
    k.add_argument("--runs", nargs="+", required=True)
    k.add_argument("--budgets")
    k.add_argument("--margin-pct", type=float, default=2.0)
    k.add_argument("--out", required=True)
    k.add_argument("--meta", action="append")
    p = sub.add_parser("pick-runtime")
    p.add_argument("--min", type=int, default=26)
    s = sub.add_parser("sync")
    s.add_argument("src")
    s.add_argument("dst")
    s.add_argument("--keep", action="append")
    args = parser.parse_args()
    if args.command == "compare":
        return compare(args)
    if args.command == "calibrate":
        return calibrate(args)
    if args.command == "sync":
        return sync(args)
    return pick_runtime(args)


if __name__ == "__main__":
    sys.exit(main())
