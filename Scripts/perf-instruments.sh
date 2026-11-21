#!/bin/bash
# Scripts/perf-instruments.sh — Instruments (xctrace) profile check on a
# simulator: base ref vs candidate ref on one mixed, performance-heavy
# document. Usage, metrics, limits and calibration: docs/Perf-Instruments.md.
#
# USAGE
#   Scripts/perf-instruments.sh [options] <base-ref> <candidate-ref>
#
#   --runs N            recordings per arm, interleaved (default 3)
#   --fixture NAME      Fixtures/<NAME>.json (default perf-mixed)
#   --app-args "ARGS"   extra launch arguments for both arms, e.g. "-textkit2"
#   --base-args "ARGS"  extra launch arguments for the base arm only, after
#   --cand-args "ARGS"  --app-args (and likewise for the candidate arm). One
#                       build with TextKit 2 off vs on:
#                         --cand-args -textkit2 a76736f a76736f
#   --list-window-s S   also measure the first S seconds of the scroll window
#                       on their own (list_* metrics): perf-mixed's dense
#                       list section comes first and scrolls for ~31 s.
#                       Default 28 for perf-mixed, 0 (off) for other fixtures
#   --out DIR           results folder (default: a new folder under
#                       ${TMPDIR}perf-instruments/)
#   --cache DIR         built apps, one per commit (default:
#                       ~/Library/Caches/connie-adf-perf-instruments)
#   --udid UDID         use this simulator instead of creating one; it is
#                       never deleted, and shut down at the end only if the
#                       script booted it (never pass someone else's device)
#   --sim-name NAME     reuse the simulator called NAME, creating it on first
#                       use, and keep it afterwards (shut down if the script
#                       booted it). A brand-new simulator spends minutes on
#                       first-boot work, so repeat runs are much faster with
#                       a kept device; give each lane its own NAME.
#   --keep-sim          keep the simulator the script created
#   --time-limit SECS   per-recording cap (default 300)
#   --busy-wait SECS    longest wait for another lane's perf-gate.sh /
#                       perf_trial.py frame run to finish before each
#                       recording (default 1800; then exit 2)
#   --build-only        build (or find cached) apps for both refs and stop
#
# WHAT IT DOES
#   1. Builds each ref once — Release, simulator, unsigned, from a clean
#      `git archive` export, never the working tree — and caches the .app
#      by commit sha. Refs that predate the fixture still work: the
#      candidate tree's Fixtures/<NAME>.json (or the working tree's, when
#      the candidate lacks it) is copied into BOTH .app bundles, so the two
#      arms always scroll the same bytes.
#   2. Creates its own simulator (iPhone 17 Pro, newest iOS runtime that
#      supports it), boots it and deletes it on exit (or reuses --udid /
#      --sim-name). Warm-up: each app is launched until it prints READY,
#      then one traced base run is recorded and discarded.
#   3. Per run, alternating base,cand / cand,base: reinstalls the arm's
#      app, then `xctrace record --template 'Time Profiler' --instrument
#      'stdout/stderr' --launch -- <bundle> -fixture <NAME> -autoscroll
#      <app-args> <arm-args>` (warm-up launches use the same arm args).
#      The demo AutoScroller scrolls the document once at 1,200 pt/s and
#      the app exits, which ends the recording.
#   4. Exports the time-profile and stdout tables and has
#      Scripts/perf_instruments.py measure the scroll window, then prints
#      the base/candidate table and the verdict. The time-profile export is
#      dropped after analysis; `perf_instruments.py reanalyze --dir <out>`
#      re-exports it from traces/ to re-run the analysis offline.
#
# OUTPUT (<out>/)
#   summary.md / summary.json   table and verdict
#   results.jsonl               one line of metrics per recording
#   env.txt                     shas, fixture sha, each arm's launch args,
#                               list window, device, Xcode, load, timings
#   traces/<arm>-<n>.trace      open in Instruments to dig in
#   logs/                       xctrace and build logs
#
# EXIT  0 PASS, 1 FAIL, 3 WARN, 2 INVALID / usage / driver error.
#
# Simulator only: the Animation Hitches template and the graphics
# instruments refuse to record on an iOS simulator, so hitch figures are
# derived from main-thread Time Profiler samples (see perf_instruments.py).
#
# bash 3.2 compatible (macOS /bin/bash); needs xcrun, xcodegen, python3.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
ANALYZE_PY="$SCRIPT_DIR/perf_instruments.py"
# shellcheck source=lib/sim.sh
. "$SCRIPT_DIR/lib/sim.sh"

RUNS=3
FIXTURE="perf-mixed"
APP_ARGS=""
BASE_ARGS=""
CAND_ARGS=""
LIST_WINDOW_S=""
OUT=""
CACHE="$HOME/Library/Caches/connie-adf-perf-instruments"
UDID=""
SIM_NAME=""
KEEP_SIM=0
TIME_LIMIT=300
BUSY_WAIT=1800
BUILD_ONLY=0
DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"

usage() { sed -n '2,/^# bash 3.2/p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
die() { echo "perf-instruments: $*" >&2; exit 2; }
now() { date +%s; }
say() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --runs) RUNS="$2"; shift 2 ;;
        --fixture) FIXTURE="$2"; shift 2 ;;
        --app-args) APP_ARGS="$2"; shift 2 ;;
        --base-args) BASE_ARGS="$2"; shift 2 ;;
        --cand-args) CAND_ARGS="$2"; shift 2 ;;
        --list-window-s) LIST_WINDOW_S="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --cache) CACHE="$2"; shift 2 ;;
        --udid) UDID="$2"; shift 2 ;;
        --sim-name) SIM_NAME="$2"; shift 2 ;;
        --keep-sim) KEEP_SIM=1; shift ;;
        --time-limit) TIME_LIMIT="$2"; shift 2 ;;
        --busy-wait) BUSY_WAIT="$2"; shift 2 ;;
        --build-only) BUILD_ONLY=1; shift ;;
        -h|--help) usage ;;
        -*) die "unknown option $1 (see --help)" ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done
[[ ${#POSITIONAL[@]} -eq 2 ]] || usage
[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || die "--runs must be a positive integer"
if [[ -z "$LIST_WINDOW_S" ]]; then
    # Tools/make-perf-mixed.py LIST_WINDOW_S: the list section's ~31 s of
    # scroll, less a margin so the mixed sections' rows are not counted.
    if [[ "$FIXTURE" == "perf-mixed" ]]; then LIST_WINDOW_S=28; else LIST_WINDOW_S=0; fi
fi
[[ "$LIST_WINDOW_S" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--list-window-s must be a number of seconds"
BASE_ARGV="$APP_ARGS${BASE_ARGS:+ $BASE_ARGS}"
CAND_ARGV="$APP_ARGS${CAND_ARGS:+ $CAND_ARGS}"
BASE_REF="${POSITIONAL[0]}"
CAND_REF="${POSITIONAL[1]}"

BASE_SHA="$(git -C "$REPO" rev-parse --verify --quiet "$BASE_REF^{commit}")" \
    || die "unknown ref $BASE_REF"
CAND_SHA="$(git -C "$REPO" rev-parse --verify --quiet "$CAND_REF^{commit}")" \
    || die "unknown ref $CAND_REF"

T_START="$(now)"
if [[ -z "$OUT" ]]; then
    OUT="${TMPDIR:-/tmp/}perf-instruments/$(date +%Y%m%d-%H%M%S)-${BASE_SHA:0:7}-${CAND_SHA:0:7}"
fi
mkdir -p "$OUT/traces" "$OUT/logs" "$OUT/exports" "$CACHE"
OUT="$(cd "$OUT" && pwd)"
CACHE="$(cd "$CACHE" && pwd)"

# ------------------------------------------------------------------ fixture
FIXTURE_FILE="$OUT/$FIXTURE.json"
if git -C "$REPO" cat-file -e "$CAND_SHA:Fixtures/$FIXTURE.json" 2>/dev/null; then
    git -C "$REPO" show "$CAND_SHA:Fixtures/$FIXTURE.json" > "$FIXTURE_FILE"
    FIXTURE_SRC="$CAND_REF:Fixtures/$FIXTURE.json"
elif [[ -f "$REPO/Fixtures/$FIXTURE.json" ]]; then
    cp "$REPO/Fixtures/$FIXTURE.json" "$FIXTURE_FILE"
    FIXTURE_SRC="working tree Fixtures/$FIXTURE.json"
else
    die "no Fixtures/$FIXTURE.json in $CAND_REF or the working tree"
fi
FIXTURE_SHA="$(shasum -a 256 "$FIXTURE_FILE" | cut -c1-12)"

# ------------------------------------------------------------------ builds
# build_app <sha> -> path of the cached .app (without the fixture).
build_app() {
    local sha="$1" dir="$CACHE/$1" src dd stage log t0
    if [[ -x "$dir/ADFReader.app/ADFReader" ]]; then
        echo "$dir/ADFReader.app"; return 0
    fi
    src="$CACHE/src-$sha.$$"
    dd="$CACHE/dd-$sha.$$"
    stage="$CACHE/stage-$sha.$$"
    log="$OUT/logs/build-${sha:0:7}.log"
    t0="$(now)"
    say "building ${sha:0:7} (Release, simulator; log $log)" >&2
    mkdir -p "$src"
    git -C "$REPO" archive "$sha" | tar -x -C "$src"
    ( cd "$src/Demo" && xcodegen generate ) > "$log" 2>&1 \
        || { tail -20 "$log" >&2; die "xcodegen failed for ${sha:0:7}"; }
    xcodebuild build -project "$src/Demo/ADFReader.xcodeproj" -scheme ADFReader \
        -configuration Release -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "$dd" ARCHS=arm64 \
        CODE_SIGNING_ALLOWED=NO >> "$log" 2>&1 \
        || { tail -30 "$log" >&2; die "build failed for ${sha:0:7}"; }
    rm -rf "$stage"
    mkdir -p "$stage"
    ditto "$dd/Build/Products/Release-iphonesimulator/ADFReader.app" \
        "$stage/ADFReader.app"
    shasum -a 256 "$stage/ADFReader.app/ADFReader" | cut -d' ' -f1 > "$stage/sha256.txt"
    [[ -x "$dir/ADFReader.app/ADFReader" ]] || rm -rf "$dir"
    python3 -c 'import os, sys; os.rename(sys.argv[1], sys.argv[2])' "$stage" "$dir" \
        2>/dev/null || rm -rf "$stage"
    echo "build ${sha:0:7}: $(( $(now) - t0 ))s" >> "$OUT/logs/timings.txt"
    say "built ${sha:0:7} in $(( $(now) - t0 ))s" >&2
    # The export and derived data are only needed to build; the .app is cached.
    rm -rf "$src" "$dd"
    echo "$dir/ADFReader.app"
}

T_BUILD="$(now)"
BASE_CACHED="$(build_app "$BASE_SHA")"
CAND_CACHED="$(build_app "$CAND_SHA")"
BUILD_S=$(( $(now) - T_BUILD ))

# Per-arm copies with the shared fixture injected (an unsigned simulator
# app reads bundle resources without a signature check). The cache is keyed
# by sha, so equal base and candidate refs share one build but still get
# their own copies here.
APP_BASE="$OUT/apps/base/ADFReader.app"
APP_CAND="$OUT/apps/cand/ADFReader.app"
for pair in "$BASE_CACHED:$APP_BASE" "$CAND_CACHED:$APP_CAND"; do
    mkdir -p "$(dirname "${pair#*:}")"
    ditto "${pair%%:*}" "${pair#*:}"
    cp "$FIXTURE_FILE" "${pair#*:}/$FIXTURE.json"
done
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP_CAND/Info.plist")"
[[ "$BUILD_ONLY" -eq 1 ]] && { say "apps ready: $APP_BASE $APP_CAND"; exit 0; }

# ---------------------------------------------------------------- simulator
CREATED_SIM=0
BOOTED_SIM=0
cleanup() {
    local rc=$?
    if [[ -n "$UDID" ]]; then
        xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
        if [[ "$CREATED_SIM" -eq 1 && "$KEEP_SIM" -eq 0 ]]; then
            xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
            xcrun simctl delete "$UDID" >/dev/null 2>&1 || true
        elif [[ "$BOOTED_SIM" -eq 1 ]]; then
            xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
        fi
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

if [[ -z "$UDID" && -n "$SIM_NAME" ]]; then
    UDID="$(xcrun simctl list devices -j | python3 -I -c '
import json, sys
for devices in json.load(sys.stdin).get("devices", {}).values():
    for d in devices:
        if d.get("name") == sys.argv[1] and d.get("isAvailable", True):
            print(d["udid"]); sys.exit(0)
' "$SIM_NAME")"
    [[ -z "$UDID" ]] || say "reusing simulator $SIM_NAME ($UDID)"
fi
if [[ -z "$UDID" ]]; then
    RUNTIME="$(xcrun simctl list runtimes -j | python3 -I -c '
import json, sys
want = sys.argv[1]
best = None
for r in json.load(sys.stdin)["runtimes"]:
    if not r.get("isAvailable") or r.get("platform") != "iOS":
        continue
    if want not in [t["identifier"] for t in r.get("supportedDeviceTypes", [])]:
        continue
    key = tuple(int(x) for x in r["version"].split("."))
    if best is None or key > best[0]:
        best = (key, r["identifier"])
print(best[1] if best else "")
' "$DEVICE_TYPE")"
    [[ -n "$RUNTIME" ]] || die "no iOS runtime supports $DEVICE_TYPE"
    UDID="$(xcrun simctl create "${SIM_NAME:-adf-perf-instruments-$$}" "$DEVICE_TYPE" "$RUNTIME")"
    # A named device is meant to be reused: keep it.
    [[ -z "$SIM_NAME" ]] || KEEP_SIM=1
    CREATED_SIM=1
    say "created simulator $UDID ($RUNTIME)"
fi
if [[ "$(sim_device_field "$UDID" state)" != "Booted" ]]; then
    xcrun simctl boot "$UDID"
    BOOTED_SIM=1
fi
# bootstatus can hang on a loaded host; cap it, then let the device settle.
xcrun simctl bootstatus "$UDID" -b > "$OUT/logs/bootstatus.log" 2>&1 &
BS_PID=$!
for _ in $(seq 1 300); do kill -0 "$BS_PID" 2>/dev/null || break; sleep 1; done
kill "$BS_PID" 2>/dev/null || true
wait "$BS_PID" 2>/dev/null || true
[[ "$(sim_device_field "$UDID" state)" == "Booted" ]] || die "simulator $UDID did not boot"
xcrun simctl ui "$UDID" appearance light
sleep 20

# ---------------------------------------------------------------- recording
wait_for_frame_runs() {
    local waited=0
    while pgrep -f 'perf-gate\.sh|perf_trial\.py' >/dev/null 2>&1; do
        if [[ "$waited" -eq 0 ]]; then
            say "another lane's perf-gate.sh / perf_trial.py frame run is active; waiting"
        fi
        [[ "$waited" -lt "$BUSY_WAIT" ]] || die "frame run still active after ${BUSY_WAIT}s"
        sleep 30
        waited=$(( waited + 30 ))
    done
    [[ "$waited" -eq 0 ]] || echo "waited ${waited}s for a frame run" >> "$OUT/logs/timings.txt"
}

install_arm() {
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl install "$UDID" "$1"
}

# Untraced launch until the document is READY (a cold simulator can take
# minutes), so first-launch caches (fonts, shaders, dyld) are warm.
# warm_up <app> <arm> <launch args>
# shellcheck disable=SC2086
warm_up() {
    local log="$OUT/logs/warmup-$2.log" pid waited=0
    install_arm "$1"
    xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID" -fixture "$FIXTURE" \
        $3 > "$log" 2>&1 &
    pid=$!
    while ! grep -q '^READY fixture=' "$log" 2>/dev/null; do
        kill -0 "$pid" 2>/dev/null || break
        [[ "$waited" -lt 900 ]] || break
        sleep 1
        waited=$(( waited + 1 ))
    done
    sleep 2
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    sleep 1
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    grep -q '^READY fixture=' "$log" || die "warm-up: $2 app never printed READY (see $log)"
}

# record <arm> <run> <app> <launch args>
# shellcheck disable=SC2086
record() {
    local arm="$1" run="$2" app="$3" argv="$4" trace log t0 rc=0
    trace="$OUT/traces/$arm-$run.trace"
    log="$OUT/logs/$arm-$run.xctrace.log"
    local attempt
    for attempt in 1 2 3 4 5 6; do
        wait_for_frame_runs
        install_arm "$app"
        t0="$(now)"
        rc=0
        rm -rf "$trace"
        # xctrace can hang while finishing a recording that hit its time
        # limit; a watchdog stops it TIME_LIMIT + 120 s after it starts.
        xcrun xctrace record --device "$UDID" --template 'Time Profiler' \
            --instrument 'stdout/stderr' --time-limit "${TIME_LIMIT}s" --no-prompt \
            --output "$trace" \
            --launch -- "$BUNDLE_ID" -fixture "$FIXTURE" -autoscroll $argv \
            > "$log" 2>&1 &
        local xpid=$! waited=0
        while kill -0 "$xpid" 2>/dev/null; do
            if [ "$waited" -ge $(( TIME_LIMIT + 120 )) ]; then
                say "$arm run $run: xctrace still running after ${waited}s; stopping it"
                echo "watchdog $arm-$run: xctrace stopped after ${waited}s" >> "$OUT/logs/timings.txt"
                kill -TERM "$xpid" 2>/dev/null || true; sleep 10; kill -KILL "$xpid" 2>/dev/null || true
                break
            fi
            sleep 5; waited=$(( waited + 5 ))
        done
        wait "$xpid" || rc=$?
        # A simulator that is booted but not yet serving logs makes the
        # stdout/stderr instrument fail before the app runs; wait and retry.
        grep -q 'os_log support not available' "$log" || break
        say "$arm run $run: simulator not ready for os_log capture (attempt $attempt); retrying in 30s"
        echo "retry $arm-$run: os_log not available (attempt $attempt)" >> "$OUT/logs/timings.txt"
        sleep 30
    done
    local rec_s=$(( $(now) - t0 ))
    t0="$(now)"
    local tp="$OUT/exports/$arm-$run.time-profile.xml"
    local so="$OUT/exports/$arm-$run.stdout.xml"
    xcrun xctrace export --input "$trace" \
        --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
        > "$tp" 2>>"$log" || rc=$?
    xcrun xctrace export --input "$trace" \
        --xpath '/trace-toc/run[@number="1"]/data/table[@schema="stdouterr-output"]' \
        > "$so" 2>>"$log" || rc=$?
    local line
    line="$(python3 -I "$ANALYZE_PY" analyze --tp "$tp" --stdout "$so" \
        --arm "$arm" --run "$run" --list-window-s "$LIST_WINDOW_S" 2>>"$log")" || true
    [[ -n "$line" ]] || line="{\"arm\": \"$arm\", \"run\": $run, \"error\": \"analysis failed (xctrace rc=$rc), see $log\"}"
    echo "$line" >> "$OUT/results.jsonl"
    echo "record $arm-$run: ${rec_s}s, export+analyze $(( $(now) - t0 ))s" >> "$OUT/logs/timings.txt"
    # The time-profile export is large and can be regenerated from the trace.
    rm -f "$tp"
    say "$arm run $run: $line"
}

{
    echo "base:       $BASE_REF $BASE_SHA ($(cat "$(dirname "$BASE_CACHED")/sha256.txt" 2>/dev/null | cut -c1-12))"
    echo "candidate:  $CAND_REF $CAND_SHA ($(cat "$(dirname "$CAND_CACHED")/sha256.txt" 2>/dev/null | cut -c1-12))"
    echo "fixture:    $FIXTURE ($FIXTURE_SRC, sha256 $FIXTURE_SHA)"
    echo "base args:  -fixture $FIXTURE -autoscroll $BASE_ARGV"
    echo "cand args:  -fixture $FIXTURE -autoscroll $CAND_ARGV"
    echo "list window: $LIST_WINDOW_S s from the scroll start (0 = off)"
    echo "runs:       $RUNS per arm, interleaved"
    echo "device:     $(sim_device_field "$UDID" name) $UDID $(sim_device_field "$UDID" runtime)"
    echo "xcode:      $(xcodebuild -version 2>/dev/null | tr '\n' ' ')"
    echo "host:       $(sysctl -n hw.model) $(sysctl -n hw.ncpu) cores"
    echo "load start: $(sysctl -n vm.loadavg)"
} > "$OUT/env.txt"

say "warming up both apps"
T_WARM="$(now)"
warm_up "$APP_BASE" base "$BASE_ARGV"
warm_up "$APP_CAND" cand "$CAND_ARGV"
# One traced, discarded run: the first recording on a device pays for
# xctrace/os_log start-up and runs slow.
record warmup 0 "$APP_BASE" "$BASE_ARGV"
echo "warm-up: $(( $(now) - T_WARM ))s" >> "$OUT/logs/timings.txt"

T_REC="$(now)"
for run in $(seq 1 "$RUNS"); do
    if (( run % 2 == 1 )); then
        record base "$run" "$APP_BASE" "$BASE_ARGV"; record cand "$run" "$APP_CAND" "$CAND_ARGV"
    else
        record cand "$run" "$APP_CAND" "$CAND_ARGV"; record base "$run" "$APP_BASE" "$BASE_ARGV"
    fi
done
REC_S=$(( $(now) - T_REC ))

{
    echo "load end:   $(sysctl -n vm.loadavg)"
    echo "timings:    builds ${BUILD_S}s, recordings ${REC_S}s, total $(( $(now) - T_START ))s"
} >> "$OUT/env.txt"

echo
echo "## perf-instruments: ${BASE_REF} (${BASE_SHA:0:7}) vs ${CAND_REF} (${CAND_SHA:0:7})"
echo
sed 's/^/    /' "$OUT/env.txt"
echo
rc=0
python3 -I "$ANALYZE_PY" summarize --results "$OUT/results.jsonl" \
    --base base --cand cand --md "$OUT/summary.md" --json "$OUT/summary.json" \
    --env "$OUT/env.txt" || rc=$?
echo
echo "results: $OUT"
exit "$rc"
