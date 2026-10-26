#!/usr/bin/env bash
# Scripts/e2e-video.sh — records a screen-capture video of the ADFReader
# renderer-switch UI test on one explicit iOS Simulator and writes a
# provenance manifest that ties the video to one exact build: the sha256 of
# the built binary, of every executable companion and fixture in the .app, of
# the binary installed on the device, and of what the test read off the
# About This Build screen (OBSERVED_BUILD_SHA256).
#
# USAGE
#   Scripts/e2e-video.sh (--udid <UDID> | --create-device <name>) --out <path.mp4>
#       [--derived-data <dir>] [--skip-build] [--keep-booted]
#       [--expected-sha256 <hex> | --negative] [--test-timeout <s>]
#       [--recorder-ready-timeout <s>] [--xcodebuild-grace <s>] [--dry-run]
#
#   --udid             the simulator to use (required unless --create-device).
#                      The script never looks devices up by name.
#   --create-device    explicit opt-in: create an iPhone 17 Pro simulator with
#                      this name on the newest installed iOS runtime and use
#                      it (recorded in the manifest; never deleted).
#   --out              video path (.mp4); <base> = path without .mp4.
#   --derived-data     isolated derived-data dir (default <base>.DerivedData).
#                      A fresh build refuses a dir that already holds an
#                      .xctestrun, so the xctestrun used is the one THIS build
#                      produced. --skip-build reuses an existing dir (recorded).
#   --keep-booted      leave a device this invocation booted running. A device
#                      that was already booted is never shut down.
#   --expected-sha256  override the digest handed to the test (default: the
#                      sha256 of the built binary). A value that differs from
#                      the built binary is a mismatch -> FAIL.
#   --negative         negative control: hand the test a deliberately wrong
#                      digest and EXPECT the named test to fail on the checksum
#                      assertion. Exit 0 only when it did; the manifest records
#                      mode=negative. Use a separate --out (e.g. videos/negative/).
#   --dry-run          print the resolved plan and commands; touch no simulator
#                      and run no xcodebuild.
#
# PROCEDURE
#   1. Unless --skip-build: xcodegen generate; xcodebuild build-for-testing
#      -configuration Release CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES
#      -destination 'platform=iOS Simulator,id=<udid>' into the isolated dir.
#      Exactly one .xctestrun must exist under <dd>/Build/Products.
#   2. Refuse if any other simulator is booted; boot --udid if shut down
#      (remembered: only that device is shut down on exit); status bar pinned
#      (9:41, full battery/signal); light appearance; uninstall ADFReader.
#   3. Start `simctl io <udid> recordVideo --codec h264 --force <out>` BEFORE
#      the test launches; wait until the recorder is ready (file exists and
#      grows, or the recorder reports "Recording started" with the file
#      present) or fail after --recorder-ready-timeout (default 20 s).
#   4. TEST_RUNNER_ADF_EXPECTED_BUILD_SHA256=<digest> xcodebuild
#      test-without-building -xctestrun <exact> -destination id=<udid>
#      -only-testing:<test id> -resultBundlePath <base>.xcresult > <base>.log
#   5. Stop the recorder only after the named test's result line
#      `Test Case '-[ADFReaderUITests.RendererSwitchUITests
#      testLiveSwitchSwiftUIToTextKit2AndBack]' passed|failed`: SIGINT, wait
#      for the recorder to exit, then check the file (ffprobe when available).
#      xcodebuild gets --xcodebuild-grace s (default 120) to finish, then is
#      killed (it can idle ~10 min after the last test case).
#   6. Write <base>.provenance.txt and decide.
#
# FAILS (exit 1) on: recorder error or never ready; missing/empty/unreadable
#   video; empty expected digest; OBSERVED_BUILD_SHA256 absent from both the
#   log and the xcresult; missing named-test result line; build/installed/
#   observed sha mismatch; expected digest != build sha (normal mode); test
#   failure (normal mode) or test pass (negative mode). Usage errors exit 2.
#
# OUTPUTS  <base>.mp4, <base>.log (xcodebuild test), <base>.build.log,
#   <base>.recorder.log, <base>.xcresult (kept), <base>.provenance.txt
#
# REQUIRES  Xcode (xcodebuild, simctl), xcodegen, python3, shasum; ffprobe
#   optional (video duration / readability). bash 3.2 compatible.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEMO_DIR="$ROOT/Demo"
SCHEME="ADFReader"
BUNDLE_ID="com.connie.adfreader"
DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
TEST_ID="ADFReaderUITests/RendererSwitchUITests/testLiveSwitchSwiftUIToTextKit2AndBack"
XCODEGEN="${XCODEGEN:-xcodegen}"
# Failure message of the test's checksum assertion (RendererSwitchUITests).
DIGEST_FAILURE_TEXT="on-screen checksum differs from the built binary"

UDID=""
CREATE_DEVICE=""
OUT=""
DERIVED_DATA=""
SKIP_BUILD=0
KEEP_BOOTED=0
EXPECTED_OVERRIDE=""
NEGATIVE=0
DRY_RUN=0
TEST_TIMEOUT=900
RECORDER_READY_TIMEOUT=20
XCODEBUILD_GRACE=120

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }
log() { printf '[e2e-video] %s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }
usage_error() { log "usage error: $*"; exit 2; }

# ------------------------------------------------------------ pure helpers --
# (Sourced by tests with E2E_VIDEO_SOURCED=1; no side effects.)

sha256_file() { shasum -a 256 "$1" | awk '{print $1}'; }

# CFBundleExecutable of a bundle dir, or $2 (default: bundle basename sans ext).
bundle_executable() {
    local bundle="$1" fallback="${2:-}" name=""
    if [[ -f "$bundle/Info.plist" ]]; then
        name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle/Info.plist" 2>/dev/null || true)"
    fi
    if [[ -z "$name" ]]; then
        name="${fallback:-$(basename "$bundle")}"
        name="${name%.*}"
    fi
    printf '%s\n' "$name"
}

# "-[Target.Class method]" for a Target/Class/method test id.
test_case_name() {
    local id="$1" target cls method
    target="${id%%/*}"; method="${id##*/}"; cls="${id#*/}"; cls="${cls%%/*}"
    printf -- '-[%s.%s %s]\n' "$target" "$cls" "$method"
}

# Prints "passed" or "failed" for the named test's result line in a log
# (the last such line wins), or nothing. Only `Test Case '<name>' passed|failed`
# for exactly this test matches — other test cases and "started" lines do not.
named_test_result() {
    local log_file="$1" name="$2"
    [[ -f "$log_file" ]] || return 0
    tr -d '\r' <"$log_file" | awk -v want="Test Case '$name' " '
        index($0, want) {
            rest = substr($0, index($0, want) + length(want))
            if (rest ~ /^passed( |$)/) r = "passed"
            else if (rest ~ /^failed( |$)/) r = "failed"
        }
        END { if (r != "") print r }'
}

# The full result line (for the manifest), or nothing.
named_test_line() {
    local log_file="$1" name="$2"
    [[ -f "$log_file" ]] || return 0
    tr -d '\r' <"$log_file" | grep -F "Test Case '$name' " | grep -E "' (passed|failed)( |$)" | tail -n 1 || true
}

# The single .xctestrun under <dd>/Build/Products. Prints it; returns 1 with a
# message on stderr when there are zero or several.
select_xctestrun() {
    local products="$1/Build/Products" found count
    found="$(find "$products" -maxdepth 1 -type f -name '*.xctestrun' 2>/dev/null | LC_ALL=C sort || true)"
    count="$(printf '%s' "$found" | grep -c . || true)"
    if [[ "$count" != "1" ]]; then
        printf 'expected exactly one .xctestrun under %s, found %s\n' "$products" "$count" >&2
        [[ -z "$found" ]] || printf '%s\n' "$found" | sed 's/^/  /' >&2
        return 1
    fi
    printf '%s\n' "$found"
}

# Every executable companion inside an .app, one "<relative path>" per line:
# Frameworks/*.framework/<exe>, PlugIns/*.appex/<exe>, every *.dylib.
list_companions() {
    local app="$1" bundle exe
    {
        for bundle in "$app"/Frameworks/*.framework "$app"/PlugIns/*.appex; do
            [[ -d "$bundle" ]] || continue
            exe="$(bundle_executable "$bundle")"
            if [[ -f "$bundle/$exe" ]]; then
                printf '%s\n' "${bundle#"$app"/}/$exe"
            else
                printf '%s\n' "${bundle#"$app"/}/$exe (MISSING)"
            fi
        done
        find "$app" -type f -name '*.dylib' 2>/dev/null | sed "s|^$app/||"
    } | LC_ALL=C sort -u
}

# Fixture JSONs bundled at the app root (Bundle.main.url(forResource:) is flat).
list_fixtures() {
    find "$1" -maxdepth 1 -type f -name '*.json' 2>/dev/null | sed "s|^$1/||" | LC_ALL=C sort
}

# First OBSERVED_BUILD_SHA256=<64 hex> in a file, or nothing.
observed_sha_in() {
    [[ -f "$1" ]] || return 0
    grep -aoE 'OBSERVED_BUILD_SHA256=[0-9a-f]{64}' "$1" | head -n 1 | cut -d= -f2 || true
}

is_sha256() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }

# A digest guaranteed to differ from $1 (for --negative).
wrong_digest_for() {
    local wrong
    wrong="$(printf 'adfreader-negative-control' | shasum -a 256 | awk '{print $1}')"
    [[ "$wrong" != "$1" ]] || wrong="$(printf '%064d' 0)"
    printf '%s\n' "$wrong"
}

if [[ "${E2E_VIDEO_SOURCED:-0}" == "1" ]]; then
    # shellcheck disable=SC2317  # reached only when executed, not sourced
    return 0 2>/dev/null || exit 0
fi

# ----------------------------------------------------------------- options --

while [[ $# -gt 0 ]]; do
    case "$1" in
        --udid) UDID="${2:-}"; shift 2 ;;
        --create-device) CREATE_DEVICE="${2:-}"; shift 2 ;;
        --out) OUT="${2:-}"; shift 2 ;;
        --derived-data) DERIVED_DATA="${2:-}"; shift 2 ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        --keep-booted) KEEP_BOOTED=1; shift ;;
        --expected-sha256) EXPECTED_OVERRIDE="$(printf '%s' "${2:-}" | tr 'A-F' 'a-f')"; shift 2 ;;
        --negative) NEGATIVE=1; shift ;;
        --test-timeout) TEST_TIMEOUT="${2:-}"; shift 2 ;;
        --recorder-ready-timeout) RECORDER_READY_TIMEOUT="${2:-}"; shift 2 ;;
        --xcodebuild-grace) XCODEBUILD_GRACE="${2:-}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage_error "unknown option: $1 (see --help)" ;;
    esac
done

if [[ -n "$UDID" && -n "$CREATE_DEVICE" ]]; then usage_error "pass --udid or --create-device, not both"; fi
if [[ -z "$UDID" && -z "$CREATE_DEVICE" ]]; then usage_error "--udid <UDID> is required (or opt in to --create-device <name>)"; fi
[[ -n "$OUT" ]] || usage_error "--out <path.mp4> is required"
[[ "$OUT" == *.mp4 ]] || usage_error "--out must end in .mp4"
if [[ -n "$EXPECTED_OVERRIDE" && $NEGATIVE -eq 1 ]]; then usage_error "--negative picks its own wrong digest; drop --expected-sha256"; fi
if [[ -n "$EXPECTED_OVERRIDE" ]] && ! is_sha256 "$EXPECTED_OVERRIDE"; then usage_error "--expected-sha256 must be 64 hex characters"; fi
for n in "$TEST_TIMEOUT" "$RECORDER_READY_TIMEOUT" "$XCODEBUILD_GRACE"; do
    [[ "$n" =~ ^[0-9]+$ ]] || usage_error "timeouts must be whole seconds (got '$n')"
done

mkdir -p "$(dirname "$OUT")"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
BASE="${OUT%.mp4}"
[[ -n "$DERIVED_DATA" ]] || DERIVED_DATA="$BASE.DerivedData"
LOG="$BASE.log"
BUILD_LOG="$BASE.build.log"
RECORDER_LOG="$BASE.recorder.log"
RESULT_BUNDLE="$BASE.xcresult"
PROVENANCE="$BASE.provenance.txt"
TEST_CASE="$(test_case_name "$TEST_ID")"
APP="$DERIVED_DATA/Build/Products/Release-iphonesimulator/ADFReader.app"
MODE="normal"; [[ $NEGATIVE -eq 0 ]] || MODE="negative"

set_build_cmd() {
    BUILD_CMD=(xcodebuild build-for-testing
        -project "$DEMO_DIR/ADFReader.xcodeproj"
        -scheme "$SCHEME"
        -configuration Release
        -destination "platform=iOS Simulator,id=${UDID:-<created udid>}"
        -derivedDataPath "$DERIVED_DATA"
        CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES)
}
set_build_cmd

# ----------------------------------------------------------------- dry run --

if [[ $DRY_RUN -eq 1 ]]; then
    echo "mode:           $MODE"
    if [[ -n "$UDID" ]]; then
        echo "device:         $UDID"
    else
        echo "device:         create \"$CREATE_DEVICE\" ($DEVICE_TYPE, newest iOS runtime)"
    fi
    echo "video:          $OUT"
    echo "derived data:   $DERIVED_DATA ($([[ $SKIP_BUILD -eq 1 ]] && echo reused || echo 'fresh build; must not already hold an .xctestrun'))"
    echo "test case:      $TEST_CASE"
    echo "git:            $(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown) ($(git -C "$ROOT" status --porcelain 2>/dev/null | grep -c . || true) dirty path(s))"
    if [[ $SKIP_BUILD -eq 0 ]]; then
        echo "build:          ( cd $DEMO_DIR && $XCODEGEN generate )"
        echo "                ${BUILD_CMD[*]}"
    fi
    if [[ -x "$APP/ADFReader" ]]; then
        echo "app sha256:     $(sha256_file "$APP/ADFReader")  ($APP)"
        echo "xctestrun:      $(select_xctestrun "$DERIVED_DATA" 2>&1 | tr '\n' ' ')"
    else
        echo "app:            $APP (not built yet)"
    fi
    echo "digest:         $([[ $NEGATIVE -eq 1 ]] && echo 'deliberately wrong (negative control)' || echo "${EXPECTED_OVERRIDE:-sha256 of the built binary}")"
    echo "record:         xcrun simctl io <udid> recordVideo --codec h264 --force $OUT   (started before the test; ready <= ${RECORDER_READY_TIMEOUT}s)"
    echo "test:           TEST_RUNNER_ADF_EXPECTED_BUILD_SHA256=<digest> xcodebuild test-without-building -xctestrun <exact> -destination 'platform=iOS Simulator,id=<udid>' -only-testing:$TEST_ID -resultBundlePath $RESULT_BUNDLE > $LOG"
    echo "stop recorder:  after \"Test Case '$TEST_CASE' passed|failed\" (timeout ${TEST_TIMEOUT}s), SIGINT, wait"
    echo "manifest:       $PROVENANCE"
    exit 0
fi

[[ -e "$RESULT_BUNDLE" ]] && die "$RESULT_BUNDLE already exists; choose another --out"
command -v xcrun >/dev/null || die "xcrun not found"
command -v python3 >/dev/null || die "python3 not found"

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

# Prints "<state>\t<name>\t<runtime>" for a udid, or nothing.
device_record() {
    xcrun simctl list devices -j | python3 -I -c '
import json, sys
udid = sys.argv[1].upper()
for rt, devices in json.load(sys.stdin).get("devices", {}).items():
    for d in devices:
        if d["udid"].upper() == udid:
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

CREATED_DEVICE="no"
BOOTED_BY_US=0
DEVICE_STATE_AT_START=""

resolve_device() {
    if [[ -n "$CREATE_DEVICE" ]]; then
        local runtime
        runtime="$(latest_ios_runtime)"
        [[ -n "$runtime" ]] || die "no available iOS simulator runtime"
        log "creating simulator '$CREATE_DEVICE' ($DEVICE_TYPE, $runtime) — explicit --create-device"
        UDID="$(xcrun simctl create "$CREATE_DEVICE" "$DEVICE_TYPE" "$runtime")"
        CREATED_DEVICE="yes ($CREATE_DEVICE, $DEVICE_TYPE, $runtime)"
    fi
    local record
    record="$(device_record "$UDID")"
    [[ -n "$record" ]] || die "no simulator with udid $UDID (the script creates devices only with --create-device)"
    DEVICE_STATE_AT_START="$(cut -f1 <<<"$record")"
    DEVICE_NAME="$(cut -f2 <<<"$record")"
    DEVICE_RUNTIME="$(cut -f3 <<<"$record")"
    log "device: $DEVICE_NAME ($UDID) $DEVICE_RUNTIME, state $DEVICE_STATE_AT_START"
}

assert_only_booted_device() {
    local other
    while read -r other; do
        [[ -z "$other" ]] && continue
        [[ "$(printf '%s' "$other" | tr 'a-f' 'A-F')" == "$(printf '%s' "$UDID" | tr 'a-f' 'A-F')" ]] && continue
        die "another simulator is already booted ($other); this script uses one device at a time"
    done < <(booted_udids)
}

boot_device() {
    if [[ "$DEVICE_STATE_AT_START" != "Booted" ]]; then
        log "booting $UDID"
        xcrun simctl boot "$UDID"
        BOOTED_BY_US=1
    fi
    xcrun simctl bootstatus "$UDID" -b >/dev/null
}

# ---------------------------------------------------------------- cleanup ----

RECORDER_PID=""
RECORDER_STATUS=""
XCODEBUILD_PID=""

stop_recorder() {
    [[ -n "$RECORDER_PID" ]] || return 0
    if kill -0 "$RECORDER_PID" 2>/dev/null; then
        kill -INT "$RECORDER_PID" 2>/dev/null || true
        local i=0
        while kill -0 "$RECORDER_PID" 2>/dev/null && [[ $i -lt 60 ]]; do sleep 0.5; i=$((i + 1)); done
        if kill -0 "$RECORDER_PID" 2>/dev/null; then
            log "recorder did not exit 30 s after SIGINT; killing"
            kill -KILL "$RECORDER_PID" 2>/dev/null || true
        fi
    fi
    RECORDER_STATUS=0
    wait "$RECORDER_PID" 2>/dev/null || RECORDER_STATUS=$?
    RECORDER_PID=""
}

cleanup() {
    local status=$?
    trap - EXIT
    stop_recorder
    if [[ -n "$XCODEBUILD_PID" ]] && kill -0 "$XCODEBUILD_PID" 2>/dev/null; then
        log "stopping lingering xcodebuild ($XCODEBUILD_PID)"
        kill "$XCODEBUILD_PID" 2>/dev/null || true
        wait "$XCODEBUILD_PID" 2>/dev/null || true
    fi
    if [[ $BOOTED_BY_US -eq 1 && $KEEP_BOOTED -eq 0 ]]; then
        log "shutting down $UDID (booted by this invocation)"
        xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
    elif [[ -n "$UDID" && -n "$DEVICE_STATE_AT_START" && $BOOTED_BY_US -eq 0 ]]; then
        log "leaving $UDID running (it was already booted)"
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ------------------------------------------------------------------- build ---

resolve_device
set_build_cmd

if [[ $SKIP_BUILD -eq 0 ]]; then
    if [[ -d "$DERIVED_DATA/Build/Products" ]] && \
        [[ -n "$(find "$DERIVED_DATA/Build/Products" -maxdepth 1 -name '*.xctestrun' 2>/dev/null)" ]]; then
        die "$DERIVED_DATA already holds an .xctestrun; a fresh build needs an empty derived-data dir (or pass --skip-build)"
    fi
    mkdir -p "$DERIVED_DATA"
    log "xcodegen generate"
    ( cd "$DEMO_DIR" && "$XCODEGEN" generate ) >"$BUILD_LOG" 2>&1 || die "xcodegen failed (see $BUILD_LOG)"
    log "build-for-testing (Release) → $DERIVED_DATA (log $BUILD_LOG)"
    "${BUILD_CMD[@]}" >>"$BUILD_LOG" 2>&1 || die "build-for-testing failed (see $BUILD_LOG)"
fi
[[ -x "$APP/ADFReader" ]] || die "no Release app at $APP"
XCTESTRUN="$(select_xctestrun "$DERIVED_DATA")" || die "cannot pick the xctestrun"
BUILD_SHA="$(sha256_file "$APP/ADFReader")"
log "app: $APP"
log "xctestrun: $XCTESTRUN"
log "build sha256: $BUILD_SHA"

if [[ $NEGATIVE -eq 1 ]]; then
    EXPECTED_SHA="$(wrong_digest_for "$BUILD_SHA")"
    log "NEGATIVE CONTROL: handing the test a wrong digest ($EXPECTED_SHA); the named test must fail"
else
    EXPECTED_SHA="${EXPECTED_OVERRIDE:-$BUILD_SHA}"
fi
is_sha256 "$EXPECTED_SHA" || die "expected digest is empty or malformed"

# ----------------------------------------------------------------- device ----

assert_only_booted_device
boot_device
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged \
    --batteryLevel 100 --cellularBars 4 --wifiBars 3
xcrun simctl ui "$UDID" appearance light
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true

# ---------------------------------------------------------------- record -----

file_size() { if [[ -f "$1" ]]; then stat -f %z "$1" 2>/dev/null || echo 0; else echo -1; fi; }

rm -f "$OUT"
xcrun simctl io "$UDID" recordVideo --codec h264 --force "$OUT" >"$RECORDER_LOG" 2>&1 &
RECORDER_PID=$!
log "recorder started (pid $RECORDER_PID); waiting for readiness"
RECORDER_READY=""
deadline=$(( SECONDS + RECORDER_READY_TIMEOUT ))
last_size=-1
while [[ -z "$RECORDER_READY" ]]; do
    kill -0 "$RECORDER_PID" 2>/dev/null || { RECORDER_PID_DEAD=1; break; }
    size="$(file_size "$OUT")"
    if [[ "$size" -gt 0 && "$last_size" -gt 0 && "$size" -gt "$last_size" ]]; then
        RECORDER_READY="file growing ($last_size -> $size bytes)"
    elif [[ "$size" -ge 0 ]] && grep -q "Recording started" "$RECORDER_LOG" 2>/dev/null; then
        RECORDER_READY="recorder reported 'Recording started', file present ($size bytes)"
    fi
    last_size="$size"
    [[ -n "$RECORDER_READY" ]] && break
    (( SECONDS <= deadline )) || break
    sleep 0.5
done
if [[ -z "$RECORDER_READY" ]]; then
    if [[ -n "${RECORDER_PID_DEAD:-}" ]]; then
        RECORDER_STATUS=0; wait "$RECORDER_PID" 2>/dev/null || RECORDER_STATUS=$?; RECORDER_PID=""
        die "recorder exited before becoming ready (status $RECORDER_STATUS; see $RECORDER_LOG)"
    fi
    die "recorder not ready after ${RECORDER_READY_TIMEOUT}s (see $RECORDER_LOG)"
fi
log "recorder ready: $RECORDER_READY"

# ------------------------------------------------------------------- test ----

TEST_CMD=(xcodebuild test-without-building
    -xctestrun "$XCTESTRUN"
    -destination "platform=iOS Simulator,id=$UDID"
    -only-testing:"$TEST_ID"
    -resultBundlePath "$RESULT_BUNDLE")
log "running $TEST_ID → $LOG"
TEST_RUNNER_ADF_EXPECTED_BUILD_SHA256="$EXPECTED_SHA" "${TEST_CMD[@]}" >"$LOG" 2>&1 &
XCODEBUILD_PID=$!

deadline=$(( SECONDS + TEST_TIMEOUT ))
TEST_RESULT=""
while :; do
    TEST_RESULT="$(named_test_result "$LOG" "$TEST_CASE")"
    [[ -n "$TEST_RESULT" ]] && break
    if ! kill -0 "$XCODEBUILD_PID" 2>/dev/null; then
        log "xcodebuild exited without the named test's result line"
        break
    fi
    if (( SECONDS > deadline )); then
        log "no result line for $TEST_CASE after ${TEST_TIMEOUT}s"
        break
    fi
    sleep 1
done
sleep 1    # let the final frame land in the recording
stop_recorder
log "recorder stopped (exit $RECORDER_STATUS)"

i=0
while kill -0 "$XCODEBUILD_PID" 2>/dev/null && [[ $i -lt $XCODEBUILD_GRACE ]]; do sleep 1; i=$((i + 1)); done
XCODEBUILD_KILLED="no"
if kill -0 "$XCODEBUILD_PID" 2>/dev/null; then
    log "xcodebuild still running after ${XCODEBUILD_GRACE}s; killing"
    kill "$XCODEBUILD_PID" 2>/dev/null || true
    XCODEBUILD_KILLED="yes"
fi
XCODEBUILD_STATUS=0
wait "$XCODEBUILD_PID" 2>/dev/null || XCODEBUILD_STATUS=$?
XCODEBUILD_PID=""

# ------------------------------------------------------------- provenance ----

TEST_LINE="$(named_test_line "$LOG" "$TEST_CASE")"
DIGEST_FAILURE="no"
grep -qF "$DIGEST_FAILURE_TEXT" "$LOG" 2>/dev/null && DIGEST_FAILURE="yes"

INSTALLED_SHA=""
CONTAINER="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" app 2>/dev/null || true)"
if [[ -n "$CONTAINER" && -f "$CONTAINER/ADFReader" ]]; then
    INSTALLED_SHA="$(sha256_file "$CONTAINER/ADFReader")"
fi

# The test prints OBSERVED_BUILD_SHA256=<hex> to stdout and records it as an
# activity in the result bundle; either source counts, absence is a FAIL.
OBSERVED_SHA="$(observed_sha_in "$LOG")"
OBSERVED_SOURCE="xcodebuild log"
if [[ -z "$OBSERVED_SHA" && -d "$RESULT_BUNDLE" ]]; then
    ACTIVITIES="$BASE.activities.json"
    xcrun xcresulttool get test-results activities --path "$RESULT_BUNDLE" \
        --test-id "${TEST_ID#*/}" >"$ACTIVITIES" 2>/dev/null || true
    OBSERVED_SHA="$(observed_sha_in "$ACTIVITIES")"
    OBSERVED_SOURCE="xcresult activities ($ACTIVITIES)"
fi
[[ -n "$OBSERVED_SHA" ]] || OBSERVED_SOURCE="absent"

VIDEO_SHA=""
VIDEO_DURATION=""
VIDEO_READABLE="unchecked (no ffprobe)"
if [[ -s "$OUT" ]]; then
    VIDEO_SHA="$(sha256_file "$OUT")"
    if command -v ffprobe >/dev/null 2>&1; then
        if VIDEO_DURATION="$(ffprobe -v error -show_entries format=duration \
            -of default=noprint_wrappers=1:nokey=1 "$OUT" 2>/dev/null)" && [[ -n "$VIDEO_DURATION" ]]; then
            VIDEO_READABLE="yes"
        else
            VIDEO_READABLE="no"; VIDEO_DURATION=""
        fi
    fi
fi

GIT_HEAD="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
GIT_BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
GIT_DIRTY="$(git -C "$ROOT" status --porcelain 2>/dev/null || true)"
GIT_DIRTY_COUNT="$(printf '%s' "$GIT_DIRTY" | grep -c . || true)"
XCODE_VERSION="$(xcodebuild -version 2>/dev/null | tr '\n' ' ')"

problems=()
[[ -n "$TEST_RESULT" ]] || problems+=("named test result line missing: Test Case '$TEST_CASE' passed|failed")
if [[ $NEGATIVE -eq 1 ]]; then
    [[ "$TEST_RESULT" == "failed" ]] || problems+=("negative control: expected the named test to FAIL, got '${TEST_RESULT:-none}'")
    [[ "$DIGEST_FAILURE" == "yes" ]] || problems+=("negative control: failure is not the checksum assertion ('$DIGEST_FAILURE_TEXT' absent)")
else
    [[ "$TEST_RESULT" == "passed" ]] || problems+=("test result: ${TEST_RESULT:-none}")
    [[ "$EXPECTED_SHA" == "$BUILD_SHA" ]] || problems+=("expected digest $EXPECTED_SHA != build $BUILD_SHA")
fi
[[ -n "$OBSERVED_SHA" ]] || problems+=("OBSERVED_BUILD_SHA256 absent from the log and the xcresult")
[[ -z "$OBSERVED_SHA" || "$OBSERVED_SHA" == "$BUILD_SHA" ]] || problems+=("observed $OBSERVED_SHA != build $BUILD_SHA")
[[ -n "$INSTALLED_SHA" ]] || problems+=("installed app not found on $UDID")
[[ -z "$INSTALLED_SHA" || "$INSTALLED_SHA" == "$BUILD_SHA" ]] || problems+=("installed $INSTALLED_SHA != build $BUILD_SHA")
[[ "$RECORDER_STATUS" == "0" ]] || problems+=("recorder exit status $RECORDER_STATUS (see $RECORDER_LOG)")
[[ -s "$OUT" ]] || problems+=("video missing or empty: $OUT")
[[ "$VIDEO_READABLE" != "no" ]] || problems+=("ffprobe cannot read $OUT")

{
    echo "ADFReader end-to-end video provenance"
    echo "date:                $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "mode:                $MODE"
    echo "git_head:            $GIT_HEAD ($GIT_BRANCH)"
    if [[ "$GIT_DIRTY_COUNT" == "0" ]]; then
        echo "git_status:          clean"
    else
        echo "git_status:          dirty, $GIT_DIRTY_COUNT path(s):"
        printf '%s\n' "$GIT_DIRTY" | sed 's/^/                     /'
    fi
    echo "xcode:               $XCODE_VERSION"
    echo "simulator:           $UDID  $DEVICE_NAME  $DEVICE_RUNTIME"
    echo "simulator_state:     $DEVICE_STATE_AT_START at start; booted_by_script=$([[ $BOOTED_BY_US -eq 1 ]] && echo yes || echo no); created_by_script=$CREATED_DEVICE"
    if [[ $SKIP_BUILD -eq 1 ]]; then
        echo "build:               SKIPPED (--skip-build); reused derived data"
    else
        echo "build_command:       ( cd $DEMO_DIR && $XCODEGEN generate ) && ${BUILD_CMD[*]}"
    fi
    echo "configuration:       Release (CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES)"
    echo "derived_data:        $DERIVED_DATA"
    if [[ $SKIP_BUILD -eq 1 ]]; then
        echo "build_log:           (none: this run did not build; see the build that produced $DERIVED_DATA)"
    else
        echo "build_log:           $BUILD_LOG"
    fi
    echo "app:                 $APP"
    echo "xctestrun:           $XCTESTRUN"
    echo "build_sha256:        $BUILD_SHA  ADFReader"
    echo "companions_sha256:"
    companions="$(list_companions "$APP")"
    if [[ -z "$companions" ]]; then
        echo "                     (none)"
    else
        while IFS= read -r rel; do
            if [[ "$rel" == *" (MISSING)" ]]; then
                echo "                     MISSING  ${rel% (MISSING)}"
                problems+=("companion executable missing: ${rel% (MISSING)}")
            else
                echo "                     $(sha256_file "$APP/$rel")  $rel"
            fi
        done <<<"$companions"
    fi
    echo "fixtures_sha256:"
    fixtures="$(list_fixtures "$APP")"
    if [[ -z "$fixtures" ]]; then
        echo "                     (none)"
    else
        while IFS= read -r rel; do
            echo "                     $(sha256_file "$APP/$rel")  $rel"
        done <<<"$fixtures"
    fi
    echo "installed_path:      ${CONTAINER:-(not installed)}"
    echo "installed_sha256:    ${INSTALLED_SHA:-(missing)}"
    echo "expected_sha256:     $EXPECTED_SHA $([[ $NEGATIVE -eq 1 ]] && echo '(deliberately wrong: negative control)')"
    echo "observed_sha256:     ${OBSERVED_SHA:-(absent)}  [source: $OBSERVED_SOURCE]"
    echo "test:                $TEST_ID"
    echo "test_command:        TEST_RUNNER_ADF_EXPECTED_BUILD_SHA256=$EXPECTED_SHA ${TEST_CMD[*]}"
    echo "test_result:         ${TEST_RESULT:-(no result line)}"
    echo "test_result_line:    ${TEST_LINE:-(none)}"
    echo "digest_assertion_failed: $DIGEST_FAILURE"
    echo "xcodebuild_exit:     $XCODEBUILD_STATUS (killed after grace: $XCODEBUILD_KILLED)"
    echo "test_log:            $LOG"
    echo "result_bundle:       $RESULT_BUNDLE $([[ -d "$RESULT_BUNDLE" ]] && echo '(kept)' || echo '(missing)')"
    echo "recorder_ready:      $RECORDER_READY"
    echo "recorder_exit:       $RECORDER_STATUS"
    echo "recorder_log:        $RECORDER_LOG"
    echo "video:               $OUT"
    echo "video_sha256:        ${VIDEO_SHA:-(missing)}"
    echo "video_duration_s:    ${VIDEO_DURATION:-(unknown)}"
    echo "video_readable:      $VIDEO_READABLE"
    if (( ${#problems[@]} > 0 )); then
        echo "verdict:             FAIL"
        for p in "${problems[@]}"; do echo "problem:             $p"; done
    else
        echo "verdict:             PASS$([[ $NEGATIVE -eq 1 ]] && echo ' (negative control failed as required)')"
    fi
} >"$PROVENANCE"

# ----------------------------------------------------------------- verdict ---

echo
cat "$PROVENANCE"
echo
if (( ${#problems[@]} > 0 )); then
    for p in "${problems[@]}"; do log "FAIL: $p"; done
    exit 1
fi
if [[ $NEGATIVE -eq 1 ]]; then
    log "PASS: negative control — the wrong digest made the named test fail on the checksum assertion"
else
    log "PASS: named test passed, build/installed/observed sha256 agree, video recorded"
fi
