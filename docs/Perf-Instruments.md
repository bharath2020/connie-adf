# Instruments profile check (simulator)

`Scripts/perf-instruments.sh` compares two refs of the demo app using an
Instruments (`xctrace`) Time Profiler recording. Each recording is a ~59 s
autoscroll of one performance-heavy document: a dense-list section first,
then mixed sections. The script prints quantified main-thread CPU, renderer
CPU, burst and hitch figures for base and candidate, plus a
PASS / WARN / FAIL verdict. A comparison takes about 13–20 minutes,
compared with 40–110 minutes for the frame gate (`Scripts/perf-gate.sh`).

TL;DR

```text
perf-instruments.sh <base> <cand>
  build each ref once (Release, simulator, cached by sha; ~25–60 s each)
  -> inject Fixtures/perf-mixed.json into both apps
  -> boot own simulator -> warm up (3–6 min)
  -> 3 x (base, cand) interleaved: xctrace record (Time Profiler + stdout)
     of "-fixture perf-mixed -autoscroll <args>"   (~2 min each)
  -> xctrace export -> perf_instruments.py: metrics over the scroll window
     and over its first 28 s (the list section)
  -> markdown table + OVERALL: PASS | WARN | FAIL | INVALID

gated:  renderer CPU (+10 / +20 %)
        app code + TextKit CPU (+10 / +15 %), whole window and list window
report: everything else (main-thread CPU, bursts, hitches, CADisplayLink)
```

## Usage

```sh
# main vs your branch, SwiftUI renderer (the default)
Scripts/perf-instruments.sh main HEAD

# with TextKit 2 on in both arms
Scripts/perf-instruments.sh --app-args "-textkit2" main HEAD

# one build, TextKit 2 off (base) vs on (candidate)
Scripts/perf-instruments.sh --cand-args "-textkit2" a76736f a76736f

# repeat runs: keep and reuse one simulator (much faster after the first)
Scripts/perf-instruments.sh --sim-name adf-perf-instruments-$USER main HEAD

# re-run the analysis offline on an existing results folder
python3 -I Scripts/perf_instruments.py reanalyze --dir <results-folder>
```

Run `Scripts/perf-instruments.sh --help` to see every option:

- `--runs N`: recordings per arm, interleaved (default 3).
- `--fixture NAME`: the document to scroll (default `perf-mixed`).
- `--app-args "ARGS"`: extra launch arguments for both arms.
- `--base-args "ARGS"`, `--cand-args "ARGS"`: extra launch arguments for
  one arm only, after `--app-args`. With the same ref on both sides, this
  compares two launch modes of one build.
- `--list-window-s S`: also measure the first S seconds of the scroll
  window on their own (the `List window:` rows). Default 28 for
  `perf-mixed`, 0 (off) for other fixtures.
- `--out DIR`: the results folder.
- `--cache DIR`: where built apps are kept, one per commit.
- `--udid UDID` or `--sim-name NAME`: reuse a simulator. `--keep-sim`
  keeps a simulator the script created.
- `--time-limit SECS`: the per-recording cap (default 300).
- `--busy-wait SECS`: the longest wait for another lane's frame run
  (default 1800).
- `--build-only`: build the two apps and stop.

The exit status is 0 for PASS, 1 for FAIL, 3 for WARN, and 2 for INVALID or
a usage or driver error.

The results folder holds these files:

- `summary.md` and `summary.json`: the comparison table and verdict.
- `results.jsonl`: one line of metrics per recording.
- `env.txt`: the shas, fixture hash, each arm's launch arguments, the list
  window, device, Xcode version, host load and timings.
- `traces/*.trace`: open these in Instruments to dig in.
- `exports/`: the stdout tables. The large time-profile export is dropped
  after analysis; `reanalyze` re-exports it from the trace.
- `logs/`: build, xctrace, warm-up logs and `timings.txt`.

`perf_instruments.py reanalyze --dir <results-folder>` re-runs the analysis
on every trace in the folder, for example after a metric or limit change.
It keeps the old `results.jsonl` as `results.prev.jsonl` and rewrites
`summary.md` and `summary.json`. It takes the list window from `env.txt`
unless you pass `--list-window-s`; `--keep-exports` keeps the re-exported
time-profile tables.

Shared-Mac etiquette:

- The script never records while another lane's `perf-gate.sh` or
  `perf_trial.py` frame run is active. It waits for that run, up to
  `--busy-wait` seconds.
- The script creates its own simulator and deletes it on exit, unless you
  pass `--sim-name` or `--udid`.
- Never pass another lane's simulator, or the captain's play simulator, to
  `--udid` or `--sim-name`.

Known xctrace hang: a recording that reaches `--time-limit` can hang while
it finishes (13 minutes observed). A watchdog stops `xctrace` at the time
limit + 120 s and notes it in `logs/timings.txt`.

## The document: `Fixtures/perf-mixed.json`

`Tools/make-perf-mixed.py` generates this document deterministically from
blocks of the existing generated fixtures. It has 310 top-level blocks in
two parts, in this order:

1. **The list section** (blocks 0–160): a heading, then `list-dense`
   blocks 0–159 verbatim. That is 8 whole cycles of `list-dense`'s 20-block
   pattern (7 bullet, 6 ordered, 4 task, 3 decision lists). These are the
   TextKit 2-eligible list rows of GitHub issue 10. The section scrolls for
   ~31 s and fills the start of the scroll window, so the default 28 s list
   window ends before the mixed rows start to load.
2. **The mixed sections** (blocks 161–309): the earlier 149-block
   document, unchanged. It has 7 sections, and each one mixes the
   expensive families:
   - 8 dense lists: bullet, ordered, task and decision lists (from
     `list-dense`).
   - 2 mixed-mark paragraphs (from `text-dense`).
   - A ~2,500-character slice of a long paragraph (from `long-paragraph`).
   - 2 code blocks (from `code-dense`).
   - A 12-row table with its header (from `giant-table`).
   - 2 images, which use local `placeholder://` URLs (from
     `media-gallery`).
   - Smart links: 2 inline cards and a block card.
   - A panel and a blockquote.

Nothing in the document uses the network. At the AutoScroller's fixed
1,200 pt/s, one pass takes about 59 s.

The script copies the candidate's `Fixtures/perf-mixed.json` into both
`.app` bundles. When the candidate has no such file, it uses the working
tree's copy. This lets refs that predate the fixture, such as 86abd56, run
it, and both arms always scroll the same bytes. If you edit the generator,
earlier results no longer compare with new ones.

## What is measured

All metrics are computed on the main thread of the app process, over the
autoscroll window only. Launch, document load and exit are excluded.

The AutoScroller waits 3 s after `READY`, scrolls, waits 500 ms, and then
prints and flushes the `SCROLL_METRICS … scrollMs=…` line. The
stdout/stderr instrument stamps that line on the trace clock, so the scroll
window is `[t − 0.5 s − scrollMs, t − 0.5 s]`. The analyzer cross-checks the
window against `READY` + 3 s. In the runs so far, the two agree to within
0.5 s. The list window is the first `--list-window-s` seconds of the scroll
window.

A sample is tagged by the frames leafward of the innermost run-loop frame
only, because `main`, `UIApplicationMain` and SwiftUI's `App.main` sit under
every sample:

- **App code**: the `ADFReader` binary, which links `ADFRendering`
  statically.
- **TextKit**: `UIFoundation`, or an `NSText*` symbol.
- **SwiftUI**: `SwiftUI`, `SwiftUICore` or `AttributeGraph`.

| Metric | Definition | Gate (warn / fail) |
|---|---|---|
| Renderer CPU | Main-thread CPU in ms per second of scroll, in samples tagged app code, TextKit or SwiftUI. | **gated**, +10 % / +20 % |
| App code + TextKit CPU | Main-thread CPU in samples tagged app code or TextKit. | **gated**, +10 % / +15 % |
| List window: app code + TextKit CPU | The same, over the list window only. | **gated**, +10 % / +15 % |
| Main-thread CPU | All main-thread CPU. | report-only |
| of which app code, of which TextKit | The two shares of the renderer CPU, apart. | report-only |
| Burst time ≥ 12 ms | A busy stretch is a run of main-thread samples with no gap longer than 1.5 sample intervals. Burst time is the whole length of the stretches of at least 12 ms, per second of scroll. | report-only |
| List window: renderer CPU, burst time ≥ 12 ms | The same, over the list window only. | report-only |
| Hitch time ratio, longest hitch, hitch count | Trace-derived hitches: a busy stretch longer than 16.67 ms is a hitch, and its excess counts toward the ratio. | report-only |
| App hitch ratio, app dropped frames | The app's own `CADisplayLink` figures from `SCROLL_METRICS`. | report-only |

The verdict compares the median of each arm. CPU and burst-time limits are
relative, `(cand − base) / base`; the others are absolute. Report-only rows
show their verdict in lower case, "(report-only)", and never change
OVERALL. The limits live in `LIMITS` in `Scripts/perf_instruments.py`.

**Why app code + TextKit is a gate.** It is the renderer's own work: row and
view creation, hosting, and TextKit layout. It is also the low-noise part of
the main thread: its spread within an arm is a few ms/s, while SwiftUI,
AttributeGraph and system work move with the host. **Caveat:** a change that
moves work from SwiftUI into app code or TextKit raises this metric even
when total CPU is flat. That is exactly the shape of issue 10. So a FAIL
here means "open the traces and look". The reviewer can accept a deliberate
move of work.

Two rules guard against a busy host:

- **Host-starved base runs are excluded.** The scroll is paced by sleeps,
  so its length is fixed by the document. A base run whose scroll window
  is more than 1.2 × the base arm's median window was starved by the
  host, and it measures the host rather than the app. The analyzer
  excludes it and names it in the summary. Candidate runs are never
  excluded for a long window: a candidate that keeps the main thread busy
  also slows its own scroll, and that is a regression to catch, not host
  noise.
- **Too few runs is INVALID.** If an arm has fewer than 2 usable runs, the
  result is INVALID; re-run, ideally on a quieter host.

## Why Time Profiler, and not Animation Hitches

On an iOS simulator, with Xcode 27.1, these templates and instruments
refuse to record:

- The Animation Hitches template fails with "Hitches is not supported on
  this platform".
- The graphics instruments fail with "The graphics instruments do not
  support the current device". These are Core Animation FPS, Frame
  Lifetimes, Display and Core Animation Commits.
- Run Loops fails with "not supported on iOS Simulator".
- `--target-stdout` fails with "Device does not support stdout
  redirection". The stdout/stderr instrument works instead.
- The SwiftUI instrument records but yields no data.

Time Profiler, stdout/stderr and Hangs all work. The hitch figures here
therefore come from main-thread CPU stretches. They show app work that
overruns a frame. They cannot see render-server or GPU stalls; the real
Hitches instrument on a physical iPhone would.

The app's own `CADisplayLink` numbers are printed for reference only. On
the simulator they mostly measure how promptly the host delivers frames,
and a single starved run reads around 970 ms/s.

## Calibration and noise

TL;DR: on the current document, only app code + TextKit CPU separates
issue 10 from main-vs-main noise. Renderer CPU moves ±10 % between two
invocations of the same build, so its limits are wider. Main-thread CPU and
burst time are noisier than any useful limit.

Medians of 3 runs per arm, Δ = (cand − base) / base. "TK2" means
`-textkit2` in both arms.

| Round, document | Comparison | Renderer CPU | App code + TextKit | List window: app code + TextKit | Burst ≥ 12 ms | Main-thread CPU | Gated verdict |
|---|---|---|---|---|---|---|---|
| 1, old (149 blocks) | issue 10: 86abd56 → a76736f, TK2 | +3.6 % | – | – | – | −10.0 % | PASS (missed) |
| 1, old | 67d3095 → 797fd86, default | −3.3 % | – | – | – | +16.6 % | noise (see below) |
| 2, current | main vs main, default | −9.7 % | +2.3 % | +0.4 % | −4.9 % | +6.2 % | PASS |
| 2, current | main vs main, TK2 | −1.2 % | −9.0 % | −12.2 % | +5.8 % | −9.5 % | PASS |
| 2, current | issue 10: 86abd56 → a76736f, TK2 | +4.6 % | **+18.1 %** | **+22.9 %** | +28.8 % | +3.2 % | **FAIL** |
| 2, current | issue 10: a76736f, TK2 off → on | −9.1 % | **+29.1 %** | **+32.9 %** | −10.0 % | +5.5 % | **FAIL** |

Round 1 used the old gates; round 2 was re-analyzed with the current ones.
Round 1's TextKit share alone moved +14.0 % on issue 10, which was not
enough to call.

Same-build spread:

- **Renderer CPU** moved −9.7 % main vs main. Hence +10 % / +20 %.
- **Main-thread CPU** spread up to ~22 % within one arm on a quiet Mac, and
  up to a third on a loaded one, wider than any useful fail limit. In
  round 1, 67d3095 → 797fd86 read +16.6 % and failed the old gate. The rise
  had no app frames: it was UIKit update-cycle scheduling and kernel
  `mach_msg` time, in 2 of the 3 candidate runs only. Main-thread CPU is
  therefore report-only.
- **Burst time** did not separate issue 10 from noise. It rose +28.8 % on
  pr1 → pr2 but fell −10 % on TextKit 2 off → on, and the list window's
  burst time moved −23.3 % main vs main. Bursts are report-only.

### Detecting issue 10

Issue 10 is the cost of TextKit 2 list rows (GitHub issue 10). On the
simulator it does not show in total renderer CPU or in bursts: TextKit 2
moves list text work out of SwiftUI into app code, so the renderer total
stays flat or falls (−9.1 % off → on) while the app-code share roughly
doubles. App code + TextKit CPU catches it, in the whole window and more
strongly in the list window.

The old 149-block document missed it because TextKit 2 takes only list
rows whose text is body-styled paragraphs
(`Sources/ADFRendering/TextKit2/TextKit2Scope.swift`): no sub- or
superscript or small text beside another block, no heading beside text, and
no nested list, code, table or media in the row. The old document's lists
are heavy in sub/superscript marks and nesting, so most of them likely fell
outside that scope (inferred from the fixture; not counted). The list section now comes
verbatim from `list-dense`, the issue's own fixture.

To check a change for this shape, run with TextKit 2 on in both arms
(`--app-args "-textkit2"`), or compare one build's two modes
(`--cand-args "-textkit2" <sha> <sha>`), and read the app code + TextKit
rows and the `of which app code` row.

### Final round

Fresh runs with the final gates, 2026-11-20, quiet Mac (load 3–7), 3 runs
per arm, medians. Δ is (cand − base) / base.

| Comparison | Renderer | Renderer CPU | App + TextKit | List window app + TextKit | Main-thread (report-only) | Verdict | Time |
|---|---|---|---|---|---|---|---|
| main vs main (67d3095) | default | −3.4 % | −1.3 % | −0.3 % | −2.8 % | PASS | 15 min |
| issue 10: 86abd56 → a76736f | TextKit 2 | +1.5 % | +11.0 % (warn) | **+20.2 %** | +0.4 % | **FAIL** | 16 min |
| 33d549f → 802eced (TextKit 2 stack PR 4) | TextKit 2 | +13.5 % (warn) | −0.5 % | −2.3 % | +5.8 % | WARN | 19 min |
| 33d549f → 802eced | default | −3.1 % | −2.2 % | +3.9 % | −3.6 % | PASS | 13 min |
| 67d3095 → 797fd86 (emoji resolvers) | default | −2.0 % | +4.6 % | +6.9 % | +3.9 % | PASS | 13 min |
| 67d3095 → 797fd86 | TextKit 2 | +0.8 % | −4.8 % | −9.0 % | +6.1 % | PASS | 13 min |
| 67d3095 → d6699aa (media resolvers) | default | −6.7 % | +3.9 % | +6.3 % | −6.6 % | PASS | 14 min |
| 67d3095 → d6699aa | TextKit 2 | −1.9 % | −3.5 % | −0.6 % | −2.6 % | PASS | 13 min |

The emoji branch's earlier +16.6 % main-thread CPU (old document, first
round) read +3.9 % and +6.1 % here, which confirms it as host noise.
PR 4's renderer-CPU WARN (+13.5 %) has a 10.1 ms/s spread within the
candidate arm and no rise in app code + TextKit; it is within the ±10 %
same-build swing seen above, so treat it as a re-run-to-confirm warning,
not a regression.

## How it fits with the other perf checks

`perf-instruments.sh` fills the frame-tier slot next to the existing frame
gate. It does not replace `Scripts/perf-gate.sh`:

| | `perf-gate.sh` (frame gate) | `perf-instruments.sh` |
|---|---|---|
| Document | stress-5k, list-dense, ... (up to 8.5 min of scroll each) | perf-mixed (~59 s) |
| Measures | app `CADisplayLink` frames, memory | Time Profiler: renderer and app code + TextKit CPU (gated); main-thread CPU, bursts, trace-derived hitches (report-only) |
| Time per PR | 40–110 min, plus waiting for a quiet host | ~13–20 min |
| Busy host | must wait for quiet | tolerated; starved base runs are excluded |
| Sees GPU and render-server stalls | partly (frame drops) | no (simulator); yes on a device, later |

To run on a real iPhone later, swap `--device` to the phone and add the
Animation Hitches template. The analyzer's window logic needs no change.
