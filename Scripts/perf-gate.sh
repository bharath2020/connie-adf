#!/usr/bin/env bash
# Scripts/perf-gate.sh — A/B(/C) performance gate for the ADFReader demo app
# on one iOS Simulator: open-to-ready latency, autoscroll dropped frames /
# hitch ratio, and memory (RSS + phys_footprint) for a candidate build
# against a reference build, interleaved trial by trial.
#
# USAGE
#   Scripts/perf-gate.sh --udid <UDID> --app-a <ref ADFReader.app> \
#       --app-c <candidate ADFReader.app> [--app-b <candidate ADFReader.app>] \
#       [--fixtures "kitchen-sink stress-5k giant-table"] [--runs 5] \
#       [--out <dir>] [--label-a main] [--label-c tk2] [--label-b tk1] \
#       [--arm-c-args "-textkit2"] [--extra-args "-fontSizeStep 2"] \
#       [--warmup 1] [--ready-timeout 60] [--trial-timeout 120] \
#       [--sample-ms 200] [--keep-booted] [--bundle-id com.connie.adfreader]
#
#   then:  python3 -I Scripts/perf_summarize.py <out>/trials.csv
#
# ARMS
#   A  reference build (e.g. a Release build of main), launched WITHOUT the
#      candidate flag.
#   C  candidate build launched WITH the candidate flag (default `-textkit2`,
#      see --arm-c-args).
#   B  (optional) candidate build launched WITHOUT the candidate flag — isolates
#      "same binary, old renderer" from "new renderer".
#
# PROCEDURE  (per run 1..N, per fixture, per arm in interleaved order A, C[, B])
#   1. terminate + uninstall + install the arm's .app  (no persisted
#      UserDefaults — e.g. a renderer key — can leak between arms);
#      verify the installed binary's sha256 == the arm's .app sha256.
#   2. `xcrun simctl ui <udid> appearance light`
#   3. launch with `xcrun simctl launch --console-pty <udid> <bundle>
#      -fixture <f> -autoscroll [extra] [arm flags]`, stdout -> per-trial log;
#      the exact command is echoed into the log as `LAUNCH_CMD:` and the
#      script asserts the candidate flag is present for C only.
#   4. poll the log every --sample-ms for `READY fixture=… blocks=…
#      firstChunkMs=…` (launch_to_ready_ms = wall time from just before
#      spawning simctl launch until READY is seen) and sample the app pid's
#      RSS (`ps -o rss=`) and phys_footprint (`/usr/bin/footprint`) until the
#      app exits (the harness calls exit(0) ~2 s after printing
#      `SCROLL_METRICS fixture=… frames=… dropped=… hitchRatioMsPerS=…`)
#      or --trial-timeout elapses.
#   5. append one CSV row (see CSV COLUMNS).
#   One warm-up trial per (fixture, arm) runs first and lands in warmup.csv,
#   not trials.csv.
#
# DEVICE
#   The script never creates a simulator. It boots --udid if it is shut down
#   and shuts it down on exit unless --keep-booted is given.
#
# OUTPUT  (<out>/, default ./perf-gate-<UTC timestamp>)
#   trials.csv    counted trials, one row each
#   warmup.csv    discarded warm-up trials (same columns)
#   env.txt       host/Xcode/runtime/app provenance
#   logs/run<N>-<fixture>-<arm>.log   app stdout (+ LAUNCH_CMD, HITCH lines)
#   samples/run<N>-<fixture>-<arm>.tsv  t_ms  rss_kb  footprint_kb  footprint_peak_kb
#
# CSV COLUMNS
#   run, fixture, arm, label, app_sha256, installed_sha256_ok, argv_ok, status
#   (ok | timeout | no_ready | no_metrics | exited), launch_exit,
#   launch_to_ready_ms, first_chunk_ms, blocks, frames, dropped_frames,
#   hitch_ms_per_s, rss_ready_kb, rss_peak_kb, footprint_ready_kb,
#   footprint_peak_kb, samples, trial_wall_ms, log
#
# Markers come from Demo/ADFReader/ReaderView.swift (READY) and
# Demo/ADFReader/AutoScroller.swift (SCROLL_METRICS, exit(0) 2 s later).
# The script is bash 3.2 compatible (macOS /bin/bash) and needs python3 only
# for the device-state JSON parse and as a timestamp fallback.

set -euo pipefail

# ---------------------------------------------------------------- defaults
UDID=""
APP_A=""; APP_B=""; APP_C=""
LABEL_A="A-ref"; LABEL_B="B-cand-noflag"; LABEL_C="C-cand"
FIXTURES="kitchen-sink stress-5k giant-table"
RUNS=5
WARMUP=1
OUT=""
ARM_C_ARGS="-textkit2"
EXTRA_ARGS=""
READY_TIMEOUT=60
TRIAL_TIMEOUT=120
SAMPLE_MS=200
KEEP_BOOTED=0
BUNDLE_ID="com.connie.adfreader"
FOOTPRINT_BIN="/usr/bin/footprint"

CSV_HEADER="run,fixture,arm,label,app_sha256,installed_sha256_ok,argv_ok,status,launch_exit,launch_to_ready_ms,first_chunk_ms,blocks,frames,dropped_frames,hitch_ms_per_s,rss_ready_kb,rss_peak_kb,footprint_ready_kb,footprint_peak_kb,samples,trial_wall_ms,log"

# ---------------------------------------------------------------- helpers
log() { printf '[perf-gate %s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

# Milliseconds since the epoch. bash >= 5 exposes EPOCHREALTIME (no fork);
# otherwise fall back to python3 (~30 ms fork, identical for every arm).
now_ms() {
    if [ -n "${EPOCHREALTIME:-}" ]; then
        local s="${EPOCHREALTIME%.*}" frac="${EPOCHREALTIME#*.}"
        frac="${frac}000"
        echo $(( s * 1000 + 10#${frac:0:3} ))
    else
        python3 -I -c 'import time; print(int(time.time()*1000))'
    fi
}

# Executable name inside an .app (CFBundleExecutable), default ADFReader.
app_executable() {
    local plist="$1/Info.plist" name=""
    if [ -f "$plist" ]; then
        name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null || true)
    fi
    echo "${name:-ADFReader}"
}

sha256_of_app() {
    local app="$1" exe
    exe=$(app_executable "$app")
    [ -f "$app/$exe" ] || die "no executable at $app/$exe"
    shasum -a 256 "$app/$exe" | awk '{print $1}'
}

# Value of `key=` on the first line of $2 that starts with marker $1, or "".
# Handles PTY \r\n line endings.
marker_field() {
    local marker="$1" key="$2" file="$3"
    tr -d '\r' < "$file" | sed -nE "/^${marker}[[:space:]]/{s/.*[[:space:]]${key}=([^[:space:]]+).*/\1/p;q;}" | head -n 1
}

has_marker() {
    local marker="$1" file="$2"
    tr -d '\r' < "$file" | grep -q -E "^${marker}[[:space:]]"
}

device_state() {
    xcrun simctl list devices -j | python3 -I -c '
import json, sys
want = sys.argv[1].lower()
data = json.load(sys.stdin)
for runtime, devices in data.get("devices", {}).items():
    for dev in devices:
        if dev.get("udid", "").lower() == want:
            print(dev.get("state", "Unknown"))
            print(dev.get("name", "?") + " | " + runtime, file=sys.stderr)
            sys.exit(0)
print("Missing")
' "$1" 2>/dev/null
}

device_description() {
    xcrun simctl list devices -j | python3 -I -c '
import json, sys
want = sys.argv[1].lower()
data = json.load(sys.stdin)
for runtime, devices in data.get("devices", {}).items():
    for dev in devices:
        if dev.get("udid", "").lower() == want:
            print(dev.get("name", "?") + " | " + runtime.rsplit(".", 1)[-1])
            sys.exit(0)
print("unknown device")
' "$1" 2>/dev/null
}

ensure_booted() {
    local state
    state=$(device_state "$UDID")
    case "$state" in
        Booted) log "device $UDID already booted" ;;
        Shutdown)
            log "booting $UDID"
            xcrun simctl boot "$UDID"
            ;;
        Missing) die "no simulator with udid $UDID (the script never creates devices)" ;;
        *) log "device state '$state'; waiting for boot" ;;
    esac
    xcrun simctl bootstatus "$UDID" -b >/dev/null
    log "device booted: $(device_description "$UDID")"
}

# pid of the app's host process on this device, or "".
app_pid() {
    pgrep -f "Devices/${UDID}/.*/${APP_EXE}\.app/${APP_EXE}( |\$)" 2>/dev/null | head -n 1 || true
}

terminate_app() {
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
}

install_arm() {
    local app="$1" expected_sha="$2" container installed_sha
    terminate_app
    xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl install "$UDID" "$app"
    container=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" app)
    installed_sha=$(shasum -a 256 "$container/$APP_EXE" | awk '{print $1}')
    if [ "$installed_sha" = "$expected_sha" ]; then
        echo "yes"
    else
        log "PROVENANCE MISMATCH: installed $installed_sha != expected $expected_sha ($app)"
        echo "no"
    fi
}

csv_escape() {
    local s="$1"
    case "$s" in
        *[,\"]*) s=${s//\"/\"\"}; printf '"%s"' "$s" ;;
        *) printf '%s' "$s" ;;
    esac
}

LAUNCH_PID=""
# One trial: run_trial <run> <fixture> <arm> <app> <label> <sha> <csv> [arm args...]
run_trial() {
    local run="$1" fixture="$2" arm="$3" app="$4" label="$5" sha="$6" csv="$7"
    shift 7
    local stem="run${run}-${fixture}-${arm}"
    local logf="$OUT/logs/$stem.log" samplef="$OUT/samples/$stem.tsv"
    : > "$logf"; printf 't_ms\trss_kb\tfootprint_kb\tfootprint_peak_kb\n' > "$samplef"

    local installed_ok
    installed_ok=$(install_arm "$app" "$sha")
    xcrun simctl ui "$UDID" appearance light >/dev/null 2>&1 || true

    # argv: fixture + autoscroll + user extras + arm-specific flags.
    local -a argv
    argv=(-fixture "$fixture" -autoscroll)
    if [ -n "$EXTRA_ARGS" ]; then
        # shellcheck disable=SC2206  # intentional word splitting of user string
        argv+=($EXTRA_ARGS)
    fi
    if [ "$#" -gt 0 ]; then argv+=("$@"); fi

    local cmd="xcrun simctl launch --console-pty $UDID $BUNDLE_ID ${argv[*]}"
    printf 'LAUNCH_CMD: %s\n' "$cmd" >> "$logf"

    # Self-check: the candidate flag must be in C's argv and in no other arm's.
    local argv_ok="yes" flag
    for flag in $ARM_C_ARGS; do
        case " ${argv[*]} " in
            *" $flag "*) [ "$arm" = "C" ] || argv_ok="no" ;;
            *)           [ "$arm" != "C" ] || argv_ok="no" ;;
        esac
    done
    [ "$argv_ok" = "yes" ] || die "argv self-check failed for arm $arm: $cmd"

    local t0 t_ready="" status="" pid="" launch_exit=""
    local rss rss_ready="" rss_peak=0 fp fp_cur fp_peak fp_ready="" fp_peak_max=0
    local samples=0 sleep_s
    sleep_s=$(awk -v ms="$SAMPLE_MS" 'BEGIN{printf "%.3f", ms/1000}')

    t0=$(now_ms)
    xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID" "${argv[@]}" >> "$logf" 2>&1 &
    LAUNCH_PID=$!

    while :; do
        local now
        now=$(now_ms)
        if [ -z "$pid" ]; then pid=$(app_pid); fi

        if [ -z "$t_ready" ] && has_marker READY "$logf"; then
            t_ready=$now
        fi

        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || true)
            fp_cur=""; fp_peak=""
            if [ -x "$FOOTPRINT_BIN" ]; then
                fp=$("$FOOTPRINT_BIN" --noCategories --format bytes "$pid" 2>/dev/null || true)
                fp_cur=$(printf '%s\n' "$fp" | sed -nE 's/^[[:space:]]*phys_footprint: ([0-9]+) B.*/\1/p' | head -n 1)
                fp_peak=$(printf '%s\n' "$fp" | sed -nE 's/^[[:space:]]*phys_footprint_peak: ([0-9]+) B.*/\1/p' | head -n 1)
                [ -n "$fp_cur" ] && fp_cur=$(( fp_cur / 1024 ))
                [ -n "$fp_peak" ] && fp_peak=$(( fp_peak / 1024 ))
            fi
            if [ -n "$rss" ]; then
                samples=$(( samples + 1 ))
                printf '%s\t%s\t%s\t%s\n' "$(( now - t0 ))" "$rss" "$fp_cur" "$fp_peak" >> "$samplef"
                [ "$rss" -gt "$rss_peak" ] && rss_peak=$rss
                if [ -n "$t_ready" ] && [ -z "$rss_ready" ]; then rss_ready=$rss; fi
                if [ -n "$fp_peak" ] && [ "$fp_peak" -gt "$fp_peak_max" ]; then fp_peak_max=$fp_peak; fi
                if [ -n "$t_ready" ] && [ -z "$fp_ready" ] && [ -n "$fp_cur" ]; then fp_ready=$fp_cur; fi
            fi
        fi

        # simctl launch (console-pty) exits when the app exits.
        if ! kill -0 "$LAUNCH_PID" 2>/dev/null; then break; fi
        if [ $(( now - t0 )) -ge $(( TRIAL_TIMEOUT * 1000 )) ]; then
            status="timeout"; log "$stem: trial timeout after ${TRIAL_TIMEOUT}s"
            terminate_app; sleep 1
            kill "$LAUNCH_PID" 2>/dev/null || true
            break
        fi
        if [ -z "$t_ready" ] && [ $(( now - t0 )) -ge $(( READY_TIMEOUT * 1000 )) ]; then
            status="no_ready"; log "$stem: no READY within ${READY_TIMEOUT}s"
            terminate_app; sleep 1
            kill "$LAUNCH_PID" 2>/dev/null || true
            break
        fi
        sleep "$sleep_s"
    done
    if wait "$LAUNCH_PID" 2>/dev/null; then launch_exit=0; else launch_exit=$?; fi
    LAUNCH_PID=""
    local t_end
    t_end=$(now_ms)

    # Late READY (seen after the loop ended, e.g. app exited between polls).
    if [ -z "$t_ready" ] && has_marker READY "$logf"; then t_ready=$t_end; fi

    local launch_to_ready="" first_chunk="" blocks="" frames="" dropped="" hitch=""
    if [ -n "$t_ready" ]; then
        launch_to_ready=$(( t_ready - t0 ))
        first_chunk=$(marker_field READY firstChunkMs "$logf")
        blocks=$(marker_field READY blocks "$logf")
    fi
    if has_marker SCROLL_METRICS "$logf"; then
        frames=$(marker_field SCROLL_METRICS frames "$logf")
        dropped=$(marker_field SCROLL_METRICS dropped "$logf")
        hitch=$(marker_field SCROLL_METRICS hitchRatioMsPerS "$logf")
    fi
    if [ -z "$status" ]; then
        if [ -z "$t_ready" ]; then status="no_ready"
        elif [ -z "$dropped" ]; then status="no_metrics"
        else status="ok"; fi
    fi
    [ "$rss_peak" -gt 0 ] || rss_peak=""
    [ "$fp_peak_max" -gt 0 ] || fp_peak_max=""

    log "$stem: status=$status ready=${launch_to_ready}ms firstChunk=${first_chunk}ms dropped=${dropped} hitch=${hitch} rss_peak=${rss_peak}kB fp_peak=${fp_peak_max}kB samples=$samples"

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$run" "$(csv_escape "$fixture")" "$arm" "$(csv_escape "$label")" "$sha" \
        "$installed_ok" "$argv_ok" "$status" "$launch_exit" \
        "$launch_to_ready" "$first_chunk" "$blocks" "$frames" "$dropped" "$hitch" \
        "$rss_ready" "$rss_peak" "$fp_ready" "$fp_peak_max" "$samples" "$(( t_end - t0 ))" \
        "$(csv_escape "$logf")" >> "$csv"
}

cleanup() {
    local rc=$?
    trap - EXIT
    if [ -n "${LAUNCH_PID:-}" ]; then kill "$LAUNCH_PID" 2>/dev/null || true; fi
    if [ -n "${UDID:-}" ] && [ -n "${DEVICE_READY:-}" ]; then
        terminate_app
        if [ "$KEEP_BOOTED" -eq 0 ]; then
            log "shutting down $UDID"
            xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
        fi
    fi
    exit "$rc"
}

# ---------------------------------------------------------------- main
main() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --udid) UDID="$2"; shift 2 ;;
            --app-a) APP_A="$2"; shift 2 ;;
            --app-b) APP_B="$2"; shift 2 ;;
            --app-c) APP_C="$2"; shift 2 ;;
            --label-a) LABEL_A="$2"; shift 2 ;;
            --label-b) LABEL_B="$2"; shift 2 ;;
            --label-c) LABEL_C="$2"; shift 2 ;;
            --fixtures) FIXTURES="$2"; shift 2 ;;
            --runs) RUNS="$2"; shift 2 ;;
            --warmup) WARMUP="$2"; shift 2 ;;
            --out) OUT="$2"; shift 2 ;;
            --arm-c-args) ARM_C_ARGS="$2"; shift 2 ;;
            --extra-args) EXTRA_ARGS="$2"; shift 2 ;;
            --ready-timeout) READY_TIMEOUT="$2"; shift 2 ;;
            --trial-timeout) TRIAL_TIMEOUT="$2"; shift 2 ;;
            --sample-ms) SAMPLE_MS="$2"; shift 2 ;;
            --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
            --keep-booted) KEEP_BOOTED=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "unknown option: $1 (see --help)" ;;
        esac
    done
    [ -n "$UDID" ] || die "--udid is required"
    [ -n "$APP_A" ] && [ -d "$APP_A" ] || die "--app-a <ADFReader.app> is required"
    [ -n "$APP_C" ] && [ -d "$APP_C" ] || die "--app-c <ADFReader.app> is required"
    if [ -n "$APP_B" ]; then [ -d "$APP_B" ] || die "--app-b: not a directory: $APP_B"; fi
    [ "$RUNS" -ge 1 ] 2>/dev/null || die "--runs must be >= 1"
    command -v xcrun >/dev/null || die "xcrun not found"
    command -v python3 >/dev/null || die "python3 not found"
    [ -n "$OUT" ] || OUT="./perf-gate-$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$OUT/logs" "$OUT/samples"
    OUT=$(cd "$OUT" && pwd)

    APP_EXE=$(app_executable "$APP_C")
    local sha_a sha_c sha_b=""
    sha_a=$(sha256_of_app "$APP_A")
    sha_c=$(sha256_of_app "$APP_C")
    [ -z "$APP_B" ] || sha_b=$(sha256_of_app "$APP_B")
    [ "$sha_a" != "$sha_c" ] || log "WARNING: app-a and app-c have the same binary sha256"

    {
        echo "date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "host=$(hostname) $(sw_vers -productVersion 2>/dev/null || true) $(uname -m)"
        echo "xcodebuild=$(xcodebuild -version 2>/dev/null | tr '\n' ' ')"
        echo "udid=$UDID"
        echo "device=$(device_description "$UDID")"
        echo "bundle_id=$BUNDLE_ID"
        echo "fixtures=$FIXTURES"
        echo "runs=$RUNS warmup=$WARMUP sample_ms=$SAMPLE_MS ready_timeout=$READY_TIMEOUT trial_timeout=$TRIAL_TIMEOUT"
        echo "arm_c_args=$ARM_C_ARGS"
        echo "extra_args=$EXTRA_ARGS"
        echo "footprint=$([ -x "$FOOTPRINT_BIN" ] && echo "$FOOTPRINT_BIN" || echo unavailable)"
        echo "A label=$LABEL_A app=$APP_A sha256=$sha_a"
        echo "C label=$LABEL_C app=$APP_C sha256=$sha_c"
        [ -z "$APP_B" ] || echo "B label=$LABEL_B app=$APP_B sha256=$sha_b"
    } > "$OUT/env.txt"
    log "output: $OUT"
    cat "$OUT/env.txt" >&2

    trap cleanup EXIT INT TERM
    ensure_booted
    DEVICE_READY=1

    local trials="$OUT/trials.csv" warm="$OUT/warmup.csv"
    echo "$CSV_HEADER" > "$trials"
    echo "$CSV_HEADER" > "$warm"

    # shellcheck disable=SC2206
    local -a c_args=($ARM_C_ARGS)

    # Interleaved arms per fixture: A, C[, B]. One row per trial.
    run_arms() {
        local run="$1" fixture="$2" csv="$3"
        run_trial "$run" "$fixture" A "$APP_A" "$LABEL_A" "$sha_a" "$csv"
        run_trial "$run" "$fixture" C "$APP_C" "$LABEL_C" "$sha_c" "$csv" "${c_args[@]}"
        if [ -n "$APP_B" ]; then
            run_trial "$run" "$fixture" B "$APP_B" "$LABEL_B" "$sha_b" "$csv"
        fi
    }

    local w fixture run
    w=0
    while [ "$w" -lt "$WARMUP" ]; do
        for fixture in $FIXTURES; do
            log "warm-up $((w + 1))/$WARMUP fixture=$fixture"
            run_arms 0 "$fixture" "$warm"
        done
        w=$(( w + 1 ))
    done

    run=1
    while [ "$run" -le "$RUNS" ]; do
        for fixture in $FIXTURES; do
            log "run $run/$RUNS fixture=$fixture"
            run_arms "$run" "$fixture" "$trials"
        done
        run=$(( run + 1 ))
    done

    log "done: $trials"
    if [ -f "$(dirname "$0")/perf_summarize.py" ]; then
        python3 -I "$(dirname "$0")/perf_summarize.py" "$trials" --out "$OUT/summary.md" --json "$OUT/summary.json" || true
    fi
}

if [ "${PERF_GATE_SOURCED:-0}" != "1" ]; then
    main "$@"
fi
