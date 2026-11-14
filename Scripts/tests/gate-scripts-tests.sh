#!/usr/bin/env bash
# Scripts/tests/gate-scripts-tests.sh — offline cases for what PR 3 added to
# Scripts/visual-parity.sh (code capture positions and declarations),
# Scripts/e2e-video.sh (--test code) and Scripts/lifecycle-gate.sh (the
# code tests, short names, tests of another class, the bundle check): their
# --dry-run plans and their pure helpers.
#
# USAGE
#   Scripts/tests/gate-scripts-tests.sh <workdir>
#
# No simulator, no build, no app: every script runs with --dry-run or is
# sourced for its helpers (E2E_VIDEO_SOURCED=1, LIFECYCLE_GATE_SOURCED=1).
# <workdir> (outside the repository; use a fresh one) receives each
# command's output. A few seconds. Needs python3 with numpy and Pillow for
# one case (the scorer parsing the declarations visual-parity.sh emits).
# Runs under the bash that runs it: `/bin/bash Scripts/tests/…` checks
# bash 3.2. Prints one line per case and "<passed>/<total> passed"; exits 1
# on any mismatch.
#
# The last section reads Demo/ADFReaderUITests/*.swift (text only): every
# test the scripts name must be declared there, and every host-agent
# request the tests send must be one lifecycle_agent.py answers. A case
# about a test file that does not exist yet is printed as "skip" and not
# counted.

set -uo pipefail

[ "$#" -ge 1 ] || { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
WORK="$1"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
PARITY="$SCRIPTS/visual-parity.sh"
E2E="$SCRIPTS/e2e-video.sh"
GATE="$SCRIPTS/lifecycle-gate.sh"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
export PYTHONDONTWRITEBYTECODE=1

PASSED=0
FAILED=0
SKIPPED=0
skip() { SKIPPED=$(( SKIPPED + 1 )); printf 'skip %s\n' "$1"; }
pass() { PASSED=$(( PASSED + 1 )); printf 'ok   %s\n' "$1"; }
fail() {
    FAILED=$(( FAILED + 1 ))
    printf 'FAIL %s\n' "$1"
    shift
    [ "$#" -eq 0 ] || printf '       %s\n' "$@"
}
expect_eq() {   # <label> <got> <want>
    if [ "$2" == "$3" ]; then pass "$1"; else fail "$1" "got  '$2'" "want '$3'"; fi
}
expect_has() {   # <label> <file> <fixed string>
    if grep -qF -- "$3" "$2" 2>/dev/null; then pass "$1"; else fail "$1" "'$3' not in $2"; fi
}
expect_lacks() {   # <label> <file> <fixed string>
    if grep -qF -- "$3" "$2" 2>/dev/null; then fail "$1" "'$3' is in $2"; else pass "$1"; fi
}
# run <name> <command...>: output to $WORK/<name>.out, status in $STATUS.
run() {
    local name="$1"
    shift
    "$@" >"$WORK/$name.out" 2>&1
    STATUS=$?
}
count_of() { grep -cF -- "$2" "$1" 2>/dev/null || true; }

# ============================================================ visual-parity ==

parity() {   # <name> <args...>: a dry run of visual-parity.sh
    local name="$1"
    shift
    run "$name" "$BASH" "$PARITY" --udid FAKE-UDID-0001 --out "$WORK/$name" --dry-run "$@"
}
# The --code-capture declarations of a dry run's score command, one
# "<pair>|<class>|<owners>|<engine>|<log>" per line; pairs to <name>.pairs.
declarations() {
    local name="$1" line
    line="$(grep -A1 '^score:' "$WORK/$name.out" | tail -n 1)"
    eval "set -- $line"
    : >"$WORK/$name.decl"
    : >"$WORK/$name.pairs"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --code-capture) printf '%s|%s|%s|%s|%s\n' "$2" "$3" "$4" "$5" "$6" >>"$WORK/$name.decl"; shift 6 ;;
            --pair) printf '%s\n' "$3" >>"$WORK/$name.pairs"; shift 5 ;;
            *) shift ;;
        esac
    done
}
lines_of() { wc -l <"$1" | tr -d ' '; }

parity vp-default
expect_eq "default plan is a dry run that exits 0" "$STATUS" "0"
declarations vp-default
OUT="$WORK/vp-default"
expect_has "default plan: 22 positions x 2 appearances x 2 sizes" "$OUT.out" "captures:     88 configurations x arms (A A2 B C)"
expect_eq "default plan scores three pairs per configuration" "$(lines_of "$OUT.pairs")" "264"
# Every PR 1 and PR 2 default position is still captured.
for cfg in kitchen-sink-p0 kitchen-sink-p0.5 stress-5k-p0 stress-5k-p0.5 lists-parity-p0 lists-parity-p0.119 \
    lists-parity-p0.214 lists-parity-p0.357 lists-parity-p0.405 lists-parity-p0.452 lists-parity-p0.548 \
    lists-parity-p0.643 list-dense-p0.761; do
    expect_has "PR 1/PR 2 position kept: $cfg" "$OUT.pairs" "$cfg-light-s0-AC"
done
# The PR 3 positions, in both appearances and at both sizes.
for cfg in kitchen-sink-p0.275 code-parity-p0 code-parity-p0.19 code-parity-p0.28 code-parity-p0.515 \
    code-parity-p0.66 code-parity-p0.87 code-dense-p0 code-dense-p0.5; do
    found=0
    for variant in light-s0 light-s3 dark-s0 dark-s3; do
        if grep -qxF -- "$cfg-$variant-AC" "$OUT.pairs"; then found=$(( found + 1 )); fi
    done
    expect_eq "PR 3 position captured light/dark at steps 0 and 3: $cfg" "$found" "4"
done
expect_has "the kitchen-sink code position is launched as -scrollToFraction 0.275" "$OUT.out" \
    "-fixture kitchen-sink -scrollToFraction 0.275 -fontSizeStep 3 -rendererReset -rendererStats -textkit2"
expect_eq "nine code positions x 4 x three pairs are declared" "$(lines_of "$OUT.decl")" "108"
expect_has "kitchen-sink names code block 0.12 native and lands on 0.10" "$OUT.decl" \
    "kitchen-sink-p0.275-dark-s3-AC|positive|0.12=tk2;land=0.10|textkit2|$OUT/captures/kitchen-sink-p0.275-dark-s3-C.log"
expect_has "arm B of a positive capture must prove SwiftUI from its own log" "$OUT.decl" \
    "kitchen-sink-p0.275-dark-s3-AB|positive|0.12=tk2;land=0.10|swiftui|$OUT/captures/kitchen-sink-p0.275-dark-s3-B.log"
expect_has "the noise pair asks for no engine proof (the reference prints no stats)" "$OUT.decl" \
    "kitchen-sink-p0.275-dark-s3-AA|positive|0.12=tk2;land=0.10|none|-"
expect_has "CP-S4 at step 0 is positive on the near-budget block" "$OUT.decl" \
    "code-parity-p0.515-light-s0-AC|positive|0.18=swiftui,0.19=tk2,0.20=swiftui;land=0.17|textkit2|"
expect_has "CP-S4 at step 3 is declared fallback (#s3 beats the step-less declaration)" "$OUT.decl" \
    "code-parity-p0.515-light-s3-AC|fallback|0.18=swiftui,0.19=swiftui;land=0.17|textkit2|"
expect_has "CP-S5 (tabs, non-ASCII) is expected fallback" "$OUT.decl" \
    "code-parity-p0.66-dark-s0-AC|fallback|0.23=swiftui,0.24=swiftui,0.25=swiftui,0.26=swiftui;land=0.22|textkit2|"
expect_has "CP-S6 (nested code) is expected fallback with nested owner ids" "$OUT.decl" \
    "code-parity-p0.87-light-s0-AC|fallback|0.30.0.1=swiftui,0.31.1=swiftui;land=0.29|textkit2|"
expect_has "code-dense@0.5 is positive on blocks 300 and 301" "$OUT.decl" \
    "code-dense-p0.5-light-s3-AC|positive|0.300=tk2,0.301=tk2;land=0.300|textkit2|"
expect_has "code-dense@0 is positive on the three pinned blocks" "$OUT.decl" \
    "code-dense-p0-dark-s0-AC|positive|0.0=tk2,0.1=tk2,0.2=tk2;land=0.0|textkit2|"
expect_eq "positive and fallback configurations: 26 + 10" \
    "$(grep -c -- '-AC|positive|' "$OUT.decl") $(grep -c -- '-AC|fallback|' "$OUT.decl")" "26 10"
expect_lacks "a position without code is not declared" "$OUT.decl" "stress-5k-"
expect_lacks "kitchen-sink@0 (code visible, nothing declared) stays undeclared" "$OUT.decl" "kitchen-sink-p0-"
undeclared=0
while IFS='|' read -r pair _; do
    grep -qxF -- "$pair" "$OUT.pairs" || undeclared=$(( undeclared + 1 ))
done <"$OUT.decl"
expect_eq "every declaration names a scored pair" "$undeclared" "0"
expect_has "the dry run lists each declared configuration" "$OUT.out" \
    "  code-parity-p0.515-dark-s3: fallback; 0.18=swiftui,0.19=swiftui;land=0.17"
expect_lacks "owner-level proof is not demanded by default" "$OUT.out" "--require-owner-proof"

# The scorer accepts exactly what the capture script emits.
run vp-parse python3 -I -c '
import importlib.util, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("visual_diff", sys.argv[1])
diff = importlib.util.module_from_spec(spec)
sys.modules["visual_diff"] = diff
spec.loader.exec_module(diff)
items = [line.rstrip("\n").split("|") for line in open(sys.argv[2])]
pairs = {line.strip() for line in open(sys.argv[3])}
rules = diff.parse_code_captures(items, pairs)
native = sum(1 for rule in rules.values() for _, engine in rule.owners if engine == "tk2")
print(len(rules), sum(1 for rule in rules.values() if rule.cls == "positive"), native,
      rules["code-parity-p0.87-light-s0-AC"].land, rules["code-parity-p0.87-light-s0-AC"].owners[0][0])
' "$SCRIPTS/visual_diff.py" "$OUT.decl" "$OUT.pairs"
expect_eq "visual_diff.py parses every emitted declaration" "$STATUS $(cat "$WORK/vp-parse.out")" "0 108 78 150 0.29 0.30.0.1"

parity vp-nostats --no-renderer-stats
declarations vp-nostats
expect_eq "--no-renderer-stats: no pair asks for engine proof" \
    "$STATUS $(lines_of "$WORK/vp-nostats.decl") $(grep -c -- '|none|-$' "$WORK/vp-nostats.decl")" "0 108 108"

parity vp-none --no-code-captures
declarations vp-none
expect_eq "--no-code-captures declares nothing and still captures every position" \
    "$STATUS $(lines_of "$WORK/vp-none.decl") $(lines_of "$WORK/vp-none.pairs")" "0 0 264"
expect_has "--no-code-captures says so" "$WORK/vp-none.out" "  (none)"

parity vp-arms --arms "A C" --fixture code-parity@0.19 --appearances light --size-steps 0
declarations vp-arms
expect_eq "arms A C: one pair, one declaration" "$STATUS $(cat "$WORK/vp-arms.decl")" \
    "0 code-parity-p0.19-light-s0-AC|positive|0.7=tk2,0.8=tk2;land=0.6|textkit2|$WORK/vp-arms/captures/code-parity-p0.19-light-s0-C.log"

parity vp-override --fixture code-dense@0.5 --code-capture 'code-dense@0.5=fallback;0.305=swiftui;land=0.300'
declarations vp-override
expect_eq "an explicit declaration replaces the default for its position" \
    "$STATUS $(grep -c -- '|fallback|0.305=swiftui;land=0.300|' "$WORK/vp-override.decl") $(lines_of "$WORK/vp-override.decl")" "0 12 12"

parity vp-step --fixture code-dense@0.5 --code-capture 'code-dense@0.5#s3=positive;0.302=tk2'
declarations vp-step
expect_eq "an explicit #s3 declaration applies to step 3 only, and land= is optional" \
    "$STATUS $(grep -c -- '-s3-A.|positive|0.302=tk2|' "$WORK/vp-step.decl") $(grep -c -- '-s0-A.|positive|0.300=tk2,0.301=tk2;land=0.300|' "$WORK/vp-step.decl")" \
    "0 6 6"

parity vp-new --fixture code-tall@0 --code-capture 'code-tall@0=fallback;0.1=swiftui'
declarations vp-new
expect_eq "a declaration for a fixture without a default" "$STATUS $(lines_of "$WORK/vp-new.decl")" "0 12"

parity vp-owner --require-owner-proof
expect_has "--require-owner-proof reaches the scorer" "$WORK/vp-owner.out" " --require-owner-proof "

parity vp-bad-syntax --code-capture 'code-dense@0.5=positive'
expect_eq "a declaration without owners is a usage error" "$STATUS" "2"
parity vp-bad-class --code-capture 'code-dense@0.5=native;0.301=tk2'
expect_eq "an unknown class is a usage error" "$STATUS" "2"
parity vp-bad-positive --code-capture 'code-dense@0.5=positive;0.301=swiftui'
expect_eq "positive without a tk2 owner is a usage error" "$STATUS" "2"
expect_has "… and says why" "$WORK/vp-bad-positive.out" "a positive capture needs an owner marked tk2"
parity vp-bad-fallback --code-capture 'code-dense@0.5=fallback;0.301=tk2'
expect_eq "fallback naming a tk2 owner is a usage error" "$STATUS" "2"
parity vp-bad-position --fixture kitchen-sink@0 --code-capture 'code-dense@0.25=positive;0.151=tk2'
expect_eq "a declaration for a position that is not captured is a usage error" "$STATUS" "2"
expect_has "… and names the position" "$WORK/vp-bad-position.out" "no --fixture position code-dense@0.25 in this run"
parity vp-old-default --fixture kitchen-sink@0,0.5
declarations vp-old-default
expect_eq "PR 1's own positions run without any declaration" "$STATUS $(lines_of "$WORK/vp-old-default.decl")" "0 0"

# ================================================================ e2e-video ==

e2e() { E2E_VIDEO_SOURCED=1 "$BASH" -c '. "$0"; "$@"' "$E2E" "$@"; }

expect_eq "--test code names the code storyboard" "$(e2e test_id_for code)" \
    "ADFReaderUITests/CodeRendererUITests/testCodeBlockStoryboard"
expect_eq "--test switch is unchanged" "$(e2e test_id_for switch)" \
    "ADFReaderUITests/RendererSwitchUITests/testLiveSwitchSwiftUIToTextKit2AndBack"
expect_eq "--test lists is unchanged" "$(e2e test_id_for lists)" \
    "ADFReaderUITests/ListStoryboardUITests/testListStoryboardSwiftUIToTextKit2AndBack"
for selector in Code codes cod "" all; do
    e2e test_id_for "$selector" >/dev/null 2>&1
    expect_eq "selector '$selector' is refused (no partial or case-insensitive match)" "$?" "1"
done
CASE="$(e2e test_case_name "$(e2e test_id_for code)")"
expect_eq "the code storyboard's test case name" "$CASE" "-[ADFReaderUITests.CodeRendererUITests testCodeBlockStoryboard]"

LOGS="$WORK/e2e-logs"
mkdir -p "$LOGS"
printf "Test Case '%s' started.\r\nOBSERVED_BUILD_SHA256=%064d\r\nTest Case '%s' passed (61.204 seconds).\r\n" \
    "$CASE" 7 "$CASE" >"$LOGS/passed.log"
printf "Test Case '%s' started.\n    t =    41.2s CodeRendererUITests.swift:88: error: %s : XCTAssertEqual failed: on-screen checksum differs from the built binary\nTest Case '%s' failed (41.377 seconds).\n" \
    "$CASE" "$CASE" "$CASE" >"$LOGS/negative.log"
printf "Test Case '%s' started.\nTest Case '-[ADFReaderUITests.CodeRendererUITests testCodeBlockStoryboardExtra]' passed (3.1 seconds).\nTest Case '-[ADFReaderUITests.ListStoryboardUITests testListStoryboardSwiftUIToTextKit2AndBack]' failed (9.0 seconds).\n" \
    "$CASE" >"$LOGS/others.log"
expect_eq "a passed result line is found (CRLF log)" "$(e2e named_test_result "$LOGS/passed.log" "$CASE")" "passed"
expect_eq "the observed digest is read from the log" "$(e2e observed_sha_in "$LOGS/passed.log")" "$(printf '%064d' 7)"
expect_eq "a failed result line is found" "$(e2e named_test_result "$LOGS/negative.log" "$CASE")" "failed"
expect_eq "other tests' result lines are not the code storyboard's" "$(e2e named_test_result "$LOGS/others.log" "$CASE")" ""
expect_eq "the manifest line is the code storyboard's own" "$(e2e named_test_line "$LOGS/negative.log" "$CASE")" \
    "Test Case '$CASE' failed (41.377 seconds)."
DIGEST_TEXT="$(e2e eval 'printf "%s\n" "$DIGEST_FAILURE_TEXT"')"
expect_eq "the checksum assertion text the negative control looks for" "$DIGEST_TEXT" \
    "on-screen checksum differs from the built binary"
expect_has "negative control: the code storyboard's checksum failure is recognised" "$LOGS/negative.log" "$DIGEST_TEXT"
expect_lacks "negative control: a pass carries no checksum failure" "$LOGS/passed.log" "$DIGEST_TEXT"
printf 'padding\0testListStoryboardSwiftUIToTextKit2AndBack\0testCodeBlockStoryboard\0more' >"$LOGS/bundle-pr3.bin"
printf 'padding\0testListStoryboardSwiftUIToTextKit2AndBack\0more' >"$LOGS/bundle-pr2.bin"
e2e binary_has_test "$LOGS/bundle-pr3.bin" testCodeBlockStoryboard
expect_eq "a bundle built with the code storyboard is accepted" "$?" "0"
e2e binary_has_test "$LOGS/bundle-pr2.bin" testCodeBlockStoryboard
expect_eq "a bundle without it (a PR 2 build) is refused" "$?" "1"
WRONG="$(e2e wrong_digest_for "$(printf '%064d' 7)")"
expect_eq "the negative control's digest differs from the build's" \
    "$([ "$WRONG" != "$(printf '%064d' 7)" ] && [ "${#WRONG}" -eq 64 ] && echo differs)" "differs"

run e2e-code "$BASH" "$E2E" --udid FAKE-UDID-0001 --out "$WORK/e2e-out/code.mp4" --test code --dry-run
expect_eq "--test code --dry-run exits 0" "$STATUS" "0"
expect_has "… and runs only the code storyboard" "$WORK/e2e-code.out" \
    "-only-testing:ADFReaderUITests/CodeRendererUITests/testCodeBlockStoryboard -resultBundlePath"
expect_has "… and waits for its result line" "$WORK/e2e-code.out" "after \"Test Case '$CASE' passed|failed\""
run e2e-code-reuse "$BASH" "$E2E" --udid FAKE-UDID-0001 --out "$WORK/e2e-out/code2.mp4" --test code --skip-build \
    --derived-data "$WORK/e2e-out/switch.DerivedData" --dry-run
expect_has "the code video reuses the switch video's build" "$WORK/e2e-code-reuse.out" \
    "derived data:   $WORK/e2e-out/switch.DerivedData (reused)"
expect_lacks "… without building again" "$WORK/e2e-code-reuse.out" "build-for-testing"
run e2e-code-negative "$BASH" "$E2E" --udid FAKE-UDID-0001 --out "$WORK/e2e-out/negative/code.mp4" --test code --negative --dry-run
expect_eq "--test code --negative is accepted" "$STATUS" "0"
expect_has "… as the wrong-digest control" "$WORK/e2e-code-negative.out" "digest:         deliberately wrong (negative control)"
run e2e-bad "$BASH" "$E2E" --udid FAKE-UDID-0001 --out "$WORK/e2e-out/bad.mp4" --test codes --dry-run
expect_eq "an unknown --test is a usage error" "$STATUS" "2"
expect_has "… that names the three selectors" "$WORK/e2e-bad.out" "--test must be 'switch', 'lists' or 'code' (got 'codes')"
run e2e-lists "$BASH" "$E2E" --udid FAKE-UDID-0001 --out "$WORK/e2e-out/lists.mp4" --test lists --dry-run
expect_has "--test lists still records the list storyboard" "$WORK/e2e-lists.out" \
    "-only-testing:ADFReaderUITests/ListStoryboardUITests/testListStoryboardSwiftUIToTextKit2AndBack"
run e2e-default "$BASH" "$E2E" --udid FAKE-UDID-0001 --out "$WORK/e2e-out/default.mp4" --dry-run
expect_has "the default is still the switch test" "$WORK/e2e-default.out" "test selector:  switch"

# ============================================================ lifecycle-gate ==

gate() { LIFECYCLE_GATE_SOURCED=1 "$BASH" -c '. "$0"; "$@"' "$GATE" "$@"; }

OLD_TESTS="test1CollapseRoundTripKeepsRows test2RotationRoundTripDriftMatchesSwiftUI test3SwitchDuringStreamingLoad test4SwitchKeepsSearchExpandAndTasks test5FlingThrashSoakSwiftUI test6FlingThrashSoakTextKit2 test7TwentyFlipsReleaseRows test8RendererLaunchFlagsAndPersistence testL1ListFiveRoundTripsAtParkedPositions testL1bListFiveRoundTripsListDense testL2ListCollapseRoundTripBothDirections testL3aListRotateAndSizeDriftMatchesSwiftUI testL3bListStateSurvivesRotateSizeAndSwitch testL3cListStateSurvivesRotateSizeAndSwitchListDense testL4aListSwitchDuringStreamingLoad testL4bListCollidingIDsReplacementDocument testL5aFlingThrashSoakListDenseSwiftUI testL5bFlingThrashSoakListDenseTextKit2 testL6TwentyFlipsListDense"
NEW_TESTS="testC1CodeFiveRoundTripsCodeDense testC1bCodeFiveRoundTripsPannedWideBlock testC2CodeCollapseRoundTripBothDirections testC3CodeTextSizeDriftMatchesSwiftUI testC4CodeSwitchDuringStreamingLoad testC5aFlingThrashSoakCodeDenseSwiftUI testC5bFlingThrashSoakCodeDenseTextKit2 testC6TwentyFlipsCodeDense"
expect_eq "ALL_TESTS = tests 1-8 and L1-L6 in their order, then C1-C6" \
    "$(gate eval 'printf "%s\n" "$ALL_TESTS"')" "$OLD_TESTS $NEW_TESTS"

resolves() {   # <short> <full>
    expect_eq "--only $1 selects $2" "$(gate resolve_test "$1")" "$2"
}
resolves testC1 testC1CodeFiveRoundTripsCodeDense
resolves testC1b testC1bCodeFiveRoundTripsPannedWideBlock
resolves testC2 testC2CodeCollapseRoundTripBothDirections
resolves testC3 testC3CodeTextSizeDriftMatchesSwiftUI
resolves testC4 testC4CodeSwitchDuringStreamingLoad
resolves testC5a testC5aFlingThrashSoakCodeDenseSwiftUI
resolves testC5b testC5bFlingThrashSoakCodeDenseTextKit2
resolves testC6 testC6TwentyFlipsCodeDense
resolves testC6TwentyFlipsCodeDense testC6TwentyFlipsCodeDense
resolves test1 test1CollapseRoundTripKeepsRows
resolves testL1 testL1ListFiveRoundTripsAtParkedPositions
resolves testL1b testL1bListFiveRoundTripsListDense
resolves LifecycleUITests/testC4 testC4CodeSwitchDuringStreamingLoad
resolves CodeRendererUITests/testCopyPutsExactCodeOnPasteboard CodeRendererUITests/testCopyPutsExactCodeOnPasteboard
for unknown in testC5 testL3 testC7 testC testc1 C1 "CodeRendererUITests/copy" "A/B/testX" "LifecycleUITests/testNope" 'test*'; do
    gate resolve_test "$unknown" >/dev/null 2>&1
    expect_eq "--only '$unknown' is refused" "$?" "1"
done
expect_eq "an ambiguous short name gets its candidates as a hint" "$(gate tests_starting_with testC5)" \
    "testC5aFlingThrashSoakCodeDenseSwiftUI testC5bFlingThrashSoakCodeDenseTextKit2"
expect_eq "the test id of a lifecycle test" "$(gate test_id testC6TwentyFlipsCodeDense)" \
    "ADFReaderUITests/LifecycleUITests/testC6TwentyFlipsCodeDense"
expect_eq "the test id of another class's test" "$(gate test_id CodeRendererUITests/testCopyX)" \
    "ADFReaderUITests/CodeRendererUITests/testCopyX"

GLOGS="$WORK/gate-logs"
mkdir -p "$GLOGS"
printf "Test Case '-[ADFReaderUITests.LifecycleUITests testC1bCodeFiveRoundTripsPannedWideBlock]' passed (118.2 seconds).\r\nTest Case '-[ADFReaderUITests.LifecycleUITests testC1CodeFiveRoundTripsCodeDense]' started.\r\nTest Case '-[ADFReaderUITests.CodeRendererUITests testCopyX]' failed (8.0 seconds).\r\n" >"$GLOGS/run.log"
verdicts() { tr -d '\r' <"$GLOGS/run.log" | grep -Ec "$(gate test_verdict_pattern "$1")" || true; }
expect_eq "C1b's verdict line is C1b's" "$(verdicts testC1bCodeFiveRoundTripsPannedWideBlock)" "1"
expect_eq "C1 has no verdict yet (C1b's line and its own 'started' do not count)" "$(verdicts testC1CodeFiveRoundTripsCodeDense)" "0"
expect_eq "another class's verdict is matched under its own class" "$(verdicts CodeRendererUITests/testCopyX)" "1"
expect_eq "… and not under LifecycleUITests" "$(verdicts testCopyX)" "0"

# A fake derived-data dir whose UI-test bundle binary holds the given names.
fake_build() {   # <dir> <method>...
    local dir="$1/Build/Products/Release-iphonesimulator/ADFReaderUITests-Runner.app/PlugIns/ADFReaderUITests.xctest" t
    shift
    mkdir -p "$dir"
    printf 'MACHO\0' >"$dir/ADFReaderUITests"
    for t in "$@"; do printf '%s\0' "$t" >>"$dir/ADFReaderUITests"; done
}
# shellcheck disable=SC2086  # word lists
fake_build "$WORK/dd-pr3" $OLD_TESTS $NEW_TESTS testCopyPutsExactCodeOnPasteboard
# shellcheck disable=SC2086
fake_build "$WORK/dd-pr2" $OLD_TESTS
PR3_BIN="$WORK/dd-pr3/Build/Products/Release-iphonesimulator/ADFReaderUITests-Runner.app/PlugIns/ADFReaderUITests.xctest/ADFReaderUITests"
PR2_BIN="$WORK/dd-pr2/Build/Products/Release-iphonesimulator/ADFReaderUITests-Runner.app/PlugIns/ADFReaderUITests.xctest/ADFReaderUITests"
expect_eq "a PR 3 bundle holds every selected test" \
    "$(gate missing_tests "$PR3_BIN" testC1CodeFiveRoundTripsCodeDense CodeRendererUITests/testCopyPutsExactCodeOnPasteboard | tr '\n' ' ')" ""
expect_eq "a PR 2 bundle lacks the code tests, and only those" \
    "$(gate missing_tests "$PR2_BIN" testL6TwentyFlipsListDense testC1CodeFiveRoundTripsCodeDense CodeRendererUITests/testCopyPutsExactCodeOnPasteboard | tr '\n' ' ')" \
    "testC1CodeFiveRoundTripsCodeDense CodeRendererUITests/testCopyPutsExactCodeOnPasteboard "
expect_eq "a missing bundle lacks everything" "$(gate missing_tests "$WORK/none" testC4CodeSwitchDuringStreamingLoad)" \
    "testC4CodeSwitchDuringStreamingLoad"

lifecycle() {   # <name> <args...>: a dry run of lifecycle-gate.sh
    local name="$1"
    shift
    run "$name" "$BASH" "$GATE" --udid FAKE-UDID-0001 --out "$WORK/$name" --dry-run "$@"
}
lifecycle lg-default
expect_eq "the default plan is a dry run that exits 0" "$STATUS" "0"
expect_has "the default plan runs all 27 tests in order" "$WORK/lg-default.out" "tests:        $OLD_TESTS $NEW_TESTS"
expect_eq "… each as its own -only-testing id" \
    "$(grep '^test: ' "$WORK/lg-default.out" | grep -o -- '-only-testing:ADFReaderUITests/LifecycleUITests/test[A-Za-z0-9]*' | sort -u | wc -l | tr -d ' ')" "27"
expect_has "the default suite timeout covers the longer suite" "$WORK/lg-default.out" "suite timeout: 13800s"
expect_has "the agent is the one the tests talk to" "$WORK/lg-default.out" "lifecycle_agent.py serve --udid FAKE-UDID-0001"
expect_has "an unbuilt derived-data dir is reported, not an error" "$WORK/lg-default.out" "bundle check: not built yet"

lifecycle lg-short --only testC1 --only testC5b --only testC1CodeFiveRoundTripsCodeDense
expect_has "short names resolve and a test named twice runs once" "$WORK/lg-short.out" \
    "tests:        testC1CodeFiveRoundTripsCodeDense testC5bFlingThrashSoakCodeDenseTextKit2"
lifecycle lg-other --only testC4 --only CodeRendererUITests/testCopyPutsExactCodeOnPasteboard
expect_has "a test of another class runs beside the agent" "$WORK/lg-other.out" \
    "-only-testing:ADFReaderUITests/LifecycleUITests/testC4CodeSwitchDuringStreamingLoad -only-testing:ADFReaderUITests/CodeRendererUITests/testCopyPutsExactCodeOnPasteboard -resultBundlePath"
lifecycle lg-ambiguous --only testC5
expect_eq "an ambiguous short name is a usage error" "$STATUS" "2"
expect_has "… with the candidates" "$WORK/lg-ambiguous.out" \
    "unknown test 'testC5' (did you mean: testC5aFlingThrashSoakCodeDenseSwiftUI testC5bFlingThrashSoakCodeDenseTextKit2)"
lifecycle lg-unknown --only testC9
expect_eq "an unknown test is a usage error" "$STATUS" "2"
lifecycle lg-timeout --suite-timeout 2h
expect_eq "a suite timeout that is not whole seconds is a usage error" "$STATUS" "2"

lifecycle lg-built --skip-build --derived-data "$WORK/dd-pr3"
expect_eq "a PR 3 build passes the bundle check" "$STATUS" "0"
expect_has "… and says so" "$WORK/lg-built.out" "bundle check: every selected test is in $PR3_BIN"
lifecycle lg-stale --skip-build --derived-data "$WORK/dd-pr2"
expect_eq "a PR 2 build fails the bundle check (exit 2, before any device is touched)" "$STATUS" "2"
expect_has "… naming the missing tests" "$WORK/lg-stale.out" \
    "bundle check: MISSING from $PR2_BIN: $NEW_TESTS"
lifecycle lg-stale-lists --skip-build --derived-data "$WORK/dd-pr2" --only testL1 --only test7
expect_eq "the same PR 2 build still runs its own tests" "$STATUS" "0"
lifecycle lg-stale-copy --skip-build --derived-data "$WORK/dd-pr2" --only CodeRendererUITests/testCopyPutsExactCodeOnPasteboard
expect_eq "another class's test missing from the bundle fails the check" "$STATUS" "2"

# ====================================================== UI test sources ==

UITESTS="$SCRIPTS/../Demo/ADFReaderUITests"
# The file that declares class $1, or nothing.
class_file() { grep -lE "^(final )?class $1([^A-Za-z0-9_]|\$)" "$UITESTS"/*.swift 2>/dev/null | head -n 1; }
# Whether class $1 declares the test method $2.
declares() {
    local file
    file="$(class_file "$1")"
    [ -n "$file" ] && grep -qE "^[[:space:]]*func $2[(][)]" "$file"
}

undeclared=""
# shellcheck disable=SC2086  # word lists
for t in $OLD_TESTS $NEW_TESTS; do
    declares LifecycleUITests "$t" || undeclared="$undeclared $t"
done
expect_eq "every ALL_TESTS method is declared in LifecycleUITests" "$undeclared" ""
extra=""
for t in $(grep -ohE '^[[:space:]]*func test[A-Za-z0-9_]*[(][)]' "$UITESTS/LifecycleUITests.swift" | sed -E 's/^[[:space:]]*func //; s/[(][)]$//'); do
    case " $OLD_TESTS $NEW_TESTS " in
        *" $t "*) ;;
        *) extra="$extra $t" ;;
    esac
done
expect_eq "every LifecycleUITests test method is in ALL_TESTS" "$extra" ""

for selector in switch lists code; do
    id="$(e2e test_id_for "$selector")"
    cls="${id#*/}"; cls="${cls%%/*}"; method="${id##*/}"
    file="$(class_file "$cls")"
    if [ -z "$file" ]; then
        skip "--test $selector: $cls is not written yet (it must declare $method)"
        continue
    fi
    declares "$cls" "$method"
    expect_eq "--test $selector: $cls declares $method" "$?" "0"
    expect_has "… and fails on a wrong digest with the text the negative control looks for" "$file" "$DIGEST_TEXT"
    expect_has "… and prints the digest it observed" "$file" 'OBSERVED_BUILD_SHA256=\('
    expect_has "… and reads the expected digest from the runner environment" "$file" '"ADF_EXPECTED_BUILD_SHA256"'
done

# Every request kind a UI test sends is one the agent answers.
KINDS="$(grep -ohE '(request[(]|Kind = )"[a-z_]+"' "$UITESTS"/*.swift | sed -E 's/.*"([a-z_]+)"$/\1/' | LC_ALL=C sort -u | tr '\n' ' ')"
KINDS="${KINDS% }"
unanswered=""
for kind in $KINDS; do
    grep -qE "kind (==|in) .*\"$kind\"" "$SCRIPTS/lifecycle_agent.py" || unanswered="$unanswered $kind"
done
expect_eq "the agent answers every request kind the UI tests send ($KINDS)" "$unanswered" ""
case " $KINDS " in
    *" pasteboard "*) pass "the UI tests read the device pasteboard through the agent (kind pasteboard)" ;;
    *) skip "no UI test reads the pasteboard through the agent yet" ;;
esac

echo
echo "$PASSED/$(( PASSED + FAILED )) passed$([ "$SKIPPED" -eq 0 ] || echo " ($SKIPPED skipped)")"
[ "$FAILED" -eq 0 ]
