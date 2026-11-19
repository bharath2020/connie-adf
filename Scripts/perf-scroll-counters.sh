#!/usr/bin/env bash
# Scripts/perf-scroll-counters.sh — the T1 scroll-counter tier: a per-PR,
# busy-host-OK check that counts the work a fast autoscroll and the idle
# time after it cost, base ref vs candidate ref, on one simulator.
#
# It counts work, not frames, so it needs no quiet host, no 300 s settle, no
# warm-up discards and one trial per cell. Frame statistics stay with
# Scripts/perf-gate.sh (T2).
#
# USAGE
#   Scripts/perf-scroll-counters.sh [options] <base-ref> <candidate-ref>
#   Scripts/perf-scroll-counters.sh main .            # main vs the working tree
#   Scripts/perf-scroll-counters.sh --udid <UDID> --fixtures "list-dense" main HEAD
#
#   <candidate-ref> "." is the working tree, uncommitted and untracked
#   (non-ignored) files included. Any other ref is exported with
#   `git archive <ref> | tar -x` into a fresh directory (never a worktree).
#
# WHAT IT DOES
#   1. Refuses to start while another perf run is on the host (perf-gate.sh,
#      perf_trial.py, lifecycle-gate.sh, another perf-scroll-counters.sh;
#      this run's own children excluded): --wait-others <s> waits for them,
#      --force runs anyway.
#   2. Exports both refs under <out>/src/. A ref older than T1 (no
#      Demo/ADFReader/ScrollCounters.swift) gets the T1 instrumentation
#      copied in: ScrollCounters.swift, AutoScroller.swift and
#      Sources/ADFRendering/RowLifecycleDiagnostics.swift from the candidate
#      (or the working tree), plus the two ADFRowLifecycle calls in
#      DocumentRow (perf_scroll_counters.py overlay; refs from 86abd56, TextKit
#      2 PR 1, on). A fixture the base lacks is copied from the candidate
#      (data only); a fixture whose bytes differ is reported. Both are
#      recorded in <out>/overlay-*.json and the report.
#   3. Builds each arm: xcodegen, then xcodebuild Release (--configuration),
#      generic iOS Simulator, arm64, unsigned, its own derived data. Or takes
#      a prebuilt .app (--base-app / --candidate-app; it must already carry
#      the T1 instrumentation).
#   4. Uses --udid (booted if shut down, shut down again at the end if it
#      booted it) or creates its own device (--device-type, newest iOS
#      runtime or --runtime) and deletes it on exit.
#   5. One throwaway launch after boot, then per arm (base, then candidate):
#      one install, and one trial per fixture × renderer:
#        -fixture <f> -autoscroll -autoscrollSpeed <speed> -scrollCounters
#        -idleSeconds <idle> -rendererStats  plus -rendererReset (swiftui)
#        or -textkit2 (textkit2)
#      perf_trial.py launch stamps the log, perf_trial.py parse appends the
#      row (status ok needs READY, SCROLL_METRICS completed=1 and
#      SCROLL_COUNTERS).
#   6. perf_scroll_counters.py compare applies Scripts/perf-scroll-counters.json
#      and writes <out>/results.md: counts within ±1 % of base, candidate
#      idle instructions / row churn / TextKit 2 layouts within fixed
#      budgets, scroll instructions a WARN above +5 %.
#
# EXIT  0 PASS or WARN, 1 FAIL, 2 INVALID or refused, other: setup error.
#
# OPTIONS
#   --udid <UDID>            use this simulator (never the captain's)
#   --device-type <name>     for a created device; default "iPhone 17 Pro"
#   --runtime <identifier>   for a created device; default the newest iOS
#   --fixtures "<names>"     default "kitchen-sink list-dense stress-1k"
#   --renderers "<names>"    default "swiftui textkit2"
#   --speed <pt/s>           default 6000 (the frame gate scrolls at 1200)
#   --idle <s>               idle window after the scroll; default 5
#   --configuration <cfg>    default Release
#   --base-app <.app> / --candidate-app <.app>   skip export and build
#   --budget <json>          default Scripts/perf-scroll-counters.json
#   --out <dir>              default $TMPDIR/adfreader-t1/<UTC stamp>; must
#                            not hold a trials.csv yet
#   --trial-timeout <s>      per trial; default 240
#   --ready-timeout <s>      READY deadline; default 60
#   --wait-others <s>        wait up to <s> for other perf runs; default 0
#   --force                  run even while other perf runs are active
#   --keep-device            do not delete a device this script created
#   --dry-run                resolve refs, check the host, print the plan
#
# OUTPUT  <out>/results.md, trials.csv, logs/, overlay-*.json, phases.tsv,
#         src/ (exports), dd/ (derived data), plan.txt.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$SCRIPT_DIR/.." && pwd)
TRIAL_PY="$SCRIPT_DIR/perf_trial.py"
HELPER_PY="$SCRIPT_DIR/perf_scroll_counters.py"
BUDGET="$SCRIPT_DIR/perf-scroll-counters.json"
CAPTAIN_UDID="FCBB16A4-94A8-406A-8F17-D9A189754F82"
BUNDLE_ID="com.connie.adfreader"

UDID=""
DEVICE_TYPE="iPhone 17 Pro"
RUNTIME=""
FIXTURES="kitchen-sink list-dense stress-1k"
RENDERERS="swiftui textkit2"
SPEED=6000
IDLE=5
CONFIG="Release"
BASE_APP=""
CAND_APP=""
OUT=""
TRIAL_TIMEOUT=240
READY_TIMEOUT=60
WAIT_OTHERS=0
FORCE=0
KEEP_DEVICE=0
DRY_RUN=0

RUN_START=$SECONDS
log() { printf '[t1 %s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 3; }
refuse() { log "REFUSED: $*"; exit 2; }

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        --udid) UDID="$2"; shift 2 ;;
        --device-type) DEVICE_TYPE="$2"; shift 2 ;;
        --runtime) RUNTIME="$2"; shift 2 ;;
        --fixtures) FIXTURES="$2"; shift 2 ;;
        --renderers) RENDERERS="$2"; shift 2 ;;
        --speed) SPEED="$2"; shift 2 ;;
        --idle) IDLE="$2"; shift 2 ;;
        --configuration) CONFIG="$2"; shift 2 ;;
        --base-app) BASE_APP="$2"; shift 2 ;;
        --candidate-app) CAND_APP="$2"; shift 2 ;;
        --budget) BUDGET="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --trial-timeout) TRIAL_TIMEOUT="$2"; shift 2 ;;
        --ready-timeout) READY_TIMEOUT="$2"; shift 2 ;;
        --wait-others) WAIT_OTHERS="$2"; shift 2 ;;
        --force) FORCE=1; shift ;;
        --keep-device) KEEP_DEVICE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --*) die "unknown option $1 (see --help)" ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done
[ "${#POSITIONAL[@]}" -eq 2 ] || { usage >&2; die "need <base-ref> <candidate-ref>"; }
BASE_REF="${POSITIONAL[0]}"; CAND_REF="${POSITIONAL[1]}"

for n in "$SPEED" "$IDLE" "$TRIAL_TIMEOUT" "$READY_TIMEOUT" "$WAIT_OTHERS"; do
    [[ "$n" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "numeric option expected, got '$n'"
done
for r in $RENDERERS; do
    case "$r" in swiftui|textkit2) ;; *) die "--renderers: unknown renderer '$r'" ;; esac
done
[ -f "$BUDGET" ] || die "no budget file $BUDGET"
if [ -n "$UDID" ] && [ "$(printf '%s' "$UDID" | tr '[:lower:]' '[:upper:]')" = "$CAPTAIN_UDID" ]; then
    refuse "$UDID is the captain's play simulator; never used for measurement"
fi

# ---------------------------------------------------------------- phases
PHASE_NAME=""; PHASE_START=0
phase() {
    local now=$SECONDS
    if [ -n "$PHASE_NAME" ]; then
        printf '%s\t%s\n' "$PHASE_NAME" "$(( now - PHASE_START ))" >> "$OUT/phases.tsv"
        log "phase '$PHASE_NAME' took $(( now - PHASE_START )) s"
    fi
    PHASE_NAME="$1"; PHASE_START=$now
    [ -z "$1" ] || log "phase '$1'"
}

# ------------------------------------------------------------------ refs
resolve_ref() {
    if [ "$1" = "." ]; then
        echo "worktree"
    else
        git -C "$REPO" rev-parse --verify --quiet "$1^{commit}" || refuse "unknown ref '$1'"
    fi
}
BASE_SHA=$(resolve_ref "$BASE_REF")
CAND_SHA=$(resolve_ref "$CAND_REF")
[ "$BASE_SHA" != "worktree" ] || refuse "the base must be a commit ('.' is for the candidate)"
label_for() {
    if [ "$1" = "worktree" ]; then
        local dirty=""
        [ -z "$(git -C "$REPO" status --porcelain)" ] || dirty="+dirty"
        echo "worktree@$(git -C "$REPO" rev-parse --short=10 HEAD)$dirty"
    else
        echo "${1:0:10}"
    fi
}
BASE_LABEL="$BASE_REF=$(label_for "$BASE_SHA")"
CAND_LABEL="$CAND_REF=$(label_for "$CAND_SHA")"

if [ -z "$OUT" ]; then
    OUT="${TMPDIR:-/tmp}"
    OUT="${OUT%/}/adfreader-t1/$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$OUT/logs" "$OUT/src" "$OUT/dd"
OUT=$(cd "$OUT" && pwd)
[ ! -s "$OUT/trials.csv" ] || die "$OUT/trials.csv exists; use a fresh --out"
: > "$OUT/phases.tsv"

# ---------------------------------------------------------- other lanes
phase "host check"
others=$(python3 -I "$HELPER_PY" others --self-pid $$)
if [ -n "$others" ] && [ "$FORCE" -eq 0 ]; then
    waited=0
    while [ -n "$others" ] && [ "$waited" -lt "${WAIT_OTHERS%.*}" ]; do
        log "another perf run is active; waiting (${waited}s of ${WAIT_OTHERS}s):"
        printf '%s\n' "$others" | sed 's/^/    /' >&2
        sleep 30; waited=$(( waited + 30 ))
        others=$(python3 -I "$HELPER_PY" others --self-pid $$)
    done
    if [ -n "$others" ]; then
        printf '%s\n' "$others" | sed 's/^/    /' >&2
        refuse "another perf run is active (above); --wait-others <s> to wait, --force to run anyway"
    fi
elif [ -n "$others" ]; then
    log "WARNING: running alongside other perf runs (--force):"
    printf '%s\n' "$others" | sed 's/^/    /' >&2
fi

{
    echo "date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "base=$BASE_LABEL ($BASE_SHA)${BASE_APP:+ app=$BASE_APP}"
    echo "candidate=$CAND_LABEL ($CAND_SHA)${CAND_APP:+ app=$CAND_APP}"
    echo "fixtures=$FIXTURES renderers=$RENDERERS speed=$SPEED idle=$IDLE configuration=$CONFIG"
    echo "udid=${UDID:-<created: $DEVICE_TYPE ${RUNTIME:-newest iOS}>} budget=$BUDGET"
    echo "host_load=$(sysctl -n vm.loadavg)"
    echo "xcodebuild=$(xcodebuild -version 2>/dev/null | tr '\n' ' ')"
} > "$OUT/plan.txt"
cat "$OUT/plan.txt" >&2
if [ "$DRY_RUN" -eq 1 ]; then
    for arm in base candidate; do
        for f in $FIXTURES; do
            for r in $RENDERERS; do
                log "trial $arm $f $r: -fixture $f -autoscroll -autoscrollSpeed $SPEED -scrollCounters -idleSeconds $IDLE -rendererStats $( [ "$r" = textkit2 ] && echo -textkit2 || echo -rendererReset )"
            done
        done
    done
    phase ""
    log "dry run: nothing exported, built or booted (out: $OUT)"
    exit 0
fi

# ------------------------------------------------------- export + build
command -v xcodegen >/dev/null || die "xcodegen not found"

export_ref() { # <sha|worktree> <dest>
    mkdir -p "$2"
    [ -z "$(ls -A "$2")" ] || die "$2 is not empty"
    if [ "$1" = "worktree" ]; then
        python3 -I "$HELPER_PY" export-worktree --repo "$REPO" --dest "$2" >&2
    else
        git -C "$REPO" archive "$1" | tar -x -C "$2"
    fi
}

build_arm() { # <name> <src> -> prints the .app path
    local name="$1" src="$2" dd="$OUT/dd/$1"
    xcodegen generate --spec "$src/Demo/project.yml" > "$OUT/logs/xcodegen-$name.log" 2>&1 \
        || die "xcodegen failed for $name (see $OUT/logs/xcodegen-$name.log)"
    xcodebuild build -project "$src/Demo/ADFReader.xcodeproj" -scheme ADFReader -configuration "$CONFIG" \
        -destination 'generic/platform=iOS Simulator' ARCHS=arm64 CODE_SIGNING_ALLOWED=NO \
        -derivedDataPath "$dd" > "$OUT/logs/build-$name.log" 2>&1 \
        || die "build failed for $name (see $OUT/logs/build-$name.log)"
    local app="$dd/Build/Products/$CONFIG-iphonesimulator/ADFReader.app"
    [ -d "$app" ] || die "no app at $app"
    echo "$app"
}

SRC_BASE="$OUT/src/base"; SRC_CAND="$OUT/src/candidate"
if [ -z "$CAND_APP" ] || [ -z "$BASE_APP" ]; then
    phase "export"
    export_ref "$CAND_SHA" "$SRC_CAND"
    [ -n "$BASE_APP" ] || export_ref "$BASE_SHA" "$SRC_BASE"
    phase "overlay"
    # The candidate first: if it predates T1 too, it takes the working tree's
    # instrumentation, and the base then takes exactly the candidate's.
    python3 -I "$HELPER_PY" overlay --dest "$SRC_CAND" --source "$REPO" --fixture-source "$REPO" \
        --fixtures "$FIXTURES" --record "$OUT/overlay-candidate.json" >&2 || refuse "candidate overlay (above)"
    if [ -z "$BASE_APP" ]; then
        python3 -I "$HELPER_PY" overlay --dest "$SRC_BASE" --source "$SRC_CAND" --fixture-source "$SRC_CAND" \
            --fixtures "$FIXTURES" --record "$OUT/overlay-base.json" >&2 || refuse "base overlay (above)"
    fi
fi
if [ -z "$BASE_APP" ]; then
    phase "build base"
    BASE_APP=$(build_arm base "$SRC_BASE")
fi
if [ -z "$CAND_APP" ]; then
    phase "build candidate"
    CAND_APP=$(build_arm candidate "$SRC_CAND")
fi
for app in "$BASE_APP" "$CAND_APP"; do
    [ -x "$app/ADFReader" ] || die "no executable at $app/ADFReader"
    for f in $FIXTURES; do
        [ -f "$app/$f.json" ] || refuse "$app does not bundle $f.json"
    done
done
log "base app: $BASE_APP ($(shasum -a 256 "$BASE_APP/ADFReader" | cut -c1-12))"
log "candidate app: $CAND_APP ($(shasum -a 256 "$CAND_APP/ADFReader" | cut -c1-12))"

# -------------------------------------------------------------- device
CREATED=0; BOOTED_BY_US=0; LAUNCH_PID=""
device_state() { xcrun simctl list devices -j | python3 -I "$HELPER_PY" device-state --udid "$UDID"; }
terminate_app() { xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true; }

# Signal a child only while it is still ours (PIDs wrap within minutes on
# this host; see the lifecycle gate's `ours`).
stop_child() {
    local pid="$1"
    [ -n "$pid" ] || return 0
    if [ "$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')" = "$$" ]; then
        kill -TERM "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    stop_child "$LAUNCH_PID"
    if [ -n "$UDID" ]; then
        terminate_app
        if [ "$CREATED" -eq 1 ] && [ "$KEEP_DEVICE" -eq 0 ]; then
            log "deleting the device this run created ($UDID)"
            xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
            xcrun simctl delete "$UDID" >/dev/null 2>&1 || log "WARNING: could not delete $UDID"
        elif [ "$BOOTED_BY_US" -eq 1 ] && [ "$CREATED" -eq 0 ]; then
            log "shutting down $UDID (this run booted it)"
            xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
        fi
    fi
    [ -z "$PHASE_NAME" ] || phase ""
    log "total run time $(( SECONDS - RUN_START )) s (out: $OUT)"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

phase "simulator"
if [ -n "$UDID" ]; then
    state=$(device_state)
    case "$state" in
        Booted) log "device $UDID already booted (left booted)" ;;
        Shutdown) log "booting $UDID"; xcrun simctl boot "$UDID"; BOOTED_BY_US=1 ;;
        Missing) die "no simulator with udid $UDID" ;;
        *) die "device $UDID is in state '$state'" ;;
    esac
else
    [ -n "$RUNTIME" ] || RUNTIME=$(xcrun simctl list runtimes -j | python3 -I "$HELPER_PY" pick-runtime --device-type "$DEVICE_TYPE") \
        || die "no runtime for $DEVICE_TYPE"
    UDID=$(xcrun simctl create "adf-t1-$(date -u +%Y%m%dT%H%M%S)-$$" "$DEVICE_TYPE" "$RUNTIME")
    CREATED=1
    log "created $UDID ($DEVICE_TYPE, $RUNTIME); booting"
    xcrun simctl boot "$UDID"
    BOOTED_BY_US=1
fi
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl ui "$UDID" appearance light >/dev/null 2>&1 || true
echo "udid=$UDID created=$CREATED booted_by_us=$BOOTED_BY_US" >> "$OUT/plan.txt"

install_app() { # <app> -> prints the installed binary's sha256
    local container
    terminate_app
    xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl install "$UDID" "$1"
    container=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" app 2>/dev/null || true)
    if [ -n "$container" ] && [ -f "$container/ADFReader" ]; then
        shasum -a 256 "$container/ADFReader" | awk '{print $1}'
    fi
}

renderer_flag() { [ "$1" = textkit2 ] && echo "-textkit2" || echo "-rendererReset"; }

# run_trial <arm> <renderer> <fixture> <stem> [csv]  (no csv: throwaway)
run_trial() {
    local arm="$1" renderer="$2" fixture="$3" stem="$4" csv="${5:-}"
    local logf="$OUT/logs/$stem.log" start ready=0 shell_status="" idle="$IDLE"
    [ -n "$csv" ] || idle=0  # the throwaway launch only warms the device
    local -a argv=(-fixture "$fixture" -autoscroll -autoscrollSpeed "$SPEED" -scrollCounters
                   -idleSeconds "$idle" -rendererStats "$(renderer_flag "$renderer")")
    python3 -I -u "$TRIAL_PY" launch --log "$logf" -- \
        xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID" "${argv[@]}" &
    LAUNCH_PID=$!
    start=$SECONDS
    while kill -0 "$LAUNCH_PID" 2>/dev/null; do
        if [ "$ready" -eq 0 ] && grep -q "$(printf '\tREADY fixture=')" "$logf" 2>/dev/null; then
            ready=1
        fi
        if [ "$ready" -eq 0 ] && [ $(( SECONDS - start )) -ge "${READY_TIMEOUT%.*}" ]; then
            shell_status="no_ready"
        elif [ $(( SECONDS - start )) -ge "${TRIAL_TIMEOUT%.*}" ]; then
            shell_status="timeout"
        fi
        if [ -n "$shell_status" ]; then
            log "$stem: $shell_status"
            terminate_app
            sleep 1
            stop_child "$LAUNCH_PID"
            break
        fi
        sleep 0.2
    done
    wait "$LAUNCH_PID" 2>/dev/null || true
    LAUNCH_PID=""
    [ -n "$csv" ] || { log "$stem: throwaway done ($(( SECONDS - start )) s)"; return 0; }
    local digest
    digest=$(python3 -I "$TRIAL_PY" parse --log "$logf" --samples - --csv "$csv" \
        --meta "run=1" --meta "fixture=$fixture" --meta "arm=$arm" --meta "label=$renderer" \
        --meta "argv=${argv[*]}" --meta "requires_completion=1" --meta "requires_counters=1" \
        --meta "trial_timeout_s=$TRIAL_TIMEOUT" --meta "shell_status=$shell_status" \
        --meta "started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --meta "host_load1=$(sysctl -n vm.loadavg | awk '{print $2}')" \
        --meta "app_sha256=$INSTALLED_SHA" --meta "installed_sha256=$INSTALLED_SHA")
    log "$stem ($(( SECONDS - start )) s): $digest"
}

phase "throwaway launch"
INSTALLED_SHA=$(install_app "$CAND_APP")
run_trial candidate swiftui "$(set -- $FIXTURES; echo "$1")" "throwaway"

phase "trials"
CSV="$OUT/trials.csv"
for arm in base candidate; do
    if [ "$arm" = base ]; then app="$BASE_APP"; else app="$CAND_APP"; fi
    INSTALLED_SHA=$(install_app "$app")
    for fixture in $FIXTURES; do
        for renderer in $RENDERERS; do
            run_trial "$arm" "$renderer" "$fixture" "$arm-$fixture-$renderer" "$CSV"
        done
    done
done

phase ""
printf 'total before compare\t%s\n' "$(( SECONDS - RUN_START ))" >> "$OUT/phases.tsv"
overlays=()
for f in "$OUT/overlay-base.json" "$OUT/overlay-candidate.json"; do
    [ ! -f "$f" ] || overlays+=(--overlay "$f")
done
set +e
python3 -I "$HELPER_PY" compare --csv "$CSV" --budget "$BUDGET" --out "$OUT/results.md" \
    --speed "$SPEED" --base-label "$BASE_LABEL" --candidate-label "$CAND_LABEL" \
    --phases "$OUT/phases.tsv" "${overlays[@]+"${overlays[@]}"}"
verdict=$?
set -e
log "report: $OUT/results.md"
exit "$verdict"
