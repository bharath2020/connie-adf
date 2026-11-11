#!/usr/bin/env bash
# Scripts/tests/perf-gate-scenarios.sh — drives Scripts/perf-gate.sh end to
# end against the fake simulator in Scripts/tests/fake-sim (no simulator,
# no app) and checks each scenario's exit status.
#
# USAGE
#   Scripts/tests/perf-gate-scenarios.sh <workdir> [scenario...]
#
# <workdir> (outside the repository) receives one directory per scenario
# (plan.json, trials.csv, logs, summary) plus <scenario>.out. About 8 min
# for all scenarios (the design-shaped run alone is 36 fake trials). Prints one
# line per scenario and "<passed>/<total> passed"; exits 1 on any mismatch.
#
# The fake apps bundle fake fixture JSON at the bundle root like the demo
# (FIXTURE PREFLIGHT): main/ and branch/ carry the same bytes for every
# fixture; main-nolist/ and branch-nolist/ lack list-dense.json;
# branch-otherlist/ carries different list-dense.json bytes.

set -uo pipefail

[ "$#" -ge 1 ] || { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
WORK="$1"; shift
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/../perf-gate.sh"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
export PATH="$HERE/fake-sim:$PATH" FAKE_UDID=FAKE-UDID-0001 PYTHONDONTWRITEBYTECODE=1

rm -rf "$WORK/apps"
for arm in main branch main-nolist branch-nolist branch-otherlist; do
    mkdir -p "$WORK/apps/$arm/ADFReader.app"
    printf '#!/bin/sh\n# fake %s\ni=0; while [ $i -lt $1 ]; do sleep 1; i=$((i+1)); done\n' "${arm%%-*}" \
        > "$WORK/apps/$arm/ADFReader.app/ADFReader"
    chmod +x "$WORK/apps/$arm/ADFReader.app/ADFReader"
    for fixture in kitchen-sink stress-1k stress-5k giant-table list-dense; do
        printf '{"fake": "%s"}\n' "$fixture" > "$WORK/apps/$arm/ADFReader.app/$fixture.json"
    done
done
rm "$WORK/apps/main-nolist/ADFReader.app/list-dense.json" "$WORK/apps/branch-nolist/ADFReader.app/list-dense.json"
printf '{"fake": "list-dense", "other": true}\n' > "$WORK/apps/branch-otherlist/ADFReader.app/list-dense.json"
A="$WORK/apps/main/ADFReader.app"; BR="$WORK/apps/branch/ADFReader.app"
A_NOLIST="$WORK/apps/main-nolist/ADFReader.app"; BR_NOLIST="$WORK/apps/branch-nolist/ADFReader.app"
BR_OTHER="$WORK/apps/branch-otherlist/ADFReader.app"
GATE_ARGS=(--udid FAKE-UDID-0001 --app-a "$A" --app-b "$BR" --app-c "$BR" --settle 0)

PASSED=0; TOTAL=0
# expect <name> <want exit> <grep pattern in output or -> -- <env...> -- <perf-gate args...>
expect() {
    local name="$1" want="$2" pattern="$3"; shift 3
    local -a envs=()
    if [ "${1:-}" = "--" ]; then
        shift
        while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
        shift
    fi
    if [ "${#SELECTED[@]}" -gt 0 ] && ! printf '%s\n' "${SELECTED[@]}" | grep -qx "$name"; then return; fi
    rm -rf "$WORK/$name" "$WORK/sim-$name"
    env FAKE_SIM_ROOT="$WORK/sim-$name" ${envs[@]+"${envs[@]}"} "$GATE" "$@" --out "$WORK/$name" \
        > "$WORK/$name.out" 2>&1
    local got=$?
    TOTAL=$((TOTAL + 1))
    if [ "$got" -eq "$want" ] && { [ "$pattern" = "-" ] || grep -q -- "$pattern" "$WORK/$name.out"; }; then
        PASSED=$((PASSED + 1)); printf 'ok   %s: exit %s\n' "$name" "$got"
    else
        printf 'FAIL %s: exit %s (want %s, pattern %s)\n' "$name" "$got" "$want" "$pattern"
        tail -5 "$WORK/$name.out" | sed 's/^/     /'
    fi
}
SELECTED=("$@")

# Refusals before any trial (Astra Must 3, Fable M2/S1/S4).
expect refuse-no-b 2 "is required: B" -- -- --udid FAKE-UDID-0001 --app-a "$A" --app-c "$BR" --settle 0
expect refuse-no-sampler 2 "pilot-only" -- -- "${GATE_ARGS[@]}" --no-sampler
expect refuse-no-markers 2 "pilot-only" -- -- "${GATE_ARGS[@]}" --no-candidate-markers
expect refuse-no-stats 2 "rendererStats" -- -- "${GATE_ARGS[@]}" --candidate-args ""
expect refuse-warmup0 2 "warm-up" -- -- "${GATE_ARGS[@]}" --warmup 0
expect refuse-fixtures 2 "runs exactly" -- -- "${GATE_ARGS[@]}" --fixtures "kitchen-sink"
expect refuse-runs 2 "needs >= 3" -- -- "${GATE_ARGS[@]}" --runs 2
expect refuse-cal-pr45 2 "takes no --calibration" -- -- "${GATE_ARGS[@]}" --calibration "$A/ADFReader"
expect refuse-full-nocal 2 "required for design full" -- -- "${GATE_ARGS[@]}" --design full
expect refuse-fixture-arms 2 "runs exactly" -- -- "${GATE_ARGS[@]}" --fixture-arms "kitchen-sink=A,C"
# One whole design-shaped run (pr45: 36 fake trials, about 3 min).
expect pass 0 "gate PASS" -- -- "${GATE_ARGS[@]}"
# Pilot-shaped runs (kitchen-sink only): a FAIL still FAILs, a pilot never PASSes.
PILOT_ARGS=("${GATE_ARGS[@]}" --pilot --fixtures kitchen-sink --runs 2)
expect c-slow 1 "gate FAIL" -- FAKE_SCENARIO=c_slow -- "${PILOT_ARGS[@]}" --warmup 0
expect c-crash 1 "gate FAIL" -- FAKE_SCENARIO=c_crash -- "${PILOT_ARGS[@]}" --warmup 1
expect b-wrong-renderer 2 "gate INVALID" -- FAKE_SCENARIO=b_wrong_renderer -- "${PILOT_ARGS[@]}" --warmup 0
expect a-timeout 2 "gate INVALID" -- FAKE_SCENARIO=a_timeout -- "${PILOT_ARGS[@]}" --warmup 0 \
    --trial-timeout-for "kitchen-sink=4"
expect pilot-reduced 4 "gate PILOT" -- -- --udid FAKE-UDID-0001 --app-a "$A" --app-c "$BR" --settle 0 --pilot \
    --fixtures kitchen-sink --runs 2 --warmup 0 --no-sampler
# Host policy: wait for a quiet host, then run anyway as HOST-BUSY (nothing killed).
printf '6.50\n6.50\n1.50\n' > "$WORK/load-seq"
expect host-quiets 4 "host quiet after" -- FAKE_LOAD_SEQ="$WORK/load-seq" -- "${PILOT_ARGS[@]}" --warmup 0 \
    --host-wait 30 --host-poll 1
expect host-busy-pilot 4 "HOST-BUSY: not quiet after" -- FAKE_TOP_CPU=177.0 -- "${PILOT_ARGS[@]}" --warmup 0 \
    --host-wait 2 --host-poll 1
expect host-busy-fail 6 "gate FAIL-HOST-BUSY" -- FAKE_SCENARIO=c_slow FAKE_LOAD=6.50 -- "${PILOT_ARGS[@]}" \
    --warmup 0 --host-wait 0
# Per-fixture arms (pilot): B only on kitchen-sink.
expect pilot-fixture-arms 4 "gate PILOT" -- -- "${GATE_ARGS[@]}" --pilot --fixtures "kitchen-sink giant-table" \
    --fixture-arms "kitchen-sink=A,B,C giant-table=A,C" --runs 2 --warmup 0


# Design pr2 (lists stage, Fable F2/F7): list-dense's deadline is UNFROZEN until
# its pilot, the gate never runs a reduced fixture set, and the fixture
# preflight refuses before any trial when an arm lacks a design fixture or
# the arms bundle different bytes.
PR2_ARGS=("${GATE_ARGS[@]}" --design pr2)
expect refuse-pr2-unfrozen 2 "no frozen trial timeout" -- -- "${PR2_ARGS[@]}"
expect refuse-pr2-unfrozen-override 2 "cannot stand in" -- -- "${PR2_ARGS[@]}" \
    --trial-timeout-for "list-dense=300"
expect refuse-pr2-omit-list-dense 2 "runs exactly" -- -- "${PR2_ARGS[@]}" \
    --fixtures "kitchen-sink stress-1k giant-table"
LIST_PILOT=(--design pr2 --pilot --fixtures list-dense --runs 2 --warmup 0 --trial-timeout-for "list-dense=60")
expect refuse-pr2-pilot-no-timeout 2 "pass --trial-timeout-for" -- -- "${GATE_ARGS[@]}" --design pr2 --pilot \
    --fixtures list-dense --runs 2 --warmup 0
expect refuse-preflight-a-missing 2 "list-dense.json (arm A:" -- -- --udid FAKE-UDID-0001 --app-a "$A_NOLIST" \
    --app-b "$BR" --app-c "$BR" --settle 0 "${LIST_PILOT[@]}"
expect refuse-preflight-bc-missing 2 "list-dense.json (arm C:" -- -- --udid FAKE-UDID-0001 --app-a "$A" \
    --app-b "$BR_NOLIST" --app-c "$BR_NOLIST" --settle 0 "${LIST_PILOT[@]}"
expect refuse-preflight-a-missing-dry-run 2 "design fixture missing" -- -- --udid FAKE-UDID-0001 --app-a "$A_NOLIST" \
    --app-b "$BR" --app-c "$BR" --settle 0 "${LIST_PILOT[@]}" --dry-run
expect refuse-preflight-hash 2 "differs across arms" -- -- --udid FAKE-UDID-0001 --app-a "$A" \
    --app-b "$BR_OTHER" --app-c "$BR_OTHER" --settle 0 "${LIST_PILOT[@]}"
# Acceptance: every arm bundles the same list-dense.json -> the trials run, C
# proves live TextKit 2 list rows, A completes its traversal -> PILOT.
expect pr2-list-pilot 4 "gate PILOT" -- -- "${GATE_ARGS[@]}" "${LIST_PILOT[@]}"
expect pr2-list-pilot-no-list-live 2 "gate INVALID" -- FAKE_SCENARIO=c_no_list_live -- "${GATE_ARGS[@]}" \
    "${LIST_PILOT[@]}"
expect pr2-list-pilot-a-short 2 "gate INVALID" -- FAKE_SCENARIO=a_short -- "${GATE_ARGS[@]}" "${LIST_PILOT[@]}"
# list-dense A–A′ bounds (Fable F7): a 3-pair calibrate-mode pilot on arm A
# only, then --measure-bounds and --merge-bounds into a copy of the bounds.
expect bounds-calibrate-list-dense 4 "calibration PILOT" -- -- --udid FAKE-UDID-0001 --app-a "$A" --settle 0 \
    --calibrate --pilot --fixtures list-dense --runs 3 --warmup 1 --trial-timeout-for "list-dense=60"
if [ "${#SELECTED[@]}" -eq 0 ] || printf '%s\n' "${SELECTED[@]}" | grep -qx bounds-calibrate-list-dense; then
    TOTAL=$((TOTAL + 1))
    BCAL="$WORK/bounds-calibrate-list-dense"
    cp "$HERE/../perf-bounds.json" "$WORK/bounds-copy.json"
    if python3 -I "$HERE/../perf_summarize.py" "$BCAL/trials.csv" --measure-bounds --quiet \
            --write-bounds "$BCAL/bounds.json" > "$WORK/bounds-measure-merge.out" 2>&1 \
        && python3 -I "$HERE/../perf_summarize.py" --merge-bounds "$BCAL/bounds.json" \
            --bounds "$WORK/bounds-copy.json" >> "$WORK/bounds-measure-merge.out" 2>&1 \
        && python3 -I "$HERE/../perf_summarize.py" --print-design pr2 --bounds "$WORK/bounds-copy.json" \
            | grep -q '^bounds_sha256=' \
        && grep -q '"list-dense"' "$WORK/bounds-copy.json"; then
        PASSED=$((PASSED + 1)); printf 'ok   bounds-measure-merge: list-dense bounds measured and merged\n'
    else
        printf 'FAIL bounds-measure-merge\n'; tail -5 "$WORK/bounds-measure-merge.out" | sed 's/^/     /'
    fi
fi

printf '\n%s/%s passed\n' "$PASSED" "$TOTAL"
[ "$PASSED" -eq "$TOTAL" ]
