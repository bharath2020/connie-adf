#!/usr/bin/env python3
"""Trace analysis and verdict for Scripts/perf-instruments.sh (standard
library only; run with `python3 -I`). See docs/Perf-Instruments.md.

SUBCOMMANDS
    analyze --tp <time-profile.xml> --stdout <stdouterr.xml>
            --arm <label> --run <n> [--budget-ms 16.67]
            [--list-window-s SECS]
        Reads one recording's `xctrace export` tables (Time Profiler
        samples and the stdout/stderr instrument's lines) and prints one
        JSON object with the run's metrics, measured over the autoscroll
        window only (launch, document load and exit are excluded).

    reanalyze --dir <results-dir> [--list-window-s SECS] [--keep-exports]
              [--budget-ms 16.67]
        Re-runs `analyze` offline on every recording of an existing
        perf-instruments.sh results folder, re-exporting the tables from
        traces/<arm>-<n>.trace with `xcrun xctrace export` where
        exports/<arm>-<n>.{time-profile,stdout}.xml are missing (the shell
        script drops the large time-profile export after analysis;
        re-exported ones are dropped again unless --keep-exports). Saves
        the old results.jsonl as results.prev.jsonl, rewrites results.jsonl,
        then summary.md / summary.json (base vs cand). Without
        --list-window-s it uses env.txt's "list window:" line, else 0.

    summarize --results <results.jsonl> --base <label> --cand <label>
              [--md <out.md>] [--json <out.json>]
        Takes the median of each metric per arm, compares candidate with
        base against LIMITS, prints a markdown table and an OVERALL line,
        and exits 0 PASS, 1 FAIL, 3 WARN, 2 INVALID.

SCROLL WINDOW
    The demo AutoScroller (Demo/ADFReader/AutoScroller.swift) waits 3 s
    after READY, scrolls the whole document at a fixed 1,200 pt/s, waits
    500 ms, then prints and flushes
        SCROLL_METRICS ... scrollMs=<ms> completed=<0|1>
    The stdout/stderr instrument stamps that line on the trace clock, so
        window = [t(SCROLL_METRICS) - 0.5 s - scrollMs, t(SCROLL_METRICS) - 0.5 s]
    Every ref since PR 1 (86abd56) prints this line; the window needs no
    app change.

METRICS (all from the Time Profiler, main thread, inside the window)
    main_cpu_ms_s      main-thread CPU, ms per second of scroll.
    renderer_cpu_ms_s  main-thread CPU in samples whose backtrace holds a
                       renderer frame leafward of the innermost run-loop
                       frame (the run loop, UIApplicationMain and the app
                       entry sit under every sample): app code (the ADFReader binary,
                       which links ADFRendering/ADFModel statically), TextKit
                       (UIFoundation, NSText* symbols) or SwiftUI
                       (SwiftUI, SwiftUICore, AttributeGraph). Most row
                       work runs inside SwiftUI's graph with no app frame
                       on the stack, so app frames alone undercount it.
    app_code_ms_s / textkit_ms_s
                       the app-code and TextKit shares of the above
                       (diagnostic, report-only).
    hitch_ms_s         trace-derived hitch time: a "busy stretch" is a run
                       of main-thread samples with no gap over 1.5 sample
                       intervals; each stretch longer than the frame budget
                       (16.67 ms, 60 Hz) adds its excess. ms per second.
    longest_hitch_ms   the longest busy stretch.
    hitch_count        stretches over budget.
    app_hitch_ms_s / app_dropped
                       the app's own CADisplayLink figures from
                       SCROLL_METRICS. On a simulator they mostly measure
                       the host (frame delivery), so they are report-only.
    burst_ms_s         main-thread time in busy stretches of >= 12 ms (the
                       whole stretch, not just the excess over a frame), ms
                       per second of scroll. Catches row materialisation
                       bursts such as GitHub issue 10 (TextKit 2 list rows).
    burst8_ms_s        the same for stretches >= 8 ms.
    burst_count        stretches >= 12 ms.
    tk_app_ms_s        main-thread CPU in samples tagged app code OR TextKit.
    list_renderer_ms_s / list_burst_ms_s / list_tk_app_ms_s
                       renderer CPU, burst time (>= 12 ms) and app+TextKit
                       CPU over the first --list-window-s seconds of the
                       scroll window only: perf-mixed's list section (from
                       list-dense) comes first. Absent when the list window
                       is 0 (disabled).

    The Animation Hitches template and the graphics instruments (Hitches,
    Frame Lifetimes, Display, Core Animation FPS) refuse to record on an
    iOS simulator ("Hitches is not supported on this platform"), so the
    hitch figures here come from main-thread CPU stretches. They show
    app work that overruns a frame; they do not see render-server or GPU
    stalls. A physical device would allow the real Hitches instrument.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import subprocess
import sys
import xml.etree.ElementTree as ET

APP_BINARY = "ADFReader"
# Frames every main-thread stack holds; they say nothing about rendering.
APP_ENTRY_SYMBOLS = {"main", "static ADFReaderApp.$main()"}
SWIFTUI_BINARIES = {"SwiftUI", "SwiftUICore", "AttributeGraph"}
TEXTKIT_BINARIES = {"UIFoundation"}
TEXTKIT_SYMBOL = re.compile(r"(^|[\s\[(-])_?NSText")
TAG_APP, TAG_TEXTKIT, TAG_SWIFTUI = 1, 2, 4
# Frames from the run loop outward (UIApplicationMain, SwiftUI's App.main,
# the `main` entry) sit under every main-thread sample; only the frames
# leafward of the innermost run-loop frame say what the callout is doing.
RUNLOOP_SYMBOL = re.compile(r"^_*CFRunLoop")
SCROLL_RE = re.compile(r"SCROLL_METRICS .*?hitchRatioMsPerS=([0-9.]+).*?"
                       r"scrollMs=(\d+).*?completed=(\d)")
DROPPED_RE = re.compile(r"\bdropped=(\d+)")
READY_RE = re.compile(r"^READY fixture=")
SETTLE_NS = 500_000_000
BURST_MS = 12.0
BURST8_MS = 8.0
# The scroll is paced by sleeps, so its length is fixed by the document
# (~30 s for perf-mixed). A run whose window is this much longer than the
# median window was starved by the host (its sleeps overran) and measures
# the host, not the app: it is excluded and reported.
STARVED_FACTOR = 1.2
MIN_RUNS = 2

# Gated metrics: (key, label, unit, kind, warn, fail, gated)
#   kind "rel": limit on (cand - base) / base in percent
#   kind "abs": limit on cand - base in the metric's unit
# Calibrated on main vs main on a busy shared Mac, 2026-11-18; see
# docs/Perf-Instruments.md "Calibration". gated=False metrics are printed
# but never change the verdict.
LIMITS = [
    ("renderer_cpu_ms_s", "Renderer CPU (main thread)", "ms/s", "rel", 8.0, 15.0, True),
    # Report-only: non-renderer main-thread work (UIKit update-cycle
    # scheduling, mach_msg) varied by up to ~22 % within one arm in the
    # 2026-11-20 quiet slot, wider than the fail limit.
    ("main_cpu_ms_s", "Main-thread CPU", "ms/s", "rel", 8.0, 15.0, False),
    ("app_code_ms_s", "  of which app code", "ms/s", "rel", 8.0, 15.0, False),
    ("textkit_ms_s", "  of which TextKit", "ms/s", "rel", 8.0, 15.0, False),
    ("hitch_ms_s", "Hitch time ratio (trace)", "ms/s", "abs", 3.0, 6.0, False),
    ("longest_hitch_ms", "Longest hitch (trace)", "ms", "abs", 20.0, 50.0, False),
    ("hitch_count", "Hitch count (trace)", "", "abs", 10.0, 25.0, False),
    ("app_hitch_ms_s", "App hitch ratio (CADisplayLink)", "ms/s", "abs", 5.0, 10.0, False),
    ("app_dropped", "App dropped frames (CADisplayLink)", "", "abs", 20.0, 40.0, False),
    # Burst and list-window metrics (GitHub issue 10). Report-only with
    # placeholder limits until calibration runs pick the gates.
    ("burst_ms_s", "Burst time, stretches >= 12 ms", "ms/s", "rel", 8.0, 15.0, False),
    ("burst8_ms_s", "Burst time, stretches >= 8 ms", "ms/s", "rel", 8.0, 15.0, False),
    ("burst_count", "Burst count, stretches >= 12 ms", "", "abs", 10.0, 25.0, False),
    ("tk_app_ms_s", "App code + TextKit CPU", "ms/s", "rel", 8.0, 15.0, False),
    ("list_renderer_ms_s", "List window: renderer CPU", "ms/s", "rel", 8.0, 15.0, False),
    ("list_burst_ms_s", "List window: burst time >= 12 ms", "ms/s", "rel", 8.0, 15.0, False),
    ("list_tk_app_ms_s", "List window: app code + TextKit CPU", "ms/s", "rel", 8.0, 15.0, False),
]


def parse_stdout(path):
    """-> (scroll_metrics_time_ns, scrollMs, completed, app_hitch, dropped, ready_ns)"""
    found = None
    ready_ns = None
    ids = {}
    for _, el in ET.iterparse(path, events=("end",)):
        if el.tag != "row":
            continue
        t = text = None
        for c in el:
            if c.tag == "event-time":
                if c.get("ref"):
                    t = ids.get(c.get("ref"))
                else:
                    t = int(c.text)
                    ids[c.get("id")] = t
            elif c.tag == "console-text":
                if c.get("ref"):
                    text = ids.get("txt" + c.get("ref"))
                else:
                    text = c.get("fmt") or (c.text or "")
                    ids["txt" + (c.get("id") or "")] = text
        el.clear()
        if text is None or t is None:
            continue
        if READY_RE.match(text) and ready_ns is None:
            ready_ns = t
        m = SCROLL_RE.search(text)
        if m:
            dropped = DROPPED_RE.search(text)
            found = (t, int(m.group(2)), int(m.group(3)), float(m.group(1)),
                     int(dropped.group(1)) if dropped else None)
    if found is None:
        return None
    return found + (ready_ns,)


def main_thread_samples(path, start_ns, end_ns):
    """-> list of (time_ns, weight_ns, tags) for main-thread samples
    of the target process inside [start_ns, end_ns]."""
    ids = {}
    out = []

    def resolve(el):
        ref = el.get("ref")
        return ids.get(ref) if ref is not None else ids.get(el.get("id"))

    for _, el in ET.iterparse(path, events=("end",)):
        tag = el.tag
        if tag == "binary" and el.get("ref") is None:
            ids[el.get("id")] = el.get("name") or ""
        elif tag == "frame" and el.get("ref") is None:
            binary = el.find("binary")
            bname = resolve(binary) if binary is not None else ""
            name = el.get("name") or ""
            tags = 0
            if bname == APP_BINARY and name not in APP_ENTRY_SYMBOLS:
                tags |= TAG_APP
            if bname in TEXTKIT_BINARIES or TEXTKIT_SYMBOL.search(name):
                tags |= TAG_TEXTKIT
            if bname in SWIFTUI_BINARIES:
                tags |= TAG_SWIFTUI
            ids[el.get("id")] = (tags, bool(RUNLOOP_SYMBOL.search(name)))
        elif tag in ("backtrace", "tagged-backtrace") and el.get("ref") is None:
            tags = 0
            for f in el.findall("frame"):  # leaf first
                ftags, runloop = resolve(f) or (0, False)
                if runloop:
                    break
                tags |= ftags
            ids[el.get("id")] = tags
        elif tag in ("sample-time", "weight", "thread-state") and el.get("ref") is None:
            ids[el.get("id")] = el.text if tag == "thread-state" else int(el.text)
        elif tag == "thread" and el.get("ref") is None:
            ids[el.get("id")] = (el.get("fmt") or "").startswith("Main Thread")
        elif tag == "row":
            t = w = None
            main = False
            tags = 0
            state = "Running"
            for c in el:
                if c.tag == "sample-time":
                    t = resolve(c)
                elif c.tag == "weight":
                    w = resolve(c)
                elif c.tag == "thread":
                    main = bool(resolve(c))
                elif c.tag == "thread-state":
                    state = resolve(c) or "Running"
                elif c.tag in ("backtrace", "tagged-backtrace"):
                    tags = resolve(c) or 0
            el.clear()
            if main and state == "Running" and t is not None and start_ns <= t <= end_ns:
                out.append((t, w or 1_000_000, tags))
    out.sort()
    return out


def stretches(samples):
    """Group samples into busy stretches -> list of durations in ns."""
    if not samples:
        return []
    interval = statistics.median(w for _, w, _ in samples)
    durations = []
    first = prev = samples[0][0]
    prev_w = samples[0][1]
    for t, w, _ in samples[1:]:
        if t - prev > 1.5 * interval:
            durations.append(prev + prev_w - first)
            first = t
        prev, prev_w = t, w
    durations.append(prev + prev_w - first)
    return durations


def cpu(samples, mask, window_s):
    return round(sum(w for _, w, tags in samples if tags & mask) / 1e6 / window_s, 2)


def burst_ms_s(durs, min_ms, window_s):
    floor = min_ms * 1_000_000
    return round(sum(d for d in durs if d >= floor) / 1e6 / window_s, 2)


def analyze_files(tp, stdout, arm, run, budget_ms=16.67, list_window_s=0.0):
    """-> (metrics dict, exit status)"""
    out = {"arm": arm, "run": run}
    sm = parse_stdout(stdout)
    if sm is None:
        out["error"] = "no SCROLL_METRICS line in the trace's stdout table"
        return out, 2
    t_print, scroll_ms, completed, app_hitch, dropped, ready_ns = sm
    end_ns = t_print - SETTLE_NS
    start_ns = end_ns - scroll_ms * 1_000_000
    window_s = scroll_ms / 1000.0
    samples = main_thread_samples(tp, start_ns, end_ns)
    budget_ns = budget_ms * 1_000_000
    durs = stretches(samples)
    over = [d for d in durs if d > budget_ns]
    out.update({
        "completed": completed,
        "window_s": round(window_s, 3),
        "window_start_s": round(start_ns / 1e9, 3),
        # READY + 3 s pre-roll should land at the window start; a large
        # offset means the window estimate is off.
        "ready_offset_s": (round((start_ns - ready_ns) / 1e9 - 3.0, 3)
                           if ready_ns is not None else None),
        "samples": len(samples),
        "main_cpu_ms_s": round(sum(w for _, w, _ in samples) / 1e6 / window_s, 2),
        "renderer_cpu_ms_s": cpu(samples, TAG_APP | TAG_TEXTKIT | TAG_SWIFTUI, window_s),
        "app_code_ms_s": cpu(samples, TAG_APP, window_s),
        "textkit_ms_s": cpu(samples, TAG_TEXTKIT, window_s),
        "hitch_ms_s": round(sum(d - budget_ns for d in over) / 1e6 / window_s, 2),
        "longest_hitch_ms": round(max(durs) / 1e6, 1) if durs else 0.0,
        "hitch_count": len(over),
        "app_hitch_ms_s": app_hitch,
        "app_dropped": dropped,
        # Appended keys (older results.jsonl lack them; summarize shows n/a).
        "burst_ms_s": burst_ms_s(durs, BURST_MS, window_s),
        "burst8_ms_s": burst_ms_s(durs, BURST8_MS, window_s),
        "burst_count": sum(1 for d in durs if d >= BURST_MS * 1_000_000),
        "tk_app_ms_s": cpu(samples, TAG_APP | TAG_TEXTKIT, window_s),
        "list_window_s": round(min(list_window_s, window_s), 3) if list_window_s > 0 else 0,
    })
    if list_window_s > 0:
        lw_s = min(list_window_s, window_s)
        lw_end = start_ns + lw_s * 1e9
        lsamples = [x for x in samples if x[0] <= lw_end]
        ldurs = stretches(lsamples)
        out.update({
            "list_renderer_ms_s": cpu(lsamples, TAG_APP | TAG_TEXTKIT | TAG_SWIFTUI, lw_s),
            "list_burst_ms_s": burst_ms_s(ldurs, BURST_MS, lw_s),
            "list_tk_app_ms_s": cpu(lsamples, TAG_APP | TAG_TEXTKIT, lw_s),
        })
    return out, (0 if completed == 1 else 2)


def analyze(args):
    out, rc = analyze_files(args.tp, args.stdout, args.arm, args.run,
                            args.budget_ms, args.list_window_s)
    print(json.dumps(out))
    return rc


XPATH = '/trace-toc/run[@number="1"]/data/table[@schema="{}"]'


def xctrace_export(trace, schema, dest):
    tmp = dest + ".part"
    with open(tmp, "wb") as f:
        rc = subprocess.run(["xcrun", "xctrace", "export", "--input", trace,
                             "--xpath", XPATH.format(schema)],
                            stdout=f, stderr=subprocess.PIPE).returncode
    if rc != 0:
        os.unlink(tmp)
        raise RuntimeError(f"xctrace export {schema} failed for {trace} (rc {rc})")
    os.replace(tmp, dest)


def env_list_window(path):
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                m = re.match(r"list window:\s*([0-9.]+)", line)
                if m:
                    return float(m.group(1))
    except OSError:
        pass
    return 0.0


def reanalyze(args):
    d = os.path.abspath(args.dir)
    results = os.path.join(d, "results.jsonl")
    lw = (args.list_window_s if args.list_window_s is not None
          else env_list_window(os.path.join(d, "env.txt")))
    runs = []
    if os.path.exists(results):
        with open(results, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    r = json.loads(line)
                    runs.append((r.get("arm"), int(r.get("run", 0))))
    tdir = os.path.join(d, "traces")
    if os.path.isdir(tdir):
        for name in sorted(os.listdir(tdir)):
            m = re.match(r"^(.+)-(\d+)\.trace$", name)
            if m and (m.group(1), int(m.group(2))) not in runs:
                runs.append((m.group(1), int(m.group(2))))
    if not runs:
        print(f"reanalyze: no recordings in {d}", file=sys.stderr)
        return 2
    os.makedirs(os.path.join(d, "exports"), exist_ok=True)
    lines = []
    for arm, run in runs:
        trace = os.path.join(tdir, f"{arm}-{run}.trace")
        tp = os.path.join(d, "exports", f"{arm}-{run}.time-profile.xml")
        so = os.path.join(d, "exports", f"{arm}-{run}.stdout.xml")
        made_tp = False
        try:
            if not os.path.exists(so):
                xctrace_export(trace, "stdouterr-output", so)
            if not os.path.exists(tp):
                xctrace_export(trace, "time-profile", tp)
                made_tp = True
            out, _ = analyze_files(tp, so, arm, run, args.budget_ms, lw)
        except (RuntimeError, OSError, ET.ParseError) as e:
            out = {"arm": arm, "run": run, "error": f"reanalyze failed: {e}"}
        finally:
            if made_tp and not args.keep_exports and os.path.exists(tp):
                os.unlink(tp)
        line = json.dumps(out)
        print(line, file=sys.stderr)
        lines.append(line)
    if os.path.exists(results):
        os.replace(results, os.path.join(d, "results.prev.jsonl"))
    with open(results, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    env = os.path.join(d, "env.txt")
    return summarize(argparse.Namespace(
        results=results, base="base", cand="cand",
        md=os.path.join(d, "summary.md"), json=os.path.join(d, "summary.json"),
        env=env if os.path.exists(env) else None))


def fmt(v, unit):
    if v is None:
        return "–"
    s = f"{v:.1f}" if isinstance(v, float) and abs(v) < 1000 else f"{v:,.0f}" if isinstance(v, (int, float)) else str(v)
    return f"{s} {unit}".rstrip()


def summarize(args):
    rows = []
    with open(args.results, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    by_arm = {args.base: [], args.cand: []}
    errors = []
    starved = []
    done = [r for r in rows if not r.get("error") and r.get("completed") == 1
            and r.get("arm") in by_arm]
    errors = [r for r in rows if r not in done and r.get("arm") in by_arm]
    nominal = statistics.median(r["window_s"] for r in done) if done else 0
    for r in done:
        if r["window_s"] > STARVED_FACTOR * nominal:
            starved.append(r)
        else:
            by_arm[r["arm"]].append(r)
    lines = []
    n_base, n_cand = len(by_arm[args.base]), len(by_arm[args.cand])
    lines.append(f"Runs: {args.base} {n_base}, {args.cand} {n_cand} "
                 f"(median of each; spread = max - min over runs)")
    lines.append("")
    lines.append(f"| Metric | {args.base} | spread | {args.cand} | spread | Δ | warn / fail | Verdict |")
    lines.append("|---|---|---|---|---|---|---|---|")
    worst = "PASS"
    order = {"PASS": 0, "WARN": 1, "FAIL": 2}
    result = {"base": args.base, "cand": args.cand, "metrics": {}, "errors": errors,
              "starved": starved}
    # Fewer than 2 usable runs in an arm leaves no median worth gating on.
    if n_base < MIN_RUNS or n_cand < MIN_RUNS:
        worst = "INVALID"
    for key, label, unit, kind, warn, fail, gated in LIMITS:
        b = [r[key] for r in by_arm[args.base] if r.get(key) is not None]
        c = [r[key] for r in by_arm[args.cand] if r.get(key) is not None]
        if not b or not c:
            lines.append(f"| {label} | – | | – | | | | n/a |")
            continue
        mb, mc = statistics.median(b), statistics.median(c)
        if kind == "rel":
            delta = (mc - mb) / mb * 100 if mb else 0.0
            dtxt = f"{delta:+.1f} %"
            ltxt = f"+{warn:g} % / +{fail:g} %"
        else:
            delta = mc - mb
            dtxt = f"{delta:+.1f} {unit}".rstrip()
            ltxt = f"+{warn:g} / +{fail:g} {unit}".rstrip()
        verdict = "FAIL" if delta > fail else "WARN" if delta > warn else "PASS"
        shown = verdict if gated else f"{verdict.lower()} (report-only)"
        if gated and worst != "INVALID" and order[verdict] > order[worst]:
            worst = verdict
        lines.append(f"| {label} | {fmt(mb, unit)} | {fmt(max(b) - min(b), unit)} "
                     f"| {fmt(mc, unit)} | {fmt(max(c) - min(c), unit)} | {dtxt} "
                     f"| {ltxt} | {shown} |")
        result["metrics"][key] = {"base": b, "cand": c, "base_median": mb,
                                  "cand_median": mc, "delta": delta,
                                  "verdict": verdict, "gated": gated}
    if starved:
        lines.append("")
        lines.append(f"{len(starved)} run(s) excluded as host-starved (scroll window over "
                     f"{STARVED_FACTOR:g} x the {nominal:.1f} s median): "
                     + ", ".join(f"{r['arm']}#{r['run']} ({r['window_s']:.1f} s)" for r in starved))
    if errors:
        lines.append("")
        lines.append(f"{len(errors)} run(s) excluded (incomplete scroll or no metrics): "
                     + ", ".join(f"{e.get('arm')}#{e.get('run')}" for e in errors))
    lines.append("")
    if worst == "INVALID":
        lines.append(f"Fewer than {MIN_RUNS} usable runs in an arm: re-run, ideally on a quieter host.")
    lines.append(f"OVERALL: {worst}")
    result["overall"] = worst
    text = "\n".join(lines)
    print(text)
    if args.md:
        header = ""
        if getattr(args, "env", None):
            # Shas, fixture and each arm's launch args, as an indented block.
            with open(args.env, encoding="utf-8") as f:
                header = "".join("    " + l for l in f) + "\n"
        with open(args.md, "w", encoding="utf-8") as f:
            f.write(header + text + "\n")
    if args.json:
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump(result, f, indent=1)
    return {"PASS": 0, "FAIL": 1, "WARN": 3}.get(worst, 2)


def main(argv):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("analyze")
    a.add_argument("--tp", required=True)
    a.add_argument("--stdout", required=True)
    a.add_argument("--arm", required=True)
    a.add_argument("--run", type=int, required=True)
    a.add_argument("--budget-ms", type=float, default=16.67)
    a.add_argument("--list-window-s", type=float, default=0.0,
                   help="list-section window from the scroll start (0 = off)")
    r = sub.add_parser("reanalyze")
    r.add_argument("--dir", required=True)
    r.add_argument("--list-window-s", type=float, default=None)
    r.add_argument("--budget-ms", type=float, default=16.67)
    r.add_argument("--keep-exports", action="store_true")
    s = sub.add_parser("summarize")
    s.add_argument("--results", required=True)
    s.add_argument("--base", required=True)
    s.add_argument("--cand", required=True)
    s.add_argument("--md")
    s.add_argument("--json")
    s.add_argument("--env", help="env.txt to put at the top of --md")
    args = p.parse_args(argv)
    return {"analyze": analyze, "reanalyze": reanalyze,
            "summarize": summarize}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
