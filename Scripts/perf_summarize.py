#!/usr/bin/env python3
"""Summarize a Scripts/perf-gate.sh trials.csv into a PASS/FAIL verdict.

USAGE
    python3 -I Scripts/perf_summarize.py <trials.csv> [--out summary.md]
        [--json summary.json] [--reference A] [--candidate C]
        [--metrics launch_to_ready_ms,first_chunk_ms,...] [--tolerance-pct 0]
        [--quiet]

    Reads the CSV written by perf-gate.sh (one row per trial; columns listed
    in that script's header comment), prints a Markdown summary to stdout and
    writes it to --out (default: summary.md next to the CSV). --json writes
    the same numbers as JSON.

VERDICT RULE  (per fixture x metric; every gated metric is lower-is-better)
    PASS  candidate median <= reference max   (C's median lies inside A's
          min-max band, or is better than all of A). --tolerance-pct T
          widens the band to reference max * (1 + T/100); default 0.
    FAIL  otherwise
    n/a   fewer than one usable trial on either side (not counted as FAIL)

    Plus one `trial_status` row per fixture: FAIL if the candidate has more
    non-"ok" trials (timeout / no_ready / no_metrics) than the reference.
    Non-"ok" trials are excluded from the numeric statistics.

    Overall: PASS when no (fixture, metric) FAILs and at least one PASSes.

    Only rows with run >= 1 are counted (perf-gate.sh keeps warm-ups in a
    separate warmup.csv anyway). Arm B (candidate without its flag), when
    present, is tabulated with its delta vs A for information; it never
    affects the verdict.

Standard library only; run with `python3 -I`.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import statistics
import sys

DEFAULT_METRICS = [
    "launch_to_ready_ms",
    "first_chunk_ms",
    "dropped_frames",
    "hitch_ms_per_s",
    "rss_ready_kb",
    "rss_peak_kb",
    "footprint_ready_kb",
    "footprint_peak_kb",
]
INFO_METRICS = ["frames", "blocks"]
ARM_ORDER = ["A", "C", "B"]


def to_float(value: str | None) -> float | None:
    if value is None:
        return None
    value = value.strip()
    if value == "":
        return None
    try:
        return float(value)
    except ValueError:
        return None


def load_rows(path: str) -> list[dict]:
    with open(path, newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        rows = list(reader)
    if reader.fieldnames is None or "arm" not in reader.fieldnames:
        raise SystemExit(f"{path}: not a perf-gate CSV (no 'arm' column)")
    counted = []
    for row in rows:
        run = to_float(row.get("run"))
        if run is None or run < 1:
            continue
        counted.append(row)
    return counted


def stats(values: list[float]) -> dict | None:
    if not values:
        return None
    return {
        "n": len(values),
        "median": statistics.median(values),
        "min": min(values),
        "max": max(values),
        "mean": statistics.fmean(values),
    }


def fmt_num(value: float | None) -> str:
    if value is None:
        return "–"
    if abs(value - round(value)) < 1e-9 and abs(value) < 1e12:
        return f"{int(round(value))}"
    return f"{value:.2f}"


def fmt_stats(st: dict | None) -> str:
    if st is None:
        return "n/a (n=0)"
    return f"{fmt_num(st['median'])} ({fmt_num(st['min'])}–{fmt_num(st['max'])}) n={st['n']}"


def fmt_delta(cand: dict | None, ref: dict | None) -> str:
    if cand is None or ref is None:
        return "–"
    delta = cand["median"] - ref["median"]
    sign = "+" if delta >= 0 else "−"
    text = f"{sign}{fmt_num(abs(delta))}"
    if ref["median"] != 0:
        pct = delta / abs(ref["median"]) * 100
        psign = "+" if pct >= 0 else "−"
        text += f" ({psign}{abs(pct):.1f}%)"
    return text


def verdict_for(cand: dict | None, ref: dict | None, tolerance_pct: float = 0.0) -> str:
    if cand is None or ref is None:
        return "n/a"
    limit = ref["max"] * (1 + tolerance_pct / 100.0) if ref["max"] >= 0 else ref["max"]
    return "PASS" if cand["median"] <= limit else "FAIL"


def summarize(
    rows: list[dict], metrics: list[str], ref_arm: str, cand_arm: str, tolerance_pct: float = 0.0
) -> dict:
    fixtures = []
    for row in rows:
        if row["fixture"] not in fixtures:
            fixtures.append(row["fixture"])
    arms = [a for a in ARM_ORDER if any(r["arm"] == a for r in rows)]
    arms += sorted({r["arm"] for r in rows} - set(arms))
    labels = {}
    for row in rows:
        labels.setdefault(row["arm"], row.get("label", "") or row["arm"])

    result = {
        "reference": ref_arm,
        "candidate": cand_arm,
        "arms": arms,
        "labels": labels,
        "metrics": metrics,
        "tolerance_pct": tolerance_pct,
        "fixtures": {},
        "overall": "n/a",
        "fail_count": 0,
        "pass_count": 0,
    }
    for fixture in fixtures:
        frows = [r for r in rows if r["fixture"] == fixture]
        entry: dict = {"metrics": {}, "trial_status": {}}
        # Trial status per arm.
        for arm in arms:
            arows = [r for r in frows if r["arm"] == arm]
            bad = [r for r in arows if (r.get("status") or "") != "ok"]
            entry["trial_status"][arm] = {
                "trials": len(arows),
                "not_ok": len(bad),
                "statuses": sorted({(r.get("status") or "?") for r in bad}),
            }
        ref_bad = entry["trial_status"].get(ref_arm, {}).get("not_ok", 0)
        cand_bad = entry["trial_status"].get(cand_arm, {}).get("not_ok", 0)
        cand_present = cand_arm in entry["trial_status"] and entry["trial_status"][cand_arm]["trials"] > 0
        ref_present = ref_arm in entry["trial_status"] and entry["trial_status"][ref_arm]["trials"] > 0
        if cand_present and ref_present:
            entry["trial_status"]["verdict"] = "FAIL" if cand_bad > ref_bad else "PASS"
        else:
            entry["trial_status"]["verdict"] = "n/a"
        _count(result, entry["trial_status"]["verdict"])

        ok_rows = [r for r in frows if (r.get("status") or "") == "ok"]
        for metric in metrics + INFO_METRICS:
            per_arm = {}
            for arm in arms:
                values = [
                    v for v in (to_float(r.get(metric)) for r in ok_rows if r["arm"] == arm)
                    if v is not None
                ]
                per_arm[arm] = stats(values)
            ref_st = per_arm.get(ref_arm)
            cand_st = per_arm.get(cand_arm)
            gated = metric in metrics
            verdict = verdict_for(cand_st, ref_st, tolerance_pct) if gated else "info"
            deltas = {}
            for arm in arms:
                if arm != ref_arm and per_arm.get(arm) is not None and ref_st is not None:
                    deltas[arm] = per_arm[arm]["median"] - ref_st["median"]
            entry["metrics"][metric] = {
                "arms": per_arm,
                "delta_median": deltas,
                "verdict": verdict,
                "gated": gated,
            }
            if gated:
                _count(result, verdict)
        result["fixtures"][fixture] = entry

    if result["fail_count"] > 0:
        result["overall"] = "FAIL"
    elif result["pass_count"] > 0:
        result["overall"] = "PASS"
    else:
        result["overall"] = "n/a"
    return result


def _count(result: dict, verdict: str) -> None:
    if verdict == "FAIL":
        result["fail_count"] += 1
    elif verdict == "PASS":
        result["pass_count"] += 1


def render_markdown(summary: dict, csv_path: str) -> str:
    ref, cand = summary["reference"], summary["candidate"]
    arms, labels = summary["arms"], summary["labels"]
    lines = []
    lines.append(f"# perf-gate summary — **{summary['overall']}**")
    lines.append("")
    lines.append(f"Source: `{csv_path}`  ")
    arm_desc = ", ".join(f"{a} = {labels.get(a, a)}" for a in arms)
    lines.append(f"Arms: {arm_desc}  ")
    lines.append(
        f"Rule: PASS if median({cand}) ≤ max({ref})"
        + (f" × (1 + {summary['tolerance_pct']:g}%)" if summary["tolerance_pct"] else "")
        + " per fixture × metric (lower is better); FAIL otherwise. "
        f"Gated metrics: {', '.join(summary['metrics'])}. "
        f"Counts: {summary['pass_count']} PASS, {summary['fail_count']} FAIL."
    )
    lines.append("")
    for fixture, entry in summary["fixtures"].items():
        lines.append(f"## {fixture}")
        lines.append("")
        header = ["metric"] + [f"{a} ({labels.get(a, a)}) median (min–max) n" for a in arms]
        header += [f"Δ {a}−{ref}" for a in arms if a != ref]
        header += ["verdict"]
        lines.append("| " + " | ".join(header) + " |")
        lines.append("|" + "|".join(["---"] * len(header)) + "|")
        ts = entry["trial_status"]
        cells = ["trial_status (not ok / trials)"]
        for a in arms:
            info = ts.get(a, {"trials": 0, "not_ok": 0, "statuses": []})
            extra = f" {','.join(info['statuses'])}" if info["statuses"] else ""
            cells.append(f"{info['not_ok']} / {info['trials']}{extra}")
        for a in arms:
            if a != ref:
                ia = ts.get(a, {"not_ok": 0})
                ir = ts.get(ref, {"not_ok": 0})
                cells.append(f"{ia['not_ok'] - ir['not_ok']:+d}")
        cells.append(_badge(ts["verdict"]))
        lines.append("| " + " | ".join(cells) + " |")
        for metric, data in entry["metrics"].items():
            cells = [metric]
            for a in arms:
                cells.append(fmt_stats(data["arms"].get(a)))
            for a in arms:
                if a != ref:
                    cells.append(fmt_delta(data["arms"].get(a), data["arms"].get(ref)))
            cells.append(_badge(data["verdict"]))
            lines.append("| " + " | ".join(cells) + " |")
        lines.append("")
    lines.append(f"**OVERALL: {summary['overall']}**")
    lines.append("")
    return "\n".join(lines)


def _badge(verdict: str) -> str:
    return {"PASS": "PASS", "FAIL": "**FAIL**", "info": "info", "n/a": "n/a"}.get(verdict, verdict)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("csv", help="trials.csv from perf-gate.sh")
    parser.add_argument("--out", help="write Markdown here (default: summary.md next to the CSV)")
    parser.add_argument("--json", dest="json_path", help="also write a JSON summary here")
    parser.add_argument("--reference", default="A", help="reference arm id (default A)")
    parser.add_argument("--candidate", default="C", help="candidate arm id (default C)")
    parser.add_argument(
        "--metrics",
        default=",".join(DEFAULT_METRICS),
        help="comma-separated gated metrics (lower is better); default: " + ",".join(DEFAULT_METRICS),
    )
    parser.add_argument(
        "--tolerance-pct",
        type=float,
        default=0.0,
        help="widen the PASS band to reference max * (1 + T/100); default 0 (strict band)",
    )
    parser.add_argument("--quiet", action="store_true", help="do not print the Markdown to stdout")
    args = parser.parse_args(argv)

    metrics = [m.strip() for m in args.metrics.split(",") if m.strip()]
    rows = load_rows(args.csv)
    if not rows:
        print(f"{args.csv}: no counted trials (run >= 1)", file=sys.stderr)
        return 2
    summary = summarize(rows, metrics, args.reference, args.candidate, args.tolerance_pct)
    markdown = render_markdown(summary, args.csv)

    out_path = args.out or os.path.join(os.path.dirname(os.path.abspath(args.csv)), "summary.md")
    with open(out_path, "w", encoding="utf-8") as handle:
        handle.write(markdown)
    if args.json_path:
        with open(args.json_path, "w", encoding="utf-8") as handle:
            json.dump(summary, handle, indent=2, sort_keys=True)
            handle.write("\n")
    if not args.quiet:
        print(markdown)
    print(f"wrote {out_path}" + (f" and {args.json_path}" if args.json_path else ""), file=sys.stderr)
    return 0 if summary["overall"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
