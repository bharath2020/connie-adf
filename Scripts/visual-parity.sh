#!/usr/bin/env bash
# Scripts/visual-parity.sh — document-level visual gate: captures screenshots
# of a reference ADFReader build (a Release build of main) and of this
# branch's build on ONE iOS Simulator, then scores them with
# Scripts/visual_diff.py (content viewport only; chrome masked).
#
# USAGE
#   Scripts/visual-parity.sh --udid <UDID> --ref-app <main ADFReader.app>
#       --app <branch ADFReader.app> [--out <dir>]
#       [--fixture <name>[@<f1>,<f2>...]]... [--appearances "light dark"]
#       [--size-steps "0 3"] [--arms "A A2 B C"] [--content-size large]
#       [--settle 3] [--scroll-wait 2] [--ready-timeout 90]
#       [--mask x0,y0,x1,y1]... [--top-band 330] [--bottom-band 102]
#       [--exact-mask x0,y0,x1,y1]... [--no-exact-mask]
#       [--threshold 24] [--max-noise-pct 0] [--max-exact-pct 0]
#       [--max-raw-pct 0.5] [--max-crop-pct 0.5] [--max-offset-px 0]
#       [--no-renderer-stats] [--keep-booted] [--skip-capture] [--dry-run]
#
# ARMS (per fixture × position × appearance × size step)
#   A   --ref-app, plain launch                          (reference)
#   A2  --ref-app again, same procedure                  (capture noise)
#   B   --app with -rendererReset                        (SwiftUI text)
#   C   --app with -rendererReset -textkit2              (TextKit 2 text)
#   B and C also get -rendererStats and must print `RENDERER_STATS
#   renderer=swiftui|textkit2 …` matching the arm (proof of which renderer
#   ran; --no-renderer-stats drops the flag and the check).
#   Every arm gets `-fixture <f> -scrollToFraction <pos> -fontSizeStep <n>`.
#
# PAIRS SCORED (Scripts/visual_diff.py kinds)
#   <cfg>-AA  noise     A vs A2: viewport % must be <= --max-noise-pct (0)
#   <cfg>-AB  exact     A vs B:  viewport % must be <= --max-exact-pct (0)
#   <cfg>-AC  tolerant  A vs C:  viewport <= --max-raw-pct (0.5) AND every
#                       text-block crop <= --max-crop-pct (0.5) with vertical
#                       offset <= --max-offset-px (0)
#   <cfg> = <fixture>-p<position>-<appearance>-s<step>
#
# CAPTURE PROCEDURE (identical for every arm)
#   terminate + uninstall + install the arm's .app (no persisted renderer key
#   or text size leaks), verify the installed binary sha256 equals the .app's,
#   pin the status bar (9:41, charged, full bars), `simctl ui appearance`,
#   `simctl ui content_size` (--content-size, default large), launch
#   `simctl launch --console-pty` logged to captures/<cfg>-<arm>.log, wait
#   for `READY fixture=<f> `, then wait --scroll-wait (default 2 s: the app
#   starts the -scrollToFraction jump 300 ms after READY with a .snappy
#   animation and re-jumps without animation ~1.5 s after READY, which makes
#   the landing exact — the animated one alone varied by up to 26 px between
#   launches of one build; applied at position 0 too so every capture has
#   the same timeline) plus --settle (default 3 s), `simctl io screenshot`,
#   terminate. A reference built from a commit that predates the re-jump
#   needs it patched into Demo/ADFReader/ReaderView.swift, or arm A lands
#   nondeterministically.
#
# DEFAULTS
#   fixtures   kitchen-sink@0,0.5 (H1, every-mark paragraph, centered and
#              indented text, H2–H6; then later blocks) and stress-5k@0,0.5
#   masks      --top-band 330 (status bar + inline nav bar/toolbar, where the
#              renderer label lives) and --bottom-band 102 (home indicator),
#              in pixels of an iPhone 17 Pro screenshot (1206x2622, 3x). When
#              no band/mask flag is given and a screenshot has another size,
#              the run stops: pass masks for that device explicitly.
#              Noise/exact pairs also mask --exact-mask 0,330,1206,460: the
#              soft shadows the toolbar's glass capsules cast below the band,
#              plus the scroll-edge effect over scrolled content. They follow
#              the capsules' widths, which follow the renderer label (main
#              has none): measured A–B |Δ| <= 7 over rows 330–436 at p0 and
#              <= 14 over rows 330–450, cols 314–1198 at p0.5 (A–A' 0).
#              Tolerant pairs (threshold 24) still score these rows.
#              --exact-mask replaces that default; --no-exact-mask drops it.
#   --out      $TMPDIR/adfreader-parity/<timestamp>
#
# OUTPUTS (<out>/)
#   captures/<cfg>-<arm>.png|.log   screenshots + launch logs
#   manifest.tsv     one row per capture: arm, fixture, position, appearance,
#                    size step, content size, app path + sha256, installed
#                    sha256, argv, device, runtime, locale, READY and
#                    RENDERER_STATS lines, png sha256, time
#   env.txt          host, Xcode, device, settings, git head of this checkout
#   scores.csv, scores.json, summary.md, *.sbs.png, crops/   (visual_diff.py)
#
# DEVICE  --udid is required for capture. The script never creates a
#   simulator, refuses to run while a different device is booted, and shuts
#   down only a device it booted itself (never with --keep-booted). It
#   restores the device's appearance and content size, and clears the status
#   bar override, on exit.
#   --skip-capture re-scores existing captures in --out (no simulator).
#   --dry-run prints the capture plan and the visual_diff invocation and
#   touches no simulator.
#
# EXIT STATUS  0 all pairs PASS; 1 a capture failed or any pair (including a
#   noise pair) FAILed; 2 usage/input error.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sim.sh
. "$SCRIPT_DIR/lib/sim.sh"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLE_ID="com.connie.adfreader"
EXPECTED_SIZE="1206x2622"

UDID=""
REF_APP=""
APP=""
OUT=""
FIXTURE_SPECS=()
APPEARANCES="light dark"
SIZE_STEPS="0 3"
ARMS="A A2 B C"
CONTENT_SIZE="large"
SETTLE_SECONDS=3
SCROLL_WAIT_SECONDS=2
READY_TIMEOUT=90
MASKS=()
TOP_BAND=330
BOTTOM_BAND=102
MASKS_EXPLICIT=0
EXACT_MASKS=("0,330,1206,460")
EXACT_MASKS_DEFAULT=1
THRESHOLD=24
MAX_NOISE_PCT=0
MAX_EXACT_PCT=0
MAX_RAW_PCT=0.5
MAX_CROP_PCT=0.5
MAX_OFFSET_PX=0
RENDERER_STATS=1
KEEP_BOOTED=0
SKIP_CAPTURE=0
DRY_RUN=0

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }
log() { printf '[visual-parity] %s\n' "$*" >&2; }
die() { log "error: $*"; exit 2; }

need_value() { [[ $# -ge 2 && -n "$2" ]] || die "$1 needs a value"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --udid) need_value "$@"; UDID="$2"; shift 2 ;;
        --ref-app) need_value "$@"; REF_APP="$2"; shift 2 ;;
        --app) need_value "$@"; APP="$2"; shift 2 ;;
        --out) need_value "$@"; OUT="$2"; shift 2 ;;
        --fixture) need_value "$@"; FIXTURE_SPECS+=("$2"); shift 2 ;;
        --appearances) need_value "$@"; APPEARANCES="$2"; shift 2 ;;
        --size-steps) need_value "$@"; SIZE_STEPS="$2"; shift 2 ;;
        --arms) need_value "$@"; ARMS="$2"; shift 2 ;;
        --content-size) need_value "$@"; CONTENT_SIZE="$2"; shift 2 ;;
        --settle) need_value "$@"; SETTLE_SECONDS="$2"; shift 2 ;;
        --scroll-wait) need_value "$@"; SCROLL_WAIT_SECONDS="$2"; shift 2 ;;
        --ready-timeout) need_value "$@"; READY_TIMEOUT="$2"; shift 2 ;;
        --mask) need_value "$@"; MASKS+=("$2"); MASKS_EXPLICIT=1; shift 2 ;;
        --top-band) need_value "$@"; TOP_BAND="$2"; MASKS_EXPLICIT=1; shift 2 ;;
        --bottom-band) need_value "$@"; BOTTOM_BAND="$2"; MASKS_EXPLICIT=1; shift 2 ;;
        --exact-mask) need_value "$@"
            [[ $EXACT_MASKS_DEFAULT -eq 1 ]] && EXACT_MASKS=()
            EXACT_MASKS+=("$2"); EXACT_MASKS_DEFAULT=0; MASKS_EXPLICIT=1; shift 2 ;;
        --no-exact-mask) EXACT_MASKS=(); EXACT_MASKS_DEFAULT=0; MASKS_EXPLICIT=1; shift ;;
        --threshold) need_value "$@"; THRESHOLD="$2"; shift 2 ;;
        --max-noise-pct) need_value "$@"; MAX_NOISE_PCT="$2"; shift 2 ;;
        --max-exact-pct) need_value "$@"; MAX_EXACT_PCT="$2"; shift 2 ;;
        --max-raw-pct) need_value "$@"; MAX_RAW_PCT="$2"; shift 2 ;;
        --max-crop-pct) need_value "$@"; MAX_CROP_PCT="$2"; shift 2 ;;
        --max-offset-px) need_value "$@"; MAX_OFFSET_PX="$2"; shift 2 ;;
        --no-renderer-stats) RENDERER_STATS=0; shift ;;
        --keep-booted) KEEP_BOOTED=1; shift ;;
        --skip-capture) SKIP_CAPTURE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
done

[[ ${#FIXTURE_SPECS[@]} -gt 0 ]] || FIXTURE_SPECS=("kitchen-sink@0,0.5" "stress-5k@0,0.5")
for arm in $ARMS; do
    case "$arm" in A|A2|B|C) ;; *) die "--arms: unknown arm '$arm' (A A2 B C)" ;; esac
done
case " $ARMS " in *" A "*) ;; *) die "--arms must include A (the reference)" ;; esac
for number in "$SETTLE_SECONDS" "$SCROLL_WAIT_SECONDS" "$READY_TIMEOUT"; do
    [[ "$number" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "not a number of seconds: $number"
done

TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}/adfreader-parity"
[[ -n "$OUT" ]] || OUT="$TMP_BASE/$(date +%Y%m%d-%H%M%S)"
CAPTURES="$OUT/captures"
MANIFEST="$OUT/manifest.tsv"

if [[ $SKIP_CAPTURE -eq 0 ]]; then
    [[ -n "$UDID" ]] || die "--udid is required (the script never picks or creates a simulator)"
    if [[ $DRY_RUN -eq 0 ]]; then
        [[ -n "$REF_APP" && -x "$REF_APP/ADFReader" ]] || die "--ref-app must be an ADFReader.app (got '${REF_APP:-}')"
        [[ -n "$APP" && -x "$APP/ADFReader" ]] || die "--app must be an ADFReader.app (got '${APP:-}')"
    fi
fi

# ------------------------------------------------------------------ plan -----

# Fills POSITIONS with "<fixture>\t<position>" per capture position of every
# --fixture spec (in the main shell, so a bad spec stops the run).
POSITIONS=()
for spec in "${FIXTURE_SPECS[@]}"; do
    name="${spec%%@*}"
    positions="0"
    [[ "$spec" == *@* ]] && positions="${spec#*@}"
    [[ -n "$name" ]] || die "--fixture '$spec': empty name"
    for pos in ${positions//,/ }; do
        [[ "$pos" =~ ^(0|1|0?[.][0-9]+|1[.]0*)$ ]] || die "--fixture '$spec': position '$pos' not in [0, 1]"
        POSITIONS+=("$name"$'\t'"$pos")
    done
done

# arm_args <arm> <fixture> <position> <step>: one argv word per line.
arm_args() {
    local arm="$1" fixture="$2" pos="$3" step="$4"
    printf '%s\n' -fixture "$fixture" -scrollToFraction "$pos" -fontSizeStep "$step"
    case "$arm" in
        B|C)
            printf '%s\n' -rendererReset
            [[ $RENDERER_STATS -eq 0 ]] || printf '%s\n' -rendererStats
            [[ "$arm" != "C" ]] || printf '%s\n' -textkit2
            ;;
    esac
}

arm_app() { case "$1" in A|A2) echo "$REF_APP" ;; *) echo "$APP" ;; esac; }
expected_renderer() { case "$1" in B) echo swiftui ;; C) echo textkit2 ;; *) echo "" ;; esac; }
has_arm() { case " $ARMS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

PLAN=()   # entries: "<cfg>\t<fixture>\t<position>\t<appearance>\t<step>"
for fixture_pos in "${POSITIONS[@]}"; do
    IFS=$'\t' read -r fixture pos <<<"$fixture_pos"
    for appearance in $APPEARANCES; do
        for step in $SIZE_STEPS; do
            [[ "$step" =~ ^-?[0-9]+$ ]] || die "--size-steps: '$step' is not an integer"
            PLAN+=("$fixture-p$pos-$appearance-s$step"$'\t'"$fixture"$'\t'"$pos"$'\t'"$appearance"$'\t'"$step")
        done
    done
done
[[ ${#PLAN[@]} -gt 0 ]] || die "empty capture plan (check --appearances / --size-steps)"

DIFF_ARGS=(--top-band "$TOP_BAND" --bottom-band "$BOTTOM_BAND" --threshold "$THRESHOLD"
    --max-noise-pct "$MAX_NOISE_PCT" --max-exact-pct "$MAX_EXACT_PCT"
    --max-raw-pct "$MAX_RAW_PCT" --max-crop-pct "$MAX_CROP_PCT" --max-offset-px "$MAX_OFFSET_PX")
for mask in ${MASKS[@]+"${MASKS[@]}"}; do DIFF_ARGS+=(--mask "$mask"); done
for mask in ${EXACT_MASKS[@]+"${EXACT_MASKS[@]}"}; do DIFF_ARGS+=(--exact-mask "$mask"); done

# pair_args <require-files:0|1>: the --pair arguments for every configuration.
PAIR_ARGS=()
build_pairs() {
    local require="$1" entry cfg a
    PAIR_ARGS=()
    for entry in "${PLAN[@]}"; do
        cfg="${entry%%$'\t'*}"
        a="$CAPTURES/$cfg-A.png"
        add_pair() {   # <kind> <suffix> <arm>
            local cand="$CAPTURES/$cfg-$3.png"
            if [[ $require -eq 0 ]] || [[ -f "$a" && -f "$cand" ]]; then
                PAIR_ARGS+=(--pair "$1" "$cfg-$2" "$a" "$cand")
            fi
        }
        if has_arm A2; then add_pair noise AA A2; fi
        if has_arm B; then add_pair exact AB B; fi
        if has_arm C; then add_pair tolerant AC C; fi
    done
}

if [[ $DRY_RUN -eq 1 ]]; then
    echo "visual-parity dry run (no simulator is touched)"
    echo "device:       ${UDID:-(none: --skip-capture)}"
    echo "out:          $OUT"
    echo "ref app (A):  ${REF_APP:-(unset)}"
    echo "app (B, C):   ${APP:-(unset)}"
    echo "settings:     content_size=$CONTENT_SIZE settle=${SETTLE_SECONDS}s scroll_wait=${SCROLL_WAIT_SECONDS}s ready_timeout=${READY_TIMEOUT}s renderer_stats=$RENDERER_STATS"
    echo "captures:     ${#PLAN[@]} configurations x arms ($ARMS)"
    if [[ $SKIP_CAPTURE -eq 0 ]]; then
        for entry in "${PLAN[@]}"; do
            IFS=$'\t' read -r cfg fixture pos appearance step <<<"$entry"
            for arm in $ARMS; do
                args="$(arm_args "$arm" "$fixture" "$pos" "$step" | tr '\n' ' ')"
                echo "  $cfg-$arm  appearance=$appearance  app=$(arm_app "$arm")"
                echo "      xcrun simctl launch --console-pty $UDID $BUNDLE_ID ${args% }"
            done
        done
    fi
    build_pairs 0
    echo "score:"
    printf '  python3 -I %q --out %q' "$SCRIPT_DIR/visual_diff.py" "$OUT"
    printf ' %q' "${DIFF_ARGS[@]}" "${PAIR_ARGS[@]}"
    echo
    exit 0
fi

mkdir -p "$CAPTURES"

# ---------------------------------------------------------------- simulator --

BOOTED_BY_US=0
DEVICE_READY=0
ORIG_APPEARANCE=""
ORIG_CONTENT_SIZE=""
LAUNCH_PID=""

prepare_device() {
    local record state other
    record="$(sim_device_record "$UDID")"
    [[ -n "$record" ]] || die "no simulator with udid $UDID (the script never creates devices)"
    IFS=$'\t' read -r state DEVICE_NAME DEVICE_RUNTIME <<<"$record"
    log "device: $DEVICE_NAME ($UDID) $DEVICE_RUNTIME, state $state"
    other="$(sim_other_booted "$UDID" | head -n 1)"
    [[ -z "$other" ]] || die "another simulator is already booted ($other); shut it down first"
    if [[ "$state" != "Booted" ]]; then
        log "booting $UDID"
        xcrun simctl boot "$UDID"
        BOOTED_BY_US=1
    fi
    xcrun simctl bootstatus "$UDID" -b >/dev/null
    DEVICE_READY=1
    ORIG_APPEARANCE="$(xcrun simctl ui "$UDID" appearance 2>/dev/null || true)"
    ORIG_CONTENT_SIZE="$(xcrun simctl ui "$UDID" content_size 2>/dev/null || true)"
    LOCALE="$(xcrun simctl spawn "$UDID" defaults read -g AppleLocale 2>/dev/null || echo unknown)"
}

# shellcheck disable=SC2329  # invoked via trap
cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n "$LAUNCH_PID" ]] && kill -0 "$LAUNCH_PID" 2>/dev/null; then
        xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
        kill "$LAUNCH_PID" 2>/dev/null || true
    fi
    if [[ $DEVICE_READY -eq 1 ]]; then
        xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
        xcrun simctl status_bar "$UDID" clear >/dev/null 2>&1 || true
        [[ -z "$ORIG_APPEARANCE" || "$ORIG_APPEARANCE" == "unsupported" ]] ||
            xcrun simctl ui "$UDID" appearance "$ORIG_APPEARANCE" >/dev/null 2>&1 || true
        [[ -z "$ORIG_CONTENT_SIZE" || "$ORIG_CONTENT_SIZE" == "unknown" ]] ||
            xcrun simctl ui "$UDID" content_size "$ORIG_CONTENT_SIZE" >/dev/null 2>&1 || true
        if [[ $BOOTED_BY_US -eq 1 && $KEEP_BOOTED -eq 0 ]]; then
            log "shutting down $UDID (booted by this run)"
            xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
        fi
    fi
    exit "$status"
}

# ----------------------------------------------------------------- capture ---

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

image_size() {
    python3 -I -c 'import sys; from PIL import Image; im = Image.open(sys.argv[1]); print(f"{im.width}x{im.height}")' "$1"
}

# First line of $2 starting with marker $1 (PTY \r stripped), or "".
marker_line() { tr -d '\r' <"$2" | grep -m1 -E "^$1( |\$)" || true; }

tsv() { local IFS=$'\t'; printf '%s\n' "$*"; }

# capture <cfg> <arm> <fixture> <position> <appearance> <step>
capture() {
    local cfg="$1" arm="$2" fixture="$3" pos="$4" appearance="$5" step="$6"
    local app png launch_log app_sha installed_sha container ready stats want
    app="$(arm_app "$arm")"
    png="$CAPTURES/$cfg-$arm.png"
    launch_log="$CAPTURES/$cfg-$arm.log"
    local -a args=()
    while IFS= read -r word; do args+=("$word"); done < <(arm_args "$arm" "$fixture" "$pos" "$step")
    rm -f "$png"

    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl install "$UDID" "$app"
    app_sha="$(sha256 "$app/ADFReader")"
    container="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" app)"
    installed_sha="$(sha256 "$container/ADFReader")"
    if [[ "$installed_sha" != "$app_sha" ]]; then
        log "$cfg-$arm: installed sha256 $installed_sha != $app_sha"
        return 1
    fi
    xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged \
        --batteryLevel 100 --cellularBars 4 --wifiBars 3 --dataNetwork wifi
    xcrun simctl ui "$UDID" appearance "$appearance"
    xcrun simctl ui "$UDID" content_size "$CONTENT_SIZE"

    {
        echo "APP: $app"
        echo "APP_SHA256: $app_sha"
        echo "LAUNCH_CMD: xcrun simctl launch --console-pty $UDID $BUNDLE_ID ${args[*]}"
    } >"$launch_log"
    xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID" "${args[@]}" >>"$launch_log" 2>&1 &
    LAUNCH_PID=$!

    local deadline=$(( SECONDS + ${READY_TIMEOUT%.*} ))
    while [[ -z "$(marker_line READY "$launch_log")" ]]; do
        if ! kill -0 "$LAUNCH_PID" 2>/dev/null; then
            log "$cfg-$arm: app exited before READY (see $launch_log)"
            LAUNCH_PID=""
            return 1
        fi
        if (( SECONDS > deadline )); then
            log "$cfg-$arm: no READY after ${READY_TIMEOUT}s (see $launch_log)"
            xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
            wait "$LAUNCH_PID" 2>/dev/null || true
            LAUNCH_PID=""
            return 1
        fi
        sleep 0.2
    done
    ready="$(marker_line READY "$launch_log")"
    sleep "$SCROLL_WAIT_SECONDS"
    sleep "$SETTLE_SECONDS"
    if ! kill -0 "$LAUNCH_PID" 2>/dev/null; then
        log "$cfg-$arm: app exited during settle (see $launch_log)"
        LAUNCH_PID=""
        return 1
    fi
    xcrun simctl io "$UDID" screenshot --type=png "$png" >/dev/null 2>&1
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    wait "$LAUNCH_PID" 2>/dev/null || true
    LAUNCH_PID=""

    local problems=""
    case "$ready" in
        "READY fixture=$fixture "*) ;;
        *) problems="READY names another fixture: '$ready'" ;;
    esac
    stats="$(marker_line RENDERER_STATS "$launch_log")"
    want="$(expected_renderer "$arm")"
    if [[ $RENDERER_STATS -eq 1 && -n "$want" ]]; then
        case " $stats " in
            *" renderer=$want "*) ;;
            *) problems="${problems:+$problems; }RENDERER_STATS missing or not renderer=$want: '${stats:-absent}'" ;;
        esac
    fi
    [[ -s "$png" ]] || problems="${problems:+$problems; }no screenshot written"

    tsv "$cfg-$arm" "$arm" "$fixture" "$pos" "$appearance" "$step" "$CONTENT_SIZE" "$app" "$app_sha" \
        "$installed_sha" "${args[*]}" "$UDID" "$DEVICE_NAME" "$DEVICE_RUNTIME" "$LOCALE" "$ready" \
        "${stats:-}" "$( [[ -s "$png" ]] && sha256 "$png" || echo missing )" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${problems:-ok}" >>"$MANIFEST"

    if [[ -n "$problems" ]]; then
        log "$cfg-$arm: $problems"
        return 1
    fi
    if [[ $MASKS_EXPLICIT -eq 0 ]]; then
        local size
        size="$(image_size "$png")"
        [[ "$size" == "$EXPECTED_SIZE" ]] ||
            die "screenshot is $size, default masks are for $EXPECTED_SIZE (iPhone 17 Pro); pass --top-band/--bottom-band/--mask for this device"
    fi
    log "captured $cfg-$arm"
}

CAPTURE_FAILURES=0
if [[ $SKIP_CAPTURE -eq 0 ]]; then
    trap cleanup EXIT
    trap 'exit 130' INT TERM
    prepare_device
    {
        echo "date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "host=$(hostname) macOS $(sw_vers -productVersion 2>/dev/null || echo ?) $(uname -m)"
        echo "xcode=$(xcodebuild -version 2>/dev/null | tr '\n' ' ')"
        echo "device=$UDID $DEVICE_NAME $DEVICE_RUNTIME booted_by_this_run=$BOOTED_BY_US"
        echo "locale=$LOCALE content_size=$CONTENT_SIZE (device had: ${ORIG_CONTENT_SIZE:-?}, appearance ${ORIG_APPEARANCE:-?})"
        echo "ref_app=$REF_APP sha256=$(sha256 "$REF_APP/ADFReader")"
        echo "app=$APP sha256=$(sha256 "$APP/ADFReader")"
        echo "arms=$ARMS fixtures=${FIXTURE_SPECS[*]} appearances=$APPEARANCES size_steps=$SIZE_STEPS"
        echo "timing=ready_timeout ${READY_TIMEOUT}s, scroll_wait ${SCROLL_WAIT_SECONDS}s, settle ${SETTLE_SECONDS}s"
        echo "renderer_stats_required=$RENDERER_STATS"
        echo "visual_diff_args=${DIFF_ARGS[*]}"
        echo "checkout=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo ?) dirty_paths=$(git -C "$ROOT" status --porcelain 2>/dev/null | grep -c . || true)"
    } >"$OUT/env.txt"
    tsv capture arm fixture position appearance size_step content_size app app_sha256 installed_sha256 \
        argv udid device runtime locale ready_line renderer_stats png_sha256 captured_utc status >"$MANIFEST"

    for entry in "${PLAN[@]}"; do
        IFS=$'\t' read -r cfg fixture pos appearance step <<<"$entry"
        for arm in $ARMS; do
            capture "$cfg" "$arm" "$fixture" "$pos" "$appearance" "$step" ||
                CAPTURE_FAILURES=$(( CAPTURE_FAILURES + 1 ))
        done
    done
fi

# ------------------------------------------------------------------- score ---

build_pairs 1
[[ ${#PAIR_ARGS[@]} -gt 0 ]] || { log "nothing to compare under $CAPTURES"; exit 1; }
DIFF_STATUS=0
python3 -I "$SCRIPT_DIR/visual_diff.py" --out "$OUT" "${DIFF_ARGS[@]}" "${PAIR_ARGS[@]}" || DIFF_STATUS=$?

echo
echo "captures:  $CAPTURES"
echo "manifest:  $MANIFEST"
echo "scores:    $OUT/scores.csv  $OUT/scores.json"
echo "summary:   $OUT/summary.md"
if (( CAPTURE_FAILURES > 0 )); then
    log "FAIL: $CAPTURE_FAILURES capture(s) failed (their pairs are not scored)"
    exit 1
fi
expected_pairs=0
for arm in A2 B C; do has_arm "$arm" && expected_pairs=$(( expected_pairs + ${#PLAN[@]} )); done
if (( ${#PAIR_ARGS[@]} / 5 != expected_pairs )); then
    log "FAIL: scored $(( ${#PAIR_ARGS[@]} / 5 )) of $expected_pairs pairs (captures missing under $CAPTURES)"
    exit 1
fi
case "$DIFF_STATUS" in
    0) log "PASS" ;;
    1) log "FAIL: see $OUT/summary.md" ;;
    *) log "visual_diff.py error (exit $DIFF_STATUS)" ;;
esac
exit "$DIFF_STATUS"
