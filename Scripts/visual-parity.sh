#!/usr/bin/env bash
# Scripts/visual-parity.sh — captures and compares screenshots of a reference
# ADFReader build (e.g. a Release build of main) against this branch's build,
# on one iOS Simulator, for every (fixture, appearance, text-size step).
#
# USAGE
#   Scripts/visual-parity.sh --ref-app <main ADFReader.app> --app <branch ADFReader.app>
#       [--udid <UDID> | --device-name <name> [--runtime <id>]] [--out <dir>]
#       [--fixture <name>]... [--size-steps "0 3"] [--appearances "light dark"]
#       [--max-raw-pct 0.5] [--max-offset-px 0] [--top-band 186] [--bottom-band 102]
#       [--keep-booted] [--skip-capture]
#
# ARMS (per fixture × appearance × step)
#   A  --ref-app, launched plainly                 (reference)
#   B  --app, launched plainly                     (same binary, SwiftUI text)
#   C  --app, launched with -textkit2              (TextKit 2 text)
#
# PROCEDURE  per capture: terminate + uninstall + install the arm's .app (so
#   no persisted renderer key leaks between arms), status-bar override
#   (9:41, full battery/signal), `simctl ui appearance`, then
#   `simctl launch --console-pty <udid> com.connie.adfreader -fixture <f>
#   [-fontSizeStep <n>] [-textkit2]` logged to <out>/captures/<name>.log;
#   wait for `READY fixture=`, sleep 3 s, `simctl io screenshot`, terminate.
#
# SCORING  Scripts/visual_diff.py (python3 -I, Pillow + numpy) scores the
#   pairs A–B and A–C: raw differing-pixel % outside the status/nav and home
#   bands, and per-text-block vertical offset (max |offset| and the last
#   block's offset). Writes side-by-side + diff PNGs, scores.csv and
#   summary.md with a PASS/FAIL line per pair.
#
# DEFAULTS  device ADFReader-e2e (iPhone 17 Pro, newest iOS runtime, created
#   when missing); --out $TMPDIR/adfreader-parity/<timestamp>; --fixture
#   kitchen-sink; --size-steps "0 3"; --appearances "light dark".
#   --skip-capture re-scores existing captures in --out.
#
# EXIT STATUS  non-zero when a capture fails or any pair FAILs. The simulator
#   is shut down at the end unless --keep-booted.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_ID="com.connie.adfreader"
DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
READY_TIMEOUT="${ADF_PARITY_READY_TIMEOUT:-90}"
SETTLE_SECONDS=3

UDID=""
DEVICE_NAME="ADFReader-e2e"
RUNTIME=""
REF_APP=""
APP=""
OUT=""
FIXTURES=()
SIZE_STEPS="0 3"
APPEARANCES="light dark"
MAX_RAW_PCT="0.5"
MAX_OFFSET_PX="0"
TOP_BAND="186"
BOTTOM_BAND="102"
KEEP_BOOTED=0
SKIP_CAPTURE=0

usage() { sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
log() { printf '[visual-parity] %s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --udid) UDID="$2"; shift 2 ;;
        --device-name) DEVICE_NAME="$2"; shift 2 ;;
        --runtime) RUNTIME="$2"; shift 2 ;;
        --ref-app) REF_APP="$2"; shift 2 ;;
        --app) APP="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --fixture) FIXTURES+=("$2"); shift 2 ;;
        --size-steps) SIZE_STEPS="$2"; shift 2 ;;
        --appearances) APPEARANCES="$2"; shift 2 ;;
        --max-raw-pct) MAX_RAW_PCT="$2"; shift 2 ;;
        --max-offset-px) MAX_OFFSET_PX="$2"; shift 2 ;;
        --top-band) TOP_BAND="$2"; shift 2 ;;
        --bottom-band) BOTTOM_BAND="$2"; shift 2 ;;
        --keep-booted) KEEP_BOOTED=1; shift ;;
        --skip-capture) SKIP_CAPTURE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
done

[[ ${#FIXTURES[@]} -gt 0 ]] || FIXTURES=(kitchen-sink)
TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}/adfreader-parity"
[[ -n "$OUT" ]] || OUT="$TMP_BASE/$(date +%Y%m%d-%H%M%S)"
CAPTURES="$OUT/captures"
mkdir -p "$CAPTURES"
if [[ $SKIP_CAPTURE -eq 0 ]]; then
    [[ -n "$REF_APP" && -x "$REF_APP/ADFReader" ]] || die "--ref-app must be an ADFReader.app (got '${REF_APP:-}')"
    [[ -n "$APP" && -x "$APP/ADFReader" ]] || die "--app must be an ADFReader.app (got '${APP:-}')"
fi

# ---------------------------------------------------------------- simulator --
# (Same helpers as Scripts/e2e-video.sh; kept inline so each script stands alone.)

latest_ios_runtime() {
    xcrun simctl list runtimes -j | python3 -I -c '
import json, sys
best = None
for rt in json.load(sys.stdin).get("runtimes", []):
    if rt.get("platform") != "iOS" or not rt.get("isAvailable"):
        continue
    key = tuple(int(p) for p in rt.get("version", "0").split(".") if p.isdigit())
    if best is None or key > best[0]:
        best = (key, rt["identifier"])
print(best[1] if best else "")
'
}

find_device_by_name() {
    xcrun simctl list devices -j | python3 -I -c '
import json, re, sys
name, runtime = sys.argv[1], sys.argv[2]
found = []
for rt, devices in json.load(sys.stdin).get("devices", {}).items():
    if runtime and rt != runtime:
        continue
    m = re.search(r"SimRuntime\.iOS-(\d+)-(\d+)", rt)
    if not m:
        continue
    for d in devices:
        if d.get("name") == name and d.get("isAvailable", True):
            found.append(((int(m.group(1)), int(m.group(2))), d["udid"]))
found.sort(reverse=True)
print(found[0][1] if found else "")
' "$1" "${2:-}"
}

device_record() {
    xcrun simctl list devices -j | python3 -I -c '
import json, sys
udid = sys.argv[1]
for rt, devices in json.load(sys.stdin).get("devices", {}).items():
    for d in devices:
        if d["udid"] == udid:
            print(d.get("state", "?"), d.get("name", "?"), rt, sep="\t")
' "$1"
}

booted_udids() {
    xcrun simctl list devices -j | python3 -I -c '
import json, sys
for devices in json.load(sys.stdin).get("devices", {}).values():
    for d in devices:
        if d.get("state") == "Booted":
            print(d["udid"])
'
}

resolve_device() {
    if [[ -z "$UDID" ]]; then
        UDID="$(find_device_by_name "$DEVICE_NAME" "$RUNTIME")"
        if [[ -z "$UDID" ]]; then
            local runtime="$RUNTIME"
            [[ -n "$runtime" ]] || runtime="$(latest_ios_runtime)"
            [[ -n "$runtime" ]] || die "no available iOS simulator runtime"
            log "creating simulator '$DEVICE_NAME' ($DEVICE_TYPE, $runtime)"
            UDID="$(xcrun simctl create "$DEVICE_NAME" "$DEVICE_TYPE" "$runtime")"
        fi
    fi
    local record
    record="$(device_record "$UDID")"
    [[ -n "$record" ]] || die "no simulator with udid $UDID"
    DEVICE_STATE="$(cut -f1 <<<"$record")"
    DEVICE_NAME="$(cut -f2 <<<"$record")"
    DEVICE_RUNTIME="$(cut -f3 <<<"$record")"
    log "device: $DEVICE_NAME ($UDID) $DEVICE_RUNTIME, state $DEVICE_STATE"
}

assert_only_booted_device() {
    local other
    while read -r other; do
        [[ -z "$other" || "$other" == "$UDID" ]] && continue
        die "another simulator is already booted ($other); shut it down or pass --udid $other"
    done < <(booted_udids)
}

boot_device() {
    if [[ "$DEVICE_STATE" != "Booted" ]]; then
        log "booting $UDID"
        xcrun simctl boot "$UDID"
    fi
    xcrun simctl bootstatus "$UDID" -b >/dev/null
    DEVICE_STATE="Booted"
}

LAUNCH_PID=""
cleanup() {
    local status=$?
    if [[ -n "$LAUNCH_PID" ]] && kill -0 "$LAUNCH_PID" 2>/dev/null; then
        xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
        kill "$LAUNCH_PID" 2>/dev/null || true
    fi
    if [[ $KEEP_BOOTED -eq 0 && -n "${UDID:-}" && "${DEVICE_STATE:-}" == "Booted" ]]; then
        log "shutting down $UDID"
        xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
    fi
    exit "$status"
}
trap cleanup EXIT

# ----------------------------------------------------------------- capture ---

# capture <app> <fixture> <appearance> <step> <textkit2:0|1> <png>
capture() {
    local app="$1" fixture="$2" appearance="$3" step="$4" textkit2="$5" png="$6"
    local launch_log="${png%.png}.log"
    local -a args=(-fixture "$fixture")
    [[ "$step" == "0" ]] || args+=(-fontSizeStep "$step")
    [[ "$textkit2" == "0" ]] || args+=(-textkit2)

    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl install "$UDID" "$app"
    xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged \
        --batteryLevel 100 --cellularBars 4 --wifiBars 3
    xcrun simctl ui "$UDID" appearance "$appearance"

    {
        echo "APP: $app"
        echo "APP_SHA256: $(shasum -a 256 "$app/ADFReader" | awk '{print $1}')"
        echo "LAUNCH_CMD: xcrun simctl launch --console-pty $UDID $BUNDLE_ID ${args[*]}"
    } >"$launch_log"
    xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID" "${args[@]}" >>"$launch_log" 2>&1 &
    LAUNCH_PID=$!

    local deadline=$(( SECONDS + READY_TIMEOUT ))
    while ! grep -q "READY fixture=" "$launch_log" 2>/dev/null; do
        if ! kill -0 "$LAUNCH_PID" 2>/dev/null; then
            log "app exited before READY (see $launch_log)"
            LAUNCH_PID=""
            return 1
        fi
        if (( SECONDS > deadline )); then
            log "no READY after ${READY_TIMEOUT}s (see $launch_log)"
            xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
            LAUNCH_PID=""
            return 1
        fi
        sleep 0.2
    done
    sleep "$SETTLE_SECONDS"
    xcrun simctl io "$UDID" screenshot "$png" >/dev/null
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    wait "$LAUNCH_PID" 2>/dev/null || true
    LAUNCH_PID=""
    log "captured $(basename "$png")"
}

PAIR_ARGS=()
CAPTURE_FAILURES=0
if [[ $SKIP_CAPTURE -eq 0 ]]; then
    resolve_device
    assert_only_booted_device
    boot_device
fi
for fixture in "${FIXTURES[@]}"; do
    for appearance in $APPEARANCES; do
        for step in $SIZE_STEPS; do
            name="$fixture-$appearance-s$step"
            a="$CAPTURES/$name-A.png"; b="$CAPTURES/$name-B.png"; c="$CAPTURES/$name-C.png"
            if [[ $SKIP_CAPTURE -eq 0 ]]; then
                capture "$REF_APP" "$fixture" "$appearance" "$step" 0 "$a" || CAPTURE_FAILURES=$((CAPTURE_FAILURES + 1))
                capture "$APP"     "$fixture" "$appearance" "$step" 0 "$b" || CAPTURE_FAILURES=$((CAPTURE_FAILURES + 1))
                capture "$APP"     "$fixture" "$appearance" "$step" 1 "$c" || CAPTURE_FAILURES=$((CAPTURE_FAILURES + 1))
            fi
            [[ -f "$a" && -f "$b" ]] && PAIR_ARGS+=(--pair "$name-AB" "$a" "$b")
            [[ -f "$a" && -f "$c" ]] && PAIR_ARGS+=(--pair "$name-AC" "$a" "$c")
        done
    done
done

# ------------------------------------------------------------------- score ---

[[ ${#PAIR_ARGS[@]} -gt 0 ]] || die "nothing to compare under $CAPTURES"
DIFF_STATUS=0
python3 -I "$SCRIPT_DIR/visual_diff.py" \
    --out "$OUT" \
    --top-band "$TOP_BAND" --bottom-band "$BOTTOM_BAND" \
    --max-raw-pct "$MAX_RAW_PCT" --max-offset-px "$MAX_OFFSET_PX" \
    "${PAIR_ARGS[@]}" || DIFF_STATUS=$?

echo
echo "captures:  $CAPTURES"
echo "scores:    $OUT/scores.csv"
echo "summary:   $OUT/summary.md"
if (( CAPTURE_FAILURES > 0 )); then
    log "FAIL: $CAPTURE_FAILURES capture(s) failed"
    exit 1
fi
exit "$DIFF_STATUS"
