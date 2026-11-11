#!/usr/bin/env bash
# Scripts/lifecycle-gate.sh — the TextKit 2 stack's lifecycle checks (plan §3,
# quantitative checks 2–6, and PR 2's list additions, Astra §6 items 1–6) as
# one reproducible gate: runs
# Demo/ADFReaderUITests/LifecycleUITests on one explicit simulator with the
# host measurement agent (Scripts/lifecycle_agent.py) answering the tests'
# requests (Darwin-hook rotation, `top` CPU settle, `footprint` memory, 60 s
# idle soak), then writes lifecycle.md with every figure.
#
# USAGE
#   Scripts/lifecycle-gate.sh --udid <UDID> --out <dir>
#       [--derived-data <dir>] [--skip-build] [--only <testName>]...
#       [--suite-timeout 9000] [--xcodebuild-grace 120] [--keep-booted]
#       [--allow-other-booted] [--dry-run]
#
#   --udid          required; never creates devices; refuses when another
#                   simulator is booted; shuts down only a device it booted.
#   --allow-other-booted  run anyway beside other booted simulators (never
#                   touched): a shakedown on a shared host. lifecycle.md
#                   records them and every CPU/soak/footprint figure is then
#                   provisional — a gate verdict needs a quiet host.
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
#                   (§3.5), test7TwentyFlipsReleaseRows (§3.6: rule B,
#                   four launches — control and TextKit 2 twice, arm order
#                   alternating — medians of 2, ~30 min),
#                   test8RendererLaunchFlagsAndPersistence (Fable S16:
#                   -textkit2 over a persisted SwiftUI choice, plain
#                   relaunch, toolbar pick persists; ~1 min);
#                   PR 2 lists (Astra §6, Fable F14/F16; fixtures
#                   lists-parity and list-dense):
#                   testL1ListFiveRoundTripsAtParkedPositions (6.1, ~4 min),
#                   testL2ListCollapseRoundTripBothDirections (6.2, ~4 min),
#                   testL3aListRotateAndSizeDriftMatchesSwiftUI (6.3, ~6 min),
#                   testL3bListStateSurvivesRotateSizeAndSwitch (6.3 state,
#                   ~3 min), testL4aListSwitchDuringStreamingLoad (6.4, ~1
#                   min), testL4bListCollidingIDsReplacementDocument (6.4,
#                   ~2 min), testL5aFlingThrashSoakListDenseSwiftUI,
#                   testL5bFlingThrashSoakListDenseTextKit2 (6.5, ~3 each),
#                   testL6TwentyFlipsListDense (6.6: test7's design on
#                   list-dense plus F14 census, ~30 min)
#   --dry-run       print the plan; touch no simulator, run no xcodebuild.
#
# PASS (exit 0) only when every selected test case printed `passed` and every
# recorded check passed. Exit 1 on any failure/skip/missing result, 2 on
# usage errors. Estimated duration: ~43 min for tests 1-8 (test7 ~30, the
# two soak tests ~3 each) + ~56 min for the list tests (testL6 ~30) = ~100
# min, plus ~4 min for a fresh build; the default --suite-timeout (9000 s)
# leaves room for a loaded host. A failed check whose record carries
# failure_class (a no-switch control drift over 2 px) is the known lifecycle
# flake (Fable F16): rerun it with --only; limits are never re-tuned.
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
ALL_TESTS="test1CollapseRoundTripKeepsRows test2RotationRoundTripDriftMatchesSwiftUI test3SwitchDuringStreamingLoad test4SwitchKeepsSearchExpandAndTasks test5FlingThrashSoakSwiftUI test6FlingThrashSoakTextKit2 test7TwentyFlipsReleaseRows test8RendererLaunchFlagsAndPersistence testL1ListFiveRoundTripsAtParkedPositions testL2ListCollapseRoundTripBothDirections testL3aListRotateAndSizeDriftMatchesSwiftUI testL3bListStateSurvivesRotateSizeAndSwitch testL4aListSwitchDuringStreamingLoad testL4bListCollidingIDsReplacementDocument testL5aFlingThrashSoakListDenseSwiftUI testL5bFlingThrashSoakListDenseTextKit2 testL6TwentyFlipsListDense"

UDID=""; OUT=""; DERIVED_DATA=""; SKIP_BUILD=0; ONLY=""; SUITE_TIMEOUT=9000; GRACE=120
KEEP_BOOTED=0; DRY_RUN=0; ALLOW_OTHERS=0

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
        --allow-other-booted) ALLOW_OTHERS=1; shift ;;
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
# Signals go only to this script's own children, by recorded PID and only
# while that PID is still our child: PIDs wrap within minutes on a busy
# host, so a recorded PID whose process has exited can belong to another
# worker's xcodebuild or test runner. Never pattern-match (pkill/killall).
ours() { [[ -n "$1" && "$(ps -o ppid= -p "$1" 2>/dev/null | tr -d ' ')" == "$$" ]]; }
stop_child() {
    if ours "$1"; then kill -TERM "$1" 2>/dev/null || true; fi
    wait "$1" 2>/dev/null || true
}
cleanup() {
    local status=$?
    trap - EXIT
    [[ -z "$XCODEBUILD_PID" ]] || stop_child "$XCODEBUILD_PID"
    [[ -z "$AGENT_PID" ]] || stop_child "$AGENT_PID"
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
OTHERS="$(sim_other_booted "$UDID" | tr '\n' ' ' | sed 's/ *$//')"
if [[ -n "$OTHERS" ]]; then
    [[ $ALLOW_OTHERS -eq 1 ]] || die "another simulator is booted ($OTHERS); one device at a time (--allow-other-booted: provisional shakedown)"
    log "warning: other simulators booted ($OTHERS); CPU/soak/footprint figures are provisional"
fi
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
while ours "$XCODEBUILD_PID"; do
    [[ "$(verdict_count)" -lt "$EXPECTED" ]] || break
    (( SECONDS < deadline )) || { log "suite timeout (${SUITE_TIMEOUT}s)"; break; }
    sleep 5
done
grace=$(( SECONDS + GRACE ))
while ours "$XCODEBUILD_PID" && (( SECONDS < grace )); do sleep 2; done
stop_child "$XCODEBUILD_PID"
XCODEBUILD_PID=""
stop_child "$AGENT_PID"
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
    --meta "other_booted_simulators=${OTHERS:-none}$([[ -n "$OTHERS" ]] && echo ' (shared host: CPU/soak/footprint figures provisional)')" \
    || REPORT_STATUS=$?
[[ $REPORT_STATUS -eq 0 ]] || problems=$((problems + 1))
log "report: $OUT/lifecycle.md"
if (( problems > 0 )); then
    log "FAIL: $problems problem(s)"
    exit 1
fi
log "PASS: every lifecycle check passed"
