#!/usr/bin/env bash
# Scripts/tests/gate-scripts-tests.sh — offline cases for what PR 3 added to
# Scripts/visual-parity.sh (code capture positions and declarations, the
# capture-geometry bracket around the screenshot),
# Scripts/e2e-video.sh (--test code) and Scripts/lifecycle-gate.sh (the
# code tests, short names, tests of another class, the bundle check), and
# for PR 4's additions (the container and caption kinds on a capture
# declaration, --test containers, CONTAINER_TESTS): their --dry-run plans
# and their pure helpers.
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
expect_has "default plan: 41 positions (22, plus PR 4 step 3's six containers-parity, step 4's two, step 5's one and step 6's two containers-parity positions, and step 8's eight captions-parity positions) x 2 appearances x 2 sizes" \
    "$OUT.out" "captures:     164 configurations x arms (A A2 B C)"
expect_eq "default plan scores three pairs per configuration" "$(lines_of "$OUT.pairs")" "492"
# Every PR 1 and PR 2 default position is still captured.
for cfg in kitchen-sink-p0 kitchen-sink-p0.5 stress-5k-p0 stress-5k-p0.5 lists-parity-p0 lists-parity-p0.119 \
    lists-parity-p0.214 lists-parity-p0.357 lists-parity-p0.405 lists-parity-p0.452 lists-parity-p0.548 \
    lists-parity-p0.643 list-dense-p0.761; do
    expect_has "PR 1/PR 2 position kept: $cfg" "$OUT.pairs" "$cfg-light-s0-AC"
done
# The PR 3 positions, in both appearances and at both sizes.
for cfg in kitchen-sink-p0.275 code-parity-p0 code-parity-p0.19 code-parity-p0.28 code-parity-p0.515 \
    code-parity-p0.66 code-parity-p0.78 code-dense-p0 code-dense-p0.5; do
    found=0
    for variant in light-s0 light-s3 dark-s0 dark-s3; do
        if grep -qxF -- "$cfg-$variant-AC" "$OUT.pairs"; then found=$(( found + 1 )); fi
    done
    expect_eq "PR 3 position captured light/dark at steps 0 and 3: $cfg" "$found" "4"
done
expect_has "the kitchen-sink code position is launched as -scrollToFraction 0.275" "$OUT.out" \
    "-fixture kitchen-sink -scrollToFraction 0.275 -fontSizeStep 3 -rendererReset -rendererStats -captureGeometryHook -textkit2"
expect_eq "ten code positions x 4 x three pairs are declared (step 7's KP-S10 on containers-parity among them), beside eleven container positions' 126 (KP-S10's fallback at step 3 only) and eight caption positions' 90 (CAP-12/13's at step 0 only)" \
    "$(grep -cv -e '|container:' -e '|caption:' "$OUT.decl") $(grep -c -- '|container:' "$OUT.decl") $(grep -c -- '|caption:' "$OUT.decl") $(lines_of "$OUT.decl")" "120 126 90 336"
expect_has "CAP-12 in a panel and CAP-13 in a column (stacked on a phone, step 4) are TextKit 2 captions" "$OUT.decl" \
    "captions-parity-p0.54-light-s0-AC|caption:positive|0.13.1.0=tk2,0.14.0.0.0=tk2;land=0.13|textkit2|"
expect_has "M2: CAP-04 (inline code's band) is a swiftui owner beside CAP-03 in a positive caption capture" "$OUT.decl" \
    "captions-parity-p0.14-dark-s3-AC|caption:positive|0.3.0=tk2,0.4.0=swiftui;land=0.3|textkit2|"
expect_has "M2: CAP-07 (a highlight) is a swiftui owner beside CAP-08 in a positive caption capture" "$OUT.decl" \
    "captions-parity-p0.30-dark-s0-AC|caption:positive|0.7.0=swiftui,0.8.0=tk2;land=0.7|textkit2|"
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
expect_has "CP-S6 (nested code, landed on CP-22 above the end clamp; CP-23 and CP-24 empty) is expected fallback with nested owner ids" "$OUT.decl" \
    "code-parity-p0.78-light-s0-AC|fallback|0.26=swiftui,0.27=swiftui,0.28=swiftui,0.30.0.1=swiftui,0.31.1=swiftui;land=0.26|textkit2|"
expect_has "code-dense@0.5 is positive on block 301 (300, its header under the band, is the landing)" "$OUT.decl" \
    "code-dense-p0.5-light-s3-AC|positive|0.301=tk2;land=0.300|textkit2|"
expect_has "code-dense@0 is positive on blocks 1 and 2 (0, its header under the band, is the landing)" "$OUT.decl" \
    "code-dense-p0-dark-s0-AC|positive|0.1=tk2,0.2=tk2;land=0.0|textkit2|"
expect_eq "positive and fallback configurations: 28 + 12 (KP-S10's nested code is a fallback at step 3, the container size rule)" \
    "$(grep -c -- '-AC|positive|' "$OUT.decl") $(grep -c -- '-AC|fallback|' "$OUT.decl")" "28 12"
expect_lacks "a position without code is not declared" "$OUT.decl" "stress-5k-"
expect_lacks "kitchen-sink@0 (code visible, nothing declared) stays undeclared" "$OUT.decl" "kitchen-sink-p0-"
undeclared=0
while IFS='|' read -r pair _; do
    grep -qxF -- "$pair" "$OUT.pairs" || undeclared=$(( undeclared + 1 ))
done <"$OUT.decl"
expect_eq "every declaration names a scored pair" "$undeclared" "0"
expect_has "the dry run lists each declared configuration" "$OUT.out" \
    "  code-parity-p0.515-dark-s3: fallback; 0.18=swiftui,0.19=swiftui;land=0.17"
expect_lacks "the scorer demands owner-level proof itself (no flag is passed)" "$OUT.out" "--require-owner-proof"
# The screenshot bracket: arms B and C of a declared configuration post the
# capture-geometry hook before and after the screenshot; arm A never does.
GEO="      geometry: notifyutil -p com.connie.adfreader.geometry before and after the screenshot"
expect_eq "the dry run brackets the screenshot of every declared B and C arm, and only those (40 code, 40 other container and 30 caption configurations: KP-S10's container fallback shares its step-3 configurations with the step-7 code capture; CAP-12/13's step 3 is undeclared)" \
    "$(grep -cxF -- "$GEO" "$OUT.out")" "220"
expect_eq "… right after the launch line of a declared configuration's arm C" \
    "$(grep -A2 -F -- "  code-parity-p0.515-light-s0-C  " "$OUT.out" | tail -n 1)" "$GEO"
expect_eq "… and of its arm B" \
    "$(grep -A2 -F -- "  code-parity-p0.515-light-s0-B  " "$OUT.out" | tail -n 1)" "$GEO"
expect_eq "… but not of its arms A and A2" \
    "$(grep -A2 -F -- "  code-parity-p0.515-light-s0-A  " "$OUT.out" | tail -n 1 | grep -cF -- "$GEO")$(grep -A2 -F -- "  code-parity-p0.515-light-s0-A2  " "$OUT.out" | tail -n 1 | grep -cF -- "$GEO")" "00"
expect_eq "… nor of an undeclared configuration's arm C" \
    "$(grep -A2 -F -- "  stress-5k-p0-light-s0-C  " "$OUT.out" | tail -n 1 | grep -cF -- "$GEO")" "0"

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
      rules["code-parity-p0.78-light-s0-AC"].land, rules["code-parity-p0.78-light-s0-AC"].owners[0][0])
' "$SCRIPTS/visual_diff.py" "$OUT.decl" "$OUT.pairs"
expect_eq "visual_diff.py parses every emitted declaration" "$STATUS $(cat "$WORK/vp-parse.out")" "0 120 84 132 0.26 0.26"

parity vp-nostats --no-renderer-stats
expect_eq "--no-renderer-stats with the default code captures is a usage error" "$STATUS" "2"
expect_has "… that says why" "$WORK/vp-nostats.out" \
    "--no-renderer-stats drops the engine proof every declared code capture needs: add --no-code-captures, or keep the stats"
parity vp-nostats-explicit --no-renderer-stats --no-code-captures --fixture code-dense@0.5 \
    --code-capture 'code-dense@0.5=positive;0.301=tk2;land=0.300'
expect_eq "… and with an explicit declaration" "$STATUS" "2"
parity vp-nostats-none --no-renderer-stats --no-code-captures
declarations vp-nostats-none
expect_eq "--no-renderer-stats --no-code-captures: accepted, nothing declared" \
    "$STATUS $(lines_of "$WORK/vp-nostats-none.decl") $(lines_of "$WORK/vp-nostats-none.pairs")" "0 0 264"
expect_lacks "… and no arm gets the stats or the geometry hook" "$WORK/vp-nostats-none.out" "-captureGeometryHook"

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

parity vp-step --fixture code-dense@0.5 --code-capture 'code-dense@0.5#s3=positive;0.302=tk2;land=0.300'
declarations vp-step
expect_eq "an explicit #s3 declaration applies to step 3 only" \
    "$STATUS $(grep -c -- '-s3-A.|positive|0.302=tk2;land=0.300|' "$WORK/vp-step.decl") $(grep -c -- '-s0-A.|positive|0.301=tk2;land=0.300|' "$WORK/vp-step.decl")" \
    "0 6 6"
parity vp-no-land --fixture code-parity@0 --code-capture 'code-parity@0=positive;0.1=tk2'
expect_eq "a declaration without land= is a usage error (the landing is measured)" "$STATUS" "2"
expect_has "… and says so" "$WORK/vp-no-land.out" "land= is required: the landing is measured"

parity vp-new --fixture code-tall@0 --code-capture 'code-tall@0=fallback;0.1=swiftui;land=0.0'
declarations vp-new
expect_eq "a declaration for a fixture without a default" "$STATUS $(lines_of "$WORK/vp-new.decl")" "0 12"

parity vp-owner --require-owner-proof
expect_eq "--require-owner-proof is still accepted (always on since R1)" "$STATUS" "0"
expect_lacks "… and is not passed on: the scorer always requires the owner-level proof" "$WORK/vp-owner.out" " --require-owner-proof"

parity vp-bad-syntax --code-capture 'code-dense@0.5=positive'
expect_eq "a declaration without owners is a usage error" "$STATUS" "2"
parity vp-bad-class --code-capture 'code-dense@0.5=native;0.301=tk2;land=0.300'
expect_eq "an unknown class is a usage error" "$STATUS" "2"
parity vp-bad-positive --code-capture 'code-dense@0.5=positive;0.301=swiftui;land=0.300'
expect_eq "positive without a tk2 owner is a usage error" "$STATUS" "2"
expect_has "… and says why" "$WORK/vp-bad-positive.out" "a positive capture needs an owner marked tk2"
parity vp-bad-fallback --code-capture 'code-dense@0.5=fallback;0.301=tk2;land=0.300'
expect_eq "fallback naming a tk2 owner is a usage error" "$STATUS" "2"
parity vp-bad-position --fixture kitchen-sink@0 --code-capture 'code-dense@0.25=positive;0.151=tk2;land=0.150'
expect_eq "a declaration for a position that is not captured is a usage error" "$STATUS" "2"
expect_has "… and names the position" "$WORK/vp-bad-position.out" "no --fixture position code-dense@0.25 in this run"
parity vp-old-default --fixture kitchen-sink@0,0.5
declarations vp-old-default
expect_eq "PR 1's own positions run without any declaration" "$STATUS $(lines_of "$WORK/vp-old-default.decl")" "0 0"

# ---- PR 4: container and caption kinds on the declaration ----
expect_eq "steps 3 to 6 declare nine container positions positive at step 0 and, at xxxLarge (the container size rule, C55), a fallback at step 3, beside two fallback-only ones (the heading panels; KP-S10's at step 3 only, from step 6) on containers-parity; step 8 eight caption positions positive, CAP-12/13's (in containers) at step 0 only" \
    "$(grep -c -- '^containers-parity-p.*|container:positive|' "$WORK/vp-default.decl") $(grep -c -- '^containers-parity-p.*|container:fallback|' "$WORK/vp-default.decl") $(grep -c -- '|container:' "$WORK/vp-default.decl") $(grep -c -- '^captions-parity-p.*|caption:positive|' "$WORK/vp-default.decl") $(grep -c -- '|caption:' "$WORK/vp-default.decl")" \
    "54 72 126 90 90"
expect_has "step 5's closed expands are a positive capture landed on KP-S8 (0.57): the stacked column paragraphs beside them are TextKit 2 (step 4)" "$WORK/vp-default.decl" \
    "containers-parity-p0.6609-dark-s0-AC|container:positive|0.60.0.0=tk2,0.60.1.0=tk2,0.58.0=swiftui,0.59.0.0=swiftui;land=0.57|textkit2|$WORK/vp-default/captures/containers-parity-p0.6609-dark-s0-C.log"
expect_has "… and a fallback at step 3 (from xxxLarge every container keeps SwiftUI: containerSizeKeepsRenderer)" "$WORK/vp-default.decl" \
    "containers-parity-p0.6609-dark-s3-AC|container:fallback|0.60.0.0=swiftui,0.60.1.0=swiftui,0.58.0=swiftui,0.59.0.0=swiftui;land=0.57|textkit2|$WORK/vp-default/captures/containers-parity-p0.6609-dark-s3-C.log"
expect_has "the quote capture names the three-deep quote's owners and lands on KP-S3" "$WORK/vp-default.decl" \
    "containers-parity-p0.3045-dark-s0-AC|container:positive|0.27.0=tk2,0.28.0=tk2,0.28.1=tk2,0.28.2=tk2,0.29.0=tk2,0.29.1.0=tk2,0.29.1.1.0=tk2,0.29.2=tk2;land=0.26|textkit2|$WORK/vp-default/captures/containers-parity-p0.3045-dark-s0-C.log"
expect_has "the excluded panels (headings) are a fallback capture landed on 0.11" "$WORK/vp-default.decl" \
    "containers-parity-p0.1321-light-s0-AB|container:fallback|0.11.0=swiftui,0.11.1=swiftui,0.11.2=swiftui,0.11.4=swiftui,0.12.0=swiftui;land=0.11|swiftui|$WORK/vp-default/captures/containers-parity-p0.1321-light-s0-B.log"
expect_has "the 25/75 and 33/67 column capture (step 4) names the stacked leaves, not the linked one, and lands on KP-S6" "$WORK/vp-default.decl" \
    "containers-parity-p0.5229-light-s0-AC|container:positive|0.46.0.0=tk2,0.46.0.1=tk2,0.46.1.0=tk2,0.46.1.1=tk2,0.46.1.2=tk2,0.47.0.0=tk2,0.47.1.0=tk2;land=0.45|textkit2|$WORK/vp-default/captures/containers-parity-p0.5229-light-s0-C.log"
expect_has "the nested-list capture (step 6) names the quote's list rows, keeps the panel and the rule-A row SwiftUI, and lands on KP-S9" "$WORK/vp-default.decl" \
    "containers-parity-p0.7183-light-s0-AC|container:positive|0.64.0.0=tk2,0.64.0.1=tk2,0.64.1.1=tk2,0.64.2.0=tk2,0.64.2.1=tk2,0.65.0.0=tk2,0.65.0.1=tk2,0.63.0=swiftui,0.64.1.0=swiftui;land=0.62|textkit2|$WORK/vp-default/captures/containers-parity-p0.7183-light-s0-C.log"
expect_has "… and at step 3 a fallback naming the rows whose block is fully on screen" "$WORK/vp-default.decl" \
    "containers-parity-p0.7643-dark-s3-AB|container:fallback|0.67.0.0=swiftui,0.67.0.1=swiftui,0.67.0.1.1.0=swiftui;land=0.66|swiftui|$WORK/vp-default/captures/containers-parity-p0.7643-dark-s3-B.log"
expect_has "step 7's nested code is a code fallback at step 3 (the container size rule)" "$WORK/vp-default.decl" \
    "containers-parity-p0.8218-dark-s3-AC|fallback|0.72.0=swiftui;land=0.71|textkit2|$WORK/vp-default/captures/containers-parity-p0.8218-dark-s3-C.log"
expect_lacks "CAP-12/13's position has no caption declaration at step 3: the top-level CAP-11 caption (TextKit 2) is on screen under the bar there" "$WORK/vp-default.decl" \
    "captions-parity-p0.54-dark-s3-AC|caption:"
expect_has "step 7: KP-S10's quote code 0.72.0 is a positive code capture, landed on the panel 0.71" "$WORK/vp-default.decl" \
    "containers-parity-p0.8218-light-s0-AC|positive|0.72.0=tk2;land=0.71|textkit2|$WORK/vp-default/captures/containers-parity-p0.8218-light-s0-C.log"
expect_has "KP-S10's panel (prose beside code) is a container fallback at step 3" "$WORK/vp-default.decl" \
    "containers-parity-p0.8218-dark-s3-AC|container:fallback|0.71.0=swiftui;land=0.71|textkit2|$WORK/vp-default/captures/containers-parity-p0.8218-dark-s3-C.log"
expect_lacks "… and not at step 0, where step 6's list rows of 0.68 are on screen under the top band" "$WORK/vp-default.decl" \
    "containers-parity-p0.8218-light-s0-AC|container:"
expect_lacks "… nor at the old KP-S10 landing (0.8103)" "$WORK/vp-default.decl" "containers-parity-p0.8103-"
expect_has "the container positions are launched like the code ones" "$WORK/vp-default.out" \
    "-fixture containers-parity -scrollToFraction 0.362 -fontSizeStep 3 -rendererReset -rendererStats -captureGeometryHook -textkit2"
parity vp-kinds --fixture code-parity@0.78 \
    --code-capture 'code-parity@0.78=container:positive;0.31.0=tk2,0.31.2#cont1=tk2;land=0.26' \
    --code-capture 'code-parity@0.78=caption:fallback;0.29.0=swiftui;land=0.26'
declarations vp-kinds
OUT="$WORK/vp-kinds"
expect_eq "a position carries one declaration per kind: code (default), container, caption on each of 12 pairs" \
    "$STATUS $(lines_of "$OUT.decl") $(lines_of "$OUT.pairs")" "0 36 12"
expect_has "the code declaration is unchanged (no kind prefix)" "$OUT.decl" \
    "code-parity-p0.78-light-s0-AC|fallback|0.26=swiftui,0.27=swiftui,0.28=swiftui,0.30.0.1=swiftui,0.31.1=swiftui;land=0.26|textkit2|$OUT/captures/code-parity-p0.78-light-s0-C.log"
expect_has "the container declaration carries its kind, with a continuation-row owner" "$OUT.decl" \
    "code-parity-p0.78-light-s0-AC|container:positive|0.31.0=tk2,0.31.2#cont1=tk2;land=0.26|textkit2|$OUT/captures/code-parity-p0.78-light-s0-C.log"
expect_has "the caption declaration on arm B proves SwiftUI from B's log" "$OUT.decl" \
    "code-parity-p0.78-dark-s3-AB|caption:fallback|0.29.0=swiftui;land=0.26|swiftui|$OUT/captures/code-parity-p0.78-dark-s3-B.log"
expect_has "the noise pair asks for no proof of any kind" "$OUT.decl" \
    "code-parity-p0.78-dark-s3-AA|container:positive|0.31.0=tk2,0.31.2#cont1=tk2;land=0.26|none|-"
expect_has "the dry run lists each kind's declaration" "$OUT.out" \
    "  code-parity-p0.78-light-s0: container:positive; 0.31.0=tk2,0.31.2#cont1=tk2;land=0.26"
run vp-kinds-parse python3 -I -c '
import importlib.util, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("visual_diff", sys.argv[1])
diff = importlib.util.module_from_spec(spec)
sys.modules["visual_diff"] = diff
spec.loader.exec_module(diff)
items = [line.rstrip("\n").split("|") for line in open(sys.argv[2])]
pairs = {line.strip() for line in open(sys.argv[3])}
rules = diff.parse_captures(items, pairs)
kinds = {kind: sum(1 for k in rules.values() if kind in k) for kind in diff.CAPTURE_KINDS}
rule = rules["code-parity-p0.78-light-s0-AC"]["container"]
print(len(rules), kinds["code"], kinds["container"], kinds["caption"], len(diff.parse_code_captures(items, pairs)),
      rule.kind, rule.cls, rule.owners[1][0], rule.land)
' "$SCRIPTS/visual_diff.py" "$OUT.decl" "$OUT.pairs"
expect_eq "visual_diff.py parses every kind the capture script emits" "$STATUS $(cat "$WORK/vp-kinds-parse.out")" \
    "0 12 12 12 12 12 container positive 0.31.2#cont1 0.26"
parity vp-kinds-replace --fixture code-parity@0.78 \
    --code-capture 'code-parity@0.78=container:positive;0.31.0=tk2;land=0.26' \
    --code-capture 'code-parity@0.78=container:fallback;0.31.0=swiftui;land=0.26'
declarations vp-kinds-replace
expect_eq "a later container declaration replaces the container one only (code default kept)" \
    "$STATUS $(grep -c -- '|container:fallback|0.31.0=swiftui;land=0.26|' "$WORK/vp-kinds-replace.decl") $(grep -c -- '|container:positive|' "$WORK/vp-kinds-replace.decl") $(grep -c -- '-A.|fallback|0.26=swiftui' "$WORK/vp-kinds-replace.decl")" \
    "0 12 0 12"
parity vp-kinds-step --fixture code-dense@0.5 --code-capture 'code-dense@0.5#s3=container:fallback;0.300=swiftui;land=0.300'
declarations vp-kinds-step
expect_eq "a #s3 container declaration applies to step 3 only, beside the code default" \
    "$STATUS $(grep -c -- '-s3-A.|container:fallback|' "$WORK/vp-kinds-step.decl") $(grep -c -- '-s0-A.|container:' "$WORK/vp-kinds-step.decl") $(grep -c -- '-A.|positive|0.301=tk2;land=0.300|' "$WORK/vp-kinds-step.decl")" \
    "0 6 0 12"
parity vp-kinds-code --fixture code-dense@0.5 --code-capture 'code-dense@0.5=code:fallback;0.305=swiftui;land=0.300'
declarations vp-kinds-code
expect_eq "an explicit code: kind is the code kind (it replaces the code default; emitted without the prefix)" \
    "$STATUS $(grep -c -- '|fallback|0.305=swiftui;land=0.300|' "$WORK/vp-kinds-code.decl") $(lines_of "$WORK/vp-kinds-code.decl")" "0 12 12"
parity vp-kinds-geo --arms "A B C" --fixture lists-parity@0.548 --appearances light --size-steps 0 \
    --code-capture 'lists-parity@0.548=container:positive;0.12.0.0=tk2;land=0.11'
expect_eq "a container capture at a position without code brackets the screenshot of arms B and C" \
    "$STATUS $(grep -cxF -- "$GEO" "$WORK/vp-kinds-geo.out")" "0 2"
parity vp-bad-kind --fixture code-dense@0.5 --code-capture 'code-dense@0.5=table:positive;0.301=tk2;land=0.300'
expect_eq "an unknown kind is a usage error" "$STATUS" "2"
expect_has "… that names the kinds" "$WORK/vp-bad-kind.out" "=[<code|container|caption>:]<positive|fallback>"
parity vp-bad-kind-positive --fixture code-dense@0.5 --code-capture 'code-dense@0.5=container:positive;0.301=swiftui;land=0.300'
expect_eq "a container positive without a tk2 owner is a usage error" "$STATUS" "2"
expect_has "… and says why" "$WORK/vp-bad-kind-positive.out" "a positive capture needs an owner marked tk2"
parity vp-bad-kind-fallback --fixture code-dense@0.5 --code-capture 'code-dense@0.5=caption:fallback;0.301=tk2;land=0.300'
expect_eq "a caption fallback naming a tk2 owner is a usage error" "$STATUS" "2"
expect_has "the manifest records the container and caption lines beside TK2_CODE_ROWS" "$PARITY" \
    "landed_code_rows landed_container_rows landed_caption_rows"
expect_has "… read after SCROLL_LANDED" "$PARITY" \
    '"$(landed_line TK2_CODE_ROWS "$launch_log")" "$(landed_line TK2_CONTAINER_ROWS "$launch_log")"'
expect_has "the usage text documents the kind" "$PARITY" \
    "#     <fixture>@<position>[#s<step>]=[<kind>:]<positive|fallback>;<owner>=<tk2|swiftui>[,...];land=<block id>"
# Adding a capture is one line: a copy of the script with one declaration
# added to CONTAINER_CAPTURES_DEFAULT captures that position by default.
PCOPY="$WORK/parity-copy"
mkdir -p "$PCOPY/lib"
cp "$SCRIPTS/lib/sim.sh" "$PCOPY/lib/sim.sh"
awk '{ print } /^CONTAINER_CAPTURES_DEFAULT=[(]$/ { print "    \"containers-parity@0.25=container:positive;0.4.0=tk2;land=0.3\"" }' \
    "$PARITY" >"$PCOPY/visual-parity.sh"
expect_eq "the copy differs by the one declaration line" "$(diff "$PARITY" "$PCOPY/visual-parity.sh" | grep -c '^>')" "1"
run vp-one-line "$BASH" "$PCOPY/visual-parity.sh" --udid FAKE-UDID-0001 --out "$WORK/vp-one-line" --dry-run
declarations vp-one-line
expect_has "… the new position joins the default plan (164 + 4 configurations)" "$WORK/vp-one-line.out" \
    "captures:     168 configurations x arms (A A2 B C)"
expect_eq "… with its declaration on every pair, and the code ones unchanged" \
    "$STATUS $(grep -c -- '^containers-parity-p0.25-.*|container:positive|0.4.0=tk2;land=0.3|' "$WORK/vp-one-line.decl") $(grep -cv -e '|container:' -e '|caption:' "$WORK/vp-one-line.decl")" \
    "0 12 120"
run vp-one-line-none "$BASH" "$PCOPY/visual-parity.sh" --udid FAKE-UDID-0001 --out "$WORK/vp-one-line-none" --dry-run \
    --no-code-captures
expect_has "… and --no-code-captures drops it with its position" "$WORK/vp-one-line-none.out" \
    "captures:     88 configurations x arms (A A2 B C)"

# =========================================================== fixtures-check ==
# F-R23: a gate runs make-fixtures --check. fixtures-check.sh on this
# checkout, on copies with one changed byte, and before a capture.

FIXCHECK="$SCRIPTS/fixtures-check.sh"
REPO_ROOT="$(cd "$SCRIPTS/.." && pwd)"
run fx-pass "$BASH" "$FIXCHECK"
expect_eq "fixtures-check passes on this checkout" "$STATUS" "0"
expect_has "… the generator regenerates and matches every generated fixture" "$WORK/fx-pass.out" \
    "fixtures-check: generator: check: all 18 generated fixtures match Fixtures/ byte for byte"
expect_has "… and every manifest digest matches" "$WORK/fx-pass.out" \
    "fixtures-check: manifest: all 21 digests in Fixtures/SHA256SUMS match"
# fx_copy <name>: a tree with this checkout's generator and fixtures.
fx_copy() {
    mkdir -p "$WORK/$1/Tools"
    cp "$REPO_ROOT/Tools/make-fixtures.swift" "$WORK/$1/Tools/"
    cp -R "$REPO_ROOT/Fixtures" "$WORK/$1/Fixtures"
}
fx_copy fx-gen
printf ' ' >>"$WORK/fx-gen/Fixtures/captions-parity.json"
run fx-gen "$BASH" "$FIXCHECK" --repo "$WORK/fx-gen"
expect_eq "a generated fixture with one byte added fails (exit 1)" "$STATUS" "1"
expect_has "… the generator step fails" "$WORK/fx-gen.out" "fixtures-check: generator: FAIL"
expect_has "… and the manifest names the file" "$WORK/fx-gen.out" "captions-parity.json: FAILED"
fx_copy fx-hand
printf ' ' >>"$WORK/fx-hand/Fixtures/kitchen-sink.json"
run fx-hand "$BASH" "$FIXCHECK" --repo "$WORK/fx-hand"
expect_eq "a hand-authored fixture with one byte added fails (exit 1): the generator does not make it" "$STATUS" "1"
expect_has "… the generator step still passes" "$WORK/fx-hand.out" "fixtures-check: generator: check: all 17"
expect_has "… the manifest names the file" "$WORK/fx-hand.out" "kitchen-sink.json: FAILED"
fx_copy fx-extra
printf '{}' >"$WORK/fx-extra/Fixtures/unlisted.json"
run fx-extra "$BASH" "$FIXCHECK" --repo "$WORK/fx-extra"
expect_eq "a fixture missing from SHA256SUMS fails (exit 1)" "$STATUS" "1"
expect_has "… named" "$WORK/fx-extra.out" "fixtures-check: manifest: FAIL (not listed in SHA256SUMS: unlisted.json)"
run fx-usage "$BASH" "$FIXCHECK" --repo "$WORK/no-such-tree"
expect_eq "a tree without the generator is a usage error (exit 2)" "$STATUS" "2"
# visual-parity runs it, then compares the apps' fixtures, before any
# simulator command: an app bundling another captions-parity is refused.
mkdir -p "$WORK/fx-apps/ref.app" "$WORK/fx-apps/cand.app"
printf '#!/bin/sh\n' >"$WORK/fx-apps/ref.app/ADFReader"
cp "$WORK/fx-apps/ref.app/ADFReader" "$WORK/fx-apps/cand.app/ADFReader"
chmod +x "$WORK/fx-apps/ref.app/ADFReader" "$WORK/fx-apps/cand.app/ADFReader"
cp "$REPO_ROOT/Fixtures/captions-parity.json" "$WORK/fx-apps/ref.app/"
cp "$WORK/fx-gen/Fixtures/captions-parity.json" "$WORK/fx-apps/cand.app/"
run fx-parity "$BASH" "$PARITY" --udid FAKE-UDID-0001 --out "$WORK/fx-parity" --ref-app "$WORK/fx-apps/ref.app" \
    --app "$WORK/fx-apps/cand.app" --fixture captions-parity@0.30 --appearances light --size-steps 0
expect_eq "visual-parity refuses a candidate app whose fixture differs from the checkout's (exit 2)" "$STATUS" "2"
expect_has "… naming the file" "$WORK/fx-parity.out" "cand.app/captions-parity.json (sha256 "
expect_lacks "… before any simulator command" "$WORK/fx-parity.out" "FAKE-UDID-0001"
parity fx-parity-dry --fixture captions-parity@0.30
expect_has "a dry run names the fixture check" "$WORK/fx-parity-dry.out" \
    "fixtures:     $SCRIPTS/fixtures-check.sh, then each captured fixture's JSON in every arm's .app == Fixtures/<fixture>.json (captions-parity)"

# ================================================================ e2e-video ==

e2e() { E2E_VIDEO_SOURCED=1 "$BASH" -c '. "$0"; "$@"' "$E2E" "$@"; }

expect_eq "--test code names the code storyboard" "$(e2e test_id_for code)" \
    "ADFReaderUITests/CodeRendererUITests/testCodeBlockStoryboard"
expect_eq "--test switch is unchanged" "$(e2e test_id_for switch)" \
    "ADFReaderUITests/RendererSwitchUITests/testLiveSwitchSwiftUIToTextKit2AndBack"
expect_eq "--test lists is unchanged" "$(e2e test_id_for lists)" \
    "ADFReaderUITests/ListStoryboardUITests/testListStoryboardSwiftUIToTextKit2AndBack"
expect_eq "--test containers names the container storyboard (PR 4)" "$(e2e test_id_for containers)" \
    "ADFReaderUITests/ContainerStoryboardUITests/testContainerStoryboard"
for selector in Code codes cod "" all container Containers containerss; do
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
expect_has "… that names the four selectors" "$WORK/e2e-bad.out" "--test must be 'switch', 'lists', 'code' or 'containers' (got 'codes')"
expect_has "the usage text names the four selectors" "$E2E" "[--test switch|lists|code|containers]"
CCASE="$(e2e test_case_name "$(e2e test_id_for containers)")"
expect_eq "the container storyboard's test case name" "$CCASE" \
    "-[ADFReaderUITests.ContainerStoryboardUITests testContainerStoryboard]"
run e2e-containers "$BASH" "$E2E" --udid FAKE-UDID-0001 --out "$WORK/e2e-out/containers.mp4" --test containers --skip-build \
    --derived-data "$WORK/e2e-out/switch.DerivedData" --dry-run
expect_eq "--test containers --dry-run exits 0" "$STATUS" "0"
expect_has "… and runs only the container storyboard" "$WORK/e2e-containers.out" \
    "-only-testing:ADFReaderUITests/ContainerStoryboardUITests/testContainerStoryboard -resultBundlePath"
expect_has "… and waits for its result line" "$WORK/e2e-containers.out" "after \"Test Case '$CCASE' passed|failed\""
expect_has "… reusing the switch video's build" "$WORK/e2e-containers.out" \
    "derived data:   $WORK/e2e-out/switch.DerivedData (reused)"
run e2e-containers-negative "$BASH" "$E2E" --udid FAKE-UDID-0001 --out "$WORK/e2e-out/negative/containers.mp4" \
    --test containers --negative --dry-run
expect_eq "--test containers --negative is accepted" "$STATUS" "0"
expect_has "… as the wrong-digest control" "$WORK/e2e-containers-negative.out" "digest:         deliberately wrong (negative control)"
printf 'padding\0testCodeBlockStoryboard\0testContainerStoryboard\0more' >"$LOGS/bundle-pr4.bin"
e2e binary_has_test "$LOGS/bundle-pr4.bin" testContainerStoryboard
expect_eq "a bundle built with the container storyboard is accepted" "$?" "0"
e2e binary_has_test "$LOGS/bundle-pr3.bin" testContainerStoryboard
expect_eq "a bundle without it (a PR 3 build) is refused" "$?" "1"
run e2e-lists "$BASH" "$E2E" --udid FAKE-UDID-0001 --out "$WORK/e2e-out/lists.mp4" --test lists --dry-run
expect_has "--test lists still records the list storyboard" "$WORK/e2e-lists.out" \
    "-only-testing:ADFReaderUITests/ListStoryboardUITests/testListStoryboardSwiftUIToTextKit2AndBack"
run e2e-default "$BASH" "$E2E" --udid FAKE-UDID-0001 --out "$WORK/e2e-out/default.mp4" --dry-run
expect_has "the default is still the switch test" "$WORK/e2e-default.out" "test selector:  switch"

# ============================================================ lifecycle-gate ==

gate() { LIFECYCLE_GATE_SOURCED=1 "$BASH" -c '. "$0"; "$@"' "$GATE" "$@"; }

OLD_TESTS="test1CollapseRoundTripKeepsRows test2RotationRoundTripDriftMatchesSwiftUI test3SwitchDuringStreamingLoad test4SwitchKeepsSearchExpandAndTasks test5FlingThrashSoakSwiftUI test6FlingThrashSoakTextKit2 test7TwentyFlipsReleaseRows test8RendererLaunchFlagsAndPersistence testL1ListFiveRoundTripsAtParkedPositions testL1bListFiveRoundTripsListDense testL2ListCollapseRoundTripBothDirections testL3aListRotateAndSizeDriftMatchesSwiftUI testL3bListStateSurvivesRotateSizeAndSwitch testL3cListStateSurvivesRotateSizeAndSwitchListDense testL4aListSwitchDuringStreamingLoad testL4bListCollidingIDsReplacementDocument testL5aFlingThrashSoakListDenseSwiftUI testL5bFlingThrashSoakListDenseTextKit2 testL6TwentyFlipsListDense"
NEW_TESTS="testC1CodeFiveRoundTripsCodeDense testC1bCodeFiveRoundTripsPannedWideBlock testC2CodeCollapseRoundTripBothDirections testC3CodeTextSizeDriftMatchesSwiftUI testC4CodeSwitchDuringStreamingLoad testC5aFlingThrashSoakCodeDenseSwiftUI testC5bFlingThrashSoakCodeDenseTextKit2 testC6TwentyFlipsCodeDense"
# PR 4's K tests (lifecycle-gate.sh CONTAINER_TESTS, plan §8.2), and the
# pins that move with them. A step that adds a K test changes these three
# lines with the script, in one commit: the name here, the suite timeout
# the script sizes for it.
CONTAINER_TESTS_EXPECTED="testK1SwitchRoundTripsAtContainerLandmarks testK2OpenExpandRoundTripAcrossSwitch testK3WidthAndTypeSizeChangesInContainers testK4SwitchDuringLoadAndSearchInContainers testK5aFlingOpenExpandsSwiftUI testK5bFlingOpenExpandsTextKit2 testK6TwentyFlipsContainers testK7ExpandOpenCloseCycles testK8TallExpandMountAndFlip testK10aFlingThrashSoakContainersSwiftUI testK10bFlingThrashSoakContainersTextKit2"
EXPECTED_SUITE_TIMEOUT=22600
# shellcheck disable=SC2086  # word list
set -- $OLD_TESTS $NEW_TESTS $CONTAINER_TESTS_EXPECTED
EXPECTED_COUNT=$#
ALL_EXPECTED="$OLD_TESTS $NEW_TESTS${CONTAINER_TESTS_EXPECTED:+ $CONTAINER_TESTS_EXPECTED}"
expect_eq "CONTAINER_TESTS is the expected K-test list" "$(gate eval 'printf "%s\n" "$CONTAINER_TESTS"')" \
    "$CONTAINER_TESTS_EXPECTED"
expect_eq "ALL_TESTS = tests 1-8 and L1-L6 in their order, then C1-C6, then CONTAINER_TESTS" \
    "$(gate eval 'printf "%s\n" "$ALL_TESTS"')" "$ALL_EXPECTED"
"$BASH" "$GATE" --help >"$WORK/lg-help.out" 2>&1
missing_usage=""
for t in $ALL_EXPECTED; do
    grep -qE "(^|[^A-Za-z0-9_])$t([^A-Za-z0-9_]|\$)" "$WORK/lg-help.out" || missing_usage="$missing_usage $t"
done
expect_eq "the usage text names every ALL_TESTS method" "$missing_usage" ""
# The wiring, with K names: a copy of the script whose CONTAINER_TESTS
# holds three of the plan's names.
GCOPY="$WORK/gate-copy"
mkdir -p "$GCOPY/lib"
cp "$SCRIPTS/lib/sim.sh" "$GCOPY/lib/sim.sh"
K_SAMPLE="testK1SwitchRoundTripsAtContainerLandmarks testK10aFlingThrashSoakContainersSwiftUI testK10bFlingThrashSoakContainersTextKit2"
sed "s/^CONTAINER_TESTS=.*/CONTAINER_TESTS=\"$K_SAMPLE\"/" "$GATE" >"$GCOPY/lifecycle-gate.sh"
kgate() { LIFECYCLE_GATE_SOURCED=1 "$BASH" -c '. "$0"; "$@"' "$GCOPY/lifecycle-gate.sh" "$@"; }
expect_eq "K tests in CONTAINER_TESTS join ALL_TESTS after the code tests" \
    "$(kgate eval 'printf "%s\n" "$ALL_TESTS"')" "$OLD_TESTS $NEW_TESTS $K_SAMPLE"
expect_eq "--only testK1 selects testK1… (never testK10a: an upper-case letter must follow)" \
    "$(kgate resolve_test testK1)" "testK1SwitchRoundTripsAtContainerLandmarks"
expect_eq "--only testK10a selects testK10a…" "$(kgate resolve_test testK10a)" "testK10aFlingThrashSoakContainersSwiftUI"
kgate resolve_test testK10 >/dev/null 2>&1
expect_eq "--only testK10 matches no test (a lower-case letter follows it in testK10a/b: refused)" "$?" "1"
expect_eq "… with both prefixed names as the hint" "$(kgate tests_starting_with testK10)" \
    "testK10aFlingThrashSoakContainersSwiftUI testK10bFlingThrashSoakContainersTextKit2"
# A real ambiguity: two names that are the short name followed by an
# upper-case letter (a copy whose CONTAINER_TESTS holds a second testK2…).
GCOPY2="$WORK/gate-copy-ambiguous"
mkdir -p "$GCOPY2/lib"
cp "$SCRIPTS/lib/sim.sh" "$GCOPY2/lib/sim.sh"
K_AMBIGUOUS="testK2OpenExpandRoundTripAcrossSwitch testK2OtherNameForTheAmbiguityCase"
sed "s/^CONTAINER_TESTS=.*/CONTAINER_TESTS=\"$K_AMBIGUOUS\"/" "$GATE" >"$GCOPY2/lifecycle-gate.sh"
agate() { LIFECYCLE_GATE_SOURCED=1 "$BASH" -c '. "$0"; "$@"' "$GCOPY2/lifecycle-gate.sh" "$@"; }
expect_eq "with two testK2<Upper>… names, each full name still selects itself" \
    "$(agate resolve_test testK2OtherNameForTheAmbiguityCase) $(agate resolve_test testK2Open)" \
    "testK2OtherNameForTheAmbiguityCase testK2OpenExpandRoundTripAcrossSwitch"
agate resolve_test testK2 >/dev/null 2>&1
expect_eq "… and --only testK2 is ambiguous: two names match (refused)" "$?" "1"
run lg-k-ambiguous "$BASH" "$GCOPY2/lifecycle-gate.sh" --udid FAKE-UDID-0001 --out "$WORK/lg-k-ambiguous" --dry-run \
    --only testK2
expect_eq "… a dry run with it exits 2 (usage error)" "$STATUS" "2"
expect_has "… naming both candidates" "$WORK/lg-k-ambiguous.out" \
    "unknown test 'testK2' (did you mean: testK2OpenExpandRoundTripAcrossSwitch testK2OtherNameForTheAmbiguityCase)"
run lg-k "$BASH" "$GCOPY/lifecycle-gate.sh" --udid FAKE-UDID-0001 --out "$WORK/lg-k" --dry-run --only testK1 --only testK10b
expect_has "a dry run selects K tests by short name" "$WORK/lg-k.out" \
    "tests:        testK1SwitchRoundTripsAtContainerLandmarks testK10bFlingThrashSoakContainersTextKit2"
expect_has "… each as a LifecycleUITests id" "$WORK/lg-k.out" \
    "-only-testing:ADFReaderUITests/LifecycleUITests/testK1SwitchRoundTripsAtContainerLandmarks -only-testing:ADFReaderUITests/LifecycleUITests/testK10bFlingThrashSoakContainersTextKit2"
run lg-k-all "$BASH" "$GCOPY/lifecycle-gate.sh" --udid FAKE-UDID-0001 --out "$WORK/lg-k-all" --dry-run
expect_eq "… and the default plan runs them all" \
    "$(grep '^test: ' "$WORK/lg-k-all.out" | grep -o -- '-only-testing:ADFReaderUITests/LifecycleUITests/test[A-Za-z0-9]*' | sort -u | wc -l | tr -d ' ')" "30"

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
resolves testK1 testK1SwitchRoundTripsAtContainerLandmarks
resolves testK2 testK2OpenExpandRoundTripAcrossSwitch
resolves testK5b testK5bFlingOpenExpandsTextKit2
resolves testK8 testK8TallExpandMountAndFlip
resolves testK10a testK10aFlingThrashSoakContainersSwiftUI
resolves MediaRowGuardUITests/testK9MediaRowScrollBackSettles MediaRowGuardUITests/testK9MediaRowScrollBackSettles
resolves test1 test1CollapseRoundTripKeepsRows
resolves testL1 testL1ListFiveRoundTripsAtParkedPositions
resolves testL1b testL1bListFiveRoundTripsListDense
resolves LifecycleUITests/testC4 testC4CodeSwitchDuringStreamingLoad
resolves CodeRendererUITests/testCopyPutsExactCodeOnPasteboard CodeRendererUITests/testCopyPutsExactCodeOnPasteboard
for unknown in testC5 testL3 testC7 testC testc1 C1 testK5 testK10 testK9 "CodeRendererUITests/copy" "A/B/testX" "LifecycleUITests/testNope" 'test*'; do
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
fake_build "$WORK/dd-pr3" $OLD_TESTS $NEW_TESTS $CONTAINER_TESTS_EXPECTED testCopyPutsExactCodeOnPasteboard
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
expect_has "the default plan runs all $EXPECTED_COUNT tests in order" "$WORK/lg-default.out" "tests:        $ALL_EXPECTED"
expect_eq "… each as its own -only-testing id" \
    "$(grep '^test: ' "$WORK/lg-default.out" | grep -o -- '-only-testing:ADFReaderUITests/LifecycleUITests/test[A-Za-z0-9]*' | sort -u | wc -l | tr -d ' ')" "$EXPECTED_COUNT"
expect_has "the default suite timeout covers the longer suite" "$WORK/lg-default.out" "suite timeout: ${EXPECTED_SUITE_TIMEOUT}s"
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
    "bundle check: MISSING from $PR2_BIN: $NEW_TESTS${CONTAINER_TESTS_EXPECTED:+ $CONTAINER_TESTS_EXPECTED}"
lifecycle lg-stale-lists --skip-build --derived-data "$WORK/dd-pr2" --only testL1 --only test7
expect_eq "the same PR 2 build still runs its own tests" "$STATUS" "0"
lifecycle lg-stale-copy --skip-build --derived-data "$WORK/dd-pr2" --only CodeRendererUITests/testCopyPutsExactCodeOnPasteboard
expect_eq "another class's test missing from the bundle fails the check" "$STATUS" "2"

# D-R5: K3's column crossing comes from a regular-width run of the same
# build (--k3-crossing <its --out>); lifecycle_agent_tests.py proves the
# report row, these the wiring.
K3_SHA="0e9e91fbada39c7199c25ac8421d2fe8273fc7430102d3d7e6dd3317db453500"
mkdir -p "$WORK/k3-ipad" "$WORK/k3-empty"
printf '{"check": "K3 width and type-size changes in containers (containers-parity 0.46)", "pass": true}\n' \
    >"$WORK/k3-ipad/results.jsonl"
printf '# Lifecycle checks\n\n- git_head: abc\n- build: reused /dd/fixU2 sha256=%s\n- device: X\n' "$K3_SHA" \
    >"$WORK/k3-ipad/lifecycle.md"
expect_eq "D-R5: the build sha256 an earlier run recorded" "$(gate recorded_build_sha "$WORK/k3-ipad")" "$K3_SHA"
expect_eq "... nothing for a run without lifecycle.md" "$(gate recorded_build_sha "$WORK/k3-empty")" ""
expect_has "D-R5: without --k3-crossing the plan says only this run's K3 can cross" "$WORK/lg-default.out" \
    "k3 crossing:  none"
expect_has "... and the report records it" "$WORK/lg-default.out" "--meta k3_crossing=none"
lifecycle lg-k3-crossing --only testK3 --k3-crossing "$WORK/k3-ipad"
expect_eq "D-R5: --k3-crossing with an earlier run's --out is accepted" "$STATUS" "0"
expect_has "... the report reads its results" "$WORK/lg-k3-crossing.out" \
    "--meta k3_crossing=$WORK/k3-ipad --crossing-results $WORK/k3-ipad/results.jsonl"
lifecycle lg-k3-crossing-empty --only testK3 --k3-crossing "$WORK/k3-empty"
expect_eq "D-R5: a --k3-crossing dir without results.jsonl is a usage error" "$STATUS" "2"
lifecycle lg-k3-crossing-missing --only testK3 --k3-crossing "$WORK/k3-nope"
expect_eq "D-R5: a --k3-crossing dir that does not exist is a usage error" "$STATUS" "2"

# N2: under the size cut-off the iPad crossing flips no TextKit 2 row; a
# Pro Max run's rotation crossing (stacked TextKit 2 -> side by side
# SwiftUI -> stacked TextKit 2) is the second --k3-crossing. These run the
# report command each dry run prints on a phone K3 record, so the gate's
# own wiring is shown to pass with both runs and to fail without the Pro
# Max record or with one whose column text did not flip.
k3_record() {   # <dir> <arm json>...: <dir>/results.jsonl holds one passing K3 record with these arms
    local dir="$1"
    shift
    mkdir -p "$dir"
    local IFS=,
    printf '{"check": "K3 width and type-size changes in containers (containers-parity 0.46)", "pass": true, "arms": [%s]}\n' \
        "$*" >"$dir/results.jsonl"
}
k3_arm() {   # <arm> <regular_width> <crossed_boundary> <rotation_crossable> <crossed_rotation> <leaves> [<in-window> <at top> <off-window at top>]
    printf '{"arm": "%s", "regular_width": %s, "crossed_boundary": %s, "rotation_crossable": %s, "crossed_rotation": %s, "rotation_textkit2_leaves": %s, "in_window_rows_rotation": %s, "release_at_top": %s, "release_off_window": %s}' \
        "$1" "$2" "$3" "$4" "$5" "$6" "${7:-null}" "${8:-null}" "${9:-null}"
}
gate_report() {   # <name>: runs the report command dry run <name> printed; status in $STATUS
    local line
    line="$(sed -n 's/^report: *//p' "$WORK/$1.out")"
    eval "set -- $line"
    "$@" >"$WORK/$1.report.out" 2>&1
    STATUS=$?
}
row_verdict() {   # <name> <row prefix>: PASS, FAIL or none, from dry run <name>'s lifecycle.md
    local line
    line="$(grep -F -- "| $2" "$WORK/$1/lifecycle.md" 2>/dev/null | head -n 1)"
    case "$line" in
        "") echo none ;;
        *"| PASS |"*) echo PASS ;;
        *) echo FAIL ;;
    esac
}
k3_record "$WORK/n2-ipad" "$(k3_arm swiftui true true false false '[0, 0, 0]')" "$(k3_arm textkit2 true true false false '[0, 0, 0]')"
k3_record "$WORK/n2-promax" "$(k3_arm swiftui false false true true '[0, 0, 0]')" \
    "$(k3_arm textkit2 false false true true '[4, 0, 4]' '[40, 8, 40]' true 0)"
k3_record "$WORK/n2-no-flip" "$(k3_arm swiftui false false true true '[0, 0, 0]')" \
    "$(k3_arm textkit2 false false true true '[4, 4, 4]' '[40, 8, 40]' true 0)"
# Call C60: the rows in a window come back exactly, and no off-window row is left at the document top.
k3_record "$WORK/n2-in-window" "$(k3_arm swiftui false false true true '[0, 0, 0]')" \
    "$(k3_arm textkit2 false false true true '[4, 0, 4]' '[40, 8, 47]' true 0)"
k3_record "$WORK/n2-not-released" "$(k3_arm swiftui false false true true '[0, 0, 0]')" \
    "$(k3_arm textkit2 false false true true '[4, 0, 4]' '[40, 8, 40]' true 5)"
for name in lg-n2-both lg-n2-no-promax lg-n2-no-flip lg-n2-ipad-run lg-n2-in-window lg-n2-not-released; do
    case "$name" in
        lg-n2-ipad-run) k3_record "$WORK/$name" "$(k3_arm swiftui true true false false '[0, 0, 0]')" \
            "$(k3_arm textkit2 true true false false '[0, 0, 0]')" ;;
        *) k3_record "$WORK/$name" "$(k3_arm swiftui false false false false '[0, 0, 0]')" \
            "$(k3_arm textkit2 false false false false '[4, 4, 4]')" ;;
    esac
done
lifecycle lg-n2-both --only testK3 --k3-crossing "$WORK/n2-ipad" --k3-crossing "$WORK/n2-promax"
expect_eq "N2: an iPad and a Pro Max --k3-crossing are accepted together" "$STATUS" "0"
expect_has "... and the report reads both" "$WORK/lg-n2-both.out" \
    "--crossing-results $WORK/n2-ipad/results.jsonl --crossing-results $WORK/n2-promax/results.jsonl"
gate_report lg-n2-both
expect_eq "N2: the gate's report passes a phone K3 beside the iPad and Pro Max runs" "$STATUS" "0"
expect_eq "... its rotation row passes" "$(row_verdict lg-n2-both "K3 rotation")" "PASS"
expect_eq "... and so does its column row" "$(row_verdict lg-n2-both "K3 column")" "PASS"
lifecycle lg-n2-no-promax --only testK3 --k3-crossing "$WORK/n2-ipad"
gate_report lg-n2-no-promax
expect_eq "N2: without the Pro Max run the gate's report fails a phone K3" "$STATUS" "1"
expect_eq "... on the rotation row (the record is missing)" "$(row_verdict lg-n2-no-promax "K3 rotation")" "FAIL"
lifecycle lg-n2-no-flip --only testK3 --k3-crossing "$WORK/n2-ipad" --k3-crossing "$WORK/n2-no-flip"
gate_report lg-n2-no-flip
expect_eq "N2: a Pro Max run whose column text stayed TextKit 2 side by side fails the gate's report" "$STATUS" "1"
expect_eq "... on the rotation row (no engine flip)" "$(row_verdict lg-n2-no-flip "K3 rotation")" "FAIL"
lifecycle lg-n2-in-window --only testK3 --k3-crossing "$WORK/n2-ipad" --k3-crossing "$WORK/n2-in-window"
gate_report lg-n2-in-window
expect_eq "C60: a Pro Max run whose rows in a window did not come back fails the gate's report" "$STATUS" "1"
expect_eq "... on the rotation row" "$(row_verdict lg-n2-in-window "K3 rotation")" "FAIL"
lifecycle lg-n2-not-released --only testK3 --k3-crossing "$WORK/n2-ipad" --k3-crossing "$WORK/n2-not-released"
gate_report lg-n2-not-released
expect_eq "C60: a Pro Max run that left off-window rows at the document top fails the gate's report" "$STATUS" "1"
expect_eq "... on the rotation row" "$(row_verdict lg-n2-not-released "K3 rotation")" "FAIL"
lifecycle lg-n2-ipad-run --only testK3
gate_report lg-n2-ipad-run
expect_eq "N2: an iPad run (regular in both orientations, its own crossing) still passes alone" "$STATUS" "0"
expect_eq "... with no rotation row" "$(row_verdict lg-n2-ipad-run "K3 rotation")" "none"

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
for t in $OLD_TESTS $NEW_TESTS $CONTAINER_TESTS_EXPECTED; do
    declares LifecycleUITests "$t" || undeclared="$undeclared $t"
done
expect_eq "every ALL_TESTS method is declared in LifecycleUITests" "$undeclared" ""
extra=""
for t in $(grep -ohE '^[[:space:]]*func test[A-Za-z0-9_]*[(][)]' "$UITESTS/LifecycleUITests.swift" | sed -E 's/^[[:space:]]*func //; s/[(][)]$//'); do
    case " $OLD_TESTS $NEW_TESTS $CONTAINER_TESTS_EXPECTED " in
        *" $t "*) ;;
        *) extra="$extra $t" ;;
    esac
done
expect_eq "every LifecycleUITests test method is in ALL_TESTS" "$extra" ""

for selector in switch lists code containers; do
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

# Every K3 field the report's crossing rows read (D-R5, N2) is one K3
# records, so a renamed key fails here, not silently in a candidate run.
for key in regular_width crossed_boundary rotation_crossable crossed_rotation rotation_textkit2_leaves \
    in_window_rows_rotation release_at_top release_off_window; do
    expect_has "K3 records $key" "$UITESTS/LifecycleUITests.swift" "\"$key\":"
    expect_has "... and the agent's crossing rows read it" "$SCRIPTS/lifecycle_agent.py" "arm.get(\"$key\")"
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
