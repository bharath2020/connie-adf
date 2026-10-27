#!/usr/bin/env bash
# Scripts/lifecycle-gate.sh — the TextKit 2 stack's lifecycle checks (plan §3,
# quantitative checks 2–6) as one reproducible gate: runs
# Demo/ADFReaderUITests/LifecycleUITests on one explicit simulator with the
# host measurement agent (Scripts/lifecycle_agent.py) answering the tests'
# requests (Darwin-hook rotation, `top` CPU settle, `footprint` memory, 60 s
# idle soak), then writes lifecycle.md with every figure.
#
# USAGE
#   Scripts/lifecycle-gate.sh --udid <UDID> --out <dir>
#       [--derived-data <dir>] [--skip-build] [--only <testName>]...
#       [--suite-timeout 5400] [--xcodebuild-grace 120] [--keep-booted] [--dry-run]
#
#   --udid          required; never creates devices; refuses when another
#                   simulator is booted; shuts down only a device it booted.
#   --out           output dir (lifecycle.md, results.jsonl, agent.log,
#                   xcodebuild.log, lifecycle.xcresult, channel/).
#   --derived-data  isolated derived data (default <out>/DerivedData). A fresh
#                   build refuses a dir that already holds an .xctestrun;
#                   --skip-build reuses one (recorded in lifecycle.md).
#   --only          run only these test methods (default: all, in order):
#                   test1CollapseRoundTripKeepsRows (§3.2),
#                   test2RotationRoundTripDriftMatchesSwiftUI (§3.3),
#                   test3SwitchDuringStreamingLoad (§3.4),
#                   test4SwitchKeepsSearchExpandAndTasks (§3.4),
#                   test5FlingThrashSoakSwiftUI, test6FlingThrashSoakTextKit2
#                   (§3.5), test7TwentyFlipsReleaseRows (§3.6)
#   --dry-run       print the plan; touch no simulator, run no xcodebuild.
#
# PASS (exit 0) only when every selected test case printed `passed` and every
# recorded check passed. Exit 1 on any failure/skip/missing result, 2 on
# usage errors. Estimated duration: ~25 min for all seven tests (the two
# soak tests are ~3 min each) plus ~4 min for a fresh build.
#
# bash 3.2 compatible; needs Xcode, xcodegen, python3.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sim.sh
. "$SCRIPT_DIR/lib/sim.sh"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEMO_DIR="$ROOT/Demo"
AGENT_PY="$SCRIPT_DIR/lifecycle_agent.py"
BUNDLE_ID="com.connie.adfreader"
XCODEGEN="${XCODEGEN:-xcodegen}"
CLASS="LifecycleUITests"
ALL_TESTS="test1CollapseRoundTripKeepsRows test2RotationRoundTripDriftMatchesSwiftUI test3SwitchDuringStreamingLoad test4SwitchKeepsSearchExpandAndTasks test5FlingThrashSoakSwiftUI test6FlingThrashSoakTextKit2 test7TwentyFlipsReleaseRows"

UDID=""; OUT=""; DERIVED_DATA=""; SKIP_BUILD=0; ONLY=""; SUITE_TIMEOUT=5400; GRACE=120
KEEP_BOOTED=0; DRY_RUN=0

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }
log() { printf '[lifecycle-gate %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "error: $*"; exit 2; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --udid) UDID="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --derived-data) DERIVED_DATA="$2"; shift 2 ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        --only) ONLY="$ONLY $2"; shift 2 ;;
        --suite-timeout) SUITE_TIMEOUT="$2"; shift 2 ;;
        --xcodebuild-grace) GRACE="$2"; shift 2 ;;
        --keep-booted) KEEP_BOOTED=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
done
[[ -n "$UDID" ]] || die "--udid is required"
[[ -n "$OUT" ]] || die "--out is required"
TESTS="${ONLY:-$ALL_TESTS}"
for t in $TESTS; do
    case " $ALL_TESTS " in *" $t "*) ;; *) die "unknown test '$t'" ;; esac
done
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
[[ -n "$DERIVED_DATA" ]] || DERIVED_DATA="$OUT/DerivedData"
CHANNEL="$OUT/channel"; RESULTS="$OUT/results.jsonl"; AGENT_LOG="$OUT/agent.log"
TEST_LOG="$OUT/xcodebuild.log"; BUILD_LOG="$OUT/build.log"; RESULT_BUNDLE="$OUT/lifecycle.xcresult"
APP="$DERIVED_DATA/Build/Products/Release-iphonesimulator/ADFReader.app"

ONLY_ARGS=()
for t in $TESTS; do ONLY_ARGS+=("-only-testing:ADFReaderUITests/$CLASS/$t"); done
BUILD_CMD=(xcodebuild build-for-testing -project "$DEMO_DIR/ADFReader.xcodeproj" -scheme ADFReader
    -configuration Release -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DERIVED_DATA"
    CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES)

if [[ $DRY_RUN -eq 1 ]]; then
    echo "tests:        $TESTS"
    if [[ $SKIP_BUILD -eq 1 ]]; then echo "build:        skipped (reuse $DERIVED_DATA)"
    else echo "build:        ( cd $DEMO_DIR && $XCODEGEN generate ) && ${BUILD_CMD[*]}"; fi
    echo "agent:        python3 -I -u $AGENT_PY serve --udid $UDID --channel $CHANNEL --results $RESULTS --log $AGENT_LOG"
    echo "test:         TEST_RUNNER_ADF_LIFECYCLE_DIR=$CHANNEL xcodebuild test-without-building -xctestrun <exact> -destination 'platform=iOS Simulator,id=$UDID' ${ONLY_ARGS[*]} -resultBundlePath $RESULT_BUNDLE"
    echo "report:       python3 -I $AGENT_PY report --results $RESULTS --out $OUT/lifecycle.md"
    exit 0
fi
[[ ! -e "$RESULT_BUNDLE" && ! -s "$RESULTS" ]] || die "$OUT already holds results; use a fresh --out"

select_xctestrun() {
    local products="$1/Build/Products" found count
    found="$(find "$products" -maxdepth 1 -type f -name '*.xctestrun' 2>/dev/null | LC_ALL=C sort || true)"
    count="$(printf '%s' "$found" | grep -c . || true)"
    [[ "$count" == "1" ]] || { log "expected exactly one .xctestrun under $products, found $count"; return 1; }
    printf '%s\n' "$found"
}

BOOTED_BY_US=0; AGENT_PID=""; XCODEBUILD_PID=""
cleanup() {
    local status=$?
    trap - EXIT
    [[ -z "$XCODEBUILD_PID" ]] || kill "$XCODEBUILD_PID" 2>/dev/null || true
    [[ -z "$AGENT_PID" ]] || { kill -TERM "$AGENT_PID" 2>/dev/null || true; wait "$AGENT_PID" 2>/dev/null || true; }
    if [[ $BOOTED_BY_US -eq 1 && $KEEP_BOOTED -eq 0 ]]; then
        log "shutting down $UDID (booted by this run)"
        xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ------------------------------------------------------------------- build
STATE="$(sim_device_field "$UDID" state)"
[[ "$STATE" != "Missing" ]] || die "no simulator with udid $UDID (this script never creates devices)"
if [[ $SKIP_BUILD -eq 0 ]]; then
    if [[ -n "$(find "$DERIVED_DATA/Build/Products" -maxdepth 1 -name '*.xctestrun' 2>/dev/null)" ]]; then
        die "$DERIVED_DATA already holds an .xctestrun; use an empty dir or --skip-build"
    fi
    mkdir -p "$DERIVED_DATA"
    log "xcodegen + build-for-testing (Release) → $DERIVED_DATA"
    ( cd "$DEMO_DIR" && "$XCODEGEN" generate ) >"$BUILD_LOG" 2>&1 || die "xcodegen failed (see $BUILD_LOG)"
    "${BUILD_CMD[@]}" >>"$BUILD_LOG" 2>&1 || die "build-for-testing failed (see $BUILD_LOG)"
fi
[[ -x "$APP/ADFReader" ]] || die "no Release app at $APP"
XCTESTRUN="$(select_xctestrun "$DERIVED_DATA")" || die "cannot pick the xctestrun"
BUILD_SHA="$(shasum -a 256 "$APP/ADFReader" | awk '{print $1}')"

# ------------------------------------------------------------------ device
OTHERS="$(sim_other_booted "$UDID")"
[[ -z "$OTHERS" ]] || die "another simulator is booted ($OTHERS); one device at a time"
STATE="$(sim_device_field "$UDID" state)"
if [[ "$STATE" != "Booted" ]]; then
    log "booting $UDID"
    xcrun simctl boot "$UDID"
    BOOTED_BY_US=1
fi
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 \
    --cellularBars 4 --wifiBars 3 >/dev/null 2>&1 || true
xcrun simctl ui "$UDID" appearance light >/dev/null 2>&1 || true
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true   # fresh task/renderer state

# ------------------------------------------------------------- agent + test
mkdir -p "$CHANNEL"
python3 -I -u "$AGENT_PY" serve --udid "$UDID" --channel "$CHANNEL" --results "$RESULTS" --log "$AGENT_LOG" &
AGENT_PID=$!
log "agent pid $AGENT_PID; running: $TESTS"
TEST_RUNNER_ADF_LIFECYCLE_DIR="$CHANNEL" xcodebuild test-without-building -xctestrun "$XCTESTRUN" \
    -destination "platform=iOS Simulator,id=$UDID" "${ONLY_ARGS[@]}" -resultBundlePath "$RESULT_BUNDLE" \
    >"$TEST_LOG" 2>&1 &
XCODEBUILD_PID=$!

# Wait for every selected test's verdict line, then give xcodebuild a grace
# period (it can idle ~10 min after the last test) before killing it.
verdict_count() {
    local n=0 t
    for t in $TESTS; do
        if tr -d '\r' <"$TEST_LOG" 2>/dev/null | grep -Eq "Test Case '-\[ADFReaderUITests\.$CLASS $t\]' (passed|failed|skipped)"; then
            n=$((n + 1))
        fi
    done
    echo "$n"
}
EXPECTED=$(echo "$TESTS" | wc -w | tr -d ' ')
deadline=$(( SECONDS + SUITE_TIMEOUT ))
while kill -0 "$XCODEBUILD_PID" 2>/dev/null; do
    [[ "$(verdict_count)" -lt "$EXPECTED" ]] || break
    (( SECONDS < deadline )) || { log "suite timeout (${SUITE_TIMEOUT}s)"; break; }
    sleep 5
done
grace=$(( SECONDS + GRACE ))
while kill -0 "$XCODEBUILD_PID" 2>/dev/null && (( SECONDS < grace )); do sleep 2; done
kill "$XCODEBUILD_PID" 2>/dev/null || true
wait "$XCODEBUILD_PID" 2>/dev/null || true
XCODEBUILD_PID=""
kill -TERM "$AGENT_PID" 2>/dev/null || true
wait "$AGENT_PID" 2>/dev/null || true
AGENT_PID=""

# ------------------------------------------------------------------ report
problems=0
for t in $TESTS; do
    line="$(tr -d '\r' <"$TEST_LOG" | grep -E "Test Case '-\[ADFReaderUITests\.$CLASS $t\]' (passed|failed|skipped)" | tail -n 1 || true)"
    case "$line" in
        *"' passed"*) log "PASS  $t" ;;
        "") log "FAIL  $t: no result line"; problems=$((problems + 1)) ;;
        *) log "FAIL  $t: $line"; problems=$((problems + 1)) ;;
    esac
done
REPORT_STATUS=0
python3 -I "$AGENT_PY" report --results "$RESULTS" --out "$OUT/lifecycle.md" \
    --meta "git_head=$(git -C "$ROOT" rev-parse HEAD) ($(git -C "$ROOT" status --porcelain | grep -c . || true) uncommitted paths)" \
    --meta "build=$([[ $SKIP_BUILD -eq 1 ]] && echo "reused $DERIVED_DATA" || echo "fresh $DERIVED_DATA") sha256=$BUILD_SHA" \
    --meta "device=$UDID $(sim_device_field "$UDID" name) $(sim_device_field "$UDID" runtime)" \
    --meta "tests=$TESTS" --meta "xcresult=$RESULT_BUNDLE" --meta "date=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    || REPORT_STATUS=$?
[[ $REPORT_STATUS -eq 0 ]] || problems=$((problems + 1))
log "report: $OUT/lifecycle.md"
if (( problems > 0 )); then
    log "FAIL: $problems problem(s)"
    exit 1
fi
log "PASS: every lifecycle check passed"
