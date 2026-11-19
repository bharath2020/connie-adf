# Instruments profile check (simulator)

`Scripts/perf-instruments.sh` compares two refs of the demo app using an
Instruments (`xctrace`) Time Profiler recording. Each recording is a ~30 s
autoscroll of one mixed, performance-heavy document. The script prints
quantified main-thread CPU and hitch figures for base and candidate, plus a
PASS / WARN / FAIL verdict. A comparison takes about 10–15 minutes,
compared with 40–110 minutes for the frame gate (`Scripts/perf-gate.sh`).

TL;DR

```text
perf-instruments.sh <base> <cand>
  build each ref once (Release, simulator, cached by sha)
  -> inject Fixtures/perf-mixed.json into both apps
  -> boot own simulator -> warm up
  -> 3 x (base, cand) interleaved: xctrace record (Time Profiler + stdout)
     of "-fixture perf-mixed -autoscroll"   (~60 s each)
  -> xctrace export -> perf_instruments.py: metrics over the scroll window
  -> markdown table + OVERALL: PASS | WARN | FAIL | INVALID
```

## Usage

```sh
# main vs your branch, SwiftUI renderer (the default)
Scripts/perf-instruments.sh main HEAD

# with TextKit 2 on in both arms
Scripts/perf-instruments.sh --app-args "-textkit2" main HEAD

# repeat runs: keep and reuse one simulator (much faster after the first)
Scripts/perf-instruments.sh --sim-name adf-perf-instruments-$USER main HEAD
```

Run `Scripts/perf-instruments.sh --help` to see every option:

- `--runs N`: recordings per arm (default 3).
- `--fixture NAME`: the document to scroll (default `perf-mixed`).
- `--out DIR`: the results folder.
- `--cache DIR`: where built apps are kept, one per commit.
- `--udid UDID` or `--sim-name NAME`: reuse a simulator.
- `--time-limit SECS`: the per-recording cap.
- `--busy-wait SECS`: the longest wait for another lane's frame run.
- `--build-only`: build the two apps and stop.

The exit status is 0 for PASS, 1 for FAIL, 3 for WARN, and 2 for INVALID or
a usage or driver error.

The results folder holds these files:

- `summary.md` and `summary.json`: the comparison table and verdict.
- `results.jsonl`: one line of metrics per recording.
- `env.txt`: the shas, fixture hash, device, Xcode version, host load and
  timings.
- `traces/*.trace`: open these in Instruments to dig in.
- `logs/`: build, xctrace and warm-up logs.

Shared-Mac etiquette:

- The script never records while another lane's `perf-gate.sh` or
  `perf_trial.py` frame run is active. It waits for that run, up to
  `--busy-wait` seconds.
- The script creates its own simulator and deletes it on exit, unless you
  pass `--sim-name` or `--udid`.
- Never pass another lane's simulator, or the captain's play simulator, to
  `--udid` or `--sim-name`.

## The document: `Fixtures/perf-mixed.json`

`Tools/make-perf-mixed.py` generates this document deterministically from
blocks of the existing generated fixtures. It has 149 top-level blocks
(272 rows when loaded) in 7 sections. Each section mixes the expensive
families:

- 8 dense lists: bullet, ordered, task and decision lists (from `list-dense`).
- 2 mixed-mark paragraphs (from `text-dense`).
- A ~2,500-character slice of a long paragraph (from `long-paragraph`).
- 2 code blocks (from `code-dense`).
- A 12-row table with its header (from `giant-table`).
- 2 images, which use local `placeholder://` URLs (from `media-gallery`).
- Smart links: 2 inline cards and a block card.
- A panel and a blockquote.

Nothing in the document uses the network. At the AutoScroller's fixed
1,200 pt/s, one pass takes about 30 s.

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
0.5 s.

| Metric | Definition | Gate |
|---|---|---|
| Renderer CPU | Main-thread CPU in ms per second of scroll, counting only samples whose stack holds a renderer frame. Renderer frames are app code (the `ADFReader` binary, which links `ADFRendering` statically), TextKit (`UIFoundation`, `NSText*`) or SwiftUI (`SwiftUI`, `SwiftUICore`, `AttributeGraph`). Only frames leafward of the innermost run-loop frame count, because `main`, `UIApplicationMain` and SwiftUI's `App.main` sit under every sample. | **gated** |
| Main-thread CPU | All main-thread CPU, in ms per second of scroll. | **gated** |
| of which app code, of which TextKit | Diagnostic shares of the renderer CPU. Most SwiftUI row work runs inside the attribute graph with no app frame on the stack. | report-only |
| Hitch time ratio, longest hitch, hitch count | Trace-derived hitches. A busy stretch is a run of main-thread samples with no gap longer than 1.5 sample intervals. A stretch longer than 16.67 ms is a hitch, and the excess counts toward the ratio. | report-only |
| App hitch ratio, app dropped frames | The app's own `CADisplayLink` figures from `SCROLL_METRICS`. | report-only |

The verdict compares the median of each arm. CPU limits are relative,
`(cand − base) / base`; the others are absolute. The limits live in `LIMITS`
in `Scripts/perf_instruments.py`.

Two rules guard against a busy host:

- **Host-starved runs are excluded.** The scroll is paced by sleeps, so its
  length is fixed by the document. A run whose scroll window is more than
  1.2 × the median window was starved by the host, and it measures the
  host rather than the app. The analyzer excludes it and names it in the
  summary.
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

## Calibration (main vs main) and noise

CALIBRATION_PLACEHOLDER

## How it fits with the other perf checks

`perf-instruments.sh` fills the frame-tier slot next to the existing frame
gate. It does not replace `Scripts/perf-gate.sh`:

| | `perf-gate.sh` (frame gate) | `perf-instruments.sh` |
|---|---|---|
| Document | stress-5k, list-dense, ... (up to 8.5 min of scroll each) | perf-mixed (~30 s) |
| Measures | app `CADisplayLink` frames, memory | Time Profiler: main-thread and renderer CPU, trace-derived hitches |
| Time per PR | 40–110 min, plus waiting for a quiet host | ~10–15 min |
| Busy host | must wait for quiet | tolerated; starved runs are excluded |
| Sees GPU and render-server stalls | partly (frame drops) | no (simulator); yes on a device, later |

To run on a real iPhone later, swap `--device` to the phone and add the
Animation Hitches template. The analyzer's window logic needs no change.
