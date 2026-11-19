#!/usr/bin/env bash
# Scripts/lifecycle-gate.sh — the TextKit 2 stack's lifecycle checks (plan §3,
# quantitative checks 2–6; PR 2's list additions, Astra §6 items 1–6; PR 3's
# code-block additions, PR 3 plan §6 C1–C6) as one reproducible gate: runs
# Demo/ADFReaderUITests/LifecycleUITests on one explicit simulator with the
# host measurement agent (Scripts/lifecycle_agent.py) answering the tests'
# requests (Darwin-hook rotation, `top` CPU settle, `footprint` memory, 60 s
# idle soak, the device pasteboard), then writes lifecycle.md with every
# figure.
#
# USAGE
#   Scripts/lifecycle-gate.sh --udid <UDID> --out <dir>
#       [--derived-data <dir>] [--skip-build] [--only <test>]...
#       [--suite-timeout 22600] [--xcodebuild-grace 120] [--keep-booted]
#       [--allow-other-booted] [--k3-crossing <dir>]... [--dry-run]
#
#   --udid          required; never creates devices; refuses when another
#                   simulator is booted; shuts down only a device it booted.
#   --allow-other-booted  run anyway beside other booted simulators (never
#                   touched): a shakedown on a shared host. lifecycle.md
#                   records them and every CPU/soak/footprint figure is then
#                   provisional — a gate verdict needs a quiet host.
#   --out           output dir (lifecycle.md, results.jsonl, agent.log,
#                   xcodebuild.log, lifecycle.xcresult, channel/).
#   --k3-crossing   an earlier run's --out on an iPad (a regular-width
#                   destination), of the same build (the sha256 its
#                   lifecycle.md records must equal this build's, else exit
#                   2 before the device is touched). A run that runs K3
#                   fails (report row "K3 column boundary crossed", review
#                   D-R5, Astra delta R5) unless its own K3 or one of these
#                   runs' K3 passed with regular_width and crossed_boundary
#                   true on both arms. K3 takes regular_width from the
#                   device, not from the layout drawn; a phone stacks the
#                   columns at every size, so its K3 records the boundary as
#                   not crossable.
#   --derived-data  isolated derived data (default <out>/DerivedData). A fresh
#                   build refuses a dir that already holds an .xctestrun;
#                   --skip-build reuses one (recorded in lifecycle.md).
#   --only          run only these tests (default: all, in order). A value is
#                   a method name below; or its short form, the name up to
#                   the first descriptive word (test7, testL3a, testC1 — the
#                   one test whose name continues with an upper-case letter,
#                   so testC1 never selects testC1b); or <Class>/<method>, a
#                   UI test of another ADFReaderUITests class that needs the
#                   host agent (CodeRendererUITests' Copy test reads the
#                   device pasteboard through it). The methods:
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
#                   testL1ListFiveRoundTripsAtParkedPositions (6.1 on
#                   lists-parity, ~2 min), testL1bListFiveRoundTripsListDense
#                   (6.1 on list-dense, ~2 min),
#                   testL2ListCollapseRoundTripBothDirections (6.2, ~10 min),
#                   testL3aListRotateAndSizeDriftMatchesSwiftUI (6.3, ~8 min),
#                   testL3bListStateSurvivesRotateSizeAndSwitch (6.3 state on
#                   lists-parity, ~3 min),
#                   testL3cListStateSurvivesRotateSizeAndSwitchListDense (6.3
#                   state on list-dense, ~4 min),
#                   testL4aListSwitchDuringStreamingLoad (6.4, ~1
#                   min), testL4bListCollidingIDsReplacementDocument (6.4,
#                   ~2 min), testL5aFlingThrashSoakListDenseSwiftUI,
#                   testL5bFlingThrashSoakListDenseTextKit2 (6.5, ~3 each),
#                   testL6TwentyFlipsListDense (6.6: test7's design on
#                   list-dense plus F14 census, ~30 min);
#                   PR 3 code blocks (PR 3 plan §6; fixture code-dense):
#                   testC1CodeFiveRoundTripsCodeDense (C1: five ON/OFF round
#                   trips at a deep position, ~2 min),
#                   testC1bCodeFiveRoundTripsPannedWideBlock (C1b: the same
#                   with one wide block panned 200 pt, ~2 min),
#                   testC2CodeCollapseRoundTripBothDirections (C2, ~10 min),
#                   testC3CodeTextSizeDriftMatchesSwiftUI (C3: Text Size
#                   0 → 3 → 0, rotation recorded only, ~8 min),
#                   testC4CodeSwitchDuringStreamingLoad (C4, ~1 min),
#                   testC5aFlingThrashSoakCodeDenseSwiftUI,
#                   testC5bFlingThrashSoakCodeDenseTextKit2 (C5: vertical
#                   fling, horizontal fling inside a wide block, scene
#                   thrash, 60 s soak; ~4 each),
#                   testC6TwentyFlipsCodeDense (C6: test7's design on
#                   code-dense, live code rows 0 after every OFF, ~30 min);
#                   PR 4 containers (PR 4 plan §8.2, CONTAINER_TESTS):
#                   testK1SwitchRoundTripsAtContainerLandmarks (8.2 K1:
#                   five ON/OFF round trips at panel, quote, column and
#                   open-expand landmarks of containers-parity, then a
#                   caption of captions-parity; ~6 min),
#                   testK2OpenExpandRoundTripAcrossSwitch (K2: an open
#                   outer and nested expand of containers-parity away and
#                   back across a switch, both directions, plus a panned
#                   code child; ~8 min),
#                   testK3WidthAndTypeSizeChangesInContainers (K3: rotation,
#                   Text Size 0 → 3 → 0 and the size rule's cut-off leg
#                   0 → accessibility3 → accessibility4 → 0 at the columns
#                   of containers-parity, per arm; the column crossing
#                   needs a regular width: --k3-crossing; ~10 min),
#                   testK4SwitchDuringLoadAndSearchInContainers (K4: a
#                   switch during the streaming load, task state, a search
#                   in a nested expand and in a caption; ~4 min),
#                   testK5aFlingOpenExpandsSwiftUI,
#                   testK5bFlingOpenExpandsTextKit2 (K5: end-to-end flings
#                   over containers-expand with five expands open, scene
#                   thrash, 60 s soak, then a walk of the open bodies;
#                   ~6 each),
#                   testK6TwentyFlipsContainers (K6: test7's design on
#                   containers-expand with CE-OPEN-1 open, live rows 0 after
#                   the closing OFF; ~35 min),
#                   testK7ExpandOpenCloseCycles (K7: five open/close/reopen
#                   cycles of each CE-OPEN expand, per arm, open time and
#                   footprint growth; ~14 min),
#                   testK8TallExpandMountAndFlip (K8: the 300-paragraph
#                   CE-TALL expand mounted and flipped, five launches per
#                   arm alternating, M2-M4; ~15 min),
#                   testK10aFlingThrashSoakContainersSwiftUI,
#                   testK10bFlingThrashSoakContainersTextKit2 (K10: test5's
#                   fling, thrash and soak on containers-dense plus the
#                   container census; ~4 each).
#                   testK1 never selects testK10a (the short-name rule
#                   above). K9 (MediaRowGuardUITests) is not in the list:
#                   --only MediaRowGuardUITests/testK9MediaRowScrollBackSettles.
#   --dry-run       print the plan; touch no simulator, run no xcodebuild.
#                   With a built --derived-data it also checks that the
#                   UI-test bundle holds every selected test.
#
# PASS (exit 0) only when every selected test case printed `passed` and every
# recorded check passed. Exit 1 on any failure/skip/missing result, 2 on
# usage errors and when the built UI-test bundle lacks a selected test (the
# run then stops before the device is touched). Estimated duration: ~43 min
# for tests 1-8 (test7 ~30, the two soak tests ~3 each) + ~70 min for the
# list tests (testL6 ~30) + ~61 min for the code tests (testC6 ~30) + ~112
# min for the container tests (testK6 ~35) = ~288 min, plus ~4 min for a
# fresh build; the default --suite-timeout (22600 s, the 13800 s that
# covered ~176 min scaled to ~288) leaves room for a loaded host. A failed
# check whose record carries failure_class (a no-switch control drift over
# 2 px) is the known lifecycle flake (Fable F16): rerun it with --only;
# limits are never re-tuned.
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
# PR 3's code-block tests (PR 3 plan §6, C1–C6). The method names are the
# contract with Demo/ADFReaderUITests/LifecycleUITests.swift: when a test is
# named differently there, change the name HERE (the run refuses a build
# whose UI-test bundle lacks a selected test, so a mismatch cannot pass).
CODE_TESTS="testC1CodeFiveRoundTripsCodeDense testC1bCodeFiveRoundTripsPannedWideBlock testC2CodeCollapseRoundTripBothDirections testC3CodeTextSizeDriftMatchesSwiftUI testC4CodeSwitchDuringStreamingLoad testC5aFlingThrashSoakCodeDenseSwiftUI testC5bFlingThrashSoakCodeDenseTextKit2 testC6TwentyFlipsCodeDense"
# PR 4's container tests (PR 4 plan §8.2: the testK names in its order,
# K9 excluded — it runs in its own class). The same contract as CODE_TESTS.
# A step that adds a name here updates, in the same commit, the usage text
# above, SUITE_TIMEOUT (sized from the estimate above plus the test's pilot
# duration) and the pins of Scripts/tests/gate-scripts-tests.sh
# (CONTAINER_TESTS_EXPECTED, EXPECTED_SUITE_TIMEOUT).
CONTAINER_TESTS="testK1SwitchRoundTripsAtContainerLandmarks testK2OpenExpandRoundTripAcrossSwitch testK3WidthAndTypeSizeChangesInContainers testK4SwitchDuringLoadAndSearchInContainers testK5aFlingOpenExpandsSwiftUI testK5bFlingOpenExpandsTextKit2 testK6TwentyFlipsContainers testK7ExpandOpenCloseCycles testK8TallExpandMountAndFlip testK10aFlingThrashSoakContainersSwiftUI testK10bFlingThrashSoakContainersTextKit2"
ALL_TESTS="test1CollapseRoundTripKeepsRows test2RotationRoundTripDriftMatchesSwiftUI test3SwitchDuringStreamingLoad test4SwitchKeepsSearchExpandAndTasks test5FlingThrashSoakSwiftUI test6FlingThrashSoakTextKit2 test7TwentyFlipsReleaseRows test8RendererLaunchFlagsAndPersistence testL1ListFiveRoundTripsAtParkedPositions testL1bListFiveRoundTripsListDense testL2ListCollapseRoundTripBothDirections testL3aListRotateAndSizeDriftMatchesSwiftUI testL3bListStateSurvivesRotateSizeAndSwitch testL3cListStateSurvivesRotateSizeAndSwitchListDense testL4aListSwitchDuringStreamingLoad testL4bListCollidingIDsReplacementDocument testL5aFlingThrashSoakListDenseSwiftUI testL5bFlingThrashSoakListDenseTextKit2 testL6TwentyFlipsListDense $CODE_TESTS${CONTAINER_TESTS:+ $CONTAINER_TESTS}"

UDID=""; OUT=""; DERIVED_DATA=""; SKIP_BUILD=0; ONLY=""; SUITE_TIMEOUT=22600; GRACE=120
KEEP_BOOTED=0; DRY_RUN=0; ALLOW_OTHERS=0; K3_CROSSING=""

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }
log() { printf '[lifecycle-gate %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "error: $*"; exit 2; }

# ------------------------------------------------------------ pure helpers --
# (Sourced by tests with LIFECYCLE_GATE_SOURCED=1; no side effects.)

# A selected test is "<method>" (of $CLASS) or "<Class>/<method>".
test_class() { case "$1" in */*) printf '%s\n' "${1%%/*}" ;; *) printf '%s\n' "$CLASS" ;; esac; }
test_method() { printf '%s\n' "${1##*/}"; }
test_id() { printf 'ADFReaderUITests/%s/%s\n' "$(test_class "$1")" "$(test_method "$1")"; }
# The verdict-line pattern (grep -E) of a selected test.
test_verdict_pattern() {
    printf "Test Case '-\\[ADFReaderUITests\\.%s %s\\]' (passed|failed|skipped)\n" \
        "$(test_class "$1")" "$(test_method "$1")"
}

# resolve_test <--only value>: the selected test it names; returns 1 for
# anything else. An ALL_TESTS method, exactly; or the one ALL_TESTS method
# that is <value> followed by an upper-case letter (testC1 →
# testC1Code…, never testC1b…); or <Class>/<method> for another class.
resolve_test() {
    local want="$1" t match="" count=0
    if [[ "$want" == */* ]]; then
        [[ "$want" =~ ^[A-Za-z][A-Za-z0-9_]*/test[A-Za-z0-9_]*$ ]] || return 1
        if [[ "${want%%/*}" != "$CLASS" ]]; then printf '%s\n' "$want"; return 0; fi
        want="${want##*/}"
    fi
    [[ "$want" =~ ^test[A-Za-z0-9_]*$ ]] || return 1
    for t in $ALL_TESTS; do
        if [[ "$t" == "$want" ]]; then printf '%s\n' "$t"; return 0; fi
    done
    for t in $ALL_TESTS; do
        if [[ "$t" == "$want"[[:upper:]]* ]]; then match="$t"; count=$(( count + 1 )); fi
    done
    [[ $count -eq 1 ]] || return 1
    printf '%s\n' "$match"
}

# ALL_TESTS methods that start with $1 (a hint for an unknown --only value).
tests_starting_with() {
    local t out=""
    for t in $ALL_TESTS; do
        [[ "$t" != "$1"* ]] || out="${out:+$out }$t"
    done
    printf '%s\n' "$out"
}

# recorded_build_sha <run dir>: the app sha256 an earlier run's
# lifecycle.md records on its build line (nothing when there is none).
recorded_build_sha() {
    sed -n 's/^- build: .* sha256=\([0-9a-f]\{64\}\)$/\1/p' "$1/lifecycle.md" 2>/dev/null | head -n 1
}

# missing_tests <UI-test bundle binary> <selected test>...: the selected
# tests whose method name the binary does not hold (the selector XCTest
# discovers a test by), one per line.
missing_tests() {
    local binary="$1" t
    shift
    for t in "$@"; do
        LC_ALL=C grep -aqF -- "$(test_method "$t")" "$binary" 2>/dev/null || printf '%s\n' "$t"
    done
}

if [[ "${LIFECYCLE_GATE_SOURCED:-0}" == "1" ]]; then
    # shellcheck disable=SC2317  # reached only when executed, not sourced
    return 0 2>/dev/null || exit 0
fi

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
        --k3-crossing) [[ -d "$2" && "$2" != *[[:space:]]* ]] || die "--k3-crossing needs a run directory without spaces: '$2'"
            K3_CROSSING="${K3_CROSSING:+$K3_CROSSING }$(cd "$2" && pwd)"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
done
[[ -n "$UDID" ]] || die "--udid is required"
[[ -n "$OUT" ]] || die "--out is required"
[[ "$SUITE_TIMEOUT" =~ ^[0-9]+$ && "$GRACE" =~ ^[0-9]+$ ]] || die "--suite-timeout and --xcodebuild-grace are whole seconds"
TESTS=""
for t in ${ONLY:-$ALL_TESTS}; do
    resolved="$(resolve_test "$t")" || {
        hint="$(tests_starting_with "$t")"
        die "unknown test '$t'${hint:+ (did you mean: $hint)} (see --help)"
    }
    case " $TESTS " in *" $resolved "*) ;; *) TESTS="${TESTS:+$TESTS }$resolved" ;; esac
done
# The report's K3 crossing evidence (D-R5): never empty (bash 3.2, set -u).
REPORT_EXTRA=(--meta "k3_crossing=${K3_CROSSING:-none}")
for dir in $K3_CROSSING; do
    [[ -s "$dir/results.jsonl" ]] || die "--k3-crossing $dir holds no results.jsonl (give an earlier run's --out)"
    REPORT_EXTRA+=(--crossing-results "$dir/results.jsonl")
done
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
[[ -n "$DERIVED_DATA" ]] || DERIVED_DATA="$OUT/DerivedData"
CHANNEL="$OUT/channel"; RESULTS="$OUT/results.jsonl"; AGENT_LOG="$OUT/agent.log"
TEST_LOG="$OUT/xcodebuild.log"; BUILD_LOG="$OUT/build.log"; RESULT_BUNDLE="$OUT/lifecycle.xcresult"
APP="$DERIVED_DATA/Build/Products/Release-iphonesimulator/ADFReader.app"
UITEST_BINARY="$DERIVED_DATA/Build/Products/Release-iphonesimulator/ADFReaderUITests-Runner.app/PlugIns/ADFReaderUITests.xctest/ADFReaderUITests"

ONLY_ARGS=()
for t in $TESTS; do ONLY_ARGS+=("-only-testing:$(test_id "$t")"); done
# Selected tests the built UI-test bundle lacks, space separated.
bundle_missing() {
    # shellcheck disable=SC2086  # $TESTS is a word list
    missing_tests "$UITEST_BINARY" $TESTS | tr '\n' ' ' | sed 's/ *$//'
}
BUILD_CMD=(xcodebuild build-for-testing -project "$DEMO_DIR/ADFReader.xcodeproj" -scheme ADFReader
    -configuration Release -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DERIVED_DATA"
    CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES)

if [[ $DRY_RUN -eq 1 ]]; then
    echo "tests:        $TESTS"
    if [[ $SKIP_BUILD -eq 1 ]]; then echo "build:        skipped (reuse $DERIVED_DATA)"
    else echo "build:        ( cd $DEMO_DIR && $XCODEGEN generate ) && ${BUILD_CMD[*]}"; fi
    echo "agent:        python3 -I -u $AGENT_PY serve --udid $UDID --channel $CHANNEL --results $RESULTS --log $AGENT_LOG"
    echo "test:         TEST_RUNNER_ADF_LIFECYCLE_DIR=$CHANNEL xcodebuild test-without-building -xctestrun <exact> -destination 'platform=iOS Simulator,id=$UDID' ${ONLY_ARGS[*]} -resultBundlePath $RESULT_BUNDLE"
    echo "k3 crossing:  ${K3_CROSSING:-none (only a K3 of this run that crosses can pass its crossing row)}"
    echo "report:       python3 -I $AGENT_PY report --results $RESULTS --out $OUT/lifecycle.md ${REPORT_EXTRA[*]}"
    echo "suite timeout: ${SUITE_TIMEOUT}s"
    if [[ -f "$UITEST_BINARY" ]]; then
        MISSING="$(bundle_missing)"
        echo "bundle check: ${MISSING:+MISSING from $UITEST_BINARY: }${MISSING:-every selected test is in $UITEST_BINARY}"
        [[ -z "$MISSING" ]] || exit 2
    else
        echo "bundle check: not built yet ($UITEST_BINARY)"
    fi
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
[[ -f "$UITEST_BINARY" ]] || die "no UI-test bundle binary at $UITEST_BINARY"
MISSING="$(bundle_missing)"
[[ -z "$MISSING" ]] || die "the UI-test bundle has no $MISSING; was it built from a checkout without those tests, or are they named differently (see CODE_TESTS)?"
XCTESTRUN="$(select_xctestrun "$DERIVED_DATA")" || die "cannot pick the xctestrun"
BUILD_SHA="$(shasum -a 256 "$APP/ADFReader" | awk '{print $1}')"
for dir in $K3_CROSSING; do
    crossing_sha="$(recorded_build_sha "$dir")"
    [[ "$crossing_sha" == "$BUILD_SHA" ]] || die "--k3-crossing $dir ran build sha256=${crossing_sha:-unknown}; this build is $BUILD_SHA"
done

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
        if tr -d '\r' <"$TEST_LOG" 2>/dev/null | grep -Eq "$(test_verdict_pattern "$t")"; then
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
    line="$(tr -d '\r' <"$TEST_LOG" | grep -E "$(test_verdict_pattern "$t")" | tail -n 1 || true)"
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
    "${REPORT_EXTRA[@]}" || REPORT_STATUS=$?
[[ $REPORT_STATUS -eq 0 ]] || problems=$((problems + 1))
log "report: $OUT/lifecycle.md"
if (( problems > 0 )); then
    log "FAIL: $problems problem(s)"
    exit 1
fi
log "PASS: every lifecycle check passed"
