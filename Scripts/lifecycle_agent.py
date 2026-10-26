#!/usr/bin/env python3
"""Host-side measurement agent for Demo/ADFReaderUITests/LifecycleUITests
(plan §3 quantitative checks), driven by Scripts/lifecycle-gate.sh.
Standard library only; run with `python3 -I -u`.

The UI test cannot rotate the simulator through the Darwin hook, read CPU
or memory of the app process: this agent does it on request. Channel = a
host directory shared through TEST_RUNNER_ADF_LIFECYCLE_DIR. The test writes
`req-<n>.json` (atomically: tmp + rename); the agent answers with
`resp-<n>.json` = {"ok": true, ...} or {"ok": false, "error": "..."}.

REQUESTS ({"kind": ..., params})
    pid                        -> {pid}
    rotate                     -> posts com.connie.adfreader.rotate via
                                  `xcrun simctl spawn <udid> notifyutil -p`
    rejump                     -> posts com.connie.adfreader.rejump (re-land on
                                  the -scrollToFraction block, no animation)
    cpu_settle  threshold_pct=2.0 timeout_s=15
                               -> {settle_s, settled, samples:[[t_s, cpu_pct]]}
                                  CPU from `top -l 2 -s 1 -pid <pid>` (second
                                  sample); settle_s = seconds from the
                                  request until the end of the first 1 s
                                  window at or below threshold_pct
    footprint_settled  threshold_pct=2.0 settle_timeout_s=15 samples=3
                               -> {footprint_kb (median), samples_kb, rss_kb,
                                   cpu_settle}
    soak  seconds=60 threshold_pct=2.0
                               -> {start_kb, end_kb, growth_kb, cpu_mean,
                                   cpu_max, cpu_samples, footprint_series}
                                  start/end are settled footprints
    record  check=<name> pass=<bool> + any fields
                               -> appended to --results (JSON lines)

SUBCOMMANDS
    serve --udid U --channel DIR --results FILE [--log FILE]
    report --results FILE --out lifecycle.md [--meta k=v]...
"""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import statistics
import subprocess
import sys
import time

BUNDLE_EXE = "ADFReader"


def log(handle, text: str) -> None:
    line = f"[{time.strftime('%H:%M:%S')}] {text}"
    print(line, file=handle, flush=True)


def app_pid(udid: str) -> int | None:
    pattern = f"Devices/{udid}/.*/{BUNDLE_EXE}\\.app/{BUNDLE_EXE}( |$)"
    out = subprocess.run(["pgrep", "-f", pattern], capture_output=True, text=True).stdout.split()
    pids = [int(p) for p in out if p.isdigit()]
    return max(pids) if pids else None


TOP_LINE = re.compile(r"^\s*(\d+)\s+([0-9.]+)\s*$")


def cpu_once(pid: int) -> float | None:
    """CPU % of `pid` over a ~1 s window (top's second sample)."""
    res = subprocess.run(["top", "-l", "2", "-s", "1", "-pid", str(pid), "-stats", "pid,cpu"],
                         capture_output=True, text=True)
    values = [float(m.group(2)) for m in (TOP_LINE.match(l) for l in res.stdout.splitlines())
              if m and int(m.group(1)) == pid]
    return values[-1] if len(values) >= 2 else (values[-1] if values else None)


FOOTPRINT = re.compile(r"^\s*phys_footprint:\s*([0-9]+)\s*B", re.M)


def footprint_kb(pid: int) -> int | None:
    res = subprocess.run(["/usr/bin/footprint", "--noCategories", "--format", "bytes", str(pid)],
                         capture_output=True, text=True)
    m = FOOTPRINT.search(res.stdout)
    return int(m.group(1)) // 1024 if m else None


def rss_kb(pid: int) -> int | None:
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return int(out) if out.isdigit() else None


def cpu_settle(pid: int, threshold: float, timeout: float) -> dict:
    start = time.monotonic()
    samples = []
    while time.monotonic() - start < timeout:
        cpu = cpu_once(pid)
        t = round(time.monotonic() - start, 2)
        if cpu is None:
            return {"settled": False, "settle_s": None, "samples": samples, "error": "no CPU sample (app gone?)"}
        samples.append([t, cpu])
        if cpu <= threshold:
            return {"settled": True, "settle_s": t, "samples": samples}
    return {"settled": False, "settle_s": None, "samples": samples}


def footprint_settled(pid: int, threshold: float, settle_timeout: float, count: int) -> dict:
    settle = cpu_settle(pid, threshold, settle_timeout)
    values = []
    for i in range(count):
        if i:
            time.sleep(1.0)
        v = footprint_kb(pid)
        if v is not None:
            values.append(v)
    if not values:
        raise RuntimeError("footprint returned no phys_footprint")
    return {"footprint_kb": int(statistics.median(values)), "samples_kb": values, "rss_kb": rss_kb(pid),
            "cpu_settle": settle}


def soak(pid: int, seconds: float, threshold: float) -> dict:
    start = footprint_settled(pid, threshold, 15, 3)
    t0 = time.monotonic()
    cpu_samples, series = [], []
    while time.monotonic() - t0 < seconds:
        cpu = cpu_once(pid)  # ~1 s
        if cpu is None:
            raise RuntimeError("app disappeared during the soak")
        t = round(time.monotonic() - t0, 1)
        cpu_samples.append([t, cpu])
        if not series or t - series[-1][0] >= 5:
            series.append([t, footprint_kb(pid)])
    end = footprint_settled(pid, threshold, 15, 3)
    cpus = [c for _, c in cpu_samples]
    return {"start_kb": start["footprint_kb"], "end_kb": end["footprint_kb"],
            "growth_kb": end["footprint_kb"] - start["footprint_kb"],
            "cpu_mean": round(statistics.fmean(cpus), 2) if cpus else None,
            "cpu_max": max(cpus) if cpus else None, "cpu_samples": cpu_samples,
            "footprint_series": series, "start": start, "end": end}


def handle(req: dict, args: argparse.Namespace) -> dict:
    kind = req.get("kind")
    if kind == "record":
        entry = dict(req)
        entry.pop("kind", None)
        entry["recorded_utc"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        with open(args.results, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry, sort_keys=True) + "\n")
        return {}
    if kind in ("rotate", "rejump"):
        res = subprocess.run(["xcrun", "simctl", "spawn", args.udid, "notifyutil", "-p",
                              f"com.connie.adfreader.{kind}"], capture_output=True, text=True)
        if res.returncode != 0:
            raise RuntimeError(f"notifyutil failed: {res.stderr.strip()}")
        return {}
    pid = app_pid(args.udid)
    if pid is None:
        raise RuntimeError("ADFReader is not running on the device")
    threshold = float(req.get("threshold_pct", 2.0))
    if kind == "pid":
        return {"pid": pid}
    if kind == "cpu_settle":
        return cpu_settle(pid, threshold, float(req.get("timeout_s", 15)))
    if kind == "footprint_settled":
        return footprint_settled(pid, threshold, float(req.get("settle_timeout_s", 15)), int(req.get("samples", 3)))
    if kind == "soak":
        return soak(pid, float(req.get("seconds", 60)), threshold)
    raise RuntimeError(f"unknown request kind {kind!r}")


def serve(args: argparse.Namespace) -> int:
    os.makedirs(args.channel, exist_ok=True)
    stop = {"flag": False}
    signal.signal(signal.SIGTERM, lambda *_: stop.update(flag=True))
    signal.signal(signal.SIGINT, lambda *_: stop.update(flag=True))
    logf = open(args.log, "a", encoding="utf-8") if args.log else sys.stderr
    log(logf, f"agent serving {args.channel} for {args.udid}")
    done: set[str] = set()
    while not stop["flag"]:
        for name in sorted(os.listdir(args.channel)):
            if not (name.startswith("req-") and name.endswith(".json")) or name in done:
                continue
            done.add(name)
            path = os.path.join(args.channel, name)
            resp_path = os.path.join(args.channel, "resp-" + name[4:])
            try:
                with open(path, encoding="utf-8") as fh:
                    req = json.load(fh)
                log(logf, f"{name}: {json.dumps(req, sort_keys=True)[:300]}")
                resp = {"ok": True, **handle(req, args)}
            except Exception as error:  # report every failure to the test
                resp = {"ok": False, "error": f"{type(error).__name__}: {error}"}
            log(logf, f"{name} -> {json.dumps(resp, sort_keys=True)[:300]}")
            tmp = resp_path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(resp, fh, sort_keys=True)
            os.rename(tmp, resp_path)
        time.sleep(0.1)
    log(logf, "agent stopped")
    return 0


def report(args: argparse.Namespace) -> int:
    entries = []
    if os.path.exists(args.results):
        with open(args.results, encoding="utf-8") as fh:
            entries = [json.loads(l) for l in fh if l.strip()]
    meta = dict(m.split("=", 1) for m in (args.meta or []) if "=" in m)
    lines = ["# Lifecycle checks (plan §3, items 2–6)", ""]
    for k, v in meta.items():
        lines.append(f"- {k}: {v}")
    lines += ["", "| check | verdict | figures |", "|---|---|---|"]
    skip = {"check", "pass", "recorded_utc"}
    for e in entries:
        figures = "; ".join(f"{k}={json.dumps(v) if isinstance(v, (list, dict)) else v}"
                            for k, v in sorted(e.items()) if k not in skip)
        lines.append(f"| {e.get('check')} | {'PASS' if e.get('pass') else '**FAIL**'} | {figures[:900]} |")
    if not entries:
        lines.append("| (no results recorded) | **FAIL** | |")
    lines.append("")
    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
    print(f"wrote {args.out} ({len(entries)} checks)")
    return 0 if entries and all(e.get("pass") for e in entries) else 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("serve")
    p.add_argument("--udid", required=True)
    p.add_argument("--channel", required=True)
    p.add_argument("--results", required=True)
    p.add_argument("--log")
    p.set_defaults(func=serve)
    p = sub.add_parser("report")
    p.add_argument("--results", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--meta", action="append")
    p.set_defaults(func=report)
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
