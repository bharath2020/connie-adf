#!/usr/bin/env bash
# Scripts/perf-gate.sh — fail-closed A/B/C performance gate for the ADFReader
# demo app on one iOS Simulator (docs: plan §6, docs/TextKit2-Stack.md §8.3).
# Measures preparation readiness (launch→READY, first chunk), autoscroll
# dropped frames / rate / hitch ratio, and memory (RSS + phys_footprint) for
# a candidate build against a reference build.
#
# USAGE
#   # per-PR gate (design pr45, ~40 min; kitchen-sink, stress-1k, giant-table
#   # × A/B/C × 3 pairs + 1 warm-up; no calibration):
#   Scripts/perf-gate.sh --udid <UDID> --app-a <main .app> --app-b <branch .app> \
#       --app-c <branch .app> --out <data>/perf/pr45-<sha>
#   # full gate (design full, ~8 h, once before the final parity PR):
#   Scripts/perf-gate.sh --calibrate --udid <UDID> --app-a <main .app> \
#       --out <data>/perf/calibration
#   Scripts/perf-gate.sh --design full --udid <UDID> --app-a <main .app> \
#       --app-b <branch .app> --app-c <branch .app> \
#       --calibration <data>/perf/calibration/calibration.json --out <data>/perf/full-<sha>
#
# A non-pilot run refuses to start with less than its design declares (arm B,
# a fixture, an arm of a fixture, pairs, the warm-up, the sampler, the
# candidate markers); the summarizer independently marks any reduced plan
# INCOMPLETE. A design names its fixtures and the arms each runs
# (perf_summarize.py DESIGNS); the plan records them as fixture_arms.
#
# OPTIONS
#   --udid <UDID>            required; the device must exist (never created).
#                            Booted if shut down, then settled (--settle) and
#                            shut down at the end (unless --keep-booted); a
#                            device that was already booted is left booted.
#                            Refuses to run if another simulator is booted.
#   --app-a / --app-b / --app-c <ADFReader.app>   (B and C required for a gate)
#   --design <pr45|full>     default pr45; fixtures, pairs and warm-ups default
#                            to the design (perf_summarize.py --print-design)
#   --calibrate              A vs A2 (both --app-a) for design full; writes
#                            calibration.json
#   --calibration <json>     frozen calibration (design full); its sha256 is
#                            recorded in plan.json before the first trial
#   --pilot                  pilot: any shape allowed, verdict never PASS;
#                            recorded in plan.json (the summarizer reads it)
#   --fixtures "<names>"     pilot only (a gate runs its design's fixtures)
#   --fixture-arms "f=A,B,C …"  pilot only: the arms per fixture (default:
#                            the design's for its fixtures, A,B,C otherwise;
#                            B dropped when there is no --app-b)
#   --runs <n>               counted pairs per (fixture, arm); a gate needs at
#                            least its design's count
#   --warmup <n>             discarded warm-ups per (fixture, arm); >= 1 unless
#                            --pilot
#   --settle <s>             idle seconds after booting the device, before the
#                            host check and the first trial; default 300 (the
#                            first trials after a boot stall); 0 when the
#                            device was already booted
#   --out <dir>              default $TMPDIR/adfreader-perf/<UTC stamp>
#   --arm-c-args "<flags>"   candidate renderer flags; default "-textkit2"
#   --candidate-args "<f>"   extra flags for the candidate binary (B and C);
#                            default "-rendererStats" (required unless --pilot)
#   --no-candidate-markers   pilot only: do not require SCROLL_METRICS
#                            completion fields or RENDERER_STATS from B/C
#   --extra-args "<flags>"   appended for every arm (e.g. "-fontSizeStep 3")
#   --expected-blocks "f=n …" READY block count each fixture must report
#   --trial-timeout <s>      fallback per-trial deadline; default 120
#   --trial-timeout-for "f=s …" per-fixture deadlines; defaults from the
#                            2026-10-26 pilot (1.5 × longest scroll + 30 s):
#                            kitchen-sink=45 stress-1k=180 stress-5k=775
#                            giant-table=95 text-dense=425 long-paragraph=45
#   --ready-timeout <s>      READY deadline; default 60
#   --rss-ms <ms> / --footprint-ms <ms>  sampler periods; default 200 / 1000
#   --no-sampler             pilot only: no memory sampling (sampler overhead)
#   --ledger <jsonl>         rerun ledger; default <out>/../perf-ledger.jsonl
#   --host-wait <s>          longest wait for a quiet host before running
#                            anyway as HOST-BUSY; default 1200 (20 min)
#   --host-poll <s>          seconds between host samples while waiting;
#                            default 30
#   --coverage "<text>"      coverage line for the summary table
#   --appearance <light|dark>  default light
#   --bundle-id <id>         default com.connie.adfreader
#   --keep-booted            never shut the device down
#   --dry-run                write plan.json and print the ordered trial list;
#                            no simulator or app is touched
#
# HOST  after the settle, `perf_trial.py host --top-samples 2` samples the
#   load averages and the three busiest processes every --host-poll seconds
#   until the host is quiet (1-min load <= 4.0, no non-simulator process
#   above 100 % CPU) or --host-wait has passed; then the run starts either
#   way. plan.json records the last sample (host_start) and the wait
#   (host_wait); every trial row records its start time, 1-min load and
#   busiest processes (`name=cpu`, `*` = simulator process). A run that was
#   not quiet at start or in any counted trial is HOST-BUSY: its PASS
#   counts; its FAIL is reported as FAIL-HOST-BUSY (exit 6) and is re-run
#   once at the next quiet window. Nothing is ever killed or reniced.
#
# ARMS
#   A   reference (--app-a), launched without the candidate flags
#   C   candidate (--app-c) with --arm-c-args + --candidate-args
#   B   candidate binary (--app-b) with -rendererReset + --candidate-args —
#       the shipping path with the switch OFF (font-spec baking, switch
#       plumbing)
#   A2  (calibration) the reference again, identical argv
#   Balanced order per run: odd runs A,C,B / even runs B,C,A (every A–C and
#   A–B pair alternates), filtered to the fixture's arms; calibration
#   alternates A,A2 / A2,A.
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
#   plan.json      declared design/fixtures/runs/arms/shas/flags/timeouts/
#                  calibration/host_start
#   trials.csv     counted trials (columns: Scripts/perf_trial.py CSV_COLUMNS)
#   warmup.csv     discarded warm-ups
#   env.txt        host, Xcode, device, apps
#   logs/<stem>.log      stamped app output (#T0, lines, #EXIT)
#   samples/<stem>.tsv   memory samples with their own timestamps
#   summary.md/.json (gate) or calibration.json/.md (calibration)
#
# EXIT  the summarizer's status: 0 PASS/CALIBRATED, 1 FAIL, 2 INVALID or
#       REFUSED, 3 INCONCLUSIVE, 4 PILOT, 5 INCOMPLETE, 6 FAIL-HOST-BUSY
#       (re-run once when the host is quiet); 2 also for usage errors and
#       driver failures.
#
# bash 3.2 compatible (macOS /bin/bash); needs python3 (-I), xcrun.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRIAL_PY="$SCRIPT_DIR/perf_trial.py"
SUMMARIZE_PY="$SCRIPT_DIR/perf_summarize.py"
# shellcheck source=lib/sim.sh
. "$SCRIPT_DIR/lib/sim.sh"

# ---------------------------------------------------------------- defaults
UDID=""
APP_A=""; APP_B=""; APP_C=""
LABEL_A="main"; LABEL_B="branch (switch OFF)"; LABEL_C="branch (TextKit 2)"
MODE="gate"
DESIGN=""
CALIBRATION=""
PILOT=0
FIXTURES=""
RUNS=""
WARMUP=""
SETTLE=""
OUT=""
ARM_C_ARGS="-textkit2"
CANDIDATE_ARGS="-rendererStats"
CANDIDATE_MARKERS=1
EXTRA_ARGS=""
EXPECTED_BLOCKS=""
TRIAL_TIMEOUT=120
DEFAULT_TIMEOUTS="kitchen-sink=45 stress-1k=180 stress-5k=775 giant-table=95 text-dense=425 long-paragraph=45"
TIMEOUTS_FOR=""
READY_TIMEOUT=60
RSS_MS=200
FOOTPRINT_MS=1000
SAMPLER=1
LEDGER=""
FIXTURE_ARMS=""
HOST_WAIT=""
HOST_POLL=""
HOST_START_JSON=""
HOST_WAIT_JSON=""
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

BOOTED_BY_US=0
ensure_booted() {
    local state others
    others=$(sim_other_booted "$UDID")
    [ -z "$others" ] || die "another simulator is booted ($others); one device at a time"
    state=$(sim_device_field "$UDID" state)
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
        B) echo "-rendererReset $CANDIDATE_ARGS" ;;
        C) echo "$ARM_C_ARGS $CANDIDATE_ARGS" ;;
    esac
}
arm_requires_completion() {
    case "$1" in B|C) [ "$CANDIDATE_MARKERS" -eq 1 ] && echo 1 || echo 0 ;; *) echo 0 ;; esac
}

# fixture_arms_of <fixture> -> its arms ("A B C"), from FIXTURE_ARMS
fixture_arms_of() {
    lookup "$1" "$FIXTURE_ARMS" | tr ',' ' '
}

# Arm order for run <n> on <fixture>: balanced pairs over the fixture's arms.
arm_order() {
    local run="$1" fixture="$2" order arm out=""
    if [ "$MODE" = "calibrate" ]; then
        if [ $(( run % 2 )) -eq 1 ]; then echo "A A2"; else echo "A2 A"; fi
        return 0
    fi
    if [ $(( run % 2 )) -eq 1 ]; then order="A C B"; else order="B C A"; fi
    for arm in $order; do
        case " $(fixture_arms_of "$fixture") " in *" $arm "*) out="$out $arm" ;; esac
    done
    echo "${out# }"
}

# all_arms -> the arms any fixture runs, in plan order
all_arms() {
    local arm f out=""
    for arm in A A2 C B; do
        for f in $FIXTURES; do
            case " $(fixture_arms_of "$f") " in *" $arm "*) out="$out $arm"; break ;; esac
        done
    done
    echo "${out# }"
}

write_plan() {
    local arms
    arms=$(all_arms)
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
    P_DESIGN="$DESIGN" P_HOST="$HOST_START_JSON" P_SETTLE="$SETTLE" P_FIXTURE_ARMS="$FIXTURE_ARMS" \
    P_HOST_WAIT="$HOST_WAIT_JSON" P_BOUNDS_SHA="$BOUNDS_SHA" P_BOUND_GATED="$BOUND_GATED" \
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
    "version": 3, "mode": mode, "design": env["P_DESIGN"], "pilot": env["P_PILOT"] == "1",
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
    "settle_s": int(env["P_SETTLE"] or 0),
    "host_start": json.loads(env["P_HOST"]) if env["P_HOST"] else None,
    "host_wait": json.loads(env["P_HOST_WAIT"]) if env["P_HOST_WAIT"] else None,
    "fixture_arms": {p.split("=")[0]: [a for a in p.split("=")[1].split(",") if a in arms]
                     for p in env["P_FIXTURE_ARMS"].split()},
}
if mode != "calibrate":
    plan["bounds_sha256"] = env["P_BOUNDS_SHA"] or None
    plan["bound_gated"] = json.loads(env["P_BOUND_GATED"]) if env["P_BOUND_GATED"] else None
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

    local started load1 top3
    started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    load1=$(sysctl -n vm.loadavg | awk '{print $2}')
    top3=$(python3 -I "$TRIAL_PY" host --top-samples 2 | python3 -I -c '
import json, os, sys
print(";".join("%s=%g%s" % (os.path.basename(p["command"]), p["cpu"], "*" if p.get("simulator") else "")
               for p in json.load(sys.stdin)["top"]))')

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
        --meta "trial_timeout_s=$deadline" --meta "shell_status=$shell_status" \
        --meta "started_utc=$started" --meta "host_load1=$load1" --meta "host_top3=$top3")
    log "$stem: $digest"
}

# host_busy_reasons <host json> -> why the sample is not quiet ("" = quiet)
host_busy_reasons() {
    printf '%s' "$1" | python3 -I -c '
import json, os, sys
h = json.load(sys.stdin)
load_max, cpu_max = float(sys.argv[1]), float(sys.argv[2])
load = h.get("load1")
why = []
if load is None or load > load_max:
    why.append("1-min load %s > %g" % (load, load_max))
for p in h.get("top", []):
    if p["cpu"] > cpu_max and not p.get("simulator"):
        why.append("%s at %g %% CPU" % (os.path.basename(p["command"]), p["cpu"]))
print("; ".join(why))' "$HOST_LOAD_MAX" "$HOST_CPU_MAX"
}

# host_wait: sample the host until it is quiet or --host-wait has passed,
# then go ahead either way (HOST). Records HOST_START_JSON (last sample) and
# HOST_WAIT_JSON. Nothing is killed or reniced.
host_wait() {
    local start=$SECONDS polls=0 why="" waited remaining nap
    while :; do
        HOST_START_JSON=$(python3 -I "$TRIAL_PY" host --top-samples 2)
        polls=$(( polls + 1 ))
        why=$(host_busy_reasons "$HOST_START_JSON")
        waited=$(( SECONDS - start ))
        [ -n "$why" ] || break
        remaining=$(( HOST_WAIT - waited ))
        [ "$remaining" -gt 0 ] || break
        nap=$HOST_POLL; [ "$nap" -le "$remaining" ] || nap=$remaining
        log "host not quiet ($why); waiting ${waited}s of ${HOST_WAIT}s, next sample in ${nap}s"
        sleep "$nap"
    done
    printf '%s\n' "$HOST_START_JSON" > "$OUT/host-start.json"
    HOST_WAIT_JSON=$(python3 -I -c '
import json, sys
limit, poll, waited, polls, why = sys.argv[1:6]
print(json.dumps({"limit_s": int(limit), "poll_s": int(poll), "waited_s": int(waited), "polls": int(polls),
                  "quiet": not why, "reasons": why}))' "$HOST_WAIT" "$HOST_POLL" "$waited" "$polls" "$why")
    if [ -n "$why" ]; then
        log "HOST-BUSY: not quiet after ${waited}s ($why); running anyway. A PASS counts; a FAIL is reported as FAIL-HOST-BUSY and re-run once when the host is quiet (details: $OUT/host-start.json)"
    else
        log "host quiet after ${waited}s (${polls} sample(s)): $(printf '%s' "$HOST_START_JSON" | cut -c1-160)"
    fi
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
            --design) DESIGN="$2"; shift 2 ;;
            --calibrate) MODE="calibrate"; shift ;;
            --calibration) CALIBRATION="$2"; shift 2 ;;
            --pilot) PILOT=1; shift ;;
            --fixtures) FIXTURES="$2"; shift 2 ;;
            --fixture-arms) FIXTURE_ARMS="$2"; shift 2 ;;
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
            --settle) SETTLE="$2"; shift 2 ;;
            --ledger) LEDGER="$2"; shift 2 ;;
            --host-wait) HOST_WAIT="$2"; shift 2 ;;
            --host-poll) HOST_POLL="$2"; shift 2 ;;
            --coverage) COVERAGE="$2"; shift 2 ;;
            --appearance) APPEARANCE="$2"; shift 2 ;;
            --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
            --keep-booted) KEEP_BOOTED=1; shift ;;
            --dry-run) DRY_RUN=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "unknown option: $1 (see --help)" ;;
        esac
    done
    command -v python3 >/dev/null || die "python3 not found"
    [ -f "$TRIAL_PY" ] || die "missing $TRIAL_PY"
    [ -n "$UDID" ] || die "--udid is required"
    [ -n "$APP_A" ] || die "--app-a <ADFReader.app> is required"
    [ "$DRY_RUN" -eq 1 ] || [ -d "$APP_A" ] || die "--app-a: not a directory: $APP_A"

    # The design declares the shape; a non-pilot run may not declare less.
    if [ "$MODE" = "calibrate" ]; then
        [ -z "$DESIGN" ] || [ "$DESIGN" = "full" ] || die "--calibrate belongs to design full (pr45 has no calibration)"
        DESIGN="full"
    fi
    [ -n "$DESIGN" ] || DESIGN="pr45"
    local shape d_fixtures d_fixture_arms d_runs d_warmup
    shape=$(python3 -I "$SUMMARIZE_PY" --print-design "$DESIGN") || die "unknown --design $DESIGN"
    d_fixtures=$(printf '%s\n' "$shape" | sed -n 's/^fixtures=//p')
    d_fixture_arms=$(printf '%s\n' "$shape" | sed -n 's/^fixture_arms=//p')
    d_runs=$(printf '%s\n' "$shape" | sed -n 's/^runs=//p')
    d_warmup=$(printf '%s\n' "$shape" | sed -n 's/^warmup=//p')
    BOUNDS_SHA=$(printf '%s\n' "$shape" | sed -n 's/^bounds_sha256=//p')
    BOUND_GATED=$(printf '%s\n' "$shape" | sed -n 's/^bound_gated=//p')
    HOST_LOAD_MAX=$(printf '%s\n' "$shape" | sed -n 's/^host_quiet_load_max=//p')
    HOST_CPU_MAX=$(printf '%s\n' "$shape" | sed -n 's/^host_process_cpu_max=//p')
    [ -n "$HOST_WAIT" ] || HOST_WAIT=$(printf '%s\n' "$shape" | sed -n 's/^host_wait_s=//p')
    [ -n "$HOST_POLL" ] || HOST_POLL=$(printf '%s\n' "$shape" | sed -n 's/^host_poll_s=//p')
    case "$HOST_WAIT" in ''|*[!0-9]*) die "--host-wait must be seconds" ;; esac
    case "$HOST_POLL" in ''|*[!0-9]*) die "--host-poll must be seconds" ;; esac
    [ "$HOST_POLL" -ge 1 ] || die "--host-poll must be >= 1"
    [ -n "$FIXTURES" ] || FIXTURES="$d_fixtures"
    [ -n "$RUNS" ] || RUNS="$d_runs"
    [ -n "$WARMUP" ] || WARMUP="$d_warmup"
    case "$RUNS" in ''|*[!0-9]*) die "--runs must be a positive integer" ;; esac
    case "$WARMUP" in ''|*[!0-9]*) die "--warmup must be a non-negative integer" ;; esac
    [ "$RUNS" -ge 1 ] || die "--runs must be >= 1"
    if [ "$PILOT" -eq 0 ]; then
        [ "$FIXTURES" = "$d_fixtures" ] || die "--fixtures: design $DESIGN runs exactly \"$d_fixtures\" (other sets: --pilot)"
        [ -z "$FIXTURE_ARMS" ] || [ "$FIXTURE_ARMS" = "$d_fixture_arms" ] || \
            die "--fixture-arms: design $DESIGN runs exactly \"$d_fixture_arms\" (other shapes: --pilot)"
        [ "$RUNS" -ge "$d_runs" ] || die "--runs $RUNS: design $DESIGN needs >= $d_runs pairs (fewer: --pilot)"
        [ "$WARMUP" -ge 1 ] || die "--warmup $WARMUP: one discarded warm-up per fixture and arm is required (0: --pilot)"
        [ "$SAMPLER" -eq 1 ] || die "--no-sampler is pilot-only (a gate measures memory)"
        [ "$CANDIDATE_MARKERS" -eq 1 ] || die "--no-candidate-markers is pilot-only (a gate proves completion and renderer)"
        case " $CANDIDATE_ARGS " in *" -rendererStats "*) ;; *) die "--candidate-args must keep -rendererStats (renderer proof) unless --pilot" ;; esac
    fi

    if [ "$MODE" = "calibrate" ]; then
        [ -z "$APP_B$APP_C" ] || die "--calibrate uses --app-a only (as A and A2)"
        [ -z "$CALIBRATION" ] || die "--calibrate and --calibration are exclusive"
    else
        [ -n "$APP_C" ] || die "--app-c <ADFReader.app> is required (or --calibrate)"
        [ "$DRY_RUN" -eq 1 ] || [ -d "$APP_C" ] || die "--app-c: not a directory: $APP_C"
        if [ -z "$APP_B" ]; then
            [ "$PILOT" -eq 1 ] || die "--app-b <ADFReader.app> is required: B (switch OFF) is gated (omit only with --pilot)"
        elif [ "$DRY_RUN" -eq 0 ]; then
            [ -d "$APP_B" ] || die "--app-b: not a directory: $APP_B"
        fi
        if [ "$DESIGN" = "full" ]; then
            if [ -z "$CALIBRATION" ] && [ "$PILOT" -eq 0 ]; then
                die "--calibration <calibration.json> is required for design full (run --calibrate first)"
            fi
        else
            [ -z "$CALIBRATION" ] || die "design $DESIGN takes no --calibration"
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
    if [ -n "$SETTLE" ]; then
        case "$SETTLE" in *[!0-9]*) die "--settle must be seconds" ;; esac
    fi

    # The arms each fixture runs (fixture_arms in the plan).
    local f fa pairs=""
    for f in $FIXTURES; do
        if [ "$MODE" = "calibrate" ]; then
            fa="A,A2"
        else
            fa=$(lookup "$f" "${FIXTURE_ARMS:-$d_fixture_arms}")
            [ -n "$fa" ] || fa="A,B,C"
            [ -n "$APP_B" ] || fa=$(printf '%s' "$fa" | tr ',' '\n' | grep -vx B | paste -sd, -)
            case ",$fa," in *,A,*) ;; *) die "--fixture-arms: $f must run the reference arm A" ;; esac
        fi
        pairs="$pairs $f=$fa"
    done
    FIXTURE_ARMS="${pairs# }"

    if [ -z "$OUT" ]; then
        OUT="${TMPDIR:-/tmp}"
        OUT="${OUT%/}/adfreader-perf/$(date -u +%Y%m%dT%H%M%SZ)"
    fi
    mkdir -p "$OUT/logs" "$OUT/samples"
    OUT=$(cd "$OUT" && pwd)
    if [ "$DRY_RUN" -eq 0 ] && [ -s "$OUT/trials.csv" ]; then
        die "$OUT/trials.csv already exists; use a fresh --out (runs are never appended)"
    fi
    [ -n "$LEDGER" ] || LEDGER="$(dirname "$OUT")/perf-ledger.jsonl"

    APP_EXE=$(app_executable "$APP_A")
    SHA_A=$(sha256_of_app "$APP_A"); SHA_B=""; SHA_C=""
    [ -z "$APP_C" ] || SHA_C=$(sha256_of_app "$APP_C")
    [ -z "$APP_B" ] || SHA_B=$(sha256_of_app "$APP_B")
    if [ "$MODE" = "gate" ] && [ "$SHA_A" = "$SHA_C" ]; then
        log "WARNING: app-a and app-c have the same binary sha256"
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        HOST_START_JSON=$(python3 -I "$TRIAL_PY" host --top-samples 2)
        HOST_WAIT_JSON='{"dry_run": true}'
        write_plan
        log "dry run: plan $OUT/plan.json (host sampled once, no wait)"
        cat "$OUT/plan.json"
    else
        log "output: $OUT"
        trap cleanup EXIT INT TERM
        ensure_booted
        DEVICE_READY=1
        if [ -z "$SETTLE" ]; then
            if [ "$BOOTED_BY_US" -eq 1 ]; then SETTLE=300; else SETTLE=0; fi
        fi
        if [ "$SETTLE" -gt 0 ]; then
            log "settling ${SETTLE}s after boot before the host check and the first trial"
            sleep "$SETTLE"
        fi
        host_wait
        write_plan
        {
            echo "date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            echo "host=$(hostname) $(sw_vers -productVersion 2>/dev/null || true) $(uname -m)"
            echo "xcodebuild=$(xcodebuild -version 2>/dev/null | tr '\n' ' ')"
            echo "udid=$UDID device=$(sim_device_field "$UDID" name) runtime=$(sim_device_field "$UDID" runtime)"
            echo "mode=$MODE design=$DESIGN pilot=$PILOT fixtures=$FIXTURES runs=$RUNS warmup=$WARMUP settle=$SETTLE"
            echo "fixture_arms=$FIXTURE_ARMS bounds_sha256=$BOUNDS_SHA bound_gated=$BOUND_GATED"
            echo "host_wait=$HOST_WAIT_JSON"
            echo "sampler=$SAMPLER rss_ms=$RSS_MS footprint_ms=$FOOTPRINT_MS"
            echo "host_start=$HOST_START_JSON"
            echo "A app=$APP_A sha256=$SHA_A"
            [ -z "$APP_C" ] || echo "C app=$APP_C sha256=$SHA_C"
            [ -z "$APP_B" ] || echo "B app=$APP_B sha256=$SHA_B"
            [ -z "$CALIBRATION" ] || echo "calibration=$CALIBRATION"
        } > "$OUT/env.txt"
    fi

    local trials="$OUT/trials.csv" warm="$OUT/warmup.csv" w fixture run arm i
    w=1
    while [ "$w" -le "$WARMUP" ]; do
        for fixture in $FIXTURES; do
            [ "$DRY_RUN" -eq 1 ] || log "warm-up $w/$WARMUP fixture=$fixture"
            i=0
            for arm in $(arm_order "$w" "$fixture"); do
                i=$(( i + 1 )); run_trial 0 "$fixture" "$arm" "$warm" "$i"
            done
        done
        w=$(( w + 1 ))
    done
    run=1
    while [ "$run" -le "$RUNS" ]; do
        for fixture in $FIXTURES; do
            [ "$DRY_RUN" -eq 1 ] || log "run $run/$RUNS fixture=$fixture order: $(arm_order "$run" "$fixture")"
            i=0
            for arm in $(arm_order "$run" "$fixture"); do
                i=$(( i + 1 )); run_trial "$run" "$fixture" "$arm" "$trials" "$i"
            done
        done
        run=$(( run + 1 ))
    done
    [ "$DRY_RUN" -eq 0 ] || exit 0

    log "trials done: $trials"
    local -a summary_args=("$trials" --plan "$OUT/plan.json" --quiet)
    [ "$PILOT" -eq 0 ] || summary_args+=(--pilot)
    summary_args+=(--ledger "$LEDGER")
    if [ "$MODE" = "calibrate" ]; then
        summary_args+=(--calibrate --write-calibration "$OUT/calibration.json")
    else
        summary_args+=(--json "$OUT/summary.json")
        [ -z "$CALIBRATION" ] || summary_args+=(--calibration "$CALIBRATION")
        [ -z "$COVERAGE" ] || summary_args+=(--coverage "$COVERAGE")
    fi
    local status=0
    python3 -I "$SUMMARIZE_PY" "${summary_args[@]}" || status=$?
    log "summary exit status $status (0 PASS/CALIBRATED, 1 FAIL, 2 INVALID/REFUSED, 3 INCONCLUSIVE, 4 PILOT, 5 INCOMPLETE, 6 FAIL-HOST-BUSY)"
    SUMMARY_DONE=1
    exit "$status"
}

if [ "${PERF_GATE_SOURCED:-0}" != "1" ]; then
    main "$@"
fi
