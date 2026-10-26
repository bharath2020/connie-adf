#!/usr/bin/env bash
# Scripts/perf-gate.sh — fail-closed A/B/C performance gate for the ADFReader
# demo app on one iOS Simulator (docs: plan §6). Measures preparation
# readiness (launch→READY, first chunk), autoscroll dropped frames / rate /
# hitch ratio, and memory (RSS + phys_footprint) for a candidate build
# against a reference build, with calibrated paired noise bounds.
#
# USAGE
#   # 1. calibration — the reference .app as both arms (A, A2):
#   Scripts/perf-gate.sh --calibrate --udid <UDID> --app-a <main ADFReader.app> \
#       --out <data>/perf/calibration [--fixtures "..."] [--runs 10]
#   # 2. gate:
#   Scripts/perf-gate.sh --udid <UDID> --app-a <main .app> --app-c <branch .app> \
#       --app-b <branch .app> --calibration <data>/perf/calibration/calibration.json \
#       --out <data>/perf/gate [--fixtures "..."] [--runs 10]
#
# OPTIONS
#   --udid <UDID>            required; the device must exist (never created).
#                            Booted if shut down — and then shut down at the
#                            end (unless --keep-booted); a device that was
#                            already booted is left booted. Refuses to run if
#                            another simulator is booted.
#   --app-a / --app-b / --app-c <ADFReader.app>
#   --calibrate              A vs A2 (both --app-a); writes calibration.json
#   --calibration <json>     frozen calibration for the gate (required unless
#                            --pilot); its sha256 is recorded in plan.json
#                            before the first trial
#   --pilot                  pilot run: default 5 runs, verdict never PASS
#   --fixtures "<names>"     default "kitchen-sink stress-5k giant-table
#                            text-dense long-paragraph"
#   --runs <n>               counted pairs per (fixture, arm); default 10
#                            (5 with --pilot); the gate needs >= 10
#   --warmup <n>             discarded warm-ups per (fixture, arm); default 1
#   --out <dir>              default $TMPDIR/adfreader-perf/<UTC stamp>
#   --arm-c-args "<flags>"   candidate renderer flags; default "-textkit2"
#   --candidate-args "<f>"   extra flags for the candidate binary (B and C);
#                            default "-rendererStats"
#   --no-candidate-markers   do not require SCROLL_METRICS completion fields
#                            or RENDERER_STATS from B/C (pre-plumbing pilot)
#   --extra-args "<flags>"   appended for every arm (e.g. "-fontSizeStep 3")
#   --expected-blocks "f=n …" READY block count each fixture must report
#   --trial-timeout <s>      fallback per-trial deadline; default 120
#   --trial-timeout-for "f=s …" per-fixture deadlines; defaults
#                            (1.5 × static scroll estimate + 30 s, min 60):
#                            kitchen-sink=60 stress-5k=220 giant-table=120
#                            text-dense=405 long-paragraph=60 — replace them
#                            with `perf_summarize.py --suggest-timeouts` on a
#                            pilot CSV
#   --ready-timeout <s>      READY deadline; default 60
#   --rss-ms <ms> / --footprint-ms <ms>  sampler periods; default 200 / 1000
#   --no-sampler             no memory sampling (measure sampler overhead:
#                            pilot with and without, compare dropped frames)
#   --prior-summary <json>   previous gate summary (rerun rule, see
#                            perf_summarize.py)
#   --coverage "<text>"      coverage line for the summary table
#   --appearance <light|dark>  default light
#   --bundle-id <id>         default com.connie.adfreader
#   --keep-booted            never shut the device down
#   --dry-run                print plan.json and the ordered trial list; no
#                            simulator or app is touched
#
# ARMS
#   A   reference (--app-a), launched without the candidate flags
#   C   candidate (--app-c) with --arm-c-args + --candidate-args
#   B   candidate binary (--app-b) with --candidate-args only — the shipping
#       path with the switch OFF (font-spec baking, switch plumbing)
#   A2  (calibration) the reference again, identical argv
#   Balanced order per run: odd runs A,C,B / even runs B,C,A (every A–C and
#   A–B pair alternates); calibration alternates A,A2 / A2,A.
#
# PROCEDURE (per trial)
#   terminate + uninstall + install the arm's .app (fresh install: no
#   UserDefaults leak between arms; OS and font caches stay warm —
#   "fresh-install, warmed-system"), verify the installed binary's sha256,
#   set the appearance, start the memory sampler (own process, own clock),
#   then `perf_trial.py launch` takes t0 and spawns
#   `xcrun simctl launch --console-pty <udid> <bundle> -fixture <f>
#   -autoscroll [extra] [arm flags]`, stamping every output line with its
#   arrival time. The driver only polls for deadlines (READY, trial); it
#   never timestamps anything. `perf_trial.py parse` derives the CSV row.
#
# OUTPUT (<out>/)
#   plan.json      declared fixtures/runs/arms/shas/flags/timeouts/calibration
#   trials.csv     counted trials (columns: Scripts/perf_trial.py CSV_COLUMNS)
#   warmup.csv     discarded warm-ups
#   env.txt        host, Xcode, device, apps
#   logs/<stem>.log      stamped app output (#T0, lines, #EXIT)
#   samples/<stem>.tsv   memory samples with their own timestamps
#   summary.md/.json (gate) or calibration.json/.md (calibration)
#
# EXIT  the summarizer's status: 0 PASS/CALIBRATED, 1 FAIL, 2 INVALID,
#       3 INCONCLUSIVE, 4 PILOT; 2 also for usage errors and driver failures.
#
# bash 3.2 compatible (macOS /bin/bash); needs python3 (-I), xcrun.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRIAL_PY="$SCRIPT_DIR/perf_trial.py"
SUMMARIZE_PY="$SCRIPT_DIR/perf_summarize.py"

# ---------------------------------------------------------------- defaults
UDID=""
APP_A=""; APP_B=""; APP_C=""
LABEL_A="main"; LABEL_B="branch (switch OFF)"; LABEL_C="branch (TextKit 2)"
MODE="gate"
CALIBRATION=""
PILOT=0
FIXTURES="kitchen-sink stress-5k giant-table text-dense long-paragraph"
RUNS=""
WARMUP=1
OUT=""
ARM_C_ARGS="-textkit2"
CANDIDATE_ARGS="-rendererStats"
CANDIDATE_MARKERS=1
EXTRA_ARGS=""
EXPECTED_BLOCKS=""
TRIAL_TIMEOUT=120
DEFAULT_TIMEOUTS="kitchen-sink=60 stress-5k=220 giant-table=120 text-dense=405 long-paragraph=60"
TIMEOUTS_FOR=""
READY_TIMEOUT=60
RSS_MS=200
FOOTPRINT_MS=1000
SAMPLER=1
PRIOR_SUMMARY=""
COVERAGE=""
APPEARANCE="light"
BUNDLE_ID="com.connie.adfreader"
KEEP_BOOTED=0
DRY_RUN=0

# ---------------------------------------------------------------- helpers
log() { printf '[perf-gate %s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 2; }
usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }

# lookup "<key>" "<k=v k=v …>" -> v or ""
lookup() {
    local key="$1" pair
    for pair in $2; do
        case "$pair" in "$key="*) echo "${pair#*=}"; return 0 ;; esac
    done
    echo ""
}

timeout_for() {
    local v
    v=$(lookup "$1" "$TIMEOUTS_FOR")
    [ -n "$v" ] || v=$(lookup "$1" "$DEFAULT_TIMEOUTS")
    [ -n "$v" ] || v="$TRIAL_TIMEOUT"
    echo "$v"
}

app_executable() {
    local plist="$1/Info.plist" name=""
    if [ -f "$plist" ]; then
        name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null || true)
    fi
    echo "${name:-ADFReader}"
}

sha256_of_app() {
    local app="$1" exe
    exe=$(app_executable "$app")
    if [ ! -f "$app/$exe" ]; then
        [ "$DRY_RUN" -eq 1 ] && { echo "dry-run-no-binary"; return 0; }
        die "no executable at $app/$exe"
    fi
    shasum -a 256 "$app/$exe" | awk '{print $1}'
}

device_field() {   # device_field <udid> <state|name|runtime>
    xcrun simctl list devices -j | python3 -I -c '
import json, sys
want, field = sys.argv[1].lower(), sys.argv[2]
for runtime, devices in json.load(sys.stdin).get("devices", {}).items():
    for d in devices:
        if d.get("udid", "").lower() == want:
            print({"state": d.get("state", "?"), "name": d.get("name", "?"), "runtime": runtime}[field])
            sys.exit(0)
print("Missing" if field == "state" else "?")
' "$1" "$2"
}

other_booted() {
    xcrun simctl list devices -j | python3 -I -c '
import json, sys
me = sys.argv[1].lower()
for devices in json.load(sys.stdin).get("devices", {}).values():
    for d in devices:
        if d.get("state") == "Booted" and d.get("udid", "").lower() != me:
            print(d["udid"])
' "$1"
}

BOOTED_BY_US=0
ensure_booted() {
    local state others
    others=$(other_booted "$UDID")
    [ -z "$others" ] || die "another simulator is booted ($others); one device at a time"
    state=$(device_field "$UDID" state)
    case "$state" in
        Booted) log "device $UDID already booted (will be left booted)" ;;
        Shutdown) log "booting $UDID"; xcrun simctl boot "$UDID"; BOOTED_BY_US=1 ;;
        Missing) die "no simulator with udid $UDID (this script never creates devices)" ;;
        *) die "device $UDID is in state '$state'" ;;
    esac
    xcrun simctl bootstatus "$UDID" -b >/dev/null
}

terminate_app() { xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true; }

# install_arm <app> -> prints the installed binary's sha256
install_arm() {
    local app="$1" container
    terminate_app
    xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl install "$UDID" "$app"
    container=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" app 2>/dev/null || true)
    if [ -n "$container" ] && [ -f "$container/$APP_EXE" ]; then
        shasum -a 256 "$container/$APP_EXE" | awk '{print $1}'
    else
        echo ""
    fi
}

# arm_* lookups (bash 3.2: no associative arrays)
arm_app()  { case "$1" in A|A2) echo "$APP_A" ;; B) echo "$APP_B" ;; C) echo "$APP_C" ;; esac; }
arm_sha()  { case "$1" in A|A2) echo "$SHA_A" ;; B) echo "$SHA_B" ;; C) echo "$SHA_C" ;; esac; }
arm_label() { case "$1" in A) echo "$LABEL_A" ;; A2) echo "$LABEL_A (repeat)" ;; B) echo "$LABEL_B" ;; C) echo "$LABEL_C" ;; esac; }
arm_flags() {
    case "$1" in
        A|A2) echo "" ;;
        B) echo "$CANDIDATE_ARGS" ;;
        C) echo "$ARM_C_ARGS $CANDIDATE_ARGS" ;;
    esac
}
arm_requires_completion() {
    case "$1" in B|C) [ "$CANDIDATE_MARKERS" -eq 1 ] && echo 1 || echo 0 ;; *) echo 0 ;; esac
}

# Arm order for run <n>: balanced pairs.
arm_order() {
    local run="$1"
    if [ "$MODE" = "calibrate" ]; then
        if [ $(( run % 2 )) -eq 1 ]; then echo "A A2"; else echo "A2 A"; fi
    else
        local odd="A C" even="C A"
        if [ -n "$APP_B" ]; then odd="A C B"; even="B C A"; fi
        if [ $(( run % 2 )) -eq 1 ]; then echo "$odd"; else echo "$even"; fi
    fi
}

write_plan() {
    local arms="A A2"
    [ "$MODE" = "calibrate" ] || { arms="A C"; [ -z "$APP_B" ] || arms="A C B"; }
    local arm_specs="" arm
    for arm in $arms; do
        arm_specs="$arm_specs$arm|$(arm_label "$arm")|$(arm_app "$arm")|$(arm_sha "$arm")|$(arm_flags "$arm")|$(arm_requires_completion "$arm")
"
    done
    local cal_sha=""
    [ -z "$CALIBRATION" ] || cal_sha=$(shasum -a 256 "$CALIBRATION" | awk '{print $1}')
    local timeouts="" f
    for f in $FIXTURES; do timeouts="$timeouts $f=$(timeout_for "$f")"; done
    ARM_SPECS="$arm_specs" P_MODE="$MODE" P_ARM_C="$ARM_C_ARGS" P_CAND="$CANDIDATE_ARGS" \
    P_MARKERS="$CANDIDATE_MARKERS" P_EXPECTED="$EXPECTED_BLOCKS" P_PILOT="$PILOT" P_FIXTURES="$FIXTURES" \
    P_RUNS="$RUNS" P_WARMUP="$WARMUP" P_EXTRA="$EXTRA_ARGS" P_APPEARANCE="$APPEARANCE" P_SAMPLER="$SAMPLER" \
    P_RSS_MS="$RSS_MS" P_FP_MS="$FOOTPRINT_MS" P_READY="$READY_TIMEOUT" P_TIMEOUTS="$timeouts" \
    P_CAL="$CALIBRATION" P_CAL_SHA="$cal_sha" P_UDID="$UDID" P_BUNDLE="$BUNDLE_ID" \
    python3 -I - "$OUT/plan.json" <<'PY'
import json, os, sys
env = os.environ
mode = env["P_MODE"]
arm_c = env["P_ARM_C"].split()
cand = env["P_CAND"].split()
markers = env["P_MARKERS"] == "1"
arms = {}
for line in env["ARM_SPECS"].strip().splitlines():
    arm, label, app, sha, flags, completion = line.split("|")
    candidate = arm in ("B", "C")
    renderer = None
    if candidate and markers and "-rendererStats" in cand:
        renderer = "textkit2" if arm == "C" else "swiftui"
    arms[arm] = {
        "label": label, "app": app, "sha256": sha,
        "role": "candidate" if candidate else "baseline",
        "required_flags": flags.split(),
        "forbidden_flags": [] if arm == "C" else arm_c + ([] if candidate else cand),
        "requires_completion": completion == "1",
        "expected_renderer": renderer,
    }
expected = {}
for pair in env["P_EXPECTED"].split():
    k, _, v = pair.partition("=")
    expected[k] = int(v)
sampler = env["P_SAMPLER"] == "1"
plan = {
    "version": 2, "mode": mode, "pilot": env["P_PILOT"] == "1",
    "fixtures": env["P_FIXTURES"].split(), "runs": int(env["P_RUNS"]), "warmup": int(env["P_WARMUP"]),
    "reference": "A", "candidates": ["A2"] if mode == "calibrate" else [a for a in ("C", "B") if a in arms],
    "arms": arms, "extra_args": env["P_EXTRA"].split(), "appearance": env["P_APPEARANCE"],
    "sampler": sampler, "footprint": sampler and os.access("/usr/bin/footprint", os.X_OK),
    "rss_ms": int(env["P_RSS_MS"]), "footprint_ms": int(env["P_FP_MS"]),
    "ready_timeout_s": int(env["P_READY"]),
    "trial_timeouts_s": {p.split("=")[0]: int(p.split("=")[1]) for p in env["P_TIMEOUTS"].split()},
    "expected_blocks": expected,
    "calibration": {"path": os.path.abspath(env["P_CAL"]), "sha256": env["P_CAL_SHA"]} if env["P_CAL"] else None,
    "udid": env["P_UDID"], "bundle_id": env["P_BUNDLE"],
    "trial_kind": "fresh-install, warmed-system",
}
with open(sys.argv[1], "w") as fh:
    json.dump(plan, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}

LAUNCH_PID=""
SAMPLER_PID=""

stop_sampler() {
    if [ -n "$SAMPLER_PID" ]; then
        kill -TERM "$SAMPLER_PID" 2>/dev/null || true
        wait "$SAMPLER_PID" 2>/dev/null || true
        SAMPLER_PID=""
    fi
}

# run_trial <run> <fixture> <arm> <csv> <order_index>
run_trial() {
    local run="$1" fixture="$2" arm="$3" csv="$4" order_index="$5"
    local app sha label stem logf samplef deadline
    app=$(arm_app "$arm"); sha=$(arm_sha "$arm"); label=$(arm_label "$arm")
    stem="run${run}-${fixture}-${arm}"
    logf="$OUT/logs/$stem.log"; samplef="$OUT/samples/$stem.tsv"
    deadline=$(timeout_for "$fixture")

    # shellcheck disable=SC2206,SC2207  # intentional word splitting of flag strings
    local -a argv=(-fixture "$fixture" -autoscroll $EXTRA_ARGS $(arm_flags "$arm"))

    if [ "$DRY_RUN" -eq 1 ]; then
        printf '%-28s order=%s timeout=%ss  simctl launch --console-pty %s %s %s\n' \
            "$stem" "$order_index" "$deadline" "$UDID" "$BUNDLE_ID" "${argv[*]}"
        return 0
    fi

    local installed
    installed=$(install_arm "$app")
    [ "$installed" = "$sha" ] || log "$stem: PROVENANCE MISMATCH installed=${installed:-none} expected=$sha"
    xcrun simctl ui "$UDID" appearance "$APPEARANCE" >/dev/null 2>&1 || true

    if [ "$SAMPLER" -eq 1 ]; then
        python3 -I -u "$TRIAL_PY" sample --udid "$UDID" --exe "$APP_EXE" --out "$samplef" \
            --rss-ms "$RSS_MS" --footprint-ms "$FOOTPRINT_MS" --pid-timeout "$READY_TIMEOUT" &
        SAMPLER_PID=$!
    else
        : > "$samplef"
    fi

    python3 -I -u "$TRIAL_PY" launch --log "$logf" -- \
        xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID" "${argv[@]}" &
    LAUNCH_PID=$!

    local start=$SECONDS shell_status="" ready=0
    while kill -0 "$LAUNCH_PID" 2>/dev/null; do
        if [ "$ready" -eq 0 ] && grep -q "$(printf '\tREADY fixture=')" "$logf" 2>/dev/null; then
            ready=1
        fi
        if [ "$ready" -eq 0 ] && [ $(( SECONDS - start )) -ge "$READY_TIMEOUT" ]; then
            shell_status="no_ready"; log "$stem: no READY within ${READY_TIMEOUT}s"
        elif [ $(( SECONDS - start )) -ge "$deadline" ]; then
            shell_status="timeout"; log "$stem: trial deadline ${deadline}s exceeded"
        fi
        if [ -n "$shell_status" ]; then
            terminate_app
            sleep 1
            kill -TERM "$LAUNCH_PID" 2>/dev/null || true
            break
        fi
        sleep 0.2
    done
    wait "$LAUNCH_PID" 2>/dev/null || true
    LAUNCH_PID=""
    stop_sampler

    local digest
    digest=$(python3 -I "$TRIAL_PY" parse --log "$logf" --samples "$samplef" --csv "$csv" \
        --meta "run=$run" --meta "fixture=$fixture" --meta "arm=$arm" --meta "label=$label" \
        --meta "order_index=$order_index" --meta "app_sha256=$sha" --meta "installed_sha256=$installed" \
        --meta "argv=${argv[*]}" --meta "requires_completion=$(arm_requires_completion "$arm")" \
        --meta "trial_timeout_s=$deadline" --meta "shell_status=$shell_status")
    log "$stem: $digest"
}

SUMMARY_DONE=0
cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    # A driver failure must never read as a verdict (1 = FAIL): map it to 2.
    if [ "$SUMMARY_DONE" -ne 1 ] && [ "$rc" -ne 0 ]; then rc=2; fi
    if [ -n "${LAUNCH_PID:-}" ]; then kill -TERM "$LAUNCH_PID" 2>/dev/null || true; fi
    stop_sampler
    if [ -n "${UDID:-}" ] && [ "${DEVICE_READY:-0}" = "1" ]; then
        terminate_app
        if [ "$BOOTED_BY_US" -eq 1 ] && [ "$KEEP_BOOTED" -eq 0 ]; then
            log "shutting down $UDID (booted by this run)"
            xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
        fi
    fi
    exit "$rc"
}

# ---------------------------------------------------------------- main
main() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --udid) UDID="$2"; shift 2 ;;
            --app-a) APP_A="$2"; shift 2 ;;
            --app-b) APP_B="$2"; shift 2 ;;
            --app-c) APP_C="$2"; shift 2 ;;
            --label-a) LABEL_A="$2"; shift 2 ;;
            --label-b) LABEL_B="$2"; shift 2 ;;
            --label-c) LABEL_C="$2"; shift 2 ;;
            --calibrate) MODE="calibrate"; shift ;;
            --calibration) CALIBRATION="$2"; shift 2 ;;
            --pilot) PILOT=1; shift ;;
            --fixtures) FIXTURES="$2"; shift 2 ;;
            --runs) RUNS="$2"; shift 2 ;;
            --warmup) WARMUP="$2"; shift 2 ;;
            --out) OUT="$2"; shift 2 ;;
            --arm-c-args) ARM_C_ARGS="$2"; shift 2 ;;
            --candidate-args) CANDIDATE_ARGS="$2"; shift 2 ;;
            --no-candidate-markers) CANDIDATE_MARKERS=0; shift ;;
            --extra-args) EXTRA_ARGS="$2"; shift 2 ;;
            --expected-blocks) EXPECTED_BLOCKS="$2"; shift 2 ;;
            --trial-timeout) TRIAL_TIMEOUT="$2"; shift 2 ;;
            --trial-timeout-for) TIMEOUTS_FOR="$2"; shift 2 ;;
            --ready-timeout) READY_TIMEOUT="$2"; shift 2 ;;
            --rss-ms) RSS_MS="$2"; shift 2 ;;
            --footprint-ms) FOOTPRINT_MS="$2"; shift 2 ;;
            --no-sampler) SAMPLER=0; shift ;;
            --prior-summary) PRIOR_SUMMARY="$2"; shift 2 ;;
            --coverage) COVERAGE="$2"; shift 2 ;;
            --appearance) APPEARANCE="$2"; shift 2 ;;
            --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
            --keep-booted) KEEP_BOOTED=1; shift ;;
            --dry-run) DRY_RUN=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "unknown option: $1 (see --help)" ;;
        esac
    done
    [ -n "$RUNS" ] || { if [ "$PILOT" -eq 1 ]; then RUNS=5; else RUNS=10; fi; }
    [ -n "$UDID" ] || die "--udid is required"
    [ -n "$APP_A" ] || die "--app-a <ADFReader.app> is required"
    [ "$DRY_RUN" -eq 1 ] || [ -d "$APP_A" ] || die "--app-a: not a directory: $APP_A"
    if [ "$MODE" = "calibrate" ]; then
        [ -z "$APP_B$APP_C" ] || die "--calibrate uses --app-a only (as A and A2)"
        [ -z "$CALIBRATION" ] || die "--calibrate and --calibration are exclusive"
    else
        [ -n "$APP_C" ] || die "--app-c <ADFReader.app> is required (or --calibrate)"
        [ "$DRY_RUN" -eq 1 ] || [ -d "$APP_C" ] || die "--app-c: not a directory: $APP_C"
        if [ -n "$APP_B" ] && [ "$DRY_RUN" -eq 0 ]; then [ -d "$APP_B" ] || die "--app-b: not a directory: $APP_B"; fi
        if [ -z "$CALIBRATION" ] && [ "$PILOT" -eq 0 ]; then
            die "--calibration <calibration.json> is required (run --calibrate first; only --pilot may skip it)"
        fi
        if [ -n "$CALIBRATION" ]; then
            [ -f "$CALIBRATION" ] || die "--calibration: no such file: $CALIBRATION"
            local cal_verdict
            cal_verdict=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("verdict",""))' "$CALIBRATION")
            case "$cal_verdict" in
                CALIBRATED) ;;
                PILOT) [ "$PILOT" -eq 1 ] || die "calibration is a pilot calibration; rerun it with >= 10 runs" ;;
                INCONCLUSIVE) log "calibration is INCONCLUSIVE: quiesce the host and rerun it once; do not gate"; exit 3 ;;
                *) die "calibration verdict '$cal_verdict' is not usable" ;;
            esac
        fi
    fi
    case "$RUNS" in ''|*[!0-9]*) die "--runs must be a positive integer" ;; esac
    [ "$RUNS" -ge 1 ] || die "--runs must be >= 1"
    if [ "$PILOT" -eq 0 ] && [ "$RUNS" -lt 10 ]; then
        die "--runs $RUNS: the gate and the calibration need >= 10 pairs (5 = --pilot only)"
    fi
    if [ -n "$PRIOR_SUMMARY" ]; then [ -f "$PRIOR_SUMMARY" ] || die "--prior-summary: no such file"; fi
    command -v python3 >/dev/null || die "python3 not found"
    [ -f "$TRIAL_PY" ] || die "missing $TRIAL_PY"

    if [ -z "$OUT" ]; then
        OUT="${TMPDIR:-/tmp}"
        OUT="${OUT%/}/adfreader-perf/$(date -u +%Y%m%dT%H%M%SZ)"
    fi
    mkdir -p "$OUT/logs" "$OUT/samples"
    OUT=$(cd "$OUT" && pwd)
    if [ "$DRY_RUN" -eq 0 ] && [ -s "$OUT/trials.csv" ]; then
        die "$OUT/trials.csv already exists; use a fresh --out (runs are never appended)"
    fi

    APP_EXE=$(app_executable "$APP_A")
    SHA_A=$(sha256_of_app "$APP_A"); SHA_B=""; SHA_C=""
    [ -z "$APP_C" ] || SHA_C=$(sha256_of_app "$APP_C")
    [ -z "$APP_B" ] || SHA_B=$(sha256_of_app "$APP_B")
    if [ "$MODE" = "gate" ] && [ "$SHA_A" = "$SHA_C" ]; then
        log "WARNING: app-a and app-c have the same binary sha256"
    fi

    write_plan
    if [ "$DRY_RUN" -eq 1 ]; then
        log "dry run: plan $OUT/plan.json"
        cat "$OUT/plan.json"
    else
        {
            echo "date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            echo "host=$(hostname) $(sw_vers -productVersion 2>/dev/null || true) $(uname -m)"
            echo "xcodebuild=$(xcodebuild -version 2>/dev/null | tr '\n' ' ')"
            echo "udid=$UDID device=$(device_field "$UDID" name) runtime=$(device_field "$UDID" runtime)"
            echo "mode=$MODE pilot=$PILOT fixtures=$FIXTURES runs=$RUNS warmup=$WARMUP"
            echo "sampler=$SAMPLER rss_ms=$RSS_MS footprint_ms=$FOOTPRINT_MS"
            echo "A app=$APP_A sha256=$SHA_A"
            [ -z "$APP_C" ] || echo "C app=$APP_C sha256=$SHA_C"
            [ -z "$APP_B" ] || echo "B app=$APP_B sha256=$SHA_B"
            [ -z "$CALIBRATION" ] || echo "calibration=$CALIBRATION"
        } > "$OUT/env.txt"
        log "output: $OUT"
        trap cleanup EXIT INT TERM
        ensure_booted
        DEVICE_READY=1
    fi

    local trials="$OUT/trials.csv" warm="$OUT/warmup.csv" w fixture run arm i
    w=1
    while [ "$w" -le "$WARMUP" ]; do
        for fixture in $FIXTURES; do
            [ "$DRY_RUN" -eq 1 ] || log "warm-up $w/$WARMUP fixture=$fixture"
            i=0
            for arm in $(arm_order "$w"); do
                i=$(( i + 1 )); run_trial 0 "$fixture" "$arm" "$warm" "$i"
            done
        done
        w=$(( w + 1 ))
    done
    run=1
    while [ "$run" -le "$RUNS" ]; do
        for fixture in $FIXTURES; do
            [ "$DRY_RUN" -eq 1 ] || log "run $run/$RUNS fixture=$fixture order: $(arm_order "$run")"
            i=0
            for arm in $(arm_order "$run"); do
                i=$(( i + 1 )); run_trial "$run" "$fixture" "$arm" "$trials" "$i"
            done
        done
        run=$(( run + 1 ))
    done
    [ "$DRY_RUN" -eq 0 ] || exit 0

    log "trials done: $trials"
    local -a summary_args=("$trials" --plan "$OUT/plan.json" --quiet)
    [ "$PILOT" -eq 0 ] || summary_args+=(--pilot)
    if [ "$MODE" = "calibrate" ]; then
        summary_args+=(--calibrate --write-calibration "$OUT/calibration.json")
    else
        summary_args+=(--json "$OUT/summary.json")
        [ -z "$CALIBRATION" ] || summary_args+=(--calibration "$CALIBRATION")
        [ -z "$PRIOR_SUMMARY" ] || summary_args+=(--prior-summary "$PRIOR_SUMMARY")
        [ -z "$COVERAGE" ] || summary_args+=(--coverage "$COVERAGE")
    fi
    local status=0
    python3 -I "$SUMMARIZE_PY" "${summary_args[@]}" || status=$?
    log "summary exit status $status (0 PASS/CALIBRATED, 1 FAIL, 2 INVALID, 3 INCONCLUSIVE, 4 PILOT)"
    SUMMARY_DONE=1
    exit "$status"
}

if [ "${PERF_GATE_SOURCED:-0}" != "1" ]; then
    main "$@"
fi
