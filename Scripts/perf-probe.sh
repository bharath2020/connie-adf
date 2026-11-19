#!/usr/bin/env bash
# Scripts/perf-probe.sh — T0 work probe: base vs candidate in a few minutes on
# a busy host. Counts the renderer's work on fixed fixture slices (TextKit 2
# layouts/draws/rows, UIViews, CALayers, sizing queries, allocations) and the
# CPU instructions retired, then compares the two refs. Frame statistics stay
# with Scripts/perf-gate.sh (T2); this never replaces it.
#
# USAGE
#   Scripts/perf-probe.sh [options] <base> [<candidate>]
#   Scripts/perf-probe.sh [options] --calibrate <N> [<ref>]
#
#   <base>, <candidate>  any git ref, or WORKTREE: the working tree this
#                 script lives in, uncommitted and untracked (not ignored)
#                 files included. Candidate defaults to WORKTREE. Calibration
#                 ref defaults to main.
#
#   --tier render|parse|all   render: the simulator suite
#                 (Tests/ADFRenderingTests/Perf/PerfProbeTests.swift); parse:
#                 `swift test` on macOS (Tests/ADFPreparationTests/Perf/
#                 ParsePreparePerfTests.swift). Default all.
#   --udid <udid> use this simulator (booted if needed, shut down at the end
#                 only if this run booted it; never deleted). Default: create
#                 `perf-probe-<pid>` (--device-type, newest iOS >= 26
#                 runtime) and delete it at exit. Refuses the captain's
#                 simulator.
#   --device-type <name>      for a created simulator (default "iPhone 17 Pro").
#   --runtime <id>            for a created simulator (default the newest
#                 available iOS runtime >= 26; pin it to compare sessions).
#   --reps N      measured reps per renderer per slice (default 5).
#   --passes N    probe passes per ref, base and candidate interleaved;
#                 a side's passes combine by median (default 1).
#   --fixtures a,b            only these render slices (default all six).
#   --no-warmup   skip the throwaway probe pass after boot (the warm-up
#                 rule: the first pass after a boot runs ~2 % high, CV ~1 %).
#   --release     build Release with ENABLE_TESTABILITY=YES (default Debug).
#   --root <dir>  exported trees, derived data and SwiftPM scratch, reused
#                 between runs (default $PERF_PROBE_ROOT, else
#                 $TMPDIR/connie-adf-perf-probe). Safe to delete when idle.
#   --out <dir>   this run's results (default <root>/runs/<stamp>-<pid>).
#   --budgets <file>          default Scripts/perf-probe-budgets.json.
#   --strict-counts           a changed count fails the run.
#   --calibrate N run N passes of one ref (both tiers unless --tier) and
#                 derive per-fixture TextKit 2 ÷ SwiftUI ratio budgets and
#                 per-line cross-process instruction noise floors (which
#                 raise that line's warn/fail thresholds):
#                 <out>/budgets.calibrated.json; --write-budgets also
#                 replaces --budgets with it. --margin-pct P (default 2).
#   --allow-busy  run while another lane's perf run is active (it corrupts
#                 their frame figures; ours barely move). Default: wait up
#                 to --busy-wait s (default 1800) for
#                 pgrep -f "$PERF_PROBE_BUSY_PATTERN" (default
#                 'perf-gate.sh|perf_trial.py') to clear, then exit 2.
#   --grace S     let xcodebuild finalise its result bundle at most S s
#                 after the test-run line before stopping it (default 300).
#   --keep-sim    leave the simulator booted (and a created one in place).
#   --dry-run     print the plan; export nothing, build nothing, boot nothing.
#   --export-only export (and overlay) the trees into <root>/src/, then stop.
#   --build-only  export and build, then stop (no simulator boot or test, so
#                 it can run while another lane holds the simulator).
#
# WHAT IT DOES
#   1. Resolves each ref to a git tree (WORKTREE: `git add -A` into a
#      temporary index + write-tree; the real index is untouched), exports it
#      with `git archive | tar -x` (no git worktree) and overlays, from this
#      checkout: both Perf/ test folders, fixtures the ref lacks, and for a
#      ref without TextKit2Scope.inheritsRenderer (TK2 PR 1) the legacy
#      routing shim (Scripts/perf-probe-compat/). The result is mirrored
#      into <root>/src/<slot> rewriting only changed files, so per-slot
#      builds (<root>/dd/<slot>-<config>, <root>/spm/<slot>) stay incremental.
#   2. xcodebuild build-for-testing (scheme ADFKit-Package) per slot;
#      `swift build --build-tests` per slot for the parse tier.
#   3. Boots the simulator, runs one throwaway pass (warm-up rule), then
#      xcodebuild test-without-building -only-testing:ADFRenderingTests/
#      PerfProbeTests per pass, TEST_RUNNER_PERF_PROBE_* passing the knobs
#      and the output path; `swift test --skip-build --filter
#      ParsePreparePerfTests` for the parse tier.
#   4. Scripts/perf_probe.py compare: markdown table to stdout and
#      <out>/report.md, summary.json beside it. Rules: counts exact (else
#      CHANGED, explain or re-baseline); instructions and allocations WARN
#      at >= +2 %, FAIL at >= +5 % vs the same-session base; per-fixture
#      TextKit 2 ÷ SwiftUI instruction ratio <= its calibrated budget; TK2
#      layouts per TK2 row > 1 reported (issue 10).
#
# ENV      Other suite knobs pass through the environment: export
#          TEST_RUNNER_PERF_PROBE_WARMUPS / TEST_RUNNER_PERF_PROBE_MALLOC_REPS
#          (render, via xcodebuild) or PERF_PROBE_PARSE_REPS /
#          PERF_PROBE_PARSE_FIXTURES / PERF_PROBE_WARMUPS (parse, swift test).
#          PERF_PROBE_ROOT, PERF_PROBE_BUSY_PATTERN as above.
#
# OUTPUTS  <out>/{base,cand}.{render,parse}.<pass>.jsonl, warmup.jsonl,
#          report.md, summary.json, logs/, xcresult/.
# EXIT     0 PASS/WARN/CHANGED; 1 FAIL; 2 usage, build, test or host error.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/sim.sh
source "$SCRIPT_DIR/lib/sim.sh"
HELPER="$SCRIPT_DIR/perf_probe.py"
LEGACY_COMPAT="$SCRIPT_DIR/perf-probe-compat/PerfProbeCompat.legacy.swift.in"
CAPTAIN_UDID="FCBB16A4-94A8-406A-8F17-D9A189754F82"
SCHEME="ADFKit-Package"
RENDER_TEST="ADFRenderingTests/PerfProbeTests"
PARSE_FILTER="ParsePreparePerfTests"
OVERLAY_DIRS=("Tests/ADFRenderingTests/Perf" "Tests/ADFPreparationTests/Perf")

log() { printf '[perf-probe %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "error: $*"; exit 2; }
usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; exit 2; }

UDID=""; TIER="all"; OUT=""; ROOT="${PERF_PROBE_ROOT:-${TMPDIR:-/tmp}/connie-adf-perf-probe}"
REPS=5; PASSES=1; WARMUP=1; ALLOW_BUSY=0; BUSY_WAIT=1800
BUDGETS="$SCRIPT_DIR/perf-probe-budgets.json"; CALIBRATE=0; WRITE_BUDGETS=0; MARGIN=2
STRICT=0; CONFIG="Debug"; KEEP_SIM=0; DRY=0; DEVICE_TYPE="iPhone 17 Pro"; FIXTURES=""; GRACE=300
TEST_LIMIT=1200; EXPORT_ONLY=0; BUILD_ONLY=0; RUNTIME=""
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --udid) UDID="${2:-}"; shift 2 ;;
        --tier) TIER="${2:-}"; shift 2 ;;
        --out) OUT="${2:-}"; shift 2 ;;
        --root) ROOT="${2:-}"; shift 2 ;;
        --reps) REPS="${2:-}"; shift 2 ;;
        --passes) PASSES="${2:-}"; shift 2 ;;
        --fixtures) FIXTURES="${2:-}"; shift 2 ;;
        --no-warmup) WARMUP=0; shift ;;
        --release) CONFIG="Release"; shift ;;
        --budgets) BUDGETS="${2:-}"; shift 2 ;;
        --strict-counts) STRICT=1; shift ;;
        --calibrate) CALIBRATE="${2:-}"; shift 2 ;;
        --write-budgets) WRITE_BUDGETS=1; shift ;;
        --margin-pct) MARGIN="${2:-}"; shift 2 ;;
        --allow-busy) ALLOW_BUSY=1; shift ;;
        --busy-wait) BUSY_WAIT="${2:-}"; shift 2 ;;
        --grace) GRACE="${2:-}"; shift 2 ;;
        --device-type) DEVICE_TYPE="${2:-}"; shift 2 ;;
        --runtime) RUNTIME="${2:-}"; shift 2 ;;
        --keep-sim) KEEP_SIM=1; shift ;;
        --dry-run) DRY=1; shift ;;
        --export-only) EXPORT_ONLY=1; shift ;;
        --build-only) BUILD_ONLY=1; shift ;;
        -h|--help) usage ;;
        --*) die "unknown option $1 (see --help)" ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done
for n in REPS PASSES CALIBRATE BUSY_WAIT GRACE; do
    [[ "${!n}" =~ ^[0-9]+$ ]] || die "--$(tr 'A-Z_' 'a-z-' <<<"$n") needs a whole number"
done
[[ "$MARGIN" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "--margin-pct needs a number"
[[ $REPS -ge 1 && $PASSES -ge 1 ]] || die "--reps and --passes must be >= 1"
case "$TIER" in render|parse|all) ;; *) die "--tier is render, parse or all" ;; esac
command -v python3 >/dev/null || die "python3 not found"
command -v xcodebuild >/dev/null || die "xcodebuild not found"

if [[ $CALIBRATE -gt 0 ]]; then
    [[ ${#POSITIONAL[@]} -le 1 ]] || die "--calibrate takes at most one ref"
    BASE_REF="${POSITIONAL[0]:-main}"; CAND_REF=""
    PASSES="$CALIBRATE"
else
    [[ ${#POSITIONAL[@]} -ge 1 && ${#POSITIONAL[@]} -le 2 ]] || usage
    BASE_REF="${POSITIONAL[0]}"; CAND_REF="${POSITIONAL[1]:-WORKTREE}"
fi
if [[ -n "$UDID" ]]; then
    [[ "$(tr 'a-z' 'A-Z' <<<"$UDID")" != "$CAPTAIN_UDID" ]] || die "refusing the captain's play simulator ($UDID)"
fi
WANT_RENDER=0; WANT_PARSE=0
[[ "$TIER" == "parse" ]] || WANT_RENDER=1
[[ "$TIER" == "render" ]] || WANT_PARSE=1

mkdir -p "$ROOT"
ROOT="$(cd "$ROOT" && pwd -P)"
case "$ROOT/" in
    "$(cd "$REPO" && pwd -P)/"*) die "--root must be outside the repository (WORKTREE export would pick it up)" ;;
esac
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${OUT:-$ROOT/runs/$STAMP-$$}"
[[ ! -e "$OUT/report.md" && -z "$(ls "$OUT"/*.jsonl 2>/dev/null)" ]] || die "$OUT already holds results; use a fresh --out"

# ------------------------------------------------------------ timing --
PHASE_LOG=()
PHASE_NAME=""; PHASE_T0=0
phase() { PHASE_NAME="$1"; PHASE_T0=$SECONDS; log "── $1"; }
phase_done() {
    local took=$((SECONDS - PHASE_T0))
    PHASE_LOG+=("$PHASE_NAME ${took}s")
    log "── $PHASE_NAME: ${took}s"
}

# ------------------------------------------------------------ refs --
# resolve <ref> <slot> -> sets TREE and LABEL
resolve() {
    local ref="$1" slot="$2" commit index
    if [[ "$ref" == "WORKTREE" ]]; then
        mkdir -p "$ROOT/tmp"
        index="$ROOT/tmp/index.$slot"
        cp "$(git -C "$REPO" rev-parse --path-format=absolute --git-path index)" "$index"
        GIT_INDEX_FILE="$index" git -C "$REPO" add -A
        TREE="$(GIT_INDEX_FILE="$index" git -C "$REPO" write-tree)"
        commit="$(git -C "$REPO" rev-parse --short=9 HEAD)"
        if [[ "$TREE" == "$(git -C "$REPO" rev-parse 'HEAD^{tree}')" ]]; then
            LABEL="WORKTREE@$commit (clean)"
        else
            LABEL="WORKTREE@$commit+changes (tree ${TREE:0:9})"
        fi
    else
        commit="$(git -C "$REPO" rev-parse --verify --quiet "$ref^{commit}")" || die "unknown ref: $ref"
        TREE="$(git -C "$REPO" rev-parse "$commit^{tree}")"
        LABEL="$ref@${commit:0:9}"
    fi
}

# export_slot <slot> <tree> -> <root>/src/<slot> holds the tree plus overlays
export_slot() {
    local slot="$1" tree="$2" stage="$ROOT/stage/$1.$$" dir name
    mkdir -p "$stage"
    git -C "$REPO" archive "$tree" | tar -x -C "$stage"
    for dir in "${OVERLAY_DIRS[@]}"; do
        python3 -I "$HELPER" sync "$REPO/$dir" "$stage/$dir" >/dev/null
    done
    OVERLAID=""
    mkdir -p "$stage/Fixtures"
    for name in "$REPO"/Fixtures/*.json; do
        if [[ ! -e "$stage/Fixtures/${name##*/}" ]]; then
            cp "$name" "$stage/Fixtures/"
            OVERLAID="$OVERLAID ${name##*/}"
        fi
    done
    ROUTING="TextKit2Scope.inheritsRenderer"
    if ! grep -rqs "static func inheritsRenderer" "$stage/Sources/ADFRendering"; then
        cp "$LEGACY_COMPAT" "$stage/Tests/ADFRenderingTests/Perf/PerfProbeCompat.swift"
        ROUTING="legacy (richText only)"
    fi
    python3 -I "$HELPER" sync "$stage" "$ROOT/src/$slot" --keep .swiftpm --keep .build >&2
    case "$stage" in
        "$ROOT"/stage/*) rm -rf "$stage" ;;
    esac
    log "$slot: overlay fixtures:${OVERLAID:- none}; routing: $ROUTING"
}

# ------------------------------------------------------------ processes --
# Signals go only to this script's own children, by recorded PID and only
# while that PID is still our child (PIDs wrap within minutes on a busy host).
# Never pattern-match (pkill/killall).
CHILD_PID=""
ours() { [[ -n "$1" && "$(ps -o ppid= -p "$1" 2>/dev/null | tr -d ' ')" == "$$" ]]; }
stop_child() {
    if ours "$1"; then kill -TERM "$1" 2>/dev/null || true; fi
    wait "$1" 2>/dev/null || true
}

# Matching command lines, less this script and any process that merely
# mentions the pattern while waiting on it (a shell running pgrep/until).
busy_pids() {
    local pid command
    for pid in $(pgrep -f "${PERF_PROBE_BUSY_PATTERN:-perf-gate.sh|perf_trial.py}" 2>/dev/null || true); do
        [[ "$pid" != "$$" ]] || continue
        command="$(ps -o command= -p "$pid" 2>/dev/null || true)"
        [[ -n "$command" ]] || continue
        case "$command" in *pgrep*) continue ;; esac
        printf '%s ' "$pid"
    done
}
wait_quiet() {
    [[ $ALLOW_BUSY -eq 0 ]] || return 0
    local waited=0 pids
    while pids="$(busy_pids)"; [[ -n "${pids// /}" ]]; do
        [[ $waited -lt $BUSY_WAIT ]] || die "another lane's perf run is still active after ${waited}s (pids $pids); rerun later or pass --allow-busy"
        log "waiting before $1: another lane's perf run is active (pids $pids), ${waited}/${BUSY_WAIT}s"
        sleep 30
        waited=$((waited + 30))
    done
}

# run_logged <log> <limit-s> <dir> <command...>: runs the command in <dir>
# as our direct child, stops it GRACE s after a test-run line (xcodebuild
# can idle for minutes finalising its result bundle) or at <limit-s>.
run_logged() {
    local logfile="$1" limit="$2" dir="$3" start=$SECONDS done_at="" status=0
    shift 3
    ( cd "$dir" && exec "$@" ) >"$logfile" 2>&1 &
    CHILD_PID=$!
    while kill -0 "$CHILD_PID" 2>/dev/null; do
        if [[ -z "$done_at" ]] && grep -Eq 'Test run with [0-9]+ tests?|\*\* TEST EXECUTE (SUCCEEDED|FAILED) \*\*' "$logfile" 2>/dev/null; then
            done_at=$SECONDS
        fi
        if [[ -n "$done_at" && $((SECONDS - done_at)) -gt $GRACE ]]; then
            log "still finalising ${GRACE}s after the test-run line; stopping it"
            stop_child "$CHILD_PID"
            break
        fi
        if [[ $((SECONDS - start)) -gt $limit ]]; then
            log "no finish after ${limit}s; stopping it (log $logfile)"
            stop_child "$CHILD_PID"
            CHILD_PID=""
            return 124
        fi
        sleep 2
    done
    wait "$CHILD_PID" 2>/dev/null || status=$?
    CHILD_PID=""
    return $status
}

# ------------------------------------------------------------ simulator --
CREATED=0; BOOTED_BY_US=0
cleanup() {
    local status=$?
    trap - EXIT
    [[ -z "$CHILD_PID" ]] || stop_child "$CHILD_PID"
    if [[ -n "$UDID" && $KEEP_SIM -eq 0 ]]; then
        if [[ $CREATED -eq 1 ]]; then
            log "deleting simulator $UDID (created by this run)"
            xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
            xcrun simctl delete "$UDID" >/dev/null 2>&1 || true
        elif [[ $BOOTED_BY_US -eq 1 ]]; then
            log "shutting down $UDID (booted by this run)"
            xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
        fi
    fi
    exit "$status"
}

ensure_device() {
    if [[ -n "$UDID" ]]; then
        [[ "$(sim_device_field "$UDID" state)" != "Missing" ]] || die "no simulator with udid $UDID"
        return
    fi
    local runtime="$RUNTIME"
    if [[ -z "$runtime" ]]; then
        runtime="$(xcrun simctl list runtimes -j | python3 -I "$HELPER" pick-runtime --min 26)" \
            || die "no available iOS 26+ simulator runtime"
    fi
    UDID="$(xcrun simctl create "perf-probe-$$" "$DEVICE_TYPE" "$runtime")" || die "simctl create failed"
    CREATED=1
    log "created simulator perf-probe-$$ ($DEVICE_TYPE, $runtime): $UDID"
}

boot_device() {
    if [[ "$(sim_device_field "$UDID" state)" != "Booted" ]]; then
        xcrun simctl boot "$UDID"
        BOOTED_BY_US=1
    fi
    xcrun simctl bootstatus "$UDID" -b >/dev/null
}

# ------------------------------------------------------------ build / run --
XCB_CONFIG=()
[[ "$CONFIG" == "Release" ]] && XCB_CONFIG=(-configuration Release ENABLE_TESTABILITY=YES)

build_render() {
    local slot="$1" logfile="$OUT/logs/build-render-$1.log"
    run_logged "$logfile" 3600 "$ROOT/src/$slot" xcodebuild build-for-testing -scheme "$SCHEME" \
        -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$ROOT/dd/$slot-$CONFIG" \
        ${XCB_CONFIG[@]+"${XCB_CONFIG[@]}"} \
        || die "build-for-testing failed for $slot (see $logfile)"
}

build_parse() {
    local slot="$1" logfile="$OUT/logs/build-parse-$1.log"
    run_logged "$logfile" 3600 "$ROOT/src/$slot" swift build --build-tests --scratch-path "$ROOT/spm/$slot" \
        || die "swift build failed for $slot (see $logfile)"
}

# run_render <slot> <label> <jsonl> <tag> <reps>
run_render() {
    local slot="$1" label="$2" jsonl="$3" tag="$4" reps="$5"
    local logfile="$OUT/logs/render-$tag.log" bundle="$OUT/xcresult/render-$tag.xcresult" status=0
    local envs=(TEST_RUNNER_PERF_PROBE=1 "TEST_RUNNER_PERF_PROBE_OUT=$jsonl" "TEST_RUNNER_PERF_PROBE_LABEL=$label"
        "TEST_RUNNER_PERF_PROBE_REPS=$reps")
    [[ -z "$FIXTURES" ]] || envs+=("TEST_RUNNER_PERF_PROBE_FIXTURES=$FIXTURES")
    run_logged "$logfile" "$TEST_LIMIT" "$ROOT/src/$slot" env "${envs[@]}" xcodebuild test-without-building \
        -scheme "$SCHEME" -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$ROOT/dd/$slot-$CONFIG" \
        ${XCB_CONFIG[@]+"${XCB_CONFIG[@]}"} -only-testing:"$RENDER_TEST" -parallel-testing-enabled NO \
        -test-timeouts-enabled NO -resultBundlePath "$bundle" || status=$?
    collect "$logfile" "$jsonl" "render $tag" "$status"
}

# run_parse <slot> <label> <jsonl> <tag>
run_parse() {
    local slot="$1" label="$2" jsonl="$3" tag="$4" logfile="$OUT/logs/parse-$4.log" status=0
    run_logged "$logfile" "$TEST_LIMIT" "$ROOT/src/$slot" env PERF_PROBE=1 "PERF_PROBE_OUT=$jsonl" \
        "PERF_PROBE_LABEL=$label" swift test --skip-build --disable-xctest --scratch-path "$ROOT/spm/$slot" \
        --filter "$PARSE_FILTER" || status=$?
    collect "$logfile" "$jsonl" "parse $tag" "$status"
}

# collect <log> <jsonl> <what> <status>: the suite writes <jsonl> itself; if
# it could not (simulator file access), take the PERF_PROBE lines from the
# log. A failed test run is fatal: no partial verdicts.
collect() {
    local logfile="$1" jsonl="$2" what="$3" status="$4"
    # Swift Testing marks results with SF Symbols glyphs under `swift test`
    # and ✔/✘ under xcodebuild, so match the words.
    if grep -Eq 'Test run with [0-9]+ tests?.* failed|recorded an issue|✘ |\*\* TEST EXECUTE FAILED \*\*|^error: |Testing failed:' "$logfile"; then
        die "$what: the probe failed (exit $status; see $logfile)"
    fi
    if [[ ! -s "$jsonl" ]]; then
        grep -o 'PERF_PROBE {.*' "$logfile" | sed 's/^PERF_PROBE //' >"$jsonl" || true
    fi
    [[ -s "$jsonl" ]] || die "$what: no probe output (exit $status; see $logfile)"
    log "$what: $(grep -c . "$jsonl") lines"
}

# ------------------------------------------------------------ plan --
resolve "$BASE_REF" base; BASE_TREE="$TREE"; BASE_LABEL="$LABEL"
SLOTS=(base)
if [[ -n "$CAND_REF" ]]; then
    resolve "$CAND_REF" cand; CAND_TREE="$TREE"; CAND_LABEL="$LABEL"
    SLOTS+=(cand)
fi
log "base: $BASE_LABEL"
[[ -z "$CAND_REF" ]] || log "candidate: $CAND_LABEL"
log "tier $TIER, $CONFIG, reps $REPS, passes $PASSES, warm-up $WARMUP, root $ROOT, out $OUT"
if [[ $DRY -eq 1 ]]; then
    log "dry run: would export ${SLOTS[*]} to $ROOT/src/, build, boot ${UDID:-a new perf-probe-$$ simulator}, run, compare"
    exit 0
fi

mkdir -p "$OUT/logs" "$OUT/xcresult" "$ROOT/src" "$ROOT/stage"
trap cleanup EXIT
trap 'exit 130' INT TERM
RUN_T0=$SECONDS

phase "export"
export_slot base "$BASE_TREE"
[[ -z "$CAND_REF" ]] || export_slot cand "$CAND_TREE"
phase_done
if [[ $EXPORT_ONLY -eq 1 ]]; then
    log "exported: ${SLOTS[*]} under $ROOT/src/"
    exit 0
fi

if [[ $WANT_RENDER -eq 1 ]]; then
    ensure_device
    log "simulator $UDID: $(sim_device_field "$UDID" name), $(sim_device_field "$UDID" runtime)"
fi

wait_quiet "the builds"
phase "build"
for slot in "${SLOTS[@]}"; do
    [[ $WANT_RENDER -eq 0 ]] || build_render "$slot"
    [[ $WANT_PARSE -eq 0 ]] || build_parse "$slot"
done
phase_done
if [[ $BUILD_ONLY -eq 1 ]]; then
    log "built: ${SLOTS[*]} (${PHASE_LOG[*]})"
    exit 0
fi

label_of() { if [[ "$1" == "base" ]]; then printf '%s' "$BASE_LABEL"; else printf '%s' "$CAND_LABEL"; fi; }

if [[ $WANT_RENDER -eq 1 ]]; then
    wait_quiet "the render tier"
    phase "boot"
    boot_device
    phase_done
    if [[ $WARMUP -eq 1 ]]; then
        phase "warm-up pass (discarded)"
        run_render base "warm-up" "$OUT/warmup.jsonl" warmup 1
        phase_done
    fi
    phase "render tier"
    for pass in $(seq 1 "$PASSES"); do
        for slot in "${SLOTS[@]}"; do
            run_render "$slot" "$(label_of "$slot")" "$OUT/$slot.render.$pass.jsonl" "$slot-$pass" "$REPS"
        done
    done
    phase_done
fi

if [[ $WANT_PARSE -eq 1 ]]; then
    wait_quiet "the parse tier"
    phase "parse tier"
    for pass in $(seq 1 "$PASSES"); do
        for slot in "${SLOTS[@]}"; do
            run_parse "$slot" "$(label_of "$slot")" "$OUT/$slot.parse.$pass.jsonl" "$slot-$pass"
        done
    done
    phase_done
fi

META=("host load at end: $(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1}')"
    "config $CONFIG, reps $REPS, passes $PASSES, warm-up $WARMUP, tier $TIER"
    "simulator: ${UDID:-none} $( [[ -z "$UDID" ]] || sim_device_field "$UDID" runtime)"
    "phases: ${PHASE_LOG[*]}; total $((SECONDS - RUN_T0))s"
    "results: $OUT")

if [[ $CALIBRATE -gt 0 ]]; then
    meta_args=()
    for m in "${META[@]}"; do meta_args+=(--meta "$m"); done
    python3 -I "$HELPER" calibrate --runs "$OUT"/base.*.jsonl --budgets "$BUDGETS" \
        --margin-pct "$MARGIN" --out "$OUT/budgets.calibrated.json" --meta "ref $BASE_LABEL" "${meta_args[@]}"
    if [[ $WRITE_BUDGETS -eq 1 ]]; then
        cp "$OUT/budgets.calibrated.json" "$BUDGETS"
        log "wrote $BUDGETS"
    fi
    exit 0
fi

meta_args=()
for m in "${META[@]}"; do meta_args+=(--meta "$m"); done
strict=()
[[ $STRICT -eq 0 ]] || strict=(--strict-counts)
status=0
python3 -I "$HELPER" compare --base "$OUT"/base.*.jsonl --cand "$OUT"/cand.*.jsonl --budgets "$BUDGETS" \
    --base-label "$BASE_LABEL" --cand-label "$CAND_LABEL" --out "$OUT/report.md" --json "$OUT/summary.json" \
    ${strict[@]+"${strict[@]}"} "${meta_args[@]}" || status=$?
log "report: $OUT/report.md (exit $status)"
exit "$status"
