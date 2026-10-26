#!/usr/bin/env bash
# Scripts/e2e-video.sh — records a screen-capture video of the ADFReader
# renderer-switch UI test on one iOS Simulator and writes a provenance file
# that ties the video to one exact binary: the sha256 of the .app that was
# built, of the binary that ended up installed on the device, and of what the
# test read off the About This Build screen.
#
# USAGE
#   Scripts/e2e-video.sh [--udid <UDID> | --device-name <name> [--runtime <id>]]
#       [--out <path.mp4>] [--test <Target/Class[/method]>]
#       [--derived-data <dir>] [--keep-booted] [--skip-build]
#
# DEFAULTS
#   device         a simulator named ADFReader-e2e (iPhone 17 Pro on the newest
#                  installed iOS runtime), created when missing
#   --out          $TMPDIR/adfreader-e2e/<timestamp>.mp4
#   --test         ADFReaderUITests/RendererSwitchUITests
#   --derived-data $TMPDIR/adfreader-e2e/DerivedData
#
# PROCEDURE
#   1. xcodegen generate; xcodebuild build-for-testing (Release, unsigned,
#      active arch only) unless --skip-build. Locate the Release .app and the
#      .xctestrun; BUILD_SHA = sha256 of <app>/ADFReader.
#   2. Boot the device (refusing if a different device is already booted),
#      override the status bar (9:41, full battery/signal), light appearance,
#      uninstall any previous ADFReader.
#   3. Start a watcher that waits for the app process on this device and then
#      runs `simctl io recordVideo` — the recording starts at app launch, not
#      at xcodebuild start.
#   4. xcodebuild test-without-building with
#      TEST_RUNNER_ADF_EXPECTED_BUILD_SHA256=$BUILD_SHA, logging to <base>.log.
#      The test asserts the on-screen checksum equals that value.
#   5. On the first `Test Case … passed|failed` line, stop the recorder
#      (SIGINT, then wait for it to finalise), let xcodebuild finish.
#   6. sha256 the installed binary (simctl get_app_container), grep the sha
#      the test printed, write <base>.provenance.txt.
#
# OUTPUTS (<base> = --out without its .mp4 extension)
#   <base>.mp4, <base>.log, <base>.xcresult, <base>.provenance.txt
#
# EXIT STATUS  non-zero when the test failed, the checksums disagree, or the
#   video is missing. The simulator is shut down on exit unless --keep-booted.
#
# REQUIRES  Xcode (xcodebuild, simctl), xcodegen, python3, shasum; ffprobe is
#   optional (video duration).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEMO_DIR="$ROOT/Demo"
SCHEME="ADFReader"
BUNDLE_ID="com.connie.adfreader"
DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
TEST_TIMEOUT="${ADF_E2E_TEST_TIMEOUT:-600}"   # seconds to wait for a verdict
XCODEGEN="${XCODEGEN:-xcodegen}"

UDID=""
DEVICE_NAME="ADFReader-e2e"
RUNTIME=""
OUT=""
TEST_ID="ADFReaderUITests/RendererSwitchUITests"
DERIVED_DATA=""
KEEP_BOOTED=0
SKIP_BUILD=0

usage() { sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
log() { printf '[e2e-video] %s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --udid) UDID="$2"; shift 2 ;;
        --device-name) DEVICE_NAME="$2"; shift 2 ;;
        --runtime) RUNTIME="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --test) TEST_ID="$2"; shift 2 ;;
        --derived-data) DERIVED_DATA="$2"; shift 2 ;;
        --keep-booted) KEEP_BOOTED=1; shift ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
done

TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}/adfreader-e2e"
STAMP="$(date +%Y%m%d-%H%M%S)"
[[ -n "$OUT" ]] || OUT="$TMP_BASE/$STAMP.mp4"
[[ -n "$DERIVED_DATA" ]] || DERIVED_DATA="$TMP_BASE/DerivedData"
BASE="${OUT%.mp4}"
LOG="$BASE.log"
RESULT_BUNDLE="$BASE.xcresult"
PROVENANCE="$BASE.provenance.txt"
mkdir -p "$(dirname "$OUT")" "$DERIVED_DATA"
[[ -e "$RESULT_BUNDLE" ]] && die "$RESULT_BUNDLE already exists; choose another --out"

# ---------------------------------------------------------------- simulator --

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

# Prints the udid of an available iOS device with this name (newest runtime
# first), optionally restricted to one runtime identifier.
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

# Prints "<state>\t<name>\t<runtime>" for a udid, or nothing.
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

# ---------------------------------------------------------------- cleanup ----

RECORDER_PID=""
XCODEBUILD_PID=""

stop_recorder() {
    if [[ -n "$RECORDER_PID" ]] && kill -0 "$RECORDER_PID" 2>/dev/null; then
        kill -INT "$RECORDER_PID" 2>/dev/null || true
        wait "$RECORDER_PID" 2>/dev/null || true
    fi
    RECORDER_PID=""
}

cleanup() {
    local status=$?
    stop_recorder
    if [[ -n "$XCODEBUILD_PID" ]] && kill -0 "$XCODEBUILD_PID" 2>/dev/null; then
        log "stopping lingering xcodebuild ($XCODEBUILD_PID)"
        kill "$XCODEBUILD_PID" 2>/dev/null || true
        wait "$XCODEBUILD_PID" 2>/dev/null || true
    fi
    if [[ $KEEP_BOOTED -eq 0 && -n "${UDID:-}" && "${DEVICE_STATE:-}" == "Booted" ]]; then
        log "shutting down $UDID"
        xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
    fi
    exit "$status"
}
trap cleanup EXIT

# ------------------------------------------------------------------- build ---

resolve_device

APP="$DERIVED_DATA/Build/Products/Release-iphonesimulator/ADFReader.app"
if [[ $SKIP_BUILD -eq 0 ]]; then
    log "xcodegen generate"
    ( cd "$DEMO_DIR" && "$XCODEGEN" generate >/dev/null )
    log "build-for-testing (Release) → $DERIVED_DATA"
    xcodebuild build-for-testing \
        -project "$DEMO_DIR/ADFReader.xcodeproj" \
        -scheme "$SCHEME" \
        -configuration Release \
        -destination "platform=iOS Simulator,id=$UDID" \
        -derivedDataPath "$DERIVED_DATA" \
        CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES \
        -quiet
fi
[[ -x "$APP/ADFReader" ]] || die "no Release app at $APP (build first, or drop --skip-build)"
XCTESTRUN="$(ls -t "$DERIVED_DATA"/Build/Products/ADFReader_iphonesimulator*.xctestrun 2>/dev/null | head -1 || true)"
[[ -n "$XCTESTRUN" ]] || die "no .xctestrun under $DERIVED_DATA/Build/Products"
BUILD_SHA="$(shasum -a 256 "$APP/ADFReader" | awk '{print $1}')"
log "app: $APP"
log "xctestrun: $XCTESTRUN"
log "build sha256: $BUILD_SHA"

# ----------------------------------------------------------------- device ----

assert_only_booted_device
boot_device
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged \
    --batteryLevel 100 --cellularBars 4 --wifiBars 3
xcrun simctl ui "$UDID" appearance light
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true

# ---------------------------------------------------------------- record -----

# The watcher waits for the app's main binary to be running on THIS device,
# then becomes the recorder (exec), so RECORDER_PID is the recordVideo pid.
(
    while ! pgrep -f "Devices/$UDID/.*ADFReader\.app/ADFReader" >/dev/null 2>&1; do
        sleep 0.2
    done
    exec xcrun simctl io "$UDID" recordVideo --codec h264 --force "$OUT"
) &
RECORDER_PID=$!
log "recorder armed (pid $RECORDER_PID), waiting for the app to launch"

# ------------------------------------------------------------------- test ----

log "running $TEST_ID → $LOG"
TEST_RUNNER_ADF_EXPECTED_BUILD_SHA256="$BUILD_SHA" xcodebuild test-without-building \
    -xctestrun "$XCTESTRUN" \
    -destination "platform=iOS Simulator,id=$UDID" \
    -only-testing:"$TEST_ID" \
    -resultBundlePath "$RESULT_BUNDLE" \
    >"$LOG" 2>&1 &
XCODEBUILD_PID=$!

deadline=$(( SECONDS + TEST_TIMEOUT ))
verdict_seen=0
while :; do
    if grep -Eq "Test Case '.*' (passed|failed)" "$LOG" 2>/dev/null; then
        verdict_seen=1
        break
    fi
    if ! kill -0 "$XCODEBUILD_PID" 2>/dev/null; then
        log "xcodebuild exited before any test verdict"
        break
    fi
    if (( SECONDS > deadline )); then
        log "no test verdict after ${TEST_TIMEOUT}s"
        break
    fi
    sleep 1
done
sleep 1    # let the final frame land in the recording
stop_recorder
log "recorder stopped"

# Give xcodebuild a moment to tear down the runner, then insist.
for _ in $(seq 1 60); do
    kill -0 "$XCODEBUILD_PID" 2>/dev/null || break
    sleep 1
done
if kill -0 "$XCODEBUILD_PID" 2>/dev/null; then
    log "xcodebuild still running; killing"
    kill "$XCODEBUILD_PID" 2>/dev/null || true
fi
XCODEBUILD_STATUS=0
wait "$XCODEBUILD_PID" || XCODEBUILD_STATUS=$?
XCODEBUILD_PID=""

# ------------------------------------------------------------- provenance ----

TEST_RESULT="unknown"
if grep -Eq "Test Case '.*' failed" "$LOG"; then
    TEST_RESULT="failed"
elif grep -Eq "Test Case '.*' passed" "$LOG"; then
    TEST_RESULT="passed"
fi

INSTALLED_SHA="(app not installed)"
CONTAINER="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" 2>/dev/null || true)"
if [[ -n "$CONTAINER" && -f "$CONTAINER/ADFReader" ]]; then
    INSTALLED_SHA="$(shasum -a 256 "$CONTAINER/ADFReader" | awk '{print $1}')"
fi

# The test prints OBSERVED_BUILD_SHA256=<hex> and, because the runner got
# ADF_EXPECTED_BUILD_SHA256, asserts it equals BUILD_SHA — so a passed test
# already vouches for the on-screen value even if xcodebuild did not relay
# the runner's stdout into the log.
OBSERVED_SHA="$(grep -oE 'OBSERVED_BUILD_SHA256=[0-9a-f]{64}' "$LOG" | head -1 | cut -d= -f2 || true)"
OBSERVED_NOTE=""
OBSERVED_AGREES="yes"
if [[ -z "$OBSERVED_SHA" ]]; then
    if grep -q "$BUILD_SHA" "$LOG"; then
        OBSERVED_SHA="$BUILD_SHA"
        OBSERVED_NOTE="(build sha found in log; OBSERVED_BUILD_SHA256 line absent)"
    elif [[ "$TEST_RESULT" == "passed" ]]; then
        OBSERVED_SHA="(not in log; equality asserted by the passed test)"
    else
        OBSERVED_SHA="(not found in log)"
        OBSERVED_AGREES="no"
    fi
elif [[ "$OBSERVED_SHA" != "$BUILD_SHA" ]]; then
    OBSERVED_AGREES="no"
fi

VIDEO_SHA="(missing)"
VIDEO_DURATION="(unknown)"
if [[ -s "$OUT" ]]; then
    VIDEO_SHA="$(shasum -a 256 "$OUT" | awk '{print $1}')"
    if command -v ffprobe >/dev/null 2>&1; then
        VIDEO_DURATION="$(ffprobe -v error -show_entries format=duration \
            -of default=noprint_wrappers=1:nokey=1 "$OUT" 2>/dev/null || echo unknown) s"
    fi
fi

GIT_HEAD="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
GIT_BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
GIT_DIRTY="$(git -C "$ROOT" status --porcelain 2>/dev/null || true)"
GIT_DIRTY_COUNT="$(printf '%s' "$GIT_DIRTY" | grep -c . || true)"
XCODE_VERSION="$(xcodebuild -version 2>/dev/null | tr '\n' ' ')"

CHECKSUMS_AGREE="yes"
[[ "$INSTALLED_SHA" == "$BUILD_SHA" ]] || CHECKSUMS_AGREE="no"
[[ "$OBSERVED_AGREES" == "yes" ]] || CHECKSUMS_AGREE="no"

{
    echo "ADFReader end-to-end video provenance"
    echo "date:               $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "git_head:           $GIT_HEAD ($GIT_BRANCH)"
    if [[ "$GIT_DIRTY_COUNT" == "0" ]]; then
        echo "git_status:         clean"
    else
        echo "git_status:         $GIT_DIRTY_COUNT uncommitted path(s):"
        printf '%s\n' "$GIT_DIRTY" | sed 's/^/                    /'
    fi
    echo "xcode:              $XCODE_VERSION"
    echo "simulator:          $UDID  $DEVICE_NAME  $DEVICE_RUNTIME"
    echo "app:                $APP"
    echo "xctestrun:          $XCTESTRUN"
    echo "build_sha256:       $BUILD_SHA"
    echo "installed_sha256:   $INSTALLED_SHA"
    echo "observed_sha256:    $OBSERVED_SHA $OBSERVED_NOTE"
    echo "checksums_agree:    $CHECKSUMS_AGREE"
    echo "test:               $TEST_ID"
    echo "test_result:        $TEST_RESULT (xcodebuild exit $XCODEBUILD_STATUS)"
    echo "video:              $OUT"
    echo "video_sha256:       $VIDEO_SHA"
    echo "video_duration:     $VIDEO_DURATION"
    echo "log:                $LOG"
    echo "result_bundle:      $RESULT_BUNDLE"
} >"$PROVENANCE"

# ----------------------------------------------------------------- verdict ---

problems=()
[[ "$TEST_RESULT" == "passed" ]] || problems+=("test result: $TEST_RESULT")
[[ "$CHECKSUMS_AGREE" == "yes" ]] || problems+=("checksums disagree (build $BUILD_SHA / installed $INSTALLED_SHA / observed $OBSERVED_SHA)")
[[ -s "$OUT" ]] || problems+=("video missing: $OUT")
[[ $verdict_seen -eq 1 ]] || problems+=("no test verdict in $LOG")

echo
echo "video:       $OUT"
echo "log:         $LOG"
echo "results:     $RESULT_BUNDLE"
echo "provenance:  $PROVENANCE"
echo
cat "$PROVENANCE"
echo
if (( ${#problems[@]} > 0 )); then
    for p in "${problems[@]}"; do log "FAIL: $p"; done
    exit 1
fi
log "PASS: test passed, checksums agree, video recorded"
