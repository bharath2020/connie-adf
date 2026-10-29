#!/usr/bin/env python3
"""Per-trial helpers for Scripts/perf-gate.sh (standard library only; run
with `python3 -I -u`).

SUBCOMMANDS
    launch --log <file> -- <command...>
        Takes t0 (time.time_ns) immediately before spawning <command> (the
        `xcrun simctl launch --console-pty …` invocation) and writes every
        line of its combined stdout/stderr to <file> as
        `<epoch_ns>\\t<line>`, stamped when the line arrives — independent
        of any polling. Header/footer records start with `#`:
            #T0\\t<epoch_ns>
            #CMD\\t<shell-quoted command>
            #EXIT\\t<epoch_ns>\\t<code>
        Exits with the child's status (128+N when killed by signal N).
        SIGTERM/SIGINT are forwarded to the child.

    sample --udid <udid> --exe <name> --out <tsv> [--rss-ms 200]
           [--footprint-ms 1000] [--pid-timeout 90] [--no-footprint]
        Waits for the app's process on that simulator (pgrep on
        `Devices/<udid>/…/<exe>.app/<exe>`), then samples it on two
        independent threads, each on its own fixed schedule and with its own
        timestamps: RSS and %CPU (`ps -o rss=,%cpu=`) every --rss-ms, and
        phys_footprint + phys_footprint_peak (`/usr/bin/footprint`) every
        --footprint-ms. The CPU column tells an app busy during a stall from
        one waiting on something outside it.
        Rows: `<epoch_ns>\\trss\\t<kb>\\t<cpu%>` and
        `<epoch_ns>\\tfootprint\\t<kb>\\t<peak_kb>`; records `#PID`, `#END`.
        Stops when the process disappears or on SIGTERM.

    parse --log <file> --samples <tsv|-> --csv <trials.csv> [--meta k=v]...
        Derives one trial's metrics from the stamped log and the samples and
        appends one row to <trials.csv> (header written when the file is
        new or empty). --meta supplies the driver's columns (run, fixture,
        arm, label, app_sha256, installed_sha256, argv, shell_status,
        requires_completion, …). Prints a one-line digest to stdout.

    host [--top-samples 2]
        Prints one JSON line describing host load: {"load1", "load5",
        "load15", "top": [{"pid", "command", "cpu", "simulator"}, ...]}
        (three busiest processes, `top` itself excluded). With
        --top-samples 2 the CPU figures come from the second of two `top`
        samples (instantaneous, about 1 s); with 0, from `ps` (decayed
        average, cheap: used per trial). `simulator` marks processes of the
        iOS Simulator runtime, which the start check ignores.

LOG LINES CONSUMED (contract with Demo/ADFReader)
    READY fixture=<name> blocks=<n> firstChunkMs=<ms>
    SCROLL_METRICS fixture=<name> frames=<n> dropped=<n> hitchRatioMsPerS=<x>
        [startRow=<i> endRow=<i> scrollMs=<ms> completed=<1|0|true|false>]
    RENDERER_STATS renderer=<swiftui|textkit2> tk2Live=<n> tk2Layouts=<n>
        tk2Draws=<n> tk2NativeDraws=<n> tk1BackedRows=<n> tk1BackedDraws=<n>
        eligibleRoots=<n> fallbackRoots=<n> textFallbackRoots=<n>
        linkRoots=<n> [other k=v...]
        (printed at READY and again with SCROLL_METRICS; the last one wins
        for the counters, the first one is kept as renderer_ready and
        tk2_live_ready; Demo/ADFReader/RendererStats.swift)
"""

from __future__ import annotations

import argparse
import csv
import os
import re
import shlex
import signal
import statistics
import subprocess
import sys
import threading
import time

CSV_COLUMNS = [
    # driver-supplied
    "run", "fixture", "arm", "label", "order_index", "app_sha256", "installed_sha256",
    "argv", "requires_completion", "trial_timeout_s", "shell_status",
    "started_utc", "host_load1", "host_top3",
    # derived
    "status", "launch_exit", "launch_to_ready_ms", "ready_fixture", "first_chunk_ms", "blocks",
    "frames", "dropped_frames", "dropped_rate_pct", "hitch_ms_per_s",
    "start_row", "end_row", "scroll_ms", "completed",
    "renderer", "renderer_ready", "tk2_live_ready", "tk2_live", "tk2_layouts", "tk2_draws",
    "tk2_native_draws", "tk1_backed_rows", "tk1_backed_draws",
    "eligible_roots", "fallback_roots", "text_fallback_roots", "link_roots", "renderer_stats_extra",
    "rss_ready_kb", "rss_peak_kb", "footprint_ready_kb", "footprint_peak_kb",
    "memory_samples", "footprint_samples", "app_cpu_median_pct", "app_cpu_max_pct",
    "rss_interval_ms_median", "rss_interval_ms_max",
    "footprint_interval_ms_median", "footprint_interval_ms_max",
    "trial_wall_ms", "log", "samples",
]
# RENDERER_STATS keys added with the TextKit 1-backed link rows (ebbdb01):
# CSV column -> log key. The summarizer's renderer proof reads these.
STATS_FIELDS = {
    "tk2_native_draws": "tk2NativeDraws",
    "tk1_backed_rows": "tk1BackedRows",
    "tk1_backed_draws": "tk1BackedDraws",
    "text_fallback_roots": "textFallbackRoots",
    "link_roots": "linkRoots",
}
DRIVER_COLUMNS = set(CSV_COLUMNS[:14]) | {"log", "samples"}

# ------------------------------------------------------------------ launch


def cmd_launch(args: argparse.Namespace) -> int:
    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        print("launch: no command given", file=sys.stderr)
        return 2
    with open(args.log, "w", encoding="utf-8", buffering=1) as log:
        t0 = time.time_ns()
        log.write(f"#T0\t{t0}\n")
        log.write(f"#CMD\t{shlex.join(command)}\n")
        proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                stdin=subprocess.DEVNULL)

        def forward(signum, _frame):
            try:
                proc.send_signal(signum)
            except ProcessLookupError:
                pass

        signal.signal(signal.SIGTERM, forward)
        signal.signal(signal.SIGINT, forward)
        assert proc.stdout is not None
        for raw in iter(proc.stdout.readline, b""):
            stamp = time.time_ns()
            line = raw.decode("utf-8", errors="replace").rstrip("\r\n").replace("\r", "")
            log.write(f"{stamp}\t{line}\n")
        code = proc.wait()
        log.write(f"#EXIT\t{time.time_ns()}\t{code}\n")
    return code if code >= 0 else 128 + (-code)


# ------------------------------------------------------------------ sample


def find_pid(udid: str, exe: str) -> int | None:
    pattern = f"Devices/{udid.upper()}/.*/{re.escape(exe)}\\.app/{re.escape(exe)}( |$)"
    try:
        out = subprocess.run(["pgrep", "-f", pattern], capture_output=True, text=True).stdout
    except OSError:
        return None
    pids = [int(p) for p in out.split() if p.isdigit() and int(p) != os.getpid()]
    return pids[0] if pids else None


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


FOOTPRINT_RE = re.compile(r"^\s*(phys_footprint(?:_peak)?):\s*([0-9]+)\s*B", re.M)


def cmd_sample(args: argparse.Namespace) -> int:
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    lock = threading.Lock()
    out = open(args.out, "w", encoding="utf-8", buffering=1)

    def emit(text: str) -> None:
        with lock:
            out.write(text + "\n")

    footprint_bin = "/usr/bin/footprint"
    use_footprint = not args.no_footprint and os.access(footprint_bin, os.X_OK)
    emit(f"#START\t{time.time_ns()}\trss_ms={args.rss_ms}\tfootprint_ms={args.footprint_ms if use_footprint else 'off'}")

    deadline = time.monotonic() + args.pid_timeout
    pid = None
    while not stop.is_set() and time.monotonic() < deadline:
        pid = find_pid(args.udid, args.exe)
        if pid:
            break
        stop.wait(0.05)
    if not pid:
        emit(f"#END\t{time.time_ns()}\tno_pid")
        out.close()
        return 0 if stop.is_set() else 3
    emit(f"#PID\t{time.time_ns()}\t{pid}")

    def schedule(period_s: float, work) -> None:
        next_t = time.monotonic()
        while not stop.is_set():
            if not alive(pid):
                stop.set()
                return
            work()
            next_t += period_s
            delay = next_t - time.monotonic()
            if delay < 0:  # overran: keep the cadence, skip missed slots
                next_t = time.monotonic()
                delay = 0
            stop.wait(delay)

    def rss_once() -> None:
        res = subprocess.run(["ps", "-o", "rss=,%cpu=", "-p", str(pid)], capture_output=True, text=True)
        fields = res.stdout.split()
        if fields and fields[0].isdigit():
            emit(f"{time.time_ns()}\trss\t{fields[0]}\t{fields[1] if len(fields) > 1 else ''}")

    def footprint_once() -> None:
        stamp = time.time_ns()
        res = subprocess.run([footprint_bin, "--noCategories", "--format", "bytes", str(pid)],
                             capture_output=True, text=True)
        found = dict(FOOTPRINT_RE.findall(res.stdout))
        if "phys_footprint" in found:
            peak = found.get("phys_footprint_peak")
            emit(f"{stamp}\tfootprint\t{int(found['phys_footprint']) // 1024}\t"
                 f"{int(peak) // 1024 if peak else ''}")

    threads = [threading.Thread(target=schedule, args=(args.rss_ms / 1000.0, rss_once), daemon=True)]
    if use_footprint:
        threads.append(threading.Thread(target=schedule, args=(args.footprint_ms / 1000.0, footprint_once),
                                        daemon=True))
    for t in threads:
        t.start()
    while not stop.is_set():
        stop.wait(0.1)
    for t in threads:
        t.join(timeout=5)
    emit(f"#END\t{time.time_ns()}\t{'process_exited' if not alive(pid) else 'stopped'}")
    out.close()
    return 0


# -------------------------------------------------------------------- host

SIMULATOR_MARKERS = ("CoreSimulator", "launchd_sim", "Simulator.app", "SimulatorTrampoline", "simctl")


def host_load(top_samples: int) -> dict:
    loads = subprocess.run(["sysctl", "-n", "vm.loadavg"], capture_output=True, text=True).stdout
    values = [float(x) for x in re.findall(r"[0-9]+\.[0-9]+", loads)[:3]]
    top_names: dict[int, str] = {}
    top_busiest: list[tuple[float, int]] = []
    if top_samples > 0:
        out = subprocess.run(["top", "-l", str(top_samples), "-n", "6", "-o", "cpu", "-stats", "pid,command,cpu"],
                             capture_output=True, text=True).stdout
        table = out.split("PID    COMMAND")[-1] if "PID    COMMAND" in out else ""
        for line in table.splitlines()[1:]:
            parts = line.split()
            if len(parts) >= 3 and parts[0].isdigit():
                try:
                    top_busiest.append((float(parts[-1]), int(parts[0])))
                    top_names[int(parts[0])] = " ".join(parts[1:-1])
                except ValueError:
                    pass
    # ps after top, so a process top saw still has a path
    ps = subprocess.run(["ps", "-Ao", "pid=,pcpu=,comm="], capture_output=True, text=True).stdout
    paths: dict[int, str] = {}
    decayed: list[tuple[float, int]] = []
    for line in ps.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and parts[0].isdigit():
            paths[int(parts[0])] = parts[2]
            try:
                decayed.append((float(parts[1]), int(parts[0])))
            except ValueError:
                pass
    busiest = top_busiest if top_samples > 0 else sorted(decayed, reverse=True)
    top = []
    for cpu, pid in busiest:
        command = paths.get(pid) or top_names.get(pid, "?")
        if os.path.basename(command) == "top" or pid == os.getpid():
            continue
        top.append({"pid": pid, "command": command, "cpu": cpu,
                    "simulator": any(m in command for m in SIMULATOR_MARKERS)})
        if len(top) == 3:
            break
    return {"load1": values[0] if values else None, "load5": values[1] if len(values) > 1 else None,
            "load15": values[2] if len(values) > 2 else None, "top": top,
            "cpu_source": f"top -l {top_samples} (last sample)" if top_samples > 0 else "ps pcpu (decayed)"}


def cmd_host(args: argparse.Namespace) -> int:
    import json
    print(json.dumps(host_load(args.top_samples), sort_keys=True))
    return 0


# ------------------------------------------------------------------- parse

KV_RE = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=(\S*)")


def parse_kv(text: str) -> dict[str, str]:
    return dict(KV_RE.findall(text))


def truthy(value: str | None) -> bool:
    return (value or "").strip().lower() in {"1", "true", "yes"}


def read_log(path: str) -> dict:
    info: dict = {"t0": None, "exit": None, "exit_ns": None, "ready": None, "ready_ns": None,
                  "scroll": None, "stats": []}
    try:
        handle = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return info
    with handle:
        for line in handle:
            line = line.rstrip("\n")
            if line.startswith("#T0\t"):
                info["t0"] = int(line.split("\t")[1])
                continue
            if line.startswith("#EXIT\t"):
                _, ns, code = line.split("\t")[:3]
                info["exit_ns"], info["exit"] = int(ns), int(code)
                continue
            if line.startswith("#"):
                continue
            stamp, _, text = line.partition("\t")
            if not stamp.isdigit():
                continue
            text = text.strip()
            if text.startswith("READY ") and info["ready"] is None:
                info["ready"], info["ready_ns"] = parse_kv(text), int(stamp)
            elif text.startswith("SCROLL_METRICS ") and info["scroll"] is None:
                info["scroll"] = parse_kv(text)
            elif text.startswith("RENDERER_STATS "):
                info["stats"].append(parse_kv(text))
    return info


def read_samples(path: str) -> dict:
    rss: list[tuple[int, int]] = []
    cpu: list[tuple[int, float]] = []
    fp: list[tuple[int, int, int | None]] = []
    if path and path != "-" and os.path.exists(path):
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                if line.startswith("#"):
                    continue
                parts = line.rstrip("\n").split("\t")
                if len(parts) < 3 or not parts[0].isdigit() or not parts[2].isdigit():
                    continue
                if parts[1] == "rss":
                    rss.append((int(parts[0]), int(parts[2])))
                    try:
                        cpu.append((int(parts[0]), float(parts[3])))
                    except (IndexError, ValueError):
                        pass
                elif parts[1] == "footprint":
                    peak = int(parts[3]) if len(parts) > 3 and parts[3].isdigit() else None
                    fp.append((int(parts[0]), int(parts[2]), peak))
    return {"rss": rss, "fp": fp, "cpu": cpu}


def intervals(stamps: list[int]) -> tuple[str, str]:
    gaps = [(b - a) / 1e6 for a, b in zip(stamps, stamps[1:])]
    if not gaps:
        return "", ""
    return f"{statistics.median(gaps):.1f}", f"{max(gaps):.1f}"


def num(value: str | None) -> str:
    """A finite number as text, else ''. Negatives pass through; the
    summarizer rejects them (a row is never silently repaired)."""
    if value is None:
        return ""
    try:
        x = float(value)
    except ValueError:
        return ""
    if x != x or x in (float("inf"), float("-inf")):
        return ""
    return value


def derive(log_path: str, samples_path: str, meta: dict[str, str]) -> dict[str, str]:
    info = read_log(log_path)
    samples = read_samples(samples_path)
    row = {c: "" for c in CSV_COLUMNS}
    row.update({k: v for k, v in meta.items() if k in DRIVER_COLUMNS})
    row["log"] = log_path
    row["samples"] = samples_path if samples_path != "-" else ""

    exit_code = info["exit"]
    row["launch_exit"] = "" if exit_code is None else str(exit_code)
    t0 = info["t0"]
    if t0 is not None and info["exit_ns"] is not None:
        row["trial_wall_ms"] = str(round((info["exit_ns"] - t0) / 1e6))

    ready = info["ready"]
    ready_ns = info["ready_ns"]
    if ready is not None and t0 is not None:
        row["launch_to_ready_ms"] = f"{(ready_ns - t0) / 1e6:.1f}"
        row["ready_fixture"] = ready.get("fixture", "")
        row["first_chunk_ms"] = num(ready.get("firstChunkMs"))
        row["blocks"] = num(ready.get("blocks"))

    scroll = info["scroll"]
    if scroll is not None:
        row["frames"] = num(scroll.get("frames"))
        row["dropped_frames"] = num(scroll.get("dropped"))
        row["hitch_ms_per_s"] = num(scroll.get("hitchRatioMsPerS"))
        row["start_row"] = num(scroll.get("startRow"))
        row["end_row"] = num(scroll.get("endRow"))
        row["scroll_ms"] = num(scroll.get("scrollMs"))
        if "completed" in scroll:
            row["completed"] = "1" if truthy(scroll["completed"]) else "0"
        if row["frames"] and row["dropped_frames"] and float(row["frames"]) > 0:
            row["dropped_rate_pct"] = f"{float(row['dropped_frames']) / float(row['frames']) * 100:.3f}"

    if info["stats"]:
        first, last = info["stats"][0], info["stats"][-1]
        row["renderer"] = last.get("renderer", "")
        row["renderer_ready"] = first.get("renderer", "")
        row["tk2_live_ready"] = num(first.get("tk2Live"))
        row["tk2_live"] = num(last.get("tk2Live"))
        row["tk2_layouts"] = num(last.get("tk2Layouts"))
        row["tk2_draws"] = num(last.get("tk2Draws"))
        row["eligible_roots"] = num(last.get("eligibleRoots"))
        row["fallback_roots"] = num(last.get("fallbackRoots"))
        known = {"renderer", "tk2Live", "tk2Layouts", "tk2Draws", "eligibleRoots", "fallbackRoots"}
        for column, key in STATS_FIELDS.items():
            row[column] = num(last.get(key))
            known.add(key)
        row["renderer_stats_extra"] = ";".join(f"{k}={v}" for k, v in last.items() if k not in known)

    rss, fp = samples["rss"], samples["fp"]
    row["memory_samples"] = str(len(rss))
    row["footprint_samples"] = str(len(fp))
    if rss:
        row["rss_peak_kb"] = str(max(v for _, v in rss))
    if fp:
        peaks = [p for _, _, p in fp if p is not None]
        row["footprint_peak_kb"] = str(max(peaks)) if peaks else str(max(v for _, v, _ in fp))
    if ready_ns is not None:
        after = [v for t, v in rss if t >= ready_ns]
        if after:
            row["rss_ready_kb"] = str(after[0])
        after_fp = [v for t, v, _ in fp if t >= ready_ns]
        if after_fp:
            row["footprint_ready_kb"] = str(after_fp[0])
    cpu_values = [v for _, v in samples["cpu"]]
    if cpu_values:
        row["app_cpu_median_pct"] = f"{statistics.median(cpu_values):.1f}"
        row["app_cpu_max_pct"] = f"{max(cpu_values):.1f}"
    row["rss_interval_ms_median"], row["rss_interval_ms_max"] = intervals([t for t, _ in rss])
    row["footprint_interval_ms_median"], row["footprint_interval_ms_max"] = intervals([t for t, _, _ in fp])

    # Status: the driver's verdict on timeouts wins; a nonzero exit is never ok.
    shell_status = meta.get("shell_status", "")
    if shell_status:
        status = shell_status
    elif exit_code is None:
        status = "no_exit"
    elif ready is None:
        status = "crashed" if exit_code != 0 else "no_ready"
    elif exit_code != 0:
        status = "crashed"
    elif scroll is None:
        status = "no_metrics"
    elif truthy(meta.get("requires_completion")) and row["completed"] != "1":
        status = "incomplete"
    else:
        status = "ok"
    row["status"] = status
    return row


def cmd_parse(args: argparse.Namespace) -> int:
    meta = {}
    for item in args.meta or []:
        key, sep, value = item.partition("=")
        if not sep:
            print(f"parse: --meta expects k=v, got {item!r}", file=sys.stderr)
            return 2
        meta[key] = value
    row = derive(args.log, args.samples, meta)
    new = not os.path.exists(args.csv) or os.path.getsize(args.csv) == 0
    with open(args.csv, "a", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=CSV_COLUMNS)
        if new:
            writer.writeheader()
        writer.writerow(row)
    print(f"status={row['status']} exit={row['launch_exit']} ready={row['launch_to_ready_ms']}ms "
          f"firstChunk={row['first_chunk_ms']}ms blocks={row['blocks']} frames={row['frames']} "
          f"dropped={row['dropped_frames']} ({row['dropped_rate_pct']}%) hitch={row['hitch_ms_per_s']} "
          f"completed={row['completed'] or '-'} renderer={row['renderer'] or '-'} "
          f"tk2Layouts={row['tk2_layouts'] or '-'} rss_ready={row['rss_ready_kb']}kB "
          f"rss_peak(sampled)={row['rss_peak_kb']}kB fp_peak={row['footprint_peak_kb']}kB "
          f"samples={row['memory_samples']}/{row['footprint_samples']}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("launch", help="run a command, stamping each output line")
    p.add_argument("--log", required=True)
    p.add_argument("command", nargs=argparse.REMAINDER)
    p.set_defaults(func=cmd_launch)

    p = sub.add_parser("sample", help="sample the app's RSS and phys_footprint")
    p.add_argument("--udid", required=True)
    p.add_argument("--exe", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--rss-ms", type=int, default=200)
    p.add_argument("--footprint-ms", type=int, default=1000)
    p.add_argument("--pid-timeout", type=float, default=90)
    p.add_argument("--no-footprint", action="store_true")
    p.set_defaults(func=cmd_sample)

    p = sub.add_parser("host", help="print host load and the busiest processes as JSON")
    p.add_argument("--top-samples", type=int, default=2)
    p.set_defaults(func=cmd_host)

    p = sub.add_parser("parse", help="derive a trial row and append it to the CSV")
    p.add_argument("--log", required=True)
    p.add_argument("--samples", default="-")
    p.add_argument("--csv", required=True)
    p.add_argument("--meta", action="append")
    p.set_defaults(func=cmd_parse)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
